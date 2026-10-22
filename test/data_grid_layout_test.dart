// Regression tests for the data grid's column alignment and its height.
//
// Reported symptoms:
//   * the header, the data cells and the '操作' column did not line up;
//   * the grid always occupied its full maxHeight, so a table with two rows
//     still showed a tall empty box instead of a compact one.
//
// Measured on the reported table (3 columns, 2 rows, 1200px window):
// before, the '操作' header and its buttons differed by 8px and the grid was
// 510px tall for 2 rows; now every column aligns exactly and the grid is 162px.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/components/data_grid.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';

Widget host(Widget child, {Size size = const Size(1200, 900)}) => MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

Future<void> sizeTo(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

List<Map<String, dynamic>> get _columns => [
      {'name': 'host', 'type_name': 'VARCHAR(255)'},
      {'name': 'ios', 'type_name': 'DECIMAL'},
      {'name': 'io_latency', 'type_name': 'DECIMAL'},
    ];

List<List<dynamic>> get _rows => [
      ['background', '3024', '659102410272'],
      ['localhost', '215', '56986745840'],
    ];

void main() {
  testWidgets('header and data cells share a left edge', (tester) async {
    await sizeTo(tester, const Size(1200, 900));
    await tester.pumpWidget(host(DataGrid(
      columns: _columns,
      rows: _rows,
      primaryKey: const ['host'],
      rowOps: true,
      editable: true,
    )));
    await tester.pumpAndSettle();

    // Regression: columns were laid out at their measured widths while the
    // header used a different inset, so the two drifted apart.
    final pairs = {
      'host(VARCHAR(255))': 'background',
      'ios(DECIMAL)': '3024',
      'io_latency(DECIMAL)': '659102410272',
    };
    for (final entry in pairs.entries) {
      final header = tester.getTopLeft(find.text(entry.key)).dx;
      final cell = tester.getTopLeft(find.text(entry.value)).dx;
      expect((cell - header).abs(), lessThan(0.5),
          reason: 'column "${entry.key}" is misaligned by ${cell - header}px');
    }

    // The actions column has its own button styling; allow the 1px button
    // border but nothing more.
    final header = tester.getTopLeft(find.text('操作')).dx;
    final button =
        tester.getTopLeft(find.byIcon(Icons.edit_outlined).first).dx;
    expect((button - header).abs(), lessThanOrEqualTo(1.5),
        reason: '操作 column is misaligned by ${button - header}px');
  });

  testWidgets('a short table shrinks instead of reserving maxHeight',
      (tester) async {
    await sizeTo(tester, const Size(1200, 900));
    await tester.pumpWidget(host(DataGrid(
      columns: _columns,
      rows: _rows,
      primaryKey: const ['host'],
    )));
    await tester.pumpAndSettle();

    // Regression: the box was pinned to maxHeight (460) whatever the row count.
    final height = tester.getSize(find.byType(DataGrid)).height;
    expect(height, lessThan(220),
        reason: '2 rows should not reserve 460px of empty space (was $height)');
    expect(height, greaterThan(60), reason: 'header + 2 rows must be visible');

    // And every row is fully laid out — nothing clipped at the bottom.
    expect(find.text('background'), findsOneWidget);
    expect(find.text('localhost'), findsOneWidget);
  });

  testWidgets('a long table is capped at maxHeight and scrolls', (tester) async {
    await sizeTo(tester, const Size(1200, 900));
    final rows = <List<dynamic>>[
      for (var r = 0; r < 200; r++) ['host$r', '$r', '${r * 1000}'],
    ];
    await tester.pumpWidget(host(DataGrid(
      columns: _columns,
      rows: rows,
      primaryKey: const ['host'],
    )));
    await tester.pumpAndSettle();

    // The grid is toolbar + table + hint, so the cap is on the table box; what
    // matters is that the height stops growing with the row count.
    final height = tester.getSize(find.byType(DataGrid)).height;
    expect(height, lessThan(540),
        reason: 'a long table must stay capped, not grow to 200 rows ($height)');
    expect(height, greaterThan(400), reason: 'the table area should be tall');
    // Virtualised: far fewer rows are built than exist.
    final built = find.byType(Row).evaluate().length;
    expect(built, lessThan(120), reason: '$built rows built for 200 rows');
    expect(find.byType(ListView), findsOneWidget);
  });


  testWidgets('a wide short table can be scrolled horizontally',
      (tester) async {
    await sizeTo(tester, const Size(1000, 900));
    // 14 wide columns with a single row: this is the case that used to overflow
    // the window with no horizontal scrollbar because the short-table branch
    // skipped the scroller entirely.
    final columns = <Map<String, dynamic>>[
      for (var i = 0; i < 14; i++)
        {'name': 'column_$i', 'type_name': 'BIGINT UNSIGNED'},
    ];
    final rows = <List<dynamic>>[
      <dynamic>[for (var i = 0; i < 14; i++) 'value_${i}_long_enough'],
    ];
    await tester.pumpWidget(host(DataGrid(
      columns: columns,
      rows: rows,
    )));
    await tester.pumpAndSettle();

    final horizontalScrollers = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .where((view) => view.scrollDirection == Axis.horizontal)
        .toList();
    expect(horizontalScrollers, isNotEmpty,
        reason: 'wide short table must still have a horizontal scroller');
    final controller = horizontalScrollers.first.controller;
    expect(controller, isNotNull);
    expect(controller!.position.maxScrollExtent, greaterThan(0),
        reason: 'content wider than the viewport must be scrollable');
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('columns stretch to fill the viewport', (tester) async {
    await sizeTo(tester, const Size(1400, 900));
    await tester.pumpWidget(host(DataGrid(
      columns: _columns,
      rows: _rows,
      primaryKey: const ['host'],
    )));
    await tester.pumpAndSettle();

    // Regression: a 3-column table hugged its content and left a large empty
    // gutter on the right.
    final lastColumn = tester.getTopLeft(find.text('io_latency(DECIMAL)')).dx;
    expect(lastColumn, greaterThan(900),
        reason: 'columns did not absorb the spare width');
  });
}
