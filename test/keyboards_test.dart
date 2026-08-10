import 'package:test/test.dart';
import 'package:sdsc_bot/bot/keyboards.dart';

void main() {
  test('grids are strictly nested: member ⊂ admin ⊂ console', () {
    final member = RoleKeyboard.memberButtons.toSet();
    final admin = RoleKeyboard.adminButtons.toSet();
    final console = RoleKeyboard.consoleButtons.toSet();

    expect(member.difference(admin).isEmpty, isTrue);
    expect(admin.difference(console).isEmpty, isTrue);
    expect(admin.length, greaterThan(member.length));
    expect(console.length, greaterThan(admin.length));
  });

  test('roleFor picks the highest role', () {
    expect(RoleKeyboard.roleFor(isConsole: false, isAdmin: false), 'member');
    expect(RoleKeyboard.roleFor(isConsole: false, isAdmin: true), 'admin');
    expect(RoleKeyboard.roleFor(isConsole: true, isAdmin: false), 'console');
    expect(RoleKeyboard.roleFor(isConsole: true, isAdmin: true), 'console');
  });

  test('gridButtons resolves each role', () {
    expect(RoleKeyboard.gridButtons('console'),
        RoleKeyboard.consoleButtons);
    expect(RoleKeyboard.gridButtons('admin'), RoleKeyboard.adminButtons);
    expect(RoleKeyboard.gridButtons('member'), RoleKeyboard.memberButtons);
  });

  test('built keyboard is persistent and resized', () {
    final kb = RoleKeyboard.build('member');
    expect(kb.isPersistent, isTrue);
    expect(kb.resizeKeyboard, isTrue);
    expect(kb.keyboard, isNotEmpty);
    // 3 member buttons, one row of up to 4 columns.
    expect(kb.buttonCount, RoleKeyboard.memberButtons.length);
  });
}
