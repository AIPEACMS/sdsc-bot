import 'package:yaml/yaml.dart';

/// A dated week from the NTU academic calendar, e.g.
/// `week: 8, type: recess, start: 2026-09-28, end: 2026-10-04`.
class CalendarWeek {
  final int week;
  final String type; // 'teaching' | 'recess' | 'exam'
  final DateTime start; // Monday
  final DateTime end; // Sunday

  const CalendarWeek({
    required this.week,
    required this.type,
    required this.start,
    required this.end,
  });
}

/// One semester block: dated weeks plus holidays/events.
class CalendarSemester {
  final String name; // 'semester_1' | 'semester_2'
  final List<CalendarWeek> weeks;
  final List<String> publicHolidays;
  final List<String> keyEvents;

  const CalendarSemester({
    required this.name,
    required this.weeks,
    this.publicHolidays = const [],
    this.keyEvents = const [],
  });

  /// Week start (Monday) of the semester's first teaching week.
  DateTime? get firstStart => weeks.isEmpty ? null : weeks.first.start;

  /// Week end (Sunday) of the semester's last week.
  DateTime? get lastEnd => weeks.isEmpty ? null : weeks.last.end;
}

/// A parsed academic year from the NTU calendar YAML.
class CalendarYear {
  final String academicYear; // e.g. '2026-27'
  final List<CalendarSemester> semesters;

  const CalendarYear({
    required this.academicYear,
    required this.semesters,
  });

  CalendarSemester? semester(String name) {
    for (final s in semesters) {
      if (s.name == name) return s;
    }
    return null;
  }

  /// The semester containing [date], or null when the date falls outside all
  /// semesters (winter gap, summer tail, before the year starts).
  CalendarSemester? semesterAt(DateTime date) {
    for (final s in semesters) {
      for (final w in s.weeks) {
        if (!date.isBefore(w.start) && !date.isAfter(w.end)) return s;
      }
    }
    return null;
  }

  /// The (semester name, calendar week number) of the week containing [date],
  /// or null when [date] is outside all semesters.
  (String semester, int week)? weekOf(DateTime date) {
    final sem = semesterAt(date);
    if (sem == null) return null;
    for (final w in sem.weeks) {
      if (!date.isBefore(w.start) && !date.isAfter(w.end)) {
        return (sem.name, w.week);
      }
    }
    return null;
  }

  /// Parses the YAML produced by the `parse-ntu-calander` tool.
  /// Throws [FormatException] on malformed input.
  factory CalendarYear.fromYaml(String source) {
    final doc = loadYaml(_sanitize(source));
    if (doc is! YamlMap) {
      throw FormatException('calendar YAML root must be a map');
    }
    final year = doc['academic_year'];
    if (year is! String || year.isEmpty) {
      throw FormatException('missing academic_year');
    }

    final semesters = <CalendarSemester>[];
    for (final key in ['semester_1', 'semester_2']) {
      final node = doc[key];
      if (node is! YamlMap) {
        throw FormatException('missing $key');
      }
      semesters.add(_parseSemester(key, node));
    }
    return CalendarYear(academicYear: year, semesters: semesters);
  }

  /// Normalizes smart punctuation to ASCII so the (stricter) Dart yaml
  /// parser accepts output from the parse-ntu-calander tool, which emits
  /// e.g. curly apostrophes (U+2019) in event names.
  static String _sanitize(String s) {
    return s
        .replaceAll('\u2018', "'")
        .replaceAll('\u2019', "'")
        .replaceAll('\u201C', '"')
        .replaceAll('\u201D', '"')
        .replaceAll('\u2013', '-')
        .replaceAll('\u2014', '-')
        .replaceAll('\u00A0', ' ');
  }

  static CalendarSemester _parseSemester(String name, YamlMap node) {    final weeksNode = node['weeks'];
    if (weeksNode is! YamlList) {
      throw FormatException('$name: missing weeks');
    }
    final weeks = <CalendarWeek>[];
    for (final w in weeksNode) {
      if (w is! YamlMap) throw FormatException('$name: bad week entry');
      final weekNum = w['week'];
      final type = w['type'];
      final start = w['start'];
      final end = w['end'];
      if (weekNum is! int ||
          type is! String ||
          start is! String ||
          end is! String) {
        throw FormatException('$name: malformed week');
      }
      final startDate = DateTime.tryParse(start);
      final endDate = DateTime.tryParse(end);
      if (startDate == null || endDate == null) {
        throw FormatException('$name: bad week dates');
      }
      weeks.add(CalendarWeek(
        week: weekNum,
        type: type,
        start: startDate,
        end: endDate,
      ));
    }

    List<String> strings(dynamic v) =>
        v is YamlList ? v.map((e) => e.toString()).toList() : const [];

    return CalendarSemester(
      name: name,
      weeks: weeks,
      publicHolidays: strings(node['public_holidays']),
      keyEvents: strings(node['key_events']),
    );
  }
}
