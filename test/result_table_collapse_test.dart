// P8 (round 30) + P2-05 (round 34): a whole-script run must not build a
// DataGrid — or one widget card — per statement.
//
// The pagila import produced 533-575 result sets. Building all of them at once
// made the page take seconds and pushed the accessibility tree past 2000
// elements, which also slowed every automation pass. Past six results the table
// folds each card (statement, error and row count only) and builds its DataGrid
// on demand; round 34 additionally bounds how many folded cards exist at once
// (ResultTable.collapsedCardBatch) and pages them in with "show more".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/components/data_grid.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/result_table.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

List<Map<String, dynamic>> oneColumn() => [
      {'name': 'x', 'type_name': 'INTEGER'},
    ];

Map<String, dynamic> rowResult(int i) => {
      'statement': 'SELECT $i;',
      'kind': 'rows',
      'row_count': 1,
      'truncated': false,
      'columns': oneColumn(),
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

/// 575 statements, two of which failed (like the pagila import).
List<Map<String, dynamic>> manyResults() => List.generate(
      575,
      (i) => (i == 100 || i == 300) ? errorResult(i) : rowResult(i),
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

void main() {
  testWidgets('575 results start folded, building one bounded batch of cards',
      (tester) async {
    final notice = Notice();
    addTearDown(notice.dispose);

    await tester.pumpWidget(
        host(ResultTable(results: manyResults(), notice: notice)));
    await tester.pumpAndSettle();

    // Summary bar: the whole script's outcome at a glance.
    expect(find.byKey(const ValueKey('results-summary-bar')), findsOneWidget);
    expect(find.textContaining('共 575 条结果'), findsOneWidget);
    expect(find.textContaining('失败 2 条'), findsOneWidget);

    // P2-05: the bound. 575 results build one batch of folded cards, not 575,
    // and results outside the batch are not in the widget/AX tree at all.
    expect(builtCards(tester), ResultTable.collapsedCardBatch);
    expect(builtCards(tester),
        lessThanOrEqualTo(ResultTable.collapsedCardBatch));
    expect(find.byKey(const ValueKey('result-card-toggle-100')), findsNothing);

    // ...but only the default-expanded cards build a grid: #0, while the two
    // failures are error cards (no columns) that are expanded by default. Both
    // are outside the first batch, so just one grid exists.
    expect(find.byType(DataGrid), findsNWidgets(1));
    expect(
      find.descendant(
          of: find.byKey(const ValueKey('result-card-1')),
          matching: find.byType(DataGrid)),
      findsNothing,
      reason: 'a folded card must not build its grid',
    );
    // A folded card also uses the cheap plain preview: no CodeBlock and no
    // SelectableText (P2-05 requirement 2).
    expect(
      find.descendant(
          of: find.byKey(const ValueKey('result-card-1')),
          matching: find.byType(CodeBlock)),
      findsNothing,
      reason: 'a folded card must use the plain statement preview',
    );
    expect(
      find.descendant(
          of: find.byKey(const ValueKey('result-card-1')),
          matching: find.byType(SelectableText)),
      findsNothing,
      reason: 'a folded card must not build SelectableText',
    );
    // Card #0 (default expanded) shows the collapse icon; #1 shows expand.
    expect(
      find.descendant(
          of: find.byKey(const ValueKey('result-card-toggle-0')),
          matching: find.byIcon(Icons.expand_less)),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: find.byKey(const ValueKey('result-card-toggle-1')),
          matching: find.byIcon(Icons.expand_more)),
      findsOneWidget,
    );

    // The rest of the script is one batch away, with the remaining count shown.
    expect(find.textContaining('显示更多（还有 515 条）'), findsOneWidget);

    // "Expand shown" expands what is built (60 cards), never all 575 results.
    await tapKey(tester, 'results-expand-all');
    expect(
        find.byType(DataGrid), findsNWidgets(ResultTable.collapsedCardBatch));
    expect(find.byKey(const ValueKey('result-card-toggle-100')), findsNothing);

    // Collapsing everything folds every card again.
    await tapKey(tester, 'results-collapse-all');
    expect(find.byType(DataGrid), findsNothing);

    // Show more pages the list in batches, never all at once.
    await tapKey(tester, 'results-show-more');
    expect(builtCards(tester), ResultTable.collapsedCardBatch * 2);
    expect(find.textContaining('显示更多（还有 455 条）'), findsOneWidget);

    // A single card can still be toggled on its own.
    await tapKey(tester, 'result-card-toggle-2');
    expect(find.byType(DataGrid), findsNWidgets(1));
    expect(
      find.descendant(
          of: find.byKey(const ValueKey('result-card-2')),
          matching: find.byType(DataGrid)),
      findsOneWidget,
    );
  });

  testWidgets('six results keep the plain layout with no summary bar',
      (tester) async {
    final notice = Notice();
    addTearDown(notice.dispose);

    await tester.pumpWidget(host(ResultTable(
      results: List.generate(6, rowResult),
      notice: notice,
    )));
    await tester.pumpAndSettle();

    // Compatibility path: up to six results render exactly as before.
    expect(find.byKey(const ValueKey('results-summary-bar')), findsNothing);
    expect(find.byKey(const ValueKey('results-expand-all')), findsNothing);
    expect(find.byKey(const ValueKey('results-only-failures')), findsNothing);
    expect(find.byType(CodeBlock), findsNWidgets(6));
    expect(find.byType(DataGrid), findsNWidgets(6));
  });
}
