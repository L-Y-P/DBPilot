// Round 23: DataGrid column virtualisation.
//
// The main result grid used to build **every** column in **every** visible row:
// a 40-column result measured 1200 cells and a ~400ms parent rebuild (debug),
// because a self setState (selecting a row, toggling the filter row, toggling a
// column) or a parent rebuild re-inflated the whole visible window. Only the
// columns that intersect the viewport are built now, with equal-width spacers
// standing in for the rest so the header, the data cells, the alignment and the
// horizontal scroll range are unchanged.
//
// These tests are structural: they count built cells and compare positions
// rather than assert wall-clock times.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/components/data_grid.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(body: child),
    );

List<Map<String, dynamic>> columns(int count) => [
      for (var i = 0; i < count; i++)
        {'name': 'column_$i', 'type': 'text'},
    ];

List<List<dynamic>> rows(int rowCount, int columnCount) => [
      for (var r = 0; r < rowCount; r++)
        [for (var c = 0; c < columnCount; c++) 'r${r}c$c'],
    ];

Finder headerText(String name) => find.byWidgetPredicate(
    (widget) => widget is Text && widget.data == name);

void main() {
  testWidgets('only the columns on screen are built', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(SizedBox(
      width: 960,
      height: 500,
      child: DataGrid(columns: columns(40), rows: rows(60, 40)),
    )));
    await tester.pump();

    final headers = tester
        .widgetList<Text>(find.byType(Text, skipOffstage: false))
        .map((text) => text.data ?? '')
        .where((value) => value.startsWith('column_'))
        .toList();
    // 40 columns x min 110px is far wider than the 960px viewport.
    expect(headers.length, lessThan(15),
        reason: 'off-screen columns must not be built: ${headers.join(',')}');
    expect(headers.first, 'column_0');

    // The full table width is still laid out, otherwise the horizontal
    // scrollbar would have nothing to scroll.
    final scroll = tester.widget<SingleChildScrollView>(find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal));
    expect(scroll.controller, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scrolling right builds the later columns and keeps alignment',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(SizedBox(
      width: 960,
      height: 500,
      child: DataGrid(columns: columns(40), rows: rows(10, 40)),
    )));
    await tester.pump();

    final horizontal = find.byWidgetPredicate((widget) =>
        widget is SingleChildScrollView &&
        widget.scrollDirection == Axis.horizontal);
    await tester.drag(horizontal, const Offset(-3000, 0));
    await tester.pumpAndSettle();

    final headers = tester
        .widgetList<Text>(find.byType(Text, skipOffstage: false))
        .map((text) => text.data ?? '')
        .where((value) => value.startsWith('column_'))
        .toList();
    expect(headers, isNotEmpty);
    expect(headers.contains('column_0'), isFalse,
        reason: 'the first columns scrolled out of view');

    // Header and data cells of one column must line up: compare the left edge
    // of a built header with the first data cell of that column.
    final name = headers.first;
    final headerRect = tester.getRect(headerText(name).first);
    final cellFinder = find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == 'r0c${name.split('_').last}');
    expect(cellFinder.evaluate(), isNotEmpty);
    final cellRect = tester.getRect(cellFinder.first);
    expect((headerRect.left - cellRect.left).abs(), lessThan(1.5),
        reason: 'header and data must stay aligned after virtualisation');
  });

  testWidgets('a new result re-measures the column widths', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Enough columns that the table is wider than the viewport, otherwise the
    // cells stretch to fill it and every column reports the same width.
    await tester.pumpWidget(host(SizedBox(
      width: 960,
      height: 500,
      child: DataGrid(columns: columns(20), rows: [
        [for (var c = 0; c < 20; c++) 'x'],
      ]),
    )));
    await tester.pump();
    final narrow = tester.getRect(headerText('column_0').first).width;

    // New rows with much wider values: the cached widths must be dropped.
    await tester.pumpWidget(host(SizedBox(
      width: 960,
      height: 500,
      child: DataGrid(columns: columns(20), rows: [
        [
          'a-very-long-value-that-needs-a-wide-column-indeed-yes',
          for (var c = 1; c < 20; c++) 'x',
        ],
      ]),
    )));
    await tester.pump();
    final wide = tester.getRect(headerText('column_0').first).width;
    expect(wide, greaterThan(narrow),
        reason: 'the width cache must follow a new result');
    expect(tester.takeException(), isNull);
  });
}
