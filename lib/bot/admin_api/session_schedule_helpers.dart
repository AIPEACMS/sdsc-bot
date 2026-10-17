part of '../admin_api.dart';

extension AdminApiSessionScheduleHelpers on AdminApi {
  Map<String, Object?> _scheduleRows(
    List<ScheduleSlot> rows,
    String scope,
    DateTime? week,
    bool locked,
  ) => {
    'ok': true,
    'scope': scope,
    'week': week == null ? null : _apiDay(week),
    'locked': locked,
    'actionable': !locked,
    'scheduleChangeEnabled': repo.activeOutreachEnabled('schedule-change'),
    'rows': [for (final r in rows) _slotJson(r)],
  };

  Map<String, Object?> _slotJson(ScheduleSlot r) => {
    'day': r.day,
    'slot': r.slot,
    'start': r.start,
    'end': r.end,
    'location': r.location,
    'locationName': repo.locationName(r.location),
    'maxPeople': r.maxPeople,
    'capacityGroup': r.capacityGroup,
  };

  String _scheduleIdentity(ScheduleSlot row) =>
      '${row.day}|${row.slot}|${row.location}|${row.start}|${row.end}';

  String _sessionIdentity(Session session) =>
      '${session.day}|${session.slot}|${session.location}|'
      '${_clock(session.start)}|${_clock(session.end)}';

  String _clock(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';

  bool _validClock(String value) {
    final match = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(value);
    if (match == null) return false;
    final hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    return hour < 24 && minute < 60;
  }

  String _apiDay(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
