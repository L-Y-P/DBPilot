//! S-08: the SQL console must tell the user when a result was cut off.
//!
//! The backend caps console results so a `SELECT *` over a million-row table
//! cannot freeze the UI. The UI has to make the truncation obvious, otherwise
//! the user would believe they are looking at every row.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/result_table.dart';

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

List<Map<String, dynamic>> columns() => [
      {'name': 'x', 'type_name': 'INTEGER'},
    ];

void main() {
  testWidgets('truncated result warns that it was cut off', (tester) async {
    final notice = Notice();
    addTearDown(notice.dispose);
    await tester.pumpWidget(host(ResultTable(
      results: [
        {
          'statement': 'SELECT * FROM big ORDER BY x',
          'kind': 'rows',
          'row_count': 50000,
          'truncated': true,
          'columns': columns(),
          'rows': [
            [1],
            [2],
          ],
          'error': null,
          'last_insert_id': 0,
        },
      ],
      notice: notice,
      rowLimit: 50000,
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('结果超出单次上限 50,000 行'), findsOneWidget);
    // The grid/toolbar now shows the page's row count; the truncation banner
    // above is the authoritative "you are not seeing every row" signal.
    expect(find.text('本页 2 行'), findsOneWidget);
  });

  testWidgets('a complete result has no truncation warning', (tester) async {
    final notice = Notice();
    addTearDown(notice.dispose);
    await tester.pumpWidget(host(ResultTable(
      results: [
        {
          'statement': 'SELECT * FROM small',
          'kind': 'rows',
          'row_count': 2,
          'truncated': false,
          'columns': columns(),
          'rows': [
            [1],
            [2],
          ],
          'error': null,
          'last_insert_id': 0,
        },
      ],
      notice: notice,
      rowLimit: 50000,
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('结果超出单次上限'), findsNothing);
    expect(find.text('本页 2 行'), findsOneWidget);
  });
}
