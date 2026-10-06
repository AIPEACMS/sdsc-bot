part of '../../repo.dart';

mixin _Repo1 on _RepoBase {

  sqlite.Database get raw => _db.raw;

  // -------------------------------------------------------- console keys

  List<ConsoleKey> listConsoleKeys() {
    return [
      for (final row
          in raw.select('SELECT * FROM console_keys ORDER BY id'))
        ConsoleKey(
          pubkey: row['pubkey'] as String,
          name: row['name'] as String,
          createdAt: row['created_at'] as String,
        ),
    ];
  }

  bool hasConsoleKey(String pubkey) =>
      raw.select(
        'SELECT 1 FROM console_keys WHERE pubkey = ? LIMIT 1',
        [pubkey],
      ).isNotEmpty;

  void addConsoleKey(String pubkey, {String name = ''}) {
    raw.execute(
      'INSERT OR IGNORE INTO console_keys (pubkey, name) VALUES (?, ?)',
      [pubkey, name],
    );
  }

  bool removeConsoleKey(String pubkey) {
    if (!hasConsoleKey(pubkey)) return false;
    raw.execute(
      'DELETE FROM console_keys WHERE pubkey = ?',
      [pubkey],
    );
    return true;
  }

  // ---------------------------------------------------------------- users

  int? getUser(int id) {
    final rows = raw.select(
      'SELECT * FROM users WHERE id = ?',
      [id],
    );
    return rows.isEmpty ? null : User.fromRow(rows.first).id;
  }

  User? findUser(int id) {
    final rows = raw.select(
      'SELECT * FROM users WHERE id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    return User.fromRow(rows.first);
  }

  List<User> allUsers() =>
      raw.select('SELECT * FROM users ORDER BY name').map(User.fromRow).toList();

  /// Users who take part in availability, allocation and messaging. Checkers
  /// and old users are excluded; out-members follow the member flow.
  List<User> activeUsers() => raw
      .select(
        "SELECT * FROM users WHERE member_tier NOT IN ('check', 'old') "
        'ORDER BY name',
      )
      .map(User.fromRow)
      .toList();

  User upsertUser(User user) {
    final columns = [
      'id',
      'name',
      'experience',
      'group_id',
      'is_admin',
      'is_global_admin',
      'ocbc_streak',
      'full_name',
      'preferred_name',
      'matric_no',
      'school_email',
      'member_tier',
      'notification_preference',
      'last_prompt_state',
    ];
    final values = <Object?>[
      user.id,
      user.name,
      user.experience.name,
      user.group,
      user.isAdmin ? 1 : 0,
      user.isGlobalAdmin ? 1 : 0,
      user.ocbcStreak,
      user.storedFullName,
      user.preferredName,
      user.storedMatricNo,
      user.storedSchoolEmail,
      _storedTier(user.memberTier),
      _notificationPreferenceValue(user.notificationPreference),
      user.lastPromptState.name,
    ];
    if (user.registeredAt != null) {
      columns.add('created_at');
      values.add(user.registeredAt!.toIso8601String());
    }
    final placeholders = List.filled(columns.length, '?').join(', ');
    raw.execute(
      '''
 INSERT INTO users (${columns.join(', ')})
 VALUES ($placeholders)
 ON CONFLICT(id) DO UPDATE SET
   name = excluded.name,
   experience = excluded.experience,
   group_id = excluded.group_id,
   is_admin = excluded.is_admin,
   ocbc_streak = excluded.ocbc_streak,
   full_name = excluded.full_name,
   preferred_name = excluded.preferred_name,
   matric_no = excluded.matric_no,
   school_email = excluded.school_email,
   member_tier = excluded.member_tier,
   notification_preference = excluded.notification_preference,
   last_prompt_state = excluded.last_prompt_state
 ''',
      values,
    );
    return findUser(user.id)!;
  }

  void updateExperience(int id, Experience experience) {
    raw.execute(
      'UPDATE users SET experience = ? WHERE id = ?',
      [experience.name, id],
    );
  }

  void updateGroup(int id, String group) {
    raw.execute(
      'UPDATE users SET group_id = ? WHERE id = ?',
      [group, id],
    );
  }

  void updateName(int id, String name) {
    raw.execute('UPDATE users SET name = ? WHERE id = ?', [name, id]);
  }

  /// Updates the name a member wants to be called.
  void updatePreferredName(int id, String preferredName) {
    raw.execute(
      'UPDATE users SET preferred_name = ? WHERE id = ?',
      [preferredName, id],
    );
  }

  /// @deprecated Use [updatePreferredName].
  @Deprecated('Use updatePreferredName.')
  void updateProfileInfo(
    int id, {
    String? fullName,
    String? preferredName,
    String? matricNo,
    String? schoolEmail,
  }) {
    final sets = <String>[];
    final args = <Object>[];
    if (fullName != null) {
      sets.add('full_name = ?');
      args.add(fullName);
    }
    if (preferredName != null) {
      sets.add('preferred_name = ?');
      args.add(preferredName);
    }
    if (matricNo != null) {
      sets.add('matric_no = ?');
      args.add(matricNo);
    }
    if (schoolEmail != null) {
      sets.add('school_email = ?');
      args.add(schoolEmail);
    }
    if (sets.isEmpty) return;
    args.add(id);
    raw.execute('UPDATE users SET ${sets.join(', ')} WHERE id = ?', args);
  }

  void setOcbcStreak(int id, int streak) {
    raw.execute(
      'UPDATE users SET ocbc_streak = ? WHERE id = ?',
      [streak, id],
    );
  }

  void setNotificationPreference(int id, NotificationPreference preference) {
    raw.execute(
      'UPDATE users SET notification_preference = ? WHERE id = ?',
      [_notificationPreferenceValue(preference), id],
    );
  }

  void setLastPromptState(int id, LastPromptState state) {
    raw.execute(
      'UPDATE users SET last_prompt_state = ? WHERE id = ?',
      [state.name, id],
    );
  }

  /// Grants or strips the normal-admin flag. Out-members cannot be promoted.
  /// Promotion automatically gives the new admin their own group (the lowest
  /// free group number); demotion dissolves their group — every member
  /// (including the demoted admin) loses their group until reassigned.
  bool updateAdmin(int id, bool isAdmin) {
    final user = findUser(id);
    if (user == null || user.isGlobalAdmin) return false;
    if (isAdmin && user.memberTier == MemberTier.outMember) return false;
    if (isAdmin) {
      raw.execute('UPDATE users SET is_admin = 1 WHERE id = ?', [id]);
      _assignGroupOnPromotion(id);
    } else {
      raw.execute('UPDATE users SET is_admin = 0 WHERE id = ?', [id]);
      _dissolveGroup(user.group);
    }
    return true;
  }

  /// Demotes a normal admin to a regular active member and dissolves their
  /// group. This is the explicit Telegram `/demote` operation.
  bool demoteAdmin(int id) {
    final user = findUser(id);
    if (user == null || !user.isAdmin || user.isGlobalAdmin) return false;
    final tx = raw;
    tx.execute('BEGIN IMMEDIATE');
    try {
      _dissolveGroup(user.group);
      tx.execute(
        'UPDATE users SET is_admin = 0, member_tier = ?, group_id = \'\' '
        'WHERE id = ?',
        [MemberTier.member, id],
      );
      tx.execute('COMMIT');
      return true;
    } catch (_) {
      tx.execute('ROLLBACK');
      rethrow;
    }
  }

  User? globalAdmin() {
    final rows = raw.select(
      'SELECT * FROM users WHERE is_global_admin = 1 LIMIT 1',
    );
    return rows.isEmpty ? null : User.fromRow(rows.first);
  }

}
