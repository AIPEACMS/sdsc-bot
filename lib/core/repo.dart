import 'dart:convert';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'calendar.dart';
import 'config.dart';
import 'db.dart';
import 'models.dart';
import 'week.dart';

/// A registered Ed25519 public key that the desktop console app uses to sign
/// admin API requests. The value is the base64 of the raw 32-byte key.
class ConsoleKey {
  final String pubkey;
  final String name;
  final String createdAt;
  const ConsoleKey({
    required this.pubkey,
    required this.name,
    required this.createdAt,
  });
}

/// Data access layer over SQLite. All dates are stored as ISO-8601 strings in
/// the bot's local timezone (UTC+8).
class Repo {
  Repo(this._db);

  final Database _db;

  sqlite.Database get raw => _db.raw;

  // -------------------------------------------------------- console keys

  List<ConsoleKey> listConsoleKeys() {
    return [
      for (final row
          in raw.select('SELECT * FROM console_keys ORDER BY id'))
        ConsoleKey(
          pubkey: row['pubkey'] as String,
          name: row['name'] as String,
          createdAt: row['created_at'] as String,
        ),
    ];
  }

  bool hasConsoleKey(String pubkey) =>
      raw.select(
        'SELECT 1 FROM console_keys WHERE pubkey = ? LIMIT 1',
        [pubkey],
      ).isNotEmpty;

  void addConsoleKey(String pubkey, {String name = ''}) {
    raw.execute(
      'INSERT OR IGNORE INTO console_keys (pubkey, name) VALUES (?, ?)',
      [pubkey, name],
    );
  }

  bool removeConsoleKey(String pubkey) {
    if (!hasConsoleKey(pubkey)) return false;
    raw.execute(
      'DELETE FROM console_keys WHERE pubkey = ?',
      [pubkey],
    );
    return true;
  }

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

  /// Users who take part in availability, allocation and messaging: members,
  /// admins and the console. Excludes the `check` and `old` tiers.
  List<User> activeUsers() => raw
      .select(
        "SELECT * FROM users WHERE member_tier NOT IN ('check', 'old') "
        'ORDER BY name',
      )
      .map(User.fromRow)
      .toList();

