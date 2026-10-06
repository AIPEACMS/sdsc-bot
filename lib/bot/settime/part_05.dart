part of '../settime.dart';

/// In-progress /settime draft for one gadmin.
class _Draft {
  final List<ParsedSession> lines = [];

  _SetTimeScope scope = _SetTimeScope.persistent;
  _SetTimeAction action = _SetTimeAction.rewrite;
  DateTime? targetSaturday;
  List<ScheduleSlot>? beforeRows;
  List<ScheduleSlot>? afterRows;
  List<_ConflictGroup>? conflicts;
  int conflictIndex = 0;
  final Set<String> removeKeys = {};
  final List<ScheduleSlot> removeRows = [];

  /// Raw token → resolved location key (approved locations only).
  final Map<String, String> resolved = {};

  /// Raw token → the full name the gadmin typed for a brand-new location
  /// (waiting for the console to approve it).
  final Map<String, String> requestedNames = {};

  /// The token whose new-location name we are waiting for.
  String? awaitingNameFor;

  /// Tokens with no approved match and no pending request yet, in order.
  List<String> unresolvedTokens(Repo repo) {
    final out = <String>{};
    for (final line in lines) {
      final token = line.locationToken;
      if (resolved.containsKey(token)) continue;
      if (requestedNames.containsKey(token)) continue;
      if (repo.resolveLocation(token) != null) continue;
      out.add(token);
    }
    return out.toList();
  }

  /// Builds the template rows, resolving every token (explicit choice first,
  /// then the approved locations and their aliases).
  List<ScheduleSlot> parseRows(Repo repo) => buildTemplate(
    lines,
    resolveToken: (token) =>
        resolved[token] ?? repo.resolveLocation(token)?.key,
  );
}

enum _SetTimeScope { temporary, persistent }

enum _SetTimeAction { add, remove, rewrite }

class _ConflictGroup {
  final List<String> keys;

  const _ConflictGroup(this.keys);
}
