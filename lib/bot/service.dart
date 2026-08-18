import 'package:televerse/televerse.dart';
import 'package:televerse/telegram.dart' hide Location, User;

import '../core/models.dart';
import '../core/repo.dart';
import '../core/config.dart';
import '../core/messages.dart';
import '../core/allocate.dart';
import 'hold.dart';
import '../core/log.dart';
import 'state.dart';

/// High-level operations that drive the rolling schedule: prompting,
/// reminding, allocating each weekend and delivering allocation messages.
/// Used by both the scheduler and the admin commands.
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

  /// Picks the right prompt for [user] for [window]: holiday variant first,
  /// then the "you did not attend" variant for lapsed members. Returns null
  /// when the member opted out of the holiday.
  String? promptFor(User user, RollingWindow w) {
    final holiday = repo.holidayOn(w.sat0) ?? repo.holidayOn(w.sat1);
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
    final sem = year?.semesterAt(w.sat0);
    final semesterMature = sem?.firstStart != null &&
        w.sat0.difference(sem!.firstStart!) >= const Duration(days: 14);
    if (!joinedRecently &&
        semesterMature &&
        !repo.hasAttendedInPastDays(user.id, 14)) {
      return messages.msg1A(user.group);
    }
    return messages.msg1(user.group);
  }

  /// Sends the availability picker for [window] to every prompt target.
  Future<void> sendPrompts(RollingWindow w) async {
    var failures = 0;
    final today = config.toLocal(Config.nowUtc());
    for (final user in repo.promptTargets(w.sat0)) {
      try {
        // Never send the same prompt to the same user twice in one day.
        if (repo.messageSentOnDay(user.id, 'prompt', today)) continue;
        final text = promptFor(user, w);
        if (text == null) continue; // opted out of this holiday
        await showAvailability(user, w, text);
        repo.markMessageSent(user.id, 'prompt', today);
      } catch (_) {
        failures++; // member may have blocked the bot
      }
    }
    if (failures > 0) LogRing.log('prompt: $failures members unreachable');
  }

  /// Reminds the bundle's non-responders (and not the quiet).
  Future<void> sendReminders(RollingWindow w) async {
    var failures = 0;
    final today = config.toLocal(Config.nowUtc());
    for (final user in repo.reminderTargets(w.sat0)) {
      try {
        if (repo.messageSentOnDay(user.id, 'reminder', today)) continue;
        await showAvailability(user, w, messages.msg2(user.group));
        repo.markMessageSent(user.id, 'reminder', today);
      } catch (_) {
        failures++;
      }
    }
    if (failures > 0) LogRing.log('remind: $failures members unreachable');
  }

  /// Whether this window's weekends fall on a holiday week.
  static bool isHolidayWindow(Repo repo, RollingWindow w) =>
      repo.holidayOn(w.sat0) != null || repo.holidayOn(w.sat1) != null;

  /// Allocates one weekend's sessions from the weekend's availability rows,
  /// persists allocations, then notifies. Runs dynamically (at the next sharp
  /// hour after an indication). Already-allocated members are locked in —
  /// the run only fills the remaining sessions with newly-indicated members,
  /// so nobody is ever moved or un-allocated by a later indication.
  Future<void> allocateWeekend(DateTime sat) async {
    repo.ensureSessionsForWeekend(
      sat,
      config.slotTimes,
      tzOffsetHours: config.timezoneOffsetHours,
    );
    final sessions = repo.sessionsForWeekend(sat);
    // Only active users can be allocated; check/old users have no availability
    // and stale availability rows must not make them candidates.
    final activeUsers = repo.activeUsers();
    final activeIds = {for (final u in activeUsers) u.id};
    final availability = repo
        .availabilityForWeekend(sat)
        .where((a) => activeIds.contains(a.userId))
        .toList();
    final users = {for (final u in activeUsers) u.id: u};

    // Already-allocated members are locked in place (every session they hold).
    final existing = repo.allocationsForWeekend(sat);
    final locked = [for (final (u, s) in existing) (u.id, s.id)];

    final result = const Allocator().run(
      sessions: sessions,
      availability: availability,
      locked: locked,
    );

    repo.replaceAllocationsForWeekend(sat, result);
    repo.markWeekendAllocated(sat);

    // Before the weekend's Friday deadline the member can still re-pick;
    // after it they must message the contact instead.
    final now = config.toLocal(Config.nowUtc());
    final deadline = RollingWindow.fromSat0(sat).deadlineFor(sat);
    final deadlinePassed = !now.isBefore(deadline);

    // Notify only the newly allocated — locked members were notified when
    // they were allocated.
    var failures = 0;
    final sessionsById = {for (final s in sessions) s.id: s};
    for (final (userId, sessionId) in result) {
      if (locked.any((l) => l.$1 == userId && l.$2 == sessionId)) continue;
      final session = sessionsById[sessionId];
      final user = users[userId];
      if (session == null || user == null) continue;
      final label = sessionLabel(session);
      final time = '${_fmt(session.start)} to ${_fmt(session.end)}';
      try {
        await bot.api.sendMessage(
          ChatID(userId),
          messages.msg4(
            user.group,
            label,
            time,
            deadlinePassed: deadlinePassed,
            deadlineLabel: 'Friday ${_fmt12h(deadline)}',
          ),
          parseMode: ParseMode.html,
        );
      } on HeldException {
        // held: drop
      } catch (_) {
        failures++;
      }
    }
    if (failures > 0) LogRing.log('allocate: $failures msg4 sends failed');
  }

  /// 12h "H:MM AM/PM" for human-facing deadlines (e.g. "6:00 PM").
  String _fmt12h(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '$h:$m $ampm';
  }

  /// Marks attendance and updates the OCBC streak: a present OCBC session
  /// extends the run, a present PR session resets it. The streak counts
  /// consecutive sessions attended, so the allocator bans the 3rd in a row.
  void markAttendance(int userId, int sessionId, {required bool attended}) {
    repo.setAttendanceState(userId, sessionId, attended: attended);
    final session = repo.sessionById(sessionId);
    final user = repo.findUser(userId);
    if (session == null || user == null) return;
    final streak =
        session.location == Location.ocbc ? user.ocbcStreak + 1 : 0;
    repo.setOcbcStreak(userId, streak);
  }

  /// Sunday/Monday attendance-marking reminders: for every allocated member
  /// of [sat]'s weekend with no attendance mark yet, remind the member's
  /// group admin. The console is notified via the log ring on the second day.
  Future<void> remindAttendanceMarking(DateTime sat, DateTime day) async {
    final sessions = repo.sessionsForWeekend(sat);
    var unmarkedTotal = 0;
    final byAdmin = <int, List<String>>{};
    for (final s in sessions) {
      final allocations =
          repo.allocationsForWeekend(sat).where((a) => a.$2.id == s.id);
      final marked =
          repo.attendanceForSession(s.id).map((a) => a.userId).toSet();
      for (final (user, _) in allocations) {
        if (marked.contains(user.id)) continue;
        unmarkedTotal++;
        final admin = repo.groupAdmin(user.group);
        if (admin == null) continue; // no group → nobody responsible
        byAdmin
            .putIfAbsent(admin.id, () => [])
            .add('${user.name} — ${sessionLabel(s)}');
      }
    }
    if (byAdmin.isEmpty) return;

    for (final entry in byAdmin.entries) {
      if (repo.messageSentOnDay(entry.key, 'attmark', day)) continue;
      final list = entry.value.take(6).join('\n');
      final more = entry.value.length > 6
          ? '\n… and ${entry.value.length - 6} more'
          : '';
      try {
        await bot.api.sendMessage(
          ChatID(entry.key),
          '⏰ <b>Mark attendance</b> — still unmarked:\n$list$more\n\n'
              'Mark it in the console or with /confirm.',
          parseMode: ParseMode.html,
        );
        repo.markMessageSent(entry.key, 'attmark', day);
      } catch (_) {
        // admin unreachable; the console banner still surfaces it
      }
    }
    LogRing.log(
        'attmark: $unmarkedTotal unmarked members on '
        '${_dayShort(sat)} — console: please chase the admins');
  }

  /// Monday: for every active member who has not attended for 4+ consecutive
  /// weeks, remind their group admin to reach out personally. Repeats each
  /// Monday while the streak holds; any attendance resets it.
  Future<void> remindAbsentMembers(DateTime monday) async {
    final latestSat = monday.subtract(const Duration(days: 2));
    final byAdmin = <int, List<String>>{};
    var absentTotal = 0;
    for (final user in repo.activeUsers()) {
      if (config.isConsole(user.id)) continue; // the console is the operator
      final streak = repo.consecutiveAbsentWeeks(user.id, latestSat);
      if (streak < 4) continue;
      final admin = repo.groupAdmin(user.group);
      if (admin == null) continue; // no group → nobody responsible
      absentTotal++;
      byAdmin
          .putIfAbsent(admin.id, () => [])
          .add('${user.name} — $streak weeks');
    }
    if (byAdmin.isEmpty) return;

    for (final entry in byAdmin.entries) {
      if (repo.messageSentOnDay(entry.key, 'absent', monday)) continue;
      final list = entry.value.take(6).join('\n');
      final more = entry.value.length > 6
          ? '\n… and ${entry.value.length - 6} more'
          : '';
      try {
        await bot.api.sendMessage(
          ChatID(entry.key),
          messages.msgAbsent(list, more: more),
          parseMode: ParseMode.html,
        );
        repo.markMessageSent(entry.key, 'absent', monday);
      } catch (_) {
        // admin unreachable; the next Monday retries
      }
    }
    LogRing.log(
        'absent: $absentTotal members absent 4+ weeks on '
        '${_dayShort(monday)} — console: please chase the admins');
  }

  /// The full allocation list for one weekend — the `check` tier's status
  /// report, reused by the on-demand button and the Friday-evening push.
  /// [title] overrides the heading (e.g. per-weekend headings in /status).
  String checkListText(DateTime sat, {String? title}) {
    final sb = StringBuffer()
      ..writeln(title ?? '📋 <b>This week\'s allocation</b>');
    final allocations = repo.allocationsForWeekend(sat);
    if (allocations.isEmpty) {
      sb.writeln('\nNo allocation published yet for ${_dayShort(sat)}.');
      return sb.toString();
    }

    final bySession = <int, List<String>>{};
    for (final (u, s) in allocations) {
      bySession.putIfAbsent(s.id, () => []).add(u.name);
    }

    final sessions = repo.sessionsForWeekend(sat)
      ..sort((a, b) => a.start.compareTo(b.start));

    sb.writeln();
    for (final s in sessions) {
      final names = bySession[s.id];
      sb.writeln('• ${sessionLabel(s)}');
      sb.writeln('   ${names == null || names.isEmpty ? '—' : names.join(', ')}');
    }
    return sb.toString();
  }

  /// Friday evening: push the current weekend's full allocation to every
  /// `check`-tier user — a final confirmation list the backend sends
  /// proactively (not a response to their status button).
  Future<void> sendCheckList(DateTime sat) async {
    final text = checkListText(sat);
    final today = config.toLocal(Config.nowUtc());
    var failures = 0;
    for (final user in repo.allUsers()) {
      if (user.memberTier != MemberTier.check) continue;
      try {
        if (repo.messageSentOnDay(user.id, 'checklist', today)) continue;
        await bot.api.sendMessage(
          ChatID(user.id),
          text,
          parseMode: ParseMode.html,
        );
        repo.markMessageSent(user.id, 'checklist', today);
      } catch (_) {
        failures++;
      }
    }
    if (failures > 0) LogRing.log('checklist: $failures sends failed');
  }

  /// Sends (or edits an existing) availability keyboard message to [user].
  Future<void> showAvailability(
    User user,
    RollingWindow w,
    String text,
  ) async {
    final picked = state.picksFor(user.id);
    final keyboard = buildKeyboard(
      w,
      picked,
      now: config.toLocal(Config.nowUtc()),
      holiday: isHolidayWindow(repo, w),
      hasIndicated: repo.hasBundleResponse(w.sat0, user.id),
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
      // held: block & drop, treated as delivered so the prompt/reminder
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

  static String _dayShort(DateTime d) =>
      '${d.day} ${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.month - 1]}';

  static String _fmt(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  /// The single mechanical explanation shown under every picker (prompt,
  /// reminder and repick all pass through [showAvailability]). The prompt
  /// texts themselves stay free of mechanics to avoid duplication.
  String _hint() => 'Tap a session <b>once</b> = backup 🟢 (you can attend '
      'if needed), or <b>twice</b> = booked 🔒. You\'ll get <b>every</b> 🔒 '
      'you book (one per time slot), plus <b>one</b> of your 🟢 backups. '
      'Tap again to unselect.';

  /// Builds the availability inline keyboard for the window's two weekends.
  /// Weekends whose deadline has passed are not offered (locked). Each slot
  /// toggles off ▫️ → offered 🟢 → booked 🔒 → off. Plus Done and Not
  /// available; on a holiday window a "skip me this holiday" opt-out button
  /// is appended. A Cancel button (abort the in-progress repick, keeping the
  /// saved answer) appears at the very bottom only when the member has
  /// already responded to this bundle.
  static InlineKeyboard buildKeyboard(
    RollingWindow w,
    (Set<Slot>, Set<Slot>) picked, {
    bool holiday = false,
    bool hasIndicated = false,
    required DateTime now,
  }) {
    final (want, available) = picked;
    var kb = InlineKeyboard();
    for (final (wi, sat) in [(0, w.sat0), (1, w.sat1)]) {
      if (w.locked(sat, now)) continue; // weekend already locked
      // A non-interactive header naming the date, so the picker says which
      // weekend each slot belongs to. No arbitrary week numbers — the
      // calendar may have breaks between weeks.
      kb = kb
          .text('Sat ${_day(sat)}', 'noop|$wi')
          .row();
      for (final day in Slot.allDays) {
        final dayLabel = day == 'sat' ? 'Sat' : 'Sun';
        for (final slot in Slot.allSlots) {
          final slotLabel = slot == 'am' ? 'AM' : 'PM';
          for (final loc in Slot.allLocations) {
            final key = '$wi:$day:$slot:$loc';
            final mark = want.any((s) => s.encode() == key)
                ? '🔒'
                : available.any((s) => s.encode() == key)
                    ? '🟢'
                    : '▫️';
            final locLabel = loc == 'ocbc' ? 'OCBC' : 'PR';
            // The callback carries the BUNDLE's first Saturday (not the
            // clicked weekend) so a toggle re-renders the same anchored
            // window — the header dates and weekend indexes never shift.
            kb = kb.text(
              '$mark $locLabel $dayLabel $slotLabel',
              'slot|${_satKey(w.sat0)}|$key',
            );
          }
          kb = kb.row();
        }
      }
      kb = kb.row();
    }
    kb = kb
        .text('✅ Done', 'done|${_satKey(w.sat0)}')
        .row()
        .text('❌ Not available', 'no|${_satKey(w.sat0)}');
    if (holiday) {
      kb = kb
          .row()
          .text('🔕 Skip me this holiday', 'holidayout|${_satKey(w.sat0)}');
    }
    if (hasIndicated) {
      kb = kb.row().text('❌ Cancel', 'cancel|${_satKey(w.sat0)}');
    }
    return kb;
  }

  static String _satKey(DateTime sat) =>
      '${sat.year}-${sat.month.toString().padLeft(2, '0')}-'
      '${sat.day.toString().padLeft(2, '0')}';
}
