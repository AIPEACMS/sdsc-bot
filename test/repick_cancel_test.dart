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

void main() {
  setUp(setUpRepick);
  tearDown(tearDownRepick);
  test(
    'cancel aborts the in-progress repick, keeping the saved answer',
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
        User(
          id: 42,
          name: '@alice',
          experience: Experience.newbie,
          group: '1',
        ),
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

      // alice first answers the bundle (Done, nothing selected → not
      // available). This weekend (2026-08-15) is already locked on the real
      // clock; next weekend is still open.
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

      // The open weekend (Sat 22 Aug) now has a saved response.
      final sat1 = DateTime(2026, 8, 22);
      expect(repo.getAvailability(sat1, 42), isNotNull);

      // alice starts a repick: toggles a week-2 slot (in-progress change).
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
            'data': 'slot|2026-08-15|1:sat:am:ocbc',
          },
        }),
      );
      expect(state.picksFor(42).$2, isNotEmpty); // 1 tap = offered 🟢

      // alice cancels: the in-progress toggle is discarded, the saved answer
      // is kept.
      await bot.handleUpdate(
        Update.fromJson({
          'update_id': 3,
          'callback_query': {
            'id': '3',
            'from': {'id': 42, 'is_bot': false, 'first_name': 'alice'},
            'chat_instance': '1',
            'message': {
              'message_id': 7,
              'date': 1,
              'chat': {'id': 42, 'type': 'private'},
              'text': 'Your availability (tap to toggle):',
            },
            'data': 'cancel|2026-08-15',
          },
        }),
      );

      await bot.stop();
      await startFuture;
      await server.close(force: true);

      // The saved answer is untouched and the in-progress picks are gone.
      expect(repo.getAvailability(sat1, 42), isNotNull);
      expect(state.availabilityPicks.containsKey(42), isFalse);
      final texts = sent.map((s) => s['text'] as String).toList();
      expect(
        texts.any((t) => t.contains('previous availability is kept')),
        isTrue,
      );
      expect(texts.any((t) => t.contains('Send re-pick')), isTrue);
      expect(texts.any((t) => t.contains('/repick')), isFalse);
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
