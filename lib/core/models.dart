import 'dart:convert';

import 'week.dart';

enum Experience { experienced, newbie }

enum NotificationPreference { weekly, everyOther, never }

enum LastPromptState { none, prompted, responded }

/// One local wall-clock time used by the rolling schedule.
class LocalWallClock {
  final int hour;
  final int minute;

  const LocalWallClock(this.hour, this.minute);

  factory LocalWallClock.parse(String value) {
    final match = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(value);
    if (match == null) throw FormatException('expected HH:MM');
    final hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    if (hour > 23 || minute > 59) {
      throw FormatException('time is outside 00:00-23:59');
    }
    return LocalWallClock(hour, minute);
  }

  String get value =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  DateTime on(DateTime day) =>
      DateTime(day.year, day.month, day.day, hour, minute);

  int compareTo(LocalWallClock other) => hour != other.hour
      ? hour.compareTo(other.hour)
      : minute.compareTo(other.minute);

  @override
  bool operator ==(Object other) =>
      other is LocalWallClock && hour == other.hour && minute == other.minute;

  @override
  int get hashCode => Object.hash(hour, minute);
}

/// Canonical weekdays accepted for schedule milestones.
const scheduleWeekdays = ['mon', 'tue', 'wed', 'thu', 'fri'];

int? scheduleWeekdayNumber(String weekday) {
  final index = scheduleWeekdays.indexOf(weekday);
  return index < 0 ? null : index + DateTime.monday;
}

/// A persisted schedule milestone: a canonical weekday and a local wall-clock
/// time. Milestones intentionally cannot be placed on Saturday or Sunday.
class ScheduleEvent {
  final String weekday;
  final LocalWallClock time;

  const ScheduleEvent({required this.weekday, required this.time});

  /// Historical convenience accessor for clients that only display the time.
  String get value => time.value;

  DateTime on(DateTime monday) {
    final day = scheduleWeekdayNumber(weekday);
    if (day == null) {
      throw ArgumentError('unknown schedule weekday "$weekday"');
    }
    return time.on(monday.add(Duration(days: day - DateTime.monday)));
  }

  int compareTo(ScheduleEvent other) {
    final thisDay = scheduleWeekdayNumber(weekday);
    final otherDay = scheduleWeekdayNumber(other.weekday);
    if (thisDay == null || otherDay == null) {
      throw ArgumentError('schedule weekdays must be mon, tue, wed, thu or fri');
    }
    final dayComparison = thisDay.compareTo(otherDay);
    return dayComparison == 0 ? time.compareTo(other.time) : dayComparison;
  }

  @override
  bool operator ==(Object other) =>
      other is ScheduleEvent && weekday == other.weekday && time == other.time;

  @override
  int get hashCode => Object.hash(weekday, time);
}

/// The four persisted weekday + local wall-clock events that drive the rolling
/// schedule. The time settings retain their historical keys for old databases.
class ScheduleTimes {
  static const promptKey = 'schedule_prompt';
  static const reminderKey = 'schedule_reminder';
  static const lockKey = 'schedule_lock';
  static const checkerKey = 'schedule_checker';
  static const promptWeekdayKey = 'schedule_prompt_weekday';
  static const reminderWeekdayKey = 'schedule_reminder_weekday';
  static const lockWeekdayKey = 'schedule_lock_weekday';
  static const checkerWeekdayKey = 'schedule_checker_weekday';

  final ScheduleEvent prompt;
  final ScheduleEvent reminder;
  final ScheduleEvent lock;
  final ScheduleEvent checker;

  const ScheduleTimes({
    required this.prompt,
    required this.reminder,
    required this.lock,
    required this.checker,
  });

  static const defaults = ScheduleTimes(
    prompt: ScheduleEvent(weekday: 'mon', time: LocalWallClock(18, 0)),
    reminder: ScheduleEvent(weekday: 'thu', time: LocalWallClock(18, 0)),
    lock: ScheduleEvent(weekday: 'fri', time: LocalWallClock(18, 0)),
    checker: ScheduleEvent(weekday: 'fri', time: LocalWallClock(21, 0)),
  );

  static const defaultSettings = <String, String>{
    promptKey: '18:00',
    reminderKey: '18:00',
    lockKey: '18:00',
    checkerKey: '21:00',
    promptWeekdayKey: 'mon',
    reminderWeekdayKey: 'thu',
    lockWeekdayKey: 'fri',
    checkerWeekdayKey: 'fri',
  };

