part of '../../repo.dart';

extension RepoSessions on Repo {

  LocationInfo? locationByKey(String key) {
    final rows = raw.select('SELECT * FROM locations WHERE key = ?', [key]);
    return rows.isEmpty ? null : LocationInfo.fromRow(rows.first);
  }

  LocationInfo? locationById(int id) {
    final rows = raw.select('SELECT * FROM locations WHERE id = ?', [id]);
    return rows.isEmpty ? null : LocationInfo.fromRow(rows.first);
  }

  /// Display name for a location key, falling back to the key itself.
  String locationName(String key) => locationByKey(key)?.name ?? key;

  /// Resolves a typed token to an approved location (case-insensitive,
  /// punctuation-insensitive, substring-tolerant). Null when nothing matches.
  LocationInfo? resolveLocation(String token) {
    final norm = _normLocation(token);
    if (norm.isEmpty) return null;
    final approved = approvedLocations();
    for (final l in approved) {
      if (_normLocation(l.key) == norm || _normLocation(l.name) == norm) {
        return l;
      }
      for (final a in l.aliases) {
        if (_normLocation(a) == norm) return l;
      }
    }
    for (final l in approved) {
      for (final c in [
        _normLocation(l.key),
        _normLocation(l.name),
        ...l.aliases.map(_normLocation),
      ]) {
        if (c.isNotEmpty && (c.contains(norm) || norm.contains(c))) return l;
      }
    }
    return null;
  }

