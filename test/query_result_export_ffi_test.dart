// Export of an arbitrary query result (result-table export UI backend).
//
// The SQL console / history result cards export through Api.exportQuery so they
// reuse the table page's exchange-format renderers (CSV / JSON / ...) instead of
// shipping rows as a String through the FFI bridge.

import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';

void main() {
  late Directory dir;
  late Directory out;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('rma-query-export-');
    out = await Directory.systemTemp.createTemp('rma-query-export-out-');
    await RustLib.init(
        externalLibrary:
            ExternalLibrary.open('rust/target/debug/librust_myadmin_core.dylib'));
    await Api.init(dir.path);
    await AppState.instance.bootstrap(dir.path);
    File('${dir.path}/demo.sqlite').createSync();
    final created = await Api.instance.createConnection(<String, dynamic>{
      'name': 'export',
      'driver': 'sqlite',
      'database': '${dir.path}/demo.sqlite',
    });
    final id = (created['connection'] as Map)['id'].toString();
    await AppState.instance.connect(id);
    await Api.instance.query(
        "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT); "
        "INSERT INTO t VALUES (1, 'Ada'), (2, 'Bob');",
        'main');
  });

  tearDownAll(() async {
    await AppState.instance.disconnect();
    await dir.delete(recursive: true);
    await out.delete(recursive: true);
  });

  test('exportQuery writes the selected format, not a Dart-side CSV', () async {
    final csvPath = '${out.path}/result.csv';
    final csv = await Api.instance.exportQuery(
        'main', 'SELECT id, name FROM t ORDER BY id',
        <String, dynamic>{'format': 'csv', 'path': csvPath});
    expect(csv['written'], isTrue);
    expect(csv['rows'], 2);
    final csvText = File(csvPath).readAsStringSync();
    expect(csvText, contains('id'));
    expect(csvText, contains('Ada'));
    expect(csvText, contains('Bob'));

    final jsonPath = '${out.path}/result.json';
    final json = await Api.instance.exportQuery(
        'main', 'SELECT id, name FROM t ORDER BY id',
        <String, dynamic>{'format': 'json', 'path': jsonPath});
    expect(json['rows'], 2);
    final jsonText = File(jsonPath).readAsStringSync();
    expect(jsonText, contains('"name"'));
    expect(jsonText, contains('Ada'));
  });
}
