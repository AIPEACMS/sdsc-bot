import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';

const _am = Slot(0, 'sat', 'am', 'ocbc');
const _amPr = Slot(0, 'sat', 'am', 'pasirRis');
const _pm = Slot(0, 'sat', 'pm', 'ocbc');
const _pmPr = Slot(0, 'sat', 'pm', 'pasirRis');
const _am1 = Slot(1, 'sat', 'am', 'ocbc'); // weekend 1

Availability _avail(int userId,
        {Set<Slot> want = const {}, Set<Slot> slots = const {}}) =>
    Availability(
      weekendStart: DateTime(2026, 8, 8),
      userId: userId,
      bundleStart: DateTime(2026, 8, 8),
      slots: slots,
      wantSlots: want,
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
  const allocator = Allocator();

  test('want picks are allocated first, one per time slot', () {
    // User wants every session of the weekend: gets one AM + one PM, never
    // two sessions at the same time.
    final result = allocator.run(
      sessions: _sessions(),
      availability: [_avail(1, want: {_am, _amPr, _pm, _pmPr})],
    );
    final sids = result.where((e) => e.$1 == 1).map((e) => e.$2).toSet();
    expect(sids, {1, 3}); // am OCBC + pm OCBC (first of each slot)
  });

  test('no double-booking: two locations of the same slot never both assigned',
      () {
    final result = allocator.run(
      sessions: _sessions(),
      availability: [_avail(1, want: {_am, _amPr})],
    );
    expect(result.where((e) => e.$1 == 1).length, 1);
    expect(result.single.$2, 1); // am OCBC (first in iteration order)
  });

  test('full-day: want in both AM and PM allocates both', () {
    final result = allocator.run(
      sessions: _sessions(),
      availability: [_avail(1, want: {_am, _pm})],
    );
    final sids = result.where((e) => e.$1 == 1).map((e) => e.$2).toSet();
    expect(sids, {1, 3});
  });

  test('available picks give exactly one session per member', () {
    final result = allocator.run(
      sessions: _sessions(),
      availability: [_avail(1, slots: {_am, _amPr, _pm, _pmPr})],
    );
    expect(result.where((e) => e.$1 == 1).length, 1);
  });

  test('want sessions plus one available session in a free time slot', () {
    // User wants am OCBC and offers pm OCBC + pm PR: gets am OCBC (want) and
    // one of the pm offers.
    final result = allocator.run(
      sessions: _sessions(),
      availability: [_avail(1, want: {_am}, slots: {_pm, _pmPr})],
    );
    final sids = result.where((e) => e.$1 == 1).map((e) => e.$2).toSet();
    expect(sids, {1, 3}); // am OCBC + pm OCBC
  });

  test('available pass never adds a second session in a held time slot', () {
    // User wants am OCBC and offers am PR: the am slot is already held, so
    // the available pass adds nothing.
    final result = allocator.run(
      sessions: _sessions(),
      availability: [_avail(1, want: {_am}, slots: {_amPr})],
    );
    expect(result.where((e) => e.$1 == 1).length, 1);
  });

  test('want members and available members are all placed (no capacity)', () {
    final result = allocator.run(
      sessions: _sessions(),
      availability: [
        _avail(1, want: {_am}),
        _avail(2, slots: {_am}),
        _avail(3, want: {_pm}),
      ],
    );
    final byUser = <int, Set<int>>{};
    for (final (uid, sid) in result) {
      byUser.putIfAbsent(uid, () => {}).add(sid);
    }
    expect(byUser[1], {1}); // want: am OCBC
    expect(byUser[2], {1}); // available: am OCBC (no capacity)
    expect(byUser[3], {3}); // want: pm OCBC
  });

  test('locked members keep their session; others may still join', () {
    final result = allocator.run(
      sessions: _sessions(),
      availability: [
        _avail(1, want: {_am}),
        _avail(2, want: {_am}),
      ],
      locked: [(1, 1)],
    );
    final byUser = <int, Set<int>>{};
    for (final (uid, sid) in result) {
      byUser.putIfAbsent(uid, () => {}).add(sid);
    }
    expect(byUser[1], {1}); // locked member keeps am OCBC
    expect(byUser[2], {1}); // no capacity: user 2 joins the same session
  });

  test('locked member never gets a second session in their held time slot',
      () {
    // User 1 is locked to am OCBC and also wants am PR: the am slot is taken
    // for them, so only the locked session stands.
    final result = allocator.run(
      sessions: _sessions(),
      availability: [_avail(1, want: {_amPr})],
      locked: [(1, 1)],
    );
    expect(result.where((e) => e.$1 == 1).map((e) => e.$2), [1]);
  });

  test('both Saturdays: want picks allocate in each weekend run', () {
    final w0 = allocator.run(
      sessions: _sessions(),
      availability: [_avail(1, want: {_am})],
    );
    final w1Sessions = _sessions()
        .map((s) => Session(
              id: s.id + 10,
              weekendStart: DateTime(2026, 8, 15),
              day: s.day,
              slot: s.slot,
              location: s.location,
              start: s.start.add(const Duration(days: 7)),
              end: s.end.add(const Duration(days: 7)),
            ))
        .toList();
    final w1 = allocator.run(
      sessions: w1Sessions,
      availability: [
        Availability(
          weekendStart: DateTime(2026, 8, 15),
          userId: 1,
          bundleStart: DateTime(2026, 8, 8),
          slots: {},
          wantSlots: {_am1},
          available: true,
          updatedAt: DateTime(2026, 8, 1),
        ),
      ],
    );
    expect(w0.single.$2, 1); // weekend 0: am OCBC
    expect(w1.single.$2, 11); // weekend 1: am OCBC
  });
}