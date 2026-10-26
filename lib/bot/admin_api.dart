import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;
import 'package:televerse/televerse.dart';
import 'package:televerse/telegram.dart' hide Location, User;

import '../core/config.dart';
import '../core/log.dart';
import '../core/models.dart';
import '../core/repo.dart';
import 'calendar_sync.dart';
import 'hold.dart';
import 'key_auth.dart';
import 'server_identity.dart';
import 'service.dart';
import 'allocation_removal_notice.dart';
import '../core/schedule.dart';

/// HTTP admin API for the desktop console app. Every request must authenticate
/// with a registered console key (Ed25519 signature) or, as a manual
/// fallback, the configured bearer token. Bound to all interfaces so the app
/// can reach it over the tailnet; authentication is the only gate.
///
/// Mutual auth: every response is signed by the server's own Ed25519 identity
/// ([ServerIdentity]), carried in these headers:
///
///   X-SDSC-Server-Pub:   base64 raw 32-byte public key
///   X-SDSC-Server-Ts:    unix milliseconds
///   X-SDSC-Server-Sig:   base64 ed25519 signature over `resp:$message`
///
/// The console pins the identity's fingerprint on first connect and ignores
/// anything not signed by that key, so an impostor backend is detected even
/// if it registers the console's public key.
///
/// Endpoints:
///   GET   /api/server-info              -> public key + fingerprint
///   GET   /api/state                    -> held flag, debug clock, cycle, schedule
///   GET   /api/schedule                 -> persisted local wall-clock schedule
///   POST  /api/schedule                 -> partial event time/weekday update
///        legacy prompt/reminder/lock/checker events allow Mon-Fri in order;
///        attendanceInitial (Sun 20:00), attendanceFollowup (Mon 08:00), and
///        absence (Mon 08:00) each accept any weekday independently with their
///        matching `attendanceInitialWeekday`, `attendanceFollowupWeekday`, and
///        `absenceWeekday` fields. Omitted fields retain their saved values;
///        timezoneOffset is server-controlled.
///   POST  /api/session-schedule/read         -> {scope, week?}; selected rows, sessions, override and lock state
///   POST  /api/session-schedule/preview  -> {scope, week?, action, rows:[{day,slot,start,end,location,maxPeople?,capacityGroup?}]}
///   POST  /api/session-schedule/commit   -> same body as preview; revalidates and applies
///   POST  /api/allocations/removal-preview -> {week?, sessionId} or {week?, entries:[{sessionId,userId}]}
///   POST  /api/allocations/remove        -> same confirmed target body; selected-week scope permits weeks outside rolling window
///   GET   /api/users                    -> every user with tier + groups + attendance
///   POST  /api/users                    -> { "handle": "@name" } (register-or-queue)
///   POST  /api/users/remove             -> { "handles": ["@a", "@b"] }
///   POST  /api/users/{id}/tier          -> { "tier": "admin|check|member|out-member|old" }
///   POST  /api/users/{id}/notification  -> { "preference": "weekly|every-other|never" }
///   POST  /api/users/{id}/admin         -> { "admin": true|false } (keeps member tier)
///   POST  /api/users/{id}/gadmin        -> { "gadmin": true|false } (singleton handoff)
///   POST  /api/users/{id}/exp           -> { "exp": "experienced|newbie" }
///   POST  /api/users/{id}/group         -> { "group": "" | "1" | "2" | ... } (member only)
///   POST  /api/assign-groups            -> randomly assign ungrouped members to admin groups
///   POST  /api/hold                     -> { "held": true|false }
///   POST  /api/date                     -> { "date": "YYYY-MM-DD HH:MM" } | { "reset": true }
///   POST  /api/sync-calendar            -> { "yaml": "..." }
///   POST  /api/prompt | /api/remind | /api/allocate -> run the cycle op now
///   POST  /api/ask                      -> { "userId": `id` } (send picker to one member)
///   POST  /api/broadcast                -> { "text": "..." } (to all members)
///   GET   /api/attendance               -> sessions + allocated members + attendance eligibility/flags
///   POST  /api/attendance               -> { "sessionId": `id`, "userId": `id` } (toggle)
///   POST  /api/console-keys/bind-challenge -> one-time code for /bind_key
///   GET   /api/attendance-corrections/targets -> eligible users for the key owner
///   POST  /api/attendance-corrections/preview -> validated correction snapshot
///   POST  /api/attendance-corrections/apply -> apply a confirmed snapshot once
///   GET   /api/logs                     -> { "lines": [...] }
///   POST  /api/log-retention            -> { "days": 14 }
///   GET   /api/locations                -> approved + pending locations + aliases
///   POST  /api/locations                -> { "name": "...", "aliases": [...] }
///   POST  /api/locations/{id}/approve   -> { "name": "...", "aliases": [...] }

part 'admin_api/routing.dart';
part 'admin_api/users.dart';
part 'admin_api/operations.dart';
part 'admin_api/attendance.dart';
part 'admin_api/removals.dart';
part 'admin_api/part_05.dart';
part 'admin_api/session_schedules.dart';
part 'admin_api/session_schedule_helpers.dart';
part 'admin_api/attendance_corrections.dart';

Map<String, dynamic> _jsonBody(String text) {
  if (text.trim().isEmpty) return {};
  return jsonDecode(text) as Map<String, dynamic>;
}

class _AdminApiBase {
  final Repo repo;

  final Config config;

  final CalendarSync calendarSync;

  final HoldGate holdGate;

  final String? token;

  final int port;

  final ServerIdentity identity;

  final ScheduleRuntime scheduleRuntime;

  final CycleService? service;

  Future<void> Function(LocationInfo location)? onLocationApproved;

  final NonceGuard _nonces = NonceGuard();
  final Random _secureRandom = Random.secure();

  HttpServer? _server;

  _AdminApiBase({
    required this.repo,
    required this.config,
    required this.calendarSync,
    required this.holdGate,
    required this.token,
    required this.port,
    this.service,
    ScheduleRuntime? scheduleRuntime,
  }) : identity = ServerIdentity(repo),
       scheduleRuntime =
           scheduleRuntime ?? ScheduleRuntime(repo: repo, config: config);
}

class AdminApi extends _AdminApiBase {
  AdminApi({
    required super.repo,
    required super.config,
    required super.calendarSync,
    required super.holdGate,
    required super.token,
    required super.port,
    super.service,
    super.scheduleRuntime,
  });
}
