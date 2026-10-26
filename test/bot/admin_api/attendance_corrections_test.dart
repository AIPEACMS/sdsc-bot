import 'package:crypto/crypto.dart' show sha256;
import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:test/test.dart';
import '../../support/admin_api_harness.dart';

String _day(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

void _addAdmin(int id, {bool global = false, String group = '1'}) {
  repo.upsertUser(
    User(
      id: id,
      name: '@admin$id',
      experience: Experience.experienced,
      group: group,
      isAdmin: !global,
      isGlobalAdmin: global,
    ),
  );
}

void _addMember(int id, {String group = '1'}) {
  repo.upsertUser(
    User(
      id: id,
      name: '@member$id',
      experience: Experience.newbie,
      group: group,
    ),
  );
}

void _bindConsoleKey(int actorId) {
  final key = repo.listConsoleKeys().single;
  repo.raw.execute(
    'UPDATE console_keys SET actor_user_id = ? WHERE pubkey = ?',
    [actorId, key.pubkey],
  );
}

String _makePreviewTokenHash(String token) =>
    sha256.convert(token.codeUnits).toString();

Future<Map<String, dynamic>> _preview({
  required int targetId,
  required int delta,
  required String scope,
  String? date,
}) async {
  final body = <String, Object?>{
    'targetId': targetId,
    'delta': delta,
    'scope': scope,
    'date': date,
  };
  final (status, result) = await signedCall(
    'POST',
    '/api/attendance-corrections/preview',
    body: body,
  );
  expect(status, 200, reason: '$result');
  return result as Map<String, dynamic>;
}

void main() {
  setUp(setUpAdminApi);
  tearDown(tearDownAdminApi);

  test(
    'unowned legacy keys keep unrelated routes and get bind guidance',
    () async {
      final (targetsStatus, targetsBody) = await signedCall(
        'GET',
        '/api/attendance-corrections/targets',
      );
      expect(targetsStatus, 403);
      expect(
        (targetsBody as Map<String, dynamic>)['error'],
        contains('/bind_key'),
      );
      final (stateStatus, stateBody) = await signedCall('GET', '/api/state');
      expect(stateStatus, 200);
      expect((stateBody as Map<String, dynamic>)['ok'], true);
      final (bearerStatus, _) = await call(
        'GET',
        '/api/attendance-corrections/targets',
      );
      expect(bearerStatus, 403);
    },
  );

  test(
    'group target scope, negative rejection, date validation and apply',
    () async {
      _addAdmin(201);
      _addMember(202);
      _addMember(203, group: '2');
      repo.upsertUser(
        User(
          id: 204,
          name: '@checker',
          experience: Experience.newbie,
          group: '1',
          memberTier: MemberTier.check,
        ),
      );
      _bindConsoleKey(201);
      repo.setActiveOutreach('prompt', false);

      final (targetsStatus, targetsResult) = await signedCall(
        'GET',
        '/api/attendance-corrections/targets',
      );
      expect(targetsStatus, 200);
      final targetsBody = targetsResult as Map<String, dynamic>;
      final targets = targetsBody['targets'] as List;
      expect(
        targets.map((row) => (row as Map)['userId']),
        containsAll([201, 202]),
      );
      expect(
        targets.map((row) => (row as Map)['userId']),
        isNot(contains(203)),
      );
      expect(
        targets.map((row) => (row as Map)['userId']),
        isNot(contains(204)),
      );
      expect(targetsBody['serverLocalDate'], isNotNull);

      final (negativeStatus, negativeBody) = await signedCall(
        'POST',
        '/api/attendance-corrections/preview',
        body: {'targetId': 202, 'delta': -1, 'scope': 'group'},
      );
      expect(negativeStatus, 400);
      expect(
        (negativeBody as Map<String, dynamic>)['error'],
        contains('cannot reduce'),
      );

      final (invalidStatus, invalidBody) = await signedCall(
        'POST',
        '/api/attendance-corrections/preview',
        body: {
          'targetId': 202,
          'delta': 1,
          'scope': 'group',
          'date': '2026-02-30',
        },
      );
      expect(invalidStatus, 400);
      expect((invalidBody as Map<String, dynamic>)['error'], contains('valid'));

      final today = api.config.toLocal(Config.nowUtc());
      final future = _day(today.add(const Duration(days: 1)));
      final (futureStatus, futureBody) = await signedCall(
        'POST',
        '/api/attendance-corrections/preview',
        body: {'targetId': 202, 'delta': 1, 'scope': 'group', 'date': future},
      );
      expect(futureStatus, 400);
      expect((futureBody as Map<String, dynamic>)['error'], contains('Future'));

      final (authorityStatus, authorityBody) = await signedCall(
        'POST',
        '/api/attendance-corrections/preview',
        body: {'targetId': 202, 'delta': 1, 'scope': 'group', 'adminId': 201},
      );
      expect(authorityStatus, 400);
      expect(
        (authorityBody as Map<String, dynamic>)['error'],
        contains('Expected'),
      );

      final (outOfScopeStatus, _) = await signedCall(
        'POST',
        '/api/attendance-corrections/preview',
        body: {'targetId': 203, 'delta': 1, 'scope': 'group'},
      );
      expect(outOfScopeStatus, 404);

      final requestedDate = _day(today.subtract(const Duration(days: 5)));
      final preview = await _preview(
        targetId: 202,
        delta: 2,
        scope: 'group',
        date: requestedDate,
      );
      expect(preview['scope'], 'group');
      expect(preview['currentSessionAttendanceCount'], 0);
      expect(preview['proposedSessionAttendanceCount'], 0);
      expect(preview['proposedBalance'], 2);
      expect(preview['proposedLastAttendedDate'], requestedDate);
      final token = preview['previewToken'] as String;
      final beforeRows = repo.raw
          .select('SELECT * FROM attendance WHERE user_id = 202')
          .map((row) => row.values.toList())
          .toList();
      final beforeSessions = repo.raw
          .select('SELECT * FROM sessions')
          .map((row) => row.values.toList())
          .toList();
      final (applyStatus, applyBody) = await signedCall(
        'POST',
        '/api/attendance-corrections/apply',
        body: {'previewToken': token},
      );
      expect(applyStatus, 200, reason: '$applyBody');
      final applied = applyBody as Map<String, dynamic>;
      expect(applied['attendanceBalance'], 2);
      expect(applied['sessionAttendanceCount'], 0);
      expect(
        repo.findUser(202)!.lastAttendedDate,
        DateTime.parse(requestedDate),
      );
      expect(
        repo.raw
            .select('SELECT * FROM attendance WHERE user_id = 202')
            .map((row) => row.values.toList())
            .toList(),
        beforeRows,
      );
      expect(
        repo.raw
            .select('SELECT * FROM sessions')
            .map((row) => row.values.toList())
            .toList(),
        beforeSessions,
      );
      final (againStatus, againBody) = await signedCall(
        'POST',
        '/api/attendance-corrections/apply',
        body: {'previewToken': token},
      );
      expect(againStatus, 409);
      expect((againBody as Map<String, dynamic>)['error'], contains('changed'));
    },
  );

  test(
    'effective date preview preserves a later actual session date',
    () async {
      _addAdmin(201);
      _addMember(202);
      _bindConsoleKey(201);
      repo.setActiveOutreach('prompt', false);
      final today = api.config.toLocal(Config.nowUtc());
      final actualDate = _day(today.subtract(const Duration(days: 1)));
      repo.raw.execute(
        'INSERT INTO sessions '
        '(weekend_start, day, slot, location, start_at, end_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [
          actualDate,
          'sat',
          'am',
          'ocbc',
          '${actualDate}T09:00:00',
          '${actualDate}T12:00:00',
        ],
      );
      final sessionId = repo.raw.lastInsertRowId;
      repo.setAttendanceState(202, sessionId, attended: true);
      final requestedDate = _day(today.subtract(const Duration(days: 8)));
      final preview = await _preview(
        targetId: 202,
        delta: 1,
        scope: 'group',
        date: requestedDate,
      );
      expect(preview['currentSessionAttendanceCount'], 1);
      expect(preview['proposedSessionAttendanceCount'], 1);
      expect(preview['proposedLastAttendedDate'], actualDate);
      final (status, response) = await signedCall(
        'POST',
        '/api/attendance-corrections/apply',
        body: {'previewToken': preview['previewToken']},
      );
      expect(status, 200, reason: '$response');
      expect(repo.lastAttendedDate(202), DateTime.parse(actualDate));
      expect(repo.attendanceStats(202).total, 1);
    },
  );

  test('apply rechecks owner group and rejects a changed scope', () async {
    _addAdmin(201);
    _addMember(202);
    _bindConsoleKey(201);
    final preview = await _preview(targetId: 202, delta: 4, scope: 'group');
    repo.raw.execute('UPDATE users SET group_id = ? WHERE id = ?', ['2', 201]);
    final (status, response) = await signedCall(
      'POST',
      '/api/attendance-corrections/apply',
      body: {'previewToken': preview['previewToken']},
    );
    expect(status, 403);
    expect(
      (response as Map<String, dynamic>)['error'],
      contains('scope changed'),
    );
    expect(repo.findUser(202)!.attendanceBalance, 0);
  });

  test(
    'global admins can apply negatives; stale and expired previews fail',
    () async {
      _addAdmin(201, global: true);
      _addMember(202);
      _bindConsoleKey(201);
      repo.setActiveOutreach('prompt', false);
      final today = api.config.toLocal(Config.nowUtc());
      final negative = await _preview(
        targetId: 202,
        delta: -3,
        scope: 'all',
        date: _day(today),
      );
      expect(negative['proposedBalance'], -3);
      final (negativeApplyStatus, negativeApplyBody) = await signedCall(
        'POST',
        '/api/attendance-corrections/apply',
        body: {'previewToken': negative['previewToken']},
      );
      expect(negativeApplyStatus, 200, reason: '$negativeApplyBody');
      expect(
        (negativeApplyBody as Map<String, dynamic>)['attendanceBalance'],
        -3,
      );

      final expired = await _preview(targetId: 202, delta: 1, scope: 'all');
      repo.raw.execute(
        'UPDATE attendance_correction_previews SET expires_at = ? '
        'WHERE token_hash = ?',
        [
          today.subtract(const Duration(minutes: 1)).toIso8601String(),
          _makePreviewTokenHash(expired['previewToken'] as String),
        ],
      );
      final (expiredStatus, expiredBody) = await signedCall(
        'POST',
        '/api/attendance-corrections/apply',
        body: {'previewToken': expired['previewToken']},
      );
      expect(expiredStatus, 409);
      expect(
        (expiredBody as Map<String, dynamic>)['error'],
        contains('expired'),
      );

      final stale = await _preview(targetId: 202, delta: 1, scope: 'all');
      repo.raw.execute(
        'UPDATE users SET attendance_balance = attendance_balance + 1 WHERE id = 202',
      );
      final (staleStatus, staleBody) = await signedCall(
        'POST',
        '/api/attendance-corrections/apply',
        body: {'previewToken': stale['previewToken']},
      );
      expect(staleStatus, 409);
      expect((staleBody as Map<String, dynamic>)['error'], contains('changed'));
    },
  );
}
