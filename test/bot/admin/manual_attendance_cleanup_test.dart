import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:sdsc_bot/bot/admin.dart';
import 'package:test/test.dart';
import '../../support/grid_harness.dart';

void main() {
  setUp(() async {
    await setUpGrid();
    flows.onManualAttendanceText = admin.onManualAttendanceText;
    // Mirrors the production callback wiring in bin/main.dart.
    flows.onPendingInputCleared = (userId, command) {
      if (command.startsWith('manualattendance')) {
        admin.onManualAttendanceInputCleared(userId);
      }
    };
  });

  test(
    'invalid retries preserve target prompt and Cancel; cancel closes all',
    () async {
      useUniqueTelegramMessageIds = true;
      await sendText(2, '/manual_mark_group_attend');
      final picker = sent.last['reply_markup']['inline_keyboard'] as List;
      final targetCallback = picker.first.first['callback_data'] as String;
      await sendCallback(2, targetCallback, messageId: sentMessageIds.last);
      final targetId = int.parse(targetCallback.split('|').last);
      final balance = repo.findUser(targetId)!.attendanceBalance;

      await sendPlainText(2, '-1');
      expect(sent.last['text'], contains('Current session-attendance count:'));
      expect(sent.last['text'], contains('Send a whole signed integer'));
      expect(_button(sent.last, 0), 'Cancel');
      await sendPlainText(2, '1 tomorrow');
      expect(sent.last['text'], contains('Invalid or future date'));
      expect(sent.last['text'], contains('Attendance correction for'));
      expect(_button(sent.last, 0), 'Cancel');
      expect(repo.findUser(targetId)!.attendanceBalance, balance);

      final retryMessageIds = sentMessageIds.toList();
      await sendCallback(
        2,
        'manualatt|cancel|0|cancel',
        messageId: retryMessageIds.last,
      );

      final removals = edited
          .where(_isMarkupRemoval)
          .map((body) => body['message_id'])
          .toSet();
      expect(removals, containsAll(retryMessageIds));
      _expectMarkupsClosed(2, retryMessageIds);
      expect(edited.last['text'], 'Cancelled.');
      expect(edited.last['reply_markup'], isNull);
      expect(state.interactiveMessages[2], isNull);
    },
  );

  test(
    'date preview escapes hostile names and applies only after confirmation',
    () async {
      useUniqueTelegramMessageIds = true;
      const targetId = 31;
      repo.upsertUser(
        User(
          id: targetId,
          name: 'A&B <Member>',
          experience: Experience.newbie,
          group: '1',
        ),
      );
      await sendText(1, '/manual_mark_all_attend');
      final picker = sent.last['reply_markup']['inline_keyboard'] as List;
      final targetCallback = picker
          .expand((row) => row as List)
          .map((button) => button['callback_data'] as String)
          .firstWhere((data) => data.endsWith('|$targetId'));
      await sendCallback(1, targetCallback, messageId: sentMessageIds.last);
      expect(edited.last['parse_mode'], 'HTML');
      expect(edited.last['text'], contains('A&amp;B &lt;Member&gt;'));

      final before = repo.findUser(targetId)!.attendanceBalance;
      final count = repo.attendanceStats(targetId).total;
      await sendPlainText(1, '3 Oct 10');
      final preview = sent.last;
      expect(preview['parse_mode'], 'HTML');
      expect(preview['text'], contains('A&amp;B &lt;Member&gt;'));
      expect(
        preview['text'],
        contains('Current session-attendance count: $count'),
      );
      expect(preview['text'], contains('Requested adjustment: 3'));
      expect(
        preview['text'],
        contains('Proposed last-attended date: 2026-Oct-10'),
      );
      expect(
        preview['text'],
        contains('Proposed resulting balance: ${before + 3}'),
      );
      expect(_button(preview, 0), 'Confirm');
      expect(repo.findUser(targetId)!.attendanceBalance, before);

      final messageIds = sentMessageIds.toList();
      await sendCallback(1, 'manualattconfirm|yes', messageId: messageIds.last);
      expect(repo.findUser(targetId)!.attendanceBalance, before + 3);
      expect(edited.last['text'], contains('Attendance updated'));
      expect(edited.last['reply_markup'], isNull);
      expect(edited.any(_isMarkupRemoval), isTrue);
      expect(
        edited.where(_isMarkupRemoval).map((body) => body['message_id']),
        containsAll(messageIds),
      );
      _expectMarkupsClosed(1, messageIds);
      expect(state.interactiveMessages[1], isNull);
    },
  );

  test(
    'registered command interrupts manual flow and reaches its handler',
    () async {
      useUniqueTelegramMessageIds = true;
      await sendText(2, '/manual_mark_group_attend');
      var picker = sent.last['reply_markup']['inline_keyboard'] as List;
      var selection = picker.first.first['callback_data'] as String;
      final firstPickerId = sentMessageIds.last;
      await sendCallback(2, selection, messageId: firstPickerId);
      final targetId = int.parse(selection.split('|').last);
      final originalBalance = repo.findUser(targetId)!.attendanceBalance;

      // Interrupt the text-input draft and prove its former input is no longer
      // consumed as a correction.
      await sendText(2, '/status');
      expect(state.pendingArg, isNot(contains(2)));
      _expectMarkupsClosed(2, [firstPickerId]);
      final sentBeforeOldInput = sent.length;
      await sendPlainText(2, '4');
      expect(sent.length, sentBeforeOldInput);

      // Build the confirmation stage too, then interrupt it through the same
      // registered-command middleware and production-equivalent callback.
      await sendText(2, '/manual_mark_group_attend');
      picker = sent.last['reply_markup']['inline_keyboard'] as List;
      selection = picker.first.first['callback_data'] as String;
      final secondPickerId = sentMessageIds.last;
      await sendCallback(2, selection, messageId: secondPickerId);
      await sendPlainText(2, '4');
      final previewId = sentMessageIds.last;
      final sentBeforeCommand = sent.length;
      await sendText(2, '/status');

      expect(sent.length, greaterThan(sentBeforeCommand));
      expect(state.pendingArg, isNot(contains(2)));
      expect(edited.any(_isMarkupRemoval), isTrue);
      _expectMarkupsClosed(2, [secondPickerId, previewId]);
      expect(sent.last['text'], contains('All members status'));

      await sendCallback(2, 'manualattconfirm|yes', messageId: previewId);
      expect(repo.findUser(targetId)!.attendanceBalance, originalBalance);
      expect(edited.last['text'], contains('no longer available'));
      expect(state.interactiveMessages[2], isNull);
    },
  );

  test('failed selection edit closes its keyboard and pending flow', () async {
    await sendText(2, '/manual_mark_group_attend');
    final picker = sent.last['reply_markup']['inline_keyboard'] as List;
    final callback = picker.first.first['callback_data'] as String;
    failNextEditMessageText = true;

    await sendCallback(2, callback);

    expect(edited.last['reply_markup'], isNull);
    expect(edited.any(_isMarkupRemoval), isTrue);
    expect(state.pendingArg, isNot(contains(2)));
    expect(state.interactiveMessages[2], isNull);
  });

  test('expired confirmation callback closes tracked controls', () async {
    await sendText(2, '/manual_mark_group_attend');
    final picker = sent.last['reply_markup']['inline_keyboard'] as List;
    await sendCallback(2, picker.first.first['callback_data'] as String);
    final balance = repo.findUser(2)!.attendanceBalance;
    await sendPlainText(2, '2');
    state.pendingArg.remove(2);

    await sendCallback(2, 'manualattconfirm|yes');

    expect(repo.findUser(2)!.attendanceBalance, balance);
    expect(edited.last['text'], contains('no longer available'));
    expect(edited.last['reply_markup'], isNull);
    expect(edited.any(_isMarkupRemoval), isTrue);
    expect(state.interactiveMessages[2], isNull);
  });

  test(
    'gadmin negative adjustment previews without applying until Confirm',
    () async {
      useUniqueTelegramMessageIds = true;
      const targetId = 32;
      const startingBalance = 2;
      repo.upsertUser(
        User(
          id: targetId,
          name: '@negative-test',
          experience: Experience.newbie,
          group: '1',
          attendanceBalance: startingBalance,
        ),
      );
      await sendText(1, '/manual_mark_all_attend');
      final picker = sent.last['reply_markup']['inline_keyboard'] as List;
      final targetCallback = picker
          .expand((row) => row as List)
          .map((button) => button['callback_data'] as String)
          .firstWhere((data) => data.endsWith('|$targetId'));
      await sendCallback(1, targetCallback, messageId: sentMessageIds.last);

      await sendPlainText(1, '-1');
      final preview = sent.last;
      final previewId = sentMessageIds.last;
      expect(
        preview['text'],
        contains('Attendance correction preview for @negative-test'),
      );
      expect(
        preview['text'],
        contains('Current persisted attendance balance: $startingBalance'),
      );
      expect(preview['text'], contains('Requested adjustment: -1'));
      expect(preview['text'], contains('Proposed resulting balance: 1'));
      expect(_button(preview, 0), 'Confirm');
      expect(repo.findUser(targetId)!.attendanceBalance, startingBalance);

      await sendCallback(1, 'manualattconfirm|yes', messageId: previewId);

      expect(repo.findUser(targetId)!.attendanceBalance, 1);
      expect(
        edited.last['text'],
        contains('Attendance updated for @negative-test'),
      );
      expect(edited.last['reply_markup'], isNull);
      _expectMarkupsClosed(1, sentMessageIds);
      expect(state.interactiveMessages[1], isNull);
    },
  );
}

bool _isMarkupRemoval(Map<String, dynamic> body) =>
    body.containsKey('message_id') &&
    !body.containsKey('text') &&
    !body.containsKey('reply_markup');

void _expectMarkupsClosed(int chatId, Iterable<int> messageIds) {
  for (final messageId in messageIds) {
    expect(
      fakeMessageMarkups[(chatId, messageId)],
      isNull,
      reason: 'message $messageId still has an inline keyboard',
    );
  }
}

String _button(Map<String, dynamic> message, int row) {
  final keyboard = message['reply_markup']['inline_keyboard'] as List;
  return keyboard[row].first['text'] as String;
}
