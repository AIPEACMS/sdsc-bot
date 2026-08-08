import 'models.dart';

/// All user-facing message templates. Contact placeholders are resolved per
/// the member's registered group via [contactForGroup].
class Messages {
  final String Function(String group) contactForGroup;

  const Messages(this.contactForGroup);

  /// Initial availability prompt.
  String msg1(String group) {
    final contact = contactForGroup(group);
    return 'Hi! Greetings from SDSC bot: It is time to indicate your '
        'availabity to attend SDSC for the next 2 weekends! <b>Indicate Now</b>\n\n'
        'If you cannot attend for the next 2 weekends, no worries! You can '
        'indicate that you are not available for the next 2 weeks, or drop a '
        'message at $contact to tell us and there is no pressure! You can '
        'always attend later sessions!';
  }

  /// Prompt variant for members who did not attend in the past 2 weeks.
  String msg1A(String group) {
    return 'Hi! Greetings from SDSC bot: It is time to indicate your '
        'availabity to attend SDSC for the next 2 weekends! <b>Indicate Now</b> '
        'You did not attend for the past 2 weeks. I encourage you to attend '
        'more! Perhaps... Do you consider attending both weeks\' sessions, or '
        'attending a full day session? If you are short in time,';
  }

  /// Reminder for members who have not responded.
  String msg2(String group) {
    final contact = contactForGroup(group);
    return 'Hi! Greetings from SDSC bot: you havent indicate your '
        'availability to attend SDSC for the next 2 weekends! May I ask are '
        'you available? <b>Indicate Now</b>\n\n'
        'If you cannot attend for the next 2 weekends, no worries! You can '
        'indicate that you are not available for the next 2 weeks, or drop a '
        'message at $contact to tell us and there is no pressure! You can '
        'always attend later sessions!';
  }

  /// Confirmation echoing the chosen availability slots.
  String msg3(Iterable<Slot> slots) {
    final lines = slots.map((s) => '• ${s.toString()}').toList();
    final list = lines.isEmpty ? '(none)' : lines.join('\n');
    return 'Thank you so much for indicating your availability! '
        'To confirm: Your available time is\n$list\n'
        'If you misclick, indicate again by sending: /reindicate';
  }

  /// Confirmation when the member indicated they are not available.
  String msg6() {
    return 'No worries! You have indicated that you are not available for '
        'the next 2 weeks. You can always attend later sessions!';
  }

  /// Allocation notice. `session` is e.g. "OCBC @ Pasir Ris" placeholder —
  /// the caller formats the session label; [time] is the "from $time to $time"
  /// portion.
  String msg4(String group, String sessionLabel, String timeLabel) {
    final contact = contactForGroup(group);
    return 'You are allocated to $sessionLabel from $timeLabel. '
        'If you have a sudden change in schedule, you can drop a message to '
        '$contact by Friday 12:00pm.';
  }

  /// Holiday prompt — middle week break.
  String msg5A(String group) {
    return 'Hi! It is the week of break: do you still like to attend for this '
        'weeks session? I know you want to relax, so no pressure on this weeks '
        'session, but we would absolutely shout out to you if you want to '
        'attend! <b>Indicate Now</b>';
  }

  /// Holiday prompt — winter or summer break.
  String msg5B(String group, {required String season}) {
    return 'Hi! It is the $season break: do you still like to attend for this '
        'weeks session? We would absolutely shout out to you if you want to '
        'attend! <b>Indicate Now</b>\nOr: if you want to stay with your family '
        'for this $season break, simply type: /holiday';
  }

  /// Response to the /holiday opt-out command.
  String msg5Z() {
    return 'Yes! Thank you for the past months volunteering! The SDSC '
        'Team wish you a good holiday! See around in the next semester!';
  }
}
