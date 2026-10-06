part of '../../repo.dart';

extension RepoAvailability on Repo {

  /// Deletes and recreates [sat]'s sessions from [template]. Destructive:
  /// callers must also clear availability/allocations for the weekend (see
  /// [clearWeekendAvailabilityAndAllocations]).
  void replaceSessionsForWeekend(
    DateTime sat,
    List<ScheduleSlot> template, {
    required int tzOffsetHours,
  }) {
    final tx = raw;
    tx.execute('BEGIN IMMEDIATE');
    try {
      tx.execute('DELETE FROM sessions WHERE weekend_start = ?', [this._dayKey(sat)]);
      tx.execute('COMMIT');
    } catch (_) {
      tx.execute('ROLLBACK');
      rethrow;
    }
    ensureSessionsForWeekend(sat, template, tzOffsetHours: tzOffsetHours);
  }

  /// Drops availability and allocations for [sat]'s weekend (used when the
  /// schedule changes on an open weekend, so members re-pick).
  void clearWeekendAvailabilityAndAllocations(DateTime sat) {
    final tx = raw;
    tx.execute('BEGIN IMMEDIATE');
    try {
      tx.execute('DELETE FROM allocations WHERE session_id IN '
          '(SELECT id FROM sessions WHERE weekend_start = ?)', [this._dayKey(sat)]);
      tx.execute('DELETE FROM availability WHERE weekend_start = ?',
          [this._dayKey(sat)]);
      tx.execute('COMMIT');
    } catch (_) {
      tx.execute('ROLLBACK');
      rethrow;
    }
  }

  /// The date of the template-day [day] inside [sat]'s bundled weekend
  /// (Saturday → Friday), or null for an unknown token.
  DateTime? _sessionDate(DateTime sat, String day) {
    final offset = Slot.allDays.indexOf(day);
    if (offset < 0) return null;
    return sat.add(Duration(days: offset));
  }

  /// Sessions of one weekend that belong to the current schedule template,
  /// ordered by day and start time. Rows left over from an older schedule
  /// (e.g. the Saturday-only or fixed-AM/PM models) are hidden and removed by
  /// the schema cleanup, so a template change can never resurrect them.
  List<Session> sessionsForWeekend(DateTime sat) => raw
      .select(
        '''
SELECT s.* FROM sessions s
WHERE s.weekend_start = ?
  AND (
    EXISTS (
      SELECT 1 FROM schedule_template t
      WHERE t.day = s.day AND t.slot = s.slot
        AND t.location_key = s.location
    ) OR EXISTS (
      SELECT 1 FROM schedule_overrides o
      WHERE o.weekend_start = s.weekend_start
        AND o.day = s.day AND o.slot = s.slot
        AND o.location_key = s.location
    )
  )
ORDER BY s.start_at
''',
        [this._dayKey(sat)],
      )
      .map(Session.fromRow)
      .toList();

  /// Sessions of the window's two weekends (current + next).
  List<Session> windowSessions(RollingWindow w) =>
      [...sessionsForWeekend(w.sat0), ...sessionsForWeekend(w.sat1)];

  Session? sessionById(int id) {
    final rows = raw.select('SELECT * FROM sessions WHERE id = ?', [id]);
    return rows.isEmpty ? null : Session.fromRow(rows.first);
  }

  // ----------------------------------------------------------- availability

  void setAvailability(Availability a) {
    raw.execute(
      '''
INSERT INTO availability (weekend_start, user_id, bundle_start, slots, want_slots, available, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(weekend_start, user_id) DO UPDATE SET
  bundle_start = excluded.bundle_start,
  slots = excluded.slots,
  want_slots = excluded.want_slots,
  available = excluded.available,
  updated_at = excluded.updated_at
''',
      [
        this._dayKey(a.weekendStart),
        a.userId,
        this._dayKey(a.bundleStart),
        jsonEncode(a.slots.map((s) => s.encode()).toList()),
        jsonEncode(a.wantSlots.map((s) => s.encode()).toList()),
        a.available ? 1 : 0,
        this._fmt(a.updatedAt),
      ],
    );
  }

