// 第 57 轮：批量编辑的「未保存离开确认」。
//
// TableView 的 DataGrid 把单元格编辑暂存在本地，翻页 / 改每页条数 / 刷新 /
// 切页签 / 切表都会替换 rows 并清掉这些编辑。这个 live SQLite 测试覆盖守卫：
//   * 翻页：取消不翻页、放弃翻页、保存后翻页（并验证真的写进数据库）；
//   * 切页签：取消留在数据页、放弃后切走；
//   * 切表：保存到原表 / 放弃；
//   * 保存失败：停留当前页并保留暂存编辑。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/components/data_grid.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/table_view.dart';

Future<void> settle(WidgetTester tester, {int rounds = 16}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Widget host(Widget child) => MaterialApp(
  theme: buildAppTheme(),
  home: Scaffold(body: child),
);

void size(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Double-click a cell, type [text] (or tick NULL) in the full-value editor and
/// press 保存, which stages the edit instead of writing it immediately.
Future<void> editCell(
  WidgetTester tester,
  String cell,
  String text, {
  bool asNull = false,
}) async {
  await tester.tap(find.text(cell));
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tap(find.text(cell));
  await tester.pumpAndSettle();
  final dialog = find.byType(Dialog);
  expect(dialog, findsOneWidget, reason: 'cell editor should open for $cell');
  if (asNull) {
    await tester.tap(find.descendant(of: dialog, matching: find.text('NULL')));
  } else {
    await tester.enterText(
      find.descendant(of: dialog, matching: find.byType(TextField)),
      text,
    );
  }
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(of: dialog, matching: find.text('保存')));
  await tester.pumpAndSettle();
  // The "已暂存" flash carries a 1.5s timer; let it fire before ending.
  await tester.pump(const Duration(milliseconds: 1700));
  await tester.pumpAndSettle();
}

/// 暂存编辑后表格工具栏上的提示。
Finder stagedPill(int count) => find.textContaining('未保存 $count 处');

Future<void> pumpTableView(
  WidgetTester tester,
  String table,
  Notice notice,
) async {
  await tester.pumpWidget(
    host(TableView(db: 'main', table: table, notice: notice)),
  );
  await settle(tester);
}

Future<String?> storedValue(
  WidgetTester tester,
  String table,
  int id,
  String column,
) async {
  final res = await tester.runAsync(
    () => Api.instance.query('SELECT $column FROM "$table" WHERE id = $id;'),
  );
  final rows = ((res!['results'] as List).first as Map)['rows'] as List;
  if (rows.isEmpty) return null;
  final row = rows.first as List;
  return row.isEmpty ? null : row.first?.toString();
}

void main() {
  late Directory temporary;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('rma-dirty-guard-');
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        'rust/target/debug/librust_myadmin_core.dylib',
      ),
    );
    expect((await Api.init(temporary.path))['ok'], isTrue);
    await AppState.instance.bootstrap(temporary.path);
    File('${temporary.path}/test.sqlite').createSync();
    final connection = await Api.instance.createConnection(<String, dynamic>{
      'name': 'dirty-guard',
      'driver': 'sqlite',
      'database': '${temporary.path}/test.sqlite',
    });
    await AppState.instance.connect(
      (connection['connection'] as Map)['id'].toString(),
    );
    await AppState.instance.refreshDatabases();
    await Api.instance.query(
      'CREATE TABLE guard_rows (id INTEGER PRIMARY KEY, name TEXT);',
    );
    await Api.instance.query(
      'CREATE TABLE guard_rows2 (id INTEGER PRIMARY KEY, name TEXT);',
    );
    await Api.instance.query(
      'CREATE TABLE guard_fail (id INTEGER PRIMARY KEY, name TEXT);',
    );
    for (var i = 1; i <= 30; i++) {
      await Api.instance.query(
        "INSERT INTO guard_rows (id, name) VALUES ($i, 'row_$i');",
      );
      await Api.instance.query(
        "INSERT INTO guard_fail (id, name) VALUES ($i, 'row_$i');",
      );
    }
    await Api.instance.query(
      "INSERT INTO guard_rows2 (id, name) VALUES (1, 'second');",
    );
  });

  tearDownAll(() async {
    try {
      await Api.instance.disconnect();
    } catch (_) {}
    try {
      await temporary.delete(recursive: true);
    } catch (_) {}
    I18n.setLang(AppLang.zh);
  });

  setUp(() async {
    I18n.setLang(AppLang.zh);
    // 用例之间互不影响：把被前面用例改过的值恢复成初始数据。
    await Api.instance.query("UPDATE guard_rows SET name = 'row_' || id;");
    await Api.instance.query("UPDATE guard_rows2 SET name = 'second';");
    // 「保存失败」用例会 DROP guard_fail；补回来，避免测试顺序变化时失败。
    try {
      await Api.instance.query(
        'CREATE TABLE IF NOT EXISTS guard_fail '
        '(id INTEGER PRIMARY KEY, name TEXT);',
      );
      for (var i = 1; i <= 30; i++) {
        await Api.instance.query(
          "INSERT OR REPLACE INTO guard_fail (id, name) VALUES ($i, 'row_$i');",
        );
      }
    } catch (_) {
      // 重建失败时该用例自己会报错，这里不掩盖真正的断言失败。
    }
  });

  testWidgets('翻页前确认：取消不翻页、放弃翻页、保存后翻页', (tester) async {
    size(tester);
    final notice = Notice();
    addTearDown(notice.dispose);
    await pumpTableView(tester, 'guard_rows', notice);
    expect(find.text('row_1'), findsWidgets);

    await editCell(tester, 'row_1', 'row_1_saved');
    expect(stagedPill(1), findsOneWidget);

    // 取消：仍在第 1 页（row_1 可见、row_26 不可见），暂存编辑保留。
    await tester.tap(find.byKey(const ValueKey('pager-next')));
    await settle(tester, rounds: 6);
    expect(find.text('有未保存的修改'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('batch-leave-cancel')));
    await settle(tester, rounds: 6);
    expect(find.text('有未保存的修改'), findsNothing);
    expect(find.text('row_1'), findsWidgets);
    expect(find.text('row_26'), findsNothing);
    expect(stagedPill(1), findsOneWidget);

    // 放弃：翻到第 2 页，暂存编辑丢弃。
    await tester.tap(find.byKey(const ValueKey('pager-next')));
    await settle(tester, rounds: 6);
    await tester.tap(find.byKey(const ValueKey('batch-leave-discard')));
    await settle(tester, rounds: 18);
    expect(find.text('row_26'), findsWidgets);
    expect(find.textContaining('未保存'), findsNothing);

    // 回第 1 页改一次，再点「保存后继续」：真正写库后才翻页。
    await tester.tap(find.byKey(const ValueKey('pager-prev')));
    await settle(tester, rounds: 18);
    expect(find.text('row_1'), findsWidgets);
    await editCell(tester, 'row_1', 'row_1_saved');
    expect(stagedPill(1), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pager-next')));
    await settle(tester, rounds: 6);
    await tester.tap(find.byKey(const ValueKey('batch-leave-save')));
    await settle(tester, rounds: 26);
    expect(find.text('row_26'), findsWidgets);
    expect(find.textContaining('未保存'), findsNothing);
    expect(await storedValue(tester, 'guard_rows', 1, 'name'), 'row_1_saved');
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('切页签前确认：取消留在数据页、放弃后切到结构页', (tester) async {
    size(tester);
    final notice = Notice();
    addTearDown(notice.dispose);
    await pumpTableView(tester, 'guard_rows', notice);

    await editCell(tester, 'row_1', 'row_1_tab');
    expect(stagedPill(1), findsOneWidget);

    await tester.tap(find.text('结构'));
    await settle(tester, rounds: 6);
    expect(find.text('有未保存的修改'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('batch-leave-cancel')));
    await settle(tester, rounds: 6);
    // 取消：仍在数据页。
    expect(find.byType(DataGrid), findsOneWidget);
    expect(stagedPill(1), findsOneWidget);

    await tester.tap(find.text('结构'));
    await settle(tester, rounds: 6);
    await tester.tap(find.byKey(const ValueKey('batch-leave-discard')));
    await settle(tester, rounds: 14);
    // 放弃后切到结构页：数据页的 DataGrid 已卸载。
    expect(find.byType(DataGrid), findsNothing);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('切表前确认：保存到原表 / 放弃', (tester) async {
    size(tester);
    final notice = Notice();
    addTearDown(notice.dispose);

    await pumpTableView(tester, 'guard_rows2', notice);
    await editCell(tester, 'second', 'second_edited');
    expect(stagedPill(1), findsOneWidget);

    // 切表：保存到原表 guard_rows2，然后加载新表 guard_rows。
    await tester.pumpWidget(
      host(TableView(db: 'main', table: 'guard_rows', notice: notice)),
    );
    await settle(tester, rounds: 12);
    expect(find.text('上一张表有未保存的修改'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('table-switch-save')));
    await settle(tester, rounds: 26);
    expect(find.text('row_1'), findsWidgets);
    expect(find.textContaining('未保存'), findsNothing);
    expect(
      await storedValue(tester, 'guard_rows2', 1, 'name'),
      'second_edited',
    );

    // 在 guard_rows 上改一行后切回 guard_rows2，选择「放弃」：原表不写入。
    await editCell(tester, 'row_2', 'row_2_discarded');
    expect(stagedPill(1), findsOneWidget);
    await tester.pumpWidget(
      host(TableView(db: 'main', table: 'guard_rows2', notice: notice)),
    );
    await settle(tester, rounds: 12);
    expect(find.text('上一张表有未保存的修改'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('table-switch-discard')));
    await settle(tester, rounds: 26);
    expect(find.text('second_edited'), findsWidgets);
    expect(await storedValue(tester, 'guard_rows', 2, 'name'), 'row_2');
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('保存失败时停留当前页并保留暂存编辑', (tester) async {
    size(tester);
    final notice = Notice();
    addTearDown(notice.dispose);
    await pumpTableView(tester, 'guard_fail', notice);

    await editCell(tester, 'row_1', 'row_1_lost');
    expect(stagedPill(1), findsOneWidget);

    // 外部删表：保存必然失败。
    await tester.runAsync(() => Api.instance.query('DROP TABLE guard_fail;'));

    await tester.tap(find.byKey(const ValueKey('pager-next')));
    await settle(tester, rounds: 6);
    await tester.tap(find.byKey(const ValueKey('batch-leave-save')));
    await settle(tester, rounds: 22);
    // 保存失败：不翻页、暂存编辑保留（用户可以随后放弃或重试）。
    expect(find.text('row_1'), findsWidgets);
    expect(find.text('row_26'), findsNothing);
    expect(stagedPill(1), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });
}
