// End-to-end verification of the **dialect-adapted** builder SQL: the SQL the
// builder produces for SQLite must actually execute (FULL OUTER JOIN is native
// since SQLite 3.39; the bundled engine is 3.46) and the DISTINCT / GROUP BY
// ORDER BY rewrite must be accepted.
//
// MySQL and PostgreSQL rendering is covered by the pure model tests
// (builder_model_test.dart); this file proves the generated statement is
// executable, not just textually correct.
// Paths and failure reasons are assembled from a temp directory; explicit
// concatenation keeps those one-liners readable in this FFI test.
// ignore_for_file: prefer_interpolation_to_compose_strings
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/builder/query_model.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';

String sqliteQuote(String name) => '"' + name.replaceAll('"', '""') + '"';

List<BuilderTable> demo() => <BuilderTable>[
      BuilderTable(
        name: 'people',
        columns: <BuilderColumn>[
          BuilderColumn(name: 'id', type: 'integer', key: 'PRI'),
          BuilderColumn(name: 'name', type: 'text'),
        ],
      ),
      BuilderTable(
        name: 'courses',
        columns: <BuilderColumn>[
          BuilderColumn(name: 'id', type: 'integer', key: 'PRI'),
          BuilderColumn(name: 'person_id', type: 'integer'),
          BuilderColumn(name: 'title', type: 'text'),
          BuilderColumn(name: 'score', type: 'numeric'),
        ],
        foreignKeys: <BuilderForeignKey>[
          BuilderForeignKey(
              column: 'person_id', refTable: 'people', refColumn: 'id'),
        ],
      ),
    ];

BuilderSql build(BuilderQuery query) => buildBuilderSql(
      query,
      demo(),
      quote: sqliteQuote,
      dialect: BuilderDialect.sqlite,
    );

void main() {
  late Directory dir;

  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run cargo build --lib in rust/ first: ' + dylib.path + ' is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    dir = await Directory.systemTemp.createTemp('rma-builder-dialect-');
    final init = await Api.init(dir.path);
    expect(init['ok'], isTrue, reason: 'init_app failed: ' + init.toString());
    await AppState.instance.bootstrap(dir.path);
    File(dir.path + '/dialect.sqlite').createSync(recursive: true);
    final created = await Api.instance.createConnection(<String, dynamic>{
      'name': 'dialect',
      'driver': 'sqlite',
      'database': dir.path + '/dialect.sqlite',
    });
    final id = (created['connection'] as Map)['id'].toString();
    await AppState.instance.connect(id);
    await Api.instance.query(
      'CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT);'
      "INSERT INTO people VALUES (1, 'Ada'), (2, 'Bob'), (3, 'Cy');"
      'CREATE TABLE courses (id INTEGER PRIMARY KEY, person_id INTEGER, '
      'title TEXT, score NUMERIC);'
      "INSERT INTO courses VALUES (1, 1, 'DB', 92.5), (2, 1, 'Rust', 88);",
    );
    await AppState.instance.refreshDatabases();
  });

  tearDownAll(() async {
    await AppState.instance.disconnect();
    await dir.delete(recursive: true);
  });

  Future<List<Map<String, dynamic>>> run(BuilderSql sql) async {
    final response = await Api.instance.query(sql.executable);
    final results = response['results'] as List;
    final first = Map<String, dynamic>.from(results.first as Map);
    final error = (first['error'] ?? '').toString();
    expect(error, isEmpty, reason: 'SQL failed: ' + error + '\n' + sql.executable);
    final rows = (first['rows'] as List?) ?? <Object?>[];
    final columns = (first['columns'] as List?) ?? <Object?>[];
    final names = <String>[
      for (final column in columns)
        ((column as Map)['name'] ?? '').toString(),
    ];
    return <Map<String, dynamic>>[
      for (final row in rows)
        <String, dynamic>{
          for (var i = 0; i < names.length; i++)
            names[i]: i < (row as List).length ? row[i] : null,
        },
    ];
  }

  test('native FULL OUTER JOIN executes on SQLite', () async {
    final query = BuilderQuery()..primaryTable = 'people';
    query.joins.add(JoinSpec(
      type: 'FULL OUTER',
      leftTable: 'people',
      rightTable: 'courses',
      leftColumn: 'id',
      rightColumn: 'person_id',
    ));
    query.outputs.add(OutputField(table: 'people', column: 'id'));
    query.outputs.add(OutputField(table: 'courses', column: 'id'));
    final sql = build(query);
    expect(sql.preview, contains('FULL OUTER JOIN'));
    // 3 people (one without courses) + 2 courses (both under Ada) = 4 rows.
    final rows = await run(sql);
    expect(rows, hasLength(4));
  });

  test('DISTINCT + ORDER BY is rewritten to a selectable expression', () async {
    final query = BuilderQuery()
      ..primaryTable = 'courses'
      ..distinct = true;
    query.outputs.add(OutputField(table: 'courses', column: 'person_id'));
    query.orders.add(OrderSpec(table: 'courses', column: 'score', dir: 'DESC'));
    final sql = build(query);
    // Sorting by a column that is not selected is rejected by MySQL (with
    // DISTINCT) and PostgreSQL; the builder remaps/drops it instead.
    expect(sql.preview, isNot(contains('ORDER BY "courses"."score"')));
    final rows = await run(sql);
    expect(rows, hasLength(1));
    expect(rows.single['person_id'], 1);
  });

  test('aggregate + ORDER BY groups the documented columns', () async {
    final query = BuilderQuery()..primaryTable = 'courses';
    query.outputs.add(OutputField(
        table: 'courses', column: 'person_id', aggregate: 'COUNT', alias: 'n'));
    query.outputs.add(OutputField(table: 'courses', column: 'person_id'));
    query.orders.add(OrderSpec(table: 'courses', column: 'score', dir: 'DESC'));
    final sql = build(query);
    expect(sql.preview, contains('GROUP BY "courses"."person_id"'));
    expect(sql.preview, isNot(contains('ORDER BY "courses"."score"')));
    final rows = await run(sql);
    expect(rows, hasLength(1));
  });
}
