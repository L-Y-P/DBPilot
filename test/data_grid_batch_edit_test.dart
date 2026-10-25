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

/// Like [editCell] but does not wait out the 1.5s flash timer, so a rejection
/// flash can still be asserted.
Future<void> tryEditCell(WidgetTester tester, String cell, String text) async {
  await tester.tap(find.text(cell));
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tap(find.text(cell));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), text);
  await tester.pumpAndSettle();
  await tester.tap(find.text('保存'));
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

  // =====================================================================
  // 第 59 轮：跨页保持（initialDirtyByKey 受控模式）
  // =====================================================================

  testWidgets('initialDirtyByKey restores staged cells and edits keep keys',
      (tester) async {
    final reports = <List<DirtyCell>>[];
    final initial = <String, List<DirtyCell>>{
      rowChangeKeyFor(<String, Object?>{'id': 1}): <DirtyCell>[
        DirtyCell(
          rowIndex: 0,
          column: 'name',
          value: 'ONE',
          keys: <String, Object?>{'id': 1},
        ),
      ],
    };
    await tester.pumpWidget(host(DataGrid(
      columns: _columns,
      rows: _rows,
      primaryKey: const <String>['id'],
      rowOps: true,
      editable: true,
      onApplyEdits: (edits) async => true,
      onDirtyChanges: (edits) => reports.add(List<DirtyCell>.of(edits)),
      initialDirtyByKey: initial,
      totalDirtyCount: 1,
    )));
    await tester.pumpAndSettle();
    // 恢复的编辑已经让工具栏显示保存入口，且不需要重新通知宿主。
    expect(find.text('保存全部改动 (1)'), findsOneWidget);
    expect(reports, isEmpty);

    // 编辑另一行后，上报的列表包含恢复的编辑 + 新编辑，都带 keys。
    await editCell(tester, 'two', 'TWO');
    expect(reports, isNotEmpty);
    expect(reports.last, hasLength(2));
    expect(
      reports.last.every((edit) => edit.keys != null && edit.keys!.isNotEmpty),
      isTrue,
    );
    final keys = reports.last.map((edit) => edit.keys!['id']).toSet();
    expect(keys, <Object?>{1, 2});
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  testWidgets('controlled mode survives a page flip and saves from any page',
      (tester) async {
    List<DirtyCell>? applied;
    final initial = <String, List<DirtyCell>>{
      rowChangeKeyFor(<String, Object?>{'id': 1}): <DirtyCell>[
        DirtyCell(
          rowIndex: 0,
          column: 'name',
          value: 'ONE',
          keys: <String, Object?>{'id': 1},
        ),
      ],
    };
    Widget grid(List<List<dynamic>> rows) => host(DataGrid(
          columns: _columns,
          rows: rows,
          primaryKey: const <String>['id'],
          rowOps: true,
          editable: true,
          initialDirtyByKey: initial,
          totalDirtyCount: 1,
          onApplyEdits: (edits) async {
            applied = List<DirtyCell>.of(edits);
            return true;
          },
        ));

    await tester.pumpWidget(grid(_rows));
    await tester.pumpAndSettle();
    expect(find.text('保存全部改动 (1)'), findsOneWidget);

    // 翻到另一页：本页没有编辑，但宿主还有别的页的编辑 → 保存入口仍在。
    await tester.pumpWidget(grid(<List<dynamic>>[
      <dynamic>[3, 'three'],
      <dynamic>[4, 'four'],
    ]));
    await tester.pumpAndSettle();
    expect(find.text('保存全部改动 (1)'), findsOneWidget);
    expect(find.byKey(const ValueKey('grid-discard-dirty')), findsNothing);

    // 从没有编辑的页也能触发保存：本页 edits 为空，宿主合并跨页批次。
    await tester.tap(find.byKey(const ValueKey('grid-apply-dirty')));
    await tester.pumpAndSettle();
    expect(applied, isNotNull);
    expect(applied, isEmpty);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });

  // =====================================================================
  // 第 60 轮：暂存上限
  // =====================================================================

  testWidgets('maxDirtyCells refuses new cells past the cap and shows N/limit',
      (tester) async {
    List<DirtyCell>? applied;
    await tester.pumpWidget(host(DataGrid(
      columns: _columns,
      rows: _rows,
      primaryKey: const <String>['id'],
      rowOps: true,
      editable: true,
      maxDirtyCells: 1,
      onApplyEdits: (edits) async {
        applied = List<DirtyCell>.of(edits);
        return true;
      },
    )));
    await tester.pumpAndSettle();

    await editCell(tester, 'one', 'ONE');
    expect(find.text('保存全部改动 (1/1)'), findsOneWidget);

    // 第二个单元格超过上限：拒绝暂存并 flash 提示。
    await tryEditCell(tester, 'two', 'TWO');
    expect(find.textContaining('暂存改动过多'), findsOneWidget);
    expect(find.textContaining('上限 1'), findsOneWidget);
    expect(find.text('保存全部改动 (1/1)'), findsOneWidget);

    // 已暂存的单元格再次编辑不受限（计数不变）。
    await tryEditCell(tester, 'one', 'ONE2');
    expect(find.text('保存全部改动 (1/1)'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('grid-apply-dirty')));
    await tester.pumpAndSettle();
    expect(applied, hasLength(1));
    expect(applied!.single.value, 'ONE2');
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  });
}
