part of '../admin.dart';

extension AdminUsers on Admin {

  // ----------------------------------------------------------- /status

  Future<void> _status(Context ctx, {String? group}) async {
    final w = this._window();
    final users = repo
        .activeUsers()
        .where((user) => group == null || user.group == group)
        .toList();
    final activeIds = {for (final u in users) u.id};
    final avail = [
      ...repo.availabilityForWeekend(w.sat0),
      ...repo.availabilityForWeekend(w.sat1),
    ].where((a) => activeIds.contains(a.userId));
    // One member responding to both weekends has two rows — count distinct
    // responders, not rows.
    final responderIds = <int>{for (final a in avail) a.userId};
    final responders = responderIds.length;
    final pending = repo
        .reminderTargets(w.sat0)
        .where((user) => activeIds.contains(user.id))
        .toList();

    final sb = StringBuffer()
      ..writeln(
        '📊 <b>${group == null ? 'All members' : 'Group $group'} status</b>',
      )
      ..writeln('Bundle: "${this._day(w.sat0)}, ${this._day(w.sat1)}"')
      ..writeln(
        'Prompt: ${this._day(w.promptDay)}  |  '
        'Reminder: ${this._day(w.reminderDay)}  |  '
        'Lock W1: ${this._day(w.deadline0)}  |  '
        'Lock W2: ${this._day(w.deadline1)}',
      )
      ..writeln('Registered members: ${users.length}')
      ..writeln('Responded: $responders/${users.length}');

    final attendanceUsers =
        users.where((user) => user.memberTier != MemberTier.outMember).toList();
    if (attendanceUsers.isNotEmpty) {
      sb.writeln('\n<b>Last attendance</b>');
      for (final user in attendanceUsers) {
        final last = repo.lastAttendedDate(user.id);
        sb.writeln(
          '• ${_displayName(user)} — last attend: '
          '${last == null ? 'never' : _day(last)}',
        );
      }
    }

    // Everyone registered is accounted for: the members who still need to
    // answer, plus the ones the quiet rule skips because they answered a
    // recent bundle (they were not prompted this cycle).
    final quiet = users
        .where(
          (u) => !responderIds.contains(u.id) && repo.isQuiet(u.id, w.sat0),
        )
        .toList();
    if (pending.isNotEmpty) {
      sb.writeln(
        '⏳ Still to respond (${pending.length}): '
        '${pending.map(_displayName).join(', ')}',
      );
    }
    if (quiet.isNotEmpty) {
      sb.writeln(
        '💤 Not prompted this cycle — answered recently '
        '(${quiet.length}): ${quiet.map(_displayName).join(', ')}',
      );
    }
    if (pending.isEmpty && quiet.isEmpty) {
      sb.writeln('✅ Everyone has answered this bundle.');
    }

    // The full allocation table for both weekends of the bundle — the same
    // per-session list the check tier sees, so admins can check who is on
    // what session without the console app.
    sb.writeln();
    sb.write(
      service.checkListText(
        w.sat0,
        title: '📋 <b>Allocation · ${this._day(w.sat0)}</b>',
        userIds: group == null ? null : activeIds,
      ),
    );
    sb.writeln();
    sb.write(
      service.checkListText(
        w.sat1,
        title: '📋 <b>Allocation · ${this._day(w.sat1)}</b>',
        userIds: group == null ? null : activeIds,
      ),
    );
    await ctx.reply(sb.toString(), parseMode: ParseMode.html);
  }

  Future<void> _groupStatus(Context ctx) async {
    final group = this._adminGroup(ctx);
    if (group.isEmpty) {
      await ctx.reply('You are not assigned to a group.');
      return;
    }
    await _status(ctx, group: group);
  }

  Future<void> _users(
    Context ctx, {
    String? group,
  }) async {
    final users = repo.allUsers().where((u) {
      // Archived users are retained for recovery but not shown in Telegram
      // roster views.
      if (u.memberTier == MemberTier.old) return false;
      if (group != null && u.group != group) return false;
      return true;
    }).toList()
      ..sort((a, b) {
        final tierComparison = _displayTierRank(a).compareTo(
          _displayTierRank(b),
        );
        if (tierComparison != 0) return tierComparison;
        return _displayName(a).compareTo(_displayName(b));
      });
    final lines = users.map((u) {
      final tier = _displayTier(u);
      final outMember = u.memberTier == MemberTier.outMember;
      final exp = u.experience == Experience.experienced ? 'exp' : 'new';
      final stats = outMember ? null : repo.attendanceStats(u.id);
      final byLoc = stats?.byLocation.entries
              .where((e) => e.value > 0)
              .map((e) => '${e.value} ${repo.locationName(e.key)}')
              .join(', ') ??
          '';
      final detail = outMember
          ? 'notifications ${_notificationLabel(u.notificationPreference)}'
          : '$exp${byLoc.isEmpty ? '' : ', $byLoc'}';
      return '• <b>${_displayName(u)}</b>\n   ($tier, '
          'group ${u.group.isEmpty ? 'none' : u.group}, $detail)';
    });
    await ctx.reply(
      '<b>${group == null ? 'All users' : 'Group $group users'} '
      '(${users.length})</b>\n${lines.join('\n')}',
      parseMode: ParseMode.html,
    );
  }

