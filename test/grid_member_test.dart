import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:sdsc_bot/bot/service.dart';
import 'support/grid_harness.dart';

void main() {
  setUp(setUpGrid);
  test('availability picker slot edits use HTML parsing', () async {
    Config.setDebugNow(DateTime.utc(2026, 9, 16, 4));
    addTearDown(() => Config.setDebugNow(null));
    final w = RollingWindow.forDate(config.toLocal(Config.nowUtc()));
    final bundleStart = w.sat0.toIso8601String().split('T').first;
    await sendText(2, '/repick');
    await sendCallback(2, 'slot|$bundleStart|0:sat:am:ocbc');

    expect(edited.last['text'], contains('<b>once</b>'));
    expect(edited.last['parse_mode'], 'HTML');
  });

  test(
    '/mystatus shows preferred name and dated unavailable responses',
    () async {
      repo.updatePreferredName(2, 'Allen');
      final w = RollingWindow.forDate(config.toLocal(Config.nowUtc()));
      repo.setAvailability(
        Availability(
          weekendStart: w.sat0,
          userId: 2,
          bundleStart: w.sat0,
          slots: const {},
          available: false,
          updatedAt: Config.nowUtc(),
        ),
      );

      await sendText(2, '/mystatus');
      final text = sent.last['text'] as String;
      expect(text, contains('Bundle: "'));
      expect(text, contains('Preferred name: Allen'));
      expect(text, contains('Indicated not available'));
      expect(text, isNot(contains('Weekend 1')));
      expect(text, isNot(contains('this bundle')));
    },
  );

  test(
    'a new command removes old picker buttons without replacing its text',
    () async {
      await sendText(2, '/repick');
      expect(sent.last['reply_markup'], isNotNull);

      await sendText(2, '/mystatus');

      expect(edited, hasLength(1));
      expect(edited.single['reply_markup'], isNull);
      expect(sent.last['text'], startsWith('👤 <b>Your information</b>'));
    },
  );

  test(
    'bundle allocation retains only one existing backup per member',
    () async {
      final w = RollingWindow.forDate(config.toLocal(Config.nowUtc()));
      final first = repo.sessionsForWeekend(w.sat0).first;
      final second = repo.sessionsForWeekend(w.sat1).last;
      repo.setAvailability(
        Availability(
          weekendStart: w.sat0,
          userId: 2,
          bundleStart: w.sat0,
          slots: {const Slot(0, 'sat', 'am', 'ocbc')},
          available: true,
          updatedAt: Config.nowUtc(),
        ),
      );
      repo.setAvailability(
        Availability(
          weekendStart: w.sat1,
          userId: 2,
          bundleStart: w.sat0,
          slots: {const Slot(1, 'sat', 'pm', 'pasirRis')},
          available: true,
          updatedAt: Config.nowUtc(),
        ),
      );
      repo.replaceAllocationsForWeekend(w.sat1, [(2, second.id)]);

      await service.allocateBundle(w);

      final allocations = [
        ...repo.allocationsForWeekend(w.sat0),
        ...repo.allocationsForWeekend(w.sat1),
      ].where((entry) => entry.$1.id == 2).toList();
      expect(allocations.map((entry) => entry.$2.id), [first.id]);
    },
  );
}
