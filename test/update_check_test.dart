// The update checker is pure dart:io, so it is driven against a real loopback
// HttpServer: no package, no mocking framework, and the HTTP path (status
// codes, timeouts, body decoding) is exercised for real.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/update_check.dart';
import 'package:rust_myadmin_desktop/src/update_source.dart';

/// One throwaway loopback server per test.
class LocalServer {
  LocalServer._(this._server);

  final HttpServer _server;

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<LocalServer> start(
      FutureOr<void> Function(HttpRequest request) handler) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      Future<void>.sync(() => handler(request)).catchError((_) {});
    });
    return LocalServer._(server);
  }

  Future<void> close() => _server.close(force: true);
}

Future<void> _json(HttpRequest request, Object body, {int status = 200}) async {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(body is String ? body : jsonEncode(body));
  await request.response.close();
}

void main() {
  // Flutter's test binding replaces HttpClient with a mock that answers every
  // request with 400; these tests need the real socket implementation.
  setUpAll(() {
    HttpOverrides.global = null;
  });

  group('compareVersions', () {
    test('equal versions compare equal', () {
      expect(compareVersions('1.0.0', '1.0.0'), 0);
      expect(compareVersions('0.0.0', '0'), 0);
    });

    test('a leading v is ignored', () {
      expect(compareVersions('v1.2.3', '1.2.3'), 0);
      expect(compareVersions('V2.0.0', '1.9.9'), greaterThan(0));
    });

    test('missing segments count as zero', () {
      expect(compareVersions('1.2', '1.2.0'), 0);
      expect(compareVersions('1.2', '1.2.1'), lessThan(0));
      expect(compareVersions('2', '1.9.9'), greaterThan(0));
      expect(compareVersions('', '1.0.0'), lessThan(0));
      expect(compareVersions('1.0.0', ''), greaterThan(0));
    });

    test('segments compare numerically, not lexicographically', () {
      expect(compareVersions('1.10.0', '1.9.0'), greaterThan(0));
      expect(compareVersions('1.2.10', '1.2.9'), greaterThan(0));
      expect(compareVersions('10.0.0', '9.0.0'), greaterThan(0));
    });

    test('build metadata and pre-release suffixes are tolerated', () {
      expect(compareVersions('1.2.3+build5', '1.2.3'), 0);
      expect(compareVersions('1.2.3-rc1', '1.2.3'), 0);
      expect(compareVersions('1.2.3beta', '1.2.3'), 0);
      expect(compareVersions('1.3.0-rc1', '1.2.9'), greaterThan(0));
      expect(compareVersions(' 1.2.3 ', '1.2.3'), 0);
    });

    test('a newer patch/minor/major sorts higher', () {
      expect(compareVersions('1.0.1', '1.0.0'), greaterThan(0));
      expect(compareVersions('1.1.0', '1.0.9'), greaterThan(0));
      expect(compareVersions('2.0.0', '1.99.99'), greaterThan(0));
      expect(compareVersions('1.0.0', '1.0.1'), lessThan(0));
    });
  });

  group('update source', () {
    // The app no longer lets the user edit the manifest address, so the
    // compiled-in constant is the only thing that decides where a check goes.
    // Pin it (and the display label) so a release cannot silently point at the
    // wrong repository.
    test('the manifest URL is the repository\'s main-branch update.json', () {
      expect(kUpdateManifestUrl,
          'https://raw.githubusercontent.com/L-Y-P/DBPilot/main/update.json');
      expect(kUpdateRepoOwner, 'L-Y-P');
      expect(kUpdateRepoName, 'DBPilot');
      expect(kUpdateRepoLabel, 'L-Y-P/DBPilot');
      expect(kUpdateRepoUrl, 'https://github.com/L-Y-P/DBPilot');
    });
  });

  group('checkForUpdates', () {
    test('empty url fails without touching the network', () async {
      final result = await checkForUpdates(
          manifestUrl: '   ', currentVersion: '1.0.0');
      expect(result.hasUpdate, isFalse);
      expect(result.error, '未配置更新源');
      expect(result.latestVersion, isEmpty);
    });

    test('a non-http scheme is rejected', () async {
      final result = await checkForUpdates(
          manifestUrl: 'ftp://example.com/update.json',
          currentVersion: '1.0.0');
      expect(result.hasUpdate, isFalse);
      expect(result.error, contains('更新地址无效'));
    });

    test('a newer manifest reports an update', () async {
      final server = await LocalServer.start((request) => _json(request, {
            'version': '1.1.0',
            'url': 'https://example.com/download',
            'notes': 'Fixes and improvements',
          }));
      addTearDown(server.close);

      final result = await checkForUpdates(
          manifestUrl: '${server.baseUrl}/update.json',
          currentVersion: '1.0.0');
      expect(result.error, isNull);
      expect(result.hasUpdate, isTrue);
      expect(result.currentVersion, '1.0.0');
      expect(result.latestVersion, '1.1.0');
      expect(result.downloadUrl, 'https://example.com/download');
      expect(result.notes, 'Fixes and improvements');
    });

    test('the same version reports no update', () async {
      final server = await LocalServer
          .start((request) => _json(request, <String, Object>{'version': '1.0.0'}));
      addTearDown(server.close);

      final result = await checkForUpdates(
          manifestUrl: server.baseUrl, currentVersion: '1.0.0');
      expect(result.error, isNull);
      expect(result.hasUpdate, isFalse);
      expect(result.latestVersion, '1.0.0');
    });

    test('an older manifest reports no update', () async {
      final server = await LocalServer
          .start((request) => _json(request, <String, Object>{'version': '0.9.0'}));
      addTearDown(server.close);

      final result = await checkForUpdates(
          manifestUrl: server.baseUrl, currentVersion: '1.0.0');
      expect(result.error, isNull);
      expect(result.hasUpdate, isFalse);
    });

    test('missing optional fields become empty strings', () async {
      final server = await LocalServer
          .start((request) => _json(request, <String, Object>{'version': 'v2.0.0'}));
      addTearDown(server.close);

      final result = await checkForUpdates(
          manifestUrl: server.baseUrl, currentVersion: '1.0.0');
      expect(result.hasUpdate, isTrue);
      expect(result.notes, isEmpty);
      expect(result.downloadUrl, isEmpty);
    });

    test('a non-200 response is a readable error', () async {
      final server = await LocalServer.start(
          (request) => _json(request, <String, Object>{'error': 'gone'}, status: 404));
      addTearDown(server.close);

      final result = await checkForUpdates(
          manifestUrl: server.baseUrl, currentVersion: '1.0.0');
      expect(result.hasUpdate, isFalse);
      expect(result.error, '更新检查失败：HTTP 404');
    });

    test('invalid JSON is a readable error', () async {
      final server = await LocalServer.start(
          (request) => _json(request, 'not json at all'));
      addTearDown(server.close);

      final result = await checkForUpdates(
          manifestUrl: server.baseUrl, currentVersion: '1.0.0');
      expect(result.hasUpdate, isFalse);
      expect(result.error, '更新检查失败：更新清单不是合法的 JSON');
    });

    test('a manifest without a version is a readable error', () async {
      final server = await LocalServer.start(
          (request) => _json(request, <String, Object>{'url': 'https://example.com'}));
      addTearDown(server.close);

      final result = await checkForUpdates(
          manifestUrl: server.baseUrl, currentVersion: '1.0.0');
      expect(result.hasUpdate, isFalse);
      expect(result.error, '更新检查失败：更新清单缺少 version 字段');
    });

    test('a JSON array is not a manifest', () async {
      final server =
          await LocalServer.start((request) => _json(request, <Object>[1, 2, 3]));
      addTearDown(server.close);

      final result = await checkForUpdates(
          manifestUrl: server.baseUrl, currentVersion: '1.0.0');
      expect(result.error, '更新检查失败：更新清单不是合法的 JSON');
    });

    test('a slow server hits the timeout', () async {
      final server = await LocalServer.start((request) async {
        await Future<void>.delayed(const Duration(seconds: 3));
        try {
          await _json(request, <String, Object>{'version': '9.9.9'});
        } catch (_) {
          // The client already gave up; closing a torn-down socket throws.
        }
      });
      addTearDown(server.close);

      final result = await checkForUpdates(
        manifestUrl: server.baseUrl,
        currentVersion: '1.0.0',
        timeout: const Duration(milliseconds: 250),
      );
      expect(result.hasUpdate, isFalse);
      expect(result.error, '检查更新超时，请稍后重试');
    });

    test('a refused connection is a readable error', () async {
      // Bind then close so the port is (almost certainly) free again.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close(force: true);

      final result = await checkForUpdates(
          manifestUrl: 'http://127.0.0.1:$port/update.json',
          currentVersion: '1.0.0');
      expect(result.hasUpdate, isFalse);
      expect(result.error, startsWith('更新检查失败：'));
    });

    test('an injected HttpClient is used and left open', () async {
      final server = await LocalServer.start((request) async {
        _json(request, <String, Object>{'version': '1.2.0'});
      });
      addTearDown(server.close);

      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final first = await checkForUpdates(
          manifestUrl: server.baseUrl,
          currentVersion: '1.0.0',
          client: client);
      final second = await checkForUpdates(
          manifestUrl: server.baseUrl,
          currentVersion: '1.0.0',
          client: client);
      expect(first.hasUpdate, isTrue);
      expect(second.hasUpdate, isTrue);
    });
  });
}
