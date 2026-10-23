import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:televerse/televerse.dart';
import 'package:televerse/telegram.dart' show Update;
import 'package:sdsc_bot/bot/service.dart';
import 'package:sdsc_bot/bot/settime.dart';
import 'package:sdsc_bot/bot/state.dart';
import 'package:sdsc_bot/bot/flows.dart';
import 'package:sdsc_bot/core/config.dart';
import 'package:sdsc_bot/core/db.dart';
import 'package:sdsc_bot/core/messages.dart';
import 'package:sdsc_bot/core/models.dart';
import 'package:sdsc_bot/core/repo.dart';
import '../../support/test_helpers.dart';
import '../../support/bot_readiness.dart';

void main() {
  late Directory temp;
  late Database db;
  late Repo repo;
  late Config config;
  late Bot bot;
  late SetTime setTime;
  late HttpServer server;
  late BotReadiness readiness;
  late Future<void> botFuture;
  final sent = <Map<String, dynamic>>[];
  final edited = <Map<String, dynamic>>[];
  var nextUpdateId = 10;
  var nextCallbackId = 0;

  Future<void> json(HttpRequest request, Map<String, Object?> body) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  setUp(() async {
    Config.setDebugNow(DateTime.utc(2026, 9, 16, 4));
    temp = Directory.systemTemp.createTempSync('allocation_removal_');
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
    sent.clear();
    edited.clear();
    nextUpdateId = 10;
    nextCallbackId = 0;
    readiness = BotReadiness();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      readiness.observe(request);
      final path = request.uri.path;
      if (path.endsWith('/getMe')) {
        await json(request, {
          'ok': true,
          'result': {
            'id': 1,
            'is_bot': true,
            'first_name': 'test',
            'username': 'test_bot',
          },
        });
      } else if (path.endsWith('/getUpdates')) {
        await json(request, {'ok': true, 'result': <dynamic>[]});
      } else if (path.endsWith('/sendMessage') ||
          path.endsWith('/editMessageText')) {
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        (path.endsWith('/sendMessage') ? sent : edited).add(body);
        await json(request, {
          'ok': true,
          'result': {
            'message_id': sent.length + edited.length,
            'date': 1,
            'chat': {'id': body['chat_id'], 'type': 'private'},
            'text': body['text'],
          },
        });
      } else if (path.endsWith('/answerCallbackQuery')) {
        await json(request, {'ok': true, 'result': true});
      } else {
        await json(request, {'ok': true, 'result': true});
      }
    });
    bot = Bot.local('test-token', 'http://127.0.0.1:${server.port}');
    final state = BotState();
    final messages = Messages((group) => config.contactForGroup(group));
    final service = CycleService(
      repo: repo,
      config: config,
      messages: messages,
      state: state,
      bot: bot,
    );
    final flows = Flows(
      bot: bot,
      repo: repo,
      config: config,
      messages: messages,
      state: state,
      service: service,
    );
    flows.register();
    setTime = SetTime(
      bot: bot,
      repo: repo,
      config: config,
      state: state,
      service: service,
    );
    setTime.register();
    flows.onSetTimeText = setTime.onText;
    repo.upsertUser(
      const User(
        id: 1,
        name: '@gadmin',
        experience: Experience.experienced,
        group: '1',
      ),
    );
    repo.appointGlobalAdmin(1);
    repo.upsertUser(
      const User(
        id: 2,
        name: '@member',
        experience: Experience.newbie,
        group: '1',
      ),
    );
    final window = RollingWindow.forDate(config.toLocal(Config.nowUtc()));
    repo.ensureSessionsForWeekend(
      window.sat0,
      defaultTemplate(),
      tzOffsetHours: 8,
    );
    botFuture = bot.start();
    await readiness.wait();
  });

  tearDown(() async {
    await bot.stop();
    await botFuture;
    await server.close(force: true);
    db.close();
    temp.deleteSync(recursive: true);
    Config.setDebugNow(null);
  });

  Future<void> text(int id, String value) => bot.handleUpdate(
    Update.fromJson({
      'update_id': nextUpdateId++,
      'message': {
        'message_id': 1,
        'date': 1,
        'chat': {'id': id, 'type': 'private'},
        'from': {'id': id, 'is_bot': false, 'first_name': 'u'},
        'text': value,
        'entities': [
          {
            'offset': 0,
            'length': value.split(' ').first.length,
            'type': 'bot_command',
          },
        ],
      },
    }),
  );

  Future<void> callback(String value) => bot.handleUpdate(
    Update.fromJson({
      'update_id': nextUpdateId++,
      'callback_query': {
        'id': '${++nextCallbackId}',
        'from': {'id': 1, 'is_bot': false, 'first_name': 'u'},
        'chat_instance': 'x',
        'data': value,
        'message': {
          'message_id': 1,
          'date': 1,
          'chat': {'id': 1, 'type': 'private'},
          'text': 'previous',
        },
      },
    }),
  );

  test(
    '/rm_allocate_entry selects, previews, confirms and cancels locked-week allocations',
    () async {
      final window = RollingWindow.forDate(config.toLocal(Config.nowUtc()));
      final sessions = repo.sessionsForWeekend(window.sat0).take(2).toList();
      final picks = {
        for (final session in sessions)
          Slot(0, session.day, session.slot, session.location),
      };
      repo.replaceAllocationsForWeekend(window.sat0, [
        for (final session in sessions) (2, session.id),
      ]);
      repo.setAvailability(
        Availability(
          weekendStart: window.sat0,
          userId: 2,
          bundleStart: window.sat0,
          slots: picks,
          available: true,
          updatedAt: DateTime(2026, 9, 10),
        ),
      );
      Config.setDebugNow(DateTime.utc(2026, 9, 18, 12));
      await text(1, '/rm_allocate_entry');
      expect(sent.last['text'], contains('including locked dates'));
      await callback('rmalloc|toggle|${sessions.first.id}|2');
      await callback('rmalloc|preview');
      expect(edited.last['text'], contains('@member'));
      await callback('rmalloc|cancel');
      expect(edited.last['reply_markup'], isNull);
      expect(repo.allocationsForWeekend(window.sat0), hasLength(2));
      Config.setDebugNow(DateTime.utc(2026, 9, 16, 4));
      await text(1, '/rm_allocate_entry');
      for (final session in sessions) {
        await callback('rmalloc|toggle|${session.id}|2');
      }
      await callback('rmalloc|preview');
      await callback('rmalloc|confirm');
      expect(repo.allocationsForWeekend(window.sat0), isEmpty);
      expect(edited.last['reply_markup'], isNull);
      expect(repo.getAvailability(window.sat0, 2)?.slots, isEmpty);
      String sessionLabel(Session session) =>
          '${session.start.year}-'
          '${session.start.month.toString().padLeft(2, '0')}-'
          '${session.start.day.toString().padLeft(2, '0')} '
          '${repo.locationName(session.location)} · '
          '${Slot.dayName(session.day)} '
          '${session.start.hour.toString().padLeft(2, '0')}:'
          '${session.start.minute.toString().padLeft(2, '0')}-'
          '${session.end.hour.toString().padLeft(2, '0')}:'
          '${session.end.minute.toString().padLeft(2, '0')}';
      final notices = sent.where(
        (message) =>
            message['chat_id'] == 2 &&
            (message['text'] as String).contains(
              'Your allocation has been removed',
            ),
      );
      expect(notices, hasLength(1));
      expect(notices.single['text'], contains(sessionLabel(sessions.first)));
      expect(notices.single['text'], contains(sessionLabel(sessions.last)));
      expect(
        notices.single['text'],
        contains('Your other allocations are unchanged.'),
      );
    },
  );

  test(
    'settime removal preview and notification follow the schedule-change route',
    () async {
      final window = RollingWindow.forDate(config.toLocal(Config.nowUtc()));
      final sessions = repo.sessionsForWeekend(window.sat0);
      repo.replaceAllocationsForWeekend(window.sat0, [
        (2, sessions[0].id),
        (2, sessions[1].id),
      ]);
      repo.setAttendanceState(2, sessions[0].id, attended: true);
      await text(1, '/settime');
      await callback('settime-scope|persistent');
      await callback('settime-action|rewrite');
      await text(1, 'sun 10 12 ocbc');
      await text(1, 'done');
      expect(sent.last['text'], contains('These allocations will be removed:'));
      expect(
        sent.last['text'],
        contains('They WILL be notified of the allocation removal.'),
      );
      await callback('settime|yes');
      final notices = sent.where(
        (message) =>
            message['chat_id'] == 2 &&
            (message['text'] as String).contains(
              'Your allocation has been removed',
            ),
      );
      expect(notices, hasLength(1));
      expect(
        notices.single['text'],
        contains('Your other allocations are unchanged.'),
      );
    },
  );

  test(
    'temporary removal preserves a later session allocation despite slot renumbering',
    () async {
      final window = RollingWindow.forDate(config.toLocal(Config.nowUtc()));
      final sessions = repo.sessionsForWeekend(window.sat0);
      final removedSession = sessions.first;
      final unchangedSession = sessions.last;
      repo.replaceAllocationsForWeekend(window.sat0, [
        (2, removedSession.id),
        (2, unchangedSession.id),
      ]);

      await text(1, '/settime');
      await callback('settime-scope|temporary');
      await callback('settime-action|remove');
      await callback('settime-week|2026-09-19');
      await callback('settime-remove|0');
      await callback('settime-remove|done');
      expect(sent.last['text'], contains('@member'));
      await callback('settime|yes');

      expect(repo.sessionById(removedSession.id), isNull);
      expect(
        repo.sessionsForWeekend(window.sat0).map((session) => session.id),
        contains(unchangedSession.id),
      );
      expect(
        repo
            .allocationsForWeekend(window.sat0)
            .map((entry) => (entry.$1.id, entry.$2.id)),
        contains((2, unchangedSession.id)),
      );
    },
  );

  test(
    'settime route OFF warns and sends no allocation-removal notice',
    () async {
      final window = RollingWindow.forDate(config.toLocal(Config.nowUtc()));
      repo.replaceAllocationsForWeekend(window.sat0, [
        (2, repo.sessionsForWeekend(window.sat0).first.id),
      ]);
      repo.setActiveOutreach('schedule-change', false);
      await text(1, '/settime');
      await callback('settime-scope|persistent');
      await callback('settime-action|rewrite');
      await text(1, 'sun 10 12 ocbc');
      await text(1, 'done');
      expect(
        sent.last['text'],
        contains(
          'They will NOT be automatically notified, if needed, please tell them personally',
        ),
      );
      await callback('settime|yes');
      expect(
        sent.where(
          (message) => (message['text'] as String).contains(
            'Your allocation has been removed',
          ),
        ),
        isEmpty,
      );
    },
  );

  test(
    'settime overlap choice replaces its buttons with confirmation',
    () async {
      await text(1, '/settime');
      await text(1, 'sat 9 13 ocbc');
      await text(1, 'sat 9 15 ocbc');
      await text(1, 'done');
      expect(sent.last['text'], contains('Overlapping sessions found'));

      await callback('settime-conflict|same');
      expect(edited.last['text'], contains('Before change:'));
      final markup = edited.last['reply_markup'] as Map<String, dynamic>;
      final callbacks = (markup['inline_keyboard'] as List)
          .expand((row) => row as List)
          .map((button) => (button as Map)['callback_data'] as String)
          .toList();
      expect(callbacks, isNot(contains('settime-conflict|same')));
    },
  );
}
