part of '../admin_api.dart';

extension AdminApiAttendanceCorrections on AdminApi {
  static const _previewLifetime = Duration(minutes: 5);
  static const _challengeLifetime = Duration(minutes: 10);

  String _randomToken(int byteCount) => base64UrlEncode(
    List<int>.generate(byteCount, (_) => _secureRandom.nextInt(256)),
  ).replaceAll('=', '');

  String _tokenHash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  String? _dateOnly(DateTime? date) {
    if (date == null) return null;
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  DateTime? _parseCorrectionDate(Object? value, DateTime today) {
    if (value == null) return null;
    if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      throw const FormatException('Use a date in YYYY-MM-DD format.');
    }
    final date = DateTime.tryParse(value);
    if (date == null || _dateOnly(date) != value) {
      throw const FormatException('That date is not valid.');
    }
    if (date.isAfter(DateTime(today.year, today.month, today.day))) {
      throw const FormatException('Future dates are not allowed.');
    }
    return date;
  }

  Future<(int, Object)> _createConsoleKeyBindChallenge(String? pubkey) async {
    if (pubkey == null) {
      return (
        403,
        {
          'ok': false,
          'error': 'Use the registered console key to request a binding code.',
        },
      );
    }
    final code = _randomToken(24);
    final now = config.toLocal(Config.nowUtc());
    final expiresAt = now.add(_challengeLifetime);
    final result = repo.createConsoleKeyBindingChallenge(
      pubkey,
      challengeHash: _tokenHash(code),
      expiresAt: expiresAt.toIso8601String(),
    );
    if (result == ConsoleKeyBindingResult.alreadyBound) {
      return (
        409,
        {
          'ok': false,
          'error':
              'This console key is already bound. Remove and register a new key to change its owner.',
        },
      );
    }
    if (result != ConsoleKeyBindingResult.success) {
      return (
        401,
        {'ok': false, 'error': 'This console key is not registered.'},
      );
    }
    return (
      200,
      {
        'ok': true,
        'code': code,
        'expiresAt': expiresAt.toIso8601String(),
        'instruction':
            'Copy this code, then send /bind_key in Telegram and paste it. It expires in 10 minutes.',
      },
    );
  }

  ({int keyId, User? actor})? _correctionOwner(String? pubkey) {
    if (pubkey == null) return null;
    final identity = repo.consoleKeyIdentity(pubkey);
    final actorId = identity?.actorUserId;
    if (identity == null || actorId == null) return null;
    final actor = repo.findUser(actorId);
    return (keyId: identity.id, actor: actor);
  }

  (int, Object) _unboundKeyResponse() => (
    403,
    {
      'ok': false,
      'error':
          'This console key is not bound to an admin. In the console, request a binding code, then run /bind_key in Telegram and paste it.',
    },
  );

  (int, Object) _inactiveOwnerResponse() => (
    403,
    {
      'ok': false,
      'error':
          'The admin account bound to this key is no longer eligible. Ask a global admin to remove the key and register a replacement.',
    },
  );

  Future<(int, Object)> _attendanceCorrectionTargets(String? pubkey) async {
    final owner = _correctionOwner(pubkey);
    if (owner == null) return _unboundKeyResponse();
    final actor = owner.actor;
    if (actor == null || (!actor.isAdmin && !actor.isGlobalAdmin)) {
      return _inactiveOwnerResponse();
    }
    final users = repo.activeUsers().where((user) {
      if (user.memberTier != MemberTier.member) return false;
      if (actor.isGlobalAdmin) return true;
      return actor.isAdmin &&
          actor.group.isNotEmpty &&
          user.group == actor.group;
    });
    final targets = [
      for (final user in users)
        {
          'userId': user.id,
          'name': user.name,
          'sessionAttendanceCount': repo.attendanceStats(user.id).total,
          'attendanceBalance': user.attendanceBalance,
          'lastAttendedDate': _dateOnly(repo.lastAttendedDate(user.id)),
        },
    ];
    final today = config.toLocal(Config.nowUtc());
    return (
      200,
      {
        'ok': true,
        'serverLocalDate': _dateOnly(today),
        'scopes': actor.isGlobalAdmin
            ? ['all', if (actor.group.isNotEmpty) 'group']
            : ['group'],
        'targets': targets,
      },
    );
  }

