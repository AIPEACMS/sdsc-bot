import 'package:televerse/televerse.dart';
import 'package:televerse/telegram.dart' hide Location, User;

import '../core/config.dart';
import '../core/log.dart';
import '../core/models.dart';
import '../core/repo.dart';
import '../core/schedule_parse.dart';
import 'command_both.dart';
import 'pickers.dart';
import 'service.dart';
import 'state.dart';
import '../core/schedule.dart';

/// `/settime` — guided schedule changes for the global admin. The gadmin can
/// add, remove, or rewrite recurring sessions, or apply one temporary change
/// to one open week. The command is also exposed as the `set-time` grid button.

part 'settime/command.dart';
part 'settime/draft.dart';
part 'settime/validation.dart';
part 'settime/persistence.dart';
part 'settime/part_05.dart';

class _SetTimeBase {

  final Bot bot;

  final Repo repo;

  final Config config;

  final BotState state;

  final CycleService service;

  final ScheduleRuntime scheduleRuntime;

  _SetTimeBase({
    required this.bot,
    required this.repo,
    required this.config,
    required this.state,
    required this.service,
    ScheduleRuntime? scheduleRuntime,
  }) : scheduleRuntime =
           scheduleRuntime ?? ScheduleRuntime(repo: repo, config: config);
}

class SetTime
    extends _SetTimeBase
    with _SetTime1, _SetTime2, _SetTime3, _SetTime4, _SetTime5 {
  SetTime({
    required super.bot,
    required super.repo,
    required super.config,
    required super.state,
    required super.service,
    super.scheduleRuntime,
  });
}
