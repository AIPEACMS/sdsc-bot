part of '../admin_api.dart';

extension AdminApiSessionSchedules on AdminApi {
  DateTime? _weekDate(String? value) {
    final date = value == null ? null : DateTime.tryParse(value);
    if (date == null ||
        date.weekday != DateTime.saturday ||
        date.hour != 0 ||
        date.minute != 0 ||
        date.second != 0 ||
        date.millisecond != 0 ||
        date.microsecond != 0) {
      return null;
    }
    return date;
  }

  DateTime _currentWeekSaturday(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    return today.add(
      Duration(days: (DateTime.saturday - today.weekday + 7) % 7),
    );
  }

  bool _weekLocked(DateTime saturday, DateTime now) {
    final deadline = RollingWindow.fromSat0(
      saturday,
      schedule: scheduleRuntime.schedule,
    ).deadlineFor(saturday);
    return !now.isBefore(deadline);
  }

  Future<(int, Object)> _readSelectedSchedule(String text) async {
    final Map<String, dynamic> body;
    try {
      body = _jsonBody(text);
    } catch (_) {
      return (400, {'ok': false, 'error': 'expected a JSON object'});
    }
    final scopeValue = body['scope'];
    if (scopeValue != null && scopeValue is! String) {
      return (
        400,
        {'ok': false, 'error': 'scope must be temporary or recurring'},
      );
    }
    final scope = scopeValue as String? ?? 'temporary';
    final rawWeek = body['week'];
    if (rawWeek != null && rawWeek is! String) {
      return (
        400,
        {'ok': false, 'error': 'week must be a Saturday YYYY-MM-DD'},
      );
    }
    final now = config.toLocal(Config.nowUtc());
    final currentWeek = _currentWeekSaturday(now);
    if (scope == 'recurring') {
      return (
        200,
        {
          ..._scheduleRows(repo.scheduleTemplate(), scope, null, false),
          'currentWeek': _apiDay(currentWeek),
        },
      );
    }
    if (scope != 'temporary') {
      return (
        400,
        {'ok': false, 'error': 'scope must be temporary or recurring'},
      );
    }
    final saturday = rawWeek == null
        ? currentWeek
        : _weekDate(rawWeek as String);
    if (saturday == null) {
      return (
        400,
        {'ok': false, 'error': 'week must be a Saturday YYYY-MM-DD'},
      );
    }
    final locked = _weekLocked(saturday, now);
    final override =
        repo.raw.select(
          'SELECT 1 FROM schedule_overrides WHERE weekend_start = ? LIMIT 1',
          [
            '${saturday.year.toString().padLeft(4, '0')}-${saturday.month.toString().padLeft(2, '0')}-${saturday.day.toString().padLeft(2, '0')}',
          ],
        ).isNotEmpty ||
        repo.getSetting('schedule_override_empty_${_apiDay(saturday)}') == '1';
    final rows = repo.scheduleForWeekend(saturday);
    repo.ensureSessionsForWeekend(
      saturday,
      rows,
      tzOffsetHours: config.timezoneOffsetHours,
    );
    final sessions = repo.sessionsForWeekend(saturday);
    return (
      200,
      {
        ..._scheduleRows(rows, 'temporary', saturday, locked),
        'currentWeek': _apiDay(currentWeek),
        'hasOverride': override,
        'sessions': [
          for (final s in sessions)
            {
              'id': s.id,
              'day': s.day,
              'slot': s.slot,
              'location': s.location,
              'locationName': repo.locationName(s.location),
              'start': s.start.toIso8601String(),
              'end': s.end.toIso8601String(),
              'allocated': repo
                  .allocationsForWeekend(saturday)
                  .any((a) => a.$2.id == s.id),
            },
        ],
      },
    );
  }

