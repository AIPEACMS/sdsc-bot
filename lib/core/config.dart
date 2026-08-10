import 'dart:io';

/// Runtime configuration. Reads from environment with sensible defaults.
class Config {
  final String botToken;
  final String dbPath;

  /// The console user's Telegram id, read from the `CONSOLE_ID` environment
  /// variable (kept in the secret env file, never committed). The console is
  /// the first user: they have admin rights + debug rights, but are not
  /// themselves an admin — they can step down from admin later.
  final int consoleId;

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
    required this.dbPath,
    required this.consoleId,
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

  /// Debug override for "now" (UTC). Set by the console via /setdate; lets
  /// the console test whether prompts/reminders/allocations would fire.
  static DateTime? _debugNowUtc;

  static void setDebugNow(DateTime? utc) => _debugNowUtc = utc;

  /// The clock the scheduler and flows use: real UTC now, or the debug
  /// override when set.
  static DateTime nowUtc() => _debugNowUtc ?? DateTime.now().toUtc();

  /// True for the console user, who has admin rights + debug rights.
  bool isConsole(int id) => id == consoleId;

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

    final consoleRaw = env('CONSOLE_ID');
    final consoleId = int.tryParse(consoleRaw);
    if (consoleId == null) {
      throw StateError(
        'CONSOLE_ID is required (the console user\'s Telegram id). '
        'Keep it in the secret env file, never in the repo.',
      );
    }

    return Config(
      botToken: token,
      dbPath: env('SDSC_DB', 'sdsc.db'),
      consoleId: consoleId,
      groupAContact: env('GROUP_A_CONTACT', 'TBD'),
      groupBContact: env('GROUP_B_CONTACT', 'TBD'),
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
