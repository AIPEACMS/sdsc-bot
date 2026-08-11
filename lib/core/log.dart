/// In-memory log ring buffer. Everything the bot prints is also kept here so
/// the admin HTTP API can serve recent log lines to the console app.
///
/// Retention is time-based: entries older than [retention] are pruned when a
/// new line arrives. A hard [maxLines] cap still bounds memory as a safety
/// net. The retention window is configurable at runtime (default 14 days) and
/// persisted by the caller via the admin API.
class LogRing {
  LogRing._();

  /// Hard memory bound — even with a long retention window, never keep more
  /// lines than this.
  static const int maxLines = 5000;

  /// How long log lines are kept before they are pruned.
  static Duration retention = const Duration(days: 14);

  static final List<({DateTime at, String text})> _lines = [];

  /// Records a log line with a timestamp, prunes entries older than the
  /// retention window (and over the line cap), and writes to stdout so
  /// systemd/journald still sees everything.
  static void log(String line) {
    final at = DateTime.now().toUtc();
    final entry = '${at.toIso8601String()}  $line';
    _lines.add((at: at, text: entry));
    _prune();
    // ignore: avoid_print
    print(entry);
  }

  static void _prune() {
    final cutoff = DateTime.now().toUtc().subtract(retention);
    _lines.removeWhere((e) => e.at.isBefore(cutoff));
    if (_lines.length > maxLines) {
      _lines.removeRange(0, _lines.length - maxLines);
    }
  }

  /// The retention window in whole days (used by the API/console display).
  static int get retentionDays => retention.inDays;

  /// Updates the retention window. Prunes immediately so lines outside the
  /// new window are dropped right away.
  static void setRetention(Duration value) {
    retention = value;
    _prune();
  }

  /// A read-only snapshot of the retained lines.
  static List<String> get snapshot =>
      List.unmodifiable(_lines.map((e) => e.text));

  /// The retained lines joined into one blob, for the logs API/page.
  static String get text => _lines.map((e) => e.text).join('\n');

  static void clear() => _lines.clear();
}
