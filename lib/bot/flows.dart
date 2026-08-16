import 'package:televerse/televerse.dart';
import 'package:televerse/telegram.dart' hide Location, User;

import '../core/models.dart';
import '../core/repo.dart';
import '../core/config.dart';
import '../core/messages.dart';
import 'command_both.dart';
import 'keyboards.dart';
import 'service.dart';
import 'state.dart';

/// Member-facing commands: gated /start, availability picking, and the
/// seen-user bookkeeping that lets admins add members by handle.
class Flows {
  final Bot bot;
  final Repo repo;
  final Config config;
  final Messages messages;
  final BotState state;
  final CycleService service;

  Flows({
    required this.bot,
    required this.repo,
    required this.config,
    required this.messages,
    required this.state,
    required this.service,
  });

  void register() {
    commandBoth(bot, 'start', _onStart, label: 'start');
    commandBoth(bot, 'repick', _onRepick, label: 're-pick');
    commandBoth(bot, 'mystatus', _onMyStatus, label: 'my-status');
    commandBoth(bot, 'check-status', _onCheckStatus, label: 'check-status');
    commandBoth(bot, 'grid', _onGrid, label: 'grid');
    commandBoth(bot, 'help', _onHelp, label: 'help');

    // Bookkeeping middleware: records seen users and routes pending-input
    // text, then ALWAYS continues the chain so command handlers registered
    // later (admin, console, grid-button hears) still receive the update.
    bot.use((ctx, next) async {
      final text = ctx.message?.text;
      if (text != null) {
        final userId = ctx.from!.id;
        _recordSeen(ctx, userId);

        // A user mid-wizard (e.g. "type the message to broadcast"): their
        // next text is the argument. Consume it here and stop the chain.
        final pending = state.pendingArg[userId];
        if (pending != null && !pending.isExpired) {
          state.pendingArg.remove(userId);
          await _consumePendingArg(ctx, userId, pending.command, text);
          return;
        }
      }
      await next();
    });

    // Callback middleware: handles member-flow callbacks (slot/done/no/
    // holiday opt-out), then continues the chain for everything else
    // (admin/console).
    bot.use((ctx, next) async {
      final data = ctx.callbackQuery?.data;
      if (data == null) return next();
      final head = data.split('|').first;
      if (head == 'slot' || head == 'done' || head == 'no' ||
          head == 'holidayout') {
        await _onCallback(ctx);
        return;
      }
      if (head == 'noop') {
        // Non-interactive label rows (e.g. the picker's weekend headers):
        // dismiss the button press instantly so Telegram shows no spinner.
        await ctx.answerCallbackQuery();
        return;
      }
      await next();
    });
  }

  // ------------------------------------------------------------- /start

