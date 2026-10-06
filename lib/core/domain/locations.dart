part of '../models.dart';

class Locations {
  static const String ocbc = 'ocbc';
  static const String pasirRis = 'pasirRis';
}

/// One row of the activity-schedule template: a session that recurs on [day]
/// from [start] to [end] ('HH:MM') at the location [location] (a location
/// key). [slot] groups rows that share the same time window (like the old
/// AM/PM slots) so availability picks stay stable across sessions.
