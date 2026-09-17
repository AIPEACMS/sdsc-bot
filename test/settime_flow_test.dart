import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:televerse/telegram.dart' show Update;
import 'package:televerse/televerse.dart';

import 'package:sdsc_bot/core/config.dart';
import 'package:sdsc_bot/core/db.dart';
import 'package:sdsc_bot/core/messages.dart';
import 'package:sdsc_bot/core/models.dart';
import 'package:sdsc_bot/core/repo.dart';
import 'package:sdsc_bot/bot/flows.dart';
import 'package:sdsc_bot/bot/service.dart';
import 'package:sdsc_bot/bot/settime.dart';
import 'package:sdsc_bot/bot/state.dart';

/// End-to-end `/settime`: lines -> confirmation -> apply, plus the re-pick
/// prompt scope. Regression cover for the "template replaced (0 rows)" bug,
/// which silently saved an empty schedule because a location token that
/// resolves automatically (e.g. `ocbc`) was never written into the draft.
void main() {
  late Directory tmp;
  late Database db;
  late Repo repo;
  late Config config;
  late BotState state;
  late CycleService service;
  late Flows flows;
  late SetTime setTime;
  late List<Map<String, dynamic>> sent;
  late HttpServer server;
  late Bot bot;

  setUp(() async {
    // Pin the clock to a Wednesday so both weekends of the window are open.
    Config.setDebugNow(DateTime.utc(2026, 9, 16, 4));
    tmp = Directory.systemTemp.createTempSync('sdsc_settime_');
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
            'message_id': sent.length,
            'date': 1,
            'chat': {'id': body['chat_id'], 'type': 'private'},
            'text': body['text'],
          },
        });
      } else if (path.endsWith('/editMessageText') ||
          path.endsWith('/editMessageReplyMarkup')) {
        final body = jsonDecode(await utf8.decoder.bind(req).join());
        await _json(req, {
          'ok': true,
          'result': {
            'message_id': 1,
            'date': 1,
            'chat': {'id': body['chat_id'] ?? 1, 'type': 'private'},
            'text': body['text'] ?? 'edited',
          },
        });
      } else if (path.endsWith('/answerCallbackQuery')) {
        await _json(req, {'ok': true, 'result': true});
      } else {
        await _json(req, {'ok': false, 'error': 'nf'}, status: 404);
      }
    });

    bot = Bot.local('test-token', 'http://127.0.0.1:${server.port}');
    final messages = Messages(
      (group) => repo.groupAdmin(group)?.name ?? config.contactForGroup(group),
    );
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
    setTime = SetTime(
      bot: bot,
      repo: repo,
      config: config,
      state: state,
      service: service,
    );
    flows.register();
    setTime.register();
    flows.onSetTimeText = setTime.onText;
    flows.onSetTimeNewNameText = setTime.onNewNameText;

    // The gadmin (also the console), and three members with different states.
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
      const User(id: 2, name: '@avail', experience: Experience.newbie, group: '1'),
    );
    repo.upsertUser(
      const User(id: 3, name: '@unavail', experience: Experience.newbie, group: '1'),
    );
    repo.upsertUser(
      const User(id: 4, name: '@silent', experience: Experience.newbie, group: '1'),
    );

    final w = RollingWindow.forDate(config.toLocal(Config.nowUtc()));
    repo.ensureSessionsForWeekend(
      w.sat0,
      repo.scheduleTemplate(),
      tzOffsetHours: config.timezoneOffsetHours,
    );
    repo.setAvailability(
      Availability(
        weekendStart: w.sat0,
        userId: 2,
        bundleStart: w.sat0,
        slots: {Slot(0, 'sat', 'am', Locations.ocbc)},
        available: true,
        updatedAt: config.toLocal(Config.nowUtc()),
      ),
    );
    repo.setAvailability(
      Availability(
        weekendStart: w.sat0,
        userId: 3,
        bundleStart: w.sat0,
        slots: const {},
        available: false,
        updatedAt: config.toLocal(Config.nowUtc()),
      ),
    );

    final startFuture = bot.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    addTearDown(() async {
      await bot.stop();
      await startFuture;
      await server.close(force: true);
      db.close();
      tmp.deleteSync(recursive: true);
      Config.setDebugNow(null);
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
            'length': text.contains(' ') ? text.indexOf(' ') : text.length,
            'type': 'bot_command',
          },
        ],
      },
    }),
  );

  Future<void> sendCallback(int userId, String data) => bot.handleUpdate(
    Update.fromJson({
      'update_id': 2,
      'callback_query': {
        'id': '1',
        'from': {'id': userId, 'is_bot': false, 'first_name': 'u'},
        'chat_instance': 'x',
        'data': data,
        'message': {
          'message_id': 1,
          'date': 1,
          'chat': {'id': userId, 'type': 'private'},
          'text': 'previous',
        },
      },
    }),
  );

  List<Map<String, dynamic>> messagesTo(int chatId) => [
    for (final m in sent)
      if (m['chat_id'] == chatId) m,
  ];

  test('a lane with known locations is saved as real sessions', () async {
    await sendText(1, '/settime');
    expect(sent.last['text'], contains('Set the activity times'));

    // Both `ocbc` and `pr` resolve automatically (no location choice needed).
    await sendText(1, 'sat 9 13 ocbc');
    final firstAck = sent.last['text'] as String;
    expect(firstAck, contains('Added session 1 (1 so far)'));
    expect(
      firstAck,
      contains('Session 1: Saturday 9:00 to 13:00 at location: OCBC'),
    );

    await sendText(1, 'sat 13 17 pr');
    final secondAck = sent.last['text'] as String;
    expect(secondAck, contains('Added session 2 (2 so far)'));
    expect(
      secondAck,
      contains('Session 2: Saturday 13:00 to 17:00 at location: Pasir Ris'),
    );

    // Several lines in one message are acknowledged as a range.
    await sendText(1, 'sun 10 12 ocbc\nfri 18 20 pasir');
    final thirdAck = sent.last['text'] as String;
    expect(thirdAck, contains('Added sessions 3-4 (4 so far)'));
    expect(thirdAck, contains('Session 3: Sunday 10:00 to 12:00'));
    expect(thirdAck, contains('Session 4: Friday 18:00 to 20:00'));

    await sendText(1, 'done');
    final confirmation = sent.last['text'] as String;
    expect(confirmation, contains('Session 1: Saturday 9:00 to 13:00'));
    expect(confirmation, contains('OCBC'));
    expect(confirmation, contains('Session 2: Saturday 13:00 to 17:00'));
    expect(confirmation, contains('Pasir Ris'));

    await sendCallback(1, 'settime|yes');

    // The template is real, not empty (four lines across three messages).
    final template = repo.scheduleTemplate();
    expect(template.length, 4);
    expect(
      template.map((r) => r.location).toSet(),
      {Locations.ocbc, Locations.pasirRis},
    );

    // And the open weekend has sessions built from it, other weekdays included.
    final w = RollingWindow.forDate(config.toLocal(Config.nowUtc()));
    final sessions = repo.sessionsForWeekend(w.sat0);
    expect(sessions.length, 4);
    expect(
      sessions.map((s) => s.location).toSet(),
      {Locations.ocbc, Locations.pasirRis},
    );
    expect(sessions.map((s) => s.day).toSet(), {'sat', 'sun', 'fri'});
    expect(sessions.first.start.hour, 9);
  });

  test('only members who indicated availability are asked to pick again',
      () async {
    await sendText(1, '/settime');
    await sendText(1, 'sat 9 13 ocbc');
    await sendText(1, 'done');
    await sendCallback(1, 'settime|yes');

    List<Map<String, dynamic>> pickers(int id) => [
      for (final m in messagesTo(id))
        if ((m['text'] as String? ?? '').contains('activity sessions have been updated'))
          m,
    ];

    // The member who had indicated availability gets a fresh picker...
    final availPickers = pickers(2);
    expect(availPickers, isNotEmpty);
    final markup = jsonEncode(availPickers.last['reply_markup']);
    expect(markup, contains('slot|'));

    // ...the member who answered "not available" does not...
    expect(pickers(3), isEmpty);
    // ...and neither does the member who never responded.
    expect(pickers(4), isEmpty);
  });
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
