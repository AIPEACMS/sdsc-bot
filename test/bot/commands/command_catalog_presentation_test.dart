import 'package:test/test.dart';
import 'package:sdsc_bot/bot/keyboards.dart';

void main() {
  test(
    'visible role sections contain ordered labels without duplicate more-cmd',
    () {
      List<VisibleRoleSection> sections({
        bool console = false,
        bool admin = false,
        bool gadmin = false,
        String? tier = 'member',
      }) => RoleKeyboard.visibleSections(
        isConsole: console,
        isAdmin: admin,
        isGlobalAdmin: gadmin,
        tier: tier,
      );

      expect(
        sections(
          console: true,
          admin: true,
          gadmin: true,
        ).map((section) => section.title),
        ['Console', 'Global admin', 'Admin', 'Member'],
      );
      expect(
        sections(
          console: true,
          admin: true,
          gadmin: true,
        ).expand((section) => section.buttons).map((button) => button.label),
        [
          'more-cmd',
          'hold',
          'unhold',
          'set-time',
          'add-user',
          'add-out-user',
          'group-status',
          'all-status',
          'ask',
          'mark-attend',
          'broadcast',
          'start',
          '(re)pick',
          'set-info',
          'my-status',
        ],
      );
      expect(
        sections(console: true, admin: true, gadmin: true)
            .expand((section) => section.buttons)
            .where((button) => button.label == 'more-cmd'),
        hasLength(1),
      );
      expect(
        sections(
          console: true,
          admin: true,
          gadmin: true,
        ).first.buttons.single.color,
        RoleColor.globalAdmin,
      );
      expect(
        sections(console: true, admin: true).first.buttons.single.color,
        RoleColor.admin,
      );
      expect(
        sections(console: true, tier: null).first.buttons.single.color,
        RoleColor.console,
      );
      expect(sections(admin: true).first.buttons.first.color, RoleColor.admin);
      expect(
        sections(gadmin: true).first.buttons.first.color,
        RoleColor.globalAdmin,
      );
      expect(sections(console: true, admin: true).map((s) => s.title), [
        'Console',
        'Admin',
        'Member',
      ]);
      expect(sections(gadmin: true).map((s) => s.title), [
        'Global admin',
        'Admin',
        'Member',
      ]);
      expect(sections(admin: true).map((s) => s.title), ['Admin', 'Member']);
      expect(sections(console: true, tier: null).map((s) => s.title), [
        'Console',
      ]);
      expect(sections(tier: 'out-member').map((s) => s.title), ['Out-member']);
      expect(sections(tier: 'check').map((s) => s.title), ['Checker']);
      expect(
        sections(tier: 'check').single.buttons.single.label,
        'check-status',
      );
    },
  );
}
