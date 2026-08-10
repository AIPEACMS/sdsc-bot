import 'package:televerse/televerse.dart';

import '../core/config.dart';
import '../core/models.dart';
import '../core/repo.dart';

/// Console commands — only for the first user, hard-coded in [Config].
/// The console has admin rights + debug rights, but is not an admin per se:
/// they can step down from admin (/demote) while staying the console.
class Console {
  final Bot bot;
  final Repo repo;
  final Config config;

  Console({
    required this.bot,
    required this.repo,
    required this.config,
  });

  void register() {
    bot.command('addadmin', _guard(_addAdmin));
    bot.command('setdate', _guard(_setDate));
    bot.command('resetdate', _guard(_resetDate));
    bot.command('demote', _guard(_demote));
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
      await ctx.reply('Usage: /addadmin @handle');
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
      await ctx.reply('Usage: /setdate YYYY-MM-DD [HH:MM]');
      return;
    }
    final date = DateTime.tryParse(args.first);
    if (date == null) {
      await ctx.reply('Invalid date. Use YYYY-MM-DD.');
      return;
    }
    var local = DateTime(date.year, date.month, date.day);
    if (args.length > 1) {
      final parts = args[1].split(':');
      final h = int.tryParse(parts[0]);
      final m = parts.length > 1 ? int.tryParse(parts[1]) : 0;
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

  static String _fmt(DateTime d) {
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')} $h:$m';
  }
}
