// P2-05 / P2-06 (round 34): the collapsed result list must stay bounded.
//
// Round 30 folded each card of a whole-script run but still built one folded
// card per result: the PG pagila import (533 statements) produced a widget tree
// (and an accessibility tree past 2000 elements) with hundreds of cards, which
// made snapshot/read-back slow and contributed to the 2.10 GB peak frame
// (P2-06). The list now:
//
//  * builds one bounded batch of folded cards (ResultTable.collapsedCardBatch),
//  * pages the rest in with a "show more" control,
//  * offers a "failures only" filter,
//  * and scopes "expand shown" to the cards actually built.
//
// These tests assert the bound itself, not a timing, so they are deterministic.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/components/data_grid.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/result_table.dart';

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// Taps a built control after scrolling it into view.
///
/// The folded list is taller than the 800x600 test viewport (that is the point
/// of the bound), so a bare `tester.tap` on the summary bar or the "show more"
/// button would miss the hit test and silently do nothing.
Future<void> tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// How many folded cards the current widget tree holds.
int builtCards(WidgetTester tester) => tester
    .widgetList(find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('result-card-toggle-');
    }))
    .length;

Map<String, dynamic> rowResult(int i) => {
      'statement': 'SELECT $i;',
      'kind': 'rows',
      'row_count': 1,
      'truncated': false,
      'columns': [
        {'name': 'x', 'type_name': 'INTEGER'},
      ],
      'rows': [
        [i],
      ],
      'error': null,
      'last_insert_id': 0,
    };

Map<String, dynamic> errorResult(int i) => {
      'statement': 'SELECT * FROM missing_$i;',
      'kind': 'error',
      'row_count': 0,
      'truncated': false,
      'columns': const <Map<String, dynamic>>[],
      'rows': const <List<dynamic>>[],
      'error': 'relation "missing_$i" does not exist',
      'last_insert_id': 0,
    };

/// 533 statements like the pagila import, failing at 5, 100 and 300.
List<Map<String, dynamic>> pagila() => List.generate(
      533,
      (i) => (i == 5 || i == 100 || i == 300) ? errorResult(i) : rowResult(i),
    );

