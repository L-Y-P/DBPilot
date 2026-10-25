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

  // =====================================================================
  // 第 57 轮：onDirtyChanges（离开当前页前的未保存保护用）
  // =====================================================================

  testWidgets('onDirtyChanges reports staged edits, then empty after apply',
      (tester) async {
    final reports = <List<DirtyCell>>[];
    await tester.pumpWidget(host(DataGrid(
      columns: _columns,
      rows: _rows,
      primaryKey: const <String>['id'],
      rowOps: true,
      editable: true,
      onApplyEdits: (edits) async => true,
      onDirtyChanges: (edits) => reports.add(List<DirtyCell>.of(edits)),
    )));
    await tester.pumpAndSettle();
    expect(reports, isEmpty);

    await editCell(tester, 'one', 'ONE');
    expect(reports, isNotEmpty);
    expect(reports.last, hasLength(1));
    expect(reports.last.single.rowIndex, 0);
    expect(reports.last.single.column, 'name');
    expect(reports.last.single.value, 'ONE');

    await tester.tap(find.byKey(const ValueKey('grid-apply-dirty')));
    await tester.pumpAndSettle();
    expect(reports.last, isEmpty, reason: '保存成功后应上报空列表');
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('onDirtyChanges reports empty after 撤销改动', (tester) async {
    final reports = <List<DirtyCell>>[];
    await tester.pumpWidget(host(DataGrid(
      columns: _columns,
      rows: _rows,
      primaryKey: const <String>['id'],
      rowOps: true,
      editable: true,
      onApplyEdits: (edits) async => true,
      onDirtyChanges: (edits) => reports.add(List<DirtyCell>.of(edits)),
    )));
    await tester.pumpAndSettle();

    await editCell(tester, 'one', 'ONE');
    expect(reports.last, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('grid-discard-dirty')));
    await tester.pumpAndSettle();
    expect(reports.last, isEmpty);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('rows replacement clears edits and reports empty; unrelated rebuild keeps them',
      (tester) async {
    final reports = <List<DirtyCell>>[];
    final rows = _rows;
    Widget grid(List<List<dynamic>> tableRows) => host(DataGrid(
          columns: _columns,
          rows: tableRows,
          primaryKey: const <String>['id'],
          rowOps: true,
          editable: true,
          onApplyEdits: (edits) async => true,
          onDirtyChanges: (edits) => reports.add(List<DirtyCell>.of(edits)),
        ));

    await tester.pumpWidget(grid(rows));
    await tester.pumpAndSettle();
    await editCell(tester, 'one', 'ONE');
    expect(reports.last, hasLength(1));

    // 父组件因无关原因重建：外层 list 是新的，但行对象没变 → 暂存编辑保留。
    await tester.pumpWidget(grid(<List<dynamic>>[...rows]));
    await tester.pumpAndSettle();
    expect(find.text('保存全部改动 (1)'), findsOneWidget);
    expect(reports.last, hasLength(1));

    // 真正的行替换（reload / page flip）：内层行对象也变了 → 清空并上报 []。
    await tester.pumpWidget(grid(<List<dynamic>>[
      <dynamic>[1, 'one'],
      <dynamic>[2, 'two'],
    ]));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grid-apply-dirty')), findsNothing);
    expect(reports.last, isEmpty);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });
}
