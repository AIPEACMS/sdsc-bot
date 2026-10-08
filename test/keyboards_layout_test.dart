import 'package:test/test.dart';
import 'package:sdsc_bot/bot/keyboards.dart';

void main() {

  test('gadmin adds only hold controls to the normal admin grid', () {
    final member = RoleKeyboard.memberButtons.map((b) => b.command).toSet();
    final outMember =
        RoleKeyboard.outMemberButtons.map((b) => b.command).toSet();
    final admin = RoleKeyboard.adminButtons.map((b) => b.command).toSet();
    final gadmin = RoleKeyboard.globalAdminButtons
        .map((b) => b.command)
        .toSet();
    final console = RoleKeyboard.consoleButtons.map((b) => b.command).toSet();
    final combined = RoleKeyboard.consoleGlobalAdminButtons
        .map((b) => b.command)
        .toSet();

    expect(member.difference(admin).isEmpty, isTrue);
    expect(admin.difference(gadmin).isEmpty, isTrue);
    expect(console, isEmpty);
    expect(outMember, contains('/notify'));
    expect(outMember.difference(member), {'/notify'});
    expect(combined, gadmin);
    expect(admin.length, greaterThan(member.length));
    expect(gadmin.difference(admin), {'/hold', '/unhold', '/settime'});
  });

  test('admin grid has exact ordered commands and role colors', () {
    expect(
      RoleKeyboard.adminButtons
          .map((button) => (button.label, button.command, button.color))
          .toList(),
      [
        ('add-user', '/adduser', RoleColor.admin),
        ('add-out-user', '/addoutuser', RoleColor.admin),
        ('group-status', '/groupstatus', RoleColor.admin),
        ('all-status', '/allstatus', RoleColor.admin),
        ('ask', '/ask', RoleColor.admin),
        ('mark-attend', '/confirm', RoleColor.admin),
        ('broadcast', '/broadcast', RoleColor.admin),
        ('start', '/start', RoleColor.member),
        ('(re)pick', '/repick', RoleColor.member),
        ('set-info', '/setinfo', RoleColor.member),
        ('my-status', '/mystatus', RoleColor.member),
      ],
    );
    expect(
      RoleKeyboard.adminButtons.map((button) => button.command),
      isNot(contains('/status')),
    );
    expect(
      RoleKeyboard.adminButtons.map((button) => button.command),
      isNot(contains('/users')),
    );
    expect(
      RoleKeyboard.globalAdminButtons.map((button) => button.command),
      isNot(contains('/status')),
    );
    expect(
      RoleKeyboard.globalAdminButtons.map((button) => button.command),
      isNot(contains('/users')),
    );
    expect(
      RoleKeyboard.globalAdminButtons.map((button) => button.command),
      containsAll(RoleKeyboard.adminButtons.map((button) => button.command)),
    );
  });

  test('labels carry no leading slash', () {
    for (final b in [
      ...RoleKeyboard.memberButtons,
      ...RoleKeyboard.adminButtons,
      ...RoleKeyboard.consoleButtons,
      ...RoleKeyboard.globalAdminButtons,
    ]) {
      expect(b.label.startsWith('/'), isFalse, reason: b.label);
    }
  });

  test('grid labels avoid Telegram wrapping except requested broadcast', () {
    for (final b in [
      ...RoleKeyboard.memberButtons,
      ...RoleKeyboard.adminButtons,
      ...RoleKeyboard.consoleButtons,
      ...RoleKeyboard.globalAdminButtons,
    ]) {
      for (final word in b.label.split(RegExp(r'[ -]'))) {
        if (word == 'broadcast') continue;
        expect(
          word.length,
          lessThanOrEqualTo(8),
          reason: '${b.label} (word "$word" is too long)',
        );
      }
    }
  });

  test('each grid has distinct labels', () {
    for (final grid in [
      RoleKeyboard.memberButtons,
      RoleKeyboard.adminButtons,
      RoleKeyboard.consoleButtons,
      RoleKeyboard.globalAdminButtons,
    ]) {
      final labels = grid.map((b) => b.label).toSet();
      expect(labels.length, grid.length, reason: 'duplicate label in grid');
    }
  });

  test('colors: member=green, admin=blue, global-admin=red, console=green', () {
    for (final b in RoleKeyboard.memberButtons) {
      expect(b.color, RoleColor.member, reason: b.label);
    }
    final adminOnly = RoleKeyboard.adminButtons
        .where((b) => b.color != RoleColor.member)
        .toList();
    expect(adminOnly.isNotEmpty, isTrue);
    for (final b in adminOnly) {
      expect(b.color, RoleColor.admin, reason: b.label);
    }
    final globalAdminOnly = RoleKeyboard.globalAdminButtons
        .where((b) => !RoleKeyboard.adminButtons.contains(b))
        .toList();
    expect(globalAdminOnly, hasLength(3));
    for (final b in globalAdminOnly) {
      expect(b.color, RoleColor.globalAdmin, reason: b.label);
    }
    for (final b in RoleKeyboard.globalAdminButtons
        .where(RoleKeyboard.adminButtons.contains)) {
      expect(
        b.color == RoleColor.admin || b.color == RoleColor.member,
        isTrue,
        reason: b.label,
      );
    }
    // Telegram style values.
    expect(RoleColor.member.style, 'success');
    expect(RoleColor.admin.style, 'primary');
    expect(RoleColor.globalAdmin.style, 'danger');
    expect(RoleColor.console.style, 'success');
  });

  test('roleFor picks the highest role', () {
    expect(RoleKeyboard.roleFor(isConsole: false, isAdmin: false), 'member');
    expect(RoleKeyboard.roleFor(isConsole: false, isAdmin: true), 'admin');
    expect(RoleKeyboard.roleFor(isConsole: true, isAdmin: false), 'console-only');
    expect(RoleKeyboard.roleFor(isConsole: true, isAdmin: true), 'admin');
    expect(
      RoleKeyboard.roleFor(
        isConsole: false,
        isGlobalAdmin: true,
        isAdmin: false,
      ),
      'gadmin',
    );
    expect(
      RoleKeyboard.roleFor(
        isConsole: true,
        isGlobalAdmin: true,
        isAdmin: false,
      ),
      'gadmin',
    );
  });

  test('roleFor honours the check/old tiers', () {
    expect(
      RoleKeyboard.roleFor(isConsole: false, isAdmin: false, tier: 'check'),
      'check',
    );
    expect(
      RoleKeyboard.roleFor(isConsole: false, isAdmin: false, tier: 'old'),
      'old',
    );
    // Admin tier wins over a stored check/old tier.
    expect(
      RoleKeyboard.roleFor(isConsole: false, isAdmin: true, tier: 'old'),
      'admin',
    );
    expect(
      RoleKeyboard.roleFor(isConsole: true, isAdmin: false, tier: 'old'),
      'old',
    );
  });

  test('gridButtons resolves each role', () {
    expect(RoleKeyboard.gridButtons('console-only'), RoleKeyboard.consoleButtons);
    expect(
      RoleKeyboard.gridButtons('gadmin'),
      RoleKeyboard.globalAdminButtons,
    );
    expect(RoleKeyboard.gridButtons('admin'), RoleKeyboard.adminButtons);
    expect(RoleKeyboard.gridButtons('member'), RoleKeyboard.memberButtons);
    expect(RoleKeyboard.gridButtons('check'), RoleKeyboard.checkButtons);
    expect(RoleKeyboard.gridButtons('old'), isEmpty);
  });

  test('console commands remain command-only', () {
    final commands = RoleKeyboard.consoleButtons.map((b) => b.command);
    expect(commands, isEmpty);
    expect(commands, isNot(contains('/addkey')));
    expect(commands, isNot(contains('/addg')));
    expect(commands, isNot(contains('/grid')));
  });

  test('admin grid no longer has set-group', () {
    expect(
      RoleKeyboard.adminButtons.map((b) => b.command),
      isNot(contains('/setgroup')),
    );
  });

  test('experience remains command-only while absent from both admin grids', () {
    expect(
      RoleKeyboard.adminButtons.map((b) => b.command),
      isNot(contains('/setexp')),
    );
    expect(
      RoleKeyboard.globalAdminButtons.map((b) => b.command),
      isNot(contains('/setexp')),
    );
  });

  test('check grid is a single button', () {
    expect(RoleKeyboard.checkButtons, hasLength(1));
    expect(RoleKeyboard.checkButtons.single.command, '/checkstatus');
  });

  test('built keyboard is persistent, resized, and buttons are styled', () {
    final kb = RoleKeyboard.build('member');
    expect(kb.isPersistent, isTrue);
    expect(kb.resizeKeyboard, isTrue);
    expect(kb.keyboard, isNotEmpty);
    expect(kb.buttonCount, RoleKeyboard.memberButtons.length);
    // Every button carries its role color style.
    for (final row in kb.keyboard) {
      for (final b in row) {
        expect(['success', 'primary', 'danger'], contains(b.style?.name));
      }
    }
  });

  test('More Commands leads admin grids with role colors', () {
    for (final (role, color) in [
      ('admin', RoleColor.admin),
      ('gadmin', RoleColor.globalAdmin),
    ]) {
      final buttons = RoleKeyboard.buttonsFor(role);
      expect(buttons.first.label, 'more-cmd');
      expect(buttons.first.command, isNull);
      expect(buttons.first.color, color);
      expect(
        buttons.skip(1).map((button) => button.command),
        RoleKeyboard.gridButtons(role).map((button) => button.command),
      );
      final keyboard = RoleKeyboard.build(role);
      final flattened = [
        for (final row in keyboard.keyboard) ...row.map((button) => button.text),
      ];
      expect(flattened, [
        'more-cmd',
        ...RoleKeyboard.gridButtons(role).map((button) => button.label),
      ]);
      final first = keyboard.keyboard.first.first;
      expect(first.text, 'more-cmd');
      expect(first.style?.name, color == RoleColor.admin ? 'primary' : 'danger');
    }

    final consoleOnlyButton =
        RoleKeyboard.build('console-only').keyboard.first.first;
    expect(consoleOnlyButton.text, 'more-cmd');
    expect(consoleOnlyButton.style?.name, 'success');
  });

  test('role combinations retain their complete ordered keyboards', () {
    List<(String, RoleColor)> buttons(String role, {bool console = false}) => [
      for (final button in RoleKeyboard.buttonsFor(
        role,
        consoleIdentity: console,
      ))
        (button.label, button.color),
    ];

    expect(buttons('console-only'), [('more-cmd', RoleColor.console)]);
    expect(
      buttons('admin'),
      [
        ('more-cmd', RoleColor.admin),
        ...RoleKeyboard.adminButtons.map((b) => (b.label, b.color)),
      ],
    );
    expect(
      buttons('gadmin'),
      [
        ('more-cmd', RoleColor.globalAdmin),
        ...RoleKeyboard.globalAdminButtons.map((b) => (b.label, b.color)),
      ],
    );
    expect(
      buttons('member'),
      RoleKeyboard.memberButtons.map((b) => (b.label, b.color)).toList(),
    );
    expect(
      buttons('out-member'),
      RoleKeyboard.outMemberButtons.map((b) => (b.label, b.color)).toList(),
    );
    expect(
      buttons('check'),
      RoleKeyboard.checkButtons.map((b) => (b.label, b.color)).toList(),
    );
  });

  test('console identity gets More Commands on lower-tier grids only', () {
    for (final role in ['member', 'out-member', 'check', 'old']) {
      expect(RoleKeyboard.buttonsFor(role, consoleIdentity: true).first,
          RoleKeyboard.moreCommandsButton);
      expect(RoleKeyboard.buttonsFor(role).map((button) => button.label),
          isNot(contains('more-cmd')));
    }
    expect(RoleKeyboard.buttonsFor('console-only').first.label, 'more-cmd');
    expect(RoleKeyboard.buttonsFor('admin').first.label, 'more-cmd');
    expect(RoleKeyboard.buttonsFor('gadmin').first.label, 'more-cmd');
    for (final role in ['member', 'out-member', 'check', 'old']) {
      expect(RoleKeyboard.build(role, consoleIdentity: true).keyboard.first.first.text,
          'more-cmd');
    }
  });
}