  Future<(int, Object)> _attendanceCorrectionPreview(
    String? pubkey,
    String bodyText,
  ) async {
    final owner = _correctionOwner(pubkey);
    if (owner == null) return _unboundKeyResponse();
    if (owner.actor == null ||
        (!owner.actor!.isAdmin && !owner.actor!.isGlobalAdmin)) {
      return _inactiveOwnerResponse();
    }
    final Map<String, dynamic> body;
    try {
      body = _jsonBody(bodyText);
    } catch (_) {
      return (400, {'ok': false, 'error': 'Expected a JSON object.'});
    }
    const allowedFields = {'targetId', 'delta', 'date', 'scope'};
    if (body.keys.any((key) => !allowedFields.contains(key)) ||
        body['targetId'] is! int ||
        body['delta'] is! int ||
        body['scope'] is! String) {
      return (
        400,
        {
          'ok': false,
          'error':
              'Expected targetId, integer delta, scope, and optional date.',
        },
      );
    }
    final targetId = body['targetId'] as int;
    final delta = body['delta'] as int;
    final scope = body['scope'] as String;
    final actor = owner.actor!;
    if (scope != 'all' && scope != 'group') {
      return (400, {'ok': false, 'error': 'Scope must be all or group.'});
    }
    if (scope == 'all' && !actor.isGlobalAdmin) {
      return (
        403,
        {'ok': false, 'error': 'Only a global admin can correct all members.'},
      );
    }
    if (scope == 'group' && (!actor.isAdmin && !actor.isGlobalAdmin)) {
      return (403, {'ok': false, 'error': 'An admin account is required.'});
    }
    if (scope == 'group' && delta < 0) {
      return (
        400,
        {
          'ok': false,
          'error': 'Group attendance corrections cannot reduce the balance.',
        },
      );
    }
    if (delta < -1000000000 || delta > 1000000000) {
      return (400, {'ok': false, 'error': 'The adjustment is too large.'});
    }
    final target = repo.findUser(targetId);
    final inScope =
        target != null &&
        repo.activeUsers().any((user) => user.id == target.id) &&
        target.memberTier == MemberTier.member &&
        (scope == 'all' ||
            (actor.group.isNotEmpty && target.group == actor.group));
    if (!inScope) {
      return (
        404,
        {
          'ok': false,
          'error': 'That member is not eligible in this correction scope.',
        },
      );
    }
    final now = config.toLocal(Config.nowUtc());
    final DateTime? requestedDate;
    try {
      requestedDate = _parseCorrectionDate(body['date'], now);
    } on FormatException catch (error) {
      return (400, {'ok': false, 'error': error.message});
    }
    final currentDate = repo.lastAttendedDate(targetId);
    final actualDate = repo.actualLastAttendedDate(targetId);
    final proposedDate = requestedDate == null
        ? currentDate
        : actualDate != null && actualDate.isAfter(requestedDate)
        ? actualDate
        : requestedDate;
    final count = repo.attendanceStats(targetId).total;
    final token = _randomToken(32);
    final expiresAt = now.add(_previewLifetime);
    repo.storeAttendanceCorrectionPreview(
      tokenHash: _tokenHash(token),
      consoleKeyId: owner.keyId,
      actorUserId: actor.id,
      targetUserId: targetId,
      scope: scope,
      delta: delta,
      requestedDate: requestedDate == null ? null : _dateOnly(requestedDate),
      expectedSessionCount: count,
      expectedBalance: target.attendanceBalance,
      expectedEffectiveDate: currentDate == null
          ? null
          : _dateOnly(currentDate),
      expiresAt: expiresAt.toIso8601String(),
      now: now.toIso8601String(),
    );
    return (
      200,
      {
        'ok': true,
        'previewToken': token,
        'expiresAt': expiresAt.toIso8601String(),
        'scope': scope,
        'target': {'userId': target.id, 'name': target.name},
        'currentSessionAttendanceCount': count,
        'proposedSessionAttendanceCount': count,
        'currentBalance': target.attendanceBalance,
        'proposedBalance': target.attendanceBalance + delta,
        'currentLastAttendedDate': _dateOnly(currentDate),
        'proposedLastAttendedDate': _dateOnly(proposedDate),
        'serverLocalDate': _dateOnly(now),
      },
    );
  }

  Future<(int, Object)> _attendanceCorrectionApply(
    String? pubkey,
    String bodyText,
  ) async {
    final owner = _correctionOwner(pubkey);
    if (owner == null) return _unboundKeyResponse();
    if (owner.actor == null ||
        (!owner.actor!.isAdmin && !owner.actor!.isGlobalAdmin)) {
      return _inactiveOwnerResponse();
    }
    final Map<String, dynamic> body;
    try {
      body = _jsonBody(bodyText);
    } catch (_) {
      return (400, {'ok': false, 'error': 'Expected a JSON object.'});
    }
    if (body.length != 1 || body['previewToken'] is! String) {
      return (
        400,
        {'ok': false, 'error': 'A confirmed previewToken is required.'},
      );
    }
    final now = config.toLocal(Config.nowUtc());
    final (result, targetId) = repo.applyAttendanceCorrectionPreview(
      tokenHash: _tokenHash(body['previewToken'] as String),
      consoleKeyId: owner.keyId,
      actorUserId: owner.actor!.id,
      now: now.toIso8601String(),
    );
    if (result == AttendanceCorrectionApplyResult.expired) {
      return (
        409,
        {
          'ok': false,
          'error':
              'This preview expired. Review a new preview before applying.',
        },
      );
    }
    if (result == AttendanceCorrectionApplyResult.stale) {
      return (
        409,
        {
          'ok': false,
          'error':
              'The member or correction changed. Review a new preview before applying.',
        },
      );
    }
    if (result == AttendanceCorrectionApplyResult.forbidden ||
        targetId == null) {
      return (
        403,
        {
          'ok': false,
          'error':
              'Your admin role or correction scope changed. No change was made.',
        },
      );
    }
    final updated = repo.findUser(targetId)!;
    final attendanceCount = repo.attendanceStats(targetId).total;
    try {
      await service?.reconcileAttendanceCorrection(updated);
    } catch (error, stackTrace) {
      LogRing.log(
        'attendance correction reconciliation failed for user $targetId: '
        '$error\n$stackTrace',
      );
    }
    return (
      200,
      {
        'ok': true,
        'userId': targetId,
        'sessionAttendanceCount': attendanceCount,
        'attendanceBalance': updated.attendanceBalance,
        'lastAttendedDate': _dateOnly(repo.lastAttendedDate(targetId)),
      },
    );
  }
}
