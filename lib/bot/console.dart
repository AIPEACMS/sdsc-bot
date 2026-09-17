import 'package:televerse/televerse.dart';
import 'package:televerse/telegram.dart' hide Location, User;

import '../core/config.dart';
import '../core/log.dart';
import '../core/models.dart';
import '../core/repo.dart';
import 'calendar_sync.dart';
import 'command_both.dart';
import 'hold.dart';
import 'pickers.dart';
import 'settime.dart';
import 'state.dart';

/// Console control-plane commands. The console is separate from the global
/// admin; when the two identities are the same, both command sets apply.
class Console {
  final Bot bot;
  final Repo repo;
  final Config config;
  final BotState state;
  final CalendarSync? calendarSync;
  final HoldGate holdGate;

  /// Set from main.dart: resumed when a new location is approved so the
  /// waiting global admin gets the updated session list.
  SetTime? setTime;

  Console({
    required this.bot,
    required this.repo,
    required this.config,
    required this.state,
    this.calendarSync,
    required this.holdGate,
    this.setTime,
  });

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
      'sync-calendar',
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

    repo.addPendingUser(handle, isAdmin: false, tier: MemberTier.check);
    await ctx.reply(
      '✅ @$handle queued as a checker. The moment they message this bot, '
      'they are registered automatically.',
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
      await ctx.reply(
        'That handle is not a registered user. Use /adduser first.',
      );
      return;
    }
    if (existing.isGlobalAdmin) {
      await ctx.reply('That user is already the global admin.');
      return;
    }
    if (existing.isAdmin) {
      await ctx.reply('✅ @$handle is already an admin.');
      return;
    }
    if (existing.memberTier != MemberTier.member) {
      repo.setTier(existing.id, MemberTier.member);
    }
    if (!repo.updateAdmin(existing.id, true)) {
      await ctx.reply('That user cannot be promoted to normal admin.');
      return;
    }
    await ctx.reply('✅ @$handle is now an admin.');
  }

  // -------------------------------------------------------- /addg /rmg

  final Map<int, int> _pendingGlobalAdmin = {};
  final Map<int, int> _pendingGlobalAdminRemoval = {};

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
    if (user == null || !user.isAdmin) {
      await ctx.reply('That handle is not a normal admin.');
      return;
    }
    repo.demoteAdmin(user.id);
    await ctx.reply('✅ @$handle is now a regular member.');
  }

  // ------------------------------------------------------ /sync-calendar

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

  /// Entry point for the sync-calendar wizard: the console pasted the YAML.
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

  static String _fmt(DateTime d) {
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')} $h:$m';
  }

  // ------------------------------------- /locations /addlocation /addalias

  /// Alias wizard state: userId → (location key, aliases typed so far).
  final Map<int, (String, List<String>)> _aliasFlow = {};

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

  Future<void> _addLocation(Context ctx) async {
    if (ctx.args.isEmpty) {
      await ctx.reply('Usage: /addlocation <name>');
      return;
    }
    final name = ctx.args.join(' ').trim();
    if (name.isEmpty) {
      await ctx.reply('Usage: /addlocation <name>');
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
      'Add aliases with <code>/addalias ${loc.name}</code>.',
      parseMode: ParseMode.html,
    );
  }

  Future<void> _addAlias(Context ctx) async {
    if (ctx.args.isEmpty) {
      await ctx.reply('Usage: /addalias <location>');
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

  /// Entry point for the /addalias wizard: the console typed an alias.
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

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  // ------------------------------------------- /addkey /keys /rmkey

  /// Registers the desktop console app's Ed25519 public key so it can talk to
  /// the admin API. The app generates a keypair on first run and displays its
  /// public key; the operator pastes it here. This is the only async-auth
  /// bootstrap — the Telegram console chat is the trusted channel.
  Future<void> _addKey(Context ctx) async {
    final args = ctx.args;
    if (args.isEmpty) {
      await ctx.reply(
        '🔑 Send the console app\'s public key to register it:\n'
        '<code>/addkey &lt;base64 public key&gt; [name]</code>',
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
      'The desktop app can now control the bot with signed requests.',
      parseMode: ParseMode.html,
    );
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
      await ctx.reply('Usage: /rmkey &lt;1|base64 public key&gt;');
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
