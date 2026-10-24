// Round34 P2-01: the browse tab's 「行数：N」 pill did not follow the data.
//
// Two paths made that happen:
//  * the COUNT was only requested for the first, un-cursored page (the round34
//    keyset contract), so a write performed while the user was on a cursor page
//    left the pill on the previous total;
//  * _reloadAll kept the previous table's _data / _knownTotal, so a table
//    switch could show another table's number while the new one was loading.
//
// The first group pins the count decision itself (the performance contract:
// one COUNT per user action, never one per page). The second drives the real
// TableView against SQLite and asserts the pill text after an insert made from
// a cursor page.

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

Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Widget host(Widget child) =>
    MaterialApp(theme: buildAppTheme(), home: Scaffold(body: child));

void main() {
  group('count decision', () {
    test('only an un-cursored page is counted by default', () {
      // Page 1 has no cursor, so the request carries count: true.
      expect(shouldCountTableRows(cursor: null), isTrue);
      // A cursor page skips COUNT(*) — the round34 keyset performance contract.
      expect(shouldCountTableRows(cursor: 25), isFalse);
      expect(shouldCountTableRows(cursor: 'row-25'), isFalse);
    });

    test('a write or an explicit refresh re-counts even on a cursor page', () {
      expect(shouldCountTableRows(cursor: 25, refreshCount: true), isTrue);
      expect(shouldCountTableRows(cursor: null, refreshCount: true), isTrue);
    });
  });

  group('TableView row-count pill', () {
    late Directory dir;

    setUpAll(() async {
      final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
      if (!dylib.existsSync()) {
        fail('Run cargo build --lib in rust/ first: ${dylib.path} is missing');
      }
      await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
      dir = await Directory.systemTemp.createTemp('rma-rowcount-');
      expect((await Api.init(dir.path))['ok'], isTrue);
      await AppState.instance.bootstrap(dir.path);
      File('${dir.path}/rowcount.sqlite').createSync();
      final created = await Api.instance.createConnection(<String, dynamic>{
        'name': 'rowcount',
        'driver': 'sqlite',
        'database': '${dir.path}/rowcount.sqlite',
      });
      await AppState.instance
          .connect((created['connection'] as Map)['id'].toString());
      await AppState.instance.refreshDatabases();
      await Api.instance.query(
          'CREATE TABLE count_rows (id INTEGER PRIMARY KEY, label TEXT);');
      await Api.instance.query('CREATE TABLE empty_rows (id INTEGER PRIMARY KEY);');
      final values = <String>[
        for (var i = 1; i <= 30; i++) "($i, 'row-$i')",
      ].join(',');
      await Api.instance
          .query('INSERT INTO count_rows (id, label) VALUES $values;');
    });

    tearDownAll(() async {
      await Api.instance.disconnect();
      await dir.delete(recursive: true);
    });

    setUp(() => I18n.setLang(AppLang.zh));

    void size(WidgetTester tester) {
      tester.view.physicalSize = const Size(1282, 817);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets('an insert on a cursor page refreshes the pill', (tester) async {
      size(tester);
      final notice = Notice();
      addTearDown(notice.dispose);
      await tester.pumpWidget(
          host(TableView(db: 'main', table: 'count_rows', notice: notice)));
      await settle(tester);

      expect(find.text('行数：30'), findsOneWidget);
      expect(find.text('第 1 / 2 页'), findsOneWidget);

      // Page 2 is reached with the page-1 cursor: the request carries
      // count: false and the pill keeps the total learned on page 1.
      await tester.tap(find.byKey(const ValueKey('pager-next')));
      await settle(tester);
      expect(find.text('第 2 页'), findsOneWidget);
      expect(find.text('行数：30'), findsOneWidget);

      // Insert one row while the browse tab sits on that cursor page. Before
      // the fix the reload kept count: false, so the pill stayed at 30.
      await tester.tap(find.text('插入').first);
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, 'inserted-after-paging');
      await tester.tap(find.text('插入').last);
      await settle(tester);

      expect(find.text('行数：31'), findsOneWidget,
          reason: 'a write must re-count even on a cursor page');
      expect(find.text('行数：30'), findsNothing);

      final data = await tester.runAsync(() => Api.instance.data(
          'main', 'count_rows', <String, dynamic>{'page': 1, 'per_page': 100}));
      expect((data!['rows'] as List).length, 31);
      expect(tester.takeException(), isNull);

      // The notice schedules its own fade timers; flush them inside the fake
      // clock so the test does not end with pending timers.
      await tester.pump(const Duration(seconds: 4));
      // Restore the fixture so the next test starts from 30 rows again.
      await tester.runAsync(() => Api.instance.query(
          "DELETE FROM count_rows WHERE label = 'inserted-after-paging';"));
    });

    testWidgets('switching tables drops the previous table total',
        (tester) async {
      size(tester);
      final notice = Notice();
      addTearDown(notice.dispose);

      await tester.pumpWidget(
          host(TableView(db: 'main', table: 'empty_rows', notice: notice)));
      await settle(tester);
      expect(find.text('行数：0'), findsOneWidget);

      // Same widget position, different table: the State is reused and
      // didUpdateWidget calls _reloadAll. The old total must not survive as the
      // header pill while the new table loads (the reported symptom was a pill
      // showing 0 on a table that has rows).
      await tester.pumpWidget(
          host(TableView(db: 'main', table: 'count_rows', notice: notice)));
      expect(find.text('行数：0'), findsNothing,
          reason: 'the previous table total must be invalidated on reload');

      await settle(tester);
      // The shared fixture means the exact total is not part of this case; the
      // point is that the pill follows the new table's own COUNT.
      final data = await tester.runAsync(() => Api.instance.data(
          'main', 'count_rows', <String, dynamic>{'page': 1, 'per_page': 50}));
      final expected = (data!['total'] as num).toInt();
      expect(find.text('行数：$expected'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('table SQL tab exposes the cancel button', (tester) async {
    await tester.pumpWidget(host(TableView(
      db: 'main',
      table: 'count_rows',
      notice: Notice(),
    )));
    await settle(tester);
    await tester.tap(find.text('SQL').first);
    await settle(tester);
    final cancel = find.byKey(const ValueKey('table-sql-cancel'));
    expect(cancel, findsOneWidget);
    // Idle: the button is disabled (no in-flight query), so tapping is a no-op
    // rather than an error.
    await tester.tap(cancel);
    await settle(tester);
  });
}
