part of '../settime.dart';

extension SetTimeAllocationRemoval on SetTime {
  Future<void> _startAllocationRemoval(Context ctx) async {
    final userId = ctx.from!.id;
    final window = scheduleRuntime.window(config.toLocal(Config.nowUtc()));
    final pairs = <(int, int)>[];
    for (final weekend in window.weekends) {
      for (final (user, session) in repo.allocationsForWeekend(weekend)) {
        pairs.add((session.id, user.id));
      }
    }
    if (pairs.isEmpty) {
      await ctx.reply(
        'There are no allocations in the current two-week window.',
      );
      return;
    }
    _allocationRemovalTargets[userId] = pairs;
    _allocationRemovalSelection[userId] = {};
    await _showAllocationRemovalPicker(ctx, userId);
  }

  Future<void> _showAllocationRemovalPicker(
    Context ctx,
    int userId, {
    bool edit = false,
  }) async {
    final targets = _allocationRemovalTargets[userId] ?? const <(int, int)>[];
    final selected = _allocationRemovalSelection[userId] ?? <String>{};
    var keyboard = InlineKeyboard();
    for (final (sessionId, userId) in targets) {
      final user = repo.findUser(userId);
      final session = repo.sessionById(sessionId);
      if (user == null || session == null) continue;
      final key = '$sessionId:$userId';
      final label =
          '${user.name} · ${_date(session.start)} ${_removalSessionLabel(session)}';
      keyboard = keyboard
          .text(
            '${selected.contains(key) ? '☑' : '☐'} $label',
            'rmalloc|toggle|$sessionId|$userId',
          )
          .row();
    }
    keyboard = keyboard
        .text('✅ Continue', 'rmalloc|preview')
        .row()
        .text('❌ Cancel', 'rmalloc|cancel');
    final text = 'Select the allocations to remove (including locked dates):';
    if (edit) {
      await ctx.editMessageText(text, replyMarkup: keyboard);
    } else {
      await ctx.reply(text, replyMarkup: keyboard);
    }
  }

  Future<void> _onAllocationRemovalCallback(Context ctx) async {
    await ctx.answerCallbackQuery();
    final userId = ctx.from!.id;
    final parts = (ctx.callbackQuery?.data ?? '').split('|');
    final action = parts.length > 1 ? parts[1] : '';
    final targets = _allocationRemovalTargets[userId];
    if (targets == null) {
      await ctx.editMessageText(
        'This selection expired. Start again with /rm_allocate_entry.',
        replyMarkup: null,
      );
      return;
    }
    if (action == 'cancel') {
      _clearAllocationRemoval(userId);
      await ctx.editMessageText(
        '❌ Cancelled. No allocations were removed.',
        replyMarkup: null,
      );
      return;
    }
    if (action == 'toggle' && parts.length == 4) {
      final sid = int.tryParse(parts[2]);
      final uid = int.tryParse(parts[3]);
      if (sid == null || uid == null || !targets.contains((sid, uid))) {
        await ctx.editMessageText(
          'That allocation is no longer available.',
          replyMarkup: null,
        );
        _clearAllocationRemoval(userId);
        return;
      }
      final selected = _allocationRemovalSelection[userId]!;
      final key = '$sid:$uid';
      if (!selected.add(key)) selected.remove(key);
      await _showAllocationRemovalPicker(ctx, userId, edit: true);
      return;
    }
    if (action == 'preview') {
      final selected = _allocationRemovalSelection[userId] ?? {};
      if (selected.isEmpty) {
        await ctx.editMessageText(
          'Select at least one allocation.',
          replyMarkup: null,
        );
        _clearAllocationRemoval(userId);
        return;
      }
      final current = _validSelectedRemovals(userId);
      if (current == null) {
        await ctx.editMessageText(
          'An allocation changed. Start again with /rm_allocate_entry.',
          replyMarkup: null,
        );
        _clearAllocationRemoval(userId);
        return;
      }
      final lines = current
          .map(
            (row) =>
                '• ${AllocationRemovalNotice.escape(row.$1.name)} — '
                '${AllocationRemovalNotice.escape('${_date(row.$2.start)} ${_removalSessionLabel(row.$2)}')}',
          )
          .join('\n');
      final routeOn = repo.activeOutreachEnabled('schedule-change');
      await ctx.editMessageText(
        'Remove these allocations?\n$lines\n\n'
        '${routeOn ? 'They WILL be notified of the allocation removal.' : 'They will NOT be automatically notified, if needed, please tell them personally'}',
        parseMode: ParseMode.html,
        replyMarkup: InlineKeyboard()
            .text('✅ Confirm removal', 'rmalloc|confirm')
            .row()
            .text('❌ Cancel', 'rmalloc|cancel'),
      );
      return;
    }
    if (action == 'confirm') {
      await _confirmAllocationRemoval(ctx, userId);
    }
  }

