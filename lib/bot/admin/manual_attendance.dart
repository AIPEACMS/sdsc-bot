part of '../admin.dart';

extension AdminManualAttendance on Admin {
  Future<void> _manualAllAttendance(Context ctx) =>
      _showManualAttendancePicker(ctx, allMembers: true, page: 0);

  Future<void> _manualGroupAttendance(Context ctx) =>
      _showManualAttendancePicker(ctx, allMembers: false, page: 0);

  Future<void> _showManualAttendancePicker(
    Context ctx, {
    required bool allMembers,
    required int page,
  }) async {
    final actor = repo.findUser(ctx.from!.id);
    if (actor == null ||
        (allMembers
            ? !actor.isGlobalAdmin
            : !actor.isAdmin && !actor.isGlobalAdmin)) {
      await ctx.editMessageText('You are not authorized to use this command.');
      return;
    }
    final group = actor.group;
    final members =
        repo
            .activeUsers()
            .where(
              (user) =>
                  user.memberTier == MemberTier.member &&
                  (allMembers || (group.isNotEmpty && user.group == group)),
            )
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    if (members.isEmpty) {
      await ctx.reply(
        allMembers
            ? 'There are no active attendance-eligible members.'
            : 'Your group has no active attendance-eligible members.',
      );
      return;
    }
    const pageSize = 5;
    final pageCount = (members.length / pageSize).ceil();
    final current = page.clamp(0, pageCount - 1);
    var keyboard = InlineKeyboard();
    for (final member in members.skip(current * pageSize).take(pageSize)) {
      final date = member.lastAttendedDate;
      final last = date == null
          ? 'never'
          : '${date.day}/${date.month}/${date.year}';
      keyboard = keyboard
          .text(
            '${member.name} · balance ${member.attendanceBalance} · last $last',
            'manualatt|${allMembers ? 'all' : 'group'}|$current|${member.id}',
          )
          .row();
    }
    if (pageCount > 1) {
      if (current > 0) {
        keyboard = keyboard.text(
          '⬅ Previous',
          'manualatt|${allMembers ? 'all' : 'group'}|${current - 1}|prev',
        );
      }
      if (current < pageCount - 1) {
        keyboard = keyboard.text(
          'Next ➡',
          'manualatt|${allMembers ? 'all' : 'group'}|${current + 1}|next',
        );
      }
      keyboard = keyboard.row();
    }
    keyboard = keyboard.text('Cancel', 'manualatt|cancel|0|cancel');
    final text = allMembers
        ? 'Choose an active member for a global attendance correction.'
        : 'Choose a member in your group for an attendance correction.';
    if (ctx.callbackQuery != null) {
      try {
        await ctx.editMessageText(text, replyMarkup: keyboard);
      } catch (error, stackTrace) {
        developer.log(
          'manual attendance picker update failed',
          name: 'sdsc-bot.admin.manual-attendance',
          error: error,
          stackTrace: stackTrace,
        );
        await _removeManualButtons(ctx);
      }
    } else {
      final message = await ctx.reply(text, replyMarkup: keyboard);
      state.trackInteractiveMessage(
        ctx.from!.id,
        ctx.from!.id,
        message.messageId,
      );
    }
  }

