part of '../../repo.dart';

extension RepoGroups on Repo {
  List<User> groupLeaders({bool numericOnly = false}) {
    final leaders = allUsers()
        .where(
          (user) =>
              (user.isAdmin || user.isGlobalAdmin) && user.group.isNotEmpty,
        )
        .where((user) => !numericOnly || int.tryParse(user.group) != null)
        .toList();
    leaders.sort((a, b) {
      final aNumber = int.tryParse(a.group);
      final bNumber = int.tryParse(b.group);
      if (aNumber != null && bNumber != null && aNumber != bNumber) {
        return aNumber.compareTo(bNumber);
      }
      if (aNumber != null && bNumber == null) return -1;
      if (aNumber == null && bNumber != null) return 1;
      final group = a.group.compareTo(b.group);
      return group == 0 ? a.id.compareTo(b.id) : group;
    });
    final seenGroups = <String>{};
    return leaders.where((leader) => seenGroups.add(leader.group)).toList();
  }

  /// Builds an assignment without changing SQLite. Leaders with no group are
  /// included as repairs, and members are distributed by stable id order.
  GroupAssignmentPreview previewAutoAssignGroups() {
    final users = allUsers();
    final leaders =
        users.where((user) => user.isAdmin || user.isGlobalAdmin).toList()
          ..sort((a, b) => a.id.compareTo(b.id));

    final usedGroups = leaders
        .map((leader) => leader.group)
        .where((group) => group.isNotEmpty)
        .toSet();
    final expectedLeaders = <int, String>{};
    final targetLeaders = <int, String>{};
    var nextGroup = 1;
    for (final leader in leaders) {
      final target = leader.group.isNotEmpty
          ? leader.group
          : _nextFreeGroup(usedGroups, nextGroup);
      if (leader.group.isEmpty) {
        usedGroups.add(target);
        nextGroup = int.parse(target) + 1;
      }
      expectedLeaders[leader.id] = leader.group;
      targetLeaders[leader.id] = target;
    }

    final orderedLeaders =
        <User>[
          for (final leader in leaders)
            if (targetLeaders.containsKey(leader.id)) leader,
        ]..sort((a, b) {
          final group = _groupNumber(
            targetLeaders[a.id]!,
          ).compareTo(_groupNumber(targetLeaders[b.id]!));
          return group == 0 ? a.id.compareTo(b.id) : group;
        });
    final candidates =
        users
            .where(
              (user) =>
                  !user.isAdmin &&
                  !user.isGlobalAdmin &&
                  user.memberTier == MemberTier.member &&
                  user.group.isEmpty,
            )
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    final members = <int, GroupAssignmentMember>{};
    final groupCounts = <String, int>{
      for (final leader in orderedLeaders) targetLeaders[leader.id]!: 0,
    };
    for (final user in users) {
      if (user.memberTier == MemberTier.member &&
          !user.isAdmin &&
          !user.isGlobalAdmin &&
          groupCounts.containsKey(user.group)) {
        groupCounts[user.group] = groupCounts[user.group]! + 1;
      }
    }
    if (orderedLeaders.isNotEmpty) {
      for (var i = 0; i < candidates.length; i++) {
        final leader = orderedLeaders.reduce((a, b) {
          final aGroup = targetLeaders[a.id]!;
          final bGroup = targetLeaders[b.id]!;
          final countComparison =
              groupCounts[aGroup]!.compareTo(groupCounts[bGroup]!);
          if (countComparison != 0) return countComparison < 0 ? a : b;
          return _groupNumber(aGroup) <= _groupNumber(bGroup) ? a : b;
        });
        final targetGroup = targetLeaders[leader.id]!;
        members[candidates[i].id] = GroupAssignmentMember(
          id: candidates[i].id,
          handle: _handleFor(candidates[i]),
          expectedGroup: candidates[i].group,
          targetGroup: targetGroup,
          expectedTier: candidates[i].memberTier,
          expectedAdmin: candidates[i].isAdmin,
          expectedGlobalAdmin: candidates[i].isGlobalAdmin,
        );
        groupCounts[targetGroup] = groupCounts[targetGroup]! + 1;
      }
    }
    return GroupAssignmentPreview(
      leaderExpectedGroups: expectedLeaders,
      leaderTargets: targetLeaders,
      members: members,
    );
  }

  GroupAssignmentPreview autoAssignGroupsPreview() => previewAutoAssignGroups();

