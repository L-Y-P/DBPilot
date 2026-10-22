// Full-app UI test: boots the real Rust core and renders the real shell.
//
// `flutter test` runs on the host VM, and flutter_rust_bridge supports that, so
// this test can initialize the actual Rust core against a real SQLite file and
// then drive the real widgets. That makes it the closest thing to launching the
// app, and it can capture PNGs of the rendered UI — which the OS screenshot
// tool cannot do without Screen Recording permission.
//
// Run with:  flutter test --update-goldens test/app_shell_test.dart

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Text;
// ExternalLibrary is exported by the generated IO surface, not the main library.
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/nav.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/shell.dart';
import 'package:rust_myadmin_desktop/src/text.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';

/// Boots the Rust core in a throwaway data directory containing one SQLite
/// connection, then opens it so the shell has a real database to show.
Future<void> bootWithSqlite() async {
  // `flutter test` runs on the host VM, where the plugin loader cannot find the
  // framework the app bundle would provide. The crate also builds a standalone
  // dylib, so point the loader at it explicitly. `cargo build --lib` in
  // rust/ produces it; the path is resolved relative to the package root.
  final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
  if (!dylib.existsSync()) {
    fail('Run `cargo build --lib` in rust/ first: ${dylib.path} is missing');
  }
  await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));

  // A deterministic data directory: the SQLite sidebar is grouped by folder,
  // so a random temp path made the rendered text differ on every run and the
  // golden snapshots could never match twice.
  final dir = Directory('${Directory.systemTemp.path}/rma-ui-golden');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  await dir.create(recursive: true);
  final dbFile = '${dir.path}/demo.sqlite';

  // Mirror main(): initialize the Rust core, then let the shell bootstrap.
  final init = await Api.init(dir.path);
  expect(init['ok'], isTrue, reason: 'init_app failed: $init');
  await AppState.instance.bootstrap(dir.path);
  expect(AppState.instance.bootstrapError, isNull,
      reason: 'bootstrap failed: ${AppState.instance.bootstrapError}');
  expect(AppState.instance.bootstrapped, isTrue);

  // The database file must exist: a connection pointing at a missing file is
  // reported as missing instead of being silently created empty.
  await File(dbFile).create(recursive: true);
  final created = await Api.instance.createConnection({
    'name': 'SQLite 示例库',
    'driver': 'sqlite',
    'database': dbFile,
    'color': '#0f80cc',
  });
  final id = (created['connection'] as Map)['id'].toString();

  // The connection must be open before any statement can run.
  await AppState.instance.connect(id);

  // Seed a small schema so the explorer and grids have content to render.
  await Api.instance.query(
      'CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER);');
  await Api.instance.query(
      "INSERT INTO people (name, age) VALUES ('Ada', 36), ('Bob', 41), ('Cy', 22);");

  await AppState.instance.refreshDatabases();
  AppState.instance.notify();
}

/// Pump frames on a real event loop so the FFI futures can actually complete.
///
/// `pumpAndSettle` uses a fake clock, so a Rust call that needs real I/O never
/// resolves and the wait times out. `runAsync` runs the body with a real clock,
/// and the explicit pumps then render the state the completed future produced.
Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Widget app() => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const Shell(),
    );

