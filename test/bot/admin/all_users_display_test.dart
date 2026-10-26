import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:test/test.dart';
import '../../support/grid_harness.dart';

void main() {
  setUp(setUpGrid);

  test(
    'rosters show persisted member balance and omit out-member group',
    () async {
      final adminGroup = repo.findUser(2)!.group;
      repo.upsertUser(
        User(
          id: 50,
          name: '@balanceadmin',
          experience: Experience.newbie,
          group: adminGroup,
          isAdmin: true,
          attendanceBalance: 9,
        ),
      );
      repo.upsertUser(
        User(
          id: 51,
          name: '@outempty',
          experience: Experience.newbie,
          group: '',
          memberTier: MemberTier.outMember,
          notificationPreference: NotificationPreference.never,
          attendanceBalance: 4,
        ),
      );

      final window = RollingWindow.forDate(config.toLocal(Config.nowUtc()));
      final sessions = repo.sessionsForWeekend(window.sat0);
      final ocbc = sessions.firstWhere(
        (session) => session.location == Locations.ocbc,
      );
      final pasirRis = sessions.firstWhere(
        (session) => session.location == Locations.pasirRis,
      );
      repo.setAttendanceState(50, ocbc.id, attended: true);
      repo.setAttendanceState(50, pasirRis.id, attended: true);
      repo.raw.execute('UPDATE users SET attendance_balance = ? WHERE id = ?', [
        9,
        50,
      ]);
      expect(repo.attendanceStats(50).total, 2);
      expect(repo.findUser(50)!.attendanceBalance, 9);

      await sendText(1, '/all_users');
      final allUsers = sent.last['text'] as String;
      final balanceLine =
          '• <b>@balanceadmin</b>\n'
          '   (admin, group $adminGroup, new, attended 9 sessions)';
      const outMemberLine =
          '• <b>@outempty</b>\n   (out-member, notifications never)';
      const checkerLine = '• <b>@checker</b>\n   (check, group none, new)';
      expect(allUsers, contains(balanceLine));
      expect(allUsers, contains(outMemberLine));
      expect(allUsers, contains(checkerLine));
      expect(allUsers, isNot(contains('2 OCBC')));
      expect(allUsers, isNot(contains('Pasir Ris')));
      expect(
        allUsers,
        isNot(contains('• <b>@outempty</b>\n   (out-member, group none')),
      );
      expect(
        allUsers,
        isNot(contains('• <b>@outempty</b>\n   (out-member, attended')),
      );

      await sendText(2, '/group_user');
      final groupUsers = sent.last['text'] as String;
      expect(groupUsers, contains(balanceLine));
      expect(groupUsers, isNot(contains('@outempty')));
      expect(groupUsers, isNot(contains('2 OCBC')));
      expect(groupUsers, isNot(contains('Pasir Ris')));
    },
  );
}