  factory ScheduleTimes.fromSettings(Map<String, String?> values) {
    LocalWallClock read(String key) {
      final raw = values[key];
      if (raw == null) return _defaultFor(key);
      try {
        return LocalWallClock.parse(raw);
      } on FormatException {
        return _defaultFor(key);
      }
    }

    String readWeekday(String key) {
      final raw = values[key];
      return raw != null && scheduleWeekdayNumber(raw) != null
          ? raw
          : defaultSettings[key]!;
    }

    return ScheduleTimes(
      prompt: ScheduleEvent(
        weekday: readWeekday(promptWeekdayKey),
        time: read(promptKey),
      ),
      reminder: ScheduleEvent(
        weekday: readWeekday(reminderWeekdayKey),
        time: read(reminderKey),
      ),
      lock: ScheduleEvent(
        weekday: readWeekday(lockWeekdayKey),
        time: read(lockKey),
      ),
      checker: ScheduleEvent(
        weekday: readWeekday(checkerWeekdayKey),
        time: read(checkerKey),
      ),
    );
  }

  static LocalWallClock _defaultFor(String key) =>
      LocalWallClock.parse(defaultSettings[key]!);

  Map<String, String> get settings => {
    promptKey: prompt.time.value,
    reminderKey: reminder.time.value,
    lockKey: lock.time.value,
    checkerKey: checker.time.value,
    promptWeekdayKey: prompt.weekday,
    reminderWeekdayKey: reminder.weekday,
    lockWeekdayKey: lock.weekday,
    checkerWeekdayKey: checker.weekday,
  };

  Map<String, String> get json => {
    'prompt': prompt.time.value,
    'reminder': reminder.time.value,
    'lock': lock.time.value,
    'checker': checker.time.value,
    'promptWeekday': prompt.weekday,
    'reminderWeekday': reminder.weekday,
    'lockWeekday': lock.weekday,
    'checkerWeekday': checker.weekday,
  };

  bool get checkerAfterLock => checker.compareTo(lock) > 0;

  void validate() {
    for (final entry in {
      'prompt': prompt,
      'reminder': reminder,
      'lock': lock,
      'checker': checker,
    }.entries) {
      final event = entry.value;
      if (scheduleWeekdayNumber(event.weekday) == null) {
        throw ArgumentError(
          '${entry.key} weekday must be mon, tue, wed, thu or fri',
        );
      }
      final value = event.time;
      if (value.hour < 0 ||
          value.hour > 23 ||
          value.minute < 0 ||
          value.minute > 59) {
        throw ArgumentError('${entry.key} time is outside 00:00-23:59');
      }
    }
    final ordered = [prompt, reminder, lock, checker];
    for (var i = 1; i < ordered.length; i++) {
      if (ordered[i - 1].compareTo(ordered[i]) >= 0) {
        throw ArgumentError(
          '${_scheduleName(i - 1)} must be earlier than ${_scheduleName(i)}',
        );
      }
    }
  }

  static String _scheduleName(int index) =>
      const ['prompt', 'reminder', 'lock', 'checker'][index];

  @override
  bool operator ==(Object other) =>
      other is ScheduleTimes &&
      prompt == other.prompt &&
      reminder == other.reminder &&
      lock == other.lock &&
      checker == other.checker;

  @override
  int get hashCode => Object.hash(prompt, reminder, lock, checker);
}

/// Built-in location keys. Locations are dynamic (DB-backed) — these are the
/// two seeded ones, referenced where behaviour is inherently location-specific
/// (the OCBC attendance streak, the allocator's default preference).
class Locations {
  static const String ocbc = 'ocbc';
  static const String pasirRis = 'pasirRis';
}

/// One row of the activity-schedule template: a session that recurs on [day]
/// from [start] to [end] ('HH:MM') at the location [location] (a location
/// key). [slot] groups rows that share the same time window (like the old
/// AM/PM slots) so availability picks stay stable across sessions.
class ScheduleSlot {
  final String day; // 'sat' | 'sun' | 'mon' | ... | 'fri'
  final String slot; // stable label, e.g. 's1'
  final String start; // 'HH:MM'
  final String end; // 'HH:MM'
  final String location; // location key
  final int? maxPeople;
  final String? capacityGroup;

