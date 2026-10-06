part of '../models.dart';

class ScheduleEvent {
  final String weekday;
  final LocalWallClock time;

  const ScheduleEvent({required this.weekday, required this.time});

  /// Historical convenience accessor for clients that only display the time.
  String get value => time.value;

  DateTime on(DateTime monday) {
    final day = scheduleWeekdayNumber(weekday);
    if (day == null) {
      throw ArgumentError('unknown schedule weekday "$weekday"');
    }
    return time.on(monday.add(Duration(days: day - DateTime.monday)));
  }

  int compareTo(ScheduleEvent other) {
    final thisDay = scheduleWeekdayNumber(weekday);
    final otherDay = scheduleWeekdayNumber(other.weekday);
    if (thisDay == null || otherDay == null) {
      throw ArgumentError('schedule weekdays must be mon, tue, wed, thu or fri');
    }
    final dayComparison = thisDay.compareTo(otherDay);
    return dayComparison == 0 ? time.compareTo(other.time) : dayComparison;
  }

  @override
  bool operator ==(Object other) =>
      other is ScheduleEvent && weekday == other.weekday && time == other.time;

  @override
  int get hashCode => Object.hash(weekday, time);
}

/// The four persisted weekday + local wall-clock events that drive the rolling
/// schedule. The time settings retain their historical keys for old databases.
