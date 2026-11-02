part of '../db.dart';

void _migrateSessionReminderDeliverySchema(sqlite.Database db) {
  final columns = db
      .select('PRAGMA table_info(session_reminder_deliveries)')
      .map((row) => row['name'] as String)
      .toSet();
  if (!columns.contains('delivery_state')) {
    db.execute(
      "ALTER TABLE session_reminder_deliveries ADD COLUMN "
      "delivery_state TEXT NOT NULL DEFAULT 'uncertain'",
    );
  }
  if (!columns.contains('retry_at')) {
    db.execute(
      'ALTER TABLE session_reminder_deliveries ADD COLUMN retry_at TEXT',
    );
  }
}
