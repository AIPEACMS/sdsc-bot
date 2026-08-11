import 'dart:convert';
import 'dart:math';

import '../core/repo.dart';
import 'key_auth.dart';

/// The admin API's own Ed25519 identity — the server half of the mutual-auth
/// scheme. The seed is generated once and persisted in the DB settings table,
/// so the identity survives restarts and redeploys (the same DB is carried
/// over). The console app pins [fingerprint] on first connect and then
/// rejects any response not signed by this identity, so a fake backend that
/// merely registers the public console key can no longer pose as the bot.
class ServerIdentity {
  static const _seedKey = 'server_identity_seed';
  static const _seedLength = 32;

  final Repo _repo;
  List<int>? _seed;

  ServerIdentity(this._repo);

  /// Loads the persisted seed, or generates and stores one on first use.
  Future<List<int>> _loadSeed() async {
    if (_seed != null) return _seed!;
    final stored = _repo.getSetting(_seedKey);
    if (stored != null) {
      _seed = base64Decode(stored);
      return _seed!;
    }
    final rand = Random.secure();
    final seed = List<int>.generate(_seedLength, (_) => rand.nextInt(256));
    _repo.setSetting(_seedKey, base64Encode(seed));
    _seed = seed;
    return seed;
  }

  Future<String> pubkeyB64() async =>
      KeyAuth.pubkeyFromSeed(await _loadSeed());

  Future<String> fingerprint() async =>
      KeyAuth.fingerprint(await pubkeyB64());

  /// Signs [message] with the server identity's private key.
  Future<String> sign(List<int> message) async {
    final (_, sig) =
        await KeyAuth.signWithSeed(seed: await _loadSeed(), message: message);
    return sig;
  }
}
