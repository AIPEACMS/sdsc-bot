import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';

const _am = Slot(0, 'sat', 'am', 'ocbc');
const _amPr = Slot(0, 'sat', 'am', 'pasirRis');

User _user(int id, Experience exp, {int streak = 0}) => User(
      id: id,
      name: 'u$id',
      experience: exp,
      group: 'A',
      ocbcStreak: streak,
    );

Availability _avail(int userId, Set<Slot> slots) => Availability(
      weekendStart: DateTime(2026, 8, 8),
      userId: userId,
      bundleStart: DateTime(2026, 8, 8),
      slots: slots,
      available: true,
      updatedAt: DateTime(2026, 8, 1),
    );

List<Session> _sessions() {
  Session s(String day, String slot, Location loc, int id) => Session(
        id: id,
        weekendStart: DateTime(2026, 8, 8),
        day: day,
        slot: slot,
        location: loc,
        start: DateTime(2026, 8, 8),
        end: DateTime(2026, 8, 8, 3),
      );
  // One weekend: Saturday am/pm, both locations. No Sunday sessions.
  return [
    s('sat', 'am', Location.ocbc, 1),
    s('sat', 'am', Location.pasirRis, 2),
    s('sat', 'pm', Location.ocbc, 3),
    s('sat', 'pm', Location.pasirRis, 4),
  ];
}

void main() {
  const allocator = Allocator(ocbcCapacity: 2, prCapacity: 20);

  Map<int, User> users(Iterable<User> u) => {for (final x in u) x.id: x};

  test('experienced go to OCBC, new go to Pasir Ris', () {
    final usersList = [
      _user(1, Experience.experienced),
      _user(2, Experience.experienced),
      _user(3, Experience.newbie),
    ];
    final result = allocator.run(
      sessions: _sessions(),
      availability: [_avail(1, {_am, _amPr}), _avail(2, {_am, _amPr}), _avail(3, {_am, _amPr})],
      users: users(usersList),
    );

    final byUser = <int, int>{};
    for (final (uid, sid) in result) {
      byUser[uid] = sid;
    }
    expect(byUser[1], 1); // OCBC
    expect(byUser[2], 1); // OCBC (both experienced, cap 2)
    expect(byUser[3], 2); // PR
  });

  test('streak rule: streak-2 experienced yields to streak-0', () {
    final usersList = [
      _user(1, Experience.experienced, streak: 2),
      _user(2, Experience.experienced),
      _user(3, Experience.newbie),
    ];
    final result = allocator.run(
      sessions: _sessions(),
      availability: [_avail(1, {_am, _amPr}), _avail(2, {_am, _amPr}), _avail(3, {_am, _amPr})],
      users: users(usersList),
    );
    final byUser = <int, int>{};
    for (final (uid, sid) in result) {
      byUser[uid] = sid;
    }
    expect(byUser[2], 1); // OCBC (streak 0 preferred)
    expect(byUser[1], 2); // streak-2 pushed to PR (no 3-in-a-row)
    expect(byUser[3], 1); // newbie fills the 2nd OCBC seat over the streak-2
  });

  test('streak rule relaxed when no alternative', () {
    final usersList = [_user(1, Experience.experienced, streak: 2)];
    final result = allocator.run(
      sessions: _sessions(),
      availability: [_avail(1, {_am, _amPr})],
      users: users(usersList),
    );
    expect(result.map((e) => e.$2), [1]); // still OCBC (no alternative)
  });

  test('new members spill to OCBC when PR overflow', () {
    // OCBC cap 2, PR cap 20; 4 new users => 2 OCBC (relaxed), 2 PR
    final usersList = [
      for (var i = 1; i <= 4; i++) _user(i, Experience.newbie),
    ];
    final result = allocator.run(
      sessions: _sessions(),
      availability: [for (var i = 1; i <= 4; i++) _avail(i, {_am, _amPr})],
      users: users(usersList),
    );
    final ocbcCount = result.where((e) => e.$2 == 1).length;
    final prCount = result.where((e) => e.$2 == 2).length;
    expect(ocbcCount, 2);
    expect(prCount, 2);
  });

  test('a member is allocated at most one session per weekend', () {
    // User picks every slot of the weekend (both locations, all days/times).
    final allWk0 = <Slot>{
      for (final day in Slot.allDays)
        for (final slot in Slot.allSlots)
          for (final loc in Slot.allLocations) Slot(0, day, slot, loc),
    };
    final result = allocator.run(
      sessions: _sessions(),
      availability: [_avail(1, allWk0)],
      users: users([_user(1, Experience.experienced)]),
    );
    expect(result.where((e) => e.$1 == 1).length, 1);
  });
}
