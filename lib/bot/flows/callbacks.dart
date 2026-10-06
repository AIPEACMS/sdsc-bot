part of '../flows.dart';

extension FlowsCallbacks on Flows {

  NotificationPreference? _parseNotificationPreference(String raw) {
    return switch (raw.toLowerCase()) {
      'weekly' || 'week' => NotificationPreference.weekly,
      'every-other' || 'every_other' || 'everyother' =>
        NotificationPreference.everyOther,
      'never' => NotificationPreference.never,
      _ => null,
    };
  }

  String _notificationLabel(NotificationPreference preference) =>
      switch (preference) {
        NotificationPreference.weekly => 'every week',
        NotificationPreference.everyOther => 'every other week',
        NotificationPreference.never => 'never',
      }

;

  String _notifyUsage() =>
      'Usage: /notify weekly|every-other|never';

  String _slotLabel(Slot slot, RollingWindow w, Repo repo) {
    final date = slot.weekendIndex == 0 ? w.sat0 : w.sat1;
    final location = repo.locationName(slot.location);
    final match = repo
        .sessionsForWeekend(date)
        .where(
          (s) =>
              s.day == slot.day &&
              s.slot == slot.slot &&
              s.location == slot.location,
        )
        .firstOrNull;
    if (match == null) return '${Slot.dayLabel(slot.day)} · $location';
    return '${Slot.dayLabel(match.day)} · $location · '
        '${_hm(match.start)}-${_hm(match.end)}';
  }

  String _hm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  String _day(DateTime date) {
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
    return '${date.day} ${months[date.month - 1]}';
  }

