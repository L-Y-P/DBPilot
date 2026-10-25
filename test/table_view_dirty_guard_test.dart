// 第 57/59 轮：批量编辑的跨页保持与「未保存离开确认」。
//
// 第 59 轮起，暂存编辑按行键跨页保留：翻页 / 排序 / 改每页条数不再丢编辑，
// 「保存全部改动」把多页合并成一次事务；切页签 / 切表 / 刷新仍然确认。
// 这个 live SQLite 测试覆盖：
//   * 跨页：第 1 页改 A、翻到第 2 页改 B、翻回第 1 页两页编辑都在，排序不丢，
//     「保存全部改动」后两页数据都写库；
//   * 刷新：仍弹未保存确认，取消后编辑保留；
//   * 切页签：取消留在数据页、放弃后切走；
//   * 切表：保存到原表 / 放弃；
//   * 保存失败：停留当前页并保留暂存编辑。
//
// 第 60 轮补充：无主键表禁用跨页保持（翻页仍确认）、暂存上限（DataGrid
// maxDirtyCells）、保存后零行命中诊断（Rust zero_row_results，dylib 未就绪时
// 该用例自动 skip）。

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

Future<int> rowCount(WidgetTester tester, String table, int id) async {
  final res = await tester.runAsync(
    () => Api.instance.query(
      'SELECT COUNT(*) AS c FROM "$table" WHERE id = $id;',
    ),
  );
  final rows = ((res!['results'] as List).first as Map)['rows'] as List;
  return ((rows.first as List).first as num).toInt();
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
    // 第 60 轮：无主键表（跨页保持应禁用）。
    await Api.instance.query('CREATE TABLE guard_nopk (id INTEGER, name TEXT);');
    for (var i = 1; i <= 30; i++) {
      await Api.instance.query(
        "INSERT INTO guard_rows (id, name) VALUES ($i, 'row_$i');",
      );
      await Api.instance.query(
        "INSERT INTO guard_fail (id, name) VALUES ($i, 'row_$i');",
      );
      await Api.instance.query(
        "INSERT INTO guard_nopk (id, name) VALUES ($i, 'row_$i');",
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
    // 用例之间互不影响：恢复初始数据（含被前面用例删除的行）。
    for (var i = 1; i <= 30; i++) {
      await Api.instance.query(
        "INSERT OR REPLACE INTO guard_rows (id, name) VALUES ($i, 'row_$i');",
      );
    }
    await Api.instance.query(
      "INSERT OR REPLACE INTO guard_rows2 (id, name) VALUES (1, 'second');",
    );
    // 无主键表没有唯一键，用 DELETE + INSERT 恢复 30 行。
    await Api.instance.query('DELETE FROM guard_nopk;');
    for (var i = 1; i <= 30; i++) {
      await Api.instance.query(
        "INSERT INTO guard_nopk (id, name) VALUES ($i, 'row_$i');",
      );
    }
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

  testWidgets('跨页保持：翻页/排序不丢编辑，保存全部一次写多页', (tester) async {
    size(tester);
    final notice = Notice();
    addTearDown(notice.dispose);
    await pumpTableView(tester, 'guard_rows', notice);
    expect(find.text('row_1'), findsWidgets);

    // 第 1 页改 row_1。
    await editCell(tester, 'row_1', 'row_1_page1');
    expect(stagedPill(1), findsOneWidget);

    // 翻到第 2 页：不再弹丢弃确认，编辑被带到别的页继续保留。
    await tester.tap(find.byKey(const ValueKey('pager-next')));
    await settle(tester, rounds: 18);
    expect(find.text('有未保存的修改'), findsNothing);
    expect(find.text('row_26'), findsWidgets);
    expect(stagedPill(1), findsOneWidget);

    // 第 2 页再改 row_26：跨页计数变 2。
    await editCell(tester, 'row_26', 'row_26_page2');
    expect(stagedPill(2), findsOneWidget);
    expect(find.textContaining('保存全部改动 (2/'), findsOneWidget);

    // 回第 1 页：两页的编辑都还在（计数 2）。
    await tester.tap(find.byKey(const ValueKey('pager-prev')));
    await settle(tester, rounds: 18);
    expect(find.text('row_1'), findsWidgets);
    expect(stagedPill(2), findsOneWidget);

    // 排序会换页数据，也不丢编辑、不弹确认（表头文字是「列名(类型)」）。
    await tester.tap(find.textContaining('name(').first);
    await settle(tester, rounds: 18);
    expect(find.text('有未保存的修改'), findsNothing);
    expect(stagedPill(2), findsOneWidget);

    // 从当前页点「保存全部改动」：两页编辑合并成一次 applyRowChanges。
    await tester.tap(find.byKey(const ValueKey('grid-apply-dirty')));
    await settle(tester, rounds: 26);
    expect(find.textContaining('未保存'), findsNothing);
    expect(await storedValue(tester, 'guard_rows', 1, 'name'), 'row_1_page1');
    expect(await storedValue(tester, 'guard_rows', 26, 'name'), 'row_26_page2');
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('刷新仍确认：取消后编辑保留', (tester) async {
    size(tester);
    final notice = Notice();
    addTearDown(notice.dispose);
    await pumpTableView(tester, 'guard_rows', notice);

    await editCell(tester, 'row_1', 'row_1_refresh');
    expect(stagedPill(1), findsOneWidget);

    await tester.tap(find.text('刷新'));
    await settle(tester, rounds: 6);
    expect(find.text('有未保存的修改'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('batch-leave-cancel')));
    await settle(tester, rounds: 6);
    expect(find.text('有未保存的修改'), findsNothing);
    expect(stagedPill(1), findsOneWidget);
    expect(find.text('row_1'), findsWidgets);
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

  testWidgets('保存失败时停留并保留暂存编辑', (tester) async {
    size(tester);
    final notice = Notice();
    addTearDown(notice.dispose);
    await pumpTableView(tester, 'guard_fail', notice);

    await editCell(tester, 'row_1', 'row_1_lost');
    expect(stagedPill(1), findsOneWidget);

    // 外部删表：保存必然失败。
    await tester.runAsync(() => Api.instance.query('DROP TABLE guard_fail;'));

    await tester.tap(find.byKey(const ValueKey('grid-apply-dirty')));
    await settle(tester, rounds: 22);
    // 保存失败：仍在本页、暂存编辑保留（可以重试或撤销）。
    expect(find.text('row_1'), findsWidgets);
    expect(stagedPill(1), findsOneWidget);
    expect(find.textContaining('保存全部改动 (1/'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('有暂存编辑时删除行：取消不删、放弃后删除', (tester) async {
    size(tester);
    final notice = Notice();
    addTearDown(notice.dispose);
    await pumpTableView(tester, 'guard_rows', notice);

    await editCell(tester, 'row_1', 'row_1_delete');
    expect(stagedPill(1), findsOneWidget);

    // 第一次点行删除：先弹未保存确认；取消 → 不删除，编辑仍在。
    await tester.tap(find.byKey(const ValueKey('row-delete')).first);
    await settle(tester, rounds: 6);
    expect(find.text('有未保存的修改'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('batch-leave-cancel')));
    await settle(tester, rounds: 6);
    expect(find.text('row_1'), findsWidgets);
    expect(stagedPill(1), findsOneWidget);
    expect(await rowCount(tester, 'guard_rows', 1), 1);

    // 再点删除 → 放弃暂存编辑 → 进入原本的删除确认 → 确认后行消失。
    await tester.tap(find.byKey(const ValueKey('row-delete')).first);
    await settle(tester, rounds: 6);
    await tester.tap(find.byKey(const ValueKey('batch-leave-discard')));
    await settle(tester, rounds: 8);
    expect(find.text('确定删除该行吗？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await settle(tester, rounds: 20);
    expect(find.text('row_1'), findsNothing);
    expect(stagedPill(1), findsNothing);
    expect(await rowCount(tester, 'guard_rows', 1), 0);
    await tester.pump(const Duration(seconds: 4));
  });

  test('BatchApplyOutcome 文案：零行命中时追加诊断', () {
    expect(
      const BatchApplyOutcome(rowsAffected: 2, zeroRows: 0).message,
      '已保存 2 行',
    );
    final zero = const BatchApplyOutcome(rowsAffected: 0, zeroRows: 1);
    expect(zero.hasZeroRows, isTrue);
    expect(zero.message, contains('未命中任何行'));
    expect(zero.message, contains('1 条改动'));
  });

  testWidgets('无主键表：翻页仍弹离开确认（不做跨页保持）', (tester) async {
    size(tester);
    final notice = Notice();
    addTearDown(notice.dispose);
    await pumpTableView(tester, 'guard_nopk', notice);
    expect(find.text('row_1'), findsWidgets);

    await editCell(tester, 'row_1', 'row_1_nopk');
    expect(stagedPill(1), findsOneWidget);

    // 无主键：翻页前仍要确认（整行旧键跨页保存可能命中 0 行）。
    await tester.tap(find.byKey(const ValueKey('pager-next')));
    await settle(tester, rounds: 6);
    expect(find.text('有未保存的修改'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('batch-leave-cancel')));
    await settle(tester, rounds: 6);
    expect(find.text('row_1'), findsWidgets);

    // 放弃后翻页：编辑不跨页保留。
    await tester.tap(find.byKey(const ValueKey('pager-next')));
    await settle(tester, rounds: 6);
    await tester.tap(find.byKey(const ValueKey('batch-leave-discard')));
    await settle(tester, rounds: 18);
    expect(find.text('row_26'), findsWidgets);
    expect(find.textContaining('未保存'), findsNothing);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('保存时行已被删除：notice 提示 N 条改动未命中任何行', (tester) async {
    size(tester);
    final notice = Notice();
    addTearDown(notice.dispose);

    // Rust 端 zero_row_results 尚未就绪（dylib 旧）时跳过，等刷新后复跑。
    var supportsZeroRows = false;
    await tester.runAsync(() async {
      try {
        await Api.instance.query(
          'CREATE TABLE IF NOT EXISTS zero_probe '
          '(id INTEGER PRIMARY KEY, name TEXT);',
        );
        await Api.instance.query(
          "INSERT OR REPLACE INTO zero_probe (id, name) VALUES (999, 'x');",
        );
        await Api.instance.query('DELETE FROM zero_probe WHERE id = 999;');
        final res = await Api.instance.applyRowChanges(
          'main',
          'zero_probe',
          <Map<String, dynamic>>[
            <String, dynamic>{
              'action': 'update',
              'keys': <String, dynamic>{'id': 999},
              'values': <String, dynamic>{'name': 'y'},
              'limit_one': false,
            },
          ],
        );
        supportsZeroRows = res.containsKey('zero_row_results');
      } catch (_) {
        supportsZeroRows = false;
      }
    });
    if (!supportsZeroRows) {
      markTestSkipped(
        'Rust zero_row_results 未就绪（等 rust teammate / dylib 刷新后复跑）',
      );
      return;
    }

    await pumpTableView(tester, 'guard_rows', notice);
    await editCell(tester, 'row_1', 'row_1_zero');
    expect(stagedPill(1), findsOneWidget);

    // 外部删除该行：保存的 keys 不再命中任何行。
    await tester.runAsync(
      () => Api.instance.query('DELETE FROM guard_rows WHERE id = 1;'),
    );
    await tester.tap(find.byKey(const ValueKey('grid-apply-dirty')));
    await settle(tester, rounds: 26);
    expect(find.textContaining('未命中任何行'), findsWidgets);
    expect(find.textContaining('未保存'), findsNothing);
    await tester.pump(const Duration(seconds: 4));
  });
}
