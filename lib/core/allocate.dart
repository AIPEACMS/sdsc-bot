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

    // Group sessions by (weekendIndex, day, slot) so both locations of a slot
    // are allocated together and nobody is allocated to both locations of the
    // same slot.
    final bySlot = <String, List<Session>>{};
    for (final s in sessions) {
      bySlot.putIfAbsent('${s.weekendIndex}:${s.day}:${s.slot}', () => []).add(s);
    }

    Session? firstOf(List<Session> list, Location loc) {
      for (final s in list) {
        if (s.location == loc) return s;
      }
      return null;
    }

    for (final weekendIndex in const [0, 1]) {
      // A member gets at most one session per weekend, so people spread
      // evenly across the two weekends instead of piling into one.
      final taken = <int>{};
      for (final day in Slot.allDays) {
        for (final slot in Slot.allSlots) {
          final key = '$weekendIndex:$day:$slot';
          final slotSessions = bySlot[key];
          if (slotSessions == null) continue;

          final ocbc = firstOf(slotSessions, Location.ocbc);
          final pr = firstOf(slotSessions, Location.pasirRis);
          if (ocbc == null && pr == null) continue;

          // Candidates = members who marked this exact session available and
          // are not yet allocated this weekend.
          List<User> candidatesFor(String loc) {
            final locKey = '$key:$loc';
            final out = <User>[];
            for (final av in availability) {
              if (!av.available) continue;
              if (taken.contains(av.userId)) continue;
              if (!av.slots.any((s) => s.encode() == locKey)) continue;
              final user = users[av.userId];
              if (user != null) out.add(user);
            }
            return out;
          }

          final ocbcCandidates = candidatesFor('ocbc');
          final prCandidates = candidatesFor('pasirRis');

          // Sort: experienced first (prefer OCBC), then by OCBC streak
          // ascending so we do not pile 3-in-a-row onto the same person.
          final ocbcSorted = [...ocbcCandidates]
            ..sort((a, b) {
              final expCompare = _expRank(a).compareTo(_expRank(b));
              if (expCompare != 0) return expCompare;
              return streakOf(a.id).compareTo(streakOf(b.id));
            });

          var ocbcSeats = ocbcCapacity;
          final ocbcTaken = <int>{};

          // Pass 1: OCBC — prefer experienced, skip anyone already at streak 2.
          for (final user in ocbcSorted) {
            if (ocbcSeats == 0) break;
            final streak = streakOf(user.id);
            if (streak >= 2) continue; // would be 3 in a row
            ocbcTaken.add(user.id);
            ocbcSeats--;
          }
          // If OCBC still has seats, relax the streak rule rather than leaving
          // capacity unfilled.
          if (ocbcSeats > 0) {
            for (final user in ocbcSorted) {
              if (ocbcSeats == 0) break;
              if (ocbcTaken.contains(user.id)) continue;
              ocbcTaken.add(user.id);
              ocbcSeats--;
            }
          }

          // Pass 2: PR — everyone who picked PR and is not already on OCBC.
          // Capacity is a soft target: exceeding it is allowed rather than
          // leaving a volunteer unallocated.
          final prTaken = <int>{};
          for (final user in prCandidates) {
            if (!ocbcTaken.contains(user.id)) prTaken.add(user.id);
          }

          if (ocbc != null) {
            for (final uid in ocbcTaken) {
              result.add((uid, ocbc.id));
              taken.add(uid);
              newStreaks[uid] = streakOf(uid) + 1;
            }
          }
          if (pr != null) {
            for (final uid in prTaken) {
              result.add((uid, pr.id));
              taken.add(uid);
              newStreaks[uid] = 0;
            }
          }
        }
      }
    }

    return result;
  }

  static int _expRank(User u) =>
      u.experience == Experience.experienced ? 0 : 1;
}
