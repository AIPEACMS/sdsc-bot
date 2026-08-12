import 'dart:convert';

import 'week.dart';

enum Experience { experienced, newbie }

enum Location { ocbc, pasirRis }

enum HolidayKind { middle, winter, summer }

/// Member tiers, in display/sort order: console > admin > check > member > old.
/// `console` and `admin` are derived (console id + is_admin); `check`, `member`
/// and `old` are stored in [User.memberTier].
class MemberTier {
  static const String console = 'console';
  static const String admin = 'admin';
  static const String check = 'check';
  static const String member = 'member';
  static const String old = 'old';

  /// Display/sort order: first defined = top.
  static const List<String> order = [console, admin, check, member, old];

  /// The tier of [user], given whether their id is the console.
  static String of(User user, {required bool isConsole}) {
    if (isConsole) return console;
    if (user.isAdmin) return admin;
    return user.memberTier;
  }

  /// True when the user takes part in availability/allocation/messaging.
  static bool isActive(String tier) =>
      tier != check && tier != old;
}

class User {
  final int id;
  final String name;
  final Experience experience;
  final String group; // 'A' or 'B'
  final bool isAdmin;
  final int ocbcStreak; // consecutive OCBC allocations
  final DateTime? registeredAt;

  /// Stored tier: 'member' | 'check' | 'old'. 'console'/'admin' are derived.
  final String memberTier;

  const User({
    required this.id,
    required this.name,
    required this.experience,
    required this.group,
    this.isAdmin = false,
    this.ocbcStreak = 0,
    this.registeredAt,
    this.memberTier = MemberTier.member,
  });

  User copyWith({
    String? name,
    Experience? experience,
    String? group,
    bool? isAdmin,
    int? ocbcStreak,
    String? memberTier,
  }) {
    return User(
      id: id,
      name: name ?? this.name,
      experience: experience ?? this.experience,
      group: group ?? this.group,
      isAdmin: isAdmin ?? this.isAdmin,
      ocbcStreak: ocbcStreak ?? this.ocbcStreak,
      registeredAt: registeredAt,
      memberTier: memberTier ?? this.memberTier,
    );
  }

  factory User.fromRow(Map<String, Object?> row) => User(
        id: row['id'] as int,
        name: row['name'] as String,
        experience: (row['experience'] as String) == 'experienced'
            ? Experience.experienced
            : Experience.newbie,
        group: row['group_id'] as String,
        isAdmin: (row['is_admin'] as int) == 1,
        ocbcStreak: (row['ocbc_streak'] as int? ?? 0),
        registeredAt: row['created_at'] == null
            ? null
            : DateTime.tryParse(row['created_at'] as String),
        memberTier: (row['member_tier'] as String?) ?? MemberTier.member,
      );
}

/// One session of one weekend, e.g. `0:sat:am:ocbc` = weekend 0, Saturday AM,
/// OCBC. Format: `{weekendIndex}:{day}:{slot}:{location}` where day in
/// {sat,sun}, slot in {am,pm}, location in {ocbc,pasirRis}.
class Slot {
  final int weekendIndex; // 0 or 1
  final String day; // 'sat' | 'sun'
  final String slot; // 'am' | 'pm'
  final String location; // 'ocbc' | 'pasirRis'

  const Slot(this.weekendIndex, this.day, this.slot, this.location);

  static const allDays = ['sat', 'sun'];
  static const allSlots = ['am', 'pm'];
  static const allLocations = ['ocbc', 'pasirRis'];

  String encode() => '$weekendIndex:$day:$slot:$location';

  String get dayLabel => day == 'sat' ? 'Sat' : 'Sun';
  String get slotLabel => slot == 'am' ? 'AM' : 'PM';
  String get locationLabel => location == 'ocbc' ? 'OCBC' : 'PR';

  static Slot? parse(String raw) {
    final parts = raw.split(':');
    if (parts.length != 4) return null;
    final wi = int.tryParse(parts[0]);
    if (wi == null || wi < 0 || wi > 1) return null;
    if (!allDays.contains(parts[1]) || !allSlots.contains(parts[2])) {
      return null;
    }
    if (!allLocations.contains(parts[3])) return null;
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
        // locations of that slot.
        final wi = int.tryParse(parts[0]);
        if (wi == null || wi < 0 || wi > 1) continue;
        if (!allDays.contains(parts[1]) || !allSlots.contains(parts[2])) {
          continue;
        }
        result.addAll([
          Slot(wi, parts[1], parts[2], 'ocbc'),
          Slot(wi, parts[1], parts[2], 'pasirRis'),
        ]);
      } else {
        final slot = Slot.parse(key);
        if (slot != null) result.add(slot);
      }
    }
    return result;
  }

  @override
  String toString() => 'Weekend ${weekendIndex + 1} · $locationLabel · '
      '$dayLabel $slotLabel';

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
///   - prompt:    Monday 08:00 of the current week
///   - reminder:  Thursday 18:00
///   - deadline0: Friday 18:00 of the current week (locks this weekend)
///   - deadline1: Friday 18:00 of next week (locks the second weekend)
///   - weekends:  Saturday of the current week and the next
class RollingWindow {
  final DateTime sat0;
  final DateTime sat1;
  final DateTime promptDay;
  final DateTime reminderDay;
  final DateTime deadline0;
  final DateTime deadline1;

