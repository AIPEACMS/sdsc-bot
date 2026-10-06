part of '../settime.dart';

extension SetTimeDraft on SetTime {

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
          ? parseTargetSessionLine(
              line,
              config.toLocal(Config.nowUtc()),
              resolveLocation: (token) => repo.resolveLocation(token)?.key,
            )
          : parseSessionLine(
              line,
              resolveLocation: (token) => repo.resolveLocation(token)?.key,
            );
      if (parsed is String) {
        errors.add('❌ $line — $parsed');
        continue;
      }
      final session = parsed as ParsedSession;
      if (draft.scope == _SetTimeScope.temporary) {
        final date = session.targetDate!;
        final saturday = this._saturdayOf(date);
        if (draft.targetSaturday == null) {
          draft.targetSaturday = saturday;
        } else if (draft.targetSaturday != saturday) {
          errors.add(
            '❌ $line — this temporary change is for the week of '
            '${this._date(draft.targetSaturday!)}; start another change for a different week',
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
      sb.writeln(this._sessionLine(draft, draft.lines[i - 1], i));
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
    if (draft.action == _SetTimeAction.remove
        ? draft.removeRows.isEmpty
        : draft.lines.isEmpty) {
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
    await this._showConfirmation(ctx, userId);
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
      'I don\'t recognise the location <b>${this._html(token)}</b>.\n\n'
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
      '✅ <b>${this._html(token)}</b> → ${this._html(loc.name)}.',
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
        'The global admin asked to add <b>${this._html(loc.name)}</b>.\n'
        'Approve it with <code>/addlocation ${this._html(loc.name)}</code> '
        '(optionally /addalias afterwards), or from the console app.',
        parseMode: ParseMode.html,
      );
    } catch (_) {
      // console may be unreachable; the request is stored either way
    }

    await ctx.reply(
      '🕓 Thank you. I have asked the console to add <b>${this._html(loc.name)}</b>. '
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
        if (this._norm(e.value) == this._norm(loc.name)) {
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
      '✅ <b>The new location is added.</b>\n\n${this._confirmationText(draft)}',
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
    await this._showConfirmation(ctx, userId);
  }

}
