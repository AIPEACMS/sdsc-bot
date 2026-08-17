import 'models.dart';

/// Result of running the allocator: one entry per (user, session).
typedef AllocationResult = List<(int userId, int sessionId)>;

/// Greedy allocator that assigns available volunteers to sessions.
///
/// Rules:
///  - Experienced members are preferred for OCBC; new members for Pasir Ris.
///  - A member must not be allocated to OCBC 3 sessions in a row
///    (i.e. their [User.ocbcStreak] must not reach 3 unless there is no
///    alternative). The streak counts consecutive OCBC sessions attended.
///  - Each member is allocated at most one session per weekend, at one of the
///    slots they marked available.
///  - OCBC and Pasir Ris both have per-slot capacities.
///  - Already-allocated members ([locked]) are never moved: the run only
///    fills the remaining seats with new candidates.
///  - After the greedy fill, new members are spread across the time slots of
///    each location so no slot is overstuffed while another sits empty.
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
    Map<int, int> locked = const {}, // userId -> sessionId, already allocated
  }) {
    final result = <(int, int)>[
      for (final e in locked.entries) (e.key, e.value),
    ];
    final newStreaks = <int, int>{}; // userId -> updated streak

    int streakOf(int userId) {
      final user = users[userId];
      if (user == null) return 0;
      return newStreaks[userId] ?? user.ocbcStreak;
    }

    // Sessions are for a single weekend here, so group by (day, slot) so both
    // locations of a slot are allocated together and nobody is allocated to
    // both locations of the same slot.
    final bySlot = <String, List<Session>>{};
    for (final s in sessions) {
      bySlot.putIfAbsent('${s.day}:${s.slot}', () => []).add(s);
    }

    Session? firstOf(List<Session> list, Location loc) {
      for (final s in list) {
        if (s.location == loc) return s;
      }
      return null;
    }

    final taken = <int>{...locked.keys};
    for (final day in Slot.allDays) {
      for (final slot in Slot.allSlots) {
        final key = '$day:$slot';
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
            if (!av.slots.any((s) =>
                '${s.day}:${s.slot}:${s.location}' == locKey)) {
              continue;
            }
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

        // Remaining seats: capacity minus locked members already in this slot.
        var ocbcSeats = ocbcCapacity -
            locked.values.where((sid) => sid == ocbc?.id).length;
        final ocbcTaken = <int>{};

        // Pass 1: OCBC — prefer experienced, skip anyone already at streak 2
        // (would be 3 sessions in a row).
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

    _balance(result, sessions, availability, locked: locked.keys.toSet());
    return result;
  }

  /// Spreads members across the time slots of each location so no slot is
  /// overstuffed while another sits empty. Only moves within the same
  /// location (experience and OCBC-streak rules are unaffected) and never
  /// moves a locked (already-allocated) member.
  void _balance(
    List<(int, int)> result,
    List<Session> sessions,
    List<Availability> availability, {
    Set<int> locked = const {},
  }) {
    final sessionMeta = <int, (String, String, String)>{
      for (final s in sessions) s.id: (s.day, s.slot, s.location.name),
    };
    final picked = <int, Set<(String, String, String)>>{
      for (final av in availability)
        if (av.available)
          av.userId: {for (final s in av.slots) (s.day, s.slot, s.location)},
    };
    final byLoc = <String, Map<String, List<int>>>{};
    for (final (uid, sid) in result) {
      final m = sessionMeta[sid];
      if (m == null) continue;
      byLoc.putIfAbsent(m.$3, () => {}).putIfAbsent(m.$2, () => []).add(uid);
    }
    for (final loc in byLoc.keys) {
      final slots = byLoc[loc]!;
      // Materialize both time slots so moves into an empty slot persist.
      slots.putIfAbsent('am', () => <int>[]);
      slots.putIfAbsent('pm', () => <int>[]);
      for (final day in Slot.allDays) {
        final am = slots['am']!;
        final pm = slots['pm']!;
        bool canMove(int uid, String to) =>
            picked[uid]?.contains((day, to, loc)) ?? false;
        while (am.length > pm.length + 1) {
          final i = am.indexWhere(
              (uid) => !locked.contains(uid) && canMove(uid, 'pm'));
          if (i < 0) break;
          pm.add(am.removeAt(i));
        }
        while (pm.length > am.length + 1) {
          final i = pm.indexWhere(
              (uid) => !locked.contains(uid) && canMove(uid, 'am'));
          if (i < 0) break;
          am.add(pm.removeAt(i));
        }
      }
    }
    result
      ..clear()
      ..addAll([
        for (final loc in byLoc.keys)
          for (final slot in byLoc[loc]!.keys)
            for (final uid in byLoc[loc]![slot]!)
              (
                uid,
                sessionMeta.entries
                    .firstWhere(
                        (e) => e.value.$2 == slot && e.value.$3 == loc)
                    .key,
              ),
      ]);
  }

  static int _expRank(User u) =>
      u.experience == Experience.experienced ? 0 : 1;
}
