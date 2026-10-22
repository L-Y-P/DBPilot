// Page math and pager behaviour shared by the paginated history/backup tables.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/paging.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

void main() {
  test('pageCountFor rounds up and keeps at least one page', () {
    expect(pageCountFor(0, 20), 1);
    expect(pageCountFor(1, 20), 1);
    expect(pageCountFor(20, 20), 1);
    expect(pageCountFor(21, 20), 2);
    expect(pageCountFor(101, 50), 3);
  });

  test('clampPage keeps a 1-based page inside the valid range', () {
    expect(clampPage(0, 101, 50), 1);
    expect(clampPage(2, 101, 50), 2);
    expect(clampPage(9, 101, 50), 3);
    expect(clampPage(3, 0, 50), 1);
  });

  test('pageSlice returns exactly one page and never overflows', () {
    final items = List<int>.generate(101, (i) => i);
    expect(pageSlice(items, 1, 50), items.sublist(0, 50));
    expect(pageSlice(items, 3, 50), items.sublist(100));
    expect(pageSlice(items, 99, 50), items.sublist(100));
    expect(pageSlice(<int>[], 1, 50), isEmpty);
  });

  testWidgets('TablePager shows bounds and emits the next page', (tester) async {
    var page = 1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => TablePager(
            page: page,
            pages: 3,
            total: 120,
            visible: page == 3 ? 20 : 50,
            keyPrefix: 't',
            onPage: (next) => setState(() => page = next),
          ),
        ),
      ),
    ));
    expect(find.text('第 1 / 3 页'), findsOneWidget);
    expect(find.text('显示 50 / 120 行'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('t-next')));
    await tester.pump();
    expect(page, 2);
    expect(find.text('第 2 / 3 页'), findsOneWidget);
  });
}
