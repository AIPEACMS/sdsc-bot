part of '../console.dart';

extension ConsoleRegistration on Console {
  /// Set from main.dart: resumed when a new location is approved so the
  /// waiting global admin gets the updated session list.

  void register() {
    commandBoth(
      bot,
      state,
      'add_admin',
      _globalAdminGuard(_addAdmin),
      label: 'add-admin',
    );
    commandAlias(bot, state, 'addadmin', _globalAdminGuard(_addAdmin));
    final addCheckHandler = _globalAdminGuard(_addCheck);
    state.registerCommand('add_check');
    bot.command('add_check', addCheckHandler);
    commandAlias(bot, state, 'addcheck', addCheckHandler);
    commandBoth(
      bot,
      state,
      'set_date',
      _consoleGuard(_setDate),
      label: 'set-date',
    );
    commandAlias(bot, state, 'setdate', _consoleGuard(_setDate));
    commandBoth(
      bot,
      state,
      'reset_date',
      _consoleGuard(_resetDate),
      label: 'reset-date',
    );
    commandAlias(bot, state, 'resetdate', _consoleGuard(_resetDate));
    commandBoth(
      bot,
      state,
      'demote',
      _globalAdminGuard(_demote),
      label: 'demote',
    );
    final removeUserHandler = _globalAdminGuard(_removeUser);
    state.registerCommand('rm_user');
    bot.command('rm_user', removeUserHandler);
    commandAlias(bot, state, 'removeuser', removeUserHandler);
    commandBoth(
      bot,
      state,
      'sync_calendar',
      _globalAdminGuard(_syncCalendar),
      label: 'sync-calendar',
    );
    commandAlias(bot, state, 'synccalendar', _globalAdminGuard(_syncCalendar));
    commandBoth(
      bot,
      state,
      'hold',
      _globalAdminGuard(_holdConfirm),
      label: 'hold',
    );
    commandBoth(
      bot,
      state,
      'unhold',
      _globalAdminGuard(_unholdConfirm),
      label: 'unhold',
    );
    commandBoth(
      bot,
      state,
      'add_key',
      _consoleGuard(_addKey),
      label: 'add-key',
    );
    commandAlias(bot, state, 'addkey', _consoleGuard(_addKey));
    commandBoth(bot, state, 'keys', _consoleGuard(_keys), label: 'keys');
    state.registerCommand('bind_key');
    bot.command('bind_key', _bindKey);
    commandBoth(bot, state, 'rm_key', _consoleGuard(_rmKey), label: 'rm-key');
    commandAlias(bot, state, 'rmkey', _consoleGuard(_rmKey));
    commandBoth(
      bot,
      state,
      'add_global_admin',
      _consoleGuard(_addGlobalAdminConfirm),
      label: 'addg',
    );
    commandAlias(bot, state, 'addg', _consoleGuard(_addGlobalAdminConfirm));
    commandBoth(
      bot,
      state,
      'rm_global_admin',
      _consoleGuard(_removeGlobalAdminConfirm),
      label: 'rmg',
    );
    commandAlias(bot, state, 'rmg', _consoleGuard(_removeGlobalAdminConfirm));
    commandBoth(
      bot,
      state,
      'locations',
      _consoleGuard(_locations),
      label: 'locations',
    );
    commandBoth(
      bot,
      state,
      'add_location',
      _consoleGuard(_addLocation),
      label: 'add-location',
    );
    commandAlias(bot, state, 'addlocation', _consoleGuard(_addLocation));
    commandBoth(
      bot,
      state,
      'add_alias',
      _consoleGuard(_addAlias),
      label: 'add-alias',
    );
    commandAlias(bot, state, 'addalias', _consoleGuard(_addAlias));
    final assignGroupHandler = _globalAdminGuard(_assignGroup);
    state.registerCommand('assign_group');
    bot.command('assign_group', assignGroupHandler);
    commandAlias(bot, state, 'assigngroup', assignGroupHandler);

    // Hold/unhold callbacks, console only.
    bot.use((ctx, next) async {
      final data = ctx.callbackQuery?.data;
      if (data == null) return next();
      final head = data.split('|').first;
      if (head == 'hold' || head == 'unhold') {
        if (_isGlobalAdmin(ctx)) await _onHoldCallback(ctx);
        return;
      }
      if (head == 'addgadmin' || head == 'rmgadmin') {
        if (_isConsole(ctx)) await _onGlobalAdminCallback(ctx, head);
        return;
      }
      if (head == 'removeuser') {
        if (_isGlobalAdmin(ctx)) {
          await _onRemoveUserCallback(ctx);
        } else {
          await ctx.answerCallbackQuery();
        }
        return;
      }
      if (head == 'assigngroup') {
        await _onAssignGroupCallback(ctx);
        return;
      }
      if (head == 'cancel' && _isConsole(ctx)) {
        await ctx.answerCallbackQuery();
        state.pendingArg.remove(ctx.from!.id);
        state.clearInteractiveMessages(ctx.from!.id);
        await ctx.editMessageText('Cancelled.', replyMarkup: null);
        return;
      }
      await next();
    });
  }

