import 'dart:async';

import '../core/models.dart';
import '../core/repo.dart';
import '../core/config.dart';
import '../core/week.dart';
import 'service.dart';
import '../core/log.dart';
import '../core/schedule.dart';

/// Periodically drives the rolling schedule. A lightweight Timer replaces a
/// cron daemon and naturally catches up when the bot restarts.
///
/// The rolling window (bundle = current + next weekend) has, every week:
///  - the configured prompt weekday/time prompts for the bundle
///  - the configured reminder weekday/time reminds non-responders
///  - the configured lock weekday/time locks availability
///  - the configured checker weekday/time pushes the allocation list
///  - configured attendance and absence reminders
///
/// New availability indications allocate immediately. The deprecated
/// [scheduleDynamicAllocation] sharp-hour path remains for compatibility; the
/// old Friday batch allocation is deprecated and no longer fires.
///
/// Two timers: a one-shot armed to the next milestone so things fire on the
/// sharp scheduled hour, and a slow periodic safety net that catches up
/// after restarts and drift.
class Scheduler {
  final Repo repo;
  final Config config;
  final CycleService service;
  final ScheduleRuntime scheduleRuntime;

  Timer? _timer;
  Timer? _milestone;
  Timer? _allocTimer;
  DateTime? _nextMilestone;

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

  void start({Duration interval = const Duration(hours: 12)}) {
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
  }

  Future<void> _tick() async {
    _milestone?.cancel();
    try {
      final now = config.toLocal(Config.nowUtc());
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
      // Re-optimize the open weekends on every tick (startup + 12h safety
      // net) so a pending allocation is never lost. Idempotent —
      // already-allocated members are locked in and only newly-allocated
      // members are notified.
      await _runDynamicAllocation();

      // Configured checker event: push the current weekend's full allocation
      // to the `check` tier, independent of their on-demand status button.
      if (_sameDay(today, w.checkerDay) && !now.isBefore(w.checkerDay)) {
        await service.sendCheckList(w.sat0);
      }

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
    _scheduleNext();
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
    try {
      final now = config.toLocal(Config.nowUtc());
      final w = _window(now);
      if (now.isBefore(w.sat0) || now.isBefore(w.sat1)) {
        await service.allocateBundle(w);
      }
      LogRing.log('dynamic allocation run');
    } catch (e) {
      LogRing.log('dynamic allocation error: $e');
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
