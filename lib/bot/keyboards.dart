import 'package:televerse/telegram.dart' as tg
    show KeyboardButton, StyleType;
import 'package:televerse/televerse.dart';

import '../core/models.dart';

/// Style colors for reply-keyboard buttons, matching Telegram's button
/// `style` values: green (member), blue (admin), red (console).
enum RoleColor {
  member('success', 'green'),
  admin('primary', 'blue'),
  console('danger', 'red');

  /// The Telegram style value for this color.
  final String style;

  /// Human-readable name, used in tests and messages.
  final String label;

  const RoleColor(this.style, this.label);

  /// The televerse [StyleType] for this color.
  tg.StyleType get styleType => switch (this) {
        RoleColor.member => tg.StyleType.success,
        RoleColor.admin => tg.StyleType.primary,
        RoleColor.console => tg.StyleType.danger,
      };
}

/// A command grid button: the label shown in the grid and the command it
/// triggers (label has no leading slash; command is the slash form).
class GridButton {
  final String label;
  final String command;
  final RoleColor color;

  const GridButton(this.label, this.command, this.color);
}

/// Reply-keyboard grids (the persistent button grid above the message bar).
///
/// Three grids, one per role, strictly nested:
///   member  ⊂  admin  ⊂  console
/// A user sees the grid of their highest role — the grids never merge or
/// compete. The console can temporarily preview the admin/member grids via
/// /grid (a debug view; see [gridButtons]).
///
/// Colors: member buttons are green, admin blue, console red. A member sees
/// only green; an admin sees blue + green; the console sees all three.
class RoleKeyboard {
  RoleKeyboard._();

  static const List<GridButton> memberButtons = [
    GridButton('start', '/start', RoleColor.member),
    GridButton('re-pick', '/reindicate', RoleColor.member),
    GridButton('my-status', '/mystatus', RoleColor.member),
  ];

  /// The `check` tier's single button: they are not members and only report
  /// on the current week's allocation.
  static const List<GridButton> checkButtons = [
    GridButton('check-status', '/check-status', RoleColor.member),
  ];

  /// The `old` tier has no buttons at all — they are no longer members.
  static const List<GridButton> oldButtons = [];

  static const List<GridButton> adminButtons = [
    GridButton('add-user', '/adduser', RoleColor.admin),
    GridButton('status', '/status', RoleColor.admin),
    GridButton('users', '/users', RoleColor.admin),
    GridButton('prompt', '/prompt', RoleColor.admin),
    GridButton('remind', '/remind', RoleColor.admin),
    GridButton('ask', '/ask', RoleColor.admin),
    GridButton('mark-attend', '/confirm', RoleColor.admin),
    GridButton('set-exp', '/setexp', RoleColor.admin),
    ...memberButtons,
  ];

  /// The console keeps exactly two extra buttons: hold and unhold. Everything
  /// else the console used to do lives in the desktop console app now.
  static const List<GridButton> consoleButtons = [
    GridButton('hold', '/hold', RoleColor.console),
    GridButton('unhold', '/unhold', RoleColor.console),
    ...adminButtons,
  ];

  /// The full button list for [role] ('console' | 'admin' | 'check' |
  /// 'member' | 'old').
  static List<GridButton> gridButtons(String role) => switch (role) {
        'console' => consoleButtons,
        'admin' => adminButtons,
        'check' => checkButtons,
        'old' => oldButtons,
        _ => memberButtons,
      };

  /// The grid a user should see by default (highest tier wins).
  static String roleFor({
    required bool isConsole,
    required bool isAdmin,
    String tier = MemberTier.member,
  }) {
    if (isConsole) return 'console';
    if (isAdmin) return 'admin';
    return MemberTier.order.contains(tier) ? tier : MemberTier.member;
  }

  /// Builds the persistent, resized reply keyboard for [role] with up to
  /// [columns] buttons per row. Labels carry no leading slash; buttons are
  /// colored by role tier.
  static Keyboard build(String role, {int columns = 4}) {
    final rows = <List<tg.KeyboardButton>>[];
    final buttons = gridButtons(role);
    for (var i = 0; i < buttons.length; i += columns) {
      final row = buttons
          .skip(i)
          .take(columns)
          .map((b) => Keyboard.buttonText(b.label, style: b.color.styleType))
          .toList();
      rows.add(row);
    }
    return Keyboard(keyboard: rows)
        .resized()
        .persistent()
        .placeholder('Tap a button, or type /help for the full list');
  }
}

