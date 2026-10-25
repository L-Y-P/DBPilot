// Live MySQL regression for the table designer (round 56): column rename.
//
// The design tab used to leave rename_columns empty, so editing a column name
// produced no DDL at all (and _buildAlter put the MODIFY clause on the new
// name, which does not exist yet). The designer now emits
// {rename_columns:[{from,to}]} and keeps MODIFY on the old name because the
// MySQL/PostgreSQL dialect renders MODIFY before RENAME in one ALTER statement.
//
// This test exercises that exact payload against a real MySQL server:
//   1. rename only;
//   2. rename + modify in one request (driver emits RENAME first as its own
//      statement, then MODIFY on the new column name);
//
// Endpoint comes from DBPILOT_TEST_MYSQL_* (see test/live_db_env.dart); the test
// skips itself when no server is reachable.

import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';

import 'live_db_env.dart';

const String _database = 'dbpilot_round56_design_live';

Future<void> _connect(AppState state, LiveDbEndpoint endpoint) async {
  final created = await Api.instance.createConnection(<String, dynamic>{
    ...connectionPayload('mysql', endpoint, name: 'round56-design'),
    'charset': 'utf8mb4',
    'ssl_mode': 'disable',
  });
  final id = (created['connection'] as Map)['id'].toString();
  await state.connect(id);
}

/// Fresh database for every test: the rename scenarios must not share tables.
Future<void> _resetDatabase() async {
  try {
    await Api.instance.dropDatabase(_database);
  } catch (_) {
    // It may not exist yet.
  }
  await Api.instance.createDatabase(<String, dynamic>{'name': _database});
}

Future<void> _createTable(String name, List<Map<String, dynamic>> columns) =>
    Api.instance.createTable(_database, <String, dynamic>{
      'name': name,
      'columns': columns,
    });

Map<String, dynamic> _column(
  String name,
  String type, {
  bool primary = false,
  bool nullable = true,
}) => <String, dynamic>{
  'name': name,
  'type': type,
  'nullable': nullable,
  'primary': primary,
  'auto_increment': false,
};

Future<Map<String, String>> _columnTypes(String table) async {
  final structure = await Api.instance.structure(_database, table);
  final out = <String, String>{};
  for (final row in (structure['columns'] as List? ?? const <dynamic>[])) {
    final map = Map<String, dynamic>.from(row as Map);
    final name = (map['COLUMN_NAME'] ?? map['name'] ?? '').toString();
    final type = (map['COLUMN_TYPE'] ?? map['type_name'] ?? map['type'] ?? '')
        .toString()
        .toLowerCase();
    if (name.isNotEmpty) out[name] = type;
  }
  return out;
}

void main() {
  late Directory dir;
  late bool available;

  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run cargo build --lib in rust/ first: the dylib is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    dir = await Directory.systemTemp.createTemp('rma-round56-design-');
    await Api.init(dir.path);
    await AppState.instance.bootstrap(dir.path);
    try {
      await _connect(AppState.instance, mysqlEndpoint().withDatabase('mysql'));
      available = true;
    } catch (_) {
      available = false;
    }
  });

  setUp(() async {
    if (available) await _resetDatabase();
  });

  tearDownAll(() async {
    if (available) {
      try {
        await Api.instance.dropDatabase(_database);
      } catch (_) {
        // The test may have failed before creating it.
      }
      await AppState.instance.disconnect();
    }
    await dir.delete(recursive: true);
  });

  test('designer rename_columns renames a real MySQL column', () async {
    if (!available) {
      markTestSkipped('MySQL (DBPILOT_TEST_MYSQL_*) not reachable');
      return;
    }
    await _createTable('t_rename', <Map<String, dynamic>>[
      _column('id', 'BIGINT', primary: true, nullable: false),
      _column('old_name', 'VARCHAR(32)'),
    ]);

    await Api.instance.alterTableChecked(
      _database,
      't_rename',
      <String, dynamic>{
        // Designer payload for "rename only": no modify_columns.
        'rename_columns': <Map<String, dynamic>>[
          <String, dynamic>{'from': 'old_name', 'to': 'new_name'},
        ],
      },
    );
    final types = await _columnTypes('t_rename');
    expect(
      types.containsKey('new_name'),
      isTrue,
      reason: 'renamed column must exist: ${types.keys.join(',')}',
    );
    expect(types.containsKey('old_name'), isFalse);
    expect(types['new_name'], contains('varchar'));
  });

  test(
    'rename + modify in one ALTER applies modify to the old name first',
    () async {
      if (!available) {
        markTestSkipped('MySQL (DBPILOT_TEST_MYSQL_*) not reachable');
        return;
      }
      await _createTable('t_rename_modify', <Map<String, dynamic>>[
        _column('id', 'BIGINT', primary: true, nullable: false),
        _column('old_b', 'VARCHAR(32)'),
      ]);

      await Api.instance.alterTableChecked(
        _database,
        't_rename_modify',
        <String, dynamic>{
          // Designer payload for "rename + change type": the driver emits
          // RENAME COLUMN as its own statement first, so MODIFY uses the NEW
          // column name.
          'modify_columns': <Map<String, dynamic>>[
            _column('new_b', 'VARCHAR(64)'),
          ],
          'rename_columns': <Map<String, dynamic>>[
            <String, dynamic>{'from': 'old_b', 'to': 'new_b'},
          ],
        },
      );
      final types = await _columnTypes('t_rename_modify');
      expect(
        types.containsKey('new_b'),
        isTrue,
        reason: 'renamed column must exist: ${types.keys.join(',')}',
      );
      expect(types.containsKey('old_b'), isFalse);
      expect(
        types['new_b'],
        contains('varchar(64)'),
        reason: 'modify must apply before rename, got ${types['new_b'] ?? ''}',
      );
    },
  );
}
