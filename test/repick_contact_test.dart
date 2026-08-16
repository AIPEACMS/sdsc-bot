import 'dart:convert';
import 'dart:io';

import 'package:televerse/telegram.dart' show Update;
import 'package:televerse/televerse.dart';
import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';

import 'package:sdsc_bot/bot/flows.dart';
import 'package:sdsc_bot/bot/service.dart';
import 'package:sdsc_bot/bot/state.dart';

/// Regression tests for member-flow edge cases:
///  - pressing Done with nothing selected must behave like "Not available"
///    (save available=false, reply msg6 — never a "(none)" confirmation);
///  - message contacts resolve to the group leader, not the env placeholder.
void main() {
  late Directory tmp;
  late Database db;
  late Repo repo;
  late Config config;
  late Messages messages;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sdsc_repick_');
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
    // Same wiring as main.dart: the contact is the member's group leader,
    // with the env contact only as a fallback.
    messages = Messages(
      (group) => repo.groupAdmin(group)?.name ?? config.contactForGroup(group),
    );
  });

  tearDown(() {
    db.close();
    tmp.deleteSync(recursive: true);
  });

  test('Done with nothing selected is treated as not available', () async {
    final sent = <Map<String, dynamic>>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
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
      } else if (path.endsWith('/answerCallbackQuery') ||
          path.endsWith('/editMessageText')) {
        await _json(req, {'ok': true, 'result': true});
      } else {
        await _json(req, {'ok': false, 'error': 'nf'}, status: 404);
      }
    });

    repo.upsertUser(User(
      id: 42,
      name: '@alice',
      experience: Experience.newbie,
      group: '1',
    ));

    final bot = Bot.local('test-token', 'http://127.0.0.1:${server.port}');
    final state = BotState();
    final service = CycleService(
      repo: repo,
      config: config,
      messages: messages,
      state: state,
      bot: bot,
    );
    Flows(
      bot: bot,
      repo: repo,
      config: config,
      messages: messages,
      state: state,
      service: service,
    ).register();

    final startFuture = bot.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // alice taps Done without selecting any slot. This weekend (2026-08-15)
    // is already locked on the real clock; next weekend is still open.
    await bot.handleUpdate(Update.fromJson({
      'update_id': 1,
      'callback_query': {
        'id': '1',
        'from': {'id': 42, 'is_bot': false, 'first_name': 'alice'},
        'chat_instance': '1',
        'message': {
          'message_id': 7,
          'date': 1,
          'chat': {'id': 42, 'type': 'private'},
          'text': 'Your availability (tap to toggle):',
        },
        'data': 'done|2026-08-15',
      },
    }));

    await bot.stop();
    await startFuture;
    await server.close(force: true);

    // The reply is the "not available" message, never a "(none)" summary.
    final texts = sent.map((s) => s['text'] as String).toList();
    expect(texts.any((t) => t.contains('all set for the next 2 weeks')),
        isTrue);
    expect(texts.any((t) => t.contains('(none)')), isFalse);

    // The open weekend's availability row is stored as available=false.
    final sat1 = DateTime(2026, 8, 22);
    final row = repo.getAvailability(sat1, 42);
    expect(row, isNotNull);
    expect(row!.available, isFalse);
  });

  test('message contacts resolve to the group leader, not the placeholder',
      () {
    repo.upsertUser(User(
      id: 10,
      name: '@leader',
      experience: Experience.experienced,
      group: '1',
      isAdmin: true,
    ));
    repo.upsertUser(User(
      id: 11,
      name: '@member',
      experience: Experience.newbie,
      group: '1',
    ));

    final prompt = messages.msg1('1');
    expect(prompt, contains('@leader'));
    expect(prompt, isNot(contains('TBD')));

    final notice = messages.msg4('1', 'OCBC · Saturday 15 Aug AM',
        '09:00 to 12:00');
    expect(notice, contains('@leader'));
    expect(notice, isNot(contains('TBD')));
  });
}

Future<void> _json(HttpRequest req, Map<String, dynamic> body,
    {int status = 200}) async {
  req.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  await req.response.close();
}
