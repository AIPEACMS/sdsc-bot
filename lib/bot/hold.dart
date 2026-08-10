import 'package:televerse/televerse.dart';

import '../core/log.dart';

/// Thrown by [HoldTransformer] when the bot is held and a message-sending
/// API call is dropped. Callers that must keep their internal state advancing
/// (e.g. knowing a prompt "went out") catch this and treat the message as
/// delivered-but-suppressed.
class HeldException implements Exception {
  final String method;
  const HeldException(this.method);

  @override
  String toString() => 'HeldException: dropped API call $method '
      '(bot is held)';
}

/// The persisted hold state. The bot stays fully alive (long-polling, admin
/// API, logs) but all outgoing per-chat messages are suppressed.
class HoldGate {
  bool _held;

  HoldGate(this._held);

  bool get isHeld => _held;

  /// Updates the in-memory state; the caller persists it via the repo.
  set held(bool value) => _held = value;
}

/// A televerse [Transformer] installed on the bot's API that drops every
/// outgoing `send*`/`edit*` call while the bot is held — block & drop, nothing
/// is queued or replayed. Non-message calls (getUpdates, answerCallbackQuery,
/// deleteMessage, ...) pass through so the bot and the admin API stay alive.
class HoldTransformer extends Transformer {
  final HoldGate gate;

  const HoldTransformer(this.gate);

  @override
  Future<Map<String, dynamic>> transform(
    APICaller call,
    String method, [
    Payload? payload,
  ]) async {
    if (gate.isHeld && (method.startsWith('send') || method.startsWith('edit'))) {
      LogRing.log('🛑 held: dropped $method');
      throw HeldException(method);
    }
    return call(method, payload);
  }
}