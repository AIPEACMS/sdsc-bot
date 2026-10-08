
import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'support/admin_api_harness.dart';

void main() {
  setUp(setUpAdminApi);
  tearDown(tearDownAdminApi);
  // ------------------------------------------------------- group model

  test(
    'POST /api/assign-groups distributes ungrouped members evenly',
    () async {
      repo.upsertUser(
        User(
          id: 1,
          name: '@root',
          experience: Experience.experienced,
          group: '1',
          isAdmin: true,
        ),
      );
      repo.upsertUser(
        User(
          id: 11,
          name: '@lead2',
          experience: Experience.experienced,
          group: '2',
          isAdmin: true,
        ),
      );
      for (var i = 100; i < 105; i++) {
        repo.upsertUser(
          User(id: i, name: '@m$i', experience: Experience.newbie, group: ''),
        );
      }
      // check/old have no group but must NOT be assigned.
      repo.upsertUser(
        User(
          id: 200,
          name: '@checker',
          experience: Experience.newbie,
          group: '',
        ),
      );
      repo.setTier(200, 'check');
      repo.upsertUser(
        User(
          id: 201,
          name: '@former',
          experience: Experience.newbie,
          group: '',
        ),
      );
      repo.setTier(201, 'old');

      final (status, body) = await call('POST', '/api/assign-groups');
      expect(status, 200);
      expect((body as Map<String, dynamic>)['assigned'], 5);

      final counts = <String, int>{};
      for (var i = 100; i < 105; i++) {
        final g = repo.findUser(i)!.group;
        expect(g, isNotEmpty);
        counts[g] = (counts[g] ?? 0) + 1;
      }
      expect(counts.length, 2); // split across both leader groups
      expect(counts.values.every((c) => c >= 2 && c <= 3), isTrue);
      // check/old untouched, admins untouched.
      expect(repo.findUser(200)!.group, '');
      expect(repo.findUser(201)!.group, '');
      expect(repo.findUser(1)!.group, '1');
      expect(repo.findUser(11)!.group, '2');
    },
  );

  test('POST /api/users/{id}/group moves or ungroups a member, blocked for '
      'admins', () async {
    repo.upsertUser(
      User(
        id: 1,
        name: '@root',
        experience: Experience.experienced,
        group: '1',
        isAdmin: true,
      ),
    );
    repo.upsertUser(
      User(
        id: 11,
        name: '@lead2',
        experience: Experience.experienced,
        group: '2',
        isAdmin: true,
      ),
    );
    repo.upsertUser(
      User(id: 101, name: '@alice', experience: Experience.newbie, group: ''),
    );

    final (m, mBody) = await call(
      'POST',
      '/api/users/101/group',
      body: {'group': '2'},
    );
    expect(m, 200);
    expect((mBody as Map<String, dynamic>)['group'], '2');
    expect(repo.findUser(101)!.group, '2');

    final (r, _) = await call(
      'POST',
      '/api/users/101/group',
      body: {'group': ''},
    );
    expect(r, 200);
    expect(repo.findUser(101)!.group, '');

    // An admin cannot be moved or removed from their own group.
    final (a, aBody) = await call(
      'POST',
      '/api/users/11/group',
      body: {'group': ''},
    );
    expect(a, 400);
    expect((aBody as Map<String, dynamic>)['error'], contains('demote'));
    expect(repo.findUser(11)!.group, '2');

    // Unknown groups are rejected.
    final (u, _) = await call(
      'POST',
      '/api/users/101/group',
      body: {'group': '9'},
    );
    expect(u, 400);
  });

  test(
    'promotion assigns the lowest free group; demotion dissolves it',
    () async {
      repo.upsertUser(
        User(
          id: 1,
          name: '@root',
          experience: Experience.experienced,
          group: '1',
          isAdmin: true,
        ),
      );
      repo.upsertUser(
        User(
          id: 101,
          name: '@alice',
          experience: Experience.newbie,
          group: '1',
        ),
      );
      repo.upsertUser(
        User(id: 102, name: '@bob', experience: Experience.newbie, group: ''),
      );

      // Promote bob → lowest free group is 2 (1 is taken by root).
      await call('POST', '/api/users/102/tier', body: {'tier': 'admin'});
      expect(repo.findUser(102)!.isAdmin, true);
      expect(repo.findUser(102)!.group, '2');

      // Demote root (console, group 1) → group 1 dissolves: alice loses it too.
      await call('POST', '/api/users/1/admin', body: {'admin': false});
      expect(repo.findUser(1)!.isAdmin, false);
      expect(repo.findUser(1)!.group, '');
      expect(repo.findUser(101)!.group, '');

      // Promote alice → group 1 is free again (bob holds 2) → gap filled.
      await call('POST', '/api/users/101/admin', body: {'admin': true});
      expect(repo.findUser(101)!.group, '1');
      expect(repo.findUser(102)!.group, '2');
    },
  );

  test('POST /api/assign-groups keeps its response contract and repairs leaders',
      () async {
    repo.upsertUser(
      User(
        id: 1,
        name: '@leader-missing',
        experience: Experience.experienced,
        group: '',
        isAdmin: true,
      ),
    );
    repo.upsertUser(
      User(
        id: 2,
        name: '@leader-two',
        experience: Experience.experienced,
        group: '2',
        isAdmin: true,
      ),
    );
    repo.upsertUser(
      User(id: 3, name: '@member', experience: Experience.newbie, group: ''),
    );

    final (status, body) = await call('POST', '/api/assign-groups');
    final result = body as Map<String, dynamic>;
    expect(status, 200);
    expect(result, containsPair('ok', true));
    expect(result, containsPair('assigned', 1));
    expect(result, containsPair('groups', 2));
    expect(repo.findUser(1)!.group, '1');
    expect(repo.findUser(3)!.group, '1');
  });
}
