import 'package:sdsc_bot/bot/flows.dart';
import 'package:sdsc_bot/core/build_version.dart';
import 'package:sdsc_bot/core/repo.dart';
import 'package:test/test.dart';

import '../support/grid_harness.dart';

void main() {
  setUp(() async {
    await setUpGrid();
    useUniqueTelegramMessageIds = true;
    repo.setSetting('role_grid_refresh_${buildVersion}_2', '1');
  });

  for (final interrupt in ['/mystatus', '/start']) {
    test(
      'immediate $interrupt invalidates the older reminder opening',
      () async {
        final opening = sendText(2, '/config_remind');
        final interruption = sendText(2, interrupt);
        await Future.wait([opening, interruption]);

        final liveReminderIds = <int>[
          for (var index = 0; index < sent.length; index++)
            if ((sent[index]['text'] as String).startsWith('Turning off') &&
                fakeMessageMarkups[(2, sentMessageIds[index])] != null)
              sentMessageIds[index],
        ];
        final pending = state.reminderPreferenceFlows.containsKey(2);
        final openingPending = state.reminderPreferenceOpenings.containsKey(2);
        await flows.shutdown();

        expect(
          liveReminderIds,
          isEmpty,
          reason: 'a newer command must clear actual reminder controls',
        );
        expect(pending, isFalse);
        expect(openingPending, isFalse);
      },
    );
  }
}
