part of '../console.dart';

extension ConsoleAssignGroup on Console {
  Future<void> _assignGroup(Context ctx) async {
    final userId = ctx.from!.id;
    await _dismissAssignGroupMessages(userId);
    _clearAssignGroupState(userId);

    var keyboard = InlineKeyboard().text('auto', 'assigngroup|select|auto');
    for (final leader in repo.groupLeaders(numericOnly: true)) {
      keyboard = keyboard.row().text(
        'Group ${leader.group} · ${_assignLeaderHandle(leader)}',
        'assigngroup|select|${leader.group}',
      );
    }
    final message = await ctx.reply(
      'Which group do you want to assign the member(s) to?',
      replyMarkup: keyboard,
    );
    state.trackInteractiveMessage(userId, userId, message.messageId);
  }

  Future<void> onAssignGroupText(Context ctx, int userId, String text) async {
    final group = _pendingGroupTarget[userId];
    if (group == null) {
      await ctx.reply('This assignment request is no longer valid.');
      return;
    }
    final handles = text
        .trim()
        .split(RegExp(r'\s+'))
        .where((handle) => handle.isNotEmpty)
        .toList();
    if (handles.isEmpty) {
      state.pendingArg[userId] = PendingArg('assigngroup-members');
      await ctx.reply('No handles found. Try again, or tap Cancel.');
      return;
    }

    final validation = repo.validateManualGroupAssignment(group, handles);
    await _dismissAssignGroupMessages(userId);
    _pendingGroupTarget.remove(userId);
    if (validation.preview == null) {
      _pendingGroupAssignment.remove(userId);
      final skipped = validation.skipped
          .map((handle) => '@${_assignHtml(handle)} is not a member, skipping.')
          .join('\n');
      await ctx.reply(
        skipped.isEmpty ? 'No members to assign.' : skipped,
        parseMode: ParseMode.html,
        replyMarkup: null,
      );
      return;
    }

    // Store the complete payload before the confirmation prompt.
    _pendingGroupAssignment[userId] = validation.preview!;
    final skipped = validation.skipped.isEmpty
        ? ''
        : '${validation.skipped.map((handle) => '@${_assignHtml(handle)} is not a member, skipping.').join('\n')}\n\n';
    final members = validation.preview!.members.values
        .map((member) => '• @${_assignHtml(member.handle)}')
        .join('\n');
    final leader = repo
        .groupLeaders(numericOnly: true)
        .where((candidate) => candidate.group == group)
        .firstOrNull;
    final leaderText = leader == null
        ? ''
        : ' under leader ${_assignLeaderLabel(leader)}';
    final message = await ctx.reply(
      '${skipped}Please confirm you want to assign these members to group '
      '$group$leaderText:\n$members',
      parseMode: ParseMode.html,
      replyMarkup: Pickers.confirm('assigngroup'),
    );
    state.trackInteractiveMessage(userId, userId, message.messageId);
  }

  void onAssignGroupInputCleared(int userId) {
    _pendingGroupTarget.remove(userId);
    _pendingGroupAssignment.remove(userId);
    state.clearInteractiveMessages(userId);
  }

  Future<void> _onAssignGroupCallback(Context ctx) async {
    await ctx.answerCallbackQuery();
    final userId = ctx.from!.id;
    final parts = (ctx.callbackQuery?.data ?? '').split('|');
    if (!_isGlobalAdmin(ctx)) {
      _clearAssignGroupState(userId);
      await _dismissAssignGroupMessages(userId);
      await ctx.editMessageText(
        'You are not the global admin.',
        replyMarkup: null,
      );
      return;
    }

    if (parts.length >= 3 && parts[1] == 'select') {
      await _selectAssignGroup(ctx, userId, parts[2]);
      return;
    }
    final action = parts.length > 1 ? parts[1] : '';
    final preview = _pendingGroupAssignment.remove(userId);
    _pendingGroupTarget.remove(userId);
    state.pendingArg.remove(userId);
    await _dismissAssignGroupMessages(userId);
    if (action == 'no' || action == 'cancel') {
      await ctx.editMessageText(
        'Cancelled — nothing changed.',
        replyMarkup: null,
      );
      return;
    }
    if (action != 'yes' || preview == null || preview.isExpired) {
      await ctx.editMessageText(
        preview == null || preview.isExpired
            ? 'This assignment request is no longer valid.'
            : 'Cancelled — nothing changed.',
        replyMarkup: null,
      );
      return;
    }
    final applied = repo.applyGroupAssignment(preview);
    await ctx.editMessageText(
      applied
          ? '✅ Group assignment applied.'
          : 'The group assignment changed; nothing was assigned.',
      replyMarkup: null,
    );
  }

