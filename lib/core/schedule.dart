import 'config.dart';
import 'models.dart';
import 'repo.dart';

/// The single in-process owner of the persisted schedule.
///
/// Components receive this object rather than copying schedule hours. A
/// successful update changes the durable settings first, then publishes the
/// new value to listeners such as the one-shot scheduler timer.
class ScheduleRuntime {
  final Repo repo;
  final Config config;
  final List<void Function()> _listeners = [];
  late ScheduleTimes _schedule;

  ScheduleRuntime({required this.repo, required this.config}) {
    _schedule = repo.readSchedule();
  }

  ScheduleTimes get schedule => _schedule;

  RollingWindow window(DateTime localNow) =>
      RollingWindow.forDate(localNow, schedule: _schedule);

  RollingWindow currentWindow() => window(config.toLocal(Config.nowUtc()));

  void addListener(void Function() listener) => _listeners.add(listener);

  void update(ScheduleTimes value) {
    value.validate();
    repo.writeSchedule(value);
    _schedule = value;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}