  Future<void> _onManualAttendanceCallback(
    Context ctx,
    List<String> parts,
  ) async {
    final actorId = ctx.from?.id;
    final actor = actorId == null ? null : repo.findUser(actorId);
    final scope = parts.length > 1 ? parts[1] : '';
    if (scope == 'cancel') {
      if (actorId != null) _clearManualAttendanceState(actorId);
      await _finishManualInteraction(ctx, actorId, 'Cancelled.');
      return;
    }
    final allMembers = scope == 'all';
    if (actor == null ||
        (allMembers
            ? !actor.isGlobalAdmin
            : !actor.isAdmin && !actor.isGlobalAdmin)) {
      if (actorId != null) _clearManualAttendanceState(actorId);
      await _finishManualInteraction(
        ctx,
        actorId,
        'You are not authorized to use this command.',
      );
      return;
    }
    final page = int.tryParse(parts.length > 2 ? parts[2] : '') ?? 0;
    final choice = parts.length > 3 ? parts[3] : '';
    if (choice == 'prev' || choice == 'next') {
      await _showManualAttendancePicker(
        ctx,
        allMembers: allMembers,
        page: page,
      );
      return;
    }
    final targetId = int.tryParse(choice);
    final target = targetId == null ? null : repo.findUser(targetId);
    final active =
        target != null &&
        target.memberTier == MemberTier.member &&
        repo.activeUsers().any((user) => user.id == target.id) &&
        (allMembers || (actor.group.isNotEmpty && target.group == actor.group));
    if (!active || targetId == null) {
      _clearManualAttendanceState(actorId!);
      await _finishManualInteraction(
        ctx,
        actorId,
        'That member is no longer eligible.',
      );
      return;
    }
    _manualAttendanceDrafts[actorId!] = (targetId, allMembers);
    _manualAttendanceConfirmations.remove(actorId);
    state.pendingArg[actorId] = PendingArg('manualattendance');
    final warning = allMembers
        ? '\n\n<b>Warning:</b> zero leaves the balance unchanged; a negative adjustment reduces it.'
        : '\n\n<b>Warning:</b> zero leaves the balance unchanged; negative adjustments are not allowed.';
    final stats = repo.attendanceStats(targetId);
    await _editManualPrompt(
      ctx,
      '<b>Attendance correction for ${_manualHtml(target.name)}</b>\n'
      'Current session-attendance count: ${stats.total}\n'
      'Current last-attended date: ${_manualDate(target.lastAttendedDate)}\n'
      'Current persisted attendance balance: ${target.attendanceBalance}\n\n'
      'Send a whole-number adjustment, optionally followed by a last-attended '
      'date (example: <code>2 Aug 24</code>; date formats include '
      '<code>Aug 24</code>, <code>24 Aug</code>, <code>12/08</code>, or '
      '<code>12-08</code>). Use <code>0</code> to leave the balance unchanged.'
      '$warning',
    );
  }

  Future<void> onManualAttendanceText(
    Context ctx,
    int userId,
    String text,
  ) async {
    final actor = repo.findUser(userId);
    final draft = _manualAttendanceDrafts[userId];
    if (actor == null ||
        draft == null ||
        (draft.$2
            ? !actor.isGlobalAdmin
            : !actor.isAdmin && !actor.isGlobalAdmin)) {
      state.pendingArg.remove(userId);
      _manualAttendanceDrafts.remove(userId);
      await _removeTrackedManualKeyboards(userId);
      await ctx.reply('You are no longer authorized. Start the command again.');
      return;
    }
    final match = RegExp(r'^([+-]?\d+)(?:\s+(.+))?$').firstMatch(text.trim());
    final delta = match == null ? null : int.tryParse(match.group(1)!);
    if (delta == null || (!draft.$2 && delta < 0)) {
      state.pendingArg[userId] = PendingArg('manualattendance');
      await _replyManualPrompt(
        ctx,
        userId,
        draft,
        'Send a whole signed integer${draft.$2 ? '' : ' (zero or positive)'} and an optional date. No change was made.',
      );
      return;
    }
    String? dateValue;
    final dateText = match?.group(2);
    if (dateText != null) {
      final today = config.toLocal(Config.nowUtc());
      final date = ManualAttendanceDate.parse(dateText, today: today);
      if (date == null) {
        state.pendingArg[userId] = PendingArg('manualattendance');
        await _replyManualPrompt(
          ctx,
          userId,
          draft,
          'Invalid or future date. Try Aug 24, 24 Aug, 12/08, or 12-08. No change was made.',
        );
        return;
      }
      dateValue = ManualAttendanceDate.canonical(date);
    }
    _manualAttendanceDrafts.remove(userId);
    final target = repo.findUser(draft.$1);
    if (target == null) {
      await _removeTrackedManualKeyboards(userId);
      await ctx.reply('That member is no longer available.');
      return;
    }
    _manualAttendanceConfirmations[userId] = (
      draft.$1,
      draft.$2,
      delta,
      dateValue,
    );
    state.pendingArg[userId] = PendingArg('manualattendance-confirm');
    final stats = repo.attendanceStats(draft.$1);
    final proposedDate = dateValue ?? _manualDate(target.lastAttendedDate);
    final balance = target.attendanceBalance + delta;
    final message = await ctx.reply(
      '<b>Attendance correction preview for ${_manualHtml(target.name)}</b>\n'
      'Current session-attendance count: ${stats.total}\n'
      'Current last-attended date: ${_manualDate(target.lastAttendedDate)}\n'
      'Current persisted attendance balance: ${target.attendanceBalance}\n'
      'Requested adjustment: $delta\n'
      'Proposed last-attended date: $proposedDate${dateValue == null ? ' (unchanged)' : ''}\n'
      'Proposed resulting balance: $balance\n\n'
      'Per-session attendance history will not change.',
      parseMode: ParseMode.html,
      replyMarkup: InlineKeyboard()
          .text('Confirm', 'manualattconfirm|yes')
          .row()
          .text('Cancel', 'manualattconfirm|no'),
    );
    state.trackInteractiveMessage(userId, userId, message.messageId);
  }

