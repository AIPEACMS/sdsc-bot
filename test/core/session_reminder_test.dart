import 'package:sdsc_bot/bot/scheduler.dart';
import 'package:sdsc_bot/core/models.dart';
import 'package:sdsc_bot/core/repo.dart';
import 'package:test/test.dart';

import '../support/repo_harness.dart';

void main() {
  setUp(setUpRepo);
  tearDown(tearDownRepo);

  test('deadline is exactly 18:00 local on the preceding day', () {
    final session = Session(
      id: 1,
      weekendStart: DateTime(2027, 2, 6),
      day: 'sat',
      slot: 's1',
      location: 'ocbc',
      start: DateTime(2027, 2, 6, 9),
      end: DateTime(2027, 2, 6, 12),
    );
    expect(sessionReminderDueAt(session), DateTime.utc(2027, 2, 5, 18));
    expect(
      sessionReminderIsDue(session, DateTime(2027, 2, 5, 17, 59)),
      isFalse,
    );
    expect(sessionReminderIsDue(session, DateTime(2027, 2, 5, 18)), isTrue);
    expect(sessionReminderIsDue(session, DateTime(2027, 2, 6, 9)), isFalse);
  });

  test('deadline stays UTC+8 when the configured schedule zone differs', () {
    final session = Session(
      id: 2,
      weekendStart: DateTime(2027, 2, 6),
      day: 'sat',
      slot: 's1',
      location: 'ocbc',
      start: DateTime(2027, 2, 6, 1),
      end: DateTime(2027, 2, 6, 4),
    );
    expect(
      sessionReminderDueAt(session, timezoneOffsetHours: 10),
      DateTime.utc(2027, 2, 4, 20),
    );
    expect(
      sessionReminderIsDue(
        session,
        DateTime.utc(2027, 2, 4, 20),
        timezoneOffsetHours: 10,
      ),
      isTrue,
    );
  });

  test(
    'recipients are recalculated, include out-members, and dedup per session',
    () {
      final weekend = DateTime(2027, 2, 6);
      repo.upsertUser(
        User(
          id: 10,
          name: '@out',
          experience: Experience.newbie,
          group: '',
          memberTier: MemberTier.outMember,
          notificationPreference: NotificationPreference.never,
        ),
      );
      repo.ensureSessionsForWeekend(
        weekend,
        repo.scheduleForWeekend(weekend),
        tzOffsetHours: 8,
      );
      final session = repo.sessionsForWeekend(weekend).first;
      repo.raw.execute(
        'UPDATE sessions SET start_at = ?, end_at = ? WHERE id = ?',
        ['2027-02-06 09:00:00', '2027-02-06 12:00:00', session.id],
      );
      repo.replaceAllocationsForWeekend(weekend, [(10, session.id)]);

      final nowUtc = DateTime.utc(2026, 11, 1);
      final targets = repo.pendingSessionReminderRecipients(
        nowUtc: nowUtc,
        timezoneOffsetHours: 8,
      );
      expect(targets.map((entry) => entry.$1.id), [10]);
      expect(targets.single.$1.memberTier, MemberTier.outMember);
      expect(
        repo.claimSessionReminder(
          10,
          session.id,
          nowUtc: DateTime.utc(2027, 2, 5, 10),
          timezoneOffsetHours: 8,
        ),
        isTrue,
      );
      expect(
        repo.claimSessionReminder(
          10,
          session.id,
          nowUtc: DateTime.utc(2027, 2, 5, 10),
          timezoneOffsetHours: 8,
        ),
        isFalse,
      );
      expect(repo.sessionReminderAttempted(10, session.id), isTrue);
      repo.upsertUser(
        repo.findUser(10)!.copyWith(sessionRemindersEnabled: false),
      );
      expect(repo.findUser(10)!.sessionRemindersEnabled, isFalse);
      repo.setSessionRemindersEnabled(10, true);
      final attemptAt = DateTime.utc(2027, 2, 5, 10);
      repo.retrySessionReminder(10, session.id, attemptAt);
      expect(
        repo.claimSessionReminder(
          10,
          session.id,
          nowUtc: attemptAt.add(const Duration(seconds: 30)),
          timezoneOffsetHours: 8,
        ),
        isFalse,
      );
      final retryAt = attemptAt.add(const Duration(minutes: 1));
      expect(
        repo.claimSessionReminder(
          10,
          session.id,
          nowUtc: retryAt,
          timezoneOffsetHours: 8,
        ),
        isTrue,
      );
      repo.markSessionReminderDelivered(10, session.id, retryAt);
      expect(
        repo.claimSessionReminder(
          10,
          session.id,
          nowUtc: retryAt.add(const Duration(minutes: 1)),
          timezoneOffsetHours: 8,
        ),
        isFalse,
      );

      repo.setSessionRemindersEnabled(10, false);
      expect(
        repo.pendingSessionReminderRecipients(
          nowUtc: nowUtc,
          timezoneOffsetHours: 8,
        ),
        isEmpty,
      );
      repo.setSessionRemindersEnabled(10, true);
      repo.replaceAllocationsForWeekend(weekend, []);
      expect(
        repo.pendingSessionReminderRecipients(
          nowUtc: nowUtc,
          timezoneOffsetHours: 8,
        ),
        isEmpty,
      );
    },
  );
}
