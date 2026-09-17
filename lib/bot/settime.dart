import 'package:televerse/televerse.dart';
import 'package:televerse/telegram.dart' hide Location, User;

import '../core/config.dart';
import '../core/log.dart';
import '../core/models.dart';
import '../core/repo.dart';
import '../core/schedule_parse.dart';
import 'command_both.dart';
import 'pickers.dart';
import 'service.dart';
import 'state.dart';

/// `/settime` — the global admin replaces the activity-schedule template.
///
/// Deliberately a typed command only: it is NOT part of any role grid. The
/// gadmin sends one line per session -- day, start time, end time, location
/// (for example `sat 9:00 13:00 PR`) -- then `done`; the bot parses them,
/// resolves locations (aliases included), asks about unknown ones, and shows a
/// confirm button. Confirming swaps the template and rebuilds the open
/// weekends.
class SetTime {
  final Bot bot;
  final Repo repo;
  final Config config;
  final BotState state;
  final CycleService service;

  SetTime({
    required this.bot,
    required this.repo,
    required this.config,
    required this.state,
    required this.service,
  });

  /// Drafts in progress, per gadmin user id.
  final Map<int, _Draft> _drafts = {};

  void register() {
    commandBoth(bot, state, 'settime', _guard(_start), label: 'settime');
    bot.use((ctx, next) async {
      final data = ctx.callbackQuery?.data;
      if (data == null) return next();
      final head = data.split('|').first;
      if (head == 'settime') {
        if (_isGadmin(ctx)) await _onConfirmOrCancel(ctx);
        return;
      }
      if (head == 'stloc') {
        if (_isGadmin(ctx)) await _onLocationChoice(ctx);
        return;
      }
      await next();
    });
  }

  bool _isGadmin(Context ctx) {
    final userId = ctx.from?.id;
    return userId != null && repo.findUser(userId)?.isGlobalAdmin == true;
  }

  void Function(Context) _guard(Future<void> Function(Context) handler) {
    return (ctx) async {
      if (!_isGadmin(ctx)) {
        await ctx.reply('You are not the global admin.');
        return;
      }
      await handler(ctx);
    };
  }

  // ------------------------------------------------------------- /settime

  Future<void> _start(Context ctx) async {
    final userId = ctx.from!.id;
    _drafts[userId] = _Draft();
    state.pendingArg[userId] = PendingArg('settime');
    await ctx.reply(
      '🗓 <b>Set the activity times</b>\n\n'
      'Send one line per session:\n'
      '<code>&lt;day&gt; &lt;startTime&gt; &lt;endTime&gt; &lt;location&gt;</code>\n\n'
      'For example: <code>sat 9:00 13:00 PR</code>\n\n'
      'You can send multiple lines (in one message or several), then wrap up '
      'by sending <b>done</b>.',
      parseMode: ParseMode.html,
      replyMarkup: InlineKeyboard().text('❌ Cancel', 'settime|no'),
    );
  }

  /// Entry point for the wizard: the gadmin typed one or more lines.
  Future<void> onText(Context ctx, int userId, String text) async {
    final draft = _drafts[userId];
    if (draft == null) return;
    final trimmed = text.trim();
    if (trimmed.toLowerCase() == 'done') {
      await _finish(ctx, userId);
      return;
    }
    if (trimmed.toLowerCase() == 'cancel') {
      _drafts.remove(userId);
      await ctx.reply('❌ Cancelled — the activity list is unchanged.');
      return;
    }

    final errors = <String>[];
    final firstIndex = draft.lines.length + 1;
    for (final raw in trimmed.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final parsed = parseSessionLine(line);
      if (parsed is String) {
        errors.add('❌ $line — $parsed');
        continue;
      }
      draft.lines.add(parsed as ParsedSession);
    }
    final total = draft.lines.length;
    final added = total - firstIndex + 1;

    // Re-arm so the next message continues the wizard.
    state.pendingArg[userId] = PendingArg('settime');

    final sb = StringBuffer();
    if (added == 1) {
      sb.writeln('✅ Added session $total ($total so far):');
    } else if (added > 1) {
      sb.writeln('✅ Added sessions $firstIndex-$total ($total so far):');
    }
    // Show exactly what was just added, numbered as in the final confirmation.
    for (var i = firstIndex; i <= total; i++) {
      sb.writeln(_sessionLine(draft, draft.lines[i - 1], i));
    }
    if (errors.isNotEmpty) {
      if (added > 0) sb.writeln();
      sb.write(errors.join('\n'));
    }
    if (added == 0 && errors.isEmpty) {
      sb.write('Send a session line, or <b>done</b> to finish.');
    } else {
      sb.write('\nSend more, or <b>done</b> to finish.');
    }
    await ctx.reply(sb.toString().trimRight(), parseMode: ParseMode.html);
  }

