import 'package:PiliPlus/utils/media_url_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.fromMillisecondsSinceEpoch(2000000000 * 1000, isUtc: true);

  test('diagnostics expose expiry without exposing media path or tokens', () {
    const url = 'https://user:password@cdn.example.com/private/video.m4s'
        '?deadline=2000000060&upsig=SECRET&access_key=TOKEN';
    final description = MediaUrlDiagnostics.describe(url, now: now);
    expect(description, 'cdn.example.com · 有效期 60 s（本机时间）');
    for (final sensitive in ['password', 'user', 'private', 'SECRET', 'TOKEN']) {
      expect(description, isNot(contains(sensitive)));
    }
  });

  test('earliest deadline wins including percent encoded Akamai token', () {
    const url = 'https://cdn.example.com/video.m4s?deadline=2000000090'
        '&hdnts=exp%3D2000000030~acl%3D%2F*~hmac%3Dsecret';
    expect(MediaUrlDiagnostics.expiresAt(url), now.add(const Duration(seconds: 30)));
  });

  test('expired URL is observable without changing or rejecting the URL', () {
    const url = 'https://cdn.example.com/v?deadline=1999999990';
    expect(
      MediaUrlDiagnostics.describe(url, now: now),
      'cdn.example.com · 有效期 -10 s（本机时间）',
    );
  });

  test('missing or invalid expiry is not treated as expired', () {
    for (final suffix in ['', '?deadline=bad', '?deadline=0', '?hdnts=invalid']) {
      expect(MediaUrlDiagnostics.expiresAt('https://cdn.example.com/v$suffix'), isNull);
      expect(MediaUrlDiagnostics.describe('https://cdn.example.com/v$suffix'), 'cdn.example.com');
    }
    expect(MediaUrlDiagnostics.describe('edl://sensitive'), '未知');
    expect(MediaUrlDiagnostics.describe(null), '无');
  });

  test('HTTP error classification strips the rest of the player message', () {
    expect(MediaUrlDiagnostics.httpStatus('HTTP error 403 Forbidden'), 403);
    expect(MediaUrlDiagnostics.httpStatus('https: HTTP error 403 Forbidden'), 403);
    expect(MediaUrlDiagnostics.httpStatus('http: Server returned 410 Gone: secret'), 410);
    expect(MediaUrlDiagnostics.httpStatus('HTTP 500 Internal Server Error'), 500);
    expect(MediaUrlDiagnostics.httpStatus('Failed to open https://cdn.example.com/HTTP403?token=secret'), isNull);
    expect(MediaUrlDiagnostics.httpStatus('tls: mbedtls_ssl_handshake returned -0x7280'), isNull);
  });
}
