import 'package:televerse/televerse.dart';
import 'package:televerse/telegram.dart' hide Location, User;

import '../core/config.dart';
import '../core/models.dart';
import '../core/repo.dart';
import 'calendar_sync.dart';
import 'command_both.dart';
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

  Console({
    required this.bot,
    required this.repo,
    required this.config,
    required this.state,
    this.calendarSync,
  });

  void register() {
    commandBoth(bot, 'addadmin', _guard(_addAdmin), label: 'add-admin');
    commandBoth(bot, 'setdate', _guard(_setDate), label: 'set-date');
    commandBoth(bot, 'resetdate', _guard(_resetDate), label: 'reset-date');
    commandBoth(bot, 'demote', _guard(_demote), label: 'demote');
    commandBoth(bot, 'sync-calendar', _guard(_syncCalendar),
        label: 'sync-calendar');
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
          group: 'A',
          isAdmin: true,
        ));
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

  static String _fmt(DateTime d) {
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')} $h:$m';
  }
}
