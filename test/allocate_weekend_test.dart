import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'support/allocate_fixtures.dart';

void main() {
  const allocator = Allocator();
  test('booked and backup sessions may share a time on different weekends', () {
    final w1Sessions = sessions()
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
    final result = allocator.run(
      sessions: [...sessions(), ...w1Sessions],
      availability: [
        avail(1, want: {pm}),
        Availability(
          weekendStart: DateTime(2026, 8, 15),
          userId: 1,
          bundleStart: DateTime(2026, 8, 8),
          slots: {pm1Pr},
          available: true,
          updatedAt: DateTime(2026, 8, 1),
        ),
      ],
    );

    expect(
      result.where((entry) => entry.$1 == 1).map((entry) => entry.$2),
      [3, 14],
    );
  });

  test('want sessions plus one available session in a free time slot', () {
    // User wants am OCBC and offers pm OCBC + pm PR: gets am OCBC (want) and
    // one of the pm offers.
    final result = allocator.run(
      sessions: sessions(),
      availability: [avail(1, want: {am}, slots: {pm, pmPr})],
    );
    final sids = result.where((e) => e.$1 == 1).map((e) => e.$2).toSet();
    expect(sids, {1, 3}); // am OCBC + pm OCBC
  });

  test('available pass never adds a second session in a held time slot', () {
    // User wants am OCBC and offers am PR: the am slot is already held, so
    // the available pass adds nothing.
    final result = allocator.run(
      sessions: sessions(),
      availability: [avail(1, want: {am}, slots: {amPr})],
    );
    expect(result.where((e) => e.$1 == 1).length, 1);
  });

  test('want members and available members are all placed (no capacity)', () {
    final result = allocator.run(
      sessions: sessions(),
      availability: [
        avail(1, want: {am}),
        avail(2, slots: {am}),
        avail(3, want: {pm}),
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
      sessions: sessions(),
      availability: [
        avail(1, want: {am}),
        avail(2, want: {am}),
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
      sessions: sessions(),
      availability: [avail(1, want: {amPr})],
      locked: [(1, 1)],
    );
    expect(result.where((e) => e.$1 == 1).map((e) => e.$2), [1]);
  });

  test('both Saturdays: want picks allocate in each weekend run', () {
    final w0 = allocator.run(
      sessions: sessions(),
      availability: [avail(1, want: {am})],
    );
    final w1Sessions = sessions()
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
          wantSlots: {am1},
          available: true,
          updatedAt: DateTime(2026, 8, 1),
        ),
      ],
    );
    expect(w0.single.$2, 1); // weekend 0: am OCBC
    expect(w1.single.$2, 11); // weekend 1: am OCBC
  });
}
