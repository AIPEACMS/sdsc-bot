part of '../service.dart';

mixin _CycleService1 on _CycleServiceBase {

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
    final joinedRecently =
        user.registeredAt == null ||
        Config.nowUtc().difference(user.registeredAt!.toUtc()) <
            const Duration(days: 14);
    final year = repo.latestCalendarYear();
    final sem = year?.semesterAt(w.sat0);
    final semesterMature =
        sem?.firstStart != null &&
        w.sat0.difference(sem!.firstStart!) >= const Duration(days: 14);
    if (!joinedRecently &&
        semesterMature &&
        !repo.hasAttendedInPastDays(user.id, 14)) {
      return messages.msg1A(user.group);
    }
    return messages.msg1(user.group);
  }

  /// The holiday a member has opted out of for this availability window.
  Holiday? optedOutHolidayFor(User user, RollingWindow w) {
    final holiday = repo.holidayOn(w.sat0) ?? repo.holidayOn(w.sat1);
    if (holiday != null && repo.hasHolidayOptout(user.id, holiday.weekStart)) {
      return holiday;
    }
    return null;
  }

  /// Reminder text for [user], or null when they opted out of the holiday.
  String? reminderFor(User user, RollingWindow w) =>
      optedOutHolidayFor(user, w) == null ? messages.msg2(user.group) : null;

  /// Human-readable period for an opted-out holiday, Monday through Sunday.
  String holidayPeriod(Holiday holiday) =>
      '${_dayShort(holiday.weekStart)} to '
      '${_dayShort(holiday.weekStart.add(const Duration(days: 6)))}';

  /// Sends the availability picker for [window] to every prompt target.
  Future<void> sendPrompts(RollingWindow w) async {
    var failures = 0;
    var suppressed = 0;
    final today = config.toLocal(Config.nowUtc());
    for (final user in repo.promptTargets(w.sat0)) {
      if (!repo.activeOutreachEnabled('prompt')) {
        suppressed++;
        continue;
      }
      if (repo.isQuiet(user.id, w.sat0)) {
        if (user.notificationPreference == NotificationPreference.everyOther) {
          repo.setLastPromptState(user.id, LastPromptState.none);
        }
        continue;
      }
      if (!_shouldPrompt(user)) {
        if (user.notificationPreference == NotificationPreference.everyOther &&
            !repo.messageSentOnDay(user.id, 'prompt', today)) {
          repo.setLastPromptState(user.id, LastPromptState.none);
        }
        continue;
      }
      try {
        // Never send the same prompt to the same user twice in one day.
        if (repo.messageSentOnDay(user.id, 'prompt', today)) continue;
        final text = promptFor(user, w);
        if (text == null) continue; // opted out of this holiday
        await showAvailability(user, w, text);
        repo.markMessageSent(user.id, 'prompt', today);
        repo.setLastPromptState(user.id, LastPromptState.prompted);
      } catch (_) {
        failures++; // member may have blocked the bot
      }
    }
    if (failures > 0) LogRing.log('prompt: $failures members unreachable');
    if (suppressed > 0) LogRing.log('prompt: suppressed $suppressed members (route disabled)');
  }

  /// Reminds the bundle's non-responders (and not the quiet).
  Future<void> sendReminders(RollingWindow w) async {
    var failures = 0;
    var suppressed = 0;
    final today = config.toLocal(Config.nowUtc());
    for (final user in repo.reminderTargets(w.sat0)) {
      if (!repo.activeOutreachEnabled('reminder')) {
        suppressed++;
        continue;
      }
      if (!_shouldRemind(user)) continue;
      try {
        if (repo.messageSentOnDay(user.id, 'reminder', today)) continue;
        final text = reminderFor(user, w);
        if (text == null) continue;
        await showAvailability(user, w, text);
        repo.markMessageSent(user.id, 'reminder', today);
      } catch (_) {
        failures++;
      }
    }
    if (failures > 0) LogRing.log('remind: $failures members unreachable');
    if (suppressed > 0) LogRing.log('remind: suppressed $suppressed members (route disabled)');
  }

  /// Every-other preference uses the durable prompt state as a two-cycle
  /// toggle. A prompt or response occupies one cycle; the next skipped cycle
  /// clears it so the following weekly prompt is delivered.
  bool _shouldPrompt(User user) => switch (user.notificationPreference) {
    NotificationPreference.weekly => true,
    NotificationPreference.never => false,
    NotificationPreference.everyOther =>
      user.lastPromptState != LastPromptState.prompted &&
          user.lastPromptState != LastPromptState.responded,
  }