void main() {
  testWidgets('533 results build exactly one batch of folded cards',
      (tester) async {
    final notice = Notice();
    addTearDown(notice.dispose);

    await tester.pumpWidget(host(ResultTable(results: pagila(), notice: notice)));
    await tester.pumpAndSettle();

    expect(find.textContaining('共 533 条结果'), findsOneWidget);
    expect(find.textContaining('失败 3 条'), findsOneWidget);

    // The bound: at most one batch of cards, whatever the result count.
    expect(builtCards(tester), ResultTable.collapsedCardBatch);
    // Failures outside the batch are not in the tree (no AX nodes).
    expect(find.byKey(const ValueKey('result-card-toggle-100')), findsNothing);
    expect(find.byKey(const ValueKey('result-card-toggle-300')), findsNothing);
    // Default-expanded #0 builds one grid; the folded cards build none.
    expect(find.byType(DataGrid), findsNWidgets(1));
    expect(find.textContaining('显示更多（还有 473 条）'), findsOneWidget);

    expect(tester.allElements.length, lessThan(4000),
        reason: 'one folded batch must stay under a bounded element count');
  });

  testWidgets('the card bound does not grow with the script size',
      (tester) async {
    final notice = Notice();
    addTearDown(notice.dispose);

    await tester.pumpWidget(host(ResultTable(
      results: List.generate(533, rowResult),
      notice: notice,
    )));
    await tester.pumpAndSettle();
    final small = tester.allElements.length;
    expect(builtCards(tester), ResultTable.collapsedCardBatch);

    await tester.pumpWidget(host(ResultTable(
      results: List.generate(2000, rowResult),
      notice: notice,
    )));
    await tester.pumpAndSettle();
    final large = tester.allElements.length;
    expect(builtCards(tester), ResultTable.collapsedCardBatch);

    // ~4x the results, same built tree: the widget / accessibility element
    // count is bounded by the batch, not by the script (P2-05).
    expect(large, small);
  });

  testWidgets('show more reveals one more batch at a time', (tester) async {
    final notice = Notice();
    addTearDown(notice.dispose);

    await tester.pumpWidget(host(ResultTable(results: pagila(), notice: notice)));
    await tester.pumpAndSettle();
    expect(builtCards(tester), ResultTable.collapsedCardBatch);

    await tapKey(tester, 'results-show-more');
    expect(builtCards(tester), ResultTable.collapsedCardBatch * 2);
    expect(find.byKey(const ValueKey('result-card-toggle-120')), findsNothing);
    expect(find.textContaining('显示更多（还有 413 条）'), findsOneWidget);

    await tapKey(tester, 'results-show-more');
    expect(builtCards(tester), ResultTable.collapsedCardBatch * 3);
    expect(find.byKey(const ValueKey('result-card-toggle-180')), findsNothing);

    // 533 = 8 full batches + 53, so the last batch ends the list.
    for (var i = 0; i < 5; i++) {
      await tapKey(tester, 'results-show-more');
    }
    expect(builtCards(tester), 480);
    expect(find.textContaining('显示更多（还有 53 条）'), findsOneWidget);
    await tapKey(tester, 'results-show-more');
    expect(builtCards(tester), 533);
    expect(find.byKey(const ValueKey('results-show-more')), findsNothing);
  });

  testWidgets('failures-only lists just the failed results', (tester) async {
    final notice = Notice();
    addTearDown(notice.dispose);

    await tester.pumpWidget(host(ResultTable(results: pagila(), notice: notice)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('result-card-toggle-100')), findsNothing);

    await tapKey(tester, 'results-only-failures');

    // Only the three failures are listed — no batching needed, no other card,
    // and no "show more" (there is nothing left to reveal).
    expect(builtCards(tester), 3);
    expect(find.byKey(const ValueKey('result-card-toggle-5')), findsOneWidget);
    expect(find.byKey(const ValueKey('result-card-toggle-100')), findsOneWidget);
    expect(find.byKey(const ValueKey('result-card-toggle-300')), findsOneWidget);
    expect(find.byKey(const ValueKey('result-card-toggle-6')), findsNothing);
    expect(find.byKey(const ValueKey('results-show-more')), findsNothing);

    // Toggling back restores the first batch.
    await tapKey(tester, 'results-only-failures');
    expect(builtCards(tester), ResultTable.collapsedCardBatch);
  });

  testWidgets('failures-only on a clean script shows the empty hint',
      (tester) async {
    final notice = Notice();
    addTearDown(notice.dispose);

    await tester.pumpWidget(host(ResultTable(
      results: List.generate(533, rowResult),
      notice: notice,
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('失败 0 条'), findsOneWidget);

    await tapKey(tester, 'results-only-failures');
    expect(builtCards(tester), 0);
    expect(find.byKey(const ValueKey('results-empty-filter')), findsOneWidget);
    expect(find.byKey(const ValueKey('results-show-more')), findsNothing);
  });

  testWidgets('expand shown stays bounded to the built batch', (tester) async {
    final notice = Notice();
    addTearDown(notice.dispose);

    await tester.pumpWidget(host(ResultTable(
      results: List.generate(533, rowResult),
      notice: notice,
    )));
    await tester.pumpAndSettle();

    await tapKey(tester, 'results-expand-all');

    // 60 built cards -> 60 grids. The 473 cards still hidden stay unbuilt, so
    // "expand shown" can never turn into the old 533-grid frame.
    expect(
        find.byType(DataGrid), findsNWidgets(ResultTable.collapsedCardBatch));
    expect(find.byKey(const ValueKey('result-card-toggle-60')), findsNothing);

    // One more batch builds at most one more batch of grids on the next tap.
    await tapKey(tester, 'results-show-more');
    await tapKey(tester, 'results-expand-all');
    expect(find.byType(DataGrid), findsNWidgets(ResultTable.collapsedCardBatch * 2));

    await tapKey(tester, 'results-collapse-all');
    expect(find.byType(DataGrid), findsNothing);
  });
}
