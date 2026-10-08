import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:sdsc_bot/sdsc_bot.dart';
import 'package:sdsc_bot/bot/admin_api.dart';
import 'package:sdsc_bot/bot/key_auth.dart';
import 'support/admin_api_harness.dart';

void main() {
  setUp(setUpAdminApi);
  tearDown(tearDownAdminApi);
  test(
    'GET /api/server-info exposes the server identity for pinning',
    () async {
      final (status, headers, body) = await rawGet('/api/server-info');
      expect(status, 200);
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json['ok'], true);
      expect(json['pubkey'], isNotEmpty);
      expect(
        json['fingerprint'],
        KeyAuth.fingerprint(json['pubkey'] as String),
      );
      // Unauthenticated — reachable before any key is registered.
      expect(headers['x-sdsc-server-pub'], json['pubkey']);
      expect(headers['x-sdsc-server-sig'], isNotEmpty);
    },
  );

  test('every response is signed by the server identity', () async {
    final (_, _, infoBody) = await rawGet('/api/server-info');
    final serverPub =
        (jsonDecode(infoBody) as Map<String, dynamic>)['pubkey'] as String;

    final client = HttpClient();
    try {
      final req = await client.openUrl(
        'GET',
        Uri.parse('http://127.0.0.1:${api.boundPort}/api/state'),
      );
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final headers = <String, String>{};
      res.headers.forEach(
        (name, values) =>
            headers[name.toLowerCase()] = values.isEmpty ? '' : values.first,
      );

      expect(headers['x-sdsc-server-pub'], serverPub);
      final ts = headers['x-sdsc-server-ts']!;
      final sig = headers['x-sdsc-server-sig']!;
      final message = KeyAuth.serverMessage(
        method: 'GET',
        path: '/api/state',
        ts: ts,
        nonce: '', // bearer-token request, no client nonce
        bodyHash: KeyAuth.bodyHash(utf8.encode(text)),
      );
      expect(
        await KeyAuth.verifySignature(
          pubkeyB64: serverPub,
          signatureB64: sig,
          message: utf8.encode(message),
        ),
        isTrue,
      );
    } finally {
      client.close(force: true);
    }
  });

  test('rejects requests without the bearer token', () async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(
        'GET',
        Uri.parse('http://127.0.0.1:${api.boundPort}/api/users'),
      );
      final res = await req.close();
      expect(res.statusCode, 401);
      await res.drain<void>();
    } finally {
      client.close(force: true);
    }
  });

  // ---------------------------------------------------------- key auth

  test('a registered console key authenticates signed requests', () async {
    final (status, body) = await signedCall('GET', '/api/users');
    final bodyMap = body as Map<String, dynamic>;
    expect(status, 200);
    expect(bodyMap['ok'], true);
  });

  test('an unregistered key is rejected even with a valid signature', () async {
    final key = repo.listConsoleKeys().single.pubkey;
    repo.removeConsoleKey(key);
    final (status, _) = await signedCall('GET', '/api/users');
    expect(status, 401);
  });

  test('a signed request with a tampered body is rejected', () async {
    // Sign for body {"held":true} but actually send
    // {"held":false}: the sha256 in the signature no longer matches.
    final bodyBytes = utf8.encode(jsonEncode({'held': true}));
    final bodyHash = KeyAuth.bodyHash(bodyBytes);
    final ts = DateTime.now().millisecondsSinceEpoch.toString();
    final nonce = 'tamper-${rand.nextInt(1 << 32)}';
    final (pub, sig) = await signKey(
      'POST',
      '/api/hold',
      bodyHash,
      ts: ts,
      nonce: nonce,
    );

    final client = HttpClient();
    try {
      final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:${api.boundPort}/api/hold'),
      );
      req.headers.set('X-SDSC-Pub', pub);
      req.headers.set('X-SDSC-Ts', ts);
      req.headers.set('X-SDSC-Nonce', nonce);
      req.headers.set('X-SDSC-Sig', sig);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'held': false}));
      final res = await req.close();
      expect(res.statusCode, 401);
      await res.drain<void>();
    } finally {
      client.close(force: true);
    }
  });

  test('replaying the same signed request (nonce) is rejected', () async {
    final ts = DateTime.now().millisecondsSinceEpoch.toString();
    final nonce = 'replay-${rand.nextInt(1 << 32)}';
    final first = await signedCall('GET', '/api/state', ts: ts, nonce: nonce);
    expect(first.$1, 200);
    final second = await signedCall('GET', '/api/state', ts: ts, nonce: nonce);
    expect(second.$1, 401);
  });

  test('a stale timestamp is rejected', () async {
    final stale = (DateTime.now().millisecondsSinceEpoch - 10 * 60 * 1000)
        .toString();
    final (status, _) = await signedCall('GET', '/api/state', ts: stale);
    expect(status, 401);
  });

  test('a signature bound to another path is rejected', () async {
    // Sign the message for /api/state but hit /api/users.
    final bodyHash = KeyAuth.bodyHash(utf8.encode(''));
    final ts = DateTime.now().millisecondsSinceEpoch.toString();
    final nonce = 'path-${rand.nextInt(1 << 32)}';
    final (pub, sig) = await signKey(
      'GET',
      '/api/state',
      bodyHash,
      ts: ts,
      nonce: nonce,
    );

    final client = HttpClient();
    try {
      final req = await client.openUrl(
        'GET',
        Uri.parse('http://127.0.0.1:${api.boundPort}/api/users'),
      );
      req.headers.set('X-SDSC-Pub', pub);
      req.headers.set('X-SDSC-Ts', ts);
      req.headers.set('X-SDSC-Nonce', nonce);
      req.headers.set('X-SDSC-Sig', sig);
      final res = await req.close();
      expect(res.statusCode, 401);
      await res.drain<void>();
    } finally {
      client.close(force: true);
    }
  });

  test('the calendar IPC token never authorizes the admin API', () async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(
        'GET',
        Uri.parse('http://127.0.0.1:${api.boundPort}/api/state'),
      );
      req.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer calendar-cron-token',
      );
      final res = await req.close();
      expect(res.statusCode, 401);
      await res.drain<void>();
    } finally {
      client.close(force: true);
    }
  });
}
