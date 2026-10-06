part of '../flows.dart';

extension FlowsPresentation on Flows {

  (Map<String, int>, Set<String>) _allocationInfo(
    RollingWindow w,
    int userId,
  ) {
    final counts = <String, int>{};
    final own = <String>{};
    for (final sat in [w.sat0, w.sat1]) {
      for (final (allocatedUser, session) in repo.allocationsForWeekend(sat)) {
        final key = capacityKey(session);
        counts[key] = (counts[key] ?? 0) + 1;
        if (allocatedUser.id == userId) own.add(key);
      }
    }
    return (counts, own);
  }

  Session? _sessionForSlot(RollingWindow w, Slot slot) {
    final weekend = slot.weekendIndex == 0 ? w.sat0 : w.sat1;
    return _sessionForSlotInWeekend(weekend, slot);
  }

  void _clearOverlappingWants(
    Session candidate,
    Slot candidateSlot,
    Set<Slot> want,
  ) {
    want.removeWhere((slot) {
      if (slot == candidateSlot || slot.weekendIndex != candidateSlot.weekendIndex) {
        return false;
      }
      final other = _sessionForSlotInWeekend(candidate.weekendStart, slot);
      return other?.overlaps(candidate) ?? false;
    });
  }

  void _clearOverlaps(
    Session candidate,
    Slot candidateSlot,
    Set<Slot> want,
    Set<Slot> available,
  ) {
    _clearOverlappingWants(candidate, candidateSlot, want);
    available.removeWhere((slot) {
      if (slot == candidateSlot || slot.weekendIndex != candidateSlot.weekendIndex) {
        return false;
      }
      final other = _sessionForSlotInWeekend(candidate.weekendStart, slot);
      return other?.overlaps(candidate) ?? false;
    });
  }

  Session? _sessionForSlotInWeekend(DateTime weekend, Slot slot) {
    for (final session in repo.sessionsForWeekend(weekend)) {
      if (session.day == slot.day &&
          session.slot == slot.slot &&
          session.location == slot.location) {
        return session;
      }
    }
    return null;
  }

  /// Aborts the in-progress /repick: discards the toggles made in this
  /// session and keeps the previously saved availability untouched. The
  /// Cancel button only appears once the member has responded, so there is
  /// always a saved answer to fall back to.
  Future<void> _cancelAvailability(
    Context ctx,
    int userId,
    List<String> parts,
  ) async {
    await ctx.answerCallbackQuery();
    if (parts.length < 2) return;
    state.forgetAvailability(userId);
    state.clearInteractiveMessages(userId);
    try {
      await ctx.editMessageText('Cancelled — your previous answer is kept.');
    } catch (_) {
      // message may be gone; ignore
    }
    await ctx.reply(
      'Your previous availability is kept. '
      'Changed your mind? Send re-pick to update by Friday.',
    );
  }

  Future<void> _saveAvailability(
    Context ctx,
    int userId,
    String sat0Raw,
    bool notAvailable,
  ) async {
    await ctx.answerCallbackQuery();
    state.clearInteractiveMessages(userId);
    final sat0 = DateTime.tryParse(sat0Raw);
    if (sat0 == null) return;
    final w = _windowForSat(sat0);
    final now = config.toLocal(Config.nowUtc());

    final user = repo.findUser(userId);
    if (user == null) return;

    final (want, available) = state.picksFor(userId);
    // Done with nothing selected means the same as "Not available": an
    // explicit "cannot make it" answer, never a "(none)" confirmation.
    final unavailable = notAvailable || (want.isEmpty && available.isEmpty);
    // Save one row per weekend that is still open; locked weekends are left
    // alone (their allocation has already run or is about to).
    var saved = 0;
    for (final (wi, sat) in [(0, w.sat0), (1, w.sat1)]) {
      if (w.locked(sat, now)) continue;
      repo.setAvailability(
        Availability(
          weekendStart: sat,
          userId: userId,
          bundleStart: sat0,
          slots: unavailable
              ? {}
              : available.where((s) => s.weekendIndex == wi).toSet(),
          wantSlots: unavailable
              ? {}
              : want.where((s) => s.weekendIndex == wi).toSet(),
          available: !unavailable,
          updatedAt: now,
        ),
      );
      // Repicking moves the member out of the allocation pool: their
      // previous allocation is revoked and immediately re-decided against
      // the current availability.
      repo.removeAllocationForUser(userId, sat);
      saved++;
    }
    if (saved > 0) repo.setLastPromptState(userId, LastPromptState.responded);
    state.forgetAvailability(userId);
    state.availabilityMessages.remove(userId);

    if (saved == 0) {
      await ctx.reply('Both weekends are already locked — nothing was saved.');
      return;
    }
    // Re-optimize immediately after saving the updated availability.
    await onAvailabilitySaved?.call();

    try {
      await ctx.editMessageText(
        unavailable
            ? 'You indicated <b>not available</b> for the open weekends.'
            : 'Availability saved.',
        parseMode: ParseMode.html,
      );
    } catch (_) {
      // message may be gone; ignore
    }
    await ctx.reply(
      unavailable
          ? messages.msg6()
          : messages.msg3(
              want,
              available,
              immediate: true,
              label: (s) => this._slotLabel(s, w, repo),
            ),
      parseMode: ParseMode.html,
    );
  }

