/// In-memory log ring buffer. Everything the bot prints is also kept here so
/// the admin HTTP API can serve recent log lines to the console app.
///
/// The buffer is capped: old lines fall off the top.
class LogRing {
  LogRing._();

  static const int maxLines = 2000;
  static final List<String> _lines = [];

  /// Records a log line with a timestamp, keeps the ring bounded, and also
  /// writes it to stdout so systemd/journald still sees everything.
  static void log(String line) {
    final entry = '${DateTime.now().toIso8601String()}  $line';
    _lines.add(entry);
    if (_lines.length > maxLines) {
      _lines.removeRange(0, _lines.length - maxLines);
    }
    // ignore: avoid_print
    print(entry);
  }

  /// A read-only snapshot of the buffered lines.
  static List<String> get snapshot => List.unmodifiable(_lines);

  /// The buffered lines joined into one blob, for the logs API/page.
  static String get text => _lines.join('\n');

  static void clear() => _lines.clear();
}