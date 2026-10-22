// Regression tests for the four defects reported after the second review.
//
//   1. Insert form: the text fields were uncontrolled, so a successful insert
//      left the old text on screen and the next submit sent empty values.
//   2. Data grid: every row was an independent Row, so each one sized its cells
//      to its own content and the columns (and header) no longer lined up.
//   3. Query builder: the ON clause emitted right = left, the opposite of the
//      order shown in the graphical join row.
//   4. Server page: MySQL returns SHOW GLOBAL STATUS counters as strings, and
//      the `as num?` cast threw, blanking the whole page.
//
// 1 and 2 boot the real Rust core against SQLite; 3 and 4 are pure checks.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/components/data_grid.dart';
import 'package:rust_myadmin_desktop/src/nav.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/builder_view.dart';
import 'package:rust_myadmin_desktop/src/views/server_view.dart';
import 'package:rust_myadmin_desktop/src/views/table_view.dart';

Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
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
  // The Rust core is a process-wide singleton, so boot it once for the file.
  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('rma-regress2-');
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run `cargo build --lib` in rust/ first: ${dylib.path} is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    final init = await Api.init(dir.path);
    expect(init['ok'], isTrue, reason: 'init_app failed: $init');
    await AppState.instance.bootstrap(dir.path);
    File('${dir.path}/r.sqlite').createSync(recursive: true);
    final created = await Api.instance.createConnection({
      'name': 'regress2',
      'driver': 'sqlite',
      'database': '${dir.path}/r.sqlite',
    });
    final id = (created['connection'] as Map)['id'].toString();
    await AppState.instance.connect(id);
    await AppState.instance.refreshDatabases();
  });

  group('data grid', () {
    testWidgets('all rows share the same column boundaries', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(host(DataGrid(
        columns: const [
          {'name': 'id', 'type_name': 'INT'},
          {'name': 'name', 'type_name': 'TEXT'},
          {'name': 'note', 'type_name': 'TEXT'},
        ],
        // Deliberately very different content lengths per row: with per-row
        // sizing the second column starts at a different x in each row.
        rows: const [
          [1, 'a', 'x'],
          [22, 'a considerably longer value here', 'y'],
          [333, 'b', 'z'],
        ],
        primaryKey: const ['id'],
        rowOps: true,
      )));
      await tester.pumpAndSettle();

      // Every body cell of the "name" column must share one left edge, no
      // matter how long that row's value is.
      final lefts = <double>[
        tester.getTopLeft(find.text('a')).dx,
        tester.getTopLeft(find.text('a considerably longer value here')).dx,
        tester.getTopLeft(find.text('b')).dx,
      ];
      for (final left in lefts) {
        expect((left - lefts.first).abs(), lessThan(0.5),
            reason: 'column "name" starts at a different x per row: $lefts');
      }
    });
  });

  group('query builder', () {
    testWidgets('join ON keeps the order shown in the picker', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.runAsync(() async {
        await Api.instance.query(
            'CREATE TABLE IF NOT EXISTS category (id INTEGER PRIMARY KEY, category TEXT);');
        await Api.instance.query(
            'CREATE TABLE IF NOT EXISTS ordert (id INTEGER PRIMARY KEY, category_id INTEGER);');
      });

      await tester.pumpWidget(host(BuilderView(notice: Notice())));
      await settle(tester);

      // Clicking a table name makes it the FROM table of the query.
      await tester.tap(find.text('category').first);
      await settle(tester, rounds: 3);
      // The join editor lives in its own tab of the merged configuration card.
      await tester.tap(find.byKey(const ValueKey('builder-tab-join')));
      await tester.pump();
      // Adding a join defaults the right side to the other table and fills ON
      // from the shared column (both tables have an 'id').
      await tester.tap(find.byKey(const ValueKey('builder-add-join')));
      await settle(tester, rounds: 5);
      // The SQL strip starts collapsed; expand it to read the generated SQL.
      await tester.tap(find.byKey(const ValueKey('builder-sql-toggle')));
      await settle(tester, rounds: 2);

      final sql = find
          .byType(SelectableText)
          .evaluate()
          .map((e) => (e.widget as SelectableText).data ?? '')
          .join('\n');
      final onLine =
          sql.split('\n').where((l) => l.contains(' ON ')).join(' ').trim();
      expect(onLine, isNotEmpty, reason: 'no JOIN ON generated:\n$sql');
      // The picker reads [leftTable].[leftColumn] = [rightTable].[rightColumn],
      // so the SQL must mention the left table's column first.
      final onIndex = onLine.indexOf('ON');
      final leftIdx = onLine.indexOf('category', onIndex);
      final rightIdx = onLine.indexOf('ordert', onIndex);
      expect(leftIdx, greaterThan(-1), reason: onLine);
      expect(rightIdx, greaterThan(-1), reason: onLine);
      expect(leftIdx, lessThan(rightIdx),
          reason: 'ON clause is reversed: $onLine');
    });
  });

  group('insert form', () {
    testWidgets('clears the inputs after a successful insert', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.runAsync(() async {
        await Api.instance.query(
            'CREATE TABLE IF NOT EXISTS people2 (id INTEGER PRIMARY KEY, name TEXT);');
      });
      Navigation.instance.go(AppRoute.tableRoute('main', 'people2'));

      await tester.pumpWidget(
          host(TableView(db: 'main', table: 'people2', notice: Notice())));
      await settle(tester);
      await tester.tap(find.text('插入'));
      await settle(tester, rounds: 4);

      // The insert form is the only TextField on this tab besides the table's.
      final nameField = find.byType(TextField).last;
      await tester.enterText(nameField, '第一次');
      await settle(tester, rounds: 2);
      await tester.tap(find.text('插入').last);
      await settle(tester, rounds: 10);

      // The visible box must be empty again...
      final textField = tester.widget<TextField>(find.byType(TextField).last);
      expect(textField.controller?.text ?? '', isEmpty,
          reason: 'insert form kept the previous value');

      // ...and a second insert of the same typed value must work (it failed
      // with "field is empty" when the values and the visible text disagreed).
      await tester.enterText(find.byType(TextField).last, '第二次');
      await settle(tester, rounds: 2);
      await tester.tap(find.text('插入').last);
      await settle(tester, rounds: 10);

      final data = await tester.runAsync(
          () => Api.instance.data(
              'main', 'people2', <String, dynamic>{'page': 1, 'per_page': 50}));
      final rows = (data!['rows'] as List?) ?? const [];
      final names = rows
          .map((r) => (r as List).length > 1 ? r[1].toString() : '')
          .toList();
      expect(names, contains('第一次'));
      expect(names, contains('第二次'));

      // Let the success toast timers expire so the test does not leak them.
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('server status', () {
    // MySQL sends every counter as a string; PostgreSQL / SQLite send numbers.
    final mysqlPayload = <String, dynamic>{
      'version': '8.4.11',
      'uptime': '8991',
      'threads_connected': '2',
      'threads_running': '1',
      'queries': '1200',
      'connections': '42',
      'database_count': 6,
      'table_count': 12,
      'bytes_received': '1024',
      'bytes_sent': '2048',
    };

    test('formats string counters instead of throwing', () {
      // Regression: `as num?` on "8991" threw and blanked the whole page.
      final stats = serverStatusStats(mysqlPayload);
      expect(stats['版本'], '8.4.11');
      // Round34 P3-02: the label is compact so it cannot wrap inside the
      // 180x92 status card (the full 0d 2h 29m 51s was clipped there).
      expect(stats['运行时间'], '2h 29m');
      expect(stats['接收字节'], '1.00 KB');
      expect(stats['发送字节'], '2.00 KB');
      expect(stats['数据库数'], '6');
    });

    test('shortens the version card without changing the full tooltip value', () {
      expect(
        shortServerVersion(
            'PostgreSQL 17.11 on x86_64-apple-darwin24.6.0, compiled by ...'),
        'PostgreSQL 17.11',
      );
      expect(shortServerVersion('8.4.11'), '8.4.11');
      expect(shortServerVersion(''), '—');
    });

    test('accepts real numbers and missing values', () {
      final stats = serverStatusStats(<String, dynamic>{
        'uptime': 60,
        'bytes_received': null,
        'bytes_sent': 0,
      });
      expect(stats['运行时间'], '1m 0s');
      expect(stats['接收字节'], '—');
      expect(stats['发送字节'], '0 B');
    });
  });
}