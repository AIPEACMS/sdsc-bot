/// Strict date parser for manual attendance corrections.
class ManualAttendanceDate {
  ManualAttendanceDate._();

  static DateTime? parse(String input, {required DateTime today}) {
    final text = input.trim();
    if (text.isEmpty) return null;
    int day;
    int month;
    int year = today.year;

    final named = RegExp(
      r'^(?:(\p{L}+)\s+(\d{1,2})|(\d{1,2})\s+(\p{L}+))(?:\s+(\d{4}))?$'
          .replaceAll(r'\p{L}', '[A-Za-z]'),
      caseSensitive: false,
    ).firstMatch(text);
    if (named != null) {
      final monthText = named.group(1) ?? named.group(4)!;
      day = int.parse(named.group(2) ?? named.group(3)!);
      month = _month(monthText);
      if (month == 0) return null;
      year = int.tryParse(named.group(5) ?? '') ?? today.year;
    } else {
      final numeric = RegExp(
        r'^(\d{1,2})[/-](\d{1,2})(?:[/-](\d{4}))?$',
      ).firstMatch(text);
      if (numeric == null) return null;
      day = int.parse(numeric.group(1)!);
      month = int.parse(numeric.group(2)!);
      year = int.tryParse(numeric.group(3) ?? '') ?? today.year;
    }

    final value = DateTime(year, month, day);
    if (value.year != year || value.month != month || value.day != day) {
      return null;
    }
    final localToday = DateTime(today.year, today.month, today.day);
    if (value.isAfter(localToday)) return null;
    return value;
  }

  static int _month(String text) {
    const months = [
      ('jan', 'january'),
      ('feb', 'february'),
      ('mar', 'march'),
      ('apr', 'april'),
      ('may', 'may'),
      ('jun', 'june'),
      ('jul', 'july'),
      ('aug', 'august'),
      ('sep', 'september'),
      ('oct', 'october'),
      ('nov', 'november'),
      ('dec', 'december'),
    ];
    final lower = text.toLowerCase();
    if (lower.length < 3) return 0;
    return months.indexWhere(
          (month) => month.$1 == lower || month.$2 == lower,
        ) +
        1;
  }

  static String canonical(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
