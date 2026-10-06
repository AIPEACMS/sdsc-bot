part of '../service.dart';

mixin _CycleService3 on _CycleServiceBase {

  /// Builds the availability inline keyboard from the window's actual
  /// sessions — the schedule template decides the days, times and locations.
  /// Weekends whose deadline has passed are not offered (locked). Each session
  /// toggles off ▫️ → offered 🟢 → booked 🔒 → off. Plus Done and Not
  /// available; on a holiday window a "skip me this holiday" opt-out button
  /// is appended. A Cancel button (abort the in-progress repick, keeping the
  /// saved answer) appears at the very bottom only when the member has
  /// already responded to this bundle.
  static InlineKeyboard buildKeyboard(
    RollingWindow w,
    (Set<Slot>, Set<Slot>) picked, {
    bool holiday = false,
    List<Holiday> holidays = const [],
    Map<String, int> allocatedCounts = const {},
    Set<String> ownCapacityGroups = const {},
    bool hasIndicated = false,
    required DateTime now,
    required List<Session> sessions,
    required String Function(String locationKey) locationName,
  }) {
    final (want, available) = picked;
    var kb = InlineKeyboard();
    for (final (wi, sat) in [(0, w.sat0), (1, w.sat1)]) {
      final locked = w.locked(sat, now);
      // A non-interactive header naming the date, so the picker says which
      // weekend each session belongs to. No arbitrary week numbers — the
      // calendar may have breaks between weeks.
      kb = kb
          .text(
            'Sat ${_day(sat)}${locked ? ' (locked)' : ''}',
            locked ? 'locked|$wi' : 'noop|$wi',
          )
          .row();
      if (locked) continue;
      final weekendSessions =
          sessions.where((s) => s.weekendStart == sat).toList()
            ..sort((a, b) => a.start.compareTo(b.start));
      for (final s in weekendSessions) {
        final key = '$wi:${s.day}:${s.slot}:${s.location}';
        final mark = want.any((x) => x.encode() == key)
            ? '🔒'
            : available.any((x) => x.encode() == key)
            ? '🟢'
            : '▫️';
        // The callback carries the BUNDLE's first Saturday (not the clicked
        // weekend) so a toggle re-renders the same anchored window — the
        // header dates and weekend indexes never shift.
        final key = capacityKey(s);
        final count = allocatedCounts[key] ?? 0;
        final capacity = _capacityFor(s, weekendSessions);
        final full = capacity != null &&
            count >= capacity &&
            !ownCapacityGroups.contains(key);
        final countLabel = capacity == null ? '' : ' [$count/$capacity]';
        final label = '$mark ${locationName(s.location)} ${Slot.dayLabel(s.day)} '
            '${_fmt(s.start)}-${_fmt(s.end)}$countLabel';
        kb = kb
            .text(
              full ? '⛔ $label' : label,
              full ? 'full|$key' : 'slot|${_satKey(w.sat0)}|$key',
            )
            .row();
      }
      kb = kb.row();
    }
    kb = kb
        .text('✅ Done', 'done|${_satKey(w.sat0)}')
        .row()
        .text('❌ Not available', 'no|${_satKey(w.sat0)}');
    final holidayRows = holidays.isEmpty && holiday ? <Holiday>[] : holidays;
    if (holidayRows.isNotEmpty) {
      for (final row in holidayRows) {
        kb = kb.row().text(
          '🔕 Skip me for the whole ${holidayName(row.kind)}',
          'holidayout|${_satKey(w.sat0)}|${row.kind.name}',
        );
      }
    }
    if (hasIndicated) {
      kb = kb.row().text('❌ Cancel', 'cancel|${_satKey(w.sat0)}');
    }
    return kb;
  }

  static String _satKey(DateTime sat) =>
      '${sat.year}-${sat.month.toString().padLeft(2, '0')}-'
      '${sat.day.toString().padLeft(2, '0')}';

  static int? _capacityFor(Session session, List<Session> sessions) {
    final same = sessions.where(
      (other) => capacityKey(other) == capacityKey(session),
    );
    final limited = same.map((item) => item.maxPeople).whereType<int>().toList();
    if (limited.isEmpty) return null;
    return limited.reduce((a, b) => a < b ? a : b);
  }

  static String _displayName(User user) {
    final human = user.preferredName;
    if (human.isEmpty) return _html(user.name);
    return '${_html(human)} ${_html(user.name)}';
  }

  static String _html(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

}
