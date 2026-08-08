import 'package:televerse/televerse.dart';
import 'package:televerse/telegram.dart' hide Location, User;

import '../core/models.dart';
import '../core/repo.dart';
import '../core/config.dart';
import '../core/messages.dart';
import 'service.dart';
import 'state.dart';

/// Registration flow, availability picking, and member-facing commands.
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
    bot.on(bot.filters.text, _onText);
    bot.on(bot.filters.callbackQuery, _onCallback);
  }

  // ------------------------------------------------------------- /start

  Future<void> _onStart(Context ctx) async {
    final userId = ctx.from!.id;
    final user = repo.findUser(userId);
    if (user != null) {
      final exp = user.experience == Experience.experienced
          ? 'experienced'
          : 'new member';
      await ctx.reply(
        'You are registered as <b>${user.name}</b> ($exp, group ${user.group}).\n'
        'Use /reindicate to update your availability for the current cycle,\n'
        'or /holiday to opt out of an upcoming break.',
        parseMode: ParseMode.html,
      );
      return;
    }
    state.registrations[userId] = RegistrationState(stage: RegStage.name);
    await ctx.reply(
      'Welcome to the SDSC bot! Let\'s get you registered.\n'
      'What is your name?',
    );
  }

  // ----------------------------------------------------- /reindicate

  Future<void> _onReindicate(Context ctx) async {
    final userId = ctx.from!.id;
    final user = repo.findUser(userId);
    if (user == null) {
      await ctx.reply('You are not registered yet. Send /start first.');
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
    if (ctx.hasCommand) return;
    final userId = ctx.from!.id;
    final reg = state.registrations[userId];
    if (reg == null) return;
    final name = ctx.text?.trim() ?? '';
    if (name.isEmpty) return;

    if (reg.stage == RegStage.name) {
      reg.name = name;
      reg.stage = RegStage.experience;
      await ctx.reply(
        'Nice to meet you, <b>$name</b>!\nHow would you describe your '
        'experience volunteering with SDSC?',
        parseMode: ParseMode.html,
        replyMarkup: InlineKeyboard()
            .text('Experienced', 'exp|experienced')
            .row()
            .text('New / less experienced', 'exp|newbie'),
      );
    }
  }

  // ---------------------------------------------------------- callback

  Future<void> _onCallback(Context ctx) async {
    final data = ctx.callbackQuery?.data ?? '';
    if (data.isEmpty) return;
    final parts = data.split('|');
    final userId = ctx.from!.id;

    switch (parts[0]) {
      case 'exp':
        await _selectExperience(ctx, userId, parts[1]);
      case 'grp':
        await _selectGroup(ctx, userId, parts[1]);
      case 'slot':
        await _toggleSlot(ctx, userId, parts);
      case 'done':
        await _saveAvailability(ctx, userId, parts[1], false);
      case 'no':
        await _saveAvailability(ctx, userId, parts[1], true);
    }
  }

  Future<void> _selectExperience(Context ctx, int userId, String exp) async {
    final reg = state.registrations[userId];
    if (reg == null) {
      await ctx.answerCallbackQuery();
      return;
    }
    reg.experience = exp;
    reg.stage = RegStage.group;
    await ctx.answerCallbackQuery();
    await ctx.editMessageText(
      'Thanks! Finally, which group are you in? (This decides who to contact '
      'with questions.)',
      replyMarkup: InlineKeyboard()
          .text('Group A', 'grp|A')
          .row()
          .text('Group B', 'grp|B'),
    );
  }

  Future<void> _selectGroup(Context ctx, int userId, String group) async {
    await ctx.answerCallbackQuery();
    final reg = state.registrations.remove(userId);
    if (reg == null) return;

    final user = User(
      id: userId,
      name: reg.name,
      experience: reg.experience == 'experienced'
          ? Experience.experienced
          : Experience.newbie,
      group: group,
      isAdmin: config.adminIds.contains(userId),
    );
    repo.upsertUser(user);
    await ctx.editMessageText('You are registered! ✅');
    await ctx.reply(
      'You are all set, <b>${user.name}</b>!\n'
      'You will be prompted before each 2-week cycle to indicate your '
      'availability. Use /reindicate anytime to update it.',
      parseMode: ParseMode.html,
    );
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
      updatedAt: DateTime.now(),
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
    final now = config.toLocal(DateTime.now().toUtc());
    return repo.ensureCurrentCycle(now);
  }
}
