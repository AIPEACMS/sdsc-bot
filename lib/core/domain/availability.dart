part of '../models.dart';

class Availability {
  final DateTime weekendStart; // the Saturday of the covered weekend
  final int userId;

  /// The Saturday of the bundle's first weekend — the prompt this response
  /// answers. The quiet rule ("not bothered for 2 weeks") keys off this.
  final DateTime bundleStart;

  /// Sessions the member can attend if needed (backup).
  final Set<Slot> slots;

  /// Sessions the member explicitly wants to attend (commitment). The
  /// allocator fills these first.
  final Set<Slot> wantSlots;
  final bool available; // false = explicitly not available for the weekend
  final DateTime updatedAt;

  const Availability({
    required this.weekendStart,
    required this.userId,
    required this.bundleStart,
    required this.slots,
    this.wantSlots = const {},
    required this.available,
    required this.updatedAt,
  });
}
