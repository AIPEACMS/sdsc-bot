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

enum GlobalAdminResult {
  success,
  noSuchUser,
  alreadyExists,
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
 INSERT INTO users (id, name, experience, group_id, is_admin, ocbc_streak, member_tier, preferred_name)
 VALUES (?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  name = excluded.name,
  experience = excluded.experience,
  group_id = excluded.group_id,
  is_admin = excluded.is_admin,
  ocbc_streak = excluded.ocbc_streak,
  member_tier = excluded.member_tier,
  preferred_name = excluded.preferred_name
''',
      [
        user.id,
        user.name,
        user.experience.name,
        user.group,
        user.isAdmin ? 1 : 0,
        user.ocbcStreak,
        user.memberTier,
        user.preferredName,
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

  /// Updates the name a member wants to be called.
  void updatePreferredName(int id, String preferredName) {
    raw.execute(
      'UPDATE users SET preferred_name = ? WHERE id = ?',
      [preferredName, id],
    );
  }

  /// @deprecated Use [updatePreferredName].
  @Deprecated('Use updatePreferredName.')
  void updateProfileInfo(
    int id, {
    String? fullName,
    String? preferredName,
    String? matricNo,
    String? schoolEmail,
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
    if (schoolEmail != null) {
      sets.add('school_email = ?');
      args.add(schoolEmail);
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

  /// Grants or strips the normal-admin flag. Promotion automatically gives the new
  /// admin their own group (the lowest free group number); demotion dissolves
  /// their group — every member (including the demoted admin) loses their
  /// group until reassigned.
  bool updateAdmin(int id, bool isAdmin) {
    final user = findUser(id);
    if (user == null || user.isGlobalAdmin) return false;
    if (isAdmin) {
      raw.execute('UPDATE users SET is_admin = 1 WHERE id = ?', [id]);
      _assignGroupOnPromotion(id);
    } else {
      raw.execute('UPDATE users SET is_admin = 0 WHERE id = ?', [id]);
      _dissolveGroup(user.group);
    }
    return true;
  }

  /// Demotes a normal admin to a regular active member and dissolves their
  /// group. This is the explicit Telegram `/demote` operation.
  bool demoteAdmin(int id) {
    final user = findUser(id);
    if (user == null || !user.isAdmin || user.isGlobalAdmin) return false;
    final tx = raw;
    tx.execute('BEGIN IMMEDIATE');
    try {
      _dissolveGroup(user.group);
      tx.execute(
        'UPDATE users SET is_admin = 0, member_tier = ?, group_id = \'\' '
        'WHERE id = ?',
        [MemberTier.member, id],
      );
      tx.execute('COMMIT');
      return true;
    } catch (_) {
      tx.execute('ROLLBACK');
      rethrow;
    }
  }

  User? globalAdmin() {
    final rows = raw.select(
      'SELECT * FROM users WHERE is_global_admin = 1 LIMIT 1',
    );
    return rows.isEmpty ? null : User.fromRow(rows.first);
  }

  /// Promotes a registered user to the singleton global-admin role. A member
  /// gets a group only when they do not already have one; an existing normal
  /// admin keeps their group while its admin flag is cleared.
  GlobalAdminResult appointGlobalAdmin(int id) {
    final tx = raw;
    tx.execute('BEGIN IMMEDIATE');
    try {
      final user = findUser(id);
      if (user == null) {
        tx.execute('ROLLBACK');
        return GlobalAdminResult.noSuchUser;
      }
      if (globalAdmin() != null) {
        tx.execute('ROLLBACK');
        return GlobalAdminResult.alreadyExists;
      }

      tx.execute(
        'UPDATE users SET is_admin = 0, is_global_admin = 1, '
        'member_tier = ? WHERE id = ?',
        [MemberTier.member, id],
      );
      if (user.group.isEmpty) _assignGroupOnPromotion(id);
      tx.execute('COMMIT');
      return GlobalAdminResult.success;
    } catch (_) {
      tx.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Removes the current global admin and returns them to a regular member,
  /// dissolving their group. The optional id is checked inside the transaction
  /// so a confirmation cannot remove a new global admin after a handoff.
  bool removeGlobalAdmin(int id) {
    final tx = raw;
    tx.execute('BEGIN IMMEDIATE');
    try {
      final user = findUser(id);
      if (user == null || !user.isGlobalAdmin) {
        tx.execute('ROLLBACK');
        return false;
      }
      _dissolveGroup(user.group);
      tx.execute(
        'UPDATE users SET is_global_admin = 0, is_admin = 0, '
        'member_tier = ?, group_id = \'\' WHERE id = ?',
        [MemberTier.member, id],
      );
      tx.execute('COMMIT');
      return true;
    } catch (_) {
      tx.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Sets a user's tier to one of 'admin', 'check', 'member' or 'old'.
  /// Promotion to admin sets is_admin and hands the new admin their own
  /// group; every other tier clears admin and dissolves the admin's group.
  /// The console tier itself is never stored — it is derived from the
  /// console id.
  bool setTier(int id, String tier) {
    if (![MemberTier.admin, MemberTier.check, MemberTier.member, MemberTier.old]
        .contains(tier)) {
      return false;
    }
    final isAdminNext = tier == MemberTier.admin;
    final stored =
        (tier == MemberTier.admin || tier == MemberTier.member)
            ? MemberTier.member
            : tier;
    final user = findUser(id);
    if (user == null || user.isGlobalAdmin) return false;
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
    return true;
  }

  // ------------------------------------------------------------ groups

  /// The smallest group number (as a string) not currently held by any
  /// admin — new admins take the lowest free slot so a disbanded group is
  /// reclaimed instead of skipped.
  String? _lowestFreeGroup() {
    final used = raw
        .select(
          "SELECT DISTINCT group_id FROM users WHERE "
          "(is_admin = 1 OR is_global_admin = 1) AND group_id != ''",
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
    for (final u in users.where((u) => u.isAdmin || u.isGlobalAdmin)) {
      if (u.group.isEmpty) _assignGroupOnPromotion(u.id);
    }
    final leaders = users
        .where((u) => (u.isAdmin || u.isGlobalAdmin) && u.group.isNotEmpty)
        .toList();
    if (leaders.isEmpty) return {};
    final leaderGroups = leaders.map((a) => a.group).toList();
    final candidates = users
        .where((u) =>
            !u.isAdmin &&
            !u.isGlobalAdmin &&
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
  /// The user is auto-registered (with admin rights if [isAdmin], and with
  /// [tier] — e.g. `check` from the console's "Add check") the first time
  /// they contact the bot.
  void addPendingUser(String handle,
      {required bool isAdmin, String tier = MemberTier.member}) {
    raw.execute(
      '''
INSERT INTO pending_users (username, is_admin, tier) VALUES (?, ?, ?)
ON CONFLICT(username) DO UPDATE SET
  is_admin = MAX(pending_users.is_admin, excluded.is_admin),
  tier = excluded.tier
''',
      [handle.replaceFirst('@', '').toLowerCase(), isAdmin ? 1 : 0, tier],
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

  /// The tier a pending user was queued with ('member' by default).
  String pendingTier(String handle) {
    final rows = raw.select(
      'SELECT tier FROM pending_users WHERE username = ?',
      [handle.replaceFirst('@', '').toLowerCase()],
    );
    return rows.isEmpty ? MemberTier.member : rows.first['tier'] as String;
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

  /// The Singapore-time timestamp at which a deduplicated outbound message
  /// was accepted by Telegram. Null means the historical row predates this
  /// audit field.
  String? messageSentAtOnDay(int userId, String kind, DateTime day) {
    final rows = raw.select(
      'SELECT sent_at FROM sent_messages '
      'WHERE user_id = ? AND kind = ? AND day = ?',
      [userId, kind, _dayKey(day)],
    );
    if (rows.isEmpty) return null;
    return rows.first['sent_at'] as String?;
  }

  void markMessageSent(int userId, String kind, DateTime day) {
    raw.execute(
      'INSERT OR IGNORE INTO sent_messages (user_id, kind, day, sent_at) '
      'VALUES (?, ?, ?, ?)',
      [userId, kind, _dayKey(day), _sgtNow()],
    );
  }

  static String _sgtNow() {
    final now = DateTime.now().toUtc().add(const Duration(hours: 8));
    String two(int value) => value.toString().padLeft(2, '0');
    String three(int value) => value.toString().padLeft(3, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.'
        '${three(now.millisecond)}+08:00';
  }

  // ------------------------------------------------------------ rolling window

  /// The rolling window covering [today] (bundle = current + next weekend).
  RollingWindow windowFor(DateTime today) => RollingWindow.forDate(today);

  // -------------------------------------------------------------- locations

  /// Every location: approved first, then pending, alphabetical by name.
  List<LocationInfo> allLocations() => raw
      .select(
        "SELECT * FROM locations ORDER BY (status = 'pending'), "
        'name COLLATE NOCASE',
      )
      .map(LocationInfo.fromRow)
      .toList();

  List<LocationInfo> approvedLocations() =>
      allLocations().where((l) => l.isApproved).toList();

  List<LocationInfo> pendingLocations() =>
      allLocations().where((l) => !l.isApproved).toList();

  LocationInfo? locationByKey(String key) {
    final rows = raw.select('SELECT * FROM locations WHERE key = ?', [key]);
    return rows.isEmpty ? null : LocationInfo.fromRow(rows.first);
  }

  LocationInfo? locationById(int id) {
    final rows = raw.select('SELECT * FROM locations WHERE id = ?', [id]);
    return rows.isEmpty ? null : LocationInfo.fromRow(rows.first);
  }

  /// Display name for a location key, falling back to the key itself.
  String locationName(String key) => locationByKey(key)?.name ?? key;

  /// Resolves a typed token to an approved location (case-insensitive,
  /// punctuation-insensitive, substring-tolerant). Null when nothing matches.
  LocationInfo? resolveLocation(String token) {
    final norm = _normLocation(token);
    if (norm.isEmpty) return null;
    final approved = approvedLocations();
    for (final l in approved) {
      if (_normLocation(l.key) == norm || _normLocation(l.name) == norm) {
        return l;
      }
      for (final a in l.aliases) {
        if (_normLocation(a) == norm) return l;
      }
    }
    for (final l in approved) {
      for (final c in [
        _normLocation(l.key),
        _normLocation(l.name),
        ...l.aliases.map(_normLocation),
      ]) {
        if (c.isNotEmpty && (c.contains(norm) || norm.contains(c))) return l;
      }
    }
    return null;
  }

  static String _normLocation(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  /// Derives a unique camelCase key from a display name.
  String _locationKey(String name) {
    final words =
        _normLocation(name).split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return 'loc';
    final base = words.first +
        words
            .skip(1)
            .map((w) => w[0].toUpperCase() + w.substring(1))
            .join();
    var key = base;
    var n = 2;
    while (locationByKey(key) != null) {
      key = '$base$n';
      n++;
    }
    return key;
  }

  /// Creates an approved location (console-driven add). Idempotent by name:
  /// an existing location with the same normalized name is returned, and any
  /// new aliases are merged into it.
  LocationInfo addLocation(String name, {List<String> aliases = const []}) {
    final clean = name.trim();
    final existing = approvedLocations()
        .where((l) => _normLocation(l.name) == _normLocation(clean))
        .toList();
    if (existing.isNotEmpty) {
      if (aliases.isNotEmpty) addAliases(existing.first.key, aliases);
      return existing.first;
    }
    raw.execute(
      'INSERT INTO locations (key, name, aliases, status) '
      "VALUES (?, ?, ?, 'approved')",
      [_locationKey(clean), clean, jsonEncode(_cleanAliases(aliases))],
    );
    return allLocations().firstWhere(
      (l) => _normLocation(l.name) == _normLocation(clean),
    );
  }

  /// Records a gadmin's request for a not-yet-known location (pending until
  /// the console approves it). Re-requesting the same name reuses the row.
  LocationInfo requestLocation(String name, {required int requestedBy}) {
    final clean = name.trim();
    final existing = allLocations()
        .where((l) => _normLocation(l.name) == _normLocation(clean))
        .toList();
    if (existing.isNotEmpty) return existing.first;
    raw.execute(
      'INSERT INTO locations (key, name, aliases, status, requested_by) '
      "VALUES (?, ?, '[]', 'pending', ?)",
      [_locationKey(clean), clean, requestedBy],
    );
    return allLocations().firstWhere(
      (l) => _normLocation(l.name) == _normLocation(clean),
    );
  }

  /// Approves a pending location, optionally renaming it and setting aliases.
  bool approveLocation(int id, {String? name, List<String>? aliases}) {
    final loc = locationById(id);
    if (loc == null) return false;
    final finalName =
        (name == null || name.trim().isEmpty) ? loc.name : name.trim();
    final merged = _cleanAliases([...loc.aliases, ...?aliases]);
    raw.execute(
      "UPDATE locations SET status = 'approved', name = ?, aliases = ? "
      'WHERE id = ?',
      [finalName, jsonEncode(merged), id],
    );
    return true;
  }

  /// Adds aliases to a location, de-duplicated (case-insensitive).
  void addAliases(String locationKey, List<String> aliases) {
    final loc = locationByKey(locationKey);
    if (loc == null) return;
    final merged = _cleanAliases([...loc.aliases, ...aliases]);
    raw.execute(
      'UPDATE locations SET aliases = ? WHERE key = ?',
      [jsonEncode(merged), locationKey],
    );
  }

  static List<String> _cleanAliases(List<String> aliases) {
    final seen = <String>{};
    final out = <String>[];
    for (final a in aliases) {
      final t = a.trim();
      final norm = _normLocation(t);
      if (norm.isEmpty || !seen.add(norm)) continue;
      out.add(t);
    }
    return out;
  }

  // --------------------------------------------------------------- sessions

  /// The active activity-schedule template (ordered). Seeded from the
  /// environment slot windows on first run; replaced wholesale by /settime.
  List<ScheduleSlot> scheduleTemplate() => raw
      .select('SELECT * FROM schedule_template ORDER BY id')
      .map(
        (r) => ScheduleSlot(
          day: r['day'] as String,
          slot: r['slot'] as String,
          start: r['start_at'] as String,
          end: r['end_at'] as String,
          location: r['location_key'] as String,
        ),
      )
      .toList();

  /// Replaces the whole template (transactional). [rows] must be non-empty.
  void replaceScheduleTemplate(List<ScheduleSlot> rows) {
    final tx = raw;
    tx.execute('BEGIN IMMEDIATE');
    try {
      tx.execute('DELETE FROM schedule_template');
      for (final r in rows) {
        tx.execute(
          'INSERT INTO schedule_template '
          '(day, slot, start_at, end_at, location_key) VALUES (?, ?, ?, ?, ?)',
          [r.day, r.slot, r.start, r.end, r.location],
        );
      }
      tx.execute('COMMIT');
    } catch (_) {
      tx.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Creates (idempotently) the sessions for [sat]'s weekend from [template].
  /// A template row on day D is placed at anchor + offset, where the bundled
  /// weekend runs Saturday → Friday.
  void ensureSessionsForWeekend(
    DateTime sat,
    List<ScheduleSlot> template, {
    required int tzOffsetHours,
  }) {
    for (final t in template) {
      final date = _sessionDate(sat, t.day);
      if (date == null) continue;
      raw.execute(
        '''
INSERT OR IGNORE INTO sessions
  (weekend_start, day, slot, location, start_at, end_at)
VALUES (?, ?, ?, ?, ?, ?)
''',
        [
          _dayKey(sat),
          t.day,
          t.slot,
          t.location,
          _fmt(_parseTime(date, t.start)),
          _fmt(_parseTime(date, t.end)),
        ],
      );
    }
  }

  /// Deletes and recreates [sat]'s sessions from [template]. Destructive:
  /// callers must also clear availability/allocations for the weekend (see
  /// [clearWeekendAvailabilityAndAllocations]).
  void replaceSessionsForWeekend(
    DateTime sat,
    List<ScheduleSlot> template, {
    required int tzOffsetHours,
  }) {
    final tx = raw;
    tx.execute('BEGIN IMMEDIATE');
    try {
      tx.execute('DELETE FROM sessions WHERE weekend_start = ?', [_dayKey(sat)]);
      tx.execute('COMMIT');
    } catch (_) {
      tx.execute('ROLLBACK');
      rethrow;
    }
    ensureSessionsForWeekend(sat, template, tzOffsetHours: tzOffsetHours);
  }

  /// Drops availability and allocations for [sat]'s weekend (used when the
  /// schedule changes on an open weekend, so members re-pick).
  void clearWeekendAvailabilityAndAllocations(DateTime sat) {
    final tx = raw;
    tx.execute('BEGIN IMMEDIATE');
    try {
      tx.execute('DELETE FROM allocations WHERE session_id IN '
          '(SELECT id FROM sessions WHERE weekend_start = ?)', [_dayKey(sat)]);
      tx.execute('DELETE FROM availability WHERE weekend_start = ?',
          [_dayKey(sat)]);
      tx.execute('COMMIT');
    } catch (_) {
      tx.execute('ROLLBACK');
      rethrow;
    }
  }

  /// The date of the template-day [day] inside [sat]'s bundled weekend
  /// (Saturday → Friday), or null for an unknown token.
  static DateTime? _sessionDate(DateTime sat, String day) {
    final offset = Slot.allDays.indexOf(day);
    if (offset < 0) return null;
    return sat.add(Duration(days: offset));
  }

  /// Sessions of one weekend that belong to the current schedule template,
  /// ordered by day and start time. Rows left over from an older schedule
  /// (e.g. the Saturday-only or fixed-AM/PM models) are hidden and removed by
  /// the schema cleanup, so a template change can never resurrect them.
  List<Session> sessionsForWeekend(DateTime sat) => raw
      .select(
        '''
SELECT s.* FROM sessions s
WHERE s.weekend_start = ?
  AND EXISTS (
    SELECT 1 FROM schedule_template t
    WHERE t.day = s.day AND t.slot = s.slot
      AND t.location_key = s.location
  )
ORDER BY s.start_at
''',
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
INSERT INTO availability (weekend_start, user_id, bundle_start, slots, want_slots, available, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(weekend_start, user_id) DO UPDATE SET
  bundle_start = excluded.bundle_start,
  slots = excluded.slots,
  want_slots = excluded.want_slots,
  available = excluded.available,
  updated_at = excluded.updated_at
''',
      [
        _dayKey(a.weekendStart),
        a.userId,
        _dayKey(a.bundleStart),
        jsonEncode(a.slots.map((s) => s.encode()).toList()),
        jsonEncode(a.wantSlots.map((s) => s.encode()).toList()),
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
      wantSlots: Slot.decodeSet(r['want_slots'] as String),
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
              wantSlots: Slot.decodeSet(r['want_slots'] as String),
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
WHERE s.weekend_start = ?
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
        location: r['session_location'] as String,
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

  /// Clears the allocated flag so the dynamic allocator may run again (used
  /// when the schedule changes for an open weekend).
  void setWeekendAllocated(DateTime sat, bool value) =>
      setSetting('alloc_${_dayKey(sat)}', value ? '1' : '0');

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

  /// The number of consecutive session weekends up to [latestSat] in which
  /// [userId] had no positive attendance, counting backward from [latestSat].
  /// An attended weekend resets the streak; holiday weeks neither count nor
  /// reset; weekends before the member registered do not count.
  int consecutiveAbsentWeeks(int userId, DateTime latestSat) {
    final weekends = raw
        .select(
          'SELECT DISTINCT weekend_start FROM sessions '
          'WHERE weekend_start <= ? ORDER BY weekend_start DESC',
          [_dayKey(latestSat)],
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
