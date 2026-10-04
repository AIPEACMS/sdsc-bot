import 'dart:io';

import 'package:sdsc_bot/bot/scheduler.dart';
import 'package:sdsc_bot/bot/service.dart';
import 'package:sdsc_bot/bot/state.dart';
import 'package:sdsc_bot/core/config.dart';
import 'package:sdsc_bot/core/db.dart';
import 'package:sdsc_bot/core/messages.dart';
import 'package:sdsc_bot/core/models.dart';
import 'package:sdsc_bot/core/repo.dart';
import 'package:sdsc_bot/core/schedule.dart';
import 'package:televerse/televerse.dart';
import 'package:test/test.dart';

void main() {
  test('schedule updates re-arm the scheduler one-shot milestone', () {
    final tmp = Directory.systemTemp.createTempSync('sdsc_scheduler_');
    final config = Config(
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
    final db = Database.open(config);
    final repo = Repo(db);
    final runtime = ScheduleRuntime(repo: repo, config: config);
    final service = CycleService(
      repo: repo,
      config: config,
      messages: Messages(config.contactForGroup),
      state: BotState(),
      bot: Bot.local('test', 'http://127.0.0.1:1'),
    );
    final scheduler = Scheduler(
      repo: repo,
      config: config,
      service: service,
      scheduleRuntime: runtime,
    );
    Config.setDebugNow(DateTime.utc(2026, 8, 10, 1));
    try {
      runtime.update(const ScheduleTimes(
        prompt: ScheduleEvent(weekday: 'mon', time: LocalWallClock(10, 0)),
        reminder: ScheduleEvent(weekday: 'thu', time: LocalWallClock(11, 0)),
        lock: ScheduleEvent(weekday: 'fri', time: LocalWallClock(19, 0)),
        checker: ScheduleEvent(weekday: 'fri', time: LocalWallClock(21, 0)),
      ));
      scheduler.start(interval: const Duration(days: 1));
      expect(scheduler.nextMilestone, DateTime(2026, 8, 10, 10));

      runtime.update(const ScheduleTimes(
        prompt: ScheduleEvent(weekday: 'tue', time: LocalWallClock(12, 0)),
        reminder: ScheduleEvent(weekday: 'wed', time: LocalWallClock(13, 0)),
        lock: ScheduleEvent(weekday: 'fri', time: LocalWallClock(19, 0)),
        checker: ScheduleEvent(weekday: 'fri', time: LocalWallClock(21, 0)),
      ));
      expect(scheduler.nextMilestone, DateTime(2026, 8, 11, 12));
    } finally {
      scheduler.stop();
      Config.setDebugNow(null);
      db.close();
      tmp.deleteSync(recursive: true);
    }
  });
}
