import 'package:televerse/televerse.dart';
import 'package:televerse/telegram.dart' hide Location, User;

import '../core/models.dart';
import '../core/domain/capacity.dart';
import '../core/repo.dart';
import '../core/config.dart';
import '../core/messages.dart';
import '../core/allocate.dart';
import 'hold.dart';
import '../core/log.dart';
import 'state.dart';

/// High-level operations that drive the rolling schedule: prompting,
/// reminding, allocating each weekend and delivering allocation messages.
/// Used by both the scheduler and the admin commands.

part 'service/prompts.dart';
part 'service/allocation.dart';
part 'service/notifications.dart';

String _dayShort(DateTime d) =>
    '${d.day} ${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.month - 1]}';

String _fmt(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class _CycleServiceBase {

  static List<Holiday> holidaysForWindow(Repo repo, RollingWindow w) =>
      CycleServicePrompts.holidaysForWindow(repo, w);

  static InlineKeyboard buildKeyboard(
    RollingWindow w,
    (Set<Slot>, Set<Slot>) picked, {
    bool holiday = false,
    List<Holiday> holidays = const [],
    Map<String, int> allocatedCounts = const {},
    Set<String> ownCapacityGroups = const {},
    bool hasIndicated = false,
    required DateTime now,
    required List<Session> sessions,
    required String Function(String locationKey) locationName,
  }) => CycleServiceNotifications.buildKeyboard(
        w,
        picked,
        holiday: holiday,
        holidays: holidays,
        allocatedCounts: allocatedCounts,
        ownCapacityGroups: ownCapacityGroups,
        hasIndicated: hasIndicated,
        now: now,
        sessions: sessions,
        locationName: locationName,
      );

  final Repo repo;

  final Config config;

  final Messages messages;

  final BotState state;

  final Bot bot;

  _CycleServiceBase({
    required this.repo,
    required this.config,
    required this.messages,
    required this.state,
    required this.bot,
  });
}

class CycleService extends _CycleServiceBase {
  CycleService({
    required super.repo,
    required super.config,
    required super.messages,
    required super.state,
    required super.bot,
  });

  static List<Holiday> holidaysForWindow(Repo repo, RollingWindow w) =>
      CycleServicePrompts.holidaysForWindow(repo, w);

  static InlineKeyboard buildKeyboard(
    RollingWindow w,
    (Set<Slot>, Set<Slot>) picked, {
    bool holiday = false,
    List<Holiday> holidays = const [],
    Map<String, int> allocatedCounts = const {},
    Set<String> ownCapacityGroups = const {},
    bool hasIndicated = false,
    required DateTime now,
    required List<Session> sessions,
    required String Function(String locationKey) locationName,
  }) => CycleServiceNotifications.buildKeyboard(
        w,
        picked,
        holiday: holiday,
        holidays: holidays,
        allocatedCounts: allocatedCounts,
        ownCapacityGroups: ownCapacityGroups,
        hasIndicated: hasIndicated,
        now: now,
        sessions: sessions,
        locationName: locationName,
      );
}
