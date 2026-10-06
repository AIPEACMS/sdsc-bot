part of '../models.dart';

class Attendance {
  final int userId;
  final int sessionId;

  /// true = present, false = not participated (a deliberate negative mark).
  final bool attended;
  final DateTime confirmedAt;

  const Attendance({
    required this.userId,
    required this.sessionId,
    required this.attended,
    required this.confirmedAt,
  });
}

/// A holiday week flagged by the admin. `weekStart` is the Monday of the week.