  /// Turns the draft into a confirmation, or asks about unknown locations.
  Future<void> _finish(Context ctx, int userId) async {
    final draft = _drafts[userId];
    if (draft == null) return;
    if (draft.lines.isEmpty) {
      await ctx.reply('Nothing to set. Send a session line first, or /settime.');
      return;
    }
    state.pendingArg.remove(userId);
    final unresolved = draft.unresolvedTokens(repo);
    if (unresolved.isNotEmpty) {
      await _askLocation(ctx, userId, unresolved.first);
      return;
    }
    await _showConfirmation(ctx, userId);
  }

  /// "Is `<token>` a new location?" with the approved locations as buttons and
  /// a prominent "new location" button on top.
  Future<void> _askLocation(
    Context ctx,
    int userId,
    String token,
  ) async {
    final approved = repo.approvedLocations()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    var kb = InlineKeyboard()
        .text('🆕 It\'s a new location', 'stloc|new')
        .row();
    for (final l in approved) {
      kb = kb.text(l.name, 'stloc|${l.key}').row();
    }
    kb = kb.text('❌ Cancel', 'settime|no');
    await ctx.reply(
      'I don\'t recognise the location <b>${_html(token)}</b>.\n\n'
      'Is it one of these, or a new location?',
      parseMode: ParseMode.html,
      replyMarkup: kb,
    );
  }

  Future<void> _onLocationChoice(Context ctx) async {
    await ctx.answerCallbackQuery();
    final userId = ctx.from!.id;
    final draft = _drafts[userId];
    if (draft == null) {
      await ctx.editMessageText('This draft has expired. Start again with /settime.');
      return;
    }
    final parts = (ctx.callbackQuery?.data ?? '').split('|');
    final choice = parts.length > 1 ? parts[1] : '';
    final token = draft.unresolvedTokens(repo).firstOrNull;
    if (token == null) {
      await ctx.editMessageText('All locations are known now.');
      return;
    }
    if (choice == 'new') {
      draft.awaitingNameFor = token;
      state.pendingArg[userId] = PendingArg('settime-newname');
      await ctx.editMessageText(
        'What is the full name of the new location? Send it in one message.',
      );
      return;
    }
    final loc = repo.locationByKey(choice);
    if (loc == null || !loc.isApproved) {
      await ctx.editMessageText('That location is no longer available.');
      return;
    }
    draft.resolved[token] = loc.key;
    await ctx.editMessageText(
      '✅ <b>${_html(token)}</b> → ${_html(loc.name)}.',
      parseMode: ParseMode.html,
    );
    await _continueDraft(ctx, userId);
  }

