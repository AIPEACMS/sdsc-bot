import 'dart:io';

import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:sdsc_bot/bot/keyboards.dart';
import 'support/settime_harness.dart';

void main() {
  setUp(() => setUpRepoHarness('sdsc_tpl_'));
  tearDown(tearDownRepoHarness);
  group('template and sessions', () {
    late Directory tmp;
    late Database db;
    late Repo repo;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('sdsc_tpl_');
      db = Database.open(configForTest(tmp));
      repo = Repo(db);
    });

    tearDown(() {
      db.close();
      tmp.deleteSync(recursive: true);
    });

    test('seeds the default Saturday template from the slot config', () {
      final t = repo.scheduleTemplate();
      expect(t.length, 4);
      expect(t.every((r) => r.day == 'sat'), isTrue);
      expect(t.map((r) => r.slot).toSet(), {'am', 'pm'});
      expect(t.map((r) => r.location).toSet(), {'ocbc', 'pasirRis'});
    });

    test('sessions follow the template, including other weekdays', () {
      final sat = DateTime(2026, 8, 15);
      repo.replaceScheduleTemplate(const [
        ScheduleSlot(
          day: 'sat',
          slot: 's1',
          start: '09:00',
          end: '13:00',
          location: 'pasirRis',
        ),
        ScheduleSlot(
          day: 'sun',
          slot: 's2',
          start: '10:00',
          end: '12:00',
          location: 'ocbc',
        ),
        ScheduleSlot(
          day: 'fri',
          slot: 's3',
          start: '18:00',
          end: '20:00',
          location: 'ocbc',
        ),
      ]);
      repo.replaceSessionsForWeekend(
        sat,
        repo.scheduleTemplate(),
        tzOffsetHours: 8,
      );
      final sessions = repo.sessionsForWeekend(sat);
      expect(sessions.length, 3);
      final sun = sessions.firstWhere((s) => s.day == 'sun');
      expect(sun.start, DateTime(2026, 8, 16, 10, 0)); // sat + 1
      final fri = sessions.firstWhere((s) => s.day == 'fri');
      expect(fri.start, DateTime(2026, 8, 21, 18, 0)); // sat + 6
      expect(sun.location, 'ocbc');
    });

    test('changing the schedule clears an open weekend availability', () {
      final sat = DateTime(2026, 8, 15);
      repo.ensureSessionsForWeekend(
        sat,
        repo.scheduleTemplate(),
        tzOffsetHours: 8,
      );
      repo.upsertUser(
        const User(
          id: 1,
          name: '@a',
          experience: Experience.newbie,
          group: '1',
        ),
      );
      repo.setAvailability(
        Availability(
          weekendStart: sat,
          userId: 1,
          bundleStart: sat,
          slots: {const Slot(0, 'sat', 'am', 'ocbc')},
          available: true,
          updatedAt: DateTime(2026, 8, 10),
        ),
      );
      expect(repo.availabilityForWeekend(sat), isNotEmpty);

      repo.clearWeekendAvailabilityAndAllocations(sat);
      const newRows = [
        ScheduleSlot(
          day: 'sat',
          slot: 's1',
          start: '09:00',
          end: '13:00',
          location: 'pasirRis',
        ),
      ];
      repo.replaceScheduleTemplate(newRows);
      repo.replaceSessionsForWeekend(sat, newRows, tzOffsetHours: 8);

      expect(repo.availabilityForWeekend(sat), isEmpty);
      final sessions = repo.sessionsForWeekend(sat);
      expect(sessions.length, 1);
      expect(sessions.single.slot, 's1');
    });

    test('sessions outside the template are cleaned up on startup', () {
      // A leftover row from an older model (Sunday sessions existed once).
      repo.raw.execute(
        'INSERT INTO sessions '
        '(weekend_start, day, slot, location, start_at, end_at) '
        "VALUES ('2026-08-15','sun','am','ocbc',"
        "'2026-08-16 09:00:00','2026-08-16 12:00:00')",
      );
      expect(
        repo.raw
            .select("SELECT COUNT(*) AS n FROM sessions WHERE day = 'sun'")
            .first['n'],
        1,
      );
      // It is hidden immediately (template membership) and deleted on the next
      // open, so it can never resurface.
      expect(repo.sessionsForWeekend(DateTime(2026, 8, 15)), isEmpty);
      db.close();
      db = Database.open(configForTest(tmp));
      repo = Repo(db);
      expect(
        repo.raw
            .select("SELECT COUNT(*) AS n FROM sessions WHERE day = 'sun'")
            .first['n'],
        0,
      );
    });

    test('/settime is not in any role grid', () {
      for (final role in [
        'member',
        'check',
        'admin',
        'gadmin',
        'console',
        'console-gadmin',
        'old',
      ]) {
        final commands =
            RoleKeyboard.gridButtons(role).map((b) => b.command).toSet();
        expect(
          commands.contains('/settime'),
          role == 'gadmin' || role == 'console-gadmin',
          reason: role,
        );
        expect(commands.contains('/addalias'), isFalse, reason: role);
      }
    });
  });
}
