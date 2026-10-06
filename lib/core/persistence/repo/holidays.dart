part of '../../repo.dart';

extension RepoHolidays on Repo {

  /// Maps calendar week types to bot holiday kinds.
  ///
  /// - recess weeks → `middle` break (msg5A)
  /// - the gap between semester 1 and 2 → `winter` break (msg5B winter)
  /// - weeks after the last semester (special term / summer) → `summer`
  static HolidayKind? kindForWeek(CalendarWeek w, CalendarYear year) {
    if (w.type == 'recess') return HolidayKind.middle;
    final s1 = year.semester('semester_1');
    final s2 = year.semester('semester_2');
    // Winter: the block between S1's last week and S2's first week.
    if (s1 != null && s2 != null) {
      final s1End = s1.lastEnd;
      final s2Start = s2.firstStart;
      if (s1End != null && s2Start != null && w.start.isAfter(s1End) &&
          w.start.isBefore(s2Start)) {
        return HolidayKind.winter;
      }
    }
    // Summer: after the last semester's final week.
    final lastSemEnd =
        s2?.lastEnd ?? s1?.lastEnd;
    if (lastSemEnd != null && w.start.isAfter(lastSemEnd)) {
      return HolidayKind.summer;
    }
    return null;
  }

  String _fmt(DateTime d) =>
      DateTime(d.year, d.month, d.day, d.hour, d.minute).toIso8601String();

  String _dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  DateTime _parseTime(DateTime day, String hhmm) {
    final parts = hhmm.split(':');
    return DateTime(
      day.year,
      day.month,
      day.day,
      int.parse(parts[0]),
      int.parse(parts[1]),
    );
  }

  String _notificationPreferenceValue(
    NotificationPreference preference,
  ) => preference == NotificationPreference.everyOther
      ? 'every-other'
      : preference.name;

  NotificationPreference _notificationPreferenceFromValue(String? value) =>
      switch (value) {
        'every-other' || 'every_other' || 'everyOther' =>
          NotificationPreference.everyOther,
        'never' => NotificationPreference.never,
        _ => NotificationPreference.weekly,
      }

;

  String _storedTier(String tier) => MemberTier.isStored(tier)
      ? tier
      : MemberTier.member;

  String _pendingHandle(String handle) =>
      handle.replaceFirst('@', '').toLowerCase();

}
