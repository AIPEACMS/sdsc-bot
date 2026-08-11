import 'dart:convert';
import 'dart:io';

import 'package:televerse/televerse.dart';

import '../core/config.dart';
import '../core/log.dart';
import '../core/models.dart';
import '../core/repo.dart';
import 'calendar_sync.dart';
import 'hold.dart';
import 'key_auth.dart';
import 'server_identity.dart';
import 'service.dart';

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
///   GET   /api/state                    -> held flag, debug clock, cycle
///   GET   /api/users                    -> every user with tier + groups + attendance
///   POST  /api/users                    -> { "handle": "@name" } (register-or-queue)
///   POST  /api/users/{id}/tier          -> { "tier": "admin|check|member|old" }
///   POST  /api/users/{id}/admin         -> { "admin": true|false } (keeps member tier)
///   POST  /api/users/{id}/exp           -> { "exp": "experienced|newbie" }
///   POST  /api/hold                     -> { "held": true|false }
///   POST  /api/date                     -> { "date": "YYYY-MM-DD HH:MM" } | { "reset": true }
///   POST  /api/sync-calendar            -> { "yaml": "..." }
///   POST  /api/prompt | /api/remind | /api/allocate -> run the cycle op now
///   POST  /api/ask                      -> { "userId": `id` } (send picker to one member)
///   POST  /api/broadcast                -> { "text": "..." } (to all members)
///   GET   /api/attendance               -> sessions + allocated members + attended flags
///   POST  /api/attendance               -> { "sessionId": `id`, "userId": `id` } (toggle)
///   GET   /api/logs                     -> { "lines": [...] }
///   POST  /api/log-retention            -> { "days": 14 }
class AdminApi {
  final Repo repo;
  final Config config;
  final CalendarSync calendarSync;
  final HoldGate holdGate;
  final String? token;
  final int port;
  final ServerIdentity identity;

  /// Wired from main.dart with the real [CycleService]. The cycle-driving
  /// endpoints (prompt/remind/allocate/ask/broadcast) require it; everything
  /// else works without it (and does in tests).
  final CycleService? service;
  final NonceGuard _nonces = NonceGuard();

  HttpServer? _server;

  AdminApi({
    required this.repo,
    required this.config,
    required this.calendarSync,
    required this.holdGate,
    required this.token,
    required this.port,
    this.service,
  }) : identity = ServerIdentity(repo);