  Availability? getAvailability(DateTime weekendStart, int userId) {
    final rows = raw.select(
      'SELECT * FROM availability WHERE weekend_start = ? AND user_id = ?',
      [this._dayKey(weekendStart), userId],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return Availability(
      weekendStart: weekendStart,
      userId: userId,
      bundleStart: DateTime.parse(r['bundle_start'] as String),
      slots: Slot.decodeSet(r['slots'] as String),
      wantSlots: Slot.decodeSet(r['want_slots'] as String),
      available: (r['available'] as int) == 1,
      updatedAt: DateTime.parse(r['updated_at'] as String),
    );
  }

  List<Availability> availabilityForWeekend(DateTime weekendStart) {
    final rows = raw.select(
      'SELECT * FROM availability WHERE weekend_start = ?',
      [this._dayKey(weekendStart)],
    );
    return rows
        .map((r) => Availability(
              weekendStart: weekendStart,
              userId: r['user_id'] as int,
              bundleStart: DateTime.parse(r['bundle_start'] as String),
              slots: Slot.decodeSet(r['slots'] as String),
              wantSlots: Slot.decodeSet(r['want_slots'] as String),
              available: (r['available'] as int) == 1,
              updatedAt: DateTime.parse(r['updated_at'] as String),
            ))
        .toList();
  }

  /// Whether [user] already answered the bundle starting [bundleStart].
  bool hasBundleResponse(DateTime bundleStart, int userId) {
    final rows = raw.select(
      'SELECT 1 FROM availability WHERE bundle_start = ? AND user_id = ? '
      'LIMIT 1',
      [this._dayKey(bundleStart), userId],
    );
    return rows.isNotEmpty;
  }

  /// The most recent bundle (Saturday) [user] answered, if any.
  DateTime? lastBundleStart(int userId) {
    final rows = raw.select(
      'SELECT MAX(bundle_start) AS b FROM availability WHERE user_id = ?',
      [userId],
    );
    final b = rows.first['b'] as String?;
    return b == null ? null : DateTime.parse(b);
  }

  /// Quiet rule: [user] answered a bundle within the last 14 days relative to
  /// [bundleStart] — they are not bothered for 2 weeks in a row.
  bool isQuiet(int userId, DateTime bundleStart) {
    final last = lastBundleStart(userId);
    return last != null && bundleStart.difference(last).inDays < 14;
  }

  /// Active users to prompt for the bundle: members, out-members and admins
  /// (not check/old), excluding anyone who already answered. Quiet users remain
  /// in this list so the service can advance every-other notification state
  /// during the skipped week.
  List<User> promptTargets(DateTime bundleStart) {
    final users = raw
        .select(
          "SELECT * FROM users WHERE member_tier NOT IN "
          "('check', 'old') "
          'ORDER BY name',
        )
        .map(User.fromRow)
        .toList();
    return users
        .where((u) => !hasBundleResponse(bundleStart, u.id))
        .toList();
  }

  /// Non-responders of the bundle: active users, including out-members, who
  /// neither answered it nor are quiet (recently answered a previous bundle).
  List<User> reminderTargets(DateTime bundleStart) {
    final users = raw
        .select(
          "SELECT * FROM users WHERE member_tier NOT IN "
          "('check', 'old') "
          'ORDER BY name',
        )
        .map(User.fromRow)
        .toList();
    return users
        .where((u) =>
            !hasBundleResponse(bundleStart, u.id) &&
            !isQuiet(u.id, bundleStart))
        .toList();
  }

  // ------------------------------------------------------------- allocations

  void replaceAllocationsForWeekend(
    DateTime sat,
    List<(int, int)> allocations,
  ) {
    final tx = raw;
    tx.execute('BEGIN IMMEDIATE');
    try {
      tx.execute(
        'DELETE FROM allocations WHERE session_id IN '
        '(SELECT id FROM sessions WHERE weekend_start = ?)',
        [this._dayKey(sat)],
      );
      final stmt = tx.prepare(
        'INSERT INTO allocations (user_id, session_id) VALUES (?, ?)',
      );
      for (final (userId, sessionId) in allocations) {
        stmt.execute([userId, sessionId]);
      }
      stmt.close();
      tx.execute('COMMIT');
    } catch (_) {
      tx.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Revokes a member's allocation for one weekend (used when they repick:
  /// they leave the allocation pool and are immediately re-decided).
  void removeAllocationForUser(int userId, DateTime sat) {
    raw.execute(
      'DELETE FROM allocations WHERE user_id = ? AND session_id IN '
      '(SELECT id FROM sessions WHERE weekend_start = ?)',
      [userId, this._dayKey(sat)],
    );
  }

  List<(User, Session)> allocationsForWeekend(DateTime sat) {
    final rows = raw.select(
      '''
SELECT u.*,
       s.id             AS session_id,
       s.weekend_start  AS session_weekend_start,
       s.day            AS session_day,
       s.slot           AS session_slot,
       s.location       AS session_location,
       s.start_at       AS session_start_at,
       s.end_at         AS session_end_at,
       s.max_people     AS session_max_people,
       s.capacity_group AS session_capacity_group
FROM allocations al
JOIN users u ON u.id = al.user_id
JOIN sessions s ON s.id = al.session_id
WHERE s.weekend_start = ?
ORDER BY s.start_at, u.name
''',
      [this._dayKey(sat)],
    );
    return rows.map((r) {
      final user = User.fromRow(r);
      final session = Session(
        id: r['session_id'] as int,
        weekendStart: DateTime.parse(r['session_weekend_start'] as String),
        day: r['session_day'] as String,
        slot: r['session_slot'] as String,
        location: r['session_location'] as String,
        start: DateTime.parse(r['session_start_at'] as String),
        end: DateTime.parse(r['session_end_at'] as String),
        maxPeople: r['session_max_people'] as int?,
        capacityGroup: r['session_capacity_group'] as String?,
      );
      return (user, session);
    }).toList();
  }

}
