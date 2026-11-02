part of '../flows.dart';

extension FlowsSessionReminders on Flows {
  Future<void> _onConfigRemind(Context ctx) async {
    final userId = ctx.from!.id;
    await _recordSeen(ctx, userId);
    final user = repo.findUser(userId);
    if (user == null || !MemberTier.isActive(user.memberTier)) return;
    final token = state.nextReminderFlowToken();
    final choice = user.sessionRemindersEnabled ? 'choose_off' : 'choose_on';
    final message = await ctx.reply(
      'Session reminders are currently '
      '${user.sessionRemindersEnabled ? 'on' : 'off'}.',
      replyMarkup: InlineKeyboard().text(
        user.sessionRemindersEnabled ? 'Turn off' : 'Turn on',
        'configremind|$token|$choice',
      ),
    );
    state.reminderPreferenceFlows[userId] = ReminderPreferenceFlow(
      token: token,
      chatId: message.chat.id,
      messageId: message.messageId,
    );
    state.trackInteractiveMessage(userId, message.chat.id, message.messageId);
  }

  Future<void> _onConfigRemindCallback(Context ctx) async {
    final userId = ctx.from!.id;
    final parts = (ctx.callbackQuery?.data ?? '').split('|');
    await ctx.answerCallbackQuery();
    final flow = state.reminderPreferenceFlows[userId];
    final callbackMessage = ctx.callbackQuery?.message;
    if (flow == null || parts.length != 3 || parts[1] != flow.token) {
      await _dismissReminderResult(ctx, userId, parts, callbackMessage);
      return;
    }
    if (callbackMessage?.chat.id != flow.chatId ||
        callbackMessage?.messageId != flow.messageId) {
      return;
    }
    if (flow.isExpired) {
      state.reminderPreferenceFlows.remove(userId);
      state.clearInteractiveMessages(userId);
      try {
        await ctx.editMessageText(
          'This confirmation expired.',
          replyMarkup: null,
        );
      } catch (error) {
        LogRing.log('expired reminder confirmation cleanup failed: $error');
      }
      return;
    }
    final user = repo.findUser(userId);
    if (user == null || !MemberTier.isActive(user.memberTier)) {
      await _closeReminderPreference(
        ctx,
        userId,
        'This preference is unavailable.',
      );
      return;
    }
    switch (parts[2]) {
      case 'choose_off':
        if (!user.sessionRemindersEnabled) {
          await _closeReminderPreference(ctx, userId, 'Reminder: off.');
          return;
        }
        flow.desiredEnabled = false;
        await ctx.editMessageText(
          'Turning off session reminders means you are responsible for '
          'remembering your allocated sessions and arriving on time. Turn them off?',
          replyMarkup: InlineKeyboard()
              .text('Confirm', 'configremind|${flow.token}|confirm_off')
              .row()
              .text('Cancel', 'configremind|${flow.token}|cancel')
              .text('Dismiss', 'configremind|${flow.token}|dismiss'),
        );
      case 'choose_on':
        if (user.sessionRemindersEnabled) {
          await _closeReminderPreference(ctx, userId, 'Reminder: on.');
          return;
        }
        flow.desiredEnabled = true;
        await ctx.editMessageText(
          'Turn session reminders on?',
          replyMarkup: InlineKeyboard()
              .text('Confirm', 'configremind|${flow.token}|confirm_on')
              .row()
              .text('Cancel', 'configremind|${flow.token}|cancel')
              .text('Dismiss', 'configremind|${flow.token}|dismiss'),
        );
      case 'confirm_off':
      case 'confirm_on':
        final enabled = parts[2] == 'confirm_on';
        if (flow.desiredEnabled != enabled ||
            user.sessionRemindersEnabled == enabled) {
          await _closeReminderPreference(
            ctx,
            userId,
            'Reminder: ${user.sessionRemindersEnabled ? 'on' : 'off'}.',
          );
          return;
        }
        repo.setSessionRemindersEnabled(userId, enabled);
        await _completeReminderPreference(
          ctx,
          userId,
          flow,
          '✅ Reminder: ${enabled ? 'on' : 'off'}.',
        );
      case 'cancel':
        await _closeReminderPreference(ctx, userId, 'No change made.');
      case 'dismiss':
        state.reminderPreferenceFlows.remove(userId);
        state.clearInteractiveMessages(userId);
        try {
          await bot.api.deleteMessage(ChatID(flow.chatId), flow.messageId);
        } catch (error) {
          LogRing.log('reminder confirmation dismiss failed: $error');
        }
      default:
        await _closeReminderPreference(
          ctx,
          userId,
          'This action is unavailable.',
        );
    }
  }

  Future<void> _closeReminderPreference(
    Context ctx,
    int userId,
    String text,
  ) async {
    state.reminderPreferenceFlows.remove(userId);
    state.clearInteractiveMessages(userId);
    try {
      await ctx.editMessageText(text, replyMarkup: null);
    } catch (error) {
      LogRing.log('reminder confirmation close failed: $error');
    }
  }

  Future<void> _completeReminderPreference(
    Context ctx,
    int userId,
    ReminderPreferenceFlow flow,
    String text,
  ) async {
    state.reminderPreferenceFlows.remove(userId);
    state.clearInteractiveMessages(userId);
    final token = state.nextReminderFlowToken();
    try {
      await ctx.editMessageText(
        text,
        replyMarkup: InlineKeyboard().text(
          'Dismiss',
          'configremind|$token|dismiss_result',
        ),
      );
      state.reminderPreferenceResults[userId] = ReminderPreferenceResult(
        token: token,
        chatId: flow.chatId,
        messageId: flow.messageId,
      );
      state.trackInteractiveMessage(userId, flow.chatId, flow.messageId);
    } catch (error) {
      LogRing.log('reminder preference result update failed: $error');
    }
  }

  Future<void> _dismissReminderResult(
    Context ctx,
    int userId,
    List<String> parts,
    MaybeInaccessibleMessage? callbackMessage,
  ) async {
    final result = state.reminderPreferenceResults[userId];
    if (result == null ||
        parts.length != 3 ||
        parts[1] != result.token ||
        parts[2] != 'dismiss_result' ||
        callbackMessage?.chat.id != result.chatId ||
        callbackMessage?.messageId != result.messageId) {
      return;
    }
    state.reminderPreferenceResults.remove(userId);
    state.clearInteractiveMessages(userId);
    if (result.isExpired) {
      try {
        await ctx.editMessageText('This result expired.', replyMarkup: null);
      } catch (error) {
        LogRing.log('expired reminder result cleanup failed: $error');
      }
      return;
    }
    try {
      await bot.api.deleteMessage(ChatID(result.chatId), result.messageId);
    } catch (error) {
      LogRing.log('reminder result dismiss failed: $error');
    }
  }
}
