import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:sdsc_bot/bot/service.dart';
import 'support/grid_harness.dart';

void main() {
  setUp(setUpGrid);
  test('/prompt excludes current and previous bundle respondents', () async {
    Config.setDebugNow(DateTime.utc(2026, 8, 12, 4));
    addTearDown(() => Config.setDebugNow(null));
    repo.upsertUser(
      User(id: 4, name: '@previous', experience: Experience.newbie, group: '1'),
    );
    repo.upsertUser(
      User(id: 5, name: '@fresh', experience: Experience.newbie, group: '1'),
    );
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
    final previous = w.sat0.subtract(const Duration(days: 7));
    repo.setAvailability(
      Availability(
        weekendStart: previous,
        userId: 4,
        bundleStart: previous,
        slots: const {},
        available: false,
        updatedAt: Config.nowUtc(),
      ),
    );

    sent.clear();
    await sendText(2, '/prompt');
    await sendCallback(2, 'prompt|yes');

    final recipients = sent
        .where((body) => (body['text'] as String).startsWith('Hi!'))
        .map((body) => body['chat_id'])
        .toSet();
    expect(recipients, contains(5));
    expect(recipients, isNot(contains(2)));
    expect(recipients, isNot(contains(4)));
  });

  test('/groupstatus and /groupuser stay in the caller group', () async {
    repo.updatePreferredName(2, 'Allen');
    final group = repo.findUser(2)!.group;
    final w = RollingWindow.forDate(config.toLocal(Config.nowUtc()));

    await sendText(2, '/groupstatus');
    expect(sent.last['text'], contains('Group $group status'));
    expect(sent.last['text'], contains('Allen @admin'));
    expect(sent.last['text'], contains('last attend:'));
    expect(sent.last['text'], contains(' ${w.sat1.day} '));
    expect(sent.last['text'], isNot(contains('@out-member')));
    expect(sent.last['text'], isNot(contains('@checker')));

    await sendText(2, '/groupuser');
    final text = sent.last['text'] as String;
    expect(text, contains('Group $group users'));
    expect(text, isNot(contains('@checker')));

    final before = sent.length;
    await sendText(2, '/groupusers');
    expect(sent, hasLength(before));
  });

  test('/unhold immediately reopens the held bot', () async {
    repo.setHeld(true);
    holdGate.held = true;

    await sendText(1, '/unhold');

    expect(repo.isHeld(), isFalse);
    expect(holdGate.isHeld, isFalse);
    expect(sent.last['text'], contains('Bot unheld'));
  });

  test(
    'console can queue a checker without exposing addcheck in the grid',
    () async {
      await sendText(1, '/addcheck @newchecker');

      expect(sent.last['text'], contains('queued as a checker'));
      expect(repo.pendingTier('newchecker'), MemberTier.check);
      expect(keyboardTexts(sent.last), isNot(contains('add-check')));
    },
  );

  test('a queued checker receives one checker welcome and grid on /start',
      () async {
    await sendText(1, '/addcheck @newchecker');
    sent.clear();

    await sendText(4, '/start', username: 'newchecker');

    expect(repo.findUser(4)!.memberTier, MemberTier.check);
    expect(sent, hasLength(1));
    expect(sent.single['text'], contains('you are a checker'));
    expect(keyboardTexts(sent.single), contains('check-status'));
  });

  test('a queued out-member receives the Member-o welcome', () async {
    repo.addPendingUser(
      'newout',
      isAdmin: false,
      tier: MemberTier.outMember,
    );
    sent.clear();

    await sendText(8, 'hello', username: 'newout');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(sent, hasLength(1));
    expect(sent.single['text'], contains('<b>Member-o</b>'));
    expect(sent.single['text'], isNot(contains('out-member')));
  });

  test(
    '/ask changes wording at the reminder time and respects holiday opt-out',
    () async {
      Config.setDebugNow(DateTime.utc(2026, 8, 13, 10)); // Thursday 18:00 SGT.
      addTearDown(() => Config.setDebugNow(null));

      await sendText(2, '/ask 2');
      expect(sent.last['text'], contains('Just a reminder'));

      final w = RollingWindow.forDate(
        config.toLocal(Config.nowUtc()),
        promptHour: config.promptHour,
        reminderHour: config.reminderHour,
      );
      final holidayMonday = w.sat0.subtract(const Duration(days: 5));
      repo.addHoliday(holidayMonday, HolidayKind.middle);
      repo.setHolidayOptout(2, holidayMonday);

      await sendText(2, '/ask 2');
      expect(sent.last['text'], contains('@admin opted out of the holiday'));
      expect(sent.last['text'], contains('10 Aug to 16 Aug'));
      expect(service.reminderFor(repo.findUser(2)!, w), isNull);
    },
  );

  test(
    'direct broadcasts survive confirmation and are discarded on cancel',
    () async {
      await sendText(2, '/broadcast <draft>');
      expect(sent.last['text'], contains('<i>&lt;draft&gt;</i>'));
      expect(sent.last['parse_mode'], 'HTML');

      sent.clear();
      await sendText(2, '/broadcast stale');
      await sendCallback(2, 'bcast|no');
      final afterCancel = sent.length;
      await sendCallback(2, 'bcast|yes');
      expect(sent, hasLength(afterCancel));

      await sendText(2, '/broadcast hello everyone');
      expect(sent.last['text'], contains('Send this to all members?'));
      await sendCallback(2, 'bcast|yes');

      expect(
        sent.where((body) => body['text'] == 'hello everyone'),
        hasLength(2),
      );
      expect(sent.last['text'], contains('Sent to 2 members'));
    },
  );
}
