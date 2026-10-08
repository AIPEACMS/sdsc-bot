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
    'setinfo walks the 3-step profile wizard and saves the profile',
    () async {
      final sent = <Map<String, dynamic>>[];
      final editedMarkups = <Map<String, dynamic>>[];
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
        } else if (path.endsWith('/editMessageReplyMarkup')) {
          final body = jsonDecode(await utf8.decoder.bind(req).join());
          editedMarkups.add(body as Map<String, dynamic>);
          await _json(req, {
            'ok': true,
            'result': {
              'message_id': 1,
              'date': 1,
              'chat': {'id': body['chat_id'] ?? 1, 'type': 'private'},
              'text': '',
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
          preferredName: 'Alice',
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

      Future<void> cmd(
        int updateId,
        String text, {
        List<Map<String, dynamic>>? entities,
      }) async {
        await bot.handleUpdate(
          Update.fromJson({
            'update_id': updateId,
            'message': {
              'message_id': updateId,
              'date': 1,
              'chat': {'id': 42, 'type': 'private'},
              'from': {'id': 42, 'is_bot': false, 'first_name': 'alice'},
              'text': text,
              'entities': ?entities,
            },
          }),
        );
      }

      // /setinfo opens the one-step preferred-name wizard.
      await cmd(
        1,
        '/setinfo',
        entities: [
          {'offset': 0, 'length': 8, 'type': 'bot_command'},
        ],
      );
      expect(state.profileStep[42], 0);
      expect(
        sent.any((s) => (s['text'] as String).contains('preferred name')),
        isTrue,
      );
      expect(sent.single['reply_markup'], isNotNull);

      await cmd(2, 'Ali');

      expect(editedMarkups, hasLength(1));
      expect(editedMarkups.single['reply_markup'], isNull);

      await bot.stop();
      await startFuture;
      await server.close(force: true);

      final user = repo.findUser(42)!;
      expect(user.preferredName, 'Ali');
      expect(state.profileStep.containsKey(42), isFalse);
      expect(
        sent.any((s) => (s['text'] as String).contains('Profile saved')),
        isTrue,
      );
    },
  );

  test('pfcancel aborts the profile wizard, keeping the saved name', () async {
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
        preferredName: 'Alice',
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

    // alice has a preferred name already → the first prompt carries Cancel.
    await bot.handleUpdate(
      Update.fromJson({
        'update_id': 1,
        'message': {
          'message_id': 1,
          'date': 1,
          'chat': {'id': 42, 'type': 'private'},
          'from': {'id': 42, 'is_bot': false, 'first_name': 'alice'},
          'text': '/setinfo',
          'entities': [
            {'offset': 0, 'length': 8, 'type': 'bot_command'},
          ],
        },
      }),
    );
    final step1 = sent.last;
    expect((step1['reply_markup'] as Map), isNotNull);
    expect(state.profileStep[42], 0);

    // Tap Cancel: wizard ends, saved fields untouched.
    await bot.handleUpdate(
      Update.fromJson({
        'update_id': 2,
        'callback_query': {
          'id': '2',
          'from': {'id': 42, 'is_bot': false, 'first_name': 'alice'},
          'chat_instance': '1',
          'message': {
            'message_id': 1,
            'date': 1,
            'chat': {'id': 42, 'type': 'private'},
            'text': '1/1 — What is your preferred name?',
          },
          'data': 'pfcancel|0',
        },
      }),
    );

    await bot.stop();
    await startFuture;
    await server.close(force: true);

    expect(state.profileStep.containsKey(42), isFalse);
    expect(repo.findUser(42)!.preferredName, 'Alice');
  });

  test('/start prompts the profile wizard when fields are empty', () async {
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

    await bot.handleUpdate(
      Update.fromJson({
        'update_id': 1,
        'message': {
          'message_id': 1,
          'date': 1,
          'chat': {'id': 42, 'type': 'private'},
          'from': {'id': 42, 'is_bot': false, 'first_name': 'alice'},
          'text': '/start',
          'entities': [
            {'offset': 0, 'length': 6, 'type': 'bot_command'},
          ],
        },
      }),
    );

    await bot.stop();
    await startFuture;
    await server.close(force: true);

    // The member help is sent, then the first profile prompt (no Cancel,
    // nothing saved yet).
    final texts = sent.map((s) => s['text'] as String).toList();
    expect(texts.any((t) => t.contains('re-pick')), isTrue);
    expect(
      texts.any((t) => t.contains('1/1') && t.contains('preferred name')),
      isTrue,
    );
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
