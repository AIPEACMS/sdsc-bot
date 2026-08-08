import 'dart:io';

/// Runtime configuration. Reads from environment with sensible defaults.
class Config {
  final String botToken;
  final Set<int> adminIds;
  final String dbPath;

  final String groupAContact;
  final String groupBContact;

  final int ocbcCapacity; // per slot
  final int prCapacity; // per slot

  // Slot time windows, e.g. AM 09:00-12:00, PM 13:00-17:00.
  final Map<String, (String, String)> slotTimes; // 'am' -> (start,end)

  // Scheduler firing hours (local).
  final int promptHour;
  final int reminderHour;
  final int deadlineHour;
  final int allocationHour;
  final int bailHour;

  final int timezoneOffsetHours; // from UTC

  const Config({
    required this.botToken,
    required this.adminIds,
    required this.dbPath,
    required this.groupAContact,
    required this.groupBContact,
    required this.ocbcCapacity,
    required this.prCapacity,
    required this.slotTimes,
    required this.promptHour,
    required this.reminderHour,
    required this.deadlineHour,
    required this.allocationHour,
    required this.bailHour,
    required this.timezoneOffsetHours,
  });

  String contactForGroup(String group) =>
      group == 'A' ? groupAContact : groupBContact;

  factory Config.fromEnv() {
    String env(String key, [String fallback = '']) =>
        Platform.environment[key] ?? fallback;

    int envInt(String key, int fallback) =>
        int.tryParse(env(key)) ?? fallback;

    final token = env('TELEGRAM_TOKEN');
    if (token.isEmpty) {
      throw StateError('TELEGRAM_TOKEN is required.');
    }

    return Config(
      botToken: token,
      adminIds: env('ADMIN_IDS', '')
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .map(int.tryParse)
          .whereType<int>()
          .toSet(),
      dbPath: env('SDSC_DB', 'sdsc.db'),
      groupAContact: env('GROUP_A_CONTACT', 'TBD'),
      groupBContact: env('GROUP_B_CONTACT', 'TBD @tbd'),
      ocbcCapacity: envInt('OCBC_CAPACITY', 6),
      prCapacity: envInt('PR_CAPACITY', 20),
      slotTimes: {
        'am': (
          env('SLOT_AM_START', '09:00'),
          env('SLOT_AM_END', '12:00'),
        ),
        'pm': (
          env('SLOT_PM_START', '13:00'),
          env('SLOT_PM_END', '17:00'),
        ),
      },
      promptHour: envInt('PROMPT_HOUR', 8),
      reminderHour: envInt('REMINDER_HOUR', 18),
      deadlineHour: envInt('DEADLINE_HOUR', 18),
      allocationHour: envInt('ALLOCATION_HOUR', 9),
      bailHour: envInt('BAIL_HOUR', 12),
      timezoneOffsetHours: envInt('TZ_OFFSET', 8),
    );
  }

  /// Converts a UTC instant to local wall-clock time for scheduling decisions.
  DateTime toLocal(DateTime utc) =>
      utc.toUtc().add(Duration(hours: timezoneOffsetHours));
}
