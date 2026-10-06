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

class _DatabaseBase {

  _DatabaseBase._(this._db);

  final sqlite.Database _db;

  static void _applySchema(sqlite.Database db, Config config) =>
      DatabaseMigrations._applySchema(db, config);
}

class Database extends _DatabaseBase {
  Database._(sqlite.Database db) : super._(db);

  factory Database.open(Config config) {
    final db = sqlite.sqlite3.open(config.dbPath);
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute('PRAGMA journal_mode = WAL;');
    _DatabaseBase._applySchema(db, config);
    return Database._(db);
  }
}
