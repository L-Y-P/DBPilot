// Round 85 / Plan A+: the result row view slices only the current page per
// build and does NOT reset the page while streaming appends to the same row
// list. These are the load-bearing behaviours of the A+ change; the pure
// batching logic is covered by row_batcher_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/result_table.dart';

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

Json resultWith(List<dynamic> rows, {int rowCount = 0}) => <String, dynamic>{
      'statement': 'SELECT n FROM t',
      'kind': 'rows',
      'row_count': rowCount == 0 ? rows.length : rowCount,
      'columns': <dynamic>[
        <String, dynamic>{'name': 'n', 'type_name': 'INT'},
      ],
      'rows': rows,
      'error': null,
      'truncated': false,
    };

void main() {
  testWidgets('a large result builds only the first page of rows',
      (tester) async {
    final rows = <dynamic>[
      for (var i = 0; i < 500; i++) <dynamic>['v$i'],
    ];
    await tester.pumpWidget(host(ResultTable(
      results: <Json>[resultWith(rows)],
      database: 'demo',
      notice: Notice(),
    )));
    await tester.pump();

    // Paged 50 at a time; page 1 of 10, showing the first row and only the
    // first page (row 50 belongs to page 2 and is never built). The grid is
    // itself virtualized, so off-screen rows of page 1 are not in the tree
    // either — this asserts the page bound, not the viewport.
    expect(find.text('第 1 / 10 页'), findsOneWidget);
    expect(find.text('显示 50 / 500 行'), findsOneWidget);
    expect(find.text('v0'), findsOneWidget);
    expect(find.text('v50'), findsNothing);
    expect(find.text('v499'), findsNothing);
  });

  testWidgets('appending to the same row list keeps the current page',
      (tester) async {
    // Streaming appends into the same mutable list reference the view holds.
    final rows = <dynamic>[
      for (var i = 0; i < 120; i++) <dynamic>['v$i'],
    ];
    final result = resultWith(rows);
    await tester.pumpWidget(host(ResultTable(
      results: <Json>[result],
      database: 'demo',
      notice: Notice(),
    )));
    await tester.pump();

    // Go to page 2.
    await tester.tap(find.byKey(const ValueKey('result-pager-0-next')));
    await tester.pump();
    expect(find.text('第 2 / 3 页'), findsOneWidget);
    expect(find.text('v50'), findsOneWidget);

    // Append more rows (as the batcher flush would) and rebuild.
    rows.addAll(<dynamic>[
      for (var i = 120; i < 200; i++) <dynamic>['v$i'],
    ]);
    result['row_count'] = rows.length;
    // Force a rebuild with the SAME list reference.
    await tester.pumpWidget(host(ResultTable(
      results: <Json>[result],
      database: 'demo',
      notice: Notice(),
    )));
    await tester.pump();

    // Still on page 2 (append did not reset the page), page count grew to 4.
    expect(find.text('第 2 / 4 页'), findsOneWidget);
    expect(find.text('v50'), findsOneWidget);
  });

  testWidgets('a new row list resets the page to the first page',
      (tester) async {
    await tester.pumpWidget(host(ResultTable(
      results: <Json>[
        resultWith(<dynamic>[
          for (var i = 0; i < 120; i++) <dynamic>['v$i'],
        ])
      ],
      database: 'demo',
      notice: Notice(),
    )));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('result-pager-0-next')));
    await tester.pump();
    expect(find.text('第 2 / 3 页'), findsOneWidget);

    // A brand new run: a fresh list reference.
    await tester.pumpWidget(host(ResultTable(
      results: <Json>[
        resultWith(<dynamic>[
          for (var i = 0; i < 120; i++) <dynamic>['z$i'],
        ])
      ],
      database: 'demo',
      notice: Notice(),
    )));
    await tester.pump();
    expect(find.text('第 1 / 3 页'), findsOneWidget);
    expect(find.text('z0'), findsOneWidget);
  });
}
