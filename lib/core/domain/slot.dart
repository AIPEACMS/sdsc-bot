part of '../models.dart';

class Slot {
  final int weekendIndex; // 0 or 1
  final String day; // 'sat' | 'sun' | 'mon' | ...
  final String slot; // template row label, e.g. 's1'
  final String location; // location key, e.g. 'ocbc' | 'pasirRis'

  const Slot(this.weekendIndex, this.day, this.slot, this.location);

  /// The bundled weekend runs Saturday → Friday, in that order.
  static const allDays = ['sat', 'sun', 'mon', 'tue', 'wed', 'thu', 'fri'];

  String encode() => '$weekendIndex:$day:$slot:$location';

  /// Human day label, e.g. 'Sat' / 'Sunday'.
  static String dayLabel(String day) => switch (day) {
    'sat' => 'Sat',
    'sun' => 'Sun',
    'mon' => 'Mon',
    'tue' => 'Tue',
    'wed' => 'Wed',
    'thu' => 'Thu',
    'fri' => 'Fri',
    _ => day,
  };

  /// Full day name, e.g. 'Saturday'.
  static String dayName(String day) => switch (day) {
    'sat' => 'Saturday',
    'sun' => 'Sunday',
    'mon' => 'Monday',
    'tue' => 'Tuesday',
    'wed' => 'Wednesday',
    'thu' => 'Thursday',
    'fri' => 'Friday',
    _ => day,
  };

  static Slot? parse(String raw) {
    final parts = raw.split(':');
    if (parts.length != 4) return null;
    final wi = int.tryParse(parts[0]);
    if (wi == null || wi < 0 || wi > 1) return null;
    if (!allDays.contains(parts[1])) return null;
    if (parts[2].isEmpty || parts[3].isEmpty) return null;
    return Slot(wi, parts[1], parts[2], parts[3]);
  }

  static Set<Slot> decodeSet(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    final list = jsonDecode(raw) as List<dynamic>;
    final result = <Slot>{};
    for (final e in list) {
      final key = e as String;
      final parts = key.split(':');
      if (parts.length == 3) {
        // Legacy slot-level picks (before locations): available for both
        // seeded locations of that slot.
        final wi = int.tryParse(parts[0]);
        if (wi == null || wi < 0 || wi > 1) continue;
        if (!allDays.contains(parts[1])) continue;
        result.addAll([
          Slot(wi, parts[1], parts[2], Locations.ocbc),
          Slot(wi, parts[1], parts[2], Locations.pasirRis),
        ]);
      } else {
        final slot = Slot.parse(key);
        if (slot != null) result.add(slot);
      }
    }
    return result;
  }

  @override
  String toString() =>
      'Weekend ${weekendIndex + 1} · $location · '
      '${dayLabel(day)} $slot';

  @override
  bool operator ==(Object other) =>
      other is Slot &&
      other.weekendIndex == weekendIndex &&
      other.day == day &&
      other.slot == slot &&
      other.location == location;

  @override
  int get hashCode => Object.hash(weekendIndex, day, slot, location);
}

/// The rolling availability window: the current week's bundle (this weekend
/// and next weekend) with its per-weekend deadlines. Everything is computed
/// from the calendar — no database rows.
///
///   - prompt:    the configured prompt weekday and time
///   - reminder:  the configured reminder weekday and time
///   - lock0:     the configured lock weekday and time (locks this weekend)
///   - lock1:     the same lock event one week later
///   - checker:   the configured checker weekday and time
///   - weekends:  Saturday of the current week and the next
