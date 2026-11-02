import 'dart:async';

import 'package:televerse/televerse.dart'
    show ChatID, TeleverseException, TeleverseExceptionType, TelegramException;

import 'hold.dart';
import 'service.dart';
import '../core/models.dart';
import '../core/config.dart';
import '../core/log.dart';
import '../core/repo.dart';
import '../core/schedule.dart';
import '../core/week.dart';

part 'scheduler/session_reminders.dart';

/// Drives the rolling schedule in-process and catches up after restarts.
///
/// The rolling window (bundle = current + next weekend) has, every week:
///  - the configured prompt weekday/time prompts for the bundle
///  - the configured reminder weekday/time reminds non-responders
///  - the configured lock weekday/time locks availability
///  - the configured checker weekday/time pushes the allocation list
///  - configured attendance and absence reminders
///
/// New indications allocate immediately; the deprecated sharp-hour path stays
/// for compatibility, while the old Friday batch allocation no longer fires.
///
/// A one-shot is armed to the next milestone for exact timing; a five-minute
/// periodic tick catches restart recovery and policy/allocation changes.
class Scheduler {
  final Repo repo;
  final Config config;
  final CycleService service;
  final ScheduleRuntime scheduleRuntime;

  Timer? _timer;
  Timer? _milestone;
  Timer? _allocTimer;
  DateTime? _nextMilestone;
  bool _workListenerRegistered = false;
  bool _allocationInProgress = false;
  final Set<Future<void>> _activeTicks = {};

  DateTime? get nextMilestone => _nextMilestone;

  Scheduler({
    required this.repo,
    required this.config,
    required this.service,
    ScheduleRuntime? scheduleRuntime,
  }) : scheduleRuntime =
           scheduleRuntime ?? ScheduleRuntime(repo: repo, config: config) {
    this.scheduleRuntime.addListener(reschedule);
  }

  void start({Duration interval = const Duration(minutes: 5)}) {
    if (_timer != null) return;
    if (!_workListenerRegistered) {
      repo.addSessionReminderWorkListener(_wakeSessionReminderWork);
      _workListenerRegistered = true;
    }
    _timer = Timer.periodic(interval, (_) => _tick());
    _scheduleNext();
    unawaited(_tick());
  }

  void stop() {
    _timer?.cancel();
    _milestone?.cancel();
    _allocTimer?.cancel();
    _timer = null;
    _milestone = null;
    _allocTimer = null;
    _nextMilestone = null;
    if (_workListenerRegistered) {
      repo.removeSessionReminderWorkListener(_wakeSessionReminderWork);
      _workListenerRegistered = false;
    }
  }

  Future<void> _tick() {
    final tick = _runTick();
    late final Future<void> trackedTick;
    trackedTick = tick.whenComplete(() {
      _activeTicks.remove(trackedTick);
    });
    _activeTicks.add(trackedTick);
    return trackedTick;
  }

  Future<void> _runTick() async {
    _milestone?.cancel();
    try {
      final nowUtc = Config.nowUtc().toUtc();
      final now = config.toLocal(nowUtc);
      final w = _window(now);
      final today = DateTime(now.year, now.month, now.day);

      // The window's sessions must exist before anything touches them.
      repo.ensureSessionsForWeekend(
        w.sat0,
        repo.scheduleForWeekend(w.sat0),
        tzOffsetHours: config.timezoneOffsetHours,
      );
      repo.ensureSessionsForWeekend(
        w.sat1,
        repo.scheduleForWeekend(w.sat1),
        tzOffsetHours: config.timezoneOffsetHours,
      );

      // Configured prompt event: availability prompts for the current bundle.
      if (_sameDay(today, w.promptDay) && !now.isBefore(w.promptDay)) {
        await service.sendPrompts(w);
      }

      // The configured reminder weekday: reminders to non-responders.
      if (_sameDay(today, w.reminderDay) && !now.isBefore(w.reminderDay)) {
        await service.sendReminders(w);
      }

      // New indications allocate immediately. The periodic catch-up below
      // recovers work after restarts; the deprecated sharp-hour and Friday
      // batch paths do not run here.

      // Catch-up: a restart can interrupt an immediate allocation run.
      // Re-optimize the open weekends on every tick (startup + 5m safety
      // net) so a pending allocation is never lost. Idempotent —
      // already-allocated members are locked in and only newly-allocated
      // members are notified.
      await _runDynamicAllocation();

      // Configured checker event: push the current weekend's full allocation
      // to the `check` tier, independent of their on-demand status button.
      if (_sameDay(today, w.checkerDay) && !now.isBefore(w.checkerDay)) {
        await service.sendCheckList(w.sat0);
      }

      await _sendSessionReminders(this, nowUtc);

      for (final occurrence in _configuredEventOccurrences(now)) {
        if (!_sameDay(today, occurrence.at) || now.isBefore(occurrence.at)) {
          continue;
        }
        final eventDay = DateTime(
          occurrence.at.year,
          occurrence.at.month,
          occurrence.at.day,
        );
        final anchor = latestCompletedSessionBlockStart(occurrence.at);
        switch (occurrence.kind) {
          case _ConfiguredEvent.attendanceInitial:
          case _ConfiguredEvent.attendanceFollowup:
            await service.remindAttendanceMarking(anchor, eventDay);
          case _ConfiguredEvent.absence:
            await service.remindAbsentMembers(anchor, eventDay);
        }
      }
    } catch (e) {
      // Scheduling failures should not kill the bot.
      LogRing.log('scheduler error: $e');
    }
    // stop() nulls _timer before waiting for this tick, so completed work never
    // re-arms a milestone after shutdown begins.
    if (_timer != null) _scheduleNext();
  }

