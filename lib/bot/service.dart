import 'package:televerse/televerse.dart';
import 'package:televerse/telegram.dart' hide Location, User;

import '../core/models.dart';
import '../core/repo.dart';
import '../core/config.dart';
import '../core/messages.dart';
import '../core/allocate.dart';
import '../core/week.dart';
import 'hold.dart';
import '../core/log.dart';
import 'state.dart';

/// High-level operations that drive a cycle: prompting, reminding, allocating
/// and delivering allocation messages. Used by both the scheduler and the
/// admin commands.
class CycleService {
  final Repo repo;
  final Config config;
  final Messages messages;
  final BotState state;
  final Bot bot;

  CycleService({
    required this.repo,
    required this.config,
    required this.messages,
    required this.state,
    required this.bot,
  });

  /// Picks the right prompt for [user] for [cycle]: holiday variant first,
  /// then the "you did not attend" variant for lapsed members. Returns null
  /// when the member opted out of the holiday.
  String? promptFor(User user, Cycle cycle) {
    final weekend1 = WeekMath.saturdayOfWeek(cycle.blockWeek, cycle.blockYear);
    final weekend2 =
        WeekMath.saturdayOfWeek(cycle.blockWeek + 1, cycle.blockYear);
    final holiday = repo.holidayOn(weekend1) ?? repo.holidayOn(weekend2);
    if (holiday != null) {
      if (repo.hasHolidayOptout(user.id, holiday.weekStart)) return null;
      if (holiday.kind == HolidayKind.middle) {
        return messages.msg5A(user.group);
      }
      final season = holiday.kind == HolidayKind.winter ? 'winter' : 'summer';
      return messages.msg5B(user.group, season: season);
    }
    // The "we noticed you have not attended the past 2 weeks" variant only
    // makes sense when the member could actually have attended: they joined
    // more than 2 weeks ago, and the semester containing the sessions has
    // been running for at least 2 weeks.
    final joinedRecently = user.registeredAt == null ||
        Config.nowUtc().difference(user.registeredAt!.toUtc()) <
            const Duration(days: 14);
    final year = repo.latestCalendarYear();
    final sem = year?.semesterAt(weekend1);
    final semesterMature = sem?.firstStart != null &&
        weekend1.difference(sem!.firstStart!) >= const Duration(days: 14);
    if (!joinedRecently &&
        semesterMature &&
        !repo.hasAttendedInPastDays(user.id, 14)) {
      return messages.msg1A(user.group);
    }
    return messages.msg1(user.group);
  }

  Future<void> sendPrompts(Cycle cycle) async {
    var failures = 0;
    final today = config.toLocal(Config.nowUtc());
    for (final user in repo.activeUsers()) {
      try {
        // Never send the same prompt to the same user twice in one day.
        if (repo.messageSentOnDay(user.id, 'prompt', today)) continue;
        final text = promptFor(user, cycle);
        if (text == null) continue; // opted out of this holiday
        await showAvailability(user, cycle, text);
        repo.markMessageSent(user.id, 'prompt', today);
      } catch (_) {
        failures++; // member may have blocked the bot
      }
    }
    repo.markPromptSent(cycle.id);
        if (failures > 0) LogRing.log('prompt: $failures members unreachable');
  }

  Future<void> sendReminders(Cycle cycle) async {
    var failures = 0;
    final today = config.toLocal(Config.nowUtc());
    for (final user in repo.nonResponders(cycle.id)) {
      try {
        if (repo.messageSentOnDay(user.id, 'reminder', today)) continue;
        final holidayWeek = _cycleHolidayWeek(cycle);
        if (holidayWeek != null && repo.hasHolidayOptout(user.id, holidayWeek)) {
          continue;
        }
        await showAvailability(user, cycle, messages.msg2(user.group));
        repo.markMessageSent(user.id, 'reminder', today);
      } catch (_) {
        failures++;
      }
    }
    repo.markReminderSent(cycle.id);
        if (failures > 0) LogRing.log('remind: $failures members unreachable');
  }

  /// The week (Monday) of the holiday covering this cycle's sessions, if any.
  DateTime? _cycleHolidayWeek(Cycle cycle) {
    final weekend1 = WeekMath.saturdayOfWeek(cycle.blockWeek, cycle.blockYear);
    final weekend2 =
        WeekMath.saturdayOfWeek(cycle.blockWeek + 1, cycle.blockYear);
    return repo.holidayOn(weekend1)?.weekStart ??
        repo.holidayOn(weekend2)?.weekStart;
  }

  /// Whether this cycle's sessions fall on a holiday week.
  static bool isHolidayCycle(Repo repo, Cycle cycle) {
    final weekend1 = WeekMath.saturdayOfWeek(cycle.blockWeek, cycle.blockYear);
    final weekend2 =
        WeekMath.saturdayOfWeek(cycle.blockWeek + 1, cycle.blockYear);
    return repo.holidayOn(weekend1) != null || repo.holidayOn(weekend2) != null;
  }

