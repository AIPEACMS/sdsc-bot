import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'support/repo_harness.dart';
import 'test_helpers.dart';

void main() {
  setUp(setUpRepo);
  tearDown(tearDownRepo);
  test('hold state persists across calls', () {
    expect(repo.isHeld(), false);
    repo.setHeld(true);
    expect(repo.isHeld(), true);
    repo.setHeld(false);
    expect(repo.isHeld(), false);
  });

  test('reminder targets exclude check and old users', () {
    addUser(1);
    addUser(2);
    repo.setTier(2, 'check');
    addUser(3);
    repo.setTier(3, 'old');
    addUser(4);
    repo.setTier(4, 'out-member');
    final sat = DateTime(2026, 8, 15);
    final pending = repo.reminderTargets(sat);
    expect(pending.map((u) => u.id), [1, 4]);
  });

  test('message log dedupes per user, kind and day', () {
    addUser(1);
    addUser(2);
    final day = DateTime(2026, 8, 10);
    expect(repo.messageSentOnDay(1, 'prompt', day), false);
    repo.markMessageSent(1, 'prompt', day);
    expect(repo.messageSentOnDay(1, 'prompt', day), true);
    expect(
      repo.messageSentAtOnDay(1, 'prompt', day),
      matches(RegExp(r'\+08:00$')),
    );
    // Different kind or different day is not deduped.
    expect(repo.messageSentOnDay(1, 'reminder', day), false);
    expect(
      repo.messageSentOnDay(1, 'prompt', day.add(const Duration(days: 1))),
      false,
    );
    // Different user is not deduped.
    expect(repo.messageSentOnDay(2, 'prompt', day), false);
  });

  test(
    'consecutiveAbsentWeeks counts non-holiday weeks since last attendance',
    () {
      // Four consecutive session weekends: Aug 1, 8, 15, 22 2026.
      final sats = [
        DateTime(2026, 8, 1),
        DateTime(2026, 8, 8),
        DateTime(2026, 8, 15),
        DateTime(2026, 8, 22),
      ];
      for (final sat in sats) {
        repo.ensureSessionsForWeekend(sat, defaultTemplate(), tzOffsetHours: 8);
      }
      final latestSat = DateTime(2026, 8, 22);

      void backdate(int id, String createdAt) {
        repo.raw.execute('UPDATE users SET created_at = ? WHERE id = ?', [
          createdAt,
          id,
        ]);
      }

      // Registered long before the first weekend, never attended.
      addUser(1);
      backdate(1, '2026-07-01 00:00:00');
      expect(repo.consecutiveAbsentWeeks(1, latestSat), 4);

      // Attended Aug 8 → the streak restarts after that weekend.
      addUser(2);
      backdate(2, '2026-07-01 00:00:00');
      final aug8 = repo.sessionsForWeekend(DateTime(2026, 8, 8)).first;
      repo.setAttendanceState(2, aug8.id, attended: true);
      expect(repo.consecutiveAbsentWeeks(2, latestSat), 2);

      // Registered mid-cycle (Aug 10): weeks before that do not count.
      addUser(3);
      backdate(3, '2026-08-10 00:00:00');
      expect(repo.consecutiveAbsentWeeks(3, latestSat), 2);

      // Holiday week (Aug 10-16) is skipped: neither counts nor resets.
      repo.addHoliday(DateTime(2026, 8, 10), HolidayKind.middle);
      expect(repo.consecutiveAbsentWeeks(1, latestSat), 3);
      expect(repo.consecutiveAbsentWeeks(2, latestSat), 1);
      expect(repo.consecutiveAbsentWeeks(3, latestSat), 1);

      // No sessions at all → 0.
      addUser(4);
      backdate(4, '2026-07-01 00:00:00');
      expect(repo.consecutiveAbsentWeeks(4, DateTime(2026, 6, 1)), 0);
    },
  );
}
