import 'package:televerse/televerse.dart';
import 'package:televerse/telegram.dart' hide Location, User;

import '../core/models.dart';
import '../core/repo.dart';
import '../core/config.dart';
import '../core/messages.dart';
import '../core/week.dart';
import 'command_both.dart';
import 'service.dart';
import 'state.dart';

/// Admin-facing commands and the attendance confirmation flow.
class Admin {
  final Bot bot;
  final Repo repo;
  final Config config;
  final Messages messages;
  final BotState state;
  final CycleService service;

  Admin({
    required this.bot,
    required this.repo,
    required this.config,
    required this.messages,
    required this.state,
    required this.service,
  });

  void register() {
    commandBoth(bot, 'adduser', _guard(_addUser), label: 'add-user');
    commandBoth(bot, 'status', _guard(_status), label: 'status');
    commandBoth(bot, 'users', _guard(_users), label: 'users');
    commandBoth(bot, 'prompt',
        _guard((ctx) => service.sendPrompts(_cycle(ctx))),
        label: 'prompt');
    commandBoth(bot, 'remind',
        _guard((ctx) => service.sendReminders(_cycle(ctx))),
        label: 'remind');
    commandBoth(bot, 'allocate',
        _guard((ctx) => service.allocate(_cycle(ctx))),
        label: 'allocate');
    commandBoth(bot, 'ask', _guard(_ask), label: 'ask');
    commandBoth(bot, 'confirm', _guard(_confirm), label: 'confirm');
    commandBoth(bot, 'setexp',
        _guard((ctx) => _pickUser(ctx, 'setexp')),
        label: 'set-exp');
    commandBoth(bot, 'setgroup',
        _guard((ctx) => _pickUser(ctx, 'setgroup')),
        label: 'set-group');
    commandBoth(bot, 'holidayset', _guard(_holidaySet),
        label: 'set-holiday');
    commandBoth(bot, 'holidayclear', _guard(_holidayClear),
        label: 'clear-holiday');
    commandBoth(bot, 'broadcast', _guard(_broadcast), label: 'announce');
    bot.on(bot.filters.callbackQuery, _onAdminCallback);
  }