  String _normLocation(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  /// Derives a unique camelCase key from a display name.
  String _locationKey(String name) {
    final words =
        _normLocation(name).split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return 'loc';
    final base = words.first +
        words
            .skip(1)
            .map((w) => w[0].toUpperCase() + w.substring(1))
            .join();
    var key = base;
    var n = 2;
    while (locationByKey(key) != null) {
      key = '$base$n';
      n++;
    }
    return key;
  }

  /// Creates an approved location (console-driven add). Idempotent by name:
  /// an existing location with the same normalized name is returned, and any
  /// new aliases are merged into it.
  LocationInfo addLocation(String name, {List<String> aliases = const []}) {
    final clean = name.trim();
    final existing = approvedLocations()
        .where((l) => _normLocation(l.name) == _normLocation(clean))
        .toList();
    if (existing.isNotEmpty) {
      if (aliases.isNotEmpty) addAliases(existing.first.key, aliases);
      return existing.first;
    }
    raw.execute(
      'INSERT INTO locations (key, name, aliases, status) '
      "VALUES (?, ?, ?, 'approved')",
      [_locationKey(clean), clean, jsonEncode(_cleanAliases(aliases))],
    );
    return allLocations().firstWhere(
      (l) => _normLocation(l.name) == _normLocation(clean),
    );
  }

  /// Records a gadmin's request for a not-yet-known location (pending until
  /// the console approves it). Re-requesting the same name reuses the row.
  LocationInfo requestLocation(String name, {required int requestedBy}) {
    final clean = name.trim();
    final existing = allLocations()
        .where((l) => _normLocation(l.name) == _normLocation(clean))
        .toList();
    if (existing.isNotEmpty) return existing.first;
    raw.execute(
      'INSERT INTO locations (key, name, aliases, status, requested_by) '
      "VALUES (?, ?, '[]', 'pending', ?)",
      [_locationKey(clean), clean, requestedBy],
    );
    return allLocations().firstWhere(
      (l) => _normLocation(l.name) == _normLocation(clean),
    );
  }

  /// Approves a pending location, optionally renaming it and setting aliases.
  bool approveLocation(int id, {String? name, List<String>? aliases}) {
    final loc = locationById(id);
    if (loc == null) return false;
    final finalName =
        (name == null || name.trim().isEmpty) ? loc.name : name.trim();
    final merged = _cleanAliases([...loc.aliases, ...?aliases]);
    raw.execute(
      "UPDATE locations SET status = 'approved', name = ?, aliases = ? "
      'WHERE id = ?',
      [finalName, jsonEncode(merged), id],
    );
    return true;
  }

  /// Adds aliases to a location, de-duplicated (case-insensitive).
  void addAliases(String locationKey, List<String> aliases) {
    final loc = locationByKey(locationKey);
    if (loc == null) return;
    final merged = _cleanAliases([...loc.aliases, ...aliases]);
    raw.execute(
      'UPDATE locations SET aliases = ? WHERE key = ?',
      [jsonEncode(merged), locationKey],
    );
  }

  List<String> _cleanAliases(List<String> aliases) {
    final seen = <String>{};
    final out = <String>[];
    for (final a in aliases) {
      final t = a.trim();
      final norm = _normLocation(t);
      if (norm.isEmpty || !seen.add(norm)) continue;
      out.add(t);
    }
    return out;
  }

  // --------------------------------------------------------------- sessions

  /// The active activity-schedule template (ordered). Seeded from the
  /// environment slot windows on first run; replaced wholesale by /settime.
  List<ScheduleSlot> scheduleTemplate() => raw
      .select('SELECT * FROM schedule_template ORDER BY id')
      .map(
        (r) => ScheduleSlot(
          day: r['day'] as String,
          slot: r['slot'] as String,
          start: r['start_at'] as String,
          end: r['end_at'] as String,
          location: r['location_key'] as String,
          maxPeople: r['max_people'] as int?,
          capacityGroup: r['capacity_group'] as String?,
        ),
      )
      .toList();

  List<ScheduleSlot> scheduleForWeekend(DateTime sat) {
    if (getSetting('schedule_override_empty_${_dayKey(sat)}') == '1') {
      return const [];
    }
    final rows = raw.select(
      'SELECT day, slot, start_at, end_at, location_key, max_people, capacity_group '
      'FROM schedule_overrides WHERE weekend_start = ? ORDER BY rowid',
      [_dayKey(sat)],
    );
    if (rows.isEmpty) return scheduleTemplate();
    return rows
        .map(
          (r) => ScheduleSlot(
            day: r['day'] as String,
            slot: r['slot'] as String,
            start: r['start_at'] as String,
            end: r['end_at'] as String,
            location: r['location_key'] as String,
            maxPeople: r['max_people'] as int?,
            capacityGroup: r['capacity_group'] as String?,
          ),
        )
        .toList();
  }

  /// Replaces the whole template (transactional). [rows] must be non-empty.
  void replaceScheduleTemplate(List<ScheduleSlot> rows) {
    final tx = raw;
    tx.execute('BEGIN IMMEDIATE');
    try {
      tx.execute('DELETE FROM schedule_template');
      for (final r in rows) {
        tx.execute(
          'INSERT INTO schedule_template '
          '(day, slot, start_at, end_at, location_key, max_people, capacity_group) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          [r.day, r.slot, r.start, r.end, r.location, r.maxPeople, r.capacityGroup],
        );
      }
      tx.execute('COMMIT');
    } catch (_) {
      tx.execute('ROLLBACK');
      rethrow;
    }
  }

  void replaceScheduleOverride(
    DateTime sat,
    List<ScheduleSlot> rows, {
    required int tzOffsetHours,
  }) {
    final tx = raw;
    tx.execute('BEGIN IMMEDIATE');
    try {
      final weekendKey = _dayKey(sat);
      final existingRows = tx.select(
        'SELECT id, day, slot, location FROM sessions WHERE weekend_start = ?',
        [weekendKey],
      );
      final existingByIdentity = {
        for (final row in existingRows)
          (
            row['day'] as String,
            row['slot'] as String,
            row['location'] as String,
          ): row['id'] as int,
      };
      final retained = <(String, String, String)>{};

      tx.execute('DELETE FROM schedule_overrides WHERE weekend_start = ?', [
        weekendKey,
      ]);
      for (final r in rows) {
        tx.execute(
          'INSERT INTO schedule_overrides '
          '(weekend_start, day, slot, start_at, end_at, location_key, '
          'max_people, capacity_group) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          [
            weekendKey,
            r.day,
            r.slot,
            r.start,
            r.end,
            r.location,
            r.maxPeople,
            r.capacityGroup,
          ],
        );

        final identity = (r.day, r.slot, r.location);
        retained.add(identity);
        final sessionId = existingByIdentity[identity];
        final date = _sessionDate(sat, r.day);
        if (sessionId != null && date != null) {
          tx.execute(
            'UPDATE sessions SET start_at = ?, end_at = ?, max_people = ?, '
            'capacity_group = ? WHERE id = ?',
            [
              _fmt(_parseTime(date, r.start)),
              _fmt(_parseTime(date, r.end)),
              r.maxPeople,
              r.capacityGroup,
              sessionId,
            ],
          );
        } else if (sessionId == null && date != null) {
          tx.execute(
            'INSERT INTO sessions '
            '(weekend_start, day, slot, location, start_at, end_at, '
            'max_people, capacity_group) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            [
              weekendKey,
              r.day,
              r.slot,
              r.location,
              _fmt(_parseTime(date, r.start)),
              _fmt(_parseTime(date, r.end)),
              r.maxPeople,
              r.capacityGroup,
            ],
          );
        }
      }

      setSetting(
        'schedule_override_empty_$weekendKey',
        rows.isEmpty ? '1' : '0',
      );

      final removedIds = existingRows
          .where(
            (row) => !retained.contains((
              row['day'] as String,
              row['slot'] as String,
              row['location'] as String,
            )),
          )
          .map((row) => row['id'] as int)
          .toList();
      for (final id in removedIds) {
        final removed = existingRows.firstWhere((row) => row['id'] == id);
        for (final availability in availabilityForWeekend(sat)) {
          removeAvailabilityForSession(
            availability.userId,
            sat,
            removed['day'] as String,
            removed['slot'] as String,
            removed['location'] as String,
          );
        }
        tx.execute('DELETE FROM allocations WHERE session_id = ?', [id]);
        tx.execute('DELETE FROM attendance WHERE session_id = ?', [id]);
        tx.execute('DELETE FROM sessions WHERE id = ?', [id]);
      }
      tx.execute('COMMIT');
    } catch (_) {
      tx.execute('ROLLBACK');
      rethrow;
    }
  }

  void clearScheduleOverride(DateTime sat) {
    raw.execute('DELETE FROM schedule_overrides WHERE weekend_start = ?', [
      _dayKey(sat),
    ]);
    setSetting('schedule_override_empty_${_dayKey(sat)}', '0');
  }

  /// Creates (idempotently) the sessions for [sat]'s weekend from [template].
  /// A template row on day D is placed at anchor + offset, where the bundled
  /// weekend runs Saturday → Friday.
  void ensureSessionsForWeekend(
    DateTime sat,
    List<ScheduleSlot> template, {
    required int tzOffsetHours,
  }) {
    for (final t in template) {
      final date = _sessionDate(sat, t.day);
      if (date == null) continue;
      raw.execute(
        '''
INSERT OR IGNORE INTO sessions
  (weekend_start, day, slot, location, start_at, end_at, max_people, capacity_group)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)
''',
        [
          _dayKey(sat),
          t.day,
          t.slot,
          t.location,
          _fmt(_parseTime(date, t.start)),
          _fmt(_parseTime(date, t.end)),
          t.maxPeople,
          t.capacityGroup,
        ],
      );
    }
  }
}
