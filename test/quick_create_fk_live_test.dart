// Live MySQL regression for round 52 (round 51 report P0-1 / P1-1 / P1-2 / P2-7).
//
// The round-51 test report reproduced "建立建议外键 clicked, nothing happened":
// the wizard created BIGINT id primary keys while the source *_id columns were
// inferred as INT, so MySQL rejected the ALTER with ERROR 3780 — and the Rust
// explorer API returns failed ALTERs inside the payload, so the UI treated them
// as success. This test drives the real wizard plan helpers against a real
// MySQL server and verifies the whole chain:
//
//   1. inferred text columns get a VARCHAR(255) margin (P1-1);
//   2. a source id primary key is NOT auto-increment; business keys (学号) are
//      picked as primary candidates but never auto-increment (P1-2/P1-3);
//   3. every *_id column is aligned to BIGINT before CREATE TABLE (P0-1);
//   4. suggested FKs apply for real, remaining suggestions survive a partial
//      apply (P2-7), the junction table is detected and orders↔products becomes
//      many-to-many;
//   5. a deliberately INT→BIGINT mismatch is blocked locally and the raw API
//      failure (failed inside the payload) is detected by alterTableChecked.
//
// Endpoint comes from DBPILOT_TEST_MYSQL_* (see test/live_db_env.dart); the test
// skips itself when no MySQL server is reachable, so a clean machine stays green.

import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/import_rules.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/views/er_model.dart';
// uniqueName is exported by both libraries with identical semantics; keep the
// wizard's plan helpers without the name clash.
import 'package:rust_myadmin_desktop/src/views/quick_create_table_wizard.dart'
    hide uniqueName;
import 'package:rust_myadmin_desktop/src/views/relation_designer.dart'
    show erFkIssueMessage;

import 'live_db_env.dart';

const String _database = 'dbpilot_round52_live';
const String _relational = 'rust/tests/fixtures/relational_multi.xlsx';
const String _chinese = 'rust/tests/fixtures/chinese_grade.xlsx';

Future<void> _connect(AppState state, LiveDbEndpoint endpoint) async {
  final created = await Api.instance.createConnection(<String, dynamic>{
    ...connectionPayload('mysql', endpoint, name: 'round52-live'),
    'charset': 'utf8mb4',
    'ssl_mode': 'disable',
  });
  final id = (created['connection'] as Map)['id'].toString();
  await state.connect(id);
}

/// Rebuild the wizard plan for every visible sheet, exactly like step 2 does:
/// per-sheet header self-healing (P1-7) + preview schema (P1-1/P1-3) + FK column
/// alignment (P0-1).
Future<List<QuickTablePlan>> _plansFor(String path) async {
  final inspect = await Api.instance.importInspect(path);
  final sheets = (inspect['sheets'] as List? ?? const <dynamic>[])
      .map(asJsonMap)
      .where((sheet) => (sheet['name'] ?? '').toString().isNotEmpty)
      .toList();
  expect(sheets, isNotEmpty, reason: 'no worksheets in $path');

  Future<Json> preview(String sheet, bool header) =>
      Api.instance.importPreview(path, <String, dynamic>{
        'read': readParamsFor(asJsonMap(inspect['read']), sheet: sheet),
        'fields': fieldParamsFor(asJsonMap(inspect['fields']), header: header),
        'limit': 200,
        'infer': true,
      });

  final plans = <QuickTablePlan>[];
  final used = <String>{};
  for (final sheet in sheets) {
    final sheetName = (sheet['name'] ?? '').toString();
    var header = asJsonMap(inspect['fields'])['header'] == true;
    var result = await preview(sheetName, header);
    final suggested = suggestHeaderForPreview(result, header);
    if (suggested != header) {
      header = suggested;
      result = await preview(sheetName, header);
    }
    final name = uniqueName(
      defaultTableNameFor(path, sheet: sheetName, multiSheet: true),
      used,
    );
    used.add(name);
    plans.add(
      QuickTablePlan(
        name: name,
        sheet: sheetName,
        header: header,
        columns: columnsFromPreview(result, driver: 'mysql'),
      ),
    );
  }
  return plans;
}

QuickColumn _column(QuickTablePlan plan, String name) =>
    plan.columns.firstWhere(
      (column) => column.name == name,
      orElse: () => throw StateError(
        'column $name missing in '
        '${plan.name}: ${plan.columns.map((c) => c.name).toList()}',
      ),
    );

