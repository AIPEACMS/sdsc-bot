import 'dart:convert';

import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'config.dart';
import 'models.dart';
import 'week.dart';

class Database {
  Database._(this._db);

  final sqlite.Database _db;

  /// Opens (creating if needed) the SQLite database and applies the schema.
  factory Database.open(Config config) {
    final db = sqlite.sqlite3.open(config.dbPath);
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute('PRAGMA journal_mode = WAL;');
    _applySchema(db);
    return Database._(db);
  }

  sqlite.Database get raw => _db;

  static void _applySchema(sqlite.Database db) {
    db.execute('''
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  experience TEXT NOT NULL DEFAULT 'newbie',
  group_id TEXT NOT NULL DEFAULT '',
  is_admin INTEGER NOT NULL DEFAULT 0,
  ocbc_streak INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  member_tier TEXT NOT NULL DEFAULT 'member'
);

CREATE TABLE IF NOT EXISTS sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  weekend_start TEXT NOT NULL,
  day TEXT NOT NULL,
  slot TEXT NOT NULL,
  location TEXT NOT NULL,
  start_at TEXT NOT NULL,
  end_at TEXT NOT NULL,
  UNIQUE(weekend_start, day, slot, location)
);

CREATE TABLE IF NOT EXISTS availability (
  weekend_start TEXT NOT NULL,
  user_id INTEGER NOT NULL REFERENCES users(id),
  bundle_start TEXT NOT NULL,
  slots TEXT NOT NULL DEFAULT '[]',
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
  is_admin INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS sent_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users(id),
  kind TEXT NOT NULL,
  day TEXT NOT NULL,
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
''');

    // Column migration for databases created before member_tier existed.
    try {
      db.execute(
        "ALTER TABLE users ADD COLUMN member_tier TEXT NOT NULL DEFAULT 'member'",
      );
    } catch (_) {
      // column already present
    }

    // Groups are now numeric (1, 2, ...) and led by admins. One-time data
    // migration from the legacy letter groups; idempotent.
    db.execute("UPDATE users SET group_id = '1' WHERE group_id = 'A'");
    db.execute("UPDATE users SET group_id = '2' WHERE group_id = 'B'");

    // Rolling-model migration: databases created before the weekend-keyed
    // sessions/availability/allocations/attendance must be rebuilt.
    _migrateWeekendModel(db);
  }

  /// One-time migration from the legacy cycle-keyed model (sessions keyed by
  /// cycle_id + weekend_index, availability/allocations by cycle_id,
  /// attendance without an absent state) to the weekend-keyed rolling model.
  static void _migrateWeekendModel(sqlite.Database db) {
    final cols = db
        .select('PRAGMA table_info(sessions)')
        .map((r) => r['name'] as String)
        .toList();
    if (cols.contains('weekend_start')) return; // already migrated (or fresh)

    // The rebuild renames/drops tables that others reference by FK — foreign
    // key enforcement must be off for the duration (a controlled migration).
    db.execute('PRAGMA foreign_keys = OFF;');
    try {
      _migrateWeekendModelInner(db);
    } finally {
      db.execute('PRAGMA foreign_keys = ON;');
    }
  }

