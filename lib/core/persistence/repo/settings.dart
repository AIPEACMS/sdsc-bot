part of '../../repo.dart';

extension RepoSettings on Repo {

  /// Promotes a registered user to the singleton global-admin role. A member
  /// gets a group only when they do not already have one; an existing normal
  /// admin keeps their group while its admin flag is cleared.
  GlobalAdminResult appointGlobalAdmin(int id) {
    final tx = raw;
    tx.execute('BEGIN IMMEDIATE');
    try {
      final user = findUser(id);
      if (user == null) {
        tx.execute('ROLLBACK');
        return GlobalAdminResult.noSuchUser;
      }
      if (user.memberTier == MemberTier.outMember) {
        tx.execute('ROLLBACK');
        return GlobalAdminResult.outMember;
      }
      if (globalAdmin() != null) {
        tx.execute('ROLLBACK');
        return GlobalAdminResult.alreadyExists;
      }

      tx.execute(
        'UPDATE users SET is_admin = 0, is_global_admin = 1, '
        'member_tier = ? WHERE id = ?',
        [MemberTier.member, id],
      );
      if (user.group.isEmpty) _assignGroupOnPromotion(id);
      tx.execute('COMMIT');
      return GlobalAdminResult.success;
    } catch (_) {
      tx.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Removes the current global admin and returns them to a regular member,
  /// dissolving their group. The optional id is checked inside the transaction
  /// so a confirmation cannot remove a new global admin after a handoff.
  bool removeGlobalAdmin(int id) {
    final tx = raw;
    tx.execute('BEGIN IMMEDIATE');
    try {
      final user = findUser(id);
      if (user == null || !user.isGlobalAdmin) {
        tx.execute('ROLLBACK');
        return false;
      }
      _dissolveGroup(user.group);
      tx.execute(
        'UPDATE users SET is_global_admin = 0, is_admin = 0, '
        'member_tier = ?, group_id = \'\' WHERE id = ?',
        [MemberTier.member, id],
      );
      tx.execute('COMMIT');
      return true;
    } catch (_) {
      tx.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Sets a user's tier to one of 'admin', 'check', 'member', 'out-member' or
  /// 'old'.
  /// Promotion to admin sets is_admin and hands the new admin their own
  /// group; out-members cannot be promoted. Every other tier clears admin and
  /// dissolves the admin's group.
  /// Console identity is never stored as a member tier; it is derived from
  /// the console id and remains separate from the stored role.
  bool setTier(int id, String tier) {
    if (![MemberTier.admin, MemberTier.check, MemberTier.member,
          MemberTier.outMember, MemberTier.old]
        .contains(tier)) {
      return false;
    }
    final isAdminNext = tier == MemberTier.admin;
    final stored =
        (tier == MemberTier.admin || tier == MemberTier.member)
            ? MemberTier.member
            : tier;
    final user = findUser(id);
    if (user == null || user.isGlobalAdmin) return false;
    if (isAdminNext && user.memberTier == MemberTier.outMember) return false;
    if (isAdminNext && !user.isAdmin) {
      // Promotion: the new admin leads the lowest free group.
      raw.execute(
        'UPDATE users SET member_tier = ?, is_admin = 1 WHERE id = ?',
        [stored, id],
      );
      _assignGroupOnPromotion(id);
    } else if (tier == MemberTier.outMember && user.isAdmin) {
      // An out-member has no group, but converting an admin to out-member must
      // not remove the group assignment from the other users who remain in it.
      raw.execute(
        'UPDATE users SET member_tier = ?, is_admin = 0, group_id = \'\' '
        'WHERE id = ?',
        [stored, id],
      );
    } else if (!isAdminNext && user.isAdmin) {
      // Demotion: the admin's group dissolves with them.
      _dissolveGroup(user.group);
      raw.execute(
        'UPDATE users SET member_tier = ?, is_admin = 0 WHERE id = ?',
        [stored, id],
      );
    } else if (tier == MemberTier.outMember && user.group.isNotEmpty) {
      // An out-member leaves their group without dissolving it for the other
      // members. Admin demotion above is the operation that dissolves a group.
      raw.execute(
        'UPDATE users SET member_tier = ?, is_admin = 0, group_id = \'\' '
        'WHERE id = ?',
        [stored, id],
      );
    } else {
      raw.execute(
        'UPDATE users SET member_tier = ?, is_admin = ? WHERE id = ?',
        [stored, user.isAdmin ? 1 : 0, id],
      );
    }
    return true;
  }

  bool setMember(int id) => setTier(id, MemberTier.member);

  bool setOutMember(int id) => setTier(id, MemberTier.outMember);

  // ------------------------------------------------------------ groups

  /// The smallest group number (as a string) not currently held by any
  /// admin — new admins take the lowest free slot so a disbanded group is
  /// reclaimed instead of skipped.
  String? _lowestFreeGroup() {
    final used = raw
        .select(
          "SELECT DISTINCT group_id FROM users WHERE "
          "(is_admin = 1 OR is_global_admin = 1) AND group_id != ''",
        )
        .map((r) => r['group_id'] as String)
        .toSet();
    var n = 1;
    while (used.contains('$n')) {
      n++;
    }
    return '$n';
  }

  /// Promotion: replaces the user's group with their own admin-led group
  /// (lowest free number). They leave whatever group they were in before.
  void _assignGroupOnPromotion(int id) {
    final group = _lowestFreeGroup();
    if (group != null) {
      raw.execute('UPDATE users SET group_id = ? WHERE id = ?', [group, id]);
    }
  }

  /// Every member of [groupId] (including its admin, if any) loses their
  /// group. Used when an admin is demoted.
  void _dissolveGroup(String groupId) {
    raw.execute(
      "UPDATE users SET group_id = '' WHERE group_id = ?",
      [groupId],
    );
  }

  /// Manual group assignment (the API validates and blocks admins).
  void setGroup(int id, String group) {
    raw.execute('UPDATE users SET group_id = ? WHERE id = ?', [group, id]);
  }

  /// Randomly and evenly assigns members without a group to the admins'
  /// groups. Admins (group leaders) are never assigned; the `check` and
  /// `old` tiers are not members and are never assigned. Returns
  /// groupId -> how many members landed in it.
  Map<String, int> autoAssignGroups() {
    final users = allUsers();
    // Defensive: every admin must hold a group.
    for (final u in users.where((u) => u.isAdmin || u.isGlobalAdmin)) {
      if (u.group.isEmpty) _assignGroupOnPromotion(u.id);
    }
    final leaders = users
        .where((u) => (u.isAdmin || u.isGlobalAdmin) && u.group.isNotEmpty)
        .toList();
    if (leaders.isEmpty) return {};
    final leaderGroups = leaders.map((a) => a.group).toList();
    final candidates = users
        .where((u) =>
            !u.isAdmin &&
            !u.isGlobalAdmin &&
            u.memberTier == MemberTier.member &&
            u.group.isEmpty)
        .toList()
      ..shuffle(Random());
    final counts = {for (final g in leaderGroups) g: 0};
    for (var i = 0; i < candidates.length; i++) {
      final group = leaderGroups[i % leaderGroups.length];
      raw.execute(
        'UPDATE users SET group_id = ? WHERE id = ?',
        [group, candidates[i].id],
      );
      counts[group] = counts[group]! + 1;
    }
    return counts;
  }

  // ------------------------------------------------------------------- holds

  /// Whether the bot is held (all outgoing messages suppressed).
  bool isHeld() {
    final rows = raw.select(
      "SELECT value FROM settings WHERE key = 'hold'",
    );
    return rows.isNotEmpty && rows.first['value'] == '1';
  }

  void setHeld(bool held) {
    raw.execute(
      "INSERT INTO settings (key, value) VALUES ('hold', ?) "
      "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      [held ? '1' : '0'],
    );
  }

  String? getSetting(String key) {
    final rows = raw.select(
      'SELECT value FROM settings WHERE key = ?',
      [key],
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void setSetting(String key, String value) {
    raw.execute(
      "INSERT INTO settings (key, value) VALUES (?, ?) "
      "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      [key, value],
    );
  }

  Map<String, bool> activeOutreach() => {
        for (final key in Repo.activeOutreachRouteKeys)
          key: getSetting('active_outreach_$key') != '0',
      }

;

  bool activeOutreachEnabled(String route) =>
      getSetting('active_outreach_$route') != '0';

  void setActiveOutreach(String route, bool enabled) {
    if (!Repo.activeOutreachRouteKeys.contains(route)) {
      throw ArgumentError.value(route, 'route', 'unknown active outreach route');
    }
    setSetting('active_outreach_$route', enabled ? '1' : '0');
  }

}
