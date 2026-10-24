// "保存全部改动" interaction: the grid stages cell edits instead of writing each
// one immediately, then hands the batch to the caller's transaction endpoint.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/components/data_grid.dart';
import 'package:rust_myadmin_desktop/src/row_changes.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';

Widget host(Widget child) => MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

List<Map<String, dynamic>> get _columns => <Map<String, dynamic>>[
      <String, dynamic>{'name': 'id', 'type_name': 'INTEGER'},
      <String, dynamic>{'name': 'name', 'type_name': 'TEXT'},
    ];

List<List<dynamic>> get _rows => <List<dynamic>>[
      <dynamic>[1, 'one'],
      <dynamic>[2, 'two'],
    ];

/// Open the cell editor for [cell], type [text] and press 保存.
Future<void> editCell(WidgetTester tester, String cell, String text) async {
  await tester.tap(find.text(cell));
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tap(find.text(cell));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(find.text('保存'));
  await tester.pumpAndSettle();
  // _flashMessage arms a 1.5s timer; let it fire so the test ends timer-free.
  await tester.pump(const Duration(milliseconds: 1600));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('cell edits are staged and applied together on 保存全部改动',
      (tester) async {
    var immediateSaves = 0;
    List<DirtyCell>? applied;
    await tester.pumpWidget(host(DataGrid(
      columns: _columns,
      rows: _rows,
      primaryKey: const <String>['id'],
      rowOps: true,
      editable: true,
      onSaveCell: (rowIndex, column, value, isNull) => immediateSaves++,
      onApplyEdits: (edits) async {
        applied = edits;
        return true;
      },
    )));
    await tester.pumpAndSettle();

    // No staged edits: no batch button.
    expect(find.byKey(const ValueKey('grid-apply-dirty')), findsNothing);

    await editCell(tester, 'one', 'ONE');
    // Batch mode must not write the cell immediately.
    expect(immediateSaves, 0);
    expect(find.byKey(const ValueKey('grid-apply-dirty')), findsOneWidget);
    expect(find.text('保存全部改动 (1)'), findsOneWidget);

    await editCell(tester, 'two', 'TWO');
    expect(find.text('保存全部改动 (2)'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('grid-apply-dirty')));
    await tester.pumpAndSettle();
    expect(immediateSaves, 0);
    expect(applied, isNotNull);
    expect(applied, hasLength(2));
    expect(applied!.first.rowIndex, 0);
    expect(applied!.first.column, 'name');
    expect(applied!.first.value, 'ONE');
    expect(applied!.last.rowIndex, 1);
    expect(applied!.last.value, 'TWO');
    // Success clears the staged state (the caller reloads the rows).
    expect(find.byKey(const ValueKey('grid-apply-dirty')), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('a failed save keeps the staged edits for a retry',
      (tester) async {
    await tester.pumpWidget(host(DataGrid(
      columns: _columns,
      rows: _rows,
      primaryKey: const <String>['id'],
      rowOps: true,
      editable: true,
      onApplyEdits: (edits) async => false,
    )));
    await tester.pumpAndSettle();

    await editCell(tester, 'one', 'ONE');
    await tester.tap(find.byKey(const ValueKey('grid-apply-dirty')));
    await tester.pumpAndSettle();

    // The caller reported failure: keep the edit so the user can retry.
    expect(find.byKey(const ValueKey('grid-apply-dirty')), findsOneWidget);
    expect(find.text('保存全部改动 (1)'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('撤销改动 discards the staged cells without calling the caller',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(host(DataGrid(
      columns: _columns,
      rows: _rows,
      primaryKey: const <String>['id'],
      rowOps: true,
      editable: true,
      onApplyEdits: (edits) async {
        calls++;
        return true;
      },
    )));
    await tester.pumpAndSettle();

    await editCell(tester, 'one', 'ONE');
    await tester.tap(find.byKey(const ValueKey('grid-discard-dirty')));
    await tester.pumpAndSettle();

    expect(calls, 0);
    expect(find.byKey(const ValueKey('grid-apply-dirty')), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('without onApplyEdits the grid keeps saving each cell immediately',
      (tester) async {
    var immediateSaves = 0;
    await tester.pumpWidget(host(DataGrid(
      columns: _columns,
      rows: _rows,
      primaryKey: const <String>['id'],
      rowOps: true,
      editable: true,
      onSaveCell: (rowIndex, column, value, isNull) => immediateSaves++,
    )));
    await tester.pumpAndSettle();

    await editCell(tester, 'one', 'ONE');
    expect(immediateSaves, 1);
    expect(find.byKey(const ValueKey('grid-apply-dirty')), findsNothing);
  });
}
