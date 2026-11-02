import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:test/test.dart';

Config _config(String path) => Config(
  botToken: 'test',
  dbPath: path,
  consoleId: 1,
  groupAContact: 'TBD',
  groupBContact: 'TBD',
  ocbcCapacity: 2,
  prCapacity: 20,
  slotTimes: const {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
  promptHour: 18,
  reminderHour: 18,
  deadlineHour: 18,
  allocationHour: 9,
  bailHour: 12,
  timezoneOffsetHours: 8,
);

void main() {
  test('fresh schema separates session-reminder from weekly reminder', () {
    final temp = Directory.systemTemp.createTempSync('sdsc_session_reminder_');
    final db = Database.open(_config('${temp.path}/fresh.db'));
    final repo = Repo(db);
    final columns = db.raw
        .select('PRAGMA table_info(session_reminder_deliveries)')
        .map((row) => row['name'] as String)
        .toSet();
    expect(columns, containsAll(['delivery_state', 'retry_at']));
    expect(repo.activeOutreach()['session-reminder'], isTrue);
    expect(repo.activeOutreach()['reminder'], isTrue);
    db.close();
    temp.deleteSync(recursive: true);
  });

  test(
    'legacy delivery ledger upgrades idempotently and keeps uncertainty',
    () {
      final temp = Directory.systemTemp.createTempSync('sdsc_old_reminder_');
      final path = '${temp.path}/old.db';
      final old = sqlite.sqlite3.open(path);
      old.execute('''
CREATE TABLE users (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  experience TEXT NOT NULL DEFAULT 'newbie',
  group_id TEXT NOT NULL DEFAULT '',
  is_admin INTEGER NOT NULL DEFAULT 0,
  ocbc_streak INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO users (id, name) VALUES (7, 'member');
CREATE TABLE session_reminder_deliveries (
  user_id INTEGER NOT NULL,
  session_id INTEGER NOT NULL,
  attempted_at TEXT NOT NULL,
  delivered_at TEXT,
  PRIMARY KEY (user_id, session_id)
);
INSERT INTO session_reminder_deliveries
  (user_id, session_id, attempted_at) VALUES (7, 12, '2027-02-05T10:00:00Z');
''');
      old.close();

      final first = Database.open(_config(path));
      final repo = Repo(first);
      expect(repo.findUser(7)!.sessionRemindersEnabled, isTrue);
      expect(
        first.raw
            .select(
              'SELECT delivery_state FROM session_reminder_deliveries '
              'WHERE user_id = 7 AND session_id = 12',
            )
            .single['delivery_state'],
        'uncertain',
      );
      repo.setSessionRemindersEnabled(7, false);
      repo.upsertUser(repo.findUser(7)!.copyWith(preferredName: 'Member'));
      expect(repo.findUser(7)!.sessionRemindersEnabled, isFalse);
      first.close();

      final second = Database.open(_config(path));
      expect(Repo(second).findUser(7)!.sessionRemindersEnabled, isFalse);
      expect(
        second.raw
            .select(
              'SELECT delivery_state FROM session_reminder_deliveries '
              'WHERE user_id = 7 AND session_id = 12',
            )
            .single['delivery_state'],
        'uncertain',
      );
      second.close();
      temp.deleteSync(recursive: true);
    },
  );
}
