part of '../admin_api.dart';

extension AdminApiRemovals on AdminApi {
  (Map<String, dynamic>?, String?) _removalTarget(String text) {
    final Map<String, dynamic> body;
    try {
      body = _jsonBody(text);
    } catch (_) {
      return (null, 'expected a JSON object');
    }
    if ((body.length == 1 || (body.length == 2 && body['week'] is String)) &&
        _integer(body['sessionId'])) {
      return (body, null);
    }
    final entries = body['entries'];
    final hasWeek = body['week'] is String;
    if ((body.length != 1 && !(hasWeek && body.length == 2)) ||
        entries is! List ||
        entries.isEmpty) {
      return (
        null,
        'expected sessionId or a non-empty entries list, optionally scoped by week',
      );
    }
    for (final entry in entries) {
      if (entry is! Map ||
          !_integer(entry['sessionId']) ||
          !_integer(entry['userId'])) {
        return (null, 'each entry needs integer sessionId and userId');
      }
    }
    return (body, null);
  }

  bool _integer(Object? value) =>
      value is int ||
      (value is double && value.isFinite && value == value.truncateToDouble());

  Future<(int, Object)> _allocationRemovalPreview(String text) async {
    final (body, error) = _removalTarget(text);
    if (error != null) return (400, {'ok': false, 'error': error});
    final target = _currentRemovalRows(body!);
    if (target == null) {
      return (
        409,
        {
          'ok': false,
          'error': 'target is outside the current window or no longer exists',
        },
      );
    }
    final wholeSession = body.containsKey('sessionId');
    final session = wholeSession ? repo.sessionById(target.$1) : null;
    return (
      200,
      {
        'ok': true,
        'allocations': target.$2,
        'scheduleChangeEnabled': repo.activeOutreachEnabled('schedule-change'),
        if (wholeSession) ...{
          'sessionId': target.$1,
          'sessionLabel': session == null ? '' : _sessionLabel(session),
        },
      },
    );
  }

  (int, List<Map<String, Object?>>)? _currentRemovalRows(
    Map<String, dynamic> body,
  ) {
    final now = config.toLocal(Config.nowUtc());
    final window = _window(now);
    final selectedWeek = body['week'] is String
        ? DateTime.tryParse(body['week'] as String)
        : null;
    if (body.containsKey('week') &&
        (selectedWeek == null || !_isSaturday(selectedWeek))) {
      return null;
    }
    if (selectedWeek != null) {
      final deadline = RollingWindow.fromSat0(
        selectedWeek,
        schedule: scheduleRuntime.schedule,
      ).deadlineFor(selectedWeek);
      if (!now.isBefore(deadline)) return null;
    }
    final validIds = selectedWeek == null
        ? repo.windowSessions(window).map((s) => s.id).toSet()
        : repo.sessionsForWeekend(selectedWeek).map((s) => s.id).toSet();
    final sessionId = (body['sessionId'] as num?)?.toInt();
    if (sessionId != null) {
      if (!validIds.contains(sessionId)) return null;
      final session = repo.sessionById(sessionId);
      if (session == null) return null;
      final rows = repo
          .allocationsForWeekend(session.weekendStart)
          .where((entry) => entry.$2.id == sessionId)
          .map((entry) => _removalJson(entry.$1, entry.$2))
          .toList();
      return (sessionId, rows);
    }
    final result = <Map<String, Object?>>[];
    final seen = <String>{};
    for (final entry in (body['entries'] as List).cast<Map>()) {
      final sid = (entry['sessionId'] as num).toInt();
      final uid = (entry['userId'] as num).toInt();
      if (!validIds.contains(sid)) return null;
      final match = repo
          .allocationsForWeekend(repo.sessionById(sid)!.weekendStart)
          .where((row) => row.$1.id == uid && row.$2.id == sid);
      if (match.isEmpty) return null;
      if (seen.add('$sid:$uid')) {
        result.add(_removalJson(match.first.$1, match.first.$2));
      }
    }
    return (-1, result);
  }

