import '../models.dart';

/// Capacity is shared by grouped sessions only within the same weekend.
String capacityKey(Session session) {
  final weekend = '${session.weekendStart.year}-'
      '${session.weekendStart.month.toString().padLeft(2, '0')}-'
      '${session.weekendStart.day.toString().padLeft(2, '0')}';
  return '$weekend:${session.capacityGroup ?? 'session:${session.id}'}';
}
