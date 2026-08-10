import 'dart:async';
import 'dart:io';

import 'package:televerse/televerse.dart';

import 'package:sdsc_bot/sdsc_bot.dart';

import 'package:sdsc_bot/bot/admin.dart';
import 'package:sdsc_bot/bot/console.dart';
import 'package:sdsc_bot/bot/flows.dart';
import 'package:sdsc_bot/bot/scheduler.dart';
import 'package:sdsc_bot/bot/service.dart';
import 'package:sdsc_bot/bot/state.dart';

Future<void> main() async {
  final config = Config.fromEnv();
  final database = Database.open(config);
  final repo = Repo(database);
  final messages = Messages(config.contactForGroup);
  final state = BotState();

  final bot = Bot<Context>(config.botToken);

  final service = CycleService(
    repo: repo,
    config: config,
    messages: messages,
    state: state,
    bot: bot,
  );

  final flows = Flows(
    bot: bot,
    repo: repo,
    config: config,
    messages: messages,
    state: state,
    service: service,
  );

  final admin = Admin(
    bot: bot,
    repo: repo,
    config: config,
    messages: messages,
    state: state,
    service: service,
  );

  final console = Console(
    bot: bot,
    repo: repo,
    config: config,
  );

  final scheduler = Scheduler(
    repo: repo,
    config: config,
    service: service,
  );

  flows.register();
  admin.register();
  console.register();

  bot.onError((error) {
    // ignore: avoid_print
    print('bot error: ${error.error}');
  });

  final stopCompleter = Completer<void>();
  ProcessSignal.sigterm.watch().listen((_) async {
    await bot.stop();
    stopCompleter.complete();
  });
  ProcessSignal.sigint.watch().listen((_) async {
    await bot.stop();
    stopCompleter.complete();
  });

  scheduler.start();
  // ignore: avoid_print
  print('SDSC bot starting (long polling)...');

  await bot.start();
  await stopCompleter.future;

  scheduler.stop();
  database.close();
  // ignore: avoid_print
  print('SDSC bot stopped.');
  exit(0);
}