  /// Entry point for the wizard: the gadmin typed the full name of a new
  /// location. Registers a pending request, tells the console, and waits.
  Future<void> onNewNameText(Context ctx, int userId, String text) async {
    final draft = _drafts[userId];
    if (draft == null) return;
    final token = draft.awaitingNameFor;
    if (token == null) return;
    final name = text.trim();
    if (name.isEmpty) {
      state.pendingArg[userId] = PendingArg('settime-newname');
      await ctx.reply('Send the full name of the new location.');
      return;
    }
    final loc = repo.requestLocation(name, requestedBy: userId);
    draft.awaitingNameFor = null;
    draft.requestedNames[token] = loc.name;
    state.pendingArg.remove(userId);

    // Tell the console on the trusted channel, so it can approve and add
    // aliases (chat: /addlocation + /addalias, or the desktop console app).
    LogRing.log('settime: new location requested: ${loc.name}');
    try {
      await bot.api.sendMessage(
        ChatID(config.consoleId),
        '🆕 <b>New location requested</b>\n\n'
        'The global admin asked to add <b>${_html(loc.name)}</b>.\n'
        'Approve it with <code>/addlocation ${_html(loc.name)}</code> '
        '(optionally /addalias afterwards), or from the console app.',
        parseMode: ParseMode.html,
      );
    } catch (_) {
      // console may be unreachable; the request is stored either way
    }

    await ctx.reply(
      '🕓 Thank you. I have asked the console to add <b>${_html(loc.name)}</b>. '
      'Please wait a moment — I will continue here once it is approved.',
      parseMode: ParseMode.html,
    );
  }

  /// Called by the console (chat command or admin API) when a location is
  /// approved: resolve it in any waiting draft and resume that gadmin with the
  /// new session list and the confirm button.
  Future<void> onLocationApproved(LocationInfo loc) async {
    for (final entry in _drafts.entries.toList()) {
      final userId = entry.key;
      final draft = entry.value;
      var touched = false;
      for (final e in draft.requestedNames.entries.toList()) {
        if (_norm(e.value) == _norm(loc.name)) {
          draft.resolved[e.key] = loc.key;
          draft.requestedNames.remove(e.key);
          touched = true;
        }
      }
      if (touched) await _resume(userId);
    }
  }

  /// Resumes a draft after the console approved a location, from a fresh
  /// message (the gadmin may have typed the name minutes ago).
  Future<void> _resume(int userId) async {
    final draft = _drafts[userId];
    if (draft == null) return;
    final unresolved = draft.unresolvedTokens(repo);
    final kb = unresolved.isNotEmpty
        ? InlineKeyboard().text('🆕 It\'s a new location', 'stloc|new')
        : Pickers.confirm('settime');
    await bot.api.sendMessage(
      ChatID(userId),
      '✅ <b>The new location is added.</b>\n\n${_confirmationText(draft)}',
      parseMode: ParseMode.html,
      replyMarkup: kb,
    );
  }

  Future<void> _continueDraft(Context ctx, int userId) async {
    final draft = _drafts[userId];
    if (draft == null) return;
    final unresolved = draft.unresolvedTokens(repo);
    if (unresolved.isNotEmpty) {
      await _askLocation(ctx, userId, unresolved.first);
      return;
    }
    await _showConfirmation(ctx, userId);
  }

  Future<void> _showConfirmation(Context ctx, int userId) async {
    final draft = _drafts[userId]!;
    await ctx.reply(
      _confirmationText(draft),
      parseMode: ParseMode.html,
      replyMarkup: Pickers.confirm('settime'),
    );
  }

  /// One draft line rendered the same way in the acknowledgements and in the
  /// final confirmation, e.g.
  /// "Session 2: Saturday 9:00 to 13:00 at location: OCBC".
  String _sessionLine(_Draft draft, ParsedSession line, int n) {
    final key = draft.resolved[line.locationToken] ??
        repo.resolveLocation(line.locationToken)?.key;
    final loc = key != null
        ? repo.locationName(key)
        : (draft.requestedNames[line.locationToken] ?? line.locationToken);
    return 'Session $n: ${Slot.dayName(line.day)} '
        '${prettyClock(line.start)} to ${prettyClock(line.end)} '
        'at location: $loc';
  }

  String _confirmationText(_Draft draft) {
    final sb = StringBuffer(
      'Thank you, the new activity list from now on will be:\n',
    );
    for (var i = 0; i < draft.lines.length; i++) {
      sb.writeln(_sessionLine(draft, draft.lines[i], i + 1));
    }
    return sb.toString().trimRight();
  }

