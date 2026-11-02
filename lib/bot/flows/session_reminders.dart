part of '../flows.dart';

InlineKeyboard _emptyReminderKeyboard() =>
    InlineKeyboard(inlineKeyboard: const []);

extension FlowsSessionReminders on Flows {
  Future<void> _onConfigRemind(Context ctx) async {
    final userId = ctx.from!.id;
    final messageId = ctx.message?.messageId;
    if (messageId == null) return;
    final generation = state.takeReminderPreferenceOpenReservation(
      userId,
      messageId,
    );
    if (generation == null ||
        !state.isCurrentReminderPreferenceOpen(userId, generation)) {
      return;
    }
    final user = repo.findUser(userId);
    if (user == null || !MemberTier.isActive(user.memberTier)) return;

    final previous =
        state.reminderPreferenceOpenings[userId] ?? Future<void>.value();
    late final Future<void> opening;
    opening = previous.then(
      (_) => _openReminderPreference(ctx, userId, generation),
    );
    state.reminderPreferenceOpenings[userId] = opening;
    try {
      await opening;
    } finally {
      if (identical(state.reminderPreferenceOpenings[userId], opening)) {
        state.reminderPreferenceOpenings.remove(userId);
      }
    }
  }

  Future<void> _openReminderPreference(
    Context ctx,
    int userId,
    int generation,
  ) async {
    if (!state.isCurrentReminderPreferenceOpen(userId, generation)) return;
    final previousFlow = state.reminderPreferenceFlows[userId];
    if (previousFlow != null) {
      if (previousFlow.closing) {
        await previousFlow.closed.future;
      } else {
        previousFlow.closing = true;
        previousFlow.expiryTimer?.cancel();
        await _finishReminderFlow(userId, previousFlow);
      }
    }
    if (!state.isCurrentReminderPreferenceOpen(userId, generation)) return;

    final user = repo.findUser(userId);
    if (user == null || !MemberTier.isActive(user.memberTier)) return;
    final desiredEnabled = !user.sessionRemindersEnabled;
    final token = state.nextReminderFlowToken();
    final warning = user.sessionRemindersEnabled && !desiredEnabled;
    final prompt = warning
        ? 'Turning off session reminders means you are responsible for '
              'remembering your allocated sessions and arriving on time. '
              'Turn them off?'
        : 'Turn session reminders on?';
    final keyboard = InlineKeyboard()
        .text(
          'Confirm',
          'configremind|$token|${desiredEnabled ? 'confirm_on' : 'confirm_off'}',
        )
        .row()
        .text('Cancel', 'configremind|$token|cancel');
    final Message message;
    try {
      message = await ctx.reply(prompt, replyMarkup: keyboard);
    } catch (error) {
      LogRing.log('reminder confirmation send failed user=$userId: $error');
      return;
    }

    if (!state.isCurrentReminderPreferenceOpen(userId, generation)) {
      await _clearReminderMarkup(
        message.chat.id,
        message.messageId,
        deleteOnFailure: true,
      );
      return;
    }
    final currentUser = repo.findUser(userId);
    if (currentUser == null ||
        !MemberTier.isActive(currentUser.memberTier) ||
        currentUser.sessionRemindersEnabled == desiredEnabled) {
      await _clearReminderMarkup(
        message.chat.id,
        message.messageId,
        deleteOnFailure: true,
      );
      return;
    }
    final flow = ReminderPreferenceFlow(
      token: token,
      chatId: message.chat.id,
      messageId: message.messageId,
      desiredEnabled: desiredEnabled,
      expiresAfter: state.reminderPreferenceTimeout,
    );
    state.reminderPreferenceFlows[userId] = flow;
    state.trackInteractiveMessage(userId, flow.chatId, flow.messageId);
    flow.expiryTimer = Timer(
      flow.expiresAfter,
      () => unawaited(_expireReminderFlow(userId, flow)),
    );
  }

