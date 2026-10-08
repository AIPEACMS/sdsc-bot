import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'support/repo_harness.dart';
import 'test_helpers.dart';

void main() {
  setUp(setUpRepo);
  tearDown(tearDownRepo);
  test('rolling window timeline computed from the current week', () {
    // 2026-08-10 is the Monday of ISO week 33.
    final now = DateTime(2026, 8, 10);
    final w = RollingWindow.forDate(now);

    expect(w.sat0, DateTime(2026, 8, 15)); // weekend 0 = this week's Saturday
    expect(w.sat1, DateTime(2026, 8, 22)); // weekend 1 = next week's Saturday
    // Prompt Mon 18:00, reminder Thu 18:00, deadline0 Fri 18:00 (this week),
    // deadline1 Fri 18:00 (next week).
    expect(w.promptDay, DateTime(2026, 8, 10, 18));
    expect(w.reminderDay, DateTime(2026, 8, 13, 18));
    expect(w.deadline0, DateTime(2026, 8, 14, 18));
    expect(w.deadline1, DateTime(2026, 8, 21, 18));
    expect(w.deadline0.weekday, DateTime.friday);
    expect(w.deadline0.isBefore(w.sat0), true);
  });

  test('active outreach settings default on and persist independently', () {
    expect(repo.activeOutreach(), {
      for (final route in Repo.activeOutreachRouteKeys) route: true,
    });

    repo.setActiveOutreach('prompt', false);
    expect(repo.activeOutreachEnabled('prompt'), isFalse);
    expect(repo.activeOutreachEnabled('reminder'), isTrue);

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
    expect(repo.activeOutreachEnabled('prompt'), isFalse);
    expect(repo.activeOutreachEnabled('reminder'), isTrue);
    expect(() => repo.setActiveOutreach('unknown', true), throwsArgumentError);
  });

  test('repo write rejects weekend milestones and bad weekly ordering', () {
    const weekend = ScheduleTimes(
      prompt: ScheduleEvent(weekday: 'sat', time: LocalWallClock(9, 0)),
      reminder: ScheduleEvent(weekday: 'thu', time: LocalWallClock(10, 0)),
      lock: ScheduleEvent(weekday: 'fri', time: LocalWallClock(18, 0)),
      checker: ScheduleEvent(weekday: 'fri', time: LocalWallClock(19, 0)),
    );
    expect(() => repo.writeSchedule(weekend), throwsArgumentError);

    const outOfOrder = ScheduleTimes(
      prompt: ScheduleEvent(weekday: 'wed', time: LocalWallClock(9, 0)),
      reminder: ScheduleEvent(weekday: 'tue', time: LocalWallClock(10, 0)),
      lock: ScheduleEvent(weekday: 'fri', time: LocalWallClock(18, 0)),
      checker: ScheduleEvent(weekday: 'fri', time: LocalWallClock(19, 0)),
    );
    expect(() => repo.writeSchedule(outOfOrder), throwsArgumentError);
  });

  test('a weekend locks at its Friday deadline', () {
    final w = RollingWindow.forDate(DateTime(2026, 8, 10));
    expect(w.locked(w.sat0, DateTime(2026, 8, 13, 12)), false);
    expect(w.locked(w.sat0, DateTime(2026, 8, 14, 18)), true);
    expect(w.locked(w.sat0, DateTime(2026, 8, 15, 9)), true);
    expect(
      w.locked(w.sat1, DateTime(2026, 8, 14, 18)),
      false,
    ); // next week open
  });

  test('sessions are created once and idempotently per weekend', () {
    final sat = DateTime(2026, 8, 15);
    repo.ensureSessionsForWeekend(sat, defaultTemplate(), tzOffsetHours: 8);
    expect(
      repo.sessionsForWeekend(sat).length,
      4,
    ); // Saturday: 2 slots x 2 locations

    repo.ensureSessionsForWeekend(sat, defaultTemplate(), tzOffsetHours: 8);
    expect(repo.sessionsForWeekend(sat).length, 4);
  });

  test('availability, allocation and streak round-trip', () {
    addUser(1, exp: Experience.experienced);
    addUser(2, exp: Experience.experienced);
    addUser(3);

    final sat = DateTime(2026, 8, 15);
    for (final id in [1, 2, 3]) {
      repo.setAvailability(
        Availability(
          weekendStart: sat,
          userId: id,
          bundleStart: sat,
          slots: {
            const Slot(0, 'sat', 'am', 'ocbc'),
            const Slot(0, 'sat', 'am', 'pasirRis'),
          },
          wantSlots: {const Slot(0, 'sat', 'pm', 'ocbc')},
          available: true,
          updatedAt: DateTime(2026, 8, 12),
        ),
      );
    }

    // want_slots round-trips through the store.
    final stored = repo.getAvailability(sat, 1)!;
    expect(stored.wantSlots, {const Slot(0, 'sat', 'pm', 'ocbc')});
    expect(stored.slots, {
      const Slot(0, 'sat', 'am', 'ocbc'),
      const Slot(0, 'sat', 'am', 'pasirRis'),
    });

    repo.ensureSessionsForWeekend(sat, defaultTemplate(), tzOffsetHours: 8);
    final sessions = repo.sessionsForWeekend(sat);

    final result = const Allocator().run(
      sessions: sessions,
      availability: repo.availabilityForWeekend(sat),
    );
    repo.replaceAllocationsForWeekend(sat, result);

    final allocated = repo.allocationsForWeekend(sat);
    // Each member gets their want (pm OCBC) plus one available (am OCBC).
    expect(allocated.length, 6);
    // Session ids must survive the join (not collide with user ids).
    final sessionIds = sessions.map((s) => s.id).toSet();
    expect(allocated.every((a) => sessionIds.contains(a.$2.id)), true);
    // User ids come from the users table.
    expect(allocated.map((a) => a.$1.id).toSet(), {1, 2, 3});

    // Both experienced should be on OCBC.
    final expOcbc = allocated
        .where((a) => a.$1.experience == Experience.experienced)
        .every((a) => a.$2.location == Locations.ocbc);
    expect(expOcbc, true);

    expect(repo.weekendAllocated(sat), false);
    repo.markWeekendAllocated(sat);
    expect(repo.weekendAllocated(sat), true);
  });

  test('allocation round-trip preserves session capacity metadata', () {
    final sat = DateTime(2026, 8, 15);
    addUser(1);
    repo.ensureSessionsForWeekend(sat, defaultTemplate(), tzOffsetHours: 8);
    final session = repo.sessionsForWeekend(sat).first;
    repo.raw.execute(
      'UPDATE sessions SET max_people = ?, capacity_group = ? WHERE id = ?',
      [4, 'capacity-1', session.id],
    );
    repo.replaceAllocationsForWeekend(sat, [(1, session.id)]);

    final loaded = repo.allocationsForWeekend(sat).single.$2;
    expect(loaded.maxPeople, 4);
    expect(loaded.capacityGroup, 'capacity-1');
  });

  test('reminder targets exclude respondents and the quiet', () {
    addUser(1);
    addUser(2);
    addUser(3);
    final sat = DateTime(2026, 8, 15);
    // User 2 answered the current bundle; user 3 answered last week's bundle
    // (quiet — not bothered for 2 weeks).
    repo.setAvailability(
      Availability(
        weekendStart: sat,
        userId: 2,
        bundleStart: sat,
        slots: {const Slot(0, 'sat', 'am', 'ocbc')},
        available: true,
        updatedAt: DateTime(2026, 8, 11),
      ),
    );
    repo.setAvailability(
      Availability(
        weekendStart: sat.subtract(const Duration(days: 7)),
        userId: 3,
        bundleStart: sat.subtract(const Duration(days: 7)),
        slots: {const Slot(0, 'sat', 'am', 'ocbc')},
        available: true,
        updatedAt: DateTime(2026, 8, 4),
      ),
    );
    final pending = repo.reminderTargets(sat);
    expect(pending.map((u) => u.id), [1]);
    expect(repo.isQuiet(3, sat), true);
  });

  test('prompt targets exclude current responders and mark previous as quiet', () {
    addUser(1);
    addUser(2);
    addUser(3);
    final sat = DateTime(2026, 8, 15);
    repo.setAvailability(
      Availability(
        weekendStart: sat,
        userId: 2,
        bundleStart: sat,
        slots: const {},
        available: false,
        updatedAt: DateTime(2026, 8, 11),
      ),
    );
    repo.setAvailability(
      Availability(
        weekendStart: sat.subtract(const Duration(days: 7)),
        userId: 3,
        bundleStart: sat.subtract(const Duration(days: 7)),
        slots: const {},
        available: false,
        updatedAt: DateTime(2026, 8, 4),
      ),
    );

    final targets = repo.promptTargets(sat);
    expect(targets.map((user) => user.id), [1, 3]);
    expect(repo.isQuiet(3, sat), isTrue);
    expect(repo.reminderTargets(sat).map((user) => user.id), [1]);
  });
}
