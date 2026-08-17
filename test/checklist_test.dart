import 'dart:convert';
import 'dart:io';

import 'package:televerse/televerse.dart';
import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';

import 'package:sdsc_bot/bot/service.dart';
import 'package:sdsc_bot/bot/state.dart';

/// Tests for the Friday-evening checklist: the backend pushes the current
/// weekend's full allocation to every `check`-tier user (a final
/// confirmation list, independent of their on-demand status button).
void main() {
  late Directory tmp;
  late Database db;
  late Repo repo;
  late Config config;
  late Messages messages;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sdsc_checklist_');
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

  void add(int id, String name, String group, {String tier = 'member'}) {
    repo.upsertUser(User(
      id: id,
      name: name,
      experience: Experience.newbie,
      group: group,
      memberTier: tier,
    ));
  }

  test('checkListText formats the weekend allocation by session', () {
    final sat = DateTime(2026, 8, 15);
    repo.ensureSessionsForWeekend(
      sat,
      {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
      tzOffsetHours: 8,
    );
    add(1, 'Console', '1');
    add(2, 'Admin 2', '1');
    add(5, 'Member 5', '1');
    final sessions = repo.sessionsForWeekend(sat);
    repo.replaceAllocationsForWeekend(sat, [
      (5, sessions[0].id),
      (2, sessions[2].id),
    ]);

    final service = CycleService(
      repo: repo,
      config: config,
      messages: messages,
      state: BotState(),
      bot: Bot.local('test-token', 'http://127.0.0.1:1'),
    );
    final text = service.checkListText(sat);
    expect(text, contains('This week\'s allocation'));
    expect(text, contains('Member 5'));
    expect(text, contains('Admin 2'));
    expect(text, isNot(contains('Console')));

    // No allocation yet: a friendly placeholder, not an error.
    final empty = service.checkListText(DateTime(2026, 8, 22));
    expect(empty, contains('No allocation published yet'));
  });

  test('sendCheckList pushes to check-tier users only, deduped per day',
      () async {
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

    final sat = DateTime(2026, 8, 15);
    repo.ensureSessionsForWeekend(
      sat,
      {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
      tzOffsetHours: 8,
    );
    add(1, 'Console', '1'); // console: not check tier
    add(2, 'Admin 2', '1'); // admin: not check tier
    add(3, 'Checker 3', '1', tier: 'check');
    add(4, 'Checker 4', '2', tier: 'check');
    add(5, 'Member 5', '1'); // member: not check tier
    final sessions = repo.sessionsForWeekend(sat);
    repo.replaceAllocationsForWeekend(sat, [(5, sessions.first.id)]);

    final bot = Bot.local('test-token', 'http://127.0.0.1:${server.port}');
    final service = CycleService(
      repo: repo,
      config: config,
      messages: messages,
      state: BotState(),
      bot: bot,
    );

    await service.sendCheckList(sat);

    // Exactly the two check-tier users, both with the allocation list.
    expect(sent.length, 2);
    final chatIds = sent.map((s) => s['chat_id']).toSet();
    expect(chatIds, {3, 4});
    for (final s in sent) {
      expect(s['text'] as String, contains('Member 5'));
    }

    // Same day: deduped, no second push.
    await service.sendCheckList(sat);
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