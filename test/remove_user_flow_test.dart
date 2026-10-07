import 'dart:convert';
import 'dart:io';

import 'package:sdsc_bot/bot/calendar_sync.dart';
import 'package:sdsc_bot/bot/console.dart';
import 'package:sdsc_bot/bot/flows.dart';
import 'package:sdsc_bot/bot/hold.dart';
import 'package:sdsc_bot/bot/service.dart';
import 'package:sdsc_bot/bot/state.dart';
import 'package:sdsc_bot/core/config.dart';
import 'package:sdsc_bot/core/db.dart';
import 'package:sdsc_bot/core/messages.dart';
import 'package:sdsc_bot/core/models.dart';
import 'package:sdsc_bot/core/repo.dart';
import 'package:televerse/telegram.dart' show Update;
import 'package:televerse/televerse.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Database db;
  late Repo repo;
  late Bot<Context> bot;
  late HttpServer server;
  late Future<void> botStart;
  late List<Map<String, dynamic>> sent;
  late List<Map<String, dynamic>> edited;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sdsc_remove_flow_');
    final config = Config(
      botToken: 'test',
      dbPath: '${tmp.path}/test.db',
      consoleId: 99,
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
    final state = BotState();
    sent = [];
    edited = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final path = req.uri.path;
      if (path.endsWith('/getMe')) {
        await _json(req, {
          'ok': true,
          'result': {
            'id': 1,
            'is_bot': true,
            'first_name': 'test',
            'username': 'test_bot',
          },
        });
      } else if (path.endsWith('/getUpdates')) {
        await _json(req, {'ok': true, 'result': <dynamic>[]});
      } else if (path.endsWith('/sendMessage')) {
        final body = jsonDecode(await utf8.decoder.bind(req).join());
        sent.add((body as Map).cast<String, dynamic>());
        await _json(req, {
          'ok': true,
          'result': {
            'message_id': sent.length,
            'date': 1,
            'chat': {'id': body['chat_id'], 'type': 'private'},
            'text': body['text'],
          },
        });
      } else if (path.endsWith('/editMessageText')) {
        final body = jsonDecode(await utf8.decoder.bind(req).join());
        edited.add((body as Map).cast<String, dynamic>());
        await _json(req, {
          'ok': true,
          'result': {
            'message_id': 1,
            'date': 1,
            'chat': {'id': body['chat_id'] ?? 1, 'type': 'private'},
            'text': body['text'],
          },
        });
      } else if (path.endsWith('/answerCallbackQuery')) {
        await _json(req, {'ok': true, 'result': true});
      } else {
        await _json(req, {'ok': false, 'error': 'nf'}, status: 404);
      }
    });

    bot = Bot.local('test-token', 'http://127.0.0.1:${server.port}');
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
    final console = Console(
      bot: bot,
      repo: repo,
      config: config,
      state: state,
      calendarSync: CalendarSync(repo: repo, config: config),
      holdGate: HoldGate(false),
    );
    flows.register();
    console.register();
    flows.onRemoveUserText = console.onRemoveUserText;
    flows.onPendingInputCleared = (userId, command) {
      if (command == 'removeuser') console.onRemoveUserInputCleared(userId);
    };

    repo.upsertUser(
      const User(
        id: 1,
        name: '@gadmin',
        experience: Experience.experienced,
        group: '1',
      ),
    );
    repo.appointGlobalAdmin(1);
    repo.upsertSeenUser(2, 'alice');
    repo.upsertUser(
      const User(
        id: 2,
        name: '@alice',
        experience: Experience.newbie,
        group: '1',
      ),
    );
    repo.addPendingUser('never_started', isAdmin: false);

    botStart = bot.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });

  tearDown(() async {
    await bot.stop();
    await botStart;
    await server.close(force: true);
    db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<void> sendText(String text) => bot.handleUpdate(
    Update.fromJson({
      'update_id': sent.length + edited.length + 1,
      'message': {
        'message_id': 1,
        'date': 1,
        'chat': {'id': 1, 'type': 'private'},
        'from': {
          'id': 1,
          'is_bot': false,
          'first_name': 'gadmin',
          'username': 'gadmin',
        },
        'text': text,
        if (text.startsWith('/'))
          'entities': [
            {
              'offset': 0,
              'length': text.split(RegExp(r'\s+')).first.length,
              'type': 'bot_command',
            },
          ],
      },
    }),
  );

  Future<void> sendCallback(String data) => bot.handleUpdate(
    Update.fromJson({
      'update_id': 99,
      'callback_query': {
        'id': 'callback',
        'from': {'id': 1, 'is_bot': false, 'first_name': 'gadmin'},
        'chat_instance': 'x',
        'data': data,
        'message': {
          'message_id': sent.length,
          'date': 1,
          'chat': {'id': 1, 'type': 'private'},
          'text': 'confirmation',
        },
      },
    }),
  );

  test('removeuser validates the batch then confirms and removes it', () async {
    await sendText('/removeuser');
    await sendText('@alice\n@never_started');
    expect(sent.last['text'], contains('@alice'));
    expect(repo.findUser(2)!.memberTier, MemberTier.member);
    expect(repo.isPendingUser('never_started'), true);

    await sendCallback('removeuser|yes');
    expect(repo.findUser(2)!.memberTier, MemberTier.old);
    expect(repo.findUser(2)!.group, isEmpty);
    expect(repo.isPendingUser('never_started'), false);
    expect(edited.last['text'], contains('Removed'));
    expect(edited.last['reply_markup'], isNull);
  });

  test(
    'an unknown handle aborts the whole batch with the exact reply',
    () async {
      await sendText('/removeuser');
      await sendText('@alice @missing');
      expect(sent.last['text'], '@missing is not found');
      expect(repo.findUser(2)!.memberTier, MemberTier.member);
      expect(repo.isPendingUser('never_started'), true);
    },
  );

  test(
    'cancel clears the confirmation and demote clears pending admin role',
    () async {
      await sendText('/removeuser');
      await sendText('@alice');
      await sendCallback('removeuser|no');
      expect(repo.findUser(2)!.memberTier, MemberTier.member);

      repo.addPendingUser('queued_admin', isAdmin: true);
      await sendText('/demote @queued_admin');
      expect(repo.pendingIsAdmin('queued_admin'), false);
    },
  );
}

Future<void> _json(
  HttpRequest req,
  Map<String, dynamic> body, {
  int status = 200,
}) async {
  req.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  await req.response.close();
}
