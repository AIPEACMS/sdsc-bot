part of '../console.dart';

extension ConsoleUserRemoval on Console {

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
}
