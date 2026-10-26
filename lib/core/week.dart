/// ISO week calculations and cycle timeline helpers.
///
/// A "cycle" is a 2-week block whose first session weekend falls on an odd ISO
/// week (`blockWeek`). Prompt, reminder, lock, and checker events are scheduled
/// from [ScheduleTimes]. Session weeks remain anchored on Saturday.
class WeekMath {
  /// ISO-8601 week number (1..53) for [date].
  static int isoWeek(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    final weekday = d.weekday; // 1=Mon..7=Sun
    final dayOfYear = _dayOfYear(d);
    var week = ((dayOfYear - weekday + 10) ~/ 7);
    if (week == 0) {
      // Belongs to last week of previous ISO year.
      return isoWeeksInYear(DateTime(d.year - 1, 12, 28));
    }
    if (week > isoWeeksInYear(d)) {
      // Belongs to week 1 of next ISO year.
      return 1;
    }
    return week;
  }

  /// ISO-8601 week-numbering year for [date].
  static int isoYear(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    final weekday = d.weekday;
    final dayOfYear = _dayOfYear(d);
    var week = ((dayOfYear - weekday + 10) ~/ 7);
    if (week == 0) return d.year - 1;
    if (week > isoWeeksInYear(d)) return d.year + 1;
    return d.year;
  }

  /// Number of ISO weeks in the ISO year of [date]: 53 iff Jan 1 is a
  /// Thursday, or Jan 1 is a Wednesday in a leap year.
  static int isoWeeksInYear(DateTime date) {
    final jan1 = DateTime(date.year, 1, 1);
    final isLeap = DateTime(date.year, 2, 29).day == 29;
    if (jan1.weekday == DateTime.thursday) return 53;
    if (jan1.weekday == DateTime.wednesday && isLeap) return 53;
    return 52;
  }

  static int _dayOfYear(DateTime date) {
    final start = DateTime(date.year, 1, 1);
    return date.difference(start).inDays + 1;
  }

  static bool isOddWeek(DateTime date) => isoWeek(date).isOdd;

  /// Monday of the week containing [date] (at 00:00 local).
  static DateTime mondayOf(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    return d.subtract(Duration(days: d.weekday - 1));
  }

  static DateTime atTime(DateTime day, int hour, [int minute = 0]) =>
      DateTime(day.year, day.month, day.day, hour, minute);

  /// ISO week/year of the Monday [date]. Mirrors [isoWeek]/[isoYear] but for
  /// an explicit Monday reference.
  static (int, int) isoWeekYearOfMonday(DateTime monday) {
    return (isoWeek(monday), isoYear(monday));
  }

  /// Returns the Monday of the ISO week [week] in [year].
  static DateTime mondayOfWeek(int week, int year) {
    final jan4 = DateTime(year, 1, 4);
    final mondayJan4 = mondayOf(jan4);
    // Week 1 starts on the Monday on/before Jan 4.
    return mondayJan4.add(Duration(days: (week - 1) * 7));
  }

  /// The weekend (Sat) of the given ISO week.
  static DateTime saturdayOfWeek(int week, int year) {
    return mondayOfWeek(week, year).add(const Duration(days: 5));
  }
}

/// Returns the Saturday anchor for the most recently completed Sat-Fri block
/// before [eventLocalDate].
DateTime latestCompletedSessionBlockStart(DateTime eventLocalDate) {
  final date = DateTime(
    eventLocalDate.year,
    eventLocalDate.month,
    eventLocalDate.day,
  );
  final daysSinceSaturday = (date.weekday - DateTime.saturday + 7) % 7;
  final mostRecentSaturday = date.subtract(Duration(days: daysSinceSaturday));
  return mostRecentSaturday.subtract(const Duration(days: 7));
}

/// Formats a local schedule event for user-facing deadline copy.
String formatLocalScheduleDateTime(DateTime dateTime) {
  const weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final hour = dateTime.hour % 12 == 0 ? 12 : dateTime.hour % 12;
  final minute = dateTime.minute.toString().padLeft(2, '0');
  final period = dateTime.hour < 12 ? 'AM' : 'PM';
  return '${weekdays[dateTime.weekday - 1]} ${dateTime.day} '
      '${months[dateTime.month - 1]} at $hour:$minute $period';
}
