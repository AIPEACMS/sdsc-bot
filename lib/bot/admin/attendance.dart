part of '../admin.dart';

extension AdminAttendance on Admin {
  Future<void> _doBroadcast(Context ctx, String text) async {
    if (!repo.activeOutreachEnabled('broadcast')) {
      final recipients = repo
          .activeUsers()
          .where((member) => member.memberTier != MemberTier.outMember)
          .length;
      LogRing.log(
        'broadcast: suppressed $recipients deliveries (route disabled)',
      );
      await ctx.reply('Broadcast delivery is disabled. Nothing was sent.');
      return;
    }
    var sent = 0;
    for (final user in repo.activeUsers()) {
      if (user.memberTier == MemberTier.outMember) continue;
      try {
        await bot.api.sendMessage(ChatID(user.id), text);
        sent++;
      } catch (_) {
        // skip members who blocked the bot
      }
    }
    await ctx.reply('✅ Sent to $sent members.');
  }

  // ------------------------------------------------------- admin callbacks

  Future<void> _onAdminCallback(Context ctx) async {
    final data = ctx.callbackQuery?.data ?? '';
    final parts = data.split('|');
    final attendance =
        parts[0] == 'att_sess' ||
        parts[0] == 'att_toggle' ||
        parts[0] == 'att_done' ||
        parts[0] == 'att_cancel' ||
        parts[0] == 'manualatt' ||
        parts[0] == 'manualattconfirm';
    if (attendance) await ctx.answerCallbackQuery();
    if (!_isAdmin(ctx)) {
      if (parts[0] == 'manualatt' || parts[0] == 'manualattconfirm') {
        await ctx.editMessageText(
          'You are not authorized to use this command.',
          replyMarkup: null,
        );
      }
      return;
    }
    switch (parts[0]) {
      case 'att_sess':
        final id = int.tryParse(parts.length > 1 ? parts[1] : '');
        if (id != null) {
          await _sessionPicker(ctx, id);
        } else {
          await ctx.editMessageText(
            'That session is no longer available.',
            replyMarkup: null,
          );
        }
      case 'att_toggle':
        final sid = parts.length > 1 ? int.tryParse(parts[1]) : null;
        final uid = parts.length > 2 ? int.tryParse(parts[2]) : null;
        if (sid != null && uid != null) {
          await _toggleAttendance(ctx, sid, uid);
        } else {
          await ctx.editMessageText(
            'That attendance choice is no longer valid.',
            replyMarkup: null,
          );
        }
      case 'att_done':
        if (parts.length > 1 && parts[1] == 'member') {
          await _renderSessionList(ctx, ctx.from!.id);
        } else {
          await _finishAttendance(ctx);
        }
      case 'att_cancel':
        await _cancelAttendance(ctx);
      case 'setexp':
        await ctx.answerCallbackQuery();
        final uid = parts.length > 2 ? int.tryParse(parts[2]) : null;
        if (uid != null) {
          await _applySet(ctx, parts[0], parts[1], uid);
        } else {
          await ctx.editMessageText(
            'That user is no longer available.',
            replyMarkup: null,
          );
        }
      case 'setval':
        final kind = parts.length > 1 ? parts[1] : '';
        final value = parts.length > 2 ? parts[2] : '';
        if (kind == 'setexp') {
          await ctx.answerCallbackQuery();
          await _pickUserFor(ctx, kind, value);
        }
      case 'mpick':
        await _onMemberPick(ctx, parts);
      case 'bcast':
        final yes = parts.length > 1 && parts[1] == 'yes';
        await ctx.answerCallbackQuery();
        await ctx.editMessageText(
          yes ? 'Sending…' : 'Cancelled — nothing was sent.',
          replyMarkup: null,
        );
        if (yes) {
          final text = _pendingBroadcast.remove(ctx.from!.id);
          if (text != null) await _doBroadcast(ctx, text);
        } else {
          _pendingBroadcast.remove(ctx.from!.id);
        }
      case 'adduser':
        final yes = parts.length > 1 && parts[1] == 'yes';
        await ctx.answerCallbackQuery();
        if (!yes) {
          _pendingAddUser.remove(ctx.from!.id);
          _pendingAddTier.remove(ctx.from!.id);
          state.pendingArg.remove(ctx.from!.id);
          state.clearInteractiveMessages(ctx.from!.id);
          await ctx.editMessageText(
            'Cancelled — nobody was added.',
            replyMarkup: null,
          );
          return;
        }
        final handles = _pendingAddUser.remove(ctx.from!.id);
        final tier = _pendingAddTier.remove(ctx.from!.id) ?? MemberTier.member;
        if (handles == null) return;
        await ctx.editMessageText(
          handles.map((handle) => _addOutcome(handle, tier: tier)).join('\n'),
          replyMarkup: null,
        );
      case 'prompt':
        final yes = parts.length > 1 && parts[1] == 'yes';
        await ctx.answerCallbackQuery();
        await ctx.editMessageText(
          yes ? 'Sending prompts…' : 'Cancelled — nothing was sent.',
          replyMarkup: null,
        );
        if (yes) await service.sendPrompts(_window());
      case 'remind':
        final yes = parts.length > 1 && parts[1] == 'yes';
        await ctx.answerCallbackQuery();
        await ctx.editMessageText(
          yes ? 'Sending reminders…' : 'Cancelled — nothing was sent.',
          replyMarkup: null,
        );
        if (yes) await service.sendReminders(_window());
      case 'admincancel':
        await ctx.answerCallbackQuery();
        state.pendingArg.remove(ctx.from!.id);
        _pendingBroadcast.remove(ctx.from!.id);
        _pendingAddUser.remove(ctx.from!.id);
        _pendingAddTier.remove(ctx.from!.id);
        state.clearInteractiveMessages(ctx.from!.id);
        await ctx.editMessageText('Cancelled.', replyMarkup: null);
      case 'manualatt':
        await _onManualAttendanceCallback(ctx, parts);
      case 'manualattconfirm':
        await _onManualAttendanceConfirm(ctx, parts);
    }
  }

  Future<void> _onMemberPick(Context ctx, List<String> parts) async {
    await ctx.answerCallbackQuery();
    final (action, page, target) = Pickers.parsePick(parts);
    if (target == 'cancel') {
      await ctx.editMessageText('Cancelled.', replyMarkup: null);
      return;
    }
    if (action == 'ask') {
      if (target == 'prev' || target == 'next') {
        // Re-render the picker at the new page.
        final members = repo
            .activeUsers()
            .where((u) => u.memberTier != MemberTier.outMember)
            .toList();
        await ctx.editMessageText(
          '🤔 Send the availability picker to which member?',
          replyMarkup: Pickers.memberPicker(
            action: 'ask',
            members: members,
            page: target == 'prev' ? page - 1 : page + 1,
          ),
        );
        return;
      }
      final memberId = int.tryParse(target);
      if (memberId != null) {
        await _askPick(ctx, memberId);
      } else {
        await ctx.editMessageText(
          'That member is no longer available.',
          replyMarkup: null,
        );
      }
      return;
    }
  }

  String _day(DateTime d) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
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
    return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}';
  }
}
