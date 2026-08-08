import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';

const _am = Slot(0, 'sat', 'am');
const _wi1Am = Slot(1, 'sat', 'am');

User _user(int id, Experience exp, {int streak = 0}) => User(
      id: id,
      name: 'u$id',
      experience: exp,
      group: 'A',
      ocbcStreak: streak,
    );

Availability _avail(int userId, Set<Slot> slots) => Availability(
      cycleId: 1,
      userId: userId,
      slots: slots,
      available: true,
      updatedAt: DateTime(2026, 8, 1),
    );

List<Session> _sessions() {
  Session s(int weekendIndex, String day, String slot, Location loc, int id) =>
      Session(
        id: id,
        cycleId: 1,
        weekendIndex: weekendIndex,
        day: day,
        slot: slot,
        location: loc,
        start: DateTime(2026, 8, 8),
        end: DateTime(2026, 8, 8, 3),
      );
  // weekend 0: sat am (both locations), sat pm, sun am; weekend 1: sat am
  return [
    s(0, 'sat', 'am', Location.ocbc, 1),
    s(0, 'sat', 'am', Location.pasirRis, 2),
    s(0, 'sat', 'pm', Location.ocbc, 3),
    s(0, 'sat', 'pm', Location.pasirRis, 4),
    s(0, 'sun', 'am', Location.ocbc, 5),
    s(0, 'sun', 'am', Location.pasirRis, 6),
    s(1, 'sat', 'am', Location.ocbc, 7),
    s(1, 'sat', 'am', Location.pasirRis, 8),
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
      availability: [_avail(1, {_am}), _avail(2, {_am}), _avail(3, {_am})],
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
      availability: [_avail(1, {_am}), _avail(2, {_am}), _avail(3, {_am})],
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
      availability: [_avail(1, {_am})],
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
      availability: [for (var i = 1; i <= 4; i++) _avail(i, {_am})],
      users: users(usersList),
    );
    final ocbcCount = result.where((e) => e.$2 == 1).length;
    final prCount = result.where((e) => e.$2 == 2).length;
    expect(ocbcCount, 2);
    expect(prCount, 2);
  });

  test('same user can be allocated on both weekends', () {
    final usersList = [
      _user(1, Experience.experienced),
      _user(2, Experience.experienced),
    ];
    final result = allocator.run(
      sessions: _sessions(),
      availability: [
        _avail(1, {_am, _wi1Am}),
        _avail(2, {_am, _wi1Am}),
      ],
      users: users(usersList),
    );
    final sessionsFor1 = result.where((e) => e.$1 == 1).map((e) => e.$2).toSet();
    expect(sessionsFor1.length, 2); // one OCBC session per weekend
  });
}
