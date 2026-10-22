// End-to-end pagination for the query-history page.
//
// The view asks Rust for exactly one page (limit/offset) and renders it through
// the same GridTable/TablePager used by the data browser, so a large history
// never builds every row or receives every stored SQL over FFI.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/history_view.dart';

Future<void> settle(WidgetTester tester, {int rounds = 14}) async {
  for (var i = 0; i < rounds; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('rma-history-paging-');
    final entries = <Map<String, dynamic>>[
      for (var i = 0; i < 120; i++)
        <String, dynamic>{
          'id': 'h-$i',
          'user': 'local',
          'sql': 'SELECT $i AS n',
          'database': 'db',
          'at': '2026-10-21T00:00:00+00:00',
          'ok': true,
          'statements': 1,
          'failed': 0,
          'elapsed_ms': 1,
        },
    ];
    File('${dir.path}/query_history.json').writeAsStringSync(jsonEncode(entries));
    await RustLib.init(
        externalLibrary:
            ExternalLibrary.open('rust/target/debug/librust_myadmin_core.dylib'));
    await Api.init(dir.path);
  });

  tearDownAll(() async {
    await dir.delete(recursive: true);
  });

  testWidgets('history page paginates 120 entries with the shared table pager',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: HistoryView(notice: Notice())),
    ));
    await settle(tester);

    expect(find.text('第 1 / 3 页'), findsOneWidget);
    expect(find.text('显示 50 / 120 行'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('history-pager-next')));
    await settle(tester);
    expect(find.text('第 2 / 3 页'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('history-pager-next')));
    await settle(tester);
    expect(find.text('第 3 / 3 页'), findsOneWidget);
    expect(find.text('显示 20 / 120 行'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
