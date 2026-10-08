
import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'support/admin_api_harness.dart';
import 'test_helpers.dart';

void main() {
  setUp(setUpAdminApi);
  tearDown(tearDownAdminApi);
  // ------------------------------------------------------- attendance

  test('attendance lists window sessions and sets explicit states', () async {
    repo.upsertUser(
      User(
        id: 101,
        name: '@alice',
        experience: Experience.experienced,
        group: 'A',
      ),
    );
    repo.upsertUser(
      User(id: 102, name: '@bob', experience: Experience.newbie, group: 'B'),
    );
    repo.upsertUser(
      User(
        id: 103,
        name: '@out',
        experience: Experience.newbie,
        group: '',
        memberTier: MemberTier.outMember,
      ),
    );
    final now = api.config.toLocal(Config.nowUtc());
    final w = RollingWindow.forDate(now);
    repo.ensureSessionsForWeekend(
      w.sat0,
      defaultTemplate(),
      tzOffsetHours: api.config.timezoneOffsetHours,
    );
    final sessions = repo.sessionsForWeekend(w.sat0);
    expect(sessions, isNotEmpty);
    final sessionId = sessions.first.id;
    repo.replaceAllocationsForWeekend(w.sat0, [
      (101, sessionId),
      (102, sessionId),
      (103, sessionId),
    ]);
    // A stale mark must not make an out-member actionable or expose attendance
    // state in the API payload.
    repo.setAttendanceState(103, sessionId, attended: true);

    final (status, body) = await call('GET', '/api/attendance');
    expect(status, 200);
    final s = ((body as Map<String, dynamic>)['sessions'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((s) => s['id'] == sessionId);
    expect(s['label'], isNotEmpty);
    expect(s['location'], isNotEmpty);
    expect(s['weekendStart'], isNotEmpty);
    expect(['sat', 'sun'], contains(s['day']));
    expect(['am', 'pm'], contains(s['slot']));
    final members = (s['members'] as List).cast<Map<String, dynamic>>();
    expect(members, hasLength(3));
    expect(
      members.where((m) => m['id'] != 103).every(
            (m) => m['eligible'] == true && m['state'] == 'unmarked',
          ),
      isTrue,
    );
    final outMember = members.firstWhere((m) => m['id'] == 103);
    expect(outMember['eligible'], false);
    expect(outMember.containsKey('state'), isFalse);

    final (outAttendanceStatus, outAttendanceBody) = await call(
      'POST',
      '/api/attendance',
      body: {'sessionId': sessionId, 'userId': 103, 'state': 'present'},
    );
    expect(outAttendanceStatus, 400);
    expect(
      (outAttendanceBody as Map<String, dynamic>)['error'],
      contains('out-members'),
    );

    final (t1, t1Body) = await call(
      'POST',
      '/api/attendance',
      body: {'sessionId': sessionId, 'userId': 101, 'state': 'present'},
    );
    expect(t1, 200);
    expect((t1Body as Map<String, dynamic>)['state'], 'present');

    final (t2, t2Body) = await call(
      'POST',
      '/api/attendance',
      body: {'sessionId': sessionId, 'userId': 101, 'state': 'absent'},
    );
    expect(t2, 200);
    expect((t2Body as Map<String, dynamic>)['state'], 'absent');

    final (t3, t3Body) = await call(
      'POST',
      '/api/attendance',
      body: {'sessionId': sessionId, 'userId': 101, 'state': 'unmarked'},
    );
    expect(t3, 200);
    expect((t3Body as Map<String, dynamic>)['state'], 'unmarked');
    expect(
      repo.attendanceForSession(sessionId).map((mark) => mark.userId),
      [103],
    );

    final (bad, _) = await call(
      'POST',
      '/api/attendance',
      body: {'sessionId': sessionId, 'userId': 101, 'state': 'maybe'},
    );
    expect(bad, 400);
  });
}