;

  bool _shouldRemind(User user) => switch (user.notificationPreference) {
    NotificationPreference.weekly => true,
    NotificationPreference.never => false,
    NotificationPreference.everyOther =>
      user.lastPromptState == LastPromptState.prompted ||
          user.lastPromptState == LastPromptState.responded,
  }

;

  /// Whether this window's weekends fall on a holiday week.
  static bool isHolidayWindow(Repo repo, RollingWindow w) =>
      repo.holidayOn(w.sat0) != null || repo.holidayOn(w.sat1) != null;

  static List<Holiday> holidaysForWindow(Repo repo, RollingWindow w) {
    final result = <Holiday>[];
    for (final sat in [w.sat0, w.sat1]) {
      final holiday = repo.holidayOn(sat);
      if (holiday != null &&
          !result.any((old) => old.kind == holiday.kind)) {
        result.add(holiday);
      }
    }
    return result;
  }

  static String holidayName(HolidayKind kind) => switch (kind) {
        HolidayKind.middle => 'recess week',
        HolidayKind.winter => 'winter holiday',
        HolidayKind.summer => 'summer holiday',
      }

;

  /// Allocates both weekends of [window] as one bundle. Every booked pick is
  /// honored, but a member receives at most one backup pick across both dates.
  /// Already-selected backups are retained in chronological order so an older
  /// per-weekend run is reconciled down to one backup without moving it.
  Future<void> allocateBundle(RollingWindow window) async {
    final weekends = [window.sat0, window.sat1];
    for (final sat in weekends) {
      repo.ensureSessionsForWeekend(
        sat,
        repo.scheduleForWeekend(sat),
        tzOffsetHours: config.timezoneOffsetHours,
      );
    }
    final sessions = [
      for (final sat in weekends) ...repo.sessionsForWeekend(sat),
    ];
    // Only active users can be allocated; check/old users have no availability
    // and stale availability rows must not make them candidates.
    final activeUsers = repo.activeUsers();
    final activeIds = {for (final u in activeUsers) u.id};
    final availability = [
      for (final sat in weekends) ...repo.availabilityForWeekend(sat),
    ].where((a) => activeIds.contains(a.userId)).toList();
    final users = {for (final u in activeUsers) u.id: u};

    final existing = [
      for (final sat in weekends) ...repo.allocationsForWeekend(sat),
    ]..sort((a, b) => a.$2.start.compareTo(b.$2.start));
    final locked = <(int, int)>[];
    final lockedBackupUserIds = <int>{};
    for (final (user, session) in existing) {
      final row = availability
          .where(
            (a) =>
                a.userId == user.id && a.weekendStart == session.weekendStart,
          )
          .firstOrNull;
      final isBackup =
          row?.slots.any((slot) => _matches(session, slot)) ?? false;
      if (!isBackup || lockedBackupUserIds.add(user.id)) {
        locked.add((user.id, session.id));
      }
    }

    final result = const Allocator().run(
      sessions: sessions,
      availability: availability,
      users: users,
      locked: locked,
      lockedBackupUserIds: lockedBackupUserIds,
    );

    final sessionsById = {for (final s in sessions) s.id: s};
    for (final sat in weekends) {
      final weekendResult = result.where((entry) {
        final session = sessionsById[entry.$2];
        return session?.weekendStart == sat;
      }).toList();
      repo.replaceAllocationsForWeekend(sat, weekendResult);
      repo.markWeekendAllocated(sat);
    }

    // Before the weekend's Friday deadline the member can still re-pick;
    // after it they must message the contact instead.
    final now = config.toLocal(Config.nowUtc());
    // Notify only the newly allocated — locked members were notified when
    // they were allocated.
    var failures = 0;
    var suppressed = 0;
    for (final (userId, sessionId) in result) {
      if (locked.any((l) => l.$1 == userId && l.$2 == sessionId)) continue;
      final session = sessionsById[sessionId];
      final user = users[userId];
      if (session == null || user == null) continue;
      if (!repo.activeOutreachEnabled('allocation')) {
        suppressed++;
        continue;
      }
      final deadline = window.deadlineFor(session.weekendStart);
      final deadlinePassed = !now.isBefore(deadline);
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
    if (suppressed > 0) LogRing.log('allocate: suppressed $suppressed notices (route disabled)');
  }

  static bool _matches(Session session, Slot slot) =>
      session.day == slot.day &&
      session.slot == slot.slot &&
      session.location == slot.location;

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
    final user = repo.findUser(userId);
    if (user == null || user.memberTier == MemberTier.outMember) return;
    repo.setAttendanceState(userId, sessionId, attended: attended);
    final session = repo.sessionById(sessionId);
    if (session == null) return;
    final streak = session.location == Locations.ocbc ? user.ocbcStreak + 1 : 0;
    repo.setOcbcStreak(userId, streak);
  }

}
