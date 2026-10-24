// Pagination and bounded height for the database overview's 数据表 / 对象 cards.
//
// Both cards used to render every row in one frame (120 rows built 120 sets of
// 清空/删除 buttons). They now show one page at a time through the same
// GridTable + TablePager pair as the data browser, with a bounded body height.
// The cards' columns and row buttons must not change: the ONLY new controls are
// the pager's prev/next buttons, so this file pins both the paging behaviour and
// the button inventory.
//
// The fixture is a real SQLite file driven through the Rust core. Note that the
// SQLite 数据表 card lists tables *and* views (the driver's list_tables covers
// both, ORDER BY name), which is why the card's 120 rows are 65 tables followed
// by 55 views.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/database_view.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

/// Real tables in the fixture (`tbl_001` … `tbl_065`).
const int kFixtureTables = 65;

/// Views in the fixture (`v_001` … `v_055`); the 视图 tab lists these.
const int kFixtureViews = 55;

/// Rows in the 数据表 card: tables and views, in name order.
const int kTableCardRows = kFixtureTables + kFixtureViews;

late Directory dir;

Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// One pump of the real view against the FFI-backed SQLite fixture.
Future<void> pumpDatabaseView(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(body: DatabaseView(db: 'main', notice: Notice())),
  ));
  await settle(tester);
}

Future<void> tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey<String>(key));
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

Finder cardNamed(String title) => find
    .byWidgetPredicate((widget) => widget is CardBox && widget.title == title);

Finder gridIn(String title) =>
    find.descendant(of: cardNamed(title), matching: find.byType(GridTable));

GridTable gridOf(WidgetTester tester, String title) =>
    tester.widget<GridTable>(gridIn(title));

/// A cell with exactly [text] inside one card (the same name can appear in
/// both cards: v_001 is a row of 数据表 *and* a row of the 视图 tab).
Finder cellIn(String title, String text) =>
    find.descendant(of: cardNamed(title), matching: find.text(text));

/// Distinct [Btn] labels rendered inside one card.
Set<String> cardButtonLabels(WidgetTester tester, String title) => tester
    .widgetList<Btn>(
        find.descendant(of: cardNamed(title), matching: find.byType(Btn)))
    .map((button) => button.label)
    .toSet();

/// Every [Btn] label on the page.
Set<String> pageButtonLabels(WidgetTester tester) => tester
    .widgetList<Btn>(find.byType(Btn))
    .map((button) => button.label)
    .toSet();

int cardIconButtonCount(WidgetTester tester, String title) => tester
    .widgetList<IconBtn>(
        find.descendant(of: cardNamed(title), matching: find.byType(IconBtn)))
    .length;

