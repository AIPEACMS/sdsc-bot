import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'support/grid_harness.dart';

void main() {
  setUp(setUpGrid);
  test('all-users and group-user show gadmin above admin', () async {
    await sendText(1, '/users');
    var text = sent.last['text'] as String;
    expect(text, contains('@console</b>\n   (gadmin,'));
    expect(text, isNot(contains('console + gadmin')));
    expect(text.indexOf('@console'), lessThan(text.indexOf('@admin')));

    repo.setGroup(2, repo.findUser(1)!.group);
    await sendText(2, '/groupuser');
    text = sent.last['text'] as String;
    expect(text, contains('@console</b>\n   (gadmin,'));
    expect(text, isNot(contains('console + gadmin')));
    expect(text.indexOf('@console'), lessThan(text.indexOf('@admin')));
  });

  test('plain broadcast button text opens the broadcast flow', () async {
    await sendPlainText(2, 'broadcast');
    expect(sent.last['text'], contains('Send me the message to broadcast'));
    expect(sent.last['text'], isNot(contains('availability')));
  });

  test('/adduser and /addoutuser accept multiple handles', () async {
    await sendText(2, '/adduser @memberalpha memberbeta');
    expect(sent.last['text'], contains('@memberalpha queued as a member'));
    expect(sent.last['text'], contains('@memberbeta queued as a member'));
    expect(repo.pendingTier('memberalpha'), MemberTier.member);
    expect(repo.pendingTier('memberbeta'), MemberTier.member);

    await sendText(2, '/addoutuser @outalpha outbeta');
    expect(sent.last['text'], contains('@outalpha queued as a out-member'));
    expect(sent.last['text'], contains('@outbeta queued as a out-member'));
    expect(repo.pendingTier('outalpha'), MemberTier.outMember);
    expect(repo.pendingTier('outbeta'), MemberTier.outMember);
  });

  test(
    'add-user wizard confirms a batch once and reports each outcome',
    () async {
      await sendText(2, '/addoutuser');
      expect(sent.last['text'], contains('Multiple users can be separated'));
      expect(sent.last['text'], contains('@alice @bob'));

      await sendPlainText(2, '@alice bad-handle @bob');
      expect(sent.last['text'], contains('Add these 3 out-members?'));
      expect(sent.last['reply_markup'], isNotNull);
      await sendCallback(2, 'adduser|yes');

      expect(edited.last['text'], contains('@alice queued as a out-member'));
      expect(edited.last['text'], contains('bad-handle is not a valid handle'));
      expect(edited.last['text'], contains('@bob queued as a out-member'));
      expect(repo.pendingTier('alice'), MemberTier.outMember);
      expect(repo.pendingTier('bob'), MemberTier.outMember);
      expect(state.pendingArg, isEmpty);
    },
  );

  test('add-user wizard uses singular confirmation copy for one handle', () async {
    await sendText(2, '/adduser');
    await sendPlainText(2, '@oneperson');
    expect(sent.last['text'], 'Add this member?\n• @oneperson');
    await sendCallback(2, 'adduser|no');

    await sendText(2, '/addoutuser');
    await sendPlainText(2, '@oneoutmember');
    expect(sent.last['text'], 'Add this out-member?\n• @oneoutmember');
    await sendCallback(2, 'adduser|no');
  });

  test(
    'cancelled add-user batch adds nobody and clears the wizard state',
    () async {
      await sendText(2, '/adduser');
      await sendPlainText(2, '@cancelalpha @cancelbeta');
      await sendCallback(2, 'adduser|no');

      expect(edited.last['text'], contains('nobody was added'));
      expect(repo.isPendingUser('cancelalpha'), isFalse);
      expect(repo.isPendingUser('cancelbeta'), isFalse);
      expect(state.pendingArg, isEmpty);
    },
  );

  test('broadcast wizard cancel does not enter availability cancel flow', () async {
    await sendText(2, '/broadcast');
    await sendCallback(2, 'admincancel|0');
    expect(edited.last['text'], 'Cancelled.');
    expect(
      sent.where((body) => body['text'] == 'Your previous availability is kept.'),
      isEmpty,
    );
  });

  test('/grid is rejected for non-console users', () async {
    await sendText(2, '/grid');
    expect(sent.last['text'], contains('Only the console can preview'));
  });

  test('/resetgrid returns the console to its own grid', () async {
    await sendText(1, '/grid'); // → admin preview
    await sendText(1, '/grid'); // → check preview
    await sendText(1, '/resetgrid');
    expect(sent.last['text'], contains('Back to your console grid'));
    expect(keyboardTexts(sent.last), contains('hold'));

    // Non-console: rejected.
    await sendText(2, '/resetgrid');
    expect(sent.last['text'], contains('Only the console can reset'));
  });

  test('console can run /checkstatus (previewing the check grid)', () async {
    await sendText(1, '/checkstatus');
    expect(sent.last['text'], isNot(contains('Only checkers')));
    expect(sent.last['text'], contains('This week\'s allocation'));
    expect(sent.last['text'], contains('@admin'));
  });

  test('a plain member is rejected from /checkstatus', () async {
    repo.upsertUser(
      User(id: 4, name: '@member', experience: Experience.newbie, group: '1'),
    );
    await sendText(4, '/checkstatus');
    expect(sent.last['text'], contains('Only the console can use /checkstatus'));
  });

  test('/status appends the allocation table for both weekends', () async {
    repo.updatePreferredName(2, 'Allen');
    await sendText(2, '/status');
    final text = sent.last['text'] as String;
    expect(text, contains('All members status'));
    expect(text, contains('Responded:'));
    expect(text, contains('Still to respond ('));
    expect(text, contains('Allocation · '));
    expect(text, contains('Allen @admin')); // sat0 allocation
    expect(text, contains('@checker')); // sat1 allocation
  });

  test('plain-text hyphenated aliases are gone; canonical commands and aliases work', () async {
    await sendPlainText(2, 'all-status');
    expect(sent.last['text'], contains('All members status'));
    final before = sent.length;
    await sendPlainText(2, 'all-users');
    expect(sent, hasLength(before));

    await sendText(2, '/allstatus');
    expect(sent.last['text'], contains('All members status'));
    await sendText(2, '/allusers');
    expect(sent.last['text'], contains('All users'));

    await sendText(2, '/status');
    expect(sent.last['text'], contains('All members status'));
    await sendText(2, '/users');
    expect(sent.last['text'], contains('All users'));

    await sendText(2, '/grid');
    final adminButtons = keyboardTexts(sent.last);
    expect(adminButtons, contains('all-status'));
    expect(adminButtons, isNot(contains('all-users')));
  });

  test('More Commands is sectioned and excludes every button-backed command', () async {
    await sendPlainText(2, 'more-cmd');
    final adminCommands = sent.last['text'] as String;
    expect(
      adminCommands,
      '<b>Admin</b>\n'
      '/allusers - list registered members\n'
      '/groupuser - show your group\'s member details\n'
      '/prompt - send availability prompts now\n'
      '/remind - remind non-responders now\n'
      '/setexp - change a member\'s experience\n'
      '/allocate - run the allocation now',
    );
    expect(adminCommands, isNot(contains('<b>Member</b>')));
    expect(adminCommands, isNot(contains('/groupstatus')));
    expect(adminCommands, contains('/groupuser - show your group\'s member details'));
    expect(adminCommands, isNot(contains('/groupusers')));
    expect(adminCommands, isNot(contains('/ask')));
    expect(adminCommands, isNot(contains('/broadcast')));
    expect(adminCommands, isNot(contains('/repick')));

    await sendText(1, '/grid');
    await sendPlainText(1, 'more-cmd');
    final text = sent.last['text'] as String;
    expect(text, contains('<b>Console</b>'));
    expect(text, contains('<b>Global admin</b>'));
    expect(text, contains('<b>Admin</b>'));
    expect(text.indexOf('<b>Console</b>'), lessThan(text.indexOf('<b>Global admin</b>')));
    expect(text.indexOf('<b>Global admin</b>'), lessThan(text.indexOf('<b>Admin</b>')));
    expect(text, contains('/addcheck @handle - add a checker'));
    expect(text, contains('/assigngroup - assign members to admin-led groups'));
    expect(text, contains('/groupuser - show your group\'s member details'));
    expect(text, isNot(contains('/allstatus')));
    expect(text, contains('/checkstatus - test the checker\'s check-status'));
    expect(text, isNot(contains('/hold')));
    expect(text, isNot(contains('/start -')));
    expect(text, isNot(contains('/repick')));
    expect(text, isNot(contains('/setinfo')));
    expect(text, isNot(contains('/mystatus')));
    expect(keyboardTexts(sent.last).first, 'more-cmd');
    expect(keyboardTexts(sent.last), contains('add-user'));
  });
}
