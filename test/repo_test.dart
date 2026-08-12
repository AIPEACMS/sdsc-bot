import 'dart:io';

import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';

void main() {
  late Directory tmp;
  late Database db;
  late Repo repo;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sdsc_test_');
    db = Database.open(Config(
      botToken: 'test',
      dbPath: '${tmp.path}/test.db',
      consoleId: 1,
      groupAContact: 'TBD',
      groupBContact: 'TBD',
      ocbcCapacity: 2,
      prCapacity: 20,
      slotTimes: {
        'am': ('09:00', '12:00'),
        'pm': ('13:00', '17:00'),
      },
      promptHour: 8,
      reminderHour: 18,
      deadlineHour: 18,
      allocationHour: 9,
      bailHour: 12,
      timezoneOffsetHours: 8,
    ));
    repo = Repo(db);
  });

  tearDown(() {
    db.close();
    tmp.deleteSync(recursive: true);
  });

  User addUser(int id, {Experience exp = Experience.newbie, String group = 'A'}) {
    final u = User(
      id: id,
      name: 'Member $id',
      experience: exp,
      group: group,
      ocbcStreak: 0,
    );
    repo.upsertUser(u);
    return repo.findUser(id)!;
  }

  test('rolling window timeline computed from the current week', () {
    // 2026-08-10 is the Monday of ISO week 33.
    final now = DateTime(2026, 8, 10);
    final w = RollingWindow.forDate(now);

    expect(w.sat0, DateTime(2026, 8, 15)); // weekend 0 = this week's Saturday
    expect(w.sat1, DateTime(2026, 8, 22)); // weekend 1 = next week's Saturday
    // Prompt Mon 08:00, reminder Thu 18:00, deadline0 Fri 18:00 (this week),
    // deadline1 Fri 18:00 (next week).
    expect(w.promptDay, DateTime(2026, 8, 10, 8));
    expect(w.reminderDay, DateTime(2026, 8, 13, 18));
    expect(w.deadline0, DateTime(2026, 8, 14, 18));
    expect(w.deadline1, DateTime(2026, 8, 21, 18));
    expect(w.deadline0.weekday, DateTime.friday);
    expect(w.deadline0.isBefore(w.sat0), true);
  });

  test('a weekend locks at its Friday deadline', () {
    final w = RollingWindow.forDate(DateTime(2026, 8, 10));
    expect(w.locked(w.sat0, DateTime(2026, 8, 13, 12)), false);
    expect(w.locked(w.sat0, DateTime(2026, 8, 14, 18)), true);
    expect(w.locked(w.sat0, DateTime(2026, 8, 15, 9)), true);
    expect(w.locked(w.sat1, DateTime(2026, 8, 14, 18)), false); // next week open
  });

  test('sessions are created once and idempotently per weekend', () {
    final sat = DateTime(2026, 8, 15);
    repo.ensureSessionsForWeekend(
      sat,
      {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
      tzOffsetHours: 8,
    );
    expect(repo.sessionsForWeekend(sat).length, 8); // 2 days x 2 slots x 2 locations

    repo.ensureSessionsForWeekend(
      sat,
      {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
      tzOffsetHours: 8,
    );
    expect(repo.sessionsForWeekend(sat).length, 8);
  });

  test('availability, allocation and streak round-trip', () {
    addUser(1, exp: Experience.experienced);
    addUser(2, exp: Experience.experienced);
    addUser(3);

    final sat = DateTime(2026, 8, 15);
    for (final id in [1, 2, 3]) {
      repo.setAvailability(Availability(
        weekendStart: sat,
        userId: id,
        bundleStart: sat,
        slots: {
          const Slot(0, 'sat', 'am', 'ocbc'),
          const Slot(0, 'sat', 'am', 'pasirRis'),
        },
        available: true,
        updatedAt: DateTime(2026, 8, 12),
      ));
    }

    repo.ensureSessionsForWeekend(
      sat,
      {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
      tzOffsetHours: 8,
    );
    final sessions = repo.sessionsForWeekend(sat);

    final result = Allocator(ocbcCapacity: 2, prCapacity: 20).run(
      sessions: sessions,
      availability: repo.availabilityForWeekend(sat),
      users: {
        for (final u in repo.allUsers()) u.id: u,
      },
    );
    repo.replaceAllocationsForWeekend(sat, result);

    final allocated = repo.allocationsForWeekend(sat);
    expect(allocated.length, 3);
    // Session ids must survive the join (not collide with user ids).
    final sessionIds = sessions.map((s) => s.id).toSet();
    expect(allocated.every((a) => sessionIds.contains(a.$2.id)), true);
    // User ids come from the users table.
    expect(allocated.map((a) => a.$1.id).toSet(), {1, 2, 3});

    // Both experienced should be on OCBC.
    final expOcbc = allocated
        .where((a) => a.$1.experience == Experience.experienced)
        .every((a) => a.$2.location == Location.ocbc);
    expect(expOcbc, true);

    expect(repo.weekendAllocated(sat), false);
    repo.markWeekendAllocated(sat);
    expect(repo.weekendAllocated(sat), true);
  });

  test('reminder targets exclude respondents and the quiet', () {
    addUser(1);
    addUser(2);
    addUser(3);
    final sat = DateTime(2026, 8, 15);
    // User 2 answered the current bundle; user 3 answered last week's bundle
    // (quiet — not bothered for 2 weeks).
    repo.setAvailability(Availability(
      weekendStart: sat,
      userId: 2,
      bundleStart: sat,
      slots: {const Slot(0, 'sat', 'am', 'ocbc')},
      available: true,
      updatedAt: DateTime(2026, 8, 11),
    ));
    repo.setAvailability(Availability(
      weekendStart: sat.subtract(const Duration(days: 7)),
      userId: 3,
      bundleStart: sat.subtract(const Duration(days: 7)),
      slots: {const Slot(0, 'sat', 'am', 'ocbc')},
      available: true,
      updatedAt: DateTime(2026, 8, 4),
    ));
    final pending = repo.reminderTargets(sat);
    expect(pending.map((u) => u.id), [1]);
    expect(repo.isQuiet(3, sat), true);
  });

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
    repo.ensureSessionsForWeekend(
      sat,
      {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
      tzOffsetHours: 8,
    );
    final sessions = repo.sessionsForWeekend(sat);
    final ocbc = sessions.firstWhere((s) => s.location == Location.ocbc);
    final pr = sessions.firstWhere((s) => s.location == Location.pasirRis);
    repo.setAttendanceState(1, ocbc.id, attended: true);
    repo.setAttendanceState(1, ocbc.id, attended: true); // same session upserts
    repo.setAttendanceState(1, pr.id, attended: true);
    repo.setAttendanceState(2, ocbc.id, attended: true);
    repo.setAttendanceState(2, pr.id, attended: false); // negative: not counted
    repo.clearAttendance(2, ocbc.id); // recoverable

    final stats = repo.attendanceStats(1);
    expect(stats.total, 2);
    expect(stats.ocbc, 1);
    expect(stats.pasirRis, 1);
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

  test('updateAdmin toggles the admin flag', () {
    addUser(7);
    expect(repo.findUser(7)!.isAdmin, false);
    repo.updateAdmin(7, true);
    expect(repo.findUser(7)!.isAdmin, true);
    repo.updateAdmin(7, false);
    expect(repo.findUser(7)!.isAdmin, false);
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

    final names = repo.activeUsers().map((u) => u.id).toSet();
    expect(names, {1, 2});
  });

  test('hold state persists across calls', () {
    expect(repo.isHeld(), false);
    repo.setHeld(true);
    expect(repo.isHeld(), true);
    repo.setHeld(false);
    expect(repo.isHeld(), false);
  });

  test('reminder targets exclude check and old users', () {
    addUser(1);
    addUser(2);
    repo.setTier(2, 'check');
    addUser(3);
    repo.setTier(3, 'old');
    final sat = DateTime(2026, 8, 15);
    final pending = repo.reminderTargets(sat);
    expect(pending.map((u) => u.id), [1]);
  });

  test('message log dedupes per user, kind and day', () {
    addUser(1);
    addUser(2);
    final day = DateTime(2026, 8, 10);
    expect(repo.messageSentOnDay(1, 'prompt', day), false);
    repo.markMessageSent(1, 'prompt', day);
    expect(repo.messageSentOnDay(1, 'prompt', day), true);
    // Different kind or different day is not deduped.
    expect(repo.messageSentOnDay(1, 'reminder', day), false);
    expect(repo.messageSentOnDay(1, 'prompt', day.add(const Duration(days: 1))),
        false);
    // Different user is not deduped.
    expect(repo.messageSentOnDay(2, 'prompt', day), false);
  });
}
