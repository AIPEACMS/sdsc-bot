
import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'support/admin_api_harness.dart';

void main() {
  setUp(setUpAdminApi);
  tearDown(tearDownAdminApi);
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

  test('POST /api/users restores old users by registered handle without /start',
      () async {
    repo.upsertUser(
      const User(
        id: 505,
        name: '@former',
        experience: Experience.newbie,
        group: '',
        memberTier: MemberTier.old,
      ),
    );
    repo.addPendingUser('former', isAdmin: false, tier: MemberTier.check);

    final (memberStatus, _) = await call(
      'POST',
      '/api/users',
      body: {'handle': '@former'},
    );
    expect(memberStatus, 200);
    expect(repo.findUser(505)!.memberTier, MemberTier.member);
    expect(repo.isPendingUser('former'), false);

    final (removeStatus, _) = await call(
      'POST',
      '/api/users/remove',
      body: {'handles': ['@former']},
    );
    expect(removeStatus, 200);

    final (outStatus, _) = await call(
      'POST',
      '/api/users',
      body: {'handle': '@former', 'tier': 'out-member'},
    );
    expect(outStatus, 200);
    expect(repo.findUser(505)!.memberTier, MemberTier.outMember);
  });

  test('POST /api/users/remove validates registered and pending batches atomically',
      () async {
    repo.upsertSeenUser(501, 'alice');
    repo.upsertUser(
      User(id: 501, name: '@alice', experience: Experience.newbie, group: '2'),
    );
    repo.addPendingUser('never_started', isAdmin: false);

    final (invalidStatus, invalidBody) = await call(
      'POST',
      '/api/users/remove',
      body: {
        'handles': ['@alice', '@unknown'],
      },
    );
    expect(invalidStatus, 404);
    expect((invalidBody as Map<String, dynamic>)['error'], '@unknown is not found');
    expect(repo.findUser(501)!.memberTier, MemberTier.member);
    expect(repo.isPendingUser('never_started'), true);

    final (status, body) = await call(
      'POST',
      '/api/users/remove',
      body: {
        'handles': ['@alice', '@never_started'],
      },
    );
    expect(status, 200);
    expect((body as Map<String, dynamic>)['removed'], ['@alice', '@never_started']);
    expect(repo.findUser(501)!.memberTier, MemberTier.old);
    expect(repo.findUser(501)!.group, isEmpty);
    expect(repo.isPendingUser('never_started'), false);

    repo.addPendingUser('alice', isAdmin: false);
    final (oldStatus, _) = await call(
      'POST',
      '/api/users/remove',
      body: {
        'handles': ['@alice'],
      },
    );
    expect(oldStatus, 404);
    expect(repo.isPendingUser('alice'), true);
  });

  test('POST /api/users/remove protects admins and keeps no pending endpoint',
      () async {
    repo.upsertSeenUser(502, 'admin');
    repo.upsertUser(
      User(
        id: 502,
        name: '@admin',
        experience: Experience.newbie,
        group: '1',
        isAdmin: true,
      ),
    );
    repo.addPendingUser('pending_admin', isAdmin: true);
    final (registeredStatus, _) = await call(
      'POST',
      '/api/users/remove',
      body: {
        'handles': ['@admin'],
      },
    );
    expect(registeredStatus, 409);
    final (pendingStatus, _) = await call(
      'POST',
      '/api/users/remove',
      body: {
        'handles': ['@pending_admin'],
      },
    );
    expect(pendingStatus, 409);
    expect(repo.pendingIsAdmin('pending_admin'), true);
    expect((await call('GET', '/api/users/pending')).$1, 404);
  });

  test('POST /api/users/remove protects global admins and preserves console identity',
      () async {
    repo.upsertSeenUser(504, 'global');
    repo.upsertUser(
      User(id: 504, name: '@global', experience: Experience.newbie, group: '1'),
    );
    expect(repo.appointGlobalAdmin(504), GlobalAdminResult.success);
    final (globalStatus, _) = await call(
      'POST',
      '/api/users/remove',
      body: {
        'handles': ['@global'],
      },
    );
    expect(globalStatus, 409);

    repo.upsertSeenUser(1, 'console');
    repo.upsertUser(
      const User(id: 1, name: '@console', experience: Experience.newbie, group: '3'),
    );
    final (consoleStatus, _) = await call(
      'POST',
      '/api/users/remove',
      body: {
        'handles': ['@console'],
      },
    );
    expect(consoleStatus, 200);
    expect(repo.findUser(1)!.memberTier, MemberTier.old);
    final (_, usersBody) = await call('GET', '/api/users');
    final users = ((usersBody as Map<String, dynamic>)['users'] as List)
        .cast<Map<String, dynamic>>();
    expect(
      users.firstWhere((user) => user['id'] == 1)['groups'],
      contains('console'),
    );
  });

}
