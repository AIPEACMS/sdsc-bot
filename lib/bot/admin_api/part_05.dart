part of '../admin_api.dart';

mixin _AdminApi5 on _AdminApiBase {

  /// Sets one member's attendance state for a session: 'present' | 'absent'
  /// | 'unmarked' (removes the mark — recoverable).
  Future<(int, Object)> _toggleAttendance(String bodyText) async {
    final service = this.service;
    if (service == null) {
      return (400, {'ok': false, 'error': 'cycle service not wired'});
    }
    final body = _jsonBody(bodyText);
    final sessionId = (body['sessionId'] as num?)?.toInt();
    final userId = (body['userId'] as num?)?.toInt();
    if (sessionId == null || userId == null) {
      return (
        400,
        {'ok': false, 'error': 'expected {"sessionId": <id>, "userId": <id>}'},
      );
    }
    final session = repo.sessionById(sessionId);
    if (session == null) {
      return (404, {'ok': false, 'error': 'no such session'});
    }
    final user = repo.findUser(userId);
    if (user == null) {
      return (404, {'ok': false, 'error': 'no such user'});
    }
    if (user.memberTier == MemberTier.outMember) {
      return (
        400,
        {'ok': false, 'error': 'out-members are excluded from attendance'},
      );
    }
    final state = (body['state'] as String?) ?? 'unmarked';
    switch (state) {
      case 'present':
        service.markAttendance(userId, sessionId, attended: true);
      case 'absent':
        repo.setAttendanceState(userId, sessionId, attended: false);
      case 'unmarked':
        repo.clearAttendance(userId, sessionId);
      default:
        return (
          400,
          {
            'ok': false,
            'error': 'expected {"state": "present"|"absent"|"unmarked"}',
          },
        );
    }
    LogRing.log('admin API: attendance ${user.name} → $state');
    return (200, {'ok': true, 'state': state});
  }

  String _sessionLabel(Session s) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final loc = repo.locationName(s.location);
    final day = Slot.dayName(s.day);
    final time = '${s.start.hour.toString().padLeft(2, '0')}:'
        '${s.start.minute.toString().padLeft(2, '0')}-'
        '${s.end.hour.toString().padLeft(2, '0')}:'
        '${s.end.minute.toString().padLeft(2, '0')}';
    return '$loc · $day ${s.start.day} ${months[s.start.month - 1]} $time';
  }

  Future<(int, Object)> _setHold(String bodyText) async {
    final body = _jsonBody(bodyText);
    final held = body['held'];
    if (held is! bool) {
      return (400, {'ok': false, 'error': 'expected {"held": bool}'});
    }
    repo.setHeld(held);
    holdGate.held = held;
    LogRing.log('admin API: ${held ? 'hold' : 'unhold'}');
    return (200, {'ok': true, 'held': held});
  }

  Future<(int, Object)> _setDate(String bodyText) async {
    final body = _jsonBody(bodyText);
    if (body['reset'] == true) {
      Config.setDebugNow(null);
      LogRing.log('admin API: reset-date');
      return (200, {'ok': true, 'held': false, 'reset': true});
    }
    final raw = (body['date'] as String?) ?? '';
    final parsed = _parseDate(raw);
    if (parsed == null) {
      return (
        400,
        {'ok': false, 'error': 'expected {"date": "YYYY-MM-DD [HH:MM]"}'},
      );
    }
    Config.setDebugNow(parsed);
    LogRing.log('admin API: set-date to $raw');
    return (200, {'ok': true, 'date': raw});
  }

  Future<(int, Object)> _syncCalendar(String bodyText) async {
    final body = _jsonBody(bodyText);
    final yaml = (body['yaml'] as String?) ?? '';
    if (yaml.trim().isEmpty) {
      return (400, {'ok': false, 'error': 'expected {"yaml": "..."}'});
    }
    try {
      final result = calendarSync.apply(yaml);
      LogRing.log(
        'admin API: sync-calendar ${result.academicYear} '
        '(${result.weeks} weeks, ${result.holidays} holidays)',
      );
      return (
        200,
        {
          'ok': true,
          'academicYear': result.academicYear,
          'weeks': result.weeks,
          'holidays': result.holidays,
        },
      );
    } catch (e) {
      return (400, {'ok': false, 'error': 'sync failed: $e'});
    }
  }

  Future<(int, Object)> _setLogRetention(String bodyText) async {
    final body = _jsonBody(bodyText);
    final days = body['days'];
    if (days is! num || days <= 0) {
      return (400, {'ok': false, 'error': 'expected {"days": <positive int>}'});
    }
    final wholeDays = days.toInt();
    repo.setSetting('log_retention_days', '$wholeDays');
    LogRing.setRetention(Duration(days: wholeDays));
    LogRing.log('admin API: log retention set to $wholeDays days');
    return (200, {'ok': true, 'days': wholeDays});
  }

  /// Parses "YYYY-MM-DD [HH:MM]" into the debug "now" instant (UTC, offset
  /// applied), mirroring the console /setdate behavior.
  DateTime? _parseDate(String input) {
    final parts = input.trim().split(RegExp(r'\s+'));
    final date = DateTime.tryParse(parts.first);
    if (date == null) return null;
    var local = DateTime(date.year, date.month, date.day);
    if (parts.length > 1) {
      final t = parts[1].split(':');
      final h = int.tryParse(t[0]);
      final m = t.length > 1 ? int.tryParse(t[1]) : 0;
      if (h == null || m == null) return null;
      local = DateTime(date.year, date.month, date.day, h, m);
    }
    return local.subtract(Duration(hours: config.timezoneOffsetHours)).toUtc();
  }

  static Map<String, dynamic> _jsonBody(String text) {
    if (text.trim().isEmpty) return {};
    return jsonDecode(text) as Map<String, dynamic>;
  }

  static NotificationPreference? _notificationFromBody(
    Map<String, dynamic> body,
  ) {
    final raw =
        body['notificationPreference'] ?? body['preference'] ?? body['notify'];
    if (raw == null) return null;
    if (raw is! String) return null;
    return switch (raw.toLowerCase()) {
      'weekly' || 'week' => NotificationPreference.weekly,
      'every-other' || 'every_other' || 'everyother' =>
        NotificationPreference.everyOther,
      'never' => NotificationPreference.never,
      _ => null,
    };
  }

  static String _notificationValue(NotificationPreference preference) =>
      preference == NotificationPreference.everyOther
      ? 'every-other'
      : preference.name;

  static String _tierLabel(String tier) => tier == MemberTier.outMember
      ? 'out-member'
      : tier == MemberTier.member
      ? 'member'
      : tier;

}
