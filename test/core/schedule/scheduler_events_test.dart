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
  test(
    'configured attendance events run and retain durable attmark dedup',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'sdsc_scheduler_events_',
      );
      final config = Config(
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
      final db = Database.open(config);
      final repo = Repo(db);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sent = <Map<String, dynamic>>[];
      final firstSend = Completer<void>();
      server.listen((request) async {
        final path = request.uri.path;
        if (path.endsWith('/sendMessage')) {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, dynamic>;
          sent.add(body);
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'ok': true,
              'result': {
                'message_id': sent.length,
                'date': 1,
                'chat': {'id': body['chat_id'], 'type': 'private'},
                'text': body['text'],
              },
            }),
          );
          await request.response.close();
          if (!firstSend.isCompleted) firstSend.complete();
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'ok': true, 'result': true}));
          await request.response.close();
        }
      });

      final bot = Bot.local('test-token', 'http://127.0.0.1:${server.port}');
      final messages = Messages(config.contactForGroup);
      final service = CycleService(
        repo: repo,
        config: config,
        messages: messages,
        state: BotState(),
        bot: bot,
      );
      Scheduler? scheduler;
      try {
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
          User(
            id: 2,
            name: '@member',
            experience: Experience.newbie,
            group: '1',
          ),
        );
        final completedSaturday = DateTime(2026, 10, 17);
        repo.ensureSessionsForWeekend(
          completedSaturday,
          defaultTemplate(),
          tzOffsetHours: 8,
        );
        final session = repo.sessionsForWeekend(completedSaturday).first;
        repo.replaceAllocationsForWeekend(completedSaturday, [(2, session.id)]);
        repo.writeSchedule(
          const ScheduleTimes(
            prompt: ScheduleEvent(weekday: 'mon', time: LocalWallClock(18, 0)),
            reminder: ScheduleEvent(
              weekday: 'thu',
              time: LocalWallClock(18, 0),
            ),
            lock: ScheduleEvent(weekday: 'fri', time: LocalWallClock(18, 0)),
            checker: ScheduleEvent(weekday: 'fri', time: LocalWallClock(21, 0)),
            attendanceInitial: ScheduleEvent(
              weekday: 'sun',
              time: LocalWallClock(20, 0),
            ),
            attendanceFollowup: ScheduleEvent(
              weekday: 'mon',
              time: LocalWallClock(20, 0),
            ),
            absence: ScheduleEvent(weekday: 'mon', time: LocalWallClock(8, 0)),
          ),
        );
        Config.setDebugNow(DateTime.utc(2026, 10, 25, 12));
        scheduler = Scheduler(
          repo: repo,
          config: config,
          service: service,
          scheduleRuntime: ScheduleRuntime(repo: repo, config: config),
        );
        scheduler.start(interval: const Duration(days: 1));

        await firstSend.future.timeout(const Duration(seconds: 5));
        await _waitForMessageMarker(repo, 1, 'attmark', DateTime(2026, 10, 25));
        expect(sent, hasLength(1));
        expect(sent.single['chat_id'], 1);
        expect(sent.single['text'], contains('@member'));
        expect(
          repo.messageSentOnDay(1, 'attmark', DateTime(2026, 10, 25)),
          isTrue,
        );
        expect(scheduler.nextMilestone, DateTime(2026, 10, 26, 8));

        await scheduler.stopAndWait();
        Config.setDebugNow(DateTime.utc(2026, 10, 25, 13));
        scheduler = Scheduler(
          repo: repo,
          config: config,
          service: service,
          scheduleRuntime: ScheduleRuntime(repo: repo, config: config),
        );
        scheduler.start(interval: const Duration(days: 1));
        await scheduler.stopAndWait();
        expect(sent, hasLength(1));
      } finally {
        await scheduler?.stopAndWait();
        Config.setDebugNow(null);
        await server.close(force: true);
        db.close();
        temp.deleteSync(recursive: true);
      }
    },
  );
}

Future<void> _waitForMessageMarker(
  Repo repo,
  int userId,
  String kind,
  DateTime day,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (repo.messageSentOnDay(userId, kind, day)) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(repo.messageSentOnDay(userId, kind, day), isTrue);
}
