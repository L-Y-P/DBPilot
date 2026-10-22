//! P1 through the real FFI bridge: table exports stream to a file.
//!
//! The Rust integration test covers the streaming implementation; this test
//! drives the same call the table page uses (`Api.instance.exportTable`) so the
//! bridge, the `path` parameter and the "no content in the response" contract
//! are covered together.

import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';

void main() {
  late Directory temporary;
  late String connectionId;

  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run `cargo build --lib` in rust/ first: ${dylib.path} is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    temporary = await Directory.systemTemp.createTemp('rma-export-ffi-');
    final init = await Api.init(temporary.path);
    expect(init['ok'], isTrue, reason: 'init_app failed: $init');
    await AppState.instance.bootstrap(temporary.path);
    final dbFile = '${temporary.path}/export.sqlite';
    File(dbFile).createSync(recursive: true);
    final created = await Api.instance.createConnection({
      'name': 'Export FFI',
      'driver': 'sqlite',
      'database': dbFile,
    });
    connectionId = ((created['connection'] as Map)['id']).toString();
    await AppState.instance.connect(connectionId);
  });

  tearDownAll(() async {
    try {
      await Api.instance.disconnect();
    } catch (_) {}
    try {
      temporary.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('export writes a file instead of returning its content',
      (tester) async {
    final setup = await tester.runAsync(() => Api.instance.query(
        'CREATE TABLE big(x INTEGER); '
        'WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 60000) '
        'INSERT INTO big SELECT x FROM c;'));
    expect(setup, isNotNull);
    expect(
      (setup!['results'] as List).every((r) => (r as Map)['error'] == null),
      isTrue,
      reason: 'setup failed: $setup',
    );

    final target = '${temporary.path}/export.csv';
    final response = await tester.runAsync(() => Api.instance.exportTable(
        'main',
        'big',
        {'format': 'csv', 'path': target}));
    expect(response, isNotNull);
    expect(response!['written'], isTrue);
    expect(response['rows'], 60000);
    expect(response['content'], '',
        reason: 'the payload must not cross the bridge as a String');

    final exported = File(target).readAsStringSync();
    final lines = exported.split('\n').where((l) => l.isNotEmpty).toList();
    expect(lines.length, 60001);
    expect(lines.first, 'x');
    expect(lines.last, '60000');

    // Preview mode stays byte-capped and reports truncation.
    final preview = await tester.runAsync(
        () => Api.instance.exportTable('main', 'big', {'format': 'csv'}));
    expect(preview!['truncated'], isTrue);
    expect((preview['content'] as String).length, lessThanOrEqualTo(256 * 1024));
    expect(preview['rows'], lessThan(60000));
  });
}
