import 'dart:io';

import 'package:sdsc_bot/sdsc_bot.dart';

late Directory tmp;
late Database db;
late Repo repo;
late Config config;
late Messages messages;

void setUpRepick() {
  Config.setDebugNow(DateTime.utc(2026, 8, 17));
  tmp = Directory.systemTemp.createTempSync('sdsc_repick_');
  config = Config(
    botToken: 'test',
    dbPath: '${tmp.path}/test.db',
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
  db = Database.open(config);
  repo = Repo(db);
  messages = Messages(
    (group) => repo.groupAdmin(group)?.name ?? config.contactForGroup(group),
  );
}

void tearDownRepick() {
  Config.setDebugNow(null);
  db.close();
  tmp.deleteSync(recursive: true);
}