  const ScheduleSlot({
    required this.day,
    required this.slot,
    required this.start,
    required this.end,
    required this.location,
    this.maxPeople,
    this.capacityGroup,
  });
}

/// A place sessions happen at. Locations are dynamic: the two built-in ones
/// are seeded, and the console can approve new ones (with aliases) when a
/// global admin requests them from /settime.
class LocationInfo {
  final int id;
  final String key; // stable id used on sessions/slots (e.g. 'pasirRis')
  final String name; // display name, e.g. 'Pasir Ris'
  final List<String> aliases; // extra spellings the parser accepts
  final String status; // 'approved' | 'pending'
  final int? requestedBy;

  const LocationInfo({
    required this.id,
    required this.key,
    required this.name,
    required this.aliases,
    required this.status,
    this.requestedBy,
  });

  bool get isApproved => status == 'approved';

  factory LocationInfo.fromRow(Map<String, Object?> row) => LocationInfo(
    id: row['id'] as int,
    key: row['key'] as String,
    name: row['name'] as String,
    aliases: ((jsonDecode((row['aliases'] as String?) ?? '[]')) as List)
        .whereType<String>()
        .toList(),
    status: (row['status'] as String?) ?? 'approved',
    requestedBy: row['requested_by'] as int?,
  );
}

enum HolidayKind { middle, winter, summer }

/// Member tiers, in display/sort order: console > gadmin > admin > check >
/// member > out-member > old. `console` is a separate identity derived from
/// the configured console id; `gadmin` and `admin` are stored flags; the
/// remaining tiers are stored in [User.memberTier].
class MemberTier {
  static const String console = 'console';
  static const String globalAdmin = 'gadmin';
  static const String admin = 'admin';
  static const String check = 'check';
  static const String member = 'member';
  static const String outMember = 'out-member';
  static const String old = 'old';

  /// Display/sort order: first defined = top.
  static const List<String> order = [
    console,
    globalAdmin,
    admin,
    check,
    member,
    outMember,
    old,
  ];

  static const List<String> stored = [check, member, outMember, old];

  /// The stored role of [user]. Console identity is orthogonal to this role,
  /// so [isConsole] does not replace an admin or member tier. Callers that
  /// need a console group should add [console] separately.
  static String of(User user, {required bool isConsole}) {
    if (user.isGlobalAdmin) return globalAdmin;
    if (user.isAdmin) return admin;
    return user.memberTier;
  }

  /// True when the user takes part in availability/allocation/messaging.
  /// Out-members use the same flow as regular members; only checkers and old
  /// members are inactive.
  static bool isActive(String tier) => tier != check && tier != old;

  static bool isStored(String tier) => stored.contains(tier);
}

class PendingRole {
  final bool isAdmin;
  final String tier;
  final NotificationPreference notificationPreference;

  const PendingRole({
    required this.isAdmin,
    required this.tier,
    this.notificationPreference = NotificationPreference.weekly,
  });

  String get effectiveTier => isAdmin ? MemberTier.admin : tier;
}

class User {
  final int id;
  final String name;
  final Experience experience;
  final String group; // 'A' or 'B'
  final bool isAdmin;
  final bool isGlobalAdmin;
  final int ocbcStreak; // consecutive OCBC sessions attended
  final DateTime? registeredAt;

  final String _fullName;

  /// @deprecated No longer collected; use [preferredName].
  @Deprecated('No longer collected; use preferredName.')
  String get fullName => _fullName;

  String get storedFullName => _fullName;

  /// What the member wants to be called.
  final String preferredName;

  final String _matricNo;

  /// @deprecated No longer collected.
  @Deprecated('No longer collected.')
  String get matricNo => _matricNo;

  String get storedMatricNo => _matricNo;

  final String _schoolEmail;

  /// @deprecated No longer collected.
  @Deprecated('No longer collected.')
  String get schoolEmail => _schoolEmail;

  String get storedSchoolEmail => _schoolEmail;

  /// Stored tier: 'member' | 'check' | 'out-member' | 'old'. Admin and
  /// global-admin are stored flags; console identity is separate.
  final String memberTier;
  final NotificationPreference notificationPreference;
  final LastPromptState lastPromptState;

