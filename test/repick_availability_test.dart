import 'dart:convert';
import 'dart:io';

import 'package:televerse/telegram.dart' show Update;
import 'package:televerse/televerse.dart';
import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:sdsc_bot/bot/flows.dart';
import 'package:sdsc_bot/bot/service.dart';
import 'package:sdsc_bot/bot/state.dart';
import 'support/repick_harness.dart';
import 'test_helpers.dart';

void main() {
  setUp(setUpRepick);
  tearDown(tearDownRepick);
  test('Done with nothing selected is treated as not available', () async {
    final sent = <Map<String, dynamic>>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
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
      } else if (path.endsWith('/answerCallbackQuery') ||
          path.endsWith('/editMessageText')) {
        await _json(req, {'ok': true, 'result': true});
      } else {
        await _json(req, {'ok': false, 'error': 'nf'}, status: 404);
      }
    });

    repo.upsertUser(
      User(id: 42, name: '@alice', experience: Experience.newbie, group: '1'),
    );

    final bot = Bot.local('test-token', 'http://127.0.0.1:${server.port}');
    final state = BotState();
    final service = CycleService(
      repo: repo,
      config: config,
      messages: messages,
      state: state,
      bot: bot,
    );
    var dynamicRuns = 0;
    final flows = Flows(
      bot: bot,
      repo: repo,
      config: config,
      messages: messages,
      state: state,
      service: service,
    );
    flows.onAvailabilitySaved = () async {
      dynamicRuns++;
    };
    flows.register();

    final startFuture = bot.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // alice taps Done without selecting any slot. This weekend (2026-08-15)
    // is already locked on the real clock; next weekend is still open.
    await bot.handleUpdate(
      Update.fromJson({
        'update_id': 1,
        'callback_query': {
          'id': '1',
          'from': {'id': 42, 'is_bot': false, 'first_name': 'alice'},
          'chat_instance': '1',
          'message': {
            'message_id': 7,
            'date': 1,
            'chat': {'id': 42, 'type': 'private'},
            'text': 'Your availability (tap to toggle):',
          },
          'data': 'done|2026-08-15',
        },
      }),
    );

    await bot.stop();
    await startFuture;
    await server.close(force: true);

    // The reply is the "not available" message, never a "(none)" summary.
    final texts = sent.map((s) => s['text'] as String).toList();
    expect(
      texts.any((t) => t.contains('all set for the next 2 weeks')),
      isTrue,
    );
    expect(texts.any((t) => t.contains('(none)')), isFalse);

    // The open weekend's availability row is stored as available=false.
    final sat1 = DateTime(2026, 8, 22);
    final row = repo.getAvailability(sat1, 42);
    expect(row, isNotNull);
    expect(row!.available, isFalse);

    // Saving availability arms the dynamic allocation run.
    expect(dynamicRuns, 1);
  });

  test('message contacts resolve to the group leader, not the placeholder', () {
    repo.upsertUser(
      User(
        id: 10,
        name: '@leader',
        experience: Experience.experienced,
        group: '1',
        isAdmin: true,
      ),
    );
    repo.upsertUser(
      User(id: 11, name: '@member', experience: Experience.newbie, group: '1'),
    );

    final prompt = messages.msg1('1');
    expect(prompt, contains('@leader'));
    expect(prompt, isNot(contains('TBD')));

    final notice = messages.msg4(
      '1',
      'OCBC · Saturday 15 Aug AM',
      '09:00 to 12:00',
      deadlinePassed: true,
      deadlineLabel: 'Friday 6:00 PM',
    );
    expect(notice, contains('@leader'));
    expect(notice, isNot(contains('TBD')));

    // Before the weekend's Friday deadline the member can still re-pick
    // instead of messaging the contact.
    final before = messages.msg4(
      '1',
      'OCBC · Saturday 15 Aug AM',
      '09:00 to 12:00',
      deadlinePassed: false,
      deadlineLabel: 'Friday 6:00 PM',
    );
    expect(before, contains('re-pick'));
    expect(before, isNot(contains('@leader')));
  });

  test('availability confirmations refer to the working re-pick label', () {
    final available = messages.msg3(const [], const []);
    final unavailable = messages.msg6();

    expect(available, contains('re-pick'));
    expect(available, isNot(contains('/repick')));
    expect(unavailable, contains('re-pick'));
    expect(unavailable, isNot(contains('/repick')));
  });

  test('confirmation no longer promises allocation at a later sharp hour', () {
    final text = messages.msg3(const [], const [], allocateAt: '6:00 PM');
    expect(text, isNot(contains('allocated at 6:00 PM')));
  });

  test('confirmation lists booked 🔒 and offered 🟢 slots separately', () {
    const want = Slot(0, 'sat', 'am', 'ocbc');
    const avail = Slot(0, 'sat', 'pm', 'pasirRis');
    final text = messages.msg3(const [want], const [avail],
        label: (s) => '${s.location == 'ocbc' ? 'OCBC' : 'PR'} '
            '${Slot.dayLabel(s.day)} ${s.slot.toUpperCase()}');
    expect(text, contains('🔒 OCBC Sat AM'));
    expect(text, contains('🟢 PR Sat PM'));
  });

  test('the allocation hour is the next sharp hour after indicating', () {
    expect(Flows.nextSharpHourLabel(DateTime(2026, 8, 12, 14, 23)), '3:00 PM');
    expect(Flows.nextSharpHourLabel(DateTime(2026, 8, 12, 15, 0)), '4:00 PM');
    expect(Flows.nextSharpHourLabel(DateTime(2026, 8, 12, 23, 30)), '12:00 AM');
    expect(Flows.nextSharpHourLabel(DateTime(2026, 8, 12, 0, 5)), '1:00 AM');
  });

  test('cancel button appears only after the member has responded', () {
    final w = RollingWindow.fromSat0(DateTime(2026, 8, 15));
    final now = DateTime(2026, 8, 12); // Wednesday, both weekends open
    final kbNo = CycleServiceNotifications.buildKeyboard(
      w,
      (const {}, const {}),
      now: now,
      sessions: defaultSessions(w.sat0),
      locationName: (k) => k,
    );
    final labelsNo = kbNo.inlineKeyboard
        .expand((r) => r)
        .map((b) => b.text)
        .toList();
    expect(labelsNo.contains('❌ Cancel'), isFalse);
    final kbYes = CycleServiceNotifications.buildKeyboard(
      w,
      (const {}, const {}),
      now: now,
      hasIndicated: true,
      sessions: defaultSessions(w.sat0),
      locationName: (k) => k,
    );
    final labelsYes = kbYes.inlineKeyboard
        .expand((r) => r)
        .map((b) => b.text)
        .toList();
    expect(labelsYes.contains('❌ Cancel'), isTrue);
  });

  test('repick names locked weekends and the holiday opt-out', () {
    final w = RollingWindow.fromSat0(DateTime(2026, 8, 15));
    final keyboard = CycleServiceNotifications.buildKeyboard(
      w,
      (const {}, const {}),
      now: DateTime(2026, 8, 17),
      holidays: [
        Holiday(
          id: 1,
          weekStart: DateTime(2026, 8, 10),
          kind: HolidayKind.winter,
        ),
      ],
      sessions: defaultSessions(w.sat0),
      locationName: (k) => k,
    );
    final labels = keyboard.inlineKeyboard
        .expand((row) => row)
        .map((button) => button.text)
        .toList();
    expect(labels, contains('Sat 15 Aug (locked)'));
    expect(labels, contains('🔕 Skip me for the whole winter holiday'));
  });

  test('full limited sessions show allocated capacity and are not selectable', () {
    final w = RollingWindow.fromSat0(DateTime(2026, 8, 15));
    final limited = Session(
      id: 99,
      weekendStart: w.sat0,
      day: 'sat',
      slot: 'limited',
      location: 'ocbc',
      start: DateTime(2026, 8, 15, 9),
      end: DateTime(2026, 8, 15, 15),
      maxPeople: 3,
    );
    final keyboard = CycleServiceNotifications.buildKeyboard(
      w,
      (const {}, const {}),
      now: DateTime(2026, 8, 12),
      sessions: [limited],
       allocatedCounts: {capacityKey(limited): 3},
      locationName: (k) => k,
    );
    final buttons = keyboard.inlineKeyboard.expand((row) => row).toList();
    final full = buttons.firstWhere((button) => button.text.contains('[3/3]'));
    expect(full.text, contains('⛔'));
    expect(full.callbackData, startsWith('full|'));
  });
}


Future<void> _json(
  HttpRequest req,
  Map<String, dynamic> body, {
  int status = 200,
}) async {
  req.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(body));
  await req.response.close();
}
