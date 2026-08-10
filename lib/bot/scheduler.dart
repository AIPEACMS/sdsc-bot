import 'dart:async';

import '../core/models.dart';
import '../core/repo.dart';
import '../core/config.dart';
import '../core/week.dart';
import 'service.dart';

/// Periodically checks the calendar and fires whatever is due for the current
/// cycle. A lightweight Timer replaces a cron daemon and naturally catches up
/// when the bot restarts.
///
/// Two timers:
///  - a one-shot armed to the next milestone (prompt / reminder / deadline /
///    allocation) so things fire on the sharp hour they are scheduled for;
///  - a slow periodic safety net that catches up after restarts and drift.
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
      final cycle = repo.ensureCurrentCycle(now);

      if (cycle.status == CycleStatus.open && !cycle.promptSent) {
        if (!now.isBefore(cycle.promptDay) && now.isBefore(cycle.deadline)) {
          await service.sendPrompts(cycle);
        }
      }

      if (!cycle.reminderSent && now.isBefore(cycle.deadline)) {
        if (!now.isBefore(cycle.reminderDay)) {
          await service.sendReminders(cycle);
        }
      }

      if (!cycle.allocated && cycle.status != CycleStatus.open) {
        final lastSessionSat = WeekMath.saturdayOfWeek(
          cycle.blockWeek + 1,
          cycle.blockYear,
        );
        final lastSessionEnd =
            lastSessionSat.add(const Duration(days: 2)); // Monday after
        if (!now.isBefore(cycle.allocationDay) &&
            now.isBefore(lastSessionEnd)) {
          await service.allocate(cycle);
        }
      }
    } catch (e) {
      // Scheduling failures should not kill the bot.
      // ignore: avoid_print
      print('scheduler error: $e');
    }
    _scheduleNext();
  }

  /// Arms a one-shot timer for the next not-yet-done milestone of the current
  /// cycle so it fires on the sharp scheduled hour.
  void _scheduleNext() {
    final now = config.toLocal(Config.nowUtc());
    final cycle = repo.ensureCurrentCycle(now);

    final due = <DateTime>[];
    if (cycle.status == CycleStatus.open) {
      if (!cycle.promptSent) due.add(cycle.promptDay);
      if (!cycle.reminderSent) due.add(cycle.reminderDay);
      due.add(cycle.deadline); // auto-close availability
    } else if (!cycle.allocated) {
      due.add(cycle.allocationDay);
    }

    DateTime? next;
    for (final d in due) {
      if (d.isAfter(now) && (next == null || d.isBefore(next))) next = d;
    }
    if (next == null) return;
    _milestone = Timer(next.difference(now), () => _tick());
  }
}
