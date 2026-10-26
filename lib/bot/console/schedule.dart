part of '../console.dart';

extension ConsoleSchedule on Console {
  void onAddAliasInputCleared(int userId) {
    _aliasFlow.remove(userId);
  }

  Future<void> _addLocation(Context ctx) async {
    if (ctx.args.isEmpty) {
      await ctx.reply('Usage: /add_location <name>');
      return;
    }
    final name = ctx.args.join(' ').trim();
    if (name.isEmpty) {
      await ctx.reply('Usage: /add_location <name>');
      return;
    }
    final pending = repo
        .pendingLocations()
        .where((l) => _norm(l.name) == _norm(name))
        .toList();
    final LocationInfo loc;
    if (pending.isNotEmpty) {
      repo.approveLocation(pending.first.id);
      loc = repo.locationByKey(pending.first.key)!;
    } else {
      loc = repo.addLocation(name);
    }
    LogRing.log('console: location approved: ${loc.name}');
    await setTime?.onLocationApproved(loc);
    await ctx.reply(
      '✅ <b>${loc.name}</b> is now an approved location.\n'
      'Add aliases with <code>/add_alias ${loc.name}</code>.',
      parseMode: ParseMode.html,
    );
  }

  Future<void> _addAlias(Context ctx) async {
    if (ctx.args.isEmpty) {
      await ctx.reply('Usage: /add_alias <location>');
      return;
    }
    final token = ctx.args.join(' ').trim();
    final loc = repo.resolveLocation(token);
    if (loc == null) {
      await ctx.reply('No location matches "$token". See /locations.');
      return;
    }
    final userId = ctx.from!.id;
    _aliasFlow[userId] = (loc.key, <String>[]);
    state.pendingArg[userId] = PendingArg('addalias');
    await ctx.reply(
      'Adding aliases to <b>${loc.name}</b>.\n'
      'Send one alias per message (several per message also works, separated '
      'by commas). Send <b>done</b> when you are finished.',
      parseMode: ParseMode.html,
    );
  }

