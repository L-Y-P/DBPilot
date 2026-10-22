//! S-08 end-to-end through the real FFI bridge.
//!
//! The Rust unit/integration tests prove the console caps rows. This drives the
//! same path the SQL console uses (`Api.instance.query` -> flutter_rust_bridge
//! -> Rust) so the row cap, the truncation flag and the JSON transfer of a
//! large result are covered together. A 60,000-row SELECT must come back as
//! exactly 50,000 rows plus `truncated: true`, quickly enough to keep the UI
//! responsive.

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
    temporary = await Directory.systemTemp.createTemp('rma-sql-cap-');
    final init = await Api.init(temporary.path);
    expect(init['ok'], isTrue, reason: 'init_app failed: $init');
    await AppState.instance.bootstrap(temporary.path);
    final dbFile = '${temporary.path}/big.sqlite';
    File(dbFile).createSync(recursive: true);
    final created = await Api.instance.createConnection({
      'name': 'SQL cap',
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

  testWidgets('a 60k-row SELECT is capped at 50k and flagged truncated',
      (tester) async {
    final setup = await tester.runAsync(() => Api.instance.query(
        'CREATE TABLE big(x INTEGER); '
        'WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 60000) '
        'INSERT INTO big SELECT x FROM c;'));
    expect(setup, isNotNull);
    expect(
      (setup!['results'] as List)
          .every((r) => (r as Map)['error'] == null),
      isTrue,
      reason: 'setup failed: $setup',
    );

    final stopwatch = Stopwatch()..start();
    final response = await tester.runAsync(
        () => Api.instance.query('SELECT x FROM big ORDER BY x'));
    stopwatch.stop();
    expect(response, isNotNull);

    // The cap and flag are reported by the backend.
    expect(response!['truncated'], isTrue);
    expect(response['row_limit'], 50000);
    final first = (response['results'] as List).first as Map;
    expect(first['kind'], 'rows');
    expect(first['truncated'], isTrue);
    final rows = first['rows'] as List;
    expect(rows.length, 50000);
    expect((rows.first as List).first, 1);
    expect((rows.last as List).first, 50000);

    // The transfer/decoding of ~50k rows must stay well short of a UI freeze.
    // 30s is deliberately generous: the assertion is "no minute-long hang",
    // not a CI-fragile benchmark.
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 30)),
        reason: '50k-row result took ${stopwatch.elapsed}');

    // A small query is unaffected.
    final small = await tester
        .runAsync(() => Api.instance.query('SELECT COUNT(*) AS c FROM big'));
    expect(small!['truncated'], isFalse);
    final countRows = ((small['results'] as List).first as Map)['rows'] as List;
    expect((countRows.first as List).first, 60000);
  });
}
