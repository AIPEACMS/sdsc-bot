
import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'support/admin_api_harness.dart';

void main() {
  setUp(setUpAdminApi);
  tearDown(tearDownAdminApi);
  test('GET /api/users lists users with resolved tiers', () async {
    repo.upsertUser(
      User(
        id: 101,
        name: '@alice',
        experience: Experience.experienced,
        group: 'A',
        preferredName: 'Alice',
      ),
    );
    repo.upsertUser(
      User(id: 2, name: '@bob', experience: Experience.newbie, group: 'B'),
    );
    repo.setTier(2, 'check');

    final (status, body) = await call('GET', '/api/users');
    expect(status, 200);
    final bodyMap = body as Map<String, dynamic>;
    final users = (bodyMap['users'] as List).cast<Map<String, dynamic>>();
    expect(users, hasLength(2));
    final alice = users.firstWhere((u) => u['id'] == 101);
    final bob = users.firstWhere((u) => u['id'] == 2);
    expect(alice['tier'], 'member');
    expect(alice['preferredName'], 'Alice');
    expect(bob['tier'], 'check');
    expect(alice['group'], 'A');
    expect(alice['attendance'], containsPair('total', 0));
  });

  test('POST /api/users/{id}/tier changes the tier', () async {
    repo.upsertUser(
      User(id: 7, name: '@carol', experience: Experience.newbie, group: 'A'),
    );
    final (status, body) = await call(
      'POST',
      '/api/users/7/tier',
      body: {'tier': 'admin'},
    );
    final bodyMap = body as Map<String, dynamic>;
    expect(status, 200);
    expect(bodyMap['ok'], true);
    expect(bodyMap['tier'], 'admin');
    expect(repo.findUser(7)!.isAdmin, true);

    await call('POST', '/api/users/7/tier', body: {'tier': 'old'});
    expect(repo.findUser(7)!.memberTier, 'old');
    expect(repo.findUser(7)!.isAdmin, false);
  });

  test('API converts out-members and persists notification preference', () async {
    repo.upsertUser(
      User(id: 17, name: '@out', experience: Experience.newbie, group: '1'),
    );
    final (tierStatus, tierBody) = await call(
      'POST',
      '/api/users/17/tier',
      body: {
        'tier': 'out-member',
        'notificationPreference': 'every-other',
      },
    );
    expect(tierStatus, 200);
    expect((tierBody as Map<String, dynamic>)['tier'], 'out-member');
    expect(repo.findUser(17)!.notificationPreference,
        NotificationPreference.everyOther);
    expect(repo.findUser(17)!.group, isEmpty);
    expect(repo.activeUsers().any((user) => user.id == 17), isTrue);

    final (tierAdminStatus, tierAdminBody) = await call(
      'POST',
      '/api/users/17/tier',
      body: {'tier': 'admin'},
    );
    expect(tierAdminStatus, 400);
    expect(
      (tierAdminBody as Map<String, dynamic>)['error'],
      contains('out-members'),
    );
    expect(repo.findUser(17)!.isAdmin, isFalse);

    final (adminStatus, adminBody) = await call(
      'POST',
      '/api/users/17/admin',
      body: {'admin': true},
    );
    expect(adminStatus, 400);
    expect(
      (adminBody as Map<String, dynamic>)['error'],
      contains('out-members'),
    );
    expect(repo.findUser(17)!.isAdmin, isFalse);

    final (notifyStatus, notifyBody) = await call(
      'POST',
      '/api/users/17/notification',
      body: {'preference': 'never'},
    );
    expect(notifyStatus, 200);
    expect(
      (notifyBody as Map<String, dynamic>)['notificationPreference'],
      'never',
    );
    expect(repo.findUser(17)!.notificationPreference,
        NotificationPreference.never);

    final (getStatus, getBody) = await call(
      'GET',
      '/api/users/17/notification',
    );
    expect(getStatus, 200);
    expect(
      (getBody as Map<String, dynamic>)['notificationPreference'],
      'never',
    );
  });

  test('out-members cannot be appointed as global admins', () async {
    repo.upsertUser(
      User(id: 18, name: '@out', experience: Experience.newbie, group: '1'),
    );
    repo.setTier(18, MemberTier.outMember);

    final (status, body) = await call(
      'POST',
      '/api/users/18/gadmin',
      body: {'gadmin': true},
    );
    expect(status, 400);
    expect((body as Map<String, dynamic>)['error'], contains('out-member'));
    expect(repo.globalAdmin(), isNull);
  });

  test('POST /api/users/{id}/exp changes experience', () async {
    repo.upsertUser(
      User(id: 7, name: '@carol', experience: Experience.newbie, group: 'A'),
    );
    final (status, body) = await call(
      'POST',
      '/api/users/7/exp',
      body: {'exp': 'experienced'},
    );
    expect(status, 200);
    expect((body as Map<String, dynamic>)['exp'], 'experienced');
    expect(repo.findUser(7)!.experience, Experience.experienced);

    final (badStatus, _) = await call(
      'POST',
      '/api/users/7/exp',
      body: {'exp': 'senior'},
    );
    expect(badStatus, 400);
    final (missingStatus, _) = await call(
      'POST',
      '/api/users/999/exp',
      body: {'exp': 'newbie'},
    );
    expect(missingStatus, 404);
  });

  test('POST /api/users registers or queues a member by handle', () async {
    // Unseen, unqueued handle → queued for first contact.
    final (q, _) = await call(
      'POST',
      '/api/users',
      body: {'handle': '@newbie'},
    );
    expect(q, 200);
    expect(repo.isPendingUser('newbie'), true);
    final pending = await call(
      'POST',
      '/api/users',
      body: {'handle': '@newbie', 'tier': 'check'},
    );
    expect(pending.$1, 200);
    expect((pending.$2 as Map<String, dynamic>)['warning'], true);
    expect((pending.$2 as Map<String, dynamic>)['message'], isNotEmpty);

    // A seen user is registered immediately as a plain member.
    repo.upsertSeenUser(202, 'alice');
    final (s, _) = await call('POST', '/api/users', body: {'handle': '@alice'});
    expect(s, 200);
    expect(repo.findUser(202), isNotNull);
    expect(repo.findUser(202)!.isAdmin, false);

    // Already a member → reported, no duplicate.
    final (d, dBody) = await call(
      'POST',
      '/api/users',
      body: {'handle': '@alice'},
    );
    expect(d, 200);
    expect(
      (dBody as Map<String, dynamic>)['message'],
      contains('already a member'),
    );

    // Garbage input is rejected.
    final (bad, _) = await call(
      'POST',
      '/api/users',
      body: {'handle': 'two words'},
    );
    expect(bad, 400);
  });

  test('POST /api/users defaults out-members to never notifications', () async {
    final (queuedStatus, _) = await call(
      'POST',
      '/api/users',
      body: {'handle': '@quiet', 'tier': 'out-member'},
    );
    expect(queuedStatus, 200);
    expect(repo.pendingRole('quiet')!.notificationPreference,
        NotificationPreference.never);

    repo.upsertSeenUser(404, 'seenquiet');
    final (addedStatus, _) = await call(
      'POST',
      '/api/users',
      body: {'handle': '@seenquiet', 'tier': 'out-member'},
    );
    expect(addedStatus, 200);
    expect(repo.findUser(404)!.notificationPreference,
        NotificationPreference.never);
  });

  test('POST /api/users adds a user directly as check tier', () async {
    // A seen user is registered immediately as a checker.
    repo.upsertSeenUser(303, 'carol');
    final (s, sBody) = await call(
      'POST',
      '/api/users',
      body: {'handle': '@carol', 'tier': 'check'},
    );
    expect(s, 200);
    expect(
      (sBody as Map<String, dynamic>)['message'],
      contains('added as a checker'),
    );
    expect(repo.findUser(303)!.memberTier, MemberTier.check);

    // An unseen user is queued as a checker; the tier survives registration.
    final (q, qBody) = await call(
      'POST',
      '/api/users',
      body: {'handle': '@dave', 'tier': 'check'},
    );
    expect(q, 200);
    expect(
      (qBody as Map<String, dynamic>)['message'],
      contains('queued as a checker'),
    );
    expect(repo.pendingTier('dave'), MemberTier.check);

    // A bad tier is rejected.
    final (bad, _) = await call(
      'POST',
      '/api/users',
      body: {'handle': '@eve', 'tier': 'admin'},
    );
    expect(bad, 400);
  });
}
