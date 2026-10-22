// Regression tests for the virtualised result preview.
//
// Round 22 changed `BuilderPreviewTable` to build only the columns that
// intersect the viewport (a 40-column page used to inflate ~950 cells in every
// visible row). These tests pin the behaviour the virtualisation must not
// break: the header still scrolls with the data, a narrowed table still shows
// its columns, and a cell that is clipped still carries the full value.
//
// Round 27 (reported: "结果预览无法左右拖动"): a wide result had no scrollbar
// to grab and desktop scroll views ignore mouse drags by default, so the
// clipped right-hand columns were unreachable with a mouse. The tests at the
// bottom pin the horizontal scrollbar, its thumb drag, and mouse-drag
// scrolling.

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/builder/builder_editors.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(body: child),
    );

List<BuilderPreviewColumn> columns(int count) => [
      for (var i = 0; i < count; i++)
        BuilderPreviewColumn('column_$i', 'TEXT'),
    ];

List<List<Object?>> rows(int rowCount, int columnCount) => [
      for (var r = 0; r < rowCount; r++)
        [for (var c = 0; c < columnCount; c++) 'r${r}c$c'],
    ];

/// The preview's horizontal scroller (there is exactly one when it overflows).
Finder horizontalScroller() => find.byWidgetPredicate(
      (widget) =>
          widget is SingleChildScrollView &&
          widget.scrollDirection == Axis.horizontal,
      skipOffstage: false,
    );

ScrollController controllerOf(WidgetTester tester) =>
    tester.widget<SingleChildScrollView>(horizontalScroller()).controller!;

/// The scrollbar that owns [controller] — the vertical [ListView] gets its own
/// (framework-supplied) bar on desktop platforms, so match by controller.
List<Scrollbar> barsFor(WidgetTester tester, ScrollController controller) =>
    tester
        .widgetList<Scrollbar>(find.byType(Scrollbar, skipOffstage: false))
        .where((bar) => identical(bar.controller, controller))
        .toList();

