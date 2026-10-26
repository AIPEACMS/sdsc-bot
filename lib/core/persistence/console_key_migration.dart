part of '../db.dart';

void _migrateConsoleKeySchema(sqlite.Database db) {
  final columns = db
      .select('PRAGMA table_info(console_keys)')
      .map((row) => row['name'] as String)
      .toSet();
  for (final (column, definition) in [
    ('actor_user_id', 'INTEGER REFERENCES users(id)'),
    ('bind_challenge_hash', 'TEXT'),
    ('bind_challenge_expires_at', 'TEXT'),
  ]) {
    if (!columns.contains(column)) {
      db.execute('ALTER TABLE console_keys ADD COLUMN $column $definition');
      columns.add(column);
    }
  }
  db.execute('''
CREATE TABLE IF NOT EXISTS attendance_correction_previews (
  token_hash TEXT PRIMARY KEY,
  console_key_id INTEGER NOT NULL REFERENCES console_keys(id),
  actor_user_id INTEGER NOT NULL REFERENCES users(id),
  target_user_id INTEGER NOT NULL REFERENCES users(id),
  scope TEXT NOT NULL CHECK (scope IN ('all', 'group')),
  delta INTEGER NOT NULL,
  requested_last_attended_date TEXT,
  expected_session_count INTEGER NOT NULL,
  expected_balance INTEGER NOT NULL,
  expected_effective_date TEXT,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
)''');
}