  Future<void> _onConfirmOrCancel(Context ctx) async {
    await ctx.answerCallbackQuery();
    final userId = ctx.from!.id;
    final parts = (ctx.callbackQuery?.data ?? '').split('|');
    final yes = parts.length > 1 && parts[1] == 'yes';
    final draft = _drafts[userId];
    if (draft == null) {
      await ctx.editMessageText('This draft has expired. Start again with /settime.');
      return;
    }
    if (!yes) {
      _drafts.remove(userId);
      state.pendingArg.remove(userId);
      await ctx.editMessageText('❌ Cancelled — the activity list is unchanged.');
      return;
    }
    await _apply(ctx, userId, draft);
    _drafts.remove(userId);
  }

  /// Stores the template and rebuilds every open weekend, then re-prompts the
  /// members whose availability it cleared.
  Future<void> _apply(Context ctx, int userId, _Draft draft) async {
    final rows = draft.parseRows(repo);
    if (rows.isEmpty) {
      // Never wipe the schedule because a location could not be resolved.
      await ctx.editMessageText(
        '⚠️ Nothing was saved — I could not resolve any of the locations. '
        'The activity list is unchanged.',
      );
      return;
    }
    repo.replaceScheduleTemplate(rows);

    final now = config.toLocal(Config.nowUtc());
    final w = RollingWindow.forDate(
      now,
      promptHour: config.promptHour,
      reminderHour: config.reminderHour,
    );
    // Only members who actually indicated availability need to pick again:
    // anyone who did not respond, or answered "not available", is left alone.
    final affected = <int>{};
    for (final sat in [w.sat0, w.sat1]) {
      if (w.locked(sat, now)) continue; // open weekends only
      for (final a in repo.availabilityForWeekend(sat)) {
        if (a.available) affected.add(a.userId);
      }
      repo.clearWeekendAvailabilityAndAllocations(sat);
      repo.setWeekendAllocated(sat, false);
      repo.replaceSessionsForWeekend(
        sat,
        rows,
        tzOffsetHours: config.timezoneOffsetHours,
      );
    }

    for (final uid in affected) {
      final user = repo.findUser(uid);
      if (user == null) continue;
      state.forgetAvailability(uid);
      state.availabilityMessages.remove(uid);
      try {
        await service.showAvailability(
          user,
          w,
          '🗓 <b>The activity sessions have been updated.</b>\n'
          'Please pick your availability again.',
        );
      } catch (_) {
        // member may have blocked the bot; ignore
      }
    }

    LogRing.log(
      'settime: template replaced (${rows.length} rows); '
      '${affected.length} members re-prompted',
    );
    await ctx.editMessageText(
      '✅ <b>Saved.</b> The activity list is updated'
      '${affected.isEmpty ? '.' : ' — ${affected.length} member(s) asked to pick again.'}',
      parseMode: ParseMode.html,
    );
  }

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  static String _html(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

/// In-progress /settime draft for one gadmin.
class _Draft {
  final List<ParsedSession> lines = [];

  /// Raw token → resolved location key (approved locations only).
  final Map<String, String> resolved = {};

  /// Raw token → the full name the gadmin typed for a brand-new location
  /// (waiting for the console to approve it).
  final Map<String, String> requestedNames = {};

  /// The token whose new-location name we are waiting for.
  String? awaitingNameFor;

  /// Tokens with no approved match and no pending request yet, in order.
  List<String> unresolvedTokens(Repo repo) {
    final out = <String>{};
    for (final line in lines) {
      final token = line.locationToken;
      if (resolved.containsKey(token)) continue;
      if (requestedNames.containsKey(token)) continue;
      if (repo.resolveLocation(token) != null) continue;
      out.add(token);
    }
    return out.toList();
  }

  /// Builds the template rows, resolving every token (explicit choice first,
  /// then the approved locations and their aliases).
  List<ScheduleSlot> parseRows(Repo repo) => buildTemplate(
        lines,
        resolveToken: (token) =>
            resolved[token] ?? repo.resolveLocation(token)?.key,
      );
}
