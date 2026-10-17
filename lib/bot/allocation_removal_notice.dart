/// Shared HTML notification copy for allocation/session removals.
class AllocationRemovalNotice {
  const AllocationRemovalNotice._();

  static String message(Iterable<String> escapedSessionLabels) =>
      '⚠️ <b>Your allocation has been removed</b>\n'
      '${escapedSessionLabels.map((label) => '• $label').join('\n')}\n\n'
      'Your other allocations are unchanged.';

  static String escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
