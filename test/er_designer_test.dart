// E-R 关系设计器的端到端测试：SQLite 真库 + 真实 FFI。
//
// 覆盖 §5.3 的验收点：
//  * 已有外键自动显示；移除表后关系消失；
//  * 添加表弹窗（搜索 / 复选 / 加入）与画布上限；
//  * SQLite 下连接点禁用并给出原因（ALTER 不能增删外键）；
//  * 多对多中间表通过 createTable 一次建表成功（SQLite 内联外键）；
//  * 中文动作文案不出现 SQL 关键字，英文界面才出现。

import 'dart:async';
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
    expect(find.text('已加入 3/20'), findsOneWidget);

    // 移除 books：它的外键边、以及 reviews → books 的边都不再显示。
    await tester.tap(find.byKey(const ValueKey('er-remove-books')));
    await settle(tester);
    expect(find.byKey(const ValueKey('er-node-books')), findsNothing);
    expect(find.text('books.author_id → authors.id'), findsNothing);
    expect(find.text('reviews.book_id → books.id'), findsNothing);
    expect(find.text('已加入 2/20'), findsOneWidget);
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
    // 第 68 轮 P3-04：画布满时按钮 tooltip 说明上限与做法。
    expect(addButton.tooltip, contains('已达画布上限 5 张'));
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
    expect(find.text('已加入 0/20'), findsOneWidget);
    // 第 68 轮 P3-04：默认画布上限从 10 提高到 20。
    expect(
      tester.widget<RelationDesigner>(find.byType(RelationDesigner)).maxTables,
      20,
    );
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
    expect(find.text('已加入 3/20'), findsOneWidget);
    expect(find.byKey(const ValueKey('er-auto-added-hint')), findsOneWidget);
    expect(find.text('已自动加入关联表：books、reviews'), findsOneWidget);
    // 自动带入的外键直接画出来。
    expect(find.text('books.author_id → authors.id'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('er-undo-auto')));
    await settle(tester);
    expect(find.byKey(const ValueKey('er-node-books')), findsNothing);
    expect(find.byKey(const ValueKey('er-node-reviews')), findsNothing);
    expect(find.byKey(const ValueKey('er-auto-added-hint')), findsNothing);
    expect(find.text('已加入 1/20'), findsOneWidget);

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
    // P2-8：被画布上限截断时，工具栏下方必须给出可关闭的说明（原来静默截断）。
    final notice = tester.widget<AlertBox>(
      find.byKey(const ValueKey('er-auto-include-notice')),
    );
    expect(notice.tone, AlertTone.warn);
    expect(notice.message, contains('已自动加入 4 张'));
    expect(notice.message, contains('已达画布上限 5 张'));
    // 第 68 轮 P3-04：明确还有几张关联表未加入。
    expect(notice.message, contains('还有 1 张关联表未加入'));
    expect(notice.message, contains('分批添加'));
    // 可关闭：关掉后提示不再出现。
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('er-auto-include-notice')),
        matching: find.byType(IconBtn),
      ),
    );
    await settle(tester);
    expect(find.byKey(const ValueKey('er-auto-include-notice')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('默认画布上限 20 张：14 张关联表可一次自动带入（第68轮 P3-04）',
      (tester) async {
    await setSurface(tester);
    Directory? directory;
    final chainId = await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('rma-er-cap20-');
      final dbFile = File('${directory!.path}/cap20.sqlite');
      await dbFile.create(recursive: true);
      final created = await Api.instance.createConnection(<String, dynamic>{
        'name': 'ER cap20',
        'driver': 'sqlite',
        'database': dbFile.path,
      });
      final id = ((created['connection'] as Map)['id']).toString();
      await AppState.instance.connect(id);
      for (var i = 1; i <= 14; i++) {
        final fk = i == 1
            ? ''
            : ', k${i - 1}_id INTEGER REFERENCES k${i - 1}(id)';
        await Api.instance.query(
            'CREATE TABLE k$i (id INTEGER PRIMARY KEY AUTOINCREMENT$fk)');
      }
      return id;
    });
    expect(chainId, isNotNull);
    addTearDown(() {
      try {
        directory?.deleteSync(recursive: true);
      } catch (_) {}
    });
    // 恢复共享 fixture 的主连接（后注册的 tearDown 先执行）。
    addTearDown(() async {
      try {
        await AppState.instance.connect(connectionId);
      } catch (_) {}
    });

    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['k1'],
          height: 520,
        ),
      ),
    );
    // 13 张关联表要逐个读取，等待轮数比普通场景更多。
    await settle(tester, rounds: 40);

    // 旧上限 10 会在第 10 张截断；默认 20 应一次带入整条链（1 + 13 = 14）。
    expect(find.text('已加入 14/20'), findsOneWidget);
    for (var i = 1; i <= 14; i++) {
      expect(
        find.byKey(ValueKey('er-node-k$i')),
        findsOneWidget,
        reason: 'node k$i',
      );
    }
    // 没有被上限截断，所以不显示「已达上限」提示。
    expect(find.byKey(const ValueKey('er-auto-include-notice')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('撤销自动加入后清空「已达上限」说明（P2-8）', (tester) async {
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
    expect(find.byKey(const ValueKey('er-auto-include-notice')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('er-undo-auto')));
    await settle(tester);
    // 撤销后自动加入的表与「已达上限」说明都必须一起消失。
    expect(find.byKey(const ValueKey('er-auto-added-hint')), findsNothing);
    expect(find.byKey(const ValueKey('er-auto-include-notice')), findsNothing);
    expect(find.text('已加入 1/5'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('数据库没有外键：自动带入给出说明而不是静默（P2-8）', (tester) async {
    await setSurface(tester);
    // 共享 fixture 库里到处是外键，这里临时切换到只有普通表的 SQLite 库。
    // 文件 IO 也要放进 runAsync：testWidgets 的 FakeAsync 不会推进真实 IO。
    Directory? directory;
    final noFkId = await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('rma-er-nofk-');
      final dbFile = File('${directory!.path}/nofk.sqlite');
      await dbFile.create(recursive: true);
      final created = await Api.instance.createConnection(<String, dynamic>{
        'name': 'ER NoFK',
        'driver': 'sqlite',
        'database': dbFile.path,
      });
      final id = ((created['connection'] as Map)['id']).toString();
      await AppState.instance.connect(id);
      await Api.instance.query(
        'CREATE TABLE standalone (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)',
      );
      await Api.instance.query(
        'CREATE TABLE plain (id INTEGER PRIMARY KEY AUTOINCREMENT)',
      );
      return id;
    });
    expect(noFkId, isNotNull);
    addTearDown(() {
      try {
        directory?.deleteSync(recursive: true);
      } catch (_) {}
    });
    // 恢复共享 fixture 的主连接（后注册的 tearDown 先执行）。
    addTearDown(() async {
      try {
        await AppState.instance.connect(connectionId);
      } catch (_) {}
    });

    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['standalone'],
          height: 520,
        ),
      ),
    );
    await settle(tester);
    expect(find.byKey(const ValueKey('er-node-standalone')), findsOneWidget);
    // 没有外键 → 不会凭列名乱加表。
    expect(find.byKey(const ValueKey('er-node-plain')), findsNothing);
    expect(find.byKey(const ValueKey('er-auto-added-hint')), findsNothing);
    final notice = tester.widget<AlertBox>(
      find.byKey(const ValueKey('er-auto-include-notice')),
    );
    expect(notice.tone, AlertTone.info);
    expect(notice.message, contains('当前数据库还没有外键'));
    expect(notice.message, contains('只能沿已有外键'));
    expect(notice.message, contains('建议外键'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除外键前二次确认：取消不删、确认才继续（P2-9）', (tester) async {
    await setSurface(tester);
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Btn(
              'open delete confirm',
              key: const ValueKey('er-open-delete-confirm'),
              onPressed: () async {
                result = await confirmDeleteForeignKeyDialog(
                  context,
                  constraintName: 'fk_books_author',
                );
              },
            ),
          ),
        ),
      ),
    );

    Finder confirmMessage() => find.byWidgetPredicate(
      (widget) =>
          widget is SelectableText &&
          (widget.data ?? '').contains('fk_books_author'),
    );

    await tester.tap(find.byKey(const ValueKey('er-open-delete-confirm')));
    await settle(tester, rounds: 8);
    expect(find.text('请确认'), findsOneWidget);
    // 必须说清楚「只解除引用约束、不删数据、之后可重建」。
    expect(confirmMessage(), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText && (widget.data ?? '').contains('数据不会删除'),
      ),
      findsOneWidget,
    );
    // 取消：确认框返回 false，不执行 ALTER。
    await tester.tap(find.widgetWithText(Btn, '取消'));
    await settle(tester, rounds: 8);
    expect(result, isFalse);
    expect(find.text('请确认'), findsNothing);

    // 再来一次并确认：返回 true（调用方才继续 ALTER）。
    await tester.tap(find.byKey(const ValueKey('er-open-delete-confirm')));
    await settle(tester, rounds: 8);
    await tester.tap(find.widgetWithText(Btn, '删除'));
    await settle(tester, rounds: 8);
    expect(result, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('工具栏术语说明按钮打开术语表（P3）', (tester) async {
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
    expect(find.byKey(const ValueKey('er-glossary')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('er-glossary')));
    await settle(tester, rounds: 8);
    expect(find.text('术语说明（说人话版）'), findsOneWidget);
    expect(find.text('主键'), findsWidgets);
    expect(find.text('FOREIGN KEY'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('glossary-close')));
    await settle(tester, rounds: 8);
    expect(find.text('术语说明（说人话版）'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关系列表侧栏：打开 / 搜索 / 无匹配 / 关闭（P2-5）', (tester) async {
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
    expect(find.byKey(const ValueKey('er-relation-list-panel')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('er-relation-list-toggle')));
    await settle(tester);
    final panel = find.byKey(const ValueKey('er-relation-list-panel'));
    expect(panel, findsOneWidget);
    expect(find.text('关系列表（2 条）'), findsOneWidget);
    expect(
      find.descendant(
        of: panel,
        matching: find.text('books.author_id → authors.id'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: panel,
        matching: find.text('reviews.book_id → books.id'),
      ),
      findsOneWidget,
    );
    // 第 55 轮：260px 面板里长关系名会被省略号截断，行 tooltip 必须给全名。
    final rowTooltip = tester.widget<app_tooltip.Tooltip>(
      find
          .ancestor(
            of: find.descendant(
              of: panel,
              matching: find.text('books.author_id → authors.id'),
            ),
            matching: find.byType(app_tooltip.Tooltip),
          )
          .first,
    );
    expect(rowTooltip.message, contains('books.author_id → authors.id'));
    // 未注入 driverOverride 时是 SQLite：真实外键行不显示删除图标。
    expect(
      find.descendant(of: panel, matching: find.byIcon(Icons.delete_outline)),
      findsNothing,
      reason: 'SQLite 下不显示删除图标（未注入 driverOverride）',
    );

    // 搜索大小写不敏感：AUTHORS 只命中「books.author_id → authors.id」。
    await tester.enterText(
      find.byKey(const ValueKey('er-relation-list-filter')),
      'AUTHORS',
    );
    await settle(tester, rounds: 3);
    expect(
      find.descendant(
        of: panel,
        matching: find.text('books.author_id → authors.id'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: panel,
        matching: find.text('reviews.book_id → books.id'),
      ),
      findsNothing,
    );

    // 无匹配 → 空状态文案（不是空白面板）。
    await tester.enterText(
      find.byKey(const ValueKey('er-relation-list-filter')),
      'zzz',
    );
    await settle(tester, rounds: 3);
    expect(find.byKey(const ValueKey('er-relation-list-empty')), findsOneWidget);
    expect(find.text('没有匹配的关系'), findsOneWidget);

    // 清空过滤恢复两条。
    await tester.enterText(
      find.byKey(const ValueKey('er-relation-list-filter')),
      '',
    );
    await settle(tester, rounds: 3);
    expect(
      find.descendant(
        of: panel,
        matching: find.text('books.author_id → authors.id'),
      ),
      findsOneWidget,
    );

    // 点击外键行 → 复用画布的外键详情对话框（可删 / 看约束名）。
    await tester.tap(
      find.descendant(
        of: panel,
        matching: find.text('books.author_id → authors.id'),
      ),
    );
    await settle(tester, rounds: 6);
    expect(find.text('外键关系'), findsWidgets);
    await tester.tap(find.widgetWithText(Btn, '关闭'));
    await settle(tester, rounds: 10);
    expect(panel, findsOneWidget);

    // 关闭侧栏 → 恢复画布，节点与画布手势区域仍在。
    await tester.tap(find.byKey(const ValueKey('er-relation-list-close')));
    await settle(tester);
    expect(find.byKey(const ValueKey('er-relation-list-panel')), findsNothing);
    expect(find.byKey(const ValueKey('er-node-authors')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关系列表：点击建议行弹出 SQLite ALTER 说明（第 55 轮）', (tester) async {
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
    await tester.tap(find.byKey(const ValueKey('er-relation-list-toggle')));
    await settle(tester);
    final panel = find.byKey(const ValueKey('er-relation-list-panel'));
    expect(panel, findsOneWidget);
    expect(find.text('关系列表（1 条）'), findsOneWidget);
    // 侧栏里的建议行与画布虚线共用「点击即建立」路径。
    expect(find.descendant(of: panel, matching: find.text('建议')), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: panel,
        matching: find.text('members.shop_id → shops.id'),
      ),
    );
    await settle(tester, rounds: 6);
    // SQLite 不能 ALTER 加外键：必须弹明确说明，而不是无反应。
    expect(find.text('SQLite 不支持用 ALTER 新增外键'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('dialog-close')));
    await settle(tester, rounds: 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关系列表空状态：还没有关系时给引导（P2-5）', (tester) async {
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
    await tester.tap(find.byKey(const ValueKey('er-relation-list-toggle')));
    await settle(tester);
    expect(find.byKey(const ValueKey('er-relation-list-panel')), findsOneWidget);
    expect(find.text('关系列表（0 条）'), findsOneWidget);
    expect(
      find.text('还没有关系；添加表并连接字段后会出现在这里'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact 模式：关系列表侧栏不溢出（P2-5）', (tester) async {
    await setSurface(tester);
    await tester.pumpWidget(
      host(
        SingleChildScrollView(
          child: RelationDesigner(
            database: 'main',
            initialTables: const <String>['authors', 'books'],
            compact: true,
            height: 440,
          ),
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('er-relation-list-toggle')));
    await settle(tester);
    final panel = find.byKey(const ValueKey('er-relation-list-panel'));
    expect(panel, findsOneWidget);
    // authors/books + 自动带入 reviews：两行关系，220px 面板里单行省略不溢出。
    expect(
      find.descendant(
        of: panel,
        matching: find.text('books.author_id → authors.id'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('driverOverride=mysql：关系列表删除图标走 alterTableOverride（第 56 轮）', (
    tester,
  ) async {
    await setSurface(tester);
    String? capturedTable;
    Json? capturedBody;
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['authors', 'books'],
          height: 520,
          driverOverride: 'mysql',
          alterTableOverride: (table, body) async {
            capturedTable = table;
            capturedBody = body;
            return <String, dynamic>{'failed': 0, 'results': <dynamic>[]};
          },
        ),
      ),
    );
    await settle(tester);
    // 注入 mysql 后不再显示 SQLite 的「不支持 ALTER」提示。
    expect(find.byKey(const ValueKey('er-sqlite-hint')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('er-relation-list-toggle')));
    await settle(tester);
    final panel = find.byKey(const ValueKey('er-relation-list-panel'));
    expect(panel, findsOneWidget);
    // SQLite 库的外键没有约束名；只有测试注入 driverOverride 时按默认命名规则
    // 补一个可操作的名字（books.author_id → fk_books_author_id）。
    final deleteIcon = find.byKey(
      const ValueKey('er-relation-delete-fk_books_author_id'),
    );
    expect(deleteIcon, findsOneWidget);
    await tester.tap(deleteIcon);
    await settle(tester, rounds: 6);
    expect(find.text('请确认'), findsOneWidget);
    expect(find.textContaining('fk_books_author_id'), findsWidgets);
    await tester.tap(find.widgetWithText(Btn, '删除'));
    await settle(tester, rounds: 10);

    expect(capturedTable, 'books');
    expect(
      (capturedBody!['drop_foreign_keys'] as List).single,
      'fk_books_author_id',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('driverOverride=mysql：建议行点击走 alterTableOverride 并成功提示（第 56 轮）', (
    tester,
  ) async {
    await setSurface(tester);
    // 临时建两张没有外键的表，制造「按列名推导」的建议关系：
    // s_child.s_parent_id → s_parent.id。
    await tester.runAsync(() async {
      await Api.instance.query(
        'CREATE TABLE IF NOT EXISTS s_parent '
        '(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)',
      );
      await Api.instance.query(
        'CREATE TABLE IF NOT EXISTS s_child '
        '(id INTEGER PRIMARY KEY AUTOINCREMENT, s_parent_id INTEGER, note TEXT)',
      );
    });
    String? capturedTable;
    Json? capturedBody;
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['s_child', 's_parent'],
          height: 520,
          driverOverride: 'mysql',
          alterTableOverride: (table, body) async {
            capturedTable = table;
            capturedBody = body;
            return <String, dynamic>{'failed': 0, 'results': <dynamic>[]};
          },
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('er-relation-list-toggle')));
    await settle(tester);
    final panel = find.byKey(const ValueKey('er-relation-list-panel'));
    expect(panel, findsOneWidget);
    expect(find.descendant(of: panel, matching: find.text('建议')), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: panel,
        matching: find.text('s_child.s_parent_id → s_parent.id'),
      ),
    );
    await settle(tester, rounds: 8);

    expect(capturedTable, 's_child');
    final payload = (capturedBody!['add_foreign_keys'] as List).single as Map;
    expect(payload['name'], 'fk_s_child_s_parent_id');
    expect((payload['columns'] as List).single, 's_parent_id');
    expect(payload['ref_table'], 's_parent');
    expect((payload['ref_columns'] as List).single, 'id');
    // 成功路径：工具栏下方出现「已建立建议外键」提示。
    final notice = tester.widget<AlertBox>(
      find.byKey(const ValueKey('er-action-notice')),
    );
    expect(notice.message, contains('已建立建议外键'));
    expect(notice.message, contains('s_child.s_parent_id'));
    // 第 62 轮：建立成功后「当前数据库还没有外键」的提示必须消失。
    expect(find.textContaining('当前数据库还没有外键'), findsNothing);
    expect(tester.takeException(), isNull);
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
    // 第 56 轮：标签 tooltip 带完整名称（窄画布隐藏标签时仍能看全名）。
    final m2mTooltip = tester.widget<app_tooltip.Tooltip>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('er-m2m-order_items')),
            matching: find.byType(app_tooltip.Tooltip),
          )
          .first,
    );
    expect(m2mTooltip.message, contains('多对多 · order_items'));

    // P2-6：标签不能压住橙色多对多连线的中段。渲染出的标签中心必须离开
    // 「两张卡片中心连线的中点」，且偏移方向与连线垂直、优先向上。
    final ordersRect = tester.getRect(
      find.byKey(const ValueKey('er-node-orders')),
    );
    final productsRect = tester.getRect(
      find.byKey(const ValueKey('er-node-products')),
    );
    final midpoint = Offset(
      (ordersRect.center.dx + productsRect.center.dx) / 2,
      (ordersRect.center.dy + productsRect.center.dy) / 2,
    );
    final labelCenter = tester.getCenter(
      find.byKey(const ValueKey('er-m2m-order_items')),
    );
    final delta = labelCenter - midpoint;
    final direction = productsRect.center - ordersRect.center;
    expect(
      delta.distance,
      greaterThan(8),
      reason: '标签盒半高约 8px，锚点必须离开连线中点才能露出线',
    );
    expect(
      (delta.dx * direction.dx + delta.dy * direction.dy).abs(),
      lessThan(1.5),
      reason: '偏移必须沿连线法线方向（点积为 0）',
    );
    expect(delta.dy, lessThan(0), reason: '优先偏向上方空白侧');

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
    // 第 70 轮：说明改成「具体成员」的差别（变长 vs 定长 vs 长文本），
    // 不再是一句适用于整个文本家族的「有长度上限的文本」。
    expect(typeTooltip.message, contains('变长文本'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('画布缩放：按钮 100% → 110% → 90%，点百分比复位（第 70 轮）', (
    tester,
  ) async {
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

    expect(find.text('100%'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('er-zoom-in')));
    await tester.pumpAndSettle();
    expect(find.text('110%'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('er-zoom-out')));
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('er-zoom-out')));
    await tester.pumpAndSettle();
    expect(find.text('90%'), findsOneWidget);

    // 点百分比复位到 100%。
    await tester.tap(find.byKey(const ValueKey('er-zoom-reset')));
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsOneWidget);

    // 缩放到上限后「放大」按钮禁用，不会越界。
    for (var i = 0; i < 12; i++) {
      await tester.tap(
        find.byKey(const ValueKey('er-zoom-in')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
    }
    expect(find.text('200%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('适应窗口：把全部表缩到一屏内（第 70 轮）', (tester) async {
    await setSurface(tester);
    // 三张表分三层（authors ← books ← reviews），层级布局会把画布拉得比
    // 视口宽；「适应窗口」应该把比例降到 100% 以下。
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['authors', 'books', 'reviews'],
          height: 420,
        ),
      ),
    );
    await settle(tester);

    expect(find.byKey(const ValueKey('er-zoom-fit')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('er-zoom-fit')));
    await tester.pumpAndSettle();

    final labels = tester
        .widgetList<app_text.Text>(find.byType(app_text.Text))
        .map((widget) => widget.data)
        .where((text) => RegExp(r'^\d+%$').hasMatch(text))
        .toList();
    expect(labels.length, 1, reason: '缩放百分比应当只有一个');
    final percent = int.parse(labels.single.replaceAll('%', ''));
    // 三列卡片 + 间距放不进 1400px 的测试视口的一半宽度里也无所谓：
    // 关键是不超过 100%，且仍然落在合法区间。
    expect(percent, lessThanOrEqualTo(100));
    expect(percent, greaterThanOrEqualTo(50));
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
    // 4 层链需要 4 列（每列 272+52）。窗口够宽时不应该折行，方向保持
    // 「子表在左、父表在右」；折行是空间不够时的降级（见下一个用例）。
    tester.view.physicalSize = const Size(1900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    expect(find.text('Added 3/20'), findsOneWidget);
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
    // P3：术语说明按钮的 tooltip 不是 Text，全树文本扫描覆盖不到，单独断言。
    final glossaryTooltip = tester.widget<app_tooltip.Tooltip>(
      find
          .descendant(
            of: find.byKey(const ValueKey('er-glossary')),
            matching: find.byType(app_tooltip.Tooltip),
          )
          .first,
    );
    expect(glossaryTooltip.message, 'Glossary');
    // P2-8：自动带入提示的 tooltip 说明「已有外键 / 建议关系」两套机制，
    // 英文模式下也必须是英文。
    final autoAddedTooltip = tester.widget<app_tooltip.Tooltip>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('er-auto-added-hint')),
            matching: find.byType(app_tooltip.Tooltip),
          )
          .first,
    );
    expect(autoAddedTooltip.message, contains('suggested relations'));
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
    // 第 56 轮：多对多标签 tooltip 在英文模式下也带完整英文名称。
    final m2mTooltip = tester.widget<app_tooltip.Tooltip>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('er-m2m-order_items')),
            matching: find.byType(app_tooltip.Tooltip),
          )
          .first,
    );
    expect(m2mTooltip.message, contains('many-to-many · order_items'));
    expect(m2mTooltip.message, contains('Collapse junction table'));

    // P2-5：关系列表侧栏里的多对多条目也必须是英文（画布上还有一份隐藏
    // 标签，所以限定在面板内查找）。
    await tester.tap(find.byKey(const ValueKey('er-relation-list-toggle')));
    await settle(tester);
    final panel = find.byKey(const ValueKey('er-relation-list-panel'));
    expect(panel, findsOneWidget);
    // 共享 SQLite 库里前面测试建过中间表，画布自动带入的表数不固定，所以只
    // 断言标题的英文前缀，不断言具体条数。
    final listTitle = tester.widget<app_text.Text>(
      find.byKey(const ValueKey('er-relation-list-title')),
    );
    expect(listTitle.data, startsWith('Relation list ('));
    expect(
      find.descendant(
        of: panel,
        matching: find.text('many-to-many · order_items'),
      ),
      findsOneWidget,
    );
    expect(find.descendant(of: panel, matching: find.text('FK')), findsWidgets);
    // 点击多对多行 → 折叠中间表（与画布上的橙色标签同一个动作）。
    await tester.tap(
      find.descendant(
        of: panel,
        matching: find.text('many-to-many · order_items'),
      ),
    );
    await settle(tester);
    expect(find.byKey(const ValueKey('er-node-order_items')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('er-relation-list-close')));
    await settle(tester);

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

    // 第 55 轮：侧栏建议行的徽标与行 tooltip 也必须是英文。
    await tester.tap(find.byKey(const ValueKey('er-relation-list-toggle')));
    await settle(tester);
    final suggestionPanel = find.byKey(
      const ValueKey('er-relation-list-panel'),
    );
    expect(
      find.descendant(of: suggestionPanel, matching: find.text('Suggested')),
      findsOneWidget,
    );
    final suggestionRowTooltip = tester.widget<app_tooltip.Tooltip>(
      find
          .ancestor(
            of: find.descendant(
              of: suggestionPanel,
              matching: find.text('members.shop_id → shops.id'),
            ),
            matching: find.byType(app_tooltip.Tooltip),
          )
          .first,
    );
    expect(
      suggestionRowTooltip.message,
      contains('members.shop_id → shops.id'),
    );
    await tester.tap(find.byKey(const ValueKey('er-relation-list-close')));
    await settle(tester);
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

  // =====================================================================
  // 第 61 轮：新建外键 1452 的可行动诊断
  // =====================================================================

  const userScenario1452 =
      'Cannot add or update a child row: a foreign key constraint fails '
      '(clerk_cn_test.#sql-1004_4e, CONSTRAINT fk_grade_student '
      'FOREIGN KEY (学号) REFERENCES 学生名单 (id) ON DELETE CASCADE) '
      '(错误码 23000)';

  Future<void> createUserScenarioTables(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Api.instance.query(
        'CREATE TABLE IF NOT EXISTS 学生名单 '
        '(id INTEGER PRIMARY KEY AUTOINCREMENT, 学号 INTEGER)',
      );
      await Api.instance.query(
        'CREATE TABLE IF NOT EXISTS 年级成绩单 '
        '(学号 INTEGER PRIMARY KEY AUTOINCREMENT, 姓名 TEXT)',
      );
    });
  }

  testWidgets('新建外键预检：孤儿→取消保留警告；仍然尝试→1452 友好文案（第 61 轮）', (
    tester,
  ) async {
    await setSurface(tester);
    await createUserScenarioTables(tester);
    final designerKey = GlobalKey<RelationDesignerState>();
    var alterCalls = 0;
    await tester.pumpWidget(
      host(
        RelationDesigner(
          key: designerKey,
          database: 'main',
          initialTables: const <String>['年级成绩单', '学生名单'],
          height: 560,
          driverOverride: 'mysql',
          orphanReportOverride:
              (localTable, localColumn, refTable, refColumn) =>
                  const FkOrphanReport(
                    count: 30,
                    childSamples: <String>['20260101', '20260102'],
                    parentSamples: <String>['1', '2'],
                    sameNameColumn: '学号',
                    sameNameMatchCount: 30,
                    childNonEmptyCount: 30,
                  ),
          alterTableOverride: (table, body) async {
            alterCalls++;
            throw StateError(userScenario1452);
          },
        ),
      ),
    );
    await settle(tester);

    unawaited(
      designerKey.currentState!.openNewForeignKeyForTest(
        localTable: '年级成绩单',
        localColumn: '学号',
        refTable: '学生名单',
        refColumn: 'id',
      ),
    );
    await settle(tester, rounds: 10);
    expect(find.text('新建外键关系'), findsOneWidget);

    // 预检警告：数量 + 示例值 + 同名列/索引建议。
    await tester.tap(find.widgetWithText(Btn, '创建'));
    await settle(tester, rounds: 10);
    expect(find.textContaining('引用数据不匹配'), findsWidgets);
    expect(find.textContaining('20260101'), findsWidgets);
    expect(find.textContaining('学生名单.学号'), findsWidgets);
    expect(find.textContaining('UNIQUE 索引'), findsWidgets);

    // 取消：不执行 ALTER；新建外键弹窗保持打开并把警告显示为错误说明。
    await tester.tap(find.byKey(const ValueKey('fk-precheck-cancel')));
    await settle(tester, rounds: 8);
    expect(alterCalls, 0);
    expect(find.text('新建外键关系'), findsOneWidget);
    expect(find.textContaining('引用数据不匹配'), findsWidgets);

    // 仍然尝试：执行一次 ALTER，1452 被翻译成可行动文案（不再出现原始错误）。
    await tester.tap(find.widgetWithText(Btn, '创建'));
    await settle(tester, rounds: 10);
    await tester.tap(find.byKey(const ValueKey('fk-precheck-proceed')));
    await settle(tester, rounds: 14);
    expect(alterCalls, 1);
    expect(find.text('新建外键关系'), findsOneWidget);
    expect(find.textContaining('找不到对应记录'), findsWidgets);
    expect(find.textContaining('UNIQUE 索引'), findsWidgets);
    expect(
      find.textContaining('Cannot add or update a child row'),
      findsNothing,
    );

    // 清理：关闭弹窗。
    await tester.tap(find.widgetWithText(Btn, '取消'));
    await settle(tester, rounds: 8);
    expect(tester.takeException(), isNull);
  });

  testWidgets('新建外键：预检被跳过时 1452 仍给友好文案（不阻塞创建）（第 61 轮）', (
    tester,
  ) async {
    await setSurface(tester);
    await createUserScenarioTables(tester);
    final designerKey = GlobalKey<RelationDesignerState>();
    var alterCalls = 0;
    await tester.pumpWidget(
      host(
        RelationDesigner(
          key: designerKey,
          database: 'main',
          initialTables: const <String>['年级成绩单', '学生名单'],
          height: 560,
          driverOverride: 'mysql',
          // 模拟测试环境/权限不足：预检返回 null（跳过），创建流程不被阻塞。
          orphanReportOverride:
              (localTable, localColumn, refTable, refColumn) => null,
          alterTableOverride: (table, body) async {
            alterCalls++;
            throw StateError(userScenario1452);
          },
        ),
      ),
    );
    await settle(tester);
    unawaited(
      designerKey.currentState!.openNewForeignKeyForTest(
        localTable: '年级成绩单',
        localColumn: '学号',
        refTable: '学生名单',
        refColumn: 'id',
      ),
    );
    await settle(tester, rounds: 10);
    expect(find.text('新建外键关系'), findsOneWidget);

    await tester.tap(find.widgetWithText(Btn, '创建'));
    await settle(tester, rounds: 14);
    expect(alterCalls, 1);
    // 没有预检警告弹窗，直接展示 1452 的友好解释。
    expect(find.textContaining('找不到对应记录'), findsWidgets);
    expect(find.textContaining('年级成绩单'), findsWidgets);
    expect(
      find.textContaining('Cannot add or update a child row'),
      findsNothing,
    );
    await tester.tap(find.widgetWithText(Btn, '取消'));
    await settle(tester, rounds: 8);
    expect(tester.takeException(), isNull);
  });

  testWidgets('新建外键预检：真实 SQL 在 SQLite 上查出孤儿（无 override）', (tester) async {
    await setSurface(tester);
    await tester.runAsync(() async {
      await Api.instance.query(
        'CREATE TABLE IF NOT EXISTS pre_parent '
        '(id INTEGER PRIMARY KEY AUTOINCREMENT)',
      );
      await Api.instance.query(
        'CREATE TABLE IF NOT EXISTS pre_child '
        '(id INTEGER PRIMARY KEY AUTOINCREMENT, pid INTEGER)',
      );
      await Api.instance.query('DELETE FROM pre_child');
      await Api.instance.query('DELETE FROM pre_parent');
      await Api.instance.query('INSERT INTO pre_parent (id) VALUES (1), (2)');
      await Api.instance.query('INSERT INTO pre_child (pid) VALUES (9), (8)');
    });
    final designerKey = GlobalKey<RelationDesignerState>();
    await tester.pumpWidget(
      host(
        RelationDesigner(
          key: designerKey,
          database: 'main',
          initialTables: const <String>['pre_child', 'pre_parent'],
          height: 520,
        ),
      ),
    );
    await settle(tester);
    unawaited(
      designerKey.currentState!.openNewForeignKeyForTest(
        localTable: 'pre_child',
        localColumn: 'pid',
        refTable: 'pre_parent',
        refColumn: 'id',
      ),
    );
    await settle(tester, rounds: 12);
    expect(find.text('新建外键关系'), findsOneWidget);

    await tester.tap(find.widgetWithText(Btn, '创建'));
    await settle(tester, rounds: 24);
    // 真实 LEFT JOIN 查询命中 2 行孤儿，且带出两侧示例值。
    expect(find.textContaining('2 行'), findsWidgets);
    expect(find.textContaining('pre_child'), findsWidgets);
    expect(find.textContaining('本表这些值的示例'), findsWidgets);
    expect(find.textContaining('引用表的示例'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('fk-precheck-cancel')));
    await settle(tester, rounds: 8);
    expect(find.textContaining('引用数据不匹配'), findsWidgets);
    await tester.tap(find.widgetWithText(Btn, '取消'));
    await settle(tester, rounds: 8);
    expect(tester.takeException(), isNull);
  });

  // =====================================================================
  // 第 62 轮：画布拖动视角 / 批量建议友好错误 / 一键 UNIQUE 索引
  // =====================================================================

  testWidgets('画布拖动视角：空白拖动平移，节点拖动不平移（第 62 轮）', (tester) async {
    await setSurface(tester);
    await tester.pumpWidget(
      host(
        SizedBox(
          width: 900,
          height: 320,
          child: RelationDesigner(
            database: 'main',
            initialTables: const <String>[
              'authors',
              'books',
              'reviews',
              'c1',
              'c2',
              'c3',
              'c4',
              'c5',
              'c6',
            ],
            height: 320,
          ),
        ),
      ),
    );
    await settle(tester);
    final canvasStack = find.byKey(const ValueKey('er-canvas-stack'));
    expect(canvasStack, findsOneWidget);
    final scrollables = find.ancestor(
      of: canvasStack,
      matching: find.byType(Scrollable),
    );
    expect(scrollables, findsNWidgets(2));
    ScrollableState scrollState(int index) =>
        tester.state<ScrollableState>(scrollables.at(index));
    double pixels(int index) => scrollState(index).position.pixels;
    final maxExtents = <double>[
      scrollState(0).position.maxScrollExtent,
      scrollState(1).position.maxScrollExtent,
    ];
    expect(
      maxExtents[0] > 0 || maxExtents[1] > 0,
      isTrue,
      reason: '测试前提：内容要超出视口，maxExtents=$maxExtents',
    );

    // 先拖节点标题栏：节点自身手势优先，视角保持不动。
    final node = find.byKey(const ValueKey('er-node-authors'));
    expect(node, findsOneWidget);
    final nodeStart = tester.getTopLeft(node) + const Offset(30, 12);
    final nodeDrag = await tester.startGesture(nodeStart);
    for (var i = 0; i < 4; i++) {
      await nodeDrag.moveBy(const Offset(10, 8));
      await tester.pump();
    }
    await nodeDrag.up();
    await tester.pump();
    expect(pixels(0), 0);
    expect(pixels(1), 0);

    // 空白处（节点从 24px 开始）向左上拖动 → 视角向右下平移。
    final start = tester.getTopLeft(canvasStack) + const Offset(4, 4);
    final pan = await tester.startGesture(start);
    for (var i = 0; i < 6; i++) {
      await pan.moveBy(const Offset(-24, -18));
      await tester.pump();
    }
    await pan.up();
    await tester.pump();
    final afterPan = <double>[pixels(0), pixels(1)];
    expect(
      afterPan[0] + afterPan[1],
      greaterThan(0),
      reason: '拖动空白处后至少一个轴应产生滚动偏移',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量建议外键失败：1452 显示可行动诊断（第 62 轮）', (tester) async {
    await setSurface(tester);
    await tester.runAsync(() async {
      await Api.instance.query(
        'CREATE TABLE IF NOT EXISTS sg_parent '
        '(id INTEGER PRIMARY KEY AUTOINCREMENT)',
      );
      await Api.instance.query(
        'CREATE TABLE IF NOT EXISTS sg_child '
        '(id INTEGER PRIMARY KEY AUTOINCREMENT, sg_parent_id INTEGER)',
      );
    });
    await tester.pumpWidget(
      host(
        RelationDesigner(
          database: 'main',
          initialTables: const <String>['sg_child', 'sg_parent'],
          height: 520,
          driverOverride: 'mysql',
          orphanReportOverride:
              (localTable, localColumn, refTable, refColumn) =>
                  const FkOrphanReport(
                    count: 30,
                    childSamples: <String>['20260101'],
                    parentSamples: <String>['1'],
                    sameNameColumn: '学号',
                    sameNameMatchCount: 30,
                    childNonEmptyCount: 30,
                  ),
          alterTableOverride: (table, body) async {
            throw StateError(userScenario1452);
          },
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('er-relation-list-toggle')));
    await settle(tester);
    final panel = find.byKey(const ValueKey('er-relation-list-panel'));
    expect(panel, findsOneWidget);
    await tester.tap(
      find.descendant(
        of: panel,
        matching: find.text('sg_child.sg_parent_id → sg_parent.id'),
      ),
    );
    await settle(tester, rounds: 12);

    // 批量失败汇总保留条数，并用可行动文案替代裸 1452。
    expect(find.textContaining('已建立 0/1 条建议外键'), findsWidgets);
    expect(find.textContaining('找不到对应记录'), findsWidgets);
    expect(find.textContaining('UNIQUE 索引'), findsWidgets);
    expect(
      find.textContaining('Cannot add or update a child row'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  Future<void> createUniqueIndexScenarioTables(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Api.instance.query(
        'CREATE TABLE IF NOT EXISTS uq_parent '
        '(id INTEGER PRIMARY KEY AUTOINCREMENT, code INTEGER)',
      );
      await Api.instance.query(
        'CREATE TABLE IF NOT EXISTS uq_child '
        '(id INTEGER PRIMARY KEY AUTOINCREMENT, code INTEGER)',
      );
      await Api.instance.query('DELETE FROM uq_parent');
      await Api.instance.query('INSERT INTO uq_parent (code) VALUES (1), (2), (3)');
    });
  }

  testWidgets('引用列全唯一：一键建 UNIQUE 索引并断言 add_indexes（第 62 轮）', (
    tester,
  ) async {
    await setSurface(tester);
    await createUniqueIndexScenarioTables(tester);
    final designerKey = GlobalKey<RelationDesignerState>();
    Json? capturedBody;
    String? capturedTable;
    var alterCalls = 0;
    await tester.pumpWidget(
      host(
        RelationDesigner(
          key: designerKey,
          database: 'main',
          initialTables: const <String>['uq_child', 'uq_parent'],
          height: 520,
          driverOverride: 'mysql',
          uniquenessOverride: (table, column) async =>
              const ErColumnUniqueness(total: 3, distinct: 3),
          alterTableOverride: (table, body) async {
            alterCalls++;
            capturedTable = table;
            capturedBody = body;
            return <String, dynamic>{'failed': 0, 'results': <dynamic>[]};
          },
        ),
      ),
    );
    await settle(tester);
    unawaited(
      designerKey.currentState!.openNewForeignKeyForTest(
        localTable: 'uq_child',
        localColumn: 'code',
        refTable: 'uq_parent',
        refColumn: 'code',
      ),
    );
    await settle(tester, rounds: 10);
    expect(find.text('目标列不是唯一键'), findsOneWidget);
    expect(find.textContaining('全部唯一'), findsWidgets);
    expect(
      find.byKey(const ValueKey('er-create-unique-index')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('er-create-unique-index')));
    await settle(tester, rounds: 16);
    expect(alterCalls, 1);
    expect(capturedTable, 'uq_parent');
    final indexes = (capturedBody!['add_indexes'] as List).cast<Map>();
    expect(indexes, hasLength(1));
    expect(indexes.single['unique'], isTrue);
    expect((indexes.single['columns'] as List).single, 'code');
    expect(indexes.single['name'], startsWith('uk_code'));

    // override 是假成功（真实库没建索引）：重新校验仍不唯一，回到阻止提示；
    // 真实 MySQL 上此处会重新打开「新建外键关系」弹窗。
    expect(find.text('无法创建外键'), findsWidgets);
    await tester.tap(find.widgetWithText(Btn, '关闭'));
    await settle(tester, rounds: 8);
    expect(tester.takeException(), isNull);
  });

  testWidgets('引用列有重复：说明数量/示例，不提供建索引（第 62 轮）', (tester) async {
    await setSurface(tester);
    await createUniqueIndexScenarioTables(tester);
    final designerKey = GlobalKey<RelationDesignerState>();
    var alterCalls = 0;
    await tester.pumpWidget(
      host(
        RelationDesigner(
          key: designerKey,
          database: 'main',
          initialTables: const <String>['uq_child', 'uq_parent'],
          height: 520,
          driverOverride: 'mysql',
          uniquenessOverride: (table, column) async =>
              const ErColumnUniqueness(
                total: 30,
                distinct: 1,
                duplicates: <ErDuplicateValue>[
                  ErDuplicateValue('20260101', 30),
                ],
              ),
          alterTableOverride: (table, body) async {
            alterCalls++;
            return <String, dynamic>{'failed': 0, 'results': <dynamic>[]};
          },
        ),
      ),
    );
    await settle(tester);
    unawaited(
      designerKey.currentState!.openNewForeignKeyForTest(
        localTable: 'uq_child',
        localColumn: 'code',
        refTable: 'uq_parent',
        refColumn: 'code',
      ),
    );
    await settle(tester, rounds: 10);
    expect(find.text('目标列不是唯一键'), findsOneWidget);
    expect(find.textContaining('30 行非空'), findsWidgets);
    expect(find.textContaining('1 个不同值'), findsWidgets);
    expect(find.textContaining('20260101'), findsWidgets);
    expect(find.textContaining('出现 30 次'), findsWidgets);
    expect(
      find.byKey(const ValueKey('er-create-unique-index')),
      findsNothing,
    );
    expect(alterCalls, 0, reason: '有重复时不自动建索引');
    await tester.tap(find.widgetWithText(Btn, '关闭'));
    await settle(tester, rounds: 8);
    expect(tester.takeException(), isNull);
  });

  testWidgets('引用列已有 UNIQUE 索引时直接打开新建外键弹窗（live SQLite）', (tester) async {
    await setSurface(tester);
    await tester.runAsync(() async {
      await Api.instance.query(
        'CREATE TABLE IF NOT EXISTS uq3_parent '
        '(id INTEGER PRIMARY KEY AUTOINCREMENT, code INTEGER)',
      );
      await Api.instance.query(
        'CREATE TABLE IF NOT EXISTS uq3_child '
        '(id INTEGER PRIMARY KEY AUTOINCREMENT, code INTEGER)',
      );
      await Api.instance.query('DROP INDEX IF EXISTS uk_uq3_code');
      await Api.instance.query(
        'CREATE UNIQUE INDEX uk_uq3_code ON uq3_parent(code)',
      );
    });
    final designerKey = GlobalKey<RelationDesignerState>();
    await tester.pumpWidget(
      host(
        RelationDesigner(
          key: designerKey,
          database: 'main',
          initialTables: const <String>['uq3_child', 'uq3_parent'],
          height: 520,
        ),
      ),
    );
    await settle(tester);
    unawaited(
      designerKey.currentState!.openNewForeignKeyForTest(
        localTable: 'uq3_child',
        localColumn: 'code',
        refTable: 'uq3_parent',
        refColumn: 'code',
      ),
    );
    await settle(tester, rounds: 12);
    // 唯一索引存在 → 本地校验通过，直接进入新建外键弹窗（不再提示建索引）。
    expect(find.text('新建外键关系'), findsOneWidget);
    expect(find.text('目标列不是唯一键'), findsNothing);
    await tester.tap(find.widgetWithText(Btn, '取消'));
    await settle(tester, rounds: 8);
    expect(tester.takeException(), isNull);
  });

  // =====================================================================
  // 第 62 轮修正：唯一性查询失败降级 + 创建成功后清「还没有外键」提示
  // =====================================================================

  testWidgets('唯一性查询失败：降级回原「不是唯一键」提示，不显示假事实', (tester) async {
    await setSurface(tester);
    await createUniqueIndexScenarioTables(tester);
    final designerKey = GlobalKey<RelationDesignerState>();
    await tester.pumpWidget(
      host(
        RelationDesigner(
          key: designerKey,
          database: 'main',
          initialTables: const <String>['uq_child', 'uq_parent'],
          height: 520,
          driverOverride: 'mysql',
          // 模拟真实查询失败（如保留字别名导致 1064 被静默吞掉）。
          uniquenessOverride: (table, column) async => null,
          alterTableOverride: (table, body) async =>
              <String, dynamic>{'failed': 0, 'results': <dynamic>[]},
        ),
      ),
    );
    await settle(tester);
    unawaited(
      designerKey.currentState!.openNewForeignKeyForTest(
        localTable: 'uq_child',
        localColumn: 'code',
        refTable: 'uq_parent',
        refColumn: 'code',
      ),
    );
    await settle(tester, rounds: 10);
    // 必须退回原来的阻止提示，不能出现「没有非空值」这种假事实。
    expect(find.text('无法创建外键'), findsWidgets);
    expect(find.textContaining('不是主键或单列唯一列'), findsWidgets);
    expect(find.text('目标列不是唯一键'), findsNothing);
    expect(find.textContaining('没有非空值'), findsNothing);
    await tester.tap(find.widgetWithText(Btn, '关闭'));
    await settle(tester, rounds: 8);
    expect(tester.takeException(), isNull);
  });

  testWidgets('成功创建外键后「还没有外键」提示消失', (tester) async {
    await setSurface(tester);
    await tester.runAsync(() async {
      await Api.instance.query(
        'CREATE TABLE IF NOT EXISTS nh_parent '
        '(id INTEGER PRIMARY KEY AUTOINCREMENT, code INTEGER)',
      );
      await Api.instance.query(
        'CREATE TABLE IF NOT EXISTS nh_child '
        '(id INTEGER PRIMARY KEY AUTOINCREMENT, code INTEGER)',
      );
      await Api.instance.query('DELETE FROM nh_parent');
      await Api.instance.query('DELETE FROM nh_child');
    });
    final designerKey = GlobalKey<RelationDesignerState>();
    await tester.pumpWidget(
      host(
        RelationDesigner(
          key: designerKey,
          database: 'main',
          initialTables: const <String>['nh_child', 'nh_parent'],
          height: 520,
          driverOverride: 'mysql',
          alterTableOverride: (table, body) async =>
              <String, dynamic>{'failed': 0, 'results': <dynamic>[]},
        ),
      ),
    );
    await settle(tester);
    // 测试库还有其它表的外键，这里直接注入「还没有外键」提示来验证创建后清除。
    designerKey.currentState!.showNoForeignKeyNoticeForTest();
    await settle(tester, rounds: 4);
    expect(find.textContaining('当前数据库还没有外键'), findsOneWidget);

    unawaited(
      designerKey.currentState!.openNewForeignKeyForTest(
        localTable: 'nh_child',
        localColumn: 'code',
        refTable: 'nh_parent',
        refColumn: 'id',
      ),
    );
    await settle(tester, rounds: 10);
    expect(find.text('新建外键关系'), findsOneWidget);

    // 预检真实查询（空表 → 0 孤儿）后 ALTER（override 成功），弹窗关闭。
    await tester.tap(find.widgetWithText(Btn, '创建'));
    await settle(tester, rounds: 20);
    expect(find.text('新建外键关系'), findsNothing);
    expect(find.textContaining('当前数据库还没有外键'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // =====================================================================
  // 第 63 轮：孤儿警告一键改用同名列 + 索引名 1826 自动重试
  // =====================================================================

  Future<void> createSameNameScenarioTables(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Api.instance.query(
        'CREATE TABLE IF NOT EXISTS 学生名单63 '
        '(id INTEGER PRIMARY KEY AUTOINCREMENT, 学号 INTEGER)',
      );
      await Api.instance.query(
        'CREATE TABLE IF NOT EXISTS 年级成绩单63 '
        '(学号 INTEGER PRIMARY KEY AUTOINCREMENT, 姓名 TEXT)',
      );
      await Api.instance.query('DELETE FROM 学生名单63');
      await Api.instance.query(
        'INSERT INTO 学生名单63 (学号) VALUES (1), (2), (3)',
      );
      await Api.instance.query('DROP INDEX IF EXISTS uk_sname63_xh');
      await Api.instance.query(
        'CREATE UNIQUE INDEX uk_sname63_xh ON 学生名单63(学号)',
      );
    });
  }

  testWidgets('孤儿警告一键改用同名列：已有 UNIQUE 索引 → 不建 DDL 并重开弹窗（第 63 轮）', (
    tester,
  ) async {
    await setSurface(tester);
    await createSameNameScenarioTables(tester);
    final designerKey = GlobalKey<RelationDesignerState>();
    final bodies = <Map<String, dynamic>>[];
    var precheckCalls = 0;
    await tester.pumpWidget(
      host(
        RelationDesigner(
          key: designerKey,
          database: 'main',
          initialTables: const <String>['年级成绩单63', '学生名单63'],
          height: 520,
          driverOverride: 'mysql',
          orphanReportOverride:
              (localTable, localColumn, refTable, refColumn) {
                precheckCalls++;
                if (precheckCalls == 1) {
                  return const FkOrphanReport(
                    count: 30,
                    childSamples: <String>['20260101'],
                    parentSamples: <String>['1'],
                    sameNameColumn: '学号',
                    sameNameMatchCount: 30,
                    childNonEmptyCount: 30,
                  );
                }
                // 改用同名列后两表数据匹配：不再有孤儿行。
                return const FkOrphanReport(count: 0);
              },
          alterTableOverride: (table, body) async {
            bodies.add(body);
            return <String, dynamic>{'failed': 0, 'results': <dynamic>[]};
          },
        ),
      ),
    );
    await settle(tester);
    unawaited(
      designerKey.currentState!.openNewForeignKeyForTest(
        localTable: '年级成绩单63',
        localColumn: '学号',
        refTable: '学生名单63',
        refColumn: 'id',
      ),
    );
    await settle(tester, rounds: 10);
    expect(find.text('新建外键关系'), findsOneWidget);

    await tester.tap(find.widgetWithText(Btn, '创建'));
    await settle(tester, rounds: 10);
    expect(find.byKey(const ValueKey('er-orphan-fix-samename')), findsOneWidget);
    expect(find.textContaining('学生名单63.学号'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('er-orphan-fix-samename')));
    await settle(tester, rounds: 20);
    // 同名列已有 UNIQUE 索引：不发 add_indexes，直接用同名列重开弹窗。
    expect(
      bodies.where((body) => body['add_indexes'] != null),
      isEmpty,
    );
    expect(find.text('新建外键关系'), findsOneWidget);

    // 重开后的弹窗引用列已是同名列；点创建 → ALTER 的 ref_columns=学号。
    await tester.tap(find.widgetWithText(Btn, '创建'));
    await settle(tester, rounds: 20);
    expect(bodies, hasLength(1));
    final payload =
        (bodies.single['add_foreign_keys'] as List).single as Map;
    expect(payload['ref_table'], '学生名单63');
    expect((payload['ref_columns'] as List).single, '学号');
    expect(find.text('新建外键关系'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('孤儿警告一键改用同名列：同名列有重复 → 只提示、不建索引（第 63 轮）', (
    tester,
  ) async {
    await setSurface(tester);
    await createSameNameScenarioTables(tester);
    final designerKey = GlobalKey<RelationDesignerState>();
    var alterCalls = 0;
    await tester.pumpWidget(
      host(
        RelationDesigner(
          key: designerKey,
          database: 'main',
          initialTables: const <String>['年级成绩单63', '学生名单63'],
          height: 520,
          driverOverride: 'mysql',
          orphanReportOverride:
              (localTable, localColumn, refTable, refColumn) =>
                  const FkOrphanReport(
                    count: 30,
                    childSamples: <String>['20260101'],
                    parentSamples: <String>['1'],
                    sameNameColumn: '学号',
                    sameNameMatchCount: 30,
                    childNonEmptyCount: 30,
                  ),
          uniquenessOverride: (table, column) async =>
              const ErColumnUniqueness(
                total: 30,
                distinct: 1,
                duplicates: <ErDuplicateValue>[
                  ErDuplicateValue('20260101', 30),
                ],
              ),
          alterTableOverride: (table, body) async {
            alterCalls++;
            return <String, dynamic>{'failed': 0, 'results': <dynamic>[]};
          },
        ),
      ),
    );
    await settle(tester);
    unawaited(
      designerKey.currentState!.openNewForeignKeyForTest(
        localTable: '年级成绩单63',
        localColumn: '学号',
        refTable: '学生名单63',
        refColumn: 'id',
      ),
    );
    await settle(tester, rounds: 10);
    await tester.tap(find.widgetWithText(Btn, '创建'));
    await settle(tester, rounds: 10);
    await tester.tap(find.byKey(const ValueKey('er-orphan-fix-samename')));
    await settle(tester, rounds: 12);
    // 重复值说明（数量/示例），不发 DDL。
    expect(find.text('目标列不是唯一键'), findsOneWidget);
    expect(find.textContaining('30 行非空'), findsWidgets);
    expect(find.textContaining('20260101'), findsWidgets);
    expect(find.textContaining('出现 30 次'), findsWidgets);
    expect(alterCalls, 0);
    await tester.tap(find.widgetWithText(Btn, '关闭'));
    await settle(tester, rounds: 8);
    // 回到原新建外键弹窗，仍保留孤儿警告（引用列没变）。
    expect(find.text('新建外键关系'), findsOneWidget);
    expect(find.textContaining('引用数据不匹配'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(Btn, '取消'));
    await settle(tester, rounds: 8);
  });

  testWidgets('索引名 1826 自动重试：第二次改用序号名并成功（第 63 轮）', (tester) async {
    await setSurface(tester);
    await createUniqueIndexScenarioTables(tester);
    final designerKey = GlobalKey<RelationDesignerState>();
    final bodies = <Map<String, dynamic>>[];
    await tester.pumpWidget(
      host(
        RelationDesigner(
          key: designerKey,
          database: 'main',
          initialTables: const <String>['uq_child', 'uq_parent'],
          height: 520,
          driverOverride: 'mysql',
          uniquenessOverride: (table, column) async =>
              const ErColumnUniqueness(total: 3, distinct: 3),
          alterTableOverride: (table, body) async {
            bodies.add(body);
            if (bodies.length == 1) {
              throw StateError(
                'ERROR 1826 (HY000): Duplicate key name uk_code',
              );
            }
            return <String, dynamic>{'failed': 0, 'results': <dynamic>[]};
          },
        ),
      ),
    );
    await settle(tester);
    unawaited(
      designerKey.currentState!.openNewForeignKeyForTest(
        localTable: 'uq_child',
        localColumn: 'code',
        refTable: 'uq_parent',
        refColumn: 'code',
      ),
    );
    await settle(tester, rounds: 10);
    expect(find.text('目标列不是唯一键'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('er-create-unique-index')));
    await settle(tester, rounds: 18);

    expect(bodies, hasLength(2));
    Map indexPayload(Map body) =>
        (body['add_indexes'] as List).single as Map;
    expect(indexPayload(bodies[0])['name'], 'uk_code');
    expect(indexPayload(bodies[0])['unique'], isTrue);
    expect(indexPayload(bodies[1])['name'], 'uk_code_2');
    expect(indexPayload(bodies[1])['unique'], isTrue);
    // override 假成功：重开后仍被真实结构拦回阻止提示；真实 DB 会打开弹窗。
    expect(find.text('无法创建外键'), findsWidgets);
    await tester.tap(find.widgetWithText(Btn, '关闭'));
    await settle(tester, rounds: 8);
    expect(tester.takeException(), isNull);
  });

  // =====================================================================
  // 第 64 轮：同名列部分匹配也能一键改选 + 1826 最多 5 次换名重试
  // =====================================================================

  Future<void> createPartialSameNameTables(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Api.instance.query(
        'CREATE TABLE IF NOT EXISTS 学生名单64 '
        '(id INTEGER PRIMARY KEY AUTOINCREMENT, 学号 INTEGER)',
      );
      await Api.instance.query(
        'CREATE TABLE IF NOT EXISTS 年级成绩单64 '
        '(学号 INTEGER PRIMARY KEY AUTOINCREMENT, 姓名 TEXT)',
      );
      await Api.instance.query('DELETE FROM 学生名单64');
      await Api.instance.query('DROP INDEX IF EXISTS "uk_学号"');
      await Api.instance.query(
        'INSERT INTO 学生名单64 (学号) VALUES '
        '(1),(2),(3),(4),(5),(6),(7),(8),(9),(10),'
        '(11),(12),(13),(14),(15),(16),(17),(18),(19),(20),'
        '(21),(22),(23),(24),(25),(26),(27)',
      );
    });
  }

  testWidgets('同名列部分匹配（27/30）：出现一键改选按钮且文案诚实（第 64 轮）', (
    tester,
  ) async {
    await setSurface(tester);
    await createPartialSameNameTables(tester);
    final designerKey = GlobalKey<RelationDesignerState>();
    await tester.pumpWidget(
      host(
        RelationDesigner(
          key: designerKey,
          database: 'main',
          initialTables: const <String>['年级成绩单64', '学生名单64'],
          height: 560,
          driverOverride: 'mysql',
          orphanReportOverride:
              (localTable, localColumn, refTable, refColumn) =>
                  const FkOrphanReport(
                    count: 30,
                    childSamples: <String>['20260101'],
                    parentSamples: <String>['1'],
                    sameNameColumn: '学号',
                    sameNameMatchCount: 27,
                    childNonEmptyCount: 30,
                  ),
          alterTableOverride: (table, body) async =>
              <String, dynamic>{'failed': 0, 'results': <dynamic>[]},
        ),
      ),
    );
    await settle(tester);
    unawaited(
      designerKey.currentState!.openNewForeignKeyForTest(
        localTable: '年级成绩单64',
        localColumn: '学号',
        refTable: '学生名单64',
        refColumn: 'id',
      ),
    );
    await settle(tester, rounds: 10);
    expect(find.text('新建外键关系'), findsOneWidget);

    await tester.tap(find.widgetWithText(Btn, '创建'));
    await settle(tester, rounds: 10);
    // 部分匹配（27/30）也有第三按钮，且 key 与第 63 轮共用。
    expect(find.byKey(const ValueKey('er-orphan-fix-samename')), findsOneWidget);
    expect(find.textContaining('27/30'), findsWidgets);
    expect(find.textContaining('3 行孤儿'), findsWidgets);
    expect(find.textContaining('补齐数据'), findsWidgets);
    expect(find.textContaining('基本完全匹配'), findsNothing);
    expect(find.textContaining('改用同名列「学号」并建唯一索引'), findsOneWidget);

    // 取消：不关闭新建外键弹窗，警告保留。
    await tester.tap(find.byKey(const ValueKey('fk-precheck-cancel')));
    await settle(tester, rounds: 8);
    expect(find.text('新建外键关系'), findsOneWidget);
    expect(find.textContaining('27/30'), findsWidgets);
    await tester.tap(find.widgetWithText(Btn, '取消'));
    await settle(tester, rounds: 8);
    expect(tester.takeException(), isNull);
  });

  testWidgets('部分匹配 + 同名列唯一：建 UNIQUE 后重开弹窗且引用列=同名列（第 64 轮）', (
    tester,
  ) async {
    await setSurface(tester);
    await createPartialSameNameTables(tester);
    final designerKey = GlobalKey<RelationDesignerState>();
    final bodies = <Map<String, dynamic>>[];
    var precheckCalls = 0;
    await tester.pumpWidget(
      host(
        RelationDesigner(
          key: designerKey,
          database: 'main',
          initialTables: const <String>['年级成绩单64', '学生名单64'],
          height: 560,
          driverOverride: 'mysql',
          orphanReportOverride:
              (localTable, localColumn, refTable, refColumn) {
                precheckCalls++;
                if (precheckCalls == 1) {
                  return const FkOrphanReport(
                    count: 30,
                    childSamples: <String>['20260101'],
                    parentSamples: <String>['1'],
                    sameNameColumn: '学号',
                    sameNameMatchCount: 27,
                    childNonEmptyCount: 30,
                  );
                }
                // 改用同名列后两表数据匹配：不再有孤儿行。
                return const FkOrphanReport(count: 0);
              },
          uniquenessOverride: (table, column) async =>
              const ErColumnUniqueness(total: 27, distinct: 27),
          alterTableOverride: (table, body) async {
            bodies.add(body);
            // 模拟真实数据库：把 UNIQUE 索引真正建出来，_reloadTable 才能把
            // 同名列计入「单列唯一」，重开的新建外键弹窗才不会被本地校验拦回。
            for (final raw
                in (body['add_indexes'] as List? ?? const <dynamic>[])) {
              final index = raw as Map;
              final name = (index['name'] as String).replaceAll('"', '""');
              final columnName = ((index['columns'] as List).single as String)
                  .replaceAll('"', '""');
              final tableName = table.replaceAll('"', '""');
              await Api.instance.query(
                'CREATE UNIQUE INDEX "$name" ON "$tableName"("$columnName")',
              );
            }
            return <String, dynamic>{'failed': 0, 'results': <dynamic>[]};
          },
        ),
      ),
    );
    await settle(tester);
    unawaited(
      designerKey.currentState!.openNewForeignKeyForTest(
        localTable: '年级成绩单64',
        localColumn: '学号',
        refTable: '学生名单64',
        refColumn: 'id',
      ),
    );
    await settle(tester, rounds: 10);
    await tester.tap(find.widgetWithText(Btn, '创建'));
    await settle(tester, rounds: 10);
    expect(find.byKey(const ValueKey('er-orphan-fix-samename')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('er-orphan-fix-samename')));
    await settle(tester, rounds: 24);
    // 同名列数据全唯一 → 收到 add_indexes（unique=true，列=学号）。
    final indexBodies = bodies
        .where((body) => body['add_indexes'] != null)
        .toList();
    expect(indexBodies, hasLength(1));
    final index = (indexBodies.single['add_indexes'] as List).single as Map;
    expect(index['unique'], isTrue);
    expect((index['columns'] as List).single, '学号');
    expect(index['name'], startsWith('uk_学号'));
    // 索引建好后用同名列重新打开弹窗（引用列=学号）。
    expect(find.text('新建外键关系'), findsOneWidget);
    expect(find.text('目标列不是唯一键'), findsNothing);

    await tester.tap(find.widgetWithText(Btn, '创建'));
    await settle(tester, rounds: 20);
    final fkPayload = (bodies.last['add_foreign_keys'] as List).single as Map;
    expect(fkPayload['ref_table'], '学生名单64');
    expect((fkPayload['ref_columns'] as List).single, '学号');
    expect(find.text('新建外键关系'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('部分匹配 + 同名列有重复：只说明、不发 DDL，保留原警告（第 64 轮）', (
    tester,
  ) async {
    await setSurface(tester);
    await createPartialSameNameTables(tester);
    final designerKey = GlobalKey<RelationDesignerState>();
    var alterCalls = 0;
    await tester.pumpWidget(
      host(
        RelationDesigner(
          key: designerKey,
          database: 'main',
          initialTables: const <String>['年级成绩单64', '学生名单64'],
          height: 560,
          driverOverride: 'mysql',
          orphanReportOverride:
              (localTable, localColumn, refTable, refColumn) =>
                  const FkOrphanReport(
                    count: 30,
                    childSamples: <String>['20260101'],
                    parentSamples: <String>['1'],
                    sameNameColumn: '学号',
                    sameNameMatchCount: 27,
                    childNonEmptyCount: 30,
                  ),
          uniquenessOverride: (table, column) async =>
              const ErColumnUniqueness(
                total: 27,
                distinct: 1,
                duplicates: <ErDuplicateValue>[
                  ErDuplicateValue('20260101', 27),
                ],
              ),
          alterTableOverride: (table, body) async {
            alterCalls++;
            return <String, dynamic>{'failed': 0, 'results': <dynamic>[]};
          },
        ),
      ),
    );
    await settle(tester);
    unawaited(
      designerKey.currentState!.openNewForeignKeyForTest(
        localTable: '年级成绩单64',
        localColumn: '学号',
        refTable: '学生名单64',
        refColumn: 'id',
      ),
    );
    await settle(tester, rounds: 10);
    await tester.tap(find.widgetWithText(Btn, '创建'));
    await settle(tester, rounds: 10);
    await tester.tap(find.byKey(const ValueKey('er-orphan-fix-samename')));
    await settle(tester, rounds: 12);
    // 重复值说明（数量/示例），不发任何 ALTER。
    expect(find.text('目标列不是唯一键'), findsOneWidget);
    expect(find.textContaining('27 行非空'), findsWidgets);
    expect(find.textContaining('20260101'), findsWidgets);
    expect(find.textContaining('出现 27 次'), findsWidgets);
    expect(alterCalls, 0);
    await tester.tap(find.widgetWithText(Btn, '关闭'));
    await settle(tester, rounds: 8);
    // 回到原新建外键弹窗，仍保留部分匹配警告（引用列没变）。
    expect(find.text('新建外键关系'), findsOneWidget);
    expect(find.textContaining('27/30'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(Btn, '取消'));
    await settle(tester, rounds: 8);
  });

  testWidgets('1826 连续失败两次：第 3 次改用 uk_x_3 成功（第 64 轮）', (tester) async {
    await setSurface(tester);
    await createUniqueIndexScenarioTables(tester);
    final designerKey = GlobalKey<RelationDesignerState>();
    final bodies = <Map<String, dynamic>>[];
    await tester.pumpWidget(
      host(
        RelationDesigner(
          key: designerKey,
          database: 'main',
          initialTables: const <String>['uq_child', 'uq_parent'],
          height: 520,
          driverOverride: 'mysql',
          uniquenessOverride: (table, column) async =>
              const ErColumnUniqueness(total: 3, distinct: 3),
          alterTableOverride: (table, body) async {
            bodies.add(body);
            // 前两次撞名（模拟并发/缓存里索引名已被占用），第三次成功。
            if (bodies.length <= 2) {
              throw StateError(
                'ERROR 1826 (HY000): Duplicate key name uk_code',
              );
            }
            return <String, dynamic>{'failed': 0, 'results': <dynamic>[]};
          },
        ),
      ),
    );
    await settle(tester);
    unawaited(
      designerKey.currentState!.openNewForeignKeyForTest(
        localTable: 'uq_child',
        localColumn: 'code',
        refTable: 'uq_parent',
        refColumn: 'code',
      ),
    );
    await settle(tester, rounds: 10);
    expect(find.text('目标列不是唯一键'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('er-create-unique-index')));
    await settle(tester, rounds: 26);

    // 三次尝试的载荷：uk_code → uk_code_2 → uk_code_3，全部 unique=true。
    expect(bodies, hasLength(3));
    Map indexPayload(Map body) => (body['add_indexes'] as List).single as Map;
    expect(indexPayload(bodies[0])['name'], 'uk_code');
    expect(indexPayload(bodies[1])['name'], 'uk_code_2');
    expect(indexPayload(bodies[2])['name'], 'uk_code_3');
    for (final body in bodies) {
      expect(indexPayload(body)['unique'], isTrue);
      expect((indexPayload(body)['columns'] as List).single, 'code');
    }
    // override 假成功：重开后仍被真实结构拦回阻止提示；真实 DB 会打开弹窗。
    expect(find.text('无法创建外键'), findsWidgets);
    await tester.tap(find.widgetWithText(Btn, '关闭'));
    await settle(tester, rounds: 8);
    expect(tester.takeException(), isNull);
  });
}
