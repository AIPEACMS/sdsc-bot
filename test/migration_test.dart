import 'dart:io';

import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:sdsc_bot/sdsc_bot.dart';

Config _config(String path) => Config(
      botToken: 'test',
      dbPath: path,
      consoleId: 1,
      groupAContact: 'TBD',
      groupBContact: 'TBD',
      ocbcCapacity: 2,
      prCapacity: 20,
      slotTimes: const {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
      promptHour: 8,
      reminderHour: 18,
      deadlineHour: 18,
      allocationHour: 9,
      bailHour: 12,
      timezoneOffsetHours: 8,
    );

void main() {
  test('a legacy cycle-keyed database migrates to the weekend-keyed model',
      () {
    final tmp = Directory.systemTemp.createTempSync('sdsc_mig_');
    final path = '${tmp.path}/old.db';

    // Build the pre-rolling schema exactly as it shipped before v1.7.0.
    final db = sqlite.sqlite3.open(path);
    db.execute('''
CREATE TABLE users (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  experience TEXT NOT NULL DEFAULT 'newbie',
  group_id TEXT NOT NULL DEFAULT 'A',
  is_admin INTEGER NOT NULL DEFAULT 0,
  ocbc_streak INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE cycles (
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
CREATE TABLE sessions (
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
CREATE TABLE availability (
  cycle_id INTEGER NOT NULL REFERENCES cycles(id),
  user_id INTEGER NOT NULL REFERENCES users(id),
  slots TEXT NOT NULL DEFAULT '[]',
  available INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (cycle_id, user_id)
);
CREATE TABLE allocations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  cycle_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL,
  session_id INTEGER NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(cycle_id, user_id, session_id)
);
CREATE TABLE attendance (
  user_id INTEGER NOT NULL REFERENCES users(id),
  session_id INTEGER NOT NULL REFERENCES sessions(id),
  confirmed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id, session_id)
);
CREATE TABLE holidays (id INTEGER PRIMARY KEY AUTOINCREMENT, week_start TEXT NOT NULL UNIQUE, kind TEXT NOT NULL);
CREATE TABLE seen_users (id INTEGER PRIMARY KEY, username TEXT NOT NULL);
CREATE TABLE pending_users (username TEXT PRIMARY KEY, is_admin INTEGER NOT NULL DEFAULT 0);
CREATE TABLE sent_messages (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, kind TEXT NOT NULL, day TEXT NOT NULL, UNIQUE(user_id, kind, day));
CREATE TABLE calendar_years (academic_year TEXT PRIMARY KEY, yaml TEXT NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE holiday_optouts (user_id INTEGER NOT NULL, week_start TEXT NOT NULL, PRIMARY KEY (user_id, week_start));
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE console_keys (id INTEGER PRIMARY KEY AUTOINCREMENT, pubkey TEXT NOT NULL UNIQUE, name TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
''');
    db.execute(
        "INSERT INTO users (id, name, group_id) VALUES (1, '@root', 'A')");
    db.execute(
        "INSERT INTO users (id, name, group_id) VALUES (2, '@member', 'B')");
    db.execute('''
INSERT INTO cycles (id, block_week, block_year, prompt_day, reminder_day, deadline, allocation_day)
VALUES (1, 33, 2026, '2026-08-10T08:00:00', '2026-08-13T18:00:00',
        '2026-08-14T18:00:00', '2026-08-14T19:00:00')
''');
    // Weekend 0 session (id 1) and weekend 1 session (id 2).
    db.execute('''
INSERT INTO sessions (id, cycle_id, weekend_index, day, slot, location, start_at, end_at)
VALUES (1, 1, 0, 'sat', 'am', 'ocbc', '2026-08-15T09:00:00', '2026-08-15T12:00:00'),
       (2, 1, 1, 'sat', 'am', 'ocbc', '2026-08-22T09:00:00', '2026-08-22T12:00:00')
''');
    db.execute(
        "INSERT INTO availability (cycle_id, user_id, slots, available) "
        "VALUES (1, 1, '[\"0:sat:am:ocbc\"]', 1)");
    db.execute('INSERT INTO allocations (cycle_id, user_id, session_id) '
        'VALUES (1, 1, 1)');
    db.execute('INSERT INTO attendance (user_id, session_id) VALUES (1, 1)');
    db.close();

    // Open with the current schema: the migration must rebuild everything.
    final database = Database.open(_config(path));
    final repo = Repo(database);

    // Sessions keep ids but carry weekend_start.
    final s1 = repo.sessionById(1)!;
    expect(s1.weekendStart, DateTime(2026, 8, 15));
    final s2 = repo.sessionById(2)!;
    expect(s2.weekendStart, DateTime(2026, 8, 22));

    // Availability: one row per bundle weekend, bundle_start = first weekend.
    final w0 = repo.getAvailability(DateTime(2026, 8, 15), 1)!;
    final w1 = repo.getAvailability(DateTime(2026, 8, 22), 1)!;
    expect(w0.bundleStart, DateTime(2026, 8, 15));
    expect(w0.slots.single.day, 'sat');
    expect(w1.available, true);
    expect(w1.slots, isEmpty); // weekend-1 picks lived in index 1 rows

    // Allocations keep the session linkage.
    final allocs = repo.allocationsForWeekend(DateTime(2026, 8, 15));
    expect(allocs, hasLength(1));
    expect(allocs.single.$1.id, 1);
    expect(allocs.single.$2.id, 1);

    // Attendance rows become positive marks.
    final marks = repo.attendanceForSession(1);
    expect(marks.single.attended, true);

    // Legacy letter groups migrated to numbers.
    expect(repo.findUser(1)!.group, '1');
    expect(repo.findUser(2)!.group, '2');

    database.close();
    tmp.deleteSync(recursive: true);
  });
}
