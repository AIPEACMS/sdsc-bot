import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';

import '../../support/admin_api_harness.dart' as harness;

void main() {
  setUp(harness.setUpAdminApi);
  tearDown(harness.tearDownAdminApi);

  test('selected-week read defaults to server-local current week', () async {
    final now = harness.api.config.toLocal(Config.nowUtc());
    final today = DateTime(now.year, now.month, now.day);
    final currentSaturday = today.add(
      Duration(days: (DateTime.saturday - today.weekday + 7) % 7),
    );
    final expected =
        '${currentSaturday.year.toString().padLeft(4, '0')}-'
        '${currentSaturday.month.toString().padLeft(2, '0')}-'
        '${currentSaturday.day.toString().padLeft(2, '0')}';
    final (status, response) = await harness.call(
      'POST',
      '/api/session-schedule/read',
      body: {'scope': 'temporary'},
    );

    expect(status, 200, reason: '$response');
    expect((response as Map)['week'], expected);
    expect(response['currentWeek'], expected);
  });

  test(
    'selected-week schedule reads and temporary changes work beyond window',
    () async {
      const week = '2026-11-07';
      final (getStatus, raw) = await harness.call(
        'POST',
        '/api/session-schedule/read',
        body: {'scope': 'temporary', 'week': week},
      );
      expect(getStatus, 200);
      final read = raw as Map<String, dynamic>;
      expect(read['week'], week);
      expect(read['actionable'], isTrue);

      final current = (read['rows'] as List).cast<Map<String, dynamic>>();
      final next = [
        ...current,
        {
          'day': 'sat',
          'slot': 'api-test',
          'start': '10:00',
          'end': '11:00',
          'location': 'ocbc',
          'maxPeople': 3,
          'capacityGroup': null,
        },
      ];
      final body = {
        'scope': 'temporary',
        'week': week,
        'action': 'rewrite',
        'rows': next,
      };
      final (previewStatus, previewRaw) = await harness.call(
        'POST',
        '/api/session-schedule/preview',
        body: body,
      );
      expect(previewStatus, 200);
      expect((previewRaw as Map)['scheduleChangeEnabled'], isA<bool>());

      final (commitStatus, commitRaw) = await harness.call(
        'POST',
        '/api/session-schedule/commit',
        body: body,
      );
      expect(commitStatus, 200, reason: '$commitRaw');
      expect((commitRaw as Map)['saved'], isTrue);
      final (afterStatus, afterRaw) = await harness.call(
        'POST',
        '/api/session-schedule/read',
        body: {'scope': 'temporary', 'week': week},
      );
      expect(afterStatus, 200);
      expect((afterRaw as Map)['rows'], hasLength(next.length));
    },
  );

  test('locked selected week is rejected for mutation', () async {
    final body = {
      'scope': 'temporary',
      'week': '2026-10-10',
      'action': 'add',
      'rows': [
        {
          'day': 'sat',
          'slot': 'x',
          'start': '10:00',
          'end': '11:00',
          'location': 'ocbc',
        },
      ],
    };
    final (status, response) = await harness.call(
      'POST',
      '/api/session-schedule/preview',
      body: body,
    );
    expect(status, 400);
    expect((response as Map)['error'], 'selected week is locked');
  });

  test('selected week is bound to the signed read body', () async {
    final (status, response) = await harness.signedCall(
      'POST',
      '/api/session-schedule/read',
      body: {'scope': 'temporary', 'week': '2026-11-07'},
    );
    expect(status, 200, reason: '$response');

    final (tamperedStatus, tampered) = await harness.signedCall(
      'POST',
      '/api/session-schedule/read',
      body: {'scope': 'temporary', 'week': '2026-11-07'},
      wireBody: {'scope': 'temporary', 'week': '2026-11-14'},
      nonce: 'tampered-week',
    );
    expect(tamperedStatus, 401, reason: '$tampered');
  });

  test(
    'recurring add preserves allocations and availability; remove is selective',
    () async {
      final now = harness.api.config.toLocal(Config.nowUtc());
      final window = harness.api.scheduleRuntime.window(now);
      final saturday = window.sat1;
      final template = harness.repo.scheduleTemplate();
      harness.repo.ensureSessionsForWeekend(
        saturday,
        template,
        tzOffsetHours: harness.api.config.timezoneOffsetHours,
      );
      final sessions = harness.repo.sessionsForWeekend(saturday);
      final user = User(
        id: 7412,
        name: 'Recurring allocation',
        experience: Experience.newbie,
        group: '',
      );
      harness.repo.upsertUser(user);
      harness.repo.replaceAllocationsForWeekend(saturday, [
        (user.id, sessions[0].id),
        (user.id, sessions[1].id),
      ]);
      final availability = Availability(
        weekendStart: saturday,
        userId: user.id,
        bundleStart: saturday,
        slots: {
          Slot(0, sessions[0].day, sessions[0].slot, sessions[0].location),
        },
        available: true,
        updatedAt: now,
      );
      harness.repo.setAvailability(availability);

      final newRow = {
        'day': 'fri',
        'slot': 'regression-extra',
        'start': '10:00',
        'end': '11:00',
        'location': 'ocbc',
        'maxPeople': 2,
        'capacityGroup': null,
      };
      final addBody = {
        'scope': 'recurring',
        'action': 'add',
        'rows': [newRow],
      };
      final (addStatus, addResult) = await harness.call(
        'POST',
        '/api/session-schedule/commit',
        body: addBody,
      );
      expect(addStatus, 200, reason: '$addResult');
      expect((addResult as Map)['affectedAllocations'], isEmpty);
      expect(addResult['notified'], 0);
      expect(addResult['notificationFailures'], 0);
      expect(harness.repo.allocationsForWeekend(saturday), hasLength(2));
      expect(
        harness.repo.getAvailability(saturday, user.id)?.slots,
        availability.slots,
      );

      final removeBody = {
        'scope': 'recurring',
        'action': 'remove',
        'rows': [
          {
            'day': sessions[0].day,
            'slot': sessions[0].slot,
            'start': '00:00',
            'end': '00:01',
            'location': sessions[0].location,
          },
        ],
      };
      final (previewStatus, previewResult) = await harness.call(
        'POST',
        '/api/session-schedule/preview',
        body: removeBody,
      );
      expect(previewStatus, 200, reason: '$previewResult');
      expect((previewResult as Map)['affectedAllocations'], hasLength(1));
      final (removeStatus, removeResult) = await harness.call(
        'POST',
        '/api/session-schedule/commit',
        body: removeBody,
      );
      expect(removeStatus, 200, reason: '$removeResult');
      expect((removeResult as Map)['affectedAllocations'], hasLength(1));
      final remaining = harness.repo.allocationsForWeekend(saturday);
      expect(remaining, hasLength(1));
      expect(remaining.single.$2.id, sessions[1].id);
      expect(
        harness.repo.getAvailability(saturday, user.id)?.slots,
        isNot(
          contains(
            Slot(0, sessions[0].day, sessions[0].slot, sessions[0].location),
          ),
        ),
      );
    },
  );

  test(
    'changing an allocated session time clears it and previews notice',
    () async {
      final now = harness.api.config.toLocal(Config.nowUtc());
      final saturday = harness.api.scheduleRuntime.window(now).sat1;
      final before = harness.repo.scheduleForWeekend(saturday);
      harness.repo.ensureSessionsForWeekend(
        saturday,
        before,
        tzOffsetHours: harness.api.config.timezoneOffsetHours,
      );
      final session = harness.repo.sessionsForWeekend(saturday).first;
      const userId = 7413;
      harness.repo.upsertUser(
        User(
          id: userId,
          name: 'Changed time allocation',
          experience: Experience.newbie,
          group: '',
        ),
      );
      harness.repo.replaceAllocationsForWeekend(saturday, [
        (userId, session.id),
      ]);
      final oldPick = Slot(0, session.day, session.slot, session.location);
      harness.repo.setAvailability(
        Availability(
          weekendStart: saturday,
          userId: userId,
          bundleStart: saturday,
          slots: {oldPick},
          available: true,
          updatedAt: now,
        ),
      );

      final changedStart = session.start.hour == 8 ? '10:00' : '08:00';
      final changedEnd = session.start.hour == 8 ? '14:00' : '12:00';
      final rows = [
        for (final row in before)
          {
            'day': row.day,
            'slot': row.slot,
            'start': row.day == session.day && row.slot == session.slot
                ? changedStart
                : row.start,
            'end': row.day == session.day && row.slot == session.slot
                ? changedEnd
                : row.end,
            'location': row.location,
            'maxPeople': row.maxPeople,
            'capacityGroup': row.capacityGroup,
          },
      ];
      final week =
          '${saturday.year.toString().padLeft(4, '0')}-'
          '${saturday.month.toString().padLeft(2, '0')}-'
          '${saturday.day.toString().padLeft(2, '0')}';
      final body = {
        'scope': 'temporary',
        'week': week,
        'action': 'rewrite',
        'rows': rows,
      };
      final (previewStatus, previewResponse) = await harness.call(
        'POST',
        '/api/session-schedule/preview',
        body: body,
      );
      expect(previewStatus, 200, reason: '$previewResponse');
      expect(
        (previewResponse as Map)['affectedAllocations'],
        contains(isA<Map>().having((row) => row['userId'], 'userId', userId)),
      );

      final (commitStatus, commitResponse) = await harness.call(
        'POST',
        '/api/session-schedule/commit',
        body: body,
      );
      expect(commitStatus, 200, reason: '$commitResponse');
      expect(
        harness.repo
            .allocationsForWeekend(saturday)
            .any((allocation) => allocation.$2.id == session.id),
        isFalse,
      );
      expect(
        harness.repo.getAvailability(saturday, userId)?.slots,
        isNot(contains(oldPick)),
      );
    },
  );

  test(
    'selected-week allocation removal accepts only IDs in that old week',
    () async {
      const week = '2026-11-07';
      final saturday = DateTime(2026, 11, 7);
      final rows = harness.repo.scheduleTemplate();
      harness.repo.ensureSessionsForWeekend(
        saturday,
        rows,
        tzOffsetHours: harness.api.config.timezoneOffsetHours,
      );
      final session = harness.repo.sessionsForWeekend(saturday).first;
      harness.repo.upsertUser(
        User(
          id: 7401,
          name: 'Selected week',
          experience: Experience.newbie,
          group: '',
        ),
      );
      harness.repo.replaceAllocationsForWeekend(saturday, [(7401, session.id)]);
      final target = {
        'week': week,
        'entries': [
          {'sessionId': session.id, 'userId': 7401},
        ],
      };
      final (previewStatus, preview) = await harness.call(
        'POST',
        '/api/allocations/removal-preview',
        body: target,
      );
      expect(previewStatus, 200);
      expect((preview as Map)['allocations'], hasLength(1));
      final (removeStatus, result) = await harness.call(
        'POST',
        '/api/allocations/remove',
        body: target,
      );
      expect(removeStatus, 200, reason: '$result');
      expect((result as Map)['removed'], 1);
      expect(harness.repo.allocationsForWeekend(saturday), isEmpty);
    },
  );
}