Map<String, dynamic> _columnBody(QuickTablePlan plan, String name) =>
    (createTableBodyFor(plan, 'mysql')['columns'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((column) => column['name'] == name);

Future<Map<String, List<ErRelation>>> _relationsByTable(
  List<QuickTablePlan> plans,
) async {
  final out = <String, List<ErRelation>>{};
  for (final plan in plans) {
    final structure = await Api.instance.structure(_database, plan.name);
    out[plan.name] = ErRelation.fromStructure(plan.name, structure);
  }
  return out;
}

Future<void> _createSchema(List<QuickTablePlan> plans) async {
  try {
    await Api.instance.dropDatabase(_database);
  } catch (_) {
    // The database may not exist yet.
  }
  await Api.instance.createDatabase(<String, dynamic>{'name': _database});
  for (final plan in plans) {
    await Api.instance.createTable(
      _database,
      createTableBodyFor(plan, 'mysql'),
    );
  }
}

Future<int> _foreignKeyCount() async {
  final result = await Api.instance.query(
    "SELECT COUNT(*) AS n FROM information_schema.table_constraints "
        "WHERE constraint_schema = '$_database' AND constraint_type = 'FOREIGN KEY'",
    'information_schema',
  );
  final results = (result['results'] as List? ?? const <dynamic>[]);
  if (results.isEmpty) return 0;
  final rows = ((results.first as Map)['rows'] as List? ?? const <dynamic>[]);
  if (rows.isEmpty) return 0;
  return (rows.first as List).first as int;
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
    dir = await Directory.systemTemp.createTemp('rma-round52-');
    await Api.init(dir.path);
    await AppState.instance.bootstrap(dir.path);
    try {
      await _connect(AppState.instance, mysqlEndpoint().withDatabase('mysql'));
      available = true;
    } catch (_) {
      available = false;
    }
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

  test('inferred columns are FK-compatible and business keys are not auto-increment', () async {
    if (!available) {
      markTestSkipped('MySQL (DBPILOT_TEST_MYSQL_*) not reachable');
      return;
    }

    final plans = await _plansFor(_relational);
    expect(plans.length, 5, reason: 'relational_multi.xlsx has 5 sheets');
    for (final plan in plans) {
      // P0-1: every *_id business column must match the BIGINT id primary key.
      for (final column in plan.columns) {
        if (RegExp(r'_id$').hasMatch(column.name)) {
          expect(
            column.sqlType,
            'BIGINT',
            reason: '${plan.name}.${column.name} must be BIGINT for the FK',
          );
        }
      }
      // P1-1: text columns get a 255-character margin (not the sample max).
      for (final column in plan.columns) {
        if (column.inferred == 'text') {
          expect(
            column.sqlType,
            'VARCHAR(255)',
            reason: '${plan.name}.${column.name} must keep a length margin',
          );
        }
      }
    }

    final users = plans.firstWhere((plan) => plan.name == 'users');
    final id = _column(users, 'id');
    // P1-2: an id column that comes from the source file is not auto-increment.
    expect(id.primary, isTrue);
    expect(id.autoIncrement, isFalse);
    expect(_columnBody(users, 'id')['auto_increment'], isFalse);
    expect(_columnBody(users, 'name')['type'], 'VARCHAR(255)');

    // A generated "添加自增 id 主键" column is the only auto-increment case.
    final orderItems = plans.firstWhere((plan) => plan.name == 'order_items');
    final generatedPlan = QuickTablePlan(
      name: 'generated_demo',
      sheet: 'demo',
      header: true,
      columns: <QuickColumn>[
        for (final column in orderItems.columns)
          QuickColumn(
            name: column.name,
            sourceLabel: column.sourceLabel,
            sourceIndex: column.sourceIndex,
            inferred: column.inferred,
            sqlType: column.sqlType,
            nullable: column.nullable,
          ),
      ],
    );
    final generated = addGeneratedPrimaryKey(generatedPlan, 'mysql');
    expect(generated.autoIncrement, isTrue);
    // order_items already has an id column, so the generated key is id_2.
    expect(
      _columnBody(generatedPlan, generated.name)['auto_increment'],
      isTrue,
    );
    for (final column in generatedPlan.columns) {
      if (RegExp(r'_id$').hasMatch(column.name)) {
        expect(column.sqlType, 'BIGINT');
      }
    }

    // Chinese sheets: 学号 becomes the primary candidate (unique_integer) and is
    // a business key, so it must NOT auto-increment (P1-2/P1-3).
    final chinesePlans = await _plansFor(_chinese);
    final students = chinesePlans.firstWhere((plan) => plan.name == '学生名单');
    final studentId = _column(students, '学号');
    expect(studentId.primary, isTrue);
    expect(studentId.primaryReason, 'unique_integer');
    expect(studentId.autoIncrement, isFalse);
    expect(_columnBody(students, '学号')['type'], 'BIGINT');
    expect(_columnBody(students, '学号')['auto_increment'], isFalse);
  });

  test('suggested foreign keys apply on MySQL and detect the many-to-many link', () async {
    if (!available) {
      markTestSkipped('MySQL (DBPILOT_TEST_MYSQL_*) not reachable');
      return;
    }
    final plans = await _plansFor(_relational);
    await _createSchema(plans);

    // Build the canvas the designer would show: all 5 tables, no FKs yet.
    final tables = <ErTable>[];
    for (final plan in plans) {
      final structure = await Api.instance.structure(_database, plan.name);
      tables.add(ErTable.fromStructure(plan.name, structure));
    }
    final names = tables.map((table) => table.name).toSet();
    var relations = await _relationsByTable(plans);
    final suggestions = suggestRelations(
      tables: tables,
      relationsByTable: relations,
    );
    expect(
      suggestions.length,
      4,
      reason:
          'expected products.category_id, orders.user_id, '
          'order_items.order_id and order_items.product_id',
    );

    Future<void> apply(ErRelation suggestion) async {
      final existingNames = <String>{
        for (final relation
            in relations[suggestion.localTable] ?? const <ErRelation>[])
          if (relation.name.isNotEmpty) relation.name,
      };
      await Api.instance.alterTableChecked(
        _database,
        suggestion.localTable,
        <String, dynamic>{
          'add_foreign_keys': <Map<String, dynamic>>[
            foreignKeyPayload(
              name: uniqueFkName(
                suggestion.localTable,
                suggestion.localColumn,
                existingNames,
              ),
              localColumn: suggestion.localColumn,
              refTable: suggestion.refTable,
              refColumn: suggestion.refColumn,
            ),
          ],
        },
      );
      relations = await _relationsByTable(plans);
    }

    // P0-1: the first suggested FK used to be rejected silently by ERROR 3780.
    await apply(suggestions.first);
    expect(await _foreignKeyCount(), 1);

    // P2-7: applying one suggestion must keep the remaining ones.
    final remaining = suggestRelations(
      tables: tables,
      relationsByTable: relations,
    );
    expect(
      remaining.length,
      3,
      reason: 'remaining suggestions after a partial apply',
    );
    for (final suggestion in remaining) {
      await apply(suggestion);
    }
    expect(await _foreignKeyCount(), 4);

    // The junction table is recognised and orders↔products is many-to-many.
    final junctions = detectJunctionTables(
      relationsByTable: relations,
      tables: names,
    );
    expect(junctions.keys, contains('order_items'));
    final links = manyToManyLinks(junctions);
    expect(
      links.any(
        (link) =>
            link.junctionTable == 'order_items' &&
            ((link.tableA == 'orders' && link.tableB == 'products') ||
                (link.tableA == 'products' && link.tableB == 'orders')),
      ),
      isTrue,
    );
  });

  test('INT→BIGINT mismatch is blocked locally and raw API failures are detected', () async {
    if (!available) {
      markTestSkipped('MySQL (DBPILOT_TEST_MYSQL_*) not reachable');
      return;
    }
    final plans = await _plansFor(_relational);
    await _createSchema(plans);
    await Api.instance.createTable(_database, <String, dynamic>{
      'name': 'bad_link',
      'columns': <Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'id',
          'type': 'BIGINT',
          'nullable': false,
          'primary': true,
          'auto_increment': false,
        },
        <String, dynamic>{
          'name': 'order_id',
          'type': 'INT',
          'nullable': true,
          'primary': false,
          'auto_increment': false,
        },
      ],
    });
    final structure = await Api.instance.structure(_database, 'bad_link');
    final bad = ErTable.fromStructure('bad_link', structure);
    final ordersStructure = await Api.instance.structure(_database, 'orders');
    final orders = ErTable.fromStructure('orders', ordersStructure);
    final issue = validateForeignKeyCandidate(
      localTable: bad,
      localColumn: 'order_id',
      refTable: orders,
      refColumn: 'id',
    );
    expect(issue, isNotNull);
    expect(issue!.kind, ErFkIssueKind.typeIncompatible);
    expect(erFkIssueMessage(issue), contains('整数位宽'));

    // Even if the UI skipped its own check, the raw API must expose the failure
    // inside the payload (failed: 1) and alterTableChecked must throw on it.
    final body = <String, dynamic>{
      'add_foreign_keys': <Map<String, dynamic>>[
        foreignKeyPayload(
          name: 'fk_bad_link_order_id',
          localColumn: 'order_id',
          refTable: 'orders',
          refColumn: 'id',
        ),
      ],
    };
    final raw = await Api.instance.alterTable(_database, 'bad_link', body);
    expect(raw['failed'], isNot(0));
    expect(alterTableErrors(raw), isNotEmpty);

    Object? thrown;
    try {
      await Api.instance.alterTableChecked(_database, 'bad_link', body);
    } catch (error) {
      thrown = error;
    }
    expect(
      thrown,
      isNotNull,
      reason: 'alterTableChecked must not swallow the failure',
    );
    final message = thrown.toString().toLowerCase();
    expect(message, anyOf(contains('3780'), contains('incompatible')));
  });
}
