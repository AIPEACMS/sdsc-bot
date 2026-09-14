import 'package:televerse/telegram.dart' as tg show KeyboardButton, StyleType;
import 'package:televerse/televerse.dart';

import '../core/models.dart';

/// Style colors for reply-keyboard buttons, matching Telegram's button
/// `style` values: green (member), blue (admin), red (console).
enum RoleColor {
  member('success', 'green'),
  admin('primary', 'blue'),
  globalAdmin('danger', 'red'),
  console('success', 'green');

  /// The Telegram style value for this color.
  final String style;

  /// Human-readable name, used in tests and messages.
  final String label;

  const RoleColor(this.style, this.label);

  /// The televerse [StyleType] for this color.
  tg.StyleType get styleType => switch (this) {
    RoleColor.member => tg.StyleType.success,
    RoleColor.admin => tg.StyleType.primary,
    RoleColor.globalAdmin => tg.StyleType.danger,
    RoleColor.console => tg.StyleType.success,
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
/// Separate grids exist for the member, admin, global-admin, and console
/// roles. A console who is also the global admin sees their two grids composed
/// explicitly; unrelated roles never merge implicitly.
///
/// Colors: member buttons are green, admin blue, global-admin red, and
/// console green.
class RoleKeyboard {
  RoleKeyboard._();

  static const List<GridButton> memberButtons = [
    GridButton('start', '/start', RoleColor.member),
    GridButton('re-pick', '/repick', RoleColor.member),
    GridButton('set-info', '/setinfo', RoleColor.member),
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
    GridButton('all-status', '/status', RoleColor.admin),
    GridButton('group-status', '/groupstatus', RoleColor.admin),
    GridButton('all-users', '/users', RoleColor.admin),
    GridButton('group-users', '/groupusers', RoleColor.admin),
    GridButton('ask', '/ask', RoleColor.admin),
    GridButton('mark-attend', '/confirm', RoleColor.admin),
    GridButton('set-exp', '/setexp', RoleColor.admin),
    GridButton('broadcast', '/broadcast', RoleColor.admin),
    ...memberButtons,
  ];

  static const List<GridButton> globalAdminButtons = [
    GridButton('hold', '/hold', RoleColor.globalAdmin),
    GridButton('unhold', '/unhold', RoleColor.globalAdmin),
    GridButton('add-user', '/adduser', RoleColor.globalAdmin),
    GridButton('all-status', '/status', RoleColor.globalAdmin),
    GridButton('group-status', '/groupstatus', RoleColor.globalAdmin),
    GridButton('all-users', '/users', RoleColor.globalAdmin),
    GridButton('group-users', '/groupusers', RoleColor.globalAdmin),
    GridButton('ask', '/ask', RoleColor.globalAdmin),
    GridButton('mark-attend', '/confirm', RoleColor.globalAdmin),
    GridButton('set-exp', '/setexp', RoleColor.globalAdmin),
    GridButton('broadcast', '/broadcast', RoleColor.globalAdmin),
    ...memberButtons,
  ];

  static const List<GridButton> consoleOnlyButtons = [
    GridButton('add-key', '/addkey', RoleColor.console),
    GridButton('keys', '/keys', RoleColor.console),
    GridButton('rm-key', '/rmkey', RoleColor.console),
    GridButton('set-date', '/setdate', RoleColor.console),
    GridButton('reset-date', '/resetdate', RoleColor.console),
    GridButton('grid', '/grid', RoleColor.console),
    GridButton('reset-grid', '/resetgrid', RoleColor.console),
    GridButton('add-gadmin', '/add-gadmin', RoleColor.console),
    GridButton('rm-gadmin', '/rm-gadmin', RoleColor.console),
  ];

  static const List<GridButton> consoleButtons = [
    ...consoleOnlyButtons,
    ...memberButtons,
  ];

  static const List<GridButton> consoleGlobalAdminButtons = [
    ...consoleOnlyButtons,
    ...globalAdminButtons,
  ];

  /// The full button list for [role] ('console' | 'gadmin' | 'admin' |
  /// 'console-gadmin' | 'console-old' | 'check' | 'member' | 'old').
  static List<GridButton> gridButtons(String role) => switch (role) {
    'console' => consoleButtons,
    'gadmin' => globalAdminButtons,
    'console-gadmin' => consoleGlobalAdminButtons,
    'console-old' => consoleOnlyButtons,
    'admin' => adminButtons,
    'check' => checkButtons,
    'old' => oldButtons,
    _ => memberButtons,
  };

  /// The grid a user should see by default (highest tier wins).
  static String roleFor({
    required bool isConsole,
    bool isGlobalAdmin = false,
    required bool isAdmin,
    String tier = MemberTier.member,
  }) {
    if (isConsole) {
      if (isGlobalAdmin) return 'console-gadmin';
      if (tier == MemberTier.old) return 'console-old';
      return 'console';
    }
    if (isGlobalAdmin) return 'gadmin';
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
        .placeholder('Tap a button below, or type /start to see your options');
  }
}
