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
///  - Monday at the configured prompt time prompts for the bundle
///  - Thursday at the configured reminder time reminds non-responders
///  - Friday at the configured lock time locks availability
///  - Friday at the configured checker time pushes the allocation list
///  - Sunday 20:00 / Monday 08:00 attendance-marking reminders to admins
///
/// Allocation is dynamic: every availability indication arms a one-shot run
/// at the next sharp hour (see [scheduleDynamicAllocation]). The old Friday
/// batch allocation is deprecated and no longer fires.
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
      final monday = WeekMath.mondayOf(now);
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

      // Monday: availability prompts for the current bundle.
      if (_sameDay(today, monday) && !now.isBefore(w.promptDay)) {
        await service.sendPrompts(w);
      }

      // Thursday: reminders to non-responders of the bundle.
      if (_sameDay(today, monday.add(const Duration(days: 3))) &&
          !now.isBefore(w.reminderDay)) {
        await service.sendReminders(w);
      }

      // Allocation is dynamic: it runs at the next sharp hour after each
      // availability indication (see scheduleDynamicAllocation). The Friday
      // batch is deprecated and no longer fires here.

      // Catch-up: the sharp-hour run armed by an indication is a one-shot
      // timer, so a restart between the indication and the sharp hour drops
      // it. Re-optimize the open weekends on every tick (startup + 12h
      // safety net) so a pending allocation is never lost. Idempotent —
      // already-allocated members are locked in and only newly-allocated
      // members are notified.
      await _runDynamicAllocation();

      // Friday checker time: push the current weekend's full allocation to the
      // `check` tier — a final confirmation list, independent of their
      // on-demand status button.
      final checkerAt = scheduleRuntime.schedule.checker.on(
        monday.add(const Duration(days: 4)),
      );
      if (_sameDay(today, checkerAt) && !now.isBefore(checkerAt)) {
        await service.sendCheckList(w.sat0);
      }

      // Attendance-marking reminders for the weekend just finished:
      // Sunday evening and again Monday morning.
      final weekendSat = monday.subtract(const Duration(days: 2));
      final sunday = monday.subtract(const Duration(days: 1));
      if (_sameDay(today, sunday) && now.hour >= 20) {
        await service.remindAttendanceMarking(weekendSat, today);
      }
      if (_sameDay(today, monday) && now.hour >= 8) {
        await service.remindAttendanceMarking(weekendSat, today);
        await service.remindAbsentMembers(today);
      }
    } catch (e) {
      // Scheduling failures should not kill the bot.
      LogRing.log('scheduler error: $e');
    }
    _scheduleNext();
  }

  RollingWindow _window(DateTime now) => scheduleRuntime.window(now);

  /// Arms a one-shot timer for the next upcoming milestone so it fires on
  /// the sharp scheduled hour instead of on the next 12h tick.
  void _scheduleNext() {
    final now = config.toLocal(Config.nowUtc());
    final w = _window(now);
    final monday = WeekMath.mondayOf(now);
    final nextWindow = _window(now.add(const Duration(days: 7)));
    final nextMonday = monday.add(const Duration(days: 7));

    final due = <DateTime>[
      // This week's milestones, if still in the future.
      w.promptDay,
      w.reminderDay,
      w.deadline0,
      w.deadline1,
      scheduleRuntime.schedule.checker.on(
        monday.add(const Duration(days: 4)),
      ),
      monday.add(const Duration(days: 6, hours: 20)), // Sunday 20:00
      nextWindow.promptDay,
      nextWindow.reminderDay,
      nextWindow.deadline0,
      nextWindow.deadline1,
      scheduleRuntime.schedule.checker.on(nextMonday.add(const Duration(days: 4))),
      nextMonday.add(const Duration(days: 6, hours: 20)), // Sunday 20:00
      monday.add(const Duration(hours: 8)), // Monday 08:00
      nextMonday.add(const Duration(hours: 8)), // Monday 08:00
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
