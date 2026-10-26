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

  void addConsoleKey(String pubkey, {String name = '', int? actorUserId}) {
    raw.execute(
      'INSERT OR IGNORE INTO console_keys (pubkey, name, actor_user_id) '
      'VALUES (?, ?, ?)',
      [pubkey, name, actorUserId],
    );
  }

  bool removeConsoleKey(String pubkey) {
    final identity = consoleKeyIdentity(pubkey);
    if (identity == null) return false;
    final legacyPreviews = raw.select(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' "
      "AND name = 'attendance_correction_previews'",
    );
    if (legacyPreviews.isNotEmpty) {
      raw.execute(
        'DELETE FROM attendance_correction_previews WHERE console_key_id = ?',
        [identity.id],
      );
    }
    raw.execute(
      'DELETE FROM attendance_correction_previews_v2 WHERE console_key_id = ?',
      [identity.id],
    );
    raw.execute('DELETE FROM console_keys WHERE pubkey = ?', [pubkey]);
    return true;
  }
}