  Future<(int, Object)> _sessionSchedulePreview(String text) async {
    final Map<String, dynamic> body;
    try {
      body = _jsonBody(text);
    } catch (_) {
      return (400, {'ok': false, 'error': 'expected a JSON object'});
    }
    final parsed = _scheduleMutation(body);
    if (parsed.$2 != null) return (400, {'ok': false, 'error': parsed.$2});
    final (scope, week, action, rows) = parsed.$1!;
    final before = scope == 'recurring'
        ? repo.scheduleTemplate()
        : repo.scheduleForWeekend(week!);
    final after = _mutatedSchedule(before, rows, action);
    if (after.isEmpty) {
      return (400, {'ok': false, 'error': 'schedule cannot be empty'});
    }
    if (action == 'remove' && after.length == before.length) {
      return (
        409,
        {'ok': false, 'error': 'none of those sessions exists in the schedule'},
      );
    }
    final affected = _removedAllocations(scope, week, after);
    return (
      200,
      {
        'ok': true,
        'scope': scope,
        'week': week == null ? null : _apiDay(week),
        'action': action,
        'before': [for (final r in before) _slotJson(r)],
        'after': [for (final r in after) _slotJson(r)],
        'affectedAllocations': affected,
        'scheduleChangeEnabled': repo.activeOutreachEnabled('schedule-change'),
        'locked': false,
      },
    );
  }

  ((String, DateTime?, String, List<ScheduleSlot>)?, String?) _scheduleMutation(
    Map<String, dynamic> body,
  ) {
    final scope = body['scope'];
    final action = body['action'];
    if ((scope != 'temporary' && scope != 'recurring') ||
        !['add', 'rewrite', 'remove'].contains(action) ||
        body['rows'] is! List) {
      return (null, 'expected scope, action, and rows');
    }
    final week = scope == 'temporary'
        ? _weekDate(body['week'] as String?)
        : null;
    if (scope == 'temporary' && week == null) {
      return (null, 'temporary scope requires a Saturday YYYY-MM-DD week');
    }
    final now = config.toLocal(Config.nowUtc());
    if (week != null && _weekLocked(week, now)) {
      return (null, 'selected week is locked');
    }
    final rows = <ScheduleSlot>[];
    for (final item in body['rows'] as List) {
      if (item is! Map ||
          item['day'] is! String ||
          item['slot'] is! String ||
          item['start'] is! String ||
          item['end'] is! String ||
          item['location'] is! String) {
        return (null, 'each row needs day, slot, start, end, and location');
      }
      final day = item['day'] as String;
      final start = item['start'] as String;
      final end = item['end'] as String;
      final location = repo.locationByKey(item['location'] as String);
      if (!Slot.allDays.contains(day) ||
          !_validClock(start) ||
          !_validClock(end) ||
          start.compareTo(end) >= 0 ||
          location == null ||
          !location.isApproved) {
        return (
          null,
          'row has an invalid day, time range, or unapproved location',
        );
      }
      rows.add(
        ScheduleSlot(
          day: item['day'] as String,
          slot: item['slot'] as String,
          start: item['start'] as String,
          end: item['end'] as String,
          location: item['location'] as String,
          maxPeople: item['maxPeople'] as int?,
          capacityGroup: item['capacityGroup'] as String?,
        ),
      );
    }
    if (action != 'remove' && rows.isEmpty) {
      return (null, 'schedule cannot be empty');
    }
    return ((scope as String, week, action as String, rows), null);
  }

