import 'package:test/test.dart';
import 'package:sdsc_bot/bot/keyboards.dart';
import 'package:sdsc_bot/bot/command_catalog.dart';

void main() {
  test('catalog omits every role grid button function', () {
    final cases =
        <({String role, bool console, bool admin, bool gadmin, String? tier})>[
          (
            role: 'member',
            console: false,
            admin: false,
            gadmin: false,
            tier: 'member',
          ),
          (
            role: 'out-member',
            console: false,
            admin: false,
            gadmin: false,
            tier: 'out-member',
          ),
          (
            role: 'check',
            console: false,
            admin: false,
            gadmin: false,
            tier: 'check',
          ),
          (
            role: 'old',
            console: false,
            admin: false,
            gadmin: false,
            tier: 'old',
          ),
          (
            role: 'admin',
            console: false,
            admin: true,
            gadmin: false,
            tier: 'member',
          ),
          (
            role: 'gadmin',
            console: false,
            admin: true,
            gadmin: true,
            tier: 'member',
          ),
          (
            role: 'console-only',
            console: true,
            admin: false,
            gadmin: false,
            tier: null,
          ),
          (
            role: 'member',
            console: true,
            admin: false,
            gadmin: false,
            tier: 'member',
          ),
          (
            role: 'check',
            console: true,
            admin: false,
            gadmin: false,
            tier: 'check',
          ),
          (
            role: 'old',
            console: true,
            admin: false,
            gadmin: false,
            tier: 'old',
          ),
          (
            role: 'admin',
            console: true,
            admin: true,
            gadmin: false,
            tier: 'member',
          ),
          (
            role: 'gadmin',
            console: true,
            admin: true,
            gadmin: true,
            tier: 'member',
          ),
        ];
    for (final testCase in cases) {
      final commands = CommandCatalog.commands(
        isConsole: testCase.console,
        isAdmin: testCase.admin,
        isGlobalAdmin: testCase.gadmin,
        tier: testCase.tier,
      );
      final buttons = RoleKeyboard.gridButtons(
        testCase.role,
      ).map((button) => button.command).toSet();
      for (final entry in commands) {
        expect(entry.command, startsWith('/'));
        expect(entry.command, isNot('more-cmd'));
        expect(
          buttons,
          isNot(contains(entry.command)),
          reason: '${testCase.role}: ${entry.command}',
        );
      }
    }
    expect(
      CommandCatalog.commands(
        isConsole: false,
        isAdmin: false,
        isGlobalAdmin: false,
        tier: 'member',
      ),
      isEmpty,
    );
    expect(
      CommandCatalog.commands(
        isConsole: false,
        isAdmin: false,
        isGlobalAdmin: false,
        tier: 'out-member',
      ),
      isEmpty,
    );
    expect(
      CommandCatalog.commands(
        isConsole: false,
        isAdmin: false,
        isGlobalAdmin: false,
        tier: 'check',
      ),
      isEmpty,
    );
    expect(
      CommandCatalog.commands(
        isConsole: false,
        isAdmin: false,
        isGlobalAdmin: false,
        tier: 'old',
      ),
      isEmpty,
    );
    final admin = CommandCatalog.commands(
      isConsole: false,
      isAdmin: true,
      tier: 'member',
      isGlobalAdmin: false,
    );
    expect(admin.map((entry) => entry.display), [
      '/all_users - list registered members',
      '/allocate - run the allocation now',
      '/group_user - show your group\'s member details',
      '/manual_mark_group_attend - correct an attendance balance in your group',
      '/prompt - send availability prompts now',
      '/remind - remind non-responders now',
      '/set_exp - change a member\'s experience',
    ]);
    final gadmin = CommandCatalog.commands(
      isConsole: false,
      isAdmin: true,
      isGlobalAdmin: true,
      tier: 'member',
    );
    expect(gadmin.map((entry) => entry.command), [
      '/add_admin',
      '/add_check',
      '/assign_group',
      '/demote',
      '/manual_mark_all_attend',
      '/rm_allocate_entry',
      '/rm_user',
      '/sync_calendar',
      ...admin.map((entry) => entry.command),
    ]);
    expect(gadmin.map((entry) => entry.command), isNot(contains('/hold')));
    expect(gadmin.map((entry) => entry.command), isNot(contains('/unhold')));
    expect(gadmin.map((entry) => entry.command), isNot(contains('/settime')));
    final consoleOnly = CommandCatalog.commands(
      isConsole: true,
      isAdmin: false,
      isGlobalAdmin: false,
      tier: null,
    );
    expect(consoleOnly.map((entry) => entry.command), [
      '/add_alias',
      '/add_global_admin',
      '/add_key',
      '/add_location',
      '/check_status',
      '/grid',
      '/keys',
      '/locations',
      '/reset_date',
      '/reset_grid',
      '/rm_global_admin',
      '/rm_key',
      '/set_date',
      '/start',
    ]);
    expect(
      consoleOnly.map((entry) => entry.command),
      isNot(contains('/add_admin')),
    );
    expect(
      consoleOnly.map((entry) => entry.display),
      contains('/add_location [name] - approve or add a location'),
    );
  });

  test('role sections preserve actual roles and presentation order', () {
    List<String> sections({
      bool console = false,
      bool admin = false,
      bool gadmin = false,
      String? tier = 'member',
    }) => CommandCatalog.roleSections(
      isConsole: console,
      isAdmin: admin,
      isGlobalAdmin: gadmin,
      tier: tier,
    );

    expect(sections(console: true, admin: true, gadmin: true), [
      'Console',
      'Global admin',
      'Admin',
      'Member',
    ]);
    expect(sections(console: true, admin: true), [
      'Console',
      'Admin',
      'Member',
    ]);
    expect(sections(gadmin: true), ['Global admin', 'Admin', 'Member']);
    expect(sections(admin: true), ['Admin', 'Member']);
    expect(sections(console: true, tier: null), ['Console']);
    expect(sections(tier: 'out-member'), ['Out-member']);
    expect(sections(tier: 'check'), ['Checker']);
  });

  test('sectioned catalog has exact role order and additional commands', () {
    final consoleOnly = CommandCatalog.sections(
      isConsole: true,
      isAdmin: false,
      isGlobalAdmin: false,
      tier: null,
    );
    expect(consoleOnly.map((section) => section.title), ['Console']);
    expect(consoleOnly.single.commands.map((entry) => entry.command), [
      '/add_alias',
      '/add_global_admin',
      '/add_key',
      '/add_location',
      '/check_status',
      '/grid',
      '/keys',
      '/locations',
      '/reset_date',
      '/reset_grid',
      '/rm_global_admin',
      '/rm_key',
      '/set_date',
      '/start',
    ]);

    final admin = CommandCatalog.sections(
      isConsole: false,
      isAdmin: true,
      isGlobalAdmin: false,
      tier: 'member',
    );
    expect(admin.map((section) => section.title), ['Admin']);
    expect(admin.single.commands.map((entry) => entry.command), [
      '/all_users',
      '/allocate',
      '/group_user',
      '/manual_mark_group_attend',
      '/prompt',
      '/remind',
      '/set_exp',
    ]);

    final gadmin = CommandCatalog.sections(
      isConsole: false,
      isAdmin: false,
      isGlobalAdmin: true,
      tier: 'member',
    );
    expect(gadmin.map((section) => section.title), ['Global admin', 'Admin']);
    expect(
      gadmin
          .expand((section) => section.commands)
          .map((entry) => entry.command),
      [
        '/add_admin',
        '/add_check',
        '/assign_group',
        '/demote',
        '/manual_mark_all_attend',
        '/rm_allocate_entry',
        '/rm_user',
        '/sync_calendar',
        '/all_users',
        '/allocate',
        '/group_user',
        '/manual_mark_group_attend',
        '/prompt',
        '/remind',
        '/set_exp',
      ],
    );

    final consoleAdmin = CommandCatalog.sections(
      isConsole: true,
      isAdmin: true,
      isGlobalAdmin: false,
      tier: 'member',
    );
    expect(consoleAdmin.map((section) => section.title), ['Console', 'Admin']);
    expect(consoleAdmin.first.commands.map((entry) => entry.command), [
      '/add_alias',
      '/add_global_admin',
      '/add_key',
      '/add_location',
      '/check_status',
      '/grid',
      '/keys',
      '/locations',
      '/reset_date',
      '/reset_grid',
      '/rm_global_admin',
      '/rm_key',
      '/set_date',
    ]);
    expect(
      consoleAdmin
          .expand((section) => section.commands)
          .map((entry) => entry.command),
      isNot(contains('/hold')),
    );

    final consoleGlobalAdmin = CommandCatalog.sections(
      isConsole: true,
      isAdmin: false,
      isGlobalAdmin: true,
      tier: 'member',
    );
    expect(consoleGlobalAdmin.map((section) => section.title), [
      'Console',
      'Global admin',
      'Admin',
    ]);
    expect(
      consoleGlobalAdmin.first.commands.map((entry) => entry.command),
      isNot(contains('/start')),
    );

    for (final section in [
      ...consoleOnly,
      ...admin,
      ...gadmin,
      ...consoleAdmin,
      ...consoleGlobalAdmin,
    ]) {
      final commandNames = section.commands
          .map((entry) => entry.command)
          .toList();
      expect(
        commandNames,
        orderedEquals([...commandNames]..sort()),
        reason: '${section.title} commands should be alphabetic',
      );
      for (final entry in section.commands) {
        expect(entry.usage, isNot(contains('<')));
        expect(entry.usage, isNot(contains('>')));
        expect(entry.command, isNot('/status'));
        expect(entry.command, isNot('/users'));
      }
    }
  });
}
