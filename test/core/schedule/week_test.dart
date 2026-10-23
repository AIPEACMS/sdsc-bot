import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';

void main() {
  group('WeekMath ISO weeks', () {
    test('2026-01-01 (Thu) is ISO week 1 of 2026', () {
      expect(WeekMath.isoWeek(DateTime(2026, 1, 1)), 1);
      expect(WeekMath.isoYear(DateTime(2026, 1, 1)), 2026);
    });

    test('2026-01-05 (Mon) is week 2', () {
      expect(WeekMath.isoWeek(DateTime(2026, 1, 5)), 2);
    });

    test('week 1 of 2026 starts on 2025-12-29', () {
      expect(WeekMath.mondayOfWeek(1, 2026), DateTime(2025, 12, 29));
    });

    test('2026 has 53 ISO weeks (Jan 1 is Thursday)', () {
      expect(WeekMath.isoWeeksInYear(DateTime(2026, 6, 1)), 53);
    });

    test('31 Dec 2026 is week 53', () {
      expect(WeekMath.isoWeek(DateTime(2026, 12, 31)), 53);
    });

    test('2025-12-29 belongs to ISO year 2026', () {
      expect(WeekMath.isoYear(DateTime(2025, 12, 29)), 2026);
    });

    test('mondayOf is correct for midweek', () {
      expect(WeekMath.mondayOf(DateTime(2026, 8, 8)), DateTime(2026, 8, 3));
      expect(WeekMath.mondayOf(DateTime(2026, 8, 3)), DateTime(2026, 8, 3));
    });

    test('odd/even parity of current week', () {
      // 2026-08-03 is a Monday; its week parity is whatever isoWeek says.
      final w = WeekMath.isoWeek(DateTime(2026, 8, 3));
      expect(WeekMath.isOddWeek(DateTime(2026, 8, 3)), w.isOdd);
    });
  });

  group('WeekMath cycle timeline', () {
    test('sessions for block week 33 land on the right weekends', () {
      // Assume 2026 week 33 is odd. First session weekend = sat of week 33.
      final sat = WeekMath.saturdayOfWeek(33, 2026);
      expect(sat.weekday, DateTime.saturday);
      expect(WeekMath.isoWeek(sat), 33);
      final sun = sat.add(const Duration(days: 1));
      expect(WeekMath.isoWeek(sun), 33);
      final sat2 = WeekMath.saturdayOfWeek(34, 2026);
      expect(WeekMath.isoWeek(sat2), 34);
    });

    test('rolling window uses all configured schedule milestones', () {
      const schedule = ScheduleTimes(
        prompt: ScheduleEvent(
          weekday: 'mon',
          time: LocalWallClock(17, 15),
        ),
        reminder: ScheduleEvent(
          weekday: 'thu',
          time: LocalWallClock(18, 30),
        ),
        lock: ScheduleEvent(
          weekday: 'fri',
          time: LocalWallClock(19, 45),
        ),
        checker: ScheduleEvent(
          weekday: 'fri',
          time: LocalWallClock(22, 0),
        ),
      );
      final window = RollingWindow.forDate(
        DateTime(2026, 8, 12),
        schedule: schedule,
      );
      expect(window.promptDay, DateTime(2026, 8, 10, 17, 15));
      expect(window.reminderDay, DateTime(2026, 8, 13, 18, 30));
      expect(window.deadline0, DateTime(2026, 8, 14, 19, 45));
      expect(window.deadline1, DateTime(2026, 8, 21, 19, 45));
    });

    test('rolling window uses configured weekdays and weekly lock spacing', () {
      const schedule = ScheduleTimes(
        prompt: ScheduleEvent(
          weekday: 'tue',
          time: LocalWallClock(9, 0),
        ),
        reminder: ScheduleEvent(
          weekday: 'wed',
          time: LocalWallClock(10, 0),
        ),
        lock: ScheduleEvent(
          weekday: 'fri',
          time: LocalWallClock(18, 0),
        ),
        checker: ScheduleEvent(
          weekday: 'fri',
          time: LocalWallClock(20, 0),
        ),
      );
      final window = RollingWindow.forDate(
        DateTime(2026, 8, 12),
        schedule: schedule,
      );
      expect(window.promptDay, DateTime(2026, 8, 11, 9));
      expect(window.reminderDay, DateTime(2026, 8, 12, 10));
      expect(window.lock0, DateTime(2026, 8, 14, 18));
      expect(window.lock1, DateTime(2026, 8, 21, 18));
      expect(window.checkerDay, DateTime(2026, 8, 14, 20));
      expect(window.lock1.difference(window.lock0), const Duration(days: 7));
    });

    test('schedule validation orders milestones by weekday then time', () {
      const valid = ScheduleTimes(
        prompt: ScheduleEvent(weekday: 'mon', time: LocalWallClock(20, 0)),
        reminder: ScheduleEvent(weekday: 'tue', time: LocalWallClock(8, 0)),
        lock: ScheduleEvent(weekday: 'fri', time: LocalWallClock(18, 0)),
        checker: ScheduleEvent(weekday: 'fri', time: LocalWallClock(18, 1)),
      );
      expect(valid.validate, returnsNormally);

      const weekend = ScheduleTimes(
        prompt: ScheduleEvent(weekday: 'sat', time: LocalWallClock(9, 0)),
        reminder: ScheduleEvent(weekday: 'tue', time: LocalWallClock(10, 0)),
        lock: ScheduleEvent(weekday: 'fri', time: LocalWallClock(18, 0)),
        checker: ScheduleEvent(weekday: 'fri', time: LocalWallClock(19, 0)),
      );
      expect(weekend.validate, throwsArgumentError);

      const outOfOrder = ScheduleTimes(
        prompt: ScheduleEvent(weekday: 'wed', time: LocalWallClock(9, 0)),
        reminder: ScheduleEvent(weekday: 'tue', time: LocalWallClock(10, 0)),
        lock: ScheduleEvent(weekday: 'fri', time: LocalWallClock(18, 0)),
        checker: ScheduleEvent(weekday: 'fri', time: LocalWallClock(19, 0)),
      );
      expect(outOfOrder.validate, throwsArgumentError);
    });
  });

  group('UTC+8 timezone anchoring', () {
    // The bot is anchored to Singapore time (UTC+8): a UTC instant at 23:30
    // is already the *next* local day, so the week/cycle math must use the
    // converted local time, never the raw UTC wall-clock.
    test('toLocal converts a UTC instant to the correct Singapore day', () {
      final config = Config(
        botToken: 'test',
        dbPath: ':memory:',
        consoleId: 1,
        groupAContact: 'TBD',
        groupBContact: 'TBD',
        ocbcCapacity: 6,
        prCapacity: 20,
        slotTimes: {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
        promptHour: 18,
        reminderHour: 18,
        deadlineHour: 18,
        allocationHour: 9,
        bailHour: 12,
        timezoneOffsetHours: 8,
      );
      // 2026-08-10 23:30 UTC == 2026-08-11 07:30 Singapore.
      final utc = DateTime.utc(2026, 8, 10, 23, 30);
      final local = config.toLocal(utc);
      expect(local.year, 2026);
      expect(local.month, 8);
      expect(local.day, 11);
      expect(local.hour, 7);
      expect(local.minute, 30);
    });

    test('debug clock override is honored by nowUtc', () {
      Config.setDebugNow(DateTime.utc(2026, 8, 10, 23, 30));
      expect(Config.nowUtc(), DateTime.utc(2026, 8, 10, 23, 30));
      Config.setDebugNow(null);
      // Back to real time: within a minute of a real UTC now.
      final diff = DateTime.now().toUtc().difference(Config.nowUtc()).abs();
      expect(diff.inMinutes, lessThan(2));
    });
  });

  group('Slot encode/decode', () {
    test('roundtrip', () {
      const s = Slot(0, 'sat', 'am', 'ocbc');
      expect(Slot.parse(s.encode()), s);
      expect(Slot.parse('0:sat:am:pasirRis')!.location, 'pasirRis');
      // Legacy 3-part keys are rejected by parse.
      expect(Slot.parse('2:sat:am'), isNull);
      expect(Slot.parse('0:sat:am'), isNull);
      expect(Slot.parse('0:xx:am:ocbc'), isNull);
      // Locations are dynamic in v3: any non-empty token is accepted.
      expect(Slot.parse('0:sat:am:xx')!.location, 'xx');
      expect(Slot.parse('garbage'), isNull);
    });

    test('decodeSet expands legacy 3-part keys to both locations', () {
      final set = Slot.decodeSet('["0:sat:am"]');
      expect(set, {
        const Slot(0, 'sat', 'am', 'ocbc'),
        const Slot(0, 'sat', 'am', 'pasirRis'),
      });
      // New 4-part keys decode as-is, and any weekday is allowed in v3.
      final set2 = Slot.decodeSet('["0:sat:am:ocbc","1:sun:pm:pasirRis"]');
      expect(set2, {
        const Slot(0, 'sat', 'am', 'ocbc'),
        const Slot(1, 'sun', 'pm', 'pasirRis'),
      });
    });
  });
}