  Future<void> _onStart(Context ctx) async {
    final userId = ctx.from!.id;
    _recordSeen(ctx, userId);

    var user = repo.findUser(userId);
    // The console is the first user and is admin by default. On their first
    // /start, register them so they get the console grid — nobody has to add
    // them first. They become the leader of the first group (1).
    if (user == null && config.isConsole(userId)) {
      final name = ctx.from?.username != null
          ? '@${ctx.from!.username}'
          : 'Console';
      repo.upsertUser(User(
        id: userId,
        name: name,
        experience: Experience.newbie,
        group: '',
      ));
      repo.updateAdmin(userId, true);
      user = repo.findUser(userId);
    }
    // A user that no admin has added yet gets silence: no backend traffic,
    // no hint that the bot exists.
    if (user == null) return;

    final isConsole = config.isConsole(userId);
    final tier = MemberTier.of(user, isConsole: isConsole);

    // A former member: no buttons, no prompts — just a heads-up.
    if (tier == MemberTier.old) {
      await ctx.reply(
        '👋 You are no longer an active member.\n\n'
        'If this is a mistake, contact an admin.',
        replyMarkup: RoleKeyboard.build('old'),
      );
      return;
    }

    // A checker: not a member, but reports on the current week's allocation.
    if (tier == MemberTier.check) {
      await ctx.reply(
        '👋 <b>${user.name}</b>, you are a checker.\n\n'
        '/check-status — the current week\'s allocation',
        parseMode: ParseMode.html,
        replyMarkup: RoleKeyboard.build('check'),
      );
      return;
    }

    // The console can step down as a member (tier 'old') while keeping the
    // console role: no prompts, no allocation, but backend control stays.
    final retired = user.memberTier == MemberTier.old;
    final isAdmin = (user.isAdmin || isConsole) && !retired;

    final sb = StringBuffer()
      ..writeln('👋 <b>${user.name}</b>, here is what you can do:');

    if (isConsole) {
      sb
        ..writeln('\n<b>Console</b>')
        ..writeln('/hold — pause the bot: no messages at all')
        ..writeln('/unhold — resume sending')
        ..writeln('\n<i>Set-date, reset-date, sync-calendar and account '
            'management now live in the desktop console app.</i>');
    }

    if (retired) {
      sb.writeln('\n<i>You are not an active member — you will not be '
          'prompted or allocated.</i>');
    }

    if (isAdmin) {
      sb
        ..writeln('\n<b>Admin</b>')
        ..writeln('/adduser @handle — add a member (they can then use /start)')
        ..writeln('/status — cycle state and responders')
        ..writeln('/users — registered members')
        ..writeln('/prompt — send availability prompts now')
        ..writeln('/remind — remind non-responders now')
        ..writeln('/ask [telegram_id] — prompt one member')
        ..writeln('/confirm — mark attendance')
        ..writeln('/setexp experienced|newbie — change a member\'s experience');
    }

    if (!retired) {
      sb
        ..writeln('\n<b>Member</b>')
        ..writeln('/repick — update your availability')
        ..writeln('/mystatus — your picks, allocation and attendance')
        ..writeln('\nUse the buttons above the keyboard to jump to a command. '
            'Type /grid to switch which grid you see (console only).');
    }

    await ctx.reply(
      sb.toString(),
      parseMode: ParseMode.html,
      replyMarkup: RoleKeyboard.build(_gridFor(userId)),
    );
  }

  // ------------------------------------------------------------- /grid

  /// Console-only: cycle through the console/admin/member grids to preview
  /// what each role sees. Type /grid again to step to the next grid.
  Future<void> _onGrid(Context ctx) async {
    final userId = ctx.from!.id;
    _recordSeen(ctx, userId);

    if (!config.isConsole(userId)) {
      await ctx.reply(
        'Only the console can preview other grids.',
        replyMarkup: RoleKeyboard.build(_gridFor(userId)),
      );
      return;
    }

    const order = ['console', 'admin', 'member'];
    final current = state.gridPreview[userId] ?? 'console';
    final next = order[(order.indexOf(current) + 1) % order.length];
    state.gridPreview[userId] = next;

    await ctx.reply(
      '👀 <b>Preview: $next grid</b>\n'
      'This is what a $next sees. Type /grid again to cycle to the next '
      'grid, or /resetgrid to return to your own console grid.',
      parseMode: ParseMode.html,
      replyMarkup: RoleKeyboard.build(next),
    );
  }

  /// Returns to the console's own grid.
  Future<void> _onHelp(Context ctx) async {
    final userId = ctx.from!.id;
    _recordSeen(ctx, userId);
    if (config.isConsole(userId)) {
      state.gridPreview.remove(userId);
      await ctx.reply(
        'Back to your console grid.',
        replyMarkup: RoleKeyboard.build('console'),
      );
      return;
    }
    final user = repo.findUser(userId);
    if (user == null) return;
    await ctx.reply(
      'Your grid is shown above the keyboard.',
      replyMarkup: RoleKeyboard.build(_gridFor(userId)),
    );
  }

  /// Which grid to show: the console's preview if set, otherwise the
  /// highest-tier grid.
  String _gridFor(int userId) {
    if (config.isConsole(userId) && state.gridPreview[userId] != null) {
      return state.gridPreview[userId]!;
    }
    final user = repo.findUser(userId);
    return RoleKeyboard.roleFor(
      isConsole: config.isConsole(userId),
      isAdmin: user?.isAdmin ?? false,
      tier: user?.memberTier ?? MemberTier.member,
    );
  }

  // ------------------------------------------------------------ /repick

