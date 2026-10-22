// Regression tests for round 19: MySQL databases the account cannot open must
// not be offered in the tree.
//
// Reported symptom: a `web` account holding only
//   GRANT USAGE ON *.* TO `web`@`%`
//   GRANT ALL PRIVILEGES ON `web`.* TO `web`@`%`
// still saw `performance_schema` in the sidebar, and clicking it produced the
// "MySQL 连接失败：当前数据库账号没有访问该数据库的权限" banner.
//
// Root cause: the database list came from `information_schema.SCHEMATA`, which
// lists `performance_schema` for every account (SHOW DATABASES does too).
// It is now narrowed to the schemas `SHOW GRANTS` actually names, with a
// global schema privilege (*.*) meaning "everything".
//
// The tests need a real MySQL server and a low-privilege account plus a
// privileged one. Endpoint, accounts and passwords all come from the environment
// (DBPILOT_TEST_MYSQL_* / DBPILOT_TEST_MYSQL_LIMITED_*, see
// test/live_db_env.dart), so no credential is stored in this repository; the
// tests skip themselves when the account is missing so a clean machine passes.

import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';

import 'live_db_env.dart';

Future<void> connectAs(AppState state, LiveDbEndpoint endpoint,
    {String name = 'visibility'}) async {
  final created = await Api.instance.createConnection(<String, dynamic>{
    ...connectionPayload('mysql', endpoint, name: name),
    'charset': 'utf8mb4',
    'ssl_mode': 'disable',
  });
  final id = (created['connection'] as Map)['id'].toString();
  await state.connect(id);
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
    dir = await Directory.systemTemp.createTemp('rma-visibility-');
    await Api.init(dir.path);
    await AppState.instance.bootstrap(dir.path);
    // Probe the account this regression is about. A machine without the local
    // fixture database skips instead of failing.
    try {
      await connectAs(AppState.instance, mysqlLimitedEndpoint());
      available = true;
      await AppState.instance.disconnect();
    } catch (_) {
      available = false;
    }
  });

  tearDownAll(() async {
    await AppState.instance.disconnect();
    await dir.delete(recursive: true);
  });

  test('a limited account only sees the databases it holds a grant on',
      () async {
    if (!available) {
      markTestSkipped('restricted MySQL account (DBPILOT_TEST_MYSQL_LIMITED_*) not reachable');
      return;
    }
    final state = AppState.instance;
    final limited = mysqlLimitedEndpoint();
    await connectAs(state, limited);
    final names = state.instanceDatabases
        .map((database) => (database['name'] ?? '').toString())
        .toList();
    expect(names, contains(limited.database));
    expect(names, contains('information_schema'),
        reason: 'information_schema is readable metadata and must stay');
    expect(names, isNot(contains('performance_schema')),
        reason: 'the web account has no grant on performance_schema');
    expect(names, isNot(contains('mysql')));
    expect(names, isNot(contains('sys')));
  });

  test('a privileged account still sees every database', () async {
    if (!available) {
      markTestSkipped('restricted MySQL account (DBPILOT_TEST_MYSQL_LIMITED_*) not reachable');
      return;
    }
    final state = AppState.instance;
    await state.disconnect();
    await connectAs(state, mysqlEndpoint(), name: 'root-visibility');
    final names = state.instanceDatabases
        .map((database) => (database['name'] ?? '').toString())
        .toList();
    expect(names, contains('rustmyadmin_demo'));
    expect(names, contains('performance_schema'));
    expect(names, contains('mysql'));
  });

  test('opening a denied database reports the database, not a dead connection',
      () async {
    if (!available) {
      markTestSkipped('restricted MySQL account (DBPILOT_TEST_MYSQL_LIMITED_*) not reachable');
      return;
    }
    final state = AppState.instance;
    await state.disconnect();
    await connectAs(state, mysqlLimitedEndpoint());
    Object? failure;
    try {
      await state.selectDatabase('mysql');
    } catch (error) {
      failure = error;
    }
    expect(failure, isNotNull);
    final message = failure.toString();
    // Naming the database prevents the banner from reading as "the connection
    // dropped"; the raw driver prefix must be gone and the TLS hint (which only
    // applies to login failures) must not be appended.
    expect(message, contains('无法打开数据库 mysql'));
    expect(message, contains('没有访问该数据库的权限'));
    expect(message, isNot(contains('MySQL 连接失败')));
    expect(message, isNot(contains('caching_sha2')));
  });
}
