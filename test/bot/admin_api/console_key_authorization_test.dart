import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:test/test.dart';
import '../../support/admin_api_harness.dart';

void _setKeyOwner(int id, {required bool admin}) {
  repo.upsertUser(
    User(
      id: id,
      name: '@owner$id',
      experience: Experience.experienced,
      group: '1',
      isAdmin: admin,
    ),
  );
  final key = repo.listConsoleKeys().single;
  repo.raw.execute(
    'UPDATE console_keys SET actor_user_id = ? WHERE pubkey = ?',
    [id, key.pubkey],
  );
}

void main() {
  setUp(setUpAdminApi);
  tearDown(tearDownAdminApi);

  test(
    'admin-owned key is rejected on unrelated and global API routes',
    () async {
      _setKeyOwner(201, admin: true);
      final requests = <(String, String, Object?)>[
        ('GET', '/api/state', null),
        ('GET', '/api/users', null),
        ('POST', '/api/hold', {'held': true}),
        ('GET', '/api/attendance-corrections/targets', null),
      ];
      for (final (method, path, body) in requests) {
        final (status, response) = await signedCall(method, path, body: body);
        expect(status, 403, reason: path);
        final error = (response as Map<String, dynamic>)['error'] as String;
        expect(error, contains('not the configured console'));
        expect(error, isNot(contains('201')));
      }
    },
  );

  test('configured console-owned key remains authorized', () async {
    _setKeyOwner(api.config.consoleId, admin: false);
    final (stateStatus, stateBody) = await signedCall('GET', '/api/state');
    expect(stateStatus, 200);
    expect((stateBody as Map<String, dynamic>)['ok'], true);
    final (targetsStatus, targetsBody) = await signedCall(
      'GET',
      '/api/attendance-corrections/targets',
    );
    expect(targetsStatus, 200);
    expect((targetsBody as Map<String, dynamic>)['scopes'], ['all']);
  });
}
