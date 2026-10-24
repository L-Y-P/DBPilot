//! 查询构建器「数据源」面板按需构建回归测试（5000 张表）。
//!
//! 背景：旧实现的 _body() 在每次 build 里把所有表的 _tableTile 预构建进 items
//! 列表（每行 Material + InkWell + EllipsisText + 标签），所以 5000 张表的数据源
//! 在搜索框每次 onChanged、每次展开字段时都要建 5000 个 widget 子树——这是构建器
//! 卡顿的主要来源。修复后 ListView.builder 的 itemBuilder 只在可见行调用
//! _tableTile；分组模式只预计算轻量的 database-header / table 引用表。
//!
//! 本测试不需要 FFI/数据库：直接 pump BuilderDataSourcePanel 喂 5000 个假表。
//!
//! 断言：
//!   1. 首帧只构建视口内的行（远小于 5000），首尾键可见性正确；
//!   2. 跳到末尾能看到最后一张表，且构建数仍受视口约束；
//!   3. 搜索表名 / 字段名立即收敛到匹配行，无匹配显示空提示，清空后恢复；
//!   4. groupByDatabase 分组模式同样懒构建，滚动后能看到后面的分组头；
//!   5. ValueKey / 选中态 / 展开字段 / 回调行为保持不变（小数据集）。

// 路径与 debug 标签由字符串拼接组成（与 builder_ui_test 同一约定）。
// ignore_for_file: prefer_interpolation_to_compose_strings

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/builder/builder_widgets.dart';
import 'package:rust_myadmin_desktop/src/builder/query_model.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';

/// 与性能报告里 5005 张表同一量级。
const int kTableCount = 5000;

String tableName(int index) => 'tbl_' + index.toString().padLeft(4, '0');

BuilderTable table(int index, {String database = ''}) => BuilderTable(
      name: tableName(index),
      database: database,
      columns: <BuilderColumn>[
        BuilderColumn(name: 'c' + index.toString() + '_id', type: 'INTEGER', key: 'PRI'),
        BuilderColumn(name: 'c' + index.toString() + '_name', type: 'TEXT'),
      ],
    );

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 360, height: 640, child: child),
        ),
      ),
    );

Widget panel({
  required List<BuilderTable> tables,
  String? primaryTable,
  Set<String> participating = const <String>{},
  Set<String> outputKeys = const <String>{},
  bool groupByDatabase = false,
  ValueChanged<String>? onToggleTable,
  void Function(String table, String column)? onToggleOutput,
}) =>
    BuilderDataSourcePanel(
      tables: tables,
      primaryTable: primaryTable,
      participating: participating,
      outputKeys: outputKeys,
      loading: false,
      enabled: true,
      groupByDatabase: groupByDatabase,
      onToggleTable: onToggleTable ?? (_) {},
      onToggleOutput: onToggleOutput ?? (_, _) {},
    );

Finder tableTile(String key) =>
    find.byKey(ValueKey<String>('builder-table-' + key));

/// 当前树里已构建（inflated）的表行数量。
int builtTableTiles(WidgetTester tester) => find
    .byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> && key.value.startsWith('builder-table-');
    })
    .evaluate()
    .length;

/// 把未分组的数据源树直接跳到底部。
///
/// 每行都是固定 30px（未展开），所以按「行高 × 行数 − 视口」算出的偏移就是精确
/// 末尾；这比反复 jumpTo(maxScrollExtent)（估算值会触发 SliverList 的长距离
/// 修正，5000 行的 debug 测试要十几秒）快得多，断言也更稳定。
Future<void> jumpToBottom(WidgetTester tester, {required int rowCount}) async {
  final rowHeight = tester.getSize(tableTile('tbl_0000')).height;
  final listView = tester.widget<ListView>(find.byType(ListView));
  final position = listView.controller!.position;
  final offset =
      (rowCount * rowHeight - position.viewportDimension).clamp(0.0, double.infinity);
  final watch = Stopwatch()..start();
  position.jumpTo(offset);
  await tester.pump();
  watch.stop();
  debugPrint('BUILDER_SOURCE_BOTTOM_JUMP_US=' +
      watch.elapsedMicroseconds.toString());
}

