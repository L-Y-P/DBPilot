// E-R 关系设计器的端到端测试：SQLite 真库 + 真实 FFI。
//
// 覆盖 §5.3 的验收点：
//  * 已有外键自动显示；移除表后关系消失；
//  * 添加表弹窗（搜索 / 复选 / 加入）与画布上限；
//  * SQLite 下连接点禁用并给出原因（ALTER 不能增删外键）；
//  * 多对多中间表通过 createTable 一次建表成功（SQLite 内联外键）；
//  * 中文动作文案不出现 SQL 关键字，英文界面才出现。

import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart' hide Text, Tooltip;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';
import 'package:rust_myadmin_desktop/src/i18n_literals.dart' as lit;
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/text.dart' as app_text;
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/tooltip.dart' as app_tooltip;
import 'package:rust_myadmin_desktop/src/views/er_model.dart';
import 'package:rust_myadmin_desktop/src/views/relation_designer.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

void main() {
  late Directory temporary;
  late String connectionId;

  /// 等待真实 FFI 完成 + 几帧 UI 重绘（CircularProgressIndicator 会让
  /// pumpAndSettle 永远无法收敛，所以手动泵）。
  Future<void> settle(WidgetTester tester, {int rounds = 16}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 25));
    }
  }

  Widget host(Widget child) => MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: Padding(padding: const EdgeInsets.all(12), child: child),
    ),
  );

  Future<void> setSurface(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run cargo build --lib in rust/ first: missing ${dylib.path}');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    temporary = await Directory.systemTemp.createTemp('rma-er-ffi-');
    final init = await Api.init(temporary.path);
    expect(init['ok'], isTrue, reason: 'init_app failed: $init');
    await AppState.instance.bootstrap(temporary.path);
    final dirPath = temporary.path;
    final dbFile = File('$dirPath/er.sqlite');
    dbFile.createSync(recursive: true);
    final created = await Api.instance.createConnection(<String, dynamic>{
      'name': 'ER FFI',
      'driver': 'sqlite',
      'database': dbFile.path,
    });
    connectionId = ((created['connection'] as Map)['id']).toString();
    await AppState.instance.connect(connectionId);
    const fixtures = <String>[
      'CREATE TABLE authors (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)',
      'CREATE TABLE books (id INTEGER PRIMARY KEY AUTOINCREMENT, author_id INTEGER REFERENCES authors(id), title TEXT)',
      'CREATE TABLE reviews (id INTEGER PRIMARY KEY AUTOINCREMENT, book_id INTEGER REFERENCES books(id), body TEXT)',
      'CREATE TABLE t1 (id INTEGER PRIMARY KEY AUTOINCREMENT)',
      'CREATE TABLE t2 (id INTEGER PRIMARY KEY AUTOINCREMENT)',
      'CREATE TABLE t3 (id INTEGER PRIMARY KEY AUTOINCREMENT)',
      'CREATE TABLE t4 (id INTEGER PRIMARY KEY AUTOINCREMENT)',
      'CREATE TABLE t5 (id INTEGER PRIMARY KEY AUTOINCREMENT)',
      'CREATE TABLE t6 (id INTEGER PRIMARY KEY AUTOINCREMENT)',
      'CREATE TABLE people (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, score INTEGER)',
      'CREATE TABLE orders (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER)',
      'CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)',
      // 链式外键：c1 <- c2 <- c3 <- c4 <- c5 <- c6（测自动带入上限）。
      'CREATE TABLE c1 (id INTEGER PRIMARY KEY AUTOINCREMENT)',
      'CREATE TABLE c2 (id INTEGER PRIMARY KEY AUTOINCREMENT, c1_id INTEGER REFERENCES c1(id))',
      'CREATE TABLE c3 (id INTEGER PRIMARY KEY AUTOINCREMENT, c2_id INTEGER REFERENCES c2(id))',
      'CREATE TABLE c4 (id INTEGER PRIMARY KEY AUTOINCREMENT, c3_id INTEGER REFERENCES c3(id))',
      'CREATE TABLE c5 (id INTEGER PRIMARY KEY AUTOINCREMENT, c4_id INTEGER REFERENCES c4(id))',
      'CREATE TABLE c6 (id INTEGER PRIMARY KEY AUTOINCREMENT, c5_id INTEGER REFERENCES c5(id))',
      // 中间表：order_items 恰好两个外键指向 orders / products（多对多）。
      'CREATE TABLE categories (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)',
      'CREATE TABLE products (id INTEGER PRIMARY KEY AUTOINCREMENT, category_id INTEGER REFERENCES categories(id), name TEXT)',
      'CREATE TABLE order_items (id INTEGER PRIMARY KEY AUTOINCREMENT, order_id INTEGER REFERENCES orders(id), product_id INTEGER REFERENCES products(id))',
      // 没有外键、但列名暗示关系的表（建议关系）。
      'CREATE TABLE shops (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)',
      'CREATE TABLE members (id INTEGER PRIMARY KEY AUTOINCREMENT, shop_id INTEGER, name TEXT)',
      // 长类型名：验证类型列单行省略、不换行。
      'CREATE TABLE variants (id INTEGER PRIMARY KEY AUTOINCREMENT, code VARCHAR(255), note TEXT)',
      // 建议关系专用（无外键）：对应 golden B 的「仅建议关系」场景。
      'CREATE TABLE su_users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)',
      'CREATE TABLE su_categories (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)',
      'CREATE TABLE su_products (id INTEGER PRIMARY KEY AUTOINCREMENT, su_categories_id INTEGER, name TEXT)',
      'CREATE TABLE su_orders (id INTEGER PRIMARY KEY AUTOINCREMENT, su_users_id INTEGER)',
      'CREATE TABLE su_items (id INTEGER PRIMARY KEY AUTOINCREMENT, su_orders_id INTEGER, su_products_id INTEGER)',
    ];
    for (final sql in fixtures) {
      await Api.instance.query(sql);
    }
  });

  tearDownAll(() async {
    try {
      await Api.instance.disconnect();
    } catch (_) {}
    try {
      temporary.deleteSync(recursive: true);
    } catch (_) {}
    I18n.setLang(AppLang.zh);
  });

  testWidgets('SQLite：已有外键自动显示，移除表后关系消失', (tester) async {
    await setSurface(tester);
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['authors', 'books', 'reviews'],
          height: 520,
        ),
      ),
    );
    await settle(tester);

    expect(find.byKey(const ValueKey('er-node-authors')), findsOneWidget);
    expect(find.byKey(const ValueKey('er-node-books')), findsOneWidget);
    expect(find.byKey(const ValueKey('er-node-reviews')), findsOneWidget);
    expect(find.text('books.author_id → authors.id'), findsOneWidget);
    expect(find.text('reviews.book_id → books.id'), findsOneWidget);
    expect(find.text('已加入 3/10'), findsOneWidget);

    // 移除 books：它的外键边、以及 reviews → books 的边都不再显示。
    await tester.tap(find.byKey(const ValueKey('er-remove-books')));
    await settle(tester);
    expect(find.byKey(const ValueKey('er-node-books')), findsNothing);
    expect(find.text('books.author_id → authors.id'), findsNothing);
    expect(find.text('reviews.book_id → books.id'), findsNothing);
    expect(find.text('已加入 2/10'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('画布最多只加入 maxTables 张表', (tester) async {
    await setSurface(tester);
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['t1', 't2', 't3', 't4', 't5', 't6'],
          maxTables: 5,
          height: 520,
        ),
      ),
    );
    await settle(tester);
    for (final name in <String>['t1', 't2', 't3', 't4', 't5']) {
      expect(
        find.byKey(ValueKey('er-node-$name')),
        findsOneWidget,
        reason: 'node $name',
      );
    }
    expect(find.byKey(const ValueKey('er-node-t6')), findsNothing);
    expect(find.text('已加入 5/5'), findsOneWidget);
    // 画布满了以后「+ 添加表」禁用。
    final addButton = tester.widget<Btn>(
      find.byKey(const ValueKey('er-add-table')),
    );
    expect(addButton.onPressed, isNull);
  });

  testWidgets('空画布显示引导文案、主按钮与 SQLite 提示', (tester) async {
    await setSurface(tester);
    await tester.pumpWidget(
      host(RelationDesigner(database: 'main', height: 400)),
    );
    await settle(tester);
    expect(find.text('还没有添加表'), findsOneWidget);
    expect(
      find.text('添加表后，从字段两端的圆点拖到另一张表的字段即可创建外键'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('er-sqlite-hint')), findsOneWidget);
    expect(find.text('已加入 0/10'), findsOneWidget);
    // 空状态必须有主行动按钮（P2-5：文员看到空画布会以为功能坏了）。
    expect(find.byKey(const ValueKey('er-empty-add-table')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('er-empty-add-table')));
    await settle(tester, rounds: 6);
    expect(find.text('添加表'), findsWidgets);
    expect(find.byKey(const ValueKey('er-picker-books')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dialog-close')));
    await settle(tester, rounds: 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('seed 表自动带入关联表；可撤销且不自动加回', (tester) async {
    await setSurface(tester);
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['authors'],
          height: 520,
        ),
      ),
    );
    await settle(tester);
    expect(find.byKey(const ValueKey('er-node-authors')), findsOneWidget);
    expect(find.byKey(const ValueKey('er-node-books')), findsOneWidget);
    expect(find.byKey(const ValueKey('er-node-reviews')), findsOneWidget);
    expect(find.text('已加入 3/10'), findsOneWidget);
    expect(find.byKey(const ValueKey('er-auto-added-hint')), findsOneWidget);
    expect(find.text('已自动加入关联表：books、reviews'), findsOneWidget);
    // 自动带入的外键直接画出来。
    expect(find.text('books.author_id → authors.id'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('er-undo-auto')));
    await settle(tester);
    expect(find.byKey(const ValueKey('er-node-books')), findsNothing);
    expect(find.byKey(const ValueKey('er-node-reviews')), findsNothing);
    expect(find.byKey(const ValueKey('er-auto-added-hint')), findsNothing);
    expect(find.text('已加入 1/10'), findsOneWidget);

    // 手动再加一张无外键的表：撤销掉的关联表不能被自动带回来。
    await tester.tap(find.byKey(const ValueKey('er-add-table')));
    await settle(tester, rounds: 4);
    await tester.enterText(find.byType(TextField).last, 't1');
    await settle(tester, rounds: 3);
    await tester.tap(find.byKey(const ValueKey('er-picker-t1')));
    await settle(tester, rounds: 3);
    await tester.tap(find.byKey(const ValueKey('er-picker-join')));
    await settle(tester);
    expect(find.byKey(const ValueKey('er-node-t1')), findsOneWidget);
    expect(find.byKey(const ValueKey('er-node-books')), findsNothing);
    expect(find.byKey(const ValueKey('er-node-reviews')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自动带入最多到画布上限 5 张', (tester) async {
    await setSurface(tester);
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['c1'],
          maxTables: 5,
          height: 520,
        ),
      ),
    );
    await settle(tester);
    for (final name in <String>['c1', 'c2', 'c3', 'c4', 'c5']) {
      expect(find.byKey(ValueKey('er-node-$name')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('er-node-c6')), findsNothing);
    expect(find.text('已加入 5/5'), findsOneWidget);
    expect(find.text('已自动加入关联表：c2、c3、c4、c5'), findsOneWidget);
  });

  testWidgets('中间表徽标、多对多连线与折叠 / 展开', (tester) async {
    await setSurface(tester);
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>[
            'orders',
            'products',
            'categories',
            'order_items',
          ],
          height: 520,
        ),
      ),
    );
    await settle(tester);
    expect(find.byKey(const ValueKey('er-node-order_items')), findsOneWidget);
    expect(find.text('中间表（多对多）'), findsOneWidget);
    expect(find.text('多对多 · order_items'), findsOneWidget);

    // 折叠：节点和它的两条 FK 边隐藏，两端多对多连线保留。
    await tester.tap(find.byKey(const ValueKey('er-collapse-order_items')));
    await settle(tester);
    expect(find.byKey(const ValueKey('er-node-order_items')), findsNothing);
    expect(find.text('多对多 · order_items'), findsOneWidget);

    // 点多对多标签展开。
    await tester.tap(find.byKey(const ValueKey('er-m2m-order_items')));
    await settle(tester);
    expect(find.byKey(const ValueKey('er-node-order_items')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('列名建议关系：虚线标签 + 建立建议外键按钮（SQLite 禁用）', (tester) async {
    await setSurface(tester);
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['members', 'shops'],
          height: 520,
        ),
      ),
    );
    await settle(tester);
    expect(find.byKey(const ValueKey('er-node-members')), findsOneWidget);
    // 标签降噪：默认只显示小号「建议」胶囊，完整文案在 tooltip。
    expect(find.text('建议'), findsOneWidget);
    expect(find.textContaining('members.shop_id → shops.id'), findsNothing);
    final suggestionTooltip = tester.widget<app_tooltip.Tooltip>(
      find
          .ancestor(
            of: find.text('建议'),
            matching: find.byType(app_tooltip.Tooltip),
          )
          .first,
    );
    expect(suggestionTooltip.message, contains('members.shop_id → shops.id'));
    expect(
      find.byKey(const ValueKey('er-suggestion-members.shop_id>shops.id')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('er-apply-suggestions')), findsOneWidget);
    expect(find.text('建立建议外键 (1)'), findsOneWidget);
    // SQLite 不能 ALTER 加外键，但按钮仍然可点：点击给出明确说明（不再静默禁用）。
    final applyButton = tester.widget<Btn>(
      find.byKey(const ValueKey('er-apply-suggestions')),
    );
    expect(applyButton.onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('er-apply-suggestions')));
    await settle(tester);
    expect(find.text('SQLite 不支持用 ALTER 新增外键'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dialog-close')));
    await settle(tester, rounds: 2);

    // 点击「建议」胶囊（等价点击建议虚线）同样给出 SQLite 说明，而不是无反应。
    await tester.tap(
      find.byKey(const ValueKey('er-suggestion-members.shop_id>shops.id')),
    );
    await settle(tester);
    expect(find.text('SQLite 不支持用 ALTER 新增外键'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dialog-close')));
    await settle(tester, rounds: 2);

    // 帮助入口说明建议是怎么推导的。
    await tester.tap(find.byKey(const ValueKey('er-suggestion-help')));
    await settle(tester);
    expect(find.text('建议关系是怎么推导的？'), findsOneWidget);
    expect(find.textContaining('members.shop_id'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('dialog-close')));
    await settle(tester, rounds: 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('添加表弹窗：搜索 + 复选 + 加入（之后自动带入关联表）', (tester) async {
    await setSurface(tester);
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['people'],
          height: 520,
        ),
      ),
    );
    await settle(tester);
    expect(find.byKey(const ValueKey('er-node-books')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('er-add-table')));
    await settle(tester, rounds: 4);
    // 已在画布上的表仍然列出，但不可再勾选（灰显 + 已加入）。
    await tester.enterText(find.byType(TextField).last, 'people');
    await settle(tester, rounds: 3);
    final existing = tester.widget<InkWell>(
      find.byKey(const ValueKey('er-picker-people')),
    );
    expect(existing.onTap, isNull);
    expect(find.text('已加入'), findsOneWidget);

    // 搜索缩小列表。
    await tester.enterText(find.byType(TextField).last, 'book');
    await settle(tester, rounds: 3);
    expect(find.byKey(const ValueKey('er-picker-books')), findsOneWidget);
    expect(find.byKey(const ValueKey('er-picker-reviews')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('er-picker-books')));
    await settle(tester, rounds: 3);
    await tester.tap(find.byKey(const ValueKey('er-picker-join')));
    await settle(tester);
    expect(find.byKey(const ValueKey('er-node-books')), findsOneWidget);
    // 加入 books 后自动带入关联的 authors / reviews，外键自动画出来。
    expect(find.byKey(const ValueKey('er-node-authors')), findsOneWidget);
    expect(find.byKey(const ValueKey('er-node-reviews')), findsOneWidget);
    expect(find.text('books.author_id → authors.id'), findsOneWidget);
    expect(find.byKey(const ValueKey('er-auto-added-hint')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SQLite 下连接点禁用并给出提示', (tester) async {
    await setSurface(tester);
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['authors', 'books'],
          height: 520,
        ),
      ),
    );
    await settle(tester);
    expect(find.byKey(const ValueKey('er-sqlite-hint')), findsOneWidget);
    // 字段行左右两端都有连接点，SQLite 下都禁用（ALTER 不能加外键）。
    final rightDot = tester.widget<GestureDetector>(
      find.byKey(const ValueKey('er-connect-books-author_id')),
    );
    expect(rightDot.onPanStart, isNull, reason: '右连接点在 SQLite 下必须禁用');
    final leftDot = tester.widget<GestureDetector>(
      find.byKey(const ValueKey('er-connect-left-books-author_id')),
    );
    expect(leftDot.onPanStart, isNull, reason: '左连接点在 SQLite 下必须禁用');
    // 只读：已有外键仍然显示。
    expect(find.text('books.author_id → authors.id'), findsOneWidget);
  });

  testWidgets('关系标签默认隐藏，hover / 选中才显示', (tester) async {
    await setSurface(tester);
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['authors', 'books'],
          height: 520,
        ),
      ),
    );
    await settle(tester);
    const booksLabel = 'books.author_id → authors.id';
    Opacity labelOpacity() => tester.widget<Opacity>(
      find
          .ancestor(of: find.text(booksLabel), matching: find.byType(Opacity))
          .first,
    );

    // 默认不绘制（仍在树里，方便命中/可访问性）。
    expect(find.text(booksLabel), findsOneWidget);
    expect(labelOpacity().opacity, 0);

    // hover 到曲线中点（标签锚点）→ 显示。
    final center = tester.getCenter(find.text(booksLabel));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: center);
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.moveTo(center);
    await settle(tester, rounds: 3);
    expect(labelOpacity().opacity, 1);

    // 移开 → 再次隐藏。
    await mouse.moveTo(const Offset(2, 2));
    await settle(tester, rounds: 3);
    expect(labelOpacity().opacity, 0);

    // 点击边（标签位置落在曲线上）→ 打开详情，关闭后保持选中高亮。
    await tester.tapAt(tester.getCenter(find.text(booksLabel)));
    await settle(tester, rounds: 6);
    expect(find.text('外键关系'), findsWidgets);
    await tester.tap(find.widgetWithText(Btn, '关闭'));
    await settle(tester, rounds: 12);
    expect(labelOpacity().opacity, 1, reason: '选中后关系标签保持显示');
    expect(tester.takeException(), isNull);
  });

  testWidgets('类型列单行省略，不换行', (tester) async {
    await setSurface(tester);
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['variants'],
          height: 420,
        ),
      ),
    );
    await settle(tester);
    // 中文界面：画布类型列说人话；完整 SQL 类型放进 Tooltip（P2-1）。
    final typeTexts = tester
        .widgetList<app_text.Text>(find.byType(app_text.Text))
        .where((widget) => widget.data == '文本（VARCHAR(255)）')
        .toList();
    expect(typeTexts.length, 1);
    expect(typeTexts.single.maxLines, 1);
    expect(typeTexts.single.softWrap, isFalse);
    final typeTooltip = tester.widget<app_tooltip.Tooltip>(
      find
          .ancestor(
            of: find.text('文本（VARCHAR(255)）'),
            matching: find.byType(app_tooltip.Tooltip),
          )
          .first,
    );
    expect(typeTooltip.message, contains('VARCHAR(255)'));
    expect(typeTooltip.message, contains('有长度上限的文本'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('边层先画、卡片后画（卡片遮挡穿过的线）', (tester) async {
    await setSurface(tester);
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['authors', 'books'],
          height: 520,
        ),
      ),
    );
    await settle(tester);
    final stack = tester.widget<Stack>(
      find.byKey(const ValueKey('er-canvas-stack')),
    );
    expect(
      stack.children.first.key,
      const ValueKey('er-edge-layer'),
      reason: '边层必须是 Stack 的第一个孩子（画在卡片下面）',
    );
    expect(
      stack.children.indexWhere(
        (child) => child.key == const ValueKey('er-node-layer-books'),
      ),
      greaterThan(0),
      reason: '卡片必须画在边层之后',
    );
    expect(
      stack.children.indexWhere(
        (child) => child.key == const ValueKey('er-node-layer-authors'),
      ),
      greaterThan(0),
    );
  });

  testWidgets('分层布局：子表在左、被引用父表在右', (tester) async {
    await setSurface(tester);
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['c1'],
          maxTables: 5,
          height: 520,
        ),
      ),
    );
    await settle(tester);
    double xOf(String name) =>
        tester.getTopLeft(find.byKey(ValueKey('er-node-$name'))).dx;
    // c2 → c1、c3 → c2：被引用的父表逐层往右。
    expect(xOf('c1'), greaterThan(xOf('c2')));
    expect(xOf('c2'), greaterThan(xOf('c3')));
    expect(xOf('c3'), greaterThan(xOf('c4')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('建议关系场景：同源两条边上下不交叉', (tester) async {
    await setSurface(tester);
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>[
            'su_users',
            'su_categories',
            'su_products',
            'su_orders',
            'su_items',
          ],
          height: 820,
        ),
      ),
    );
    await settle(tester);
    double yOf(String name) =>
        tester.getTopLeft(find.byKey(ValueKey('er-node-$name'))).dy;
    // su_items 的 su_orders_id 在 su_products_id 上面 → su_orders 必须排在
    // su_products 上面，否则两条建议边会交叉成 X。
    expect(yOf('su_orders'), lessThan(yOf('su_products')));
    expect(yOf('su_users'), lessThan(yOf('su_categories')));
    // 4 条建议虚线，各带一个小「建议」胶囊。
    expect(find.text('建议'), findsNWidgets(4));
    expect(find.text('建立建议外键 (4)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SQLite：中间表通过 createTable 一次建表成功', (tester) async {
    await setSurface(tester);
    final schema = await tester.runAsync(
      () => Api.instance.builderSchema('main'),
    );
    final rows = erRowsOf(schema!['tables']);
    final byName = <String, Map<String, dynamic>>{
      for (final row in rows) erStringOf(row['name']): row,
    };
    final orders = ErTable.fromSchema(byName['orders']!);
    final users = ErTable.fromSchema(byName['users']!);
    expect(orders.primaryColumn?.name, 'id');
    expect(users.primaryColumn?.name, 'id');

    final plan = planJunction(
      driver: ErDriver.sqlite,
      localTable: orders,
      refTable: users,
      existingTableNames: byName.keys.toSet(),
    );
    expect(plan, isNotNull);
    expect(plan!.idType, 'INTEGER');

    await tester.runAsync(
      () => Api.instance.createTable('main', plan.createTableBody()),
    );
    final structure = await tester.runAsync(
      () => Api.instance.structure('main', plan.name),
    );
    final columns = erRowsOf(structure!['columns']);
    final foreignKeys = erRowsOf(structure['foreign_keys']);
    expect(columns.length, 3, reason: 'id + 两个外键列: $columns');
    expect(erStringOf(columns.first['COLUMN_KEY']), 'PRI');
    expect(foreignKeys.length, 2, reason: '两个内联外键: $foreignKeys');

    // 画布上 junction 表 + 两条关系（SQLite 无约束名，标签是 表.字段 → 表.字段）。
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: <String>['orders', 'users', plan.name],
          height: 520,
        ),
      ),
    );
    await settle(tester);
    expect(find.byKey(ValueKey('er-node-${plan.name}')), findsOneWidget);
    expect(find.text('orders_users.orders_id → orders.id'), findsOneWidget);
    expect(find.text('orders_users.users_id → users.id'), findsOneWidget);
    // 恰好两个外键指向两张实体表 → 徽标 + 两端多对多连线。
    // （自动带入的关联表也可能成为中间表，所以徽标数量用 findsWidgets。）
    expect(find.text('中间表（多对多）'), findsWidgets);
    expect(find.text('多对多 · orders_users'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact 模式嵌入向导：1 张 3 列表格 height 440 不溢出', (tester) async {
    await setSurface(tester);
    // 模拟 quick-create 向导第 4 步：SingleChildScrollView 里放 compact 设计器。
    await tester.pumpWidget(
      host(
        SingleChildScrollView(
          child: RelationDesigner(
            database: 'main',
            initialTables: const <String>['people'],
            compact: true,
            height: 440,
          ),
        ),
      ),
    );
    await settle(tester);
    expect(find.byKey(const ValueKey('er-node-people')), findsOneWidget);
    final box = tester.getSize(find.byKey(const ValueKey('er-node-people')));
    expect(box.width, 200, reason: 'compact 卡片宽度');
    // 修复前 Container 边框会把内容缩进 1px，导致节点 Column 底部溢出 2px。
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击关系标签打开外键详情；SQLite 下删除按钮禁用', (tester) async {
    await setSurface(tester);
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['authors', 'books'],
          height: 520,
        ),
      ),
    );
    await settle(tester);
    // 标签默认隐藏，直接点线（标签锚点在曲线上）。
    await tester.tapAt(
      tester.getCenter(find.text('books.author_id → authors.id')),
    );
    await settle(tester, rounds: 5);
    expect(find.text('外键关系'), findsWidgets);
    expect(find.text('books.author_id'), findsOneWidget);
    expect(find.text('authors.id'), findsOneWidget);
    // SQLite 不能用 ALTER 删除外键：按钮存在但禁用。
    final deleteButton = tester.widget<Btn>(find.widgetWithText(Btn, '删除关系'));
    expect(deleteButton.onPressed, isNull);
    await tester.tap(find.widgetWithText(Btn, '关闭'));
    await settle(tester, rounds: 12); // 等对话框退出动画结束
    expect(find.text('books.author_id'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('画布上方图例说明外键方向与线型', (tester) async {
    await setSurface(tester);
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['authors', 'books'],
          height: 520,
        ),
      ),
    );
    await settle(tester);
    expect(find.byKey(const ValueKey('er-legend')), findsOneWidget);
    expect(find.text('外键关系：'), findsOneWidget);
    // 与画布箭头方向一致：被约束（子表外键列）→ 约束（父表被引用主键）。
    expect(find.text('被约束（外键列 / 子表）'), findsOneWidget);
    expect(find.text('约束（被引用主键 / 父表）'), findsOneWidget);
    expect(find.textContaining('虚线=建议外键'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_forward), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('前置校验失败时错误对话框可返回字段修改', (tester) async {
    await setSurface(tester);
    var backCalled = false;
    final local = ErTable(
      name: 'books',
      columns: const <ErColumn>[
        ErColumn(name: 'id', typeName: 'INTEGER', primary: true),
        ErColumn(name: 'category_id', typeName: 'INTEGER'),
      ],
    );
    final ref = ErTable(
      name: 'categories',
      columns: const <ErColumn>[
        ErColumn(name: 'id', typeName: 'INTEGER', primary: true),
        ErColumn(name: 'name', typeName: 'TEXT'),
      ],
    );
    final issue = validateForeignKeyCandidate(
      localTable: local,
      localColumn: 'category_id',
      refTable: ref,
      refColumn: 'name',
    );
    expect(issue, isNotNull);
    expect(issue!.kind, ErFkIssueKind.refColumnNotUnique);
    final message = erFkIssueMessage(issue);
    expect(message, contains('categories.name'));
    expect(message, contains('不是主键或单列唯一列'));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Btn(
              'open',
              onPressed: () => showForeignKeyBlockedDialog(
                context,
                message: message,
                onRequestEditFields: () => backCalled = true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester, rounds: 6);
    expect(find.text('无法创建外键'), findsWidgets);
    expect(find.text(message), findsOneWidget);
    expect(find.byKey(const ValueKey('er-back-to-fields')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('er-back-to-fields')));
    await settle(tester, rounds: 10);
    expect(backCalled, isTrue);
    expect(find.text('无法创建外键'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未传 onRequestEditFields 时不显示返回字段按钮', (tester) async {
    await setSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Btn(
              'open',
              onPressed: () => showForeignKeyBlockedDialog(
                context,
                message: '表 logs 没有主键，无法创建外键。',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester, rounds: 6);
    expect(find.text('无法创建外键'), findsWidgets);
    expect(find.byKey(const ValueKey('er-back-to-fields')), findsNothing);
    expect(find.widgetWithText(Btn, '关闭'), findsOneWidget);
  });

  testWidgets('SQLite 建议外键提示里可返回字段修改', (tester) async {
    await setSurface(tester);
    var backCalled = false;
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['members', 'shops'],
          height: 520,
          onRequestEditFields: () => backCalled = true,
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('er-apply-suggestions')));
    await settle(tester, rounds: 6);
    expect(find.text('SQLite 不支持用 ALTER 新增外键'), findsWidgets);
    expect(find.byKey(const ValueKey('er-back-to-fields')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('er-back-to-fields')));
    await settle(tester, rounds: 10);
    expect(backCalled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('showRelationDesigner 作为对话框入口可用', (tester) async {
    await setSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Btn(
              'open',
              onPressed: () => showRelationDesigner(
                context,
                database: 'main',
                initialTables: const <String>['authors'],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester, rounds: 8);
    expect(find.text('E-R 关系图'), findsWidgets);
    expect(find.byKey(const ValueKey('er-node-authors')), findsOneWidget);
    expect(find.widgetWithText(Btn, '关闭'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('英文模式：工具条与画布无中文残留', (tester) async {
    I18n.setLang(AppLang.en);
    addTearDown(() => I18n.setLang(AppLang.zh));
    await setSurface(tester);
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['authors', 'books'],
          height: 480,
        ),
      ),
    );
    await settle(tester);
    expect(find.text('E-R diagram'), findsOneWidget);
    expect(find.text('+ Add table'), findsOneWidget);
    // authors/books + 自动带入的 reviews。
    expect(find.text('Added 3/10'), findsOneWidget);
    expect(
      find.text('Related tables added automatically: reviews'),
      findsOneWidget,
    );
    expect(find.text('Undo auto-add'), findsOneWidget);
    // 画布上方图例（英文）。
    expect(find.text('Constrained (FK column / child)'), findsOneWidget);
    expect(find.text('Constraining (referenced key / parent)'), findsOneWidget);
    expect(find.textContaining('dashed = suggested FK'), findsOneWidget);
    expect(find.byKey(const ValueKey('er-sqlite-hint')), findsOneWidget);
    // 表名 / 列名 / 箭头标签是数据，其它可见文案必须是英文。
    final offenders = <String>{};
    for (final widget in tester.allWidgets) {
      if (widget is app_text.Text) {
        final rendered = lit.trLiteral(widget.data);
        if (RegExp(r'[一-鿿]').hasMatch(rendered)) {
          offenders.add(rendered);
        }
      }
    }
    expect(offenders, isEmpty, reason: '未翻译的中文: $offenders');
    expect(find.text('books.author_id → authors.id'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('英文模式：多对多徽标与建议关系文案', (tester) async {
    I18n.setLang(AppLang.en);
    addTearDown(() => I18n.setLang(AppLang.zh));
    await setSurface(tester);
    await tester.pumpWidget(
      host(
        RelationDesigner(
          key: UniqueKey(),
          database: 'main',
          initialTables: const <String>[
            'orders',
            'products',
            'categories',
            'order_items',
          ],
          height: 520,
        ),
      ),
    );
    await settle(tester);
    expect(find.text('Junction table (many-to-many)'), findsWidgets);
    expect(find.text('many-to-many · order_items'), findsOneWidget);

    // 建议关系：虚线标签与批量按钮也都是英文。
    await tester.pumpWidget(
      host(
        RelationDesigner(
          key: UniqueKey(),
          database: 'main',
          initialTables: const <String>['members', 'shops'],
          height: 520,
        ),
      ),
    );
    await settle(tester);
    expect(find.text('Suggested'), findsOneWidget);
    expect(find.text('Create suggested FKs (1)'), findsOneWidget);
    expect(find.byKey(const ValueKey('er-sqlite-hint')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('中文动作文案不出现 SQL 关键字；英文界面才显示 SQL', () {
    for (final action in kErFkActions) {
      final deleteLabel = erFkActionLabel(action, onDelete: true);
      final updateLabel = erFkActionLabel(action, onDelete: false);
      for (final label in <String>[deleteLabel, updateLabel]) {
        expect(label.contains('CASCADE'), isFalse, reason: label);
        expect(label.contains('SET NULL'), isFalse, reason: label);
        expect(label.contains('RESTRICT'), isFalse, reason: label);
      }
    }
    expect(erFkActionLabel('CASCADE', onDelete: true), '级联（一并删除子行）');
    expect(erFkActionLabel('SET NULL', onDelete: true), '置空（仅可空字段）');

    I18n.setLang(AppLang.en);
    addTearDown(() => I18n.setLang(AppLang.zh));
    expect(erFkActionLabel('CASCADE', onDelete: true), 'ON DELETE CASCADE');
    expect(erFkActionLabel('SET NULL', onDelete: false), 'ON UPDATE SET NULL');
    expect(erFkActionLabel('', onDelete: true), 'NO ACTION');
  });

  test('整数位宽不兼容的提示直接点名原因与两端列', () {
    final local = ErTable(name: 'orders', columns: const <ErColumn>[
      ErColumn(name: 'id', typeName: 'INT', primary: true),
      ErColumn(name: 'user_id', typeName: 'INT'),
    ]);
    final ref = ErTable(name: 'users', columns: const <ErColumn>[
      ErColumn(name: 'id', typeName: 'BIGINT', primary: true),
    ]);
    final issue = validateForeignKeyCandidate(
      localTable: local,
      localColumn: 'user_id',
      refTable: ref,
      refColumn: 'id',
    );
    expect(issue!.kind, ErFkIssueKind.typeIncompatible);
    final message = erFkIssueMessage(issue);
    expect(message, contains('orders.user_id'));
    expect(message, contains('users.id'));
    expect(message, contains('整数位宽或无符号不一致'));
    expect(message, contains('同一类型'));
  });

  testWidgets('英文模式：返回字段按钮与建议帮助 tooltip 也是英文', (tester) async {
    I18n.setLang(AppLang.en);
    addTearDown(() => I18n.setLang(AppLang.zh));
    await setSurface(tester);
    var backCalled = false;
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['authors', 'books'],
          height: 520,
        ),
      ),
    );
    await settle(tester);
    // 帮助入口的 tooltip 不是 Text，english_ui_test 的文本扫描覆盖不到，
    // 这里单独断言（P2-12：英文模式不能出现中文）。
    final helpTooltip = tester.widget<app_tooltip.Tooltip>(
      find
          .descendant(
            of: find.byKey(const ValueKey('er-suggestion-help')),
            matching: find.byType(app_tooltip.Tooltip),
          )
          .first,
    );
    expect(helpTooltip.message, 'How are suggested relations derived?');

    final context = tester.element(find.byType(RelationDesigner));
    final dialog = showForeignKeyBlockedDialog(
      context,
      message: 'Blocked by the local check',
      onRequestEditFields: () => backCalled = true,
    );
    await settle(tester, rounds: 6);
    expect(find.text('Cannot create the foreign key'), findsOneWidget);
    expect(find.text('Back to worksheets and fields'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('er-back-to-fields')));
    await settle(tester, rounds: 8);
    await dialog;
    expect(backCalled, isTrue);
    expect(tester.takeException(), isNull);
  });

  test('alterTableErrors：数据库失败不会被当成成功（P0-1 回归）', () {
    expect(
      alterTableErrors(<String, dynamic>{
        'failed': 0,
        'results': <dynamic>[
          <String, dynamic>{'statement': 'ALTER ...', 'error': null},
        ],
      }),
      isEmpty,
    );
    expect(
      alterTableErrors(<String, dynamic>{
        'failed': 1,
        'results': <dynamic>[
          <String, dynamic>{
            'statement': 'ALTER ...',
            'error': 'ERROR 3780 (HY000): Referencing column ... are incompatible.',
          },
        ],
      }),
      <String>[
        'ERROR 3780 (HY000): Referencing column ... are incompatible.',
      ],
    );
    // 只有 failed 计数、没有 error 文本时也要给出兜底错误，不能静默。
    expect(
      alterTableErrors(<String, dynamic>{
        'failed': 2,
        'results': <dynamic>[],
      }),
      hasLength(1),
    );
    expect(alterTableErrors(<String, dynamic>{}), isEmpty);
  });
}
