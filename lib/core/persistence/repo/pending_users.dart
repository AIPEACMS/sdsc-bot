part of '../../repo.dart';

extension RepoPendingUsers on Repo {
  /// Pending registrations in handle order. A handle that has since become a
  /// registered user is omitted without mutating the pending row.
  List<PendingUser> pendingUsers() {
    final rows = raw.select(
      'SELECT username, is_admin, tier, notification_preference '
      'FROM pending_users ORDER BY lower(username), username',
    );
    final result = <PendingUser>[];
    for (final row in rows) {
      final username = row['username'] as String;
      if (findUserByHandle(username) != null) continue;
      final preference = switch (row['notification_preference'] as String?) {
        'every-other' ||
        'every_other' ||
        'everyOther' => NotificationPreference.everyOther,
        'never' => NotificationPreference.never,
        _ => NotificationPreference.weekly,
      };
      result.add(
        PendingUser(
          username: username,
          role: PendingRole(
            isAdmin: (row['is_admin'] as int) == 1,
            tier: row['tier'] as String? ?? MemberTier.member,
            notificationPreference: preference,
          ),
        ),
      );
    }
    return result;
  }
}
