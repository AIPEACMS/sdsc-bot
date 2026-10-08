import 'dart:convert';

import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'calendar.dart';
import 'config.dart';
import 'db.dart';
import 'models.dart';
import 'week.dart';

part 'persistence/repo/users.dart';
part 'persistence/repo/settings.dart';
part 'persistence/repo/locations.dart';
part 'persistence/repo/sessions.dart';
part 'persistence/repo/availability.dart';
part 'persistence/repo/attendance.dart';
part 'persistence/repo/holidays.dart';
part 'persistence/repo/groups.dart';

/// A registered Ed25519 public key that the desktop console app uses to sign
/// admin API requests. The value is the base64 of the raw 32-byte key.
class ConsoleKey {
  final String pubkey;
  final String name;
  final String createdAt;
  const ConsoleKey({
    required this.pubkey,
    required this.name,
    required this.createdAt,
  });
}

enum GlobalAdminResult {
  success,
  noSuchUser,
  alreadyExists,
  outMember,
}

enum UserRemovalFailure { none, notFound, protectedAdmin }

/// The result of an all-or-nothing handle removal operation.
class UserRemovalResult {
  final UserRemovalFailure failure;
  final String? failedHandle;
  final List<String> removedHandles;

  const UserRemovalResult.success(this.removedHandles)
      : failure = UserRemovalFailure.none,
        failedHandle = null;

  const UserRemovalResult.failure(this.failure, this.failedHandle)
      : removedHandles = const [];

  bool get succeeded => failure == UserRemovalFailure.none;
}

/// Data access layer over SQLite. All dates are stored as ISO-8601 strings in
/// the bot's local timezone (UTC+8).

class _RepoBase {
  _RepoBase(this._db);

  final Database _db;
}

class Repo extends _RepoBase {
  static const activeOutreachRouteKeys = defaultActiveOutreachRouteKeys;

  Repo(Database db) : super(db);
}
