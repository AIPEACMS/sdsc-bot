import 'package:sdsc_bot/bot/scheduler.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:test/test.dart';

import '../support/grid_harness.dart';

void main() {
  setUp(setUpGrid);

  test(
    'scheduler catches due reminders once and respects held/category gates',
    () async {
      addTearDown(() => Config.setDebugNow(null));
      final allocation = repo
          .allocationsForWeekend(
            RollingWindow.forDate(config.toLocal(Config.nowUtc())).sat0,
          )
          .first;
      final session = allocation.$2;
      final today = DateTime(2027, 2, 5);
      final start = today.add(const Duration(days: 1));
      repo.raw.execute(
        'UPDATE sessions SET start_at = ?, end_at = ? WHERE id = ?',
        ['${_date(start)} 09:00:00', '${_date(start)} 12:00:00', session.id],
      );
      repo.setHeld(true);
      Config.setDebugNow(DateTime.utc(2027, 2, 5, 9, 0)); // 17:00 local

      Future<void> tick() async {
        final scheduler = Scheduler(
          repo: repo,
          config: config,
          service: service,
        );
        scheduler.start(interval: const Duration(days: 1));
        await scheduler.stopAndWait();
      }

      await tick();
      expect(_sessionReminders(), isEmpty);
      repo.setHeld(false);
      repo.setActiveOutreach('session-reminder', false);
      Config.setDebugNow(DateTime.utc(2027, 2, 5, 10, 0)); // 18:00 local
      await tick();
      expect(_sessionReminders(), isEmpty);

      repo.setActiveOutreach('session-reminder', true);
      await tick();
      final sentReminder = _sessionReminders();
      expect(sentReminder, hasLength(1));
      expect(
        sentReminder.single['text'],
        startsWith('Reminder: you have session at '),
      );
      expect(sentReminder.single['text'], endsWith('from 09:00 to 12:00.'));

      Config.setDebugNow(DateTime.utc(2027, 2, 5, 11, 0));
      await tick();
      expect(_sessionReminders(), hasLength(1));
    },
  );

  test(
    'definite Telegram rejection is retryable; accepted delivery is not',
    () async {
      addTearDown(() => Config.setDebugNow(null));
      final session = _prepareSession([_recipient(10, 'A first')]);
      Config.setDebugNow(DateTime.utc(2027, 2, 5, 10));
      failNextSendMessage = true;
      nextSendFailureStatus = 400;
      await _tick();
      expect(_sessionReminders(), hasLength(1));
      final retryAt = repo.nextSessionReminderRetryAt(Config.nowUtc());
      expect(retryAt, isNotNull);

      Config.setDebugNow(retryAt);
      await _tick();
      expect(_sessionReminders(), hasLength(2));
      expect(repo.sessionReminderAttempted(10, session.id), isTrue);
      expect(
        repo.raw.select(
          'SELECT delivery_state FROM session_reminder_deliveries '
          'WHERE user_id = ? AND session_id = ?',
          [10, session.id],
        ).single['delivery_state'],
        'delivered',
      );
    },
  );

  test('ambiguous Telegram outcome is not retried', () async {
    addTearDown(() => Config.setDebugNow(null));
    final session = _prepareSession([_recipient(10, 'A first')]);
    Config.setDebugNow(DateTime.utc(2027, 2, 5, 10));
    failNextSendMessage = true;
    nextSendFailureStatus = 500;
    await _tick();
    expect(_sessionReminders(), hasLength(1));
    Config.setDebugNow(DateTime.utc(2027, 2, 5, 12));
    await _tick();
    expect(_sessionReminders(), hasLength(1));
    expect(
      repo.raw.select(
        'SELECT delivery_state FROM session_reminder_deliveries '
        'WHERE user_id = ? AND session_id = ?',
        [10, session.id],
      ).single['delivery_state'],
      'uncertain',
    );
  });

  test(
    'hold, opt-out, and allocation removal during delivery stop later sends',
    () async {
      addTearDown(() => Config.setDebugNow(null));
      final session = _prepareSession([
        _recipient(10, 'A first'),
        _recipient(11, 'B opted out'),
        _recipient(12, 'C removed'),
      ]);
      Config.setDebugNow(DateTime.utc(2027, 2, 5, 10));
      beforeSendMessageResponse = (body) async {
        if ((body['text'] as String).startsWith('Reminder:')) {
          repo.setSessionRemindersEnabled(11, false);
          repo.removeAllocationForUser(12, session.weekendStart);
        }
      };
      await _tick();
      expect(_sessionReminders(), hasLength(1));
      expect(repo.sessionReminderAttempted(11, session.id), isFalse);
      expect(repo.sessionReminderAttempted(12, session.id), isFalse);

      beforeSendMessageResponse = (body) async {
        if ((body['text'] as String).startsWith('Reminder:')) {
          repo.setHeld(true);
        }
      };
      repo.setSessionRemindersEnabled(11, true);
      repo.replaceAllocationsForWeekend(session.weekendStart, [
        (11, session.id),
        (12, session.id),
      ]);
      await _tick();
      expect(_sessionReminders(), hasLength(2));
      expect(repo.sessionReminderAttempted(12, session.id), isFalse);
      repo.setHeld(false);
    },
  );

  test('a slow batch rechecks the clock before each recipient', () async {
    addTearDown(() => Config.setDebugNow(null));
    final session = _prepareSession([
      _recipient(10, 'A first'),
      _recipient(11, 'B starts at deadline'),
    ]);
    Config.setDebugNow(DateTime.utc(2027, 2, 5, 10));
    beforeSendMessageResponse = (body) async {
      if ((body['text'] as String).startsWith('Reminder:')) {
        Config.setDebugNow(DateTime.utc(2027, 2, 6, 1));
      }
    };
    await _tick();
    expect(_sessionReminders(), hasLength(1));
    expect(repo.sessionReminderAttempted(11, session.id), isFalse);
  });

  test(
    're-enabled preference and late allocation wake overdue delivery',
    () async {
      addTearDown(() => Config.setDebugNow(null));
      final session = _prepareSession([
        _recipient(10, 'A disabled', sessionRemindersEnabled: false),
      ]);
      Config.setDebugNow(DateTime.utc(2027, 2, 5, 10));
      final scheduler = Scheduler(repo: repo, config: config, service: service);
      addTearDown(scheduler.stopAndWait);
      scheduler.start(interval: const Duration(days: 1));
      await scheduler.waitForCurrentTicks();
      expect(_sessionReminders(), isEmpty);

      repo.setSessionRemindersEnabled(10, true);
      await scheduler.waitForCurrentTicks();
      expect(_sessionReminders(), hasLength(1));

      repo.upsertUser(_recipient(11, 'B late allocation'));
      repo.replaceAllocationsForWeekend(session.weekendStart, [
        (10, session.id),
        (11, session.id),
      ]);
      await scheduler.waitForCurrentTicks();
      expect(_sessionReminders(), hasLength(2));
    },
  );

  test(
    'global category re-enable wakes overdue catch-up immediately',
    () async {
      addTearDown(() => Config.setDebugNow(null));
      _prepareSession([_recipient(10, 'A first')]);
      Config.setDebugNow(DateTime.utc(2027, 2, 5, 10));
      repo.setActiveOutreach('session-reminder', false);
      final scheduler = Scheduler(repo: repo, config: config, service: service);
      addTearDown(scheduler.stopAndWait);
      scheduler.start(interval: const Duration(days: 1));
      await scheduler.waitForCurrentTicks();
      expect(_sessionReminders(), isEmpty);

      repo.setActiveOutreach('session-reminder', true);
      await scheduler.waitForCurrentTicks();
      expect(_sessionReminders(), hasLength(1));
    },
  );

  test(
    'disabling the category during a batch blocks the next recipient',
    () async {
      addTearDown(() => Config.setDebugNow(null));
      final session = _prepareSession([
        _recipient(10, 'A first'),
        _recipient(11, 'B second'),
      ]);
      Config.setDebugNow(DateTime.utc(2027, 2, 5, 10));
      beforeSendMessageResponse = (body) async {
        if ((body['text'] as String).startsWith('Reminder:')) {
          repo.setActiveOutreach('session-reminder', false);
        }
      };
      await _tick();
      expect(_sessionReminders(), hasLength(1));
      expect(repo.sessionReminderAttempted(11, session.id), isFalse);
    },
  );
}

Future<void> _tick() async {
  final scheduler = Scheduler(repo: repo, config: config, service: service);
  scheduler.start(interval: const Duration(days: 1));
  await scheduler.stopAndWait();
}

Session _prepareSession(List<User> users) {
  final weekend = RollingWindow.forDate(config.toLocal(Config.nowUtc())).sat0;
  final session = repo.sessionsForWeekend(weekend).first;
  final start = DateTime(2027, 2, 6);
  repo.raw.execute(
    'UPDATE sessions SET start_at = ?, end_at = ? WHERE id = ?',
    ['${_date(start)} 09:00:00', '${_date(start)} 12:00:00', session.id],
  );
  for (final user in users) {
    repo.upsertUser(user);
  }
  repo.replaceAllocationsForWeekend(weekend, [
    for (final user in users) (user.id, session.id),
  ]);
  return session;
}

User _recipient(int id, String name, {bool sessionRemindersEnabled = true}) =>
    User(
      id: id,
      name: name,
      experience: Experience.newbie,
      group: '',
      sessionRemindersEnabled: sessionRemindersEnabled,
    );

List<Map<String, dynamic>> _sessionReminders() => sent
    .where((message) => (message['text'] as String).startsWith('Reminder:'))
    .toList();

String _date(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
