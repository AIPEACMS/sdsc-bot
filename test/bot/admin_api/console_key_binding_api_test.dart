import 'package:crypto/crypto.dart' show sha256;
import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:test/test.dart';
import '../../support/admin_api_harness.dart';

void _addAdmin(int id) {
  repo.upsertUser(
    User(
      id: id,
      name: '@admin$id',
      experience: Experience.experienced,
      group: '1',
      isAdmin: true,
    ),
  );
}

void main() {
  setUp(setUpAdminApi);
  tearDown(tearDownAdminApi);

  test('binding challenge stores only a hash and expires one-time', () async {
    _addAdmin(201);
    final (status, response) = await signedCall(
      'POST',
      '/api/console-keys/bind-challenge',
    );
    expect(status, 200);
    final body = response as Map<String, dynamic>;
    final code = body['code'] as String;
    expect(code, isNotEmpty);
    expect(body['instruction'], contains('/bind_key'));
    final row = repo.raw
        .select(
          'SELECT bind_challenge_hash, bind_challenge_expires_at '
          'FROM console_keys',
        )
        .single;
    expect(row['bind_challenge_hash'], isNot(code));
    expect(
      row['bind_challenge_hash'],
      sha256.convert(code.codeUnits).toString(),
    );
    expect(row['bind_challenge_expires_at'], isNotNull);
    expect(
      repo.redeemConsoleKeyBindingChallenge(
        code,
        actorUserId: 999,
        now: api.config.toLocal(Config.nowUtc()).toIso8601String(),
      ),
      ConsoleKeyBindingResult.notAdmin,
    );
    expect(
      repo.redeemConsoleKeyBindingChallenge(
        code,
        actorUserId: 201,
        now: api.config.toLocal(Config.nowUtc()).toIso8601String(),
      ),
      ConsoleKeyBindingResult.success,
    );
    expect(repo.listConsoleKeys().single.actorUserId, 201);
    expect(
      repo.redeemConsoleKeyBindingChallenge(
        code,
        actorUserId: 201,
        now: api.config.toLocal(Config.nowUtc()).toIso8601String(),
      ),
      ConsoleKeyBindingResult.invalidCode,
    );
    expect(
      repo.createConsoleKeyBindingChallenge(
        repo.listConsoleKeys().single.pubkey,
        challengeHash: 'replacement-hash',
        expiresAt: api.config.toLocal(Config.nowUtc()).toIso8601String(),
      ),
      ConsoleKeyBindingResult.alreadyBound,
    );
  });
}
