import 'dart:convert';
import 'dart:io';

import 'package:televerse/telegram.dart' show Update;
import 'package:televerse/televerse.dart';
import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:sdsc_bot/bot/flows.dart';
import 'package:sdsc_bot/bot/service.dart';
import 'package:sdsc_bot/bot/state.dart';
import 'support/repick_harness.dart';
import 'test_helpers.dart';

void main() {
  setUp(setUpRepick);
  tearDown(tearDownRepick);
  test(
    'toggling a slot keeps the picker anchored to the bundle start',
    () async {
      final edits = <Map<String, dynamic>>[];
      var answered = 0;
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
          await _json(req, {
            'ok': true,
            'result': {
              'message_id': 1,
              'date': 1,
              'chat': {'id': 1, 'type': 'private'},
              'text': 'x',
            },
          });
        } else if (path.endsWith('/editMessageText')) {
          final body = jsonDecode(await utf8.decoder.bind(req).join());
          edits.add(body as Map<String, dynamic>);
          await _json(req, {'ok': true, 'result': true});
        } else if (path.endsWith('/answerCallbackQuery')) {
          answered++;
          await _json(req, {'ok': true, 'result': true});
        } else {
          await _json(req, {'ok': false, 'error': 'nf'}, status: 404);
        }
      });

      repo.upsertUser(
        User(id: 42, name: '@alice', experience: Experience.newbie, group: '1'),
      );

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

      final w = RollingWindow.fromSat0(DateTime(2026, 8, 15));
      final picker = CycleServiceNotifications.buildKeyboard(
        w,
        (const {}, const {}),
        now: DateTime(2026, 8, 17),
        sessions: defaultSessions(w.sat0),
        locationName: (k) => k,
      );
      final selectable = picker.inlineKeyboard
          .expand((row) => row)
          .firstWhere(
            (button) => button.callbackData?.startsWith('slot|') ?? false,
          );
      final callbackData = selectable.callbackData!;
      final callbackParts = callbackData.split('|');
      expect(Slot.parse(callbackParts[2])?.encode(), callbackParts[2]);

      // Toggle a week-2 slot (weekend index 1 of the bundle starting
      // 2026-08-15). The re-rendered keyboard must stay anchored to that
      // bundle: only the open weekend (Sat 22 Aug) shows a header — never a
      // shifted one like "Sat 29 Aug".
      await bot.handleUpdate(
        Update.fromJson({
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
            'data': callbackData,
          },
        }),
      );

      expect(edits, isNotEmpty);
      final rows =
          (edits.last['reply_markup']! as Map)['inline_keyboard']! as List;
      final headers = [
        for (final row in rows)
          for (final b in (row as List))
            if ((b as Map)['callback_data'].toString().startsWith('noop'))
              b['text'] as String,
      ];
      expect(headers, ['Sat 22 Aug']);

      // A header tap is answered immediately (no spinner left hanging).
      final answeredBeforeNoop = answered;
      await bot.handleUpdate(
        Update.fromJson({
          'update_id': 2,
          'callback_query': {
            'id': '2',
            'from': {'id': 42, 'is_bot': false, 'first_name': 'alice'},
            'chat_instance': '1',
            'message': {
              'message_id': 7,
              'date': 1,
              'chat': {'id': 42, 'type': 'private'},
              'text': 'Your availability (tap to toggle):',
            },
            'data': 'noop|1',
          },
        }),
      );
      expect(answered, answeredBeforeNoop + 1);

      await bot.stop();
      await startFuture;
      await server.close(force: true);
    },
  );

  test(
    'toggling cycles off → offered → booked → off and saves want separately',
    () async {
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

      repo.upsertUser(
        User(id: 42, name: '@alice', experience: Experience.newbie, group: '1'),
      );

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

      Future<void> tap(int updateId, String data) => bot.handleUpdate(
        Update.fromJson({
          'update_id': updateId,
          'callback_query': {
            'id': '$updateId',
            'from': {'id': 42, 'is_bot': false, 'first_name': 'alice'},
            'chat_instance': '1',
            'message': {
              'message_id': 7,
              'date': 1,
              'chat': {'id': 42, 'type': 'private'},
              'text': 'Your availability (tap to toggle):',
            },
            'data': data,
          },
        }),
      );

      // 1st tap: offered 🟢.
      await tap(1, 'slot|2026-08-15|1:sat:am:ocbc');
      expect(state.picksFor(42).$1, isEmpty);
      expect(state.picksFor(42).$2, {const Slot(1, 'sat', 'am', 'ocbc')});

      // 2nd tap: booked 🔒.
      await tap(2, 'slot|2026-08-15|1:sat:am:ocbc');
      expect(state.picksFor(42).$1, {const Slot(1, 'sat', 'am', 'ocbc')});
      expect(state.picksFor(42).$2, isEmpty);

      // 3rd tap: off again.
      await tap(3, 'slot|2026-08-15|1:sat:am:ocbc');
      expect(state.picksFor(42).$1, isEmpty);
      expect(state.picksFor(42).$2, isEmpty);

      // Book it again (2 taps) and also offer a second slot, then Done.
      await tap(4, 'slot|2026-08-15|1:sat:am:ocbc');
      await tap(5, 'slot|2026-08-15|1:sat:am:ocbc');
      await tap(6, 'slot|2026-08-15|1:sat:pm:pasirRis');
      await tap(7, 'done|2026-08-15');

      await bot.stop();
      await startFuture;
      await server.close(force: true);

      // The open weekend (Sat 22 Aug) saved want and available separately.
      final sat1 = DateTime(2026, 8, 22);
      final row = repo.getAvailability(sat1, 42);
      expect(row, isNotNull);
      expect(row!.wantSlots, {const Slot(1, 'sat', 'am', 'ocbc')});
      expect(row.slots, {const Slot(1, 'sat', 'pm', 'pasirRis')});
      expect(row.available, isTrue);
    },
  );

  test('saving availability revokes the member\'s allocation', () async {
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

    repo.upsertUser(
      User(id: 42, name: '@alice', experience: Experience.newbie, group: '1'),
    );

    // alice was already allocated to a session of the open weekend.
    final sat1 = DateTime(2026, 8, 22);
    repo.ensureSessionsForWeekend(
      sat1,
      defaultTemplate(),
      tzOffsetHours: config.timezoneOffsetHours,
    );
    final sessions = repo.sessionsForWeekend(sat1);
    expect(sessions, isNotEmpty);
    repo.replaceAllocationsForWeekend(sat1, [(42, sessions.first.id)]);

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

    // alice answers the bundle (Done, nothing selected). The open weekend
    // (Sat 22 Aug) gets saved; her allocation there must be revoked so the
    // immediate re-optimization re-decides her from scratch.
    await bot.handleUpdate(
      Update.fromJson({
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
      }),
    );

    await bot.stop();
    await startFuture;
    await server.close(force: true);

    final allocs = repo.allocationsForWeekend(sat1);
    expect(allocs.where((e) => e.$1.id == 42), isEmpty);
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
