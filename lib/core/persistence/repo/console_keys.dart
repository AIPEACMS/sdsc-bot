part of '../../repo.dart';

extension RepoConsoleKeys on Repo {
  List<ConsoleKey> listConsoleKeys() => [
    for (final row in raw.select('SELECT * FROM console_keys ORDER BY id'))
      ConsoleKey(
        pubkey: row['pubkey'] as String,
        name: row['name'] as String,
        createdAt: row['created_at'] as String,
        actorUserId: row['actor_user_id'] as int?,
      ),
  ];

  bool hasConsoleKey(String pubkey) => raw.select(
    'SELECT 1 FROM console_keys WHERE pubkey = ? LIMIT 1',
    [pubkey],
  ).isNotEmpty;

  ({int id, int? actorUserId})? consoleKeyIdentity(String pubkey) {
    final rows = raw.select(
      'SELECT id, actor_user_id FROM console_keys WHERE pubkey = ? LIMIT 1',
      [pubkey],
    );
    if (rows.isEmpty) return null;
    return (
      id: rows.first['id'] as int,
      actorUserId: rows.first['actor_user_id'] as int?,
    );
  }

  void addConsoleKey(String pubkey, {String name = ''}) {
    raw.execute(
      'INSERT OR IGNORE INTO console_keys (pubkey, name) VALUES (?, ?)',
      [pubkey, name],
    );
  }

  bool removeConsoleKey(String pubkey) {
    final identity = consoleKeyIdentity(pubkey);
    if (identity == null) return false;
    raw.execute(
      'DELETE FROM attendance_correction_previews WHERE console_key_id = ?',
      [identity.id],
    );
    raw.execute('DELETE FROM console_keys WHERE pubkey = ?', [pubkey]);
    return true;
  }

  ConsoleKeyBindingResult createConsoleKeyBindingChallenge(
    String pubkey, {
    required String challengeHash,
    required String expiresAt,
  }) {
    final identity = consoleKeyIdentity(pubkey);
    if (identity == null) return ConsoleKeyBindingResult.missingKey;
    if (identity.actorUserId != null) {
      return ConsoleKeyBindingResult.alreadyBound;
    }
    raw.execute(
      'UPDATE console_keys SET bind_challenge_hash = ?, '
      'bind_challenge_expires_at = ? WHERE id = ? AND actor_user_id IS NULL',
      [challengeHash, expiresAt, identity.id],
    );
    return ConsoleKeyBindingResult.success;
  }

  ConsoleKeyBindingResult redeemConsoleKeyBindingChallenge(
    String challengeCode, {
    required int actorUserId,
    required String now,
  }) {
    final hash = sha256.convert(utf8.encode(challengeCode)).toString();
    final tx = raw;
    tx.execute('BEGIN IMMEDIATE');
    try {
      final rows = tx.select(
        'SELECT id, bind_challenge_expires_at FROM console_keys '
        'WHERE bind_challenge_hash = ? AND actor_user_id IS NULL LIMIT 1',
        [hash],
      );
      if (rows.isEmpty) {
        tx.execute('ROLLBACK');
        return ConsoleKeyBindingResult.invalidCode;
      }
      final row = rows.first;
      final expiresAt = row['bind_challenge_expires_at'] as String?;
      if (expiresAt == null || expiresAt.compareTo(now) <= 0) {
        tx.execute(
          'UPDATE console_keys SET bind_challenge_hash = NULL, '
          'bind_challenge_expires_at = NULL WHERE id = ?',
          [row['id']],
        );
        tx.execute('COMMIT');
        return ConsoleKeyBindingResult.expiredCode;
      }
      final user = findUser(actorUserId);
      if (user == null || (!user.isAdmin && !user.isGlobalAdmin)) {
        tx.execute('ROLLBACK');
        return ConsoleKeyBindingResult.notAdmin;
      }
      tx.execute(
        'UPDATE console_keys SET actor_user_id = ?, bind_challenge_hash = NULL, '
        'bind_challenge_expires_at = NULL WHERE id = ? AND actor_user_id IS NULL',
        [actorUserId, row['id']],
      );
      if (tx.updatedRows != 1) {
        tx.execute('ROLLBACK');
        return ConsoleKeyBindingResult.alreadyBound;
      }
      tx.execute('COMMIT');
      return ConsoleKeyBindingResult.success;
    } catch (_) {
      tx.execute('ROLLBACK');
      rethrow;
    }
  }
}