  /// Applies exactly one preview, or rolls back everything when any observed
  /// leader/member row no longer matches the preview.
  bool applyGroupAssignment(GroupAssignmentPreview preview) {
    if (preview.isExpired) return false;
    final tx = raw;
    tx.execute('BEGIN IMMEDIATE');
    try {
      final currentLeaders = <int, User>{};
      for (final entry in preview.leaderExpectedGroups.entries) {
        final leader = findUser(entry.key);
        if (leader == null ||
            (!leader.isAdmin && !leader.isGlobalAdmin) ||
            leader.group != entry.value ||
            preview.leaderTargets[entry.key] == null) {
          tx.execute('ROLLBACK');
          return false;
        }
        currentLeaders[entry.key] = leader;
      }

      final targetOwners = <String, int>{};
      for (final leader in currentLeaders.values) {
        if (leader.group.isNotEmpty) {
          final previous = targetOwners[leader.group];
          if (previous != null && previous != leader.id) {
            tx.execute('ROLLBACK');
            return false;
          }
          targetOwners[leader.group] = leader.id;
        }
      }
      for (final entry in preview.leaderTargets.entries) {
        final target = entry.value;
        final owner = targetOwners[target];
        if (owner != null && owner != entry.key) {
          tx.execute('ROLLBACK');
          return false;
        }
      }

      for (final member in preview.members.values) {
        final current = findUser(member.id);
        if (current == null ||
            current.group != member.expectedGroup ||
            current.memberTier != member.expectedTier ||
            current.isAdmin != member.expectedAdmin ||
            current.isGlobalAdmin != member.expectedGlobalAdmin ||
            current.memberTier != MemberTier.member ||
            current.isAdmin ||
            current.isGlobalAdmin ||
            !preview.leaderTargets.values.contains(member.targetGroup)) {
          tx.execute('ROLLBACK');
          return false;
        }
      }

      for (final entry in preview.leaderTargets.entries) {
        tx.execute('UPDATE users SET group_id = ? WHERE id = ?', [
          entry.value,
          entry.key,
        ]);
      }
      for (final member in preview.members.values) {
        tx.execute('UPDATE users SET group_id = ? WHERE id = ?', [
          member.targetGroup,
          member.id,
        ]);
      }
      tx.execute('COMMIT');
      return true;
    } catch (_) {
      tx.execute('ROLLBACK');
      rethrow;
    }
  }

  bool applyAutoAssignGroups(GroupAssignmentPreview preview) =>
      applyGroupAssignment(preview);

  GroupAssignmentValidation validateManualGroupAssignment(
    String group,
    List<String> handles,
  ) {
    final leader = groupLeaders(
      numericOnly: true,
    ).where((candidate) => candidate.group == group).firstOrNull;
    final skipped = <String>[];
    final members = <int, GroupAssignmentMember>{};
    final seen = <String>{};
    for (final rawHandle in handles) {
      final normalized = rawHandle.replaceFirst('@', '').toLowerCase();
      if (!seen.add(normalized)) continue;
      final user = RegExp(r'^[A-Za-z0-9_]+$').hasMatch(normalized)
          ? findUserByHandle(normalized)
          : null;
      if (user == null ||
          user.memberTier != MemberTier.member ||
          user.isAdmin ||
          user.isGlobalAdmin ||
          leader == null) {
        skipped.add(normalized);
        continue;
      }
      members[user.id] = GroupAssignmentMember(
        id: user.id,
        handle: _handleFor(user, fallback: normalized),
        expectedGroup: user.group,
        targetGroup: group,
        expectedTier: user.memberTier,
        expectedAdmin: user.isAdmin,
        expectedGlobalAdmin: user.isGlobalAdmin,
      );
    }
    if (leader == null || members.isEmpty) {
      return GroupAssignmentValidation(preview: null, skipped: skipped);
    }
    return GroupAssignmentValidation(
      preview: GroupAssignmentPreview(
        leaderExpectedGroups: {leader.id: leader.group},
        leaderTargets: {leader.id: leader.group},
        members: members,
      ),
      skipped: skipped,
    );
  }

  String _nextFreeGroup(Set<String> used, int start) {
    var number = start;
    while (used.contains('$number')) {
      number++;
    }
    return '$number';
  }

  int _groupNumber(String group) => int.tryParse(group) ?? 1 << 30;

  String _handleFor(User user, {String? fallback}) {
    final seen = seenUsername(user.id);
    if (seen != null && seen.isNotEmpty) return seen;
    if (user.name.startsWith('@')) return user.name.substring(1);
    return fallback ?? user.name;
  }

  /// Preserves the API's historical `group -> count` response while making
  /// repair and assignment one atomic operation.
  Map<String, int> autoAssignGroups() {
    final preview = previewAutoAssignGroups();
    if (!applyGroupAssignment(preview)) return {};
    final counts = <String, int>{
      for (final group in preview.leaderTargets.values) group: 0,
    };
    for (final member in preview.members.values) {
      counts[member.targetGroup] = (counts[member.targetGroup] ?? 0) + 1;
    }
    return counts;
  }
}
