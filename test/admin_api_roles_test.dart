
import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'support/admin_api_harness.dart';

void main() {
  setUp(setUpAdminApi);
  tearDown(tearDownAdminApi);
  // ------------------------------------------------------------ groups

  test('GET /api/users reports every group of a user', () async {
    // Id 1 is the console id in this test config (makeConfig).
    repo.upsertUser(
      User(
        id: 1,
        name: '@root',
        experience: Experience.experienced,
        group: 'A',
        isAdmin: true,
      ),
    );
    repo.upsertUser(
      User(
        id: 101,
        name: '@alice',
        experience: Experience.newbie,
        group: 'A',
        isAdmin: true,
      ),
    );
    repo.upsertUser(
      User(id: 2, name: '@bob', experience: Experience.newbie, group: 'B'),
    );
    repo.setTier(2, 'check');
    repo.upsertUser(
      User(id: 3, name: '@carol', experience: Experience.newbie, group: 'A'),
    );
    repo.setTier(3, 'old');
    repo.upsertUser(
      User(id: 4, name: '@dave', experience: Experience.newbie, group: 'B'),
    );

    final (status, body) = await call('GET', '/api/users');
    expect(status, 200);
    final users = ((body as Map<String, dynamic>)['users'] as List)
        .cast<Map<String, dynamic>>();

    String? groupOf(int id) {
      final u = users.firstWhere((u) => u['id'] == id);
      return (u['groups'] as List).cast<String>().join(' | ');
    }

    expect(groupOf(1), 'console | admin');
    expect(groupOf(101), 'admin');
    expect(groupOf(2), 'check');
    expect(groupOf(3), 'old');
    expect(groupOf(4), 'member');
  });

  test('a console who stepped down as admin shows console | member', () async {
    repo.upsertUser(
      User(
        id: 1,
        name: '@root',
        experience: Experience.experienced,
        group: 'A',
        isAdmin: true,
      ),
    );
    // Console removes their own admin flag: still a member, not an admin.
    await call('POST', '/api/users/1/admin', body: {'admin': false});
    final (_, body) = await call('GET', '/api/users');
    final users = ((body as Map<String, dynamic>)['users'] as List)
        .cast<Map<String, dynamic>>();
    final root = users.firstWhere((u) => u['id'] == 1);
    expect((root['groups'] as List).cast<String>(), ['console', 'member']);
    // Still active: a retired-from-admin console is a normal member.
    expect(repo.activeUsers().any((u) => u.id == 1), isTrue);
  });

  // ------------------------------------------------------- user admin

  test(
    'POST /api/users/{id}/admin grants and strips admin, keeping the tier',
    () async {
      repo.upsertUser(
        User(id: 7, name: '@carol', experience: Experience.newbie, group: 'A'),
      );
      repo.setTier(7, 'check'); // check, not admin
      expect(repo.findUser(7)!.memberTier, 'check');

      final (status, body) = await call(
        'POST',
        '/api/users/7/admin',
        body: {'admin': true},
      );
      expect(status, 200);
      expect((body as Map<String, dynamic>)['admin'], true);
      expect(repo.findUser(7)!.isAdmin, true);
      expect(repo.findUser(7)!.memberTier, 'check'); // tier untouched

      await call('POST', '/api/users/7/admin', body: {'admin': false});
      expect(repo.findUser(7)!.isAdmin, false);
      expect(repo.findUser(7)!.memberTier, 'check');

      // The console can also toggle their own admin flag (stepping down as
      // admin while staying the console).
      repo.upsertUser(
        User(
          id: 1,
          name: '@root',
          experience: Experience.experienced,
          group: 'A',
          isAdmin: true,
        ),
      );
      final (consoleStatus, _) = await call(
        'POST',
        '/api/users/1/admin',
        body: {'admin': false},
      );
      expect(consoleStatus, 200);
      expect(repo.findUser(1)!.isAdmin, false);
    },
  );

  // ------------------------------------------------------- global admin

  test(
    'POST /api/users/{id}/gadmin appoints and removes the singleton global admin',
    () async {
      repo.upsertUser(
        User(id: 7, name: '@carol', experience: Experience.newbie, group: 'A'),
      );
      repo.upsertUser(
        User(id: 8, name: '@dave', experience: Experience.newbie, group: 'B'),
      );

      // Appoint @carol — mutually exclusive with the normal-admin flag.
      final (status, body) = await call(
        'POST',
        '/api/users/7/gadmin',
        body: {'gadmin': true},
      );
      expect(status, 200);
      expect((body as Map<String, dynamic>)['gadmin'], true);
      expect(repo.globalAdmin()!.id, 7);
      expect(repo.findUser(7)!.isAdmin, false);

      // The one-global-admin rule: a second appointment is refused.
      final (conflict, conflictBody) = await call(
        'POST',
        '/api/users/8/gadmin',
        body: {'gadmin': true},
      );
      expect(conflict, 409);
      expect(
        (conflictBody as Map<String, dynamic>)['error'],
        contains('already exists'),
      );
      expect(repo.globalAdmin()!.id, 7);

      // Remove @carol: back to a regular member, group dissolved.
      final (removed, removedBody) = await call(
        'POST',
        '/api/users/7/gadmin',
        body: {'gadmin': false},
      );
      expect(removed, 200);
      expect((removedBody as Map<String, dynamic>)['gadmin'], false);
      expect(repo.globalAdmin(), isNull);
      expect(repo.findUser(7)!.memberTier, 'member');
      expect(repo.findUser(7)!.group, '');

      // The slot is free again, so the second user can take it.
      final (again, _) = await call(
        'POST',
        '/api/users/8/gadmin',
        body: {'gadmin': true},
      );
      expect(again, 200);
      expect(repo.globalAdmin()!.id, 8);
    },
  );

  test('POST /api/users/{id}/gadmin rejects unknown ids and bad bodies', () async {
    repo.upsertUser(
      User(id: 7, name: '@carol', experience: Experience.newbie, group: 'A'),
    );

    final (missing, missingBody) = await call(
      'POST',
      '/api/users/999/gadmin',
      body: {'gadmin': true},
    );
    expect(missing, 404);
    expect(
      (missingBody as Map<String, dynamic>)['error'],
      contains('no such user'),
    );

    final (bad, badBody) = await call(
      'POST',
      '/api/users/7/gadmin',
      body: {'gadmin': 'yes'},
    );
    expect(bad, 400);
    expect((badBody as Map<String, dynamic>)['error'], contains('gadmin'));

    // Removing a user who is not the global admin is refused and changes
    // nothing.
    final (notGadmin, _) = await call(
      'POST',
      '/api/users/7/gadmin',
      body: {'gadmin': false},
    );
    expect(notGadmin, 409);
    expect(repo.findUser(7)!.memberTier, 'member');
  });

  test(
    'the console can demote themselves to old (no prompts, no allocation)',
    () async {
      // Id 1 is the console id in this test config.
      repo.upsertUser(
        User(
          id: 1,
          name: '@root',
          experience: Experience.experienced,
          group: 'A',
          isAdmin: true,
        ),
      );
      final (status, body) = await call(
        'POST',
        '/api/users/1/tier',
        body: {'tier': 'old'},
      );
      expect(status, 200);
      final u = repo.findUser(1)!;
      expect(u.memberTier, 'old');
      expect(u.isAdmin, false);
      // Dropped from the prompt/allocation pool.
      expect(repo.activeUsers().any((x) => x.id == 1), isFalse);
      // Still reported as the console, with the old-mem group visible.
      final (_, usersBody) = await call('GET', '/api/users');
      final users = ((usersBody as Map<String, dynamic>)['users'] as List)
          .cast<Map<String, dynamic>>();
      final root = users.firstWhere((u) => u['id'] == 1);
      expect((root['groups'] as List).cast<String>(), ['console', 'old']);

      // They can promote themselves back to an active member.
      await call('POST', '/api/users/1/tier', body: {'tier': 'member'});
      expect(repo.activeUsers().any((x) => x.id == 1), isTrue);
    },
  );

}
