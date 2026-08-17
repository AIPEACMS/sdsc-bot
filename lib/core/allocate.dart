import 'models.dart';

/// Result of running the allocator: one entry per (user, session).
typedef AllocationResult = List<(int userId, int sessionId)>;

/// Volunteer allocator with no capacity limits.
///
/// Rules:
///  - **Want picks** (the member's commitment) are allocated first — every
///    one of them, one session per time slot (a member can't be in two places
///    at once, so the two locations of the same slot never both get assigned).
///  - Then each member with **available picks** (backup) is allocated to one
///    of them — again one per time slot, never at a time they already hold.
///  - Already-allocated members ([locked]) are never moved: the run only adds
///    new allocations, so nobody is ever un-allocated by a later indication.
class Allocator {
  const Allocator();

  AllocationResult run({
    required List<Session> sessions,
    required List<Availability> availability,
    List<(int userId, int sessionId)> locked = const [],
  }) {
    final result = <(int, int)>[
      for (final (uid, sid) in locked) (uid, sid),
    ];
    final sessionById = {for (final s in sessions) s.id: s};

    Session? sessionFor(String day, String slot, String location) {
      for (final s in sessions) {
        if (s.day == day &&
            s.slot == slot &&
            s.location == Location.values.byName(location)) {
          return s;
        }
      }
      return null;
    }

    // Per (day:slot): members already placed in that time slot (any location).
    final takenBySlot = <String, Set<int>>{};
    Set<int> takenOf(String key) => takenBySlot.putIfAbsent(key, () => {});

    // Locked members occupy their locked session's time slot.
    for (final (uid, sid) in locked) {
      final s = sessionById[sid];
      if (s != null) takenOf('${s.day}:${s.slot}').add(uid);
    }

    void assign(int userId, Session s) {
      result.add((userId, s.id));
      takenOf('${s.day}:${s.slot}').add(userId);
    }

    final open = availability.where((a) => a.available).toList();

    // Pass 1: every want pick, one per time slot.
    for (final av in open) {
      for (final slot in av.wantSlots) {
        if (takenOf('${slot.day}:${slot.slot}').contains(av.userId)) continue;
        final session = sessionFor(slot.day, slot.slot, slot.location);
        if (session == null) continue;
        assign(av.userId, session);
      }
    }

    // Pass 2: one available (backup) session per member, never at a time they
    // already hold.
    for (final av in open) {
      for (final slot in av.slots) {
        if (takenOf('${slot.day}:${slot.slot}').contains(av.userId)) continue;
        final session = sessionFor(slot.day, slot.slot, slot.location);
        if (session == null) continue;
        assign(av.userId, session);
        break; // exactly one available session per member
      }
    }

    return result;
  }
}
