import 'dart:convert';
import 'dart:io';

import '../core/config.dart';
import '../core/log.dart';
import '../core/models.dart';
import '../core/repo.dart';
import 'calendar_sync.dart';
import 'hold.dart';
import 'key_auth.dart';
import 'server_identity.dart';

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
///   GET   /api/users                    -> every user with tier + attendance
///   POST  /api/users/{id}/tier          -> { "tier": "admin|check|member|old" }
///   POST  /api/hold                     -> { "held": true|false }
///   POST  /api/date                     -> { "date": "YYYY-MM-DD HH:MM" } | { "reset": true }
///   POST  /api/sync-calendar            -> { "yaml": "..." }
///   GET   /api/logs                     -> { "lines": [...] }
class AdminApi {
  final Repo repo;
  final Config config;
  final CalendarSync calendarSync;
  final HoldGate holdGate;
  final String? token;
  final int port;
  final ServerIdentity identity;
  final NonceGuard _nonces = NonceGuard();

  HttpServer? _server;

  AdminApi({
    required this.repo,
    required this.config,
    required this.calendarSync,
    required this.holdGate,
    required this.token,
    required this.port,
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
        if (method == 'POST' &&
            segs.length == 4 &&
            segs[3] == 'tier' &&
            segs[2].isNotEmpty) {
          final id = int.tryParse(segs[2]);
          if (id == null) {
            return (400, {'ok': false, 'error': 'bad user id'});
          }
          return _setTier(id, bodyText);
        }
      case 'hold':
        if (method == 'POST') return _setHold(bodyText);
      case 'date':
        if (method == 'POST') return _setDate(bodyText);
      case 'sync-calendar':
        if (method == 'POST') return _syncCalendar(bodyText);
      case 'logs':
        if (method == 'GET') {
          return (200, {'ok': true, 'lines': LogRing.snapshot});
        }
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

  List<Map<String, Object?>> _usersJson() {
    return [
      for (final u in repo.allUsers())
        {
          'id': u.id,
          'name': u.name,
          'tier': MemberTier.of(u, isConsole: config.isConsole(u.id)),
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
    if (config.isConsole(id)) {
      return (400, {'ok': false, 'error': 'cannot change console tier'});
    }
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