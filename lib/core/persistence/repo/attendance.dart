part of '../../repo.dart';

extension RepoAttendance on Repo {

  /// Per-weekend allocation flags (in settings) so a weekend is allocated
  /// exactly once even if the scheduler ticks repeatedly.
  bool weekendAllocated(DateTime sat) =>
      getSetting('alloc_${this._dayKey(sat)}') == '1';

  void markWeekendAllocated(DateTime sat) =>
      setSetting('alloc_${this._dayKey(sat)}', '1');

  /// Clears the allocated flag so the dynamic allocator may run again (used
  /// when the schedule changes for an open weekend).
  void setWeekendAllocated(DateTime sat, bool value) =>
      setSetting('alloc_${this._dayKey(sat)}', value ? '1' : '0');

  // -------------------------------------------------------------- attendance

  /// Sets an explicit mark: `attended = true` for present, `false` for not
  /// participated. Recoverable: [clearAttendance] removes the mark.
  void setAttendanceState(int userId, int sessionId, {required bool attended}) {
    raw.execute(
      '''
INSERT INTO attendance (user_id, session_id, attended)
VALUES (?, ?, ?)
ON CONFLICT(user_id, session_id) DO UPDATE SET
  attended = excluded.attended,
  confirmed_at = CURRENT_TIMESTAMP
''',
      [userId, sessionId, attended ? 1 : 0],
    );
  }

  void clearAttendance(int userId, int sessionId) {
    raw.execute(
      'DELETE FROM attendance WHERE user_id = ? AND session_id = ?',
      [userId, sessionId],
    );
  }

  /// The leader of [groupId] (the admin owning that group), or null.
  User? groupAdmin(String groupId) {
    if (groupId.isEmpty) return null;
    final rows = raw.select(
      'SELECT * FROM users WHERE group_id = ? AND '
      '(is_admin = 1 OR is_global_admin = 1) LIMIT 1',
      [groupId],
    );
    return rows.isEmpty ? null : User.fromRow(rows.first);
  }

  bool hasAttendedInPastDays(int userId, int days) {
    // attendance.confirmed_at is stored as UTC (SQLite CURRENT_TIMESTAMP),
    // so compare against a UTC cutoff. Using the config clock keeps this
    // consistent with /setdate debugging. Only positive marks count.
    final since = Config.nowUtc()
        .subtract(Duration(days: days))
        .toIso8601String();
    final rows = raw.select(
      '''
SELECT COUNT(*) AS c FROM attendance
WHERE user_id = ? AND attended = 1 AND confirmed_at >= ?
''',
      [userId, since],
    );
    return (rows.first['c'] as int) > 0;
  }

  DateTime? lastAttendedWeekend(int userId) {
    final rows = raw.select(
      '''
SELECT MAX(s.weekend_start) AS last_attended
FROM attendance a
JOIN sessions s ON s.id = a.session_id
WHERE a.user_id = ? AND a.attended = 1
''',
      [userId],
    );
    final value = rows.first['last_attended'] as String?;
    return value == null ? null : DateTime.parse(value);
  }

  /// The number of consecutive session weekends up to [latestSat] in which
  /// [userId] had no positive attendance, counting backward from [latestSat].
  /// An attended weekend resets the streak; holiday weeks neither count nor
  /// reset; weekends before the member registered do not count.
  int consecutiveAbsentWeeks(int userId, DateTime latestSat) {
    final weekends = raw
        .select(
          'SELECT DISTINCT weekend_start FROM sessions '
          'WHERE weekend_start <= ? ORDER BY weekend_start DESC',
          [this._dayKey(latestSat)],
        )
        .map((r) => DateTime.parse(r['weekend_start'] as String))
        .toList();
    if (weekends.isEmpty) return 0;

    final attended = raw
        .select(
          'SELECT DISTINCT s.weekend_start FROM attendance a '
          'JOIN sessions s ON s.id = a.session_id '
          'WHERE a.user_id = ? AND a.attended = 1',
          [userId],
        )
        .map((r) => DateTime.parse(r['weekend_start'] as String))
        .toSet();

    final registeredAt = findUser(userId)?.registeredAt;

    var streak = 0;
    for (final sat in weekends) {
      // A week the member had no chance to attend (before they joined).
      if (registeredAt != null && !sat.isAfter(registeredAt)) break;
      // Attended → the streak ends here.
      if (attended.contains(sat)) break;
      // Holiday weeks neither count nor reset the streak.
      if (holidayOn(sat) != null) continue;
      streak++;
    }
    return streak;
  }

  List<Attendance> attendanceForSession(int sessionId) {
    final rows = raw.select(
      'SELECT * FROM attendance WHERE session_id = ?',
      [sessionId],
    );
    return rows
        .map((r) => Attendance(
              userId: r['user_id'] as int,
              sessionId: sessionId,
              attended: (r['attended'] as int) == 1,
              confirmedAt: DateTime.parse(r['confirmed_at'] as String),
            ))
        .toList();
  }

