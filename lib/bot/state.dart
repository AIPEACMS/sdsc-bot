import '../core/models.dart';

/// Stage of the registration flow for a user.
enum RegStage { name, experience, group }

class RegistrationState {
  RegStage stage;
  String name;
  String? experience;

  RegistrationState({required this.stage, this.name = '', this.experience});
}

/// Transient in-memory state for the bot. Nothing here is durable — it only
/// tracks interactive flows in progress (registration + availability picks).
class BotState {
  final Map<int, RegistrationState> registrations = {};
  final Map<int, Set<Slot>> availabilityPicks = {};

  /// Inline-keyboard message ids for availability selection per user, so a
  /// new /reindicate or prompt replaces the old keyboard instead of stacking.
  final Map<int, (int chatId, int messageId)> availabilityMessages = {};

  void forgetAvailability(int userId) => availabilityPicks.remove(userId);

  Set<Slot> picksFor(int userId) =>
      availabilityPicks.putIfAbsent(userId, () => {});
}
