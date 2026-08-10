import 'dart:async';
import 'dart:io';

import 'package:televerse/televerse.dart';

import 'package:sdsc_bot/sdsc_bot.dart';

import 'package:sdsc_bot/bot/admin.dart';
import 'package:sdsc_bot/bot/calendar_sync.dart';
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

  final calendarSync = CalendarSync(repo: repo, config: config);

  final console = Console(
    bot: bot,
    repo: repo,
    config: config,
    state: state,
    calendarSync: calendarSync,
  );

  final scheduler = Scheduler(
    repo: repo,
    config: config,
    service: service,
  );

  CalendarIpcServer? ipcServer;
  if (config.calendarIpcToken != null) {
    ipcServer = CalendarIpcServer(
      sync: calendarSync,
      token: config.calendarIpcToken!,
      port: config.calendarIpcPort,
    );
  }

  flows.register();
  admin.register();
  console.register();

  // The /broadcast wizard asks the admin to type the message; the text lands
  // in Flows' text middleware, which hands it back to Admin for confirmation.
  // The /setdate and /sync-calendar wizards hand the typed input to Console.
  flows.onBroadcastText = admin.onBroadcastText;
  flows.onSetDateText = console.onSetDateText;
  flows.onSyncCalendarText = console.onSyncCalendarText;

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
  if (ipcServer != null) await ipcServer.start();
  // ignore: avoid_print
  print('SDSC bot starting (long polling)...');

  await bot.start();
  await stopCompleter.future;

  await ipcServer?.stop();
  scheduler.stop();
  database.close();
  // ignore: avoid_print
  print('SDSC bot stopped.');
  exit(0);
}
