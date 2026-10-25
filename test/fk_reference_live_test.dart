// Live MySQL regression for round 62: FK referenced columns must be UNIQUE.
//
// The user asked why creating a foreign key on clerk_cn_test failed in DBPilot
// while "phpMyAdmin web could do it". The product's local pre-check requires the
// referenced column to be a primary key or a single-column unique key, and
// MySQL 8.4 enforces exactly that server-side: ALTER TABLE ... ADD FOREIGN KEY
// fails with ERROR 6125 "Missing unique key ... in the referenced table" unless
// the parent column has a UNIQUE key. A plain (non-unique) KEY is no longer
// enough in 8.4. So the product is not stricter than MySQL: 学生名单.学号
// (30/30 unique) needs a UNIQUE index before the FK can be created.
//
// This test proves the rule against a real server:
//   1. parent(code) without an index -> 6125;
//   2. parent(code) + UNIQUE KEY -> FK created, orphan child row rejected (1452);
//   3. parent2(code) + plain KEY -> still 6125 (a non-unique index is insufficient).
//
// Endpoint comes from DBPILOT_TEST_MYSQL_* (see test/live_db_env.dart); the test
// skips itself when no MySQL server is reachable, so a clean machine stays green.

import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/views/er_model.dart'
    show foreignKeyPayload;

import 'live_db_env.dart';

const String _database = 'dbpilot_round62_fk_ref';

Future<void> _connect(AppState state, LiveDbEndpoint endpoint) async {
  final created = await Api.instance.createConnection(<String, dynamic>{
    ...connectionPayload('mysql', endpoint, name: 'round62-fk-ref'),
    'charset': 'utf8mb4',
    'ssl_mode': 'disable',
  });
  final id = (created['connection'] as Map)['id'].toString();
  await state.connect(id);
}

/// 与产品完全相同的 add_foreign_keys payload（foreignKeyPayload）。
Map<String, dynamic> _fkBody({
  required String name,
  required String localColumn,
  required String refTable,
  required String refColumn,
}) => <String, dynamic>{
  'add_foreign_keys': <Map<String, dynamic>>[
    foreignKeyPayload(
      name: name,
      localColumn: localColumn,
      refTable: refTable,
      refColumn: refColumn,
    ),
  ],
};

/// 执行查询并取出第一个结果集的 rows（与 quick_create_fk_live_test 一致）。
Future<List<List<Object?>>> _rows(String sql, {String? database}) async {
  final payload = await Api.instance.query(sql, database);
  final results = payload['results'] as List? ?? const <dynamic>[];
  if (results.isEmpty) return const <List<Object?>>[];
  final rows = (results.first as Map)['rows'] as List? ?? const <dynamic>[];
  return <List<Object?>>[
    for (final row in rows)
      if (row is List) row.cast<Object?>(),
  ];
}

/// 在当前临时库里执行一条 DDL / DML。
Future<void> _sql(String sql) async {
  await Api.instance.query(sql, _database);
}

/// 重建临时库，保证每个用例从干净状态开始。
Future<void> _recreateDatabase() async {
  try {
    await Api.instance.dropDatabase(_database);
  } catch (_) {
    // The database may not exist yet.
  }
  await Api.instance.createDatabase(<String, dynamic>{'name': _database});
}

/// 执行预期失败的 SQL，返回错误文本：可能是抛出的 ApiException，也可能是
/// payload 里的逐语句 error（Rust 把部分失败折叠进返回体）。
Future<String> _failureText(String sql) async {
  try {
    final payload = await Api.instance.query(sql, _database);
    final errors = <String>[
      if (payload['error'] != null) payload['error'].toString(),
      for (final result in (payload['results'] as List? ?? const <dynamic>[]))
        if (result is Map && result['error'] != null)
          result['error'].toString(),
    ].where((text) => text.isNotEmpty).toList();
    if (errors.isNotEmpty) return errors.join('\n');
  } catch (error) {
    return error.toString();
  }
  fail('SQL unexpectedly succeeded: $sql');
}

/// 某张表上真实存在的外键（约束名 / 被引用表 / 被引用列）。
Future<List<List<Object?>>> _foreignKeysOf(String table) => _rows(
  "SELECT CONSTRAINT_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME "
  "FROM information_schema.KEY_COLUMN_USAGE "
  "WHERE TABLE_SCHEMA = '$_database' AND TABLE_NAME = '$table' "
  "AND REFERENCED_TABLE_NAME IS NOT NULL",
  database: 'information_schema',
);

Matcher _uniqueKeyError() =>
    anyOf(contains('6125'), contains('missing unique key'));

