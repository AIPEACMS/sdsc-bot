import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'support/allocate_fixtures.dart';

void main() {
  const allocator = Allocator();
  test('want picks are allocated first, one per time slot', () {
    // User wants every session of the weekend: gets one AM + one PM, never
    // two sessions at the same time.
    final result = allocator.run(
      sessions: sessions(),
      availability: [avail(1, want: {am, amPr, pm, pmPr})],
    );
    final sids = result.where((e) => e.$1 == 1).map((e) => e.$2).toSet();
    expect(sids, {1, 3}); // am OCBC + pm OCBC (first of each slot)
  });

  test('same capacity group is independent across weekends', () {
    final sessions = [
      Session(
        id: 1,
        weekendStart: DateTime(2026, 8, 8),
        day: 'sat',
        slot: 'am',
        location: Locations.ocbc,
        start: DateTime(2026, 8, 8, 9),
        end: DateTime(2026, 8, 8, 13),
        maxPeople: 1,
        capacityGroup: 'same-session',
      ),
      Session(
        id: 2,
        weekendStart: DateTime(2026, 8, 15),
        day: 'sat',
        slot: 'am',
        location: Locations.ocbc,
        start: DateTime(2026, 8, 15, 9),
        end: DateTime(2026, 8, 15, 13),
        maxPeople: 1,
        capacityGroup: 'same-session',
      ),
    ];
    final result = allocator.run(
      sessions: sessions,
      availability: [
        Availability(
          weekendStart: DateTime(2026, 8, 8),
          userId: 1,
          bundleStart: DateTime(2026, 8, 8),
          slots: {const Slot(0, 'sat', 'am', Locations.ocbc)},
          available: true,
          updatedAt: DateTime(2026, 8, 1),
        ),
        Availability(
          weekendStart: DateTime(2026, 8, 15),
          userId: 2,
          bundleStart: DateTime(2026, 8, 8),
          slots: {const Slot(1, 'sat', 'am', Locations.ocbc)},
          available: true,
          updatedAt: DateTime(2026, 8, 1),
        ),
      ],
    );
    expect(result, containsAll([(1, 1), (2, 2)]));
  });

  test('same weekend capacity group is shared across session lengths', () {
    final sessions = [
      Session(
        id: 1,
        weekendStart: DateTime(2026, 8, 8),
        day: 'sat',
        slot: 'am',
        location: Locations.ocbc,
        start: DateTime(2026, 8, 8, 9),
        end: DateTime(2026, 8, 8, 12),
        maxPeople: 1,
        capacityGroup: 'same-session',
      ),
      Session(
        id: 2,
        weekendStart: DateTime(2026, 8, 8),
        day: 'sat',
        slot: 'pm',
        location: Locations.ocbc,
        start: DateTime(2026, 8, 8, 9),
        end: DateTime(2026, 8, 8, 13),
        maxPeople: 1,
        capacityGroup: 'same-session',
      ),
    ];
    final result = allocator.run(
      sessions: sessions,
      availability: [
        avail(1, want: {const Slot(0, 'sat', 'am', Locations.ocbc)}),
        avail(2, want: {const Slot(0, 'sat', 'pm', Locations.ocbc)}),
      ],
    );
    expect(result.length, 1);
  });

  test('no double-booking: two locations of the same slot never both assigned',
      () {
    final result = allocator.run(
      sessions: sessions(),
      availability: [avail(1, want: {am, amPr})],
    );
    expect(result.where((e) => e.$1 == 1).length, 1);
    expect(result.single.$2, 1); // am OCBC (first in iteration order)
  });

  test('overlapping free-form want picks are mutually exclusive', () {
    final sessions = [
      Session(
        id: 20,
        weekendStart: DateTime(2026, 8, 8),
        day: 'sat',
        slot: 'long',
        location: Locations.ocbc,
        start: DateTime(2026, 8, 8, 13),
        end: DateTime(2026, 8, 8, 18),
      ),
      Session(
        id: 21,
        weekendStart: DateTime(2026, 8, 8),
        day: 'sat',
        slot: 'early',
        location: Locations.pasirRis,
        start: DateTime(2026, 8, 8, 9),
        end: DateTime(2026, 8, 8, 15),
      ),
    ];
    final result = allocator.run(
      sessions: sessions,
      availability: [
        avail(
          1,
          want: {
            const Slot(0, 'sat', 'long', Locations.ocbc),
            const Slot(0, 'sat', 'early', Locations.pasirRis),
          },
        ),
      ],
    );
    expect(result.where((entry) => entry.$1 == 1), hasLength(1));
  });

  test('overlapping backup and booked picks only keep the booked pick', () {
    final sessions = [
      Session(
        id: 30,
        weekendStart: DateTime(2026, 8, 8),
        day: 'sat',
        slot: 'long',
        location: Locations.ocbc,
        start: DateTime(2026, 8, 8, 13),
        end: DateTime(2026, 8, 8, 18),
      ),
      Session(
        id: 31,
        weekendStart: DateTime(2026, 8, 8),
        day: 'sat',
        slot: 'early',
        location: Locations.pasirRis,
        start: DateTime(2026, 8, 8, 9),
        end: DateTime(2026, 8, 8, 15),
      ),
    ];
    final result = allocator.run(
      sessions: sessions,
      availability: [
        avail(
          1,
          want: {const Slot(0, 'sat', 'long', Locations.ocbc)},
          slots: {const Slot(0, 'sat', 'early', Locations.pasirRis)},
        ),
      ],
    );
    expect(result, [(1, 30)]);
  });
}