  const User({
    required this.id,
    required this.name,
    required this.experience,
    required this.group,
    this.isAdmin = false,
    this.isGlobalAdmin = false,
    this.ocbcStreak = 0,
    this.registeredAt,
    String fullName = '',
    this.preferredName = '',
    String matricNo = '',
    String schoolEmail = '',
    this.memberTier = MemberTier.member,
    this.notificationPreference = NotificationPreference.weekly,
    this.lastPromptState = LastPromptState.none,
  }) : _fullName = fullName,
       _matricNo = matricNo,
       _schoolEmail = schoolEmail;

  User copyWith({
    String? name,
    Experience? experience,
    String? group,
    bool? isAdmin,
    bool? isGlobalAdmin,
    int? ocbcStreak,
    String? preferredName,
    String? memberTier,
    String? fullName,
    String? matricNo,
    String? schoolEmail,
    DateTime? registeredAt,
    NotificationPreference? notificationPreference,
    LastPromptState? lastPromptState,
  }) {
    return User(
      id: id,
      name: name ?? this.name,
      experience: experience ?? this.experience,
      group: group ?? this.group,
      isAdmin: isAdmin ?? this.isAdmin,
      isGlobalAdmin: isGlobalAdmin ?? this.isGlobalAdmin,
      ocbcStreak: ocbcStreak ?? this.ocbcStreak,
      registeredAt: registeredAt ?? this.registeredAt,
      fullName: fullName ?? _fullName,
      preferredName: preferredName ?? this.preferredName,
      matricNo: matricNo ?? _matricNo,
      schoolEmail: schoolEmail ?? _schoolEmail,
      memberTier: memberTier ?? this.memberTier,
      notificationPreference:
          notificationPreference ?? this.notificationPreference,
      lastPromptState: lastPromptState ?? this.lastPromptState,
    );
  }

  User asMember() => copyWith(memberTier: MemberTier.member);

  User asOutMember() => copyWith(memberTier: MemberTier.outMember);

  User toMember() => asMember();

  User toOutMember() => asOutMember();

  factory User.fromRow(Map<String, Object?> row) => User(
    id: row['id'] as int,
    name: row['name'] as String,
    experience: (row['experience'] as String) == 'experienced'
        ? Experience.experienced
        : Experience.newbie,
    group: row['group_id'] as String,
    isAdmin: (row['is_admin'] as int) == 1,
    isGlobalAdmin: (row['is_global_admin'] as int? ?? 0) == 1,
    ocbcStreak: (row['ocbc_streak'] as int? ?? 0),
    registeredAt: row['created_at'] == null
        ? null
        : DateTime.tryParse(row['created_at'] as String),
    fullName: (row['full_name'] as String?) ?? '',
    preferredName: (row['preferred_name'] as String?) ?? '',
    matricNo: (row['matric_no'] as String?) ?? '',
    schoolEmail: (row['school_email'] as String?) ?? '',
    memberTier: (row['member_tier'] as String?) ?? MemberTier.member,
    notificationPreference: _notificationPreferenceFromRow(row),
    lastPromptState: _lastPromptStateFromRow(row),
  );

  static NotificationPreference _notificationPreferenceFromRow(
    Map<String, Object?> row,
  ) {
    final value = row['notification_preference'] as String?;
    return switch (value) {
      'every-other' || 'every_other' || 'everyOther' =>
        NotificationPreference.everyOther,
      'never' => NotificationPreference.never,
      _ => NotificationPreference.weekly,
    };
  }

  static LastPromptState _lastPromptStateFromRow(Map<String, Object?> row) {
    final value = row['last_prompt_state'] as String?;
    return switch (value) {
      'prompted' => LastPromptState.prompted,
      'responded' => LastPromptState.responded,
      _ => LastPromptState.none,
    };
  }
}

/// One session of one weekend, e.g. `0:sat:am:ocbc` = weekend 0, Saturday AM,
/// OCBC. Format: `{weekendIndex}:{day}:{slot}:{location}`, where day is a
/// weekday token and slot/location identify the schedule-template row.
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
class RollingWindow {
  final DateTime sat0;
  final DateTime sat1;
  final DateTime promptDay;
  final DateTime reminderDay;
  final DateTime lock0;
  final DateTime lock1;
  final DateTime checkerDay;