  static void _migrateWeekendModelInner(sqlite.Database db) {

    // 1. Attach weekend_start to the legacy sessions via their cycle.
    db.execute('ALTER TABLE sessions ADD COLUMN weekend_start TEXT');
    final cycles = db.select(
      'SELECT id, block_week, block_year FROM cycles',
    );
    final cycleWeek = <int, (int, int)>{};
    for (final c in cycles) {
      cycleWeek[c['id'] as int] =
          (c['block_week'] as int, c['block_year'] as int);
    }
    final legacy = db.select('SELECT id, cycle_id, weekend_index FROM sessions');
    for (final s in legacy) {
      final (week, year) = cycleWeek[s['cycle_id'] as int] ?? (1, 2026);
      final sat = WeekMath.saturdayOfWeek(week + (s['weekend_index'] as int), year);
      db.execute(
        'UPDATE sessions SET weekend_start = ? WHERE id = ?',
        [_dayKey(sat), s['id'] as int],
      );
    }

    // 2. Rebuild sessions (drop the cycle linkage).
    db.execute('ALTER TABLE sessions RENAME TO sessions_old');
    db.execute('''
CREATE TABLE sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  weekend_start TEXT NOT NULL,
  day TEXT NOT NULL,
  slot TEXT NOT NULL,
  location TEXT NOT NULL,
  start_at TEXT NOT NULL,
  end_at TEXT NOT NULL,
  UNIQUE(weekend_start, day, slot, location)
);
''');
    db.execute('''
INSERT INTO sessions (id, weekend_start, day, slot, location, start_at, end_at)
SELECT id, weekend_start, day, slot, location, start_at, end_at FROM sessions_old
''');
    db.execute('DROP TABLE sessions_old');

    // 3. Rebuild availability: one row per bundle weekend, bundle_start =
    // the cycle's first weekend. A legacy bundle row becomes two rows (one
    // per weekend) with only that weekend's picks.
    final avRows = db.select(
      'SELECT a.cycle_id, a.user_id, a.slots, a.available, a.updated_at, '
      'c.block_week, c.block_year FROM availability a '
      'JOIN cycles c ON c.id = a.cycle_id',
    );
    db.execute('DROP TABLE availability');
    db.execute('''
CREATE TABLE availability (
  weekend_start TEXT NOT NULL,
  user_id INTEGER NOT NULL REFERENCES users(id),
  bundle_start TEXT NOT NULL,
  slots TEXT NOT NULL DEFAULT '[]',
  available INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (weekend_start, user_id)
);
''');
    for (final r in avRows) {
      final sat0 = WeekMath.saturdayOfWeek(
          r['block_week'] as int, r['block_year'] as int);
      final user = r['user_id'] as int;
      final available = (r['available'] as int) == 1;
      final updated = r['updated_at'] as String;
      final allSlots = Slot.decodeSet(r['slots'] as String);
      final weekend0 = allSlots.where((s) => s.weekendIndex == 0).toList();
      final weekend1 = allSlots.where((s) => s.weekendIndex == 1).toList();
      db.execute(
        'INSERT OR REPLACE INTO availability '
        '(weekend_start, user_id, bundle_start, slots, available, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [_dayKey(sat0), user, _dayKey(sat0), _encodeSlots(weekend0),
            available ? 1 : 0, updated],
      );
      db.execute(
        'INSERT OR REPLACE INTO availability '
        '(weekend_start, user_id, bundle_start, slots, available, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [_dayKey(sat0.add(const Duration(days: 7))), user, _dayKey(sat0),
            _encodeSlots(weekend1), available ? 1 : 0, updated],
      );
    }

    // 4. Rebuild allocations (drop the cycle linkage).
    db.execute('ALTER TABLE allocations RENAME TO allocations_old');
    db.execute('''
CREATE TABLE allocations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id INTEGER NOT NULL REFERENCES sessions(id),
  user_id INTEGER NOT NULL REFERENCES users(id),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(session_id, user_id)
);
''');
    db.execute('''
INSERT INTO allocations (id, session_id, user_id, created_at)
SELECT id, session_id, user_id, created_at FROM allocations_old
''');
    db.execute('DROP TABLE allocations_old');

    // 5. Rebuild attendance with an explicit attended flag (legacy rows were
    // all positive marks).
    db.execute('ALTER TABLE attendance RENAME TO attendance_old');
    db.execute('''
CREATE TABLE attendance (
  user_id INTEGER NOT NULL REFERENCES users(id),
  session_id INTEGER NOT NULL REFERENCES sessions(id),
  attended INTEGER NOT NULL DEFAULT 1,
  confirmed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id, session_id)
);
''');
    db.execute('''
INSERT INTO attendance (user_id, session_id, attended, confirmed_at)
SELECT user_id, session_id, 1, confirmed_at FROM attendance_old
''');
    db.execute('DROP TABLE attendance_old');
  }

  static String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static String _encodeSlots(Iterable<Slot> slots) =>
      jsonEncode(slots.map((s) => s.encode()).toList());

  void close() => _db.close();
}