  /// Runs the allocator, persists allocations + streaks, then sends msg4.
  Future<void> allocate(Cycle cycle) async {
    repo.ensureSessionsForCycle(
      cycle,
      config.slotTimes,
      tzOffsetHours: config.timezoneOffsetHours,
    );
    final sessions = repo.sessionsForCycle(cycle.id);
    // Only active users can be allocated; check/old users have no availability
    // and stale availability rows must not make them candidates.
    final activeUsers = repo.activeUsers();
    final activeIds = {for (final u in activeUsers) u.id};
    final availability = repo.allAvailability(cycle.id)
        .where((a) => activeIds.contains(a.userId))
        .toList();
    final users = {for (final u in activeUsers) u.id: u};

    final result = Allocator(
      ocbcCapacity: config.ocbcCapacity,
      prCapacity: config.prCapacity,
    ).run(
      sessions: sessions,
      availability: availability,
      users: users,
    );

    repo.replaceAllocations(cycle.id, result);

    final sessionsById = {for (final s in sessions) s.id: s};
    for (final (userId, sessionId) in result) {
      final session = sessionsById[sessionId];
      final user = users[userId];
      if (session == null || user == null) continue;
      final streak = session.location == Location.ocbc
          ? user.ocbcStreak + 1
          : 0;
      repo.setOcbcStreak(userId, streak);
    }

    repo.markAllocated(cycle.id);

    var failures = 0;
    final today = config.toLocal(Config.nowUtc());
    for (final (userId, sessionId) in result) {
      final session = sessionsById[sessionId];
      final user = users[userId];
      if (session == null || user == null) continue;
      final label = sessionLabel(session);
      final time =
          '${_fmt(session.start)} to ${_fmt(session.end)}';
      try {
        if (repo.messageSentOnDay(user.id, 'allocation', today)) continue;
        try {
          await bot.api.sendMessage(
            ChatID(userId),
            messages.msg4(user.group, label, time),
          );
        } on HeldException {
          // held: drop, still marked as sent
        }
        repo.markMessageSent(user.id, 'allocation', today);
      } catch (_) {
        failures++;
      }
    }
        if (failures > 0) LogRing.log('allocate: $failures msg4 sends failed');
  }

  /// Sends (or edits an existing) availability keyboard message to [user].
  Future<void> showAvailability(
    User user,
    Cycle cycle,
    String text,
  ) async {
    final picked = state.picksFor(user.id);
    final keyboard = buildKeyboard(
      cycle,
      picked,
      holiday: isHolidayCycle(repo, cycle),
    );

    final existing = state.availabilityMessages[user.id];
    if (existing != null) {
      try {
        await bot.api.editMessageText(
          ChatID(existing.$1),
          existing.$2,
          '$text\n\n${_hint()}',
          parseMode: ParseMode.html,
          replyMarkup: keyboard,
        );
        return;
      } on HeldException {
        return; // held: block & drop, treated as delivered
      } catch (_) {
        state.availabilityMessages.remove(user.id);
      }
    }

    try {
      final msg = await bot.api.sendMessage(
        ChatID(user.id),
        '$text\n\n${_hint()}',
        parseMode: ParseMode.html,
        replyMarkup: keyboard,
      );
      state.availabilityMessages[user.id] = (user.id, msg.messageId);
    } on HeldException {
      // held: block & drop, treated as delivered so the (prompt/reminder)
      // flags still advance and nothing is replayed on unhold.
    }
  }

  String sessionLabel(Session s) {
    final loc = s.location == Location.ocbc ? 'OCBC' : 'Pasir Ris';
    final day = s.day == 'sat' ? 'Saturday' : 'Sunday';
    final slot = s.slot == 'am' ? 'AM' : 'PM';
    return '$loc · $day ${_day(s.start)} $slot';
  }

  static String _day(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month - 1]}';
  }

  static String _fmt(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  String _hint() => 'Tap the sessions you can attend, then <b>Done</b>. '
      'Not able to attend? Tap <b>Not available</b>.';

  /// Builds the availability inline keyboard: toggles per weekend/day/slot
  /// and location, plus Done and Not available actions. On a holiday cycle a
  /// "skip me this holiday" opt-out button is appended.
  static InlineKeyboard buildKeyboard(
    Cycle cycle,
    Set<Slot> picked, {
    bool holiday = false,
  }) {
    var kb = InlineKeyboard();
    for (final wi in [0, 1]) {
      for (final day in Slot.allDays) {
        final dayLabel = day == 'sat' ? 'Sat' : 'Sun';
        for (final slot in Slot.allSlots) {
          final slotLabel = slot == 'am' ? 'AM' : 'PM';
          for (final loc in Slot.allLocations) {
            final key = '$wi:$day:$slot:$loc';
            final selected = picked.any((s) => s.encode() == key);
            final mark = selected ? '✅' : '▫️';
            final locLabel = loc == 'ocbc' ? 'OCBC' : 'PR';
            kb = kb.text(
              '$mark $locLabel $dayLabel $slotLabel',
              'slot|${cycle.id}|$key',
            );
          }
          kb = kb.row();
        }
      }
      kb = kb.row();
    }
    kb = kb
        .text('✅ Done', 'done|${cycle.id}')
        .row()
        .text('❌ Not available', 'no|${cycle.id}');
    if (holiday) {
      kb = kb
          .row()
          .text('🔕 Skip me this holiday', 'holidayout|${cycle.id}');
    }
    return kb;
  }
}
