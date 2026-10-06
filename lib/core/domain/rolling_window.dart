part of '../models.dart';

class RollingWindow {
  final DateTime sat0;
  final DateTime sat1;
  final DateTime promptDay;
  final DateTime reminderDay;
  final DateTime lock0;
  final DateTime lock1;
  final DateTime checkerDay;

  const RollingWindow({
    required this.sat0,
    required this.sat1,
    required this.promptDay,
    required this.reminderDay,
    required this.lock0,
    required this.lock1,
    required this.checkerDay,
  });

  /// Historical names retained for callers of the rolling-window API.
  DateTime get deadline0 => lock0;
  DateTime get deadline1 => lock1;

  /// The bundle whose first weekend is [sat0].
  factory RollingWindow.fromSat0(
    DateTime sat0, {
    int promptHour = 18,
    int reminderHour = 18,
    ScheduleTimes? schedule,
  }) {
    final times = schedule ?? ScheduleTimes(
      prompt: ScheduleEvent(
        weekday: 'mon',
        time: LocalWallClock(promptHour, 0),
      ),
      reminder: ScheduleEvent(
        weekday: 'thu',
        time: LocalWallClock(reminderHour, 0),
      ),
      lock: const ScheduleEvent(
        weekday: 'fri',
        time: LocalWallClock(18, 0),
      ),
      checker: const ScheduleEvent(
        weekday: 'fri',
        time: LocalWallClock(21, 0),
      ),
    );
    final monday = sat0.subtract(const Duration(days: 5)); // Sat - 5 = Mon
    return RollingWindow(
      sat0: sat0,
      sat1: sat0.add(const Duration(days: 7)),
      promptDay: times.prompt.on(monday),
      reminderDay: times.reminder.on(monday),
      lock0: times.lock.on(monday),
      lock1: times.lock.on(monday.add(const Duration(days: 7))),
      checkerDay: times.checker.on(monday),
    );
  }

  /// The window for a local date: bundle = [current week, next week].
  factory RollingWindow.forDate(
    DateTime localNow, {
    int promptHour = 18,
    int reminderHour = 18,
    ScheduleTimes? schedule,
  }) {
    final week = WeekMath.isoWeek(localNow);
    final year = WeekMath.isoYear(localNow);
    return RollingWindow.fromSat0(
      WeekMath.saturdayOfWeek(week, year),
      promptHour: promptHour,
      reminderHour: reminderHour,
      schedule: schedule,
    );
  }

  List<DateTime> get weekends => [sat0, sat1];

  bool sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// The deadline that locks [weekendStart] (one of [sat0], [sat1]).
  DateTime deadlineFor(DateTime weekendStart) =>
      sameDay(weekendStart, sat0) ? deadline0 : deadline1;

  /// Whether [weekendStart]'s availability is already locked at [now].
  bool locked(DateTime weekendStart, DateTime now) =>
      !now.isBefore(deadlineFor(weekendStart));
}

/// A concrete session (weekend x day x slot x location) needing volunteers.
