import 'dart:convert';
import 'dart:io';

import 'package:sdsc_bot/bot/admin.dart';
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
import 'package:televerse/televerse.dart';
import 'package:televerse/telegram.dart' show Update;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Database db;
  late Repo repo;
  late BotState state;
  late Bot bot;
  late HttpServer server;
  late List<Map<String, dynamic>> sent;
  late List<Map<String, dynamic>> edited;
  late Future<void> botStart;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sdsc_assign_flow_');
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
    db = Database.open(config);
    repo = Repo(db);
    state = BotState();
    sent = [];
    edited = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      if (path.endsWith('/getMe')) {
        await _json(request, {
          'ok': true,
          'result': {
            'id': 1,
            'is_bot': true,
            'first_name': 'test',
            'username': 'test_bot',
          },
        });
      } else if (path.endsWith('/getUpdates')) {
        await _json(request, {'ok': true, 'result': <dynamic>[]});
      } else if (path.endsWith('/sendMessage')) {
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        sent.add(body);
        await _message(request, body);
      } else if (path.endsWith('/editMessageReplyMarkup')) {
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        edited.add(body);
        await _message(request, body);
      } else if (path.endsWith('/editMessageText')) {
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        edited.add(body);
        await _message(request, body);
      } else if (path.endsWith('/answerCallbackQuery')) {
        await _json(request, {'ok': true, 'result': true});
      } else {
        await _json(request, {'ok': false}, status: 404);
      }
    });

    bot = Bot.local('test-token', 'http://127.0.0.1:${server.port}');
    final service = CycleService(
      repo: repo,
      config: config,
      messages: Messages((group) => repo.groupAdmin(group)?.name ?? 'leader'),
      state: state,
      bot: bot,
    );
    final flows = Flows(
      bot: bot,
      repo: repo,
      config: config,
      messages: Messages((group) => repo.groupAdmin(group)?.name ?? 'leader'),
      state: state,
      service: service,
    );
    final admin = Admin(
      bot: bot,
      repo: repo,
      config: config,
      state: state,
      service: service,
    );
    final console = Console(
      bot: bot,
      repo: repo,
      config: config,
      state: state,
      holdGate: HoldGate(false),
    );
    flows.onAssignGroupText = console.onAssignGroupText;
    flows.onPendingInputCleared = (id, command) {
      if (command == 'assigngroup-members') {
        console.onAssignGroupInputCleared(id);
      }
    };
    flows.register();
    admin.register();
    console.register();

    repo.upsertSeenUser(2, 'gadmin');
    repo.upsertUser(
      User(
        id: 2,
        name: '@gadmin',
        preferredName: 'Global <Admin>',
        experience: Experience.experienced,
        group: '10',
        isGlobalAdmin: true,
      ),
    );
    repo.upsertSeenUser(3, 'leader');
    repo.upsertUser(
      User(
        id: 3,
        name: '@leader',
        experience: Experience.experienced,
        group: '2',
        isAdmin: true,
      ),
    );
    repo.upsertSeenUser(4, 'member');
    repo.upsertUser(
      User(id: 4, name: '@member', experience: Experience.newbie, group: ''),
    );
    repo.upsertSeenUser(5, 'checker');
    repo.upsertUser(
      User(
        id: 5,
        name: '@checker',
        experience: Experience.newbie,
        group: '',
        memberTier: MemberTier.check,
      ),
    );

    botStart = bot.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    addTearDown(() async {
      await bot.stop();
      await botStart;
      await server.close(force: true);
      db.close();
      tmp.deleteSync(recursive: true);
    });
  });

  Future<void> text(int userId, String value) => bot.handleUpdate(
    Update.fromJson({
      'update_id': DateTime.now().microsecondsSinceEpoch,
      'message': {
        'message_id': 1,
        'date': 1,
        'chat': {'id': userId, 'type': 'private'},
        'from': {'id': userId, 'is_bot': false, 'first_name': 'user'},
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

  Future<void> plain(int userId, String value) => bot.handleUpdate(
    Update.fromJson({
      'update_id': DateTime.now().microsecondsSinceEpoch,
      'message': {
        'message_id': 1,
        'date': 1,
        'chat': {'id': userId, 'type': 'private'},
        'from': {'id': userId, 'is_bot': false, 'first_name': 'user'},
        'text': value,
      },
    }),
  );

  Future<void> callback(int userId, String data) => bot.handleUpdate(
    Update.fromJson({
      'update_id': DateTime.now().microsecondsSinceEpoch,
      'callback_query': {
        'id': 'callback-${DateTime.now().microsecondsSinceEpoch}',
        'from': {'id': userId, 'is_bot': false, 'first_name': 'user'},
        'chat_instance': 'test',
        'message': {
          'message_id': 1,
          'date': 1,
          'chat': {'id': userId, 'type': 'private'},
        },
        'data': data,
      },
    }),
  );

  test(
    'selector and auto preview are inline and confirmation applies exact preview',
    () async {
      await text(2, '/assigngroup');
      expect(
        sent.last['text'],
        'Which group do you want to assign the member(s) to?',
      );
      final selector = sent.last['reply_markup'] as Map<String, dynamic>;
      expect(selector['inline_keyboard'], isNotEmpty);
      expect((selector['keyboard']), isNull);

      await callback(2, 'assigngroup|select|auto');
      expect(edited.any((body) => body['reply_markup'] == null), isTrue);
      expect(sent.last['text'], contains('@member'));
      expect(repo.findUser(4)!.group, isEmpty);
      await callback(2, 'assigngroup|yes');
      expect(repo.findUser(4)!.group, '2');
      expect(edited.last['reply_markup'], isNull);
      expect(state.pendingArg, isEmpty);
    },
  );

  test(
    'manual input skips ineligible handles and dismisses entry markup',
    () async {
      await text(2, '/assigngroup');
      await callback(2, 'assigngroup|select|2');
      expect(sent.last['text'], contains('Please send me the handle(s)'));
      expect(sent.last['reply_markup'], isNotNull);
      await plain(2, '@member\n@checker @unknown');
      expect(edited.any((body) => body['reply_markup'] == null), isTrue);
      expect(
        sent.last['text'],
        contains('@checker is not a member, skipping.'),
      );
       expect(
         sent.last['text'],
         contains(
           'Please confirm you want to assign these members to group 2 '
           'under leader @leader:',
         ),
       );
      await callback(2, 'assigngroup|yes');
      expect(repo.findUser(4)!.group, '2');
      expect(edited.last['reply_markup'], isNull);
    },
  );

  test(
    'unauthorized callback is answered and clears its inline keyboard',
    () async {
      await text(2, '/assigngroup');
      await callback(4, 'assigngroup|select|auto');
      expect(edited.last['reply_markup'], isNull);
      expect(edited.last['text'], 'You are not the global admin.');
      expect(repo.findUser(4)!.group, isEmpty);
    },
  );

  test('stale confirmation clears its keyboard and applies nothing', () async {
    await text(2, '/assigngroup');
    await callback(2, 'assigngroup|select|auto');
    repo.setGroup(4, '99');
    await callback(2, 'assigngroup|yes');
    expect(repo.findUser(4)!.group, '99');
    expect(edited.last['reply_markup'], isNull);
    expect(
      edited.last['text'],
      'The group assignment changed; nothing was assigned.',
    );
    expect(state.pendingArg, isEmpty);
  });
}

Future<void> _json(HttpRequest request, Object body, {int status = 200}) async {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(body));
  await request.response.close();
}

Future<void> _message(HttpRequest request, Map<String, dynamic> body) =>
    _json(request, {
      'ok': true,
      'result': {
        'message_id': 1,
        'date': 1,
        'chat': {'id': body['chat_id'] ?? 1, 'type': 'private'},
        'text': body['text'] ?? '',
      },
    });
