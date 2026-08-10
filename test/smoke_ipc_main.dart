import 'dart:io';

import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:sdsc_bot/bot/calendar_sync.dart';

/// Runs the real IPC server on a real DB, then exits. Used to smoke-test the
/// production cron path: calendar-sync.sh pushes to this, we verify the
/// holidays landed.
Future<void> main(List<String> args) async {
  final dbPath = args[0];
  final port = int.parse(args[1]);
  final token = args[2];

  final db = Database.open(Config(
    botToken: 'test',
    dbPath: dbPath,
    consoleId: 1,
    groupAContact: 'TBD',
    groupBContact: 'TBD',
    ocbcCapacity: 6,
    prCapacity: 20,
    slotTimes: {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
    promptHour: 8,
    reminderHour: 18,
    deadlineHour: 18,
    allocationHour: 9,
    bailHour: 12,
    timezoneOffsetHours: 8,
  ));
  final repo = Repo(db);
  final sync = CalendarSync(repo: repo, config: Config(
    botToken: 'test',
    dbPath: dbPath,
    consoleId: 1,
    groupAContact: 'TBD',
    groupBContact: 'TBD',
    ocbcCapacity: 6,
    prCapacity: 20,
    slotTimes: {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
    promptHour: 8,
    reminderHour: 18,
    deadlineHour: 18,
    allocationHour: 9,
    bailHour: 12,
    timezoneOffsetHours: 8,
  ));
  final server = CalendarIpcServer(sync: sync, token: token, port: port);
  await server.start();
  print('READY $port');
  await Future<void>.delayed(const Duration(seconds: 20));
  await server.stop();
  db.close();
  exit(0);
}