void main() {
  late Directory dir;
  late bool available;

  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run cargo build --lib in rust/ first: the dylib is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    dir = await Directory.systemTemp.createTemp('rma-round62-fk-ref-');
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

  test(
    'MySQL 8.4: FK to a referenced column without an index fails with 6125',
    () async {
      if (!available) {
        markTestSkipped('MySQL (DBPILOT_TEST_MYSQL_*) not reachable');
        return;
      }
      await _recreateDatabase();
      await _sql(
        'CREATE TABLE parent (id INT PRIMARY KEY, code INT NOT NULL) ENGINE=InnoDB',
      );
      await _sql(
        'CREATE TABLE child (id INT PRIMARY KEY, pcode INT) ENGINE=InnoDB',
      );

      final body = _fkBody(
        name: 'fk_child_parent_code',
        localColumn: 'pcode',
        refTable: 'parent',
        refColumn: 'code',
      );
      final raw = await Api.instance.alterTable(_database, 'child', body);
      expect(
        raw['failed'],
        isNot(0),
        reason:
            'MySQL 8.4 must reject a referenced column without a unique key',
      );
      final errors = alterTableErrors(raw);
      expect(errors, isNotEmpty);
      expect(errors.join('\n').toLowerCase(), _uniqueKeyError());
      expect(
        await _foreignKeysOf('child'),
        isEmpty,
        reason: 'the rejected FK must not exist',
      );

      // 产品路径走 alterTableChecked：必须抛错，不能把失败当成功。
      Object? thrown;
      try {
        await Api.instance.alterTableChecked(_database, 'child', body);
      } catch (error) {
        thrown = error;
      }
      expect(
        thrown,
        isNotNull,
        reason: 'alterTableChecked must surface the 6125 failure',
      );
    },
  );

  test(
    'MySQL 8.4: UNIQUE KEY on the referenced column makes the FK work',
    () async {
      if (!available) {
        markTestSkipped('MySQL (DBPILOT_TEST_MYSQL_*) not reachable');
        return;
      }
      await _recreateDatabase();
      await _sql(
        'CREATE TABLE parent (id INT PRIMARY KEY, code INT NOT NULL) ENGINE=InnoDB',
      );
      await _sql(
        'CREATE TABLE child (id INT PRIMARY KEY, pcode INT) ENGINE=InnoDB',
      );
      final body = _fkBody(
        name: 'fk_child_parent_code',
        localColumn: 'pcode',
        refTable: 'parent',
        refColumn: 'code',
      );
      // 不依赖用例执行顺序：先确认没有唯一键时确实失败。
      final rejected = await Api.instance.alterTable(_database, 'child', body);
      expect(rejected['failed'], isNot(0));

      // 用户需要的那一步：先给被引用列建 UNIQUE（学生名单.学号 30/30 唯一）。
      await _sql('ALTER TABLE parent ADD UNIQUE KEY uq_parent_code (code)');
      await Api.instance.alterTableChecked(_database, 'child', body);

      final foreignKeys = await _foreignKeysOf('child');
      expect(foreignKeys, hasLength(1));
      expect(foreignKeys.single[0], 'fk_child_parent_code');
      expect(foreignKeys.single[1], 'parent');
      expect(foreignKeys.single[2], 'code');

      // 外键真实生效：父行存在时子行可以插入，孤儿父值被拒绝（1452）。
      await _sql('INSERT INTO parent (id, code) VALUES (1, 10)');
      await _sql('INSERT INTO child (id, pcode) VALUES (1, 10)');
      final orphan = await _failureText(
        'INSERT INTO child (id, pcode) VALUES (2, 999)',
      );
      expect(
        orphan.toLowerCase(),
        anyOf(contains('1452'), contains('foreign key constraint')),
      );
    },
  );

  test(
    'MySQL 8.4: a plain non-unique KEY is still not enough (6125)',
    () async {
      if (!available) {
        markTestSkipped('MySQL (DBPILOT_TEST_MYSQL_*) not reachable');
        return;
      }
      await _recreateDatabase();
      await _sql(
        'CREATE TABLE parent2 '
        '(id INT PRIMARY KEY, code INT NOT NULL, KEY idx_parent2_code (code)) '
        'ENGINE=InnoDB',
      );
      await _sql(
        'CREATE TABLE child2 (id INT PRIMARY KEY, pcode INT) ENGINE=InnoDB',
      );

      // 普通非唯一索引确实存在（NON_UNIQUE=1），但 MySQL 8.4 仍要求唯一键。
      final indexes = await _rows(
        "SELECT INDEX_NAME, NON_UNIQUE FROM information_schema.STATISTICS "
        "WHERE TABLE_SCHEMA = '$_database' AND TABLE_NAME = 'parent2' "
        "AND COLUMN_NAME = 'code'",
        database: 'information_schema',
      );
      expect(indexes, isNotEmpty);
      expect(
        indexes.any((row) => row.length > 1 && '${row[1]}' == '1'),
        isTrue,
        reason: 'parent2.code must have a plain non-unique index',
      );

      final body = _fkBody(
        name: 'fk_child2_parent2_code',
        localColumn: 'pcode',
        refTable: 'parent2',
        refColumn: 'code',
      );
      final raw = await Api.instance.alterTable(_database, 'child2', body);
      expect(
        raw['failed'],
        isNot(0),
        reason: 'a non-unique index must not satisfy the 8.4 requirement',
      );
      expect(alterTableErrors(raw).join('\n').toLowerCase(), _uniqueKeyError());
      expect(await _foreignKeysOf('child2'), isEmpty);
    },
  );
}
