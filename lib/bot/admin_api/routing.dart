part of '../admin_api.dart';

extension AdminApiRouting on AdminApi {

  /// Wired from main.dart with the real [CycleService]. The cycle-driving
  /// endpoints (prompt/remind/allocate/ask/broadcast) require it; everything
  /// else works without it (and does in tests).
  /// Wired from main.dart: called after a location is added/approved so the
  /// waiting global admin is told and can confirm the new session list.
  RollingWindow _window(DateTime now) => scheduleRuntime.window(now);

  /// The actual bound port (differs from [port] when 0 = ephemeral).
  int get boundPort => _server?.port ?? port;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen(_handle);
    LogRing.log('admin API listening on :$boundPort');
    LogRing.log('admin API server fingerprint ${await identity.fingerprint()}');
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

      if (!await _authorized(
        req,
        method: method,
        path: path,
        bodyBytes: bodyBytes,
      )) {
        await _send(req, 401, {'ok': false, 'error': 'unauthorized'});
        return;
      }
      final route = await _route(req, utf8.decode(bodyBytes));
      await _send(req, route.$1, route.$2);
    } catch (e) {
      await _send(req, 500, {'ok': false, 'error': 'internal: $e'});
    }
  }

  Future<List<int>> _readBody(HttpRequest req) async {
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
        if (segs.length != 2) return (404, {'ok': false, 'error': 'not found'});
        if (method == 'GET') return (200, _stateBody());
      case 'active-outreach':
        if (segs.length != 2 || method != 'POST') {
          return (404, {'ok': false, 'error': 'not found'});
        }
        return _setActiveOutreach(bodyText);
      case 'schedule':
        if (segs.length != 2) return (404, {'ok': false, 'error': 'not found'});
        if (method == 'GET') return (200, _scheduleBody());
        if (method == 'POST') return this._setSchedule(bodyText);
      case 'users':
        if (method == 'GET' && segs.length == 2) {
          return (200, {'ok': true, 'users': _usersJson()});
        }
        if (method == 'POST' && segs.length == 2) {
          return this._addUser(bodyText);
        }
        if (method == 'POST' && segs.length == 4 && segs[3].isNotEmpty) {
          final id = int.tryParse(segs[2]);
          if (id == null) {
            return (400, {'ok': false, 'error': 'bad user id'});
          }
          switch (segs[3]) {
            case 'tier':
              return this._setTier(id, bodyText);
            case 'admin':
              return this._setUserAdmin(id, bodyText);
            case 'gadmin':
              return this._setUserGlobalAdmin(id, bodyText);
            case 'exp':
              return this._setUserExp(id, bodyText);
            case 'group':
              return this._setUserGroup(id, bodyText);
            case 'notification':
            case 'notify':
              return this._setUserNotification(id, bodyText);
          }
        }
        if (method == 'GET' && segs.length == 4 &&
            (segs[3] == 'notification' || segs[3] == 'notify')) {
          final id = int.tryParse(segs[2]);
          if (id == null) return (400, {'ok': false, 'error': 'bad user id'});
          return this._getUserNotification(id);
        }
      case 'assign-groups':
        if (method == 'POST') return this._assignGroups();
      case 'locations':
        if (method == 'GET' && segs.length == 2) {
          return (200, this._locationsBody());
        }
        if (method == 'POST' && segs.length == 2) {
          return this._createLocation(bodyText);
        }
        if (method == 'POST' &&
            segs.length == 4 &&
            segs[3] == 'approve' &&
            segs[2].isNotEmpty) {
          final id = int.tryParse(segs[2]);
          if (id == null) {
            return (400, {'ok': false, 'error': 'bad location id'});
          }
          return this._approveLocation(id, bodyText);
        }
      case 'hold':
        if (method == 'POST') return this._setHold(bodyText);
      case 'date':
        if (method == 'POST') return this._setDate(bodyText);
      case 'sync-calendar':
        if (method == 'POST') return this._syncCalendar(bodyText);
      case 'prompt':
        if (method == 'POST') return this._runCycleOp('prompt');
      case 'remind':
        if (method == 'POST') return this._runCycleOp('remind');
      case 'allocate':
        if (method == 'POST') return this._runCycleOp('allocate');
      case 'ask':
        if (method == 'POST') return this._ask(bodyText);
      case 'broadcast':
        if (method == 'POST') return this._broadcast(bodyText);
      case 'attendance':
        if (method == 'GET') return (200, this._attendanceBody());
        if (method == 'POST') return this._toggleAttendance(bodyText);
      case 'logs':
        if (method == 'GET') {
          return (200, {'ok': true, 'lines': LogRing.snapshot});
        }
      case 'log-retention':
        if (method == 'POST') return this._setLogRetention(bodyText);
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
    final w = _window(now);
    return {
      'ok': true,
      'held': holdGate.isHeld,
      'debugNow': Config.hasDebugNow
          ? config.toLocal(Config.nowUtc()).toIso8601String()
          : null,
      'logRetentionDays': LogRing.retentionDays,
      // Keep the event fields available at the state level as well as inside
      // `schedule` for older console clients that flatten this response.
      'promptWeekday': scheduleRuntime.schedule.prompt.weekday,
      'reminderWeekday': scheduleRuntime.schedule.reminder.weekday,
      'lockWeekday': scheduleRuntime.schedule.lock.weekday,
      'checkerWeekday': scheduleRuntime.schedule.checker.weekday,
      'schedule': _scheduleJson(),
      'activeOutreach': repo.activeOutreach(),
      'window': {
        'weekend0': w.sat0.toIso8601String(),
        'weekend1': w.sat1.toIso8601String(),
        'promptDay': w.promptDay.toIso8601String(),
        'reminderDay': w.reminderDay.toIso8601String(),
        'lock0': w.lock0.toIso8601String(),
        'lock1': w.lock1.toIso8601String(),
        'checkerDay': w.checkerDay.toIso8601String(),
        'deadline0': w.deadline0.toIso8601String(),
        'deadline1': w.deadline1.toIso8601String(),
        'allocated0': repo.weekendAllocated(w.sat0),
        'allocated1': repo.weekendAllocated(w.sat1),
      },
    };
  }

  Map<String, Object?> _scheduleJson() => {
    ...scheduleRuntime.schedule.json,
    'timezoneOffset': config.timezoneOffsetHours,
  }

  ;

  Future<(int, Object)> _setActiveOutreach(String bodyText) async {
    final Map<String, dynamic> body;
    try {
      body = this._jsonBody(bodyText);
    } catch (_) {
      return (400, {'ok': false, 'error': 'expected a JSON object'});
    }
    if (body.length != 2 || body['route'] is! String || body['enabled'] is! bool) {
      return (
        400,
        {'ok': false, 'error': 'expected {"route": <key>, "enabled": bool}'},
      );
    }
    final route = body['route'] as String;
    if (!Repo.activeOutreachRouteKeys.contains(route)) {
      return (400, {'ok': false, 'error': 'unknown active outreach route'});
    }
    repo.setActiveOutreach(route, body['enabled'] as bool);
    LogRing.log(
      'admin API: active outreach $route -> '
      '${(body['enabled'] as bool) ? 'enabled' : 'disabled'}',
    );
    return (200, {'ok': true, 'activeOutreach': repo.activeOutreach()});
  }

  Map<String, Object?> _scheduleBody() => {
    'ok': true,
    ..._scheduleJson(),
    'schedule': _scheduleJson(),
  }

}
