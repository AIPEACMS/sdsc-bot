import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:test/test.dart';
import '../../support/grid_harness.dart';

void main() {
  setUp(setUpGrid);

  test(
    'pending commands enforce roles, filters, sorting, and HTML escaping',
    () async {
      repo.addPendingUser('memberzeta', isAdmin: false);
      repo.addPendingUser('odd<&"\'', isAdmin: false);
      repo.addPendingUser(
        'adminpending',
        isAdmin: true,
        tier: MemberTier.member,
      );
      repo.addPendingUser(
        'checkerpending',
        isAdmin: false,
        tier: MemberTier.check,
      );
      repo.addPendingUser(
        'memberalpha',
        isAdmin: false,
        tier: MemberTier.member,
      );
      repo.addPendingUser(
        'outpending',
        isAdmin: false,
        tier: MemberTier.outMember,
        notificationPreference: NotificationPreference.everyOther,
      );
      repo.upsertUser(
        User(id: 60, name: '@stale', experience: Experience.newbie, group: '1'),
      );
      repo.addPendingUser('stale', isAdmin: false);

      await sendText(2, '/view_pend_user');
      expect(sent.last['text'], contains('not authorized'));

      await sendText(1, '/view_pend_user');
      final all = sent.last['text'] as String;
      expect(all, contains('All pending registrations (6)'));
      expect(all, contains('• <b>@adminpending</b> — admin'));
      expect(all, contains('• <b>@checkerpending</b> — check'));
      expect(
        all,
        contains(
          '• <b>@outpending</b> — out-member, notifications every other week',
        ),
      );
      expect(all, contains('• <b>@odd&lt;&amp;&quot;&#39;</b> — member'));
      expect(all, isNot(contains('@stale')));
      expect(all, isNot(contains('group')));
      final orderedHandles = [
        '@adminpending',
        '@checkerpending',
        '@memberalpha',
        '@memberzeta',
        '@odd&lt;&amp;&quot;&#39;',
        '@outpending',
      ];
      final positions = orderedHandles.map(all.indexOf).toList();
      expect(positions, orderedEquals([...positions]..sort()));
      expect(repo.isPendingUser('stale'), isTrue);

      await sendText(2, '/view_pend_member');
      final members = sent.last['text'] as String;
      expect(members, contains('Pending members (4)'));
      expect(members, contains('@memberalpha'));
      expect(members, contains('@memberzeta'));
      expect(members, contains('notifications every other week'));
      expect(members, isNot(contains('@adminpending')));
      expect(members, isNot(contains('@checkerpending')));
      expect(members, isNot(contains('@stale')));
      expect(members, isNot(contains('group')));

      await sendText(1, '/view_pend_member');
      expect(sent.last['text'], contains('Pending members (4)'));
      await sendText(4, '/view_pend_member');
      expect(sent.last['text'], contains('not an admin'));
    },
  );

  test(
    'empty pending listings are friendly and do not delete stale rows',
    () async {
      repo.upsertUser(
        User(
          id: 61,
          name: '@alreadyregistered',
          experience: Experience.newbie,
          group: '',
        ),
      );
      repo.addPendingUser('alreadyregistered', isAdmin: false);

      await sendText(1, '/view_pend_user');
      expect(sent.last['text'], 'There are no pending registrations.');
      await sendText(2, '/view_pend_member');
      expect(
        sent.last['text'],
        'There are no pending member or out-member registrations.',
      );
      expect(repo.isPendingUser('alreadyregistered'), isTrue);
    },
  );
}
