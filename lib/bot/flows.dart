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

NotificationPreference? _parseNotificationPreference(String raw) =>
    switch (raw.toLowerCase()) {
      'weekly' || 'week' => NotificationPreference.weekly,
      'every-other' || 'every_other' || 'everyother' =>
        NotificationPreference.everyOther,
      'never' => NotificationPreference.never,
      _ => null,
    };

String _notificationLabel(NotificationPreference preference) =>
    switch (preference) {
      NotificationPreference.weekly => 'every week',
      NotificationPreference.everyOther => 'every other week',
      NotificationPreference.never => 'never',
    };

String _notifyUsage() => 'Usage: /notify weekly|every-other|never';

String _hm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

String _day(DateTime date) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${date.day} ${months[date.month - 1]}';
}

String _html(String text) =>
    text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _slotLabel(Slot slot, RollingWindow w, Repo repo) {
  final date = slot.weekendIndex == 0 ? w.sat0 : w.sat1;
  final location = repo.locationName(slot.location);
  final match = repo.sessionsForWeekend(date).where((s) =>
      s.day == slot.day && s.slot == slot.slot && s.location == slot.location).firstOrNull;
  if (match == null) return '${Slot.dayLabel(slot.day)} · $location';
  return '${Slot.dayLabel(match.day)} · $location · ${_hm(match.start)}-${_hm(match.end)}';
}

class Flows with _Flows1, _Flows2, _Flows3, _Flows4 {

  @Deprecated('Immediate allocation is the default in v3.2.0.')
  static String nextSharpHourLabel(DateTime now) =>
      _Flows4.nextSharpHourLabel(now);

  final Bot bot;

  final Repo repo;

  final Config config;

  final Messages messages;

  final BotState state;

  final CycleService service;

  final ScheduleRuntime scheduleRuntime;

  Flows({
    required this.bot,
    required this.repo,
    required this.config,
    required this.messages,
    required this.state,
    required this.service,
    ScheduleRuntime? scheduleRuntime,
  }) : scheduleRuntime =
           scheduleRuntime ?? ScheduleRuntime(repo: repo, config: config);

  static const int _profileSteps = 1;

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
