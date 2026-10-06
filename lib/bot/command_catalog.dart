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

/// A heading and its additional slash commands.
class CommandSection {
  final String title;
  final List<CommandHelp> commands;

  const CommandSection(this.title, this.commands);
}

/// Shared role presentation and the commands exposed by More Commands.
/// Grid-backed functions are filtered using the caller's actual role, never
/// their console grid preview.
class CommandCatalog {
  CommandCatalog._();

  static const List<CommandHelp> _admin = [
    CommandHelp('/allstatus', 'show cycle state and responders'),
    CommandHelp('/allusers', 'list registered members'),
    CommandHelp('/prompt', 'send availability prompts now'),
    CommandHelp('/remind', 'remind non-responders now'),
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
    CommandHelp('/check-status', 'show the current week\'s allocation'),
    CommandHelp('/start', 'show the welcome and role buttons'),
    CommandHelp('/grid', 'preview role grids'),
    CommandHelp('/resetgrid', 'return to your console grid'),
    CommandHelp('/setdate', 'set a custom or calendar date', usage: '[date]'),
    CommandHelp('/resetdate', 'return to the real date'),
    CommandHelp('/addkey', 'register a console app key'),
    CommandHelp('/keys', 'list console app keys'),
    CommandHelp('/rmkey', 'remove a console app key', usage: '[key]'),
    CommandHelp('/addg', 'appoint the global admin', usage: '@handle'),
    CommandHelp('/rmg', 'remove the global admin', usage: '[@handle]'),
    CommandHelp('/locations', 'list locations and their aliases'),
    CommandHelp('/addlocation', 'approve or add a location', usage: '[name]'),
    CommandHelp('/addalias', 'add location aliases; send done to finish', usage: '[location]'),
  ];

  /// Returns the role headings shown by `/start`, in presentation order.
  static List<String> roleSections({
    required bool isConsole,
    required bool isAdmin,
    required bool isGlobalAdmin,
    required String? tier,
  }) {
    return [
      if (isConsole) 'Console',
      if (isGlobalAdmin) 'Global admin',
      if (isAdmin || isGlobalAdmin) 'Admin',
      if (tier == MemberTier.member) 'Member',
      if (tier == MemberTier.outMember) 'Out-member',
      if (tier == MemberTier.check) 'Checker',
    ];
  }

  /// Returns additional commands grouped by the caller's actual roles.
  /// Member, out-member, and checker users do not receive a menu. A console
  /// with one of those stored tiers still receives the console menu because
  /// console identity is independent of the stored tier.
  static List<CommandSection> sections({
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
    final buttonFunctions = RoleKeyboard.buttonsFor(
      role,
      consoleIdentity: isConsole,
    )
        .map((button) => button.command)
        .whereType<String>()
        .toSet();
    List<CommandHelp> additional(List<CommandHelp> commands) => commands
        .where((entry) => !buttonFunctions.contains(entry.command))
        .toList(growable: false);

    final result = <CommandSection>[
      if (isConsole) CommandSection('Console', additional(_console)),
      if (isGlobalAdmin)
        CommandSection('Global admin', additional(_globalAdmin)),
      if (isAdmin || isGlobalAdmin)
        CommandSection('Admin', additional(_admin)),
    ];
    return result.where((section) => section.commands.isNotEmpty).toList();
  }

  /// Flat compatibility view for callers that only need the entries.
  static List<CommandHelp> commands({
    required bool isConsole,
    required bool isAdmin,
    required bool isGlobalAdmin,
    required String? tier,
  }) => [
    for (final section in sections(
      isConsole: isConsole,
      isAdmin: isAdmin,
      isGlobalAdmin: isGlobalAdmin,
      tier: tier,
    ))
      ...section.commands,
  ];
}
