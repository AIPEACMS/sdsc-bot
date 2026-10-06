part of '../admin_api.dart';

mixin _AdminApi4 on _AdminApiBase {

  /// Registers (or queues) a member by @handle, mirroring the /adduser
  /// outcome: already-registered → already member; pending → already queued;
  /// seen before → registered now; unseen → queued for first contact.
  /// An optional `tier` ("member" | "check") registers/queues the user
  /// directly as that tier — the console's "Add check" uses this instead of
  /// adding a member and converting afterwards.
  Future<(int, Object)> _addUser(String bodyText) async {
    final body = _jsonBody(bodyText);
    final handle =
        (body['handle'] as String?)?.trim().replaceFirst('@', '') ?? '';
    final tier = (body['tier'] as String?) ?? MemberTier.member;
    if (handle.isEmpty || handle.contains(' ')) {
      return (400, {'ok': false, 'error': 'expected {"handle": "@username"}'});
    }
    if (tier != MemberTier.member &&
        tier != MemberTier.outMember &&
        tier != MemberTier.check) {
      return (
        400,
        {'ok': false, 'error': 'tier must be "member", "out-member" or "check"'},
      );
    }
    final preference = _notificationFromBody(body);
    if ((body.containsKey('notificationPreference') ||
            body.containsKey('preference') ||
            body.containsKey('notify')) &&
        preference == null) {
      return (400, {'ok': false, 'error': 'bad notification preference'});
    }
    final isCheck = tier == MemberTier.check;
    final userId = repo.userIdByUsername(handle);
    final existing = userId == null ? null : repo.findUser(userId);
    final pending = repo.pendingRole(handle);
    if (existing != null) {
      repo.removePendingUser(handle);
      if (existing.isGlobalAdmin) {
        return (409, {'ok': false, 'error': 'global admin cannot be converted'});
      }
      if (existing.isAdmin) {
        return (
          409,
          {
            'ok': false,
            'error': 'user is already an admin; demote them before conversion',
          },
        );
      }
      if (existing.memberTier == tier) {
        if (preference != null) repo.setNotificationPreference(existing.id, preference);
        return (
          200,
          {
            'ok': true,
            'message': '@$handle is already a ${_tierLabel(tier)}.',
          },
        );
      }
      if (!repo.setTier(existing.id, tier)) {
        return (409, {'ok': false, 'error': 'user cannot be converted'});
      }
      if (preference != null) repo.setNotificationPreference(existing.id, preference);
      return (
        200,
        {'ok': true, 'message': '@$handle converted to ${_tierLabel(tier)}.'},
      );
    }
    if (pending != null) {
      repo.replacePendingUser(
        handle,
        isAdmin: false,
        tier: tier,
        notificationPreference:
            preference ?? NotificationPreference.weekly,
      );
      return (
        200,
        {
          'ok': true,
          'warning': true,
          'message': '@$handle is not registered; pending role '
              '${_tierLabel(pending.effectiveTier)} was replaced with '
              '${_tierLabel(tier)}.',
        },
      );
    }
    if (userId != null) {
      repo.upsertUser(
        User(
          id: userId,
          name: '@$handle',
          experience: Experience.newbie,
          group: '',
          memberTier: tier,
        ),
      );
      if (preference != null) repo.setNotificationPreference(userId, preference);
      return (
        200,
        {
          'ok': true,
          'message': isCheck
              ? '@$handle added as a checker. They can now use /start to see '
                    'their commands.'
              : '@$handle added. They can now use /start to see their commands.',
        },
      );
    }
    repo.addPendingUser(
      handle,
      isAdmin: false,
      tier: tier,
      notificationPreference: preference ?? NotificationPreference.weekly,
    );
    return (
      200,
      {
        'ok': true,
        'message': isCheck
            ? '@$handle queued as a checker — no need for them to message '
                  'first. The moment they message this bot, they are registered '
                  'automatically.'
            : '@$handle queued — no need for them to message first. The '
                  'moment they message this bot, they are registered '
                  'automatically.',
      },
    );
  }

  /// Runs a cycle-driving operation (prompt / remind / allocate). Requires
  /// the wired [service]; the ops themselves follow the same code path as
  /// the admin bot commands.
  Future<(int, Object)> _runCycleOp(String op) async {
    final service = this.service;
    if (service == null) {
      return (400, {'ok': false, 'error': 'cycle service not wired'});
    }
    final now = config.toLocal(Config.nowUtc());
    final w = _window(now);
    switch (op) {
      case 'prompt':
        await service.sendPrompts(w);
        LogRing.log('admin API: prompts sent');
        return (200, {'ok': true, 'op': op});
      case 'remind':
        await service.sendReminders(w);
        LogRing.log('admin API: reminders sent');
        return (200, {'ok': true, 'op': op});
      case 'allocate':
        await service.allocateBundle(w);
        LogRing.log('admin API: allocation run');
        return (200, {'ok': true, 'op': op});
    }
    return (400, {'ok': false, 'error': 'unknown op'});
  }

  /// Sends the availability picker to one member, like the admin /ask.
  Future<(int, Object)> _ask(String bodyText) async {
    final service = this.service;
    if (service == null) {
      return (400, {'ok': false, 'error': 'cycle service not wired'});
    }
    final body = _jsonBody(bodyText);
    final id = (body['userId'] as num?)?.toInt();
    if (id == null) {
      return (400, {'ok': false, 'error': 'expected {"userId": <id>}'});
    }
    final user = repo.findUser(id);
    if (user == null) return (404, {'ok': false, 'error': 'no such user'});
    if (user.memberTier == MemberTier.outMember) {
      return (400, {'ok': false, 'error': 'out-members are excluded from /ask'});
    }
    if (!repo.activeOutreachEnabled('ask')) {
      LogRing.log('ask: suppressed 1 delivery (route disabled)');
      return (
        200,
        {'ok': true, 'asked': false, 'message': 'Ask delivery is disabled.'},
      );
    }
    final now = config.toLocal(Config.nowUtc());
    final w = _window(now);
    final holiday = service.optedOutHolidayFor(user, w);
    if (holiday != null) {
      return (
        200,
        {
          'ok': true,
          'asked': false,
          'message':
              '${user.name} opted out of the holiday from '
              '${service.holidayPeriod(holiday)}. No availability picker was sent.',
        },
      );
    }
    if (!now.isBefore(w.deadline0)) {
      return (
        409,
        {'ok': false, 'error': 'availability is closed for this window'},
      );
    }
    final text = now.isBefore(w.reminderDay)
        ? service.promptFor(user, w)!
        : service.reminderFor(user, w)!;
    await service.showAvailability(user, w, text);
    LogRing.log('admin API: ask ${user.name}');
    return (200, {'ok': true, 'asked': user.name});
  }

  /// Sends [text] to every active member, like the admin /broadcast.
  Future<(int, Object)> _broadcast(String bodyText) async {
    final service = this.service;
    if (service == null) {
      return (400, {'ok': false, 'error': 'cycle service not wired'});
    }
    final body = _jsonBody(bodyText);
    final text = (body['text'] as String?)?.trim() ?? '';
    if (text.isEmpty) {
      return (400, {'ok': false, 'error': 'expected {"text": "..."}'});
    }
    if (!repo.activeOutreachEnabled('broadcast')) {
      final recipients = repo
          .activeUsers()
          .where((member) => member.memberTier != MemberTier.outMember)
          .length;
      LogRing.log(
        'broadcast: suppressed $recipients deliveries (route disabled)',
      );
      return (
        200,
        {'ok': true, 'sent': 0, 'message': 'Broadcast delivery is disabled.'},
      );
    }
    var sent = 0;
    for (final user in repo.activeUsers()) {
      if (user.memberTier == MemberTier.outMember) continue;
      try {
        await service.bot.api.sendMessage(ChatID(user.id), text);
        sent++;
      } catch (_) {
        // member may have blocked the bot
      }
    }
    LogRing.log('admin API: broadcast sent to $sent members');
    return (200, {'ok': true, 'sent': sent});
  }

  /// Current rolling window's sessions with their allocated members and
  /// attendance states, for the console's attendance timetable.
  Map<String, Object?> _attendanceBody() {
    final now = config.toLocal(Config.nowUtc());
    final w = _window(now);
    final sessions = repo.windowSessions(w);
    final bySession = <int, List<User>>{};
    for (final sat in w.weekends) {
      for (final (u, s) in repo.allocationsForWeekend(sat)) {
        bySession.putIfAbsent(s.id, () => []).add(u);
      }
    }
    return {
      'ok': true,
      'window': {
        'weekend0': w.sat0.toIso8601String(),
        'weekend1': w.sat1.toIso8601String(),
      },
      'sessions': [
        for (final s in sessions)
          {
            'id': s.id,
            'label': _sessionLabel(s),
            'location': s.location,
            'weekendStart': s.weekendStart.toIso8601String(),
            'day': s.day,
            'slot': s.slot,
            'start': s.start.toIso8601String(),
            'end': s.end.toIso8601String(),
            'maxPeople': s.maxPeople,
            // Whether the session has begun — attendance can only be marked
            // once it has, so the console hides future sessions from its
            // "unmarked" reminder.
            'started': !s.start.isAfter(now),
            'members': [
              for (final u in bySession[s.id] ?? const <User>[])
                _attendanceMemberJson(u, s),
            ],
          },
      ],
    };
  }

  /// Out-members are visible in the timetable because they can be allocated,
  /// but they cannot receive or expose attendance marks.
  Map<String, Object?> _attendanceMemberJson(User user, Session session) {
    final eligible = user.memberTier != MemberTier.outMember;
    return {
      'id': user.id,
      'name': user.name,
      'eligible': eligible,
      if (eligible) 'state': _attendanceStateFor(user.id, session.id),
    };
  }

  /// 'present' | 'absent' | 'unmarked' for (user, session).
  String _attendanceStateFor(int userId, int sessionId) {
    for (final a in repo.attendanceForSession(sessionId)) {
      if (a.userId == userId) {
        return a.attended ? 'present' : 'absent';
      }
    }
    return 'unmarked';
  }

}