void main() {
  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run `cargo build --lib` in rust/ first: ${dylib.path} is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));

    dir = await Directory.systemTemp.createTemp('rma-db-paging-');
    final init = await Api.init(dir.path);
    expect(init['ok'], isTrue, reason: 'init_app failed: $init');
    await AppState.instance.bootstrap(dir.path);

    final dbFile = '${dir.path}/paging.sqlite';
    await File(dbFile).create(recursive: true);
    final created = await Api.instance.createConnection({
      'name': 'paging-fixture',
      'driver': 'sqlite',
      'database': dbFile,
    });
    final id = (created['connection'] as Map)['id'].toString();
    await AppState.instance.connect(id);

    String seq(int n) => n.toString().padLeft(3, '0');
    await Api.instance.query(
        [
          for (var i = 1; i <= kFixtureTables; i++)
            'CREATE TABLE tbl_${seq(i)} (id INTEGER);',
        ].join(' '),
        'main');
    await Api.instance.query(
        [
          for (var i = 1; i <= kFixtureViews; i++)
            'CREATE VIEW v_${seq(i)} AS SELECT $i AS id;',
        ].join(' '),
        'main');

    // The fixture must really hold the rows the assertions count.
    expect((await Api.instance.tables('main')).length, kTableCardRows);
    final objects = await Api.instance.objects('main');
    expect((objects['views'] as List).length, kFixtureViews);
  });

  tearDownAll(() async {
    await AppState.instance.disconnect();
    await dir.delete(recursive: true);
    I18n.setLang(AppLang.zh);
  });

  testWidgets('数据表卡片 120 行只渲染第一页 50 行，下一页渲染第 51–100 行',
      (tester) async {
    await pumpDatabaseView(tester);

    // Page 1: exactly one page of rows is built, not all 120.
    expect(find.text('第 1 / 3 页'), findsOneWidget);
    expect(find.text('显示 50 / 120 行'), findsOneWidget);
    expect(gridOf(tester, '数据表').rows.length, kDbTablePageSize);
    expect(cellIn('数据表', 'tbl_001'), findsWidgets);
    expect(cellIn('数据表', 'tbl_050'), findsWidgets);
    // Row 51 is on page 2; the first view (row 66) is on page 2 as well.
    expect(cellIn('数据表', 'tbl_051'), findsNothing);
    expect(cellIn('数据表', 'v_001'), findsNothing);

    await tapKey(tester, 'db-tables-next');
    expect(find.text('第 2 / 3 页'), findsOneWidget);
    expect(find.text('显示 50 / 120 行'), findsOneWidget);
    expect(gridOf(tester, '数据表').rows.length, kDbTablePageSize);
    expect(cellIn('数据表', 'tbl_051'), findsWidgets);
    expect(cellIn('数据表', 'v_035'), findsWidgets); // last row of page 2
    expect(cellIn('数据表', 'tbl_050'), findsNothing);
    expect(cellIn('数据表', 'v_036'), findsNothing); // first row of page 3
    expect(tester.takeException(), isNull);
  });

  testWidgets('行按钮文案与分页前完全一致，唯一新增控件是分页前后翻页按钮',
      (tester) async {
    await pumpDatabaseView(tester);

    // The two cards keep exactly the buttons they had before pagination.
    expect(cardButtonLabels(tester, '数据表'), <String>{'清空', '删除'});
    expect(cardButtonLabels(tester, '对象'),
        <String>{'查看 DDL', '删除', '刷新', '新建对象'});

    // No new button copy anywhere on the page. Round 50 added two page-level
    // entry points (from-file table creation and the relationship designer),
    // which are the only labels allowed beyond the paging-era set.
    const known = <String>{
      '刷新',
      '新建表',
      '从文件建表',
      '关系图',
      '打开目录',
      '删除数据库文件',
      '新建对象',
      '查看 DDL',
      '删除',
      '清空',
    };
    expect(pageButtonLabels(tester).difference(known), isEmpty,
        reason: 'page gained button copy that did not exist before paging');

    // The pager's prev/next are the only controls added to each card.
    expect(find.byKey(const ValueKey<String>('db-tables-prev')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('db-tables-next')), findsOneWidget);
    expect(
        find.byKey(const ValueKey<String>('db-objects-prev')), findsOneWidget);
    expect(
        find.byKey(const ValueKey<String>('db-objects-next')), findsOneWidget);
    expect(cardIconButtonCount(tester, '数据表'), 2);
    expect(cardIconButtonCount(tester, '对象'), 2);

    // One page of row buttons, not 120: page 1 is 50 BASE TABLE rows, so both
    // row actions appear exactly 50 times.
    expect(
        find.descendant(of: cardNamed('数据表'), matching: find.text('清空')),
        findsNWidgets(kDbTablePageSize));
    expect(
        find.descendant(of: cardNamed('数据表'), matching: find.text('删除')),
        findsNWidgets(kDbTablePageSize));
  });

  testWidgets('对象卡片切换页签后回到第 1 页', (tester) async {
    await pumpDatabaseView(tester);

    // 视图 holds all 55 views: two pages of 50 + 5.
    expect(find.text('第 1 / 2 页'), findsOneWidget);
    expect(gridOf(tester, '对象').rows.length, kDbTablePageSize);

    await tapKey(tester, 'db-objects-next');
    expect(find.text('第 2 / 2 页'), findsOneWidget);
    expect(gridOf(tester, '对象').rows.length, kFixtureViews - kDbTablePageSize);
    expect(cellIn('对象', 'v_051'), findsWidgets);
    expect(cellIn('对象', 'v_001'), findsNothing);

    Future<void> tapTab(String label) async {
      final finder = find.text(label);
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
      await tester.pump();
    }

    // 触发器 is a different list (and empty here): page 2 of 视图 does not leak
    // into it.
    await tapTab('触发器');
    expect(find.text('第 2 / 2 页'), findsNothing);
    expect(gridOf(tester, '对象').rows, isEmpty);

    // Coming back to 视图 starts at page 1 again.
    await tapTab('视图');
    expect(find.text('第 1 / 2 页'), findsOneWidget);
    expect(cellIn('对象', 'v_001'), findsWidgets);
    expect(cellIn('对象', 'v_051'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('两个列表都受 maxHeight 约束（有界高度，无溢出异常）', (tester) async {
    await pumpDatabaseView(tester);

    expect(gridOf(tester, '数据表').maxHeight, 360);
    expect(gridOf(tester, '对象').maxHeight, 300);
    // 50 rows are far taller than the cap, so the body really is bounded.
    expect(tester.getSize(gridIn('数据表')).height, 360);
    expect(tester.getSize(gridIn('对象')).height, 300);
    expect(tester.takeException(), isNull);
  });

  testWidgets('分页文案在英文模式下没有中文残留', (tester) async {
    I18n.setLang(AppLang.en);
    addTearDown(() => I18n.setLang(AppLang.zh));
    await pumpDatabaseView(tester);

    expect(find.text('Page 1 / 3'), findsOneWidget);
    expect(find.text('Showing 50 / 120 rows'), findsOneWidget);
    expect(find.text('Showing 50 / 55 items'), findsOneWidget);
  });
}
