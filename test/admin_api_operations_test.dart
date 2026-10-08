
import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:sdsc_bot/bot/calendar_sync.dart';
import 'package:sdsc_bot/bot/admin_api.dart';
import 'package:sdsc_bot/bot/hold.dart';
import 'support/admin_api_harness.dart';

void main() {
  setUp(setUpAdminApi);
  tearDown(tearDownAdminApi);
  test('POST /api/hold flips the gate and persists it', () async {
    await call('POST', '/api/hold', body: {'held': true});
    expect(repo.isHeld(), true);
    final (_, state) = await call('GET', '/api/state');
    final stateMap = state as Map<String, dynamic>;
    expect(stateMap['held'], true);
    expect(stateMap['window'], containsPair('weekend0', anything));
    expect(stateMap['window'], containsPair('deadline0', anything));

    await call('POST', '/api/hold', body: {'held': false});
    expect(repo.isHeld(), false);
  });

  test('active outreach API validates and updates one route', () async {
    final (_, initialBody) = await call('GET', '/api/state');
    final initial = initialBody as Map<String, dynamic>;
    final initialRoutes = (initial['activeOutreach'] as Map).cast<String, bool>();
    expect(initialRoutes.length, 9);
    expect(initialRoutes.values, everyElement(isTrue));

    final (status, body) = await call(
      'POST',
      '/api/active-outreach',
      body: {'route': 'prompt', 'enabled': false},
    );
    expect(status, 200);
    expect((body as Map<String, dynamic>)['activeOutreach'],
        containsPair('prompt', false));
    expect(repo.activeOutreachEnabled('reminder'), isTrue);

    final (unknownStatus, _) = await call(
      'POST',
      '/api/active-outreach',
      body: {'route': 'nope', 'enabled': false},
    );
    expect(unknownStatus, 400);
    final (malformedStatus, _) = await call(
      'POST',
      '/api/active-outreach',
      body: {'route': 'prompt', 'enabled': 'no'},
    );
    expect(malformedStatus, 400);
    final (extraStatus, _) = await call(
      'POST',
      '/api/active-outreach',
      body: {'route': 'prompt', 'enabled': true, 'extra': true},
    );
    expect(extraStatus, 400);
  });

  test('POST /api/date sets and resets the debug clock', () async {
    await call('GET', '/api/state'); // warm up
    Config.setDebugNow(null);
    final (_, set) = await call(
      'POST',
      '/api/date',
      body: {'date': '2026-08-10 08:00'},
    );
    final setMap = set as Map<String, dynamic>;
    expect(setMap['ok'], true);
    final local = Config.nowUtc().toUtc().toLocal();
    expect(local.day, 10);

    final (_, reset) = await call('POST', '/api/date', body: {'reset': true});
    final resetMap = reset as Map<String, dynamic>;
    expect(resetMap['ok'], true);
  });

  test('schedule API returns normalized values and updates state', () async {
    final (getStatus, getBody) = await call('GET', '/api/schedule');
    expect(getStatus, 200);
    final initial = getBody as Map<String, dynamic>;
    expect(initial['schedule'], containsPair('prompt', '18:00'));
    expect(initial['schedule'], containsPair('checker', '21:00'));
    expect(initial['schedule'], containsPair('promptWeekday', 'mon'));
    expect(initial['schedule'], containsPair('reminderWeekday', 'thu'));
    expect(initial['timezoneOffset'], 8);

    final (postStatus, postBody) = await call(
      'POST',
      '/api/schedule',
      body: {
        'prompt': '07:05',
        'reminder': '08:06',
        'lock': '19:10',
        'checker': '21:20',
      },
    );
    expect(postStatus, 200);
    final updated = postBody as Map<String, dynamic>;
    expect(updated['schedule'], containsPair('lock', '19:10'));
    expect(updated['schedule'], containsPair('promptWeekday', 'mon'));
    expect(repo.readSchedule().prompt.value, '07:05');

    final (weekdayStatus, weekdayBody) = await call(
      'POST',
      '/api/schedule',
      body: {'reminderWeekday': 'wed'},
    );
    expect(weekdayStatus, 200);
    expect(
      (weekdayBody as Map<String, dynamic>)['schedule'],
      containsPair('reminderWeekday', 'wed'),
    );
    expect(repo.readSchedule().prompt.value, '07:05');

    final (_, stateBody) = await call('GET', '/api/state');
    final state = stateBody as Map<String, dynamic>;
    expect(state['promptWeekday'], 'mon');
    expect(state['schedule'], containsPair('checker', '21:20'));
    expect(state['schedule'], containsPair('reminderWeekday', 'wed'));
  });

  test('schedule API rejects malformed times and checker before lock', () async {
    final (badTimeStatus, _) = await call(
      'POST',
      '/api/schedule',
      body: {'prompt': '7:05'},
    );
    expect(badTimeStatus, 400);
    final (badOrderStatus, badOrderBody) = await call(
      'POST',
      '/api/schedule',
      body: {'lock': '20:00', 'checker': '20:00'},
    );
    expect(badOrderStatus, 400);
    expect((badOrderBody as Map<String, dynamic>)['error'], contains('checker'));

    final (weekendStatus, weekendBody) = await call(
      'POST',
      '/api/schedule',
      body: {'promptWeekday': 'sat'},
    );
    expect(weekendStatus, 400);
    expect((weekendBody as Map<String, dynamic>)['error'], contains('weekday'));

    final (emptyStatus, _) = await call(
      'POST',
      '/api/schedule',
      body: <String, Object?>{},
    );
    expect(emptyStatus, 400);
    final (unknownStatus, _) = await call(
      'POST',
      '/api/schedule',
      body: {'promptDay': 'mon'},
    );
    expect(unknownStatus, 400);
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

    final (status, body) = await call(
      'POST',
      '/api/log-retention',
      body: {'days': 30},
    );
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
    final (status, body) = await call(
      'POST',
      '/api/log-retention',
      body: {'days': -1},
    );
    final bodyMap = body as Map<String, dynamic>;
    expect(status, 400);
    expect(bodyMap['error'], contains('positive int'));
  });

  test('bad tier and unknown user are rejected', () async {
    repo.upsertUser(
      User(id: 9, name: '@dave', experience: Experience.newbie, group: 'A'),
    );
    final (badStatus, bad) = await call(
      'POST',
      '/api/users/9/tier',
      body: {'tier': 'chief'},
    );
    final badMap = bad as Map<String, dynamic>;
    expect(badStatus, 400);
    expect(badMap['error'], contains('bad tier'));
    final (missingStatus, missing) = await call(
      'POST',
      '/api/users/999/tier',
      body: {'tier': 'member'},
    );
    final missingMap = missing as Map<String, dynamic>;
    expect(missingStatus, 404);
    expect(missingMap['error'], contains('no such user'));
  });

  // ------------------------------------------------------ cycle ops

  test('cycle ops require a wired service', () async {
    // A bare instance without a cycle service must refuse cycle ops.
    final bare = AdminApi(
      repo: repo,
      config: api.config,
      calendarSync: CalendarSync(repo: repo, config: api.config),
      holdGate: HoldGate(false),
      token: token,
      port: 0,
    );
    await bare.start();
    try {
      final (p, pBody) = await call('POST', '/api/prompt', on: bare);
      expect(p, 400);
      expect((pBody as Map<String, dynamic>)['error'], contains('not wired'));

      final (r, _) = await call('POST', '/api/remind', on: bare);
      expect(r, 400);
      final (a, _) = await call('POST', '/api/allocate', on: bare);
      expect(a, 400);
      final (ask, _) = await call('POST', '/api/ask', on: bare);
      expect(ask, 400);
      final (b, _) = await call('POST', '/api/broadcast', on: bare);
      expect(b, 400);
    } finally {
      await bare.stop();
    }
  });
}
