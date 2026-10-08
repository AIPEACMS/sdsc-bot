import 'dart:io';

import 'package:sdsc_bot/sdsc_bot.dart';

late Directory tmp;
late Database db;
late Repo repo;

void setUpRepo() {
  tmp = Directory.systemTemp.createTempSync('sdsc_test_');
  db = Database.open(Config(
    botToken: 'test',
    dbPath: '${tmp.path}/test.db',
    consoleId: 1,
    groupAContact: 'TBD',
    groupBContact: 'TBD',
    ocbcCapacity: 2,
    prCapacity: 20,
    slotTimes: {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
    promptHour: 18,
    reminderHour: 18,
    deadlineHour: 18,
    allocationHour: 9,
    bailHour: 12,
    timezoneOffsetHours: 8,
  ));
  repo = Repo(db);
}

void tearDownRepo() {
  db.close();
  tmp.deleteSync(recursive: true);
}

User addUser(
  int id, {
  Experience exp = Experience.newbie,
  String group = 'A',
}) {
  final u = User(
    id: id,
    name: 'Member $id',
    experience: exp,
    group: group,
    ocbcStreak: 0,
  );
  repo.upsertUser(u);
  return repo.findUser(id)!;
}
