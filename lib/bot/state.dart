import '../core/models.dart';

/// A pending text-input step in an interactive flow (e.g. "type the message
/// to broadcast"). Lives only in memory; expires after [timeout].
class PendingArg {
  final String command; // which command is awaiting input, e.g. 'broadcast'
  final DateTime createdAt;

  static const Duration timeout = Duration(minutes: 10);

  PendingArg(this.command) : createdAt = DateTime.now();

  bool get isExpired => DateTime.now().difference(createdAt) > timeout;
}

/// Transient in-memory state for the bot. Nothing here is durable — it only
/// tracks interactive flows in progress (availability picks) and the console's
/// grid preview.
class BotState {
  /// Per user, the in-progress availability pick: (want, available) slot sets.
  /// want = tapped to 🔒 (commitment), available = tapped to 🟢 (backup).
  final Map<int, (Set<Slot>, Set<Slot>)> availabilityPicks = {};

  /// Inline-keyboard message ids for availability selection per user, so a
  /// new /repick or prompt replaces the old keyboard instead of stacking.
  final Map<int, (int chatId, int messageId)> availabilityMessages = {};

  /// The console's grid preview: which role's grid is currently shown
  /// ('console' | 'admin' | 'check' | 'member'). Absent = console's own grid.
  final Map<int, String> gridPreview = {};

  /// Users waiting for a text argument (e.g. the message to broadcast).
  final Map<int, PendingArg> pendingArg = {};

  /// Users mid-way through the 4-step profile wizard (full name → preferred
  /// name → matric no. → school email). Value = the next step index (0..3).
  final Map<int, int> profileStep = {};

  /// Whether the member had profile fields saved *before* the wizard started
  /// (drives the Cancel button — only shown when re-running /setinfo over
  /// existing data, never mid-walk over freshly typed answers).
  final Map<int, bool> profileCancel = {};

  void forgetAvailability(int userId) => availabilityPicks.remove(userId);

  /// The in-progress (want, available) pick sets for [userId], creating them
  /// if absent.
  (Set<Slot>, Set<Slot>) picksFor(int userId) => availabilityPicks.putIfAbsent(
      userId, () => (<Slot>{}, <Slot>{}));
}
