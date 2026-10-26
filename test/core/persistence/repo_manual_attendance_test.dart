import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:test/test.dart';
import '../../support/repo_harness.dart';
import '../../support/test_helpers.dart';

void main() {
  setUp(setUpRepo);
  tearDown(tearDownRepo);

  test('attendance balance follows only actual positive state transitions', () {
    final user = addUser(2);
    repo.ensureSessionsForWeekend(
      DateTime(2026, 8, 15),
      defaultTemplate(),
      tzOffsetHours: 8,
    );
    final session = repo.sessionsForWeekend(DateTime(2026, 8, 15)).first;

    repo.setAttendanceState(user.id, session.id, attended: true);
    repo.setAttendanceState(user.id, session.id, attended: true);
    expect(repo.findUser(user.id)!.attendanceBalance, 1);
    expect(repo.findUser(user.id)!.lastAttendedDate, DateTime(2026, 8, 15));
    repo.setAttendanceState(user.id, session.id, attended: false);
    expect(repo.findUser(user.id)!.attendanceBalance, 0);
    repo.setAttendanceState(user.id, session.id, attended: true);
    repo.raw.execute(
      'DELETE FROM attendance WHERE user_id = ? AND session_id = ?',
      [user.id, session.id],
    );
    expect(repo.findUser(user.id)!.attendanceBalance, 0);
    expect(repo.attendanceForSession(session.id), isEmpty);
  });

  test(
    'last-attended date follows remaining rows and manual-date precedence',
    () {
      repo.upsertUser(
        User(
          id: 1,
          name: 'Gadmin',
          experience: Experience.newbie,
          group: '1',
          isGlobalAdmin: true,
        ),
      );
      addUser(8, group: '1');
      final aug1 = DateTime(2026, 8, 1);
      final aug8 = DateTime(2026, 8, 8);
      final aug15 = DateTime(2026, 8, 15);
      for (final saturday in [aug1, aug8, aug15]) {
        repo.ensureSessionsForWeekend(
          saturday,
          defaultTemplate(),
          tzOffsetHours: 8,
        );
      }
      final first = repo.sessionsForWeekend(aug1).first;
      final second = repo.sessionsForWeekend(aug8).first;
      final third = repo.sessionsForWeekend(aug15).first;

      repo.setAttendanceState(8, first.id, attended: true);
      repo.setAttendanceState(8, second.id, attended: true);
      expect(repo.findUser(8)!.lastAttendedDate, DateTime(2026, 8, 8));
      repo.setAttendanceState(8, second.id, attended: false);
      expect(repo.findUser(8)!.lastAttendedDate, DateTime(2026, 8, 1));
      repo.setAttendanceState(8, second.id, attended: true);
      repo.clearAttendance(8, second.id);
      expect(repo.findUser(8)!.lastAttendedDate, DateTime(2026, 8, 1));
      repo.raw.execute(
        'DELETE FROM attendance WHERE user_id = ? AND session_id = ?',
        [8, first.id],
      );
      expect(repo.findUser(8)!.lastAttendedDate, isNull);

      expect(
        repo.applyManualAttendance(
          1,
          8,
          0,
          allMembers: true,
          lastAttendedDate: '2026-08-10',
        ),
        isTrue,
      );
      repo.setAttendanceState(8, second.id, attended: true);
      expect(repo.findUser(8)!.lastAttendedDate, DateTime(2026, 8, 10));
      repo.setAttendanceState(8, second.id, attended: false);
      expect(repo.findUser(8)!.lastAttendedDate, DateTime(2026, 8, 10));
      repo.setAttendanceState(8, third.id, attended: true);
      expect(repo.findUser(8)!.lastAttendedDate, DateTime(2026, 8, 15));
      repo.clearAttendance(8, third.id);
      expect(repo.findUser(8)!.lastAttendedDate, DateTime(2026, 8, 10));
    },
  );

  test(
    'manual corrections validate group/global scope and preserve sessions',
    () {
      repo.upsertUser(
        User(
          id: 1,
          name: 'Gadmin',
          experience: Experience.newbie,
          group: '1',
          isGlobalAdmin: true,
        ),
      );
      repo.upsertUser(
        User(
          id: 3,
          name: 'Admin',
          experience: Experience.newbie,
          group: '1',
          isAdmin: true,
        ),
      );
      addUser(2, group: '1');
      addUser(4, group: '2');
      repo.ensureSessionsForWeekend(
        DateTime(2026, 8, 15),
        defaultTemplate(),
        tzOffsetHours: 8,
      );
      final session = repo.sessionsForWeekend(DateTime(2026, 8, 15)).first;
      repo.setAttendanceState(2, session.id, attended: true);

      expect(repo.applyManualAttendance(3, 2, 0, allMembers: false), isTrue);
      expect(repo.applyManualAttendance(3, 4, 1, allMembers: false), isFalse);
      expect(repo.applyManualAttendance(3, 2, -1, allMembers: false), isFalse);
      expect(repo.applyManualAttendance(1, 4, -2, allMembers: true), isTrue);
      expect(repo.findUser(4)!.attendanceBalance, -2);
      repo.upsertUser(
        User(
          id: 4,
          name: 'Member 4 updated',
          experience: Experience.newbie,
          group: '2',
        ),
      );
      expect(repo.findUser(4)!.attendanceBalance, -2);
      expect(repo.attendanceForSession(session.id).single.attended, isTrue);
    },
  );

  test('sent message records its Telegram id for same-day reconciliation', () {
    addUser(4);
    final day = DateTime(2026, 8, 24);
    repo.markMessageSent(4, 'absent', day, telegramMessageId: 51);
    expect(repo.messageIdSentOnDay(4, 'absent', day), 51);
    expect(repo.messageSentOnDay(4, 'absent', day), isTrue);
  });
}