  Future<void> _onRepick(Context ctx) async {
    final userId = ctx.from!.id;
    final user = repo.findUser(userId);
    if (user == null || !_isActive(user)) {
      // Silent for unadded and non-active (check/old) users.
      return;
    }
    final window = _currentWindow(ctx);
    state.forgetAvailability(userId);
    await service.showAvailability(user, window, messages.msg1(user.group));
  }

  /// True for members/admins/console — anyone with availability duties.
  bool _isActive(User user) {
    final tier = MemberTier.of(user, isConsole: config.isConsole(user.id));
    return MemberTier.isActive(tier);
  }

  // ------------------------------------------------------- /mystatus

  /// Member-facing status: what they indicated, what they are allocated to,
  /// and their attendance (total + per location).
  Future<void> _onMyStatus(Context ctx) async {
    final userId = ctx.from!.id;
    _recordSeen(ctx, userId);
    final user = repo.findUser(userId);
    if (user == null || !_isActive(user)) return;
    final w = _currentWindow(ctx);

    final sb = StringBuffer()..writeln('📋 <b>Your status</b>');

    final avail0 = repo.getAvailability(w.sat0, userId);
    final avail1 = repo.getAvailability(w.sat1, userId);
    final picks = <Slot>{};
    if (avail0 != null && avail0.available) picks.addAll(avail0.slots);
    if (avail1 != null && avail1.available) picks.addAll(avail1.slots);
    if (picks.isNotEmpty) {
      final lines = picks.map((s) => '• ${s.toString()}').join('\n');
      sb.writeln('\n<b>Indicated</b> (this bundle):\n$lines');
    } else {
      sb.writeln('\n<b>Indicated</b>: none yet for this bundle.');
    }

    final allocated = [
      ...repo.allocationsForWeekend(w.sat0),
      ...repo.allocationsForWeekend(w.sat1),
    ]
        .where((a) => a.$1.id == userId)
        .map((a) => '• ${service.sessionLabel(a.$2)}')
        .join('\n');
    if (allocated.isNotEmpty) {
      sb.writeln('\n<b>Allocated</b>:\n$allocated');
    } else {
      sb.writeln('\n<b>Allocated</b>: not yet — this weekend locks Friday '
          '18:00, next weekend the Friday after.');
    }

    final stats = repo.attendanceStats(userId);
    sb.writeln('\n<b>Attendance</b>: ${stats.total} sessions total '
        '(${stats.ocbc} OCBC · ${stats.pasirRis} PR).');

    await ctx.reply(sb.toString(), parseMode: ParseMode.html);
  }

  // ---------------------------------------------------- /check-status

  /// The `check` tier's only command: print the current weekend's allocation.
  Future<void> _onCheckStatus(Context ctx) async {
    final userId = ctx.from!.id;
    _recordSeen(ctx, userId);
    final user = repo.findUser(userId);
    if (user == null) return;
    final tier = MemberTier.of(user, isConsole: config.isConsole(userId));
    if (tier != MemberTier.check) {
      await ctx.reply('Only checkers can view the weekly allocation.');
      return;
    }

    final now = config.toLocal(Config.nowUtc());
    final w = RollingWindow.forDate(now);
    final sb = StringBuffer()
      ..writeln('📋 <b>This week\'s allocation</b>');

    // "This week": weekend-0 during its week, weekend-1 once we roll over.
    final sat = now.isBefore(w.sat1) ? w.sat0 : w.sat1;
    final allocations = repo.allocationsForWeekend(sat);
    if (allocations.isEmpty) {
      sb.writeln('\nNo allocation published yet for ${_dateLabel(sat)}.');
      await ctx.reply(sb.toString(), parseMode: ParseMode.html);
      return;
    }

    final bySession = <int, List<String>>{};
    for (final (u, s) in allocations) {
      bySession.putIfAbsent(s.id, () => []).add(u.name);
    }

    final sessions = repo.sessionsForWeekend(sat)
      ..sort((a, b) => a.start.compareTo(b.start));

    sb.writeln();
    for (final s in sessions) {
      final names = bySession[s.id];
      sb.writeln('• ${service.sessionLabel(s)}');
      sb.writeln('   ${names == null || names.isEmpty ? '—' : names.join(', ')}');
    }

    await ctx.reply(sb.toString(), parseMode: ParseMode.html);
  }

