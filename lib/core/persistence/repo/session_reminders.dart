part of '../../repo.dart';

extension RepoSessionReminders on Repo {
  List<(User, Session)> pendingSessionReminderRecipients({
    required DateTime nowUtc,
    required int timezoneOffsetHours,
  }) {
    final localNow = _sessionReminderLocalTime(nowUtc, timezoneOffsetHours);
    return raw
        .select(
          '''
SELECT u.*,
       s.id AS session_id,
       s.weekend_start AS session_weekend_start,
       s.day AS session_day,
       s.slot AS session_slot,
       s.location AS session_location,
       s.start_at AS session_start_at,
       s.end_at AS session_end_at,
       s.max_people AS session_max_people,
       s.capacity_group AS session_capacity_group
FROM allocations al
JOIN users u ON u.id = al.user_id
JOIN sessions s ON s.id = al.session_id
WHERE u.member_tier NOT IN ('check', 'old')
  AND u.session_reminders_enabled = 1
  AND s.start_at > ?
ORDER BY s.start_at, u.name
''',
          [_fmt(localNow)],
        )
        .map(_sessionReminderPair)
        .toList();
  }

  (User, Session)? sessionReminderRecipient(
    int userId,
    int sessionId, {
    required DateTime nowUtc,
    required int timezoneOffsetHours,
  }) {
    final localNow = _sessionReminderLocalTime(nowUtc, timezoneOffsetHours);
    final rows = raw.select(
      '''
SELECT u.*,
       s.id AS session_id,
       s.weekend_start AS session_weekend_start,
       s.day AS session_day,
       s.slot AS session_slot,
       s.location AS session_location,
       s.start_at AS session_start_at,
       s.end_at AS session_end_at,
       s.max_people AS session_max_people,
       s.capacity_group AS session_capacity_group
FROM allocations al
JOIN users u ON u.id = al.user_id
JOIN sessions s ON s.id = al.session_id
WHERE al.user_id = ? AND al.session_id = ?
  AND u.member_tier NOT IN ('check', 'old')
  AND u.session_reminders_enabled = 1
  AND s.start_at > ?
LIMIT 1
''',
      [userId, sessionId, _fmt(localNow)],
    );
    return rows.isEmpty ? null : _sessionReminderPair(rows.first);
  }

  bool claimSessionReminder(
    int userId,
    int sessionId, {
    required DateTime nowUtc,
    required int timezoneOffsetHours,
  }) {
    final tx = raw;
    final attemptAt = nowUtc.toUtc().toIso8601String();
    tx.execute('BEGIN IMMEDIATE');
    try {
      if (sessionReminderRecipient(
            userId,
            sessionId,
            nowUtc: nowUtc,
            timezoneOffsetHours: timezoneOffsetHours,
          ) ==
          null) {
        tx.execute('COMMIT');
        return false;
      }
      tx.execute(
        '''
INSERT INTO session_reminder_deliveries
  (user_id, session_id, attempted_at, delivery_state, retry_at)
VALUES (?, ?, ?, 'sending', NULL)
ON CONFLICT(user_id, session_id) DO UPDATE SET
  attempted_at = excluded.attempted_at,
  delivery_state = 'sending',
  retry_at = NULL
WHERE delivery_state = 'retryable'
  AND (retry_at IS NULL OR retry_at <= excluded.attempted_at)
''',
        [userId, sessionId, attemptAt],
      );
      final claimed =
          (tx.select('SELECT changes() AS n').first['n'] as int) == 1;
      tx.execute('COMMIT');
      return claimed;
    } catch (_) {
      tx.execute('ROLLBACK');
      rethrow;
    }
  }

  void markSessionReminderDelivered(
    int userId,
    int sessionId,
    DateTime nowUtc,
  ) {
    raw.execute(
      "UPDATE session_reminder_deliveries SET delivery_state = 'delivered', "
      'delivered_at = ?, retry_at = NULL WHERE user_id = ? AND session_id = ?',
      [nowUtc.toUtc().toIso8601String(), userId, sessionId],
    );
  }

  void retrySessionReminder(int userId, int sessionId, DateTime nowUtc) {
    raw.execute(
      "UPDATE session_reminder_deliveries SET delivery_state = 'retryable', "
      'retry_at = ? WHERE user_id = ? AND session_id = ?',
      [
        nowUtc.toUtc().add(const Duration(minutes: 1)).toIso8601String(),
        userId,
        sessionId,
      ],
    );
  }

  void markSessionReminderUncertain(int userId, int sessionId) {
    raw.execute(
      "UPDATE session_reminder_deliveries SET delivery_state = 'uncertain', "
      'retry_at = NULL WHERE user_id = ? AND session_id = ?',
      [userId, sessionId],
    );
  }

  DateTime? nextSessionReminderRetryAt(DateTime nowUtc) {
    final rows = raw.select(
      "SELECT MIN(retry_at) AS retry_at FROM session_reminder_deliveries "
      "WHERE delivery_state = 'retryable' AND retry_at > ?",
      [nowUtc.toUtc().toIso8601String()],
    );
    final value = rows.first['retry_at'] as String?;
    return value == null ? null : DateTime.parse(value);
  }

  bool sessionReminderAttempted(int userId, int sessionId) => raw.select(
    'SELECT 1 FROM session_reminder_deliveries '
    'WHERE user_id = ? AND session_id = ?',
    [userId, sessionId],
  ).isNotEmpty;

  void setSessionRemindersEnabled(int userId, bool enabled) {
    raw.execute('UPDATE users SET session_reminders_enabled = ? WHERE id = ?', [
      enabled ? 1 : 0,
      userId,
    ]);
    notifySessionReminderWorkChanged();
  }

  (User, Session) _sessionReminderPair(Map<String, Object?> row) {
    final user = User.fromRow(row);
    final session = Session(
      id: row['session_id'] as int,
      weekendStart: DateTime.parse(row['session_weekend_start'] as String),
      day: row['session_day'] as String,
      slot: row['session_slot'] as String,
      location: row['session_location'] as String,
      start: DateTime.parse(row['session_start_at'] as String),
      end: DateTime.parse(row['session_end_at'] as String),
      maxPeople: row['session_max_people'] as int?,
      capacityGroup: row['session_capacity_group'] as String?,
    );
    return (user, session);
  }

  DateTime _sessionReminderLocalTime(DateTime nowUtc, int offsetHours) {
    final local = nowUtc.toUtc().add(Duration(hours: offsetHours));
    return DateTime(
      local.year,
      local.month,
      local.day,
      local.hour,
      local.minute,
    );
  }
}
