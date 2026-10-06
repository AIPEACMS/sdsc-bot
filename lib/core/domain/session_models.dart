part of '../models.dart';

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
