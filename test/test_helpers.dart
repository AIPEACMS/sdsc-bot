import 'package:sdsc_bot/sdsc_bot.dart';

/// The built-in Saturday schedule used across tests: AM 09:00-12:00 and
/// PM 13:00-17:00 at OCBC and Pasir Ris. Mirrors the template the bot seeds
/// from the environment slots on first run.
List<ScheduleSlot> defaultTemplate() => const [
  ScheduleSlot(
    day: 'sat',
    slot: 'am',
    start: '09:00',
    end: '12:00',
    location: Locations.ocbc,
  ),
  ScheduleSlot(
    day: 'sat',
    slot: 'am',
    start: '09:00',
    end: '12:00',
    location: Locations.pasirRis,
  ),
  ScheduleSlot(
    day: 'sat',
    slot: 'pm',
    start: '13:00',
    end: '17:00',
    location: Locations.ocbc,
  ),
  ScheduleSlot(
    day: 'sat',
    slot: 'pm',
    start: '13:00',
    end: '17:00',
    location: Locations.pasirRis,
  ),
];

/// Concrete sessions mirroring [defaultTemplate] for the weekend anchored at
/// [sat], plus the following weekend when [next] is true.
List<Session> defaultSessions(DateTime sat, {bool next = true}) {
  final out = <Session>[];
  var id = 1;
  for (final anchor in [sat, if (next) sat.add(const Duration(days: 7))]) {
    for (final t in defaultTemplate()) {
      final offset = Slot.allDays.indexOf(t.day);
      final date = anchor.add(Duration(days: offset));
      DateTime at(String hm) {
        final parts = hm.split(':');
        return DateTime(
          date.year,
          date.month,
          date.day,
          int.parse(parts[0]),
          int.parse(parts[1]),
        );
      }

      out.add(
        Session(
          id: id++,
          weekendStart: anchor,
          day: t.day,
          slot: t.slot,
          location: t.location,
          start: at(t.start),
          end: at(t.end),
        ),
      );
    }
  }
  return out;
}
