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
      adminIds: {1},
      dbPath: '${tmp.path}/test.db',
      groupAContact: 'TBD',
      groupBContact: 'TBD @tbd',
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

  test('cycle timeline computed from an even prompt week', () {
    // 2026-08-03 is the Monday of ISO week 32 (even) — the prompt week of the
    // cycle whose first session weekend is week 33 (odd).
    final now = DateTime(2026, 8, 3);
    final cycle = repo.ensureCurrentCycle(now);

    expect(cycle.blockWeek, 33);
    expect(cycle.blockWeek.isOdd, true);
    expect(cycle.promptDay, DateTime(2026, 8, 3));
    expect(cycle.deadline, DateTime(2026, 8, 7));
    expect(cycle.allocationDay, DateTime(2026, 8, 12));
    expect(cycle.deadline.weekday, DateTime.friday);
    expect(cycle.allocationDay.weekday, DateTime.wednesday);
    // deadline (Friday of blockWeek-1) is before allocation (Wednesday of
    // blockWeek).
    expect(cycle.deadline.isBefore(cycle.allocationDay), true);
  });

  test('deadline closes the cycle automatically', () {
    final now = DateTime(2026, 8, 3); // Monday of an even week
    final cycle = repo.ensureCurrentCycle(now);
    expect(cycle.status, CycleStatus.open);

    final afterDeadline = cycle.deadline.add(const Duration(days: 1));
    final closed = repo.ensureCurrentCycle(afterDeadline);
    expect(closed.status, CycleStatus.closed);
  });

  test('sessions are created once and idempotently', () {
    final now = DateTime(2026, 8, 10);
    final cycle = repo.ensureCurrentCycle(now);
    repo.ensureSessionsForCycle(
      cycle,
      {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
      tzOffsetHours: 8,
    );
    final sessions = repo.sessionsForCycle(cycle.id);
    expect(sessions.length, 16); // 2 weekends x 2 days x 2 slots x 2 locations

    repo.ensureSessionsForCycle(
      cycle,
      {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
      tzOffsetHours: 8,
    );
    expect(repo.sessionsForCycle(cycle.id).length, 16);
  });

  test('availability, allocation and streak round-trip', () {
    addUser(1, exp: Experience.experienced);
    addUser(2, exp: Experience.experienced);
    addUser(3);

    final now = DateTime(2026, 8, 10);
    final cycle = repo.ensureCurrentCycle(now);
    final pastDeadline = cycle.deadline.add(const Duration(days: 1));
    repo.ensureCurrentCycle(pastDeadline); // closes the cycle

    for (final id in [1, 2, 3]) {
      repo.setAvailability(Availability(
        cycleId: cycle.id,
        userId: id,
        slots: {const Slot(0, 'sat', 'am')},
        available: true,
        updatedAt: DateTime(2026, 8, 12),
      ));
    }

    repo.ensureSessionsForCycle(
      cycle,
      {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
      tzOffsetHours: 8,
    );
    final sessions = repo.sessionsForCycle(cycle.id);

    final result = Allocator(ocbcCapacity: 2, prCapacity: 20).run(
      sessions: sessions,
      availability: repo.allAvailability(cycle.id),
      users: {
        for (final u in repo.allUsers()) u.id: u,
      },
    );
    repo.replaceAllocations(cycle.id, result);

    final allocated = repo.allocationsForCycle(cycle.id);
    expect(allocated.length, 3);
    expect(allocated.every((a) => a.$2.cycleId == cycle.id), true);
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

    repo.markAllocated(cycle.id);
    expect(repo.cycleById(cycle.id)!.status, CycleStatus.allocated);
  });

  test('nonResponders only counts users without availability', () {
    addUser(1);
    addUser(2);
    final cycle = repo.ensureCurrentCycle(DateTime(2026, 8, 10));
    repo.setAvailability(Availability(
      cycleId: cycle.id,
      userId: 2,
        slots: {Slot(0, 'sat', 'am')},
      available: true,
      updatedAt: DateTime(2026, 8, 11),
    ));
    final pending = repo.nonResponders(cycle.id);
    expect(pending.map((u) => u.id), [1]);
  });

  test('holiday lookup by week', () {
    repo.addHoliday(DateTime(2026, 8, 3), HolidayKind.winter);
    final holiday = repo.holidayOn(DateTime(2026, 8, 5));
    expect(holiday, isNotNull);
    expect(holiday!.kind, HolidayKind.winter);
    expect(repo.holidayOn(DateTime(2026, 8, 10)), isNull);
  });
}
