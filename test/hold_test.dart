import 'package:test/test.dart';
import 'package:televerse/televerse.dart';

import 'package:sdsc_bot/bot/hold.dart';

void main() {
  APICaller recording(List<String> calls) {
    return (String method, [Payload? payload]) async {
      calls.add(method);
      return {'ok': true, 'result': <String, dynamic>{}};
    };
  }

  test('while held, send* and edit* calls are dropped (block & drop)', () async {
    final gate = HoldGate(true);
    final t = HoldTransformer(gate);
    final calls = <String>[];

    await expectLater(t.transform(recording(calls), 'sendMessage'),
        throwsA(isA<HeldException>()));
    await expectLater(t.transform(recording(calls), 'editMessageText'),
        throwsA(isA<HeldException>()));
    await expectLater(t.transform(recording(calls), 'sendMediaGroup'),
        throwsA(isA<HeldException>()));
    expect(calls, isEmpty);
  });

  test('while held, non-message calls still pass through', () async {
    final gate = HoldGate(true);
    final t = HoldTransformer(gate);
    final calls = <String>[];

    final r = await t.transform(recording(calls), 'getUpdates');
    expect(r['ok'], isTrue);
    await t.transform(recording(calls), 'answerCallbackQuery');
    await t.transform(recording(calls), 'deleteMessage');
    expect(calls, ['getUpdates', 'answerCallbackQuery', 'deleteMessage']);
  });

  test('when not held, everything passes through', () async {
    final gate = HoldGate(false);
    final t = HoldTransformer(gate);
    final calls = <String>[];

    await t.transform(recording(calls), 'sendMessage');
    await t.transform(recording(calls), 'getMe');
    expect(calls, ['sendMessage', 'getMe']);
  });

  test('gate can be flipped at runtime', () async {
    final gate = HoldGate(false);
    final t = HoldTransformer(gate);
    final calls = <String>[];

    await t.transform(recording(calls), 'sendMessage');
    gate.held = true;
    await expectLater(t.transform(recording(calls), 'sendMessage'),
        throwsA(isA<HeldException>()));
    expect(calls, ['sendMessage']);
  });
}