  /// Cancels scheduled work and waits for the current tick to finish.
  Future<void> stopAndWait() async {
    stop();
    await waitForCurrentTicks();
  }

  Future<void> waitForCurrentTicks() async {
    while (_activeTicks.isNotEmpty) {
      await Future.wait(_activeTicks.toList());
    }
  }

  void _wakeSessionReminderWork() {
    if (_timer == null || _allocationInProgress) return;
    _milestone?.cancel();
    unawaited(_tick());
  }

  RollingWindow _window(DateTime now) => scheduleRuntime.window(now);

  List<_ConfiguredOccurrence> _configuredEventOccurrences(DateTime now) {
    final monday = WeekMath.mondayOf(now);
    final schedule = scheduleRuntime.schedule;
    final events = [
      (_ConfiguredEvent.attendanceInitial, schedule.attendanceInitial),
      (_ConfiguredEvent.attendanceFollowup, schedule.attendanceFollowup),
      (_ConfiguredEvent.absence, schedule.absence),
    ];
    return [
      for (final week in [monday, monday.add(const Duration(days: 7))])
        for (final (kind, event) in events)
          _ConfiguredOccurrence(kind, event.on(week)),
    ];
  }

  /// Arms a one-shot timer for the next upcoming milestone so it fires on
  /// the sharp scheduled hour instead of on the next 12h tick.
  void _scheduleNext() {
    final now = config.toLocal(Config.nowUtc());
    final w = _window(now);
    final nextWindow = _window(now.add(const Duration(days: 7)));
    final retryUtc = repo.nextSessionReminderRetryAt(Config.nowUtc());

    final due = <DateTime>[
      // This week's milestones, if still in the future.
      w.promptDay,
      w.reminderDay,
      w.lock0,
      w.lock1,
      w.checkerDay,
      nextWindow.promptDay,
      nextWindow.reminderDay,
      nextWindow.lock0,
      nextWindow.lock1,
      nextWindow.checkerDay,
      ..._configuredEventOccurrences(now).map((event) => event.at),
      ...repo
          .pendingSessionReminderRecipients(
            nowUtc: Config.nowUtc(),
            timezoneOffsetHours: config.timezoneOffsetHours,
          )
          .map(
            (recipient) => sessionReminderDueAt(
              recipient.$2,
              timezoneOffsetHours: config.timezoneOffsetHours,
            ),
          ),
      if (retryUtc != null) config.toLocal(retryUtc),
    ];
    DateTime? next;
    for (final d in due) {
      if (d.isAfter(now) && (next == null || d.isBefore(next))) next = d;
    }
    if (next == null) {
      _nextMilestone = null;
      return;
    }
    _nextMilestone = next;
    _milestone = Timer(next.difference(now), () => _tick());
  }

  /// Re-arms the one-shot timer after a persisted schedule update.
  void reschedule() {
    if (_timer == null) return;
    _milestone?.cancel();
    _scheduleNext();
  }

  /// Legacy path: arms a one-shot dynamic-allocation run at the next sharp hour.
  /// New availability saves use [allocateImmediately].
  /// if a run is already armed, does nothing — indications before the sharp
  /// hour share a single run. Called after every availability indication.
  @Deprecated('Immediate allocation is the default in v3.2.0.')
  void scheduleDynamicAllocation() {
    if (_allocTimer != null) return;
    final now = config.toLocal(Config.nowUtc());
    final next = now.add(const Duration(hours: 1));
    final sharp = DateTime(next.year, next.month, next.day, next.hour);
    _allocTimer = Timer(sharp.difference(now), () {
      _allocTimer = null;
      unawaited(_runDynamicAllocation());
    });
  }

  /// Allocates immediately after an availability indication. The old
  /// sharp-hour timer remains available for compatibility and manual recovery.
  Future<void> allocateImmediately() => _runDynamicAllocation();

  /// Re-optimizes both weekends of the current bundle over the current
  /// availability. Weekends that have already started are left alone.
  Future<void> _runDynamicAllocation() async {
    if (_allocationInProgress) return;
    _allocationInProgress = true;
    try {
      final now = config.toLocal(Config.nowUtc());
      final w = _window(now);
      if (now.isBefore(w.sat0) || now.isBefore(w.sat1)) {
        await service.allocateBundle(w);
      }
      await _sendSessionReminders(this, Config.nowUtc());
      LogRing.log('dynamic allocation run');
    } catch (e) {
      LogRing.log('dynamic allocation error: $e');
    } finally {
      _allocationInProgress = false;
    }
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

enum _ConfiguredEvent { attendanceInitial, attendanceFollowup, absence }

class _ConfiguredOccurrence {
  final _ConfiguredEvent kind;
  final DateTime at;

  const _ConfiguredOccurrence(this.kind, this.at);
}