  List<(User, Session)>? _validSelectedRemovals(int userId) {
    final selected = _allocationRemovalSelection[userId] ?? {};
    final window = scheduleRuntime.window(config.toLocal(Config.nowUtc()));
    final sessions = repo.windowSessions(window).map((s) => s.id).toSet();
    final result = <(User, Session)>[];
    for (final key in selected) {
      final parts = key.split(':');
      final sid = int.parse(parts[0]);
      final uid = int.parse(parts[1]);
      if (!sessions.contains(sid)) return null;
      final session = repo.sessionById(sid);
      final allocation = session == null
          ? null
          : repo
                .allocationsForWeekend(session.weekendStart)
                .where((pair) => pair.$1.id == uid && pair.$2.id == sid)
                .firstOrNull;
      if (allocation == null) return null;
      result.add(allocation);
    }
    return result;
  }

  Future<void> _confirmAllocationRemoval(Context ctx, int userId) async {
    final current = _validSelectedRemovals(userId);
    if (current == null) {
      _clearAllocationRemoval(userId);
      await ctx.editMessageText(
        'An allocation changed. Nothing was removed; start again with /rm_allocate_entry.',
        replyMarkup: null,
      );
      return;
    }
    final enabled = repo.activeOutreachEnabled('schedule-change');
    final db = repo.raw;
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final (user, session) in current) {
        repo.removeAvailabilityForSession(
          user.id,
          session.weekendStart,
          session.day,
          session.slot,
          session.location,
        );
        db.execute(
          'DELETE FROM attendance WHERE user_id = ? AND session_id = ?',
          [user.id, session.id],
        );
        db.execute(
          'DELETE FROM allocations WHERE user_id = ? AND session_id = ?',
          [user.id, session.id],
        );
      }
      db.execute('COMMIT');
    } catch (e) {
      db.execute('ROLLBACK');
      LogRing.log('Telegram allocation removal failed: $e');
      rethrow;
    }
    var notified = 0;
    var failures = 0;
    final notifiedNames = <String>[];
    final reminderNames = <String>[];
    if (enabled) {
      final byUser = <int, (User, List<Session>)>{};
      for (final (user, session) in current) {
        byUser.putIfAbsent(user.id, () => (user, <Session>[])).$2.add(session);
      }
      for (final entry in byUser.entries) {
        try {
          await bot.api.sendMessage(
            ChatID(entry.key),
            AllocationRemovalNotice.message(
              entry.value.$2.map(
                (session) => AllocationRemovalNotice.escape(
                  '${_date(session.start)} ${_removalSessionLabel(session)}',
                ),
              ),
            ),
            parseMode: ParseMode.html,
          );
          notified++;
          notifiedNames.add(_safeRemovalRecipientName(entry.value.$1));
        } catch (e) {
          failures++;
          reminderNames.add(_safeRemovalRecipientName(entry.value.$1));
          LogRing.log(
            'Telegram allocation removal notice failed for ${entry.key}: $e',
          );
        }
      }
    } else {
      final byUser = <int, User>{};
      for (final (user, _) in current) {
        byUser.putIfAbsent(user.id, () => user);
      }
      reminderNames.addAll(byUser.values.map(_safeRemovalRecipientName));
    }
    LogRing.log(
      'Telegram allocation removal: ${current.length} entries, $notified notified, $failures failures',
    );
    _clearAllocationRemoval(userId);
    final result = StringBuffer('✅ Removed ${current.length} allocation(s).');
    if (notifiedNames.isNotEmpty) {
      result
        ..write('\n\nThese people are notified of the removal: ')
        ..write(notifiedNames.join(', '))
        ..write('.');
    }
    if (reminderNames.isNotEmpty) {
      result
        ..write('\n\nPlease remember to notify them if you haven\'t: ')
        ..write(reminderNames.join(', '))
        ..write('.');
    }
    await ctx.editMessageText(result.toString(), replyMarkup: null);
  }

  String _safeRemovalRecipientName(User user) {
    final name = user.name
        .replaceAll(RegExp(r'[\x00-\x1F\x7F-\x9F\u2028\u2029]'), ' ')
        .trim();
    return name.isEmpty ? 'user ${user.id}' : name;
  }

  void _clearAllocationRemoval(int userId) {
    _allocationRemovalTargets.remove(userId);
    _allocationRemovalSelection.remove(userId);
  }

  String _removalSessionLabel(Session session) =>
      '${repo.locationName(session.location)} · ${Slot.dayName(session.day)} '
      '${session.start.hour.toString().padLeft(2, '0')}:${session.start.minute.toString().padLeft(2, '0')}-'
      '${session.end.hour.toString().padLeft(2, '0')}:${session.end.minute.toString().padLeft(2, '0')}';
}
