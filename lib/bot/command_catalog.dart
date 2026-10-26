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
    CommandHelp('/all_users', 'list registered members'),
    CommandHelp('/group_user', 'show your group\'s member details'),
    CommandHelp('/prompt', 'send availability prompts now'),
    CommandHelp('/remind', 'remind non-responders now'),
    CommandHelp('/set_exp', 'change a member\'s experience'),
    CommandHelp('/allocate', 'run the allocation now'),
    CommandHelp(
      '/manual_mark_group_attend',
      'correct an attendance balance in your group',
    ),
  ];
  static const List<CommandHelp> _globalAdmin = [
    CommandHelp('/add_admin', 'promote a registered user', usage: '@handle'),
    CommandHelp('/add_check', 'add a checker', usage: '@handle'),
    CommandHelp('/demote', 'demote an admin', usage: '@handle'),
    CommandHelp(
      '/rm_user',
      'remove active users or pending registrations',
      usage: '[@handle ...]',
    ),
    CommandHelp('/sync_calendar', 'push the calendar YAML'),
    CommandHelp('/assign_group', 'assign members to admin-led groups'),
    CommandHelp(
      '/rm_allocate_entry',
      'remove selected current-window allocations',
    ),
    CommandHelp(
      '/manual_mark_all_attend',
      'correct attendance balance for active members',
    ),
  ];
  static const List<CommandHelp> _console = [
    CommandHelp('/check_status', 'test the checker\'s check-status'),
    CommandHelp('/start', 'show the welcome and role buttons'),
    CommandHelp('/grid', 'preview role grids'),
    CommandHelp('/reset_grid', 'return to your console grid'),
    CommandHelp('/set_date', 'set a custom or calendar date', usage: '[date]'),
    CommandHelp('/reset_date', 'return to the real date'),
    CommandHelp('/add_key', 'register a console app key'),
    CommandHelp('/keys', 'list console app keys'),
    CommandHelp('/rm_key', 'remove a console app key', usage: '[key]'),
    CommandHelp(
      '/add_global_admin',
      'appoint the global admin',
      usage: '@handle',
    ),
    CommandHelp(
      '/rm_global_admin',
      'remove the global admin',
      usage: '[@handle]',
    ),
    CommandHelp('/locations', 'list locations and their aliases'),
    CommandHelp('/add_location', 'approve or add a location', usage: '[name]'),
    CommandHelp(
      '/add_alias',
      'add location aliases; send done to finish',
      usage: '[location]',
    ),
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
    ).map((button) => button.command).whereType<String>().toSet();
    List<CommandHelp> additional(List<CommandHelp> commands) => commands
        .where((entry) => !buttonFunctions.contains(entry.command))
        .toList(growable: false);

    final result = <CommandSection>[
      if (isConsole) CommandSection('Console', additional(_console)),
      if (isGlobalAdmin)
        CommandSection('Global admin', additional(_globalAdmin)),
      if (isAdmin || isGlobalAdmin) CommandSection('Admin', additional(_admin)),
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
