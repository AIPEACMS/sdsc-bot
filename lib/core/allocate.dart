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
///    of them across all supplied availability rows, never at a time they
///    already hold. Experienced members prefer OCBC; new members prefer Pasir
///    Ris. An OCBC streak of two or more makes Pasir Ris the preference.
///  - Already-allocated members ([locked]) are never moved: the run only adds
///    new allocations, so nobody is ever un-allocated by a later indication.
class Allocator {
  const Allocator();

  AllocationResult run({
    required List<Session> sessions,
    required List<Availability> availability,
    Map<int, User> users = const {},
    List<(int userId, int sessionId)> locked = const [],
    Set<int> lockedBackupUserIds = const {},
  }) {
    final result = <(int, int)>[
      for (final (uid, sid) in locked) (uid, sid),
    ];
    final sessionById = {for (final s in sessions) s.id: s};

    Session? sessionFor(Availability availability, Slot slot) {
      for (final s in sessions) {
        if (s.weekendStart == availability.weekendStart &&
            s.day == slot.day &&
            s.slot == slot.slot &&
            s.location == Location.values.byName(slot.location)) {
          return s;
        }
      }
      return null;
    }

    // Per (weekend, day, slot): members already placed in that time slot (any
    // location). The two bundle weekends have independent schedules.
    final takenBySlot = <String, Set<int>>{};
    String slotKey(DateTime weekendStart, String day, String slot) =>
        '${weekendStart.toIso8601String()}:$day:$slot';
    Set<int> takenOf(String key) => takenBySlot.putIfAbsent(key, () => {});

    // Locked members occupy their locked session's time slot.
    for (final (uid, sid) in locked) {
      final s = sessionById[sid];
      if (s != null) takenOf(slotKey(s.weekendStart, s.day, s.slot)).add(uid);
    }

    void assign(int userId, Session s) {
      result.add((userId, s.id));
      takenOf(slotKey(s.weekendStart, s.day, s.slot)).add(userId);
    }

    final open = availability.where((a) => a.available).toList();

    // Pass 1: every want pick, one per time slot.
    for (final av in open) {
      for (final slot in av.wantSlots) {
        final session = sessionFor(av, slot);
        if (session == null) continue;
        if (takenOf(slotKey(session.weekendStart, session.day, session.slot))
            .contains(av.userId)) {
          continue;
        }
        assign(av.userId, session);
      }
    }

    // Pass 2: collect all available (backup) candidates first so preference
    // ranking can choose across both availability rows. A retained backup
    // allocation from an earlier dynamic run counts as that member's one
    // backup.
    final backupAssigned = {...lockedBackupUserIds};
    final backupCandidates = <int, List<Session>>{};
    for (final av in open) {
      if (backupAssigned.contains(av.userId)) continue;
      for (final slot in av.slots) {
        final session = sessionFor(av, slot);
        if (session == null) continue;
        if (takenOf(slotKey(session.weekendStart, session.day, session.slot))
            .contains(av.userId)) {
          continue;
        }
        backupCandidates.putIfAbsent(av.userId, () => []).add(session);
      }
    }

    // Choose one backup per member. This is the only pass where experience
    // and OCBC rotation affect location; booked picks above remain exact.
    for (final entry in backupCandidates.entries) {
      final user = users[entry.key];
      if (user != null) {
        final preferredLocation = user.ocbcStreak >= 2 ||
                user.experience == Experience.newbie
            ? Location.pasirRis
            : Location.ocbc;
        entry.value.sort((a, b) {
          final locationOrder = (a.location == preferredLocation ? 0 : 1)
              .compareTo(b.location == preferredLocation ? 0 : 1);
          if (locationOrder != 0) return locationOrder;
          final timeOrder = a.start.compareTo(b.start);
          if (timeOrder != 0) return timeOrder;
          return a.id.compareTo(b.id);
        });
      }
      assign(entry.key, entry.value.first);
      backupAssigned.add(entry.key);
    }

    return result;
  }
}