  bool _isSaturday(DateTime date) =>
      date.weekday == DateTime.saturday &&
      date.hour == 0 &&
      date.minute == 0 &&
      date.second == 0 &&
      date.millisecond == 0 &&
      date.microsecond == 0;

  Map<String, Object?> _removalJson(User user, Session session) => {
    'sessionId': session.id,
    'userId': user.id,
    'userName': user.name,
    'sessionLabel': _sessionLabel(session),
    'weekendStart': session.weekendStart.toIso8601String(),
  };

  Future<(int, Object)> _removeAllocations(String text) async {
    final service = this.service;
    if (service == null) {
      return (400, {'ok': false, 'error': 'cycle service not wired'});
    }
    final (body, error) = _removalTarget(text);
    if (error != null) return (400, {'ok': false, 'error': error});
    final target = _currentRemovalRows(body!);
    if (target == null) {
      return (
        409,
        {
          'ok': false,
          'error': 'target is outside the current window or no longer exists',
        },
      );
    }
    final enabled = repo.activeOutreachEnabled('schedule-change');
    final rows = target.$2;
    final sessionToDelete = body.containsKey('sessionId')
        ? repo.sessionById(target.$1)
        : null;
    try {
      if (sessionToDelete != null) {
        final effective = repo.scheduleForWeekend(sessionToDelete.weekendStart);
        final remaining = effective
            .where(
              (row) =>
                  !(row.day == sessionToDelete.day &&
                      row.slot == sessionToDelete.slot &&
                      row.location == sessionToDelete.location),
            )
            .toList();
        repo.replaceScheduleOverride(
          sessionToDelete.weekendStart,
          remaining,
          tzOffsetHours: config.timezoneOffsetHours,
        );
      } else {
        final db = repo.raw;
        db.execute('BEGIN IMMEDIATE');
        try {
          for (final row in rows) {
            final session = repo.sessionById(row['sessionId']! as int);
            if (session != null) {
              repo.removeAvailabilityForSession(
                row['userId']! as int,
                session.weekendStart,
                session.day,
                session.slot,
                session.location,
              );
            }
            db.execute(
              'DELETE FROM attendance WHERE user_id = ? AND session_id = ?',
              [row['userId'], row['sessionId']],
            );
            db.execute(
              'DELETE FROM allocations WHERE user_id = ? AND session_id = ?',
              [row['userId'], row['sessionId']],
            );
          }
          db.execute('COMMIT');
        } catch (_) {
          db.execute('ROLLBACK');
          rethrow;
        }
      }
    } catch (e) {
      LogRing.log('allocation removal transaction failed: $e');
      rethrow;
    }
    var notified = 0;
    var failures = 0;
    if (enabled && rows.isNotEmpty) {
      final byUser = <int, List<Map<String, Object?>>>{};
      for (final row in rows) {
        byUser.putIfAbsent(row['userId']! as int, () => []).add(row);
      }
      for (final item in byUser.entries) {
        try {
          await service.bot.api.sendMessage(
            ChatID(item.key),
            AllocationRemovalNotice.message(
              item.value.map(
                (row) => AllocationRemovalNotice.escape(
                  row['sessionLabel']! as String,
                ),
              ),
            ),
            parseMode: ParseMode.html,
          );
          notified++;
        } catch (e) {
          failures++;
          LogRing.log(
            'allocation removal notification failed for user ${item.key}: $e',
          );
        }
      }
    }
    LogRing.log(
      'allocation removal completed: ${rows.length} rows, $notified notified, $failures failures',
    );
    return (
      200,
      {
        'ok': true,
        'removed': rows.length,
        'notified': notified,
        'notificationFailures': failures,
        'scheduleChangeEnabled': enabled,
        'sessionRemoved': sessionToDelete != null,
      },
    );
  }
}
