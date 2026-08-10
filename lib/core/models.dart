import 'dart:convert';

enum Experience { experienced, newbie }

enum Location { ocbc, pasirRis }

enum HolidayKind { middle, winter, summer }

enum CycleStatus { open, closed, allocated }

class User {
  final int id;
  final String name;
  final Experience experience;
  final String group; // 'A' or 'B'
  final bool isAdmin;
  final int ocbcStreak; // consecutive OCBC allocations
  final DateTime? registeredAt;

  const User({
    required this.id,
    required this.name,
    required this.experience,
    required this.group,
    this.isAdmin = false,
    this.ocbcStreak = 0,
    this.registeredAt,
  });

  User copyWith({
    String? name,
    Experience? experience,
    String? group,
    bool? isAdmin,
    int? ocbcStreak,
  }) {
    return User(
      id: id,
      name: name ?? this.name,
      experience: experience ?? this.experience,
      group: group ?? this.group,
      isAdmin: isAdmin ?? this.isAdmin,
      ocbcStreak: ocbcStreak ?? this.ocbcStreak,
      registeredAt: registeredAt,
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
      );
}

/// One day+time slot of one weekend, e.g. `0:sat:am` = weekend 0, Saturday AM.
/// Format: `{weekendIndex}:{day}:{slot}` where day in {sat,sun}, slot in {am,pm}.
class Slot {
  final int weekendIndex; // 0 or 1
  final String day; // 'sat' | 'sun'
  final String slot; // 'am' | 'pm'

  const Slot(this.weekendIndex, this.day, this.slot);

  static const allDays = ['sat', 'sun'];
  static const allSlots = ['am', 'pm'];

  String encode() => '$weekendIndex:$day:$slot';

  static Slot? parse(String raw) {
    final parts = raw.split(':');
    if (parts.length != 3) return null;
    final wi = int.tryParse(parts[0]);
    if (wi == null || wi < 0 || wi > 1) return null;
    if (!allDays.contains(parts[1]) || !allSlots.contains(parts[2])) {
      return null;
    }
    return Slot(wi, parts[1], parts[2]);
  }

  static Set<Slot> decodeSet(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => Slot.parse(e as String))
        .whereType<Slot>()
        .toSet();
  }

  @override
  String toString() => 'Weekend ${weekendIndex + 1} $day/$slot';

  @override
  bool operator ==(Object other) =>
      other is Slot &&
      other.weekendIndex == weekendIndex &&
      other.day == day &&
      other.slot == slot;

  @override
  int get hashCode => Object.hash(weekendIndex, day, slot);
}

/// A 2-week cycle identified by its first session weekend ISO week (`blockWeek`, odd).
class Cycle {
  final int id;
  final int blockWeek; // ISO week of the first session weekend (odd)
  final int blockYear; // ISO year of blockWeek
  final DateTime promptDay; // Monday of blockWeek - 1
  final DateTime reminderDay; // Thursday of blockWeek - 1
  final DateTime deadline; // Friday of blockWeek - 1 18:00
  final DateTime allocationDay; // Wednesday of blockWeek
  final CycleStatus status;
  final bool promptSent;
  final bool reminderSent;
  final bool allocated;

  const Cycle({
    required this.id,
    required this.blockWeek,
    required this.blockYear,
    required this.promptDay,
    required this.reminderDay,
    required this.deadline,
    required this.allocationDay,
    required this.status,
    required this.promptSent,
    required this.reminderSent,
    required this.allocated,
  });

  Cycle copyWith({
    CycleStatus? status,
    bool? promptSent,
    bool? reminderSent,
    bool? allocated,
  }) {
    return Cycle(
      id: id,
      blockWeek: blockWeek,
      blockYear: blockYear,
      promptDay: promptDay,
      reminderDay: reminderDay,
      deadline: deadline,
      allocationDay: allocationDay,
      status: status ?? this.status,
      promptSent: promptSent ?? this.promptSent,
      reminderSent: reminderSent ?? this.reminderSent,
      allocated: allocated ?? this.allocated,
    );
  }

  factory Cycle.fromRow(Map<String, Object?> row) => Cycle(
        id: row['id'] as int,
        blockWeek: row['block_week'] as int,
        blockYear: row['block_year'] as int,
        promptDay: DateTime.parse(row['prompt_day'] as String),
        reminderDay: DateTime.parse(row['reminder_day'] as String),
        deadline: DateTime.parse(row['deadline'] as String),
        allocationDay: DateTime.parse(row['allocation_day'] as String),
        status: CycleStatus.values.byName(row['status'] as String),
        promptSent: (row['prompt_sent'] as int) == 1,
        reminderSent: (row['reminder_sent'] as int) == 1,
        allocated: (row['allocated'] as int) == 1,
      );
}

/// A concrete session (weekend x day x slot x location) needing volunteers.
class Session {
  final int id;
  final int cycleId;
  final int weekendIndex; // 0 or 1
  final String day; // 'sat' | 'sun'
  final String slot; // 'am' | 'pm'
  final Location location;
  final DateTime start; // actual date+time
  final DateTime end;

  const Session({
    required this.id,
    required this.cycleId,
    required this.weekendIndex,
    required this.day,
    required this.slot,
    required this.location,
    required this.start,
    required this.end,
  });

  String slotKey() => '$weekendIndex:$day:$slot';

  factory Session.fromRow(Map<String, Object?> row) => Session(
        id: row['id'] as int,
        cycleId: row['cycle_id'] as int,
        weekendIndex: row['weekend_index'] as int,
        day: row['day'] as String,
        slot: row['slot'] as String,
        location: (row['location'] as String) == 'ocbc'
            ? Location.ocbc
            : Location.pasirRis,
        start: DateTime.parse(row['start_at'] as String),
        end: DateTime.parse(row['end_at'] as String),
      );
}

/// A user's availability for a cycle.
class Availability {
  final int cycleId;
  final int userId;
  final Set<Slot> slots;
  final bool available; // false = explicitly not available for the 2 weeks
  final DateTime updatedAt;

  const Availability({
    required this.cycleId,
    required this.userId,
    required this.slots,
    required this.available,
    required this.updatedAt,
  });
}

class Allocation {
  final int cycleId;
  final int userId;
  final int sessionId;

  const Allocation({
    required this.cycleId,
    required this.userId,
    required this.sessionId,
  });
}

class Attendance {
  final int userId;
  final int sessionId;
  final DateTime confirmedAt;

  const Attendance({
    required this.userId,
    required this.sessionId,
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