  const RollingWindow({
    required this.sat0,
    required this.sat1,
    required this.promptDay,
    required this.reminderDay,
    required this.lock0,
    required this.lock1,
    required this.checkerDay,
  });

  /// Historical names retained for callers of the rolling-window API.
  DateTime get deadline0 => lock0;
  DateTime get deadline1 => lock1;

  /// The bundle whose first weekend is [sat0].
  factory RollingWindow.fromSat0(
    DateTime sat0, {
    int promptHour = 18,
    int reminderHour = 18,
    ScheduleTimes? schedule,
  }) {
    final times = schedule ?? ScheduleTimes(
      prompt: ScheduleEvent(
        weekday: 'mon',
        time: LocalWallClock(promptHour, 0),
      ),
      reminder: ScheduleEvent(
        weekday: 'thu',
        time: LocalWallClock(reminderHour, 0),
      ),
      lock: const ScheduleEvent(
        weekday: 'fri',
        time: LocalWallClock(18, 0),
      ),
      checker: const ScheduleEvent(
        weekday: 'fri',
        time: LocalWallClock(21, 0),
      ),
    );
    final monday = sat0.subtract(const Duration(days: 5)); // Sat - 5 = Mon
    return RollingWindow(
      sat0: sat0,
      sat1: sat0.add(const Duration(days: 7)),
      promptDay: times.prompt.on(monday),
      reminderDay: times.reminder.on(monday),
      lock0: times.lock.on(monday),
      lock1: times.lock.on(monday.add(const Duration(days: 7))),
      checkerDay: times.checker.on(monday),
    );
  }

  /// The window for a local date: bundle = [current week, next week].
  factory RollingWindow.forDate(
    DateTime localNow, {
    int promptHour = 18,
    int reminderHour = 18,
    ScheduleTimes? schedule,
  }) {
    final week = WeekMath.isoWeek(localNow);
    final year = WeekMath.isoYear(localNow);
    return RollingWindow.fromSat0(
      WeekMath.saturdayOfWeek(week, year),
      promptHour: promptHour,
      reminderHour: reminderHour,
      schedule: schedule,
    );
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

  /// The Saturday date of the session's weekend (the bundle anchor).
  final DateTime weekendStart;
  final String day; // 'sat' | 'sun' | 'mon' | ... (from the template)
  final String slot; // template row label, e.g. 's1'
  final String location; // location key
  final DateTime start; // actual date+time
  final DateTime end;
  final int? maxPeople;
  final String? capacityGroup;

  const Session({
    required this.id,
    required this.weekendStart,
    required this.day,
    required this.slot,
    required this.location,
    required this.start,
    required this.end,
    this.maxPeople,
    this.capacityGroup,
  });

  String slotKey() => '$day:$slot';

  /// Whether this session and [other] need the same person at the same time
  /// (same weekend, overlapping interval). Replaces the old "one pick per
  /// AM/PM slot" rule now that times are free-form.
  bool overlaps(Session other) =>
      weekendStart == other.weekendStart &&
      start.isBefore(other.end) &&
      other.start.isBefore(end);

  factory Session.fromRow(Map<String, Object?> row) => Session(
    id: row['id'] as int,
    weekendStart: DateTime.parse(row['weekend_start'] as String),
    day: row['day'] as String,
    slot: row['slot'] as String,
    location: row['location'] as String,
    start: DateTime.parse(row['start_at'] as String),
    end: DateTime.parse(row['end_at'] as String),
    maxPeople: row['max_people'] as int?,
    capacityGroup: row['capacity_group'] as String?,
  );
}

/// A user's availability for one weekend of a bundle.
class Availability {
  final DateTime weekendStart; // the Saturday of the covered weekend
  final int userId;

  /// The Saturday of the bundle's first weekend — the prompt this response
  /// answers. The quiet rule ("not bothered for 2 weeks") keys off this.
  final DateTime bundleStart;

  /// Sessions the member can attend if needed (backup).
  final Set<Slot> slots;

  /// Sessions the member explicitly wants to attend (commitment). The
  /// allocator fills these first.
  final Set<Slot> wantSlots;
  final bool available; // false = explicitly not available for the weekend
  final DateTime updatedAt;

  const Availability({
    required this.weekendStart,
    required this.userId,
    required this.bundleStart,
    required this.slots,
    this.wantSlots = const {},
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
