import 'dart:convert';
import 'dart:io';

import 'package:televerse/telegram.dart' show Update;
import 'package:televerse/televerse.dart';
import 'package:test/test.dart';

/// Regression test: a bookkeeping `bot.use` middleware registered before
/// command handlers must NOT swallow slash commands. (Real bug: the flows
/// bookkeeping middleware returned early on `ctx.hasCommand`, so typed
/// commands like /addkey never reached the console/admin handlers registered
/// later in main.dart.)
void main() {
  test('slash commands reach handlers registered after a use() middleware',
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
      } else {
        await _json(req, {'ok': false, 'error': 'nf'}, status: 404);
      }
    });

    final bot = Bot.local('test-token', 'http://127.0.0.1:${server.port}');
    var handled = false;

    // Registration order mirrors main.dart: flows commands + bookkeeping
    // middleware first, then console commands.
    bot.command('start', (ctx) async => ctx.reply('hi'));
    bot.use((ctx, next) async {
      final text = ctx.message?.text;
      if (text != null) {
        // pending-arg consumption (wizard) stops the chain; everything else
        // must continue so later command handlers still run.
        if (text == 'wizard-input') return;
      }
      await next();
    });
    bot.command('addkey', (ctx) async {
      handled = true;
      await ctx.reply('ok ${ctx.args.first}');
    });

    final startFuture = bot.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    await bot.handleUpdate(Update.fromJson({
      'update_id': 1,
      'message': {
        'message_id': 1,
        'date': 1,
        'chat': {'id': 6337440771, 'type': 'private'},
        'from': {'id': 6337440771, 'is_bot': false, 'first_name': 'op'},
        'text': '/addkey uI0pd4X6aKMYDTilhGdxzlF476WoRlNR9jhUZFZupK4=',
        'entities': [
          {'offset': 0, 'length': 7, 'type': 'bot_command'},
        ],
      },
    }));

    await bot.stop();
    await startFuture;
    await server.close(force: true);

    expect(handled, isTrue);
    expect(sent, isNotEmpty);
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
