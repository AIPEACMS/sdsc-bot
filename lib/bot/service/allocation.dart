part of '../service.dart';

extension CycleServiceAllocation on CycleService {

  /// Sunday/Monday attendance-marking reminders: for every allocated member
  /// of [sat]'s weekend with no attendance mark yet, remind the member's
  /// group admin. The console is notified via the log ring on the second day.
  Future<void> remindAttendanceMarking(DateTime sat, DateTime day) async {
    final sessions = repo.sessionsForWeekend(sat);
    var unmarkedTotal = 0;
    final byAdmin = <int, List<String>>{};
    for (final s in sessions) {
      final allocations = repo
          .allocationsForWeekend(sat)
          .where((a) => a.$2.id == s.id);
      final marked = repo
          .attendanceForSession(s.id)
          .map((a) => a.userId)
          .toSet();
      for (final (user, _) in allocations) {
        if (user.memberTier == MemberTier.outMember) continue;
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
    if (!repo.activeOutreachEnabled('attendance')) {
      LogRing.log('attmark: suppressed $unmarkedTotal reminders (route disabled)');
      return;
    }

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
      '${_dayShort(sat)} — console: please chase the admins',
    );
  }

  /// Monday: for every active member who has not attended for 4+ consecutive
  /// weeks, remind their group admin to reach out personally. Repeats each
  /// Monday while the streak holds; any attendance resets it.
  Future<void> remindAbsentMembers(DateTime monday) async {
    final latestSat = monday.subtract(const Duration(days: 2));
    final byAdmin = <int, List<String>>{};
    var absentTotal = 0;
    for (final user in repo.activeUsers()) {
      if (user.memberTier == MemberTier.outMember) continue;
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
    if (!repo.activeOutreachEnabled('absence')) {
      LogRing.log('absent: suppressed $absentTotal reminders (route disabled)');
      return;
    }

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
      '${_dayShort(monday)} — console: please chase the admins',
    );
  }

  /// The full allocation list for one weekend — the `check` tier's status
  /// report, reused by the on-demand button and the Friday-evening push.
  /// [title] overrides the heading (e.g. per-weekend headings in /status).
  String checkListText(DateTime sat, {String? title, Set<int>? userIds}) {
    final sb = StringBuffer()
      ..writeln(title ?? '📋 <b>This week\'s allocation</b>');
    final allocations = repo.allocationsForWeekend(sat);
    if (allocations.isEmpty) {
      sb.writeln('\nNo allocation published yet for ${_dayShort(sat)}.');
      return sb.toString();
    }

    final bySession = <int, List<String>>{};
    for (final (u, s) in allocations) {
      if (userIds != null && !userIds.contains(u.id)) continue;
       bySession.putIfAbsent(s.id, () => []).add(CycleServiceNotifications._displayName(u));
    }

    final sessions = repo.sessionsForWeekend(sat)
      ..sort((a, b) => a.start.compareTo(b.start));

    sb.writeln();
    for (final s in sessions) {
      final names = bySession[s.id];
      sb.writeln('• ${sessionLabel(s)}');
      sb.writeln(
        '   ${names == null || names.isEmpty ? '—' : names.join(', ')}',
      );
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
    var suppressed = 0;
    for (final user in repo.allUsers()) {
      if (user.memberTier != MemberTier.check) continue;
      if (!repo.activeOutreachEnabled('checker')) {
        suppressed++;
        continue;
      }
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
    if (suppressed > 0) LogRing.log('checklist: suppressed $suppressed sends (route disabled)');
  }

  /// Sends (or edits an existing) availability keyboard message to [user].
  Future<void> showAvailability(User user, RollingWindow w, String text) async {
    // The window's sessions must exist before we can render them.
    for (final sat in [w.sat0, w.sat1]) {
      repo.ensureSessionsForWeekend(
        sat,
        repo.scheduleForWeekend(sat),
        tzOffsetHours: config.timezoneOffsetHours,
      );
    }
    final picked = state.picksFor(user.id);
    final allocatedCounts = <String, int>{};
    final ownCapacityGroups = <String>{};
    for (final sat in [w.sat0, w.sat1]) {
      for (final (allocatedUser, session) in repo.allocationsForWeekend(sat)) {
        final key = capacityKey(session);
        allocatedCounts[key] = (allocatedCounts[key] ?? 0) + 1;
        if (allocatedUser.id == user.id) ownCapacityGroups.add(key);
      }
    }
    final keyboard = CycleServiceNotifications.buildKeyboard(
      w,
      picked,
      now: config.toLocal(Config.nowUtc()),
        holidays: CycleServicePrompts.holidaysForWindow(repo, w),
      allocatedCounts: allocatedCounts,
      ownCapacityGroups: ownCapacityGroups,
      hasIndicated: repo.hasBundleResponse(w.sat0, user.id),
      sessions: [
        ...repo.sessionsForWeekend(w.sat0),
        ...repo.sessionsForWeekend(w.sat1),
      ],
      locationName: repo.locationName,
    );

    final pickerText = '$text\n\n${_hint()}';
    final existing = state.availabilityMessages[user.id];
    if (existing != null) {
      try {
        await bot.api.editMessageText(
          ChatID(existing.$1),
          existing.$2,
          pickerText,
          parseMode: ParseMode.html,
          replyMarkup: keyboard,
        );
        LogRing.log(
          'availability ${user.id}: picker edited: '
          '${_logText(pickerText)}',
        );
        return;
      } on HeldException {
        LogRing.log('availability ${user.id}: picker edit dropped (held)');
        return; // held: block & drop, treated as delivered
      } catch (error) {
        LogRing.log('availability ${user.id}: picker edit failed: $error');
        state.availabilityMessages.remove(user.id);
      }
    }

    try {
      final msg = await bot.api.sendMessage(
        ChatID(user.id),
        pickerText,
        parseMode: ParseMode.html,
        replyMarkup: keyboard,
      );
      state.availabilityMessages[user.id] = (user.id, msg.messageId);
      state.trackInteractiveMessage(user.id, user.id, msg.messageId);
      LogRing.log(
        'availability ${user.id}: picker sent: '
        '${_logText(pickerText)}',
      );
    } on HeldException {
      // held: block & drop, treated as delivered so the prompt/reminder
      // flags still advance and nothing is replayed on unhold.
      LogRing.log('availability ${user.id}: picker send dropped (held)');
    } catch (error) {
      LogRing.log('availability ${user.id}: picker send failed: $error');
      rethrow;
    }
  }

  String _logText(String text) {
    final singleLine = text.replaceAll(RegExp(r'\s+'), ' ');
    return singleLine.length <= 160
        ? singleLine
        : '${singleLine.substring(0, 160)}…';
  }

  /// A human label for a session: location, day and time, e.g.
  /// "Pasir Ris · Saturday 09:00-13:00 (21 Sep)".
  String sessionLabel(Session s) {
    final loc = repo.locationName(s.location);
    final day = Slot.dayName(s.day);
    return '$loc · $day ${_fmt(s.start)}-${_fmt(s.end)} (${_day(s.start)})';
  }

  String _day(DateTime d) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${d.day} ${months[d.month - 1]}';
  }

  String _dayShort(DateTime d) =>
      '${d.day} ${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.month - 1]}';

  String _fmt(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  /// The single mechanical explanation shown under every picker (prompt,
  /// reminder and repick all pass through [showAvailability]). The prompt
  /// texts themselves stay free of mechanics to avoid duplication.
  String _hint() =>
      'Tap a session <b>once</b> = backup 🟢 (you can attend '
      'if needed), or <b>twice</b> = booked 🔒. You\'ll get <b>every</b> 🔒 '
      'you book (one per time slot), plus <b>one</b> of your 🟢 backups. '
      'Tap again to unselect.';

}
