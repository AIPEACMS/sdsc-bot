
import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';

void main() {

  group('schedule parsing', () {
    test('accepts day/time spellings and location tokens', () {
      final cases = <String, (String, String, String, String)>{
        'sat 9:00 13:00 PR': ('sat', '09:00', '13:00', 'PR'),
        'Saturday 9 13 pasir ris': ('sat', '09:00', '13:00', 'pasir ris'),
        'SATURDAY 9am 3pm OCBC Arena': (
          'sat',
          '09:00',
          '15:00',
          'OCBC Arena',
        ),
        'sun 09:30 12:00 ocbc': ('sun', '09:30', '12:00', 'ocbc'),
        'Fri 13:00 17:30 pasir': ('fri', '13:00', '17:30', 'pasir'),
      };
      cases.forEach((line, expected) {
        final parsed = parseSessionLine(line);
        expect(parsed, isA<ParsedSession>(), reason: line);
        final s = parsed as ParsedSession;
        expect((s.day, s.start, s.end, s.locationToken), expected, reason: line);
      });
    });

    test('rejects bad lines with a reason', () {
      expect(parseSessionLine('sat 9:00 13:00'), isA<String>());
      expect(parseSessionLine('funday 9:00 13:00 PR'), isA<String>());
      expect(parseSessionLine('sat 9x 13:00 PR'), isA<String>());
      expect(parseSessionLine('sat 25:00 13:00 PR'), isA<String>());
      // end must be after start
      expect(parseSessionLine('sat 13:00 9:00 PR'), isA<String>());
      expect(parseSessionLine('sat 9:00 9:00 PR'), isA<String>());
    });

    test('parseSchedule splits lines, keeping the good ones', () {
      final r = parseSchedule('sat 9:00 13:00 PR\n\nbogus line\nsun 10 12 OCBC');
      expect(r.sessions.length, 2);
      expect(r.errors.length, 1);
      expect(r.sessions[0].locationToken, 'PR');
      expect(r.sessions[1].day, 'sun');
    });

    test('prettyClock drops the leading zero', () {
      expect(prettyClock('09:00'), '9:00');
      expect(prettyClock('13:30'), '13:30');
    });

    test('temporary lines resolve explicit dates and next weekdays', () {
      final now = DateTime(2026, 9, 16); // Wednesday
      final explicit = parseTargetSessionLine(
        'mon as 2026-09-21 9:00 13:00 PR',
        now,
      ) as ParsedSession;
      expect(explicit.targetDate, DateTime(2026, 9, 21));
      expect(explicit.day, 'mon');
      final nextThursday =
          parseTargetSessionLine('thu 9:00 13:00 PR', now) as ParsedSession;
      expect(nextThursday.targetDate, DateTime(2026, 9, 17));
      final nextMonday =
          parseTargetSessionLine('mon 9:00 13:00 PR', now) as ParsedSession;
      expect(nextMonday.targetDate, DateTime(2026, 9, 21));
    });

    test('temporary explicit date must match its weekday', () {
      expect(
        parseTargetSessionLine(
          'mon as 2026-09-20 9:00 13:00 PR',
          DateTime(2026, 9, 16),
        ),
        isA<String>(),
      );
    });

    test('trailing numeric max is separated from a multiword location', () {
      final parsed = parseSessionLine(
        'sat 09:00 15:00 Pasir Ris 5',
        resolveLocation: (token) => token == 'Pasir Ris' ? 'pasirRis' : null,
      ) as ParsedSession;
      expect(parsed.locationToken, 'Pasir Ris');
      expect(parsed.maxPeople, 5);
    });
  });
}