void main() {
  testWidgets('only the visible columns are built', (tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(SizedBox(
      width: 880,
      height: 400,
      child: BuilderPreviewTable(
        columns: columns(40),
        rows: rows(20, 40),
      ),
    )));
    await tester.pump();

    // 40 columns x 140px = 5600px of content in an ~880px viewport.
    final headerTexts = tester
        .widgetList<Text>(find.byType(Text, skipOffstage: false))
        .map((text) => text.data ?? '')
        .where((value) => value.startsWith('column_'))
        .toList();
    expect(headerTexts.length, lessThan(15),
        reason: 'far-away columns must not be built');
    expect(headerTexts, contains('column_0'));
    // The row width is preserved, so the scroll range is unchanged.
    final scrollable = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView, skipOffstage: false));
    expect(scrollable.scrollDirection, Axis.horizontal);
  });

  testWidgets('scrolling right brings later columns in', (tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(SizedBox(
      width: 880,
      height: 400,
      child: BuilderPreviewTable(columns: columns(40), rows: rows(20, 40)),
    )));
    await tester.pump();
    final scrollable = find.byType(SingleChildScrollView, skipOffstage: false);
    await tester.drag(scrollable, const Offset(-2800, 0));
    await tester.pumpAndSettle();

    final headerTexts = tester
        .widgetList<Text>(find.byType(Text, skipOffstage: false))
        .map((text) => text.data ?? '')
        .where((value) => value.startsWith('column_'))
        .toList();
    expect(headerTexts, isNotEmpty);
    // Half way through the table, so early columns are gone and later ones came in.
    expect(headerTexts.any((name) => name == 'column_0'), isFalse);
    expect(headerTexts.length, lessThan(15));
  });

  testWidgets('a re-run with fewer columns still shows them', (tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final wide = columns(40);
    await tester.pumpWidget(host(SizedBox(
      width: 880,
      height: 400,
      child: BuilderPreviewTable(columns: wide, rows: rows(20, 40)),
    )));
    await tester.pump();
    await tester.drag(
        find.byType(SingleChildScrollView, skipOffstage: false),
        const Offset(-4000, 0));
    await tester.pumpAndSettle();

    // New result: a narrow table. A stale horizontal offset must not leave it
    // empty.
    final narrow = columns(2);
    await tester.pumpWidget(host(SizedBox(
      width: 880,
      height: 400,
      child: BuilderPreviewTable(columns: narrow, rows: rows(5, 2)),
    )));
    await tester.pump();
    final headerTexts = tester
        .widgetList<Text>(find.byType(Text, skipOffstage: false))
        .map((text) => text.data ?? '')
        .where((value) => value.startsWith('column_'))
        .toList();
    expect(headerTexts, contains('column_0'));
    expect(headerTexts, contains('column_1'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a clipped cell still exposes the full value on hover',
      (tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final long = 'a-value-that-is-much-wider-than-one-column-' * 3;
    await tester.pumpWidget(host(SizedBox(
      width: 880,
      height: 400,
      child: BuilderPreviewTable(
        columns: columns(4),
        rows: [
          [long, 'short', 'x', 'y'],
        ],
      ),
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final tips = tester
        .widgetList<Tooltip>(find.byType(Tooltip, skipOffstage: false))
        .where((tooltip) => (tooltip.message ?? '').contains('a-value-that-is-much-wider'))
        .toList();
    expect(tips, isNotEmpty, reason: 'the clipped cell needs a hover read-out');
    expect(tips.first.constraints, isNotNull);
  });

  testWidgets('a wide preview has a visible, draggable scrollbar',
      (tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(SizedBox(
      width: 880,
      height: 400,
      child: BuilderPreviewTable(columns: columns(12), rows: rows(20, 12)),
    )));
    await tester.pumpAndSettle();

    // Reported symptom (round 27): a preview wider than its card had no
    // scrollbar at all, so the right-hand columns could not be dragged into
    // view with a mouse.
    final controller = controllerOf(tester);
    expect(controller.position.maxScrollExtent, greaterThan(0));

    final bars = barsFor(tester, controller);
    expect(bars, hasLength(1), reason: 'the preview needs one horizontal bar');
    final bar = bars.single;
    expect(bar.thumbVisibility, isTrue);
    expect(bar.controller, isNotNull,
        reason: 'a null controller attaches to the page and cannot be dragged');
    expect(controller.hasClients, isTrue);

    // Dragging the thumb left must scroll the content right.
    final barRect = tester.getRect(find.byWidget(bar));
    await tester.dragFrom(
      Offset(barRect.left + 30, barRect.bottom - 6),
      const Offset(-200, 0),
    );
    await tester.pumpAndSettle();
    expect(controller.position.pixels, greaterThan(0),
        reason: 'the scrollbar thumb must actually move the table');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a mouse drag scrolls the preview sideways', (tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(SizedBox(
      width: 880,
      height: 400,
      child: BuilderPreviewTable(columns: columns(12), rows: rows(20, 12)),
    )));
    await tester.pumpAndSettle();

    final controller = controllerOf(tester);
    expect(controller.offset, 0);

    // Desktop scroll views ignore the mouse unless it is added to dragDevices;
    // before round 27 this drag moved the table by exactly 0px.
    await tester.drag(
      horizontalScroller(),
      const Offset(-300, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0),
        reason: 'a mouse drag must scroll the preview');

    // The user story: grab the table and pull it left until the last column
    // is visible.
    await tester.drag(
      horizontalScroller(),
      const Offset(-2000, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    final lastColumn = tester
        .widgetList<Text>(find.byType(Text, skipOffstage: false))
        .map((text) => text.data ?? '')
        .where((value) => value == 'column_11');
    expect(lastColumn, isNotEmpty,
        reason: 'the clipped last column must become reachable');
  });

  testWidgets('a narrow preview is not wrapped in a horizontal scroller',
      (tester) async {
    await tester.pumpWidget(host(SizedBox(
      width: 880,
      height: 400,
      child: BuilderPreviewTable(columns: columns(2), rows: rows(3, 2)),
    )));
    await tester.pumpAndSettle();

    // No overflow: no scroller, and (crucially) no Scrollbar whose controller
    // would have no ScrollPosition to paint.
    expect(horizontalScroller(), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
