import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:sdsc_bot/bot/admin_api.dart';
import 'package:sdsc_bot/bot/calendar_sync.dart';
import 'package:sdsc_bot/bot/hold.dart';
import 'support/settime_harness.dart';

void main() {
  setUp(setUpLocationApi);
  tearDown(tearDownLocationApi);
  group('admin API locations', () {
    late Directory tmp;
    late Database db;
    late Repo repo;
    late AdminApi api;
    const token = 'secret-token';

    setUp(() async {
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
    });

    tearDown(() async {
      await api.stop();
      db.close();
      tmp.deleteSync(recursive: true);
    });

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

    test('GET /api/locations lists approved and pending', () async {
      repo.requestLocation('Marina Bay', requestedBy: 1);
      final (status, body) = await call('GET', '/api/locations');
      expect(status, 200);
      final map = body as Map<String, dynamic>;
      expect((map['approved'] as List).length, 2);
      final pending = (map['pending'] as List).cast<Map<String, dynamic>>();
      expect(pending.single['name'], 'Marina Bay');
      expect(pending.single['status'], 'pending');
    });

    test('POST /api/locations creates and approves by name', () async {
      var approved = <LocationInfo>[];
      api.onLocationApproved = (l) async => approved.add(l);
      repo.requestLocation('Marina Bay', requestedBy: 1);

      final (status, body) = await call(
        'POST',
        '/api/locations',
        body: {
          'name': 'Marina Bay',
          'aliases': ['MB'],
        },
      );
      expect(status, 200);
      final loc = (body as Map<String, dynamic>)['location'] as Map;
      expect(loc['status'], 'approved');
      expect(repo.resolveLocation('MB')!.name, 'Marina Bay');
      expect(approved.single.name, 'Marina Bay');
    });

    test('POST /api/locations/{id}/approve sets aliases', () async {
      final pending = repo.requestLocation('Marina Bay', requestedBy: 1);
      final (status, body) = await call(
        'POST',
        '/api/locations/${pending.id}/approve',
        body: {
          'aliases': ['MB', 'the bay'],
        },
      );
      expect(status, 200);
      expect((body as Map<String, dynamic>)['ok'], true);
      expect(repo.resolveLocation('the bay')!.key, pending.key);
      final (missing, _) = await call(
        'POST',
        '/api/locations/999/approve',
        body: const {},
      );
      expect(missing, 404);
    });
  });
}
