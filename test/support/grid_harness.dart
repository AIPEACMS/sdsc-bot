import 'dart:convert';
import 'dart:io';

import 'package:televerse/telegram.dart' show Update;
import 'package:televerse/televerse.dart';
import 'package:test/test.dart';
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
import '../test_helpers.dart';

late Directory tmp;
late Database db;
late Repo repo;
late Config config;
late Messages messages;
late BotState state;
late CycleService service;
late Flows flows;
late Admin admin;
late Console console;
late HoldGate holdGate;
late List<Map<String, dynamic>> sent;
late List<Map<String, dynamic>> edited;
late HttpServer server;
late Bot bot;

Future<void> setUpGrid() async {
  tmp = Directory.systemTemp.createTempSync('sdsc_grid_');
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
  state = BotState();
  sent = <Map<String, dynamic>>[];
  edited = <Map<String, dynamic>>[];
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
          'username': 'sdsc_attendence_bot',
        },
      });
    } else if (path.endsWith('/getUpdates')) {
      await _json(req, {'ok': true, 'result': <dynamic>[]});
    } else if (path.endsWith('/sendMessage')) {
      final body = jsonDecode(await utf8.decoder.bind(req).join());
      sent.add(body as Map<String, dynamic>);
      await _json(req, {
        'ok': true,
        'result': {
          'message_id': 1,
          'date': 1,
          'chat': {'id': 1, 'type': 'private'},
          'text': body['text'],
        },
      });
    } else if (path.endsWith('/editMessageReplyMarkup')) {
      final body = jsonDecode(await utf8.decoder.bind(req).join());
      edited.add(body as Map<String, dynamic>);
      await _json(req, {
        'ok': true,
        'result': {
          'message_id': 1,
          'date': 1,
          'chat': {'id': 1, 'type': 'private'},
          'text': '',
        },
      });
    } else if (path.endsWith('/answerCallbackQuery')) {
      await _json(req, {'ok': true, 'result': true});
    } else if (path.endsWith('/editMessageText')) {
      final body = jsonDecode(await utf8.decoder.bind(req).join());
      edited.add(body as Map<String, dynamic>);
      await _json(req, {
        'ok': true,
        'result': {
          'message_id': 1,
          'date': 1,
          'chat': {'id': 1, 'type': 'private'},
          'text': body['text'],
        },
      });
    } else {
      await _json(req, {'ok': false, 'error': 'nf'}, status: 404);
    }
  });

  bot = Bot.local('test-token', 'http://127.0.0.1:${server.port}');
  service = CycleService(
    repo: repo,
    config: config,
    messages: messages,
    state: state,
    bot: bot,
  );
  flows = Flows(
    bot: bot,
    repo: repo,
    config: config,
    messages: messages,
    state: state,
    service: service,
  );
  admin = Admin(
    bot: bot,
    repo: repo,
    config: config,
    state: state,
    service: service,
  );
  flows.onAddUserText = admin.onAddUserText;
  holdGate = HoldGate(false);
  console = Console(
    bot: bot,
    repo: repo,
    config: config,
    state: state,
    holdGate: holdGate,
  );
  flows.register();
  admin.register();
  console.register();

  repo.upsertUser(User(
    id: 1,
    name: '@console',
    experience: Experience.experienced,
    group: '1',
  ));
  repo.updateAdmin(1, true);
  expect(repo.appointGlobalAdmin(1), GlobalAdminResult.success);
  repo.upsertUser(User(
    id: 2,
    name: '@admin',
    experience: Experience.experienced,
    group: '1',
  ));
  repo.updateAdmin(2, true);
  repo.upsertUser(User(
    id: 3,
    name: '@checker',
    experience: Experience.newbie,
    group: '',
    memberTier: MemberTier.check,
  ));
  repo.upsertUser(User(
    id: 4,
    name: '@out-member',
    experience: Experience.newbie,
    group: '1',
    memberTier: MemberTier.outMember,
  ));

  final w = RollingWindow.forDate(config.toLocal(Config.nowUtc()));
  repo.ensureSessionsForWeekend(
    w.sat0,
    defaultTemplate(),
    tzOffsetHours: config.timezoneOffsetHours,
  );
  repo.ensureSessionsForWeekend(
    w.sat1,
    defaultTemplate(),
    tzOffsetHours: config.timezoneOffsetHours,
  );
  final s0 = repo.sessionsForWeekend(w.sat0);
  final s1 = repo.sessionsForWeekend(w.sat1);
  repo.replaceAllocationsForWeekend(w.sat0, [(2, s0[0].id)]);
  repo.replaceAllocationsForWeekend(w.sat1, [(3, s1[0].id)]);
  repo.setAttendanceState(2, s0[0].id, attended: true);
  repo.setAttendanceState(2, s1[0].id, attended: true);

  final startFuture = bot.start();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  addTearDown(() async {
    await bot.stop();
    await startFuture;
    await server.close(force: true);
    db.close();
    tmp.deleteSync(recursive: true);
  });
}

Future<void> sendText(int userId, String text, {String? username}) =>
    bot.handleUpdate(Update.fromJson({
  'update_id': 1,
  'message': {
    'message_id': 1,
    'date': 1,
    'chat': {'id': userId, 'type': 'private'},
    'from': {
      'id': userId,
      'is_bot': false,
      'first_name': 'u',
      ...?(username == null ? null : {'username': username}),
    },
    'text': text,
    'entities': [
      {
        'offset': 0,
        'length': text.contains(' ') ? text.indexOf(' ') : text.length,
        'type': 'bot_command',
      },
    ],
  },
}));

Future<void> sendPlainText(int userId, String text) => bot.handleUpdate(
      Update.fromJson({
        'update_id': 3,
        'message': {
          'message_id': 1,
          'date': 1,
          'chat': {'id': userId, 'type': 'private'},
          'from': {'id': userId, 'is_bot': false, 'first_name': 'u'},
          'text': text,
        },
      }),
    );

Future<void> sendCallback(int userId, String data) => bot.handleUpdate(
      Update.fromJson({
        'update_id': 2,
        'callback_query': {
          'id': 'callback-$userId-$data',
          'from': {'id': userId, 'is_bot': false, 'first_name': 'u'},
          'chat_instance': 'test-chat-instance',
          'message': {
            'message_id': 1,
            'date': 1,
            'chat': {'id': userId, 'type': 'private'},
          },
          'data': data,
        },
      }),
    );

List<String> keyboardTexts(Map<String, dynamic> body) {
  final kb = (body['reply_markup'] as Map<String, dynamic>?)?['keyboard'];
  if (kb == null) return const [];
  return [
    for (final row in kb as List)
      for (final b in row as List) (b as Map)['text'] as String,
  ];
}

Future<void> _json(HttpRequest req, Object body, {int status = 200}) async {
  req.response.statusCode = status;
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode(body));
  await req.response.close();
}
