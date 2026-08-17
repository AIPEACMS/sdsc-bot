import 'dart:async';

import '../core/models.dart';
import '../core/repo.dart';
import '../core/config.dart';
import '../core/week.dart';
import 'service.dart';
import '../core/log.dart';

/// Periodically drives the rolling schedule. A lightweight Timer replaces a
/// cron daemon and naturally catches up when the bot restarts.
///
/// The rolling window (bundle = current + next weekend) has, every week:
///  - Monday 08:00   prompts for the bundle (quiet users skipped)
///  - Thursday 18:00 reminders to the bundle's non-responders
///  - Friday 18:00   deadline for this weekend (locks availability)
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

  Timer? _timer;
  Timer? _milestone;
  Timer? _allocTimer;

  Scheduler({
    required this.repo,
    required this.config,
    required this.service,
  });

  void start({Duration interval = const Duration(hours: 12)}) {
    unawaited(_tick());
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _milestone?.cancel();
    _allocTimer?.cancel();
    _timer = null;
    _milestone = null;
    _allocTimer = null;
  }

  Future<void> _tick() async {
    _milestone?.cancel();
    try {
      final now = config.toLocal(Config.nowUtc());
      final w = RollingWindow.forDate(now);
      final monday = WeekMath.mondayOf(now);
      final today = DateTime(now.year, now.month, now.day);

      // The window's sessions must exist before anything touches them.
      repo.ensureSessionsForWeekend(
        w.sat0,
        config.slotTimes,
        tzOffsetHours: config.timezoneOffsetHours,
      );
      repo.ensureSessionsForWeekend(
        w.sat1,
        config.slotTimes,
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

  /// Arms a one-shot timer for the next upcoming milestone so it fires on
  /// the sharp scheduled hour instead of on the next 12h tick.
  void _scheduleNext() {
    final now = config.toLocal(Config.nowUtc());
    final w = RollingWindow.forDate(now);
    final monday = WeekMath.mondayOf(now);

    final due = <DateTime>[
      // This week's milestones, if still in the future.
      w.promptDay,
      w.reminderDay,
      monday.add(const Duration(days: 6, hours: 20)), // Sunday 20:00
    ];
    DateTime? next;
    for (final d in due) {
      if (d.isAfter(now) && (next == null || d.isBefore(next))) next = d;
    }
    if (next == null) return;
    _milestone = Timer(next.difference(now), () => _tick());
  }

  /// Arms a one-shot dynamic-allocation run at the next sharp hour. Coalesces:
  /// if a run is already armed, does nothing — indications before the sharp
  /// hour share a single run. Called after every availability indication.
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

  /// Re-optimizes both weekends of the current bundle over the current
  /// availability. Weekends that have already started are left alone.
  Future<void> _runDynamicAllocation() async {
    try {
      final now = config.toLocal(Config.nowUtc());
      final w = RollingWindow.forDate(now);
      if (now.isBefore(w.sat0)) await service.allocateWeekend(w.sat0);
      if (now.isBefore(w.sat1)) await service.allocateWeekend(w.sat1);
      LogRing.log('dynamic allocation run');
    } catch (e) {
      LogRing.log('dynamic allocation error: $e');
    }
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
