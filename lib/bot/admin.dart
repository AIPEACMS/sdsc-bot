import 'package:televerse/televerse.dart';
import 'package:televerse/telegram.dart' hide Location, User;

import '../core/models.dart';
import '../core/repo.dart';
import '../core/config.dart';
import '../core/log.dart';
import 'command_both.dart';
import 'pickers.dart';
import 'service.dart';
import 'state.dart';
import '../core/schedule.dart';

/// Admin-facing commands and the attendance confirmation flow.

part 'admin/commands.dart';
part 'admin/users.dart';
part 'admin/broadcast.dart';
part 'admin/attendance.dart';

class _AdminBase {

  final Bot bot;

  final Repo repo;

  final Config config;

  final BotState state;

  final CycleService service;

  final ScheduleRuntime scheduleRuntime;

  final Map<int, List<String>> _pendingAddUser = {};
  final Map<int, String> _pendingAddTier = {};
  final Map<int, String> _pendingBroadcast = {};

  _AdminBase({
    required this.bot,
    required this.repo,
    required this.config,
    required this.state,
    required this.service,
    ScheduleRuntime? scheduleRuntime,
  }) : scheduleRuntime =
           scheduleRuntime ?? ScheduleRuntime(repo: repo, config: config);
}

class Admin extends _AdminBase {
  Admin({
    required super.bot,
    required super.repo,
    required super.config,
    required super.state,
    required super.service,
    super.scheduleRuntime,
  });
}
