// Live regression for ROUND68 P2-02: a MySQL server that REQUIRES TLS
// (require_secure_transport=ON) must connect with SSL mode = require and
// certificate check = require, even though its certificate is self-signed and
// has no SAN.
//
// The 3307 fixture from tools/tls_fixture.sh is exactly that server: plaintext
// connections are rejected, so a successful connect proves TLS was negotiated.
// Credentials come from the fixture environment (DBPILOT_TLS_MYSQL_*); when the
// fixture is not running the test SKIPs.
//
// This exercises the same Dart->Rust path the connection form uses
// (createConnection -> connectConnection), so it pins the behaviour the GUI
// depends on: ssl_verify = require must map to MySqlSslMode::Required and not
// to VerifyIdentity (which rejected the self-signed certificate).
// ignore_for_file: prefer_interpolation_to_compose_strings
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';

String _env(String key, String fallback) =>
    Platform.environment[key] ?? fallback;

void main() {
  late Directory dir;

  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run cargo build --lib in rust/ first: ' + dylib.path + ' is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    dir = await Directory.systemTemp.createTemp('rma-tls-require-');
    final init = await Api.init(dir.path);
    expect(init['ok'], isTrue, reason: 'init_app failed: ' + init.toString());
    await AppState.instance.bootstrap(dir.path);
  });

  tearDownAll(() async {
    try {
      await AppState.instance.disconnect();
    } catch (_) {}
    await dir.delete(recursive: true);
  });

  test('MySQL TLS-required server connects with require, rejects verify-full',
      () async {
    final port = int.tryParse(_env('DBPILOT_TLS_MYSQL_PORT', '3307')) ?? 3307;
    final user = _env('DBPILOT_TLS_MYSQL_USER', 'tlstest');
    final password = _env('DBPILOT_TLS_MYSQL_PASSWORD', 'TlsPass!2026');

    final reachable = await Socket.connect('127.0.0.1', port).then((socket) {
      socket.destroy();
      return true;
    }).catchError((_) => false);
    if (!reachable) {
      markTestSkipped('MySQL TLS fixture on 127.0.0.1:' +
          port.toString() +
          ' is not running (tools/tls_fixture.sh up)');
      return;
    }

    final created = await Api.instance.createConnection(<String, dynamic>{
      'name': 'round69-tls-require',
      'driver': 'mysql',
      'host': '127.0.0.1',
      'port': port,
      'user': user,
      'password': password,
      'ssl_mode': 'require',
      // The form's new default for the certificate check.
      'ssl_verify': 'require',
    });
    final id = ((created['connection'] as Map)['id']).toString();
    expect(id, isNotEmpty,
        reason: 'connection not created: ' + created.toString());

    // Plaintext is rejected by require_secure_transport, so success means TLS.
    await AppState.instance.connect(id);
    expect(AppState.instance.connected, isTrue);
    expect(AppState.instance.serverVersion, isNotEmpty);

    // The same server must still reject a chain-validating connection without a
    // CA: verify-full on a self-signed certificate fails. That is the exact
    // round-68 failure, and it proves require really differs from verify-full.
    final strict = await Api.instance.createConnection(<String, dynamic>{
      'name': 'round69-tls-verify-full',
      'driver': 'mysql',
      'host': '127.0.0.1',
      'port': port,
      'user': user,
      'password': password,
      'ssl_mode': 'require',
      'ssl_verify': 'verify-full',
    });
    final strictId = ((strict['connection'] as Map)['id']).toString();
    var strictFailed = false;
    try {
      await AppState.instance.connect(strictId);
    } catch (_) {
      strictFailed = true;
    }
    expect(strictFailed, isTrue,
        reason: 'verify-full must reject a self-signed certificate without a CA');

    await AppState.instance.disconnect();
  });
}