import 'dart:convert';

import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'calendar.dart';
import 'config.dart';
import 'db.dart';
import 'models.dart';
import 'week.dart';

/// Data access layer over SQLite. All dates are stored as ISO-8601 strings in
/// the bot's local timezone (UTC+8).
class Repo {
  Repo(this._db);

  final Database _db;

  sqlite.Database get raw => _db.raw;

  // ---------------------------------------------------------------- users

  int? getUser(int id) {
    final rows = raw.select(
      'SELECT * FROM users WHERE id = ?',
      [id],
    );
    return rows.isEmpty ? null : User.fromRow(rows.first).id;
  }

  User? findUser(int id) {
    final rows = raw.select(
      'SELECT * FROM users WHERE id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    return User.fromRow(rows.first);
  }

  List<User> allUsers() =>
      raw.select('SELECT * FROM users ORDER BY name').map(User.fromRow).toList();

  User upsertUser(User user) {
    raw.execute(
      '''
INSERT INTO users (id, name, experience, group_id, is_admin, ocbc_streak)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  name = excluded.name,
  experience = excluded.experience,
  group_id = excluded.group_id,
  is_admin = excluded.is_admin,
  ocbc_streak = excluded.ocbc_streak
''',
      [
        user.id,
        user.name,
        user.experience.name,
        user.group,
        user.isAdmin ? 1 : 0,
        user.ocbcStreak,
      ],
    );
    return findUser(user.id)!;
  }

  void updateExperience(int id, Experience experience) {
    raw.execute(
      'UPDATE users SET experience = ? WHERE id = ?',
      [experience.name, id],
    );
  }

  void updateGroup(int id, String group) {
    raw.execute(
      'UPDATE users SET group_id = ? WHERE id = ?',
      [group, id],
    );
  }

  void updateName(int id, String name) {
    raw.execute('UPDATE users SET name = ? WHERE id = ?', [name, id]);
  }

  void setOcbcStreak(int id, int streak) {
    raw.execute(
      'UPDATE users SET ocbc_streak = ? WHERE id = ?',
      [streak, id],
    );
  }

  void updateAdmin(int id, bool isAdmin) {
    raw.execute(
      'UPDATE users SET is_admin = ? WHERE id = ?',
      [isAdmin ? 1 : 0, id],
    );
  }

  // ----------------------------------------------------------- seen users

  /// Records a (telegram id, username) pair observed in an incoming update.
  /// This is the only way the bot learns a user's handle, because the
  /// Telegram API cannot resolve @handle to an id on its own.
  void upsertSeenUser(int id, String username) {
    raw.execute(
      '''
INSERT INTO seen_users (id, username) VALUES (?, ?)
ON CONFLICT(id) DO UPDATE SET username = excluded.username
''',
      [id, username],
    );
  }

  /// Resolves a @handle (with or without the leading @) to a telegram id,
  /// or null if the bot has never seen that username.
  int? userIdByUsername(String handle) {
    final normalized = handle.replaceFirst('@', '').toLowerCase();
    final rows = raw.select(
      'SELECT id FROM seen_users WHERE lower(username) = ?',
      [normalized],
    );
    return rows.isEmpty ? null : rows.first['id'] as int;
  }

  /// Users the bot has seen in messages but who are not registered yet —
  /// the candidates for the /adduser and /addadmin pickers.
  List<User> unregisteredSeen() {
    final rows = raw.select(
      '''
SELECT s.id, s.username
FROM seen_users s
LEFT JOIN users u ON u.id = s.id
WHERE u.id IS NULL
ORDER BY s.username
''',
    );
    return [
      for (final r in rows)
        User(
          id: r['id'] as int,
          name: '@${r['username']}',
          experience: Experience.newbie,
          group: 'A',
        ),
    ];
  }

  /// The username the bot saw for [id], or null if never seen.
  String? seenUsername(int id) {
    final rows = raw.select(
      'SELECT username FROM seen_users WHERE id = ?',
      [id],
    );
    return rows.isEmpty ? null : rows.first['username'] as String;
  }

  // -------------------------------------------------------- pending users

  /// A handle added by an admin before the user has ever messaged the bot.
  /// The user is auto-registered (with admin rights if [isAdmin]) the first
  /// time they contact the bot.
  void addPendingUser(String handle, {required bool isAdmin}) {
    raw.execute(
      '''
INSERT INTO pending_users (username, is_admin) VALUES (?, ?)
ON CONFLICT(username) DO UPDATE SET
  is_admin = MAX(pending_users.is_admin, excluded.is_admin)
''',
      [handle.replaceFirst('@', '').toLowerCase(), isAdmin ? 1 : 0],
    );
  }

  bool isPendingUser(String handle) {
    final rows = raw.select(
      'SELECT 1 FROM pending_users WHERE username = ?',
      [handle.replaceFirst('@', '').toLowerCase()],
    );
    return rows.isNotEmpty;
  }

  bool pendingIsAdmin(String handle) {
    final rows = raw.select(
      'SELECT is_admin FROM pending_users WHERE username = ?',
      [handle.replaceFirst('@', '').toLowerCase()],
    );
    return rows.isNotEmpty && (rows.first['is_admin'] as int) == 1;
  }

  void removePendingUser(String handle) {
    raw.execute(
      'DELETE FROM pending_users WHERE username = ?',
      [handle.replaceFirst('@', '').toLowerCase()],
    );
  }

  // --------------------------------------------------------- message log

  /// Whether [kind] of message was already sent to [user] on the local date
  /// of [day]. Used to never send the same message to the same user twice in
  /// one day.
  bool messageSentOnDay(int userId, String kind, DateTime day) {
    final rows = raw.select(
      'SELECT COUNT(*) AS c FROM sent_messages '
      'WHERE user_id = ? AND kind = ? AND day = ?',
      [userId, kind, _dayKey(day)],
    );
    return (rows.first['c'] as int) > 0;
  }

  void markMessageSent(int userId, String kind, DateTime day) {
    raw.execute(
      'INSERT OR IGNORE INTO sent_messages (user_id, kind, day) '
      'VALUES (?, ?, ?)',
      [userId, kind, _dayKey(day)],
    );
  }

  // ---------------------------------------------------------------- cycles

  Cycle? cycleByBlock(int year, int week) {
    final rows = raw.select(
      'SELECT * FROM cycles WHERE block_year = ? AND block_week = ?',
      [year, week],
    );
    return rows.isEmpty ? null : Cycle.fromRow(rows.first);
  }

  Cycle? cycleById(int id) {
    final rows = raw.select('SELECT * FROM cycles WHERE id = ?', [id]);
    return rows.isEmpty ? null : Cycle.fromRow(rows.first);
  }

  List<Cycle> allCycles() =>
      raw.select('SELECT * FROM cycles ORDER BY block_year, block_week')
          .map(Cycle.fromRow)
          .toList();

  /// Creates the cycle for the given first-session block week (odd ISO week),
  /// or returns the existing one.
  Cycle ensureCycle(int blockWeek, int blockYear) {
    final existing = cycleByBlock(blockYear, blockWeek);
    if (existing != null) return existing;

    final promptMonday = WeekMath.mondayOfWeek(blockWeek - 1, blockYear);
    final reminder = promptMonday.add(const Duration(days: 3));
    final deadline = promptMonday.add(const Duration(days: 4));
    final allocDay = WeekMath.mondayOfWeek(blockWeek, blockYear)
        .add(const Duration(days: 2));

    raw.execute(
      '''
INSERT INTO cycles (block_year, block_week, prompt_day, reminder_day,
                    deadline, allocation_day)
VALUES (?, ?, ?, ?, ?, ?)
''',
      [
        blockYear,
        blockWeek,
        _fmt(promptMonday),
        _fmt(reminder),
        _fmt(deadline),
        _fmt(allocDay),
      ],
    );
    return cycleByBlock(blockYear, blockWeek)!;
  }

  /// The current cycle: the smallest odd block week whose prompt week is the
  /// latest even week at or before `today`.
  Cycle ensureCurrentCycle(DateTime today) {
    final week = WeekMath.isoWeek(today);
    final year = WeekMath.isoYear(today);
    var blockWeek = week;
    if (week.isEven) blockWeek = week + 1;

    final cycle = ensureCycle(blockWeek, year);

    // Auto-close availability once the deadline passes.
    if (cycle.status == CycleStatus.open &&
        !today.isBefore(cycle.deadline)) {
      _db.raw.execute('UPDATE cycles SET status = ? WHERE id = ?',
          [CycleStatus.closed.name, cycle.id]);
      return cycleById(cycle.id)!;
    }
    return cycle;
  }

  void markPromptSent(int id) {
    raw.execute('UPDATE cycles SET prompt_sent = 1 WHERE id = ?', [id]);
  }

  void markReminderSent(int id) {
    raw.execute('UPDATE cycles SET reminder_sent = 1 WHERE id = ?', [id]);
  }

  void markAllocated(int id) {
    raw.execute(
      'UPDATE cycles SET allocated = 1, status = ? WHERE id = ?',
      [CycleStatus.allocated.name, id],
    );
  }

  // --------------------------------------------------------------- sessions

  /// Creates the 8 sessions (2 weekends x sat/sun x am/pm x 2 locations) for a
  /// cycle, using the given slot time windows. Idempotent.
  void ensureSessionsForCycle(
    Cycle cycle,
    Map<String, (String, String)> slotTimes, {
    required int tzOffsetHours,
  }) {
    const days = ['sat', 'sun'];
    const slots = ['am', 'pm'];
    const locations = [Location.ocbc, Location.pasirRis];

    for (var wi = 0; wi < 2; wi++) {
      final week = cycle.blockWeek + wi;
      final sat = WeekMath.saturdayOfWeek(week, cycle.blockYear);
      for (final day in days) {
        final dayDate = sat.add(Duration(days: day == 'sun' ? 1 : 0));
        for (final slot in slots) {
          final (startT, endT) = slotTimes[slot]!;
          final start = _parseTime(dayDate, startT);
          final end = _parseTime(dayDate, endT);
          for (final loc in locations) {
            raw.execute(
              '''
INSERT OR IGNORE INTO sessions
  (cycle_id, weekend_index, day, slot, location, start_at, end_at)
VALUES (?, ?, ?, ?, ?, ?, ?)
''',
              [
                cycle.id,
                wi,
                day,
                slot,
                loc.name,
                _fmt(start),
                _fmt(end),
              ],
            );
          }
        }
      }
    }
  }

  List<Session> sessionsForCycle(int cycleId) =>
      raw.select('SELECT * FROM sessions WHERE cycle_id = ?', [cycleId])
          .map(Session.fromRow)
          .toList();

  Session? sessionById(int id) {
    final rows = raw.select('SELECT * FROM sessions WHERE id = ?', [id]);
    return rows.isEmpty ? null : Session.fromRow(rows.first);
  }

  List<Session> sessionsForSlot(int cycleId, String slotKey) {
    final parts = slotKey.split(':');
    final rows = raw.select(
      'SELECT * FROM sessions WHERE cycle_id = ? AND weekend_index = ? '
      'AND day = ? AND slot = ? ORDER BY location',
      [cycleId, int.parse(parts[0]), parts[1], parts[2]],
    );
    return rows.map(Session.fromRow).toList();
  }

  // ----------------------------------------------------------- availability

  void setAvailability(Availability a) {
    raw.execute(
      '''
INSERT INTO availability (cycle_id, user_id, slots, available, updated_at)
VALUES (?, ?, ?, ?, ?)
ON CONFLICT(cycle_id, user_id) DO UPDATE SET
  slots = excluded.slots,
  available = excluded.available,
  updated_at = excluded.updated_at
''',
      [
        a.cycleId,
        a.userId,
        jsonEncode(a.slots.map((s) => s.encode()).toList()),
        a.available ? 1 : 0,
        _fmt(a.updatedAt),
      ],
    );
  }

  Availability? getAvailability(int cycleId, int userId) {
    final rows = raw.select(
      'SELECT * FROM availability WHERE cycle_id = ? AND user_id = ?',
      [cycleId, userId],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return Availability(
      cycleId: cycleId,
      userId: userId,
      slots: Slot.decodeSet(r['slots'] as String),
      available: (r['available'] as int) == 1,
      updatedAt: DateTime.parse(r['updated_at'] as String),
    );
  }

  List<Availability> allAvailability(int cycleId) {
    final rows =
        raw.select('SELECT * FROM availability WHERE cycle_id = ?', [cycleId]);
    return rows
        .map((r) => Availability(
              cycleId: cycleId,
              userId: r['user_id'] as int,
              slots: Slot.decodeSet(r['slots'] as String),
              available: (r['available'] as int) == 1,
              updatedAt: DateTime.parse(r['updated_at'] as String),
            ))
        .toList();
  }

  List<User> nonResponders(int cycleId) {
    final rows = raw.select(
      '''
SELECT u.* FROM users u
LEFT JOIN availability a ON a.user_id = u.id AND a.cycle_id = ?
WHERE a.user_id IS NULL
ORDER BY u.name
''',
      [cycleId],
    );
    return rows.map(User.fromRow).toList();
  }

  // ------------------------------------------------------------- allocations

  void replaceAllocations(int cycleId, List<(int, int)> allocations) {
    final tx = raw;
    tx.execute('BEGIN IMMEDIATE');
    try {
      tx.execute('DELETE FROM allocations WHERE cycle_id = ?', [cycleId]);
      final stmt = tx.prepare(
        'INSERT INTO allocations (cycle_id, user_id, session_id) '
        'VALUES (?, ?, ?)',
      );
      for (final (userId, sessionId) in allocations) {
        stmt.execute([cycleId, userId, sessionId]);
      }
      stmt.close();
      tx.execute('COMMIT');
    } catch (_) {
      tx.execute('ROLLBACK');
      rethrow;
    }
  }

  List<(User, Session)> allocationsForCycle(int cycleId) {
    final rows = raw.select(
      '''
SELECT u.*,
       s.id           AS session_id,
       s.cycle_id     AS session_cycle_id,
       s.weekend_index AS session_weekend_index,
       s.day          AS session_day,
       s.slot         AS session_slot,
       s.location     AS session_location,
       s.start_at     AS session_start_at,
       s.end_at       AS session_end_at
FROM allocations al
JOIN users u ON u.id = al.user_id
JOIN sessions s ON s.id = al.session_id
WHERE al.cycle_id = ?
ORDER BY s.start_at, u.name
''',
      [cycleId],
    );
    return rows.map((r) {
      final user = User.fromRow(r);
      final session = Session(
        id: r['session_id'] as int,
        cycleId: r['session_cycle_id'] as int,
        weekendIndex: r['session_weekend_index'] as int,
        day: r['session_day'] as String,
        slot: r['session_slot'] as String,
        location: (r['session_location'] as String) == 'ocbc'
            ? Location.ocbc
            : Location.pasirRis,
        start: DateTime.parse(r['session_start_at'] as String),
        end: DateTime.parse(r['session_end_at'] as String),
      );
      return (user, session);
    }).toList();
  }

  // -------------------------------------------------------------- attendance

  void confirmAttendance(int userId, int sessionId) {
    raw.execute(
      '''
INSERT INTO attendance (user_id, session_id)
VALUES (?, ?) ON CONFLICT DO NOTHING
''',
      [userId, sessionId],
    );
  }

  bool hasAttendedInPastDays(int userId, int days) {
    // attendance.confirmed_at is stored as UTC (SQLite CURRENT_TIMESTAMP),
    // so compare against a UTC cutoff. Using the config clock keeps this
    // consistent with /setdate debugging.
    final since = Config.nowUtc()
        .subtract(Duration(days: days))
        .toIso8601String();
    final rows = raw.select(
      '''
SELECT COUNT(*) AS c FROM attendance
WHERE user_id = ? AND confirmed_at >= ?
''',
      [userId, since],
    );
    return (rows.first['c'] as int) > 0;
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
              confirmedAt: DateTime.parse(r['confirmed_at'] as String),
            ))
        .toList();
  }

