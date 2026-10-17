import 'dart:async';
import 'dart:io';

/// Synchronizes Bot.local tests with the first long-poll request instead of
/// sleeping for a guessed startup interval.
class BotReadiness {
  final Completer<void> _started = Completer<void>();

  void observe(HttpRequest request) {
    if (request.uri.path.endsWith('/getUpdates') && !_started.isCompleted) {
      _started.complete();
    }
  }

  Future<void> wait() => _started.future.timeout(const Duration(seconds: 5));
}
