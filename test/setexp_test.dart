import 'package:test/test.dart';

import 'package:sdsc_bot/sdsc_bot.dart';
import 'support/grid_harness.dart';
import 'package:sdsc_bot/core/models.dart';

void main() {
  setUp(setUpGrid);

  test('setexp only lists users whose experience will change', () async {
    repo.upsertUser(
      const User(
        id: 10,
        name: '@newbie',
        experience: Experience.newbie,
        group: '1',
      ),
    );
    repo.upsertUser(
      const User(
        id: 11,
        name: '@experienced',
        experience: Experience.experienced,
        group: '1',
      ),
    );

    await sendText(2, '/setexp');
    await sendCallback(2, 'setval|setexp|experienced');
    expect(_inlineTexts(edited.last), contains('@newbie'));
    expect(_inlineTexts(edited.last), isNot(contains('@experienced')));

    await sendText(2, '/setexp');
    await sendCallback(2, 'setval|setexp|newbie');
    expect(_inlineTexts(edited.last), isNot(contains('@newbie')));
    expect(_inlineTexts(edited.last), contains('@experienced'));
  });
}

List<String> _inlineTexts(Map<String, dynamic> body) {
  final keyboard =
      (body['reply_markup'] as Map<String, dynamic>?)?['inline_keyboard'];
  if (keyboard is! List) return const [];
  return [
    for (final row in keyboard)
      for (final button in row as List)
        (button as Map<String, dynamic>)['text'] as String,
  ];
}
