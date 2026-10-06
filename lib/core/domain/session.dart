part of '../models.dart';

class Session {
  final int id;

  /// The Saturday date of the session's weekend (the bundle anchor).
  final DateTime weekendStart;
  final String day; // 'sat' | 'sun' | 'mon' | ... (from the template)
  final String slot; // template row label, e.g. 's1'
  final String location; // location key
  final DateTime start; // actual date+time
  final DateTime end;
  final int? maxPeople;
  final String? capacityGroup;

  const Session({
    required this.id,
    required this.weekendStart,
    required this.day,
    required this.slot,
    required this.location,
    required this.start,
    required this.end,
    this.maxPeople,
    this.capacityGroup,
  });

  String slotKey() => '$day:$slot';

  /// Whether this session and [other] need the same person at the same time
  /// (same weekend, overlapping interval). Replaces the old "one pick per
  /// AM/PM slot" rule now that times are free-form.
  bool overlaps(Session other) =>
      weekendStart == other.weekendStart &&
      start.isBefore(other.end) &&
      other.start.isBefore(end);

  factory Session.fromRow(Map<String, Object?> row) => Session(
    id: row['id'] as int,
    weekendStart: DateTime.parse(row['weekend_start'] as String),
    day: row['day'] as String,
    slot: row['slot'] as String,
    location: row['location'] as String,
    start: DateTime.parse(row['start_at'] as String),
    end: DateTime.parse(row['end_at'] as String),
    maxPeople: row['max_people'] as int?,
    capacityGroup: row['capacity_group'] as String?,
  );
}

/// A user's availability for one weekend of a bundle.
