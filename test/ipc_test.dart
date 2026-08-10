import 'dart:io';

import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:sdsc_bot/bot/calendar_sync.dart';

void main() {
  late Directory tmp;
  late Database db;
  late Repo repo;
  late CalendarSync sync;
  late CalendarIpcServer server;

  Config config() => Config(
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
      );

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sdsc_ipc_');
    db = Database.open(config());
    repo = Repo(db);
    sync = CalendarSync(repo: repo, config: config());
    server = CalendarIpcServer(sync: sync, token: 'secret-token', port: 0);
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    db.close();
    tmp.deleteSync(recursive: true);
  });

  Future<String> sendIpc(String token, String payload) async {
    final socket = await Socket.connect('127.0.0.1', server.boundPort);
    final bytes = payload.codeUnits;
    socket.write('TOKEN $token\nLEN ${bytes.length}\n$payload');
    await socket.flush();
    final resp = await socket.map((c) => String.fromCharCodes(c)).join();
    await socket.close();
    return resp.trim();
  }

  test('IPC accepts valid YAML and returns OK', () async {
    final yaml = '''
academic_year: 2026-27
semester_1:
  weeks:
    - week: 8
      type: recess
      start: 2026-09-28
      end: 2026-10-04
semester_2:
  weeks:
    - week: 1
      type: teaching
      start: 2027-01-04
      end: 2027-01-10
''';
    final resp = await sendIpc('secret-token', yaml);
    expect(resp, startsWith('OK 2026-27'));
    // The recess week became a middle holiday.
    final h = repo.holidayOn(DateTime(2026, 9, 28));
    expect(h, isNotNull);
    expect(h!.kind, HolidayKind.middle);
  });

  test('IPC rejects a bad token', () async {
    final resp = await sendIpc('wrong', 'academic_year: x');
    expect(resp, startsWith('ERR bad token'));
  });

  test('IPC rejects malformed YAML', () async {
    final resp = await sendIpc('secret-token', 'not: [valid');
    expect(resp, startsWith('ERR'));
  });
}
