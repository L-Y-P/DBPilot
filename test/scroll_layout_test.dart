// Regression tests for the scroll/overflow fixes on wide content.
//
// Reported symptoms:
//   * the vertical scrollbar in a data grid could not be dragged with the mouse;
//   * long values in code/pre blocks were clipped with no way to reach them, and
//     at the minimum window width the page could not be scrolled sideways.
//
// Cause: a Scrollbar without an explicit controller attaches to the
// PrimaryScrollController (the page) instead of the inner scroll view, so the
// thumb was painted but inert; and the pre/code blocks only scrolled vertically.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/components/data_grid.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

Widget host(Widget child) => MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('data grid scrollbars own their controllers', (tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final columns = <Map<String, dynamic>>[
      for (var c = 0; c < 6; c++) {'name': 'col$c', 'type_name': 'TEXT'},
    ];
    final rows = <List<dynamic>>[
      for (var r = 0; r < 40; r++)
        [for (var c = 0; c < 6; c++) 'v${r}_$c'],
    ];

    await tester.pumpWidget(host(SizedBox(
      height: 400,
      child: DataGrid(columns: columns, rows: rows, primaryKey: const ['col0']),
    )));
    await tester.pumpAndSettle();

    final bars = tester.widgetList<Scrollbar>(find.byType(Scrollbar)).toList();
    expect(bars.length, 2, reason: 'one bar per axis');
    for (final bar in bars) {
      // Regression: a null controller means the thumb attaches to the page and
      // cannot be dragged.
      expect(bar.controller, isNotNull,
          reason: 'scrollbar would attach to the PrimaryScrollController');
      expect(bar.controller!.hasClients, isTrue,
          reason: 'controller is not attached to the scroll view');
    }
    // Both axes are actually scrollable.
    final positions = bars
        .map((b) => b.controller!.position)
        .toList();
    expect(positions.any((p) => p.maxScrollExtent > 0), isTrue,
        reason: 'nothing to scroll');
  });

  testWidgets('data grid stays usable when it has no rows', (tester) async {
    await tester.pumpWidget(host(SizedBox(
      height: 200,
      child: DataGrid(
        columns: const [
          {'name': 'a', 'type_name': 'TEXT'},
        ],
        rows: const [],
      ),
    )));
    // Regression: the empty grid still built a vertical Scrollbar whose
    // controller had no ScrollPosition, which asserted while painting.
    await tester.pumpAndSettle();
    expect(find.text('无结果'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('CodeBlock scrolls horizontally for a long line', (tester) async {
    tester.view.physicalSize = const Size(600, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final longLine = 'SELECT ${'column_name, ' * 40}FROM t;';
    await tester.pumpWidget(host(Padding(
      padding: const EdgeInsets.all(8),
      child: CodeBlock(longLine, maxHeight: 200),
    )));
    await tester.pumpAndSettle();

    // Regression: only the vertical axis scrolled, so the tail of a long
    // statement was unreachable.
    final scrollers = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .toList();
    expect(scrollers.any((s) => s.scrollDirection == Axis.horizontal), isTrue,
        reason: 'long code has no horizontal scroller');
  });

  testWidgets('SqlEditor keeps a bounded width for a long statement',
      (tester) async {
    tester.view.physicalSize = const Size(600, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = TextEditingController(text: 'SELECT 1;');
    addTearDown(controller.dispose);

    await tester.pumpWidget(host(Padding(
      padding: const EdgeInsets.all(8),
      child: SqlEditor(controller: controller, lines: 6),
    )));
    await tester.pumpAndSettle();

    // Regression: a TextField inside an unbounded horizontal scroller throws
    // "An InputDecorator ... cannot have an unbounded width".
    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.getSize(find.byType(TextField)).width.isFinite, isTrue);
  });
}
