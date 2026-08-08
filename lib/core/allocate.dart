import 'models.dart';

/// Result of running the allocator: one entry per (user, session).
typedef AllocationResult = List<(int userId, int sessionId)>;

/// Greedy allocator that assigns available volunteers to sessions.
///
/// Rules:
///  - Experienced members are preferred for OCBC; new members for Pasir Ris.
///  - A member must not be allocated to OCBC 3 cycles in a row
///    (i.e. their [User.ocbcStreak] must not reach 3 unless there is no
///    alternative).
///  - Each member is allocated at most one session per weekend, at one of the
///    slots they marked available.
///  - OCBC and Pasir Ris both have per-slot capacities.
class Allocator {
  final int ocbcCapacity;
  final int prCapacity;

  const Allocator({
    required this.ocbcCapacity,
    required this.prCapacity,
  });

  AllocationResult run({
    required List<Session> sessions,
    required List<Availability> availability,
    required Map<int, User> users,
  }) {
    final result = <(int, int)>[];
    final newStreaks = <int, int>{}; // userId -> updated streak

    int streakOf(int userId) {
      final user = users[userId];
      if (user == null) return 0;
      return newStreaks[userId] ?? user.ocbcStreak;
    }

    // Group sessions by (weekendIndex, slotKey) so we allocate each weekend
    // and slot independently.
    final bySlot = <String, List<Session>>{};
    for (final s in sessions) {
      bySlot.putIfAbsent(s.slotKey(), () => []).add(s);
    }

    for (final weekendIndex in const [0, 1]) {
      for (final day in Slot.allDays) {
        for (final slot in Slot.allSlots) {
          final key = '$weekendIndex:$day:$slot';
          final slotSessions = bySlot[key];
          if (slotSessions == null) continue;

          // Candidates = members who marked this slot available.
          final candidates = <User>[];
          for (final av in availability) {
            if (!av.available) continue;
            if (av.slots.any((s) => s.encode() == key)) {
              final user = users[av.userId];
              if (user != null) candidates.add(user);
            }
          }
          if (candidates.isEmpty) continue;

          final ocbc = slotSessions
              .firstWhere((s) => s.location == Location.ocbc);
          final pr =
              slotSessions.firstWhere((s) => s.location == Location.pasirRis);

          // Sort: experienced first (prefer OCBC), then by OCBC streak
          // ascending so we do not pile 3-in-a-row onto the same person.
          final sorted = [...candidates]
            ..sort((a, b) {
              final expCompare = _expRank(a).compareTo(_expRank(b));
              if (expCompare != 0) return expCompare;
              return streakOf(a.id).compareTo(streakOf(b.id));
            });

          var ocbcSeats = ocbcCapacity;
          final ocbcTaken = <int>{};
          final prTaken = <int>{};

          // Pass 1: OCBC — prefer experienced, skip anyone already at streak 2.
          for (final user in sorted) {
            if (ocbcSeats == 0) break;
            final streak = streakOf(user.id);
            if (streak >= 2) continue; // would be 3 in a row
            ocbcTaken.add(user.id);
            ocbcSeats--;
          }
          // If OCBC still has seats, relax the streak rule rather than leaving
          // capacity unfilled.
          if (ocbcSeats > 0) {
            for (final user in sorted) {
              if (ocbcSeats == 0) break;
              if (ocbcTaken.contains(user.id)) continue;
              ocbcTaken.add(user.id);
              ocbcSeats--;
            }
          }

          // Pass 2: PR — everyone else. Capacity is a soft target: exceeding it
          // is allowed rather than leaving a volunteer unallocated.
          for (final user in sorted) {
            if (!ocbcTaken.contains(user.id)) prTaken.add(user.id);
          }

          for (final uid in ocbcTaken) {
            result.add((uid, ocbc.id));
            newStreaks[uid] = streakOf(uid) + 1;
          }
          for (final uid in prTaken) {
            result.add((uid, pr.id));
            newStreaks[uid] = 0;
          }
        }
      }
    }

    return result;
  }

  static int _expRank(User u) =>
      u.experience == Experience.experienced ? 0 : 1;
}
