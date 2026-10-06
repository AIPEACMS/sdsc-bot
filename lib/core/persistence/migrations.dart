part of '../db.dart';
mixin _Database2 on _DatabaseBase {
  static void _applySchema(sqlite.Database db, Config config) {
    db.execute('''
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  experience TEXT NOT NULL DEFAULT 'newbie',
  group_id TEXT NOT NULL DEFAULT '',
  is_admin INTEGER NOT NULL DEFAULT 0,
  is_global_admin INTEGER NOT NULL DEFAULT 0
    CHECK (is_global_admin IN (0, 1)),
  ocbc_streak INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  full_name TEXT NOT NULL DEFAULT '',
  preferred_name TEXT NOT NULL DEFAULT '',
  matric_no TEXT NOT NULL DEFAULT '',
  school_email TEXT NOT NULL DEFAULT '',
  member_tier TEXT NOT NULL DEFAULT 'member',
  notification_preference TEXT NOT NULL DEFAULT 'weekly',
  last_prompt_state TEXT NOT NULL DEFAULT 'none'
);
CREATE TABLE IF NOT EXISTS sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  weekend_start TEXT NOT NULL,
  day TEXT NOT NULL,
  slot TEXT NOT NULL,
  location TEXT NOT NULL,
  start_at TEXT NOT NULL,
  end_at TEXT NOT NULL,
  max_people INTEGER,
  capacity_group TEXT,
  UNIQUE(weekend_start, day, slot, location)
);
CREATE TABLE IF NOT EXISTS availability (
  weekend_start TEXT NOT NULL,
  user_id INTEGER NOT NULL REFERENCES users(id),
  bundle_start TEXT NOT NULL,
  slots TEXT NOT NULL DEFAULT '[]',
  want_slots TEXT NOT NULL DEFAULT '[]',
  available INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (weekend_start, user_id)
);
CREATE TABLE IF NOT EXISTS allocations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id INTEGER NOT NULL REFERENCES sessions(id),
  user_id INTEGER NOT NULL REFERENCES users(id),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(session_id, user_id)
);
CREATE TABLE IF NOT EXISTS attendance (
  user_id INTEGER NOT NULL REFERENCES users(id),
  session_id INTEGER NOT NULL REFERENCES sessions(id),
  attended INTEGER NOT NULL DEFAULT 1,
  confirmed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id, session_id)
);
CREATE TABLE IF NOT EXISTS cycles (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  block_week INTEGER NOT NULL,
  block_year INTEGER NOT NULL,
  prompt_day TEXT NOT NULL,
  reminder_day TEXT NOT NULL,
  deadline TEXT NOT NULL,
  allocation_day TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open',
  prompt_sent INTEGER NOT NULL DEFAULT 0,
  reminder_sent INTEGER NOT NULL DEFAULT 0,
  allocated INTEGER NOT NULL DEFAULT 0,
  UNIQUE(block_year, block_week)
);
CREATE TABLE IF NOT EXISTS holidays (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  week_start TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS seen_users (
  id INTEGER PRIMARY KEY,
  username TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS pending_users (
  username TEXT PRIMARY KEY,
  is_admin INTEGER NOT NULL DEFAULT 0,
  tier TEXT NOT NULL DEFAULT 'member',
  notification_preference TEXT NOT NULL DEFAULT 'weekly'
);
CREATE TABLE IF NOT EXISTS sent_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users(id),
  kind TEXT NOT NULL,
  day TEXT NOT NULL,
  sent_at TEXT NOT NULL,
  UNIQUE(user_id, kind, day)
);
CREATE TABLE IF NOT EXISTS calendar_years (
  academic_year TEXT PRIMARY KEY,
  yaml TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS holiday_optouts (
  user_id INTEGER NOT NULL REFERENCES users(id),
  week_start TEXT NOT NULL,
  PRIMARY KEY (user_id, week_start)
);
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS console_keys (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  pubkey TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS locations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  aliases TEXT NOT NULL DEFAULT '[]',
  status TEXT NOT NULL DEFAULT 'approved',
  requested_by INTEGER,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS schedule_template (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  day TEXT NOT NULL,
  slot TEXT NOT NULL,
  start_at TEXT NOT NULL,
  end_at TEXT NOT NULL,
  location_key TEXT NOT NULL,
  max_people INTEGER,
  capacity_group TEXT
);
CREATE TABLE IF NOT EXISTS schedule_overrides (
  weekend_start TEXT NOT NULL,
  day TEXT NOT NULL,
  slot TEXT NOT NULL,
  start_at TEXT NOT NULL,
  end_at TEXT NOT NULL,
  location_key TEXT NOT NULL,
  max_people INTEGER,
  capacity_group TEXT,
  PRIMARY KEY (weekend_start, day, slot, location_key)
);
''');
    // Schedule settings are durable and seeded once. The transaction keeps a
    // restart from exposing only part of the schedule. The four historical
    // time keys are deliberately retained; weekday keys are additive so old
    // databases keep their custom times.
    db.execute('BEGIN IMMEDIATE');
    try {
      String hour(int value) => '${value.toString().padLeft(2, '0')}:00';
      final defaults = {
        ...ScheduleTimes.defaultSettings,
        ScheduleTimes.promptKey: hour(config.promptHour),
        ScheduleTimes.reminderKey: hour(config.reminderHour),
        ScheduleTimes.lockKey: hour(config.deadlineHour),
        ScheduleTimes.checkerKey: hour(config.checkerHour),
      };
      for (final entry in defaults.entries) {
        db.execute(
          'INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)',
          [entry.key, entry.value],
        );
      }
      for (final key in defaultActiveOutreachRouteKeys) {
        db.execute(
          'INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)',
          ['active_outreach_$key', '1'],
        );
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    // Column migrations for databases created before session max limits existed.
    for (final table in ['sessions', 'schedule_template', 'schedule_overrides']) {
      try {
        db.execute('ALTER TABLE $table ADD COLUMN max_people INTEGER');
      } catch (_) {
        // column already present
      }
      try {
        db.execute('ALTER TABLE $table ADD COLUMN capacity_group TEXT');
      } catch (_) {
        // column already present
      }
    }
    // Column migration for databases created before member_tier existed.
    try {
      db.execute(
        "ALTER TABLE users ADD COLUMN member_tier TEXT NOT NULL DEFAULT 'member'",
      );
    } catch (_) {
      // column already present
    }
    // Global-admin state was added after the original users table. Keep the
    // migration idempotent for existing databases.
    final userColumnsAfterTier = db
        .select('PRAGMA table_info(users)')
        .map((row) => row['name'] as String)
        .toSet();
    if (!userColumnsAfterTier.contains('is_global_admin')) {
      db.execute(
        'ALTER TABLE users ADD COLUMN is_global_admin INTEGER NOT NULL '
        'DEFAULT 0 CHECK (is_global_admin IN (0, 1))',
      );
    }
    db.execute('''
CREATE UNIQUE INDEX IF NOT EXISTS users_one_global_admin
  ON users (is_global_admin) WHERE is_global_admin = 1
''');
    db.execute('''
CREATE TRIGGER IF NOT EXISTS users_role_exclusive_insert
BEFORE INSERT ON users
WHEN NEW.is_admin = 1 AND NEW.is_global_admin = 1
BEGIN
  SELECT RAISE(ABORT, 'a user cannot be both admin and global admin');
END;
''');
    db.execute('''
CREATE TRIGGER IF NOT EXISTS users_role_exclusive_update
BEFORE UPDATE OF is_admin, is_global_admin ON users
WHEN NEW.is_admin = 1 AND NEW.is_global_admin = 1
BEGIN
  SELECT RAISE(ABORT, 'a user cannot be both admin and global admin');
END;
''');
    // Explicit one-time v2 bootstrap: only the configured console's
    // pre-existing normal-admin role is converted automatically. The marker
    // prevents a later restart from inferring a replacement after removal.
    final migrationDone = db.select(
      "SELECT 1 FROM settings WHERE key = 'global_admin_migration_v2'",
    ).isNotEmpty;
    if (!migrationDone) {
      final hasGlobalAdmin = db.select(
        'SELECT 1 FROM users WHERE is_global_admin = 1 LIMIT 1',
      ).isNotEmpty;
      if (!hasGlobalAdmin) {
        db.execute(
          'UPDATE users SET is_admin = 0, is_global_admin = 1 '
          'WHERE id = ? AND is_admin = 1',
          [config.consoleId],
        );
      }
      db.execute(
        "INSERT INTO settings (key, value) VALUES "
        "('global_admin_migration_v2', '1')",
      );
    }
    // Profile fields for databases created before they existed. The legacy
    // fields remain for compatibility but are no longer collected or shown.
    final userColumns = db
        .select('PRAGMA table_info(users)')
        .map((row) => row['name'] as String)
        .toSet();
    for (final col in [
      'full_name',
      'preferred_name',
      'matric_no',
      'school_email',
    ]) {
      if (!userColumns.contains(col)) {
        db.execute("ALTER TABLE users ADD COLUMN $col TEXT NOT NULL DEFAULT ''");
        userColumns.add(col);
      }
    }
    // Notification scheduling state was added for the v4 role/storage model.
    // Check PRAGMA first so opening the same database repeatedly is harmless.
    for (final (column, definition) in [
      ('notification_preference', "TEXT NOT NULL DEFAULT 'weekly'"),
      ('last_prompt_state', "TEXT NOT NULL DEFAULT 'none'"),
    ]) {
      if (!userColumns.contains(column)) {
        db.execute(
          'ALTER TABLE users ADD COLUMN $column $definition',
        );
        userColumns.add(column);
      }
    }
    // Per-slot commitment: the sessions a member *wants* to attend, separate
    // from the ones they can attend if needed (availability.slots). Databases
    // created before the split only have `slots`.
    try {
      db.execute("ALTER TABLE availability ADD COLUMN want_slots TEXT NOT NULL DEFAULT '[]'");
    } catch (_) {
      // column already present
    }
    // Pending users can be queued directly as a tier (e.g. `check` from the
    // console's "Add check"), not only as plain members.
    try {
      db.execute("ALTER TABLE pending_users ADD COLUMN tier TEXT NOT NULL DEFAULT 'member'");
    } catch (_) {
      // column already present
    }
    final pendingColumns = db
        .select('PRAGMA table_info(pending_users)')
        .map((row) => row['name'] as String)
        .toSet();
    if (!pendingColumns.contains('notification_preference')) {
      db.execute(
        "ALTER TABLE pending_users ADD COLUMN notification_preference "
        "TEXT NOT NULL DEFAULT 'weekly'",
      );
    }
    // Exact send time is audit data, not part of the daily deduplication key.
    // Historical rows predate this column, so their timestamp remains unknown.
    final sentMessageColumns = db
        .select('PRAGMA table_info(sent_messages)')
        .map((row) => row['name'] as String)
        .toSet();
    if (!sentMessageColumns.contains('sent_at')) {
      db.execute('ALTER TABLE sent_messages ADD COLUMN sent_at TEXT');
    }
    // Groups are now numeric (1, 2, ...) and led by admins. One-time data
    // migration from the legacy letter groups; idempotent.
    db.execute("UPDATE users SET group_id = '1' WHERE group_id = 'A'");
    db.execute("UPDATE users SET group_id = '2' WHERE group_id = 'B'");
    // Rolling-model migration: databases created before the weekend-keyed
    // sessions/availability/allocations/attendance must be rebuilt.
    _migrateWeekendModel(db);
    // Dynamic locations (added in v3): seed the two built-in ones once, with
    // their common aliases. A console can add more later (with aliases).
    for (final (key, name, aliases) in [
      ('ocbc', 'OCBC', '["ocbc arena","arena"]'),
      ('pasirRis', 'Pasir Ris', '["pr","pasir","pasir ris","pasir-ris"]'),
    ]) {
      db.execute(
        "INSERT OR IGNORE INTO locations (key, name, aliases, status) "
        "VALUES (?, ?, ?, 'approved')",
        [key, name, aliases],
      );
    }
    // Seed the schedule template from the configured slot windows on first
    // run, so behaviour is unchanged until a global admin sets a new list. A
    // template the gadmin has set is never overwritten.
    final templateCount =
        db.select('SELECT COUNT(*) AS n FROM schedule_template').first['n']
            as int;
    if (templateCount == 0) {
      final am = config.slotTimes['am']!;
      final pm = config.slotTimes['pm']!;
      for (final (slot, times) in [('am', am), ('pm', pm)]) {
        for (final loc in ['ocbc', 'pasirRis']) {
          db.execute(
            'INSERT INTO schedule_template '
            '(day, slot, start_at, end_at, location_key) VALUES (?, ?, ?, ?, ?)',
            ['sat', slot, times.$1, times.$2, loc],
          );
        }
      }
    }
    // Drop sessions that no longer belong to the template (rows left over from
    // the Saturday-only or fixed-AM/PM models), so they never surface in the
    // pickers again. Dependent allocation/attendance rows go first.
    const staleSessions = '''
NOT EXISTS (
  SELECT 1 FROM schedule_template t
  WHERE t.day = sessions.day AND t.slot = sessions.slot
    AND t.location_key = sessions.location
 ) AND NOT EXISTS (
   SELECT 1 FROM schedule_overrides o
   WHERE o.weekend_start = sessions.weekend_start
     AND o.day = sessions.day AND o.slot = sessions.slot
     AND o.location_key = sessions.location
 )''';
    db.execute(
      'DELETE FROM allocations WHERE session_id IN '
      '(SELECT id FROM sessions WHERE $staleSessions)',
    );
    db.execute(
      'DELETE FROM attendance WHERE session_id IN '
      '(SELECT id FROM sessions WHERE $staleSessions)',
    );
    db.execute('DELETE FROM sessions WHERE $staleSessions');
  }
}
