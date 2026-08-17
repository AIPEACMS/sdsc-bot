import 'dart:convert';
import 'dart:io';

import 'package:televerse/televerse.dart';
import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';

import 'package:sdsc_bot/bot/service.dart';
import 'package:sdsc_bot/bot/state.dart';

/// Tests for the Monday absence reminder: members who have not attended for
/// 4+ consecutive weeks get their group admin reminded to reach out
/// personally (never via /ask). Repeats each Monday while the streak holds.
void main() {
  late Directory tmp;
  late Database db;
  late Repo repo;
  late Config config;
  late Messages messages;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sdsc_absent_');
    config = Config(
      botToken: 'test',
      dbPath: '${tmp.path}/test.db',
      consoleId: 1,
      groupAContact: 'TBD',
      groupBContact: 'TBD',
      ocbcCapacity: 2,
      prCapacity: 20,
      slotTimes: const {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
      promptHour: 8,
      reminderHour: 18,
      deadlineHour: 18,
      allocationHour: 9,
      bailHour: 12,
      timezoneOffsetHours: 8,
    );
    db = Database.open(config);
    repo = Repo(db);
    messages = Messages(
      (group) => repo.groupAdmin(group)?.name ?? config.contactForGroup(group),
    );
  });

  tearDown(() {
    db.close();
    tmp.deleteSync(recursive: true);
  });

  test('remindAbsentMembers flags 4+ week absences to the group admin', () async {
    final sent = <Map<String, dynamic>>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final path = req.uri.path;
      if (path.endsWith('/sendMessage')) {
        final body = jsonDecode(await utf8.decoder.bind(req).join());
        sent.add(body as Map<String, dynamic>);
        await _json(req, {
          'ok': true,
          'result': {
            'message_id': 1,
            'date': 1,
            'chat': {'id': body['chat_id'], 'type': 'private'},
            'text': body['text'],
          },
        });
      } else {
        await _json(req, {'ok': false, 'error': 'nf'}, status: 404);
      }
    });

    // Four consecutive session weekends: Aug 1, 8, 15, 22 2026.
    for (final sat in [
      DateTime(2026, 8, 1),
      DateTime(2026, 8, 8),
      DateTime(2026, 8, 15),
      DateTime(2026, 8, 22),
    ]) {
      repo.ensureSessionsForWeekend(
        sat,
        {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
        tzOffsetHours: 8,
      );
    }

    void add(int id, String name, String group, {bool isAdmin = false}) {
      repo.upsertUser(User(
        id: id,
        name: name,
        experience: Experience.newbie,
        group: group,
        isAdmin: isAdmin,
      ));
    }

    void backdate(int id, String createdAt) {
      repo.raw.execute(
          'UPDATE users SET created_at = ? WHERE id = ?', [createdAt, id]);
    }

    add(1, 'Console', '1'); // console: skipped as operator, not a group admin
    add(2, 'Admin 2', '1', isAdmin: true); // group 1 leader
    add(3, 'Member 3', '1'); // never attended → 4 weeks
    add(4, 'Member 4', '1'); // attended Aug 8 → 2 weeks
    add(5, 'Member 5', ''); // no group → nobody responsible
    add(6, 'Member 6', '2'); // group without an admin → skipped
    for (final id in [3, 4, 5, 6]) {
      backdate(id, '2026-07-01 00:00:00');
    }
    final aug8 = repo.sessionsForWeekend(DateTime(2026, 8, 8)).first;
    repo.setAttendanceState(4, aug8.id, attended: true);

    final bot = Bot.local('test-token', 'http://127.0.0.1:${server.port}');
    final service = CycleService(
      repo: repo,
      config: config,
      messages: messages,
      state: BotState(),
      bot: bot,
    );

    final monday = DateTime(2026, 8, 24);
    await service.remindAbsentMembers(monday);

    // Exactly one message, to the group-1 admin, about member 3 only.
    expect(sent.length, 1);
    expect(sent.single['chat_id'], 2);
    final text = sent.single['text'] as String;
    expect(text, contains('Member 3 — 4 weeks'));
    expect(text, contains('personally'));
    expect(text, contains('/ask'));
    expect(text, isNot(contains('Member 4')));
    expect(text, isNot(contains('Member 5')));
    expect(text, isNot(contains('Member 6')));

    // Same Monday: deduped, no second message.
    await service.remindAbsentMembers(monday);
    expect(sent.length, 1);

    // Next Monday: the streak still holds, so it repeats.
    await service.remindAbsentMembers(monday.add(const Duration(days: 7)));
    expect(sent.length, 2);

    await server.close(force: true);
  });
}

Future<void> _json(HttpRequest req, Map<String, dynamic> body,
    {int status = 200}) async {
  req.response
    ..statusCode = status
    ..headers.contentType = ContentType.json;
  req.response.write(jsonEncode(body));
  await req.response.close();
}