  const RollingWindow({
    required this.sat0,
    required this.sat1,
    required this.promptDay,
    required this.reminderDay,
    required this.deadline0,
    required this.deadline1,
  });

  /// The bundle whose first weekend is [sat0].
  factory RollingWindow.fromSat0(DateTime sat0) {
    final monday = sat0.subtract(const Duration(days: 5)); // Sat - 5 = Mon
    return RollingWindow(
      sat0: sat0,
      sat1: sat0.add(const Duration(days: 7)),
      promptDay: WeekMath.atTime(monday, 8),
      reminderDay: WeekMath.atTime(monday.add(const Duration(days: 3)), 18),
      deadline0: WeekMath.atTime(monday.add(const Duration(days: 4)), 18),
      deadline1: WeekMath.atTime(monday.add(const Duration(days: 11)), 18),
    );
  }

  /// The window for a local date: bundle = [current week, next week].
  factory RollingWindow.forDate(DateTime localNow) {
    final week = WeekMath.isoWeek(localNow);
    final year = WeekMath.isoYear(localNow);
    return RollingWindow.fromSat0(WeekMath.saturdayOfWeek(week, year));
  }

  List<DateTime> get weekends => [sat0, sat1];

  bool sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// The deadline that locks [weekendStart] (one of [sat0], [sat1]).
  DateTime deadlineFor(DateTime weekendStart) =>
      sameDay(weekendStart, sat0) ? deadline0 : deadline1;

  /// Whether [weekendStart]'s availability is already locked at [now].
  bool locked(DateTime weekendStart, DateTime now) =>
      !now.isBefore(deadlineFor(weekendStart));
}

/// A concrete session (weekend x day x slot x location) needing volunteers.
class Session {
  final int id;

  /// The Saturday date of the session's weekend.
  final DateTime weekendStart;
  final String day; // 'sat' | 'sun'
  final String slot; // 'am' | 'pm'
  final Location location;
  final DateTime start; // actual date+time
  final DateTime end;

  const Session({
    required this.id,
    required this.weekendStart,
    required this.day,
    required this.slot,
    required this.location,
    required this.start,
    required this.end,
  });

  String slotKey() => '$day:$slot';

  factory Session.fromRow(Map<String, Object?> row) => Session(
        id: row['id'] as int,
        weekendStart: DateTime.parse(row['weekend_start'] as String),
        day: row['day'] as String,
        slot: row['slot'] as String,
        location: (row['location'] as String) == 'ocbc'
            ? Location.ocbc
            : Location.pasirRis,
        start: DateTime.parse(row['start_at'] as String),
        end: DateTime.parse(row['end_at'] as String),
      );
}

/// A user's availability for one weekend of a bundle.
class Availability {
  final DateTime weekendStart; // the Saturday of the covered weekend
  final int userId;

  /// The Saturday of the bundle's first weekend — the prompt this response
  /// answers. The quiet rule ("not bothered for 2 weeks") keys off this.
  final DateTime bundleStart;
  final Set<Slot> slots;
  final bool available; // false = explicitly not available for the weekend
  final DateTime updatedAt;

  const Availability({
    required this.weekendStart,
    required this.userId,
    required this.bundleStart,
    required this.slots,
    required this.available,
    required this.updatedAt,
  });
}

class Allocation {
  final int id;
  final int userId;
  final int sessionId;

  const Allocation({
    required this.id,
    required this.userId,
    required this.sessionId,
  });
}

class Attendance {
  final int userId;
  final int sessionId;

  /// true = present, false = not participated (a deliberate negative mark).
  final bool attended;
  final DateTime confirmedAt;

  const Attendance({
    required this.userId,
    required this.sessionId,
    required this.attended,
    required this.confirmedAt,
  });
}

/// A holiday week flagged by the admin. `weekStart` is the Monday of the week.
class Holiday {
  final int id;
  final DateTime weekStart;
  final HolidayKind kind;

  const Holiday({
    required this.id,
    required this.weekStart,
    required this.kind,
  });

  factory Holiday.fromRow(Map<String, Object?> row) => Holiday(
        id: row['id'] as int,
        weekStart: DateTime.parse(row['week_start'] as String),
        kind: HolidayKind.values.byName(row['kind'] as String),
      );
}
