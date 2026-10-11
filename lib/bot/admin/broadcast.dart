part of '../admin.dart';
extension AdminBroadcast on Admin {
  /// The calling admin's group. Empty when the user has no group (e.g. the
  /// console before being added as a member) — then no group filter applies.
  String _adminGroup(Context ctx) {
    final user = repo.findUser(ctx.from?.id ?? 0);
    return user?.group ?? '';
  }
  /// The calling admin's own group only: the /confirm flow is scoped to the
  /// group the admin leads, so a leader never marks (or is reminded about)
  /// another group's members.
  Future<void> _confirm(Context ctx) async {
    final sat = this._currentWeekendSat();
    final sessions = repo.sessionsForWeekend(sat);
    if (sessions.isEmpty) {
      await ctx.reply('No sessions yet. Run /allocate first.');
      return;
    }
    final group = _adminGroup(ctx);
    var kb = InlineKeyboard();
    for (final s in sessions) {
      final mark = _sessionMark(s, group);
      final loc = repo.locationName(s.location);
      kb = kb
          .text(
            '$mark$loc ${Slot.dayLabel(s.day)} '
            '${s.start.hour.toString().padLeft(2, '0')}:'
            '${s.start.minute.toString().padLeft(2, '0')}-'
            '${s.end.hour.toString().padLeft(2, '0')}:'
            '${s.end.minute.toString().padLeft(2, '0')}',
            'att_sess|${s.id}',
          )
          .row();
    }
    kb = kb.text('✅ Done', 'att_done|all').row().text('❌ Cancel', 'att_cancel');
    final message = await ctx.reply(
      'Mark attendance for ${this._day(sat)}:\n'
      '🔵 some of your group unmarked · 🟢 all marked · '
      'no icon = nobody from your group',
      replyMarkup: kb,
    );
    state.trackInteractiveMessage(
      ctx.from!.id,
      ctx.from!.id,
      message.messageId,
    );
  }
  Future<void> _renderSessionList(Context ctx, int adminId) async {
    final sat = this._currentWeekendSat();
    final sessions = repo.sessionsForWeekend(sat);
    final group = _adminGroup(ctx);
    var kb = InlineKeyboard();
    for (final s in sessions) {
      final mark = _sessionMark(s, group, adminId);
      final loc = repo.locationName(s.location);
      kb = kb
          .text(
            '$mark$loc ${Slot.dayLabel(s.day)} '
                '${s.start.hour.toString().padLeft(2, '0')}: '
                '${s.start.minute.toString().padLeft(2, '0')}-'
                '${s.end.hour.toString().padLeft(2, '0')}: '
                '${s.end.minute.toString().padLeft(2, '0')}',
            'att_sess|${s.id}',
          )
          .row();
    }
    kb = kb.text('✅ Done', 'att_done|all').row().text('❌ Cancel', 'att_cancel');
    await ctx.editMessageText(
      'Mark attendance for ${this._day(sat)}:',
      replyMarkup: kb,
    );
  }

  /// The status mark for one session's button, scoped to the admin's [group]:
  /// '' (transparent) when nobody from the group is allocated, '🟢 ' when
  /// every allocated member is marked, '🔵 ' when some are still unmarked.
  String _sessionMark(Session s, String group, [int? adminId]) {
    final members = _sessionMembers(s, group);
    if (members.isEmpty) return '';
    final draft = adminId == null
        ? null
        : state.attendanceDrafts[(adminId, s.id)];
    for (final user in members) {
      final mark = draft == null
          ? _dbAttendance(user.id, s.id)
          : draft.values[user.id];
      if (mark == null) return '🔵 ';
    }
    return '🟢 ';
  }

  bool? _dbAttendance(int userId, int sessionId) {
    final mark = repo
        .attendanceForSession(sessionId)
        .where((attendance) => attendance.userId == userId)
        .firstOrNull;
    return mark?.attended;
  }

  /// The admin's group members allocated to [session] (empty group = every
  /// group).
  List<User> _sessionMembers(Session s, String group) => repo
      .allocationsForWeekend(s.weekendStart)
      .where(
        (a) =>
            a.$2.id == s.id &&
            a.$1.memberTier != MemberTier.outMember &&
            (group.isEmpty || a.$1.group == group),
      )
      .map((a) => a.$1)
      .toList();

  Future<void> _sessionPicker(Context ctx, int sessionId) async {
    final session = repo.sessionById(sessionId);
    if (session == null) {
      await ctx.editMessageText(
        'That session is no longer available.',
        replyMarkup: null,
      );
      return;
    }
    await _renderSessionPicker(ctx, session);
  }

