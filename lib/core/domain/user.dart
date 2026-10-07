part of '../models.dart';

class User {
  final int id;
  final String name;
  final Experience experience;
  final String group; // 'A' or 'B'
  final bool isAdmin;
  final bool isGlobalAdmin;
  final int ocbcStreak; // consecutive OCBC sessions attended
  final DateTime? registeredAt;

  final String _fullName;

  /// @deprecated No longer collected; use [preferredName].
  @Deprecated('No longer collected; use preferredName.')
  String get fullName => _fullName;

  String get storedFullName => _fullName;

  /// What the member wants to be called.
  final String preferredName;

  final String _matricNo;

  /// @deprecated No longer collected.
  @Deprecated('No longer collected.')
  String get matricNo => _matricNo;

  String get storedMatricNo => _matricNo;

  final String _schoolEmail;

  /// @deprecated No longer collected.
  @Deprecated('No longer collected.')
  String get schoolEmail => _schoolEmail;

  String get storedSchoolEmail => _schoolEmail;

  /// Stored tier: 'member' | 'check' | 'out-member' | 'old'. Admin and
  /// global-admin are stored flags; console identity is separate.
  final String memberTier;
  final NotificationPreference notificationPreference;
  final LastPromptState lastPromptState;

  const User({
    required this.id,
    required this.name,
    required this.experience,
    required this.group,
    this.isAdmin = false,
    this.isGlobalAdmin = false,
    this.ocbcStreak = 0,
    this.registeredAt,
    String fullName = '',
    this.preferredName = '',
    String matricNo = '',
    String schoolEmail = '',
    this.memberTier = MemberTier.member,
    NotificationPreference? notificationPreference,
    this.lastPromptState = LastPromptState.none,
  }) : notificationPreference = notificationPreference ??
           defaultNotificationPreference(memberTier),
       _fullName = fullName,
       _matricNo = matricNo,
       _schoolEmail = schoolEmail;

  User copyWith({
    String? name,
    Experience? experience,
    String? group,
    bool? isAdmin,
    bool? isGlobalAdmin,
    int? ocbcStreak,
    String? preferredName,
    String? memberTier,
    String? fullName,
    String? matricNo,
    String? schoolEmail,
    DateTime? registeredAt,
    NotificationPreference? notificationPreference,
    LastPromptState? lastPromptState,
  }) {
    return User(
      id: id,
      name: name ?? this.name,
      experience: experience ?? this.experience,
      group: group ?? this.group,
      isAdmin: isAdmin ?? this.isAdmin,
      isGlobalAdmin: isGlobalAdmin ?? this.isGlobalAdmin,
      ocbcStreak: ocbcStreak ?? this.ocbcStreak,
      registeredAt: registeredAt ?? this.registeredAt,
      fullName: fullName ?? _fullName,
      preferredName: preferredName ?? this.preferredName,
      matricNo: matricNo ?? _matricNo,
      schoolEmail: schoolEmail ?? _schoolEmail,
      memberTier: memberTier ?? this.memberTier,
      notificationPreference:
          notificationPreference ?? this.notificationPreference,
      lastPromptState: lastPromptState ?? this.lastPromptState,
    );
  }

  User asMember() => copyWith(memberTier: MemberTier.member);

  User asOutMember() => copyWith(memberTier: MemberTier.outMember);

  User toMember() => asMember();

  User toOutMember() => asOutMember();

  factory User.fromRow(Map<String, Object?> row) => User(
    id: row['id'] as int,
    name: row['name'] as String,
    experience: (row['experience'] as String) == 'experienced'
        ? Experience.experienced
        : Experience.newbie,
    group: row['group_id'] as String,
    isAdmin: (row['is_admin'] as int) == 1,
    isGlobalAdmin: (row['is_global_admin'] as int? ?? 0) == 1,
    ocbcStreak: (row['ocbc_streak'] as int? ?? 0),
    registeredAt: row['created_at'] == null
        ? null
        : DateTime.tryParse(row['created_at'] as String),
    fullName: (row['full_name'] as String?) ?? '',
    preferredName: (row['preferred_name'] as String?) ?? '',
    matricNo: (row['matric_no'] as String?) ?? '',
    schoolEmail: (row['school_email'] as String?) ?? '',
    memberTier: (row['member_tier'] as String?) ?? MemberTier.member,
    notificationPreference: _notificationPreferenceFromRow(row),
    lastPromptState: _lastPromptStateFromRow(row),
  );

  static NotificationPreference _notificationPreferenceFromRow(
    Map<String, Object?> row,
  ) {
    final value = row['notification_preference'] as String?;
    return switch (value) {
      'every-other' || 'every_other' || 'everyOther' =>
        NotificationPreference.everyOther,
      'never' => NotificationPreference.never,
      _ => defaultNotificationPreference(
          (row['member_tier'] as String?) ?? MemberTier.member,
        ),
    };
  }

  static LastPromptState _lastPromptStateFromRow(Map<String, Object?> row) {
    final value = row['last_prompt_state'] as String?;
    return switch (value) {
      'prompted' => LastPromptState.prompted,
      'responded' => LastPromptState.responded,
      _ => LastPromptState.none,
    };
  }
}

/// One session of one weekend, e.g. `0:sat:am:ocbc` = weekend 0, Saturday AM,
/// OCBC. Format: `{weekendIndex}:{day}:{slot}:{location}`, where day is a
/// weekday token and slot/location identify the schedule-template row.
