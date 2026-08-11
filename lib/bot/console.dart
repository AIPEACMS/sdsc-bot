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
import 'state.dart';

/// Console commands — only for the first user, hard-coded in [Config].
/// The console has admin rights + debug rights, but is not an admin per se:
/// they can step down from admin (/demote) while staying the console.
class Console {
  final Bot bot;
  final Repo repo;
  final Config config;
  final BotState state;
  final CalendarSync? calendarSync;
  final HoldGate holdGate;

  Console({
    required this.bot,
    required this.repo,
    required this.config,
    required this.state,
    this.calendarSync,
    required this.holdGate,
  });

  void register() {
    commandBoth(bot, 'addadmin', _guard(_addAdmin), label: 'add-admin');
    commandBoth(bot, 'setdate', _guard(_setDate), label: 'set-date');
    commandBoth(bot, 'resetdate', _guard(_resetDate), label: 'reset-date');
    commandBoth(bot, 'demote', _guard(_demote), label: 'demote');
    commandBoth(bot, 'sync-calendar', _guard(_syncCalendar),
        label: 'sync-calendar');
    commandBoth(bot, 'hold', _guard(_holdConfirm), label: 'hold');
    commandBoth(bot, 'unhold', _guard(_unholdConfirm), label: 'unhold');
    commandBoth(bot, 'addkey', _guard(_addKey), label: 'add-key');
    commandBoth(bot, 'keys', _guard(_keys), label: 'keys');
    commandBoth(bot, 'rmkey', _guard(_rmKey), label: 'rm-key');

    // Hold/unhold callbacks, console only.
    bot.use((ctx, next) async {
      final data = ctx.callbackQuery?.data;
      if (data == null) return next();
      final head = data.split('|').first;
      if (head == 'hold' || head == 'unhold') {
        if (_isConsole(ctx)) await _onHoldCallback(ctx);
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

  void Function(Context) _guard(Future<void> Function(Context) handler) {
    return (ctx) async {
      if (!_isConsole(ctx)) {
        await ctx.reply('You are not the console.');
        return;
      }
      await handler(ctx);
    };
  }

  // --------------------------------------------------------- /addadmin

  Future<void> _addAdmin(Context ctx) async {
    final args = ctx.args;
    if (args.isEmpty) {
      final seen = repo.unregisteredSeen();
      if (seen.isEmpty) {
        await ctx.reply('Usage: /addadmin @handle');
        return;
      }
      await ctx.reply(
        '➕ Promote which member to admin?',
        replyMarkup: Pickers.memberPicker(
          action: 'addadmin',
          members: seen,
          page: 0,
        ),
      );
      return;
    }
    final handle = args.first.replaceFirst('@', '');
    final userId = repo.userIdByUsername(handle);
    if (userId != null) {
      final existing = repo.findUser(userId);
      if (existing == null) {
        repo.upsertUser(User(
          id: userId,
          name: '@$handle',
          experience: Experience.newbie,
          group: '',
        ));
        repo.updateAdmin(userId, true); // gets their own group
      } else {
        repo.updateAdmin(userId, true);
      }
      await ctx.reply('✅ @$handle is now an admin.');
      return;
    }
    // Not seen yet: queue by handle; auto-promote on first contact.
    repo.addPendingUser(handle, isAdmin: true);
    await ctx.reply(
      '✅ @$handle queued as admin — no need for them to message first. The '
      'moment they message this bot, they are promoted automatically.',
    );
  }

  // -------------------------------------------------- /setdate /resetdate

  /// Debug: pretend "now" is a fixed local date (and optional time), so the
  /// console can test whether prompts/reminders/allocations would fire.
  Future<void> _setDate(Context ctx) async {
    final args = ctx.args;
    if (args.isEmpty) {
      final userId = ctx.from!.id;
      state.pendingArg[userId] = PendingArg('setdate');
      await ctx.reply(
        '📅 Send the date as <b>YYYY-MM-DD</b>, optionally with a time '
        '(YYYY-MM-DD HH:MM), or tap Cancel.',
        parseMode: ParseMode.html,
        replyMarkup: InlineKeyboard().text('❌ Cancel', 'cancel|0'),
      );
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

  /// Console steps down as admin. Admins cannot demote each other — this
  /// only ever affects the caller, and only the console may call it.
  Future<void> _demote(Context ctx) async {
    final userId = ctx.from!.id;
    if (repo.findUser(userId) == null) {
      await ctx.reply('You are not a member yet; nothing to demote.');
      return;
    }
    repo.updateAdmin(userId, false);
    await ctx.reply('✅ You stepped down as admin. You remain the console.');
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
      await ctx.reply(
        '📆 Paste the academic-calendar YAML, or tap Cancel.',
        replyMarkup: InlineKeyboard().text('❌ Cancel', 'cancel|0'),
      );
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
    await ctx.reply(
      '▶️ <b>Unhold the bot?</b>\n\n'
      'It will start sending again. Anything dropped while held is gone — '
      'nothing is replayed.',
      parseMode: ParseMode.html,
      replyMarkup: Pickers.confirm('unhold'),
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
    LogRing.log(
        'console: registered console key ${pubkey.substring(0, 12)}…');
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