void main() {
  setUpAll(() async {
    await bootWithSqlite();
  });

  testWidgets('shell renders the connection manager', (tester) async {
    // A desktop-sized surface so the sidebar and topbar are both laid out.
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Navigation.instance.go(AppRoute.connections);
    await tester.pumpWidget(app());
    await settle(tester);

    // The real shell is on screen: brand, sidebar head and the page title.
    expect(find.text('DBPilot'), findsWidgets);
    expect(find.text('数据库'), findsWidgets);
    expect(find.text('连接管理'), findsWidgets);

    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/app_01_connections.png'));
  });

  testWidgets('shell renders the database explorer', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // The seeded database is 'main'; open it so the table list is populated.
    Navigation.instance.go(AppRoute.database('main'));
    await tester.pumpWidget(app());
    await settle(tester);

    expect(find.text('people'), findsWidgets);

    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/app_02_database.png'));
  });

  testWidgets('shell renders the table browser', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Navigation.instance.go(AppRoute.tableRoute('main', 'people'));
    await tester.pumpWidget(app());
    await settle(tester);

    // The seeded rows are visible in the browse grid.
    expect(find.text('Ada'), findsWidgets);

    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/app_03_table.png'));
  });


  testWidgets('table SQL tab starts with the database prelude', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Navigation.instance.go(AppRoute.tableRoute('main', 'people'));
    await tester.pumpWidget(app());
    await settle(tester);
    await tester.tap(find.text('SQL').first);
    await settle(tester, rounds: 3);

    // SQLite has no USE syntax, so the prelude documents the namespace; the
    // editor still opens with the generated SELECT below it.
    expect(find.textContaining('当前数据库: main'), findsWidgets);
    expect(find.textContaining('SELECT * FROM'), findsWidgets);
  });

  testWidgets('shell renders the SQL console', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Navigation.instance.go(AppRoute.sql);
    await tester.pumpWidget(app());
    await settle(tester);

    expect(find.text('SQL 控制台'), findsWidgets);

    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/app_04_sql.png'));
  });

  testWidgets('deleting the active connection clears the shell', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Create and open a uniquely named SQLite connection so the delete button
    // under test belongs to a card we can identify, not to one of the backend
    // seed connections.
    final created = await tester.runAsync(() async {
      final tmp = Directory('${Directory.systemTemp.path}/rma-ui-golden');
      final extraFile = File('${tmp.path}/delete-me.sqlite');
      await extraFile.create(recursive: true);
      final response = await Api.instance.createConnection({
        'name': '待删除连接',
        'driver': 'sqlite',
        'database': extraFile.path,
        'color': '#0f80cc',
      });
      final id = ((response['connection'] as Map)['id']).toString();
      await AppState.instance.connect(id);
      return response;
    });
    expect(created, isNotNull);

    Navigation.instance.go(AppRoute.connections);
    await tester.pumpWidget(app());
    await settle(tester);
    expect(find.text('当前连接：待删除连接 (SQLite)'), findsOneWidget);

    // Last card in the list = the connection created last. Open its confirm
    // dialog, then press the dialog's danger button (also the last '删除').
    await tester.tap(find.text('删除').last);
    await settle(tester);
    await tester.tap(find.text('删除').last);
    await settle(tester);

    // Removing the active saved connection must close it in Rust and clear the
    // topbar, sidebar and explorer caches in the same step.
    expect(find.text('未连接数据库'), findsWidgets);
    expect(find.text('前往连接管理'), findsWidgets);
    expect(find.text('当前连接：待删除连接 (SQLite)'), findsNothing);
    expect(find.text('待删除连接'), findsNothing);
  });

  testWidgets('disconnect clears the tree and guards database pages', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Navigation.instance.go(AppRoute.connections);
    await tester.pumpWidget(app());
    await settle(tester);

    await tester.runAsync(() => AppState.instance.disconnect());
    await settle(tester);

    // Sidebar and topbar must both report the empty state, and no stale table
    // from the previous connection may remain visible.
    expect(find.text('未连接数据库'), findsWidgets);
    expect(find.text('前往连接管理'), findsWidgets);
    expect(find.text('people'), findsNothing);

    // A route that needs a database (SQL console) shows the guard instead of a
    // dead SQL page when the connection was closed underneath it.
    Navigation.instance.go(AppRoute.sql);
    await tester.pump();
    await settle(tester);
    expect(find.text('未连接数据库'), findsWidgets);
    expect(find.text('执行'), findsNothing);

    await tester.tap(find.text('前往连接管理').first);
    await settle(tester);
    expect(find.text('连接管理'), findsWidgets);
  });

  // The topbar used to put a scrollable connection strip next to a Spacer:
  // Flutter split the free space between the two flex children, so on wide
  // windows the nav group stopped far short of the right edge. The info area now
  // takes the leftover space itself, caps its width, truncates long names with
  // an ellipsis and shows the full value in a tooltip; the nav group must end
  // flush against the topbar's right padding at every width.
  testWidgets('topbar truncates long names and keeps the nav right-aligned',
      (tester) async {
    Future<void> sizeTo(Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    await sizeTo(const Size(1600, 1000));
    // Leave whatever connection the previous test left behind.
    await tester.runAsync(() async {
      try {
        await AppState.instance.disconnect();
      } catch (_) {}
    });
    final longName =
        'A very long remote SQLite connection name used to verify that the '
        'topbar ellipsizes instead of pushing the navigation buttons left';
    final dbFile = '${Directory.systemTemp.path}/rma-ui-golden/demo.sqlite';
    final created = await tester.runAsync(() => Api.instance.createConnection({
          'name': longName,
          'driver': 'sqlite',
          'database': dbFile,
        }));
    final id = (((created!['connection'] as Map)['id'])).toString();
    await tester.runAsync(() => AppState.instance.connect(id));

    Navigation.instance.go(AppRoute.connections);
    await tester.pumpWidget(app());
    await settle(tester);

    // Nav group flush against the topbar's 14px right padding.
    final enFinder = find.byKey(const ValueKey('topbar-settings'));
    expect(enFinder, findsOneWidget);
    expect(tester.getTopRight(enFinder).dx, closeTo(1600 - 14, 0.5),
        reason: 'the settings button must be right-aligned');

    // Long connection name: single line, ellipsized, capped, full text in
    // the tooltip.
    final labelFinder = find.byKey(const ValueKey('topbar-connection'));
    expect(labelFinder, findsOneWidget);
    final label = tester.widget<Text>(labelFinder);
    expect(label.maxLines, 1);
    expect(label.overflow, TextOverflow.ellipsis);
    expect(tester.getSize(labelFinder).width, lessThanOrEqualTo(560));
    // The topbar label itself carries the full value in a bounded tooltip. The
    // connection card on the page shows the same name (and now also exposes it
    // on hover), so scope the lookup to the topbar rather than the whole tree.
    final topbarTooltip = find.ancestor(
      of: labelFinder,
      matching: find.byWidgetPredicate(
          (widget) => widget is Tooltip && widget.message == longName),
    );
    expect(topbarTooltip, findsOneWidget);
    final tooltip = tester.widget<Tooltip>(topbarTooltip);
    expect(tooltip.constraints, isNotNull,
        reason: 'tooltip must stay width-bounded');

    // Hovering shows the full value in the tooltip overlay.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.moveTo(tester.getCenter(labelFinder));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text(longName).evaluate().length, greaterThan(1),
        reason: 'tooltip overlay must show the untruncated connection name');
    await mouse.moveTo(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 400));

    // Still right-aligned and never overflowing at narrower widths.
    for (final width in [1200.0, 900.0]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pump();
      await settle(tester);
      expect(tester.takeException(), isNull, reason: 'overflow at width $width');
      expect(tester.getTopRight(find.byKey(const ValueKey('topbar-settings'))).dx,
          closeTo(width - 14, 0.5),
          reason: 'nav must stay right-aligned at width $width');
    }

    // The empty ("not connected") state must be right-aligned too.
    await tester.runAsync(() => AppState.instance.disconnect());
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(tester.getTopRight(find.byKey(const ValueKey('topbar-settings'))).dx,
        closeTo(900 - 14, 0.5));
    expect(find.text('未连接数据库'), findsWidgets);
  });
}
