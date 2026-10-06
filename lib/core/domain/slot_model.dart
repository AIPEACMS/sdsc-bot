part of '../models.dart';

class LocalWallClock {
  final int hour;
  final int minute;

  const LocalWallClock(this.hour, this.minute);

  factory LocalWallClock.parse(String value) {
    final match = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(value);
    if (match == null) throw FormatException('expected HH:MM');
    final hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    if (hour > 23 || minute > 59) {
      throw FormatException('time is outside 00:00-23:59');
    }
    return LocalWallClock(hour, minute);
  }

  String get value =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  DateTime on(DateTime day) =>
      DateTime(day.year, day.month, day.day, hour, minute);

  int compareTo(LocalWallClock other) => hour != other.hour
      ? hour.compareTo(other.hour)
      : minute.compareTo(other.minute);

  @override
  bool operator ==(Object other) =>
      other is LocalWallClock && hour == other.hour && minute == other.minute;

  @override
  int get hashCode => Object.hash(hour, minute);
}

/// Canonical weekdays accepted for schedule milestones.
const scheduleWeekdays = ['mon', 'tue', 'wed', 'thu', 'fri'];

int? scheduleWeekdayNumber(String weekday) {
  final index = scheduleWeekdays.indexOf(weekday);
  return index < 0 ? null : index + DateTime.monday;
}

/// A persisted schedule milestone: a canonical weekday and a local wall-clock
/// time. Milestones intentionally cannot be placed on Saturday or Sunday.
