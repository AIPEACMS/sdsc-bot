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
import '../../support/bot_readiness.dart';

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
  late List<Map<String, dynamic>> edited;
  late HttpServer server;
  late Bot bot;
  late BotReadiness readiness;
  setUp(() async {
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
    edited = <Map<String, dynamic>>[];
    readiness = BotReadiness();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      readiness.observe(req);
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
        edited.add(body as Map<String, dynamic>);
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
        name: '@avail',
        experience: Experience.newbie,
        group: '1',
      ),
    );
    repo.upsertUser(
      const User(
        id: 3,
        name: '@unavail',
        experience: Experience.newbie,
        group: '1',
      ),
    );
    repo.upsertUser(
      const User(
        id: 4,
        name: '@silent',
        experience: Experience.newbie,
        group: '1',
      ),
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
    await readiness.wait();
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
    await sendCallback(1, 'settime-scope|persistent');
    await sendCallback(1, 'settime-action|rewrite');
    expect(edited.last['text'], contains('max-num-ppl'));
    await sendText(1, 'sat 9 13 ocbc 4');
    final firstAck = sent.last['text'] as String;
    expect(firstAck, contains('Added session 1 (1 so far)'));
    expect(
      firstAck,
      contains('Session 1: Saturday 9:00 to 13:00 at location: OCBC [max 4]'),
    );
    await sendText(1, 'sat 13 17 pr');
    final secondAck = sent.last['text'] as String;
    expect(secondAck, contains('Added session 2 (2 so far)'));
    expect(
      secondAck,
      contains('Session 2: Saturday 13:00 to 17:00 at location: Pasir Ris'),
    );
    await sendText(1, 'sun 10 12 ocbc\nfri 18 20 pasir');
    final thirdAck = sent.last['text'] as String;
    expect(thirdAck, contains('Added sessions 3-4 (4 so far)'));
    expect(thirdAck, contains('Session 3: Sunday 10:00 to 12:00'));
    expect(thirdAck, contains('Session 4: Friday 18:00 to 20:00'));
    await sendText(1, 'done');
    expect(edited.any((body) => body['reply_markup'] == null), isTrue);
    final confirmation = sent.last['text'] as String;
    expect(confirmation, contains('Before change:'));
    expect(confirmation, contains('After change:'));
    await sendCallback(1, 'settime|yes');
    final template = repo.scheduleTemplate();
    expect(template.length, 4);
    expect(template.map((r) => r.location).toSet(), {
      Locations.ocbc,
      Locations.pasirRis,
    });
    final w = RollingWindow.forDate(config.toLocal(Config.nowUtc()));
    final sessions = repo.sessionsForWeekend(w.sat0);
    expect(sessions.length, 4);
    expect(sessions.map((s) => s.location).toSet(), {
      Locations.ocbc,
      Locations.pasirRis,
    });
    expect(sessions.map((s) => s.day).toSet(), {'sat', 'sun', 'fri'});
  });
  test(
    'only members who indicated availability are asked to pick again',
    () async {
      await sendText(1, '/settime');
      await sendText(1, 'sat 9 13 ocbc');
      await sendText(1, 'done');
      await sendCallback(1, 'settime|yes');
      List<Map<String, dynamic>> pickers(int id) => [
        for (final m in messagesTo(id))
          if ((m['text'] as String? ?? '').contains(
            'activity sessions have been updated',
          ))
            m,
      ];
      final availPickers = pickers(2);
      expect(availPickers, isNotEmpty);
      final markup = jsonEncode(availPickers.last['reply_markup']);
      expect(markup, contains('slot|'));
      expect(pickers(3), isEmpty);
      expect(pickers(4), isEmpty);
    },
  );
  test('remove sessions uses tick buttons and confirmation', () async {
    await sendText(1, '/settime');
    await sendCallback(1, 'settime-scope|persistent');
    await sendCallback(1, 'settime-action|remove');
    expect(
      edited.last['text'],
      contains('Select recurring sessions to remove'),
    );
    await sendCallback(1, 'settime-remove|0');
    await sendCallback(1, 'settime-remove|done');
    await sendCallback(1, 'settime|yes');
    expect(repo.scheduleTemplate(), hasLength(3));
  });
  test('temporary week labels show the Monday-Sunday calendar range', () async {
    final saturday = DateTime(2026, 10, 3);
    repo.ensureSessionsForWeekend(
      saturday,
      repo.scheduleForWeekend(saturday),
      tzOffsetHours: config.timezoneOffsetHours,
    );
    final session = repo.sessionsForWeekend(saturday).first;
    repo.replaceAllocationsForWeekend(saturday, [(2, session.id)]);
    await sendText(1, '/settime');
    await sendCallback(1, 'settime-scope|temporary');
    await sendCallback(1, 'settime-action|remove');
    final picker = edited.last['reply_markup'] as Map<String, dynamic>;
    final buttons = (picker['inline_keyboard'] as List)
        .expand((row) => row as List)
        .map((button) => button as Map<String, dynamic>)
        .toList();
    expect(buttons.first['text'], 'Week 2026-09-14 - 2026-09-20');
    expect(buttons.first['callback_data'], 'settime-week|2026-09-19');
    expect(buttons, hasLength(6)); // Four weeks, Next, Cancel.
    expect(buttons[2]['callback_data'], 'settime-week|2026-10-03');
    expect(buttons[3]['callback_data'], 'settime-week|2026-10-10');
    expect(buttons[4]['callback_data'], 'settime-week-page|1');
    await sendCallback(1, 'settime-week-page|1');
    final nextPage = edited.last['reply_markup'] as Map<String, dynamic>;
    final nextButtons = (nextPage['inline_keyboard'] as List)
        .expand((row) => row as List)
        .map((button) => button as Map<String, dynamic>)
        .toList();
    expect(nextButtons[0]['callback_data'], 'settime-week|2026-10-17');
    expect(nextButtons[4]['callback_data'], 'settime-week-page|0');
    expect(nextButtons[5]['callback_data'], 'settime-week-page|2');
    await sendCallback(1, 'settime-week-page|0');
    await sendCallback(1, 'settime-week|2026-10-03');
    expect(
      edited.last['text'],
      contains('Select sessions to remove from week 2026-09-28 - 2026-10-04:'),
    );
    final sessionButtons =
        (edited.last['reply_markup'] as Map<String, dynamic>)['inline_keyboard']
            as List;
    final removeButton =
        (sessionButtons.first as List).first as Map<String, dynamic>;
    await sendCallback(1, removeButton['callback_data'] as String);
    await sendCallback(1, 'settime-remove|done');
    expect(sent.last['text'], contains('These allocations will be removed:'));
    expect(sent.last['text'], contains('@avail'));
    await sendCallback(1, 'settime|yes');
    expect(
      repo
          .scheduleForWeekend(saturday)
          .any(
            (row) =>
                row.day == session.day &&
                row.slot == session.slot &&
                row.location == session.location,
          ),
      isFalse,
    );
    expect(repo.allocationsForWeekend(saturday), isEmpty);
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
