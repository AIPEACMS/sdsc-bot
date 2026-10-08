import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'support/repo_harness.dart';
import 'test_helpers.dart';

void main() {
  setUp(setUpRepo);
  tearDown(tearDownRepo);
  test('holiday lookup by week', () {
    repo.addHoliday(DateTime(2026, 8, 3), HolidayKind.winter);
    final holiday = repo.holidayOn(DateTime(2026, 8, 5));
    expect(holiday, isNotNull);
    expect(holiday!.kind, HolidayKind.winter);
    expect(repo.holidayOn(DateTime(2026, 8, 10)), isNull);
  });

  test('holiday opt-out is per user and per week', () {
    addUser(7);
    addUser(8);
    repo.setHolidayOptout(7, DateTime(2026, 8, 3));
    expect(repo.hasHolidayOptout(7, DateTime(2026, 8, 3)), true);
    expect(repo.hasHolidayOptout(7, DateTime(2026, 8, 10)), false);
    expect(repo.hasHolidayOptout(8, DateTime(2026, 8, 3)), false);
  });

  test('attendance stats split by location, negative marks not counted', () {
    addUser(1);
    addUser(2);
    final sat = DateTime(2026, 8, 15);
    repo.ensureSessionsForWeekend(sat, defaultTemplate(), tzOffsetHours: 8);
    final sessions = repo.sessionsForWeekend(sat);
    final ocbc = sessions.firstWhere((s) => s.location == Locations.ocbc);
    final pr = sessions.firstWhere((s) => s.location == Locations.pasirRis);
    repo.setAttendanceState(1, ocbc.id, attended: true);
    repo.setAttendanceState(1, ocbc.id, attended: true); // same session upserts
    repo.setAttendanceState(1, pr.id, attended: true);
    repo.setAttendanceState(2, ocbc.id, attended: true);
    repo.setAttendanceState(2, pr.id, attended: false); // negative: not counted
    repo.clearAttendance(2, ocbc.id); // recoverable

    final stats = repo.attendanceStats(1);
    expect(stats.total, 2);
    expect(stats.byLocation['ocbc'] ?? 0, 1);
    expect(stats.byLocation['pasirRis'] ?? 0, 1);
    expect(repo.attendanceStats(2).total, 0);
    final prMarks = repo.attendanceForSession(pr.id);
    expect(prMarks.firstWhere((a) => a.userId == 2).attended, false);
  });

  test('seen users resolve handles to ids', () {
    repo.upsertSeenUser(111, 'alice');
    expect(repo.userIdByUsername('@Alice'), 111);
    expect(repo.userIdByUsername('alice'), 111);
    expect(repo.userIdByUsername('bob'), isNull);
  });

  test('unregisteredSeen lists seen users not yet registered', () {
    repo.upsertSeenUser(111, 'alice');
    repo.upsertSeenUser(222, 'bob');
    addUser(222); // bob is now registered
    final seen = repo.unregisteredSeen();
    expect(seen.map((u) => u.id), [111]);
    expect(seen.single.name, '@alice');
    expect(repo.seenUsername(111), 'alice');
    expect(repo.seenUsername(222), 'bob');
    expect(repo.seenUsername(333), isNull);
  });

  test('pending users queue by handle before first contact', () {
    expect(repo.isPendingUser('bob'), false);
    repo.addPendingUser('@Bob', isAdmin: false);
    expect(repo.isPendingUser('bob'), true);
    expect(repo.pendingIsAdmin('bob'), false);
    repo.removePendingUser('Bob');
    expect(repo.isPendingUser('bob'), false);
  });

  test('pending admin flag survives upsert and wins over non-admin', () {
    repo.addPendingUser('carol', isAdmin: false);
    repo.addPendingUser('carol', isAdmin: true);
    expect(repo.pendingIsAdmin('carol'), true);
  });

  test('pending tier round-trips and defaults to member', () {
    expect(repo.pendingTier('dave'), MemberTier.member); // never queued
    repo.addPendingUser('dave', isAdmin: false);
    expect(repo.pendingTier('dave'), MemberTier.member);
    repo.addPendingUser('dave', isAdmin: false, tier: MemberTier.check);
    expect(repo.pendingTier('dave'), MemberTier.check);
  });

  test('new out-members default to never notifications', () {
    final user = User(
      id: 8,
      name: '@out',
      experience: Experience.newbie,
      group: '',
      memberTier: MemberTier.outMember,
    );
    expect(user.notificationPreference, NotificationPreference.never);

    repo.upsertUser(user);
    expect(repo.setMember(8), isTrue);
    expect(repo.setOutMember(8), isTrue);
    expect(repo.findUser(8)!.notificationPreference,
        NotificationPreference.never);

    repo.addPendingUser('queued-out', isAdmin: false,
        tier: MemberTier.outMember);
    expect(repo.pendingRole('queued-out')!.notificationPreference,
        NotificationPreference.never);
  });

  test('replacing a pending role overwrites both role components', () {
    expect(
      repo.addPendingUser('dave', isAdmin: true, tier: MemberTier.check),
      isNull,
    );
    final previous = repo.addPendingUser(
      'dave',
      isAdmin: false,
      tier: MemberTier.outMember,
    );
    expect(previous?.isAdmin, isTrue);
    expect(previous?.tier, MemberTier.check);
    expect(repo.pendingIsAdmin('dave'), isFalse);
    expect(repo.pendingTier('dave'), MemberTier.outMember);
    expect(
      repo.replacePendingUser('dave', isAdmin: true)?.tier,
      MemberTier.outMember,
    );
    expect(repo.pendingRole('dave')?.isAdmin, isTrue);
  });

  test('pending notification preference survives role replacement', () {
    repo.addPendingUser(
      'erin',
      isAdmin: false,
      tier: MemberTier.outMember,
      notificationPreference: NotificationPreference.never,
    );
    expect(
      repo.pendingRole('erin')?.notificationPreference,
      NotificationPreference.never,
    );
    repo.replacePendingUser(
      'erin',
      isAdmin: false,
      tier: MemberTier.outMember,
      notificationPreference: NotificationPreference.everyOther,
    );
    expect(
      repo.pendingRole('erin')?.notificationPreference,
      NotificationPreference.everyOther,
    );
  });

  test('registered handle lookup falls back to users.name', () {
    repo.upsertUser(
      const User(
        id: 31,
        name: '@former',
        experience: Experience.newbie,
        group: '',
        memberTier: MemberTier.old,
      ),
    );
    repo.addPendingUser('former', isAdmin: false);
    expect(repo.findUserByHandle('@former')?.id, 31);
    expect(repo.setMember(31), isTrue);
    expect(repo.findUser(31)!.memberTier, MemberTier.member);
    expect(repo.setOutMember(31), isTrue);
    expect(repo.findUser(31)!.memberTier, MemberTier.outMember);
    expect(repo.isPendingUser('former'), true);
  });

  test('user removal validates the complete batch before mutating', () {
    repo.upsertSeenUser(10, 'alice');
    repo.upsertSeenUser(11, 'checker');
    repo.upsertUser(
      User(id: 10, name: '@alice', experience: Experience.newbie, group: '4'),
    );
    repo.upsertUser(
      User(
        id: 11,
        name: '@checker',
        experience: Experience.newbie,
        group: '',
        memberTier: MemberTier.check,
      ),
    );
    repo.addPendingUser('never_started', isAdmin: false);

    final invalid = repo.removeUsers(['@alice', '@missing']);
    expect(invalid.failure, UserRemovalFailure.notFound);
    expect(repo.findUser(10)!.memberTier, MemberTier.member);
    expect(repo.findUser(10)!.group, '4');
    expect(repo.isPendingUser('never_started'), true);

    final removed = repo.removeUsers(['@alice', '@checker', '@never_started']);
    expect(removed.succeeded, true);
    expect(removed.removedHandles, ['alice', 'checker', 'never_started']);
    expect(repo.findUser(10)!.memberTier, MemberTier.old);
    expect(repo.findUser(10)!.group, isEmpty);
    expect(repo.findUser(11)!.memberTier, MemberTier.old);
    expect(repo.isPendingUser('never_started'), false);
  });

  test('user removal protects registered and pending admins', () {
    repo.upsertSeenUser(20, 'admin');
    repo.upsertUser(
      User(
        id: 20,
        name: '@admin',
        experience: Experience.newbie,
        group: '1',
        isAdmin: true,
      ),
    );
    final registered = repo.removeUsers(['@admin']);
    expect(registered.failure, UserRemovalFailure.protectedAdmin);
    expect(repo.findUser(20)!.isAdmin, true);

    repo.addPendingUser('pending_admin', isAdmin: true);
    final pending = repo.removeUsers(['@pending_admin']);
    expect(pending.failure, UserRemovalFailure.protectedAdmin);
    expect(repo.pendingIsAdmin('pending_admin'), true);
    expect(repo.demotePendingAdmin('@pending_admin'), true);
    expect(repo.pendingIsAdmin('pending_admin'), false);
    expect(repo.removeUsers(['@pending_admin']).succeeded, true);
  });

  test('old users are not removable and can be restored by tier', () {
    repo.upsertUser(
      const User(
        id: 30,
        name: '@former',
        experience: Experience.newbie,
        group: '',
        memberTier: MemberTier.old,
      ),
    );
    repo.addPendingUser('former', isAdmin: false);
    final result = repo.removeUsers(['@former']);
    expect(result.failure, UserRemovalFailure.notFound);
    expect(repo.isPendingUser('former'), true);
    expect(repo.setOutMember(30), isTrue);
    expect(repo.findUser(30)!.memberTier, MemberTier.outMember);
  });

  test('user role and notification fields round-trip through SQL', () {
    final registered = DateTime(2026, 8, 12, 10, 30);
    repo.upsertUser(
      User(
        id: 42,
        name: 'Member 42',
        experience: Experience.experienced,
        group: '9',
        isGlobalAdmin: true,
        ocbcStreak: 4,
        registeredAt: registered,
        fullName: 'Legacy Name',
        preferredName: 'Preferred',
        matricNo: 'M42',
        schoolEmail: 'm42@example.test',
        memberTier: MemberTier.outMember,
        notificationPreference: NotificationPreference.everyOther,
        lastPromptState: LastPromptState.responded,
      ),
    );

    final stored = repo.findUser(42)!;
    expect(stored.name, 'Member 42');
    expect(stored.experience, Experience.experienced);
    expect(stored.group, '9');
    expect(stored.isAdmin, isFalse);
    expect(stored.isGlobalAdmin, isTrue);
    expect(stored.ocbcStreak, 4);
    expect(stored.registeredAt, registered);
    expect(stored.storedFullName, 'Legacy Name');
    expect(stored.preferredName, 'Preferred');
    expect(stored.storedMatricNo, 'M42');
    expect(stored.storedSchoolEmail, 'm42@example.test');
    expect(stored.memberTier, MemberTier.outMember);
    expect(stored.notificationPreference, NotificationPreference.everyOther);
    expect(stored.lastPromptState, LastPromptState.responded);
  });

  test('member and out-member conversion preserve admin protections', () {
    addUser(1, group: '3');
    addUser(2, group: '3');
    expect(repo.setOutMember(1), isTrue);
    expect(repo.findUser(1)!.memberTier, MemberTier.outMember);
    expect(repo.findUser(1)!.group, isEmpty);
    expect(repo.findUser(1)!.notificationPreference,
        NotificationPreference.never);
    expect(repo.findUser(2)!.group, '3');
    expect(repo.setMember(1), isTrue);
    expect(repo.findUser(1)!.memberTier, MemberTier.member);

    expect(repo.appointGlobalAdmin(1), GlobalAdminResult.success);
    expect(repo.setOutMember(1), isFalse);
    expect(
      MemberTier.of(repo.findUser(1)!, isConsole: true),
      MemberTier.globalAdmin,
    );
    expect(
      repo.raw.select('SELECT member_tier FROM users WHERE id = 1').first[
          'member_tier'],
      MemberTier.member,
    );
  });
}
