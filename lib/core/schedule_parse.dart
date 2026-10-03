/// Parsing for `/settime` schedule lines. Tolerant of many spellings: day
/// names and abbreviations (any case), 24-hour or 12-hour times, and location
/// tokens (resolved separately against the locations table, aliases included).
library;

import 'models.dart';

/// One parsed schedule line. [locationToken] is still the raw text — the
/// caller resolves it to a location key.
class ParsedSession {
  final String day; // canonical: 'sat' | 'sun' | 'mon' | ...
  final String start; // 'HH:MM'
  final String end; // 'HH:MM'
  final String locationToken;
  final DateTime? targetDate;

  const ParsedSession({
    required this.day,
    required this.start,
    required this.end,
    required this.locationToken,
    this.targetDate,
  });
}

/// Accepted day spellings → canonical weekday token.
const Map<String, String> dayAliases = {
  'sat': 'sat',
  'saturday': 'sat',
  'sun': 'sun',
  'sunday': 'sun',
  'mon': 'mon',
  'monday': 'mon',
  'tue': 'tue',
  'tues': 'tue',
  'tuesday': 'tue',
  'wed': 'wed',
  'weds': 'wed',
  'wednesday': 'wed',
  'thu': 'thu',
  'thur': 'thu',
  'thurs': 'thu',
  'thursday': 'thu',
  'fri': 'fri',
  'friday': 'fri',
};

/// Parses one line. Returns a [ParsedSession] on success, or a human error
/// message on failure.
Object parseSessionLine(String line) {
  final parts = line.trim().split(RegExp(r'\s+'));
  if (parts.length < 4) {
    return 'expected "day startTime endTime location"';
  }
  final day = dayAliases[parts[0].toLowerCase()];
  if (day == null) return 'unknown day "${parts[0]}"';
  final start = parseClock(parts[1]);
  if (start == null) return 'unknown time "${parts[1]}"';
  final end = parseClock(parts[2]);
  if (end == null) return 'unknown time "${parts[2]}"';
  if (_minutes(start) >= _minutes(end)) {
    return 'the end time must be after the start time';
  }
  return ParsedSession(
    day: day,
    start: start,
    end: end,
    locationToken: parts.sublist(3).join(' '),
  );
}

/// Parses a temporary-change line. A plain weekday resolves to its next
/// occurrence after [now]. An explicit line uses `day as YYYY-MM-DD` and the
/// date must actually fall on that weekday.
Object parseTargetSessionLine(String line, DateTime now) {
  final parts = line.trim().split(RegExp(r'\s+'));
  if (parts.length >= 6 && parts[1].toLowerCase() == 'as') {
    final day = dayAliases[parts[0].toLowerCase()];
    if (day == null) return 'unknown day "${parts[0]}"';
    final date = DateTime.tryParse(parts[2]);
    if (date == null) return 'unknown date "${parts[2]}"';
    if (_dayForDate(date) != day) {
      return '${parts[2]} is not a ${dayAliases.entries.firstWhere((e) => e.value == day).key}';
    }
    final parsed = parseSessionLine('$day ${parts.sublist(3).join(' ')}');
    if (parsed is String) return parsed;
    final session = parsed as ParsedSession;
    return ParsedSession(
      day: session.day,
      start: session.start,
      end: session.end,
      locationToken: session.locationToken,
      targetDate: DateTime(date.year, date.month, date.day),
    );
  }

  final parsed = parseSessionLine(line);
  if (parsed is String) return parsed;
  final session = parsed as ParsedSession;
  final weekday = _weekdayForDay(session.day);
  var delta = (weekday - now.weekday) % 7;
  if (delta == 0) delta = 7;
  final date = DateTime(now.year, now.month, now.day + delta);
  return ParsedSession(
    day: session.day,
    start: session.start,
    end: session.end,
    locationToken: session.locationToken,
    targetDate: date,
  );
}

/// Parses many lines (one session per line, blank lines ignored).
({List<ParsedSession> sessions, List<String> errors}) parseSchedule(
  String text,
) {
  final sessions = <ParsedSession>[];
  final errors = <String>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final parsed = parseSessionLine(line);
    if (parsed is ParsedSession) {
      sessions.add(parsed);
    } else {
      errors.add('$line — $parsed');
    }
  }
  return (sessions: sessions, errors: errors);
}

/// Builds schedule-template rows from parsed lines.
///
/// [resolveToken] maps a raw location token to a location key (or null when it
/// is unknown); lines whose token cannot be resolved are skipped. Rows sharing
/// (day, start, end) share a slot label, so availability treats them as one
/// time window.
List<ScheduleSlot> buildTemplate(
  List<ParsedSession> lines, {
  required String? Function(String token) resolveToken,
}) {
  final rows = <ScheduleSlot>[];
  final slotByGroup = <String, String>{};
  var n = 1;
  for (final line in lines) {
    final key = resolveToken(line.locationToken);
    if (key == null) continue;
    final group = '${line.day}|${line.start}|${line.end}';
    final slot = slotByGroup.putIfAbsent(group, () => 's${n++}');
    rows.add(
      ScheduleSlot(
        day: line.day,
        slot: slot,
        start: line.start,
        end: line.end,
        location: key,
      ),
    );
  }
  return rows;
}

/// Normalizes a clock token to 'HH:MM', or null when it is not a time.
///
/// Accepted: `9` (09:00), `9:30`, `09:30`, `9am`, `9 AM`, `3pm`, `13`,
/// `13:30`, `12am`, `12pm`. A bare hour 0-23 is read as 24-hour time.
String? parseClock(String raw) {
  final t = raw.trim().toLowerCase().replaceAll(' ', '');
  final m = RegExp(r'^(\d{1,2})(?::(\d{2}))?(am|pm)?$').firstMatch(t);
  if (m == null) return null;
  var h = int.parse(m.group(1)!);
  final min = m.group(2) == null ? 0 : int.parse(m.group(2)!);
  if (min > 59) return null;
  final ampm = m.group(3);
  if (ampm == 'pm' && h < 12) h += 12;
  if (ampm == 'am' && h == 12) h = 0;
  if (h > 23) return null;
  return '${h.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}';
}

/// '09:00' → '9:00' (for the human-facing confirmation).
String prettyClock(String hm) {
  final parts = hm.split(':');
  return '${int.parse(parts[0])}:${parts[1]}';
}

int _minutes(String hm) {
  final parts = hm.split(':');
  return int.parse(parts[0]) * 60 + int.parse(parts[1]);
}

int _weekdayForDay(String day) => switch (day) {
  'mon' => DateTime.monday,
  'tue' => DateTime.tuesday,
  'wed' => DateTime.wednesday,
  'thu' => DateTime.thursday,
  'fri' => DateTime.friday,
  'sat' => DateTime.saturday,
  'sun' => DateTime.sunday,
  _ => 0,
};

String _dayForDate(DateTime date) => switch (date.weekday) {
  DateTime.monday => 'mon',
  DateTime.tuesday => 'tue',
  DateTime.wednesday => 'wed',
  DateTime.thursday => 'thu',
  DateTime.friday => 'fri',
  DateTime.saturday => 'sat',
  DateTime.sunday => 'sun',
  _ => '',
};
