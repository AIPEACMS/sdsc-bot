import 'dart:convert';
import 'dart:io';

import '../core/config.dart';
import '../core/log.dart';
import '../core/models.dart';
import '../core/repo.dart';
import 'calendar_sync.dart';
import 'hold.dart';

/// HTTP admin API for the desktop console app. Every request must present the
/// configured bearer token (`Authorization: Bearer <token>`). Bound to all
/// interfaces so the app can reach it over the tailnet; the token is the
/// only gate.
///
/// Endpoints:
///   GET   /api/state                     -> held flag, debug clock, cycle
///   GET   /api/users                     -> every user with tier + attendance
///   POST  /api/users/{id}/tier           -> { "tier": "admin|check|member|old" }
///   POST  /api/hold                      -> { "held": true|false }
///   POST  /api/date                      -> { "date": "YYYY-MM-DD HH:MM" } | { "reset": true }
///   POST  /api/sync-calendar             -> { "yaml": "..." }
///   GET   /api/logs                      -> { "lines": [...] }
class AdminApi {
  final Repo repo;
  final Config config;
  final CalendarSync calendarSync;
  final HoldGate holdGate;
  final String token;
  final int port;

  HttpServer? _server;

  AdminApi({
    required this.repo,
    required this.config,
    required this.calendarSync,
    required this.holdGate,
    required this.token,
    required this.port,
  });

  /// The actual bound port (differs from [port] when 0 = ephemeral).
  int get boundPort => _server?.port ?? port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen(_handle);
    LogRing.log('admin API listening on :$boundPort');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  bool _authorized(HttpRequest req) {
    final raw = req.headers.value(HttpHeaders.authorizationHeader);
    if (raw == null || !raw.startsWith('Bearer ')) return false;
    return raw.substring('Bearer '.length) == token;
  }

  Future<void> _handle(HttpRequest req) async {
    HttpResponse res;
    try {
      if (!_authorized(req)) {
        res = _json(req, 401, {'ok': false, 'error': 'unauthorized'});
      } else {
        res = await _route(req);
      }
    } catch (e) {
      res = _json(req, 500, {'ok': false, 'error': 'internal: $e'});
    }
    await res.close();
  }

  Future<HttpResponse> _route(HttpRequest req) async {
    final segs = req.uri.pathSegments;
    if (segs.length < 2 || segs[0] != 'api') {
      return _json(req, 404, {'ok': false, 'error': 'not found'});
    }
    final kind = segs[1];
    final method = req.method.toUpperCase();

    switch (kind) {
      case 'state':
        if (method == 'GET') return _json(req, 200, _stateBody());
      case 'users':
        if (method == 'GET' && segs.length == 2) {
          return _json(req, 200, {'ok': true, 'users': _usersJson()});
        }
        if (method == 'POST' &&
            segs.length == 4 &&
            segs[3] == 'tier' &&
            segs[2].isNotEmpty) {
          final id = int.tryParse(segs[2]);
          if (id == null) {
            return _json(req, 400, {'ok': false, 'error': 'bad user id'});
          }
          return _setTier(req, id);
        }
      case 'hold':
        if (method == 'POST') return _setHold(req);
      case 'date':
        if (method == 'POST') return _setDate(req);
      case 'sync-calendar':
        if (method == 'POST') return _syncCalendar(req);
      case 'logs':
        if (method == 'GET') {
          return _json(req, 200, {'ok': true, 'lines': LogRing.snapshot});
        }
    }
    return _json(req, 404, {'ok': false, 'error': 'not found'});
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

  Future<HttpResponse> _setTier(HttpRequest req, int id) async {
    final user = repo.findUser(id);
    if (user == null) return _json(req, 404, {'ok': false, 'error': 'no such user'});
    if (config.isConsole(id)) {
      return _json(req, 400, {'ok': false, 'error': 'cannot change console tier'});
    }
    final body = await _body(req);
    final tier = (body['tier'] as String?) ?? '';
    if (!MemberTier.order.contains(tier) || tier == MemberTier.console) {
      return _json(req, 400, {'ok': false, 'error': 'bad tier'});
    }
    repo.setTier(id, tier);
    final updated = repo.findUser(id)!;
    LogRing.log('admin API: ${user.name} ${user.isAdmin ? 'admin' : ''} → tier $tier');
    return _json(req, 200, {
      'ok': true,
      'user': updated.name,
      'tier': MemberTier.of(updated, isConsole: config.isConsole(id)),
    });
  }

  Future<HttpResponse> _setHold(HttpRequest req) async {
    final body = await _body(req);
    final held = body['held'];
    if (held is! bool) {
      return _json(req, 400, {'ok': false, 'error': 'expected {"held": bool}'});
    }
    repo.setHeld(held);
    holdGate.held = held;
    LogRing.log('admin API: ${held ? 'hold' : 'unhold'}');
    return _json(req, 200, {'ok': true, 'held': held});
  }

  Future<HttpResponse> _setDate(HttpRequest req) async {
    final body = await _body(req);
    if (body['reset'] == true) {
      Config.setDebugNow(null);
      LogRing.log('admin API: reset-date');
      return _json(req, 200, {'ok': true, 'held': false, 'reset': true});
    }
    final raw = (body['date'] as String?) ?? '';
    final parsed = _parseDate(raw);
    if (parsed == null) {
      return _json(req, 400,
          {'ok': false, 'error': 'expected {"date": "YYYY-MM-DD [HH:MM]"}'});
    }
    Config.setDebugNow(parsed);
    LogRing.log('admin API: set-date to $raw');
    return _json(req, 200, {'ok': true, 'date': raw});
  }

  Future<HttpResponse> _syncCalendar(HttpRequest req) async {
    final body = await _body(req);
    final yaml = (body['yaml'] as String?) ?? '';
    if (yaml.trim().isEmpty) {
      return _json(req, 400,
          {'ok': false, 'error': 'expected {"yaml": "..."}'});
    }
    try {
      final result = calendarSync.apply(yaml);
      LogRing.log(
          'admin API: sync-calendar ${result.academicYear} '
          '(${result.weeks} weeks, ${result.holidays} holidays)');
      return _json(req, 200, {
        'ok': true,
        'academicYear': result.academicYear,
        'weeks': result.weeks,
        'holidays': result.holidays,
      });
    } catch (e) {
      return _json(req, 400, {'ok': false, 'error': 'sync failed: $e'});
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

  static Future<Map<String, dynamic>> _body(HttpRequest req) async {
    final text = await utf8.decoder.bind(req).join();
    if (text.trim().isEmpty) return {};
    return jsonDecode(text) as Map<String, dynamic>;
  }

  static HttpResponse _json(HttpRequest req, int status, Object body) {
    final res = req.response;
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    return res;
  }
}