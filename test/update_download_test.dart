import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/update_download.dart';

/// One throwaway loopback server per test (same pattern as update_check_test).
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

void main() {
  // Flutter's test binding replaces HttpClient with a mock that answers every
  // request with 400; these tests need the real socket implementation.
  setUpAll(() {
    HttpOverrides.global = null;
  });

  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('dbpilot-download-test');
  });
  tearDown(() async {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('streams the package, reports progress and writes the file', () async {
    final payload = List<int>.generate(120000, (i) => i % 251);
    final server = await LocalServer.start((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.binary
        ..contentLength = payload.length
        ..add(payload);
      await request.response.close();
    });
    addTearDown(server.close);

    final ticks = <UpdateDownloadProgress>[];
    final file = await downloadUpdatePackage(
      url: '${server.baseUrl}/DBPilot-1.1.0-macos.zip',
      directory: temp,
      fileName: 'DBPilot-1.1.0-macos.zip',
      onProgress: ticks.add,
      isCancelled: () => false,
    );

    expect(file.path, endsWith('/DBPilot-1.1.0-macos.zip'));
    expect(await file.length(), payload.length);
    expect(await file.readAsBytes(), payload);
    expect(ticks.first.received, 0);
    expect(ticks.first.total, payload.length);
    expect(ticks.last.done, isTrue);
    expect(ticks.last.received, payload.length);
    expect(ticks.last.fraction, 1.0);
    // The .part file is renamed into place, never left behind.
    expect(File('${file.path}.part').existsSync(), isFalse);
  });

  test('a non-200 response throws and leaves no file behind', () async {
    final server = await LocalServer.start((request) async {
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    });
    addTearDown(server.close);

    await expectLater(
      downloadUpdatePackage(
        url: '${server.baseUrl}/x',
        directory: temp,
        fileName: 'x.zip',
        onProgress: (_) {},
        isCancelled: () => false,
      ),
      throwsA(isA<UpdateDownloadException>()),
    );
    expect(temp.listSync().whereType<File>(), isEmpty);
  });

  test('cancelling deletes the partial file', () async {
    final chunk = List<int>.filled(60000, 7);
    final server = await LocalServer.start((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.binary
        ..contentLength = chunk.length * 4;
      for (var i = 0; i < 4; i++) {
        request.response.add(chunk);
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await request.response.close();
    });
    addTearDown(server.close);

    var checks = 0;
    await expectLater(
      downloadUpdatePackage(
        url: '${server.baseUrl}/big',
        directory: temp,
        fileName: 'big.zip',
        onProgress: (_) {},
        // First check passes (so one chunk is written), the next one cancels.
        isCancelled: () => checks++ > 0,
      ),
      throwsA(isA<UpdateCancelledException>()),
    );
    expect(temp.listSync().whereType<File>(), isEmpty);
  });

  test('invalid URLs and file names are rejected before any network use',
      () async {
    Future<void> expectRejected(String url, String fileName) => expectLater(
          downloadUpdatePackage(
            url: url,
            directory: temp,
            fileName: fileName,
            onProgress: (_) {},
            isCancelled: () => false,
          ),
          throwsA(isA<UpdateDownloadException>()),
        );

    await expectRejected('ftp://example.com/x', 'x.zip');
    await expectRejected('https://example.com/x', '../x.zip');
    await expectRejected('https://example.com/x', 'a/b.zip');
  });
}
