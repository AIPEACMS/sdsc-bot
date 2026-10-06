part of '../settime.dart';

mixin _SetTime4 on SetTime {

  /// Stores the template and rebuilds every open weekend, then re-prompts the
  /// members whose availability it cleared.
  Future<void> _apply(Context ctx, int userId, _Draft draft) async {
    final now = config.toLocal(Config.nowUtc());
    final w = scheduleRuntime.window(now);
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

    final scheduleChangeEnabled = repo.activeOutreachEnabled('schedule-change');
    for (final uid in affected) {
      final user = repo.findUser(uid);
      if (user == null) continue;
      state.forgetAvailability(uid);
      state.availabilityMessages.remove(uid);
      if (!scheduleChangeEnabled) continue;
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
      '${scheduleChangeEnabled ? affected.length : 0} members re-prompted'
      '${scheduleChangeEnabled ? '' : '; suppressed ${affected.length} re-prompts (route disabled)'}',
    );
    await ctx.editMessageText(
      '✅ <b>Saved.</b> The activity list is updated'
      '${affected.isEmpty ? '.' : scheduleChangeEnabled ? ' — ${affected.length} member(s) asked to pick again.' : ' — re-prompts are disabled.'}',
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