  Future<(int, Object)> _sessionScheduleCommit(String text) async {
    final Map<String, dynamic> body;
    try {
      body = _jsonBody(text);
    } catch (_) {
      return (400, {'ok': false, 'error': 'expected a JSON object'});
    }
    final parsed = _scheduleMutation(body);
    if (parsed.$2 != null) return (400, {'ok': false, 'error': parsed.$2});
    final (scope, week, action, rows) = parsed.$1!;
    final before = scope == 'recurring'
        ? repo.scheduleTemplate()
        : repo.scheduleForWeekend(week!);
    final after = _mutatedSchedule(before, rows, action);
    if (action == 'remove' && after.length == before.length) {
      return (
        409,
        {'ok': false, 'error': 'none of those sessions exists in the schedule'},
      );
    }
    if (after.isEmpty) {
      return (400, {'ok': false, 'error': 'schedule cannot be empty'});
    }
    final allocations = _removedAllocations(scope, week, after);
    if (scope == 'temporary') {
      repo.replaceScheduleOverride(
        week!,
        after,
        tzOffsetHours: config.timezoneOffsetHours,
      );
    } else {
      repo.replaceScheduleTemplate(after);
      final now = config.toLocal(Config.nowUtc());
      final window = scheduleRuntime.window(now);
      for (final sat in window.weekends) {
        if (_weekLocked(sat, now)) continue;
        // Reconcile by identity to preserve allocations and availability on
        // retained sessions; removing the override restores template behavior.
        repo.replaceScheduleOverride(
          sat,
          after,
          tzOffsetHours: config.timezoneOffsetHours,
        );
        repo.clearScheduleOverride(sat);
      }
    }
    final enabled = repo.activeOutreachEnabled('schedule-change');
    var notified = 0;
    var failures = 0;
    if (enabled && service != null) {
      final byUser = <int, List<String>>{};
      for (final row in allocations) {
        byUser
            .putIfAbsent(row['userId']! as int, () => <String>[])
            .add(
              AllocationRemovalNotice.escape(row['sessionLabel']! as String),
            );
      }
      for (final entry in byUser.entries) {
        try {
          await service!.bot.api.sendMessage(
            ChatID(entry.key),
            AllocationRemovalNotice.message(entry.value),
            parseMode: ParseMode.html,
          );
          notified++;
        } catch (error) {
          failures++;
          LogRing.log(
            'admin API schedule-change notice failed for ${entry.key}: $error',
          );
        }
      }
    }
    return (
      200,
      {
        'ok': true,
        'saved': true,
        'scope': scope,
        'week': week == null ? null : _apiDay(week),
        'rows': after.length,
        'affectedAllocations': allocations,
        'scheduleChangeEnabled': enabled,
        'notified': notified,
        'notificationFailures': failures,
      },
    );
  }

  List<Map<String, Object?>> _removedAllocations(
    String scope,
    DateTime? week,
    List<ScheduleSlot> after,
  ) {
    final now = config.toLocal(Config.nowUtc());
    final weekends = scope == 'temporary'
        ? [week!]
        : scheduleRuntime
              .window(now)
              .weekends
              .where((sat) => !_weekLocked(sat, now))
              .toList();
    final kept = after.map(_scheduleIdentity).toSet();
    return [
      for (final sat in weekends)
        for (final (user, session) in repo.allocationsForWeekend(sat))
          if (!kept.contains(_sessionIdentity(session)))
            {
              'userId': user.id,
              'userName': user.name,
              'sessionId': session.id,
              'sessionLabel':
                  '${session.day} ${repo.locationName(session.location)} ${session.start}',
              'week': _apiDay(sat),
            },
    ];
  }

  List<ScheduleSlot> _mutatedSchedule(
    List<ScheduleSlot> before,
    List<ScheduleSlot> rows,
    String action,
  ) {
    if (action == 'rewrite') return rows;
    if (action == 'remove') {
      return before
          .where(
            (old) => !rows.any(
              (r) =>
                  r.day == old.day &&
                  r.slot == old.slot &&
                  r.location == old.location,
            ),
          )
          .toList();
    }
    final out = [...before];
    for (final row in rows) {
      final i = out.indexWhere(
        (old) =>
            old.day == row.day &&
            old.slot == row.slot &&
            old.location == row.location,
      );
      if (i < 0) {
        out.add(row);
      } else {
        out[i] = row;
      }
    }
    return out;
  }
}