void setView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('5000 张表的首帧只构建视口内的行', (tester) async {
    setView(tester);
    final tables = List<BuilderTable>.generate(kTableCount, table);
    final watch = Stopwatch()..start();
    await tester.pumpWidget(host(panel(tables: tables)));
    await tester.pump();
    watch.stop();
    debugPrint('BUILDER_SOURCE_5000_FIRST_FRAME_US=' +
        watch.elapsedMicroseconds.toString());

    final built = builtTableTiles(tester);
    debugPrint('BUILDER_SOURCE_5000_BUILT_ROWS=' + built.toString());
    expect(built, greaterThan(0), reason: '至少要有可见的表行');
    expect(built, lessThan(200),
        reason: '5000 张表不能一次性建成 widget，实际构建了 ' +
            built.toString() +
            ' 行');
    expect(tableTile('tbl_0000'), findsOneWidget);
    expect(tableTile('tbl_4999'), findsNothing);
  });

  testWidgets('跳到末尾能拿到最后一张表，构建数仍受视口约束', (tester) async {
    setView(tester);
    final tables = List<BuilderTable>.generate(kTableCount, table);
    await tester.pumpWidget(host(panel(tables: tables)));
    await tester.pump();

    await jumpToBottom(tester, rowCount: kTableCount);
    expect(tableTile('tbl_4999'), findsOneWidget);
    expect(builtTableTiles(tester), lessThan(400),
        reason: '滚动过程中构建过的行数也必须受视口约束');
  });

  testWidgets('搜索表名/字段名只建匹配行，清空后恢复', (tester) async {
    setView(tester);
    final tables = List<BuilderTable>.generate(kTableCount, table);
    await tester.pumpWidget(host(panel(tables: tables)));
    await tester.pump();
    final search = find.byType(TextField);
    expect(search, findsOneWidget);

    // 按表名搜索：只剩一行。
    await tester.enterText(search, 'tbl_4999');
    await tester.pump();
    expect(builtTableTiles(tester), 1);
    expect(tableTile('tbl_4999'), findsOneWidget);
    expect(tableTile('tbl_0000'), findsNothing);

    // 按字段名搜索：命中该字段所属的表。
    await tester.enterText(search, 'c4998_name');
    await tester.pump();
    expect(builtTableTiles(tester), 1);
    expect(tableTile('tbl_4998'), findsOneWidget);
    expect(tableTile('tbl_4999'), findsNothing);

    // 无匹配：空提示，不建任何表行。
    await tester.enterText(search, 'no_such_table_or_column');
    await tester.pump();
    expect(find.text('没有匹配的表或字段'), findsOneWidget);
    expect(builtTableTiles(tester), 0);

    // 清空搜索：回到按需构建的首屏。
    await tester.enterText(search, '');
    await tester.pump();
    expect(tableTile('tbl_0000'), findsOneWidget);
    expect(builtTableTiles(tester), lessThan(200));
  });

  testWidgets('groupByDatabase 分组模式懒构建表行与分组头', (tester) async {
    setView(tester);
    final tables = List<BuilderTable>.generate(
      kTableCount,
      (index) => table(index, database: 'db' + (index % 4).toString()),
    );
    await tester.pumpWidget(
      host(panel(tables: tables, groupByDatabase: true)),
    );
    await tester.pump();

    final built = builtTableTiles(tester);
    debugPrint('BUILDER_SOURCE_GROUPED_BUILT_ROWS=' + built.toString());
    expect(built, greaterThan(0));
    expect(built, lessThan(200));
    expect(find.text('db0'), findsOneWidget);
    expect(find.text('db3'), findsNothing,
        reason: '后面的分组头在滚到之前不应构建');
    expect(tableTile('db0.tbl_0000'), findsOneWidget);
    expect(tableTile('db3.tbl_4999'), findsNothing);

    // 后面的分组头/表行同样按需构建：搜索只留下 db3 的表时，header + 表行
    // 一起出现（分组计划的 header 字符串此时才变成 widget）。
    await tester.enterText(find.byType(TextField), 'tbl_0003');
    await tester.pump();
    expect(find.text('db3'), findsOneWidget);
    expect(tableTile('db3.tbl_0003'), findsOneWidget);
    expect(builtTableTiles(tester), 1);

    // 搜到最后一张表：证明数据没丢、按需构建能取到任意位置。
    await tester.enterText(find.byType(TextField), 'tbl_4999');
    await tester.pump();
    expect(tableTile('db3.tbl_4999'), findsOneWidget);
    expect(builtTableTiles(tester), 1);
  });

  testWidgets('选中态/展开字段/回调在按需构建下保持不变', (tester) async {
    setView(tester);
    final tables = List<BuilderTable>.generate(20, table);
    final toggled = <String>[];
    final outputs = <String>[];
    await tester.pumpWidget(host(panel(
      tables: tables,
      primaryTable: 'tbl_0001',
      participating: const <String>{'tbl_0002'},
      outputKeys: const <String>{'tbl_0001.c1_id'},
      onToggleTable: toggled.add,
      onToggleOutput: (tableKey, column) =>
          outputs.add(tableKey + '.' + column),
    )));
    await tester.pump();

    // 主表 / 接入 标记仍然渲染。
    expect(find.text('主表'), findsOneWidget);
    expect(find.text('接入'), findsOneWidget);

    // 展开字段（builder-expand-* 键未变），字段行按需构建。
    await tester.tap(find.byKey(const ValueKey('builder-expand-tbl_0001')));
    await tester.pump();
    final fieldKey = const ValueKey('builder-field-tbl_0001.c1_id');
    expect(find.byKey(fieldKey), findsOneWidget);
    expect(find.text('c1_id'), findsOneWidget);

    // 点击字段仍触发 onToggleOutput。
    await tester.tap(find.byKey(fieldKey));
    await tester.pump();
    expect(outputs, <String>['tbl_0001.c1_id']);

    // 点击表行仍触发 onToggleTable；ValueKey 让测试按表名定位。
    await tester.tap(find.byKey(const ValueKey('builder-table-tbl_0003')));
    await tester.pump();
    expect(toggled, <String>['tbl_0003']);
  });
}
