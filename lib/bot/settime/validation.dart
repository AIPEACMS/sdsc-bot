part of '../settime.dart';

mixin _SetTime3 on _SetTimeBase {

  Future<void> _showConfirmation(
    Context ctx,
    int userId, {
    bool edit = false,
  }) async {
    final draft = _drafts[userId]!;
    if (draft.scope == _SetTimeScope.temporary &&
        draft.targetSaturday == null) {
      await ctx.reply('Send at least one dated session before finishing.');
      return;
    }
    final before = draft.beforeRows ??=
        draft.scope == _SetTimeScope.temporary
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
    if (draft.conflicts == null) {
      draft.conflicts = _findConflicts(after);
      draft.conflictIndex = 0;
    }
    if (draft.conflictIndex < draft.conflicts!.length) {
      await _showConflictQuestion(ctx, userId);
      return;
    }
    final text = _confirmationText(draft);
    if (edit) {
      await ctx.editMessageText(
        text,
        parseMode: ParseMode.html,
        replyMarkup: Pickers.confirm('settime'),
      );
    } else {
      await ctx.reply(
        text,
        parseMode: ParseMode.html,
        replyMarkup: Pickers.confirm('settime'),
      );
    }
  }

  Future<void> _showConflictQuestion(
    Context ctx,
    int userId, {
    bool edit = false,
  }) async {
    final draft = _drafts[userId]!;
    final conflict = draft.conflicts![draft.conflictIndex];
    final rows = draft.afterRows!
        .where((row) => conflict.keys.contains(_rowKey(row)))
        .toList();
    final description = rows
        .map((row) =>
            '${Slot.dayName(row.day)} ${prettyClock(row.start)}-'
            '${prettyClock(row.end)} ${repo.locationName(row.location)}')
        .join('\n');
    final text = '<b>Overlapping sessions found</b>\n\n$description\n\n'
        'Are these the same session with different durations, or two separate sessions?';
    final keyboard = InlineKeyboard()
        .text('Same session', 'settime-conflict|same')
        .row()
        .text('Two sessions', 'settime-conflict|separate')
        .row()
        .text('❌ Cancel', 'settime|no');
    if (edit) {
      await ctx.editMessageText(text, parseMode: ParseMode.html, replyMarkup: keyboard);
    } else {
      await ctx.reply(text, parseMode: ParseMode.html, replyMarkup: keyboard);
    }
  }

  Future<void> _resolveConflict(Context ctx, int userId, String choice) async {
    final draft = _drafts[userId]!;
    final conflict = draft.conflicts![draft.conflictIndex];
    final group = choice == 'same' ? 'capacity-${draft.conflictIndex + 1}' : null;
    draft.afterRows = [
      for (final row in draft.afterRows!)
        conflict.keys.contains(_rowKey(row))
            ? _copyRow(row, capacityGroup: group)
            : row,
    ];
    draft.conflictIndex++;
    if (draft.conflictIndex < draft.conflicts!.length) {
      await _showConflictQuestion(ctx, userId, edit: true);
    } else {
      await _showConfirmation(ctx, userId, edit: true);
    }
  }

  List<_ConflictGroup> _findConflicts(List<ScheduleSlot> rows) {
    final result = <_ConflictGroup>[];
    final visited = <int>{};
    for (var i = 0; i < rows.length; i++) {
      if (visited.contains(i)) continue;
      final component = <int>{i};
      var changed = true;
      while (changed) {
        changed = false;
        for (var j = 0; j < rows.length; j++) {
          if (component.contains(j)) continue;
          final overlaps = component.any((index) =>
              _samePlaceAndDay(rows[index], rows[j]) &&
              _timesOverlap(rows[index], rows[j]));
          if (overlaps) {
            component.add(j);
            changed = true;
          }
        }
      }
      visited.addAll(component);
      if (component.length > 1) {
        final group = component.map((index) => rows[index].capacityGroup).toSet();
        if (group.length != 1 || group.first == null) {
          result.add(_ConflictGroup([
            for (final index in component) _rowKey(rows[index]),
          ]));
        }
      }
    }
    return result;
  }

  static bool _samePlaceAndDay(ScheduleSlot a, ScheduleSlot b) =>
      a.day == b.day && a.location == b.location;

  static bool _timesOverlap(ScheduleSlot a, ScheduleSlot b) =>
      a.start.compareTo(b.end) < 0 && b.start.compareTo(a.end) < 0;

  static ScheduleSlot _copyRow(ScheduleSlot row, {String? capacityGroup}) =>
      ScheduleSlot(
        day: row.day,
        slot: row.slot,
        start: row.start,
        end: row.end,
        location: row.location,
        maxPeople: row.maxPeople,
        capacityGroup: capacityGroup,
      );

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
    final max = line.maxPeople == null ? '' : ' [max ${line.maxPeople}]';
    return 'Session $n: ${Slot.dayName(line.day)}$date '
        '${prettyClock(line.start)} to ${prettyClock(line.end)} '
        'at location: $loc$max';
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
        'at location: ${_html(repo.locationName(row.location))}'
        '${row.maxPeople == null ? '' : ' [max ${row.maxPeople}]'}',
      );
    }
  }

  List<ScheduleSlot> _applyDraft(List<ScheduleSlot> before, _Draft draft) {
    final additions = draft.action == _SetTimeAction.remove
        ? draft.removeRows
        : draft.parseRows(repo);
    List<ScheduleSlot> rows;
    switch (draft.action) {
      case _SetTimeAction.rewrite:
        rows = additions;
      case _SetTimeAction.add:
        rows = [...before];
        for (final row in additions) {
          final index = rows.indexWhere((old) => _sameRow(old, row));
          if (index < 0) {
            rows.add(row);
          } else if (row.maxPeople != null) {
            rows[index] = row;
          }
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
          maxPeople: row.maxPeople,
          capacityGroup: row.capacityGroup,
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

  static String _rowKey(ScheduleSlot row) =>
      '${row.day}|${row.start}|${row.end}|${row.location}';

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

}
