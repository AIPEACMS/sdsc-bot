part of '../models.dart';

enum HolidayKind { middle, winter, summer }

/// Member tiers, in display/sort order: console > gadmin > admin > check >
/// member > out-member > old. `console` is a separate identity derived from
/// the configured console id; `gadmin` and `admin` are stored flags; the
/// remaining tiers are stored in [User.memberTier].