  /// The per-member attendance list for one session, scoped to the admin's
  /// own group. Both the picker entry and the post-toggle re-render go
  /// through here so they always show the same members.
  Future<void> _renderSessionPicker(Context ctx, Session session) async {
    final group = _adminGroup(ctx);
    final members = _sessionMembers(session, group);

    if (members.isEmpty) {
      await ctx.editMessageText(
        '${service.sessionLabel(session)}\n'
        'No one from your group is allocated here.',
        replyMarkup: null,
      );
      return;
    }

    final draft = this._draftFor(ctx, session, members);
    var kb = InlineKeyboard();
    for (final user in members) {
      final mark = _markForValue(user.id, draft.values[user.id]);
      kb = kb
          .text('$mark ${user.name}', 'att_toggle|${session.id}|${user.id}')
          .row();
    }
    kb = kb
        .text('✅ Done', 'att_done|member')
        .row()
        .text('❌ Cancel', 'att_cancel');
    await ctx.editMessageText(
      '${service.sessionLabel(session)}\n'
      'Tap to cycle: ⬜ unmarked → ✅ present → ❌ not participated → ⬜',
      replyMarkup: kb,
    );
  }

  String _markForValue(int userId, bool? value) => value == null
      ? '⬜'
      : value
      ? '✅'
      : '❌';

  AttendanceDraft _draftFor(Context ctx, Session session, List<User> members) {
    final key = (ctx.from!.id, session.id);
    return state.attendanceDrafts.putIfAbsent(key, () {
      final snapshot = <int, bool?>{
        for (final user in members) user.id: _dbAttendance(user.id, session.id),
      };
      return AttendanceDraft(snapshot);
    });
  }

  Future<void> _toggleAttendance(Context ctx, int sessionId, int userId) async {
    final session = repo.sessionById(sessionId);
    if (session == null) {
      await ctx.editMessageText(
        'That session is no longer available.',
        replyMarkup: null,
      );
      return;
    }
    final group = _adminGroup(ctx);
    final members = _sessionMembers(session, group);
    if (!members.any((member) => member.id == userId)) {
      await ctx.editMessageText(
        'That member is not in your group for this session.',
        replyMarkup: null,
      );
      return;
    }
    final draft = this._draftFor(ctx, session, members);
    final current = draft.values[userId];
    draft.values[userId] = current == null
        ? true
        : current
        ? false
        : null;
    await _renderSessionPicker(ctx, session);
  }

  Future<void> _finishAttendance(Context ctx) async {
    final adminId = ctx.from!.id;
    for (final entry
        in state.attendanceDrafts.entries
            .where((entry) => entry.key.$1 == adminId)
            .toList()) {
      final sessionId = entry.key.$2;
      for (final member in entry.value.values.entries) {
        if (member.value == entry.value.original[member.key]) continue;
        final value = member.value;
        if (value == null) {
          repo.clearAttendance(member.key, sessionId);
        } else if (value) {
          service.markAttendance(member.key, sessionId, attended: true);
        } else {
          repo.setAttendanceState(member.key, sessionId, attended: false);
        }
      }
      state.attendanceDrafts.remove(entry.key);
    }
    state.clearInteractiveMessages(adminId);
    await ctx.editMessageText('✅ Attendance saved.', replyMarkup: null);
  }

  Future<void> _cancelAttendance(Context ctx) async {
    state.clearAttendanceDrafts(ctx.from!.id);
    state.clearInteractiveMessages(ctx.from!.id);
    await ctx.editMessageText(
      '❌ Attendance changes discarded.',
      replyMarkup: null,
    );
  }

  // ----------------------------------------------------------- /setexp

  Future<void> _pickUser(Context ctx, String kind) async {
    final args = ctx.args;
    if (args.length > 1) {
      await ctx.reply('Usage: /setexp');
      return;
    }
    if (args.isEmpty) {
      await _pickValue(ctx, kind);
      return;
    }
    final value = args.first.toLowerCase();
    if (kind != 'setexp' || !_isValidValue(kind, value)) {
      await ctx.reply('Usage: /setexp');
      return;
    }
    await _pickUserFor(ctx, kind, value);
  }

  bool _isValidValue(String kind, String value) {
    if (kind == 'setexp') {
      return value == 'experienced' || value == 'newbie';
    }
    return value == 'a' || value == 'b';
  }

