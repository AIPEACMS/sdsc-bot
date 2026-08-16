import 'models.dart';

/// All user-facing message templates. Contact placeholders are resolved per
/// the member's registered group via [contactForGroup].
class Messages {
  final String Function(String group) contactForGroup;

  const Messages(this.contactForGroup);

  /// Initial availability prompt.
  String msg1(String group) {
    final contact = contactForGroup(group);
    return 'Hi! It is time to let us know your availability for the next 2 '
        'weekends.\n\n'
        'Tap the sessions you can attend and press <b>Done</b> when you '
        'finish. If you cannot make it at all, press <b>Not available</b> '
        'instead — no pressure at all.\n\n'
        'Questions? Message $contact.';
  }

  /// Prompt variant for members who did not attend in the past 2 weeks.
  String msg1A(String group) {
    return 'Hi! It is time to let us know your availability for the next 2 '
        'weekends.\n\n'
        'We noticed you have not attended the past 2 weeks — it would be '
        'great to see you again! Tap the sessions you can attend and press '
        '<b>Done</b>. If you are short on time, even one session helps.';
  }

  /// Reminder for members who have not responded.
  String msg2(String group) {
    final contact = contactForGroup(group);
    return 'Hi! Just a reminder: we have not heard from you yet about the '
        'next 2 weekends.\n\n'
        'Tap the sessions you can attend and press <b>Done</b>, or press '
        '<b>Not available</b> if you cannot make it. Questions? Message '
        '$contact.';
  }

  /// Confirmation echoing the chosen availability slots.
  String msg3(Iterable<Slot> slots) {
    final lines = slots.map((s) => '• ${s.toString()}').toList();
    final list = lines.isEmpty ? '(none)' : lines.join('\n');
    return 'Thank you! Here is what you told us:\n$list\n\n'
        'Availability locks on the Friday before each weekend. '
        'Changed your mind? Send /repick to update before then.';
  }

  /// Confirmation when the member indicated they are not available.
  String msg6() {
    return 'No worries — you are all set for the next 2 weeks. '
        'We will prompt you again for the following cycle!\n\n'
        'Changed your mind? Send /repick to update before then.';
  }

  /// Allocation notice. `session` is e.g. "OCBC @ Pasir Ris" placeholder —
  /// the caller formats the session label; [time] is the "from $time to $time"
  /// portion.
  String msg4(String group, String sessionLabel, String timeLabel) {
    final contact = contactForGroup(group);
    return 'You have been allocated to <b>$sessionLabel</b>, $timeLabel.\n\n'
        'If your plans suddenly change, message $contact as soon as possible.';
  }

  /// Holiday prompt — middle week break.
  String msg5A(String group) {
    return 'Hi! It is the week of a break, but we still have a session on if '
        'you would like to attend.\n\n'
        'No pressure at all — tap the sessions you can attend and press '
        '<b>Done</b>, or press <b>Not available</b> to rest this week.';
  }

  /// Holiday prompt — winter or summer break.
  String msg5B(String group, {required String season}) {
    return 'Hi! It is the $season break, but we still have a session on if '
        'you would like to attend.\n\n'
        'Tap the sessions you can attend and press <b>Done</b>, or press '
        '<b>Not available</b> to rest this break. Spending it with family? '
        'Tap <b>Skip me this holiday</b> on the prompt to opt out.';
  }

  /// Response to the /holiday opt-out command.
  String msg5Z() {
    return 'Thank you for volunteering with us! Enjoy your holiday — '
        'we will see you next semester!';
  }
}
