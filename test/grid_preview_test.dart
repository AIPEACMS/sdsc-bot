import 'dart:convert';
import 'dart:io';

import 'package:televerse/telegram.dart' show Update;
import 'package:televerse/televerse.dart';
import 'package:test/test.dart';

import 'package:sdsc_bot/bot/admin.dart';
import 'package:sdsc_bot/bot/console.dart';
import 'package:sdsc_bot/bot/flows.dart';
import 'package:sdsc_bot/bot/hold.dart';
import 'package:sdsc_bot/bot/service.dart';
import 'package:sdsc_bot/bot/state.dart';
import 'package:sdsc_bot/core/config.dart';
import 'package:sdsc_bot/core/db.dart';
import 'package:sdsc_bot/core/messages.dart';
import 'package:sdsc_bot/core/models.dart';
import 'package:sdsc_bot/core/repo.dart';

/// Grid preview (/grid, /resetgrid), check-status access, and the admin
/// /status allocation table.
void main() {
  late Directory tmp;
  late Database db;
  late Repo repo;
  late Config config;
  late Messages messages;
  late BotState state;
  late CycleService service;
  late Flows flows;
  late Admin admin;
  late Console console;
  late HoldGate holdGate;
  late List<Map<String, dynamic>> sent;
  late List<Map<String, dynamic>> edited;
  late HttpServer server;
  late Bot bot;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sdsc_grid_');
    config = Config(
      botToken: 'test',
      dbPath: '${tmp.path}/test.db',
      consoleId: 1,
      groupAContact: 'TBD',
      groupBContact: 'TBD',
      ocbcCapacity: 2,
      prCapacity: 20,
      slotTimes: const {'am': ('09:00', '12:00'), 'pm': ('13:00', '17:00')},
      promptHour: 18,
      reminderHour: 18,
      deadlineHour: 18,
      allocationHour: 9,
      bailHour: 12,
      timezoneOffsetHours: 8,
    );
    db = Database.open(config);
    repo = Repo(db);
    messages = Messages(
      (group) => repo.groupAdmin(group)?.name ?? config.contactForGroup(group),
    );
    state = BotState();

    sent = <Map<String, dynamic>>[];
    edited = <Map<String, dynamic>>[];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final path = req.uri.path;
      if (path.endsWith('/getMe')) {
        await _json(req, {
          'ok': true,
          'result': {
            'id': 1,
            'is_bot': true,
            'first_name': 'test',
            'username': 'sdsc_attendence_bot',
          },
        });
      } else if (path.endsWith('/getUpdates')) {
        await _json(req, {'ok': true, 'result': <dynamic>[]});
      } else if (path.endsWith('/sendMessage')) {
        final body = jsonDecode(await utf8.decoder.bind(req).join());
        sent.add(body as Map<String, dynamic>);
        await _json(req, {
          'ok': true,
          'result': {
            'message_id': 1,
            'date': 1,
            'chat': {'id': 1, 'type': 'private'},
            'text': body['text'],
          },
        });
      } else if (path.endsWith('/editMessageReplyMarkup')) {
        final body = jsonDecode(await utf8.decoder.bind(req).join());
        edited.add(body as Map<String, dynamic>);
        await _json(req, {'ok': true, 'result': true});
      } else if (path.endsWith('/answerCallbackQuery')) {
        await _json(req, {'ok': true, 'result': true});
      } else if (path.endsWith('/editMessageText')) {
        final body = jsonDecode(await utf8.decoder.bind(req).join());
        edited.add(body as Map<String, dynamic>);
        await _json(req, {
          'ok': true,
          'result': {
            'message_id': 1,
            'date': 1,
            'chat': {'id': 1, 'type': 'private'},
            'text': body['text'],
          },
        });
      } else {
        await _json(req, {'ok': false, 'error': 'nf'}, status: 404);
      }
    });

    bot = Bot.local('test-token', 'http://127.0.0.1:${server.port}');
    service = CycleService(
      repo: repo,
      config: config,
      messages: messages,
      state: state,
      bot: bot,
    );
    flows = Flows(
      bot: bot,
      repo: repo,
      config: config,
      messages: messages,
      state: state,
      service: service,
    );
    admin = Admin(
      bot: bot,
      repo: repo,
      config: config,
      state: state,
      service: service,
    );
    holdGate = HoldGate(false);
    console = Console(
      bot: bot,
      repo: repo,
      config: config,
      state: state,
      holdGate: holdGate,
    );
    flows.register();
    admin.register();
    console.register();

    // Console (1), an admin (2), and a checker (3).
    repo.upsertUser(
      User(
        id: 1,
        name: '@console',
        experience: Experience.experienced,
        group: '1',
      ),
    );
    repo.updateAdmin(1, true);
    repo.upsertUser(
      User(
        id: 2,
        name: '@admin',
        experience: Experience.experienced,
        group: '1',
      ),
    );
    repo.updateAdmin(2, true);
    repo.upsertUser(
      User(
        id: 3,
        name: '@checker',
        experience: Experience.newbie,
        group: '',
        memberTier: MemberTier.check,
      ),
    );

    // Allocate the current bundle so the tables have content.
    final w = RollingWindow.forDate(config.toLocal(Config.nowUtc()));
    repo.ensureSessionsForWeekend(
      w.sat0,
      config.slotTimes,
      tzOffsetHours: config.timezoneOffsetHours,
    );
    repo.ensureSessionsForWeekend(
      w.sat1,
      config.slotTimes,
      tzOffsetHours: config.timezoneOffsetHours,
    );
    final s0 = repo.sessionsForWeekend(w.sat0);
    final s1 = repo.sessionsForWeekend(w.sat1);
    repo.replaceAllocationsForWeekend(w.sat0, [(2, s0[0].id)]);
    repo.replaceAllocationsForWeekend(w.sat1, [(3, s1[0].id)]);

    final startFuture = bot.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    addTearDown(() async {
      await bot.stop();
      await startFuture;
      await server.close(force: true);
      db.close();
      tmp.deleteSync(recursive: true);
    });
  });

  Future<void> sendText(int userId, String text, {String? username}) =>
      bot.handleUpdate(
    Update.fromJson({
      'update_id': 1,
      'message': {
        'message_id': 1,
        'date': 1,
        'chat': {'id': userId, 'type': 'private'},
        'from': {
          'id': userId,
          'is_bot': false,
          'first_name': 'u',
          ...?(username == null ? null : {'username': username}),
        },
        'text': text,
        'entities': [
          {
            'offset': 0,
            'length': text.contains(' ') ? text.indexOf(' ') : text.length,
            'type': 'bot_command',
          },
        ],
      },
    }),
  );

  Future<void> sendCallback(int userId, String data) => bot.handleUpdate(
    Update.fromJson({
      'update_id': 2,
      'callback_query': {
        'id': 'callback-$userId-$data',
        'from': {'id': userId, 'is_bot': false, 'first_name': 'u'},
        'chat_instance': 'test-chat-instance',
        'message': {
          'message_id': 1,
          'date': 1,
          'chat': {'id': userId, 'type': 'private'},
        },
        'data': data,
      },
    }),
  );

  List<String> keyboardTexts(Map<String, dynamic> body) {
    final kb = (body['reply_markup'] as Map<String, dynamic>?)?['keyboard'];
    if (kb == null) return const [];
    return [
      for (final row in kb as List)
        for (final b in row as List) (b as Map)['text'] as String,
    ];
  }

  test(
    '/start sends parseable console help',
    () async {
      final sentBefore = sent.length;
      await sendText(1, '/start');
      final welcome = sent[sentBefore];
      expect(welcome['text'], contains('/broadcast &lt;message&gt;'));
      expect(welcome['parse_mode'], 'HTML');
    },
  );

  test(
    '/grid cycles console → admin → check → member for the console',
    () async {
      await sendText(1, '/grid');
      expect(sent.last['text'], contains('Preview: admin grid'));
      expect(
        keyboardTexts(sent.last),
        containsAll([
          'all-status',
          'group-status',
          'all-users',
          'group-users',
          'broadcast',
        ]),
      );
      expect(keyboardTexts(sent.last), isNot(contains('prompt')));
      expect(keyboardTexts(sent.last), isNot(contains('remind')));
      expect(keyboardTexts(sent.last), isNot(contains('allocate')));

      await sendText(1, '/grid');
      expect(sent.last['text'], contains('Preview: check grid'));
      expect(keyboardTexts(sent.last), contains('check-status'));

      await sendText(1, '/grid');
      expect(sent.last['text'], contains('Preview: member grid'));
      expect(keyboardTexts(sent.last), contains('re-pick'));

      await sendText(1, '/grid');
      expect(sent.last['text'], contains('Preview: console grid'));
      expect(keyboardTexts(sent.last), containsAll(['hold', 'full-info']));
    },
  );

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

  test('console can run /check-status (previewing the check grid)', () async {
    await sendText(1, '/check-status');
    expect(sent.last['text'], isNot(contains('Only checkers')));
    expect(sent.last['text'], contains('This week\'s allocation'));
    expect(sent.last['text'], contains('@admin'));
  });

  test('a plain member is still rejected from /check-status', () async {
    repo.upsertUser(
      User(id: 4, name: '@member', experience: Experience.newbie, group: '1'),
    );
    await sendText(4, '/check-status');
    expect(sent.last['text'], contains('Only checkers can view'));
  });

  test('/status appends the allocation table for both weekends', () async {
    repo.updateProfileInfo(2, preferredName: 'Allen');
    await sendText(2, '/status');
    final text = sent.last['text'] as String;
    expect(text, contains('All members status'));
    expect(text, contains('Responded:'));
    expect(text, contains('Allocation · '));
    expect(text, contains('Allen @admin')); // sat0 allocation
    expect(text, contains('@checker')); // sat1 allocation
  });

  test('/groupstatus and /groupusers stay in the caller group', () async {
    repo.updateProfileInfo(
      2,
      fullName: 'Allen Tan',
      preferredName: 'Allen',
      schoolEmail: 'allen@example.edu',
      matricNo: 'A1234567X',
    );
    final group = repo.findUser(2)!.group;

    await sendText(2, '/groupstatus');
    expect(sent.last['text'], contains('Group $group status'));
    expect(sent.last['text'], contains('Allen @admin'));
    expect(sent.last['text'], isNot(contains('@checker')));

    await sendText(2, '/groupusers');
    final text = sent.last['text'] as String;
    expect(text, contains('Group $group users'));
    expect(text, contains('Full name: Allen Tan'));
    expect(text, contains('Preferred name: Allen'));
    expect(text, contains('School email: allen@example.edu'));
    expect(text, contains('Matric number: A1234567X'));
    expect(text, isNot(contains('@checker')));
  });

  test('/fullinfo shows profile information without attendance', () async {
    repo.updateProfileInfo(
      2,
      fullName: 'Allen Tan',
      preferredName: 'Allen',
      schoolEmail: 'allen@example.edu',
      matricNo: 'A1234567X',
    );

    await sendText(1, '/fullinfo');
    final text = sent.last['text'] as String;
    expect(text, contains('All profile information'));
    expect(text, contains('Allen @admin'));
    expect(text, contains('School email: allen@example.edu'));
    expect(text, isNot(contains('ocbc ×')));
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

  test(
    '/mystatus shows profile fields and dated unavailable responses',
    () async {
      repo.updateProfileInfo(
        2,
        fullName: 'Allen Tan',
        preferredName: 'Allen',
        schoolEmail: 'allen@example.edu',
        matricNo: 'A1234567X',
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

      await sendText(2, '/mystatus');
      final text = sent.last['text'] as String;
      expect(text, contains('Bundle: "'));
      expect(text, contains('Full name: Allen Tan'));
      expect(text, contains('Preferred name: Allen'));
      expect(text, contains('School email: allen@example.edu'));
      expect(text, contains('Matric number: A1234567X'));
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

Future<void> _json(HttpRequest req, Object body, {int status = 200}) async {
  req.response.statusCode = status;
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode(body));
  await req.response.close();
}
