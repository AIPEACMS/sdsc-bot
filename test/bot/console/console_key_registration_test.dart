import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:test/test.dart';
import '../../support/grid_harness.dart';

void main() {
  setUp(setUpGrid);

  test(
    '/add_key is console-only and records the configured console owner',
    () async {
      const publicKey = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
      expect(state.isValidCommandText('/bind_key one-time-code'), isFalse);

      await sendText(2, '/add_key $publicKey test-key');
      expect(sent.last['text'], contains('not the console'));
      expect(repo.hasConsoleKey(publicKey), isFalse);

      await sendText(1, '/add_key $publicKey test-key');
      expect(sent.last['text'], contains('configured console account'));
      expect(repo.listConsoleKeys(), hasLength(1));
      expect(repo.listConsoleKeys().single.actorUserId, config.consoleId);

      await sendText(2, '/bind_key one-time-code');
      expect(state.pendingArg, isNot(contains(2)));
      expect(repo.listConsoleKeys().single.actorUserId, config.consoleId);
    },
  );
}
