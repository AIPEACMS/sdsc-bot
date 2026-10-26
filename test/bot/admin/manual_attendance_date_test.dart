import 'package:sdsc_bot/bot/admin/manual_attendance_date.dart';
import 'package:test/test.dart';

void main() {
  final today = DateTime(2026, 8, 24);

  test('accepts month-name orderings with the current year by default', () {
    expect(
      ManualAttendanceDate.parse('Aug 24', today: today),
      DateTime(2026, 8, 24),
    );
    expect(
      ManualAttendanceDate.parse('24 Aug', today: today),
      DateTime(2026, 8, 24),
    );
  });

  test('numeric dates prefer day-month and accept explicit D-M-Y', () {
    expect(
      ManualAttendanceDate.parse('12/08', today: today),
      DateTime(2026, 8, 12),
    );
    expect(
      ManualAttendanceDate.parse('12-08-2025', today: today),
      DateTime(2025, 8, 12),
    );
    expect(ManualAttendanceDate.canonical(DateTime(2025, 8, 12)), '2025-08-12');
  });

  test('displays dates with four-digit year and abbreviated month', () {
    expect(ManualAttendanceDate.display(DateTime(2026, 9, 26)), '2026-Sept-26');
    expect(ManualAttendanceDate.display(DateTime(2026, 1, 2)), '2026-Jan-02');
    expect(ManualAttendanceDate.display(null), 'never');
  });

  test('rejects invalid, ambiguous, and future dates', () {
    expect(ManualAttendanceDate.parse('31 Feb', today: today), isNull);
    expect(ManualAttendanceDate.parse('25 Aug', today: today), isNull);
    expect(ManualAttendanceDate.parse('08/12/26', today: today), isNull);
    expect(ManualAttendanceDate.parse('Aug 24 2027', today: today), isNull);
    expect(
      ManualAttendanceDate.parse('29 Feb 2024', today: today),
      DateTime(2024, 2, 29),
    );
    expect(ManualAttendanceDate.parse('29 Feb 2025', today: today), isNull);
  });
}