  // ---------------------------------------------------------------- holidays

  void addHoliday(DateTime weekMonday, HolidayKind kind) {
    raw.execute(
      'INSERT OR REPLACE INTO holidays (week_start, kind) VALUES (?, ?)',
      [this._fmt(weekMonday), kind.name],
    );
  }

  void removeHoliday(DateTime weekMonday) {
    raw.execute('DELETE FROM holidays WHERE week_start = ?', [this._fmt(weekMonday)]);
  }

  List<Holiday> allHolidays() =>
      raw.select('SELECT * FROM holidays ORDER BY week_start')
          .map(Holiday.fromRow)
          .toList();

  /// Returns the contiguous holiday period containing [target].
  List<Holiday> holidayPeriod(Holiday target) {
    final sameKind = allHolidays()
        .where((holiday) => holiday.kind == target.kind)
        .toList()
      ..sort((a, b) => a.weekStart.compareTo(b.weekStart));
    final index = sameKind.indexWhere(
      (holiday) => holiday.weekStart == target.weekStart,
    );
    if (index < 0) return [target];
    var first = index;
    var last = index;
    while (first > 0 &&
        sameKind[first].weekStart.difference(sameKind[first - 1].weekStart) ==
            const Duration(days: 7)) {
      first--;
    }
    while (last + 1 < sameKind.length &&
        sameKind[last + 1].weekStart.difference(sameKind[last].weekStart) ==
            const Duration(days: 7)) {
      last++;
    }
    return sameKind.sublist(first, last + 1);
  }

  /// Returns the holiday covering the given date, if any.
  Holiday? holidayOn(DateTime date) {
    final monday = WeekMath.mondayOf(date);
    final rows = raw.select(
      'SELECT * FROM holidays WHERE week_start = ?',
      [this._fmt(monday)],
    );
    return rows.isEmpty ? null : Holiday.fromRow(rows.first);
  }

  // -------------------------------------------------------- holiday optouts

  /// Marks [user] as "don't bother me this holiday" for the week starting
  /// [weekMonday].
  void setHolidayOptout(int userId, DateTime weekMonday) {
    raw.execute(
      'INSERT OR REPLACE INTO holiday_optouts (user_id, week_start) '
      'VALUES (?, ?)',
      [userId, this._fmt(weekMonday)],
    );
  }

  bool hasHolidayOptout(int userId, DateTime weekMonday) {
    final rows = raw.select(
      'SELECT 1 FROM holiday_optouts WHERE user_id = ? AND week_start = ?',
      [userId, this._fmt(weekMonday)],
    );
    return rows.isNotEmpty;
  }

  // ------------------------------------------------------------- attendance

  /// Total positive attendance of [userId], split by location key.
  ({int total, Map<String, int> byLocation}) attendanceStats(int userId) {
    final rows = raw.select(
      '''
SELECT COUNT(*) AS n, s.location AS location
FROM attendance a
JOIN sessions s ON s.id = a.session_id
WHERE a.user_id = ? AND a.attended = 1
GROUP BY s.location
''',
      [userId],
    );
    var total = 0;
    final byLocation = <String, int>{};
    for (final r in rows) {
      final n = (r['n'] as int?) ?? 0;
      total += n;
      byLocation[r['location'] as String] = n;
    }
    return (total: total, byLocation: byLocation);
  }

  // ------------------------------------------------------------ calendar

  /// Stores the raw calendar YAML for [academicYear]. The parsed weeks drive
  /// the derived holidays below; the YAML is kept so a re-sync is idempotent.
  void saveCalendarYaml(String academicYear, String yaml) {
    raw.execute(
      '''
INSERT INTO calendar_years (academic_year, yaml, updated_at)
VALUES (?, ?, ?)
ON CONFLICT(academic_year) DO UPDATE SET
  yaml = excluded.yaml,
  updated_at = excluded.updated_at
''',
      [academicYear, yaml, this._fmt(Config.nowUtc())],
    );
  }

  /// Deletes all holiday rows derived from calendars (week_start >= [from]).
  void clearDerivedHolidays(DateTime from) {
    raw.execute('DELETE FROM holidays WHERE week_start >= ?', [this._fmt(from)]);
  }

  /// The most recently synced calendar year, parsed; null when none is stored
  /// or the stored YAML fails to parse.
  CalendarYear? latestCalendarYear() {
    final rows = raw.select(
      'SELECT yaml FROM calendar_years ORDER BY updated_at DESC LIMIT 1',
    );
    if (rows.isEmpty) return null;
    try {
      return CalendarYear.fromYaml(rows.first['yaml'] as String);
    } catch (_) {
      return null;
    }
  }

}
