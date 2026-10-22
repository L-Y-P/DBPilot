// Round 20: the MySQL visibility rule (a database the account cannot open must
// not be offered) has to hold for PostgreSQL schemas as well.
//
// PostgreSQL's `information_schema.schemata` is not a permission check: it
// lists a schema as soon as the role holds *any* privilege on it, including
// `CREATE` without `USAGE`, and it also exposes `pg_temp_N`. Such a schema was
// offered in the tree / pickers and every click failed with "permission denied
// for schema". The driver now filters on `has_schema_privilege(oid,'USAGE')`.
//
// 这是 live 测试：需要本地 PostgreSQL fixture（受限角色与 schema `app`）。
// 端点与账号来自环境变量（DBPILOT_TEST_PG_* / DBPILOT_TEST_PG_LIMITED_*，见
// test/live_db_env.dart），仓库里不留任何账号密码字面量；fixture 缺失时自动 SKIP。

import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';

import 'live_db_env.dart';

Future<void> connectAs(LiveDbEndpoint endpoint, {String name = 'pg-visibility'}) async {
  final created = await Api.instance.createConnection(<String, dynamic>{
    ...connectionPayload('postgres', endpoint, name: name),
    'ssl_mode': 'disable',
  });
  final id = (created['connection'] as Map)['id'].toString();
  await AppState.instance.connect(id);
}

void main() {
  late Directory dir;
  late bool limitedAvailable;
  late bool superuserAvailable;

  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run cargo build --lib in rust/ first: the dylib is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    dir = await Directory.systemTemp.createTemp('rma-pg-visibility-');
    await Api.init(dir.path);
    await AppState.instance.bootstrap(dir.path);
    try {
      await connectAs(pgLimitedEndpoint(), name: 'probe-lim');
      limitedAvailable = true;
    } catch (_) {
      limitedAvailable = false;
    }
    try {
      await AppState.instance.disconnect();
    } catch (_) {}
    try {
      await connectAs(pgEndpoint(), name: 'probe-super');
      superuserAvailable = true;
    } catch (_) {
      superuserAvailable = false;
    }
    try {
      await AppState.instance.disconnect();
    } catch (_) {}
  });

  tearDownAll(() async {
    try {
      await AppState.instance.disconnect();
    } catch (_) {}
    await dir.delete(recursive: true);
  });

  test('a role only sees schemas it may actually USE', () async {
    if (!limitedAvailable) {
      markTestSkipped('PostgreSQL limited role (DBPILOT_TEST_PG_LIMITED_*) not reachable');
      return;
    }
    await connectAs(pgLimitedEndpoint(), name: 'limited');
    final schemas = AppState.instance.databases
        .map((row) => (row['name'] ?? '').toString())
        .toList();
    // The fixture grants USAGE on app (and PUBLIC has USAGE on public).
    expect(schemas, contains('app'));
    // No temporary schemas: their objects are session-scoped and cannot be
    // browsed from another connection.
    expect(schemas.any((name) => name.startsWith('pg_temp_')), isFalse);
    expect(schemas.any((name) => name.startsWith('pg_toast_temp_')), isFalse);
  });

  test('a schema granted only CREATE (no USAGE) stays hidden', () async {
    if (!limitedAvailable || !superuserAvailable) {
      markTestSkipped('PostgreSQL fixture not reachable');
      return;
    }
    // information_schema.schemata lists this schema because the role holds a
    // privilege on it, but every query inside it fails. Build the exact case
    // the filter exists for, then remove it again.
    await connectAs(pgEndpoint(), name: 'fixture');
    for (final sql in [
      'DROP SCHEMA IF EXISTS rma_create_only CASCADE',
      'CREATE SCHEMA rma_create_only',
      'GRANT CREATE ON SCHEMA rma_create_only TO rma_limited',
    ]) {
      await Api.instance.query(sql);
    }
    try {
      await AppState.instance.disconnect();
      await connectAs(pgLimitedEndpoint(), name: 'limited2');
      final schemas = AppState.instance.databases
          .map((row) => (row['name'] ?? '').toString())
          .toList();
      expect(schemas, isNot(contains('rma_create_only')),
          reason: 'CREATE without USAGE does not make a schema browsable');
      expect(schemas, contains('app'));
    } finally {
      await AppState.instance.disconnect();
      await connectAs(pgEndpoint(), name: 'cleanup');
      await Api.instance.query('DROP SCHEMA IF EXISTS rma_create_only CASCADE');
    }
  });

  test('a database without CONNECT is not offered', () async {
    if (!limitedAvailable || !superuserAvailable) {
      markTestSkipped('PostgreSQL fixture not reachable');
      return;
    }
    // pg_database lists every database, including ones the role cannot open.
    // Filtering on has_database_privilege(CONNECT) is what keeps the tree and
    // every picker from offering a database whose every click fails with
    // "permission denied for database".
    await connectAs(pgEndpoint(), name: 'mk-db');
    for (final sql in [
      'DROP DATABASE IF EXISTS rma_noconnect',
      'CREATE DATABASE rma_noconnect',
      'REVOKE CONNECT ON DATABASE rma_noconnect FROM PUBLIC',
    ]) {
      await Api.instance.query(sql);
    }
    await AppState.instance.refreshInstanceDatabases();
    final asSuperuser = AppState.instance.instanceDatabases
        .map((row) => (row['name'] ?? '').toString())
        .toList();
    expect(asSuperuser, contains('rma_noconnect'),
        reason: 'a superuser may connect, so it must still be listed');
    try {
      await AppState.instance.disconnect();
      await connectAs(pgLimitedEndpoint(), name: 'no-connect');
      final asLimited = AppState.instance.instanceDatabases
          .map((row) => (row['name'] ?? '').toString())
          .toList();
      expect(asLimited, isNot(contains('rma_noconnect')));
    } finally {
      await AppState.instance.disconnect();
      await connectAs(pgEndpoint(database: 'postgres'), name: 'drop-db');
      await Api.instance.query('DROP DATABASE IF EXISTS rma_noconnect');
    }
  });

  test('a superuser still sees every browsable schema', () async {
    if (!superuserAvailable) {
      markTestSkipped('PostgreSQL superuser fixture not reachable');
      return;
    }
    await connectAs(pgEndpoint(), name: 'super');
    final schemas = AppState.instance.databases
        .map((row) => (row['name'] ?? '').toString())
        .toList();
    expect(schemas, contains('app'));
    expect(schemas, contains('public'));
    expect(schemas.any((name) => name.startsWith('pg_temp_')), isFalse);
  });
}