  Future<void> _selectAssignGroup(Context ctx, int userId, String group) async {
    await _dismissAssignGroupMessages(userId);
    _pendingGroupAssignment.remove(userId);
    state.pendingArg.remove(userId);
    if (group == 'auto') {
      final preview = repo.previewAutoAssignGroups();
      _pendingGroupAssignment[userId] = preview;
      final message = await ctx.reply(
        _autoPreviewText(preview),
        parseMode: ParseMode.html,
        replyMarkup: Pickers.confirm('assigngroup'),
      );
      state.trackInteractiveMessage(userId, userId, message.messageId);
      return;
    }

    final leader = repo
        .groupLeaders(numericOnly: true)
        .where((candidate) => candidate.group == group)
        .firstOrNull;
    if (leader == null) {
      await ctx.editMessageText(
        'That group is no longer available.',
        replyMarkup: null,
      );
      return;
    }
    _pendingGroupTarget[userId] = group;
    state.pendingArg[userId] = PendingArg('assigngroup-members');
    final message = await ctx.reply(
      'Please send me the handle(s) of members you want to be assigned to '
      'group $group under leader ${_assignLeaderLabel(leader)}.',
      parseMode: ParseMode.html,
      replyMarkup: InlineKeyboard().text('❌ Cancel', 'assigngroup|cancel'),
    );
    state.trackInteractiveMessage(userId, userId, message.messageId);
  }

  String _autoPreviewText(GroupAssignmentPreview preview) {
    final groups =
        <String>{
          ...preview.leaderTargets.values,
          ...preview.membersByGroup.keys,
        }.toList()..sort((a, b) {
          final ai = int.tryParse(a) ?? 1 << 30;
          final bi = int.tryParse(b) ?? 1 << 30;
          return ai == bi ? a.compareTo(b) : ai.compareTo(bi);
        });
    final lines = <String>['Auto assignment preview:'];
    for (final group in groups) {
      final leaderId = preview.leaderTargets.entries
          .where((entry) => entry.value == group)
          .map((entry) => entry.key)
          .firstOrNull;
      final leader = leaderId == null ? null : repo.findUser(leaderId);
      final label = leader == null ? '' : ' (${_assignLeaderLabel(leader)})';
      lines.add('<b>Group ${_assignHtml(group)}$label</b>');
      final members = preview.membersByGroup[group] ?? const [];
      lines.add(
        members.isEmpty
            ? '• (none)'
            : members
                  .map((member) => '• @${_assignHtml(member.handle)}')
                  .join('\n'),
      );
    }
    if (groups.isEmpty) lines.add('No admin-led groups are available.');
    return lines.join('\n');
  }

  String _assignLeaderLabel(User leader) {
    final handle = _assignLeaderHandle(leader);
    final name = leader.preferredName.trim();
    return name.isEmpty
        ? '@${_assignHtml(handle)}'
        : '${_assignHtml(name)} @${_assignHtml(handle)}';
  }

  String _assignLeaderHandle(User leader) {
    final seen = repo.seenUsername(leader.id);
    final value = seen?.trim().isNotEmpty == true ? seen! : leader.name;
    return value.startsWith('@') ? value.substring(1) : value;
  }

  String _assignHtml(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  void _clearAssignGroupState(int userId) {
    _pendingGroupAssignment.remove(userId);
    _pendingGroupTarget.remove(userId);
    state.pendingArg.remove(userId);
    state.clearInteractiveMessages(userId);
  }

  Future<void> _dismissAssignGroupMessages(int userId) async {
    for (final (chatId, messageId) in state.takeInteractiveMessages(userId)) {
      try {
        await bot.api.editMessageReplyMarkup(
          ChatID(chatId),
          messageId,
          replyMarkup: null,
        );
      } catch (error) {
        LogRing.log(
          'assigngroup: failed to dismiss message $messageId: $error',
        );
      }
    }
  }
}
