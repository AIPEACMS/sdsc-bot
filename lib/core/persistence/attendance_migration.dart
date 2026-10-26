part of '../db.dart';

void _createAttendanceBalanceTriggers(sqlite.Database db) {
  db.execute('''
CREATE TRIGGER IF NOT EXISTS attendance_balance_insert
AFTER INSERT ON attendance WHEN NEW.attended = 1
BEGIN
  UPDATE users SET
    attendance_balance = attendance_balance + 1,
    last_attended_date = NULLIF(MAX(
      COALESCE(manual_last_attended_date, ''),
      COALESCE((SELECT MAX(substr(s.start_at, 1, 10))
        FROM attendance a JOIN sessions s ON s.id = a.session_id
        WHERE a.user_id = users.id AND a.attended = 1), '')
    ), '')
  WHERE id = NEW.user_id;
END;
CREATE TRIGGER IF NOT EXISTS attendance_balance_update
AFTER UPDATE OF attended ON attendance
WHEN OLD.attended <> NEW.attended
BEGIN
  UPDATE users SET
    attendance_balance = attendance_balance + NEW.attended - OLD.attended,
    last_attended_date = NULLIF(MAX(
      COALESCE(manual_last_attended_date, ''),
      COALESCE((SELECT MAX(substr(s.start_at, 1, 10))
        FROM attendance a JOIN sessions s ON s.id = a.session_id
        WHERE a.user_id = users.id AND a.attended = 1), '')
    ), '')
  WHERE id = NEW.user_id;
END;
CREATE TRIGGER IF NOT EXISTS attendance_balance_delete
AFTER DELETE ON attendance WHEN OLD.attended = 1
BEGIN
  UPDATE users SET
    attendance_balance = attendance_balance - 1,
    last_attended_date = NULLIF(MAX(
      COALESCE(manual_last_attended_date, ''),
      COALESCE((SELECT MAX(substr(s.start_at, 1, 10))
        FROM attendance a JOIN sessions s ON s.id = a.session_id
        WHERE a.user_id = users.id AND a.attended = 1), '')
    ), '')
  WHERE id = OLD.user_id;
END;
''');
}

void _migrateSentMessageColumns(sqlite.Database db) {
  final columns = db
      .select('PRAGMA table_info(sent_messages)')
      .map((row) => row['name'] as String)
      .toSet();
  if (!columns.contains('sent_at')) {
    db.execute('ALTER TABLE sent_messages ADD COLUMN sent_at TEXT');
  }
  if (!columns.contains('telegram_message_id')) {
    db.execute(
      'ALTER TABLE sent_messages ADD COLUMN telegram_message_id INTEGER',
    );
  }
  if (!columns.contains('message_id_update_attempted')) {
    db.execute(
      'ALTER TABLE sent_messages ADD COLUMN '
      'message_id_update_attempted INTEGER NOT NULL DEFAULT 0',
    );
  }
}

void _migrateAttendanceSummary(sqlite.Database db) {
  final migrationDone = db
      .select(
        "SELECT 1 FROM settings WHERE key = 'attendance_balance_migration_v1'",
      )
      .isNotEmpty;
  if (migrationDone) return;
  db.execute('''
UPDATE users SET
 attendance_balance = (SELECT COUNT(*) FROM attendance a
   WHERE a.user_id = users.id AND a.attended = 1),
 last_attended_date = (SELECT MAX(substr(s.start_at, 1, 10))
   FROM attendance a JOIN sessions s ON s.id = a.session_id
   WHERE a.user_id = users.id AND a.attended = 1)
''');
  db.execute(
    "INSERT INTO settings (key, value) VALUES "
    "('attendance_balance_migration_v1', '1')",
  );
}
