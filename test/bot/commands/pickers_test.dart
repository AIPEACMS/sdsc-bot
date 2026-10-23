import 'package:test/test.dart';
import 'package:sdsc_bot/bot/pickers.dart';
import 'package:sdsc_bot/bot/state.dart';
import 'package:sdsc_bot/core/models.dart';

void main() {
  List<User> members(int n) => [
        for (var i = 0; i < n; i++)
          User(id: i, name: 'Member $i', experience: Experience.newbie, group: 'A'),
      ];

  group('Pickers.memberPicker', () {
    test('slices members per page (6 per page)', () {
      final kb = Pickers.memberPicker(
        action: 'ask',
        members: members(13),
        page: 0,
      );
      // 6 member rows + 1 pagination row + cancel row.
      expect(kb.inlineKeyboard.length, 8);
      expect(kb.inlineKeyboard[0].length, 1);
      final total = kb.inlineKeyboard.expand((r) => r).length;
      expect(total, 6 + 2 + 1); // 6 members + pagination(2) + cancel
    });

    test('page 2 shows the next slice', () {
      final kb = Pickers.memberPicker(
        action: 'ask',
        members: members(13),
        page: 2,
      );
      // 1 member on page 2 (13 = 6+6+1).
      final memberRows = kb.inlineKeyboard.where((r) =>
          r.isNotEmpty && r.first.text.startsWith('Member')).toList();
      expect(memberRows.length, 1);
      expect(memberRows.first.first.text, 'Member 12');
    });

    test('page clamps beyond the end', () {
      final kb = Pickers.memberPicker(
        action: 'ask',
        members: members(3),
        page: 99,
      );
      final total = kb.inlineKeyboard.expand((r) => r).length;
      expect(total, 3 + 1); // 3 members + cancel
    });

    test('no pagination row when one page fits', () {
      final kb = Pickers.memberPicker(
        action: 'ask',
        members: members(3),
        page: 0,
      );
      final labels = kb.inlineKeyboard
          .expand((r) => r)
          .map((b) => b.text)
          .toList();
      expect(labels.any((t) => t == '⬅' || t == '➡'), isFalse);
      expect(labels.contains('❌ Cancel'), isTrue);
    });

    test('parsePick extracts action/page/target', () {
      final parts = 'mpick|ask|2|42'.split('|');
      final (action, page, target) = Pickers.parsePick(parts);
      expect(action, 'ask');
      expect(page, 2);
      expect(target, '42');
    });
  });

  group('PendingArg', () {
    test('not expired right after creation', () {
      final p = PendingArg('broadcast');
      expect(p.isExpired, isFalse);
    });
  });
}