  User upsertUser(User user) {
    raw.execute(
      '''
INSERT INTO users (id, name, experience, group_id, is_admin, ocbc_streak, member_tier, full_name, preferred_name, matric_no)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  name = excluded.name,
  experience = excluded.experience,
  group_id = excluded.group_id,
  is_admin = excluded.is_admin,
  ocbc_streak = excluded.ocbc_streak,
  member_tier = excluded.member_tier,
  full_name = excluded.full_name,
  preferred_name = excluded.preferred_name,
  matric_no = excluded.matric_no
''',
      [
        user.id,
        user.name,
        user.experience.name,
        user.group,
        user.isAdmin ? 1 : 0,
        user.ocbcStreak,
        user.memberTier,
        user.fullName,
        user.preferredName,
        user.matricNo,
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

  /// Updates the profile fields collected by the /start and /setinfo wizards.
  void updateProfileInfo(
    int id, {
    String? fullName,
    String? preferredName,
    String? matricNo,
  }) {
    final sets = <String>[];
    final args = <Object>[];
    if (fullName != null) {
      sets.add('full_name = ?');
      args.add(fullName);
    }
    if (preferredName != null) {
      sets.add('preferred_name = ?');
      args.add(preferredName);
    }
    if (matricNo != null) {
      sets.add('matric_no = ?');
      args.add(matricNo);
    }
    if (sets.isEmpty) return;
    args.add(id);
    raw.execute('UPDATE users SET ${sets.join(', ')} WHERE id = ?', args);
  }

  void setOcbcStreak(int id, int streak) {
    raw.execute(
      'UPDATE users SET ocbc_streak = ? WHERE id = ?',
      [streak, id],
    );
  }

  /// Grants or strips the admin flag. Promotion automatically gives the new
  /// admin their own group (the lowest free group number); demotion dissolves
  /// their group — every member (including the demoted admin) loses their
  /// group until reassigned.
  void updateAdmin(int id, bool isAdmin) {
    if (isAdmin) {
      raw.execute('UPDATE users SET is_admin = 1 WHERE id = ?', [id]);
      _assignGroupOnPromotion(id);
    } else {
      final user = findUser(id);
      if (user != null) _dissolveGroup(user.group);
      raw.execute('UPDATE users SET is_admin = 0 WHERE id = ?', [id]);
    }
  }

  /// Sets a user's tier to one of 'admin', 'check', 'member' or 'old'.
  /// Promotion to admin sets is_admin and hands the new admin their own
  /// group; every other tier clears admin and dissolves the admin's group.
  /// The console tier itself is never stored — it is derived from the
  /// console id.
  void setTier(int id, String tier) {
    final isAdminNext = tier == MemberTier.admin;
    final stored =
        (tier == MemberTier.admin || tier == MemberTier.member)
            ? MemberTier.member
            : tier;
    final user = findUser(id);
    if (user == null) return;
    if (isAdminNext && !user.isAdmin) {
      // Promotion: the new admin leads the lowest free group.
      raw.execute(
        'UPDATE users SET member_tier = ?, is_admin = 1 WHERE id = ?',
        [stored, id],
      );
      _assignGroupOnPromotion(id);
    } else if (!isAdminNext && user.isAdmin) {
      // Demotion: the admin's group dissolves with them.
      _dissolveGroup(user.group);
      raw.execute(
        'UPDATE users SET member_tier = ?, is_admin = 0 WHERE id = ?',
        [stored, id],
      );
    } else {
      raw.execute(
        'UPDATE users SET member_tier = ?, is_admin = ? WHERE id = ?',
        [stored, user.isAdmin ? 1 : 0, id],
      );
    }
  }

  // ------------------------------------------------------------ groups

  /// The smallest group number (as a string) not currently held by any
  /// admin — new admins take the lowest free slot so a disbanded group is
  /// reclaimed instead of skipped.
  String? _lowestFreeGroup() {
    final used = raw
        .select(
          "SELECT DISTINCT group_id FROM users WHERE is_admin = 1 AND group_id != ''",
        )
        .map((r) => r['group_id'] as String)
        .toSet();
    var n = 1;
    while (used.contains('$n')) {
      n++;
    }
    return '$n';
  }

  /// Promotion: replaces the user's group with their own admin-led group
  /// (lowest free number). They leave whatever group they were in before.
  void _assignGroupOnPromotion(int id) {
    final group = _lowestFreeGroup();
    if (group != null) {
      raw.execute('UPDATE users SET group_id = ? WHERE id = ?', [group, id]);
    }
  }

  /// Every member of [groupId] (including its admin, if any) loses their
  /// group. Used when an admin is demoted.
  void _dissolveGroup(String groupId) {
    raw.execute(
      "UPDATE users SET group_id = '' WHERE group_id = ?",
      [groupId],
    );
  }

  /// Manual group assignment (the API validates and blocks admins).
  void setGroup(int id, String group) {
    raw.execute('UPDATE users SET group_id = ? WHERE id = ?', [group, id]);
  }

  /// Randomly and evenly assigns members without a group to the admins'
  /// groups. Admins (group leaders) are never assigned; the `check` and
  /// `old` tiers are not members and are never assigned. Returns
  /// groupId -> how many members landed in it.
  Map<String, int> autoAssignGroups() {
    final users = allUsers();
    // Defensive: every admin must hold a group.
    for (final u in users.where((u) => u.isAdmin)) {
      if (u.group.isEmpty) _assignGroupOnPromotion(u.id);
    }
    final leaders = users.where((u) => u.isAdmin && u.group.isNotEmpty).toList();
    if (leaders.isEmpty) return {};
    final leaderGroups = leaders.map((a) => a.group).toList();
    final candidates = users
        .where((u) =>
            !u.isAdmin &&
            u.memberTier == MemberTier.member &&
            u.group.isEmpty)
        .toList()
      ..shuffle(Random());
    final counts = {for (final g in leaderGroups) g: 0};
    for (var i = 0; i < candidates.length; i++) {
      final group = leaderGroups[i % leaderGroups.length];
      raw.execute(
        'UPDATE users SET group_id = ? WHERE id = ?',
        [group, candidates[i].id],
      );
      counts[group] = counts[group]! + 1;
    }
    return counts;
  }

  // ------------------------------------------------------------------- holds

  /// Whether the bot is held (all outgoing messages suppressed).
  bool isHeld() {
    final rows = raw.select(
      "SELECT value FROM settings WHERE key = 'hold'",
    );
    return rows.isNotEmpty && rows.first['value'] == '1';
  }

  void setHeld(bool held) {
    raw.execute(
      "INSERT INTO settings (key, value) VALUES ('hold', ?) "
      "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      [held ? '1' : '0'],
    );
  }

  String? getSetting(String key) {
    final rows = raw.select(
      'SELECT value FROM settings WHERE key = ?',
      [key],
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void setSetting(String key, String value) {
    raw.execute(
      "INSERT INTO settings (key, value) VALUES (?, ?) "
      "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      [key, value],
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

  // ------------------------------------------------------------ rolling window

  /// The rolling window covering [today] (bundle = current + next weekend).
  RollingWindow windowFor(DateTime today) => RollingWindow.forDate(today);

  // --------------------------------------------------------------- sessions

  /// Creates the 4 sessions (Saturday x am/pm x 2 locations) of [sat]'s
  /// weekend, using the given slot time windows. There are no Sunday
  /// sessions. Idempotent.
  void ensureSessionsForWeekend(
    DateTime sat,
    Map<String, (String, String)> slotTimes, {
    required int tzOffsetHours,
  }) {
    const slots = ['am', 'pm'];
    const locations = [Location.ocbc, Location.pasirRis];
    for (final slot in slots) {
      final (startT, endT) = slotTimes[slot]!;
      final start = _parseTime(sat, startT);
      final end = _parseTime(sat, endT);
      for (final loc in locations) {
        raw.execute(
          '''
INSERT OR IGNORE INTO sessions
  (weekend_start, day, slot, location, start_at, end_at)
VALUES (?, ?, ?, ?, ?, ?)
''',
          [_dayKey(sat), 'sat', slot, loc.name, _fmt(start), _fmt(end)],
        );
      }
    }
  }

  /// Sessions of one weekend, ordered by start time. Saturday only — Sunday
  /// sessions are not a thing (and stale rows from older versions are hidden).
  List<Session> sessionsForWeekend(DateTime sat) => raw
      .select(
        'SELECT * FROM sessions WHERE weekend_start = ? AND day = \'sat\' '
        'ORDER BY start_at',
        [_dayKey(sat)],
      )
      .map(Session.fromRow)
      .toList();

  /// Sessions of the window's two weekends (current + next).
  List<Session> windowSessions(RollingWindow w) =>
      [...sessionsForWeekend(w.sat0), ...sessionsForWeekend(w.sat1)];

  Session? sessionById(int id) {
    final rows = raw.select('SELECT * FROM sessions WHERE id = ?', [id]);
    return rows.isEmpty ? null : Session.fromRow(rows.first);
  }

  // ----------------------------------------------------------- availability

  void setAvailability(Availability a) {
    raw.execute(
      '''
INSERT INTO availability (weekend_start, user_id, bundle_start, slots, available, updated_at)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(weekend_start, user_id) DO UPDATE SET
  bundle_start = excluded.bundle_start,
  slots = excluded.slots,
  available = excluded.available,
  updated_at = excluded.updated_at
''',
      [
        _dayKey(a.weekendStart),
        a.userId,
        _dayKey(a.bundleStart),
        jsonEncode(a.slots.map((s) => s.encode()).toList()),
        a.available ? 1 : 0,
        _fmt(a.updatedAt),
      ],
    );
  }

  Availability? getAvailability(DateTime weekendStart, int userId) {
    final rows = raw.select(
      'SELECT * FROM availability WHERE weekend_start = ? AND user_id = ?',
      [_dayKey(weekendStart), userId],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return Availability(
      weekendStart: weekendStart,
      userId: userId,
      bundleStart: DateTime.parse(r['bundle_start'] as String),
      slots: Slot.decodeSet(r['slots'] as String),
      available: (r['available'] as int) == 1,
      updatedAt: DateTime.parse(r['updated_at'] as String),
    );
  }

  List<Availability> availabilityForWeekend(DateTime weekendStart) {
    final rows = raw.select(
      'SELECT * FROM availability WHERE weekend_start = ?',
      [_dayKey(weekendStart)],
    );
    return rows
        .map((r) => Availability(
              weekendStart: weekendStart,
              userId: r['user_id'] as int,
              bundleStart: DateTime.parse(r['bundle_start'] as String),
              slots: Slot.decodeSet(r['slots'] as String),
              available: (r['available'] as int) == 1,
              updatedAt: DateTime.parse(r['updated_at'] as String),
            ))
        .toList();
  }

  /// Whether [user] already answered the bundle starting [bundleStart].
  bool hasBundleResponse(DateTime bundleStart, int userId) {
    final rows = raw.select(
      'SELECT 1 FROM availability WHERE bundle_start = ? AND user_id = ? '
      'LIMIT 1',
      [_dayKey(bundleStart), userId],
    );
    return rows.isNotEmpty;
  }

  /// The most recent bundle (Saturday) [user] answered, if any.
  DateTime? lastBundleStart(int userId) {
    final rows = raw.select(
      'SELECT MAX(bundle_start) AS b FROM availability WHERE user_id = ?',
      [userId],
    );
    final b = rows.first['b'] as String?;
    return b == null ? null : DateTime.parse(b);
  }

  /// Quiet rule: [user] answered a bundle within the last 14 days relative to
  /// [bundleStart] — they are not bothered for 2 weeks in a row.
  bool isQuiet(int userId, DateTime bundleStart) {
    final last = lastBundleStart(userId);
    return last != null && bundleStart.difference(last).inDays < 14;
  }

  /// Active users to prompt for the bundle: members and admins (not
  /// check/old), excluding the quiet and anyone who already answered.
  List<User> promptTargets(DateTime bundleStart) {
    final users = raw
        .select(
          "SELECT * FROM users WHERE member_tier NOT IN ('check', 'old') "
          'ORDER BY name',
        )
        .map(User.fromRow)
        .toList();
    return users
        .where((u) =>
            !hasBundleResponse(bundleStart, u.id) &&
            !isQuiet(u.id, bundleStart))
        .toList();
  }

  /// Non-responders of the bundle: active users who neither answered it nor
  /// are quiet (recently answered a previous bundle).
  List<User> reminderTargets(DateTime bundleStart) {
    final users = raw
        .select(
          "SELECT * FROM users WHERE member_tier NOT IN ('check', 'old') "
          'ORDER BY name',
        )
        .map(User.fromRow)
        .toList();
    return users
        .where((u) =>
            !hasBundleResponse(bundleStart, u.id) &&
            !isQuiet(u.id, bundleStart))
        .toList();
  }

  // ------------------------------------------------------------- allocations

  void replaceAllocationsForWeekend(
    DateTime sat,
    List<(int, int)> allocations,
  ) {
    final tx = raw;
    tx.execute('BEGIN IMMEDIATE');
    try {
      tx.execute(
        'DELETE FROM allocations WHERE session_id IN '
        '(SELECT id FROM sessions WHERE weekend_start = ?)',
        [_dayKey(sat)],
      );
      final stmt = tx.prepare(
        'INSERT INTO allocations (user_id, session_id) VALUES (?, ?)',
      );
      for (final (userId, sessionId) in allocations) {
        stmt.execute([userId, sessionId]);
      }
      stmt.close();
      tx.execute('COMMIT');
    } catch (_) {
      tx.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Revokes a member's allocation for one weekend (used when they repick:
  /// they leave the allocation pool and are re-decided at the next sharp
  /// hour).
  void removeAllocationForUser(int userId, DateTime sat) {
    raw.execute(
      'DELETE FROM allocations WHERE user_id = ? AND session_id IN '
      '(SELECT id FROM sessions WHERE weekend_start = ?)',
      [userId, _dayKey(sat)],
    );
  }

  List<(User, Session)> allocationsForWeekend(DateTime sat) {
    final rows = raw.select(
      '''
SELECT u.*,
       s.id             AS session_id,
       s.weekend_start  AS session_weekend_start,
       s.day            AS session_day,
       s.slot           AS session_slot,
       s.location       AS session_location,
       s.start_at       AS session_start_at,
       s.end_at         AS session_end_at
FROM allocations al
JOIN users u ON u.id = al.user_id
JOIN sessions s ON s.id = al.session_id
WHERE s.weekend_start = ? AND s.day = 'sat'
ORDER BY s.start_at, u.name
''',
      [_dayKey(sat)],
    );
    return rows.map((r) {
      final user = User.fromRow(r);
      final session = Session(
        id: r['session_id'] as int,
        weekendStart: DateTime.parse(r['session_weekend_start'] as String),
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

  /// Per-weekend allocation flags (in settings) so a weekend is allocated
  /// exactly once even if the scheduler ticks repeatedly.
  bool weekendAllocated(DateTime sat) =>
      getSetting('alloc_${_dayKey(sat)}') == '1';

  void markWeekendAllocated(DateTime sat) =>
      setSetting('alloc_${_dayKey(sat)}', '1');

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
      'SELECT * FROM users WHERE group_id = ? AND is_admin = 1 LIMIT 1',
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

  // -------------------------------------------------------- holiday optouts

  /// Marks [user] as "don't bother me this holiday" for the week starting
  /// [weekMonday].
  void setHolidayOptout(int userId, DateTime weekMonday) {
    raw.execute(
      'INSERT OR REPLACE INTO holiday_optouts (user_id, week_start) '
      'VALUES (?, ?)',
      [userId, _fmt(weekMonday)],
    );
  }

  bool hasHolidayOptout(int userId, DateTime weekMonday) {
    final rows = raw.select(
      'SELECT 1 FROM holiday_optouts WHERE user_id = ? AND week_start = ?',
      [userId, _fmt(weekMonday)],
    );
    return rows.isNotEmpty;
  }

  // ------------------------------------------------------------- attendance

  /// Total positive attendance of [userId], split by location.
  ({int total, int ocbc, int pasirRis}) attendanceStats(int userId) {
    final rows = raw.select(
      '''
SELECT COUNT(*) AS total,
       SUM(CASE WHEN s.location = 'ocbc' THEN 1 ELSE 0 END) AS ocbc,
       SUM(CASE WHEN s.location = 'pasirRis' THEN 1 ELSE 0 END) AS pr
FROM attendance a
JOIN sessions s ON s.id = a.session_id
WHERE a.user_id = ? AND a.attended = 1
''',
      [userId],
    );
    final r = rows.first;
    return (
      total: r['total'] as int,
      ocbc: (r['ocbc'] as int?) ?? 0,
      pasirRis: (r['pr'] as int?) ?? 0,
    );
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
