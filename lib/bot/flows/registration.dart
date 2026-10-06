part of '../flows.dart';

mixin _Flows1 on _FlowsBase {

  /// Fired after a member's availability is saved (Done or Not available).
  /// Wired in main.dart to the scheduler's dynamic-allocation trigger.
  Future<void> Function()? onAvailabilitySaved;

  void register() {
    // Bookkeeping middleware: records seen users and routes pending-input
    // text, then ALWAYS continues the chain so command handlers registered
    // later (admin, console, grid-button hears) still receive the update.
    bot.use((ctx, next) async {
      final text = ctx.message?.text;
      if (text != null) {
        final userId = ctx.from!.id;
        _recordSeen(ctx, userId);

        if (state.isValidCommandText(text)) {
          await _dismissInteractiveMessages(userId);
          await next();
          return;
        }

        // A user mid-wizard (e.g. "type the message to broadcast"): their
        // next text is the argument. Consume it here and stop the chain.
        final pending = state.pendingArg[userId];
        if (pending != null && !pending.isExpired) {
          state.pendingArg.remove(userId);
          await _consumePendingArg(ctx, userId, pending.command, text);
          return;
        }
        // The preferred-name profile wizard.
        final profileStep = state.profileStep[userId];
        if (profileStep != null) {
          await _consumeProfileStep(ctx, userId, profileStep, text);
          return;
        }
      }
      await next();
    });

    // Callback middleware: handles member-flow callbacks (slot/done/no/
    // holiday opt-out), then continues the chain for everything else
    // (admin/console).
    bot.use((ctx, next) async {
      final data = ctx.callbackQuery?.data;
      if (data == null) return next();
      final head = data.split('|').first;
      if (head == 'slot' ||
          head == 'done' ||
          head == 'no' ||
          head == 'cancel' ||
          head == 'holidayout' ||
          head == 'notify') {
        await _onCallback(ctx);
        return;
      }
      if (head == 'noop' || head == 'locked' || head == 'full') {
        // Non-interactive label rows (e.g. the picker's weekend headers):
        // dismiss the button press instantly so Telegram shows no spinner.
        await ctx.answerCallbackQuery();
        return;
      }
      if (head == 'pfcancel') {
        // Abort the profile wizard, keeping whatever is already saved.
        state.profileStep.remove(ctx.from!.id);
        state.profileCancel.remove(ctx.from!.id);
        state.clearInteractiveMessages(ctx.from!.id);
        await ctx.answerCallbackQuery();
        try {
          await ctx.editMessageText('Cancelled — your profile is unchanged.');
        } catch (_) {
          // message may be gone; ignore
        }
        return;
      }
      await next();
    });

    // Register commands after the bookkeeping middleware. This lets a valid
    // command cancel a pending text flow before its handler runs.
    commandBoth(bot, state, 'start', _onStart, label: 'start');
    commandBoth(bot, state, 'repick', _onRepick, label: 're-pick');
    commandBoth(bot, state, 'setinfo', _onSetInfo, label: 'set-info');
    commandBoth(bot, state, 'mystatus', _onMyStatus, label: 'my-status');
    state.registerCommand('checkstatus');
    bot.command('checkstatus', _onCheckStatusCommand);
    state.registerLabel('check-status');
    bot.hears('check-status', _onCheckStatus);
    commandBoth(bot, state, 'grid', _onGrid, label: 'grid');
    commandBoth(bot, state, 'resetgrid', _onResetGrid, label: 'reset-grid');
    commandBoth(bot, state, 'notify', _onNotify, label: 'notify');
    state.registerLabel('more-cmd');
    bot.hears('more-cmd', _onMoreCommands);
  }

  // ------------------------------------------------------------- /start

  Future<void> _onStart(Context ctx) async {
    final userId = ctx.from!.id;
    _recordSeen(ctx, userId);

    final user = repo.findUser(userId);
    final isConsole = config.isConsole(userId);
    // A user that no admin has added yet gets silence: no backend traffic,
    // no hint that the bot exists.
    if (user == null && !isConsole) return;

    final name = user?.name ??
        (ctx.from?.username == null ? 'Console' : '@${ctx.from!.username}');
    final isAdmin = user?.isAdmin == true;
    final retired = user?.memberTier == MemberTier.old;
    final checker = user?.memberTier == MemberTier.check;

    final sb = StringBuffer('👋 <b>${_html(name)}</b>, here is what you can do:');

    if (retired) {
      sb.writeln('\nThank you for your commitment! Hope to see you in the future!');
    }

    // Checkers are not members. Keep their focused start response and single
    // check-status keyboard instead of presenting the generic role sections.
    if (checker && !isConsole) {
      await ctx.reply(
          '👋 <b>${_html(name)}</b>, you are a checker.\n\n'
          'check-status - show the current week\'s allocation',
        parseMode: ParseMode.html,
        replyMarkup: RoleKeyboard.build('check'),
      );
      return;
    }

    final visibleSections = RoleKeyboard.visibleSections(
      isConsole: isConsole,
      isAdmin: isAdmin,
      isGlobalAdmin: user?.isGlobalAdmin == true,
      tier: user?.memberTier,
    );
    for (final section in visibleSections) {
      sb.write('\n\n<b>${_html(section.title)}</b>');
      for (final button in section.buttons) {
        sb.write(
          '\n${_html(button.label)} - '
          '${_html(RoleKeyboard.descriptionFor(
            button,
            outMember: section.title == 'Out-member',
          ))}',
        );
      }
    }

    final isGlobalAdmin = user?.isGlobalAdmin == true;
    final isPrivileged = isConsole || isAdmin || isGlobalAdmin;
    if (user != null && !retired && !checker && !isPrivileged) {
      final isOutMember = user.memberTier == MemberTier.outMember;
      sb
        ..write('\nre-pick — update your availability')
        ..write('\nset-info — update your preferred name')
        ..write(
          '\n${isOutMember ? 'my-status — your picks and allocation' : 'my-status — your picks, allocation and attendance'}',
        )
        ..write(isOutMember ? '\nnotify — choose prompt frequency' : '');
    }

    if (isPrivileged) {
      sb.write('\n\nTap more-cmd for additional commands.');
    }
    if (isConsole) {
      sb.write('\nType /grid to switch which grid you see (console only).');
    }

    await ctx.reply(
      sb.toString(),
      parseMode: ParseMode.html,
      replyMarkup: RoleKeyboard.build(
        _gridFor(userId),
        consoleIdentity: isConsole,
      ),
    );

    // First-time profile: collect the preferred name. Only prompted until
    // complete; /setinfo re-opens it later.
    if (user != null && !retired && !checker && user.preferredName.isEmpty) {
      await _startProfileWizard(ctx, userId, user);
    }
  }

  Future<void> _onMoreCommands(Context ctx) async {
    final userId = ctx.from!.id;
    _recordSeen(ctx, userId);
    final user = repo.findUser(userId);
    final isConsole = config.isConsole(userId);
    if (user == null && !isConsole) return;
    final sections = CommandCatalog.sections(
      isConsole: isConsole,
      isAdmin: user?.isAdmin == true,
      isGlobalAdmin: user?.isGlobalAdmin == true,
      tier: user?.memberTier,
    );
    final text = sections.isEmpty
        ? 'No additional commands.'
        : sections
              .map(
                (section) =>
                    '<b>${section.title}</b>\n'
                    '${section.commands.map((entry) => entry.display).join('\n')}',
              )
              .join('\n\n');
    await ctx.reply(
      text,
      parseMode: ParseMode.html,
      replyMarkup: RoleKeyboard.build(
        _gridFor(userId),
        consoleIdentity: isConsole,
      ),
    );
  }

  // ----------------------------------------------------------- /setinfo

  /// Re-opens the preferred-name profile wizard. If the name is already
  /// filled, the first prompt carries a Cancel button so the member can abort
  /// without losing their info.
  Future<void> _onSetInfo(Context ctx) async {
    final userId = ctx.from!.id;
    _recordSeen(ctx, userId);
    final user = repo.findUser(userId);
    if (user == null || !_isActive(user)) return;
    await _startProfileWizard(ctx, userId, user);
  }

  Future<void> _startProfileWizard(Context ctx, int userId, User user) async {
    state.profileStep[userId] = 0;
    // Decided once, from the profile the member had BEFORE this wizard run:
    // re-running /setinfo over existing data offers Cancel; a fresh walk
    // (nothing saved yet) never does — even after the first answer.
    final hasInfo = user.preferredName.isNotEmpty;
    state.profileCancel[userId] = hasInfo;
    final message = await ctx.reply(
      '1/$_profileSteps — ${_profilePrompt(0)}',
      replyMarkup: hasInfo
          ? InlineKeyboard().text('❌ Cancel', 'pfcancel|0')
          : null,
    );
    state.trackInteractiveMessage(userId, userId, message.messageId);
  }

  static String _profilePrompt(int step) => switch (step) {
    0 => 'What is your preferred name?',
    _ => '',
  }

;

  Future<void> _consumeProfileStep(
    Context ctx,
    int userId,
    int step,
    String text,
  ) async {
    final value = text.trim();
    if (value.isEmpty) {
      await ctx.reply('That cannot be empty — please type it again.');
      return; // stay on the same step
    }
    if (step != 0) throw StateError('Unexpected profile step: $step');
    repo.updatePreferredName(userId, value);
    if (step < _profileSteps - 1) {
      state.profileStep[userId] = step + 1;
      final cancel = state.profileCancel[userId] ?? false;
      final message = await ctx.reply(
        '${step + 2}/$_profileSteps — ${_profilePrompt(step + 1)}',
        replyMarkup: cancel
            ? InlineKeyboard().text('❌ Cancel', 'pfcancel|0')
            : null,
      );
      state.trackInteractiveMessage(userId, userId, message.messageId);
    } else {
      state.profileStep.remove(userId);
      state.profileCancel.remove(userId);
      state.clearInteractiveMessages(userId);
      await ctx.reply('✅ Profile saved.');
    }
  }

}
