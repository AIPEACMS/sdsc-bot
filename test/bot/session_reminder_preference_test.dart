import 'package:test/test.dart';
import 'package:sdsc_bot/bot/state.dart';
import 'package:sdsc_bot/core/repo.dart';

import '../support/grid_harness.dart';

void main() {
  setUp(setUpGrid);

  test(
    'opt-out warns; opt-in confirms without the responsibility warning',
    () async {
      await sendText(2, '/config_remind');
      await sendCallback(2, _callback(sent.last, 'Turn off'));
      expect(edited.last['text'], contains('responsible for remembering'));
      await sendCallback(2, _callback(edited.last, 'Cancel'));
      expect(repo.findUser(2)!.sessionRemindersEnabled, isTrue);

      await sendText(2, '/config_remind');
      await sendCallback(2, _callback(sent.last, 'Turn off'));
      final confirmOff = _callback(edited.last, 'Confirm');
      await sendCallback(2, confirmOff);
      expect(repo.findUser(2)!.sessionRemindersEnabled, isFalse);
      expect(state.reminderPreferenceFlows, isEmpty);
      expect(state.reminderPreferenceResults, contains(2));
      final dismissResult = _callback(edited.last, 'Dismiss');
      final deletedCount = deletedMessages.length;
      await sendCallback(2, confirmOff);
      expect(state.reminderPreferenceResults, contains(2));
      expect(deletedMessages, hasLength(deletedCount));
      await sendCallback(2, dismissResult);
      expect(deletedMessages, hasLength(deletedCount + 1));
      expect(state.reminderPreferenceResults, isEmpty);
      expect(repo.findUser(2)!.sessionRemindersEnabled, isFalse);
      await sendText(2, '/mystatus');
      expect(sent.last['text'], contains('Reminder: off'));

      await sendText(2, '/config_remind');
      await sendCallback(2, _callback(sent.last, 'Turn on'));
      expect(edited.last['text'], 'Turn session reminders on?');
      expect(
        edited.last['text'],
        isNot(contains('responsible for remembering')),
      );
      await sendCallback(2, _callback(edited.last, 'Confirm'));
      expect(repo.findUser(2)!.sessionRemindersEnabled, isTrue);
    },
  );

  test(
    'Dismiss deletes the message; Cancel and replay do not change preference',
    () async {
      await sendText(2, '/config_remind');
      await sendCallback(2, _callback(sent.last, 'Turn off'));
      final dismiss = _callback(edited.last, 'Dismiss');
      await sendCallback(2, dismiss);
      expect(deletedMessages, hasLength(1));
      expect(edited.last['text'], isNot('No change made.'));
      expect(repo.findUser(2)!.sessionRemindersEnabled, isTrue);

      await sendText(2, '/config_remind');
      await sendCallback(2, _callback(sent.last, 'Turn off'));
      final confirm = _callback(edited.last, 'Confirm');
      await sendCallback(2, _callback(edited.last, 'Cancel'));
      await sendCallback(2, confirm);
      expect(repo.findUser(2)!.sessionRemindersEnabled, isTrue);
      expect(state.reminderPreferenceFlows, isEmpty);
    },
  );

  test(
    'mismatched owner/message, expiry, and interruption cannot confirm',
    () async {
      await sendText(2, '/config_remind');
      await sendCallback(2, _callback(sent.last, 'Turn off'));
      final confirm = _callback(edited.last, 'Confirm');
      await sendCallback(3, confirm);
      await sendCallback(2, confirm, messageId: 99);
      expect(repo.findUser(2)!.sessionRemindersEnabled, isTrue);
      expect(state.reminderPreferenceFlows, contains(2));

      final flow = state.reminderPreferenceFlows[2]!;
      state.reminderPreferenceFlows[2] = ReminderPreferenceFlow(
        token: flow.token,
        chatId: flow.chatId,
        messageId: flow.messageId,
        createdAt: DateTime.now().subtract(const Duration(minutes: 11)),
      )..desiredEnabled = false;
      await sendCallback(2, confirm);
      expect(repo.findUser(2)!.sessionRemindersEnabled, isTrue);
      expect(state.reminderPreferenceFlows, isEmpty);

      await sendText(2, '/config_remind');
      await sendCallback(2, _callback(sent.last, 'Turn off'));
      final interruptedConfirm = _callback(edited.last, 'Confirm');
      await sendText(2, '/mystatus');
      await sendCallback(2, interruptedConfirm);
      expect(repo.findUser(2)!.sessionRemindersEnabled, isTrue);
      expect(state.reminderPreferenceFlows, isEmpty);
    },
  );

  test('all-users marks only session reminder opt-outs as dismissed', () async {
    repo.setSessionRemindersEnabled(2, false);
    await sendText(2, '/all_users');
    final text = sent.last['text'] as String;
    expect(text, contains('<i>reminder dismissed</i>'));
    expect(text, contains('@admin</b>'));
    expect(text, isNot(contains('@console</b>\n   (gadmin, group 1')));
  });
}

String _callback(Map<String, dynamic> body, String label) {
  final markup = body['reply_markup'] as Map<String, dynamic>;
  final rows = markup['inline_keyboard'] as List;
  for (final row in rows) {
    for (final value in row as List) {
      final button = value as Map<String, dynamic>;
      if (button['text'] == label) return button['callback_data'] as String;
    }
  }
  throw StateError('No inline button labeled $label');
}
