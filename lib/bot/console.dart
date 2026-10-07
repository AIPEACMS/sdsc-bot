import 'package:televerse/televerse.dart';
import 'package:televerse/telegram.dart' hide Location, User;

import '../core/config.dart';
import '../core/log.dart';
import '../core/models.dart';
import '../core/repo.dart';
import 'calendar_sync.dart';
import 'command_both.dart';
import 'hold.dart';
import 'pickers.dart';
import 'settime.dart';
import 'state.dart';

/// Console control-plane commands. The console is separate from the global
/// admin; when the two identities are the same, both command sets apply.

part 'console/registration.dart';
part 'console/users.dart';
part 'console/schedule.dart';

class _ConsoleBase {

  final Bot bot;

  final Repo repo;

  final Config config;

  final BotState state;

  final CalendarSync? calendarSync;

  final HoldGate holdGate;

  SetTime? setTime;
  final Map<int, int> _pendingGlobalAdmin = {};
  final Map<int, int> _pendingGlobalAdminRemoval = {};
  final Map<int, List<String>> _pendingUserRemoval = {};
  final Map<int, (String, List<String>)> _aliasFlow = {};

  _ConsoleBase({
    required this.bot,
    required this.repo,
    required this.config,
    required this.state,
    this.calendarSync,
    required this.holdGate,
    this.setTime,
  });
}

class Console extends _ConsoleBase {
  Console({
    required super.bot,
    required super.repo,
    required super.config,
    required super.state,
    super.calendarSync,
    required super.holdGate,
    super.setTime,
  });
}
