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

  /// Out-members keep the complete availability grid and can choose how often
  /// the weekly availability prompt is sent to them.
  static const List<GridButton> outMemberButtons = [
    ...memberButtons,
    GridButton('notify', '/notify', RoleColor.member),
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
    GridButton('add-out-user', '/addoutuser', RoleColor.admin),
    GridButton('group-status', '/groupstatus', RoleColor.admin),
    GridButton('group-users', '/groupusers', RoleColor.admin),
    GridButton('ask', '/ask', RoleColor.admin),
    GridButton('mark-attend', '/confirm', RoleColor.admin),
    GridButton('broadcast', '/broadcast', RoleColor.admin),
    ...memberButtons,
  ];

  static const List<GridButton> globalAdminButtons = [
    GridButton('hold', '/hold', RoleColor.globalAdmin),
    GridButton('unhold', '/unhold', RoleColor.globalAdmin),
    GridButton('set-time', '/settime', RoleColor.globalAdmin),
    ...adminButtons,
  ];

  /// Console-only commands remain typed commands, not grid buttons. A
  /// console-only identity therefore has no normal member grid.
  static const List<GridButton> consoleButtons = [];

  /// Kept as a named alias for callers that used the old composed preview.
  static const List<GridButton> consoleGlobalAdminButtons = globalAdminButtons;

  /// The full button list for [role]. `console-only` deliberately has no
  /// member buttons: console identity is independent of a stored user role.
  static List<GridButton> gridButtons(String role) => switch (role) {
    'console-only' => consoleButtons,
    'console' => consoleButtons,
    'gadmin' => globalAdminButtons,
    'console-gadmin' => globalAdminButtons,
    'admin' => adminButtons,
    'check' => checkButtons,
    MemberTier.outMember => outMemberButtons,
    'console-old' => oldButtons,
    'old' => oldButtons,
    _ => memberButtons,
  };

  /// The grid a user should see by default (highest tier wins).
  static String roleFor({
    required bool isConsole,
    bool isGlobalAdmin = false,
    required bool isAdmin,
    String? tier,
  }) {
    if (isConsole) {
      if (isGlobalAdmin) return 'gadmin';
      if (isAdmin) return 'admin';
      if (tier == null) return 'console-only';
      if (MemberTier.stored.contains(tier)) return tier;
      return 'console-only';
    }
    if (isGlobalAdmin) return 'gadmin';
    if (isAdmin) return 'admin';
    if (tier != null && MemberTier.stored.contains(tier)) return tier;
    return MemberTier.member;
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
