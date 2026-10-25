//! 表设计器「列改名不会生效」可见化（第 64 轮）。
//!
//! tableDesignRenameColumns 会安全跳过撞名/互换/空名/重复目标名的改名（避免
//! ALTER 指向不存在或冲突的列），但旧 UI 直接提示「修改已应用」，用户会以为
//! 改名成功了。本文件覆盖：
//!   * tableDesignRenameConflicts 的纯逻辑：各种跳过原因 + 与
//!     tableDesignRenameColumns 共用判定的一致性断言；
//!   * tableDesignRenameConflictWarning 的中英文警示文案；
//!   * 应用前警告对话框的渲染与「取消 / 继续」返回值；
//!   * _applyDesign 的完整接线（live SQLite + dylib）：取消什么都不做，确认后
//!     才 dry_run，最终应用时改名被跳过、其余修改照常生效。dylib 缺失时该用例
//!     自动 skip（与 table_view_dirty_guard_test 同一前提）。

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
import 'package:rust_myadmin_desktop/src/views/table_view.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

/// 设计器里的一行（与 _seedDesigner 产出的形状一致）。
Map<String, dynamic> designColumn(
  String original,
  String name, {
  bool isNew = false,
}) => <String, dynamic>{
  'name': name,
  'original': original,
  'isNew': isNew,
  'type': 'INT',
  'nullable': false,
  'default': '',
  'auto_increment': false,
  'comment': '',
};

/// 期望会改名（用户输入了和原名不同的新名）的现有列，含新名为空的输入。
List<Map<String, String>> desiredRenames(List<Map<String, dynamic>> columns) {
  final out = <Map<String, String>>[];
  for (final column in columns) {
    final original = (column['original'] ?? '').toString().trim();
    final name = (column['name'] ?? '').toString().trim();
    if (column['isNew'] == true || original.isEmpty || original == name) {
      continue;
    }
    out.add(<String, String>{'from': original, 'to': name});
  }
  return out;
}

String pairOf(String from, String to) => '$from=>$to';

String conflictPair(TableDesignRenameConflict conflict) =>
    pairOf(conflict.from, conflict.to);

Widget host(Widget child) => MaterialApp(
  theme: buildAppTheme(),
  home: Scaffold(body: child),
);

