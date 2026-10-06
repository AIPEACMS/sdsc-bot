part of '../admin.dart';

mixin _Admin4 on _AdminBase {

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
    if (!_isAdmin(ctx)) return;
    final data = ctx.callbackQuery?.data ?? '';
    final parts = data.split('|');
    switch (parts[0]) {
      case 'att_sess':
        final id = int.tryParse(parts.length > 1 ? parts[1] : '');
        if (id != null) await _sessionPicker(ctx, id);
      case 'att_toggle':
        final sid = int.tryParse(parts[1]);
        final uid = int.tryParse(parts[2]);
        if (sid != null && uid != null) {
          await _toggleAttendance(ctx, sid, uid);
        }
      case 'setexp':
        final uid = int.tryParse(parts[2]);
        if (uid != null) await _applySet(ctx, parts[0], parts[1], uid);
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
          await ctx.editMessageText('Cancelled — nobody was added.');
          return;
        }
        final handles = _pendingAddUser.remove(ctx.from!.id);
        final tier = _pendingAddTier.remove(ctx.from!.id) ?? MemberTier.member;
        if (handles == null) return;
        await ctx.editMessageText(
          handles.map((handle) => _addOutcome(handle, tier: tier)).join('\n'),
        );
      case 'prompt':
        final yes = parts.length > 1 && parts[1] == 'yes';
        await ctx.answerCallbackQuery();
        await ctx.editMessageText(
          yes ? 'Sending prompts…' : 'Cancelled — nothing was sent.',
        );
        if (yes) await service.sendPrompts(_window());
      case 'remind':
        final yes = parts.length > 1 && parts[1] == 'yes';
        await ctx.answerCallbackQuery();
        await ctx.editMessageText(
          yes ? 'Sending reminders…' : 'Cancelled — nothing was sent.',
        );
        if (yes) await service.sendReminders(_window());
      case 'admincancel':
        await ctx.answerCallbackQuery();
        state.pendingArg.remove(ctx.from!.id);
        _pendingBroadcast.remove(ctx.from!.id);
        _pendingAddUser.remove(ctx.from!.id);
        _pendingAddTier.remove(ctx.from!.id);
        await ctx.editMessageText('Cancelled.');
    }
  }

  /// The broadcast message awaiting confirmation, per admin.
  final Map<int, String> _pendingBroadcast = {}

;

  Future<void> _onMemberPick(Context ctx, List<String> parts) async {
    await ctx.answerCallbackQuery();
    final (action, page, target) = Pickers.parsePick(parts);
    if (target == 'cancel') {
      await ctx.editMessageText('Cancelled.');
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
      if (memberId != null) await _askPick(ctx, memberId);
      return;
    }
  }

  static String _day(DateTime d) {
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
