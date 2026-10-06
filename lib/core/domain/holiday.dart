part of '../models.dart';

class Holiday {
  final int id;
  final DateTime weekStart;
  final HolidayKind kind;

  const Holiday({
    required this.id,
    required this.weekStart,
    required this.kind,
  });

  factory Holiday.fromRow(Map<String, Object?> row) => Holiday(
    id: row['id'] as int,
    weekStart: DateTime.parse(row['week_start'] as String),
    kind: HolidayKind.values.byName(row['kind'] as String),
  );
}
