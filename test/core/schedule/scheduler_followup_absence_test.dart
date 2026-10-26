import 'dart:async';
import 'dart:convert';
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
import '../../support/test_helpers.dart';

void main() {
  late _SchedulerHarness harness;

  setUp(() async {
    harness = _SchedulerHarness();
    await harness.open();
  });

  tearDown(() async {
    await harness.close();
  });

  test(
    'custom Tuesday attendance follow-up uses the completed Saturday block',
    () async {
      final anchor = DateTime(2026, 10, 17);
      harness.addAdminAndMember();
      harness.repo.ensureSessionsForWeekend(
        anchor,
        defaultTemplate(),
        tzOffsetHours: 8,
      );
      final session = harness.repo.sessionsForWeekend(anchor).first;
      harness.repo.replaceAllocationsForWeekend(anchor, [(2, session.id)]);
      harness.repo.writeSchedule(
        _schedule(
          attendanceFollowup: const ScheduleEvent(
            weekday: 'tue',
            time: LocalWallClock(11, 30),
          ),
          absence: const ScheduleEvent(
            weekday: 'mon',
            time: LocalWallClock(8, 0),
          ),
        ),
      );

      Config.setDebugNow(DateTime.utc(2026, 10, 27, 3)); // Tue 11:00 local.
      var scheduler = harness.newScheduler();
      scheduler.start(interval: const Duration(days: 1));
      expect(scheduler.nextMilestone, DateTime(2026, 10, 27, 11, 30));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      scheduler.stop();

      Config.setDebugNow(DateTime.utc(2026, 10, 27, 3, 30)); // Tue 11:30 local.
      scheduler = harness.newScheduler();
      scheduler.start(interval: const Duration(days: 1));
      await harness.firstSend.future.timeout(const Duration(seconds: 5));
      await harness.waitForMark('attmark', DateTime(2026, 10, 27));

      expect(harness.sent, hasLength(1));
      expect(harness.sent.single['chat_id'], 1);
      expect(harness.sent.single['text'], contains('@member'));
      expect(
        harness.repo.messageSentOnDay(1, 'attmark', DateTime(2026, 10, 27)),
        isTrue,
      );
    },
  );

  test(
    'custom Monday absence event uses Saturday October 17, not October 24',
    () async {
      harness.addAdminAndMember();
      harness.repo.raw.execute('UPDATE users SET created_at = ? WHERE id = ?', [
        '2026-09-01 00:00:00',
        2,
      ]);
      for (final saturday in [
        DateTime(2026, 9, 26),
        DateTime(2026, 10, 3),
        DateTime(2026, 10, 10),
        DateTime(2026, 10, 17),
      ]) {
        harness.repo.ensureSessionsForWeekend(
          saturday,
          defaultTemplate(),
          tzOffsetHours: 8,
        );
      }
      harness.repo.setActiveOutreach('prompt', false);
      harness.repo.writeSchedule(
        _schedule(
          attendanceFollowup: const ScheduleEvent(
            weekday: 'tue',
            time: LocalWallClock(11, 30),
          ),
          absence: const ScheduleEvent(
            weekday: 'mon',
            time: LocalWallClock(15, 45),
          ),
        ),
      );

      Config.setDebugNow(DateTime.utc(2026, 10, 26, 7)); // Mon 15:00 local.
      var scheduler = harness.newScheduler();
      scheduler.start(interval: const Duration(days: 1));
      expect(scheduler.nextMilestone, DateTime(2026, 10, 26, 15, 45));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      scheduler.stop();

      Config.setDebugNow(DateTime.utc(2026, 10, 26, 7, 45)); // Mon 15:45 local.
      scheduler = harness.newScheduler();
      scheduler.start(interval: const Duration(days: 1));
      await harness.firstSend.future.timeout(const Duration(seconds: 5));
      await harness.waitForMark('absent', DateTime(2026, 10, 26));

      expect(harness.sent, hasLength(1));
      expect(harness.sent.single['chat_id'], 1);
      expect(harness.sent.single['text'], contains('@member — 4 weeks'));
      expect(harness.sent.single['text'], isNot(contains('5 weeks')));
      expect(
        harness.repo.messageSentOnDay(1, 'absent', DateTime(2026, 10, 26)),
        isTrue,
      );
    },
  );
}

ScheduleTimes _schedule({
  required ScheduleEvent attendanceFollowup,
  required ScheduleEvent absence,
}) => ScheduleTimes(
  prompt: const ScheduleEvent(weekday: 'mon', time: LocalWallClock(9, 0)),
  reminder: const ScheduleEvent(weekday: 'tue', time: LocalWallClock(14, 0)),
  lock: const ScheduleEvent(weekday: 'wed', time: LocalWallClock(18, 0)),
  checker: const ScheduleEvent(weekday: 'thu', time: LocalWallClock(21, 0)),
  attendanceInitial: const ScheduleEvent(
    weekday: 'sun',
    time: LocalWallClock(20, 0),
  ),
  attendanceFollowup: attendanceFollowup,
  absence: absence,
);

class _SchedulerHarness {
  late Directory temp;
  late Config config;
  late Database db;
  late Repo repo;
  late HttpServer server;
  late CycleService service;
  late Completer<void> firstSend;
  Scheduler? scheduler;
  final sent = <Map<String, dynamic>>[];

  Future<void> open() async {
    temp = Directory.systemTemp.createTempSync('sdsc_scheduler_followup_');
    config = Config(
      botToken: 'test',
      dbPath: '${temp.path}/test.db',
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
    firstSend = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final isSend = request.uri.path.endsWith('/sendMessage');
      final body = isSend
          ? jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>
          : <String, dynamic>{};
      if (isSend) sent.add(body);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'ok': true,
          'result': isSend
              ? {
                  'message_id': sent.length,
                  'date': 1,
                  'chat': {'id': body['chat_id'], 'type': 'private'},
                  'text': body['text'],
                }
              : true,
        }),
      );
      await request.response.close();
      if (isSend && !firstSend.isCompleted) firstSend.complete();
    });
    final bot = Bot.local('test-token', 'http://127.0.0.1:${server.port}');
    service = CycleService(
      repo: repo,
      config: config,
      messages: Messages(config.contactForGroup),
      state: BotState(),
      bot: bot,
    );
  }

  void addAdminAndMember() {
    repo.upsertUser(
      User(
        id: 1,
        name: '@admin',
        experience: Experience.experienced,
        group: '1',
        isAdmin: true,
      ),
    );
    repo.upsertUser(
      User(id: 2, name: '@member', experience: Experience.newbie, group: '1'),
    );
  }

  Scheduler newScheduler() => scheduler = Scheduler(
    repo: repo,
    config: config,
    service: service,
    scheduleRuntime: ScheduleRuntime(repo: repo, config: config),
  );

  Future<void> waitForMark(String kind, DateTime day) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      if (repo.messageSentOnDay(1, kind, day)) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> close() async {
    scheduler?.stop();
    Config.setDebugNow(null);
    await server.close(force: true);
    db.close();
    temp.deleteSync(recursive: true);
  }
}