/// 等真实的 FFI 往返（dylib）+ 对话框动画：live 测试沿用 table_view_dirty_guard
/// 的 settle 写法。
Future<void> settle(WidgetTester tester, {int rounds = 16}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void size(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 设计器里 controller 文本等于 [text] 的输入框（列名 / 类型 / 默认值 / 注释
/// 都是同一个 TextField 组件）。
Finder designField(String text, {int index = 0}) => find
    .byWidgetPredicate(
      (widget) => widget is TextField && widget.controller?.text == text,
    )
    .at(index);

void main() {
  setUp(() => I18n.setLang(AppLang.zh));
  tearDown(() => I18n.setLang(AppLang.zh));

  group('tableDesignRenameColumns：正常改名仍然生效（回归）', () {
    test('普通改名无冲突，冲突列表为空', () {
      final columns = <Map<String, dynamic>>[
        designColumn('qty', 'quantity'),
        designColumn('price', 'price'),
        designColumn('', 'new_col', isNew: true),
      ];
      expect(tableDesignRenameColumns(columns), <Map<String, dynamic>>[
        <String, dynamic>{'from': 'qty', 'to': 'quantity'},
      ]);
      expect(tableDesignRenameConflicts(columns), isEmpty);
    });

    test('只有新增列 / 未改名 / 空原名 → 没有冲突也没有 RENAME', () {
      final columns = <Map<String, dynamic>>[
        designColumn('a', 'a'),
        designColumn('', 'new_col', isNew: true),
      ];
      expect(tableDesignRenameColumns(columns), isEmpty);
      expect(tableDesignRenameConflicts(columns), isEmpty);
    });
  });

  group('tableDesignRenameConflicts：每种「不会生效」的原因', () {
    test('目标名是另一列当前的名字（被不改名的列占用）', () {
      final conflicts = tableDesignRenameConflicts(<Map<String, dynamic>>[
        designColumn('qty', 'price'),
        designColumn('price', 'price'),
      ]);
      expect(conflicts, hasLength(1));
      expect(conflicts.single.from, 'qty');
      expect(conflicts.single.to, 'price');
      expect(
        conflicts.single.kind,
        TableDesignRenameConflictKind.originalNameTaken,
      );
      // 文案必须点名「另一列的原名」，让文员知道为什么没生效。
      expect(conflicts.single.zh, contains('qty → price'));
      expect(conflicts.single.zh, contains('另一列的原名'));
    });

    test('两列互换名字：两条都跳过，都给出原因', () {
      final columns = <Map<String, dynamic>>[
        designColumn('a', 'b'),
        designColumn('b', 'a'),
      ];
      expect(tableDesignRenameColumns(columns), isEmpty);
      final conflicts = tableDesignRenameConflicts(columns);
      expect(conflicts.map(conflictPair).toList(), <String>['a=>b', 'b=>a']);
      for (final conflict in conflicts) {
        expect(conflict.kind, TableDesignRenameConflictKind.originalNameTaken);
        expect(conflict.zh, contains('两列互换或链式改名'));
      }
    });

    test('链式改名 A→B、B→C：A→B 撞名被跳过，B→C 照常生效', () {
      final columns = <Map<String, dynamic>>[
        designColumn('a', 'b'),
        designColumn('b', 'c'),
      ];
      expect(tableDesignRenameColumns(columns), <Map<String, dynamic>>[
        <String, dynamic>{'from': 'b', 'to': 'c'},
      ]);
      final conflicts = tableDesignRenameConflicts(columns);
      expect(conflicts.map(conflictPair).toList(), <String>['a=>b']);
      expect(
        conflicts.single.kind,
        TableDesignRenameConflictKind.originalNameTaken,
      );
    });

    test('目标名被新增列占用', () {
      final columns = <Map<String, dynamic>>[
        designColumn('a', 'tmp'),
        designColumn('', 'tmp', isNew: true),
      ];
      expect(tableDesignRenameColumns(columns), isEmpty);
      final conflicts = tableDesignRenameConflicts(columns);
      expect(conflicts.map(conflictPair).toList(), <String>['a=>tmp']);
      expect(conflicts.single.kind, TableDesignRenameConflictKind.nameOccupied);
      expect(conflicts.single.zh, contains('新增列'));
    });

    test('新列名为空：不会改名，数据库保持原名', () {
      final columns = <Map<String, dynamic>>[
        designColumn('a', ''),
        designColumn('b', 'b'),
      ];
      expect(tableDesignRenameColumns(columns), isEmpty);
      final conflicts = tableDesignRenameConflicts(columns);
      expect(conflicts, hasLength(1));
      expect(conflicts.single.from, 'a');
      expect(conflicts.single.to, isEmpty);
      expect(conflicts.single.kind, TableDesignRenameConflictKind.emptyName);
      expect(conflicts.single.zh, startsWith('a → （空）：'));
      expect(conflicts.single.en, startsWith('a → (blank): '));
    });

    test('多列改成同一个目标名：只有第一条生效，后面明确说被跳过', () {
      final columns = <Map<String, dynamic>>[
        designColumn('a', 'x'),
        designColumn('b', 'x'),
        designColumn('c', 'c'),
      ];
      expect(tableDesignRenameColumns(columns), <Map<String, dynamic>>[
        <String, dynamic>{'from': 'a', 'to': 'x'},
      ]);
      final conflicts = tableDesignRenameConflicts(columns);
      expect(conflicts, hasLength(1));
      expect(conflicts.single.from, 'b');
      expect(
        conflicts.single.kind,
        TableDesignRenameConflictKind.duplicateTarget,
      );
      // 「谁先占了这个名字」必须写进文案。
      expect(conflicts.single.otherColumn, 'a');
      expect(conflicts.single.zh, contains('列「a」也要改名为「x」'));
    });

    test('不是重复目标名而是撞原名时，两条都按「另一列的原名」解释', () {
      // 存在另一列 b（不改名）时，a→b 与 d→b 都是「撞另一列的原名」，
      // 而不是第 2 条被第 1 条占掉名字的重复目标名。
      final columns = <Map<String, dynamic>>[
        designColumn('a', 'b'),
        designColumn('c', 'x'),
        designColumn('d', 'b'),
        designColumn('b', 'b'),
      ];
      final conflicts = tableDesignRenameConflicts(columns);
      expect(conflicts.map(conflictPair).toList(), <String>['a=>b', 'd=>b']);
      for (final conflict in conflicts) {
        expect(conflict.kind, TableDesignRenameConflictKind.originalNameTaken);
      }
      expect(tableDesignRenameColumns(columns), <Map<String, dynamic>>[
        <String, dynamic>{'from': 'c', 'to': 'x'},
      ]);
    });

    test('大小写不敏感：目标名只差大小写也算撞名', () {
      final columns = <Map<String, dynamic>>[
        designColumn('a', 'PRICE'),
        designColumn('price', 'price'),
      ];
      expect(tableDesignRenameColumns(columns), isEmpty);
      final conflicts = tableDesignRenameConflicts(columns);
      expect(conflicts, hasLength(1));
      expect(conflicts.single.to, 'PRICE');
    });

    test('前后空格 trim 后判定：只能空白的新名也算空名', () {
      final columns = <Map<String, dynamic>>[designColumn(' a ', '   ')];
      final conflicts = tableDesignRenameConflicts(columns);
      expect(conflicts.single.from, 'a');
      expect(conflicts.single.to, isEmpty);
      expect(conflicts.single.kind, TableDesignRenameConflictKind.emptyName);
    });
  });

  group('冲突集合与 tableDesignRenameColumns 的跳过集合一致', () {
    final scenarios = <String, List<Map<String, dynamic>>>{
      '普通改名': <Map<String, dynamic>>[
        designColumn('a', 'aa'),
        designColumn('b', 'b'),
      ],
      '撞未改名列': <Map<String, dynamic>>[
        designColumn('a', 'b'),
        designColumn('b', 'b'),
        designColumn('c', 'cc'),
      ],
      '互换': <Map<String, dynamic>>[
        designColumn('a', 'b'),
        designColumn('b', 'a'),
      ],
      '链式': <Map<String, dynamic>>[
        designColumn('a', 'b'),
        designColumn('b', 'c'),
        designColumn('c', 'c'),
      ],
      '被新增列占用': <Map<String, dynamic>>[
        designColumn('a', 'tmp'),
        designColumn('', 'tmp', isNew: true),
      ],
      '空名': <Map<String, dynamic>>[
        designColumn('a', ''),
        designColumn('b', 'bb'),
      ],
      '重复目标名': <Map<String, dynamic>>[
        designColumn('a', 'x'),
        designColumn('b', 'x'),
        designColumn('c', 'x'),
      ],
      '混合': <Map<String, dynamic>>[
        designColumn('a', 'b'),
        designColumn('b', 'c'),
        designColumn('c', ''),
        designColumn('d', 'x'),
        designColumn('e', 'x'),
        designColumn('', 'new_col', isNew: true),
        designColumn('f', 'f'),
      ],
    };

    for (final entry in scenarios.entries) {
      test(entry.key, () {
        final columns = entry.value;
        final applied = tableDesignRenameColumns(columns)
            .map(
              (rename) => pairOf(
                (rename['from'] ?? '').toString(),
                (rename['to'] ?? '').toString(),
              ),
            )
            .toSet();
        final skipped = desiredRenames(columns)
            .map((rename) => pairOf(rename['from']!, rename['to']!))
            .where((pair) => !applied.contains(pair))
            .toList();
        final conflicts = tableDesignRenameConflicts(columns);
        expect(conflicts.map(conflictPair).toList(), skipped);
        // 另一方向：每条冲突都对应一条同名同姓的被跳过改名。
        for (final conflict in conflicts) {
          expect(
            desiredRenames(columns).any(
              (rename) =>
                  rename['from'] == conflict.from &&
                  rename['to'] == conflict.to,
            ),
            isTrue,
            reason: conflict.zh,
          );
        }
      });
    }
  });

  group('冲突文案（zh/en 成对，界面语言无关）', () {
    test('TableDesignRenameConflict.zh / en 始终双语', () {
      final conflicts = tableDesignRenameConflicts(<Map<String, dynamic>>[
        designColumn('a', 'b'),
        designColumn('b', 'a'),
      ]);
      final first = conflicts.first;
      I18n.setLang(AppLang.en);
      expect(first.zh, startsWith('a → b：'));
      expect(first.en, startsWith('a → b: '));
      I18n.setLang(AppLang.zh);
      expect(first.zh, startsWith('a → b：'));
      expect(first.en, isNot(first.zh));
    });

    test('warning 中文：应用前说明「继续会跳过」', () {
      final conflicts = tableDesignRenameConflicts(<Map<String, dynamic>>[
        designColumn('a', 'b'),
        designColumn('b', 'a'),
      ]);
      final warning = tableDesignRenameConflictWarning(conflicts);
      expect(warning, contains('以下 2 处改名不会生效'));
      expect(warning, contains('继续应用会跳过它们'));
      expect(warning, contains('a → b：'));
      expect(warning, contains('b → a：'));
    });

    test('warning 中文（预览）：说明预览 SQL 不包含这些改名', () {
      final conflicts = tableDesignRenameConflicts(<Map<String, dynamic>>[
        designColumn('a', 'b'),
        designColumn('b', 'a'),
      ]);
      final warning = tableDesignRenameConflictWarning(
        conflicts,
        preview: true,
      );
      expect(warning, contains('预览 SQL 不包含以下 2 处改名'));
    });

    test('warning 英文：继续 / 预览两套措辞', () {
      I18n.setLang(AppLang.en);
      final conflicts = tableDesignRenameConflicts(<Map<String, dynamic>>[
        designColumn('a', 'b'),
        designColumn('b', 'a'),
      ]);
      expect(
        tableDesignRenameConflictWarning(conflicts),
        contains('The following 2 rename(s) will not take effect'),
      );
      expect(
        tableDesignRenameConflictWarning(conflicts, preview: true),
        contains('The preview SQL does not include the following 2 rename(s)'),
      );
    });
  });

  group('showTableDesignRenameConflictDialog：应用前警告弹窗', () {
    List<TableDesignRenameConflict> sampleConflicts() =>
        tableDesignRenameConflicts(<Map<String, dynamic>>[
          designColumn('qty', 'price'),
          designColumn('price', 'price'),
          designColumn('note', ''),
        ]);

    testWidgets('列出每条「原名 → 新名：原因」，取消返回 false', (tester) async {
      final conflicts = sampleConflicts();
      expect(conflicts, hasLength(2));
      bool? result;
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) => Btn(
              'open',
              key: const ValueKey<String>('open-conflict-dialog'),
              onPressed: () async {
                result = await showTableDesignRenameConflictDialog(
                  context,
                  conflicts: conflicts,
                );
              },
            ),
          ),
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('open-conflict-dialog')),
      );
      await tester.pumpAndSettle();

      expect(find.text('有改名不会生效'), findsOneWidget);
      expect(find.textContaining('qty → price：'), findsWidgets);
      expect(find.textContaining('note → （空）：'), findsWidgets);
      expect(find.textContaining('继续应用其余修改'), findsWidgets);
      expect(find.textContaining('其余修改照常应用'), findsWidgets);
      // AlertBox 用 SelectableText 渲染，单独断言「2 处」摘要。
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText &&
              (widget.data ?? '').contains('有 2 处列改名会被跳过'),
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(
          const ValueKey<String>('table-design-rename-conflict-cancel'),
        ),
      );
      await tester.pumpAndSettle();
      expect(result, isFalse);
      expect(find.text('有改名不会生效'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('继续应用其余修改返回 true', (tester) async {
      final conflicts = sampleConflicts();
      bool? result;
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) => Btn(
              'open',
              key: const ValueKey<String>('open-conflict-dialog'),
              onPressed: () async {
                result = await showTableDesignRenameConflictDialog(
                  context,
                  conflicts: conflicts,
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('open-conflict-dialog')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey<String>('table-design-rename-conflict-continue'),
        ),
      );
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(find.text('有改名不会生效'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('没有其它修改时文案诚实说明「继续不会修改数据库」', (tester) async {
      final conflicts = tableDesignRenameConflicts(<Map<String, dynamic>>[
        designColumn('a', 'b'),
        designColumn('b', 'a'),
      ]);
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) => Btn(
              'open',
              key: const ValueKey<String>('open-conflict-dialog'),
              onPressed: () => showTableDesignRenameConflictDialog(
                context,
                conflicts: conflicts,
                hasOtherChanges: false,
              ),
            ),
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('open-conflict-dialog')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('当前没有其它修改'), findsWidgets);
      await tester.tap(
        find.byKey(
          const ValueKey<String>('table-design-rename-conflict-cancel'),
        ),
      );
      await tester.pumpAndSettle();
    });

    testWidgets('英文界面：标题、原因、按钮全部英文', (tester) async {
      I18n.setLang(AppLang.en);
      final conflicts = tableDesignRenameConflicts(<Map<String, dynamic>>[
        designColumn('a', 'b'),
        designColumn('b', 'a'),
      ]);
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) => Btn(
              'open',
              key: const ValueKey<String>('open-conflict-dialog'),
              onPressed: () => showTableDesignRenameConflictDialog(
                context,
                conflicts: conflicts,
              ),
            ),
          ),
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('open-conflict-dialog')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Some renames will not take effect'), findsOneWidget);
      expect(find.textContaining('a → b: '), findsWidgets);
      expect(find.textContaining('Apply the other changes'), findsWidgets);
      expect(find.text('有改名不会生效'), findsNothing);
      await tester.tap(
        find.byKey(
          const ValueKey<String>('table-design-rename-conflict-continue'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  // =====================================================================
  // _applyDesign 接线：冲突弹窗拦在 dry_run 之前（live SQLite + dylib）
  // =====================================================================
  group('_applyDesign：改名冲突弹窗（live SQLite）', () {
    const table = 'design_conflict';
    late Directory temporary;
    late bool available;

    setUpAll(() async {
      available = false;
      final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
      if (!dylib.existsSync()) return;
      try {
        await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
        temporary = await Directory.systemTemp.createTemp('rma-r64-rename-');
        await Api.init(temporary.path);
        await AppState.instance.bootstrap(temporary.path);
        File('${temporary.path}/test.sqlite').createSync();
        final connection = await Api.instance.createConnection(
          <String, dynamic>{
            'name': 'r64-rename',
            'driver': 'sqlite',
            'database': '${temporary.path}/test.sqlite',
          },
        );
        await AppState.instance.connect(
          (connection['connection'] as Map)['id'].toString(),
        );
        await AppState.instance.refreshDatabases();
        available = true;
      } catch (_) {
        available = false;
      }
    });

    tearDownAll(() async {
      if (!available) return;
      try {
        await Api.instance.disconnect();
      } catch (_) {}
      try {
        temporary.deleteSync(recursive: true);
      } catch (_) {}
    });

    /// 每次用例一张干净的 SQLite 表：id / qty / price / note。
    Future<void> resetTable(WidgetTester tester) async {
      await tester.runAsync(() async {
        await Api.instance.query('DROP TABLE IF EXISTS $table;');
        await Api.instance.query(
          'CREATE TABLE $table (id INTEGER PRIMARY KEY, qty TEXT, price TEXT, note TEXT);',
        );
      });
    }

    Future<Map<String, String>> columnTypes(WidgetTester tester) async {
      final structure = await tester.runAsync(
        () => Api.instance.structure('main', table),
      );
      final out = <String, String>{};
      for (final raw in (structure!['columns'] as List? ?? <dynamic>[])) {
        final map = Map<String, dynamic>.from(raw as Map);
        final name = (map['name'] ?? map['COLUMN_NAME'] ?? '').toString();
        final type =
            (map['type_name'] ?? map['COLUMN_TYPE'] ?? map['type'] ?? '')
                .toString();
        out[name] = type.toLowerCase();
      }
      return out;
    }

    Future<void> tapApply(WidgetTester tester) async {
      final apply = find.text('应用修改');
      await tester.ensureVisible(apply);
      await tester.pumpAndSettle();
      await tester.tap(apply);
      await tester.pumpAndSettle();
    }

    testWidgets('取消什么都不做；确认后才 dry_run；应用时改名被跳过、其余修改生效', (tester) async {
      if (!available) {
        markTestSkipped(
          'dylib 未就绪（rust/target/debug/librust_myadmin_core.dylib）',
        );
        return;
      }
      size(tester);
      I18n.setLang(AppLang.zh);
      await resetTable(tester);
      final notice = Notice();
      addTearDown(notice.dispose);

      await tester.pumpWidget(
        host(TableView(db: 'main', table: table, notice: notice)),
      );
      await settle(tester);
      await tester.tap(find.text('设计').first);
      await settle(tester, rounds: 8);
      expect(find.text('字段设计'), findsOneWidget);

      // 1) qty 改名成 price（撞另一列的原名）；2) 删掉 note 列（让「继续」后
      // 还有一条 SQLite 支持的其余修改，而不是空载荷）。
      await tester.enterText(designField('qty'), 'price');
      await tester.pump();
      final deleteButtons = find.widgetWithText(Btn, '删除');
      expect(deleteButtons, findsNWidgets(4));
      final deleteNote = deleteButtons.last;
      await tester.ensureVisible(deleteNote);
      await tester.pumpAndSettle();
      await tester.tap(deleteNote);
      await tester.pumpAndSettle();

      // 应用 → 先弹冲突警告（在 dry_run / ALTER 之前），取消。
      await tapApply(tester);
      expect(find.text('有改名不会生效'), findsOneWidget);
      expect(find.textContaining('qty → price：'), findsWidgets);
      await tester.tap(
        find.byKey(
          const ValueKey<String>('table-design-rename-conflict-cancel'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('有改名不会生效'), findsNothing);
      // 设计 tab 留下持久警示，不再假装改名生效。
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText &&
              (widget.data ?? '').contains('以下 1 处改名不会生效'),
        ),
        findsOneWidget,
      );
      // 取消 = 什么都没执行（note 还在、qty 还是原名）。
      var types = await columnTypes(tester);
      expect(types.keys.toList(), <String>['id', 'qty', 'price', 'note']);

      // 再次应用 → 冲突警告里选「继续应用其余修改」→ 这时才出现 dry_run 的
      // SQL 确认框；在这里取消，仍然不改库。
      await tapApply(tester);
      await tester.tap(
        find.byKey(
          const ValueKey<String>('table-design-rename-conflict-continue'),
        ),
      );
      await settle(tester, rounds: 24);
      expect(find.text('请确认'), findsOneWidget);
      // dry_run 的 SQL 里不能出现改名语句（改名已被跳过），但要有删列语句。
      final confirmBody = find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            (widget.data ?? '').contains('DROP COLUMN'),
      );
      expect(confirmBody, findsWidgets);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText &&
              (widget.data ?? '').contains('RENAME COLUMN'),
        ),
        findsNothing,
      );
      await tester.tap(find.widgetWithText(Btn, '取消'));
      await settle(tester, rounds: 10);
      types = await columnTypes(tester);
      expect(types.keys.toList(), <String>['id', 'qty', 'price', 'note']);

      // 第三次应用并真正确认：note 被删除，qty 没有改名成 price（改名被跳过）。
      await tapApply(tester);
      await tester.tap(
        find.byKey(
          const ValueKey<String>('table-design-rename-conflict-continue'),
        ),
      );
      await settle(tester, rounds: 24);
      expect(find.text('请确认'), findsOneWidget);
      await tester.tap(find.widgetWithText(Btn, '应用'));
      await settle(tester, rounds: 30);

      types = await columnTypes(tester);
      expect(types.keys.toList(), <String>['id', 'qty', 'price']);
      expect(types.containsKey('note'), isFalse);
      // 改名被跳过：qty 仍是 qty，没有变成第二个 price。
      expect(types.containsKey('price'), isTrue);
      // 结果提示必须说明「改名未生效（已跳过）」，而不是只说修改已应用。
      expect(find.textContaining('处改名未生效（已跳过）'), findsWidgets);
      // notice 的淡出计时器还在跑，先让它走完再结束测试。
      await tester.pump(const Duration(seconds: 4));
      expect(tester.takeException(), isNull);
    });
  });
}
