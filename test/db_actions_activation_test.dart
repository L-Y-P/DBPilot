// Round 70: a context-menu action opened from a PostgreSQL *schema* node must
// not try to switch the connection to that schema.
//
// The sidebar nests schemas under the connected database, so the name passed
// to activateDatabase() from a schema node is a schema, not a database.
// Switching to it fails with "database does not exist"; because the dialog is
// only shown after the switch, the old code made 关系图 / 新建表 silently do
// nothing from any PostgreSQL tree node.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/db_actions.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';

late Directory dir;

void main() {
  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run cargo build --lib in rust/ first: ${dylib.path} is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    dir = await Directory.systemTemp.createTemp('rma-activate-');
    final init = await Api.init(dir.path);
    expect(init['ok'], isTrue, reason: 'init_app failed: ${init.toString()}');
    await AppState.instance.bootstrap(dir.path);
  });

  tearDownAll(() async {
    try {
      await AppState.instance.disconnect();
    } catch (_) {}
    await dir.delete(recursive: true);
  });

  test('activateDatabase never switches to a PostgreSQL schema name', () async {
    final state = AppState.instance;
    // Stand in for a connected PostgreSQL session: the tree lists schemas,
    // and the physical database list holds the real database names.
    state.connection = <String, dynamic>{'driver': 'postgres', 'name': 'pg'};
    addTearDown(() => state.connection = null);
    state.activeDatabase = 'pagila';
    state.instanceDatabases = <Json>[
      <String, dynamic>{'name': 'pagila'},
      <String, dynamic>{'name': 'postgres'},
    ];
    state.databases = <Json>[
      <String, dynamic>{'name': 'public'},
      <String, dynamic>{'name': 'sales'},
    ];

    // A schema is not a database: the active database must stay put, and no
    // selectDatabase round trip may be attempted.
    await activateDatabase('sales');
    expect(state.activeDatabase, 'pagila',
        reason: 'a schema node must not switch the physical database');

    // A real database still switches when the server knows it.
    state.activeDatabase = 'public';
    await activateDatabase('pagila');
    expect(state.activeDatabase, 'public',
        reason: 'without a live server the switch is best-effort, not fatal');
  });
}