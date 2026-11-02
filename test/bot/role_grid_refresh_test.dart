import 'dart:async';

import 'package:sdsc_bot/bot/hold.dart';
import 'package:sdsc_bot/bot/keyboards.dart';
import 'package:sdsc_bot/core/build_version.dart';
import 'package:sdsc_bot/core/models.dart';
import 'package:sdsc_bot/core/repo.dart';
import 'package:test/test.dart';

import '../support/grid_harness.dart';

void main() {
  setUp(setUpGrid);

  test(
    'logic-only release does not announce an unchanged admin grid',
    () async {
      repo.setSetting('role_grid_refresh_4_14_2_2', '1');
      await sendText(2, '/allstatus');

      expect(_refreshMessages(), isEmpty);
      expect(repo.getSetting(_marker(2)), '1');
      expect(
        repo.getSetting('role_grid_layout_2'),
        RoleKeyboard.layoutFingerprint('admin'),
      );
      expect(sent.last['text'], contains('All members status'));
    },
  );

  test(
    'member sees upgrade only when their legacy button labels differ',
    () async {
      repo.setTier(2, MemberTier.member);
      await sendPlainText(2, 'hello');

      expect(_refreshMessages(), hasLength(1));
      expect(
        repo.getSetting('role_grid_layout_2'),
        RoleKeyboard.layoutFingerprint(MemberTier.member),
      );
    },
  );

  test('checker grid remains silent when its labels are unchanged', () async {
    repo.setSetting('role_grid_refresh_4_14_2_80', '1');
    repo.upsertUser(
      User(
        id: 80,
        name: '@checker',
        experience: Experience.newbie,
        group: '',
        memberTier: MemberTier.check,
      ),
    );
    await sendPlainText(80, 'hello');

    expect(_refreshMessages(), isEmpty);
    expect(repo.getSetting(_marker(80)), '1');
  });

  test(
    'refresh retries a definite rejection and passes the original message',
    () async {
      repo.setSetting('role_grid_refresh_4.13.2_2', '1');
      failNextSendMessage = true;
      nextSendFailureStatus = 400;
      await sendText(2, '/allstatus');
      expect(_refreshMessages(), hasLength(1));
      expect(repo.getSetting(_marker(2)), isNull);
      expect(sent.last['text'], contains('All members status'));

      await sendText(2, '/allstatus');
      expect(_refreshMessages(), hasLength(2));
      expect(repo.getSetting(_marker(2)), '1');
      expect(repo.getSetting('role_grid_refresh_4.13.2_2'), '1');
      expect(sent.last['text'], contains('All members status'));
    },
  );

  test('simultaneous first messages serialize refresh per user', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var blocked = false;
    beforeSendMessageResponse = (body) async {
      if (body['text'] != 'Your command buttons have been updated.' ||
          blocked) {
        return;
      }
      blocked = true;
      entered.complete();
      await release.future;
    };

    final first = sendText(2, '/allstatus');
    await entered.future;
    final second = sendText(2, '/mystatus');
    release.complete();
    await Future.wait([first, second]);

    expect(_refreshMessages(), hasLength(1));
    expect(repo.getSetting(_marker(2)), '1');
  });

  test('held refresh does not write its marker and later retries', () async {
    bot.api.use(HoldTransformer(holdGate));
    repo.setHeld(true);
    holdGate.held = true;
    await sendPlainText(2, 'hello');
    expect(repo.getSetting(_marker(2)), isNull);

    repo.setHeld(false);
    holdGate.held = false;
    await sendPlainText(2, 'hello again');
    expect(repo.getSetting(_marker(2)), '1');
    expect(_refreshMessages(), hasLength(1));
  });

  test(
    'callbacks do not trigger refresh and old users get keyboard removal',
    () async {
      await sendCallback(2, 'configremind|stale|confirm_off');
      expect(_refreshMessages(), isEmpty);

      repo.upsertUser(
        User(
          id: 80,
          name: '@retired',
          experience: Experience.newbie,
          group: '',
          memberTier: MemberTier.old,
        ),
      );
      repo.setSetting(
        'role_grid_layout_80',
        RoleKeyboard.layoutFingerprint(MemberTier.member),
      );
      await sendText(80, '/start');
      final refresh = _refreshMessages().single;
      final markup = refresh['reply_markup'] as Map<String, dynamic>;
      expect(markup['remove_keyboard'], isTrue);
      expect(markup, isNot(contains('keyboard')));
      expect(repo.getSetting(_marker(80)), '1');
    },
  );
}

String _marker(int userId) => 'role_grid_refresh_${buildVersion}_$userId';

List<Map<String, dynamic>> _refreshMessages() => sent
    .where(
      (message) => message['text'] == 'Your command buttons have been updated.',
    )
    .toList();
