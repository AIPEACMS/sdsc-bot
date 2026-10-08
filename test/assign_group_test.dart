import 'dart:io';

import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Database db;
  late Repo repo;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sdsc_assign_');
    db = Database.open(
      Config(
        botToken: 'test',
        dbPath: '${tmp.path}/test.db',
        consoleId: 1,
        groupAContact: 'TBD',
        groupBContact: 'TBD',
        ocbcCapacity: 2,
        prCapacity: 20,
        slotTimes: const {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
        promptHour: 18,
        reminderHour: 18,
        deadlineHour: 18,
        allocationHour: 9,
        bailHour: 12,
        timezoneOffsetHours: 8,
      ),
    );
    repo = Repo(db);
  });

  tearDown(() {
    db.close();
    tmp.deleteSync(recursive: true);
  });

  void add(
    int id,
    String handle, {
    String group = '',
    String tier = MemberTier.member,
    bool admin = false,
    bool gadmin = false,
  }) {
    repo.upsertSeenUser(id, handle);
    repo.upsertUser(
      User(
        id: id,
        name: '@$handle',
        experience: Experience.newbie,
        group: group,
        memberTier: tier,
        isAdmin: admin,
        isGlobalAdmin: gadmin,
      ),
    );
  }

  test('auto preview is deterministic and does not mutate', () {
    add(20, 'leader20', group: '10', admin: true);
    add(10, 'leader10', group: '2', admin: true);
    add(3, 'alice');
    add(4, 'bob');
    final preview = repo.previewAutoAssignGroups();

    expect(repo.findUser(3)!.group, isEmpty);
    expect(repo.findUser(4)!.group, isEmpty);
    expect(preview.members.values.map((m) => m.targetGroup), ['2', '10']);
    expect(preview.members.values.map((m) => m.id), [3, 4]);
  });

  test('exact preview applies and stale batches roll back atomically', () {
    add(1, 'leader', group: '1', admin: true);
    add(2, 'alice');
    add(3, 'bob');
    final preview = repo.previewAutoAssignGroups();
    expect(repo.applyGroupAssignment(preview), isTrue);
    expect(repo.findUser(2)!.group, '1');
    expect(repo.findUser(3)!.group, '1');

    add(4, 'carol');
    add(5, 'dave');
    final stale = repo.previewAutoAssignGroups();
    repo.setGroup(4, '9');
    expect(repo.applyGroupAssignment(stale), isFalse);
    expect(repo.findUser(4)!.group, '9');
    expect(repo.findUser(5)!.group, isEmpty);
  });

  test('auto preview fills the smallest existing group first', () {
    add(1, 'leader1', group: '1', admin: true);
    add(2, 'leader2', group: '2', admin: true);
    add(3, 'existing1', group: '1');
    add(4, 'existing2', group: '1');
    add(5, 'alice');
    add(6, 'bob');

    final preview = repo.previewAutoAssignGroups();

    expect(preview.members[5]!.targetGroup, '2');
    expect(preview.members[6]!.targetGroup, '1');
    expect(repo.findUser(5)!.group, isEmpty);
    expect(repo.findUser(6)!.group, isEmpty);
  });

  test('expired previews are rejected without mutation', () {
    add(1, 'leader', group: '1', admin: true);
    add(2, 'alice');
    final current = repo.previewAutoAssignGroups();
    final expired = GroupAssignmentPreview(
      leaderExpectedGroups: current.leaderExpectedGroups,
      leaderTargets: current.leaderTargets,
      members: current.members,
      createdAt: DateTime.now().subtract(const Duration(minutes: 11)),
    );
    expect(repo.applyGroupAssignment(expired), isFalse);
    expect(repo.findUser(2)!.group, isEmpty);
  });

  test('manual validation moves members and skips every ineligible tier', () {
    add(1, 'leader', group: '3', admin: true);
    add(2, 'member', group: '9');
    add(3, 'checker', tier: MemberTier.check);
    add(4, 'out', tier: MemberTier.outMember);
    add(5, 'old', tier: MemberTier.old);
    add(6, 'admin', group: '4', admin: true);
    final result = repo.validateManualGroupAssignment('3', [
      '@member',
      '@checker',
      '@out',
      '@old',
      '@admin',
      '@pending',
      '@member',
    ]);

    expect(result.preview!.members.keys, [2]);
    expect(result.skipped, ['checker', 'out', 'old', 'admin', 'pending']);
    expect(repo.findUser(2)!.group, '9');
    expect(repo.applyGroupAssignment(result.preview!), isTrue);
    expect(repo.findUser(2)!.group, '3');
  });

  test('numeric leaders are sorted and missing admin groups are repaired', () {
    add(1, 'leader10', group: '10', admin: true);
    add(2, 'leader2', group: '2', admin: true);
    add(3, 'leaderMissing', admin: true);
    final leaders = repo.groupLeaders(numericOnly: true);
    expect(leaders.map((u) => u.group), ['2', '10']);

    final counts = repo.autoAssignGroups();
    expect(repo.findUser(3)!.group, '1');
    expect(counts.keys, ['10', '2', '1']);
  });
}
