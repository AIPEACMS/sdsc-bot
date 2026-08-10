import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:sdsc_bot/bot/calendar_sync.dart';
import 'package:sdsc_bot/bot/admin_api.dart';
import 'package:sdsc_bot/bot/hold.dart';

void main() {
  late Directory tmp;
  late Database db;
  late Repo repo;
  late AdminApi api;

  const token = 'secret-token';

  Config makeConfig() => Config(
        botToken: 'test',
        dbPath: '${tmp.path}/test.db',
        consoleId: 1,
        groupAContact: 'TBD',
        groupBContact: 'TBD',
        ocbcCapacity: 2,
        prCapacity: 20,
        slotTimes: {
          'am': ('09:00', '12:00'),
          'pm': ('13:00', '17:00'),
        },
        promptHour: 8,
        reminderHour: 18,
        deadlineHour: 18,
        allocationHour: 9,
        bailHour: 12,
        timezoneOffsetHours: 8,
      );

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sdsc_api_');
    final config = makeConfig();
    db = Database.open(config);
    repo = Repo(db);
    final gate = HoldGate(false);
    api = AdminApi(
      repo: repo,
      config: config,
      calendarSync: CalendarSync(repo: repo, config: config),
      holdGate: gate,
      token: token,
      port: 0,
    );
    await api.start();
  });

  tearDown(() async {
    await api.stop();
    db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<(int, Object?)> call(
    String method,
    String path, {
    Object? body,
    bool authorized = true,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(method, Uri.parse(
          'http://127.0.0.1:${api.boundPort}$path'));
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

  test('rejects requests without the bearer token', () async {
    final client = HttpClient();
    try {
      final req = await client.openUrl('GET',
          Uri.parse('http://127.0.0.1:${api.boundPort}/api/users'));
      final res = await req.close();
      expect(res.statusCode, 401);
      await res.drain<void>();
    } finally {
      client.close(force: true);
    }
  });

  test('GET /api/users lists users with resolved tiers', () async {
    repo.upsertUser(User(
      id: 101,
      name: '@alice',
      experience: Experience.experienced,
      group: 'A',
    ));
    repo.upsertUser(User(
      id: 2,
      name: '@bob',
      experience: Experience.newbie,
      group: 'B',
    ));
    repo.setTier(2, 'check');

    final (status, body) = await call('GET', '/api/users');
    expect(status, 200);
    final bodyMap = body as Map<String, dynamic>;
    final users = (bodyMap['users'] as List).cast<Map<String, dynamic>>();
    expect(users, hasLength(2));
    final alice = users.firstWhere((u) => u['id'] == 101);
    final bob = users.firstWhere((u) => u['id'] == 2);
    expect(alice['tier'], 'member');
    expect(bob['tier'], 'check');
    expect(alice['group'], 'A');
    expect(alice['attendance'], containsPair('total', 0));
  });

  test('POST /api/users/{id}/tier changes the tier', () async {
    repo.upsertUser(User(
      id: 7,
      name: '@carol',
      experience: Experience.newbie,
      group: 'A',
    ));
    final (status, body) = await call('POST', '/api/users/7/tier',
        body: {'tier': 'admin'});
    final bodyMap = body as Map<String, dynamic>;
    expect(status, 200);
    expect(bodyMap['ok'], true);
    expect(bodyMap['tier'], 'admin');
    expect(repo.findUser(7)!.isAdmin, true);

    await call('POST', '/api/users/7/tier', body: {'tier': 'old'});
    expect(repo.findUser(7)!.memberTier, 'old');
    expect(repo.findUser(7)!.isAdmin, false);
  });

  test('POST /api/hold flips the gate and persists it', () async {
    await call('POST', '/api/hold', body: {'held': true});
    expect(repo.isHeld(), true);
    final (_, state) = await call('GET', '/api/state');
    final stateMap = state as Map<String, dynamic>;
    expect(stateMap['held'], true);
    expect(stateMap['cycle'], containsPair('status', anything));

    await call('POST', '/api/hold', body: {'held': false});
    expect(repo.isHeld(), false);
  });

  test('POST /api/date sets and resets the debug clock', () async {
    await call('GET', '/api/state'); // warm up
    Config.setDebugNow(null);
    final (_, set) = await call('POST', '/api/date',
        body: {'date': '2026-08-10 08:00'});
    final setMap = set as Map<String, dynamic>;
    expect(setMap['ok'], true);
    final local = Config.nowUtc().toUtc().toLocal();
    expect(local.day, 10);

    final (_, reset) = await call('POST', '/api/date',
        body: {'reset': true});
    final resetMap = reset as Map<String, dynamic>;
    expect(resetMap['ok'], true);
  });

  test('GET /api/logs returns the in-memory ring', () async {
    LogRing.log('hello from the test');
    final (_, body) = await call('GET', '/api/logs');
    final bodyMap = body as Map<String, dynamic>;
    final lines = (bodyMap['lines'] as List).cast<String>();
    expect(lines.any((l) => l.contains('hello from the test')), isTrue);
    expect(lines.length, greaterThan(0));
  });

  test('bad tier and unknown user are rejected', () async {
    repo.upsertUser(User(
      id: 9,
      name: '@dave',
      experience: Experience.newbie,
      group: 'A',
    ));
    final (badStatus, bad) = await call('POST', '/api/users/9/tier',
        body: {'tier': 'chief'});
    final badMap = bad as Map<String, dynamic>;
    expect(badStatus, 400);
    expect(badMap['error'], contains('bad tier'));
    final (missingStatus, missing) = await call('POST', '/api/users/999/tier',
        body: {'tier': 'member'});
    final missingMap = missing as Map<String, dynamic>;
    expect(missingStatus, 404);
    expect(missingMap['error'], contains('no such user'));
  });
}