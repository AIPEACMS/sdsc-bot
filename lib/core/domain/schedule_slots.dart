part of '../models.dart';

class ScheduleSlot {
  final String day; // 'sat' | 'sun' | 'mon' | ... | 'fri'
  final String slot; // stable label, e.g. 's1'
  final String start; // 'HH:MM'
  final String end; // 'HH:MM'
  final String location; // location key
  final int? maxPeople;
  final String? capacityGroup;

  const ScheduleSlot({
    required this.day,
    required this.slot,
    required this.start,
    required this.end,
    required this.location,
    this.maxPeople,
    this.capacityGroup,
  });
}

/// A place sessions happen at. Locations are dynamic: the two built-in ones
/// are seeded, and the console can approve new ones (with aliases) when a
/// global admin requests them from /settime.