  String _displayTier(User user) {
    if (user.isGlobalAdmin) return MemberTier.globalAdmin;
    if (user.isAdmin) return MemberTier.admin;
    return user.memberTier;
  }

  String _notificationLabel(NotificationPreference preference) =>
      switch (preference) {
        NotificationPreference.weekly => 'weekly',
        NotificationPreference.everyOther => 'every other week',
        NotificationPreference.never => 'never',
      }

;

  int _displayTierRank(User user) {
    final index = MemberTier.order.indexOf(_displayTier(user));
    return index < 0 ? MemberTier.order.length : index;
  }

  Future<void> _groupUsers(Context ctx) async {
    final group = this._adminGroup(ctx);
    if (group.isEmpty) {
      await ctx.reply('You are not assigned to a group.');
      return;
    }
    await _users(ctx, group: group);
  }

  String _displayName(User user) {
    final human = user.preferredName;
    if (human.isEmpty) return _html(user.name);
    return '${_html(human)} ${_html(user.name)}';
  }

  String _html(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  // ------------------------------------------------- /prompt /remind confirm

  /// /prompt asks for confirmation before messaging everyone.
  Future<void> _promptConfirm(Context ctx) async {
    await ctx.reply(
      '📣 Send availability prompts to all members now?',
      replyMarkup: Pickers.confirm('prompt'),
    );
  }

  /// /remind asks for confirmation before messaging non-responders.
  Future<void> _remindConfirm(Context ctx) async {
    await ctx.reply(
      '⏰ Remind non-responders now?',
      replyMarkup: Pickers.confirm('remind'),
    );
  }

  // ------------------------------------------------------------- /ask

  Future<void> _ask(Context ctx) async {
    final args = ctx.args;
    if (args.isEmpty) {
      await _askPicker(ctx, 0);
      return;
    }
    final id = int.tryParse(args.first);
    final user = id == null ? null : repo.findUser(id);
    if (user == null || user.memberTier == MemberTier.outMember) {
      await ctx.reply('Unknown user id.');
      return;
    }
    final result = await _sendAsk(ctx, user);
    if (!result.$2) await ctx.reply(result.$1);
  }

  Future<void> _askPicker(Context ctx, int page) async {
    final members = repo
        .activeUsers()
        .where((u) => u.memberTier != MemberTier.outMember)
        .toList();
    if (members.isEmpty) {
      await ctx.reply('No members yet. Add some with /adduser.');
      return;
    }
    await ctx.reply(
      '🤔 Send the availability picker to which member?',
      replyMarkup: Pickers.memberPicker(
        action: 'ask',
        members: members,
        page: page,
      ),
    );
  }

  Future<void> _askPick(Context ctx, int memberId) async {
    await ctx.answerCallbackQuery();
    final user = repo.findUser(memberId);
    if (user == null || user.memberTier == MemberTier.outMember) return;
    final result = await _sendAsk(ctx, user);
    await ctx.editMessageText(result.$1);
  }

  /// Sends an individual picker only while the current availability window is
  /// open. Early-week asks use prompt text; late-week asks use reminder text.
  Future<(String, bool)> _sendAsk(Context ctx, User user) async {
    if (user.memberTier == MemberTier.outMember) {
      return ('Out-members are not included in /ask.', false);
    }
    if (!repo.activeOutreachEnabled('ask')) {
      LogRing.log('ask: suppressed 1 delivery (route disabled)');
      return ('Ask delivery is disabled. No availability picker was sent.', false);
    }
    final now = config.toLocal(Config.nowUtc());
    final w = this._window();
    final holiday = service.optedOutHolidayFor(user, w);
    if (holiday != null) {
      return (
        '${user.name} opted out of the holiday from '
            '${service.holidayPeriod(holiday)}. No availability picker was sent.',
        false,
      );
    }
    if (!now.isBefore(w.deadline0)) {
      return (
        'Availability is closed for this window. No availability picker was '
            'sent to ${user.name}.',
        false,
      );
    }
    final text = now.isBefore(w.reminderDay)
        ? service.promptFor(user, w)!
        : service.reminderFor(user, w)!;
    await service.showAvailability(user, w, text);
    return ('✅ Availability picker sent to ${user.name}.', true);
  }

  // ----------------------------------------------------------- /confirm

  /// The weekend /confirm marks: the current week's Saturday from 00:00
  /// Saturday onward; before that, the previous Saturday (the week just
  /// finished) can still be marked.
  DateTime _currentWeekendSat() {
    final now = config.toLocal(Config.nowUtc());
    final w = this._windowFor(now);
    return now.isBefore(w.sat0)
        ? w.sat0.subtract(const Duration(days: 7))
        : w.sat0;
  }

}