  // ------------------------------------------------------------ text

  /// Routes a wizard's pending-input text to the command that requested it.
  /// `broadcast` = the message to send to every member (handled in admin);
  /// `adduser` = the handle to add (handled in admin);
  /// `setdate` / `synccalendar` = typed console wizard input (in console).
  Future<void> _consumePendingArg(
      Context ctx, int userId, String command, String text) async {
    switch (command) {
      case 'broadcast':
        await onBroadcastText?.call(ctx, userId, text);
      case 'adduser':
        await onAddUserText?.call(ctx, userId, text);
      case 'setdate':
        await onSetDateText?.call(ctx, userId, text);
      case 'synccalendar':
        await onSyncCalendarText?.call(ctx, userId, text);
      default:
        await ctx.reply('That input is not understood. Start over.');
    }
  }

  /// Set by main.dart: handles the pending "type the message" step of
  /// /broadcast (shows the confirm dialog).
  Future<void> Function(Context ctx, int userId, String text)?
      onBroadcastText;

  /// Set by main.dart: handles the typed handle of the /adduser wizard
  /// (shows the confirm dialog).
  Future<void> Function(Context ctx, int userId, String text)? onAddUserText;

  /// Set by main.dart: applies the typed date of the /setdate wizard.
  Future<void> Function(Context ctx, int userId, String text)? onSetDateText;

  /// Set by main.dart: applies the pasted YAML of the /sync-calendar wizard.
  Future<void> Function(Context ctx, int userId, String text)?
      onSyncCalendarText;

  // ---------------------------------------------------------- callback

  Future<void> _onCallback(Context ctx) async {
    final data = ctx.callbackQuery?.data ?? '';
    if (data.isEmpty) return;
    final parts = data.split('|');
    final userId = ctx.from!.id;
    _recordSeen(ctx, userId);

    switch (parts[0]) {
      case 'slot':
        await _toggleSlot(ctx, userId, parts);
      case 'done':
        await _saveAvailability(ctx, userId, parts[1], false);
      case 'no':
        await _saveAvailability(ctx, userId, parts[1], true);
      case 'holidayout':
        await _optOutHoliday(ctx, userId, parts);
    }
  }

  Future<void> _optOutHoliday(Context ctx, int userId, List<String> parts) async {
    await ctx.answerCallbackQuery();
    final sat0Raw = parts.length > 1 ? parts[1] : '';
    final sat0 = DateTime.tryParse(sat0Raw);
    if (sat0 == null) return;
    var opted = false;
    for (final week in [sat0, sat0.add(const Duration(days: 7))]) {
      final holiday = repo.holidayOn(week);
      if (holiday != null) {
        repo.setHolidayOptout(userId, holiday.weekStart);
        opted = true;
      }
    }
    if (!opted) return;
    // They are out for this holiday: no longer a candidate for allocation.
    state.forgetAvailability(userId);
    final now = config.toLocal(Config.nowUtc());
    for (final week in [sat0, sat0.add(const Duration(days: 7))]) {
      repo.setAvailability(Availability(
        weekendStart: week,
        userId: userId,
        bundleStart: sat0,
        slots: {},
        available: false,
        updatedAt: now,
      ));
    }
    await ctx.editMessageText(messages.msg5Z());
  }

  Future<void> _toggleSlot(Context ctx, int userId, List<String> parts) async {
    await ctx.answerCallbackQuery();
    if (parts.length < 3) return;
    final sat0 = DateTime.tryParse(parts[1]);
    final slot = Slot.parse(parts[2]);
    if (sat0 == null || slot == null) return;
    final w = RollingWindow.fromSat0(sat0);
    final sat = slot.weekendIndex == 0 ? w.sat0 : w.sat1;
    final now = config.toLocal(Config.nowUtc());
    if (w.locked(sat, now)) {
      await ctx.reply('That weekend\'s availability is already locked — '
          'its Friday deadline passed.');
      return;
    }

    final picks = state.picksFor(userId);
    if (!picks.remove(slot)) picks.add(slot);

    final text = 'Your availability (tap to toggle):';
    try {
      await ctx.editMessageText(
        text,
        replyMarkup: CycleService.buildKeyboard(
          w,
          picks,
          now: now,
          holiday: CycleService.isHolidayWindow(repo, w),
        ),
      );
    } catch (_) {
      // message may be gone; ignore
    }
  }

