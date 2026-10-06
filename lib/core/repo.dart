import 'dart:convert';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'calendar.dart';
import 'config.dart';
import 'db.dart';
import 'models.dart';
import 'week.dart';

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

/// Data access layer over SQLite. All dates are stored as ISO-8601 strings in
/// the bot's local timezone (UTC+8).

part 'persistence/repo/users.dart';
part 'persistence/repo/settings.dart';
part 'persistence/repo/locations.dart';
part 'persistence/repo/sessions.dart';
part 'persistence/repo/availability.dart';
part 'persistence/repo/attendance.dart';
part 'persistence/repo/holidays.dart';

class Repo with _Repo1, _Repo2, _Repo3, _Repo4, _Repo5, _Repo6, _Repo7 {

  static const activeOutreachRouteKeys = defaultActiveOutreachRouteKeys;

  Repo(this._db);

  final Database _db;
}
