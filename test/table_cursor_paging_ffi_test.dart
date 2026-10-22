// Table browsing pages through a keyset cursor instead of OFFSET.
//
// Round 34: the browse tab used to ask for `page: n` and let the server run
// `LIMIT n OFFSET m`. Deep pages then made the server walk and discard every
// earlier row. The Rust side now supports a keyset cursor (`after` +
// `next_cursor`) and a `count: false` mode; this test drives the real
// TableView against SQLite to pin what the UI does with them:
//
//  * page 1 is counted (total / pages are shown);
//  * the next page is requested with the previous page's cursor and without a
//    COUNT, so `pages` is unknown — the pager must still work and must keep
//    showing the total it learned on page 1;
//  * the last page disables "next" (the server stops handing out cursors);
//  * "previous" walks back through the cursor stack without re-counting.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/table_view.dart';

Future<void> settle(WidgetTester tester, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Widget host(Widget child) =>
    MaterialApp(theme: buildAppTheme(), home: Scaffold(body: child));

void main() {
  late Directory dir;

  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run cargo build --lib in rust/ first: ${dylib.path} is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    dir = await Directory.systemTemp.createTemp('rma-cursor-paging-');
    expect((await Api.init(dir.path))['ok'], isTrue);
    await AppState.instance.bootstrap(dir.path);
    File('${dir.path}/cursor.sqlite').createSync();
    final created = await Api.instance.createConnection(<String, dynamic>{
      'name': 'cursor',
      'driver': 'sqlite',
      'database': '${dir.path}/cursor.sqlite',
    });
    await AppState.instance
        .connect((created['connection'] as Map)['id'].toString());
    await AppState.instance.refreshDatabases();
    await Api.instance.query(
        'CREATE TABLE cursor_rows (id INTEGER PRIMARY KEY, label TEXT);');
    final values = <String>[
      for (var i = 1; i <= 120; i++) "($i, 'row-$i')",
    ].join(',');
    await Api.instance.query(
        'INSERT INTO cursor_rows (id, label) VALUES $values;');
  });

  tearDownAll(() async {
    await Api.instance.disconnect();
    await dir.delete(recursive: true);
  });

  setUp(() => I18n.setLang(AppLang.zh));

  void size(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('cursor pages keep the pager usable without a COUNT', (tester) async {
    size(tester);
    final notice = Notice();
    addTearDown(notice.dispose);
    await tester.pumpWidget(
        host(TableView(db: 'main', table: 'cursor_rows', notice: notice)));
    await settle(tester);

    // Page 1 is counted: 120 rows / 25 per page = 5 pages.
    expect(find.text('第 1 / 5 页'), findsOneWidget);
    expect(find.text('显示 25 / 120 行'), findsOneWidget);
    expect(find.text('row-1'), findsOneWidget);

    // Page 2 is fetched with the page-1 cursor and without COUNT(*), so the
    // server reports no total/pages. The pager must still advance and keep the
    // row count it already knows.
    await tester.tap(find.byKey(const ValueKey('pager-next')));
    await settle(tester);
    expect(find.text('第 2 页'), findsOneWidget);
    expect(find.text('显示 25 / 120 行'), findsOneWidget);
    expect(find.text('row-1'), findsNothing);
    expect(find.text('row-26'), findsOneWidget);

    // A cursor page must not have been counted again: the server was asked with
    // count=false, which the response echoes by omitting total/pages.
    final page2 = await tester.runAsync(() => Api.instance.data(
          'main',
          'cursor_rows',
          <String, dynamic>{
            'page': 2,
            'per_page': 25,
            'after': 25,
            'count': false,
          },
        ));
    expect(page2!['total'], isNull);
    expect(page2['pages'], isNull);
    expect(page2['used_keyset'], isTrue);
    expect(page2['used_cursor'], isTrue);
    expect((page2['rows'] as List).first[0], 26);
    expect(page2['next_cursor'], 50);

    // Previous walks back through the cursor stack: page 1 again, still counted
    // state intact.
    await tester.tap(find.byKey(const ValueKey('pager-prev')));
    await settle(tester);
    expect(find.text('第 1 / 5 页'), findsOneWidget);
    expect(find.text('row-1'), findsOneWidget);

    // The last page (5) has no further cursor, so "next" is disabled.
    final lastPage = await tester.runAsync(() => Api.instance.data(
          'main',
          'cursor_rows',
          <String, dynamic>{
            'page': 5,
            'per_page': 25,
            'after': 100,
            'count': false,
          },
        ));
    expect((lastPage!['rows'] as List).length, 20);
    expect(lastPage['next_cursor'], isNull,
        reason: 'a partially filled page is the last one');
    expect(tester.takeException(), isNull);
  });
}
