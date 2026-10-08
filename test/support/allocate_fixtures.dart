import 'package:sdsc_bot/sdsc_bot.dart';

const am = Slot(0, 'sat', 'am', 'ocbc');
const amPr = Slot(0, 'sat', 'am', 'pasirRis');
const pm = Slot(0, 'sat', 'pm', 'ocbc');
const pmPr = Slot(0, 'sat', 'pm', 'pasirRis');
const am1 = Slot(1, 'sat', 'am', 'ocbc');
const pm1Pr = Slot(1, 'sat', 'pm', 'pasirRis');

Availability avail(int userId,
        {Set<Slot> want = const {},
        Set<Slot> slots = const {},
        DateTime? updatedAt}) =>
    Availability(
      weekendStart: DateTime(2026, 8, 8),
      userId: userId,
      bundleStart: DateTime(2026, 8, 8),
      slots: slots,
      wantSlots: want,
      available: true,
      updatedAt: updatedAt ?? DateTime(2026, 8, 1),
    );

List<Session> sessions() {
  Session session(String day, String slot, String location, int id) {
    final startHour = slot == 'am' ? 9 : 13;
    final endHour = slot == 'am' ? 12 : 17;
    return Session(
      id: id,
      weekendStart: DateTime(2026, 8, 8),
      day: day,
      slot: slot,
      location: location,
      start: DateTime(2026, 8, 8, startHour),
      end: DateTime(2026, 8, 8, endHour),
    );
  }
  return [
    session('sat', 'am', Locations.ocbc, 1),
    session('sat', 'am', Locations.pasirRis, 2),
    session('sat', 'pm', Locations.ocbc, 3),
    session('sat', 'pm', Locations.pasirRis, 4),
  ];
}

User user(
  int id, {
  Experience experience = Experience.newbie,
  int ocbcStreak = 0,
}) => User(
  id: id,
  name: '@user$id',
  experience: experience,
  group: '1',
  ocbcStreak: ocbcStreak,
);
