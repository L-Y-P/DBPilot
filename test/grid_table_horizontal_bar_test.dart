// Regression: a wide GridTable must keep its horizontal scrollbar at the
// viewport edge, not below the last row.
//
// The history page paginates 50 rows and was using the eager GridTable path:
// the horizontal Scrollbar wrapped a vertical scroller containing every row, so
// its thumb only appeared after scrolling to the bottom of the page. The
// pinned-header/virtual body wraps a fixed-height box instead.
//
// The database overview's 数据表 / 对象 cards use the *eager* path with a height
// cap (50 rows, maxHeight 360/300), so the eager path has to keep both thumbs in
// the viewport too: the horizontal one along the bottom edge, the vertical one
// along the right edge, whatever the scroll offset is.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

/// 900x700 logical pixels, device pixel ratio 1.
void setViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 700);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// A 600px-wide eager GridTable: [rowCount] rows x [columnCount] 220px columns.
///
/// [GridTable.virtualizeAfter] keeps its default (150), so 20 rows render
/// through the eager path — the one that painted the horizontal thumb below the
/// last row when a height cap was set.
Widget eagerGrid({
  required int rowCount,
  required int columnCount,
  double? maxHeight,
}) {
  return MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 600,
          child: GridTable(
            headers: <Widget>[
              for (var c = 0; c < columnCount; c++) Text('h$c'),
            ],
            rows: <TableRow>[
              for (var r = 0; r < rowCount; r++)
                TableRow(children: [
                  for (var c = 0; c < columnCount; c++)
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: Text('r$r c$c'),
                    ),
                ]),
            ],
            widths: <TableColumnWidth>[
              for (var c = 0; c < columnCount; c++)
                const FixedColumnWidth(220),
            ],
            maxHeight: maxHeight,
          ),
        ),
      ),
    ),
  );
}

/// The Scrollbar driving the scroll view of [axis].
///
/// Found by predicate rather than by widget identity: a pump can rebuild the
/// subtree after a scroll, and the bars are then new widget instances.
Finder barFinder(Axis axis) => find.byWidgetPredicate((widget) =>
    widget is Scrollbar &&
    widget.controller != null &&
    widget.controller!.hasClients &&
    widget.controller!.position.axis == axis);

ScrollController controllerOf(WidgetTester tester, Axis axis) =>
    tester.widget<Scrollbar>(barFinder(axis)).controller!;

