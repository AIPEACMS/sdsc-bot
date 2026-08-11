import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:sdsc_bot/bot/calendar_sync.dart';
import 'package:sdsc_bot/bot/admin_api.dart';
import 'package:sdsc_bot/bot/hold.dart';
import 'package:sdsc_bot/bot/key_auth.dart';

/// Deterministic 32-byte ed25519 seed for the test console key.
final List<int> _seed = List<int>.generate(32, (i) => i + 13);

void main() {
  late Directory tmp;
  late Database db;
  late Repo repo;
  late AdminApi api;
  final rand = Random();

  const token = 'secret-token';

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

    // Register the test console key so signed requests authenticate.
    final (pub, _) = await KeyAuth.signWithSeed(
      seed: _seed,
      message: utf8.encode('seed'),
    );
    repo.addConsoleKey(pub, name: 'test');
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

  /// Sends a request signed with the test console key. [body] is covered by
  /// the signature via its sha256, so send the EXACT bytes you intend.
  Future<(int, Object?)> signedCall(
    String method,
    String path, {
    Object? body,
    String? ts,
    String? nonce,
  }) async {
    final tsNow = ts ?? DateTime.now().millisecondsSinceEpoch.toString();
    final nonceNow =
        nonce ?? '${rand.nextInt(1 << 32)}-${rand.nextInt(1 << 32)}';
    final bodyBytes =
        body == null ? utf8.encode('') : utf8.encode(jsonEncode(body));
    final (pub, sig) = await signKey(method, path, KeyAuth.bodyHash(bodyBytes),
        ts: tsNow, nonce: nonceNow);

    final client = HttpClient();
    try {
      final req = await client.openUrl(method, Uri.parse(
          'http://127.0.0.1:${api.boundPort}$path'));
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

  /// GET with raw headers returned, so server-signature headers can be read.
  Future<(int, Map<String, String>, String)> rawGet(String path) async {
    final client = HttpClient();
    try {
      final req = await client
          .openUrl('GET', Uri.parse('http://127.0.0.1:${api.boundPort}$path'));
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final headers = <String, String>{};
      res.headers.forEach((name, values) => headers[name.toLowerCase()] =
          values.isEmpty ? '' : values.first);
      return (res.statusCode, headers, text);
    } finally {
      client.close(force: true);
    }
  }

  test('GET /api/server-info exposes the server identity for pinning', () async {
    final (status, headers, body) = await rawGet('/api/server-info');
    expect(status, 200);
    final json = jsonDecode(body) as Map<String, dynamic>;
    expect(json['ok'], true);
    expect(json['pubkey'], isNotEmpty);
    expect(json['fingerprint'], KeyAuth.fingerprint(json['pubkey'] as String));
    // Unauthenticated — reachable before any key is registered.
    expect(headers['x-sdsc-server-pub'], json['pubkey']);
    expect(headers['x-sdsc-server-sig'], isNotEmpty);
  });

  test('every response is signed by the server identity', () async {
    final (_, _, infoBody) = await rawGet('/api/server-info');
    final serverPub = (jsonDecode(infoBody) as Map<String, dynamic>)['pubkey']
        as String;

    final client = HttpClient();
    try {
      final req = await client
          .openUrl('GET', Uri.parse('http://127.0.0.1:${api.boundPort}/api/state'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final headers = <String, String>{};
      res.headers.forEach((name, values) => headers[name.toLowerCase()] =
          values.isEmpty ? '' : values.first);

      expect(headers['x-sdsc-server-pub'], serverPub);
      final ts = headers['x-sdsc-server-ts']!;
      final sig = headers['x-sdsc-server-sig']!;
      final message = KeyAuth.serverMessage(
        method: 'GET',
        path: '/api/state',
        ts: ts,
        nonce: '', // bearer-token request, no client nonce
        bodyHash: KeyAuth.bodyHash(utf8.encode(text)),
      );
      expect(
        await KeyAuth.verifySignature(
          pubkeyB64: serverPub,
          signatureB64: sig,
          message: utf8.encode(message),
        ),
        isTrue,
      );
    } finally {
      client.close(force: true);
    }
  });

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

  test('POST /api/log-retention changes the retained window', () async {
    final (_, state) = await call('GET', '/api/state');
    final stateMap = state as Map<String, dynamic>;
    expect(stateMap['logRetentionDays'], 14);

    final (status, body) = await call('POST', '/api/log-retention',
        body: {'days': 30});
    final bodyMap = body as Map<String, dynamic>;
    expect(status, 200);
    expect(bodyMap['ok'], true);
    expect(bodyMap['days'], 30);
    expect(LogRing.retentionDays, 30);
    expect(repo.getSetting('log_retention_days'), '30');

    final (_, state2) = await call('GET', '/api/state');
    final stateMap2 = state2 as Map<String, dynamic>;
    expect(stateMap2['logRetentionDays'], 30);

    // Reset for other tests.
    await call('POST', '/api/log-retention', body: {'days': 14});
    expect(LogRing.retentionDays, 14);
  });

  test('POST /api/log-retention rejects nonsense input', () async {
    final (status, body) =
        await call('POST', '/api/log-retention', body: {'days': -1});
    final bodyMap = body as Map<String, dynamic>;
    expect(status, 400);
    expect(bodyMap['error'], contains('positive int'));
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

  // ---------------------------------------------------------- key auth

  test('a registered console key authenticates signed requests', () async {
    final (status, body) = await signedCall('GET', '/api/users');
    final bodyMap = body as Map<String, dynamic>;
    expect(status, 200);
    expect(bodyMap['ok'], true);
  });

  test('an unregistered key is rejected even with a valid signature', () async {
    final key = repo.listConsoleKeys().single.pubkey;
    repo.removeConsoleKey(key);
    final (status, _) = await signedCall('GET', '/api/users');
    expect(status, 401);
  });

  test('a signed request with a tampered body is rejected', () async {
    // Sign for body {"held":true} but actually send
    // {"held":false}: the sha256 in the signature no longer matches.
    final bodyBytes = utf8.encode(jsonEncode({'held': true}));
    final bodyHash = KeyAuth.bodyHash(bodyBytes);
    final ts = DateTime.now().millisecondsSinceEpoch.toString();
    final nonce = 'tamper-${rand.nextInt(1 << 32)}';
    final (pub, sig) = await signKey('POST', '/api/hold', bodyHash,
        ts: ts, nonce: nonce);

    final client = HttpClient();
    try {
      final req = await client.postUrl(
          Uri.parse('http://127.0.0.1:${api.boundPort}/api/hold'));
      req.headers.set('X-SDSC-Pub', pub);
      req.headers.set('X-SDSC-Ts', ts);
      req.headers.set('X-SDSC-Nonce', nonce);
      req.headers.set('X-SDSC-Sig', sig);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'held': false}));
      final res = await req.close();
      expect(res.statusCode, 401);
      await res.drain<void>();
    } finally {
      client.close(force: true);
    }
  });

  test('replaying the same signed request (nonce) is rejected', () async {
    final ts = DateTime.now().millisecondsSinceEpoch.toString();
    final nonce = 'replay-${rand.nextInt(1 << 32)}';
    final first = await signedCall('GET', '/api/state', ts: ts, nonce: nonce);
    expect(first.$1, 200);
    final second = await signedCall('GET', '/api/state', ts: ts, nonce: nonce);
    expect(second.$1, 401);
  });

  test('a stale timestamp is rejected', () async {
    final stale =
        (DateTime.now().millisecondsSinceEpoch - 10 * 60 * 1000).toString();
    final (status, _) = await signedCall('GET', '/api/state', ts: stale);
    expect(status, 401);
  });

  test('a signature bound to another path is rejected', () async {
    // Sign the message for /api/state but hit /api/users.
    final bodyHash = KeyAuth.bodyHash(utf8.encode(''));
    final ts = DateTime.now().millisecondsSinceEpoch.toString();
    final nonce = 'path-${rand.nextInt(1 << 32)}';
    final (pub, sig) = await signKey('GET', '/api/state', bodyHash,
        ts: ts, nonce: nonce);

    final client = HttpClient();
    try {
      final req = await client
          .openUrl('GET', Uri.parse('http://127.0.0.1:${api.boundPort}/api/users'));
      req.headers.set('X-SDSC-Pub', pub);
      req.headers.set('X-SDSC-Ts', ts);
      req.headers.set('X-SDSC-Nonce', nonce);
      req.headers.set('X-SDSC-Sig', sig);
      final res = await req.close();
      expect(res.statusCode, 401);
      await res.drain<void>();
    } finally {
      client.close(force: true);
    }
  });

  test('the calendar IPC token never authorizes the admin API', () async {
    final client = HttpClient();
    try {
      final req = await client
          .openUrl('GET', Uri.parse('http://127.0.0.1:${api.boundPort}/api/state'));
      req.headers.set(
          HttpHeaders.authorizationHeader, 'Bearer calendar-cron-token');
      final res = await req.close();
      expect(res.statusCode, 401);
      await res.drain<void>();
    } finally {
      client.close(force: true);
    }
  });

  // ------------------------------------------------------------ groups

  test('GET /api/users reports every group of a user', () async {
    // Id 1 is the console id in this test config (makeConfig).
    repo.upsertUser(User(
      id: 1,
      name: '@root',
      experience: Experience.experienced,
      group: 'A',
      isAdmin: true,
    ));
    repo.upsertUser(User(
      id: 101,
      name: '@alice',
      experience: Experience.newbie,
      group: 'A',
      isAdmin: true,
    ));
    repo.upsertUser(User(
      id: 2,
      name: '@bob',
      experience: Experience.newbie,
      group: 'B',
    ));
    repo.setTier(2, 'check');
    repo.upsertUser(User(
      id: 3,
      name: '@carol',
      experience: Experience.newbie,
      group: 'A',
    ));
    repo.setTier(3, 'old');
    repo.upsertUser(User(
      id: 4,
      name: '@dave',
      experience: Experience.newbie,
      group: 'B',
    ));

    final (status, body) = await call('GET', '/api/users');
    expect(status, 200);
    final users =
        ((body as Map<String, dynamic>)['users'] as List)
            .cast<Map<String, dynamic>>();

    String? groupOf(int id) {
      final u = users.firstWhere((u) => u['id'] == id);
      return (u['groups'] as List).cast<String>().join(' | ');
    }

    expect(groupOf(1), 'console | admin');
    expect(groupOf(101), 'admin');
    expect(groupOf(2), 'check');
    expect(groupOf(3), 'old');
    expect(groupOf(4), 'member');
  });

  test('a console who stepped down as admin shows console | member',
      () async {
    repo.upsertUser(User(
      id: 1,
      name: '@root',
      experience: Experience.experienced,
      group: 'A',
      isAdmin: true,
    ));
    // Console removes their own admin flag: still a member, not an admin.
    await call('POST', '/api/users/1/admin', body: {'admin': false});
    final (_, body) = await call('GET', '/api/users');
    final users =
        ((body as Map<String, dynamic>)['users'] as List)
            .cast<Map<String, dynamic>>();
    final root = users.firstWhere((u) => u['id'] == 1);
    expect((root['groups'] as List).cast<String>(), ['console', 'member']);
    // Still active: a retired-from-admin console is a normal member.
    expect(repo.activeUsers().any((u) => u.id == 1), isTrue);
  });

  // ------------------------------------------------------- user admin

  test('POST /api/users/{id}/admin grants and strips admin, keeping the tier',
      () async {
    repo.upsertUser(User(
      id: 7,
      name: '@carol',
      experience: Experience.newbie,
      group: 'A',
    ));
    repo.setTier(7, 'check'); // check, not admin
    expect(repo.findUser(7)!.memberTier, 'check');

    final (status, body) = await call('POST', '/api/users/7/admin',
        body: {'admin': true});
    expect(status, 200);
    expect((body as Map<String, dynamic>)['admin'], true);
    expect(repo.findUser(7)!.isAdmin, true);
    expect(repo.findUser(7)!.memberTier, 'check'); // tier untouched

    await call('POST', '/api/users/7/admin', body: {'admin': false});
    expect(repo.findUser(7)!.isAdmin, false);
    expect(repo.findUser(7)!.memberTier, 'check');

    // The console can also toggle their own admin flag (stepping down as
    // admin while staying the console).
    repo.upsertUser(User(
      id: 1,
      name: '@root',
      experience: Experience.experienced,
      group: 'A',
      isAdmin: true,
    ));
    final (consoleStatus, _) = await call('POST', '/api/users/1/admin',
        body: {'admin': false});
    expect(consoleStatus, 200);
    expect(repo.findUser(1)!.isAdmin, false);
  });

  test('the console can demote themselves to old (no prompts, no allocation)',
      () async {
    // Id 1 is the console id in this test config.
    repo.upsertUser(User(
      id: 1,
      name: '@root',
      experience: Experience.experienced,
      group: 'A',
      isAdmin: true,
    ));
    final (status, body) =
        await call('POST', '/api/users/1/tier', body: {'tier': 'old'});
    expect(status, 200);
    final u = repo.findUser(1)!;
    expect(u.memberTier, 'old');
    expect(u.isAdmin, false);
    // Dropped from the prompt/allocation pool.
    expect(repo.activeUsers().any((x) => x.id == 1), isFalse);
    // Still reported as the console, with the old-mem group visible.
    final (_, usersBody) = await call('GET', '/api/users');
    final users = ((usersBody as Map<String, dynamic>)['users'] as List)
        .cast<Map<String, dynamic>>();
    final root = users.firstWhere((u) => u['id'] == 1);
    expect((root['groups'] as List).cast<String>(), ['console', 'old']);

    // They can promote themselves back to an active member.
    await call('POST', '/api/users/1/tier', body: {'tier': 'member'});
    expect(repo.activeUsers().any((x) => x.id == 1), isTrue);
  });

  test('POST /api/users/{id}/exp changes experience', () async {
    repo.upsertUser(User(
      id: 7,
      name: '@carol',
      experience: Experience.newbie,
      group: 'A',
    ));
    final (status, body) = await call('POST', '/api/users/7/exp',
        body: {'exp': 'experienced'});
    expect(status, 200);
    expect((body as Map<String, dynamic>)['exp'], 'experienced');
    expect(repo.findUser(7)!.experience, Experience.experienced);

    final (badStatus, _) = await call('POST', '/api/users/7/exp',
        body: {'exp': 'senior'});
    expect(badStatus, 400);
    final (missingStatus, _) = await call('POST', '/api/users/999/exp',
        body: {'exp': 'newbie'});
    expect(missingStatus, 404);
  });

  test('POST /api/users registers or queues a member by handle', () async {
    // Unseen, unqueued handle → queued for first contact.
    final (q, _) =
        await call('POST', '/api/users', body: {'handle': '@newbie'});
    expect(q, 200);
    expect(repo.isPendingUser('newbie'), true);

    // A seen user is registered immediately as a plain member.
    repo.upsertSeenUser(202, 'alice');
    final (s, _) =
        await call('POST', '/api/users', body: {'handle': '@alice'});
    expect(s, 200);
    expect(repo.findUser(202), isNotNull);
    expect(repo.findUser(202)!.isAdmin, false);

    // Already a member → reported, no duplicate.
    final (d, dBody) =
        await call('POST', '/api/users', body: {'handle': '@alice'});
    expect(d, 200);
    expect((dBody as Map<String, dynamic>)['message'],
        contains('already a member'));

    // Garbage input is rejected.
    final (bad, _) =
        await call('POST', '/api/users', body: {'handle': 'two words'});
    expect(bad, 400);
  });

  // ------------------------------------------------------ cycle ops

  test('cycle ops require a wired service', () async {
    final (p, pBody) = await call('POST', '/api/prompt');
    expect(p, 400);
    expect((pBody as Map<String, dynamic>)['error'], contains('not wired'));

    final (r, _) = await call('POST', '/api/remind');
    expect(r, 400);
    final (a, _) = await call('POST', '/api/allocate');
    expect(a, 400);
    final (ask, _) = await call('POST', '/api/ask');
    expect(ask, 400);
    final (b, _) = await call('POST', '/api/broadcast');
    expect(b, 400);
  });

  // ------------------------------------------------------- attendance

  test('attendance lists sessions and toggles per member', () async {
    repo.upsertUser(User(
      id: 101,
      name: '@alice',
      experience: Experience.experienced,
      group: 'A',
    ));
    repo.upsertUser(User(
      id: 102,
      name: '@bob',
      experience: Experience.newbie,
      group: 'B',
    ));
    final now = api.config.toLocal(Config.nowUtc());
    final cycle = repo.ensureCurrentCycle(now);
    repo.ensureSessionsForCycle(
      cycle,
      api.config.slotTimes,
      tzOffsetHours: api.config.timezoneOffsetHours,
    );
    final sessions = repo.sessionsForCycle(cycle.id);
    expect(sessions, isNotEmpty);
    final sessionId = sessions.first.id;
    repo.replaceAllocations(cycle.id, [(101, sessionId), (102, sessionId)]);

    final (status, body) = await call('GET', '/api/attendance');
    expect(status, 200);
    final s = ((body as Map<String, dynamic>)['sessions'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((s) => s['id'] == sessionId);
    expect(s['label'], isNotEmpty);
    expect(s['location'], isNotEmpty);
    expect((s['weekendIndex'] as num?)?.toInt(), inInclusiveRange(0, 1));
    expect(['sat', 'sun'], contains(s['day']));
    expect(['am', 'pm'], contains(s['slot']));
    final members = (s['members'] as List).cast<Map<String, dynamic>>();
    expect(members, hasLength(2));
    expect(members.every((m) => m['attended'] == false), isTrue);

    final (t1, t1Body) = await call('POST', '/api/attendance',
        body: {'sessionId': sessionId, 'userId': 101});
    expect(t1, 200);
    expect((t1Body as Map<String, dynamic>)['attended'], true);
    expect(repo.attendanceForSession(sessionId), hasLength(1));

    final (t2, t2Body) = await call('POST', '/api/attendance',
        body: {'sessionId': sessionId, 'userId': 101});
    expect(t2, 200);
    expect((t2Body as Map<String, dynamic>)['attended'], false);
    expect(repo.attendanceForSession(sessionId), isEmpty);

    final (bad, _) = await call('POST', '/api/attendance',
        body: {'sessionId': sessionId});
    expect(bad, 400);
  });

  // ------------------------------------------------------- group model

  test('POST /api/assign-groups distributes ungrouped members evenly',
      () async {
    repo.upsertUser(User(
      id: 1,
      name: '@root',
      experience: Experience.experienced,
      group: '1',
      isAdmin: true,
    ));
    repo.upsertUser(User(
      id: 11,
      name: '@lead2',
      experience: Experience.experienced,
      group: '2',
      isAdmin: true,
    ));
    for (var i = 100; i < 105; i++) {
      repo.upsertUser(User(
        id: i,
        name: '@m$i',
        experience: Experience.newbie,
        group: '',
      ));
    }
    // check/old have no group but must NOT be assigned.
    repo.upsertUser(User(
      id: 200, name: '@checker', experience: Experience.newbie, group: '',
    ));
    repo.setTier(200, 'check');
    repo.upsertUser(User(
      id: 201, name: '@former', experience: Experience.newbie, group: '',
    ));
    repo.setTier(201, 'old');

    final (status, body) = await call('POST', '/api/assign-groups');
    expect(status, 200);
    expect((body as Map<String, dynamic>)['assigned'], 5);

    final counts = <String, int>{};
    for (var i = 100; i < 105; i++) {
      final g = repo.findUser(i)!.group;
      expect(g, isNotEmpty);
      counts[g] = (counts[g] ?? 0) + 1;
    }
    expect(counts.length, 2); // split across both leader groups
    expect(counts.values.every((c) => c >= 2 && c <= 3), isTrue);
    // check/old untouched, admins untouched.
    expect(repo.findUser(200)!.group, '');
    expect(repo.findUser(201)!.group, '');
    expect(repo.findUser(1)!.group, '1');
    expect(repo.findUser(11)!.group, '2');
  });

  test('POST /api/users/{id}/group moves or ungroups a member, blocked for '
      'admins', () async {
    repo.upsertUser(User(
      id: 1,
      name: '@root',
      experience: Experience.experienced,
      group: '1',
      isAdmin: true,
    ));
    repo.upsertUser(User(
      id: 11,
      name: '@lead2',
      experience: Experience.experienced,
      group: '2',
      isAdmin: true,
    ));
    repo.upsertUser(User(
      id: 101, name: '@alice', experience: Experience.newbie, group: '',
    ));

    final (m, mBody) = await call('POST', '/api/users/101/group',
        body: {'group': '2'});
    expect(m, 200);
    expect((mBody as Map<String, dynamic>)['group'], '2');
    expect(repo.findUser(101)!.group, '2');

    final (r, _) = await call('POST', '/api/users/101/group',
        body: {'group': ''});
    expect(r, 200);
    expect(repo.findUser(101)!.group, '');

    // An admin cannot be moved or removed from their own group.
    final (a, aBody) = await call('POST', '/api/users/11/group',
        body: {'group': ''});
    expect(a, 400);
    expect((aBody as Map<String, dynamic>)['error'], contains('demote'));
    expect(repo.findUser(11)!.group, '2');

    // Unknown groups are rejected.
    final (u, _) = await call('POST', '/api/users/101/group',
        body: {'group': '9'});
    expect(u, 400);
  });

  test('promotion assigns the lowest free group; demotion dissolves it',
      () async {
    repo.upsertUser(User(
      id: 1,
      name: '@root',
      experience: Experience.experienced,
      group: '1',
      isAdmin: true,
    ));
    repo.upsertUser(User(
      id: 101, name: '@alice', experience: Experience.newbie, group: '1',
    ));
    repo.upsertUser(User(
      id: 102, name: '@bob', experience: Experience.newbie, group: '',
    ));

    // Promote bob → lowest free group is 2 (1 is taken by root).
    await call('POST', '/api/users/102/tier', body: {'tier': 'admin'});
    expect(repo.findUser(102)!.isAdmin, true);
    expect(repo.findUser(102)!.group, '2');

    // Demote root (console, group 1) → group 1 dissolves: alice loses it too.
    await call('POST', '/api/users/1/admin', body: {'admin': false});
    expect(repo.findUser(1)!.isAdmin, false);
    expect(repo.findUser(1)!.group, '');
    expect(repo.findUser(101)!.group, '');

    // Promote alice → group 1 is free again (bob holds 2) → gap filled.
    await call('POST', '/api/users/101/admin', body: {'admin': true});
    expect(repo.findUser(101)!.group, '1');
    expect(repo.findUser(102)!.group, '2');
  });
}