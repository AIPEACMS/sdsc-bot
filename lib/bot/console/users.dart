part of '../console.dart';

extension ConsoleUsers on Console {

  // ------------------------------------------------------- /removeuser

  /// Starts the global-admin-only batch removal wizard. This is deliberately
  /// registered as a slash command only, not as a reply-keyboard action.
  Future<void> _removeUser(Context ctx) async {
    final userId = ctx.from!.id;
    _pendingUserRemoval.remove(userId);
    state.cancelInputFlow(userId);
    final handles = ctx.args.isEmpty
        ? const <String>[]
        : _removeHandles(ctx.args.join(' '));
    if (handles.isEmpty) {
      state.pendingArg[userId] = PendingArg('removeuser');
      final message = await ctx.reply(
        'Send the handle(s) to remove, separated by spaces or new lines, '
        'or tap Cancel.',
        replyMarkup: InlineKeyboard().text('❌ Cancel', 'removeuser|cancel'),
      );
      state.trackInteractiveMessage(userId, userId, message.messageId);
      return;
    }
    await _prepareUserRemoval(ctx, userId, handles);
  }

  /// Entry point for the text step of the /removeuser wizard.
  Future<void> onRemoveUserText(Context ctx, int userId, String text) async {
    await _prepareUserRemoval(ctx, userId, _removeHandles(text));
  }

  void onRemoveUserInputCleared(int userId) {
    _pendingUserRemoval.remove(userId);
    state.clearInteractiveMessages(userId);
  }

  List<String> _removeHandles(String text) {
    final handles = <String>[];
    final seen = <String>{};
    for (final part in text.trim().split(RegExp(r'\s+'))) {
      if (part.isEmpty) continue;
      final normalized = (part.startsWith('@') ? part.substring(1) : part)
          .toLowerCase();
      if (seen.add(normalized)) handles.add(normalized);
    }
    return handles;
  }