  bool _isConsole(Context ctx) {
    final userId = ctx.from?.id;
    if (userId == null) return false;
    return config.isConsole(userId);
  }

  void Function(Context) _consoleGuard(Future<void> Function(Context) handler) {
    return (ctx) async {
      if (!_isConsole(ctx)) {
        await ctx.reply('You are not the console.');
        return;
      }
      await handler(ctx);
    };
  }

  bool _isGlobalAdmin(Context ctx) {
    final userId = ctx.from?.id;
    return userId != null && repo.findUser(userId)?.isGlobalAdmin == true;
  }

  void Function(Context) _globalAdminGuard(
    Future<void> Function(Context) handler,
  ) {
    return (ctx) async {
      if (!_isGlobalAdmin(ctx)) {
        await ctx.reply('You are not the global admin.');
        return;
      }
      await handler(ctx);
    };
  }

  // --------------------------------------------------------- /add_admin

  /// Adds a checker directly when their handle is known, or queues them until
  /// their first contact with the bot.
  Future<void> _addCheck(Context ctx) async {
    if (ctx.args.length != 1) {
      await ctx.reply('Usage: /add_check @handle');
      return;
    }
    final handle = ctx.args.single.replaceFirst('@', '').trim();
    if (!RegExp(r'^[A-Za-z0-9_]+$').hasMatch(handle)) {
      await ctx.reply('Usage: /add_check @handle');
      return;
    }

    final existing = repo.findUserByHandle(handle);
    final userId = existing?.id ?? repo.userIdByUsername(handle);
    if (existing != null) {
      repo.removePendingUser(handle);
      if (existing.memberTier == MemberTier.check && !existing.isAdmin) {
        await ctx.reply('✅ @$handle is already a checker.');
        return;
      }
      if (!repo.setTier(existing.id, MemberTier.check)) {
        await ctx.reply(
          'That user is the global admin and cannot be changed here.',
        );
        return;
      }
      await ctx.reply('✅ @$handle is now a checker.');
      return;
    }
    if (userId != null) {
      repo.upsertUser(
        User(
          id: userId,
          name: '@$handle',
          experience: Experience.newbie,
          group: '',
          memberTier: MemberTier.check,
        ),
      );
      await ctx.reply(
        '✅ @$handle added as a checker. They can now use /start.',
      );
      return;
    }

    final previous = repo.replacePendingUser(
      handle,
      isAdmin: false,
      tier: MemberTier.check,
    );
    await ctx.reply(
      previous == null
          ? '✅ @$handle queued as a checker. The moment they message this bot, '
                'they are registered automatically.'
          : '⚠️ @$handle is not registered. The pending role '
                '(${previous.effectiveTier}) was replaced with checker; they will '
                'be registered when they message the bot.',
    );
  }

  Future<void> _addAdmin(Context ctx) async {
    final args = ctx.args;
    if (args.length != 1) {
      await ctx.reply('Usage: /add_admin @handle');
      return;
    }
    final handle = args.first.replaceFirst('@', '');
    final existing = repo.findUserByHandle(handle);
    if (existing == null) {
      final previous = repo.replacePendingUser(
        handle,
        isAdmin: true,
        tier: MemberTier.member,
      );
      await ctx.reply(
        previous == null
            ? '⚠️ That handle is not a registered user. It was queued as an '
                  'admin and will be promoted when they message the bot.'
            : '⚠️ That handle is not a registered user. The pending role '
                  '(${previous.effectiveTier}) was replaced with admin; they will '
                  'be promoted when they message the bot.',
      );
      return;
    }
    // A registered account wins over a stale pending row. Console identity
    // does not make the account immutable; only global-admin does.
    repo.removePendingUser(handle);
    if (existing.isGlobalAdmin) {
      await ctx.reply('That user is already the global admin.');
      return;
    }
    if (existing.memberTier == MemberTier.outMember) {
      await ctx.reply('Out-members cannot be promoted to normal admin.');
      return;
    }
    if (existing.isAdmin) {
      await ctx.reply('✅ @$handle is already an admin.');
      return;
    }
    if (!repo.setTier(existing.id, MemberTier.admin)) {
      await ctx.reply('That user cannot be promoted to normal admin.');
      return;
    }
    await ctx.reply('✅ @$handle is now an admin.');
  }

  // -------------------------------------------------------- /add_global_admin /rm_global_admin

  Future<void> _addGlobalAdminConfirm(Context ctx) async {
    if (ctx.args.length != 1) {
      await ctx.reply('Usage: /add_global_admin @handle');
      return;
    }
    final handle = ctx.args.single.replaceFirst('@', '').trim();
    final userId = repo.userIdByUsername(handle);
    final user = userId == null ? null : repo.findUser(userId);
    if (user == null) {
      await ctx.reply('That handle is not a registered user.');
      return;
    }
    if (repo.globalAdmin() != null) {
      await ctx.reply('A global admin already exists.');
      return;
    }
    _pendingGlobalAdmin[ctx.from!.id] = user.id;
    await ctx.reply(
      'Appoint <b>${user.name}</b> as the global admin?',
      parseMode: ParseMode.html,
      replyMarkup: Pickers.confirm('addgadmin'),
    );
  }
}
