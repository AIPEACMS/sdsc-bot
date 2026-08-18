import 'dart:convert';
import 'dart:io';

import 'package:televerse/telegram.dart' show Update;
import 'package:televerse/televerse.dart';
import 'package:test/test.dart';

import 'package:sdsc_bot/bot/admin.dart';
import 'package:sdsc_bot/bot/flows.dart';
import 'package:sdsc_bot/bot/service.dart';
import 'package:sdsc_bot/bot/state.dart';
import 'package:sdsc_bot/core/config.dart';
import 'package:sdsc_bot/core/db.dart';
import 'package:sdsc_bot/core/messages.dart';
import 'package:sdsc_bot/core/models.dart';
import 'package:sdsc_bot/core/repo.dart';

/// Grid preview (/grid, /resetgrid), check-status access, and the admin
/// /status allocation table.
void main() {
  late Directory tmp;
  late Database db;
  late Repo repo;
  late Config config;
  late Messages messages;
  late BotState state;
  late CycleService service;
  late Flows flows;
  late Admin admin;
  late List<Map<String, dynamic>> sent;
  late HttpServer server;
  late Bot bot;

  setUp(() async {
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
      promptHour: 8,
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
      messages: messages,
      state: state,
      service: service,
    );
    flows.register();
    admin.register();

    // Console (1), an admin (2), and a checker (3).
    repo.upsertUser(User(
      id: 1,
      name: '@console',
      experience: Experience.experienced,
      group: '1',
    ));
    repo.updateAdmin(1, true);
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

    // Allocate the current bundle so the tables have content.
    final w = RollingWindow.forDate(config.toLocal(Config.nowUtc()));
    repo.ensureSessionsForWeekend(
      w.sat0,
      config.slotTimes,
      tzOffsetHours: config.timezoneOffsetHours,
    );
    repo.ensureSessionsForWeekend(
      w.sat1,
      config.slotTimes,
      tzOffsetHours: config.timezoneOffsetHours,
    );
    final s0 = repo.sessionsForWeekend(w.sat0);
    final s1 = repo.sessionsForWeekend(w.sat1);
    repo.replaceAllocationsForWeekend(w.sat0, [(2, s0[0].id)]);
    repo.replaceAllocationsForWeekend(w.sat1, [(3, s1[0].id)]);

    final startFuture = bot.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    addTearDown(() async {
      await bot.stop();
      await startFuture;
      await server.close(force: true);
      db.close();
      tmp.deleteSync(recursive: true);
    });
  });

  Future<void> sendText(int userId, String text) => bot.handleUpdate(
        Update.fromJson({
          'update_id': 1,
          'message': {
            'message_id': 1,
            'date': 1,
            'chat': {'id': userId, 'type': 'private'},
            'from': {'id': userId, 'is_bot': false, 'first_name': 'u'},
            'text': text,
            'entities': [
              {
                'offset': 0,
                'length': text.length,
                'type': 'bot_command',
              }
            ],
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

  test('/grid cycles console → admin → check → member for the console', () async {
    await sendText(1, '/grid');
    expect(sent.last['text'], contains('Preview: admin grid'));
    expect(keyboardTexts(sent.last), contains('status'));

    await sendText(1, '/grid');
    expect(sent.last['text'], contains('Preview: check grid'));
    expect(keyboardTexts(sent.last), contains('check-status'));

    await sendText(1, '/grid');
    expect(sent.last['text'], contains('Preview: member grid'));
    expect(keyboardTexts(sent.last), contains('re-pick'));

    await sendText(1, '/grid');
    expect(sent.last['text'], contains('Preview: console grid'));
    expect(keyboardTexts(sent.last), contains('hold'));
  });

  test('/grid is rejected for non-console users', () async {
    await sendText(2, '/grid');
    expect(sent.last['text'], contains('Only the console can preview'));
  });

  test('/resetgrid returns the console to its own grid', () async {
    await sendText(1, '/grid'); // → admin preview
    await sendText(1, '/grid'); // → check preview
    await sendText(1, '/resetgrid');
    expect(sent.last['text'], contains('Back to your console grid'));
    expect(keyboardTexts(sent.last), contains('hold'));

    // Non-console: rejected.
    await sendText(2, '/resetgrid');
    expect(sent.last['text'], contains('Only the console can reset'));
  });

  test('console can run /check-status (previewing the check grid)', () async {
    await sendText(1, '/check-status');
    expect(sent.last['text'], isNot(contains('Only checkers')));
    expect(sent.last['text'], contains('This week\'s allocation'));
    expect(sent.last['text'], contains('@admin'));
  });

  test('a plain member is still rejected from /check-status', () async {
    repo.upsertUser(User(
      id: 4,
      name: '@member',
      experience: Experience.newbie,
      group: '1',
    ));
    await sendText(4, '/check-status');
    expect(sent.last['text'], contains('Only checkers can view'));
  });

  test('/status appends the allocation table for both weekends', () async {
    await sendText(2, '/status');
    final text = sent.last['text'] as String;
    expect(text, contains('SDSC status'));
    expect(text, contains('Responded:'));
    expect(text, contains('Allocation · '));
    expect(text, contains('@admin')); // sat0 allocation
    expect(text, contains('@checker')); // sat1 allocation
  });
}

Future<void> _json(HttpRequest req, Object body, {int status = 200}) async {
  req.response.statusCode = status;
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode(body));
  await req.response.close();
}