import 'dart:io';

import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';

import 'package:sdsc_bot/bot/calendar_sync.dart';

const sampleYaml = '''
academic_year: 2026-27
semester_1:
  weeks:
    - week: 1
      type: teaching
      start: 2026-08-10
      end: 2026-08-16
    - week: 7
      type: teaching
      start: 2026-09-21
      end: 2026-09-27
    - week: 8
      type: recess
      start: 2026-09-28
      end: 2026-10-04
    - week: 9
      type: teaching
      start: 2026-10-05
      end: 2026-10-11
semester_2:
  weeks:
    - week: 1
      type: teaching
      start: 2027-01-04
      end: 2027-01-10
    - week: 14
      type: exam
      start: 2027-04-05
      end: 2027-04-11
''';

void main() {
  late Directory tmp;
  late Database db;
  late Repo repo;
  late CalendarSync sync;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sdsc_cal_');
    db = Database.open(Config(
      botToken: 'test',
      dbPath: '${tmp.path}/test.db',
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
    ));
    repo = Repo(db);
    sync = CalendarSync(repo: repo, config: Config(
      botToken: 'test',
      dbPath: '${tmp.path}/test.db',
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
    ));
  });

  tearDown(() {
    db.close();
    tmp.deleteSync(recursive: true);
  });

  test('parses calendar YAML into typed weeks', () {
    final year = CalendarYear.fromYaml(sampleYaml);
    expect(year.academicYear, '2026-27');
    expect(year.semester('semester_1')!.weeks.length, 4);
    expect(year.semester('semester_1')!.weeks[2].type, 'recess');
    expect(year.semester('semester_1')!.weeks[2].start,
        DateTime(2026, 9, 28));
  });

  test('rejects malformed YAML', () {
    expect(() => CalendarYear.fromYaml('garbage: [not'), throwsFormatException);
    expect(() => CalendarYear.fromYaml('foo: bar'),
        throwsFormatException); // missing academic_year
  });

  test('sync derives holidays: recess=middle, winter gap, summer tail',
      () {
    final result = sync.apply(sampleYaml);
    expect(result.academicYear, '2026-27');
    expect(result.holidays, greaterThan(0));

    // Recess week 8 (2026-09-28) → middle holiday.
    final recess = repo.holidayOn(DateTime(2026, 9, 29));
    expect(recess, isNotNull);
    expect(recess!.kind, HolidayKind.middle);

    // Winter: a week in the S1→S2 gap (e.g. 2026-12-07) → winter.
    final winter = repo.holidayOn(DateTime(2026, 12, 7));
    expect(winter, isNotNull);
    expect(winter!.kind, HolidayKind.winter);

    // Summer: a week after S2 end (e.g. 2027-06-07) → summer.
    final summer = repo.holidayOn(DateTime(2027, 6, 7));
    expect(summer, isNotNull);
    expect(summer!.kind, HolidayKind.summer);

    // Teaching weeks are NOT holidays.
    expect(repo.holidayOn(DateTime(2026, 8, 11)), isNull);
    expect(repo.holidayOn(DateTime(2027, 1, 5)), isNull);
  });

  test('sync is idempotent (no duplicate holiday rows)', () {
    sync.apply(sampleYaml);
    sync.apply(sampleYaml);
    final all = repo.allHolidays();
    final starts = all.map((h) => h.weekStart).toSet();
    expect(starts.length, all.length);
  });

  test('saveCalendarYaml round-trips', () {
    sync.apply(sampleYaml);
    final rows = repo.raw.select(
      "SELECT academic_year FROM calendar_years WHERE academic_year = '2026-27'");
    expect(rows.length, 1);
  });

  test('weekOf maps a date to its semester and calendar week', () {
    final year = CalendarYear.fromYaml(sampleYaml);
    expect(year.weekOf(DateTime(2026, 8, 12)), ('semester_1', 1));
    expect(year.weekOf(DateTime(2026, 9, 25)), ('semester_1', 7));
    expect(year.weekOf(DateTime(2027, 1, 6)), ('semester_2', 1));
    // Outside all semesters (before S1 and in the winter gap).
    expect(year.weekOf(DateTime(2026, 8, 1)), isNull);
    expect(year.weekOf(DateTime(2026, 12, 7)), isNull);
  });

  test('semesterAt and weekOf agree', () {
    final year = CalendarYear.fromYaml(sampleYaml);
    expect(year.semesterAt(DateTime(2026, 8, 12))!.name, 'semester_1');
    expect(year.semesterAt(DateTime(2026, 12, 7)), isNull);
  });

  test('latestCalendarYear returns the most recently synced calendar', () {
    expect(repo.latestCalendarYear(), isNull);
    sync.apply(sampleYaml);
    expect(repo.latestCalendarYear()!.academicYear, '2026-27');
  });
}
