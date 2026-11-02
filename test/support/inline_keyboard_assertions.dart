List<int> inlineKeyboardMessageIds(
  List<Map<String, dynamic>> messages,
  List<int> messageIds,
) => [
  for (var index = 0; index < messages.length; index++)
    if ((messages[index]['reply_markup'] as Map?)?['inline_keyboard'] != null)
      messageIds[index],
];

bool hasEmptyInlineKeyboard(Map<String, dynamic> body) {
  final markup = body['reply_markup'];
  final rows = markup is Map<String, dynamic>
      ? markup['inline_keyboard']
      : null;
  return rows is List && rows.isEmpty;
}
