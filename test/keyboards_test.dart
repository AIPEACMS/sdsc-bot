import 'package:test/test.dart';
import 'package:sdsc_bot/bot/keyboards.dart';

void main() {
  test('grids are strictly nested: member ⊂ admin ⊂ console', () {
    final member = RoleKeyboard.memberButtons.map((b) => b.command).toSet();
    final admin = RoleKeyboard.adminButtons.map((b) => b.command).toSet();
    final console = RoleKeyboard.consoleButtons.map((b) => b.command).toSet();

    expect(member.difference(admin).isEmpty, isTrue);
    expect(admin.difference(console).isEmpty, isTrue);
    expect(admin.length, greaterThan(member.length));
    expect(console.length, greaterThan(admin.length));
  });

  test('labels carry no leading slash', () {
    for (final b in [
      ...RoleKeyboard.memberButtons,
      ...RoleKeyboard.adminButtons,
      ...RoleKeyboard.consoleButtons,
    ]) {
      expect(b.label.startsWith('/'), isFalse, reason: b.label);
    }
  });

  test('every word in a label is 8 chars or fewer (no Telegram wrap)', () {
    for (final b in [
      ...RoleKeyboard.memberButtons,
      ...RoleKeyboard.adminButtons,
      ...RoleKeyboard.consoleButtons,
    ]) {
      for (final word in b.label.split(RegExp(r'[ -]'))) {
        expect(word.length, lessThanOrEqualTo(8),
            reason: '${b.label} (word "$word" is too long)');
      }
    }
  });

  test('each grid has distinct labels', () {
    for (final grid in [
      RoleKeyboard.memberButtons,
      RoleKeyboard.adminButtons,
      RoleKeyboard.consoleButtons,
    ]) {
      final labels = grid.map((b) => b.label).toSet();
      expect(labels.length, grid.length,
          reason: 'duplicate label in grid');
    }
  });

  test('colors: member=green, admin=blue, console=red', () {
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
    final consoleOnly = RoleKeyboard.consoleButtons
        .where((b) => b.color != RoleColor.admin &&
            b.color != RoleColor.member)
        .toList();
    expect(consoleOnly.isNotEmpty, isTrue);
    for (final b in consoleOnly) {
      expect(b.color, RoleColor.console, reason: b.label);
    }
    // Telegram style values.
    expect(RoleColor.member.style, 'success');
    expect(RoleColor.admin.style, 'primary');
    expect(RoleColor.console.style, 'danger');
  });

  test('roleFor picks the highest role', () {
    expect(RoleKeyboard.roleFor(isConsole: false, isAdmin: false), 'member');
    expect(RoleKeyboard.roleFor(isConsole: false, isAdmin: true), 'admin');
    expect(RoleKeyboard.roleFor(isConsole: true, isAdmin: false), 'console');
    expect(RoleKeyboard.roleFor(isConsole: true, isAdmin: true), 'console');
  });

  test('roleFor honours the check/old tiers', () {
    expect(RoleKeyboard.roleFor(
        isConsole: false, isAdmin: false, tier: 'check'), 'check');
    expect(RoleKeyboard.roleFor(
        isConsole: false, isAdmin: false, tier: 'old'), 'old');
    // Admin tier wins over a stored check/old tier.
    expect(RoleKeyboard.roleFor(
        isConsole: false, isAdmin: true, tier: 'old'), 'admin');
    expect(RoleKeyboard.roleFor(
        isConsole: true, isAdmin: false, tier: 'old'), 'console');
  });

  test('gridButtons resolves each role', () {
    expect(RoleKeyboard.gridButtons('console'),
        RoleKeyboard.consoleButtons);
    expect(RoleKeyboard.gridButtons('admin'), RoleKeyboard.adminButtons);
    expect(RoleKeyboard.gridButtons('member'), RoleKeyboard.memberButtons);
    expect(RoleKeyboard.gridButtons('check'), RoleKeyboard.checkButtons);
    expect(RoleKeyboard.gridButtons('old'), isEmpty);
  });

  test('console keeps exactly two extra buttons: hold + unhold', () {
    final console = RoleKeyboard.consoleButtons.toSet();
    final admin = RoleKeyboard.adminButtons.toSet();
    final consoleOnly = console.difference(admin);
    expect(consoleOnly.map((b) => b.command), hasLength(2));
    expect(consoleOnly.map((b) => b.command), containsAll(['/hold', '/unhold']));
  });

  test('admin grid no longer has set-group', () {
    expect(
        RoleKeyboard.adminButtons.map((b) => b.command), isNot(contains('/setgroup')));
  });

  test('check grid is a single button', () {
    expect(RoleKeyboard.checkButtons, hasLength(1));
    expect(RoleKeyboard.checkButtons.single.command, '/check-status');
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
}