  /// Entry point for the /add_alias wizard: the console typed an alias.
  Future<void> onAddAliasText(Context ctx, int userId, String text) async {
    final flow = _aliasFlow[userId];
    if (flow == null) return;
    final trimmed = text.trim();
    if (trimmed.toLowerCase() == 'done') {
      repo.addAliases(flow.$1, flow.$2);
      _aliasFlow.remove(userId);
      final loc = repo.locationByKey(flow.$1);
      LogRing.log('console: aliases updated for ${loc?.name ?? flow.$1}');
      await ctx.reply(
        '✅ <b>${loc?.name ?? flow.$1}</b> aliases: '
        '${(loc?.aliases ?? const <String>[]).join(', ')}',
        parseMode: ParseMode.html,
      );
      return;
    }
    if (trimmed.toLowerCase() == 'cancel') {
      _aliasFlow.remove(userId);
      await ctx.reply('❌ Cancelled — no aliases added.');
      return;
    }
    final parts = trimmed
        .split(RegExp(r'[,\n]'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty);
    flow.$2.addAll(parts);
    state.pendingArg[userId] = PendingArg('addalias');
    await ctx.reply(
      'Added ${flow.$2.length} alias(es) so far. Send more, or <b>done</b>.',
      parseMode: ParseMode.html,
    );
  }

  String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  // ------------------------------------------- /add_key /keys /rm_key

  /// Registers the desktop console app's Ed25519 public key so it can talk to
  /// the admin API. The app generates a keypair on first run and displays its
  /// public key; the operator pastes it here. This is the only async-auth
  /// bootstrap — the Telegram console chat is the trusted channel.
  Future<void> _addKey(Context ctx) async {
    final args = ctx.args;
    if (args.isEmpty) {
      await ctx.reply(
        '🔑 Send the console app\'s public key to register it:\n'
        '<code>/add_key &lt;base64 public key&gt; [name]</code>',
        parseMode: ParseMode.html,
      );
      return;
    }
    final pubkey = args.first.trim();
    final name = args.skip(1).join(' ');
    if (pubkey.length < 16) {
      await ctx.reply('That does not look like a valid public key.');
      return;
    }
    if (repo.hasConsoleKey(pubkey)) {
      await ctx.reply('That key is already registered.');
      return;
    }
    repo.addConsoleKey(pubkey, name: name);
    LogRing.log('console: registered console key ${pubkey.substring(0, 12)}…');
    await ctx.reply(
      '✅ Console key registered.\n'
      'Run /bind_key from the admin Telegram account to enable attendance corrections.',
    );
  }

  Future<void> _bindKey(Context ctx) async {
    final userId = ctx.from?.id;
    final actor = userId == null ? null : repo.findUser(userId);
    if (userId == null ||
        actor == null ||
        (!actor.isAdmin && !actor.isGlobalAdmin)) {
      await ctx.reply('Only an admin or global admin can bind a console key.');
      return;
    }
    state.pendingArg[userId] = PendingArg('bindkey');
    await ctx.reply(
      'In the console, request a key-binding code. Paste the code here; it expires in 10 minutes.',
    );
  }

  Future<void> onBindKeyText(Context ctx, int userId, String text) async {
    final actor = repo.findUser(userId);
    if (actor == null || (!actor.isAdmin && !actor.isGlobalAdmin)) {
      await ctx.reply('Only an admin or global admin can bind a console key.');
      return;
    }
    final result = repo.redeemConsoleKeyBindingChallenge(
      text.trim(),
      actorUserId: userId,
      now: config.toLocal(Config.nowUtc()).toIso8601String(),
    );
    final message = switch (result) {
      ConsoleKeyBindingResult.success =>
        '✅ This console app key is now bound to your admin account.',
      ConsoleKeyBindingResult.expiredCode =>
        'That code expired. Request a new code in the console and try again.',
      ConsoleKeyBindingResult.notAdmin =>
        'Only an admin or global admin can bind a console key.',
      ConsoleKeyBindingResult.alreadyBound =>
        'This key is already bound and cannot be reassigned. Remove it and register a new key instead.',
      ConsoleKeyBindingResult.invalidCode ||
      ConsoleKeyBindingResult.missingKey =>
        'That code is invalid or already used. Request a new code in the console.',
    };
    await ctx.reply(message);
  }

  Future<void> _keys(Context ctx) async {
    final keys = repo.listConsoleKeys();
    if (keys.isEmpty) {
      await ctx.reply('No console keys registered yet.');
      return;
    }
    final lines = [
      for (final (i, k) in keys.indexed)
        '${i + 1}. ${k.pubkey.substring(0, 16)}…'
            '${k.name.isNotEmpty ? ' (${k.name})' : ''}',
    ];
    await ctx.reply(
      '🔑 <b>Console keys (${keys.length})</b>\n${lines.join('\n')}',
      parseMode: ParseMode.html,
    );
  }

  Future<void> _rmKey(Context ctx) async {
    final args = ctx.args;
    if (args.isEmpty) {
      await ctx.reply('Usage: /rm_key &lt;1|base64 public key&gt;');
      return;
    }
    final keys = repo.listConsoleKeys();
    final arg = args.first.trim();
    String? target;
    final index = int.tryParse(arg);
    if (index != null && index >= 1 && index <= keys.length) {
      target = keys[index - 1].pubkey;
    } else {
      for (final k in keys) {
        if (k.pubkey == arg) {
          target = k.pubkey;
          break;
        }
      }
    }
    if (target == null) {
      await ctx.reply('No matching key. Use /keys to list them.');
      return;
    }
    repo.removeConsoleKey(target);
    LogRing.log('console: removed console key ${target.substring(0, 12)}…');
    await ctx.reply('✅ Key removed — the app can no longer sign in.');
  }
}
