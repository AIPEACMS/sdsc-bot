import 'package:televerse/televerse.dart';

/// Registers a command so it responds to both `/name` and a grid button
/// press, which sends the plain label text (no leading slash) as a message.
///
/// Usage in a class's `register()`:
/// ```dart
/// commandBoth(bot, 'status', _status, 'status');
/// ```
void commandBoth(
  Bot bot,
  String command,
  UpdateHandler handler, {
  String? label,
}) {
  bot.command(command, handler);
  bot.hears(label ?? command, handler);
}