  /// The actual bound port (differs from [port] when 0 = ephemeral).
  int get boundPort => _server?.port ?? port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen(_handle);
    LogRing.log('admin API listening on :$boundPort');
    LogRing.log(
        'admin API server fingerprint ${await identity.fingerprint()}');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// Returns true if the request is allowed: a known key signed it, or the
  /// bearer token matches (when configured). The message signed by the app is
  /// rebuilt here from the live request so nothing can be swapped.
  Future<bool> _authorized(
    HttpRequest req, {
    required String method,
    required String path,
    required List<int> bodyBytes,
  }) async {
    final bearer = req.headers.value(HttpHeaders.authorizationHeader);
    if (bearer != null && token != null && bearer == 'Bearer $token') {
      return true;
    }

    final pubB64 = req.headers.value('X-SDSC-Pub');
    final tsRaw = req.headers.value('X-SDSC-Ts');
    final nonce = req.headers.value('X-SDSC-Nonce');
    final sigB64 = req.headers.value('X-SDSC-Sig');
    if (pubB64 == null || tsRaw == null || nonce == null || sigB64 == null) {
      return false;
    }

    if (!repo.hasConsoleKey(pubB64)) return false;

    final ts = int.tryParse(tsRaw);
    if (ts == null) return false;

    // Reject stale or clock-skewed timestamps, and replay of a nonce.
    final skew = DateTime.now().millisecondsSinceEpoch - ts;
    if (skew.abs() > 5 * 60 * 1000) return false;
    if (_nonces.contains(nonce)) return false;
    _nonces.remember(nonce, ts);

    final message = KeyAuth.message(
      method: method,
      path: path,
      ts: tsRaw,
      nonce: nonce,
      bodyHash: KeyAuth.bodyHash(bodyBytes),
    );
    return KeyAuth.verifySignature(
      pubkeyB64: pubB64,
      signatureB64: sigB64,
      message: utf8.encode(message),
    );
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final bodyBytes = await _readBody(req);
      final method = req.method.toUpperCase();
      final path = req.uri.path;

      // The server identity is public by design: the console must be able to
      // discover the fingerprint to pin on its very first connect, before it
      // holds any registration. Nothing is signed here — this is the anchor.
      if (method == 'GET' && path == '/api/server-info') {
        await _send(req, 200, {
          'ok': true,
          'pubkey': await identity.pubkeyB64(),
          'fingerprint': await identity.fingerprint(),
        });
        return;
      }

      if (!await _authorized(req,
          method: method, path: path, bodyBytes: bodyBytes)) {
        await _send(req, 401, {'ok': false, 'error': 'unauthorized'});
        return;
      }
      final route = await _route(req, utf8.decode(bodyBytes));
      await _send(req, route.$1, route.$2);
    } catch (e) {
      await _send(req, 500, {'ok': false, 'error': 'internal: $e'});
    }
  }

  static Future<List<int>> _readBody(HttpRequest req) async {
    final bytes = <int>[];
    await for (final chunk in req) {
      bytes.addAll(chunk);
    }
    return bytes;
  }

  Future<(int, Object)> _route(HttpRequest req, String bodyText) async {
    final segs = req.uri.pathSegments;
    if (segs.length < 2 || segs[0] != 'api') {
      return (404, {'ok': false, 'error': 'not found'});
    }
    final kind = segs[1];
    final method = req.method.toUpperCase();

    switch (kind) {
      case 'state':
        if (method == 'GET') return (200, _stateBody());
      case 'users':
        if (method == 'GET' && segs.length == 2) {
          return (200, {'ok': true, 'users': _usersJson()});
        }
        if (method == 'POST' && segs.length == 2) {
          return _addUser(bodyText);
        }
        if (method == 'POST' && segs.length == 4 && segs[3].isNotEmpty) {
          final id = int.tryParse(segs[2]);
          if (id == null) {
            return (400, {'ok': false, 'error': 'bad user id'});
          }
          switch (segs[3]) {
            case 'tier':
              return _setTier(id, bodyText);
            case 'admin':
              return _setUserAdmin(id, bodyText);
            case 'exp':
              return _setUserExp(id, bodyText);
          }
        }
      case 'hold':
        if (method == 'POST') return _setHold(bodyText);
      case 'date':
        if (method == 'POST') return _setDate(bodyText);
      case 'sync-calendar':
        if (method == 'POST') return _syncCalendar(bodyText);
      case 'prompt':
        if (method == 'POST') return _runCycleOp('prompt');
      case 'remind':
        if (method == 'POST') return _runCycleOp('remind');
      case 'allocate':
        if (method == 'POST') return _runCycleOp('allocate');
      case 'ask':
        if (method == 'POST') return _ask(bodyText);
      case 'broadcast':
        if (method == 'POST') return _broadcast(bodyText);
      case 'attendance':
        if (method == 'GET') return (200, _attendanceBody());
        if (method == 'POST') return _toggleAttendance(bodyText);
      case 'logs':
        if (method == 'GET') {
          return (200, {'ok': true, 'lines': LogRing.snapshot});
        }
      case 'log-retention':
        if (method == 'POST') return _setLogRetention(bodyText);
    }
    return (404, {'ok': false, 'error': 'not found'});
  }

  /// Signs the JSON body with the server identity and writes it with the
  /// signature headers. The request nonce is echoed into the signed message
  /// so the response is cryptographically bound to the exact exchange.
  Future<void> _send(HttpRequest req, int status, Object body) async {
    final bodyJson = jsonEncode(body);
    final bodyBytes = utf8.encode(bodyJson);

    final nonce = req.headers.value('X-SDSC-Nonce') ?? '';
    final ts = DateTime.now().millisecondsSinceEpoch.toString();
    final message = KeyAuth.serverMessage(
      method: req.method.toUpperCase(),
      path: req.uri.path,
      ts: ts,
      nonce: nonce,
      bodyHash: KeyAuth.bodyHash(bodyBytes),
    );
    final signature = await identity.sign(utf8.encode(message));

    final res = req.response;
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.headers.set('X-SDSC-Server-Pub', await identity.pubkeyB64());
    res.headers.set('X-SDSC-Server-Ts', ts);
    res.headers.set('X-SDSC-Server-Sig', signature);
    res.write(bodyJson);
    await res.close();
  }

  Map<String, Object?> _stateBody() {
    final now = config.toLocal(Config.nowUtc());
    final cycle = repo.ensureCurrentCycle(now);
    return {
      'ok': true,
      'held': holdGate.isHeld,
      'debugNow': Config.nowUtc() != DateTime.now().toUtc()
          ? config.toLocal(Config.nowUtc()).toIso8601String()
          : null,
      'logRetentionDays': LogRing.retentionDays,
      'cycle': {
        'id': cycle.id,
        'blockWeek': cycle.blockWeek,
        'blockYear': cycle.blockYear,
        'promptDay': cycle.promptDay.toIso8601String(),
        'reminderDay': cycle.reminderDay.toIso8601String(),
        'deadline': cycle.deadline.toIso8601String(),
        'allocationDay': cycle.allocationDay.toIso8601String(),
        'status': cycle.status.name,
      },
    };
  }

  /// The user's full set of groups, most significant first: console >
  /// admin > check/member/old. 'member' is implied by admin (admin is always
  /// a member) but shown explicitly for a plain member — including a console
  /// who stepped down as admin (console | member).
  static List<String> _groupsOf(User u, {required bool isConsole}) {
    final groups = <String>[];
    if (isConsole) groups.add(MemberTier.console);
    if (u.isAdmin) groups.add(MemberTier.admin);
    if (u.memberTier == MemberTier.check || u.memberTier == MemberTier.old) {
      groups.add(u.memberTier);
    } else if (u.memberTier == MemberTier.member && !u.isAdmin) {
      groups.add(MemberTier.member);
    }
    if (groups.isEmpty) groups.add(MemberTier.member);
    return groups;
  }

  List<Map<String, Object?>> _usersJson() {
    return [
      for (final u in repo.allUsers())
        {
          'id': u.id,
          'name': u.name,
          'tier': MemberTier.of(u, isConsole: config.isConsole(u.id)),
          'groups': _groupsOf(u, isConsole: config.isConsole(u.id)),
          'group': u.group,
          'experience': u.experience.name,
          'ocbcStreak': u.ocbcStreak,
          'attendance': {
            'total': repo.attendanceStats(u.id).total,
            'ocbc': repo.attendanceStats(u.id).ocbc,
            'pasirRis': repo.attendanceStats(u.id).pasirRis,
          },
        },
    ];
  }

  Future<(int, Object)> _setTier(int id, String bodyText) async {
    final user = repo.findUser(id);
    if (user == null) return (404, {'ok': false, 'error': 'no such user'});
    final body = _jsonBody(bodyText);
    final tier = (body['tier'] as String?) ?? '';
    if (!MemberTier.order.contains(tier) || tier == MemberTier.console) {
      return (400, {'ok': false, 'error': 'bad tier'});
    }
    repo.setTier(id, tier);
    final updated = repo.findUser(id)!;
    LogRing.log('admin API: ${user.name} ${user.isAdmin ? 'admin' : ''} → tier $tier');
    return (200, {
      'ok': true,
      'user': updated.name,
      'tier': MemberTier.of(updated, isConsole: config.isConsole(id)),
    });
  }

  /// Toggles the admin flag only — the member tier (check/member/old) is
  /// left untouched, unlike [setTier] which clears admin on any non-admin
  /// tier. The console may also use this (e.g. stepping down as admin while
  /// remaining the console).
  Future<(int, Object)> _setUserAdmin(int id, String bodyText) async {
    final user = repo.findUser(id);
    if (user == null) return (404, {'ok': false, 'error': 'no such user'});
    final body = _jsonBody(bodyText);
    final admin = body['admin'];
    if (admin is! bool) {
      return (400, {'ok': false, 'error': 'expected {"admin": bool}'});
    }
    repo.updateAdmin(id, admin);
    final updated = repo.findUser(id)!;
    LogRing.log('admin API: ${updated.name} ${admin ? 'granted' : 'stripped'} admin');
    return (200, {
      'ok': true,
      'admin': admin,
      'tier': MemberTier.of(updated, isConsole: config.isConsole(id)),
    });
  }

  Future<(int, Object)> _setUserExp(int id, String bodyText) async {
    final user = repo.findUser(id);
    if (user == null) return (404, {'ok': false, 'error': 'no such user'});
    final body = _jsonBody(bodyText);
    final exp = (body['exp'] as String?) ?? '';
    if (exp != 'experienced' && exp != 'newbie') {
      return (400, {'ok': false, 'error': 'expected {"exp": "experienced"|"newbie"}'});
    }
    repo.updateExperience(
        id, exp == 'experienced' ? Experience.experienced : Experience.newbie);
    LogRing.log('admin API: ${user.name} exp → $exp');
    return (200, {'ok': true, 'exp': exp});
  }

  /// Registers (or queues) a member by @handle, mirroring the /adduser
  /// outcome: already-registered → already member; pending → already queued;
  /// seen before → registered now; unseen → queued for first contact.
  Future<(int, Object)> _addUser(String bodyText) async {
    final body = _jsonBody(bodyText);
    final handle =
        (body['handle'] as String?)?.trim().replaceFirst('@', '') ?? '';
    if (handle.isEmpty || handle.contains(' ')) {
      return (400, {'ok': false, 'error': 'expected {"handle": "@username"}'});
    }
    final userId = repo.userIdByUsername(handle);
    if (userId != null && repo.findUser(userId) != null) {
      return (200, {'ok': true, 'message': '@$handle is already a member.'});
    }
    if (repo.isPendingUser(handle)) {
      return (200, {
        'ok': true,
        'message': '@$handle is already queued — they will be registered the '
            'first time they message the bot.',
      });
    }
    if (userId != null) {
      repo.upsertUser(User(
        id: userId,
        name: '@$handle',
        experience: Experience.newbie,
        group: 'A',
      ));
      return (200, {
        'ok': true,
        'message': '@$handle added. They can now use /start to see their '
            'commands.',
      });
    }
    repo.addPendingUser(handle, isAdmin: false);
    return (200, {
      'ok': true,
      'message': '@$handle queued — no need for them to message first. The '
          'moment they message this bot, they are registered automatically.',
    });
  }

  /// Runs a cycle-driving operation (prompt / remind / allocate). Requires
  /// the wired [service]; the ops themselves follow the same code path as
  /// the admin bot commands.
  Future<(int, Object)> _runCycleOp(String op) async {
    final service = this.service;
    if (service == null) {
      return (400, {'ok': false, 'error': 'cycle service not wired'});
    }
    final now = config.toLocal(Config.nowUtc());
    final cycle = repo.ensureCurrentCycle(now);
    switch (op) {
      case 'prompt':
        await service.sendPrompts(cycle);
        LogRing.log('admin API: prompts sent');
        return (200, {'ok': true, 'op': op});
      case 'remind':
        await service.sendReminders(cycle);
        LogRing.log('admin API: reminders sent');
        return (200, {'ok': true, 'op': op});
      case 'allocate':
        await service.allocate(cycle);
        LogRing.log('admin API: allocation run');
        return (200, {'ok': true, 'op': op});
    }
    return (400, {'ok': false, 'error': 'unknown op'});
  }

  /// Sends the availability picker to one member, like the admin /ask.
  Future<(int, Object)> _ask(String bodyText) async {
    final service = this.service;
    if (service == null) {
      return (400, {'ok': false, 'error': 'cycle service not wired'});
    }
    final body = _jsonBody(bodyText);
    final id = (body['userId'] as num?)?.toInt();
    if (id == null) {
      return (400, {'ok': false, 'error': 'expected {"userId": <id>}'});
    }
    final user = repo.findUser(id);
    if (user == null) return (404, {'ok': false, 'error': 'no such user'});
    final now = config.toLocal(Config.nowUtc());
    final cycle = repo.ensureCurrentCycle(now);
    final text = service.promptFor(user, cycle) ??
        service.messages.msg1(user.group);
    await service.showAvailability(user, cycle, text);
    LogRing.log('admin API: ask ${user.name}');
    return (200, {'ok': true, 'asked': user.name});
  }

  /// Sends [text] to every active member, like the admin /broadcast.
  Future<(int, Object)> _broadcast(String bodyText) async {
    final service = this.service;
    if (service == null) {
      return (400, {'ok': false, 'error': 'cycle service not wired'});
    }
    final body = _jsonBody(bodyText);
    final text = (body['text'] as String?)?.trim() ?? '';
    if (text.isEmpty) {
      return (400, {'ok': false, 'error': 'expected {"text": "..."}'});
    }
    var sent = 0;
    for (final user in repo.activeUsers()) {
      try {
        await service.bot.api.sendMessage(ChatID(user.id), text);
        sent++;
      } catch (_) {
        // member may have blocked the bot
      }
    }
    LogRing.log('admin API: broadcast sent to $sent members');
    return (200, {'ok': true, 'sent': sent});
  }

  /// Current cycle's sessions with their allocated members and attended
  /// flags, for the console's attendance screen.
  Map<String, Object?> _attendanceBody() {
    final now = config.toLocal(Config.nowUtc());
    final cycle = repo.ensureCurrentCycle(now);
    final allocations = repo.allocationsForCycle(cycle.id);
    final bySession = <int, List<User>>{};
    for (final (u, s) in allocations) {
      bySession.putIfAbsent(s.id, () => []).add(u);
    }
    return {
      'ok': true,
      'cycleStatus': cycle.status.name,
      'sessions': [
        for (final s in repo.sessionsForCycle(cycle.id))
          {
            'id': s.id,
            'label': _sessionLabel(s),
            'location': s.location.name,
            'weekendIndex': s.weekendIndex,
            'day': s.day,
            'slot': s.slot,
            'members': [
              for (final u in bySession[s.id] ?? const <User>[])
                {
                  'id': u.id,
                  'name': u.name,
                  'attended': repo
                      .attendanceForSession(s.id)
                      .any((a) => a.userId == u.id),
                },
            ],
          },
      ],
    };
  }

  /// Toggles one member's attendance for one session; returns the new state.
  Future<(int, Object)> _toggleAttendance(String bodyText) async {
    final body = _jsonBody(bodyText);
    final sessionId = (body['sessionId'] as num?)?.toInt();
    final userId = (body['userId'] as num?)?.toInt();
    if (sessionId == null || userId == null) {
      return (400, {
        'ok': false,
        'error': 'expected {"sessionId": <id>, "userId": <id>}',
      });
    }
    final session = repo.sessionById(sessionId);
    if (session == null) return (404, {'ok': false, 'error': 'no such session'});
    final user = repo.findUser(userId);
    if (user == null) return (404, {'ok': false, 'error': 'no such user'});
    final already = repo
        .attendanceForSession(sessionId)
        .any((a) => a.userId == userId);
    if (already) {
      repo.raw.execute(
        'DELETE FROM attendance WHERE user_id = ? AND session_id = ?',
        [userId, sessionId],
      );
    } else {
      repo.confirmAttendance(userId, sessionId);
    }
    LogRing.log('admin API: attendance ${already ? 'unmarked' : 'marked'} '
        '${user.name}');
    return (200, {'ok': true, 'attended': !already});
  }

  static String _sessionLabel(Session s) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final loc = s.location == Location.ocbc ? 'OCBC' : 'Pasir Ris';
    final day = s.day == 'sat' ? 'Saturday' : 'Sunday';
    final slot = s.slot == 'am' ? 'AM' : 'PM';
    return '$loc · $day ${s.start.day} ${months[s.start.month - 1]} $slot';
  }

  Future<(int, Object)> _setHold(String bodyText) async {
    final body = _jsonBody(bodyText);
    final held = body['held'];
    if (held is! bool) {
      return (400, {'ok': false, 'error': 'expected {"held": bool}'});
    }
    repo.setHeld(held);
    holdGate.held = held;
    LogRing.log('admin API: ${held ? 'hold' : 'unhold'}');
    return (200, {'ok': true, 'held': held});
  }

  Future<(int, Object)> _setDate(String bodyText) async {
    final body = _jsonBody(bodyText);
    if (body['reset'] == true) {
      Config.setDebugNow(null);
      LogRing.log('admin API: reset-date');
      return (200, {'ok': true, 'held': false, 'reset': true});
    }
    final raw = (body['date'] as String?) ?? '';
    final parsed = _parseDate(raw);
    if (parsed == null) {
      return (400, {'ok': false, 'error': 'expected {"date": "YYYY-MM-DD [HH:MM]"}'});
    }
    Config.setDebugNow(parsed);
    LogRing.log('admin API: set-date to $raw');
    return (200, {'ok': true, 'date': raw});
  }

  Future<(int, Object)> _syncCalendar(String bodyText) async {
    final body = _jsonBody(bodyText);
    final yaml = (body['yaml'] as String?) ?? '';
    if (yaml.trim().isEmpty) {
      return (400, {'ok': false, 'error': 'expected {"yaml": "..."}'});
    }
    try {
      final result = calendarSync.apply(yaml);
      LogRing.log(
          'admin API: sync-calendar ${result.academicYear} '
          '(${result.weeks} weeks, ${result.holidays} holidays)');
      return (200, {
        'ok': true,
        'academicYear': result.academicYear,
        'weeks': result.weeks,
        'holidays': result.holidays,
      });
    } catch (e) {
      return (400, {'ok': false, 'error': 'sync failed: $e'});
    }
  }

  Future<(int, Object)> _setLogRetention(String bodyText) async {
    final body = _jsonBody(bodyText);
    final days = body['days'];
    if (days is! num || days <= 0) {
      return (400, {'ok': false, 'error': 'expected {"days": <positive int>}'});
    }
    final wholeDays = days.toInt();
    repo.setSetting('log_retention_days', '$wholeDays');
    LogRing.setRetention(Duration(days: wholeDays));
    LogRing.log('admin API: log retention set to $wholeDays days');
    return (200, {'ok': true, 'days': wholeDays});
  }

  /// Parses "YYYY-MM-DD [HH:MM]" into the debug "now" instant (UTC, offset
  /// applied), mirroring the console /setdate behavior.
  DateTime? _parseDate(String input) {
    final parts = input.trim().split(RegExp(r'\s+'));
    final date = DateTime.tryParse(parts.first);
    if (date == null) return null;
    var local = DateTime(date.year, date.month, date.day);
    if (parts.length > 1) {
      final t = parts[1].split(':');
      final h = int.tryParse(t[0]);
      final m = t.length > 1 ? int.tryParse(t[1]) : 0;
      if (h == null || m == null) return null;
      local = DateTime(date.year, date.month, date.day, h, m);
    }
    return local
        .subtract(Duration(hours: config.timezoneOffsetHours))
        .toUtc();
  }

  static Map<String, dynamic> _jsonBody(String text) {
    if (text.trim().isEmpty) return {};
    return jsonDecode(text) as Map<String, dynamic>;
  }
}