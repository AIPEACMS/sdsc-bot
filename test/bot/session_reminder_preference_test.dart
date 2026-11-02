import 'dart:async';

import 'package:sdsc_bot/core/models.dart';
import 'package:sdsc_bot/core/repo.dart';
import 'package:televerse/telegram.dart' show Message, Update;
import 'package:televerse/televerse.dart' show ChatID, InlineKeyboard;
import 'package:test/test.dart';

import '../support/grid_harness.dart';

void main() {
  setUp(() async {
    await setUpGrid();
    useUniqueTelegramMessageIds = true;
  });

  test('off warning, on confirmation, and terminal markup removal', () async {
    await sendText(2, '/config_remind');
    final offPrompt = sent.last;
    final offMessageId = sentMessageIds.last;
    expect(offPrompt['text'], contains('responsible for remembering'));
    expect(_buttonLabels(offPrompt), ['Confirm', 'Cancel']);
    await sendCallback(
      2,
      _callback(offPrompt, 'Confirm'),
      messageId: offMessageId,
    );
    expect(repo.findUser(2)!.sessionRemindersEnabled, isFalse);
    expect(state.reminderPreferenceFlows, isEmpty);
    _expectMarkupRemoved(2, offMessageId);
    expect(edited.last['text'], startsWith('✅ Reminder: off.'));
    expect(_buttonLabels(edited.last), isEmpty);

    await sendText(2, '/config_remind');
    final onPrompt = sent.last;
    final onMessageId = sentMessageIds.last;
    expect(onPrompt['text'], 'Turn session reminders on?');
    expect(onPrompt['text'], isNot(contains('responsible for remembering')));
    expect(_buttonLabels(onPrompt), ['Confirm', 'Cancel']);
    await sendCallback(
      2,
      _callback(onPrompt, 'Confirm'),
      messageId: onMessageId,
    );
    expect(repo.findUser(2)!.sessionRemindersEnabled, isTrue);
    _expectMarkupRemoved(2, onMessageId);
    expect(_buttonLabels(edited.last), isEmpty);
    expect(_visibleInlineLabels(), isNot(contains('Dismiss')));
  });

  test('Cancel leaves preference unchanged and removes markup', () async {
    await sendText(2, '/config_remind');
    final prompt = sent.last;
    final messageId = sentMessageIds.last;
    await sendCallback(2, _callback(prompt, 'Cancel'), messageId: messageId);
    expect(repo.findUser(2)!.sessionRemindersEnabled, isTrue);
    expect(state.reminderPreferenceFlows, isEmpty);
    _expectMarkupRemoved(2, messageId);
  });

  test('failed result edit still clears the confirmation keyboard', () async {
    await sendText(2, '/config_remind');
    final prompt = sent.last;
    final messageId = sentMessageIds.last;
    failNextEditMessageText = true;
    await sendCallback(2, _callback(prompt, 'Confirm'), messageId: messageId);
    expect(repo.findUser(2)!.sessionRemindersEnabled, isFalse);
    expect(state.reminderPreferenceFlows, isEmpty);
    _expectMarkupRemoved(2, messageId);
  });

  test(
    'role ineligibility closes the confirmation without changing preference',
    () async {
      await sendText(2, '/config_remind');
      final prompt = sent.last;
      final messageId = sentMessageIds.last;
      final confirm = _callback(prompt, 'Confirm');
      expect(repo.setTier(2, MemberTier.old), isTrue);
      await sendCallback(2, confirm, messageId: messageId);
      expect(repo.findUser(2)!.sessionRemindersEnabled, isTrue);
      expect(state.reminderPreferenceFlows, isEmpty);
      _expectMarkupRemoved(2, messageId);
    },
  );

  test('timer expiry clears markup and completes its lifecycle', () async {
    state.reminderPreferenceTimeout = const Duration(milliseconds: 100);
    await sendText(2, '/config_remind');
    final flow = state.reminderPreferenceFlows[2]!;
    await flow.closed.future.timeout(const Duration(seconds: 3));
    expect(repo.findUser(2)!.sessionRemindersEnabled, isTrue);
    expect(state.reminderPreferenceFlows, isEmpty);
    _expectMarkupRemoved(2, flow.messageId);
  });

  test('wrong owner/message and command interruption cannot confirm', () async {
    await sendText(2, '/config_remind');
    final prompt = sent.last;
    final messageId = sentMessageIds.last;
    final confirm = _callback(prompt, 'Confirm');
    await sendCallback(3, confirm, messageId: messageId);
    await sendCallback(2, confirm, messageId: messageId + 100);
    expect(repo.findUser(2)!.sessionRemindersEnabled, isTrue);
    expect(state.reminderPreferenceFlows, contains(2));
    expect(fakeMessageMarkups[(2, messageId)], isNotNull);

    await sendText(2, '/mystatus');
    expect(repo.findUser(2)!.sessionRemindersEnabled, isTrue);
    expect(state.reminderPreferenceFlows, isEmpty);
    _expectMarkupRemoved(2, messageId);
    await sendCallback(2, confirm, messageId: messageId);
    expect(repo.findUser(2)!.sessionRemindersEnabled, isTrue);
    _expectMarkupRemoved(2, messageId);
  });

  test(
    'repeated concurrent opens clear the superseded unique message',
    () async {
      final firstRequest = Completer<void>();
      final releaseFirst = Completer<void>();
      var blocked = false;
      beforeSendMessageResponse = (body) async {
        if ((body['text'] as String).startsWith('Turning off') && !blocked) {
          blocked = true;
          firstRequest.complete();
          await releaseFirst.future;
        }
      };

      final firstOpen = sendText(2, '/config_remind');
      await firstRequest.future;
      final firstOpening = state.reminderPreferenceOpenings[2];
      final secondOpen = sendText(2, '/config_remind');
      await _waitUntil(
        () => !identical(state.reminderPreferenceOpenings[2], firstOpening),
      );
      releaseFirst.complete();
      await Future.wait([firstOpen, secondOpen]);

      final prompts = [
        for (var index = 0; index < sent.length; index++)
          if ((sent[index]['text'] as String).startsWith('Turning off'))
            (sent[index], sentMessageIds[index]),
      ];
      expect(prompts, hasLength(2));
      expect(fakeMessageMarkups[(2, prompts.first.$2)], isNull);
      expect(fakeMessageMarkups[(2, prompts.last.$2)], isNotNull);
      expect(state.reminderPreferenceFlows[2]!.messageId, prompts.last.$2);
      expect(
        prompts.where((prompt) => fakeMessageMarkups[(2, prompt.$2)] != null),
        hasLength(1),
      );
      await sendCallback(
        2,
        _callback(prompts.last.$1, 'Cancel'),
        messageId: prompts.last.$2,
      );
      _expectMarkupRemoved(2, prompts.last.$2);
    },
  );

  test(
    'old private-chat callbacks clear keyboards without deleting or mutating',
    () async {
      final legacyData = [
        'configremind|off',
        'configremind|old-token|choose_off',
        'configremind|old-token|confirm_off',
        'configremind|old-token|dismiss',
        'configremind|old-token|dismiss_result',
      ];
      final messages = <(Message, String)>[];
      for (final data in legacyData) {
        final message = await bot.api.sendMessage(
          ChatID(2),
          'Old reminder control',
          replyMarkup: InlineKeyboard().text('Old action', data),
        );
        messages.add((message, data));
      }
      final deleteCount = deletedMessages.length;
      for (final (message, data) in messages) {
        await sendCallback(2, data, messageId: message.messageId);
        _expectMarkupRemoved(2, message.messageId);
      }

      final groupMessage = await bot.api.sendMessage(
        ChatID(-200),
        'Group reminder control',
        replyMarkup: InlineKeyboard().text(
          'Old action',
          'configremind|old-token|confirm_off',
        ),
      );
      await bot.handleUpdate(
        Update.fromJson({
          'update_id': 101,
          'callback_query': {
            'id': 'group-reminder',
            'from': {'id': 2, 'is_bot': false, 'first_name': 'member'},
            'chat_instance': 'group-instance',
            'message': {
              'message_id': groupMessage.messageId,
              'date': 1,
              'chat': {'id': -200, 'type': 'group'},
              'text': 'Group reminder control',
            },
            'data': 'configremind|old-token|confirm_off',
          },
        }),
      );
      expect(fakeMessageMarkups[(-200, groupMessage.messageId)], isNotNull);
      expect(deletedMessages, hasLength(deleteCount));
      expect(repo.findUser(2)!.sessionRemindersEnabled, isTrue);
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

List<String> _buttonLabels(Map<String, dynamic> body) {
  final markup = body['reply_markup'] as Map<String, dynamic>?;
  final keyboard = markup?['inline_keyboard'];
  if (keyboard is! List) return const [];
  return [
    for (final row in keyboard)
      for (final button in row as List)
        (button as Map<String, dynamic>)['text'] as String,
  ];
}

List<String> _visibleInlineLabels() {
  final labels = <String>[];
  for (final value in fakeMessageMarkups.values) {
    if (value is! Map<String, dynamic>) continue;
    final keyboard = value['inline_keyboard'];
    if (keyboard is! List) continue;
    for (final row in keyboard) {
      for (final button in row as List) {
        labels.add((button as Map<String, dynamic>)['text'] as String);
      }
    }
  }
  return labels;
}

void _expectMarkupRemoved(int chatId, int messageId) {
  expect(fakeMessageMarkups[(chatId, messageId)], isNull);
  expect(
    edited.any(
      (body) =>
          body['chat_id'] == chatId &&
          body['message_id'] == messageId &&
          _isEmptyInlineMarkup(body['reply_markup']),
    ),
    isTrue,
    reason: 'message $messageId must receive an explicit empty inline keyboard',
  );
}

bool _isEmptyInlineMarkup(Object? markup) =>
    markup is Map<String, dynamic> &&
    markup['inline_keyboard'] is List &&
    (markup['inline_keyboard'] as List).isEmpty;

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('reminder open generation did not advance');
    }
    await Future<void>.delayed(Duration.zero);
  }
}