  /// Arg-less /setexp: pick the value first, then the member.
  Future<void> _pickValue(Context ctx, String kind) async {
    final choices = kind == 'setexp'
        ? [('Experienced', 'experienced'), ('Newbie', 'newbie')]
        : [('Group A', 'a'), ('Group B', 'b')];
    var kb = InlineKeyboard();
    for (final (label, value) in choices) {
      kb = kb.text(label, 'setval|$kind|$value').row();
    }
    kb = kb.text('❌ Cancel', 'admincancel|0');
    await ctx.reply(
      kind == 'setexp' ? 'Set experience to:' : 'Set group to:',
      replyMarkup: kb,
    );
  }

  Future<void> _pickUserFor(Context ctx, String kind, String value) async {
    final users = repo
        .activeUsers()
        .where(
          (u) =>
              u.memberTier != MemberTier.outMember &&
              (value == 'experienced'
                  ? u.experience != Experience.experienced
                  : u.experience != Experience.newbie),
        )
        .toList();
    if (users.isEmpty) {
      if (ctx.callbackQuery != null) {
        await ctx.editMessageText(
          'No registered users match that value.',
          replyMarkup: null,
        );
      } else {
        await ctx.reply('No registered users match that value.');
      }
      return;
    }
    var kb = InlineKeyboard();
    for (final u in users) {
      kb = kb.text(u.name, '$kind|$value|${u.id}').row();
    }
    kb = kb.text('❌ Cancel', 'admincancel|0');
    final text =
        'Set <b>'
        '${kind == 'setexp' ? 'experience to $value' : 'group to ${value.toUpperCase()}'}'
        '</b> for:';
    if (ctx.callbackQuery != null) {
      await ctx.editMessageText(
        text,
        parseMode: ParseMode.html,
        replyMarkup: kb,
      );
    } else {
      await ctx.reply(text, parseMode: ParseMode.html, replyMarkup: kb);
    }
  }

  Future<void> _applySet(
    Context ctx,
    String kind,
    String value,
    int userId,
  ) async {
    final user = repo.findUser(userId);
    if (user == null || user.memberTier == MemberTier.outMember) {
      await ctx.editMessageText(
        'That user is no longer available.',
        replyMarkup: null,
      );
      return;
    }
    if (kind == 'setexp') {
      repo.updateExperience(
        userId,
        value == 'experienced' ? Experience.experienced : Experience.newbie,
      );
    } else {
      repo.updateGroup(userId, value.toUpperCase());
    }
    final updated = repo.findUser(userId)!;
    final exp = updated.experience == Experience.experienced
        ? 'experienced'
        : 'newbie';
    await ctx.editMessageText(
      '✅ <b>${updated.name}</b> → $exp, '
      'group ${updated.group.isEmpty ? 'none' : updated.group}',
      parseMode: ParseMode.html,
      replyMarkup: null,
    );
  }

  // ----------------------------------------------------------- broadcast

  /// /broadcast with a message runs immediately; without one, starts the
  /// ask-to-type wizard (grid button press) then confirms before sending.
  Future<void> _broadcast(Context ctx) async {
    final text = ctx.argsString;
    if (text == null || text.trim().isEmpty) {
      final userId = ctx.from!.id;
      state.pendingArg[userId] = PendingArg('broadcast');
      final message = await ctx.reply(
        '📢 Send me the message to broadcast to all members, or tap Cancel.',
        replyMarkup: InlineKeyboard().text('❌ Cancel', 'admincancel|0'),
      );
      state.trackInteractiveMessage(userId, userId, message.messageId);
      return;
    }
    final userId = ctx.from!.id;
    _pendingBroadcast[userId] = text.trim();
    await _confirmBroadcast(ctx, text.trim());
  }

  /// Entry point for the wizard: the user typed the broadcast text; show the
  /// confirm dialog.
  Future<void> onBroadcastText(Context ctx, int userId, String text) async {
    _pendingBroadcast[userId] = text;
    await _confirmBroadcast(ctx, text.trim());
  }

  Future<void> _confirmBroadcast(Context ctx, String text) async {
    final preview = this._html(
      text.length > 200 ? '${text.substring(0, 200)}…' : text,
    );
    final message = await ctx.reply(
      '📢 Send this to all members?\n\n<i>$preview</i>',
      parseMode: ParseMode.html,
      replyMarkup: Pickers.confirm('bcast'),
    );
    state.trackInteractiveMessage(
      ctx.from!.id,
      ctx.from!.id,
      message.messageId,
    );
  }
}
