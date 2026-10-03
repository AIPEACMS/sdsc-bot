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

/// `/settime` — guided schedule changes for the global admin. The gadmin can
/// add, remove, or rewrite recurring sessions, or apply one temporary change
/// to one open week. The command is also exposed as the `set-time` grid button.
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
    commandBoth(bot, state, 'settime', _guard(_start), label: 'set-time');
    bot.use((ctx, next) async {
      final data = ctx.callbackQuery?.data;
      if (data == null) return next();
      final head = data.split('|').first;
      if (head == 'settime') {
        if (_isGadmin(ctx)) await _onConfirmOrCancel(ctx);
        return;
      }
      if (head == 'settime-scope' || head == 'settime-action') {
        if (_isGadmin(ctx)) await _onChoice(ctx, head);
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
    // Keep the old typed flow working if the user starts sending lines before
    // choosing a button; the buttons are the normal path for new sessions.
    state.pendingArg[userId] = PendingArg('settime');
    await ctx.reply(
      '🗓 <b>Set the activity times</b>\n\n'
      'Do you want this change to be temporary for one week, or persistent '
      'from now on?',
      parseMode: ParseMode.html,
      replyMarkup: InlineKeyboard()
          .text('Temporary (one week)', 'settime-scope|temporary')
          .row()
          .text('Persistent (from now on)', 'settime-scope|persistent')
          .row()
          .text('❌ Cancel', 'settime|no'),
    );
  }

  Future<void> _onChoice(Context ctx, String head) async {
    await ctx.answerCallbackQuery();
    final userId = ctx.from!.id;
    final draft = _drafts[userId];
    if (draft == null) {
      await ctx.editMessageText(
        'This draft has expired. Start again with /settime.',
      );
      return;
    }
    final parts = (ctx.callbackQuery?.data ?? '').split('|');
    final value = parts.length > 1 ? parts[1] : '';
    if (head == 'settime-scope') {
      draft.scope = value == 'temporary'
          ? _SetTimeScope.temporary
          : _SetTimeScope.persistent;
      await ctx.editMessageText(
        'Choose how to change the ${draft.scope == _SetTimeScope.temporary ? 'week' : 'recurring schedule'}:',
        replyMarkup: InlineKeyboard()
            .text('Add some sessions', 'settime-action|add')
            .row()
            .text('Remove some sessions', 'settime-action|remove')
            .row()
            .text('Rewrite all sessions', 'settime-action|rewrite')
            .row()
            .text('❌ Cancel', 'settime|no'),
      );
      return;
    }
    draft.action = switch (value) {
      'add' => _SetTimeAction.add,
      'remove' => _SetTimeAction.remove,
      _ => _SetTimeAction.rewrite,
    };
    state.pendingArg[userId] = PendingArg('settime');
    final temporary = draft.scope == _SetTimeScope.temporary;
    await ctx.editMessageText(
      temporary
          ? 'Send one line per session for one week. Use '
                '<code>mon as 2026-09-21 9:00 13:00 PR</code> for an explicit date, '
                'or <code>thu 9:00 13:00 PR</code> for the next Thursday.\n\n'
                'The first line chooses the week; all later lines must be in that same week. '
                'Send <b>done</b> when finished.'
          : 'Send one line per session:\n'
                '<code>&lt;day&gt; &lt;startTime&gt; &lt;endTime&gt; &lt;location&gt;</code>\n\n'
                'For example: <code>sat 9:00 13:00 PR</code>\n\n'
                'Send <b>done</b> when finished.',
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
      state.pendingArg.remove(userId);
      await ctx.reply('❌ Cancelled — the activity list is unchanged.');
      return;
    }

    final errors = <String>[];
    final firstIndex = draft.lines.length + 1;
    for (final raw in trimmed.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final parsed = draft.scope == _SetTimeScope.temporary
          ? parseTargetSessionLine(line, config.toLocal(Config.nowUtc()))
          : parseSessionLine(line);
      if (parsed is String) {
        errors.add('❌ $line — $parsed');
        continue;
      }
      final session = parsed as ParsedSession;
      if (draft.scope == _SetTimeScope.temporary) {
        final date = session.targetDate!;
        final saturday = _saturdayOf(date);
        if (draft.targetSaturday == null) {
          draft.targetSaturday = saturday;
        } else if (draft.targetSaturday != saturday) {
          errors.add(
            '❌ $line — this temporary change is for the week of '
            '${_date(draft.targetSaturday!)}; start another change for a different week',
          );
          continue;
        }
      }
      draft.lines.add(session);
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
      await ctx.reply(
        'Nothing to set. Send a session line first, or /settime.',
      );
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
  Future<void> _askLocation(Context ctx, int userId, String token) async {
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
      await ctx.editMessageText(
        'This draft has expired. Start again with /settime.',
      );
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
    if (draft.scope == _SetTimeScope.temporary &&
        draft.targetSaturday == null) {
      await ctx.reply('Send at least one dated session before finishing.');
      return;
    }
    final before = draft.scope == _SetTimeScope.temporary
        ? repo.scheduleForWeekend(draft.targetSaturday!)
        : repo.scheduleTemplate();
    final after = _applyDraft(before, draft);
    if (after.isEmpty) {
      await ctx.reply(
        'That change would leave the schedule empty. The activity list is unchanged.',
      );
      return;
    }
    if (draft.action == _SetTimeAction.remove &&
        after.length == before.length) {
      await ctx.reply('None of those sessions exists in the current schedule.');
      return;
    }
    draft.beforeRows = before;
    draft.afterRows = after;
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
    final key =
        draft.resolved[line.locationToken] ??
        repo.resolveLocation(line.locationToken)?.key;
    final loc = key != null
        ? repo.locationName(key)
        : (draft.requestedNames[line.locationToken] ?? line.locationToken);
    final date = line.targetDate == null ? '' : ' ${_date(line.targetDate!)}';
    return 'Session $n: ${Slot.dayName(line.day)}$date '
        '${prettyClock(line.start)} to ${prettyClock(line.end)} '
        'at location: $loc';
  }

  String _confirmationText(_Draft draft) {
    final before = draft.beforeRows ??= draft.scope == _SetTimeScope.temporary
        ? repo.scheduleForWeekend(draft.targetSaturday!)
        : repo.scheduleTemplate();
    final after = draft.afterRows ??= _applyDraft(before, draft);
    final sb = StringBuffer();
    if (draft.scope == _SetTimeScope.temporary) {
      final sat = draft.targetSaturday!;
      sb.writeln('Before change:');
      _writeRows(sb, before);
      sb.writeln('\nAfter change:');
      sb.writeln(
        'Week ${_date(sat)} - ${_date(sat.add(const Duration(days: 6)))} '
        'will be updated to:',
      );
      _writeRows(sb, after);
    } else {
      sb.writeln('Before change:');
      _writeRows(sb, before);
      sb.writeln('\nAfter change: the recurring schedule from now on will be:');
      _writeRows(sb, after);
    }
    return sb.toString().trimRight();
  }

  void _writeRows(StringBuffer sb, List<ScheduleSlot> rows) {
    if (rows.isEmpty) {
      sb.writeln('— none —');
      return;
    }
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      sb.writeln(
        '${i + 1}. ${Slot.dayName(row.day)} '
        '${prettyClock(row.start)} to ${prettyClock(row.end)} '
        'at location: ${_html(repo.locationName(row.location))}',
      );
    }
  }

  List<ScheduleSlot> _applyDraft(List<ScheduleSlot> before, _Draft draft) {
    final additions = draft.parseRows(repo);
    List<ScheduleSlot> rows;
    switch (draft.action) {
      case _SetTimeAction.rewrite:
        rows = additions;
      case _SetTimeAction.add:
        rows = [...before];
        for (final row in additions) {
          if (!rows.any((old) => _sameRow(old, row))) rows.add(row);
        }
      case _SetTimeAction.remove:
        rows = before
            .where((old) => !additions.any((remove) => _sameRow(old, remove)))
            .toList();
    }
    final slots = <String, String>{};
    var next = 1;
    final out = <ScheduleSlot>[];
    for (final row in rows) {
      final key = '${row.day}|${row.start}|${row.end}';
      final slot = slots.putIfAbsent(key, () => 's${next++}');
      out.add(
        ScheduleSlot(
          day: row.day,
          slot: slot,
          start: row.start,
          end: row.end,
          location: row.location,
        ),
      );
    }
    return out;
  }

  static bool _sameRow(ScheduleSlot a, ScheduleSlot b) =>
      a.day == b.day &&
      a.start == b.start &&
      a.end == b.end &&
      a.location == b.location;

  Future<void> _onConfirmOrCancel(Context ctx) async {
    await ctx.answerCallbackQuery();
    final userId = ctx.from!.id;
    final parts = (ctx.callbackQuery?.data ?? '').split('|');
    final yes = parts.length > 1 && parts[1] == 'yes';
    final draft = _drafts[userId];
    if (draft == null) {
      await ctx.editMessageText(
        'This draft has expired. Start again with /settime.',
      );
      return;
    }
    if (!yes) {
      _drafts.remove(userId);
      state.pendingArg.remove(userId);
      await ctx.editMessageText(
        '❌ Cancelled — the activity list is unchanged.',
      );
      return;
    }
    await _apply(ctx, userId, draft);
    _drafts.remove(userId);
  }

  /// Stores the template and rebuilds every open weekend, then re-prompts the
  /// members whose availability it cleared.
  Future<void> _apply(Context ctx, int userId, _Draft draft) async {
    final now = config.toLocal(Config.nowUtc());
    final w = RollingWindow.forDate(
      now,
      promptHour: config.promptHour,
      reminderHour: config.reminderHour,
    );
    final rows = draft.afterRows;
    if (rows == null || rows.isEmpty) {
      await ctx.editMessageText(
        '⚠️ Nothing was saved — the activity list is unchanged.',
      );
      return;
    }

    final affected = <int>{};
    if (draft.scope == _SetTimeScope.temporary) {
      final sat = draft.targetSaturday!;
      if (sat != w.sat0 && sat != w.sat1) {
        await ctx.editMessageText(
          '⚠️ That date is outside the current two-week window. '
          'The activity list is unchanged.',
        );
        return;
      }
      if (w.locked(sat, now)) {
        await ctx.editMessageText(
          '⚠️ That week is already locked. The activity list is unchanged.',
        );
        return;
      }
      for (final a in repo.availabilityForWeekend(sat)) {
        if (a.available) affected.add(a.userId);
      }
      repo.clearWeekendAvailabilityAndAllocations(sat);
      repo.setWeekendAllocated(sat, false);
      repo.replaceScheduleOverride(
        sat,
        rows,
        tzOffsetHours: config.timezoneOffsetHours,
      );
    } else {
      repo.replaceScheduleTemplate(rows);
      for (final sat in [w.sat0, w.sat1]) {
        if (w.locked(sat, now)) continue;
        for (final a in repo.availabilityForWeekend(sat)) {
          if (a.available) affected.add(a.userId);
        }
        repo.clearScheduleOverride(sat);
        repo.clearWeekendAvailabilityAndAllocations(sat);
        repo.setWeekendAllocated(sat, false);
        repo.replaceSessionsForWeekend(
          sat,
          rows,
          tzOffsetHours: config.timezoneOffsetHours,
        );
      }
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
      'settime: ${draft.scope.name} ${draft.action.name} '
      '(${rows.length} rows); '
      '${affected.length} members re-prompted',
    );
    await ctx.editMessageText(
      '✅ <b>Saved.</b> The activity list is updated'
      '${affected.isEmpty ? '.' : ' — ${affected.length} member(s) asked to pick again.'}',
      parseMode: ParseMode.html,
    );
  }

  static DateTime _saturdayOf(DateTime date) => DateTime(
    date.year,
    date.month,
    date.day,
  ).subtract(Duration(days: (date.weekday + 1) % 7));

  static String _date(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

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

  _SetTimeScope scope = _SetTimeScope.persistent;
  _SetTimeAction action = _SetTimeAction.rewrite;
  DateTime? targetSaturday;
  List<ScheduleSlot>? beforeRows;
  List<ScheduleSlot>? afterRows;

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

enum _SetTimeScope { temporary, persistent }

enum _SetTimeAction { add, remove, rewrite }
