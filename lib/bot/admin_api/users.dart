part of '../admin_api.dart';

mixin _AdminApi2 on _AdminApiBase {

;

  Future<(int, Object)> _setSchedule(String bodyText) async {
    final Map<String, dynamic> body;
    try {
      body = _jsonBody(bodyText);
    } catch (_) {
      return (400, {'ok': false, 'error': 'expected a JSON object'});
    }
    if (body.containsKey('schedule') && body['schedule'] is! Map) {
      return (400, {'ok': false, 'error': 'schedule must be a JSON object'});
    }
    final hasNested = body['schedule'] is Map;
    if (hasNested && body.keys.any((key) => key != 'schedule')) {
      return (400, {'ok': false, 'error': 'unknown schedule fields'});
    }
    final nested = hasNested
        ? (body['schedule'] as Map).cast<String, dynamic>()
        : body;
    const knownKeys = {
      'prompt',
      'reminder',
      'lock',
      'checker',
      'promptWeekday',
      'reminderWeekday',
      'lockWeekday',
      'checkerWeekday',
      // Kept for clients that POST the complete GET response. The timezone is
      // configured by the server and is not mutable through this endpoint.
      'timezoneOffset',
    };
    if (nested.isEmpty || nested.keys.any((key) => !knownKeys.contains(key))) {
      return (400, {'ok': false, 'error': 'schedule has no valid fields'});
    }
    if (nested.keys.every((key) => key == 'timezoneOffset')) {
      return (400, {'ok': false, 'error': 'schedule has no timing fields'});
    }
    if (nested.containsKey('timezoneOffset')) {
      final offset = nested['timezoneOffset'];
      if (offset is! num || offset.toInt() != offset ||
          offset.toInt() != config.timezoneOffsetHours) {
        return (400, {
          'ok': false,
          'error': 'timezoneOffset is controlled by server configuration',
        });
      }
    }

    final current = scheduleRuntime.schedule;
    LocalWallClock parse(String key, LocalWallClock fallback) {
      if (!nested.containsKey(key)) return fallback;
      final raw = nested[key];
      if (raw is! String) {
        throw FormatException('$key: expected HH:MM');
      }
      try {
        return LocalWallClock.parse(raw);
      } on FormatException catch (e) {
        throw FormatException('$key: ${e.message}');
      }
    }
    String parseWeekday(String key, String fallback) {
      if (!nested.containsKey(key)) return fallback;
      final raw = nested[key];
      if (raw is! String || scheduleWeekdayNumber(raw) == null) {
        throw FormatException(
          '${key.replaceAll('Weekday', ' weekday')}: '
          'expected one of mon, tue, wed, thu, fri',
        );
      }
      return raw;
    }

    final ScheduleTimes next;
    try {
      next = ScheduleTimes(
        prompt: ScheduleEvent(
          weekday: parseWeekday('promptWeekday', current.prompt.weekday),
          time: parse('prompt', current.prompt.time),
        ),
        reminder: ScheduleEvent(
          weekday: parseWeekday('reminderWeekday', current.reminder.weekday),
          time: parse('reminder', current.reminder.time),
        ),
        lock: ScheduleEvent(
          weekday: parseWeekday('lockWeekday', current.lock.weekday),
          time: parse('lock', current.lock.time),
        ),
        checker: ScheduleEvent(
          weekday: parseWeekday('checkerWeekday', current.checker.weekday),
          time: parse('checker', current.checker.time),
        ),
      )..validate();
    } on FormatException catch (e) {
      return (400, {'ok': false, 'error': e.message});
    } on ArgumentError catch (e) {
      return (400, {'ok': false, 'error': e.message});
    }
    scheduleRuntime.update(next);
    LogRing.log('admin API: schedule updated');
    return (200, {
      'ok': true,
      ..._scheduleJson(),
      'schedule': _scheduleJson(),
    });
  }

  /// The user's full set of groups, most significant first. The console and
  /// global-admin identities are independent and can both be present.
  static List<String> _groupsOf(User u, {required bool isConsole}) {
    final groups = <String>[];
    if (isConsole) groups.add(MemberTier.console);
    if (u.isGlobalAdmin) groups.add(MemberTier.globalAdmin);
    if (u.isAdmin) groups.add(MemberTier.admin);
    if (u.memberTier == MemberTier.check ||
        u.memberTier == MemberTier.outMember ||
        u.memberTier == MemberTier.old) {
      groups.add(u.memberTier);
    } else if (u.memberTier == MemberTier.member &&
        !u.isAdmin &&
        !u.isGlobalAdmin) {
      groups.add(MemberTier.member);
    }
    if (groups.isEmpty) groups.add(MemberTier.member);
    return groups;
  }

  List<Map<String, Object?>> _usersJson() {
    return repo.allUsers().map(_userJson).toList();
  }

  Map<String, Object?> _userJson(User u) {
    final attendance = u.memberTier == MemberTier.outMember
        ? <String, Object?>{
            'total': 0,
            'ocbc': 0,
            'pasirRis': 0,
            'byLocation': <String, int>{},
          }
        : () {
            final stats = repo.attendanceStats(u.id);
            return <String, Object?>{
              'total': stats.total,
              'ocbc': stats.byLocation['ocbc'] ?? 0,
              'pasirRis': stats.byLocation['pasirRis'] ?? 0,
              'byLocation': stats.byLocation,
            };
          }();
    return {
      'id': u.id,
      'name': u.name,
      'tier': MemberTier.of(u, isConsole: config.isConsole(u.id)),
      'groups': _groupsOf(u, isConsole: config.isConsole(u.id)),
      'group': u.group,
      'preferredName': u.preferredName,
      'experience': u.experience.name,
      'notificationPreference': _notificationValue(u.notificationPreference),
      'lastPromptState': u.lastPromptState.name,
      'ocbcStreak': u.ocbcStreak,
      'attendance': attendance,
    };
  }

  Future<(int, Object)> _setTier(int id, String bodyText) async {
    final user = repo.findUser(id);
    if (user == null) return (404, {'ok': false, 'error': 'no such user'});
    final body = _jsonBody(bodyText);
    final tier = (body['tier'] as String?) ?? '';
    if (![
      MemberTier.admin,
      MemberTier.check,
      MemberTier.member,
      MemberTier.outMember,
      MemberTier.old,
    ].contains(tier)) {
      return (400, {'ok': false, 'error': 'bad tier'});
    }
    if (tier == MemberTier.admin && user.memberTier == MemberTier.outMember) {
      return (400, {
        'ok': false,
        'error': 'out-members cannot be promoted to admin',
      });
    }
    final preference = _notificationFromBody(body);
    if ((body.containsKey('notificationPreference') ||
            body.containsKey('preference') ||
            body.containsKey('notify')) &&
        preference == null) {
      return (400, {'ok': false, 'error': 'bad notification preference'});
    }
    if (!repo.setTier(id, tier)) {
      return (
        409,
        {'ok': false, 'error': 'global admin role requires Telegram handoff'},
      );
    }
    if (preference != null) repo.setNotificationPreference(id, preference);
    final updated = repo.findUser(id)!;
    LogRing.log(
      'admin API: ${user.name} ${user.isAdmin ? 'admin' : ''} → tier $tier',
    );
    return (
      200,
      {
        'ok': true,
        'user': updated.name,
        'tier': MemberTier.of(updated, isConsole: config.isConsole(id)),
        'notificationPreference': _notificationValue(
          updated.notificationPreference,
        ),
      },
    );
  }

  Future<(int, Object)> _setUserNotification(
    int id,
    String bodyText,
  ) async {
    final user = repo.findUser(id);
    if (user == null) return (404, {'ok': false, 'error': 'no such user'});
    final body = _jsonBody(bodyText);
    final preference = _notificationFromBody(body);
    if (preference == null) {
      return (
        400,
        {
          'ok': false,
          'error':
              'expected {"preference": "weekly"|"every-other"|"never"}',
        },
      );
    }
    repo.setNotificationPreference(id, preference);
    final updated = repo.findUser(id)!;
    return (
      200,
      {
        'ok': true,
        'notificationPreference': _notificationValue(
          updated.notificationPreference,
        ),
      },
    );
  }

  Future<(int, Object)> _getUserNotification(int id) async {
    final user = repo.findUser(id);
    if (user == null) return (404, {'ok': false, 'error': 'no such user'});
    return (
      200,
      {
        'ok': true,
        'notificationPreference': _notificationValue(
          user.notificationPreference,
        ),
        'lastPromptState': user.lastPromptState.name,
      },
    );
  }

}
