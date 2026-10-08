import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'support/repo_harness.dart';

void main() {
  setUp(setUpRepo);
  tearDown(tearDownRepo);
  test('console identity does not replace the stored member role', () {
    User user(String tier, {bool admin = false, bool globalAdmin = false}) =>
        User(
          id: 99,
          name: '@user99',
          experience: Experience.newbie,
          group: '',
          isAdmin: admin,
          isGlobalAdmin: globalAdmin,
          memberTier: tier,
        );

    expect(
      MemberTier.of(user(MemberTier.admin, admin: true), isConsole: true),
      MemberTier.admin,
    );
    expect(
      MemberTier.of(user(MemberTier.member), isConsole: true),
      MemberTier.member,
    );
    expect(
      MemberTier.of(user(MemberTier.check), isConsole: true),
      MemberTier.check,
    );
    expect(
      MemberTier.of(user(MemberTier.outMember), isConsole: true),
      MemberTier.outMember,
    );
    expect(
      MemberTier.of(user(MemberTier.old), isConsole: true),
      MemberTier.old,
    );
    expect(
      MemberTier.of(
        user(MemberTier.member, globalAdmin: true),
        isConsole: true,
      ),
      MemberTier.globalAdmin,
    );
  });

  test('only check and old tiers are inactive', () {
    expect(MemberTier.isActive(MemberTier.admin), isTrue);
    expect(MemberTier.isActive(MemberTier.globalAdmin), isTrue);
    expect(MemberTier.isActive(MemberTier.member), isTrue);
    expect(MemberTier.isActive(MemberTier.outMember), isTrue);
    expect(MemberTier.isActive(MemberTier.check), isFalse);
    expect(MemberTier.isActive(MemberTier.old), isFalse);
  });

  test('out-members cannot become global admins', () {
    addUser(19);
    expect(repo.setTier(19, MemberTier.outMember), isTrue);
    expect(repo.appointGlobalAdmin(19), GlobalAdminResult.outMember);
    expect(repo.findUser(19)!.isGlobalAdmin, isFalse);
  });

  test('updateAdmin toggles the admin flag', () {
    addUser(7);
    expect(repo.findUser(7)!.isAdmin, false);
    repo.updateAdmin(7, true);
    expect(repo.findUser(7)!.isAdmin, true);
    repo.updateAdmin(7, false);
    expect(repo.findUser(7)!.isAdmin, false);
  });

  test('out-members cannot be promoted to admin', () {
    addUser(8);
    expect(repo.setOutMember(8), isTrue);
    expect(repo.updateAdmin(8, true), isFalse);
    expect(repo.setTier(8, MemberTier.admin), isFalse);
    expect(repo.findUser(8)!.isAdmin, isFalse);
    expect(repo.findUser(8)!.memberTier, MemberTier.outMember);
  });

  test('v2 startup migration converts the existing console admin', () {
    repo.upsertUser(
      User(
        id: 1,
        name: '@console',
        experience: Experience.experienced,
        group: '7',
        isAdmin: true,
      ),
    );
    repo.raw.execute(
      "DELETE FROM settings WHERE key = 'global_admin_migration_v2'",
    );
    db.close();
    db = Database.open(
      Config(
        botToken: 'test',
        dbPath: '${tmp.path}/test.db',
        consoleId: 1,
        groupAContact: 'TBD',
        groupBContact: 'TBD',
        ocbcCapacity: 2,
        prCapacity: 20,
        slotTimes: {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
        promptHour: 18,
        reminderHour: 18,
        deadlineHour: 18,
        allocationHour: 9,
        bailHour: 12,
        timezoneOffsetHours: 8,
      ),
    );
    repo = Repo(db);
    final console = repo.findUser(1)!;
    expect(console.isGlobalAdmin, isTrue);
    expect(console.isAdmin, isFalse);
    expect(console.group, '7');
  });

  test('global admin is singleton and mutually exclusive with admin', () {
    addUser(1, group: '3');
    addUser(2, group: '4');
    repo.upsertUser(
      User(
        id: 1,
        name: 'Member 1',
        experience: Experience.newbie,
        group: '3',
        isAdmin: true,
      ),
    );
    expect(repo.appointGlobalAdmin(1), GlobalAdminResult.success);
    expect(repo.findUser(1)!.isAdmin, isFalse);
    expect(repo.findUser(1)!.isGlobalAdmin, isTrue);
    expect(repo.findUser(1)!.group, '3');
    expect(repo.appointGlobalAdmin(2), GlobalAdminResult.alreadyExists);
    expect(
      () => repo.raw.execute(
        'UPDATE users SET is_admin = 1 WHERE id = 1',
      ),
      throwsException,
    );
  });

  test('global-admin removal returns a member and dissolves the group', () {
    addUser(1, group: '3');
    addUser(2, group: '3');
    repo.upsertUser(
      User(
        id: 1,
        name: 'Member 1',
        experience: Experience.newbie,
        group: '3',
        isAdmin: true,
      ),
    );
    expect(repo.appointGlobalAdmin(1), GlobalAdminResult.success);
    expect(repo.removeGlobalAdmin(1), isTrue);
    final removed = repo.findUser(1)!;
    expect(removed.isGlobalAdmin, isFalse);
    expect(removed.isAdmin, isFalse);
    expect(removed.memberTier, MemberTier.member);
    expect(removed.group, isEmpty);
    expect(repo.findUser(2)!.group, isEmpty);
    expect(repo.globalAdmin(), isNull);
  });

  test('ordinary upsert does not clear global-admin state', () {
    addUser(1);
    expect(repo.appointGlobalAdmin(1), GlobalAdminResult.success);
    repo.upsertUser(
      User(
        id: 1,
        name: 'Updated',
        experience: Experience.experienced,
        group: '',
      ),
    );
    expect(repo.findUser(1)!.isGlobalAdmin, isTrue);
  });

  test('setTier promotes to admin and demotes elsewhere', () {
    addUser(7);
    expect(repo.findUser(7)!.memberTier, 'member');
    repo.setTier(7, 'admin');
    final admin = repo.findUser(7)!;
    expect(admin.isAdmin, true);
    expect(admin.memberTier, 'member'); // admin is derived, not stored
    repo.setTier(7, 'check');
    final check = repo.findUser(7)!;
    expect(check.isAdmin, false);
    expect(check.memberTier, 'check');
    expect(check.memberTier, 'check'); // stored tier survives round-trip
    repo.setTier(7, 'old');
    final old = repo.findUser(7)!;
    expect(old.isAdmin, false);
    expect(old.memberTier, 'old');
    repo.setTier(7, 'member');
    expect(repo.findUser(7)!.memberTier, 'member');
  });

  test('activeUsers excludes check and old but keeps admins', () {
    addUser(1);
    addUser(2);
    repo.updateAdmin(2, true); // admin
    addUser(3);
    repo.setTier(3, 'check');
    addUser(4);
    repo.setTier(4, 'old');
    addUser(5);
    repo.setTier(5, 'out-member');

    final names = repo.activeUsers().map((u) => u.id).toSet();
    expect(names, {1, 2, 5});
  });
}