  void onManualAttendanceInputCleared(int userId) {
    _manualAttendanceDrafts.remove(userId);
    _manualAttendanceConfirmations.remove(userId);
  }

  void _clearManualAttendanceState(int userId) {
    state.pendingArg.remove(userId);
    onManualAttendanceInputCleared(userId);
  }

  Future<void> _replyManualPrompt(
    Context ctx,
    int userId,
    (int, bool) draft,
    String message,
  ) async {
    final target = repo.findUser(draft.$1);
    final text = target == null
        ? 'The selected member is no longer available.'
        : '<b>Attendance correction for ${_manualHtml(target.name)}</b>\n'
              'Current session-attendance count: ${repo.attendanceStats(target.id).total}\n'
              'Current last-attended date: ${_manualDate(target.lastAttendedDate)}\n'
              'Current persisted attendance balance: ${target.attendanceBalance}\n\n'
              '$message\n'
              'Input: a whole-number adjustment and optional date, for example '
              '<code>3 Oct 10</code>. Dates: <code>Aug 24</code>, '
              '<code>24 Aug</code>, <code>12/08</code>, or <code>12-08</code>.';
    final reply = await ctx.reply(
      text,
      parseMode: ParseMode.html,
      replyMarkup: InlineKeyboard().text('Cancel', 'manualatt|cancel|0|cancel'),
    );
    state.trackInteractiveMessage(userId, userId, reply.messageId);
  }

  Future<void> _onManualAttendanceConfirm(
    Context ctx,
    List<String> parts,
  ) async {
    final userId = ctx.from?.id;
    if (userId == null) return;
    final pending = state.pendingArg.remove(userId);
    final confirmation = _manualAttendanceConfirmations.remove(userId);
    final yes = parts.length > 1 && parts[1] == 'yes';
    if (!yes ||
        confirmation == null ||
        pending == null ||
        pending.command != 'manualattendance-confirm' ||
        pending.isExpired) {
      await _finishManualInteraction(
        ctx,
        userId,
        confirmation == null || pending == null || pending.isExpired
            ? 'This correction is no longer available.'
            : 'Cancelled. No change was made.',
      );
      return;
    }
    await _applyManualAttendance(
      userId,
      confirmation.$1,
      confirmation.$2,
      confirmation.$3,
      confirmation.$4,
      ctx,
      edit: true,
    );
  }

  Future<void> _applyManualAttendance(
    int adminId,
    int targetId,
    bool allMembers,
    int delta,
    String? dateValue,
    Context ctx, {
    bool edit = false,
  }) async {
    final changed = repo.applyManualAttendance(
      adminId,
      targetId,
      delta,
      allMembers: allMembers,
      lastAttendedDate: dateValue,
    );
    if (!changed) {
      const failure =
          'The member or your authorization changed. No change was made.';
      if (edit) {
        await _finishManualInteraction(ctx, adminId, failure);
      } else {
        await ctx.reply(failure);
      }
      return;
    }
    final updated = repo.findUser(targetId)!;
    final result =
        'Attendance updated for ${updated.name}. '
        'Balance: ${updated.attendanceBalance}.'
        '${dateValue == null ? '' : ' Last-attended date: $dateValue.'}';
    if (edit) {
      await _finishManualInteraction(ctx, adminId, result);
    } else {
      await ctx.reply(result);
    }
    await service.reconcileAttendanceCorrection(updated);
  }

  String _manualDate(DateTime? date) =>
      date == null ? 'never' : '${date.day}/${date.month}/${date.year}';

  String _manualHtml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
