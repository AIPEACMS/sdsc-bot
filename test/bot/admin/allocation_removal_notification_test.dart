import 'dart:convert';
import 'dart:io';

import 'package:sdsc_bot/bot/flows.dart';
import 'package:sdsc_bot/bot/service.dart';
import 'package:sdsc_bot/bot/settime.dart';
import 'package:sdsc_bot/bot/state.dart';
import 'package:sdsc_bot/core/config.dart';
import 'package:sdsc_bot/core/db.dart';
import 'package:sdsc_bot/core/messages.dart';
import 'package:sdsc_bot/core/models.dart';
import 'package:sdsc_bot/core/repo.dart';
import 'package:televerse/telegram.dart' show Update;
import 'package:televerse/televerse.dart';
import 'package:test/test.dart';
import '../../support/bot_readiness.dart';
import '../../support/test_helpers.dart';

void main() {
  late Directory temp;
  late Database db;
  late Repo repo;
  late Config config;
  late Bot bot;
  late HttpServer server;
  late BotReadiness readiness;
  late Future<void> botFuture;
  final sent = <Map<String, dynamic>>[];
  final edited = <Map<String, dynamic>>[];
  var nextUpdateId = 1;
  var nextCallbackId = 0;

  Future<void> json(HttpRequest request, Map<String, Object?> body) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  setUp(() async {
    Config.setDebugNow(DateTime.utc(2026, 9, 16, 4));
    temp = Directory.systemTemp.createTempSync('allocation_removal_notice_');
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
    nextUpdateId = 1;
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
        final isEdit = path.endsWith('/editMessageText');
        (isEdit ? edited : sent).add(body);
        final failsForRecipient =
            !isEdit &&
            body['chat_id'] == 3 &&
            (body['text'] as String).contains(
              'Your allocation has been removed',
            );
        if (failsForRecipient) {
          request.response.statusCode = HttpStatus.badRequest;
          await json(request, {
            'ok': false,
            'error_code': HttpStatus.badRequest,
            'description': 'Bad Request: chat not found',
          });
        } else {
          await json(request, {
            'ok': true,
            'result': {
              'message_id': sent.length + edited.length,
              'date': 1,
              'chat': {'id': body['chat_id'], 'type': 'private'},
              'text': body['text'],
            },
          });
        }
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
    final setTime = SetTime(
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
        name: '@notified',
        experience: Experience.newbie,
        group: '1',
      ),
    );
    repo.upsertUser(
      const User(
        id: 3,
        name: '@failed\nInjected',
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

  Future<void> command(String value) => bot.handleUpdate(
    Update.fromJson({
      'update_id': nextUpdateId++,
      'message': {
        'message_id': 1,
        'date': 1,
        'chat': {'id': 1, 'type': 'private'},
        'from': {'id': 1, 'is_bot': false, 'first_name': 'operator'},
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
        'from': {'id': 1, 'is_bot': false, 'first_name': 'operator'},
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

  Future<void> confirmRemoval() async {
    final window = RollingWindow.forDate(config.toLocal(Config.nowUtc()));
    final sessions = repo.sessionsForWeekend(window.sat0).take(2).toList();
    repo.replaceAllocationsForWeekend(window.sat0, [
      for (final userId in [2, 3])
        for (final session in sessions) (userId, session.id),
    ]);
    await command('/rm_allocate_entry');
    for (final userId in [2, 3]) {
      for (final session in sessions) {
        await callback('rmalloc|toggle|${session.id}|$userId');
      }
    }
    await callback('rmalloc|preview');
    await callback('rmalloc|confirm');
  }

  test(
    'confirmation separates successful notices from failed recipients',
    () async {
      await confirmRemoval();

      final confirmation = edited.last;
      final text = confirmation['text'] as String;
      expect(text, contains('Removed 4 allocation(s).'));
      expect(
        text,
        contains('These people are notified of the removal: @notified.'),
      );
      expect(
        text,
        contains(
          'Please remember to notify them if you haven\'t: @failed Injected.',
        ),
      );
      expect(text, isNot(contains('@failed\nInjected')));
      expect(confirmation, isNot(contains('parse_mode')));
      expect(
        sent.where(
          (message) =>
              message['chat_id'] == 2 &&
              (message['text'] as String).contains(
                'Your allocation has been removed',
              ),
        ),
        hasLength(1),
      );
      expect(
        sent.where(
          (message) =>
              message['chat_id'] == 3 &&
              (message['text'] as String).contains(
                'Your allocation has been removed',
              ),
        ),
        hasLength(1),
      );
    },
  );

  test(
    'disabled route reminds about every affected recipient without notices',
    () async {
      repo.setActiveOutreach('schedule-change', false);
      await confirmRemoval();

      final confirmation = edited.last;
      final text = confirmation['text'] as String;
      expect(text, contains('Removed 4 allocation(s).'));
      expect(
        text,
        isNot(contains('These people are notified of the removal:')),
      );
      expect(
        text,
        contains(
          'Please remember to notify them if you haven\'t: @notified, @failed Injected.',
        ),
      );
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
}
