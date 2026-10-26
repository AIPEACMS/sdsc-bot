#!/usr/bin/env bash
set -euo pipefail

base=''
jobs=${TEST_JOBS:-4}
run_all=false
dart_bin=${DART_BIN:-}
if [[ -z "$dart_bin" ]]; then
  flutter_bin=$(command -v flutter 2>/dev/null || true)
  if [[ -n "$flutter_bin" ]]; then
    flutter_root=$(cd "$(dirname "$flutter_bin")/.." && pwd -P)
    bundled_dart="$flutter_root/bin/cache/dart-sdk/bin/dart"
    if [[ -x "$bundled_dart" ]]; then dart_bin=$bundled_dart; fi
  fi
fi
dart_bin=${dart_bin:-dart}
while (($#)); do
  case "$1" in
    --all) run_all=true; shift ;;
    --jobs)
      if (($# < 2)) || [[ ! "$2" =~ ^[1-9][0-9]*$ ]]; then
        echo '--jobs requires a positive integer' >&2
        exit 2
      fi
      jobs=$2
      shift 2
      ;;
    --base)
      if (($# < 2)); then
        echo 'usage: tool/test-affected.sh [--all] [--jobs N] [--base REF]' >&2
        exit 2
      fi
      base=$2
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      echo 'usage: tool/test-affected.sh [--all] [--jobs N] [--base REF]' >&2
      exit 2
      ;;
  esac
done

if $run_all; then
  exec "$dart_bin" test -j "$jobs"
fi

declare -A changed=()
add_paths() {
  local path
  while IFS= read -r path; do
    [[ -n "$path" ]] && changed["$path"]=1
  done
}
if [[ -n "$base" ]]; then
  add_paths < <(git diff --name-only "$base"...HEAD)
fi
add_paths < <(git diff --name-only HEAD)
add_paths < <(git ls-files --others --exclude-standard)

if ((${#changed[@]} == 0)); then
  echo 'No uncommitted changes detected; running the full suite.'
  exec "$dart_bin" test -j "$jobs"
fi

declare -A selected=()
select_tests() {
  local path=$1
  if [[ -f "$path" ]]; then
    selected["$path"]=1
  else
    echo "Mapped test does not exist: $path" >&2
    exit 1
  fi
}
full_suite() {
  echo "$1; running the full suite."
  exec "$dart_bin" test -j "$jobs"
}

for path in "${!changed[@]}"; do
  case "$path" in
    test/support/*.dart|test/**/support/*.dart)
      ;;
    test/*.dart|test/**/*.dart)
      [[ -f "$path" ]] && selected["$path"]=1
      ;;
    lib/bot/settime.dart|lib/bot/settime/command.dart|lib/bot/settime/allocation_removal.dart)
      select_tests 'test/bot/admin/allocation_removal_flow_test.dart'
      select_tests 'test/bot/admin/allocation_removal_notification_test.dart'
      select_tests 'test/bot/commands/command_catalog_test.dart'
      select_tests 'test/bot/settime/settime_flow_test.dart'
      ;;
    lib/bot/settime/persistence.dart|lib/bot/settime/validation.dart)
      select_tests 'test/bot/admin/allocation_removal_flow_test.dart'
      select_tests 'test/bot/admin/allocation_removal_notification_test.dart'
      select_tests 'test/bot/settime/settime_flow_test.dart'
      select_tests 'test/bot/settime/settime_schedule_test.dart'
      select_tests 'test/bot/settime/temporary_schedule_override_test.dart'
      ;;
    lib/bot/admin_api.dart|lib/bot/admin_api/routing.dart)
      select_tests 'test/bot/admin_api/admin_api_allocation_removal_test.dart'
      select_tests 'test/bot/admin_api/admin_api_operations_test.dart'
      select_tests 'test/bot/admin_api/admin_api_session_schedule_test.dart'
      ;;
    lib/bot/admin_api/removals.dart|lib/bot/admin_api/session_schedules.dart)
      select_tests 'test/bot/admin_api/admin_api_allocation_removal_test.dart'
      select_tests 'test/bot/admin_api/admin_api_session_schedule_test.dart'
      ;;
    lib/bot/admin_api/attendance.dart|lib/bot/admin_api/part_05.dart)
      select_tests 'test/bot/admin_api/admin_api_attendance_test.dart'
      ;;
    lib/bot/admin_api/users.dart)
      select_tests 'test/bot/admin_api/admin_api_users_test.dart'
      select_tests 'test/bot/admin_api/admin_api_roles_test.dart'
      select_tests 'test/bot/admin_api/admin_api_registration_removal_test.dart'
      select_tests 'test/bot/admin_api/admin_api_operations_test.dart'
      ;;
    lib/bot/admin_api/operations.dart)
      select_tests 'test/bot/admin_api/admin_api_operations_test.dart'
      select_tests 'test/bot/admin_api/admin_api_group_assignment_test.dart'
      ;;
    lib/bot/admin.dart|lib/bot/admin/*.dart|lib/bot/console.dart|lib/bot/console/*.dart)
      select_tests 'test/bot/admin/grid_admin_test.dart'
      select_tests 'test/bot/admin/grid_operations_test.dart'
      select_tests 'test/bot/admin/grid_start_test.dart'
      select_tests 'test/bot/admin/assign_group_flow_test.dart'
      select_tests 'test/bot/admin/remove_user_flow_test.dart'
      select_tests 'test/bot/admin/setexp_test.dart'
      select_tests 'test/bot/admin/allocation_removal_flow_test.dart'
      ;;
    lib/bot/flows/presentation.dart|lib/bot/flows/registration.dart)
      select_tests 'test/bot/admin/grid_operations_test.dart'
      select_tests 'test/bot/user/repick_profile_test.dart'
      select_tests 'test/bot/user/repick_availability_test.dart'
      ;;
    lib/bot/flows/availability.dart|lib/bot/flows/callbacks.dart)
      select_tests 'test/bot/user/grid_member_test.dart'
      select_tests 'test/bot/user/repick_availability_test.dart'
      select_tests 'test/bot/user/repick_cancel_test.dart'
      select_tests 'test/bot/user/repick_cycle_test.dart'
      ;;
    lib/bot/flows.dart)
      select_tests 'test/bot/admin/grid_admin_test.dart'
      select_tests 'test/bot/admin/grid_operations_test.dart'
      select_tests 'test/bot/admin/grid_start_test.dart'
      select_tests 'test/bot/admin/allocation_removal_flow_test.dart'
      ;;
    lib/bot/command_catalog.dart|lib/bot/keyboards.dart)
      select_tests 'test/bot/commands/command_catalog_test.dart'
      select_tests 'test/bot/commands/keyboards_layout_test.dart'
      select_tests 'test/bot/admin/grid_start_test.dart'
      ;;
    lib/bot/allocation_removal_notice.dart)
      select_tests 'test/bot/admin/allocation_removal_flow_test.dart'
      select_tests 'test/bot/admin/allocation_removal_notification_test.dart'
      select_tests 'test/bot/admin_api/admin_api_allocation_removal_test.dart'
      ;;
    lib/core/allocate.dart|lib/core/domain/allocation.dart)
      select_tests 'test/core/allocation/allocate_basic_test.dart'
      select_tests 'test/core/allocation/allocate_capacity_test.dart'
      select_tests 'test/core/allocation/allocate_priority_test.dart'
      select_tests 'test/core/allocation/allocate_weekend_test.dart'
      ;;
    lib/core/persistence/repo/availability.dart|lib/core/persistence/repo/sessions.dart)
      select_tests 'test/bot/admin_api/admin_api_allocation_removal_test.dart'
      select_tests 'test/bot/admin/allocation_removal_flow_test.dart'
      select_tests 'test/bot/settime/settime_schedule_test.dart'
      select_tests 'test/bot/settime/temporary_schedule_override_test.dart'
      ;;
    lib/core/persistence/*.dart|lib/core/persistence/repo/*.dart|lib/core/repo.dart)
      select_tests 'test/core/persistence/repo_messaging_attendance_test.dart'
      select_tests 'test/core/persistence/repo_roles_test.dart'
      select_tests 'test/core/persistence/repo_schedule_test.dart'
      select_tests 'test/core/persistence/repo_user_flow_test.dart'
      select_tests 'test/core/persistence/migration_test.dart'
      select_tests 'test/bot/settime/settime_schedule_test.dart'
      select_tests 'test/bot/admin_api/admin_api_operations_test.dart'
      ;;
    lib/core/db.dart)
      select_tests 'test/core/persistence/migration_test.dart'
      select_tests 'test/core/persistence/repo_messaging_attendance_test.dart'
      select_tests 'test/core/persistence/repo_roles_test.dart'
      select_tests 'test/core/persistence/repo_schedule_test.dart'
      select_tests 'test/core/persistence/repo_user_flow_test.dart'
      select_tests 'test/bot/admin_api/admin_api_operations_test.dart'
      ;;
    lib/core/schedule.dart|lib/core/domain/rolling_window.dart|lib/core/week.dart)
      select_tests 'test/core/schedule/week_test.dart'
      select_tests 'test/core/schedule/scheduler_test.dart'
      select_tests 'test/core/schedule/scheduler_events_test.dart'
      select_tests 'test/core/persistence/repo_schedule_test.dart'
      ;;
    lib/bot/scheduler.dart)
      select_tests 'test/core/schedule/scheduler_test.dart'
      select_tests 'test/core/schedule/scheduler_events_test.dart'
      select_tests 'test/bot/user/absent_reminder_test.dart'
      ;;
    lib/bot/service/allocation.dart|lib/bot/service/prompts.dart)
      select_tests 'test/core/schedule/scheduler_events_test.dart'
      select_tests 'test/bot/user/absent_reminder_test.dart'
      select_tests 'test/bot/user/repick_availability_test.dart'
      ;;
    lib/core/domain/session_models.dart|lib/core/domain/slot_model.dart|lib/core/domain/window_model.dart)
      select_tests 'test/core/persistence/migration_test.dart'
      select_tests 'test/core/persistence/repo_schedule_test.dart'
      select_tests 'test/bot/admin_api/admin_api_operations_test.dart'
      select_tests 'test/core/schedule/scheduler_test.dart'
      select_tests 'test/core/schedule/scheduler_events_test.dart'
      ;;
    lib/core/messages.dart)
      select_tests 'test/bot/user/repick_availability_test.dart'
      ;;
    tool/*.sh|README.md|CHANGELOG.md|pubspec.yaml|pubspec.lock|.github/workflows/*.yml)
      ;;
    lib/*.dart|lib/core/*.dart|bin/*.dart)
      full_suite "No focused test map for $path"
      ;;
    *)
      full_suite "No focused test map for $path"
      ;;
  esac
done

if ((${#selected[@]} == 0)); then
  full_suite 'No focused tests matched'
fi

mapfile -t test_files < <(printf '%s\n' "${!selected[@]}" | sort)
printf 'Running %d affected test file(s) with %s worker(s):\n' \
  "${#test_files[@]}" "$jobs"
printf '  %s\n' "${test_files[@]}"
exec "$dart_bin" test -j "$jobs" "${test_files[@]}"
