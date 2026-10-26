part of '../../repo.dart';

extension RepoAttendanceCorrections on Repo {
  DateTime? actualLastAttendedDate(int userId) {
    final rows = raw.select(
      'SELECT MAX(substr(s.start_at, 1, 10)) AS last_attended '
      'FROM attendance a JOIN sessions s ON s.id = a.session_id '
      'WHERE a.user_id = ?',
      [userId],
    );
    final value = rows.first['last_attended'] as String?;
    return value == null ? null : DateTime.parse(value);
  }

  void storeAttendanceCorrectionPreview({
    required String tokenHash,
    required int consoleKeyId,
    required int targetUserId,
    required int delta,
    required String? requestedDate,
    required int expectedSessionCount,
    required int expectedBalance,
    required String? expectedEffectiveDate,
    required String expiresAt,
    required String now,
  }) {
    raw.execute(
      'DELETE FROM attendance_correction_previews_v2 WHERE expires_at <= ?',
      [now],
    );
    raw.execute(
      'INSERT INTO attendance_correction_previews_v2 '
      '(token_hash, console_key_id, target_user_id, '
      'delta, requested_last_attended_date, expected_session_count, '
      'expected_balance, expected_effective_date, expires_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        tokenHash,
        consoleKeyId,
        targetUserId,
        delta,
        requestedDate,
        expectedSessionCount,
        expectedBalance,
        expectedEffectiveDate,
        expiresAt,
      ],
    );
  }

  (AttendanceCorrectionApplyResult, int?) applyAttendanceCorrectionPreview({
    required String tokenHash,
    required int consoleKeyId,
    required int consoleUserId,
    required String now,
  }) {
    final tx = raw;
    tx.execute('BEGIN IMMEDIATE');
    try {
      final previews = tx.select(
        'SELECT * FROM attendance_correction_previews_v2 WHERE token_hash = ?',
        [tokenHash],
      );
      if (previews.isEmpty) {
        tx.execute('ROLLBACK');
        return (AttendanceCorrectionApplyResult.stale, null);
      }
      final preview = previews.first;
      final targetId = preview['target_user_id'] as int;
      final expired = (preview['expires_at'] as String).compareTo(now) <= 0;
      final identity = tx.select(
        'SELECT actor_user_id FROM console_keys WHERE id = ?',
        [consoleKeyId],
      );
      if (expired) {
        _deletePreview(tx, tokenHash);
        tx.execute('COMMIT');
        return (AttendanceCorrectionApplyResult.expired, null);
      }
      if (identity.isEmpty || preview['console_key_id'] != consoleKeyId) {
        tx.execute('ROLLBACK');
        return (AttendanceCorrectionApplyResult.stale, null);
      }
      final ownerId = identity.first['actor_user_id'] as int?;
      final targetRows = tx.select('SELECT * FROM users WHERE id = ?', [
        targetId,
      ]);
      if ((ownerId != null && ownerId != consoleUserId) || targetRows.isEmpty) {
        _deletePreview(tx, tokenHash);
        tx.execute('COMMIT');
        return (AttendanceCorrectionApplyResult.forbidden, null);
      }
      final target = User.fromRow(targetRows.first);
      final delta = preview['delta'] as int;
      if (target.memberTier != MemberTier.member) {
        _deletePreview(tx, tokenHash);
        tx.execute('COMMIT');
        return (AttendanceCorrectionApplyResult.forbidden, null);
      }
      final counts = tx.select(
        'SELECT COUNT(*) AS n FROM attendance WHERE user_id = ? AND attended = 1',
        [targetId],
      );
      final sessionCount = counts.first['n'] as int;
      final effectiveDate = targetRows.first['last_attended_date'] as String?;
      if (sessionCount != preview['expected_session_count'] ||
          target.attendanceBalance != preview['expected_balance'] ||
          effectiveDate != preview['expected_effective_date']) {
        _deletePreview(tx, tokenHash);
        tx.execute('COMMIT');
        return (AttendanceCorrectionApplyResult.stale, null);
      }
      final requestedDate = preview['requested_last_attended_date'] as String?;
      if (requestedDate != null &&
          requestedDate.compareTo(now.substring(0, 10)) > 0) {
        _deletePreview(tx, tokenHash);
        tx.execute('COMMIT');
        return (AttendanceCorrectionApplyResult.stale, null);
      }
      tx.execute(
        'UPDATE users SET attendance_balance = attendance_balance + ?, '
        'manual_last_attended_date = COALESCE(?, manual_last_attended_date), '
        'last_attended_date = NULLIF(MAX('
        'COALESCE(?, manual_last_attended_date, \'\'), '
        'COALESCE((SELECT MAX(substr(s.start_at, 1, 10)) '
        'FROM attendance a JOIN sessions s ON s.id = a.session_id '
        'WHERE a.user_id = users.id AND a.attended = 1), \'\')), \'\') '
        'WHERE id = ?',
        [delta, requestedDate, requestedDate, targetId],
      );
      _deletePreview(tx, tokenHash);
      tx.execute('COMMIT');
      return (AttendanceCorrectionApplyResult.applied, targetId);
    } catch (_) {
      tx.execute('ROLLBACK');
      rethrow;
    }
  }

  void _deletePreview(sqlite.Database tx, String tokenHash) {
    tx.execute(
      'DELETE FROM attendance_correction_previews_v2 WHERE token_hash = ?',
      [tokenHash],
    );
  }
}