  Future<void> _saveAvailability(
    Context ctx,
    int userId,
    String sat0Raw,
    bool notAvailable,
  ) async {
    await ctx.answerCallbackQuery();
    final sat0 = DateTime.tryParse(sat0Raw);
    if (sat0 == null) return;
    final w = RollingWindow.fromSat0(sat0);
    final now = config.toLocal(Config.nowUtc());

    final user = repo.findUser(userId);
    if (user == null) return;

    final picks = state.picksFor(userId).toSet();
    // Done with nothing selected means the same as "Not available": an
    // explicit "cannot make it" answer, never a "(none)" confirmation.
    final unavailable = notAvailable || picks.isEmpty;
    // Save one row per weekend that is still open; locked weekends are left
    // alone (their allocation has already run or is about to).
    var saved = 0;
    for (final (wi, sat) in [(0, w.sat0), (1, w.sat1)]) {
      if (w.locked(sat, now)) continue;
      repo.setAvailability(Availability(
        weekendStart: sat,
        userId: userId,
        bundleStart: sat0,
        slots: unavailable
            ? {}
            : picks.where((s) => s.weekendIndex == wi).toSet(),
        available: !unavailable,
        updatedAt: now,
      ));
      saved++;
    }
    state.forgetAvailability(userId);
    state.availabilityMessages.remove(userId);

    if (saved == 0) {
      await ctx.reply('Both weekends are already locked — nothing was saved.');
      return;
    }

    try {
      await ctx.editMessageText(
        unavailable
            ? 'You indicated <b>not available</b> for the open weekends.'
            : 'Availability saved.',
        parseMode: ParseMode.html,
      );
    } catch (_) {
      // message may be gone; ignore
    }
    await ctx.reply(
        unavailable ? messages.msg6() : messages.msg3(picks));
  }

  /// "Sat 15 Aug" — short weekday + date.
  static String _dateLabel(DateTime d) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}';
  }

  // ------------------------------------------------------------- helpers

  RollingWindow _currentWindow(Context ctx) {
    final now = config.toLocal(Config.nowUtc());
    return RollingWindow.forDate(now);
  }

  /// Remembers (id, username) from any update so admins can add members by
  /// handle later. If the handle is in the pending queue (added by an admin
  /// before the user ever contacted the bot), the user is auto-registered
  /// right here. Never replies, never errors.
  void _recordSeen(Context ctx, int userId) {
    final username = ctx.from?.username;
    if (username == null || username.isEmpty) return;
    try {
      repo.upsertSeenUser(userId, username);
      _autoRegisterPending(ctx, userId, username);
    } catch (_) {
      // bookkeeping failure should not break the flow
    }
  }

  /// If [username] was added to the pending queue (via /adduser or
  /// /addadmin) before the user ever messaged the bot, register them now.
  void _autoRegisterPending(Context ctx, int userId, String username) {
    if (!repo.isPendingUser(username)) return;
    final isAdmin = repo.pendingIsAdmin(username);
    repo.removePendingUser(username);

    final existing = repo.findUser(userId);
    if (existing == null) {
      repo.upsertUser(User(
        id: userId,
        name: '@$username',
        experience: Experience.newbie,
        group: '',
      ));
      if (isAdmin) repo.updateAdmin(userId, true); // gets their own group
    } else if (isAdmin) {
      repo.updateAdmin(userId, true);
    }
    // Let the user know they're in — they can now use /start.
    ctx.reply(
      isAdmin
          ? 'Welcome! You have been added as an <b>admin</b>. Send /start to see your commands.'
          : 'Welcome! You have been added. Send /start to see your commands.',
      parseMode: ParseMode.html,
      replyMarkup: RoleKeyboard.build(isAdmin ? 'admin' : 'member'),
    );
  }
}
