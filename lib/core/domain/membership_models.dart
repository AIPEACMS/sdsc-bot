part of '../models.dart';

enum NotificationPreference { weekly, everyOther, never }

NotificationPreference defaultNotificationPreference(String tier) =>
    tier == MemberTier.outMember
        ? NotificationPreference.never
        : NotificationPreference.weekly;
