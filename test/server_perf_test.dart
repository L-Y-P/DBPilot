// Regression tests for the server page's tab-switch cost.
//
// Reported symptom: clicking between 状态 / 变量 / 进程 / 账号 felt sluggish.
//
// Cause: switching a tab does NOT query the database — the tab handler only
// calls setState — but the rebuild was expensive. The status tab lists ~490
// MySQL status variables and the variables tab ~620 rows, and each row was
// built eagerly as its own SelectableText inside a Column. Every SelectableText
// owns a selection registrar and gesture recogniser, so the tab took over a
// second to build (measured: 3750ms for 620 rows; ~200ms after the fix).
//
// These tests pin the structural properties that make it fast, because a wall
// clock assertion would be flaky on a loaded CI box.
//
// 这是 live 测试：需要本地数据库。端点与账号来自环境变量（DBPILOT_TEST_MYSQL_*，
// 见 test/live_db_env.dart），仓库里不留任何账号密码字面量。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/server_view.dart';

import 'live_db_env.dart';

Future<void> settle(WidgetTester tester, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(body: child),
    );

void main() {
  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run cargo build --lib in rust/ first: the dylib is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    final dir = await Directory.systemTemp.createTemp('rma-perf-regress-');
    final init = await Api.init(dir.path);
    expect(init['ok'], isTrue, reason: 'init_app failed');
    await AppState.instance.bootstrap(dir.path);
    final created = await Api.instance.createConnection(
      connectionPayload('mysql', mysqlEndpoint(), name: 'perf-regress'),
    );
    final id = (created['connection'] as Map)['id'].toString();
    try {
      await AppState.instance.connect(id);
    } catch (_) {
      // Covered by the per-test skip below.
    }
  });

  bool connected() => AppState.instance.connected;

  testWidgets('the variable list is virtualised and uses one SelectionArea',
      (tester) async {
    if (!connected()) {
      markTestSkipped('MySQL (DBPILOT_TEST_MYSQL_*) not reachable');
      return;
    }
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host(ServerView(notice: Notice())));
    await settle(tester);

    // The status tab is the default; its "all status variables" card holds
    // ~490 rows.
    expect(find.text('全部状态变量'), findsOneWidget);

    // One SelectionArea for the whole list, not one SelectableText per row.
    expect(find.byType(SelectionArea), findsWidgets);
    expect(find.byType(SelectableText), findsNothing,
        reason: 'per-row SelectableText is what made the tab slow');

    // Lazy list, so only a screenful of rows is materialised.
    expect(find.byType(ListView), findsWidgets);
    final rows = find.byType(Row).evaluate().length;
    expect(rows, lessThan(120),
        reason: 'the whole 490-row list was built eagerly ($rows Row widgets)');
  });

  testWidgets('switching tabs does not re-query the database', (tester) async {
    if (!connected()) {
      markTestSkipped('MySQL (DBPILOT_TEST_MYSQL_*) not reachable');
      return;
    }
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host(ServerView(notice: Notice())));
    await settle(tester);

    // A tab switch is synchronous state only: one pump must settle it, with no
    // pending microtasks waiting on the bridge. If the handler queried the
    // database, the panel would still be empty after a single frame.
    await tester.tap(find.text('变量'));
    await tester.pump();
    expect(find.text('服务器变量'), findsOneWidget);
    // The variables were already cached by the initial load, so the list is
    // populated immediately rather than after a round-trip.
    expect(find.byType(ListView), findsWidgets);

    await tester.tap(find.text('状态'));
    await tester.pump();
    expect(find.text('全部状态变量'), findsOneWidget);
  });
}