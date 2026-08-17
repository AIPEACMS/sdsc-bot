import 'package:televerse/televerse.dart';
import 'package:televerse/telegram.dart' hide Location, User;

import '../core/models.dart';
import '../core/repo.dart';
import '../core/config.dart';
import '../core/messages.dart';
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
    commandBoth(bot, 'prompt', _guard(_promptConfirm), label: 'prompt');
    commandBoth(bot, 'remind', _guard(_remindConfirm), label: 'remind');
    commandBoth(bot, 'allocate',
        _guard((ctx) async {
          final w = _window(ctx);
          await service.allocateWeekend(w.sat0);
          await service.allocateWeekend(w.sat1);
        }),
        label: 'allocate');
    commandBoth(bot, 'ask', _guard(_ask), label: 'ask');
    commandBoth(bot, 'confirm', _guard(_confirm), label: 'mark-attend');
    commandBoth(bot, 'setexp',
        _guard((ctx) => _pickUser(ctx, 'setexp')),
        label: 'set-exp');
    commandBoth(bot, 'broadcast', _guard(_broadcast), label: 'announce');

    // Callback middleware: handles admin prefixes, continues otherwise.
    bot.use((ctx, next) async {
      final data = ctx.callbackQuery?.data;
      if (data == null) return next();
      final head = data.split('|').first;
      const mine = {
        'att_sess', 'att_toggle', 'setexp', 'setval',
        'mpick', 'bcast', 'adduser', 'prompt', 'remind', 'cancel',
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

  RollingWindow _window(Context ctx) =>
      RollingWindow.forDate(config.toLocal(Config.nowUtc()));

  // ----------------------------------------------------------- /adduser

  /// /adduser with no args starts the wizard: the admin sends one handle and
  /// confirms before anything is added. With a handle, adds it directly.
  Future<void> _addUser(Context ctx) async {
    final args = ctx.args;
    if (args.isEmpty) {
      final userId = ctx.from!.id;
      state.pendingArg[userId] = PendingArg('adduser');
      await ctx.reply(
        '➕ Send me the handle to add (e.g. <b>@username</b>), or tap Cancel.',
        parseMode: ParseMode.html,
        replyMarkup: InlineKeyboard().text('❌ Cancel', 'cancel|0'),
      );
      return;
    }
    await ctx.reply(_addOutcome(args.first, isAdmin: false));
  }

  /// Entry point for the /adduser wizard: the admin typed the handle; show
  /// the confirm dialog.
  Future<void> onAddUserText(Context ctx, int userId, String text) async {
    final handle = text.trim().replaceFirst('@', '');
    if (handle.isEmpty || handle.contains(' ')) {
      await ctx.reply('That is not a valid handle. Try again, or /cancel.');
      return;
    }
    _pendingAddUser[userId] = handle;
    await ctx.reply(
      'Add <b>@$handle</b>?',
      parseMode: ParseMode.html,
      replyMarkup: Pickers.confirm('adduser'),
    );
  }

  /// The handle awaiting confirmation per admin, from the /adduser wizard.
  final Map<int, String> _pendingAddUser = {};

  /// Registers a member picked from the seen-users list (add-admin picker).
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
      group: '',
    ));
    if (isAdmin) repo.updateAdmin(memberId, true); // gets their own group
    await ctx.editMessageText(
      isAdmin
          ? '✅ @$username promoted to admin.'
          : '✅ @$username added. They can now use /start to see their commands.',
    );
  }

  /// Registers (or queues) @handle and returns the outcome message.
  String _addOutcome(String rawHandle, {required bool isAdmin}) {
    final handle = rawHandle.replaceFirst('@', '');
    final userId = repo.userIdByUsername(handle);
    if (userId != null && repo.findUser(userId) != null) {
      return '@$handle is already a member.';
    }
    if (repo.isPendingUser(handle)) {
      return '@$handle is already queued — they will be registered the first '
          'time they message the bot.';
    }
    if (userId != null) {
      // Seen before: register now.
      repo.upsertUser(User(
        id: userId,
        name: '@$handle',
        experience: Experience.newbie,
        group: '',
      ));
      if (isAdmin) repo.updateAdmin(userId, true); // gets their own group
      return isAdmin
          ? '✅ @$handle is now an admin.'
          : '✅ @$handle added. They can now use /start to see their commands.';
    }
    // Not seen yet: queue by handle; auto-register on first contact.
    repo.addPendingUser(handle, isAdmin: isAdmin);
    return isAdmin
        ? '✅ @$handle queued as admin — no need for them to message first. '
            'The moment they message this bot, they are promoted automatically.'
        : '✅ @$handle queued — no need for them to message first. The moment '
            'they message this bot, they are registered automatically.';
  }

  // ----------------------------------------------------------- /status

  Future<void> _status(Context ctx) async {
    final w = _window(ctx);
    final users = repo.activeUsers();
    final activeIds = {for (final u in users) u.id};
    final avail = [
      ...repo.availabilityForWeekend(w.sat0),
      ...repo.availabilityForWeekend(w.sat1),
    ].where((a) => activeIds.contains(a.userId));
    // One member responding to both weekends has two rows — count distinct
    // responders, not rows.
    final responderIds = <int>{for (final a in avail) a.userId};
    final responders = responderIds.length;
    final pending = repo.reminderTargets(w.sat0);

    final sb = StringBuffer()
      ..writeln('📊 <b>SDSC status</b>')
      ..writeln('Bundle: ${_day(w.sat0)} & ${_day(w.sat1)}')
      ..writeln('Prompt: ${_day(w.promptDay)}  |  '
          'Reminder: ${_day(w.reminderDay)}  |  '
          'Lock W1: ${_day(w.deadline0)}  |  '
          'Lock W2: ${_day(w.deadline1)}')
      ..writeln('Registered members: ${users.length}')
      ..writeln('Responded: $responders/${users.length} '
          '(+${pending.length} pending)');

    if (pending.isNotEmpty) {
      sb.writeln('⏳ Pending: ${pending.map((u) => u.name).join(', ')}');
    }
    await ctx.reply(sb.toString(), parseMode: ParseMode.html);
  }

  Future<void> _users(Context ctx) async {
    final users = repo.allUsers().where((u) {
      // The console shows only while still a member (or admin); once demoted
      // out of membership entirely, they disappear from the list.
      if (!config.isConsole(u.id)) return true;
      return u.isAdmin || MemberTier.isActive(u.memberTier);
    }).toList();
    final lines = users.map((u) {
      final isConsole = config.isConsole(u.id);
      final tier = isConsole
          ? (u.isAdmin ? MemberTier.admin : MemberTier.member)
          : MemberTier.of(u, isConsole: false);
      final exp = u.experience == Experience.experienced ? 'exp' : 'new';
      final stats = repo.attendanceStats(u.id);
      return '• <b>${u.name}</b> ($tier, '
          'group ${u.group.isEmpty ? 'none' : u.group}, '
          '$exp, ocbc × ${stats.ocbc}, pr × ${stats.pasirRis})';
    });
    await ctx.reply(
      '<b>Registered users (${users.length})</b>\n${lines.join('\n')}',
      parseMode: ParseMode.html,
    );
  }

  // ------------------------------------------------- /prompt /remind confirm

  /// /prompt asks for confirmation before messaging everyone.
  Future<void> _promptConfirm(Context ctx) async {
    await ctx.reply(
      '📣 Send availability prompts to all members now?',
      replyMarkup: Pickers.confirm('prompt'),
    );
  }

  /// /remind asks for confirmation before messaging non-responders.
  Future<void> _remindConfirm(Context ctx) async {
    await ctx.reply(
      '⏰ Remind non-responders now?',
      replyMarkup: Pickers.confirm('remind'),
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
    final w = _window(ctx);
    final text = service.promptFor(user, w) ?? messages.msg1(user.group);
    await service.showAvailability(user, w, text);
  }

  Future<void> _askPicker(Context ctx, int page) async {
    final members = repo.activeUsers();
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
    final w = _window(ctx);
    final text = service.promptFor(user, w) ?? messages.msg1(user.group);
    await service.showAvailability(user, w, text);
    await ctx.editMessageText('✅ Availability picker sent to ${user.name}.');
  }

  // ----------------------------------------------------------- /confirm

  /// The weekend /confirm marks: the current week's Saturday from 00:00
  /// Saturday onward; before that, the previous Saturday (the week just
  /// finished) can still be marked.
  DateTime _currentWeekendSat() {
    final now = config.toLocal(Config.nowUtc());
    final w = RollingWindow.forDate(now);
    return now.isBefore(w.sat0)
        ? w.sat0.subtract(const Duration(days: 7))
        : w.sat0;
  }

  /// The calling admin's group. Empty when the user has no group (e.g. the
  /// console before being added as a member) — then no group filter applies.
  String _adminGroup(Context ctx) {
    final user = repo.findUser(ctx.from?.id ?? 0);
    return user?.group ?? '';
  }

  /// The calling admin's own group only: the /confirm flow is scoped to the
  /// group the admin leads, so a leader never marks (or is reminded about)
  /// another group's members.
  Future<void> _confirm(Context ctx) async {
    final sat = _currentWeekendSat();
    final sessions = repo.sessionsForWeekend(sat);
    if (sessions.isEmpty) {
      await ctx.reply('No sessions yet. Run /allocate first.');
      return;
    }
    final group = _adminGroup(ctx);
    var kb = InlineKeyboard();
    for (final s in sessions) {
      final mark = _sessionMark(s, group);
      final loc = s.location == Location.ocbc ? 'OCBC' : 'PR';
      kb = kb
          .text('$mark$loc Sat ${s.slot.toUpperCase()}', 'att_sess|${s.id}')
          .row();
    }
    await ctx.reply(
      'Mark attendance for ${_day(sat)}:\n'
      '🔵 some of your group unmarked · 🟢 all marked · '
      'no icon = nobody from your group',
      replyMarkup: kb,
    );
  }

  /// The status mark for one session's button, scoped to the admin's [group]:
  /// '' (transparent) when nobody from the group is allocated, '🟢 ' when
  /// every allocated member is marked, '🔵 ' when some are still unmarked.
  String _sessionMark(Session s, String group) {
    final members = _sessionMembers(s, group);
    if (members.isEmpty) return '';
    final marks = repo.attendanceForSession(s.id);
    for (final user in members) {
      if (!marks.any((a) => a.userId == user.id)) return '🔵 ';
    }
    return '🟢 ';
  }

  /// The admin's group members allocated to [session] (empty group = every
  /// group).
  List<User> _sessionMembers(Session s, String group) => repo
      .allocationsForWeekend(s.weekendStart)
      .where((a) => a.$2.id == s.id && (group.isEmpty || a.$1.group == group))
      .map((a) => a.$1)
      .toList();

  Future<void> _sessionPicker(Context ctx, int sessionId) async {
    final session = repo.sessionById(sessionId);
    if (session == null) return;
    await _renderSessionPicker(ctx, session);
  }

  /// The per-member attendance list for one session, scoped to the admin's
  /// own group. Both the picker entry and the post-toggle re-render go
  /// through here so they always show the same members.
  Future<void> _renderSessionPicker(Context ctx, Session session) async {
    final group = _adminGroup(ctx);
    final members = _sessionMembers(session, group);

    if (members.isEmpty) {
      await ctx.editMessageText(
        '${service.sessionLabel(session)}\n'
        'No one from your group is allocated here.',
      );
      return;
    }

    final state = repo.attendanceForSession(session.id);
    var kb = InlineKeyboard();
    for (final user in members) {
      final mark = _markFor(user.id, state);
      kb = kb
          .text('$mark ${user.name}', 'att_toggle|${session.id}|${user.id}')
          .row();
    }
    await ctx.editMessageText(
      '${service.sessionLabel(session)}\n'
      'Tap to cycle: ⬜ unmarked → ✅ present → ❌ not participated → ⬜',
      replyMarkup: kb,
    );
  }

  static String _markFor(int userId, List<Attendance> marks) {
    for (final m in marks) {
      if (m.userId == userId) return m.attended ? '✅' : '❌';
    }
    return '⬜';
  }

  Future<void> _toggleAttendance(Context ctx, int sessionId, int userId) async {
    final session = repo.sessionById(sessionId);
    if (session == null) return;
    final current = repo
        .attendanceForSession(sessionId)
        .where((a) => a.userId == userId)
        .toList();
    if (current.isEmpty) {
      service.markAttendance(userId, sessionId, attended: true);
    } else if (current.first.attended) {
      repo.setAttendanceState(userId, sessionId, attended: false);
    } else {
      repo.clearAttendance(userId, sessionId);
    }
    await _renderSessionPicker(ctx, session);
  }

  // ----------------------------------------------------------- /setexp

  Future<void> _pickUser(Context ctx, String kind) async {
    final args = ctx.args;
    if (args.isEmpty) {
      await _pickValue(ctx, kind);
      return;
    }
    final value = args.first.toLowerCase();
    if (kind != 'setexp' || !_isValidValue(kind, value)) {
      await ctx.reply('Usage: /setexp experienced|newbie');
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

  /// Arg-less /setexp: pick the value first, then the member.
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
    final users = repo.activeUsers();
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
      '✅ <b>${updated.name}</b> → $exp, '
          'group ${updated.group.isEmpty ? 'none' : updated.group}',
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
    for (final user in repo.activeUsers()) {
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
        final id = int.tryParse(parts.length > 1 ? parts[1] : '');
        if (id != null) await _sessionPicker(ctx, id);
      case 'att_toggle':
        final sid = int.tryParse(parts[1]);
        final uid = int.tryParse(parts[2]);
        if (sid != null && uid != null) {
          await _toggleAttendance(ctx, sid, uid);
        }
      case 'setexp':
        final uid = int.tryParse(parts[2]);
        if (uid != null) await _applySet(ctx, parts[0], parts[1], uid);
      case 'setval':
        final kind = parts.length > 1 ? parts[1] : '';
        final value = parts.length > 2 ? parts[2] : '';
        if (kind == 'setexp') {
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
      case 'adduser':
        final yes = parts.length > 1 && parts[1] == 'yes';
        await ctx.answerCallbackQuery();
        if (!yes) {
          await ctx.editMessageText('Cancelled — nobody was added.');
          return;
        }
        final handle = _pendingAddUser.remove(ctx.from!.id);
        if (handle == null) return;
        await ctx.editMessageText(_addOutcome(handle, isAdmin: false));
      case 'prompt':
        final yes = parts.length > 1 && parts[1] == 'yes';
        await ctx.answerCallbackQuery();
        await ctx.editMessageText(yes ? 'Sending prompts…' : 'Cancelled — nothing was sent.');
        if (yes) await service.sendPrompts(_window(ctx));
      case 'remind':
        final yes = parts.length > 1 && parts[1] == 'yes';
        await ctx.answerCallbackQuery();
        await ctx.editMessageText(yes ? 'Sending reminders…' : 'Cancelled — nothing was sent.');
        if (yes) await service.sendReminders(_window(ctx));
      case 'cancel':
        await ctx.answerCallbackQuery();
        state.pendingArg.remove(ctx.from!.id);
        _pendingBroadcast.remove(ctx.from!.id);
        _pendingAddUser.remove(ctx.from!.id);
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
        final members = repo.activeUsers();
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
    if (action == 'addadmin') {
      if (target == 'prev' || target == 'next') {
        final seen = repo.unregisteredSeen();
        await ctx.editMessageText(
          '➕ Promote which member to admin?',
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
        await _addSeenById(ctx, memberId, isAdmin: true);
      }
      return;
    }
  }

  static String _day(DateTime d) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}';
  }
}