  String _html(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  // ---------------------------------------------------- /checkstatus

  Future<void> _onCheckStatusCommand(Context ctx) async {
    if (!config.isConsole(ctx.from?.id ?? 0)) {
      await ctx.reply('Only the console can use /checkstatus.');
      return;
    }
    await _onCheckStatus(ctx);
  }

  /// The `check` tier's only button action: print the current weekend's allocation.
  /// The console is allowed too (it may preview the check grid via /grid and
  /// must be able to actually test the output).
  Future<void> _onCheckStatus(Context ctx) async {
    final userId = ctx.from!.id;
    this._recordSeen(ctx, userId);
    final user = repo.findUser(userId);
    final isConsoleUser = config.isConsole(userId);
    if (user == null && !isConsoleUser) return;
    final tier = user == null
        ? null
        : MemberTier.of(user, isConsole: isConsoleUser);
    if (tier != MemberTier.check && !isConsoleUser) {
      await ctx.reply('Only checkers can view the weekly allocation.');
      return;
    }

    final now = config.toLocal(Config.nowUtc());
    final w = this._windowFor(now);

    // "This week": weekend-0 during its week, weekend-1 once we roll over.
    final sat = now.isBefore(w.sat1) ? w.sat0 : w.sat1;
    await ctx.reply(service.checkListText(sat), parseMode: ParseMode.html);
  }

  // ------------------------------------------------------------ text

  /// Routes a wizard's pending-input text to the command that requested it.
  /// `broadcast` = the message to send to every member (handled in admin);
  /// `adduser` = the handle to add (handled in admin);
  /// `setdate` / `synccalendar` = typed console wizard input (in console);
  /// `settime` / `settime-newname` = the gadmin's schedule wizard; `addalias`
  /// = the console's alias wizard.
  Future<void> _consumePendingArg(
    Context ctx,
    int userId,
    String command,
    String text,
  ) async {
    switch (command) {
      case 'broadcast':
        await onBroadcastText?.call(ctx, userId, text);
      case 'adduser':
        await onAddUserText?.call(ctx, userId, text);
      case 'setdate':
        await onSetDateText?.call(ctx, userId, text);
      case 'synccalendar':
        await onSyncCalendarText?.call(ctx, userId, text);
      case 'settime':
        await onSetTimeText?.call(ctx, userId, text);
      case 'settime-newname':
        await onSetTimeNewNameText?.call(ctx, userId, text);
      case 'addalias':
        await onAddAliasText?.call(ctx, userId, text);
      default:
        await ctx.reply('That input is not understood. Start over.');
    }
  }

  /// Set by main.dart: handles the pending "type the message" step of
  /// /broadcast (shows the confirm dialog).
  /// Set by main.dart: handles the typed handle of the /adduser wizard
  /// (shows the confirm dialog).
  // ---------------------------------------------------------- callback

  Future<void> _onCallback(Context ctx) async {
    final data = ctx.callbackQuery?.data ?? '';
    if (data.isEmpty) return;
    final parts = data.split('|');
    final userId = ctx.from!.id;
    this._recordSeen(ctx, userId);

    switch (parts[0]) {
      case 'slot':
        await _toggleSlot(ctx, userId, parts);
      case 'done':
        await this._saveAvailability(ctx, userId, parts[1], false);
      case 'no':
        await this._saveAvailability(ctx, userId, parts[1], true);
      case 'cancel':
        await this._cancelAvailability(ctx, userId, parts);
      case 'holidayout':
        await _optOutHoliday(ctx, userId, parts);
      case 'notify':
        await this._onNotifyCallback(ctx);
    }
  }

  Future<void> _optOutHoliday(
    Context ctx,
    int userId,
    List<String> parts,
  ) async {
    await ctx.answerCallbackQuery();
    final sat0Raw = parts.length > 1 ? parts[1] : '';
    final sat0 = DateTime.tryParse(sat0Raw);
    if (sat0 == null) return;
    final kind = parts.length > 2
        ? HolidayKind.values.where((value) => value.name == parts[2]).firstOrNull
        : null;
    final windowHolidays = [sat0, sat0.add(const Duration(days: 7))]
        .map(repo.holidayOn)
        .whereType<Holiday>()
        .where((holiday) => kind == null || holiday.kind == kind)
        .toList();
    final weeks = <DateTime>{};
    for (final holiday in windowHolidays) {
      for (final periodWeek in repo.holidayPeriod(holiday)) {
        weeks.add(periodWeek.weekStart);
      }
    }
    if (weeks.isEmpty) return;
    for (final week in weeks) {
      repo.setHolidayOptout(userId, week);
    }
    // They are out for this holiday: no longer a candidate for allocation.
    state.forgetAvailability(userId);
    final now = config.toLocal(Config.nowUtc());
    for (final week in [sat0, sat0.add(const Duration(days: 7))]) {
      if (!weeks.contains(repo.holidayOn(week)?.weekStart)) continue;
      repo.setAvailability(
        Availability(
          weekendStart: week,
          userId: userId,
          bundleStart: sat0,
          slots: {},
          available: false,
          updatedAt: now,
        ),
      );
    }
    await ctx.editMessageText(messages.msg5Z());
  }

  Future<void> _toggleSlot(Context ctx, int userId, List<String> parts) async {
    await ctx.answerCallbackQuery();
    if (parts.length < 3) return;
    final sat0 = DateTime.tryParse(parts[1]);
    final slot = Slot.parse(parts[2]);
    if (sat0 == null || slot == null) return;
    final w = this._windowForSat(sat0);
    final sat = slot.weekendIndex == 0 ? w.sat0 : w.sat1;
    final now = config.toLocal(Config.nowUtc());
    if (w.locked(sat, now)) {
      await ctx.reply(
        'That weekend\'s availability is already locked — '
        'its Friday deadline passed.',
      );
      return;
    }

    final (want, available) = state.picksFor(userId);
    final session = this._sessionForSlot(w, slot);
    // Toggle cycle: off ▫️ -> offered 🟢 -> booked 🔒 -> off. A newly
    // selected choice wins over overlapping choices in the same weekend:
    // backups may overlap backups, but a booked choice clears every
    // overlapping choice and a new backup clears overlapping booked choices.
    if (want.contains(slot)) {
      want.remove(slot);
    } else if (available.contains(slot)) {
      available.remove(slot);
      if (session != null) this._clearOverlaps(session, slot, want, available);
      want.add(slot);
    } else {
      if (session != null) this._clearOverlappingWants(session, slot, want);
      available.add(slot);
    }

    final text =
        'Your availability — tap <b>once</b> = backup 🟢, '
        '<b>twice</b> = booked 🔒, <b>again</b> = off.\n\n'
        'You\'ll be allocated to <b>every</b> session you book 🔒 '
        '(one per time slot), plus <b>one</b> of your 🟢 backups.';
    try {
      final allocationInfo = _allocationInfo(w, userId);
      await ctx.editMessageText(
        text,
        parseMode: ParseMode.html,
        replyMarkup: CycleServiceNotifications.buildKeyboard(
          w,
          (want, available),
          now: now,
            holidays: CycleServicePrompts.holidaysForWindow(repo, w),
           allocatedCounts: allocationInfo.$1,
           ownCapacityGroups: allocationInfo.$2,
          hasIndicated: repo.hasBundleResponse(sat0, userId),
          sessions: [
            ...repo.sessionsForWeekend(w.sat0),
            ...repo.sessionsForWeekend(w.sat1),
          ],
          locationName: repo.locationName,
        ),
      );
    } catch (_) {
      // message may be gone; ignore
    }
  }

}
