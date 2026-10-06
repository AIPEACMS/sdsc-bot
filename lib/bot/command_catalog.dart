import '../core/models.dart';
import 'keyboards.dart';

/// One registered slash command and its concise help text.
class CommandHelp {
  final String command;
  final String usage;
  final String description;

  const CommandHelp(this.command, this.description, {this.usage = ''});

  String get display =>
      '$command${usage.isEmpty ? '' : ' $usage'} - $description';
}

/// Slash commands exposed by More Commands, grouped by their handler
/// permissions. Grid-backed functions are filtered using the caller's actual
/// role, never their console grid preview.
class CommandCatalog {
  CommandCatalog._();

  static const List<CommandHelp> _member = [
    CommandHelp('/start', 'show the welcome and role buttons'),
    CommandHelp('/repick', 'update your availability'),
    CommandHelp('/setinfo', 'update your preferred name'),
    CommandHelp('/mystatus', 'show your picks and allocation'),
  ];
  static const List<CommandHelp> _checker = [
    CommandHelp('/check-status', 'show the current week\'s allocation'),
  ];
  static const List<CommandHelp> _outMember = [
    CommandHelp('/notify', 'choose how often to receive prompts'),
  ];
  static const List<CommandHelp> _admin = [
    CommandHelp('/allstatus', 'show cycle state and responders'),
    CommandHelp('/groupstatus', 'show your group\'s cycle state and responders'),
    CommandHelp('/allusers', 'list registered members'),
    CommandHelp('/groupusers', 'show your group\'s member details'),
    CommandHelp('/prompt', 'send availability prompts now'),
    CommandHelp('/remind', 'remind non-responders now'),
    CommandHelp('/ask', 'send one member an availability picker', usage: '[telegram_id]'),
    CommandHelp('/setexp', 'change a member\'s experience'),
    CommandHelp('/allocate', 'run the allocation now'),
  ];
  static const List<CommandHelp> _globalAdmin = [
    CommandHelp('/addadmin', 'promote a registered user', usage: '@handle'),
    CommandHelp('/addcheck', 'add a checker', usage: '@handle'),
    CommandHelp('/demote', 'demote an admin', usage: '@handle'),
    CommandHelp('/sync-calendar', 'push the calendar YAML'),
  ];
  static const List<CommandHelp> _console = [
    CommandHelp('/grid', 'preview role grids'),
    CommandHelp('/resetgrid', 'return to your console grid'),
    CommandHelp('/setdate', 'set a custom or calendar date', usage: '[date]'),
    CommandHelp('/resetdate', 'return to the real date'),
    CommandHelp('/addkey', 'register a console app key'),
    CommandHelp('/keys', 'list console app keys'),
    CommandHelp('/rmkey', 'remove a console app key', usage: '<key>'),
    CommandHelp('/addg', 'appoint the global admin', usage: '@handle'),
    CommandHelp('/rmg', 'remove the global admin', usage: '[@handle]'),
    CommandHelp('/locations', 'list locations and their aliases'),
    CommandHelp('/addlocation', 'approve or add a location', usage: '<name>'),
    CommandHelp('/addalias', 'add location aliases; send done to finish', usage: '<location>'),
  ];

  /// Returns commands available to this caller, excluding functions already
  /// represented by buttons in their real grid. Only console/admin/gadmin
  /// callers have a More Commands button; checkers retain console access to
  /// `/check-status` when the console identity is also a checker.
  static List<CommandHelp> commands({
    required bool isConsole,
    required bool isAdmin,
    required bool isGlobalAdmin,
    required String? tier,
  }) {
    if (!isConsole && !isAdmin && !isGlobalAdmin) return const [];

    final role = RoleKeyboard.roleFor(
      isConsole: isConsole,
      isAdmin: isAdmin,
      isGlobalAdmin: isGlobalAdmin,
      tier: tier,
    );
    final result = <CommandHelp>[
      if (tier == MemberTier.check || isConsole) ..._checker,
      if (tier == MemberTier.outMember) ..._outMember,
      if (isConsole &&
          tier != MemberTier.member &&
          tier != MemberTier.outMember &&
          !isAdmin &&
          !isGlobalAdmin)
        _member.first,
      if (tier == MemberTier.member ||
          tier == MemberTier.outMember ||
          isAdmin ||
          isGlobalAdmin)
        ..._member,
      if (isAdmin || isGlobalAdmin) ..._admin,
      if (isGlobalAdmin) ..._globalAdmin,
      if (isConsole) ..._console,
    ];
    final buttonFunctions = RoleKeyboard.gridButtons(role)
        .map((button) => button.command)
        .whereType<String>()
        .toSet();
    return result
        .where((entry) => !buttonFunctions.contains(entry.command))
        .toList(growable: false);
  }
}