  String _html(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  Future<void> _prepareUserRemoval(
    Context ctx,
    int userId,
    List<String> handles,
  ) async {
    if (handles.isEmpty) {
      _pendingUserRemoval.remove(userId);
      state.pendingArg[userId] = PendingArg('removeuser');
      await ctx.reply('No handles found. Try again, or tap Cancel.');
      return;
    }
    final validation = repo.validateUserRemoval(handles);
    if (!validation.succeeded) {
      _pendingUserRemoval.remove(userId);
      state.cancelInputFlow(userId);
      await _dismissRemovalMessages(userId);
      await ctx.reply(_userRemovalFailureMessage(validation));
      return;
    }

    await _dismissRemovalMessages(userId);
    // Store the complete payload before sending the confirmation prompt.
    _pendingUserRemoval[userId] = validation.removedHandles;
    final list = validation.removedHandles
        .map((handle) => '• @${_html(handle)}')
        .join('\n');
    final message = await ctx.reply(
      'Remove ${validation.removedHandles.length == 1 ? 'this user' : 'these users'}?\n$list',
      parseMode: ParseMode.html,
      replyMarkup: Pickers.confirm('removeuser'),
    );
    state.trackInteractiveMessage(userId, userId, message.messageId);
  }

  String _userRemovalFailureMessage(UserRemovalResult result) {
    final handle = result.failedHandle ?? '';
    return switch (result.failure) {
      UserRemovalFailure.notFound => '@$handle is not found',
      UserRemovalFailure.protectedAdmin =>
        '@$handle is an admin; demote them first.',
      UserRemovalFailure.none => 'Nothing to remove.',
    };
  }

  Future<void> _onRemoveUserCallback(Context ctx) async {
    await ctx.answerCallbackQuery();
    final userId = ctx.from!.id;
    final payload = _pendingUserRemoval[userId];
    final parts = (ctx.callbackQuery?.data ?? '').split('|');
    final action = parts.length > 1 ? parts[1] : '';
    if (payload == null) {
      await _dismissRemovalMessages(userId);
      await ctx.editMessageText(
        action == 'no'
            ? 'Cancelled — nothing changed.'
            : 'This removal request is no longer valid.',
        replyMarkup: null,
      );
      return;
    }
    if (action != 'yes') {
      _pendingUserRemoval.remove(userId);
      state.clearInteractiveMessages(userId);
      await ctx.editMessageText(
        'Cancelled — nothing changed.',
        replyMarkup: null,
      );
      return;
    }

    // Remove the payload before the mutation so every callback path clears it.
    _pendingUserRemoval.remove(userId);
    state.clearInteractiveMessages(userId);
    final result = repo.removeUsers(payload);
    if (!result.succeeded) {
      await ctx.editMessageText(
        _userRemovalFailureMessage(result),
        replyMarkup: null,
      );
      return;
    }
    await ctx.editMessageText(
      '✅ Removed ${result.removedHandles.map((h) => '@${_html(h)}').join(', ')}.',
      parseMode: ParseMode.html,
      replyMarkup: null,
    );
  }

  Future<void> _dismissRemovalMessages(int userId) async {
    for (final (chatId, messageId) in state.takeInteractiveMessages(userId)) {
      try {
        await bot.api.editMessageReplyMarkup(
          ChatID(chatId),
          messageId,
          replyMarkup: null,
        );
      } catch (error) {
        LogRing.log('removeuser: failed to dismiss message $messageId: $error');
      }
    }
  }

  Future<void> _removeGlobalAdminConfirm(Context ctx) async {
    final current = repo.globalAdmin();
    if (current == null) {
      await ctx.reply('There is no global admin to remove.');
      return;
    }
    if (ctx.args.length > 1) {
      await ctx.reply('Usage: /rmg [@handle]');
      return;
    }
    if (ctx.args.length == 1) {
      final handle = ctx.args.single.replaceFirst('@', '').trim();
      final id = repo.userIdByUsername(handle);
      if (id != current.id) {
        await ctx.reply('That handle is not the current global admin.');
        return;
      }
    }
    _pendingGlobalAdminRemoval[ctx.from!.id] = current.id;
    await ctx.reply(
      'Remove <b>${current.name}</b> as global admin? '
      'They become a regular member and their group is dissolved.',
      parseMode: ParseMode.html,
      replyMarkup: Pickers.confirm('rmgadmin'),
    );
  }

  Future<void> _onGlobalAdminCallback(Context ctx, String head) async {
    await ctx.answerCallbackQuery();
    final parts = (ctx.callbackQuery?.data ?? '').split('|');
    final yes = parts.length > 1 && parts[1] == 'yes';
    if (head == 'addgadmin') {
      final id = _pendingGlobalAdmin.remove(ctx.from!.id);
      if (!yes) {
        await ctx.editMessageText('Cancelled — nobody was appointed.');
        return;
      }
      if (id == null) return;
      final result = repo.appointGlobalAdmin(id);
      await ctx.editMessageText(switch (result) {
        GlobalAdminResult.success => '✅ Global admin appointed.',
        GlobalAdminResult.noSuchUser => 'That user is no longer registered.',
        GlobalAdminResult.alreadyExists => 'A global admin already exists.',
        GlobalAdminResult.outMember =>
          'Out-members cannot become the global admin.',
      });
      return;
    }
    final id = _pendingGlobalAdminRemoval.remove(ctx.from!.id);
    if (!yes) {
      await ctx.editMessageText('Cancelled — nothing changed.');
      return;
    }
    if (id == null || !repo.removeGlobalAdmin(id)) {
      await ctx.editMessageText('The global admin changed; nothing was removed.');
      return;
    }
    await ctx.editMessageText(
      '✅ Global admin removed; they are now a regular member.',
    );
  }

  // --------------------------------------------------------- /setdate /resetdate

  /// Debug: pretend "now" is a fixed local date (and optional time), so the
  /// console can test whether prompts/reminders/allocations would fire.
  Future<void> _setDate(Context ctx) async {
    final args = ctx.args;
    if (args.isEmpty) {
      final userId = ctx.from!.id;
      state.pendingArg[userId] = PendingArg('setdate');
      final message = await ctx.reply(
        '📅 Send the date as <b>YYYY-MM-DD</b>, optionally with a time '
        '(YYYY-MM-DD HH:MM), or tap Cancel.',
        parseMode: ParseMode.html,
        replyMarkup: InlineKeyboard().text('❌ Cancel', 'cancel|0'),
      );
      state.trackInteractiveMessage(userId, userId, message.messageId);
      return;
    }
    await _applyDate(ctx, args.join(' '));
  }

  /// Entry point for the set-date wizard: the console typed the date.
  Future<void> onSetDateText(Context ctx, int userId, String text) async {
    await _applyDate(ctx, text.trim());
  }

  Future<void> _applyDate(Context ctx, String input) async {
    final parts = input.trim().split(RegExp(r'\s+'));
    final date = DateTime.tryParse(parts.first);
    if (date == null) {
      await ctx.reply('Invalid date. Use YYYY-MM-DD.');
      return;
    }
    var local = DateTime(date.year, date.month, date.day);
    if (parts.length > 1) {
      final t = parts[1].split(':');
      final h = int.tryParse(t[0]);
      final m = t.length > 1 ? int.tryParse(t[1]) : 0;
      if (h == null || m == null) {
        await ctx.reply('Invalid time. Use HH:MM.');
        return;
      }
      local = DateTime(date.year, date.month, date.day, h, m);
    }
    final utc = local.subtract(Duration(hours: config.timezoneOffsetHours));
    Config.setDebugNow(utc.toUtc());
    await ctx.reply(
      '✅ Debug clock set to ${_fmt(local)} '
      '(local, offset ${config.timezoneOffsetHours}h). '
      'Send /resetdate to go back to the real clock.',
    );
  }

  Future<void> _resetDate(Context ctx) async {
    Config.setDebugNow(null);
    await ctx.reply('✅ Back to the real clock.');
  }

  // ----------------------------------------------------------- /demote

  /// Global admin demotes a normal admin by handle.
  Future<void> _demote(Context ctx) async {
    if (ctx.args.length != 1) {
      await ctx.reply('Usage: /demote @handle');
      return;
    }
    final handle = ctx.args.single.replaceFirst('@', '').trim();
    final id = repo.userIdByUsername(handle);
    final user = id == null ? null : repo.findUser(id);
    if (user != null) {
      if (!user.isAdmin) {
        await ctx.reply('That handle is not a normal admin.');
        return;
      }
      repo.demoteAdmin(user.id);
      await ctx.reply('✅ @$handle is now a regular member.');
      return;
    }
    if (repo.demotePendingAdmin(handle)) {
      await ctx.reply('✅ @$handle is no longer a pending admin.');
      return;
    }
    await ctx.reply('That handle is not a normal admin.');
  }

  // ------------------------------------------------------ /synccalendar

  /// Manual trigger for the calendar sync. The cron script pushes YAML via
  /// IPC; this lets the console do the same by typing/pasting the YAML.
  Future<void> _syncCalendar(Context ctx) async {
    if (calendarSync == null) {
      await ctx.reply('Calendar sync is not wired up in this build.');
      return;
    }
    final args = ctx.args;
    if (args.isEmpty) {
      final userId = ctx.from!.id;
      state.pendingArg[userId] = PendingArg('synccalendar');
      final message = await ctx.reply(
        '📆 Paste the academic-calendar YAML, or tap Cancel.',
        replyMarkup: InlineKeyboard().text('❌ Cancel', 'cancel|0'),
      );
      state.trackInteractiveMessage(userId, userId, message.messageId);
      return;
    }
    await _applyCalendarYaml(ctx, args.join(' '));
  }

  /// Entry point for the synccalendar wizard: the console pasted the YAML.
  Future<void> onSyncCalendarText(Context ctx, int userId, String text) async {
    await _applyCalendarYaml(ctx, text.trim());
  }

  Future<void> _applyCalendarYaml(Context ctx, String yaml) async {
    try {
      final result = calendarSync!.apply(yaml);
      await ctx.reply(
        '✅ Calendar ${result.academicYear}: ${result.weeks} weeks, '
        '${result.holidays} holiday rows.',
      );
    } catch (e) {
      await ctx.reply('❌ Sync failed: $e');
    }
  }

  // -------------------------------------------------------- /hold /unhold

  /// Console-only: pause all outgoing messages (block & drop). The bot keeps
  /// running — prompts, reminders and replies are suppressed; the console app
  /// (admin API, logs) stays reachable. Nothing is queued or replayed.
  Future<void> _holdConfirm(Context ctx) async {
    await ctx.reply(
      '🔇 <b>Hold the bot?</b>\n\n'
      'While held, the bot sends nothing — prompts, reminders, allocations '
      'and replies. It keeps running, and the console app stays reachable.',
      parseMode: ParseMode.html,
      replyMarkup: Pickers.confirm('hold'),
    );
  }

  Future<void> _unholdConfirm(Context ctx) async {
    // A held bot cannot deliver a confirmation keyboard: the transformer drops
    // every send/edit call while the gate is closed. Unhold is therefore an
    // immediate console-only recovery command.
    if (holdGate.isHeld) {
      repo.setHeld(false);
      holdGate.held = false;
      await ctx.reply(
        '✅ <b>Bot unheld.</b> It can send again.',
        parseMode: ParseMode.html,
      );
      return;
    }
    await ctx.reply(
      '✅ <b>Bot is already unheld.</b>',
      parseMode: ParseMode.html,
    );
  }

  Future<void> _onHoldCallback(Context ctx) async {
    await ctx.answerCallbackQuery();
    final parts = (ctx.callbackQuery?.data ?? '').split('|');
    final yes = parts.length > 1 && parts[1] == 'yes';
    final isHold = parts.first == 'hold';
    if (!yes) {
      await ctx.editMessageText('Cancelled — nothing changed.');
      return;
    }
    if (isHold) {
      // Engage the gate only after the confirmation message goes out, or the
      // confirmation itself is dropped.
      await ctx.editMessageText(
        '🔇 <b>Bot held.</b> No messages will be sent.',
        parseMode: ParseMode.html,
      );
      repo.setHeld(true);
      holdGate.held = true;
    } else {
      // Release the gate before replying, or the reply is dropped too.
      repo.setHeld(false);
      holdGate.held = false;
      await ctx.editMessageText(
        '✅ <b>Bot unheld.</b> It can send again.',
        parseMode: ParseMode.html,
      );
    }
  }

  String _fmt(DateTime d) {
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')} $h:$m';
  }

  // ------------------------------------- /locations /addlocation /addalias

  Future<void> _locations(Context ctx) async {
    final approved = repo.approvedLocations();
    final pending = repo.pendingLocations();
    final sb = StringBuffer('📍 <b>Locations</b>\n');
    if (approved.isEmpty) sb.writeln('(none approved)');
    for (final l in approved) {
      sb.writeln(
        '• <b>${l.name}</b>'
        '${l.aliases.isEmpty ? '' : ' — aliases: ${l.aliases.join(', ')}'}',
      );
    }
    if (pending.isNotEmpty) {
      sb.writeln(
        '\n🕓 <b>Pending</b> — approve with /addlocation &lt;name&gt;:',
      );
      for (final l in pending) {
        sb.writeln('• ${l.name}');
      }
    }
    await ctx.reply(sb.toString().trimRight(), parseMode: ParseMode.html);
  }

}
