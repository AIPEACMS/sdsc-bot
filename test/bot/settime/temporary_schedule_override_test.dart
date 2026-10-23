import 'dart:io';

import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Database db;
  late Repo repo;
  final sat = DateTime(2026, 8, 15);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sdsc_temp_override_');
    db = Database.open(
      Config(
        botToken: 'test',
        dbPath: '${tmp.path}/test.db',
        consoleId: 1,
        groupAContact: 'TBD',
        groupBContact: 'TBD',
        ocbcCapacity: 2,
        prCapacity: 20,
        slotTimes: const {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
        promptHour: 18,
        reminderHour: 18,
        deadlineHour: 18,
        allocationHour: 9,
        bailHour: 12,
        timezoneOffsetHours: 8,
      ),
    );
    repo = Repo(db);
    for (final id in [1, 2]) {
      repo.upsertUser(
        User(
          id: id,
          name: '@member$id',
          experience: Experience.newbie,
          group: '1',
        ),
      );
      repo.setAvailability(
        Availability(
          weekendStart: sat,
          userId: id,
          bundleStart: sat,
          slots: {Slot(0, 'sat', 's$id', id == 1 ? 'ocbc' : 'pasirRis')},
          available: true,
          updatedAt: DateTime(2026, 8, 10),
        ),
      );
    }
  });

  tearDown(() {
    db.close();
    tmp.deleteSync(recursive: true);
  });

  test('temporary removal and addition preserve surviving session rows', () {
    const first = ScheduleSlot(
      day: 'sat',
      slot: 's1',
      start: '09:00',
      end: '12:00',
      location: 'ocbc',
    );
    const second = ScheduleSlot(
      day: 'sat',
      slot: 's2',
      start: '13:00',
      end: '17:00',
      location: 'pasirRis',
    );
    repo.replaceScheduleOverride(sat, const [first, second], tzOffsetHours: 8);
    final initial = repo.sessionsForWeekend(sat);
    final firstSession = initial.singleWhere((session) => session.slot == 's1');
    final secondSession = initial.singleWhere(
      (session) => session.slot == 's2',
    );
    repo.replaceAllocationsForWeekend(sat, [
      (1, firstSession.id),
      (2, secondSession.id),
    ]);
    repo.setAttendanceState(2, secondSession.id, attended: true);

    repo.replaceScheduleOverride(sat, const [first], tzOffsetHours: 8);

    final afterRemoval = repo.sessionsForWeekend(sat);
    expect(afterRemoval, hasLength(1));
    expect(afterRemoval.single.id, firstSession.id);
    expect(
      repo
          .allocationsForWeekend(sat)
          .map((entry) => (entry.$1.id, entry.$2.id))
          .toList(),
      [(1, firstSession.id)],
    );
    expect(repo.attendanceForSession(secondSession.id), isEmpty);
    expect(
      repo
          .availabilityForWeekend(sat)
          .map((availability) => availability.userId)
          .toSet(),
      {1, 2},
    );
    expect(repo.sessionById(secondSession.id), isNull);

    const added = ScheduleSlot(
      day: 'sat',
      slot: 's3',
      start: '18:00',
      end: '20:00',
      location: 'ocbc',
    );
    repo.replaceScheduleOverride(sat, const [first, added], tzOffsetHours: 8);

    final afterAddition = repo.sessionsForWeekend(sat);
    expect(afterAddition, hasLength(2));
    expect(
      afterAddition.singleWhere((session) => session.slot == 's1').id,
      firstSession.id,
    );
    expect(afterAddition.any((session) => session.slot == 's3'), isTrue);
    expect(
      repo
          .allocationsForWeekend(sat)
          .map((entry) => (entry.$1.id, entry.$2.id))
          .toList(),
      [(1, firstSession.id)],
    );
    expect(
      repo
          .availabilityForWeekend(sat)
          .map((availability) => availability.userId)
          .toSet(),
      {1, 2},
    );
  });
}
