part of '../admin.dart';

extension AdminCommands on Admin {

  void register() {
    commandBoth(bot, state, 'adduser', _guard(_addUser), label: 'add-user');
    commandBoth(
      bot,
      state,
      'addoutuser',
      _guard(_addOutUser),
      label: 'add-out-user',
    );
    commandBoth(
      bot,
      state,
      'allstatus',
      _guard(this._status),
      label: 'all-status',
    );
    state.registerCommand('status');
    bot.command('status', _guard(this._status)); // Compatibility alias.
    commandBoth(
      bot,
      state,
      'groupstatus',
      _guard(this._groupStatus),
      label: 'group-status',
    );
    state.registerCommand('allusers');
    bot.command('allusers', _guard(this._users));
    state.registerCommand('users');
    bot.command('users', _guard(this._users)); // Compatibility alias.
    state.registerCommand('groupuser');
    bot.command('groupuser', _guard(this._groupUsers));
    commandBoth(bot, state, 'prompt', _guard(this._promptConfirm), label: 'prompt');
    commandBoth(bot, state, 'remind', _guard(this._remindConfirm), label: 'remind');
    commandBoth(
      bot,
      state,
      'allocate',
      _guard((ctx) async {
        final w = _window();
        await service.allocateBundle(w);
        await ctx.reply('✅ Allocation completed.');
      }),
      label: 'allocate',
    );
    commandBoth(bot, state, 'ask', _guard(this._ask), label: 'ask');
    commandBoth(bot, state, 'confirm', _guard(this._confirm), label: 'mark-attend');
    commandBoth(
      bot,
      state,
      'setexp',
      _guard((ctx) => this._pickUser(ctx, 'setexp')),
      label: 'set-exp',
    );
    commandBoth(
      bot,
      state,
      'broadcast',
      _guard(this._broadcast),
      label: 'broadcast',
    );

    // Callback middleware: handles admin prefixes, continues otherwise.
    bot.use((ctx, next) async {
      final data = ctx.callbackQuery?.data;
      if (data == null) return next();
      final head = data.split('|').first;
      const mine = {
        'att_sess',
        'att_toggle',
        'setexp',
        'setval',
        'mpick',
        'bcast',
        'adduser',
        'prompt',
        'remind',
        'admincancel',
      };
      if (mine.contains(head)) {
        await this._onAdminCallback(ctx);
        return;
      }
      await next();
    });
  }

  bool _isAdmin(Context ctx) {
    final userId = ctx.from?.id;
    if (userId == null) return false;
    final user = repo.findUser(userId);
    return user?.isAdmin == true || user?.isGlobalAdmin == true;
  }

  void Function(Context) _guard(Future<void> Function(Context) handler) {
    return (ctx) async {
      if (!_isAdmin(ctx)) {
        await ctx.reply('You are not an admin.');
        return;
      }
      await handler(ctx);
    };
  }

  RollingWindow _window() => _windowFor(config.toLocal(Config.nowUtc()));

  RollingWindow _windowFor(DateTime now) => scheduleRuntime.window(now);

  // ----------------------------------------------------------- /adduser

  /// /adduser with no args starts the wizard: the admin sends handles and
  /// confirms the batch before anything is added. Arguments add directly.
  Future<void> _addUser(Context ctx) async {
    await _addUserAs(ctx, MemberTier.member);
  }

  Future<void> _addOutUser(Context ctx) async {
    await _addUserAs(ctx, MemberTier.outMember);
  }

  Future<void> _addUserAs(Context ctx, String tier) async {
    final args = ctx.args;
    if (args.isEmpty) {
      final userId = ctx.from!.id;
      _pendingAddUser.remove(userId);
      _pendingAddTier.remove(userId);
      state.pendingArg[userId] = PendingArg('adduser');
      _pendingAddTier[userId] = tier;
      final message = await ctx.reply(
        '➕ Send me the handle(s) to add as a ${tier == MemberTier.member ? 'member' : 'out-member'} '
        '(e.g. <b>@username</b>). Multiple users can be separated by whitespace, '
        'for example <b>@alice @bob</b>. Or tap Cancel.',
        parseMode: ParseMode.html,
        replyMarkup: InlineKeyboard().text('❌ Cancel', 'admincancel|0'),
      );
      state.trackInteractiveMessage(userId, userId, message.messageId);
      return;
    }
    _pendingAddUser.remove(ctx.from!.id);
    _pendingAddTier.remove(ctx.from!.id);
    await ctx.reply(
      args.map((handle) => _addOutcome(handle, tier: tier)).join('\n'),
    );
  }

