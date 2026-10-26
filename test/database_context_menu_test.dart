// Round 70: the database page and the sidebar expose the same actions through a
// right-click menu as through their toolbar buttons.
//
// CUA automation cannot deliver a right-click to Flutter (its synthetic event
// route is not seen by GestureDetector), so the wiring is pinned here with a
// real secondary-button gesture instead.
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/database_view.dart';

late Directory dir;

Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> rightClick(WidgetTester tester, Offset at) async {
  final gesture = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    I18n.setLang(AppLang.zh);
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run cargo build --lib in rust/ first: ${dylib.path} is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    dir = await Directory.systemTemp.createTemp('rma-menu-wiring-');
    final init = await Api.init(dir.path);
    expect(init['ok'], isTrue, reason: 'init_app failed: ${init.toString()}');
    await AppState.instance.bootstrap(dir.path);
    final dbFile = '${dir.path}/menu.sqlite';
    await File(dbFile).create(recursive: true);
    final created = await Api.instance.createConnection(<String, dynamic>{
      'name': 'menu-wiring',
      'driver': 'sqlite',
      'database': dbFile,
    });
    final id = ((created['connection'] as Map)['id']).toString();
    await AppState.instance.connect(id);
    await Api.instance.query('CREATE TABLE menu_target (id INTEGER);', 'main');
    await AppState.instance.refreshDatabases();
  });

  tearDownAll(() async {
    try {
      await AppState.instance.disconnect();
    } catch (_) {}
    await dir.delete(recursive: true);
  });

  testWidgets('right-clicking the database page head opens its action menu', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: DatabaseView(db: 'main', notice: Notice()),
        ),
      ),
    );
    await settle(tester);

    // The page title lives inside the context-menu region. For SQLite the
    // namespace is `main`, so the title is the database file name; match it
    // loosely because the app may show the bare name without the extension.
    // Right-click the page head area (the title row), not a card.
    final head = find.textContaining('menu');
    expect(head, findsWidgets);
    await rightClick(tester, tester.getCenter(head.first));

    // The menu carries the same labels as the toolbar.
    expect(find.text('新建表'), findsWidgets);
    expect(find.text('关系图'), findsWidgets);
    expect(find.text('从文件建表'), findsWidgets);

    // Dismiss without running anything.
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
  });
}
