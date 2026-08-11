import 'package:test/test.dart';
import 'package:sdsc_bot/core/log.dart';

void main() {
  tearDown(() {
    LogRing.clear();
    LogRing.setRetention(const Duration(days: 14));
  });

  test('retention defaults to 14 days', () {
    expect(LogRing.retentionDays, 14);
  });

  test('shrinking the window prunes old lines immediately', () {
    LogRing.log('kept line');
    expect(LogRing.snapshot.any((l) => l.contains('kept line')), isTrue);

    // Any line logged before this instant is now older than the window.
    LogRing.setRetention(const Duration(microseconds: 1));
    expect(LogRing.snapshot, isEmpty);
  });

  test('fresh lines stay within a matching window', () {
    LogRing.setRetention(const Duration(hours: 1));
    LogRing.log('fresh line');
    expect(LogRing.snapshot.any((l) => l.contains('fresh line')), isTrue);
  });

  test('setRetention reports whole days', () {
    LogRing.setRetention(const Duration(days: 21));
    expect(LogRing.retentionDays, 21);
  });
}
