import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'support/grid_harness.dart';

void main() {
  setUp(setUpGrid);
  test('/start shows every actual role in the approved order', () async {
    Future<String> startText(int userId) async {
      final before = sent.length;
      await sendText(userId, '/start');
      return sent[before]['text'] as String;
    }

    repo.updatePreferredName(1, 'Console');
    expect(
      await startText(1),
      '👋 <b>@console</b>, here is what you can do:\n\n'
      '<b>Console</b>\nmore-cmd - show additional commands\n\n'
      '<b>Global admin</b>\n'
      'hold - pause outgoing messages\n'
      'unhold - resume outgoing messages\n'
      'set-time - set activity days, times and locations\n\n'
      '<b>Admin</b>\n'
      'add-user - add members\n'
      'add-out-user - add out-members\n'
      'group-status - show your group\'s cycle state and responders\n'
      'all-status - show cycle state and responders\n'
      'ask - send one member an availability picker\n'
      'mark-attend - mark attendance\n'
      'broadcast - message all members\n\n'
      '<b>Member</b>\n'
      'start - show the welcome and role buttons\n'
      '(re)pick - update your availability\n'
      'set-info - update your preferred name\n'
      'my-status - show your picks, allocation and attendance\n'
      '\nTap more-cmd for additional commands.\n'
      'Type /grid to switch which grid you see (console only).',
    );
    expect(keyboardTexts(sent.last).first, 'more-cmd');
    expect(keyboardTexts(sent.last), contains('hold'));

    expect(repo.removeGlobalAdmin(1), isTrue);
    repo.upsertUser(
      User(
        id: 5,
        name: '@adminonly',
        experience: Experience.newbie,
        group: '1',
      ),
    );
    expect(repo.appointGlobalAdmin(5), GlobalAdminResult.success);
    repo.updatePreferredName(5, 'Global');
    expect(
      await startText(5),
      '👋 <b>@adminonly</b>, here is what you can do:\n\n'
      '<b>Global admin</b>\n'
      'more-cmd - show additional commands\n'
      'hold - pause outgoing messages\n'
      'unhold - resume outgoing messages\n'
      'set-time - set activity days, times and locations\n\n'
      '<b>Admin</b>\n'
      'add-user - add members\n'
      'add-out-user - add out-members\n'
      'group-status - show your group\'s cycle state and responders\n'
      'all-status - show cycle state and responders\n'
      'ask - send one member an availability picker\n'
      'mark-attend - mark attendance\n'
      'broadcast - message all members\n\n'
      '<b>Member</b>\n'
      'start - show the welcome and role buttons\n'
      '(re)pick - update your availability\n'
      'set-info - update your preferred name\n'
      'my-status - show your picks, allocation and attendance\n'
      '\nTap more-cmd for additional commands.',
    );

    expect(repo.removeGlobalAdmin(5), isTrue);
    expect(repo.updateAdmin(1, true), isTrue);
    expect(
      await startText(1),
      '👋 <b>@console</b>, here is what you can do:\n\n'
      '<b>Console</b>\nmore-cmd - show additional commands\n\n'
      '<b>Admin</b>\n'
      'add-user - add members\n'
      'add-out-user - add out-members\n'
      'group-status - show your group\'s cycle state and responders\n'
      'all-status - show cycle state and responders\n'
      'ask - send one member an availability picker\n'
      'mark-attend - mark attendance\n'
      'broadcast - message all members\n\n'
      '<b>Member</b>\n'
      'start - show the welcome and role buttons\n'
      '(re)pick - update your availability\n'
      'set-info - update your preferred name\n'
      'my-status - show your picks, allocation and attendance\n'
      '\nTap more-cmd for additional commands.\n'
      'Type /grid to switch which grid you see (console only).',
    );

    expect(repo.updateAdmin(1, false), isTrue);
    repo.raw.execute('DELETE FROM users WHERE id = ?', [1]);
    expect(
      await startText(1),
      '👋 <b>Console</b>, here is what you can do:\n\n'
      '<b>Console</b>\nmore-cmd - show additional commands\n'
      '\nTap more-cmd for additional commands.\n'
      'Type /grid to switch which grid you see (console only).',
    );

    repo.updatePreferredName(2, 'Admin');
    expect(
      await startText(2),
      '👋 <b>@admin</b>, here is what you can do:\n\n'
      '<b>Admin</b>\n'
      'more-cmd - show additional commands\n'
      'add-user - add members\n'
      'add-out-user - add out-members\n'
      'group-status - show your group\'s cycle state and responders\n'
      'all-status - show cycle state and responders\n'
      'ask - send one member an availability picker\n'
      'mark-attend - mark attendance\n'
      'broadcast - message all members\n\n'
      '<b>Member</b>\n'
      'start - show the welcome and role buttons\n'
      '(re)pick - update your availability\n'
      'set-info - update your preferred name\n'
      'my-status - show your picks, allocation and attendance\n'
      '\nTap more-cmd for additional commands.',
    );

    repo.upsertUser(
      User(id: 4, name: '@member', experience: Experience.newbie, group: '1'),
    );
    repo.updatePreferredName(4, 'Member');
    expect(
      await startText(4),
      '👋 <b>@member</b>, here is what you can do:\n\n'
      '<b>Member</b>\n'
      'start - show the welcome and role buttons\n'
      '(re)pick - update your availability\n'
      'set-info - update your preferred name\n'
      'my-status - show your picks, allocation and attendance\n'
      're-pick — update your availability\n'
      'set-info — update your preferred name\n'
      'my-status — your picks, allocation and attendance',
    );

    repo.upsertUser(
      User(
        id: 7,
        name: '@outmember',
        experience: Experience.newbie,
        group: '',
        memberTier: MemberTier.outMember,
      ),
    );
    expect(
      await startText(7),
      '👋 <b>@outmember</b>, here is what you can do:\n\n'
       '<b>Member-o</b>\n'
      'start - show the welcome and role buttons\n'
      '(re)pick - update your availability\n'
      'set-info - update your preferred name\n'
      'my-status - show your picks and allocation\n'
      'notify - choose prompt frequency\n'
      're-pick — update your availability\n'
      'set-info — update your preferred name\n'
      'my-status — your picks and allocation\n'
      'notify — choose prompt frequency',
    );

    expect(
      await startText(3),
      '👋 <b>@checker</b>, you are a checker.\n\n'
      'check-status - show the current week\'s allocation',
    );
    expect(keyboardTexts(sent.last), ['check-status']);

    repo.upsertUser(
      User(
        id: 6,
        name: '@retired',
        experience: Experience.newbie,
        group: '1',
        memberTier: MemberTier.old,
      ),
    );
    expect(
      await startText(6),
      '👋 <b>@retired</b>, here is what you can do:\n'
      'Thank you for your commitment! Hope to see you in the future!\n',
    );
  });

  test(
    '/grid cycles the stored role through the available previews',
    () async {
      await sendText(1, '/grid');
      expect(sent.last['text'], contains('Preview: admin grid'));
      expect(
        keyboardTexts(sent.last),
        containsAll([
          'add-user',
          'add-out-user',
          'group-status',
          'all-status',
          'broadcast',
        ]),
      );
      expect(keyboardTexts(sent.last), contains('all-status'));
      expect(keyboardTexts(sent.last), isNot(contains('all-users')));
      expect(keyboardTexts(sent.last), isNot(contains('prompt')));
      expect(keyboardTexts(sent.last), isNot(contains('remind')));
      expect(keyboardTexts(sent.last), isNot(contains('allocate')));

      await sendText(1, '/grid');
      expect(sent.last['text'], contains('Preview: check grid'));
      expect(keyboardTexts(sent.last), contains('check-status'));

      await sendText(1, '/grid');
      expect(sent.last['text'], contains('Preview: member grid'));
      expect(keyboardTexts(sent.last), contains('(re)pick'));

      await sendText(1, '/grid');
      expect(sent.last['text'], contains('Preview: out-member grid'));
      expect(keyboardTexts(sent.last), contains('notify'));
    },
  );

}
