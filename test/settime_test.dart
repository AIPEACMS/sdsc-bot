import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:sdsc_bot/bot/admin_api.dart';
import 'package:sdsc_bot/bot/calendar_sync.dart';
import 'package:sdsc_bot/bot/hold.dart';
import 'package:sdsc_bot/bot/keyboards.dart';

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
  });

  group('locations', () {
    late Directory tmp;
    late Database db;
    late Repo repo;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('sdsc_loc_');
      db = Database.open(_config(tmp));
      repo = Repo(db);
    });

    tearDown(() {
      db.close();
      tmp.deleteSync(recursive: true);
    });

    test('seeds the built-in locations with aliases', () {
      final approved = repo.approvedLocations();
      expect(approved.map((l) => l.key).toSet(), {'ocbc', 'pasirRis'});
      expect(repo.resolveLocation('PR')!.key, 'pasirRis');
      expect(repo.resolveLocation('ocbc arena')!.key, 'ocbc');
      expect(repo.resolveLocation('pasir')!.key, 'pasirRis');
      expect(repo.resolveLocation('Pasir Ris')!.key, 'pasirRis');
      expect(repo.resolveLocation('nowhere'), isNull);
    });

    test('addAliases merges and de-duplicates', () {
      repo.addAliases('ocbc', ['The Arena', 'ocbc arena', '  ']);
      final loc = repo.locationByKey('ocbc')!;
      expect(loc.aliases, contains('The Arena'));
      expect(
        loc.aliases.where((a) => a.toLowerCase() == 'ocbc arena').length,
        1,
      );
      expect(repo.resolveLocation('the arena')!.key, 'ocbc');
    });

    test('request -> pending -> approve flow', () {
      final pending = repo.requestLocation('Marina Bay', requestedBy: 5);
      expect(pending.status, 'pending');
      expect(repo.approvedLocations().map((l) => l.key), isNot(contains(pending.key)));
      expect(repo.resolveLocation('marina bay'), isNull);

      expect(repo.approveLocation(pending.id, aliases: ['MB']), isTrue);
      expect(repo.resolveLocation('MB')!.key, pending.key);
      expect(repo.resolveLocation('Marina Bay')!.key, pending.key);
    });

    test('addLocation is idempotent by name', () {
      final a = repo.addLocation('Marina Bay');
      final b = repo.addLocation('marina bay', aliases: ['MB']);
      expect(b.id, a.id);
      expect(repo.resolveLocation('mb')!.key, a.key);
    });
  });

  group('template and sessions', () {
    late Directory tmp;
    late Database db;
    late Repo repo;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('sdsc_tpl_');
      db = Database.open(_config(tmp));
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
      repo.replaceSessionsForWeekend(
        sat,
        const [
          ScheduleSlot(
            day: 'sat',
            slot: 's1',
            start: '09:00',
            end: '13:00',
            location: 'pasirRis',
          ),
        ],
        tzOffsetHours: 8,
      );

      expect(repo.availabilityForWeekend(sat), isEmpty);
      final sessions = repo.sessionsForWeekend(sat);
      expect(sessions.length, 1);
      expect(sessions.single.slot, 's1');
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
        expect(commands.contains('/settime'), isFalse, reason: role);
        expect(commands.contains('/addalias'), isFalse, reason: role);
      }
    });
  });

  group('admin API locations', () {
    late Directory tmp;
    late Database db;
    late Repo repo;
    late AdminApi api;
    const token = 'secret-token';

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('sdsc_lapi_');
      final config = _config(tmp);
      db = Database.open(config);
      repo = Repo(db);
      api = AdminApi(
        repo: repo,
        config: config,
        calendarSync: CalendarSync(repo: repo, config: config),
        holdGate: HoldGate(false),
        token: token,
        port: 0,
      );
      await api.start();
    });

    tearDown(() async {
      await api.stop();
      db.close();
      tmp.deleteSync(recursive: true);
    });

    Future<(int, Object?)> call(String method, String path, {Object? body}) async {
      final client = HttpClient();
      try {
        final req = await client.openUrl(
          method,
          Uri.parse('http://127.0.0.1:${api.boundPort}$path'),
        );
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        if (body != null) {
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(body));
        }
        final res = await req.close();
        final text = await res.transform(utf8.decoder).join();
        return (
          res.statusCode,
          text.isEmpty ? <String, dynamic>{} : jsonDecode(text),
        );
      } finally {
        client.close(force: true);
      }
    }

    test('GET /api/locations lists approved and pending', () async {
      repo.requestLocation('Marina Bay', requestedBy: 1);
      final (status, body) = await call('GET', '/api/locations');
      expect(status, 200);
      final map = body as Map<String, dynamic>;
      expect((map['approved'] as List).length, 2);
      final pending = (map['pending'] as List).cast<Map<String, dynamic>>();
      expect(pending.single['name'], 'Marina Bay');
      expect(pending.single['status'], 'pending');
    });

    test('POST /api/locations creates and approves by name', () async {
      var approved = <LocationInfo>[];
      api.onLocationApproved = (l) async => approved.add(l);
      repo.requestLocation('Marina Bay', requestedBy: 1);

      final (status, body) = await call(
        'POST',
        '/api/locations',
        body: {
          'name': 'Marina Bay',
          'aliases': ['MB'],
        },
      );
      expect(status, 200);
      final loc = (body as Map<String, dynamic>)['location'] as Map;
      expect(loc['status'], 'approved');
      expect(repo.resolveLocation('MB')!.name, 'Marina Bay');
      expect(approved.single.name, 'Marina Bay');
    });

    test('POST /api/locations/{id}/approve sets aliases', () async {
      final pending = repo.requestLocation('Marina Bay', requestedBy: 1);
      final (status, body) = await call(
        'POST',
        '/api/locations/${pending.id}/approve',
        body: {
          'aliases': ['MB', 'the bay'],
        },
      );
      expect(status, 200);
      expect((body as Map<String, dynamic>)['ok'], true);
      expect(repo.resolveLocation('the bay')!.key, pending.key);
      final (missing, _) = await call(
        'POST',
        '/api/locations/999/approve',
        body: const {},
      );
      expect(missing, 404);
    });
  });
}

Config _config(Directory tmp) => Config(
  botToken: 'test',
  dbPath: '${tmp.path}/test.db',
  consoleId: 1,
  groupAContact: 'TBD',
  groupBContact: 'TBD',
  ocbcCapacity: 2,
  prCapacity: 20,
  slotTimes: const {
    'am': ('09:00', '12:00'),
    'pm': ('13:00', '17:00'),
  },
  promptHour: 18,
  reminderHour: 18,
  deadlineHour: 18,
  allocationHour: 9,
  bailHour: 12,
  timezoneOffsetHours: 8,
);
