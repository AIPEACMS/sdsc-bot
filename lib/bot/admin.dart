import 'package:televerse/televerse.dart';
import 'package:televerse/telegram.dart' hide Location, User;

import '../core/models.dart';
import '../core/repo.dart';
import '../core/config.dart';
import '../core/messages.dart';
import '../core/week.dart';
import 'command_both.dart';
import 'pickers.dart';
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
    commandBoth(bot, 'broadcast', _guard(_broadcast), label: 'announce');

    // Callback middleware: handles admin prefixes, continues otherwise.
    bot.use((ctx, next) async {
      final data = ctx.callbackQuery?.data;
      if (data == null) return next();
      final head = data.split('|').first;
      const mine = {
        'att_sess', 'att_toggle', 'setexp', 'setgroup', 'setval',
        'mpick', 'bcast', 'cancel',
      };
      if (mine.contains(head)) {
        await _onAdminCallback(ctx);
        return;
      }
      await next();
    });
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
      await _addUserPicker(ctx, 0, isAdmin: false);
      return;
    }
    await _addByHandle(ctx, args.first, isAdmin: false);
  }

  /// Arg-less /adduser (and /addadmin): show a picker of users the bot has
  /// seen but not registered yet.
  Future<void> _addUserPicker(Context ctx, int page, {required bool isAdmin}) async {
    final seen = repo.unregisteredSeen();
    if (seen.isEmpty) {
      await ctx.reply(isAdmin ? 'Usage: /addadmin @handle' : 'Usage: /adduser @handle');
      return;
    }
    await ctx.reply(
      isAdmin ? '➕ Promote which member to admin?' : '➕ Add which member?',
      replyMarkup: Pickers.memberPicker(
        action: isAdmin ? 'addadmin' : 'adduser',
        members: seen,
        page: page,
      ),
    );
  }

  /// Registers a member picked from the seen-users list.
  Future<void> _addSeenById(Context ctx, int memberId, {required bool isAdmin}) async {
    final username = repo.seenUsername(memberId);
    if (username == null) return;
    final existing = repo.findUser(memberId);
    if (existing != null) {
      final alreadyAdmin = existing.isAdmin;
      if (isAdmin && !alreadyAdmin) repo.updateAdmin(memberId, true);
      await ctx.editMessageText(
        isAdmin
            ? (alreadyAdmin
                ? '✅ @$username is already an admin.'
                : '✅ @$username is now an admin.')
            : '✅ @$username is already a member.',
      );
      return;
    }
    repo.upsertUser(User(
      id: memberId,
      name: '@$username',
      experience: Experience.newbie,
      group: 'A',
      isAdmin: isAdmin,
    ));
    await ctx.editMessageText(
      isAdmin
          ? '✅ @$username promoted to admin.'
          : '✅ @$username added. They can now use /start to see their commands.',
    );
  }

  Future<void> _addByHandle(Context ctx, String rawHandle,
      {required bool isAdmin}) async {
    final handle = rawHandle.replaceFirst('@', '');
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
        isAdmin: isAdmin,
      ));
      await ctx.reply(
        isAdmin
            ? '✅ @$handle is now an admin.'
            : '✅ @$handle added. They can now use /start to see their commands.',
      );
      return;
    }
    // Not seen yet: queue by handle; auto-register on first contact.
    repo.addPendingUser(handle, isAdmin: isAdmin);
    await ctx.reply(
      isAdmin
          ? '✅ @$handle queued as admin — no need for them to message first. '
              'The moment they message this bot, they are promoted automatically.'
          : '✅ @$handle queued — no need for them to message first. The moment '
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
      await _askPicker(ctx, 0);
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

  Future<void> _askPicker(Context ctx, int page) async {
    final members = repo.allUsers();
    if (members.isEmpty) {
      await ctx.reply('No members yet. Add some with /adduser.');
      return;
    }
    await ctx.reply(
      '🤔 Send the availability picker to which member?',
      replyMarkup: Pickers.memberPicker(
        action: 'ask',
        members: members,
        page: page,
      ),
    );
  }

  Future<void> _askPick(Context ctx, int memberId) async {
    await ctx.answerCallbackQuery();
    final user = repo.findUser(memberId);
    if (user == null) return;
    final cycle = _cycle(ctx);
    await service.showAvailability(user, cycle, service.promptFor(user, cycle));
    await ctx.editMessageText('✅ Availability picker sent to ${user.name}.');
  }

  // ----------------------------------------------------------- /confirm

  Future<void> _confirm(Context ctx) async {
    final cycle = _cycle(ctx);
    final sessions = repo.sessionsForCycle(cycle.id);
    if (sessions.isEmpty) {
      await ctx.reply('No sessions yet. Run /allocate first.');
      return;
    }
    var kb = InlineKeyboard();
    for (final s in sessions) {
      final label = 'Wk${s.weekendIndex + 1} '
          '${s.day == 'sat' ? 'Sat' : 'Sun'} '
          '${s.slot.toUpperCase()} ${s.location == Location.ocbc ? 'OCBC' : 'PR'}';
      kb = kb.text(label, 'att_sess|${s.id}').row();
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

    var kb = InlineKeyboard();
    for (final user in members) {
      final mark = attended.contains(user.id) ? '✅' : '⬜';
      kb = kb.text('$mark ${user.name}', 'att_toggle|$sessionId|${user.id}').row();
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

    var kb = InlineKeyboard();
    for (final user in members) {
      final mark = newAttended.contains(user.id) ? '✅' : '⬜';
      kb = kb.text('$mark ${user.name}', 'att_toggle|$sessionId|${user.id}').row();
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
      await _pickValue(ctx, kind);
      return;
    }
    final value = args.first.toLowerCase();
    if (!_isValidValue(kind, value)) {
      await ctx.reply(kind == 'setexp'
          ? 'Usage: /setexp experienced|newbie'
          : 'Usage: /setgroup A|B');
      return;
    }
    await _pickUserFor(ctx, kind, value);
  }

  bool _isValidValue(String kind, String value) {
    if (kind == 'setexp') {
      return value == 'experienced' || value == 'newbie';
    }
    return value == 'a' || value == 'b';
  }

  /// Arg-less /setexp or /setgroup: pick the value first, then the member.
  Future<void> _pickValue(Context ctx, String kind) async {
    final choices = kind == 'setexp'
        ? [('Experienced', 'experienced'), ('Newbie', 'newbie')]
        : [('Group A', 'a'), ('Group B', 'b')];
    var kb = InlineKeyboard();
    for (final (label, value) in choices) {
      kb = kb.text(label, 'setval|$kind|$value').row();
    }
    kb = kb.text('❌ Cancel', 'cancel|0');
    await ctx.reply(
      kind == 'setexp' ? 'Set experience to:' : 'Set group to:',
      replyMarkup: kb,
    );
  }

  Future<void> _pickUserFor(Context ctx, String kind, String value) async {
    final users = repo.allUsers();
    if (users.isEmpty) {
      await ctx.reply('No registered users yet.');
      return;
    }
    var kb = InlineKeyboard();
    for (final u in users) {
      kb = kb.text(u.name, '$kind|$value|${u.id}').row();
    }
    final text = 'Set <b>'
        '${kind == 'setexp' ? 'experience to $value' : 'group to ${value.toUpperCase()}'}'
        '</b> for:';
    if (ctx.callbackQuery != null) {
      await ctx.editMessageText(text, parseMode: ParseMode.html, replyMarkup: kb);
    } else {
      await ctx.reply(text, parseMode: ParseMode.html, replyMarkup: kb);
    }
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

  // ----------------------------------------------------------- broadcast

  /// /broadcast with a message runs immediately; without one, starts the
  /// ask-to-type wizard (grid button press) then confirms before sending.
  Future<void> _broadcast(Context ctx) async {
    final text = ctx.argsString;
    if (text == null || text.trim().isEmpty) {
      final userId = ctx.from!.id;
      state.pendingArg[userId] = PendingArg('broadcast');
      await ctx.reply(
        '📢 Send me the message to broadcast to all members, or /cancel.',
        replyMarkup: InlineKeyboard().text('❌ Cancel', 'cancel|0'),
      );
      return;
    }
    await _confirmBroadcast(ctx, text.trim());
  }

  /// Entry point for the wizard: the user typed the broadcast text; show the
  /// confirm dialog.
  Future<void> onBroadcastText(
      Context ctx, int userId, String text) async {
    _pendingBroadcast[userId] = text;
    await _confirmBroadcast(ctx, text.trim());
  }

  Future<void> _confirmBroadcast(Context ctx, String text) async {
    final preview = text.length > 200 ? '${text.substring(0, 200)}…' : text;
    await ctx.reply(
      '📢 Send this to all members?\n\n<i>$preview</i>',
      parseMode: ParseMode.html,
      replyMarkup: Pickers.confirm('bcast'),
    );
  }

  Future<void> _doBroadcast(Context ctx, String text) async {
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
      case 'setval':
        final kind = parts.length > 1 ? parts[1] : '';
        final value = parts.length > 2 ? parts[2] : '';
        if (kind == 'setexp' || kind == 'setgroup') {
          await ctx.answerCallbackQuery();
          await _pickUserFor(ctx, kind, value);
        }
      case 'mpick':
        await _onMemberPick(ctx, parts);
      case 'bcast':
        final yes = parts.length > 1 && parts[1] == 'yes';
        await ctx.answerCallbackQuery();
        await ctx.editMessageText(
          yes ? 'Sending…' : 'Cancelled — nothing was sent.',
        );
        if (yes) {
          final text = _pendingBroadcast.remove(ctx.from!.id);
          if (text != null) await _doBroadcast(ctx, text);
        }
      case 'cancel':
        await ctx.answerCallbackQuery();
        state.pendingArg.remove(ctx.from!.id);
        _pendingBroadcast.remove(ctx.from!.id);
        await ctx.editMessageText('Cancelled.');
    }
  }

  /// The broadcast message awaiting confirmation, per admin.
  final Map<int, String> _pendingBroadcast = {};

  Future<void> _onMemberPick(Context ctx, List<String> parts) async {
    await ctx.answerCallbackQuery();
    final (action, page, target) = Pickers.parsePick(parts);
    if (target == 'cancel') {
      await ctx.editMessageText('Cancelled.');
      return;
    }
    if (action == 'ask') {
      if (target == 'prev' || target == 'next') {
        // Re-render the picker at the new page.
        final members = repo.allUsers();
        await ctx.editMessageText(
          '🤔 Send the availability picker to which member?',
          replyMarkup: Pickers.memberPicker(
            action: 'ask',
            members: members,
            page: target == 'prev' ? page - 1 : page + 1,
          ),
        );
        return;
      }
      final memberId = int.tryParse(target);
      if (memberId != null) await _askPick(ctx, memberId);
      return;
    }
    if (action == 'adduser' || action == 'addadmin') {
      final isAdmin = action == 'addadmin';
      if (target == 'prev' || target == 'next') {
        final seen = repo.unregisteredSeen();
        await ctx.editMessageText(
          isAdmin ? '➕ Promote which member to admin?' : '➕ Add which member?',
          replyMarkup: Pickers.memberPicker(
            action: action,
            members: seen,
            page: target == 'prev' ? page - 1 : page + 1,
          ),
        );
        return;
      }
      final memberId = int.tryParse(target);
      if (memberId != null) {
        await _addSeenById(ctx, memberId, isAdmin: isAdmin);
      }
      return;
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
