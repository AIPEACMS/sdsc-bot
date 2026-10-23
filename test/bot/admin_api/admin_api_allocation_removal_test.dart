import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:televerse/televerse.dart' show Bot;
import 'package:sdsc_bot/bot/admin_api.dart';
import 'package:sdsc_bot/bot/calendar_sync.dart';
import 'package:sdsc_bot/bot/hold.dart';
import 'package:sdsc_bot/bot/service.dart';
import 'package:sdsc_bot/bot/state.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import '../../support/admin_api_harness.dart';
import '../../support/test_helpers.dart';

void main() {
  setUp(setUpAdminApi);
  tearDown(tearDownAdminApi);

  test(
    'allocation preview and confirm remove only requested current entries',
    () async {
      repo.upsertUser(
        User(
          id: 101,
          name: '<Alice>',
          experience: Experience.newbie,
          group: '',
        ),
      );
      repo.upsertUser(
        User(id: 102, name: '@Bob', experience: Experience.newbie, group: ''),
      );
      final window = RollingWindow.forDate(api.config.toLocal(Config.nowUtc()));
      repo.ensureSessionsForWeekend(
        window.sat0,
        defaultTemplate(),
        tzOffsetHours: api.config.timezoneOffsetHours,
      );
      final sessions = repo.sessionsForWeekend(window.sat0);
      final first = sessions.first;
      final second = sessions.last;
      final firstPick = Slot(0, first.day, first.slot, first.location);
      final secondPick = Slot(0, second.day, second.slot, second.location);
      repo.setAvailability(
        Availability(
          weekendStart: window.sat0,
          userId: 101,
          bundleStart: window.sat0,
          slots: {firstPick, secondPick},
          available: true,
          updatedAt: DateTime(2026, 9, 10),
        ),
      );
      repo.replaceAllocationsForWeekend(window.sat0, [
        (101, first.id),
        (102, second.id),
      ]);
      repo.setAttendanceState(101, first.id, attended: true);

      final (previewStatus, preview) = await call(
        'POST',
        '/api/allocations/removal-preview',
        body: {
          'entries': [
            {'sessionId': first.id, 'userId': 101},
          ],
        },
      );
      expect(previewStatus, 200);
      final previewBody = preview as Map<String, dynamic>;
      expect((previewBody['allocations'] as List), hasLength(1));
      expect(previewBody['allocations'][0]['userName'], '<Alice>');

      final (removeStatus, result) = await call(
        'POST',
        '/api/allocations/remove',
        body: {
          'entries': [
            {'sessionId': first.id, 'userId': 101},
          ],
        },
      );
      expect(removeStatus, 200);
      expect((result as Map<String, dynamic>)['removed'], 1);
      expect(repo.allocationsForWeekend(window.sat0).map((r) => r.$1.id), [
        102,
      ]);
      expect(repo.attendanceForSession(first.id), isEmpty);
      expect(
        repo.getAvailability(window.sat0, 101)?.slots,
        {secondPick},
      );
    },
  );

  test(
    'whole session removal is allowed on locked dates in the current window',
    () async {
      Config.setDebugNow(
        DateTime.utc(2026, 9, 18, 12),
      ); // Friday 20:00 local, current week locked.
      addTearDown(() => Config.setDebugNow(null));
      final window = RollingWindow.forDate(api.config.toLocal(Config.nowUtc()));
      repo.upsertUser(
        User(id: 101, name: '@Alice', experience: Experience.newbie, group: ''),
      );
      repo.ensureSessionsForWeekend(
        window.sat0,
        defaultTemplate(),
        tzOffsetHours: api.config.timezoneOffsetHours,
      );
      final session = repo.sessionsForWeekend(window.sat0).first;
      final otherSessions = repo
          .sessionsForWeekend(window.sat0)
          .where((candidate) => candidate.id != session.id)
          .map((candidate) => candidate.id)
          .toSet();
      repo.replaceAllocationsForWeekend(window.sat0, [(101, session.id)]);
      repo.setAttendanceState(101, session.id, attended: true);
      final other = repo
          .sessionsForWeekend(window.sat0)
          .firstWhere((candidate) => candidate.id != session.id);
      final otherPick = Slot(0, other.day, other.slot, other.location);
      final removedPick = Slot(0, session.day, session.slot, session.location);
      repo.setAvailability(
        Availability(
          weekendStart: window.sat0,
          userId: 101,
          bundleStart: window.sat0,
          slots: {removedPick, otherPick},
          available: true,
          updatedAt: DateTime(2026, 9, 10),
        ),
      );
      final (previewStatus, preview) = await call(
        'POST',
        '/api/allocations/removal-preview',
        body: {'sessionId': session.id},
      );
      expect(previewStatus, 200);
      expect((preview as Map<String, dynamic>)['sessionLabel'], isNotEmpty);
      final (status, body) = await call(
        'POST',
        '/api/allocations/remove',
        body: {'sessionId': session.id},
      );
      expect(status, 200);
      expect((body as Map<String, dynamic>)['removed'], 1);
      expect(repo.sessionById(session.id), isNull);
      expect(repo.attendanceForSession(session.id), isEmpty);
      expect(repo.getAvailability(window.sat0, 101)?.slots, {otherPick});
      expect(
        repo.sessionsForWeekend(window.sat0).map((s) => s.id).toSet(),
        otherSessions,
      );
      expect(repo.scheduleTemplate(), isNotEmpty);
    },
  );

  test(
    'malformed and stale removal requests are rejected without mutation',
    () async {
      final window = RollingWindow.forDate(api.config.toLocal(Config.nowUtc()));
      repo.upsertUser(
        User(id: 101, name: '@Alice', experience: Experience.newbie, group: ''),
      );
      repo.ensureSessionsForWeekend(
        window.sat0,
        defaultTemplate(),
        tzOffsetHours: api.config.timezoneOffsetHours,
      );
      final session = repo.sessionsForWeekend(window.sat0).first;
      repo.replaceAllocationsForWeekend(window.sat0, [(101, session.id)]);
      final (badStatus, _) = await call(
        'POST',
        '/api/allocations/removal-preview',
        body: {
          'entries': [
            {'sessionId': 'bad', 'userId': 101},
          ],
        },
      );
      expect(badStatus, 400);
      final (staleStatus, _) = await call(
        'POST',
        '/api/allocations/remove',
        body: {
          'entries': [
            {'sessionId': session.id + 100000, 'userId': 101},
          ],
        },
      );
      expect(staleStatus, 409);
      expect(repo.allocationsForWeekend(window.sat0), hasLength(1));
    },
  );

  test(
    'allocation-removal API suppresses notices when route is disabled',
    () async {
      final window = RollingWindow.forDate(api.config.toLocal(Config.nowUtc()));
      repo.upsertUser(
        User(id: 101, name: '@Alice', experience: Experience.newbie, group: ''),
      );
      repo.ensureSessionsForWeekend(
        window.sat0,
        defaultTemplate(),
        tzOffsetHours: api.config.timezoneOffsetHours,
      );
      final session = repo.sessionsForWeekend(window.sat0).first;
      repo.replaceAllocationsForWeekend(window.sat0, [(101, session.id)]);
      repo.setActiveOutreach('schedule-change', false);
      final (status, body) = await call(
        'POST',
        '/api/allocations/remove',
        body: {
          'entries': [
            {'sessionId': session.id, 'userId': 101},
          ],
        },
      );
      expect(status, 200);
      expect((body as Map<String, dynamic>)['notified'], 0);
      expect(body['notificationFailures'], 0);
      expect(body['scheduleChangeEnabled'], false);
    },
  );

  test('allocation-removal API batches notices per user with session details', () async {
    final window = RollingWindow.forDate(api.config.toLocal(Config.nowUtc()));
    repo.upsertUser(
      User(id: 101, name: '@Alice', experience: Experience.newbie, group: ''),
    );
    repo.ensureSessionsForWeekend(
      window.sat0,
      defaultTemplate(),
      tzOffsetHours: api.config.timezoneOffsetHours,
    );
    final sessions = repo.sessionsForWeekend(window.sat0).take(2).toList();
    repo.replaceAllocationsForWeekend(window.sat0, [
      for (final session in sessions) (101, session.id),
    ]);

    final sent = <Map<String, dynamic>>[];
    final botServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    botServer.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      sent.add(body);
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'ok': true,
          'result': {
            'message_id': sent.length,
            'date': 1,
            'chat': {'id': body['chat_id'], 'type': 'private'},
            'text': body['text'],
          },
        }));
      await request.response.close();
    });

    final config = api.config;
    final bot = Bot.local(
      'test-token',
      'http://127.0.0.1:${botServer.port}',
    );
    final service = CycleService(
      repo: repo,
      config: config,
      messages: Messages((group) => config.contactForGroup(group)),
      state: BotState(),
      bot: bot,
    );
    final notifyApi = AdminApi(
      repo: repo,
      config: config,
      calendarSync: CalendarSync(repo: repo, config: config),
      holdGate: HoldGate(false),
      service: service,
      token: token,
      port: 0,
    );
    await notifyApi.start();
    addTearDown(() async {
      await notifyApi.stop();
      await botServer.close(force: true);
    });

    final (status, result) = await call(
      'POST',
      '/api/allocations/remove',
      on: notifyApi,
      body: {
        'entries': [
          for (final session in sessions)
            {'sessionId': session.id, 'userId': 101},
        ],
      },
    );
    expect(status, 200);
    expect((result as Map<String, dynamic>)['notified'], 1);
    expect(result['notificationFailures'], 0);
    expect(sent, hasLength(1));
    final message = sent.single['text'] as String;
    expect(message, contains('⚠️ <b>Your allocation has been removed</b>'));
    expect(message, contains('Your other allocations are unchanged.'));
    for (final session in sessions) {
      expect(message, contains(session.location == Locations.ocbc ? 'OCBC' : 'Pasir Ris'));
    }
  });

  test(
    'deleting the final temporary session preserves an empty override, not the template',
    () async {
      final window = RollingWindow.forDate(api.config.toLocal(Config.nowUtc()));
      final template = repo.scheduleTemplate();
      repo.replaceScheduleOverride(window.sat0, [
        template.first,
      ], tzOffsetHours: api.config.timezoneOffsetHours);
      repo.ensureSessionsForWeekend(
        window.sat0,
        repo.scheduleForWeekend(window.sat0),
        tzOffsetHours: api.config.timezoneOffsetHours,
      );
      final session = repo.sessionsForWeekend(window.sat0).single;
      final (status, _) = await call(
        'POST',
        '/api/allocations/remove',
        body: {'sessionId': session.id},
      );
      expect(status, 200);
      expect(repo.scheduleForWeekend(window.sat0), isEmpty);
      expect(
        repo
            .scheduleTemplate()
            .map(
              (row) =>
                  '${row.day}|${row.slot}|${row.start}|${row.end}|${row.location}',
            )
            .toList(),
        template
            .map(
              (row) =>
                  '${row.day}|${row.slot}|${row.start}|${row.end}|${row.location}',
            )
            .toList(),
      );
    },
  );
}