void main() {
  testWidgets('horizontal scrollbar stays at the viewport bottom with many rows',
      (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final rows = <TableRow>[
      for (var i = 0; i < 60; i++)
        TableRow(children: [
          for (var c = 0; c < 4; c++) Padding(
              padding: const EdgeInsets.all(4), child: Text('r$i c$c')),
        ]),
    ];
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 600,
            child: GridTable(
              headers: const <Widget>[Text('a'), Text('b'), Text('c'), Text('d')],
              rows: rows,
              widths: const <TableColumnWidth>[
                FixedColumnWidth(220),
                FixedColumnWidth(220),
                FixedColumnWidth(220),
                FixedColumnWidth(220),
              ],
              maxHeight: 300,
              virtualizeAfter: 0,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final gridRect = tester.getRect(find.byType(GridTable));
    final bars = tester.widgetList<Scrollbar>(find.byType(Scrollbar));
    final horizontal = bars.firstWhere(
        (bar) => bar.controller?.position.axisDirection == AxisDirection.right);
    final rect = tester.getRect(find.byWidget(horizontal));
    expect(horizontal.controller!.hasClients, isTrue);
    expect(horizontal.controller!.position.maxScrollExtent, greaterThan(0),
        reason: 'the 4 x 220px columns must overflow the 600px box');
    // The thumb is painted inside the 300px-tall grid box: its bottom is the
    // grid's bottom, never the bottom of the 60-row content.
    expect(rect.bottom, lessThanOrEqualTo(gridRect.top + 301));
    expect(rect.bottom, greaterThan(gridRect.top + 250));
  });

  testWidgets(
      'eager path: the horizontal thumb is at the viewport bottom, not below the rows',
      (tester) async {
    setViewport(tester);
    await tester.pumpWidget(
        eagerGrid(rowCount: 20, columnCount: 8, maxHeight: 300));
    await tester.pumpAndSettle();

    final gridRect = tester.getRect(find.byType(GridTable));
    final horizontal = controllerOf(tester, Axis.horizontal);
    final vertical = controllerOf(tester, Axis.vertical);

    // 8 x 220px columns and 20 rows under a 300px cap: both axes really
    // overflow, so the assertions below are about the reported case.
    expect(gridRect.height, 300);
    expect(horizontal.position.maxScrollExtent, greaterThan(0));
    expect(vertical.position.maxScrollExtent, greaterThan(0));

    // Bottom of the 20-row content, i.e. where the thumb used to be painted.
    final contentBottom = gridRect.top +
        vertical.position.viewportDimension +
        vertical.position.maxScrollExtent;
    final barRect = tester.getRect(barFinder(Axis.horizontal));
    // The Scrollbar's box is the viewport, so the thumb is painted along the
    // grid's bottom edge...
    expect(barRect.bottom, closeTo(gridRect.bottom, 0.01));
    // ...and nowhere near the bottom of the scrolled content.
    expect(barRect.bottom, lessThan(contentBottom - 20),
        reason: 'the horizontal thumb must not wait for the last row');
    expect(barRect.bottom, lessThan(gridRect.top + 400),
        reason: 'the 20-row content is ~570px tall; the thumb must not be there');

    // The vertical thumb keeps its own viewport position: its box is the visible
    // width, not the 1760px table width.
    expect(tester.getRect(barFinder(Axis.vertical)).right,
        closeTo(gridRect.right, 0.01));
  });

  testWidgets(
      'eager path: scrolling to the last row does not move the horizontal bar',
      (tester) async {
    setViewport(tester);
    await tester.pumpWidget(
        eagerGrid(rowCount: 20, columnCount: 8, maxHeight: 300));
    await tester.pumpAndSettle();

    final horizontalRectBefore = tester.getRect(barFinder(Axis.horizontal));
    final verticalRectBefore = tester.getRect(barFinder(Axis.vertical));
    final vertical = controllerOf(tester, Axis.vertical);
    expect(vertical.offset, 0);

    vertical.jumpTo(vertical.position.maxScrollExtent);
    await tester.pumpAndSettle();

    expect(vertical.offset, greaterThan(0), reason: 'the rows did scroll');
    expect(tester.getRect(barFinder(Axis.horizontal)), horizontalRectBefore,
        reason: 'the horizontal thumb belongs to the viewport, not the content');
    expect(tester.getRect(barFinder(Axis.vertical)), verticalRectBefore);
  });

  testWidgets('eager path: the horizontal bar is visible and still draggable',
      (tester) async {
    setViewport(tester);
    await tester.pumpWidget(
        eagerGrid(rowCount: 20, columnCount: 8, maxHeight: 300));
    await tester.pumpAndSettle();

    final horizontal = controllerOf(tester, Axis.horizontal);
    final vertical = controllerOf(tester, Axis.vertical);
    expect(horizontal.offset, 0);

    // The thumb itself drags: it is laid out at the bottom edge of the viewport,
    // which is where the pointer can reach it without scrolling the rows first.
    final barRect = tester.getRect(barFinder(Axis.horizontal));
    await tester.dragFrom(
        Offset(barRect.left + 20, barRect.bottom - 4), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(horizontal.offset, greaterThan(0),
        reason: 'dragging the visible thumb must scroll the columns');
    expect(vertical.offset, 0, reason: 'a sideways drag must not scroll rows');

    // And a sideways drag on the grid content keeps working too.
    final afterThumbDrag = horizontal.offset;
    await tester.drag(find.byType(GridTable), const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(horizontal.offset, greaterThan(afterThumbDrag));
    expect(vertical.offset, 0);
  });

  testWidgets('eager path: a height cap does not pad a short table',
      (tester) async {
    setViewport(tester);
    await tester.pumpWidget(
        eagerGrid(rowCount: 2, columnCount: 4, maxHeight: 300));
    await tester.pumpAndSettle();

    final gridRect = tester.getRect(find.byType(GridTable));
    // The cap is a maximum, not a fixed height: a two-row grid keeps hugging its
    // rows, so the database overview's 数据表 card does not turn into a 360px
    // empty box when the database has one table.
    expect(gridRect.height, lessThan(300));
    expect(controllerOf(tester, Axis.vertical).position.maxScrollExtent, 0);
    // The horizontal bar is still at the bottom of the (short) viewport.
    expect(tester.getRect(barFinder(Axis.horizontal)).bottom,
        closeTo(gridRect.bottom, 0.01));
  });

  testWidgets('eager path without a height cap keeps the short-table layout',
      (tester) async {
    setViewport(tester);
    await tester.pumpWidget(
        eagerGrid(rowCount: 3, columnCount: 4, maxHeight: null));
    await tester.pumpAndSettle();

    final gridRect = tester.getRect(find.byType(GridTable));
    // No vertical viewport is introduced by the uncapped branch.
    expect(find.byType(Scrollbar), findsOneWidget);
    final horizontal = controllerOf(tester, Axis.horizontal);
    expect(horizontal.position.maxScrollExtent, greaterThan(0));

    // A short table is not padded out to a height cap...
    expect(gridRect.height, lessThan(200));
    // ...and its horizontal thumb sits at the bottom of its (short) content,
    // which is the same edge as the viewport here: pre-existing behaviour.
    expect(tester.getRect(barFinder(Axis.horizontal)).bottom,
        closeTo(gridRect.bottom, 0.01));
  });
}
