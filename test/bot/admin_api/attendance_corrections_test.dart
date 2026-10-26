import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:test/test.dart';
import '../../support/admin_api_harness.dart';

String _day(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String _hashToken(String token) =>
    sha256.convert(utf8.encode(token)).toString();

void _addMember(int id) {
  repo.upsertUser(
    User(id: id, name: '@member$id', experience: Experience.newbie, group: '1'),
  );
}

Future<Map<String, dynamic>> _preview({
  required int targetId,
  required int delta,
  String? date,
  String scope = 'all',
}) async {
  final (status, result) = await signedCall(
    'POST',
    '/api/attendance-corrections/preview',
    body: {'targetId': targetId, 'delta': delta, 'scope': scope, 'date': date},
  );
  expect(status, 200, reason: '$result');
  return result as Map<String, dynamic>;
}

void main() {
  setUp(setUpAdminApi);
  tearDown(tearDownAdminApi);

  test(
    'legacy unowned key remains trusted for console-wide corrections',
    () async {
      repo.setActiveOutreach('prompt', false);
      _addMember(202);
      _addMember(203);
      repo.setGroup(203, '2');
      repo.upsertUser(
        User(
          id: 204,
          name: '@checker',
          experience: Experience.newbie,
          group: '1',
          memberTier: MemberTier.check,
        ),
      );
      repo.upsertUser(
        User(
          id: 205,
          name: '@out',
          experience: Experience.newbie,
          group: '',
          memberTier: MemberTier.outMember,
        ),
      );

      final columns = repo.raw
          .select('PRAGMA table_info(console_keys)')
          .map((row) => row['name'] as String)
          .toSet();
      expect(columns, contains('actor_user_id'));
      expect(columns, isNot(contains('bind_challenge_hash')));
      expect(columns, isNot(contains('bind_challenge_expires_at')));
      expect(repo.listConsoleKeys().single.actorUserId, isNull);

      final (stateStatus, stateBody) = await signedCall('GET', '/api/state');
      expect(stateStatus, 200);
      expect((stateBody as Map<String, dynamic>)['ok'], true);
      final (targetsStatus, targetsBody) = await signedCall(
        'GET',
        '/api/attendance-corrections/targets',
      );
      expect(targetsStatus, 200);
      final response = targetsBody as Map<String, dynamic>;
      expect(response['scopes'], ['all']);
      final ids = (response['targets'] as List)
          .map((entry) => (entry as Map<String, dynamic>)['userId'])
          .toSet();
      expect(ids, containsAll([202, 203]));
      expect(ids, isNot(contains(204)));
      expect(ids, isNot(contains(205)));

      final (groupStatus, groupBody) = await signedCall(
        'POST',
        '/api/attendance-corrections/preview',
        body: {'targetId': 203, 'delta': 1, 'scope': 'group'},
      );
      expect(groupStatus, 400);
      expect(
        (groupBody as Map<String, dynamic>)['error'],
        contains('all scope'),
      );
      final (authorityStatus, _) = await signedCall(
        'POST',
        '/api/attendance-corrections/preview',
        body: {'targetId': 202, 'delta': 1, 'scope': 'all', 'adminId': 201},
      );
      expect(authorityStatus, 400);

      final today = api.config.toLocal(Config.nowUtc());
      final (invalidStatus, invalidBody) = await signedCall(
        'POST',
        '/api/attendance-corrections/preview',
        body: {
          'targetId': 202,
          'delta': 1,
          'scope': 'all',
          'date': '2026-02-30',
        },
      );
      expect(invalidStatus, 400);
      expect((invalidBody as Map<String, dynamic>)['error'], contains('valid'));
      final (futureStatus, futureBody) = await signedCall(
        'POST',
        '/api/attendance-corrections/preview',
        body: {
          'targetId': 202,
          'delta': 1,
          'scope': 'all',
          'date': _day(today.add(const Duration(days: 1))),
        },
      );
      expect(futureStatus, 400);
      expect((futureBody as Map<String, dynamic>)['error'], contains('Future'));

      final preview = await _preview(
        targetId: 203,
        delta: -2,
        date: _day(today),
      );
      expect(preview['scope'], 'all');
      expect(preview['proposedBalance'], -2);
      final beforeAttendance = repo.raw
          .select('SELECT * FROM attendance WHERE user_id = 203')
          .map((row) => row.values.toList())
          .toList();
      final beforeSessions = repo.raw
          .select('SELECT * FROM sessions')
          .map((row) => row.values.toList())
          .toList();
      final (applyStatus, applyBody) = await signedCall(
        'POST',
        '/api/attendance-corrections/apply',
        body: {'previewToken': preview['previewToken']},
      );
      expect(applyStatus, 200, reason: '$applyBody');
      final applied = applyBody as Map<String, dynamic>;
      expect(applied['attendanceBalance'], -2);
      expect(applied['sessionAttendanceCount'], 0);
      expect(
        repo.raw
            .select('SELECT * FROM attendance WHERE user_id = 203')
            .map((row) => row.values.toList())
            .toList(),
        beforeAttendance,
      );
      expect(
        repo.raw
            .select('SELECT * FROM sessions')
            .map((row) => row.values.toList())
            .toList(),
        beforeSessions,
      );
      final (repeatStatus, repeatBody) = await signedCall(
        'POST',
        '/api/attendance-corrections/apply',
        body: {'previewToken': preview['previewToken']},
      );
      expect(repeatStatus, 409);
      expect(
        (repeatBody as Map<String, dynamic>)['error'],
        contains('changed'),
      );
    },
  );

  test('preview token is bound to the console key id', () async {
    _addMember(202);
    repo.setActiveOutreach('prompt', false);
    final preview = await _preview(targetId: 202, delta: 2);
    final firstKeyId = repo
        .consoleKeyIdentity(repo.listConsoleKeys().single.pubkey)!
        .id;
    repo.addConsoleKey('another-registered-key');
    final secondKeyId = repo.consoleKeyIdentity('another-registered-key')!.id;
    final (wrongKeyResult, _) = repo.applyAttendanceCorrectionPreview(
      tokenHash: _hashToken(preview['previewToken'] as String),
      consoleKeyId: secondKeyId,
      consoleUserId: api.config.consoleId,
      now: api.config.toLocal(Config.nowUtc()).toIso8601String(),
    );
    expect(wrongKeyResult, AttendanceCorrectionApplyResult.stale);
    expect(repo.findUser(202)!.attendanceBalance, 0);

    final (status, response) = await signedCall(
      'POST',
      '/api/attendance-corrections/apply',
      body: {'previewToken': preview['previewToken']},
    );
    expect(status, 200, reason: '$response');
    expect(
      repo.consoleKeyIdentity(repo.listConsoleKeys().first.pubkey)!.id,
      firstKeyId,
    );
    expect(repo.findUser(202)!.attendanceBalance, 2);
  });

  test(
    'effective date retains later actual attendance; stale and expired fail',
    () async {
      repo.setActiveOutreach('prompt', false);
      _addMember(202);
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
      repo.setAttendanceState(202, repo.raw.lastInsertRowId, attended: true);
      final preview = await _preview(
        targetId: 202,
        delta: 1,
        date: _day(today.subtract(const Duration(days: 8))),
      );
      expect(preview['currentSessionAttendanceCount'], 1);
      expect(preview['proposedSessionAttendanceCount'], 1);
      expect(preview['proposedLastAttendedDate'], actualDate);
      final (applyStatus, _) = await signedCall(
        'POST',
        '/api/attendance-corrections/apply',
        body: {'previewToken': preview['previewToken']},
      );
      expect(applyStatus, 200);
      expect(repo.lastAttendedDate(202), DateTime.parse(actualDate));

      final expired = await _preview(targetId: 202, delta: 1);
      repo.raw.execute(
        'UPDATE attendance_correction_previews_v2 SET expires_at = ? '
        'WHERE token_hash = ?',
        [
          today.subtract(const Duration(minutes: 1)).toIso8601String(),
          _hashToken(expired['previewToken'] as String),
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

      final stale = await _preview(targetId: 202, delta: 1);
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
