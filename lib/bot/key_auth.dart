import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';

/// Signed-request authentication for the admin API.
///
/// The console app holds an Ed25519 private key and signs every request; the
/// bot verifies against a registered public key. Message format:
///
///   `$method\n$path\n$ts\n$nonce\n$bodyHash`
///
/// where `$bodyHash` is the lowercase hex sha256 of the raw request body (the
/// hash of empty bytes when there is no body). Requests carry:
///
///   X-SDSC-Pub:    base64 raw 32-byte public key
///   X-SDSC-Ts:     unix milliseconds
///   X-SDSC-Nonce:  client-random challenge string
///   X-SDSC-Sig:    base64 ed25519 signature of the message above
class KeyAuth {
  /// Verify [signatureB64] over [message] against the base64 public key.
  static Future<bool> verifySignature({
    required String pubkeyB64,
    required String signatureB64,
    required List<int> message,
  }) async {
    try {
      final publicKey = SimplePublicKey(
        base64Decode(pubkeyB64),
        type: KeyPairType.ed25519,
      );
      final signature = Signature(
        base64Decode(signatureB64),
        publicKey: publicKey,
      );
      return await Ed25519().verify(message, signature: signature);
    } catch (_) {
      return false;
    }
  }

  /// Signs [message] with a 32-byte ed25519 seed. Used by the bot's tests
  /// and kept in one place so the wire format can never drift from the
  /// console app.
  static Future<(String pubkeyB64, String signatureB64)> signWithSeed({
    required List<int> seed,
    required List<int> message,
  }) async {
    final keyPair = await Ed25519().newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();
    final signature = await Ed25519().sign(message, keyPair: keyPair);
    return (
      base64Encode(publicKey.bytes),
      base64Encode(signature.bytes),
    );
  }

  /// Derives just the base64 public key from a 32-byte ed25519 seed.
  static Future<String> pubkeyFromSeed(List<int> seed) async {
    final keyPair = await Ed25519().newKeyPairFromSeed(seed);
    final publicKey = await keyPair.extractPublicKey();
    return base64Encode(publicKey.bytes);
  }

  /// An operator-verifiable fingerprint for a base64 ed25519 public key:
  /// lowercase hex sha256 of the raw 32 bytes. The same function lives in the
  /// console app so both sides display identical fingerprints.
  static String fingerprint(String pubkeyB64) {
    final digest = sha256.convert(base64Decode(pubkeyB64));
    return digest.toString();
  }

  /// Builds the exact signed-message string for a server response. Distinct
  /// from the request format (prefix `resp:`) so a captured request signature
  /// can never verify as a response. `$nonce` is the request nonce being
  /// answered, binding the signature to the specific exchange.
  static String serverMessage({
    required String method,
    required String path,
    required String ts,
    required String nonce,
    required String bodyHash,
  }) {
    return 'resp:$method\n$path\n$ts\n$nonce\n$bodyHash';
  }

  /// Hex sha256 of [bytes] (lowercase), the body-hash of the signed message.
  static String bodyHash(List<int> bytes) {
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Builds the exact signed-message string for a request.
  static String message({
    required String method,
    required String path,
    required String ts,
    required String nonce,
    required String bodyHash,
  }) {
    return '$method\n$path\n$ts\n$nonce\n$bodyHash';
  }
}

/// Replay protection: remembers nonces within a sliding time window so a
/// captured signed request cannot be replayed.
class NonceGuard {
  final int windowSeconds;
  final Map<String, int> _seen = {};

  NonceGuard({this.windowSeconds = 300});

  /// True if [nonce] was never accepted within the window. Recording happens
  /// in [remember].
  bool contains(String nonce) => _seen.containsKey(nonce);

  void remember(String nonce, int tsMillis) {
    _seen[nonce] = tsMillis;
    _prune();
  }

  /// Drops entries older than the window.
  void _prune() {
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - windowSeconds * 1000;
    _seen.removeWhere((_, ts) => ts < cutoff);
  }
}
