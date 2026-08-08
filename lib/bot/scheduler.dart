import 'dart:async';

import '../core/models.dart';
import '../core/repo.dart';
import '../core/config.dart';
import '../core/week.dart';
import 'service.dart';

/// Periodically checks the calendar and fires whatever is due for the current
/// cycle. A lightweight Timer replaces a cron daemon and naturally catches up
/// when the bot restarts.
class Scheduler {
  final Repo repo;
  final Config config;
  final CycleService service;

  Timer? _timer;

  Scheduler({
    required this.repo,
    required this.config,
    required this.service,
  });

  void start({Duration interval = const Duration(minutes: 5)}) {
    unawaited(_tick());
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    try {
      final now = config.toLocal(DateTime.now().toUtc());
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
  }
}
