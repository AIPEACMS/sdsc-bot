import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'support/allocate_fixtures.dart';

void main() {
  const allocator = Allocator();
  test('overlapping backups remain selectable but allocate only one', () {
    final sessions = [
      Session(
        id: 40,
        weekendStart: DateTime(2026, 8, 8),
        day: 'sat',
        slot: 'long',
        location: Locations.ocbc,
        start: DateTime(2026, 8, 8, 13),
        end: DateTime(2026, 8, 8, 18),
      ),
      Session(
        id: 41,
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
          slots: {
            const Slot(0, 'sat', 'long', Locations.ocbc),
            const Slot(0, 'sat', 'early', Locations.pasirRis),
          },
        ),
      ],
    );
    expect(result.where((entry) => entry.$1 == 1), hasLength(1));
  });

  test('limited sessions allocate by indication time', () {
    final session = Session(
      id: 50,
      weekendStart: DateTime(2026, 8, 8),
      day: 'sat',
      slot: 'limited',
      location: Locations.ocbc,
      start: DateTime(2026, 8, 8, 9),
      end: DateTime(2026, 8, 8, 15),
      maxPeople: 1,
    );
    final slot = const Slot(0, 'sat', 'limited', Locations.ocbc);
    final result = allocator.run(
      sessions: [session],
      availability: [
        avail(2, want: {slot}, updatedAt: DateTime(2026, 8, 1, 10)),
        avail(1, want: {slot}, updatedAt: DateTime(2026, 8, 1, 9)),
      ],
    );
    expect(result, [(1, 50)]);
  });

  test('unlimited sessions keep accepting allocations', () {
    final session = Session(
      id: 51,
      weekendStart: DateTime(2026, 8, 8),
      day: 'sat',
      slot: 'unlimited',
      location: Locations.ocbc,
      start: DateTime(2026, 8, 8, 9),
      end: DateTime(2026, 8, 8, 15),
    );
    final slot = const Slot(0, 'sat', 'unlimited', Locations.ocbc);
    final result = allocator.run(
      sessions: [session],
      availability: [
        avail(1, want: {slot}),
        avail(2, want: {slot}),
      ],
    );
    expect(result, [(1, 51), (2, 51)]);
  });
}
