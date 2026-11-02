import 'package:sdsc_bot/bot/flows.dart';
import 'package:sdsc_bot/core/repo.dart';
import 'package:test/test.dart';

import '../support/grid_harness.dart';

void main() {
  setUp(() async {
    await setUpGrid();
    useUniqueTelegramMessageIds = true;
  });

  test(
    'failed preference write closes the confirmation and its lifecycle',
    () async {
      await sendText(2, '/config_remind');
      final prompt = sent.last;
      final messageId = sentMessageIds.last;
      final rows = prompt['reply_markup']['inline_keyboard'] as List;
      final confirm = rows.first.first['callback_data'] as String;
      repo.raw.execute('''
CREATE TRIGGER reject_reminder_preference
BEFORE UPDATE OF session_reminders_enabled ON users
BEGIN
  SELECT RAISE(ABORT, 'simulated preference write failure');
END;
''');
      Object? failure;
      try {
        await sendCallback(2, confirm, messageId: messageId);
      } catch (error) {
        failure = error;
      }
      final markupAfterFailure = fakeMessageMarkups[(2, messageId)];
      final resultText = edited.last['text'] as String;
      final remainingFlow = state.reminderPreferenceFlows[2];
      final lifecycleClosed =
          remainingFlow == null || remainingFlow.closed.isCompleted;
      final unchanged = repo.findUser(2)!.sessionRemindersEnabled;

      // Recover the deliberately injected failure before harness teardown so a
      // broken closing lifecycle cannot make this regression test hang.
      repo.raw.execute('DROP TRIGGER reject_reminder_preference');
      if (remainingFlow != null && !remainingFlow.closed.isCompleted) {
        remainingFlow.closing = false;
      }
      await flows.shutdown();

      expect(unchanged, isTrue);
      expect(
        markupAfterFailure,
        isNull,
        reason: 'failed writes must clear actual markup; caught: $failure',
      );
      expect(lifecycleClosed, isTrue);
      expect(failure, isNull);
      expect(resultText, contains('Could not save'));
      expect(resultText, isNot(contains('Reminder: off')));
    },
  );
}
