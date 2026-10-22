// Round 24: GridTable virtualisation for long tables.
//
// GridTable used to build one [Table] with every row, so a long list (the
// database table list, users, processes) inflated every cell on every parent
// rebuild. Above [GridTable.virtualizeAfter] rows it now renders a pinned header
// plus one ListView item per row; the column widths are measured once from a
// sample of rows so the columns stay aligned.
//
// Short tables keep the original single-Table rendering, which these tests also
// pin (the change must not alter them).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

List<TableRow> rows(int count, {String prefix = 'row'}) => [
      for (var r = 0; r < count; r++)
        TableRow(children: [
          Text('$prefix$r-a'),
          Text('$prefix$r-b'),
          Text('$prefix$r-c'),
        ]),
    ];

Finder textFinder(String value) => find.byWidgetPredicate(
    (widget) => widget is Text && widget.data == value);

void main() {
  testWidgets('a short table keeps the eager single-table rendering',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(GridTable(
      headers: const [Text('A'), Text('B'), Text('C')],
      rows: rows(20),
    )));
    await tester.pump();
    await tester.pump();

    // Every row is built, and there is no inner ListView.
    expect(textFinder('row0-a').evaluate(), isNotEmpty);
    expect(textFinder('row19-a').evaluate(), isNotEmpty);
    expect(find.byType(ListView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long table builds only the rows on screen', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(GridTable(
      headers: const [Text('A'), Text('B'), Text('C')],
      rows: rows(600),
    )));
    // Frame 1 measures the sample, frame 2 is the virtualised body.
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(textFinder('row0-a').evaluate(), isNotEmpty);
    // Far-away rows must not be built.
    expect(textFinder('row500-a').evaluate(), isEmpty);
    expect(find.byType(ListView, skipOffstage: false), findsOneWidget);

    // The header is still there.
    expect(find.text('A'), findsWidgets);

    // Rows beyond the sample are reachable by scrolling the body.
    await tester.drag(
        find.byType(ListView, skipOffstage: false), const Offset(0, -3000));
    await tester.pumpAndSettle();
    final indices = tester
        .widgetList<Text>(find.byType(Text, skipOffstage: false))
        .map((text) => text.data ?? '')
        .where((value) => value.startsWith('row') && value.endsWith('-a'))
        .map((value) => int.tryParse(value.substring(3, value.length - 2)) ?? -1)
        .toList();
    expect(indices, isNotEmpty);
    expect(indices.reduce((a, b) => a > b ? a : b), greaterThan(20),
        reason: 'scrolling must reveal later rows, saw: ${indices.join(',')}');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the frozen widths keep header and rows aligned', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // A wide first column so the measured widths differ per column.
    List<TableRow> wideRows(int count) => [
          for (var r = 0; r < count; r++)
            TableRow(children: [
              Text('r$r-${'x' * 40}'),
              const Text('short'),
              const Text('mid'),
            ]),
        ];
    // Reference: the eager rendering of the same rows.
    await tester.pumpWidget(host(GridTable(
      headers: const [Text('A'), Text('B'), Text('C')],
      rows: wideRows(40),
      virtualizeAfter: 10000,
    )));
    await tester.pump();
    final eagerHeader = tester.getRect(find.text('A').first);
    final eagerCell = tester.getRect(
        find.byWidgetPredicate((widget) =>
            widget is Text && (widget.data ?? '').startsWith('r0-')).first);
    final eagerDelta = eagerHeader.left - eagerCell.left;

    // Virtualised rendering of the same table.
    await tester.pumpWidget(host(GridTable(
      headers: const [Text('A'), Text('B'), Text('C')],
      rows: wideRows(40),
    )));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    final virtualHeader = tester.getRect(find.text('A').first);
    final virtualCell = tester.getRect(
        find.byWidgetPredicate((widget) =>
            widget is Text && (widget.data ?? '').startsWith('r0-')).first);
    expect((virtualHeader.left - virtualCell.left - eagerDelta).abs(),
        lessThan(1.5),
        reason: 'the header/row offset must match the eager rendering');
    expect((virtualCell.left - eagerCell.left).abs(), lessThan(1.5),
        reason: 'columns must not shift when virtualised');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long table can be rebuilt cheaply and stays correct',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late StateSetter rebuild;
    var tick = 0;
    final sw = Stopwatch()..start();
    await tester.pumpWidget(host(StatefulBuilder(builder: (context, setState) {
      rebuild = setState;
      return GridTable(
        headers: const [Text('A'), Text('B'), Text('C')],
        rows: rows(600),
      );
    })));
    await tester.pump();
    await tester.pump();
    final initial = sw.elapsedMicroseconds;

    final rebuilds = <int>[];
    for (var i = 0; i < 4; i++) {
      final t = Stopwatch()..start();
      rebuild(() => tick++);
      await tester.pump();
      rebuilds.add(t.elapsedMicroseconds);
    }
    rebuilds.sort();
    // Ignore `print` lints: this is a benchmark-style assertion in a test file.
    debugPrint('GRIDTABLE_INITIAL_US=$initial REBUILD_US=${rebuilds[rebuilds.length ~/ 2]}');
    expect(tick, 4);
    expect(textFinder('row0-a').evaluate(), isNotEmpty);
    expect(tester.takeException(), isNull);
  });
}
