import 'dart:convert';

import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'config.dart';
import 'models.dart';
import 'week.dart';

const defaultActiveOutreachRouteKeys = [
  'prompt',
  'reminder',
  'schedule-change',
  'allocation',
  'checker',
  'attendance',
  'absence',
  'ask',
  'broadcast',
];

part 'persistence/schema.dart';
part 'persistence/migrations.dart';
part 'persistence/seeds.dart';

class Database with _Database1, _Database2, _Database3 {

  Database._(this._db);

  final sqlite.Database _db;

  /// Opens (creating if needed) the SQLite database and applies the schema.
  factory Database.open(Config config) {
    final db = sqlite.sqlite3.open(config.dbPath);
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute('PRAGMA journal_mode = WAL;');
    _applySchema(db, config);
    return Database._(db);
  }

  static void _applySchema(sqlite.Database db, Config config) =>
      _Database2._applySchema(db, config);
}
