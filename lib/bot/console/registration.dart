part of '../console.dart';

mixin _Console1 on _ConsoleBase {

  /// Set from main.dart: resumed when a new location is approved so the
  /// waiting global admin gets the updated session list.

  void register() {
    commandBoth(
      bot,
      state,
      'addadmin',
      _globalAdminGuard(_addAdmin),
      label: 'add-admin',
    );
    state.registerCommand('addcheck');
    bot.command('addcheck', _globalAdminGuard(_addCheck));
    commandBoth(
      bot,
      state,
      'setdate',
      _consoleGuard(_setDate),
      label: 'set-date',
    );
    commandBoth(
      bot,
      state,
      'resetdate',
      _consoleGuard(_resetDate),
      label: 'reset-date',
    );
    commandBoth(
      bot,
      state,
      'demote',
      _globalAdminGuard(_demote),
      label: 'demote',
    );
    commandBoth(
      bot,
      state,
      'synccalendar',
      _globalAdminGuard(_syncCalendar),
      label: 'sync-calendar',
    );
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
    commandBoth(bot, state, 'addkey', _consoleGuard(_addKey), label: 'add-key');
    commandBoth(bot, state, 'keys', _consoleGuard(_keys), label: 'keys');
    commandBoth(bot, state, 'rmkey', _consoleGuard(_rmKey), label: 'rm-key');
    commandBoth(
      bot,
      state,
      'addg',
      _consoleGuard(_addGlobalAdminConfirm),
      label: 'addg',
    );
    commandBoth(
      bot,
      state,
      'rmg',
      _consoleGuard(_removeGlobalAdminConfirm),
      label: 'rmg',
    );
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
      'addlocation',
      _consoleGuard(_addLocation),
      label: 'add-location',
    );
    commandBoth(
      bot,
      state,
      'addalias',
      _consoleGuard(_addAlias),
      label: 'add-alias',
    );

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

  // --------------------------------------------------------- /addadmin

  /// Adds a checker directly when their handle is known, or queues them until
  /// their first contact with the bot.
  Future<void> _addCheck(Context ctx) async {
    if (ctx.args.length != 1) {
      await ctx.reply('Usage: /addcheck @handle');
      return;
    }
    final handle = ctx.args.single.replaceFirst('@', '').trim();
    if (!RegExp(r'^[A-Za-z0-9_]+$').hasMatch(handle)) {
      await ctx.reply('Usage: /addcheck @handle');
      return;
    }

    final userId = repo.userIdByUsername(handle);
    final existing = userId == null ? null : repo.findUser(userId);
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
      await ctx.reply('Usage: /addadmin @handle');
      return;
    }
    final handle = args.first.replaceFirst('@', '');
    final userId = repo.userIdByUsername(handle);
    final existing = userId == null ? null : repo.findUser(userId);
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

  // -------------------------------------------------------- /addg /rmg

  final Map<int, int> _pendingGlobalAdmin = {}

;

  final Map<int, int> _pendingGlobalAdminRemoval = {}

;

  Future<void> _addGlobalAdminConfirm(Context ctx) async {
    if (ctx.args.length != 1) {
      await ctx.reply('Usage: /addg @handle');
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
