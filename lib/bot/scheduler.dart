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
///  - Friday 18:00   deadline for this weekend (locks)
///  - Friday 18:00+  allocation of this weekend's sessions
///  - next Friday 18:00+ allocation of the second weekend's sessions
///  - Sunday 20:00 / Monday 08:00 attendance-marking reminders to admins
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
    _timer = null;
    _milestone = null;
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

      // Friday 18:00+: allocate this weekend (once, then flagged).
      if (!repo.weekendAllocated(w.sat0) &&
          !now.isBefore(w.deadline0) &&
          now.isBefore(w.sat1)) {
        await service.allocateWeekend(w.sat0);
      }

      // Next Friday 18:00+: allocate the second weekend of the bundle.
      if (!repo.weekendAllocated(w.sat1) &&
          !now.isBefore(w.deadline1) &&
          now.isBefore(w.sat1.add(const Duration(days: 7)))) {
        await service.allocateWeekend(w.sat1);
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
      w.deadline0,
      w.deadline1,
      monday.add(const Duration(days: 6, hours: 20)), // Sunday 20:00
    ];
    DateTime? next;
    for (final d in due) {
      if (d.isAfter(now) && (next == null || d.isBefore(next))) next = d;
    }
    if (next == null) return;
    _milestone = Timer(next.difference(now), () => _tick());
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
