import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'config.dart';

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
  group_id TEXT NOT NULL DEFAULT 'A',
  is_admin INTEGER NOT NULL DEFAULT 0,
  ocbc_streak INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
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

CREATE TABLE IF NOT EXISTS sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  cycle_id INTEGER NOT NULL REFERENCES cycles(id),
  weekend_index INTEGER NOT NULL,
  day TEXT NOT NULL,
  slot TEXT NOT NULL,
  location TEXT NOT NULL,
  start_at TEXT NOT NULL,
  end_at TEXT NOT NULL,
  UNIQUE(cycle_id, weekend_index, day, slot, location)
);

CREATE TABLE IF NOT EXISTS availability (
  cycle_id INTEGER NOT NULL REFERENCES cycles(id),
  user_id INTEGER NOT NULL REFERENCES users(id),
  slots TEXT NOT NULL DEFAULT '[]',
  available INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (cycle_id, user_id)
);

CREATE TABLE IF NOT EXISTS allocations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  cycle_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL,
  session_id INTEGER NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(cycle_id, user_id, session_id)
);

CREATE TABLE IF NOT EXISTS attendance (
  user_id INTEGER NOT NULL REFERENCES users(id),
  session_id INTEGER NOT NULL REFERENCES sessions(id),
  confirmed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id, session_id)
);

CREATE TABLE IF NOT EXISTS holidays (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  week_start TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL
);
''');
  }

  void close() => _db.close();
}
