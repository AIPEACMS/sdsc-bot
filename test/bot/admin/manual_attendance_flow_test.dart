import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:sdsc_bot/bot/admin.dart';
import 'package:sdsc_bot/bot/service.dart';
import 'package:test/test.dart';
import '../../support/grid_harness.dart';

void main() {
  setUp(() async {
    await setUpGrid();
    flows.onManualAttendanceText = admin.onManualAttendanceText;
    flows.onPendingInputCleared = (userId, command) {
      if (command.startsWith('manualattendance')) {
        admin.onManualAttendanceInputCleared(userId);
      }
    };
  });

  test(
    'all-member command is gadmin-only and picker excludes ineligible tiers',
    () async {
      await sendText(2, '/manual_mark_all_attend');
      expect(sent.last['text'], contains('not authorized'));

      for (var id = 10; id < 16; id++) {
        repo.upsertUser(
          User(
            id: id,
            name: '@member$id',
            experience: Experience.newbie,
            group: '1',
          ),
        );
      }
      await sendText(1, '/manual_mark_all_attend');
      expect(sent.last['text'], contains('global attendance correction'));
      final keyboard = sent.last['reply_markup']['inline_keyboard'] as List;
      expect(keyboard.first, hasLength(1));
      final buttons = keyboard
          .cast<List<dynamic>>()
          .take(5)
          .expand((row) => row.cast<Map<String, dynamic>>())
          .toList();
      expect(buttons.length, 5);
      final labels = buttons.map((button) => button['text'] as String).toList();
      expect(labels, everyElement(isNot(contains('@checker'))));
      expect(labels, everyElement(isNot(contains('@out-member'))));
      expect(keyboard[5].first['text'], contains('Next'));

      final next = keyboard[5].first['callback_data'] as String;
      await sendCallback(1, next);
      expect(edited.last['text'], contains('Choose an active member'));
    },
  );

  test(
    'group command is available to all admins and zero requires confirmation',
    () async {
      await sendText(2, '/manual_mark_group_attend');
      expect(sent.last['text'], contains('in your group'));

      final keyboard = sent.last['reply_markup']['inline_keyboard'] as List;
      final callback = keyboard.first.first['callback_data'] as String;
      final targetId = int.parse(callback.split('|').last);
      final originalBalance = repo.findUser(targetId)!.attendanceBalance;
      await sendCallback(2, callback);
      expect(
        edited.last['text'],
        contains('Current persisted attendance balance'),
      );
      expect(edited.last['text'], contains('Current session-attendance count'));
      expect(
        edited.last['reply_markup']['inline_keyboard'].last.first['text'],
        'Cancel',
      );
      await sendPlainText(2, '0');
      expect(sent.last['text'], contains('Attendance correction preview'));
      expect(sent.last['text'], contains('Proposed resulting balance'));
      expect(sent.last['text'], contains('Requested adjustment: 0'));
      expect(repo.findUser(targetId)!.attendanceBalance, originalBalance);
      await sendCallback(2, 'manualattconfirm|no');
      expect(repo.findUser(targetId)!.attendanceBalance, originalBalance);
      expect(edited.last['text'], contains('Cancelled'));
      expect(edited.last['reply_markup'], isNull);
      expect(state.interactiveMessages[2], isNull);
    },
  );

  test(
    'positive adjustment and optional date persist without changing session rows',
    () async {
      repo.setActiveOutreach('prompt', false);
      repo.upsertUser(
        User(
          id: 21,
          name: '@manualtest',
          experience: Experience.newbie,
          group: '1',
        ),
      );
      await sendText(1, '/manual_mark_all_attend');
      final picker = sent.last['reply_markup']['inline_keyboard'] as List;
      final targetCallback = picker
          .expand((row) => row as List)
          .map((button) => button['callback_data'] as String)
          .firstWhere((data) => data.endsWith('|21'));
      const targetId = 21;
      final before = repo.attendanceStats(targetId).total;
      final initial = repo.findUser(targetId)!.attendanceBalance;
      await sendCallback(1, targetCallback);
      expect(edited.last['text'], contains('@manualtest'));
      expect(
        edited.last['text'],
        contains('Current session-attendance count: $before'),
      );
      expect(
        edited.last['text'],
        contains('Current last-attended date: never'),
      );
      expect(
        edited.last['text'],
        contains('Current persisted attendance balance: $initial'),
      );
      expect(edited.last['text'], contains('example: <code>2 Aug 24</code>'));
      await sendPlainText(1, '3 Aug 24');
      expect(repo.findUser(targetId)!.attendanceBalance, initial);
      expect(
        sent.last['text'],
        contains('Attendance correction preview for @manualtest'),
      );
      expect(sent.last['text'], contains('Requested adjustment: 3'));
      expect(
        sent.last['text'],
        contains('Proposed last-attended date: 2026-08-24'),
      );
      expect(
        sent.last['text'],
        contains('Proposed resulting balance: ${initial + 3}'),
      );
      expect(state.interactiveMessages[1], contains((1, 1)));

      await sendCallback(1, 'manualattconfirm|yes');

      final updated = repo.findUser(targetId)!;
      expect(updated.attendanceBalance, initial + 3);
      expect(updated.lastAttendedDate, DateTime(2026, 8, 24));
      expect(repo.attendanceStats(targetId).total, before);
      expect(edited.last['text'], contains('Attendance updated'));
      expect(edited.last['reply_markup'], isNull);
      await sendCallback(1, 'manualattconfirm|yes');
      expect(repo.findUser(targetId)!.attendanceBalance, initial + 3);
    },
  );

  test(
    'prompt Cancel replaces the prompt and clears tracked controls',
    () async {
      useUniqueTelegramMessageIds = true;
      await sendText(2, '/manual_mark_group_attend');
      final picker = sent.last['reply_markup']['inline_keyboard'] as List;
      final callback = picker.first.first['callback_data'] as String;
      await sendCallback(2, callback, messageId: sentMessageIds.last);
      expect(state.interactiveMessages[2], contains((2, 1)));

      final messageIds = sentMessageIds.toList();
      await sendCallback(
        2,
        'manualatt|cancel|0|cancel',
        messageId: messageIds.last,
      );

      expect(edited.last['text'], 'Cancelled.');
      expect(edited.last['reply_markup'], isNull);
      expect(state.pendingArg, isNot(contains(2)));
      expect(state.interactiveMessages[2], isNull);
      for (final messageId in messageIds) {
        expect(fakeMessageMarkups[(2, messageId)], isNull);
      }
    },
  );

  test(
    'positive preview Cancel never changes balance and removes buttons',
    () async {
      useUniqueTelegramMessageIds = true;
      repo.upsertUser(
        User(
          id: 22,
          name: '@cancelpreview',
          experience: Experience.newbie,
          group: '1',
        ),
      );
      await sendText(1, '/manual_mark_all_attend');
      final picker = sent.last['reply_markup']['inline_keyboard'] as List;
      final targetCallback = picker
          .expand((row) => row as List)
          .map((button) => button['callback_data'] as String)
          .firstWhere((data) => data.endsWith('|22'));
      await sendCallback(1, targetCallback, messageId: sentMessageIds.last);
      final balance = repo.findUser(22)!.attendanceBalance;
      await sendPlainText(1, '3 Oct 10');
      expect(sent.last['text'], contains('Requested adjustment: 3'));
      expect(repo.findUser(22)!.attendanceBalance, balance);

      final messageIds = sentMessageIds.toList();
      await sendCallback(1, 'manualattconfirm|no', messageId: messageIds.last);

      expect(repo.findUser(22)!.attendanceBalance, balance);
      expect(edited.last['text'], contains('Cancelled'));
      expect(edited.last['reply_markup'], isNull);
      expect(state.interactiveMessages[1], isNull);
      for (final messageId in messageIds) {
        expect(fakeMessageMarkups[(1, messageId)], isNull);
      }
    },
  );

  test('valid command interrupts input and preview stages cleanly', () async {
    await sendText(2, '/manual_mark_group_attend');
    var picker = sent.last['reply_markup']['inline_keyboard'] as List;
    await sendCallback(2, picker.first.first['callback_data'] as String);
    final inputBefore = repo.findUser(2)!.attendanceBalance;

    await sendText(2, '/status');

    expect(state.pendingArg, isNot(contains(2)));
    expect(state.interactiveMessages[2], isNull);
    expect(edited.any((message) => message['reply_markup'] == null), isTrue);
    expect(repo.findUser(2)!.attendanceBalance, inputBefore);

    await sendText(2, '/manual_mark_group_attend');
    picker = sent.last['reply_markup']['inline_keyboard'] as List;
    await sendCallback(2, picker.first.first['callback_data'] as String);
    await sendPlainText(2, '2');
    final previewBefore = repo.findUser(2)!.attendanceBalance;

    await sendText(2, '/status');

    expect(state.pendingArg, isNot(contains(2)));
    expect(state.interactiveMessages[2], isNull);
    expect(repo.findUser(2)!.attendanceBalance, previewBefore);
  });

  test(
    'stale selection callback is rejected after the global-admin role changes',
    () async {
      await sendText(1, '/manual_mark_all_attend');
      final picker = sent.last['reply_markup']['inline_keyboard'] as List;
      final callback = picker.first.first['callback_data'] as String;
      repo.raw.execute('UPDATE users SET is_global_admin = 0 WHERE id = 1');
      await sendCallback(1, callback);

      expect(edited.last['text'], contains('not authorized'));
      expect(edited.last['reply_markup'], isNull);
      expect(
        edited.any(
          (body) =>
              body.containsKey('message_id') &&
              !body.containsKey('text') &&
              !body.containsKey('reply_markup'),
        ),
        isTrue,
      );
      expect(state.pendingArg, isEmpty);
    },
  );

  test('same-day absence notice is edited rather than sent again', () async {
    repo.setActiveOutreach('prompt', false);
    final today = config.toLocal(Config.nowUtc());
    final groupAdminId = repo.groupAdmin(repo.findUser(2)!.group)!.id;
    repo.markMessageSent(groupAdminId, 'absent', today, telegramMessageId: 77);
    expect(repo.messageIdSentOnDay(groupAdminId, 'absent', today), 77);
    final sentCount = sent.length;

    await service.reconcileAttendanceCorrection(repo.findUser(2)!);

    expect(sent.length, sentCount);
    expect(edited.last['message_id'], 77);
    expect(edited.last['chat_id'], groupAdminId);
  });

  test(
    'legacy same-day absence row gets one update send then edits it',
    () async {
      repo.setActiveOutreach('prompt', false);
      final today = config.toLocal(Config.nowUtc());
      final groupAdminId = repo.groupAdmin(repo.findUser(2)!.group)!.id;
      repo.markMessageSent(groupAdminId, 'absent', today);
      final sentBefore = sent.length;

      await service.reconcileAttendanceCorrection(repo.findUser(2)!);

      expect(sent.length, sentBefore + 1);
      expect(sent.last['text'], contains('Updated absence status'));
      expect(repo.messageIdSentOnDay(groupAdminId, 'absent', today), 1);
      expect(
        repo.raw.select(
          'SELECT message_id_update_attempted FROM sent_messages '
          'WHERE user_id = ? AND kind = ? AND day = ?',
          [groupAdminId, 'absent', today.toIso8601String().substring(0, 10)],
        ).single['message_id_update_attempted'],
        1,
      );

      await service.reconcileAttendanceCorrection(repo.findUser(2)!);

      expect(sent.length, sentBefore + 1);
      expect(edited.last['message_id'], 1);
      expect(edited.last['text'], contains('Updated absence status'));
    },
  );

  test(
    'legacy correction send failure is claimed and not retried that day',
    () async {
      repo.setActiveOutreach('prompt', false);
      final today = config.toLocal(Config.nowUtc());
      final groupAdminId = repo.groupAdmin(repo.findUser(2)!.group)!.id;
      repo.markMessageSent(groupAdminId, 'absent', today);
      failNextSendMessage = true;
      final sentBefore = sent.length;

      await service.reconcileAttendanceCorrection(repo.findUser(2)!);

      expect(sent.length, sentBefore + 1);
      expect(sent.last['text'], contains('Updated absence status'));
      expect(repo.messageIdSentOnDay(groupAdminId, 'absent', today), isNull);
      expect(
        repo.raw.select(
          'SELECT message_id_update_attempted FROM sent_messages '
          'WHERE user_id = ? AND kind = ? AND day = ?',
          [groupAdminId, 'absent', today.toIso8601String().substring(0, 10)],
        ).single['message_id_update_attempted'],
        1,
      );
      final editsBefore = edited.length;

      await service.reconcileAttendanceCorrection(repo.findUser(2)!);

      expect(sent.length, sentBefore + 1);
      expect(edited.length, editsBefore);
    },
  );

  test(
    'failed edit of a correction message never falls back to a send',
    () async {
      repo.setActiveOutreach('prompt', false);
      final today = config.toLocal(Config.nowUtc());
      final groupAdminId = repo.groupAdmin(repo.findUser(2)!.group)!.id;
      repo.markMessageSent(
        groupAdminId,
        'absent',
        today,
        telegramMessageId: 77,
      );
      failNextEditMessageText = true;
      final sentBefore = sent.length;

      await service.reconcileAttendanceCorrection(repo.findUser(2)!);

      expect(sent.length, sentBefore);
      expect(edited.length, 1);
      expect(edited.single['message_id'], 77);
      expect(repo.messageIdSentOnDay(groupAdminId, 'absent', today), 77);

      await service.reconcileAttendanceCorrection(repo.findUser(2)!);

      expect(sent.length, sentBefore);
      expect(edited.length, 2);
      expect(edited.last['message_id'], 77);
    },
  );
}
