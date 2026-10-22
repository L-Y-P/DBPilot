// Live check for P14 (PostgreSQL tree: clicking a database node selects it)
// and P13 (the database page subtitle must show public instead of "（未知）").
//
// 这是 live 测试：需要本地 PostgreSQL 与 pagila 库。端点与账号来自环境变量
// （DBPILOT_TEST_PG_* / DBPILOT_TEST_PG_LIVE_DB，见 test/live_db_env.dart），
// 仓库里不留任何账号密码字面量。数据库不可达时自动 SKIP。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/nav.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/shell.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';

import 'live_db_env.dart';

Widget app() => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const Shell(),
    );

Future<bool> pumpUntil(WidgetTester tester, bool Function() done,
    {int rounds = 120}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
    if (done()) return true;
  }
  return done();
}

void main() {
  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run cargo build --lib in rust/ first: the dylib is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    final dir = await Directory.systemTemp.createTemp('rma-pg-tree-live-');
    final init = await Api.init(dir.path);
    expect(init['ok'], isTrue, reason: 'init_app failed');
    await AppState.instance.bootstrap(dir.path);
  });

  tearDownAll(() async {
    try {
      await AppState.instance.disconnect();
    } catch (_) {}
  });

  testWidgets('clicking a PG database selects it and the subtitle shows public',
      (tester) async {
    final liveDb = pgLiveDatabase();
    final connected = await tester.runAsync(() async {
      try {
        final created = await Api.instance.createConnection(
          connectionPayload(
            'postgres',
            pgEndpoint(database: liveDb),
            name: 'pg-tree-live',
          ),
        );
        final id = (created['connection'] as Map)['id'].toString();
        await AppState.instance.connect(id);
        return true;
      } catch (_) {
        return false;
      }
    });
    if (connected != true) {
      markTestSkipped('PostgreSQL (DBPILOT_TEST_PG_*) + $liveDb not available');
      return;
    }

    // Make sure the live database is not already active, so the click really
    // exercises the selection path instead of passing trivially.
    final other = AppState.instance.instanceDatabases
        .map((db) => (db['name'] ?? '').toString())
        .where((name) => name.isNotEmpty && name != liveDb)
        .firstOrNull;
    if (other == null) {
      await tester.runAsync(() => AppState.instance.disconnect());
      markTestSkipped('PG instance needs a second database besides $liveDb');
      return;
    }
    await tester.runAsync(() => AppState.instance.selectDatabase(other));
    expect(AppState.instance.activeDatabase, other);

    Navigation.instance.go(AppRoute.connections);
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app());
    await tester.pump();

    // The sidebar lists the instance's databases; clicking one used to only
    // expand it and leave the previous database active.
    final visible = await pumpUntil(
        tester, () => find.text(liveDb).evaluate().isNotEmpty);
    expect(visible, isTrue, reason: '$liveDb must appear in the PG tree');
    await tester.tap(find.text(liveDb).first);

    final selected = await pumpUntil(
        tester, () => AppState.instance.activeDatabase == liveDb);
    expect(selected, isTrue,
        reason: 'clicking a database node must select it (P14)');
    // selectDatabase returns the schemas; the tree must reuse that response
    // instead of issuing a second list-schemas query on expand.
    expect(Navigation.instance.expandedDatabases.contains(liveDb), isTrue);
    expect(Navigation.instance.schemasByDb[liveDb], isNotNull);

    // P13: the search_path came back with the switch, and the subtitle label is
    // used by the database page.
    expect(AppState.instance.searchPath, isNotEmpty);
    expect(AppState.instance.defaultSchemaLabel, 'public');

    Navigation.instance.go(AppRoute.database('public'));
    await tester.pump();
    final subtitle = await pumpUntil(
        tester, () => find.textContaining('默认 schema').evaluate().isNotEmpty);
    expect(subtitle, isTrue);
    expect(find.textContaining('（未知）'), findsNothing,
        reason: 'the default schema must never render as unknown (P13)');
    expect(find.textContaining('默认 schema public'), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.runAsync(() => AppState.instance.disconnect());
  }, timeout: const Timeout(Duration(minutes: 2)));
}