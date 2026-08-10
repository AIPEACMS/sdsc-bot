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
        promptHour: 8,
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
      const s = Slot(0, 'sat', 'am');
      expect(Slot.parse(s.encode()), s);
      expect(Slot.parse('2:sat:am'), isNull);
      expect(Slot.parse('0:xx:am'), isNull);
      expect(Slot.parse('garbage'), isNull);
    });
  });
}
