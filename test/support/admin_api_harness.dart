import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:sdsc_bot/bot/admin_api.dart';
import 'package:sdsc_bot/bot/calendar_sync.dart';
import 'package:sdsc_bot/bot/hold.dart';
import 'package:sdsc_bot/bot/key_auth.dart';
import 'package:sdsc_bot/bot/service.dart';
import 'package:sdsc_bot/bot/state.dart';
import 'package:televerse/televerse.dart' hide HttpClient;

late Directory tmp;
late Database db;
late Repo repo;
late AdminApi api;
final rand = Random();
const token = 'secret-token';
final _seed = List<int>.generate(32, (i) => i + 13);

Config makeConfig() => Config(
  botToken: 'test',
  dbPath: '${tmp.path}/test.db',
  consoleId: 1,
  groupAContact: 'TBD',
  groupBContact: 'TBD',
  ocbcCapacity: 2,
  prCapacity: 20,
  slotTimes: {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
  promptHour: 18,
  reminderHour: 18,
  deadlineHour: 18,
  allocationHour: 9,
  bailHour: 12,
  timezoneOffsetHours: 8,
);

Future<(String pub, String sig)> signKey(
  String method,
  String path,
  String bodyHash, {
  String? ts,
  String? nonce,
}) async {
  final t = ts ?? DateTime.now().millisecondsSinceEpoch.toString();
  final n = nonce ?? '${rand.nextInt(1 << 32)}-${rand.nextInt(1 << 32)}';
  final message = KeyAuth.message(
    method: method,
    path: path,
    ts: t,
    nonce: n,
    bodyHash: bodyHash,
  );
  final (pub, sig) = await KeyAuth.signWithSeed(
    seed: _seed,
    message: utf8.encode(message),
  );
  return (pub, sig);
}

Future<void> setUpAdminApi() async {
  tmp = Directory.systemTemp.createTempSync('sdsc_api_');
  final config = makeConfig();
  db = Database.open(config);
  repo = Repo(db);
  final gate = HoldGate(false);
  final service = CycleService(
    repo: repo,
    config: config,
    messages: Messages((g) => config.contactForGroup(g)),
    state: BotState(),
    bot: Bot.local('test-token', 'http://127.0.0.1:1'),
  );
  api = AdminApi(
    repo: repo,
    config: config,
    calendarSync: CalendarSync(repo: repo, config: config),
    holdGate: gate,
    service: service,
    token: token,
    port: 0,
  );
  await api.start();

  final (pub, _) = await KeyAuth.signWithSeed(
    seed: _seed,
    message: utf8.encode('seed'),
  );
  repo.addConsoleKey(pub, name: 'test');
}

Future<void> tearDownAdminApi() async {
  await api.stop();
  db.close();
  tmp.deleteSync(recursive: true);
}

Future<(int, Object?)> call(
  String method,
  String path, {
  Object? body,
  bool authorized = true,
  AdminApi? on,
}) async {
  final target = on ?? api;
  final client = HttpClient();
  try {
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${target.boundPort}$path'),
    );
    if (authorized) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    final decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
    return (res.statusCode, decoded);
  } finally {
    client.close(force: true);
  }
}

Future<(int, Object?)> signedCall(
  String method,
  String path, {
  Object? body,
  String? ts,
  String? nonce,
}) async {
  final tsNow = ts ?? DateTime.now().millisecondsSinceEpoch.toString();
  final nonceNow = nonce ?? '${rand.nextInt(1 << 32)}-${rand.nextInt(1 << 32)}';
  final bodyBytes = body == null ? utf8.encode('') : utf8.encode(jsonEncode(body));
  final (pub, sig) = await signKey(
    method,
    path,
    KeyAuth.bodyHash(bodyBytes),
    ts: tsNow,
    nonce: nonceNow,
  );

  final client = HttpClient();
  try {
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${api.boundPort}$path'),
    );
    req.headers.set('X-SDSC-Pub', pub);
    req.headers.set('X-SDSC-Ts', tsNow);
    req.headers.set('X-SDSC-Nonce', nonceNow);
    req.headers.set('X-SDSC-Sig', sig);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    final decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
    return (res.statusCode, decoded);
  } finally {
    client.close(force: true);
  }
}

Future<(int, Map<String, String>, String)> rawGet(String path) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(
      'GET',
      Uri.parse('http://127.0.0.1:${api.boundPort}$path'),
    );
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    final headers = <String, String>{};
    res.headers.forEach(
      (name, values) =>
          headers[name.toLowerCase()] = values.isEmpty ? '' : values.first,
    );
    return (res.statusCode, headers, text);
  } finally {
    client.close(force: true);
  }
}
