import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'support/allocate_fixtures.dart';

void main() {
  const allocator = Allocator();
  test('full-day: want in both AM and PM allocates both', () {
    final result = allocator.run(
      sessions: sessions(),
      availability: [avail(1, want: {am, pm})],
    );
    final sids = result.where((e) => e.$1 == 1).map((e) => e.$2).toSet();
    expect(sids, {1, 3});
  });

  test('available picks give exactly one session per member', () {
    final result = allocator.run(
      sessions: sessions(),
      availability: [avail(1, slots: {am, amPr, pm, pmPr})],
    );
    expect(result.where((e) => e.$1 == 1).length, 1);
  });

  test('experienced backup members prefer OCBC', () {
    final result = allocator.run(
      sessions: sessions(),
      availability: [avail(1, slots: {pm, pmPr})],
      users: {1: user(1, experience: Experience.experienced)},
    );
    expect(result.single, (1, 3));
  });

  test('new backup members prefer Pasir Ris', () {
    final result = allocator.run(
      sessions: sessions(),
      availability: [avail(1, slots: {pm, pmPr})],
      users: {1: user(1)},
    );
    expect(result.single, (1, 4));
  });

  test('OCBC streak rotates experienced backup members to Pasir Ris', () {
    final result = allocator.run(
      sessions: sessions(),
      availability: [avail(1, slots: {pm, pmPr})],
      users: {
        1: user(1, experience: Experience.experienced, ocbcStreak: 2),
      },
    );
    expect(result.single, (1, 4));
  });

  test('OCBC remains the fallback when no Pasir Ris backup is offered', () {
    final result = allocator.run(
      sessions: sessions(),
      availability: [avail(1, slots: {pm})],
      users: {
        1: user(1, experience: Experience.experienced, ocbcStreak: 2),
      },
    );
    expect(result.single, (1, 3));
  });

  test('location preference never changes a booked pick', () {
    final result = allocator.run(
      sessions: sessions(),
      availability: [avail(1, want: {pmPr})],
      users: {1: user(1, experience: Experience.experienced)},
    );
    expect(result.single, (1, 4));
  });

  test('backup picks across both bundle weekends allocate only once', () {
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
        avail(1, slots: {am}),
        Availability(
          weekendStart: DateTime(2026, 8, 15),
          userId: 1,
          bundleStart: DateTime(2026, 8, 8),
          slots: {am1},
          available: true,
          updatedAt: DateTime(2026, 8, 1),
        ),
      ],
    );
    expect(result.where((entry) => entry.$1 == 1).map((entry) => entry.$2),
        [1]);
  });
}
