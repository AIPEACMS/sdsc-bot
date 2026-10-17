part of '../settime.dart';

extension SetTimeCommand on SetTime {
  /// Drafts in progress, per gadmin user id.
  void register() {
    commandBoth(bot, state, 'settime', _guard(_start), label: 'set-time');
    state.registerCommand('rm_allocate_entry');
    bot.command('rm_allocate_entry', _guard(_startAllocationRemoval));
    bot.hears('/rm_allocate_entry', _guard(_startAllocationRemoval));
    bot.use((ctx, next) async {
      final data = ctx.callbackQuery?.data;
      if (data == null) return next();
      final head = data.split('|').first;
      if (head == 'settime') {
        if (_isGadmin(ctx)) await _onConfirmOrCancel(ctx);
        return;
      }
      if (head == 'rmalloc') {
        if (_isGadmin(ctx)) {
          await _onAllocationRemovalCallback(ctx);
        } else {
          await ctx.answerCallbackQuery(text: 'Not authorized');
        }
        return;
      }
      if (head == 'settime-scope' ||
          head == 'settime-action' ||
          head == 'settime-conflict') {
        if (_isGadmin(ctx)) await _onChoice(ctx, head);
        return;
      }
      if (head == 'settime-week' ||
          head == 'settime-week-page' ||
          head == 'settime-week-locked' ||
          head == 'settime-remove') {
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
    final message = await ctx.reply(
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
    state.trackInteractiveMessage(userId, userId, message.messageId);
  }

  Future<void> _onChoice(Context ctx, String head) async {
    await ctx.answerCallbackQuery();
    final userId = ctx.from!.id;
    final draft = _drafts[userId];
    if (draft == null) {
      await ctx.editMessageText(
        'This draft has expired. Start again with /settime.',
        replyMarkup: null,
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
          ? 'Enter one session per line. The first line selects the week; '
                'every later line must be in that same week.\n\n'
                'Choose the week with either:\n'
                '• An explicit date: <code>mon as 2026-09-21 9:00 13:00 PR 5</code> '
                '(replace the date with your intended date).\n'
                '• The next matching weekday: <code>thu 9:00 13:00 PR 5</code>.\n\n'
                'Use <code>day as YYYY-MM-DD</code> on a later line if its date '
                'would otherwise fall in a different week. The max is optional; '
                'without one: <code>sun 13 15 ocbc</code>.\n\n'
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
    if (head == 'settime-week-locked') {
      await ctx.answerCallbackQuery(
        text: 'That week is locked and cannot be changed.',
      );
      return;
    }
    await ctx.answerCallbackQuery();
    final userId = ctx.from!.id;
    final draft = _drafts[userId];
    if (draft == null) {
      await ctx.editMessageText(
        'This draft has expired. Start again with /settime.',
        replyMarkup: null,
      );
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
    if (head == 'settime-week-page') {
      final page = int.tryParse(value);
      if (page == null || page < 0) return;
      draft.temporaryWeekPage = page;
      await _showTemporaryWeekPicker(ctx, userId);
      return;
    }
    if (value == 'done') {
      if (draft.removeRows.isEmpty) {
        await ctx.editMessageText(
          'Select at least one session to remove.',
          replyMarkup: null,
        );
        return;
      }
      await ctx.editMessageText('Selection accepted.', replyMarkup: null);
      await _showConfirmation(ctx, userId);
      return;
    }
    final index = int.tryParse(value);
    if (index == null || index < 0 || index >= draft.beforeRows!.length) {
      await ctx.editMessageText(
        'That session is no longer available.',
        replyMarkup: null,
      );
      return;
    }
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
        draft.beforeRows!.where(
          (candidate) => draft.removeKeys.contains(_rowKey(candidate)),
        ),
      );
    await _showRemovePicker(ctx, userId, edit: true);
  }

  Future<void> _showTemporaryWeekPicker(Context ctx, int userId) async {
    final now = config.toLocal(Config.nowUtc());
    final draft = _drafts[userId]!;
    final thisSaturday = DateTime(
      now.year,
      now.month,
      now.day,
    ).add(Duration(days: (DateTime.saturday - now.weekday + 7) % 7));
    final first = thisSaturday.add(
      Duration(days: draft.temporaryWeekPage * 28),
    );
    var kb = InlineKeyboard();
    for (var i = 0; i < 4; i++) {
      final sat = first.add(Duration(days: i * 7));
      final monday = sat.subtract(const Duration(days: 5));
      final lockAt = scheduleRuntime.schedule.lock.on(monday);
      final locked = !now.isBefore(lockAt);
      kb = kb
          .text(
            '${locked ? '🔒 ' : ''}Week ${_calendarWeekLabel(sat)}',
            locked
                ? 'settime-week-locked|${_date(sat)}'
                : 'settime-week|${_date(sat)}',
          )
          .row();
    }
    kb = kb.row();
    if (draft.temporaryWeekPage > 0) {
      kb = kb.text(
        '‹ Prev page',
        'settime-week-page|${draft.temporaryWeekPage - 1}',
      );
    }
    kb = kb
        .text('Next page ›', 'settime-week-page|${draft.temporaryWeekPage + 1}')
        .row()
        .text('❌ Cancel', 'settime|no');
    await ctx.editMessageText(
      'Choose the week whose sessions you want to remove. Locked weeks are shown but cannot be changed:',
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
        ? 'Select sessions to remove from week '
              '${_calendarWeekLabel(draft.targetSaturday!)}:'
        : 'Select recurring sessions to remove:';
    if (edit) {
      await ctx.editMessageText(text, replyMarkup: kb);
    } else {
      await ctx.editMessageText(text, replyMarkup: kb);
    }
  }

  String _calendarWeekLabel(DateTime saturday) {
    final monday = saturday.subtract(const Duration(days: 5));
    final sunday = monday.add(const Duration(days: 6));
    return '${_date(monday)} - ${_date(sunday)}';
  }
}
