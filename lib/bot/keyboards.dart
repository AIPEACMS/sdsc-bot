import 'package:televerse/televerse.dart';

/// Reply-keyboard grids (the persistent button grid above the message bar).
///
/// Three grids, one per role, strictly nested:
///   member  ⊂  admin  ⊂  console
/// A user sees the grid of their highest role — the grids never merge or
/// compete. The console can temporarily preview the admin/member grids via
/// /grid (a debug view; see [gridButtons]).
class RoleKeyboard {
  RoleKeyboard._();

  static const List<String> memberButtons = [
    '/start',
    '/reindicate',
    '/holiday',
  ];

  static const List<String> adminButtons = [
    '/adduser',
    '/status',
    '/users',
    '/prompt',
    '/remind',
    '/allocate',
    '/ask',
    '/confirm',
    '/setexp',
    '/setgroup',
    '/holidayset',
    '/holidayclear',
    '/broadcast',
    ...memberButtons,
  ];

  static const List<String> consoleButtons = [
    '/addadmin',
    '/setdate',
    '/resetdate',
    '/demote',
    ...adminButtons,
  ];

  /// The full grid for [role]. Used both to display and to preview.
  static List<String> gridButtons(String role) => switch (role) {
        'console' => consoleButtons,
        'admin' => adminButtons,
        _ => memberButtons,
      };

  /// The grid a user should see by default (highest role wins).
  static String roleFor({required bool isConsole, required bool isAdmin}) {
    if (isConsole) return 'console';
    if (isAdmin) return 'admin';
    return 'member';
  }

  /// Builds the persistent, resized reply keyboard for [role] with up to
  /// [columns] buttons per row.
  static Keyboard build(String role, {int columns = 4}) {
    return Keyboard.grid(gridButtons(role), columns: columns)
        .resized()
        .persistent()
        .placeholder('Tap a button, or type /help for the full list');
  }
}
