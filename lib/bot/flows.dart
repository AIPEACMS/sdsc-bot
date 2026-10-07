import 'package:televerse/televerse.dart';
import 'package:televerse/telegram.dart' hide Location, User;

import '../core/models.dart';
import '../core/domain/capacity.dart';
import '../core/repo.dart';
import '../core/config.dart';
import '../core/log.dart';
import '../core/messages.dart';
import 'command_both.dart';
import 'command_catalog.dart';
import 'keyboards.dart';
import 'service.dart';
import 'state.dart';
import '../core/schedule.dart';

/// Member-facing commands: gated /start, availability picking, and the
/// seen-user bookkeeping that lets admins add members by handle.

part 'flows/registration.dart';
part 'flows/availability.dart';
part 'flows/callbacks.dart';
part 'flows/presentation.dart';

class _FlowsBase {
  final Bot bot;

  final Repo repo;

  final Config config;

  final Messages messages;

  final BotState state;

  final CycleService service;

  final ScheduleRuntime scheduleRuntime;

  Future<void> Function()? onAvailabilitySaved;
  Future<void> Function(Context ctx, int userId, String text)? onBroadcastText;
  Future<void> Function(Context ctx, int userId, String text)? onAddUserText;
  Future<void> Function(Context ctx, int userId, String text)? onRemoveUserText;
  void Function(int userId, String command)? onPendingInputCleared;

  _FlowsBase({
    required this.bot,
    required this.repo,
    required this.config,
    required this.messages,
    required this.state,
    required this.service,
    ScheduleRuntime? scheduleRuntime,
  }) : scheduleRuntime =
           scheduleRuntime ?? ScheduleRuntime(repo: repo, config: config);

  final int _profileSteps = 1;

  /// Set by main.dart: applies the typed date of the /setdate wizard.
  Future<void> Function(Context ctx, int userId, String text)? onSetDateText;

  /// Set by main.dart: applies the pasted YAML of the /synccalendar wizard.
  Future<void> Function(Context ctx, int userId, String text)?
  onSyncCalendarText;

  /// Set by main.dart: the gadmin's /settime wizard line(s).
  Future<void> Function(Context ctx, int userId, String text)? onSetTimeText;

  /// Set by main.dart: the full name typed for a new location in /settime.
  Future<void> Function(Context ctx, int userId, String text)?
  onSetTimeNewNameText;

  /// Set by main.dart: one alias typed in the console's /addalias wizard.
  Future<void> Function(Context ctx, int userId, String text)? onAddAliasText;
}

class Flows extends _FlowsBase {
  Flows({
    required super.bot,
    required super.repo,
    required super.config,
    required super.messages,
    required super.state,
    required super.service,
    super.scheduleRuntime,
  });

  @Deprecated('Immediate allocation is the default in v3.2.0.')
  static String nextSharpHourLabel(DateTime now) =>
      FlowsPresentation.nextSharpHourLabel(now);
}