  /// The sharp hour the allocation goes out: the next hour boundary after
  /// [now] (the moment the member indicated). "14:23" -> "3:00 PM".
  @Deprecated('Immediate allocation is the default in v3.2.0.')
  static String nextSharpHourLabel(DateTime now) {
    final h = now.add(const Duration(hours: 1)).hour;
    final hour12 = h % 12 == 0 ? 12 : h % 12;
    final ampm = h < 12 ? 'AM' : 'PM';
    return '$hour12:00 $ampm';
  }

  // ------------------------------------------------------------- helpers

  RollingWindow _currentWindow(Context ctx) {
    final now = config.toLocal(Config.nowUtc());
    return _windowFor(now);
  }

  RollingWindow _windowFor(DateTime now) => scheduleRuntime.window(now);

  RollingWindow _windowForSat(DateTime sat0) =>
      RollingWindow.fromSat0(sat0, schedule: scheduleRuntime.schedule);

  /// Remembers (id, username) from any update so admins can add members by
  /// handle later. If the handle is in the pending queue (added by an admin
  /// before the user ever contacted the bot), the user is auto-registered
  /// right here. Never replies, never errors.
  void _recordSeen(Context ctx, int userId) {
    final username = ctx.from?.username;
    if (username == null || username.isEmpty) return;
    try {
      repo.upsertSeenUser(userId, username);
      _autoRegisterPending(ctx, userId, username);
    } catch (_) {
      // bookkeeping failure should not break the flow
    }
  }

  /// If [username] was added to the pending queue (via /adduser or
  /// /addadmin) before the user ever messaged the bot, register them now.
  void _autoRegisterPending(Context ctx, int userId, String username) {
    if (!repo.isPendingUser(username)) return;
    final pendingRole = repo.pendingRole(username);
    final isAdmin = pendingRole?.isAdmin ?? false;
    final tier = pendingRole?.tier ?? MemberTier.member;
    final notificationPreference =
        pendingRole?.notificationPreference ?? NotificationPreference.weekly;

    final existing = repo.findUser(userId);
    if (existing?.memberTier == MemberTier.outMember && isAdmin) {
      repo.removePendingUser(username);
      ctx.reply('Out-members cannot be promoted to admin.');
      return;
    }
    repo.removePendingUser(username);

    if (existing == null) {
      repo.upsertUser(
        User(
          id: userId,
          name: '@$username',
          experience: Experience.newbie,
          group: '',
          memberTier: tier,
          notificationPreference: notificationPreference,
        ),
      );
      if (isAdmin) repo.setTier(userId, MemberTier.admin);
    } else if (!existing.isGlobalAdmin) {
      repo.setTier(
        userId,
        isAdmin ? MemberTier.admin : tier,
      );
    }
    // /start provides the role-aware welcome and grid itself. Other first
    // contacts still receive them here after being auto-registered.
    final messageText = ctx.message?.text;
    if (messageText?.trim().startsWith('/start') ?? false) return;
    // Let the user know they're in — they can now use /start.
    final isCheck = tier == MemberTier.check && !isAdmin;
    final isOutMember = tier == MemberTier.outMember && !isAdmin;
    ctx.reply(
      isAdmin
          ? 'Welcome! You have been added as an <b>admin</b>. Send /start to see your commands.'
          : isCheck
          ? 'Welcome! You have been added as a <b>checker</b>. Send /start to see your commands.'
          : isOutMember
          ? 'Welcome! You have been added as an <b>out-member</b>. Send /start to see your commands.'
          : 'Welcome! You have been added. Send /start to see your commands.',
      parseMode: ParseMode.html,
      replyMarkup: RoleKeyboard.build(
        isAdmin
            ? 'admin'
            : isCheck
            ? 'check'
            : isOutMember
            ? MemberTier.outMember
            : 'member',
      ),
    );
  }

}
