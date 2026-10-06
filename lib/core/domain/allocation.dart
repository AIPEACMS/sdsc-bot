part of '../models.dart';

class Allocation {
  final int id;
  final int userId;
  final int sessionId;

  const Allocation({
    required this.id,
    required this.userId,
    required this.sessionId,
  });
}
