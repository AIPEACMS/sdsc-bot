part of '../models.dart';

class MemberTier {
  static const String console = 'console';
  static const String globalAdmin = 'gadmin';
  static const String admin = 'admin';
  static const String check = 'check';
  static const String member = 'member';
  static const String outMember = 'out-member';
  static const String old = 'old';

  /// Display/sort order: first defined = top.
  static const List<String> order = [
    console,
    globalAdmin,
    admin,
    check,
    member,
    outMember,
    old,
  ];

  static const List<String> stored = [check, member, outMember, old];

  /// The stored role of [user]. Console identity is orthogonal to this role,
  /// so [isConsole] does not replace an admin or member tier. Callers that
  /// need a console group should add [console] separately.
  static String of(User user, {required bool isConsole}) {
    if (user.isGlobalAdmin) return globalAdmin;
    if (user.isAdmin) return admin;
    return user.memberTier;
  }

  /// True when the user takes part in availability/allocation/messaging.
  /// Out-members use the same flow as regular members; only checkers and old
  /// members are inactive.
  static bool isActive(String tier) => tier != check && tier != old;

  static bool isStored(String tier) => stored.contains(tier);
}
