import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:test/test.dart';
import '../../support/admin_api_harness.dart';

void main() {
  setUp(setUpAdminApi);
  tearDown(tearDownAdminApi);

  test(
    'GET /api/users/pending returns sorted public registration fields',
    () async {
      repo.addPendingUser('zeta', isAdmin: false);
      repo.addPendingUser(
        'outmember',
        isAdmin: false,
        tier: MemberTier.outMember,
        notificationPreference: NotificationPreference.never,
      );
      repo.addPendingUser('checker', isAdmin: false, tier: MemberTier.check);
      repo.addPendingUser('admin', isAdmin: true, tier: MemberTier.member);
      repo.addPendingUser('alpha', isAdmin: false, tier: MemberTier.member);
      repo.upsertUser(
        User(
          id: 42,
          name: '@registered',
          experience: Experience.newbie,
          group: '1',
        ),
      );
      repo.addPendingUser('registered', isAdmin: false);

      final (status, response) = await signedCall('GET', '/api/users/pending');
      expect(status, 200);
      final body = response as Map<String, dynamic>;
      expect(body.keys.toSet(), {'ok', 'pending'});
      expect(body['ok'], true);
      final pending = (body['pending'] as List).cast<Map<String, dynamic>>();
      expect(pending.map((entry) => entry['username']), [
        'admin',
        'alpha',
        'checker',
        'outmember',
        'zeta',
      ]);
      expect(
        pending.map((entry) => entry.keys.toSet()),
        everyElement({'username', 'isAdmin', 'tier', 'notificationPreference'}),
      );
      expect(pending.first['isAdmin'], true);
      expect(pending.first['tier'], MemberTier.member);
      final out = pending.firstWhere(
        (entry) => entry['username'] == 'outmember',
      );
      expect(out['isAdmin'], false);
      expect(out['tier'], MemberTier.outMember);
      expect(out['notificationPreference'], 'never');
      expect(
        pending.any((entry) => entry['username'] == 'registered'),
        isFalse,
      );
      expect(repo.isPendingUser('registered'), isTrue);
    },
  );
}
