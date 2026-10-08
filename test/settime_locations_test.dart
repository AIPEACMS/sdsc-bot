import 'dart:io';

import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'support/settime_harness.dart';

void main() {
  setUp(() => setUpRepoHarness('sdsc_loc_'));
  tearDown(tearDownRepoHarness);
  group('locations', () {
    late Directory tmp;
    late Database db;
    late Repo repo;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('sdsc_loc_');
      db = Database.open(configForTest(tmp));
      repo = Repo(db);
    });

    tearDown(() {
      db.close();
      tmp.deleteSync(recursive: true);
    });

    test('seeds the built-in locations with aliases', () {
      final approved = repo.approvedLocations();
      expect(approved.map((l) => l.key).toSet(), {'ocbc', 'pasirRis'});
      expect(repo.resolveLocation('PR')!.key, 'pasirRis');
      expect(repo.resolveLocation('ocbc arena')!.key, 'ocbc');
      expect(repo.resolveLocation('pasir')!.key, 'pasirRis');
      expect(repo.resolveLocation('Pasir Ris')!.key, 'pasirRis');
      expect(repo.resolveLocation('nowhere'), isNull);
    });

    test('addAliases merges and de-duplicates', () {
      repo.addAliases('ocbc', ['The Arena', 'ocbc arena', '  ']);
      final loc = repo.locationByKey('ocbc')!;
      expect(loc.aliases, contains('The Arena'));
      expect(
        loc.aliases.where((a) => a.toLowerCase() == 'ocbc arena').length,
        1,
      );
      expect(repo.resolveLocation('the arena')!.key, 'ocbc');
    });

    test('request -> pending -> approve flow', () {
      final pending = repo.requestLocation('Marina Bay', requestedBy: 5);
      expect(pending.status, 'pending');
      expect(repo.approvedLocations().map((l) => l.key), isNot(contains(pending.key)));
      expect(repo.resolveLocation('marina bay'), isNull);

      expect(repo.approveLocation(pending.id, aliases: ['MB']), isTrue);
      expect(repo.resolveLocation('MB')!.key, pending.key);
      expect(repo.resolveLocation('Marina Bay')!.key, pending.key);
    });

    test('addLocation is idempotent by name', () {
      final a = repo.addLocation('Marina Bay');
      final b = repo.addLocation('marina bay', aliases: ['MB']);
      expect(b.id, a.id);
      expect(repo.resolveLocation('mb')!.key, a.key);
    });
  });
}