  Future<void> _onConfigRemindCallback(Context ctx) async {
    final userId = ctx.from!.id;
    final parts = (ctx.callbackQuery?.data ?? '').split('|');
    final flow = state.reminderPreferenceFlows[userId];
    final callbackMessage = ctx.callbackQuery?.message;
    if (flow == null || parts.length != 3 || parts[1] != flow.token) {
      await _answerReminderCallback(ctx);
      await _clearLegacyReminderKeyboard(
        userId,
        callbackMessage,
        protectedFlow: flow,
      );
      return;
    }
    if (callbackMessage?.chat.id != flow.chatId ||
        callbackMessage?.messageId != flow.messageId) {
      await _answerReminderCallback(ctx);
      await _clearLegacyReminderKeyboard(
        userId,
        callbackMessage,
        protectedFlow: flow,
      );
      return;
    }
    if (flow.closing) {
      await _answerReminderCallback(ctx);
      return;
    }
    if (flow.isExpired) {
      flow.closing = true;
      flow.expiryTimer?.cancel();
      await _answerReminderCallback(ctx);
      await _finishReminderFlow(
        userId,
        flow,
        context: ctx,
        text: 'This confirmation expired.',
      );
      return;
    }

    final action = parts[2];
    if (action == 'confirm_on' || action == 'confirm_off') {
      flow.closing = true;
      flow.expiryTimer?.cancel();
      final wantsEnabled = action == 'confirm_on';
      String result;
      try {
        final user = repo.findUser(userId);
        if (flow.desiredEnabled == wantsEnabled &&
            user != null &&
            MemberTier.isActive(user.memberTier) &&
            user.sessionRemindersEnabled != wantsEnabled) {
          repo.setSessionRemindersEnabled(userId, wantsEnabled);
        }
        final updated = repo.findUser(userId);
        result = updated?.sessionRemindersEnabled == wantsEnabled
            ? '✅ Reminder: ${wantsEnabled ? 'on' : 'off'}.'
            : 'This reminder setting is no longer available.';
      } catch (error) {
        LogRing.log('reminder preference write failed user=$userId: $error');
        result = 'Could not save this reminder preference. Please try again.';
      }
      await _answerReminderCallback(ctx);
      await _finishReminderFlow(userId, flow, context: ctx, text: result);
      return;
    }

    flow.closing = true;
    flow.expiryTimer?.cancel();
    await _answerReminderCallback(ctx);
    await _finishReminderFlow(
      userId,
      flow,
      context: ctx,
      text: action == 'cancel'
          ? 'No change made.'
          : 'This reminder action is no longer available.',
    );
  }

  Future<void> _answerReminderCallback(Context ctx) async {
    try {
      await ctx.answerCallbackQuery();
    } catch (error) {
      LogRing.log('reminder callback answer failed: $error');
    }
  }

  Future<void> _expireReminderFlow(
    int userId,
    ReminderPreferenceFlow flow,
  ) async {
    if (!identical(state.reminderPreferenceFlows[userId], flow) ||
        flow.closing) {
      return;
    }
    flow.closing = true;
    await _finishReminderFlow(userId, flow, text: 'This confirmation expired.');
  }

  Future<void> _finishReminderFlow(
    int userId,
    ReminderPreferenceFlow flow, {
    Context? context,
    String? text,
  }) async {
    flow.closing = true;
    flow.expiryTimer?.cancel();
    try {
      if (context != null && text != null) {
        await context.editMessageText(
          text,
          replyMarkup: _emptyReminderKeyboard(),
        );
      } else {
        await bot.api.editMessageReplyMarkup(
          ChatID(flow.chatId),
          flow.messageId,
          replyMarkup: _emptyReminderKeyboard(),
        );
      }
    } catch (error) {
      LogRing.log('reminder markup cleanup failed: $error');
      try {
        await bot.api.editMessageReplyMarkup(
          ChatID(flow.chatId),
          flow.messageId,
          replyMarkup: _emptyReminderKeyboard(),
        );
      } catch (retryError) {
        try {
          await bot.api.deleteMessage(ChatID(flow.chatId), flow.messageId);
        } catch (deleteError) {
          LogRing.log(
            'reminder prompt removal failed: $retryError; $deleteError',
          );
        }
      }
    } finally {
      if (identical(state.reminderPreferenceFlows[userId], flow)) {
        state.reminderPreferenceFlows.remove(userId);
      }
      state.untrackInteractiveMessage(userId, flow.chatId, flow.messageId);
      if (!flow.closed.isCompleted) flow.closed.complete();
    }
  }

  Future<void> _clearReminderMarkup(
    int chatId,
    int messageId, {
    bool deleteOnFailure = false,
  }) async {
    Object? error;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await bot.api.editMessageReplyMarkup(
          ChatID(chatId),
          messageId,
          replyMarkup: _emptyReminderKeyboard(),
        );
        return;
      } catch (failure) {
        error = failure;
      }
    }
    LogRing.log('stale reminder keyboard cleanup failed: $error');
    if (!deleteOnFailure) return;
    try {
      await bot.api.deleteMessage(ChatID(chatId), messageId);
    } catch (deleteError) {
      LogRing.log('stale reminder prompt removal failed: $deleteError');
    }
  }

  Future<void> _clearLegacyReminderKeyboard(
    int userId,
    MaybeInaccessibleMessage? message, {
    required ReminderPreferenceFlow? protectedFlow,
  }) async {
    if (message == null ||
        message.chat.type != ChatType.private ||
        message.chat.id != userId ||
        (protectedFlow != null &&
            message.chat.id == protectedFlow.chatId &&
            message.messageId == protectedFlow.messageId)) {
      return;
    }
    await _clearReminderMarkup(userId, message.messageId);
  }

  Future<void> shutdown() async {
    for (final userId in state.reminderPreferenceOpenings.keys.toList()) {
      state.invalidateReminderPreferenceOpen(userId);
    }
    await Future.wait(state.reminderPreferenceOpenings.values.toList());
    for (final entry in state.reminderPreferenceFlows.entries.toList()) {
      final flow = entry.value;
      if (flow.closing) {
        await flow.closed.future;
      } else {
        flow.closing = true;
        await _finishReminderFlow(entry.key, flow);
      }
    }
  }
}
