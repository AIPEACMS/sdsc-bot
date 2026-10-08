part of '../models.dart';

class GroupAssignmentMember {
  final int id;
  final String handle;
  final String expectedGroup;
  final String targetGroup;
  final String expectedTier;
  final bool expectedAdmin;
  final bool expectedGlobalAdmin;

  const GroupAssignmentMember({
    required this.id,
    required this.handle,
    required this.expectedGroup,
    required this.targetGroup,
    required this.expectedTier,
    required this.expectedAdmin,
    required this.expectedGlobalAdmin,
  });
}

/// A complete, immutable assignment decision. It contains the state observed
/// while building the preview so applying it can reject a stale confirmation.
class GroupAssignmentPreview {
  static const timeout = Duration(minutes: 10);

  final Map<int, String> leaderExpectedGroups;
  final Map<int, String> leaderTargets;
  final Map<int, GroupAssignmentMember> members;
  final DateTime createdAt;

  GroupAssignmentPreview({
    required Map<int, String> leaderExpectedGroups,
    required Map<int, String> leaderTargets,
    required Map<int, GroupAssignmentMember> members,
    DateTime? createdAt,
  }) : leaderExpectedGroups = Map.unmodifiable(leaderExpectedGroups),
       leaderTargets = Map.unmodifiable(leaderTargets),
       members = Map.unmodifiable(members),
       createdAt = createdAt ?? DateTime.now();

  bool get isExpired => DateTime.now().difference(createdAt) > timeout;

  Map<String, List<GroupAssignmentMember>> get membersByGroup {
    final result = <String, List<GroupAssignmentMember>>{};
    for (final member in members.values) {
      result.putIfAbsent(member.targetGroup, () => []).add(member);
    }
    for (final members in result.values) {
      members.sort((a, b) => a.id.compareTo(b.id));
    }
    return result;
  }
}

class GroupAssignmentValidation {
  final GroupAssignmentPreview? preview;
  final List<String> skipped;

  const GroupAssignmentValidation({
    required this.preview,
    required this.skipped,
  });
}