  /// Entry point for the /adduser wizard: parse the batch and show one
  /// confirmation before applying any additions.
  Future<void> onAddUserText(Context ctx, int userId, String text) async {
    final handles = _parseHandles(text);
    if (handles.isEmpty) {
      state.pendingArg[userId] = PendingArg('adduser');
      await ctx.reply('No handles found. Try again, or tap Cancel.');
      return;
    }
    final tier = _pendingAddTier[userId] ?? MemberTier.member;
    _pendingAddTier[userId] = tier;
    _pendingAddUser[userId] = handles;
    final list = handles.map((handle) => '• @${this._html(handle)}').join('\n');
    final batchLabel = handles.length == 1
        ? 'this ${_tierLabel(tier)}'
        : 'these ${handles.length} ${_tierLabel(tier)}s';
    final message = await ctx.reply(
      'Add $batchLabel?\n$list',
      parseMode: ParseMode.html,
      replyMarkup: Pickers.confirm('adduser'),
    );
    state.trackInteractiveMessage(userId, userId, message.messageId);
  }

  List<String> _parseHandles(String text) => text
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .map((part) => part.startsWith('@') ? part.substring(1) : part)
      .toList();

  /// Registers (or queues) @handle and returns the outcome message.
  String _addOutcome(String rawHandle, {required String tier}) {
    final handle = rawHandle.trim().replaceFirst('@', '');
    if (!RegExp(r'^[A-Za-z0-9_]+$').hasMatch(handle)) {
      return '$rawHandle is not a valid handle.';
    }
    final userId = repo.userIdByUsername(handle);
    final existing = userId == null ? null : repo.findUser(userId);
    final pending = repo.pendingRole(handle);
    if (existing != null) {
      // A registered user is authoritative: stale pending rows are removed and
      // never produce a pending warning.
      repo.removePendingUser(handle);
      if (existing.isGlobalAdmin) {
        return '@$handle is the global admin and cannot be converted.';
      }
      if (existing.isAdmin) {
        return '@$handle is already an admin. Use /demote before converting '
            'them to a ${_tierLabel(tier)}.';
      }
      if (existing.memberTier == tier) {
        return '@$handle is already a ${_tierLabel(tier)}.';
      }
      if (!repo.setTier(existing.id, tier)) {
        return '@$handle cannot be converted to a ${_tierLabel(tier)}.';
      }
      return '✅ @$handle is now a ${_tierLabel(tier)}.';
    }
    if (pending != null) {
      repo.replacePendingUser(handle, isAdmin: false, tier: tier);
      return '⚠️ @$handle is not registered. Their pending role '
          '(${_tierLabel(pending.effectiveTier)}) was replaced with '
          '${_tierLabel(tier)}. They will be registered when they message the bot.';
    }
    if (userId != null) {
      // Seen before: register now.
      repo.upsertUser(
        User(
          id: userId,
          name: '@$handle',
          experience: Experience.newbie,
          group: '',
          memberTier: tier,
        ),
      );
      return '✅ @$handle added as a ${_tierLabel(tier)}. They can now use '
          '/start to see their commands.';
    }
    // Not seen yet: queue by handle; auto-register on first contact.
    repo.addPendingUser(handle, isAdmin: false, tier: tier);
    return '✅ @$handle queued as a ${_tierLabel(tier)} — no need for them to '
        'message first. The moment they message this bot, they are registered '
        'automatically.';
  }

  String _tierLabel(String tier) => tier == MemberTier.outMember
      ? 'out-member'
      : tier == MemberTier.member
      ? 'member'
      : tier;

}
