// Structure-sync result paging.
//
// 5000 comparison rows used to be built as 5000 TableRows on every rebuild
// (and the execution log built one AlertBox per statement). Both are now
// paged 50 at a time with the same TablePager as the data browser, so the
// first frame only builds the current page.

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/sync_view.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

/// One comparison row shaped like the Rust schema_diff payload.
Json syncTable(int index, {String warning = ''}) => <String, dynamic>{
  'name': 't_${index.toString().padLeft(4, '0')}',
  'status': index.isEven ? 'missing' : 'differs',
  'columns_added': 1,
  'columns_changed': 0,
  'columns_dropped': 0,
  'indexes_added': 0,
  'indexes_dropped': 0,
  'statements': <String>['ALTER TABLE `t_$index` ADD COLUMN `c` INT'],
  'warnings': warning.isEmpty ? <String>[] : <String>[warning],
};

Json syncResult(int index) => <String, dynamic>{
  'statement': 'ALTER TABLE t_$index ADD COLUMN c INT',
  'error': index % 10 == 0 ? 'boom-$index' : null,
};

/// Tap a pager button that may sit below the fold inside the page scroll.
Future<void> tapPager(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Widget host(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: buildAppTheme(),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets('5000 comparison rows build only the first page', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final tables = [for (var i = 0; i < 5000; i++) syncTable(i)];
    await tester.pumpWidget(host(SyncResultTable(tables: tables)));
    await tester.pumpAndSettle();

    // Only one page of rows reaches GridTable: the 5000-row eager build is gone.
    final grid = tester.widget<GridTable>(find.byType(GridTable));
    expect(grid.rows.length, 50);
    expect(find.text('t_0000'), findsOneWidget);
    expect(find.text('t_0050'), findsNothing);
    expect(find.byType(Pill), findsNWidgets(50));

    // Total count / page count stay visible for a large schema.
    expect(find.text('第 1 / 100 页'), findsOneWidget);
    expect(find.text('显示 50 / 5000 张表'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sync-tables-pager-next')),
      findsOneWidget,
    );
  });

  testWidgets('comparison pager switches page and keeps the row columns', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final tables = [
      for (var i = 0; i < 120; i++)
        syncTable(i, warning: i == 0 ? '外键不会同步' : ''),
    ];
    await tester.pumpWidget(host(SyncResultTable(tables: tables)));
    await tester.pumpAndSettle();

    // Status pill / statements / warnings columns still render for each row.
    expect(find.text(t('sync_missing')), findsWidgets);
    expect(find.text('外键不会同步'), findsOneWidget);
    expect(find.byType(SelectableText), findsWidgets);
    expect(find.text('第 1 / 3 页'), findsOneWidget);

    await tapPager(tester, 'sync-tables-pager-next');
    expect(find.text('第 2 / 3 页'), findsOneWidget);
    expect(find.text('t_0000'), findsNothing);
    expect(find.text('t_0050'), findsOneWidget);
    expect(tester.widget<GridTable>(find.byType(GridTable)).rows.length, 50);

    await tapPager(tester, 'sync-tables-pager-next');
    expect(find.text('第 3 / 3 页'), findsOneWidget);
    expect(find.text('显示 20 / 120 张表'), findsOneWidget);
    expect(find.text('t_0100'), findsOneWidget);
    expect(tester.widget<GridTable>(find.byType(GridTable)).rows.length, 20);
  });

  testWidgets('a new comparison resets the table to page 1', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      host(
        SyncResultTable(tables: [for (var i = 0; i < 120; i++) syncTable(i)]),
      ),
    );
    await tester.pumpAndSettle();
    await tapPager(tester, 'sync-tables-pager-next');
    expect(find.text('第 2 / 3 页'), findsOneWidget);

    // Fresh Rust payload -> new list instance, page must go back to 1.
    await tester.pumpWidget(
      host(
        SyncResultTable(
          tables: [for (var i = 0; i < 120; i++) syncTable(i + 1000)],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('第 1 / 3 页'), findsOneWidget);
    expect(find.text('t_1000'), findsOneWidget);
  });

  testWidgets('execution log builds one page of 50 AlertBoxes', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final results = [for (var i = 0; i < 120; i++) syncResult(i)];
    await tester.pumpWidget(host(SyncRunResults(results: results)));
    await tester.pumpAndSettle();

    expect(find.byType(AlertBox), findsNWidgets(50));
    expect(find.textContaining('ALTER TABLE t_0 ADD COLUMN c INT'), findsOneWidget);
    expect(find.textContaining('ALTER TABLE t_50 ADD COLUMN c INT'), findsNothing);
    expect(find.text('第 1 / 3 页'), findsOneWidget);
    expect(find.text('显示 50 / 120 条'), findsOneWidget);
    // Errors keep the error tone and message.
    expect(find.textContaining('boom-0'), findsOneWidget);

    await tapPager(tester, 'sync-run-pager-next');
    expect(find.byType(AlertBox), findsNWidgets(50));
    expect(find.text('第 2 / 3 页'), findsOneWidget);
    expect(find.textContaining('ALTER TABLE t_50 ADD COLUMN c INT'), findsOneWidget);
    expect(find.textContaining('ALTER TABLE t_0 ADD COLUMN c INT'), findsNothing);
  });
}
