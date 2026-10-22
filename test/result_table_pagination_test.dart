// Pagination + result export for SQL-console / table-SQL-tab / history results.
//
// The result tables used to hand the whole row set to DataGrid and had no
// export. They now page 50 rows at a time (same TablePager as the data browser)
// and export through the table page's exchange-format writers.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/result_table.dart';

Json resultWith(int rowCount) => <String, dynamic>{
      'statement': 'SELECT n FROM t',
      'kind': 'rows',
      'row_count': rowCount,
      'columns': <dynamic>[
        <String, dynamic>{'name': 'n', 'type_name': 'INT'},
      ],
      'rows': <dynamic>[
        for (var i = 0; i < rowCount; i++) <dynamic>['v$i'],
      ],
      'error': null,
      'truncated': false,
    };

Widget host(Widget child) => MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  testWidgets('a row result is paged 50 at a time and keeps the export tools',
      (tester) async {
    await tester.pumpWidget(host(ResultTable(
      results: <Json>[resultWith(120)],
      database: 'demo',
      notice: Notice(),
    )));
    await tester.pump();

    expect(find.text('第 1 / 3 页'), findsOneWidget);
    expect(find.text('显示 50 / 120 行'), findsOneWidget);
    expect(find.byKey(const ValueKey('result-export-0')), findsOneWidget);
    // The three old export entries are merged into one menu: the grid's CSV /
    // JSON clipboard buttons must be gone, and only one export control remains.
    expect(find.text('导出 CSV'), findsNothing);
    expect(find.text('导出 JSON'), findsNothing);
    expect(find.text('导出结果'), findsOneWidget);
    expect(find.text('v0'), findsOneWidget);
    expect(find.text('v50'), findsNothing);

    // The menu lists the exchange formats used by the table page export.
    await tester.tap(find.byKey(const ValueKey('result-export-0')));
    await tester.pumpAndSettle();
    expect(find.text('JSON'), findsOneWidget);
    expect(find.text('Excel'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10)); // close the menu
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('result-pager-0-next')));
    await tester.pump();
    expect(find.text('第 2 / 3 页'), findsOneWidget);
    expect(find.text('v50'), findsOneWidget);
    expect(find.text('v0'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('result-pager-0-next')));
    await tester.pump();
    expect(find.text('第 3 / 3 页'), findsOneWidget);
    expect(find.text('显示 20 / 120 行'), findsOneWidget);
  });

  testWidgets('result export is disabled when no database context is known',
      (tester) async {
    await tester.pumpWidget(host(ResultTable(
      results: <Json>[resultWith(3)],
      notice: Notice(),
    )));
    await tester.pump();
    final button = tester.widget<PopupMenuButton<String>>(
        find.byKey(const ValueKey('result-export-0')));
    expect(button.enabled, isFalse);
  });
}
