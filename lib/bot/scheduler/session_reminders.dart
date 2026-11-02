part of '../scheduler.dart';

DateTime sessionReminderDueAt(Session session, {int timezoneOffsetHours = 8}) {
  final dueLocal = _sessionReminderDueUtc(
    session,
    timezoneOffsetHours,
  ).add(Duration(hours: timezoneOffsetHours));
  return DateTime.utc(
    dueLocal.year,
    dueLocal.month,
    dueLocal.day,
    dueLocal.hour,
    dueLocal.minute,
  );
}

DateTime _sessionReminderDueUtc(Session session, int timezoneOffsetHours) {
  final sessionUtc = _sessionStartUtc(session, timezoneOffsetHours);
  final singaporeStart = sessionUtc.add(const Duration(hours: 8));
  return DateTime.utc(
    singaporeStart.year,
    singaporeStart.month,
    singaporeStart.day - 1,
    18,
  ).subtract(const Duration(hours: 8));
}

DateTime _sessionStartUtc(Session session, int timezoneOffsetHours) =>
    DateTime.utc(
      session.start.year,
      session.start.month,
      session.start.day,
      session.start.hour,
      session.start.minute,
    ).subtract(Duration(hours: timezoneOffsetHours));

bool sessionReminderIsDue(
  Session session,
  DateTime localNow, {
  int timezoneOffsetHours = 8,
}) {
  final nowUtc = DateTime.utc(
    localNow.year,
    localNow.month,
    localNow.day,
    localNow.hour,
    localNow.minute,
  ).subtract(Duration(hours: timezoneOffsetHours));
  return !nowUtc.isBefore(
        _sessionReminderDueUtc(session, timezoneOffsetHours),
      ) &&
      nowUtc.isBefore(_sessionStartUtc(session, timezoneOffsetHours));
}

Future<void> _sendSessionReminders(Scheduler scheduler, DateTime nowUtc) async {
  final repo = scheduler.repo;
  final config = scheduler.config;
  final recipients = repo.pendingSessionReminderRecipients(
    nowUtc: nowUtc,
    timezoneOffsetHours: config.timezoneOffsetHours,
  );
  for (final (snapshotUser, snapshotSession) in recipients) {
    final liveNowUtc = Config.nowUtc().toUtc();
    final liveNow = config.toLocal(liveNowUtc);
    if (repo.isHeld() || !repo.activeOutreachEnabled('session-reminder')) {
      if (repo.isHeld()) break;
      continue;
    }
    final current = repo.sessionReminderRecipient(
      snapshotUser.id,
      snapshotSession.id,
      nowUtc: liveNowUtc,
      timezoneOffsetHours: config.timezoneOffsetHours,
    );
    if (current == null ||
        !sessionReminderIsDue(
          current.$2,
          liveNow,
          timezoneOffsetHours: config.timezoneOffsetHours,
        )) {
      continue;
    }
    final (user, session) = current;
    if (!repo.claimSessionReminder(
      user.id,
      session.id,
      nowUtc: liveNowUtc,
      timezoneOffsetHours: config.timezoneOffsetHours,
    )) {
      continue;
    }
    // Revalidate clock, allocation, preference, hold, and category after the
    // durable claim and immediately before Telegram can accept the request.
    final preSendUtc = Config.nowUtc().toUtc();
    final latest = repo.sessionReminderRecipient(
      user.id,
      session.id,
      nowUtc: preSendUtc,
      timezoneOffsetHours: config.timezoneOffsetHours,
    );
    final preSendLocal = config.toLocal(preSendUtc);
    if (repo.isHeld() ||
        !repo.activeOutreachEnabled('session-reminder') ||
        latest == null ||
        !sessionReminderIsDue(
          latest.$2,
          preSendLocal,
          timezoneOffsetHours: config.timezoneOffsetHours,
        )) {
      repo.retrySessionReminder(user.id, session.id, preSendUtc);
      if (repo.isHeld()) break;
      continue;
    }
    final (liveUser, liveSession) = latest;
    final text =
        'Reminder: you have session at '
        '${repo.locationName(liveSession.location)}, from '
        '${_time(liveSession.start)} to ${_time(liveSession.end)}.';
    try {
      await scheduler.service.bot.api.sendMessage(ChatID(liveUser.id), text);
      repo.markSessionReminderDelivered(
        liveUser.id,
        liveSession.id,
        Config.nowUtc(),
      );
      LogRing.log(
        'session-reminder delivered user=${liveUser.id} '
        'session=${liveSession.id}',
      );
    } catch (error) {
      if (error is HeldException) {
        repo.retrySessionReminder(liveUser.id, liveSession.id, liveNowUtc);
        LogRing.log(
          'session-reminder suppressed by hold user=${liveUser.id} '
          'session=${liveSession.id}',
        );
      } else if (_definitelyRejected(error)) {
        repo.retrySessionReminder(liveUser.id, liveSession.id, liveNowUtc);
        LogRing.log(
          'session-reminder rejected; retry scheduled user=${liveUser.id} '
          'session=${liveSession.id}: $error',
        );
      } else {
        repo.markSessionReminderUncertain(liveUser.id, liveSession.id);
        LogRing.log(
          'session-reminder outcome uncertain user=${liveUser.id} '
          'session=${liveSession.id}: $error',
        );
      }
    }
  }
}

bool _definitelyRejected(Object error) {
  if (error is TelegramException) return error.code >= 400 && error.code < 500;
  if (error is! TeleverseException ||
      error.type != TeleverseExceptionType.requestFailed) {
    return false;
  }
  final details = '${error.message}\n${error.description ?? ''}';
  final status = int.tryParse(
    RegExp(r'HTTP (\d{3}): Request failed').firstMatch(details)?.group(1) ?? '',
  );
  return status != null && status >= 400 && status < 500;
}

String _time(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';
