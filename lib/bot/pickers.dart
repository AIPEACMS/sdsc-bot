import 'package:televerse/televerse.dart';

import '../core/models.dart';

/// Reusable interactive-picker builders: paginated member pickers and
/// confirm dialogs. These are the "inline response API": a grid button press
/// (or an arg-less command) shows a message with inline buttons for the next
/// step instead of demanding typed arguments.
class Pickers {
  Pickers._();

  /// Members shown per page of a member picker.
  static const int pageSize = 6;

  /// Builds an inline keyboard of members, paginated so the message stays
  /// short even with a large roster.
  ///
  /// Callback payload: `mpick|<action>|<page>|<memberId|prev|next|cancel>`
  static InlineKeyboard memberPicker({
    required String action,
    required List<User> members,
    required int page,
  }) {
    final pageCount = members.isEmpty ? 1 : (members.length / pageSize).ceil();
    final clamped = page.clamp(0, pageCount - 1);
    final start = clamped * pageSize;
    final slice = members.skip(start).take(pageSize).toList();

    var kb = InlineKeyboard();
    for (final m in slice) {
      kb = kb.text(m.name, 'mpick|$action|$clamped|${m.id}').row();
    }

    // Pagination row (only when more than one page).
    if (pageCount > 1) {
      if (clamped > 0) {
        kb = kb.text('⬅', 'mpick|$action|${clamped - 1}|prev');
      }
      kb = kb.text('$clamped / ${pageCount - 1}', 'noop|0');
      if (clamped < pageCount - 1) {
        kb = kb.text('➡', 'mpick|$action|${clamped + 1}|next');
      }
      kb = kb.row();
    }

    kb = kb.text('❌ Cancel', 'mpick|$action|$clamped|cancel');
    return kb;
  }

  /// Builds a Yes/Cancel confirm keyboard.
  ///
  /// Callback payload: `<prefix>|<yes|no>`.
  static InlineKeyboard confirm(String prefix) {
    return InlineKeyboard()
        .text('✅ Yes', '$prefix|yes')
        .row()
        .text('❌ Cancel', '$prefix|no');
  }

  /// Splits a `mpick` callback payload.
  static (String action, int page, String target) parsePick(
      List<String> parts) {
    return (
      parts.length > 1 ? parts[1] : '',
      parts.length > 2 ? int.tryParse(parts[2]) ?? 0 : 0,
      parts.length > 3 ? parts[3] : 'cancel',
    );
  }
}
