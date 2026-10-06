part of '../db.dart';

extension DatabaseSchema on Database {

  sqlite.Database get raw => _db;

}
