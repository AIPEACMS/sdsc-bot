import 'package:televerse/televerse.dart';
import 'package:televerse/telegram.dart' hide Location, User;

import '../core/models.dart';
import '../core/repo.dart';
import '../core/config.dart';
import '../core/messages.dart';
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
    bot.command('start', _onStart);
    bot.command('reindicate', _onReindicate);
    bot.command('holiday', _onHoliday);
    bot.command('grid', _onGrid);
    bot.command('help', _onHelp);
    bot.on(bot.filters.text, _onText);
    bot.on(bot.filters.callbackQuery, _onCallback);
  }

  // ------------------------------------------------------------- /start

  Future<void> _onStart(Context ctx) async {
    final userId = ctx.from!.id;
    _recordSeen(ctx, userId);

    final user = repo.findUser(userId);
    // A user that no admin has added yet gets silence: no backend traffic,
    // no hint that the bot exists.
    if (user == null) return;

    final isConsole = config.isConsole(userId);
    final isAdmin = user.isAdmin || isConsole;

    final sb = StringBuffer()
      ..writeln('👋 <b>${user.name}</b>, here is what you can do:');

    if (isConsole) {
      sb
        ..writeln('\n<b>Console</b>')
        ..writeln('/addadmin @handle — make a user an admin')
        ..writeln('/setdate YYYY-MM-DD — debug: pretend it is that date')
        ..writeln('/resetdate — stop pretending')
        ..writeln('/demote — step down as admin (you stay console)');
    }

    if (isAdmin) {
      sb
        ..writeln('\n<b>Admin</b>')
        ..writeln('/adduser @handle — add a member (they can then use /start)')
        ..writeln('/status — cycle state and responders')
        ..writeln('/users — registered members')
        ..writeln('/prompt — send availability prompts now')
        ..writeln('/remind — remind non-responders now')
        ..writeln('/allocate — run allocation and send notices now')
        ..writeln('/ask <telegram_id> — prompt one member')
        ..writeln('/confirm — mark attendance')
        ..writeln('/setexp experienced|newbie — change a member\'s experience')
        ..writeln('/setgroup A|B — change a member\'s group')
        ..writeln('/holidayset <middle|winter|summer> <YYYY-MM-DD> — break')
        ..writeln('/holidayclear <YYYY-MM-DD> — remove a break')
        ..writeln('/broadcast <message> — message everyone');
    }

    sb
      ..writeln('\n<b>Member</b>')
      ..writeln('/reindicate — update your availability')
      ..writeln('/holiday — opt out of an upcoming break')
      ..writeln('\nUse the buttons above the keyboard to jump to a command. '
          'Type /grid to switch which grid you see (console only).');

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
        replyMarkup: RoleKeyboard.build(RoleKeyboard.roleFor(
          isConsole: false,
          isAdmin: repo.findUser(userId)?.isAdmin ?? false,
        )),
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
      replyMarkup: RoleKeyboard.build(RoleKeyboard.roleFor(
        isConsole: false,
        isAdmin: user.isAdmin,
      )),
    );
  }

  /// Which grid to show: the console's preview if set, otherwise the
  /// highest-role grid.
  String _gridFor(int userId) {
    if (config.isConsole(userId) && state.gridPreview[userId] != null) {
      return state.gridPreview[userId]!;
    }
    return RoleKeyboard.roleFor(
      isConsole: config.isConsole(userId),
      isAdmin: repo.findUser(userId)?.isAdmin ?? false,
    );
  }

  // ----------------------------------------------------- /reindicate

  Future<void> _onReindicate(Context ctx) async {
    final userId = ctx.from!.id;
    final user = repo.findUser(userId);
    if (user == null) {
      // Silent for unadded users, same as /start.
      return;
    }
    final cycle = _currentCycle(ctx);
    if (cycle == null) {
      await ctx.reply('No active availability window right now.');
      return;
    }
    state.forgetAvailability(userId);
    await service.showAvailability(user, cycle, messages.msg1(user.group));
  }

  // -------------------------------------------------------- /holiday

  Future<void> _onHoliday(Context ctx) async {
    await ctx.reply(messages.msg5Z());
  }

  // ------------------------------------------------------------ text

  Future<void> _onText(Context ctx) async {
    final userId = ctx.from!.id;
    _recordSeen(ctx, userId);
    if (ctx.hasCommand) return;
  }

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
    }
  }

  Future<void> _toggleSlot(Context ctx, int userId, List<String> parts) async {
    await ctx.answerCallbackQuery();
    if (parts.length < 3) return;
    final cycleId = int.tryParse(parts[1]);
    final slot = Slot.parse(parts[2]);
    final cycle = cycleId == null ? null : repo.cycleById(cycleId);
    if (slot == null || cycle == null) return;
    if (cycle.status == CycleStatus.allocated) {
      await ctx.reply('Availability for this cycle is already closed.');
      return;
    }

    final picks = state.picksFor(userId);
    if (!picks.remove(slot)) picks.add(slot);

    final text = 'Your availability (tap to toggle):';
    try {
      await ctx.editMessageText(
        text,
        replyMarkup: CycleService.buildKeyboard(cycle, picks),
      );
    } catch (_) {
      // message may be gone; ignore
    }
  }

  Future<void> _saveAvailability(
    Context ctx,
    int userId,
    String cycleIdRaw,
    bool notAvailable,
  ) async {
    await ctx.answerCallbackQuery();
    final cycleId = int.tryParse(cycleIdRaw);
    final cycle = cycleId == null ? null : repo.cycleById(cycleId);
    if (cycle == null) return;
    if (cycle.status == CycleStatus.allocated) {
      await ctx.reply('Availability for this cycle is already closed.');
      return;
    }

    final user = repo.findUser(userId);
    if (user == null) return;

    final picks = state.picksFor(userId).toSet();
    repo.setAvailability(Availability(
      cycleId: cycle.id,
      userId: userId,
      slots: notAvailable ? {} : picks,
      available: !notAvailable,
      updatedAt: Config.nowUtc(),
    ));
    state.forgetAvailability(userId);
    state.availabilityMessages.remove(userId);

    try {
      await ctx.editMessageText(
        notAvailable
            ? 'You indicated <b>not available</b> for the next 2 weeks.'
            : 'Availability saved.',
        parseMode: ParseMode.html,
      );
    } catch (_) {
      // message may be gone; ignore
    }
    await ctx.reply(notAvailable ? messages.msg6() : messages.msg3(picks));
  }

  // ------------------------------------------------------------- helpers

  Cycle? _currentCycle(Context ctx) {
    final now = config.toLocal(Config.nowUtc());
    return repo.ensureCurrentCycle(now);
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
        group: 'A',
        isAdmin: isAdmin,
      ));
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
