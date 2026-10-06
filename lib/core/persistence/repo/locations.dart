part of '../../repo.dart';

mixin _Repo3 on Repo {

  /// Reads all schedule values from one SQLite read transaction. Missing
  /// weekday keys are filled by [ScheduleTimes.fromSettings] for legacy DBs.
  ScheduleTimes readSchedule() {
    raw.execute('BEGIN');
    try {
      const keys = [
        ScheduleTimes.promptKey,
        ScheduleTimes.reminderKey,
        ScheduleTimes.lockKey,
        ScheduleTimes.checkerKey,
        ScheduleTimes.promptWeekdayKey,
        ScheduleTimes.reminderWeekdayKey,
        ScheduleTimes.lockWeekdayKey,
        ScheduleTimes.checkerWeekdayKey,
      ];
      final rows = raw.select(
        'SELECT key, value FROM settings WHERE key IN '
        '(${List.filled(keys.length, '?').join(', ')})',
        keys,
      );
      final values = <String, String?>{
        for (final row in rows) row['key'] as String: row['value'] as String,
      };
      final schedule = ScheduleTimes.fromSettings(values);
      raw.execute('COMMIT');
      return schedule;
    } catch (_) {
      raw.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Replaces all four schedule values atomically.
  void writeSchedule(ScheduleTimes schedule) {
    schedule.validate();
    raw.execute('BEGIN IMMEDIATE');
    try {
      for (final entry in schedule.settings.entries) {
        raw.execute(
          'INSERT INTO settings (key, value) VALUES (?, ?) '
          'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          [entry.key, entry.value],
        );
      }
      raw.execute('COMMIT');
    } catch (_) {
      raw.execute('ROLLBACK');
      rethrow;
    }
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
  PendingRole? addPendingUser(String handle,
      {
        required bool isAdmin,
        String tier = MemberTier.member,
        NotificationPreference notificationPreference =
            NotificationPreference.weekly,
      }) {
    final normalized = _pendingHandle(handle);
    final previous = pendingRole(normalized);
    raw.execute(
      '''
INSERT INTO pending_users
    (username, is_admin, tier, notification_preference)
VALUES (?, ?, ?, ?)
ON CONFLICT(username) DO UPDATE SET
  is_admin = excluded.is_admin,
  tier = excluded.tier,
  notification_preference = excluded.notification_preference
''',
      [
        normalized,
        isAdmin ? 1 : 0,
        tier,
        _notificationPreferenceValue(notificationPreference),
      ],
    );
    return previous;
  }

  PendingRole? pendingRole(String handle) {
    final rows = raw.select(
      'SELECT is_admin, tier, notification_preference '
      'FROM pending_users WHERE username = ?',
      [_pendingHandle(handle)],
    );
    if (rows.isEmpty) return null;
    return PendingRole(
      isAdmin: (rows.first['is_admin'] as int) == 1,
      tier: rows.first['tier'] as String,
      notificationPreference: _notificationPreferenceFromValue(
        rows.first['notification_preference'] as String?,
      ),
    );
  }

  /// Replaces a queued role and returns the role that was replaced, if any.
  PendingRole? replacePendingUser(String handle,
          {
            required bool isAdmin,
            String tier = MemberTier.member,
            NotificationPreference notificationPreference =
                NotificationPreference.weekly,
          }) =>
      addPendingUser(
        handle,
        isAdmin: isAdmin,
        tier: tier,
        notificationPreference: notificationPreference,
      );

  bool isPendingUser(String handle) {
    final rows = raw.select(
      'SELECT 1 FROM pending_users WHERE username = ?',
      [_pendingHandle(handle)],
    );
    return rows.isNotEmpty;
  }

  bool pendingIsAdmin(String handle) {
    final rows = raw.select(
      'SELECT is_admin FROM pending_users WHERE username = ?',
      [_pendingHandle(handle)],
    );
    return rows.isNotEmpty && (rows.first['is_admin'] as int) == 1;
  }

  /// The tier a pending user was queued with ('member' by default).
  String pendingTier(String handle) {
    final rows = raw.select(
      'SELECT tier FROM pending_users WHERE username = ?',
      [_pendingHandle(handle)],
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
  RollingWindow windowFor(DateTime today, {ScheduleTimes? schedule}) =>
      RollingWindow.forDate(today, schedule: schedule);

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

}
