// Golden snapshots for the three views that had no visual verification in the
// first desktop build (the handover flagged Backups / Sync as "implemented but
// never rendered"). They also pin the layout fixes: the backup grid used to
// collapse to zero width and the sync toolbar used to mix three control heights.
//
// Run with:  flutter test --update-goldens test/views_golden_test.dart
//
// Like app_shell_test.dart this boots the real Rust core against a throwaway
// SQLite file, because the views read AppState.databases.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/backups_view.dart';
import 'package:rust_myadmin_desktop/src/views/builder_view.dart';
import 'package:rust_myadmin_desktop/src/views/connections_view.dart';
import 'package:rust_myadmin_desktop/src/views/sync_view.dart';

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
      fail('Run `cargo build --lib` in rust/ first: ${dylib.path} is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    final dir = await Directory.systemTemp.createTemp('rma-views-');
    final init = await Api.init(dir.path);
    expect(init['ok'], isTrue, reason: 'init_app failed: $init');
    await AppState.instance.bootstrap(dir.path);

    // Two SQLite namespaces so the sync source/target selects have real options.
    // The database file must exist: a connection pointing at a missing file is
    // reported as missing instead of being silently created empty.
    File('${dir.path}/demo.sqlite').createSync(recursive: true);
    final created = await Api.instance.createConnection({
      'name': 'SQLite 示例库',
      'driver': 'sqlite',
      'database': '${dir.path}/demo.sqlite',
      'color': '#0f80cc',
    });
    final id = (created['connection'] as Map)['id'].toString();
    await AppState.instance.connect(id);
    await Api.instance.query(
        'CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL);');
    await Api.instance.query(
        "INSERT INTO people (name) VALUES ('Ada'), ('Bob');");
    await Api.instance.query(
        'CREATE TABLE courses (id INTEGER PRIMARY KEY, people_id INTEGER, '
        'title TEXT, score NUMERIC);');
    await Api.instance.query(
        "INSERT INTO courses VALUES (1, 1, 'Databases', 92.5), (2, 2, 'Rust', 88);");
    await AppState.instance.refreshDatabases();
    AppState.instance.notify();
  });

  testWidgets('structure sync', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host(SyncView(notice: Notice())));
    await settle(tester);

    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/app_05_sync.png'));
  });

  testWidgets('backups', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host(BackupsView(notice: Notice())));
    await settle(tester);

    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/app_06_backups.png'));
  });

  testWidgets('query builder', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host(BuilderView(notice: Notice())));
    await settle(tester);
    // Primary table + all of its columns as output gives the snapshot a
    // populated output card and a realistic SQL preview.
    await tester.tap(find.byKey(const ValueKey('builder-table-people')));
    await settle(tester, rounds: 3);
    await tester.tap(find.text('全部'));
    await settle(tester, rounds: 3);
    // A declared FK between the demo tables derives a join automatically; the
    // golden captures the merged tabbed card with that join in place.
    expect(find.byKey(const ValueKey('builder-tab-join')), findsOneWidget);

    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/app_08_builder.png'));
  });

  testWidgets('connection editor dialog', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host(ConnectionsView(notice: Notice())));
    await settle(tester);
    await tester.tap(find.text('新建连接'));
    await settle(tester, rounds: 4);

    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/app_07_connection_dialog.png'));
  });
}
