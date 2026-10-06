part of '../models.dart';

class PendingRole {
  final bool isAdmin;
  final String tier;
  final NotificationPreference notificationPreference;

  const PendingRole({
    required this.isAdmin,
    required this.tier,
    this.notificationPreference = NotificationPreference.weekly,
  });

  String get effectiveTier => isAdmin ? MemberTier.admin : tier;
}
