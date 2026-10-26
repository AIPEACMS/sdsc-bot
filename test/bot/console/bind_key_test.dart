import 'package:crypto/crypto.dart' show sha256;
import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:test/test.dart';
import '../../support/grid_harness.dart';

void main() {
  setUp(setUpGrid);

  test('admin binds one console key with a one-time code', () async {
    const code = 'copy-this-one-time-binding-code';
    await sendPlainText(2, 'more-cmd');
    expect(sent.last['text'], contains('/bind_key'));
    repo.addConsoleKey('console-public-key', name: 'desktop');
    final result = repo.createConsoleKeyBindingChallenge(
      'console-public-key',
      challengeHash: sha256.convert(code.codeUnits).toString(),
      expiresAt: config
          .toLocal(Config.nowUtc())
          .add(const Duration(minutes: 10))
          .toIso8601String(),
    );
    expect(result, ConsoleKeyBindingResult.success);

    await sendText(2, '/bind_key');
    expect(sent.last['text'], contains('Paste the code here'));
    expect(state.pendingArg[2]?.command, 'bindkey');
    await sendPlainText(2, code);
    expect(sent.last['text'], contains('now bound to your admin account'));
    expect(repo.listConsoleKeys().single.actorUserId, 2);
    expect(state.pendingArg, isNot(contains(2)));

    await sendText(2, '/bind_key');
    await sendPlainText(2, code);
    expect(sent.last['text'], contains('invalid or already used'));
    expect(repo.listConsoleKeys().single.actorUserId, 2);
  });

  test(
    'non-admin cannot start binding and expired codes are consumed',
    () async {
      await sendText(4, '/bind_key');
      expect(sent.last['text'], contains('Only an admin or global admin'));
      expect(state.pendingArg, isNot(contains(4)));

      const code = 'expired-one-time-code';
      repo.addConsoleKey('expired-console-key');
      repo.createConsoleKeyBindingChallenge(
        'expired-console-key',
        challengeHash: sha256.convert(code.codeUnits).toString(),
        expiresAt: config
            .toLocal(Config.nowUtc())
            .subtract(const Duration(seconds: 1))
            .toIso8601String(),
      );
      await sendText(2, '/bind_key');
      await sendPlainText(2, code);
      expect(sent.last['text'], contains('expired'));
      expect(repo.listConsoleKeys().last.actorUserId, isNull);
    },
  );
}
