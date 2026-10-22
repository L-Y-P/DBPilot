// Regression tests for the query-history table.
//
// Reported symptom: the history box had no width/height limit and no usable
// horizontal scrolling, so a long statement (or the minimum window width) cut
// the grid off with no way to reach the rest of a row.
//
// Cause: the view wrapped a bare [DataTable] in a horizontal
// [SingleChildScrollView] with no controller and no height cap. This test boots
// the real Rust core against a throwaway SQLite file so the view loads real
// history entries, then pins the layout contract:
//   * both axes have a Scrollbar with an attached controller;
//   * the horizontal extent is actually scrollable at a narrow window width;
//   * the grid never grows past its maximum height;
//   * long statements can be opened in full.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/history_view.dart';

Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
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
    final dir = await Directory.systemTemp.createTemp('rma-history-');
    final init = await Api.init(dir.path);
    expect(init['ok'], isTrue, reason: 'init_app failed: $init');
    await AppState.instance.bootstrap(dir.path);

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
    await Api.instance.query('CREATE TABLE people (id INTEGER PRIMARY KEY);');

    // A statement far wider than any window: it must stay reachable.
    // Sent last so it stays the newest (top) history row: the grid virtualises
    // and only builds what fits in the viewport.
    final longList = List.generate(40, (i) => 'column_name_$i').join(', ');
    // Enough rows to overflow the vertical cap.
    for (var i = 0; i < 30; i++) {
      await Api.instance.query('SELECT $i AS n;');
    }
    await Api.instance.query('SELECT $longList FROM people;');
  });

  testWidgets('history table scrolls both axes and stays bounded',
      (tester) async {
    // Narrow: narrower than the fixed columns plus the minimum SQL width, so
    // the horizontal axis must scroll.
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host(HistoryView(notice: Notice())));
    await settle(tester);
    await tester.pump(const Duration(seconds: 5));

    final bars = tester.widgetList<Scrollbar>(find.byType(Scrollbar)).toList();
    expect(bars.length, greaterThanOrEqualTo(2), reason: 'one bar per axis');
    for (final bar in bars) {
      // Regression: an unattached/absent controller means the thumb is inert,
      // which is exactly how the old DataTable behaved.
      expect(bar.controller, isNotNull,
          reason: 'scrollbar would attach to the PrimaryScrollController');
      expect(bar.controller!.hasClients, isTrue,
          reason: 'controller is not attached to the scroll view');
    }
    final positions = bars.map((b) => b.controller!.position).toList();
    expect(
      positions.any((p) => p.maxScrollExtent > 0 &&
          p.axisDirection == AxisDirection.right),
      isTrue,
      reason: 'a wide row must be reachable by horizontal scrolling',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('history box is height capped and can open the full SQL',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host(HistoryView(notice: Notice())));
    await settle(tester);
    await tester.pump(const Duration(seconds: 5));

    // The grid lives inside a Card: its height must be bounded (and capped),
    // not driven by the number of rows.
    final tableSizes = tester
        .widgetList<SizedBox>(find.byType(SizedBox))
        .map((s) => s.height)
        .whereType<double>()
        .where((h) => h > 100 && h < 2000)
        .toList();
    expect(tableSizes, isNotEmpty, reason: 'no bounded height was found');
    expect(tableSizes.every((h) => h <= 440), isTrue,
        reason: 'history grid grew past its cap: $tableSizes');

    // Tapping the clipped statement opens the full text.
    final statement = find.textContaining('column_name_0').first;
    await tester.tap(statement);
    await settle(tester, rounds: 4);
    expect(find.text('完整 SQL'), findsOneWidget);
    expect(find.byKey(const ValueKey('history-close')), findsOneWidget);
  });
}