  bool _isAdmin(Context ctx) {
    final userId = ctx.from?.id;
    if (userId == null) return false;
    // The console has admin rights but is not an admin per se.
    if (config.isConsole(userId)) return true;
    return repo.findUser(userId)?.isAdmin ?? false;
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

  Cycle _cycle(Context ctx) {
    final now = config.toLocal(Config.nowUtc());
    return repo.ensureCurrentCycle(now);
  }

  // ----------------------------------------------------------- /adduser

  Future<void> _addUser(Context ctx) async {
    final args = ctx.args;
    if (args.isEmpty) {
      await ctx.reply('Usage: /adduser @handle');
      return;
    }
    final handle = args.first.replaceFirst('@', '');
    final userId = repo.userIdByUsername(handle);
    if (userId != null && repo.findUser(userId) != null) {
      await ctx.reply('@$handle is already a member.');
      return;
    }
    if (repo.isPendingUser(handle)) {
      await ctx.reply(
        '@$handle is already queued — they will be registered the first time '
        'they message the bot.',
      );
      return;
    }
    if (userId != null) {
      // Seen before: register now.
      repo.upsertUser(User(
        id: userId,
        name: '@$handle',
        experience: Experience.newbie,
        group: 'A',
      ));
      await ctx.reply(
        '✅ @$handle added. They can now use /start to see their commands.',
      );
      return;
    }
    // Not seen yet: queue by handle; auto-register on first contact.
    repo.addPendingUser(handle, isAdmin: false);
    await ctx.reply(
      '✅ @$handle queued — no need for them to message first. The moment '
      'they message this bot, they are registered automatically.',
    );
  }

  // ----------------------------------------------------------- /status

  Future<void> _status(Context ctx) async {
    final cycle = _cycle(ctx);
    final users = repo.allUsers();
    final avail = repo.allAvailability(cycle.id);
    final responders = avail.where((a) => a.available).length;
    final nonResponders = repo.nonResponders(cycle.id);
    final allocations = repo.allocationsForCycle(cycle.id);

    final w1 = WeekMath.saturdayOfWeek(cycle.blockWeek, cycle.blockYear);
    final w2 =
        WeekMath.saturdayOfWeek(cycle.blockWeek + 1, cycle.blockYear);

    final sb = StringBuffer()
      ..writeln('📊 <b>SDSC status</b>')
      ..writeln('Cycle sessions: ${_day(w1)} & ${_day(w2)} '
          '(week ${cycle.blockWeek})')
      ..writeln('Prompt: ${_day(cycle.promptDay)}'
          '${cycle.promptSent ? ' ✅' : ''}  |  '
          'Reminder: ${_day(cycle.reminderDay)}'
          '${cycle.reminderSent ? ' ✅' : ''}  |  '
          'Deadline: ${_day(cycle.deadline)} '
          '${cycle.status == CycleStatus.closed ? '⛔' : ''}  |  '
          'Allocated: ${cycle.allocated ? '✅' : '—'}')
      ..writeln('Registered members: ${users.length}')
      ..writeln('Responded: $responders/${users.length} '
          '(+${nonResponders.length} pending)')
      ..writeln('Allocations: ${allocations.length}');

    if (nonResponders.isNotEmpty) {
      sb.writeln('⏳ Pending: ${nonResponders.map((u) => u.name).join(', ')}');
    }
    await ctx.reply(sb.toString(), parseMode: ParseMode.html);
  }

  Future<void> _users(Context ctx) async {
    final users = repo.allUsers();
    final lines = users.map((u) {
      final exp = u.experience == Experience.experienced ? 'exp' : 'new';
      return '• <b>${u.name}</b> (id ${u.id}, $exp, group ${u.group}, '
          'ocbc×${u.ocbcStreak})';
    });
    await ctx.reply(
      '<b>Registered users (${users.length})</b>\n${lines.join('\n')}',
      parseMode: ParseMode.html,
    );
  }

  // ------------------------------------------------------------- /ask

  Future<void> _ask(Context ctx) async {
    final args = ctx.args;
    if (args.isEmpty) {
      await ctx.reply('Usage: /ask <telegram_id>');
      return;
    }
    final id = int.tryParse(args.first);
    final user = id == null ? null : repo.findUser(id);
    if (user == null) {
      await ctx.reply('Unknown user id.');
      return;
    }
    final cycle = _cycle(ctx);
    await service.showAvailability(user, cycle, service.promptFor(user, cycle));
  }

  // ----------------------------------------------------------- /confirm

  Future<void> _confirm(Context ctx) async {
    final cycle = _cycle(ctx);
    final sessions = repo.sessionsForCycle(cycle.id);
    if (sessions.isEmpty) {
      await ctx.reply('No sessions yet. Run /allocate first.');
      return;
    }
    final kb = InlineKeyboard();
    for (final s in sessions) {
      final label = 'Wk${s.weekendIndex + 1} '
          '${s.day == 'sat' ? 'Sat' : 'Sun'} '
          '${s.slot.toUpperCase()} ${s.location == Location.ocbc ? 'OCBC' : 'PR'}';
      kb.text(label, 'att_sess|${s.id}');
      kb.row();
    }
    await ctx.reply(
      'Tap a session to confirm attendance:',
      replyMarkup: kb,
    );
  }

  Future<void> _sessionPicker(Context ctx, int sessionId) async {
    final session = repo.sessionById(sessionId);
    if (session == null) return;
    final allocations = repo.allocationsForCycle(session.cycleId);
    final members = allocations
        .where((a) => a.$2.id == sessionId)
        .map((a) => a.$1)
        .toList();
    final attended = repo.attendanceForSession(sessionId)
        .map((a) => a.userId)
        .toSet();

    final kb = InlineKeyboard();
    for (final user in members) {
      final mark = attended.contains(user.id) ? '✅' : '⬜';
      kb.text('$mark ${user.name}', 'att_toggle|$sessionId|${user.id}');
      kb.row();
    }
    await ctx.editMessageText(
      '${service.sessionLabel(session)}\nTap to toggle attendance:',
      replyMarkup: kb,
    );
  }

  Future<void> _toggleAttendance(Context ctx, int sessionId, int userId) async {
    final session = repo.sessionById(sessionId);
    if (session == null) return;
    final attended = repo.attendanceForSession(sessionId)
        .map((a) => a.userId)
        .toSet();
    if (attended.contains(userId)) {
      repo.raw.execute(
        'DELETE FROM attendance WHERE user_id = ? AND session_id = ?',
        [userId, sessionId],
      );
    } else {
      repo.confirmAttendance(userId, sessionId);
    }
    final allocations = repo.allocationsForCycle(session.cycleId);
    final members = allocations
        .where((a) => a.$2.id == sessionId)
        .map((a) => a.$1)
        .toList();
    final newAttended = repo.attendanceForSession(sessionId)
        .map((a) => a.userId)
        .toSet();

    final kb = InlineKeyboard();
    for (final user in members) {
      final mark = newAttended.contains(user.id) ? '✅' : '⬜';
      kb.text('$mark ${user.name}', 'att_toggle|$sessionId|${user.id}');
      kb.row();
    }
    await ctx.editMessageText(
      '${service.sessionLabel(session)}\nTap to toggle attendance:',
      replyMarkup: kb,
    );
  }

  // ----------------------------------------------------- /setexp /setgroup

  Future<void> _pickUser(Context ctx, String kind) async {
    final args = ctx.args;
    if (args.isEmpty) {
      final what = kind == 'setexp' ? 'experienced|newbie' : 'A|B';
      await ctx.reply('Usage: /$kind <$what>');
      return;
    }
    final value = args.first.toLowerCase();
    if (kind == 'setexp' && value != 'experienced' && value != 'newbie') {
      await ctx.reply('Usage: /setexp experienced|newbie');
      return;
    }
    if (kind == 'setgroup' && value != 'a' && value != 'b') {
      await ctx.reply('Usage: /setgroup A|B');
      return;
    }
    final users = repo.allUsers();
    if (users.isEmpty) {
      await ctx.reply('No registered users yet.');
      return;
    }
    final kb = InlineKeyboard();
    for (final u in users) {
      kb.text(u.name, '$kind|$value|${u.id}');
      kb.row();
    }
    await ctx.reply(
      'Set <b>${kind == 'setexp' ? 'experience to $value' : 'group to ${value.toUpperCase()}'}</b> for:',
      parseMode: ParseMode.html,
      replyMarkup: kb,
    );
  }

  Future<void> _applySet(
    Context ctx,
    String kind,
    String value,
    int userId,
  ) async {
    final user = repo.findUser(userId);
    if (user == null) return;
    if (kind == 'setexp') {
      repo.updateExperience(
        userId,
        value == 'experienced' ? Experience.experienced : Experience.newbie,
      );
    } else {
      repo.updateGroup(userId, value.toUpperCase());
    }
    await ctx.answerCallbackQuery();
    final updated = repo.findUser(userId)!;
    final exp = updated.experience == Experience.experienced
        ? 'experienced'
        : 'newbie';
    await ctx.editMessageText(
      '✅ <b>${updated.name}</b> → $exp, group ${updated.group}',
      parseMode: ParseMode.html,
    );
  }

  // ----------------------------------------------------------- holidays

  Future<void> _holidaySet(Context ctx) async {
    final args = ctx.args;
    if (args.length < 2) {
      await ctx.reply(
        'Usage: /holidayset <middle|winter|summer> <YYYY-MM-DD>\n'
        'The date can be any day of the affected week.',
      );
      return;
    }
    final kind = switch (args[0].toLowerCase()) {
      'middle' => HolidayKind.middle,
      'winter' => HolidayKind.winter,
      'summer' => HolidayKind.summer,
      _ => null,
    };
    final date = DateTime.tryParse(args[1]);
    if (kind == null || date == null) {
      await ctx.reply('Invalid arguments. See /holidayset for usage.');
      return;
    }
    final monday = WeekMath.mondayOf(date);
    repo.addHoliday(monday, kind);
    await ctx.reply(
      '✅ ${kind.name} break set for the week of ${_day(monday)}.',
    );
  }

  Future<void> _holidayClear(Context ctx) async {
    final args = ctx.args;
    if (args.isEmpty) {
      await ctx.reply('Usage: /holidayclear <YYYY-MM-DD>');
      return;
    }
    final date = DateTime.tryParse(args.first);
    if (date == null) {
      await ctx.reply('Invalid date.');
      return;
    }
    repo.removeHoliday(WeekMath.mondayOf(date));
    await ctx.reply('✅ Holiday cleared.');
  }

  // ----------------------------------------------------------- broadcast

  Future<void> _broadcast(Context ctx) async {
    final text = ctx.argsString;
    if (text == null || text.trim().isEmpty) {
      await ctx.reply('Usage: /broadcast <message>');
      return;
    }
    var sent = 0;
    for (final user in repo.allUsers()) {
      try {
        await bot.api.sendMessage(ChatID(user.id), text);
        sent++;
      } catch (_) {
        // skip members who blocked the bot
      }
    }
    await ctx.reply('✅ Sent to $sent members.');
  }

  // ------------------------------------------------------- admin callbacks

  Future<void> _onAdminCallback(Context ctx) async {
    if (!_isAdmin(ctx)) return;
    final data = ctx.callbackQuery?.data ?? '';
    final parts = data.split('|');
    switch (parts[0]) {
      case 'att_sess':
        final id = int.tryParse(parts[1]);
        if (id != null) await _sessionPicker(ctx, id);
      case 'att_toggle':
        final sid = int.tryParse(parts[1]);
        final uid = int.tryParse(parts[2]);
        if (sid != null && uid != null) {
          await _toggleAttendance(ctx, sid, uid);
        }
      case 'setexp':
      case 'setgroup':
        final uid = int.tryParse(parts[2]);
        if (uid != null) await _applySet(ctx, parts[0], parts[1], uid);
    }
  }

  static String _day(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month - 1]}';
  }
}
