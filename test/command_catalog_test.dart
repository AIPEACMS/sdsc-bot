import 'package:test/test.dart';
import 'package:sdsc_bot/bot/keyboards.dart';
import 'package:sdsc_bot/bot/command_catalog.dart';

void main() {

  test('catalog omits every role grid button function', () {
    final cases = <({
      String role,
      bool console,
      bool admin,
      bool gadmin,
      String? tier,
    })>[
      (role: 'member', console: false, admin: false, gadmin: false, tier: 'member'),
      (role: 'out-member', console: false, admin: false, gadmin: false, tier: 'out-member'),
      (role: 'check', console: false, admin: false, gadmin: false, tier: 'check'),
      (role: 'old', console: false, admin: false, gadmin: false, tier: 'old'),
      (role: 'admin', console: false, admin: true, gadmin: false, tier: 'member'),
      (role: 'gadmin', console: false, admin: true, gadmin: true, tier: 'member'),
      (role: 'console-only', console: true, admin: false, gadmin: false, tier: null),
      (role: 'member', console: true, admin: false, gadmin: false, tier: 'member'),
      (role: 'check', console: true, admin: false, gadmin: false, tier: 'check'),
      (role: 'old', console: true, admin: false, gadmin: false, tier: 'old'),
      (role: 'admin', console: true, admin: true, gadmin: false, tier: 'member'),
      (role: 'gadmin', console: true, admin: true, gadmin: true, tier: 'member'),
    ];
    for (final testCase in cases) {
      final commands = CommandCatalog.commands(
        isConsole: testCase.console,
        isAdmin: testCase.admin,
        isGlobalAdmin: testCase.gadmin,
        tier: testCase.tier,
      );
      final buttons = RoleKeyboard.gridButtons(testCase.role)
          .map((button) => button.command)
          .toSet();
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
      '/allusers - list registered members',
      '/groupuser - show your group\'s member details',
      '/prompt - send availability prompts now',
      '/remind - remind non-responders now',
      '/setexp - change a member\'s experience',
      '/allocate - run the allocation now',
    ]);
    final gadmin = CommandCatalog.commands(
      isConsole: false,
      isAdmin: true,
      isGlobalAdmin: true,
      tier: 'member',
    );
    expect(gadmin.map((entry) => entry.command), [
      '/addadmin',
      '/addcheck',
      '/demote',
      '/removeuser',
      '/synccalendar',
      '/assigngroup',
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
      '/checkstatus',
      '/start',
      '/grid',
      '/resetgrid',
      '/setdate',
      '/resetdate',
      '/addkey',
      '/keys',
      '/rmkey',
      '/addg',
      '/rmg',
      '/locations',
      '/addlocation',
      '/addalias',
    ]);
    expect(
      consoleOnly.map((entry) => entry.command),
      isNot(contains('/addadmin')),
    );
    expect(
      consoleOnly.map((entry) => entry.display),
      contains('/addlocation [name] - approve or add a location'),
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

  test('visible role sections contain ordered labels without duplicate more-cmd', () {
    List<VisibleRoleSection> sections({
      bool console = false,
      bool admin = false,
      bool gadmin = false,
      String? tier = 'member',
    }) => RoleKeyboard.visibleSections(
      isConsole: console,
      isAdmin: admin,
      isGlobalAdmin: gadmin,
      tier: tier,
    );

    expect(
      sections(console: true, admin: true, gadmin: true)
          .map((section) => section.title),
      ['Console', 'Global admin', 'Admin', 'Member'],
    );
    expect(
      sections(console: true, admin: true, gadmin: true)
          .expand((section) => section.buttons)
          .map((button) => button.label),
      [
        'more-cmd',
        'hold', 'unhold', 'set-time',
        'add-user', 'add-out-user', 'group-status', 'all-status',
        'ask', 'mark-attend', 'broadcast',
        'start', '(re)pick', 'set-info', 'my-status',
      ],
    );
    expect(
      sections(console: true, admin: true, gadmin: true)
          .expand((section) => section.buttons)
          .where((button) => button.label == 'more-cmd'),
      hasLength(1),
    );
    expect(
      sections(console: true, admin: true, gadmin: true).first.buttons.single.color,
      RoleColor.globalAdmin,
    );
    expect(
      sections(console: true, admin: true).first.buttons.single.color,
      RoleColor.admin,
    );
    expect(
      sections(console: true, tier: null).first.buttons.single.color,
      RoleColor.console,
    );
    expect(
      sections(admin: true).first.buttons.first.color,
      RoleColor.admin,
    );
    expect(
      sections(gadmin: true).first.buttons.first.color,
      RoleColor.globalAdmin,
    );
    expect(sections(console: true, admin: true).map((s) => s.title),
        ['Console', 'Admin', 'Member']);
    expect(sections(gadmin: true).map((s) => s.title),
        ['Global admin', 'Admin', 'Member']);
    expect(sections(admin: true).map((s) => s.title), ['Admin', 'Member']);
    expect(sections(console: true, tier: null).map((s) => s.title), ['Console']);
    expect(sections(tier: 'out-member').map((s) => s.title), ['Out-member']);
    expect(sections(tier: 'check').map((s) => s.title), ['Checker']);
    expect(sections(tier: 'check').single.buttons.single.label, 'check-status');
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
      '/checkstatus',
      '/start',
      '/grid',
      '/resetgrid',
      '/setdate',
      '/resetdate',
      '/addkey',
      '/keys',
      '/rmkey',
      '/addg',
      '/rmg',
      '/locations',
      '/addlocation',
      '/addalias',
    ]);

    final admin = CommandCatalog.sections(
      isConsole: false,
      isAdmin: true,
      isGlobalAdmin: false,
      tier: 'member',
    );
    expect(admin.map((section) => section.title), ['Admin']);
    expect(admin.single.commands.map((entry) => entry.command), [
      '/allusers',
      '/groupuser',
      '/prompt',
      '/remind',
      '/setexp',
      '/allocate',
    ]);

    final gadmin = CommandCatalog.sections(
      isConsole: false,
      isAdmin: false,
      isGlobalAdmin: true,
      tier: 'member',
    );
    expect(gadmin.map((section) => section.title), ['Global admin', 'Admin']);
    expect(gadmin.expand((section) => section.commands).map((entry) => entry.command), [
      '/addadmin',
      '/addcheck',
      '/demote',
      '/removeuser',
      '/synccalendar',
      '/assigngroup',
      '/allusers',
      '/groupuser',
      '/prompt',
      '/remind',
      '/setexp',
      '/allocate',
    ]);

    final consoleAdmin = CommandCatalog.sections(
      isConsole: true,
      isAdmin: true,
      isGlobalAdmin: false,
      tier: 'member',
    );
    expect(consoleAdmin.map((section) => section.title), ['Console', 'Admin']);
    expect(consoleAdmin.first.commands.map((entry) => entry.command), [
      '/checkstatus',
      '/grid',
      '/resetgrid',
      '/setdate',
      '/resetdate',
      '/addkey',
      '/keys',
      '/rmkey',
      '/addg',
      '/rmg',
      '/locations',
      '/addlocation',
      '/addalias',
    ]);
    expect(
      consoleAdmin.expand((section) => section.commands).map((entry) => entry.command),
      isNot(contains('/hold')),
    );

    final consoleGlobalAdmin = CommandCatalog.sections(
      isConsole: true,
      isAdmin: false,
      isGlobalAdmin: true,
      tier: 'member',
    );
    expect(
      consoleGlobalAdmin.map((section) => section.title),
      ['Console', 'Global admin', 'Admin'],
    );
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
      for (final entry in section.commands) {
        expect(entry.usage, isNot(contains('<')));
        expect(entry.usage, isNot(contains('>')));
        expect(entry.command, isNot('/status'));
        expect(entry.command, isNot('/users'));
      }
    }
  });
}
