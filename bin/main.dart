import 'dart:async';
import 'dart:io';

import 'package:televerse/televerse.dart';

import 'package:sdsc_bot/sdsc_bot.dart';

import 'package:sdsc_bot/bot/admin.dart';
import 'package:sdsc_bot/bot/admin_api.dart';
import 'package:sdsc_bot/bot/calendar_sync.dart';
import 'package:sdsc_bot/bot/console.dart';
import 'package:sdsc_bot/bot/flows.dart';
import 'package:sdsc_bot/bot/hold.dart';
import 'package:sdsc_bot/bot/scheduler.dart';
import 'package:sdsc_bot/bot/service.dart';
import 'package:sdsc_bot/bot/state.dart';

Future<void> main() async {
  final config = Config.fromEnv();
  final database = Database.open(config);
  final repo = Repo(database);

  // Load the log retention window persisted by the console (default 14 days).
  final retention = repo.getSetting('log_retention_days');
  if (retention != null) {
    final days = int.tryParse(retention);
    if (days != null && days > 0) {
      LogRing.setRetention(Duration(days: days));
    }
  }

  final messages = Messages(config.contactForGroup);
  final state = BotState();

  final bot = Bot<Context>(config.botToken);

  // Block & drop gate: while held, all outgoing per-chat messages are
  // suppressed at the API layer. Persisted in the DB, loaded on start.
  final holdGate = HoldGate(repo.isHeld());
  bot.api.use(HoldTransformer(holdGate));

  // Incoming-message log: every message the bot receives lands in the log
  // ring (and journal), so the console can see what arrived and when. The
  // payload is truncated — a public key, handle or text, never secrets.
  bot.use((ctx, next) async {
    final text = ctx.message?.text;
    if (text != null) {
      final from = ctx.from?.id;
      final shown = text.length <= 120 ? text : '${text.substring(0, 120)}…';
      LogRing.log('msg $from: $shown');
    }
    return next();
  });

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
    holdGate: holdGate,
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

    AdminApi? adminApi;
  // Always listen: with zero registered keys the API 401s every request, but
  // it must be up for the very first console key to be usable after /addkey.
  final apiToken = config.adminApiToken;
  if (config.adminApiPort > 0) {
    adminApi = AdminApi(
      repo: repo,
      config: config,
      calendarSync: calendarSync,
      holdGate: holdGate,
      token: apiToken,
      port: config.adminApiPort,
    );
  }

  flows.register();
  admin.register();
  console.register();

  // The /broadcast wizard asks the admin to type the message; the text lands
  // in Flows' text middleware, which hands it back to Admin for confirmation.
  // The /adduser wizard hands the typed handle back for confirmation, and the
  // /setdate and /sync-calendar wizards hand the typed input to Console.
  flows.onBroadcastText = admin.onBroadcastText;
  flows.onAddUserText = admin.onAddUserText;
  flows.onSetDateText = console.onSetDateText;
  flows.onSyncCalendarText = console.onSyncCalendarText;

  bot.onError((error) {
    processLog('bot error: ${error.error}');
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
  if (adminApi != null) await adminApi.start();
  processLog('SDSC bot starting (long polling)...');

  await bot.start();
  await stopCompleter.future;

  await ipcServer?.stop();
  await adminApi?.stop();
  scheduler.stop();
  database.close();
  processLog('SDSC bot stopped.');
  exit(0);
}

/// Prints to stdout and keeps a copy in the in-memory log ring for the admin
/// API `/logs` endpoint.
void processLog(String line) => LogRing.log(line);
