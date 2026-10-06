part of '../settime.dart';

mixin _SetTime1 on SetTime {

  /// Drafts in progress, per gadmin user id.
  final Map<int, _Draft> _drafts = {}

;

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
      if (head == 'settime-scope' || head == 'settime-action' ||
          head == 'settime-conflict') {
        if (_isGadmin(ctx)) await _onChoice(ctx, head);
        return;
      }
      if (head == 'settime-week' || head == 'settime-remove') {
        if (_isGadmin(ctx)) await _onRemoveChoice(ctx, head);
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
    if (head == 'settime-conflict') {
      await _resolveConflict(ctx, userId, value);
      return;
    }
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
    if (draft.action == _SetTimeAction.remove) {
      state.pendingArg.remove(userId);
      if (draft.scope == _SetTimeScope.temporary) {
        await _showTemporaryWeekPicker(ctx, userId);
      } else {
        await _showRemovePicker(ctx, userId);
      }
      return;
    }
    state.pendingArg[userId] = PendingArg('settime');
    final temporary = draft.scope == _SetTimeScope.temporary;
    await ctx.editMessageText(
      temporary
          ? 'Send one line per session for one week. Use '
                '<code>mon as 2026-09-21 9:00 13:00 PR 5</code> for an explicit date, '
                'or <code>thu 9:00 13:00 PR 5</code> for the next Thursday.\n'
                'Example without a max: <code>sun 13 15 ocbc</code>.\n\n'
                'The first line chooses the week; all later lines must be in that same week. '
                'Send <b>done</b> when finished.'
          : 'Send one line per session:\n'
                '<code>&lt;day&gt; &lt;startTime&gt; &lt;endTime&gt; &lt;location&gt; '
                '[&lt;max-num-ppl&gt;]</code>\n\n'
                'Examples: <code>sat 9:00 13:00 PR 5</code> or '
                '<code>sun 13 15 ocbc</code>.\n\n'
                'Send <b>done</b> when finished.',
      parseMode: ParseMode.html,
      replyMarkup: InlineKeyboard().text('❌ Cancel', 'settime|no'),
    );
  }

  Future<void> _onRemoveChoice(Context ctx, String head) async {
    await ctx.answerCallbackQuery();
    final userId = ctx.from!.id;
    final draft = _drafts[userId];
    if (draft == null) {
      await ctx.editMessageText('This draft has expired. Start again with /settime.');
      return;
    }
    final parts = (ctx.callbackQuery?.data ?? '').split('|');
    final value = parts.length > 1 ? parts[1] : '';
    if (head == 'settime-week') {
      final sat = DateTime.tryParse(value);
      if (sat == null) return;
      draft.targetSaturday = sat;
      await _showRemovePicker(ctx, userId);
      return;
    }
    if (value == 'done') {
      if (draft.removeRows.isEmpty) {
        await ctx.editMessageText('Select at least one session to remove.');
        return;
      }
      await _showConfirmation(ctx, userId);
      return;
    }
    final index = int.tryParse(value);
    if (index == null || index < 0 || index >= draft.beforeRows!.length) return;
    final row = draft.beforeRows![index];
    final key = _rowKey(row);
    if (draft.removeKeys.contains(key)) {
      draft.removeKeys.remove(key);
    } else {
      draft.removeKeys.add(key);
    }
    draft.removeRows
      ..clear()
      ..addAll(
        draft.beforeRows!.where((candidate) => draft.removeKeys.contains(_rowKey(candidate))),
      );
    await _showRemovePicker(ctx, userId, edit: true);
  }

  Future<void> _showTemporaryWeekPicker(Context ctx, int userId) async {
    final now = config.toLocal(Config.nowUtc());
    final window = scheduleRuntime.window(now);
    var kb = InlineKeyboard();
    for (final sat in [window.sat0, window.sat1]) {
      if (window.locked(sat, now)) continue;
      kb = kb.text(
        'Week ${_date(sat)} - ${_date(sat.add(const Duration(days: 6)))}',
        'settime-week|${_date(sat)}',
      ).row();
    }
    kb = kb.text('❌ Cancel', 'settime|no');
    await ctx.editMessageText(
      'Choose the week whose sessions you want to remove:',
      replyMarkup: kb,
    );
  }

  Future<void> _showRemovePicker(
    Context ctx,
    int userId, {
    bool edit = false,
  }) async {
    final draft = _drafts[userId]!;
    final before = draft.scope == _SetTimeScope.temporary
        ? repo.scheduleForWeekend(draft.targetSaturday!)
        : repo.scheduleTemplate();
    draft.beforeRows = before;
    var kb = InlineKeyboard();
    for (var i = 0; i < before.length; i++) {
      final row = before[i];
      final selected = draft.removeKeys.contains(_rowKey(row));
      final max = row.maxPeople == null ? '' : ' ${row.maxPeople}';
      kb = kb
          .text(
            '${selected ? '☑' : '☐'} ${Slot.dayName(row.day)} '
            '${prettyClock(row.start)}-${prettyClock(row.end)} '
            '${repo.locationName(row.location)}$max',
            'settime-remove|$i',
          )
          .row();
    }
    kb = kb
        .text('✅ Confirm selection', 'settime-remove|done')
        .row()
        .text('❌ Cancel', 'settime|no');
    final text = draft.scope == _SetTimeScope.temporary
        ? 'Select sessions to remove from week ${_date(draft.targetSaturday!)} '
            '- ${_date(draft.targetSaturday!.add(const Duration(days: 6)))}:'
        : 'Select recurring sessions to remove:';
    if (edit) {
      await ctx.editMessageText(text, replyMarkup: kb);
    } else {
      await ctx.editMessageText(text, replyMarkup: kb);
    }
  }

}
