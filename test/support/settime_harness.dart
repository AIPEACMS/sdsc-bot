import 'dart:convert';
import 'dart:io';

import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:sdsc_bot/bot/admin_api.dart';
import 'package:sdsc_bot/bot/calendar_sync.dart';
import 'package:sdsc_bot/bot/hold.dart';

late Directory tmp;
late Database db;
late Repo repo;
late AdminApi api;
const token = 'secret-token';

Config configForTest(Directory directory) => Config(
  botToken: 'test',
  dbPath: '${directory.path}/test.db',
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

void setUpRepoHarness(String prefix) {
  tmp = Directory.systemTemp.createTempSync(prefix);
  db = Database.open(configForTest(tmp));
  repo = Repo(db);
}

void tearDownRepoHarness() {
  db.close();
  tmp.deleteSync(recursive: true);
}

Future<void> setUpLocationApi() async {
  tmp = Directory.systemTemp.createTempSync('sdsc_lapi_');
  final config = configForTest(tmp);
  db = Database.open(config);
  repo = Repo(db);
  api = AdminApi(
    repo: repo,
    config: config,
    calendarSync: CalendarSync(repo: repo, config: config),
    holdGate: HoldGate(false),
    token: token,
    port: 0,
  );
  await api.start();
}

Future<void> tearDownLocationApi() async {
  await api.stop();
  db.close();
  tmp.deleteSync(recursive: true);
}

Future<(int, Object?)> call(String method, String path, {Object? body}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${api.boundPort}$path'),
    );
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    return (
      res.statusCode,
      text.isEmpty ? <String, dynamic>{} : jsonDecode(text),
    );
  } finally {
    client.close(force: true);
  }
}