  // ---------------------------------------------------------------- holidays

  void addHoliday(DateTime weekMonday, HolidayKind kind) {
    raw.execute(
      'INSERT OR REPLACE INTO holidays (week_start, kind) VALUES (?, ?)',
      [_fmt(weekMonday), kind.name],
    );
  }

  void removeHoliday(DateTime weekMonday) {
    raw.execute('DELETE FROM holidays WHERE week_start = ?', [_fmt(weekMonday)]);
  }

  List<Holiday> allHolidays() =>
      raw.select('SELECT * FROM holidays ORDER BY week_start')
          .map(Holiday.fromRow)
          .toList();

  /// Returns the holiday covering the given date, if any.
  Holiday? holidayOn(DateTime date) {
    final monday = WeekMath.mondayOf(date);
    final rows = raw.select(
      'SELECT * FROM holidays WHERE week_start = ?',
      [_fmt(monday)],
    );
    return rows.isEmpty ? null : Holiday.fromRow(rows.first);
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
      [academicYear, yaml, _fmt(Config.nowUtc())],
    );
  }

  /// Deletes all holiday rows derived from calendars (week_start >= [from]).
  void clearDerivedHolidays(DateTime from) {
    raw.execute('DELETE FROM holidays WHERE week_start >= ?', [_fmt(from)]);
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

  /// Maps calendar week types to bot holiday kinds.
  ///
  /// - recess weeks → `middle` break (msg5A)
  /// - the gap between semester 1 and 2 → `winter` break (msg5B winter)
  /// - weeks after the last semester (special term / summer) → `summer`
  static HolidayKind? kindForWeek(CalendarWeek w, CalendarYear year) {
    if (w.type == 'recess') return HolidayKind.middle;
    final s1 = year.semester('semester_1');
    final s2 = year.semester('semester_2');
    // Winter: the block between S1's last week and S2's first week.
    if (s1 != null && s2 != null) {
      final s1End = s1.lastEnd;
      final s2Start = s2.firstStart;
      if (s1End != null && s2Start != null && w.start.isAfter(s1End) &&
          w.start.isBefore(s2Start)) {
        return HolidayKind.winter;
      }
    }
    // Summer: after the last semester's final week.
    final lastSemEnd =
        s2?.lastEnd ?? s1?.lastEnd;
    if (lastSemEnd != null && w.start.isAfter(lastSemEnd)) {
      return HolidayKind.summer;
    }
    return null;
  }

  static String _fmt(DateTime d) =>
      DateTime(d.year, d.month, d.day, d.hour, d.minute).toIso8601String();

  static String _dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static DateTime _parseTime(DateTime day, String hhmm) {
    final parts = hhmm.split(':');
    return DateTime(
      day.year,
      day.month,
      day.day,
      int.parse(parts[0]),
      int.parse(parts[1]),
    );
  }
}
