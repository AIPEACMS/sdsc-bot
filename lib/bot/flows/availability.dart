part of '../flows.dart';

mixin _Flows2 on Flows {

  // ------------------------------------------------------------- /grid

  /// Console-only: cycle through the console/admin/check/member grids to
  /// preview what each role sees. Type /grid again to step to the next grid,
  /// or /resetgrid to return to the console's own grid.
  Future<void> _onGrid(Context ctx) async {
    final userId = ctx.from!.id;
    _recordSeen(ctx, userId);

    if (!config.isConsole(userId)) {
      await ctx.reply(
        'Only the console can preview other grids.',
        replyMarkup: RoleKeyboard.build(_gridFor(userId)),
      );
      return;
    }

    final ownUser = repo.findUser(userId);
    final ownGrid = RoleKeyboard.roleFor(
      isConsole: true,
      isGlobalAdmin: ownUser?.isGlobalAdmin ?? false,
      isAdmin: ownUser?.isAdmin ?? false,
      tier: ownUser?.memberTier,
    );
    final order = <String>{
      ownGrid,
      'gadmin',
      'admin',
      'check',
      'member',
      MemberTier.outMember,
      'old',
      'console-only',
    }.toList();
    final current = state.gridPreview[userId] ?? ownGrid;
    final next = order[(order.indexOf(current) + 1) % order.length];
    state.gridPreview[userId] = next;

    await ctx.reply(
      '👀 <b>Preview: $next grid</b>\n'
      'This is what a $next sees. Type /grid again to cycle to the next '
      'grid, or /resetgrid to return to your own console grid.',
      parseMode: ParseMode.html,
      replyMarkup: RoleKeyboard.build(next),
    );
  }

  /// Console-only: drop the grid preview and return to the console's own
  /// grid.
  Future<void> _onResetGrid(Context ctx) async {
    final userId = ctx.from!.id;
    _recordSeen(ctx, userId);

    if (!config.isConsole(userId)) {
      await ctx.reply(
        'Only the console can reset the grid preview.',
        replyMarkup: RoleKeyboard.build(_gridFor(userId)),
      );
      return;
    }

    state.gridPreview.remove(userId);
    final user = repo.findUser(userId);
    final ownGrid = RoleKeyboard.roleFor(
      isConsole: true,
      isGlobalAdmin: user?.isGlobalAdmin ?? false,
      isAdmin: user?.isAdmin ?? false,
      tier: user?.memberTier,
    );
    await ctx.reply(
      'Back to your console grid.',
      replyMarkup: RoleKeyboard.build(ownGrid, consoleIdentity: true),
    );
  }

  /// Which grid to show: the console's preview if set, otherwise the
  /// highest-tier grid.
  String _gridFor(int userId) {
    if (config.isConsole(userId) && state.gridPreview[userId] != null) {
      return state.gridPreview[userId]!;
    }
    final user = repo.findUser(userId);
    return RoleKeyboard.roleFor(
      isConsole: config.isConsole(userId),
      isGlobalAdmin: user?.isGlobalAdmin ?? false,
      isAdmin: user?.isAdmin ?? false,
      tier: user?.memberTier,
    );
  }

  // ------------------------------------------------------------ /repick

  Future<void> _onRepick(Context ctx) async {
    final userId = ctx.from!.id;
    LogRing.log('repick $userId: handler entered');
    final user = repo.findUser(userId);
    if (user == null || !_isActive(user)) {
      // Silent for unadded and non-active (check/old) users.
      LogRing.log('repick $userId: ignored (not an active member)');
      return;
    }
    final window = _currentWindow(ctx);
    state.forgetAvailability(userId);
    LogRing.log('repick $userId: opening availability picker');
    await service.showAvailability(user, window, messages.msg1(user.group));
    LogRing.log('repick $userId: availability picker completed');
  }

  Future<void> _dismissInteractiveMessages(int userId) async {
    state.forgetAvailability(userId);
    state.cancelInputFlow(userId);
    for (final (chatId, messageId) in state.takeInteractiveMessages(userId)) {
      try {
        await bot.api.editMessageReplyMarkup(
          ChatID(chatId),
          messageId,
          replyMarkup: null,
        );
      } catch (_) {
        // The message may already be gone or have been closed by a callback.
      }
    }
    state.availabilityMessages.remove(userId);
  }

  /// True for members/admins/console — anyone with availability duties.
  bool _isActive(User user) {
    return MemberTier.isActive(user.memberTier);
  }

  // ------------------------------------------------------- /mystatus

  /// Member-facing status: what they indicated, what they are allocated to,
  /// and their attendance (total + per location).
  Future<void> _onMyStatus(Context ctx) async {
    final userId = ctx.from!.id;
    _recordSeen(ctx, userId);
    final user = repo.findUser(userId);
    if (user == null || !_isActive(user)) return;
    final w = _currentWindow(ctx);

    final sb = StringBuffer()
      ..writeln('👤 <b>Your information</b>')
      ..writeln('Preferred name: ${_html(user.preferredName)}')
      ..writeln('\n📋 <b>Your status</b>')
      ..writeln('Bundle: "${_day(w.sat0)}, ${_day(w.sat1)}"');

    final avail0 = repo.getAvailability(w.sat0, userId);
    final avail1 = repo.getAvailability(w.sat1, userId);
    final want = <Slot>{};
    final avail = <Slot>{};
    if (avail0 != null && avail0.available) {
      want.addAll(avail0.wantSlots);
      avail.addAll(avail0.slots);
    }
    if (avail1 != null && avail1.available) {
      want.addAll(avail1.wantSlots);
      avail.addAll(avail1.slots);
    }
    final unavailableDates = [
      if (avail0 != null && !avail0.available) _day(w.sat0),
      if (avail1 != null && !avail1.available) _day(w.sat1),
    ];
    if (want.isNotEmpty || avail.isNotEmpty) {
      sb.writeln('\n<b>Indicated</b> — 🔒 booked · 🟢 backup:');
      if (want.isNotEmpty) {
        sb.writeln(
          want.map((s) => '🔒 ${_slotLabel(s, w, repo)}').join('\n'),
        );
      }
      if (avail.isNotEmpty) {
        sb.writeln(
          avail.map((s) => '🟢 ${_slotLabel(s, w, repo)}').join('\n'),
        );
      }
    } else if (unavailableDates.isNotEmpty) {
      sb.writeln(
        '\n<b>Indicated not available</b>: '
        '${unavailableDates.join(', ')}.',
      );
    } else {
      sb.writeln('\n<b>Indicated</b>: none yet.');
    }

    final allocated =
        [
              ...repo.allocationsForWeekend(w.sat0),
              ...repo.allocationsForWeekend(w.sat1),
            ]
            .where((a) => a.$1.id == userId)
            .map((a) => '• ${service.sessionLabel(a.$2)}')
            .join('\n');
    if (allocated.isNotEmpty) {
      sb.writeln('\n<b>Allocated</b>:\n$allocated');
    } else {
      sb.writeln(
        '\n<b>Allocated</b>: not yet — this weekend locks Friday '
        '18:00, next weekend the Friday after.',
      );
    }

    if (user.memberTier != MemberTier.outMember) {
      final stats = repo.attendanceStats(userId);
      final byLoc = stats.byLocation.entries
          .where((e) => e.value > 0)
          .map((e) => '${e.value} ${repo.locationName(e.key)}')
          .join(' · ');
      sb.writeln(
        '\n<b>Attendance</b>: ${stats.total} sessions total'
        '${byLoc.isEmpty ? '' : ' ($byLoc)'}.',
      );
    }

    await ctx.reply(sb.toString(), parseMode: ParseMode.html);
  }

  // ------------------------------------------------------------- /notify

  Future<void> _onNotify(Context ctx) async {
    final userId = ctx.from!.id;
    _recordSeen(ctx, userId);
    final user = repo.findUser(userId);
    if (user == null || user.memberTier != MemberTier.outMember) {
      await ctx.reply('Only out-members can change notification frequency.');
      return;
    }
    final args = ctx.args;
    if (args.isNotEmpty) {
      final preference = _parseNotificationPreference(args.first);
      if (preference == null) {
        await ctx.reply(_notifyUsage());
        return;
      }
      await _saveNotificationPreference(ctx, userId, preference);
      return;
    }

    var keyboard = InlineKeyboard();
    keyboard = keyboard
        .text('Every week', 'notify|weekly')
        .row()
        .text('Every other week', 'notify|every-other')
        .row()
        .text('Never', 'notify|never');
    await ctx.reply(
      'How often should I send the weekly availability prompt?',
      replyMarkup: keyboard,
    );
  }

  Future<void> _onNotifyCallback(Context ctx) async {
    final userId = ctx.from!.id;
    final parts = (ctx.callbackQuery?.data ?? '').split('|');
    final preference = parts.length > 1
        ? _parseNotificationPreference(parts[1])
        : null;
    await ctx.answerCallbackQuery();
    if (preference == null) {
      await ctx.editMessageText(_notifyUsage());
      return;
    }
    final user = repo.findUser(userId);
    if (user == null || user.memberTier != MemberTier.outMember) {
      await ctx.editMessageText(
        'Only out-members can change notification frequency.',
      );
      return;
    }
    await _saveNotificationPreference(ctx, userId, preference, edit: true);
  }

  Future<void> _saveNotificationPreference(
    Context ctx,
    int userId,
    NotificationPreference preference, {
    bool edit = false,
  }) async {
    repo.setNotificationPreference(userId, preference);
    final text = '✅ Notification preference: ${_notificationLabel(preference)}.';
    if (edit) {
      await ctx.editMessageText(text);
    } else {
      await ctx.reply(text);
    }
  }

}
