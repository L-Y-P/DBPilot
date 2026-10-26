// 纯逻辑单测：E-R 关系设计器的模型 / 外键 payload / 中间表 / 命中检测 / 布局。
//
// 这里不需要 dylib，也不需要数据库：er_model.dart 不 import Flutter widget 层，
// 只依赖 dart:ui 的几何类型。

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';
import 'package:rust_myadmin_desktop/src/views/er_model.dart';

ErTable table(String name, List<ErColumn> columns) =>
    ErTable(name: name, columns: columns);

ErColumn column(
  String name, {
  String type = 'int',
  bool primary = false,
  bool foreignKey = false,
}) => ErColumn(
  name: name,
  typeName: type,
  primary: primary,
  foreignKey: foreignKey,
);

/// MySQL / PostgreSQL 的 tableStructure 返回形状（drivers::column_json）。
Map<String, dynamic> mysqlStructure() => <String, dynamic>{
  'columns': <dynamic>[
    <String, dynamic>{
      'COLUMN_NAME': 'id',
      'COLUMN_TYPE': 'int unsigned',
      'COLUMN_KEY': 'PRI',
      'IS_NULLABLE': 'NO',
      'EXTRA': 'auto_increment',
    },
    <String, dynamic>{
      'COLUMN_NAME': 'user_id',
      'COLUMN_TYPE': 'int unsigned',
      'COLUMN_KEY': 'MUL',
      'IS_NULLABLE': 'YES',
      'EXTRA': '',
    },
  ],
  'primary_key': <dynamic>['id'],
  'foreign_keys': <dynamic>[
    <String, dynamic>{
      'CONSTRAINT_NAME': 'fk_orders_user',
      'COLUMN_NAME': 'user_id',
      'REFERENCED_TABLE_NAME': 'users',
      'REFERENCED_COLUMN_NAME': 'id',
      'DELETE_RULE': 'CASCADE',
      'UPDATE_RULE': 'RESTRICT',
    },
  ],
};

void main() {
  group('ErTable 解析', () {
    test('structure（MySQL/PG 形状）：列类型、主键、外键标记', () {
      final orders = ErTable.fromStructure('orders', mysqlStructure());
      expect(orders.name, 'orders');
      expect(orders.columns.length, 2);
      expect(orders.columns[0].name, 'id');
      expect(orders.columns[0].typeName, 'int unsigned');
      expect(orders.columns[0].primary, isTrue);
      expect(orders.columns[0].autoIncrement, isTrue);
      expect(orders.columns[1].name, 'user_id');
      expect(orders.columns[1].foreignKey, isTrue);
      expect(orders.columns[1].primary, isFalse);
      expect(orders.primaryColumn?.name, 'id');
      expect(orders.hasPrimary, isTrue);
    });

    test('structure（SQLite 形状）：CONSTRAINT_NAME 为 null 时保留 SEQ', () {
      final payload = <String, dynamic>{
        'columns': <dynamic>[
          <String, dynamic>{
            'name': 'id',
            'type_name': 'INTEGER',
            'COLUMN_KEY': 'PRI',
            'IS_NULLABLE': 'NO',
            'EXTRA': '',
          },
          <String, dynamic>{
            'name': 'author_id',
            'type_name': 'INTEGER',
            'COLUMN_KEY': '',
            'IS_NULLABLE': 'YES',
            'EXTRA': '',
          },
        ],
        'primary_key': <dynamic>['id'],
        'foreign_keys': <dynamic>[
          <String, dynamic>{
            'CONSTRAINT_NAME': null,
            'COLUMN_NAME': 'author_id',
            'REFERENCED_TABLE_NAME': 'authors',
            'REFERENCED_COLUMN_NAME': 'id',
            'DELETE_RULE': 'NO ACTION',
            'UPDATE_RULE': 'NO ACTION',
            'SEQ': 0,
          },
        ],
      };
      final books = ErTable.fromStructure('books', payload);
      expect(books.columns[0].typeName, 'INTEGER');
      expect(books.columns[1].foreignKey, isTrue);
      final relations = ErRelation.fromStructure('books', payload);
      expect(relations.length, 1);
      expect(relations.single.name, '');
      expect(relations.single.seq, 0);
      expect(relations.single.displayLabel, 'books.author_id → authors.id');
      expect(relations.single.onDelete, 'NO ACTION');
    });

    test('structure 里没有主键列表时按 COLUMN_KEY 判断', () {
      final payload = <String, dynamic>{
        'columns': <dynamic>[
          <String, dynamic>{
            'COLUMN_NAME': 'id',
            'COLUMN_TYPE': 'integer',
            'COLUMN_KEY': 'PRI',
          },
          <String, dynamic>{
            'COLUMN_NAME': 'name',
            'COLUMN_TYPE': 'text',
            'COLUMN_KEY': '',
          },
        ],
      };
      final t = ErTable.fromStructure('t', payload);
      expect(t.columns[0].primary, isTrue);
      expect(t.columns[1].primary, isFalse);
    });

    test('builderSchema 兜底解析', () {
      final schema = <String, dynamic>{
        'name': 'orders',
        'columns': <dynamic>[
          <String, dynamic>{'name': 'id', 'type': 'int', 'key': 'PRI'},
          <String, dynamic>{'name': 'user_id', 'type': 'int', 'key': ''},
        ],
        'foreign_keys': <dynamic>[
          <String, dynamic>{
            'column': 'user_id',
            'ref_table': 'users',
            'ref_column': 'id',
          },
        ],
      };
      final orders = ErTable.fromSchema(schema);
      expect(orders.columns.length, 2);
      expect(orders.columns[0].primary, isTrue);
      expect(orders.columns[1].foreignKey, isTrue);
      final relations = ErRelation.fromSchema('orders', schema);
      expect(relations.single.localColumn, 'user_id');
      expect(relations.single.refTable, 'users');
      expect(relations.single.name, '');
    });

    test('复合外键只画一条边', () {
      final payload = <String, dynamic>{
        'columns': <dynamic>[],
        'foreign_keys': <dynamic>[
          <String, dynamic>{
            'CONSTRAINT_NAME': 'fk_multi',
            'COLUMN_NAME': 'a',
            'REFERENCED_TABLE_NAME': 'x',
            'REFERENCED_COLUMN_NAME': 'a1',
          },
          <String, dynamic>{
            'CONSTRAINT_NAME': 'fk_multi',
            'COLUMN_NAME': 'b',
            'REFERENCED_TABLE_NAME': 'x',
            'REFERENCED_COLUMN_NAME': 'b1',
          },
        ],
      };
      expect(ErRelation.fromStructure('t', payload).length, 1);
    });
  });

  group('外键命名与 payload', () {
    test('默认约束名 fk_表_字段', () {
      expect(defaultFkName('users', 'role_id'), 'fk_users_role_id');
      expect(defaultFkName(' user ', 'id '), 'fk_user_id');
    });

    test('中文名塌缩成合法的 ASCII 约束名', () {
      final name = defaultFkName('订单', '用户id');
      expect(RegExp(r'^[0-9A-Za-z_]+$').hasMatch(name), isTrue);
      expect(name, isNotEmpty);
    });

    test('中文表名的默认约束名互不相同（MySQL 库内唯一）', () {
      final first = defaultFkName('订单', '用户id');
      final second = defaultFkName('客户', '用户id');
      final third = defaultFkName('订单', '商品id');
      expect(first, isNot(second), reason: '两个中文表名不能塌缩成同一个约束名');
      expect(first, isNot(third));
      expect(RegExp(r'^[0-9A-Za-z_]+$').hasMatch(first), isTrue);
    });

    test('约束名去重：_2 / _3', () {
      expect(uniqueFkName('users', 'role_id', <String>{}), 'fk_users_role_id');
      expect(
        uniqueFkName('users', 'role_id', <String>{'fk_users_role_id'}),
        'fk_users_role_id_2',
      );
      expect(uniqueName('a', <String>{'a', 'a_2'}), 'a_3');
    });

    test('add_foreign_keys payload', () {
      final payload = foreignKeyPayload(
        name: ' fk_orders_user ',
        localColumn: 'user_id',
        refTable: 'users',
        refColumn: 'id',
        onDelete: 'cascade',
        onUpdate: ' set null ',
      );
      expect(payload['name'], 'fk_orders_user');
      expect(payload['columns'], <String>['user_id']);
      expect(payload['ref_table'], 'users');
      expect(payload['ref_columns'], <String>['id']);
      expect(payload['on_delete'], 'CASCADE');
      expect(payload['on_update'], 'SET NULL');
    });

    test('空动作保持空串（Rust 侧视为不写 ON DELETE/UPDATE）', () {
      final payload = foreignKeyPayload(
        name: 'fk_a_b',
        localColumn: 'b',
        refTable: 'a',
        refColumn: 'id',
      );
      expect(payload['on_delete'], '');
      expect(payload['on_update'], '');
    });
  });

  group('已存在关系判断', () {
    final relations = <ErRelation>[
      const ErRelation(
        localTable: 'books',
        localColumn: 'author_id',
        refTable: 'authors',
        refColumn: 'id',
        name: 'fk_books_author',
      ),
    ];

    test('任一方向都算已有关系', () {
      expect(hasRelationBetween(relations, 'books', 'authors'), isTrue);
      expect(hasRelationBetween(relations, 'authors', 'books'), isTrue);
      expect(hasRelationBetween(relations, 'books', 'tags'), isFalse);
    });

    test('relationBetween 返回那条关系', () {
      expect(
        relationBetween(relations, 'authors', 'books')?.name,
        'fk_books_author',
      );
      expect(relationBetween(relations, 'a', 'b'), isNull);
    });
  });

  group('多对多中间表', () {
    ErTable orders() => table('orders', <ErColumn>[
      column('id', type: 'int unsigned', primary: true),
      column('user_id', type: 'int unsigned', foreignKey: true),
    ]);
    ErTable users() => table('users', <ErColumn>[
      column('id', type: 'int unsigned', primary: true),
    ]);

    test('MySQL：id BIGINT 自增 + 两列 + 两个外键', () {
      final plan = planJunction(
        driver: ErDriver.mysql,
        localTable: orders(),
        refTable: users(),
        existingTableNames: <String>{'orders', 'users'},
      );
      expect(plan, isNotNull);
      expect(plan!.name, 'orders_users');
      expect(plan.idType, 'BIGINT');
      expect(plan.columnA, 'orders_id');
      expect(plan.columnB, 'users_id');
      expect(plan.typeA, 'int unsigned');
      expect(plan.typeB, 'int unsigned');
      final body = plan.createTableBody();
      expect(body['name'], 'orders_users');
      final columns = body['columns'] as List<dynamic>;
      expect(columns.length, 3);
      final id = columns[0] as Map<String, dynamic>;
      expect(id['name'], 'id');
      expect(id['type'], 'BIGINT');
      expect(id['primary'], isTrue);
      expect(id['auto_increment'], isTrue);
      final fks = body['foreign_keys'] as List<dynamic>;
      expect(fks.length, 2);
      expect((fks[0] as Map)['ref_table'], 'orders');
      expect((fks[0] as Map)['ref_columns'], <String>['id']);
      expect((fks[1] as Map)['ref_table'], 'users');
      expect(plan.relations.length, 2);
      expect(plan.fkNameA, isNot(plan.fkNameB));
    });

    test('SQLite：id 用 INTEGER（AUTOINCREMENT 由驱动生成）', () {
      final plan = planJunction(
        driver: ErDriver.sqlite,
        localTable: orders(),
        refTable: users(),
        existingTableNames: <String>{},
      );
      expect(plan!.idType, 'INTEGER');
    });

    test('PostgreSQL：serial 引用的列映射回 integer', () {
      final plan = planJunction(
        driver: ErDriver.postgres,
        localTable: table('events', <ErColumn>[
          column('id', type: 'serial', primary: true),
        ]),
        refTable: table('users', <ErColumn>[
          column('id', type: 'bigserial', primary: true),
        ]),
        existingTableNames: <String>{},
      );
      expect(plan!.typeA, 'integer');
      expect(plan.typeB, 'bigint');
    });

    test('命名去重：_rel / _2', () {
      final rel = planJunction(
        driver: ErDriver.mysql,
        localTable: orders(),
        refTable: users(),
        existingTableNames: <String>{'orders_users'},
      );
      expect(rel!.name, 'orders_users_rel');
      final two = planJunction(
        driver: ErDriver.mysql,
        localTable: orders(),
        refTable: users(),
        existingTableNames: <String>{'orders_users', 'orders_users_rel'},
      );
      expect(two!.name, 'orders_users_2');
    });

    test('用户改过的名字优先', () {
      final plan = planJunction(
        driver: ErDriver.mysql,
        localTable: orders(),
        refTable: users(),
        existingTableNames: <String>{'orders_users'},
        name: 'order_user_link',
      );
      expect(plan!.name, 'order_user_link');
    });

    test('缺主键 / 同一张表时返回 null', () {
      expect(
        planJunction(
          driver: ErDriver.mysql,
          localTable: orders(),
          refTable: table('tags', <ErColumn>[column('name', type: 'text')]),
          existingTableNames: <String>{},
        ),
        isNull,
      );
      expect(
        planJunction(
          driver: ErDriver.mysql,
          localTable: orders(),
          refTable: orders(),
          existingTableNames: <String>{},
        ),
        isNull,
      );
    });
  });

  group('自动布局', () {
    ErTable shortTable(String name) =>
        table(name, <ErColumn>[column('id', primary: true)]);

    test('宽画布一行放得下时同一行排开', () {
      final tables = <ErTable>[
        shortTable('a'),
        shortTable('b'),
        shortTable('c'),
      ];
      final positions = autoErLayout(tables, viewportWidth: 900);
      expect(positions.length, 3);
      expect(positions['a']!.dy, positions['b']!.dy);
      expect(positions['a']!.dx, lessThan(positions['b']!.dx));
      expect(positions['b']!.dx, lessThan(positions['c']!.dx));
      // 非 compact 卡片宽 244（略加宽，类型列更可读）。
      expect(positions['b']!.dx - positions['a']!.dx, 244 + 48);
    });

    test('窄画布折行，行距取该行最高卡片', () {
      final tall = table('tall', <ErColumn>[
        for (var i = 0; i < 8; i++) column('c$i'),
      ]);
      final tables = <ErTable>[tall, shortTable('b')];
      final positions = autoErLayout(tables, viewportWidth: 300);
      expect(positions['b']!.dy, greaterThan(positions['tall']!.dy));
      // 第二行起点 = margin + 第一行最高卡片高度 + gap。
      expect(
        positions['b']!.dy,
        24 + const ErNodeMetrics().heightOf(tall) + 48,
      );
    });

    test('空列表返回空布局', () {
      expect(autoErLayout(const <ErTable>[], viewportWidth: 800), isEmpty);
    });
  });

  group('画布命中检测', () {
    final tables = <ErTable>[
      table('authors', <ErColumn>[
        column('id', type: 'INTEGER', primary: true),
        column('name', type: 'TEXT'),
      ]),
      table('books', <ErColumn>[
        column('id', type: 'INTEGER', primary: true),
        column('author_id', type: 'INTEGER', foreignKey: true),
      ]),
    ];
    final positions = <String, Offset>{
      'authors': const Offset(24, 24),
      'books': const Offset(400, 24),
    };
    final layout = ErCanvasLayout(tables: tables, positions: positions);

    test('fieldAt 行命中与表头不命中', () {
      final metrics = layout.metrics;
      final authorsPos = positions['authors']!;
      final firstRow = Offset(
        authorsPos.dx + 40,
        metrics.rowCenterY(authorsPos, 0),
      );
      expect(layout.fieldAt(firstRow), const ErFieldRef('authors', 0));
      final secondRow = Offset(
        authorsPos.dx + 40,
        metrics.rowCenterY(authorsPos, 1),
      );
      expect(layout.fieldAt(secondRow), const ErFieldRef('authors', 1));
      // 表头区域不算字段。
      expect(
        layout.fieldAt(Offset(authorsPos.dx + 40, authorsPos.dy + 4)),
        isNull,
      );
      // 画布空白处。
      expect(layout.fieldAt(const Offset(1000, 600)), isNull);
    });

    test('连接点与左锚点位置', () {
      final point = layout.connectionPoint('books', 'author_id');
      expect(point, isNotNull);
      expect(point!.dy, layout.metrics.rowCenterY(positions['books']!, 1));
      // 卡片边框会把内容缩进 1px，连接点建在内容右边缘。
      expect(point.dx, 400 + 244 - 1 - 8);
      final anchor = layout.refAnchor('authors', 'id');
      expect(anchor!.dx, 24);
      expect(layout.connectionPoint('books', 'missing'), isNull);
    });

    test('contentSize 不小于视口', () {
      final size = layout.contentSize(viewport: const Size(1200, 800));
      expect(size.width, greaterThanOrEqualTo(1200));
      expect(size.height, greaterThanOrEqualTo(800));
    });

    test('distanceToSegment', () {
      const a = Offset(0, 0);
      const b = Offset(100, 0);
      expect(distanceToSegment(const Offset(50, 0), a, b), 0);
      expect(distanceToSegment(const Offset(50, 5), a, b), 5);
      expect(distanceToSegment(const Offset(-10, 0), a, b), 10);
    });

    test('关系曲线命中：线上命中，远处不命中', () {
      const relation = ErRelation(
        localTable: 'books',
        localColumn: 'author_id',
        refTable: 'authors',
        refColumn: 'id',
        name: 'fk_books_author',
      );
      final curve = relationCurve(layout, relation);
      expect(curve, isNotNull);
      final mid = curve!.labelAnchor;
      expect(hitTestRelationCurves(<ErRelationCurve>[curve], mid), 0);
      expect(
        hitTestRelationCurves(<ErRelationCurve>[
          curve,
        ], mid + const Offset(0, 4)),
        0,
      );
      expect(
        hitTestRelationCurves(<ErRelationCurve>[
          curve,
        ], mid + const Offset(0, 40)),
        isNull,
      );
      expect(
        hitTestRelationCurves(<ErRelationCurve>[
          curve,
        ], mid + const Offset(0, 7)),
        0,
      );
    });

    test('端点缺失 / 目标表不在画布时曲线为 null', () {
      const missing = ErRelation(
        localTable: 'books',
        localColumn: 'author_id',
        refTable: 'nope',
        refColumn: 'id',
      );
      expect(relationCurve(layout, missing), isNull);
      expect(relationCurves(layout, <ErRelation>[missing]), isEmpty);
    });

    test('自引用关系也能画（不穿过卡片）', () {
      final employees = table('employees', <ErColumn>[
        column('id', type: 'INTEGER', primary: true),
        column('manager_id', type: 'INTEGER', foreignKey: true),
      ]);
      final selfLayout = ErCanvasLayout(
        tables: <ErTable>[employees],
        positions: <String, Offset>{'employees': Offset.zero},
      );
      const relation = ErRelation(
        localTable: 'employees',
        localColumn: 'manager_id',
        refTable: 'employees',
        refColumn: 'id',
      );
      final curve = relationCurve(selfLayout, relation);
      expect(curve, isNotNull);
      // 自引用：右侧边界出、右侧边界回，箭头在卡片外侧。
      expect(curve!.start.dx, 244);
      expect(curve.end.dx, 244);
      expect(curve.control1.dx, greaterThan(244));
    });
  });

  group('箭头几何', () {
    final tables = <ErTable>[
      table('a', <ErColumn>[column('id', type: 'INTEGER', primary: true)]),
      table('b', <ErColumn>[column('id', type: 'INTEGER', primary: true)]),
    ];
    final layout = ErCanvasLayout(
      tables: tables,
      positions: <String, Offset>{
        'a': const Offset(24, 24),
        'b': const Offset(400, 24),
      },
    );

    test('箭头尖端在曲线终点、沿终点切线、大小可调', () {
      const relation = ErRelation(
        localTable: 'a',
        localColumn: 'id',
        refTable: 'b',
        refColumn: 'id',
      );
      final curve = relationCurve(layout, relation);
      expect(curve, isNotNull);
      final head = ErArrowHead.forCurve(curve!, length: 13, halfWidth: 6);
      expect(head, isNotNull);
      expect(head!.tip, curve.end);
      expect(head.direction.distance, closeTo(1, 1e-9));
      expect(head.length, closeTo(13, 0.0001));
      expect(head.triangle.length, 3);
      // 从左往右画：箭头底边在尖端左侧。
      expect(head.base.dx, lessThan(head.tip.dx));
      expect(head.left.dy, isNot(head.right.dy));
    });

    test('默认左进右出：源在左 → 源右边界出、目标左边界进', () {
      const metrics = ErNodeMetrics();
      const relation = ErRelation(
        localTable: 'a',
        localColumn: 'id',
        refTable: 'b',
        refColumn: 'id',
      );
      final side = relationAnchorSide(layout, relation);
      expect(side.startOnRight, isTrue);
      expect(side.endOnRight, isFalse);
      final curve = relationCurve(layout, relation)!;
      expect(curve.start, metrics.rightBoundary(const Offset(24, 24), 0));
      expect(curve.end, metrics.leftBoundary(const Offset(400, 24), 0));
      // 水平切线：控制点与端点同高。
      expect(curve.control1.dy, curve.start.dy);
      expect(curve.control2.dy, curve.end.dy);
    });

    test('源在右侧镜像：源左边界出、目标右边界进，箭头朝左', () {
      final mirrored = ErCanvasLayout(
        tables: tables,
        positions: <String, Offset>{
          'a': const Offset(400, 24),
          'b': const Offset(24, 24),
        },
      );
      const relation = ErRelation(
        localTable: 'a',
        localColumn: 'id',
        refTable: 'b',
        refColumn: 'id',
      );
      final side = relationAnchorSide(mirrored, relation);
      expect(side.startOnRight, isFalse);
      expect(side.endOnRight, isTrue);
      final curve = relationCurve(mirrored, relation)!;
      expect(curve.start.dx, 400); // 源左边界
      expect(curve.end.dx, 24 + 244); // 目标右边界
      final head = ErArrowHead.forCurve(curve)!;
      expect(head.tip, curve.end);
      expect(head.direction.dx, lessThan(0));
      expect(head.base.dx, greaterThan(head.tip.dx));
    });

    test('同一水平位置按上下选更顺的一侧', () {
      final stacked = ErCanvasLayout(
        tables: tables,
        positions: <String, Offset>{
          'a': const Offset(100, 24),
          'b': const Offset(100, 300),
        },
      );
      const relation = ErRelation(
        localTable: 'a',
        localColumn: 'id',
        refTable: 'b',
        refColumn: 'id',
      );
      // 源在上方 → 走默认「右出左进」，不用绕圈。
      final side = relationAnchorSide(stacked, relation);
      expect(side.startOnRight, isTrue);
      expect(side.endOnRight, isFalse);
    });

    test('同一字段多条边扇出（控制点上下错开）', () {
      final three = <ErTable>[
        table('a', <ErColumn>[column('id', type: 'INTEGER', primary: true)]),
        table('b', <ErColumn>[column('id', type: 'INTEGER', primary: true)]),
        table('c', <ErColumn>[column('id', type: 'INTEGER', primary: true)]),
      ];
      final wide = ErCanvasLayout(
        tables: three,
        positions: <String, Offset>{
          'a': const Offset(24, 24),
          'b': const Offset(400, 24),
          'c': const Offset(400, 200),
        },
      );
      const r1 = ErRelation(
        localTable: 'a',
        localColumn: 'id',
        refTable: 'b',
        refColumn: 'id',
      );
      const r2 = ErRelation(
        localTable: 'a',
        localColumn: 'id',
        refTable: 'c',
        refColumn: 'id',
      );
      final curves = relationCurves(wide, <ErRelation>[r1, r2]);
      expect(curves.length, 2);
      // 起点 x 相同（同一字段右锚点），y 上下扇开；切线仍然水平。
      expect(curves[0].start.dx, curves[1].start.dx);
      expect(
        (curves[0].start.dy - curves[1].start.dy).abs(),
        closeTo(12, 0.001),
      );
      expect(curves[0].control1.dy, curves[0].start.dy);
      expect(curves[1].control1.dy, curves[1].start.dy);
    });

    test('多条关系指向同一个主键：箭头端点重合（父表侧不扇出）', () {
      // sakila.film 有两个外键（language_id / original_language_id）都指向
      // language.language_id。父表侧如果也扇出，就会画出两个几乎重叠、谁也
      // 点不准的箭头；这里钉住「父表侧端点完全相同」这一条。
      final tables = <ErTable>[
        table('film', <ErColumn>[
          column('film_id', type: 'INTEGER', primary: true),
          column('language_id', type: 'SMALLINT', foreignKey: true),
          column('original_language_id', type: 'SMALLINT', foreignKey: true),
        ]),
        table('language', <ErColumn>[
          column('language_id', type: 'SMALLINT', primary: true),
        ]),
      ];
      final layout = ErCanvasLayout(
        tables: tables,
        positions: <String, Offset>{
          'film': const Offset(24, 24),
          'language': const Offset(400, 24),
        },
      );
      const r1 = ErRelation(
        localTable: 'film',
        localColumn: 'language_id',
        refTable: 'language',
        refColumn: 'language_id',
      );
      const r2 = ErRelation(
        localTable: 'film',
        localColumn: 'original_language_id',
        refTable: 'language',
        refColumn: 'language_id',
      );
      final curves = relationCurves(layout, <ErRelation>[r1, r2]);
      expect(curves.length, 2);
      // 父表侧（箭头所在端）完全重合 —— 两条边收成一个箭头。
      expect(curves[0].end, curves[1].end);
      // 子表侧仍然是两个不同的外键列，起点必须分开，否则线会叠在一起。
      expect(curves[0].start, isNot(curves[1].start));
    });
  });

  group('中间表识别与多对多连线', () {
    ErTable entity(String name) =>
        table(name, <ErColumn>[column('id', type: 'INTEGER', primary: true)]);
    ErTable junction() => table('order_items', <ErColumn>[
      column('id', type: 'INTEGER', primary: true),
      column('order_id', type: 'INTEGER', foreignKey: true),
      column('product_id', type: 'INTEGER', foreignKey: true),
    ]);
    const toOrders = ErRelation(
      localTable: 'order_items',
      localColumn: 'order_id',
      refTable: 'orders',
      refColumn: 'id',
      name: 'fk_order_items_order',
    );
    const toProducts = ErRelation(
      localTable: 'order_items',
      localColumn: 'product_id',
      refTable: 'products',
      refColumn: 'id',
      name: 'fk_order_items_product',
    );

    test('恰好两个单列外键指向两张不同表 → 中间表', () {
      final junctions = detectJunctionTables(
        relationsByTable: <String, List<ErRelation>>{
          'order_items': <ErRelation>[toOrders, toProducts],
        },
        tables: <String>{'orders', 'products', 'order_items'},
      );
      expect(junctions.length, 1);
      final info = junctions['order_items']!;
      expect(info.connects('orders', 'products'), isTrue);
      expect(info.connects('products', 'orders'), isTrue);
      final links = manyToManyLinks(junctions);
      expect(links.single.junctionTable, 'order_items');
      expect(links.single.key, 'm2m:order_items');
      expect(links.single.syntheticRelation.origin, ErRelationOrigin.junction);
    });

    test('一个外键 / 两个外键指向同一张表 / 引用画布外都不算中间表', () {
      final one = detectJunctionTables(
        relationsByTable: <String, List<ErRelation>>{
          'order_items': <ErRelation>[toOrders],
        },
        tables: <String>{'orders', 'products', 'order_items'},
      );
      expect(one, isEmpty);
      final same = detectJunctionTables(
        relationsByTable: <String, List<ErRelation>>{
          'order_items': <ErRelation>[
            toOrders,
            const ErRelation(
              localTable: 'order_items',
              localColumn: 'order_id_2',
              refTable: 'orders',
              refColumn: 'id',
            ),
          ],
        },
        tables: <String>{'orders', 'products', 'order_items'},
      );
      expect(same, isEmpty);
      final outside = detectJunctionTables(
        relationsByTable: <String, List<ErRelation>>{
          'order_items': <ErRelation>[toOrders, toProducts],
        },
        tables: <String>{'order_items', 'orders'},
      );
      expect(outside, isEmpty);
    });

    test('多对多连线锚在两张实体表的左右边缘中部', () {
      final ordersTable = entity('orders');
      final productsTable = entity('products');
      final items = junction();
      final layout = ErCanvasLayout(
        tables: <ErTable>[ordersTable, productsTable, items],
        positions: <String, Offset>{
          'orders': const Offset(24, 24),
          'products': const Offset(400, 24),
          'order_items': const Offset(760, 24),
        },
      );
      final junctions = detectJunctionTables(
        relationsByTable: <String, List<ErRelation>>{
          'order_items': <ErRelation>[toOrders, toProducts],
        },
        tables: <String>{'orders', 'products', 'order_items'},
      );
      final link = manyToManyLinks(junctions).single;
      final curve = manyToManyCurve(layout, link);
      expect(curve, isNotNull);
      expect(curve!.start.dx, 24 + 244);
      expect(curve.end.dx, 400);
      expect(
        curve.start.dy,
        24 + const ErNodeMetrics().heightOf(ordersTable) / 2,
      );
      expect(curve.labelAnchor.dx, greaterThan(curve.start.dx));
      expect(curve.labelAnchor.dx, lessThan(curve.end.dx));
    });
  });

  group('多对多标签避让锚点（P2-6）', () {
    Offset midpointOf(Offset a, Offset b) =>
        Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);

    test('水平连线：锚点从中点沿法线向上偏移，连线中段不再被盖住', () {
      const a = Offset(100, 200);
      const b = Offset(500, 200);
      final midpoint = midpointOf(a, b);
      final anchor = m2mLabelAnchorFor(start: a, end: b);
      expect(anchor, isNot(midpoint), reason: '锚点必须离开曲线中点');
      expect(anchor.dx, closeTo(midpoint.dx, 0.0001), reason: '水平线只上下偏移');
      expect(anchor.dy, lessThan(midpoint.dy));
      expect(midpoint.dy - anchor.dy, closeTo(18, 0.0001));
      // 锚点到中点的向量与连线方向垂直（点积 0）：标签不会压住线的中段。
      final delta = anchor - midpoint;
      final direction = b - a;
      expect(
        delta.dx * direction.dx + delta.dy * direction.dy,
        closeTo(0, 0.0001),
      );
    });

    test('垂直连线：按标签宽度自适应净空（105 + padding），y 不变', () {
      const a = Offset(300, 100);
      const b = Offset(300, 500);
      final midpoint = midpointOf(a, b);
      final anchor = m2mLabelAnchorFor(start: a, end: b);
      expect(anchor.dy, closeTo(midpoint.dy, 0.0001));
      expect(anchor.dx, lessThan(midpoint.dx));
      // 第 55 轮：法线是水平的，必须让开半个标签宽度（105）+ padding（6）。
      expect((anchor - midpoint).distance, closeTo(111, 0.0001));
      expect(m2mLabelClearance(start: a, end: b), closeTo(111, 0.0001));
    });

    test('斜线：净空介于水平与垂直之间；offset 只是下限', () {
      const a = Offset(0, 0);
      const b = Offset(400, 400);
      final midpoint = midpointOf(a, b);
      final anchor = m2mLabelAnchorFor(start: a, end: b);
      expect(anchor.dy, lessThan(midpoint.dy), reason: '优先偏向上方空白侧');
      final clearance = m2mLabelClearance(start: a, end: b);
      expect(clearance, greaterThan(18));
      expect(clearance, lessThan(111));
      expect((anchor - midpoint).distance, closeTo(clearance, 0.0001));
      final delta = anchor - midpoint;
      final direction = b - a;
      expect(
        delta.dx * direction.dx + delta.dy * direction.dy,
        closeTo(0, 0.0001),
      );
      // offset 比自适应净空小 → 不起作用；比它大 → 抬升到 offset。
      expect(
        (m2mLabelAnchorFor(start: a, end: b, offset: 36) - midpoint).distance,
        closeTo(clearance, 0.0001),
      );
      expect(
        (m2mLabelAnchorFor(start: a, end: b, offset: 400) - midpoint).distance,
        closeTo(400, 0.0001),
      );
      // 水平连线时 offset 仍然生效（兼容旧行为）。
      expect(
        (m2mLabelAnchorFor(
                  start: const Offset(0, 0),
                  end: const Offset(400, 0),
                  offset: 36,
                ) -
                const Offset(200, 0))
            .distance,
        closeTo(36, 0.0001),
      );
    });

    test('两点重合 / offset 为 0 时退回中点', () {
      expect(
        m2mLabelAnchorFor(
          start: const Offset(10, 10),
          end: const Offset(10, 10),
        ),
        const Offset(10, 10),
      );
      expect(
        m2mLabelAnchorFor(
          start: const Offset(0, 0),
          end: const Offset(100, 0),
          offset: 0,
        ),
        const Offset(50, 0),
      );
    });

    test('接上真实多对多连线：标签锚点 = 卡片中心中点沿法线上移', () {
      final ordersTable = table('orders', <ErColumn>[
        column('id', type: 'INTEGER', primary: true),
      ]);
      final productsTable = table('products', <ErColumn>[
        column('id', type: 'INTEGER', primary: true),
      ]);
      final layout = ErCanvasLayout(
        tables: <ErTable>[ordersTable, productsTable],
        positions: <String, Offset>{
          'orders': const Offset(24, 24),
          'products': const Offset(400, 24),
        },
      );
      final left = layout.positions['orders']!;
      final right = layout.positions['products']!;
      final metrics = layout.metrics;
      final a = Offset(
        left.dx + metrics.cardWidth / 2,
        left.dy + metrics.heightOf(ordersTable) / 2,
      );
      final b = Offset(
        right.dx + metrics.cardWidth / 2,
        right.dy + metrics.heightOf(productsTable) / 2,
      );
      final anchor = m2mLabelAnchorFor(start: a, end: b);
      // 两卡片同高时，连线中点 y 与卡片中心一致；标签上移 18px 后离开连线。
      expect(anchor.dy, closeTo(a.dy - 18, 0.0001));
      expect(anchor.dx, closeTo((a.dx + b.dx) / 2, 0.0001));
    });
  });

  group('多对多标签自适应净空（第 55 轮）', () {
    test('水平 18 / 垂直 111 / 斜线 86.6，方向决定净空', () {
      expect(
        m2mLabelClearance(
          start: const Offset(0, 0),
          end: const Offset(100, 0),
        ),
        closeTo(18, 0.0001),
      );
      expect(
        m2mLabelClearance(
          start: const Offset(0, 0),
          end: const Offset(0, 100),
        ),
        closeTo(111, 0.0001),
      );
      final diagonal = m2mLabelClearance(
        start: const Offset(0, 0),
        end: const Offset(100, 100),
      );
      expect(diagonal, greaterThan(18));
      expect(diagonal, lessThan(111));
      // |nx| = |ny| = 1/sqrt(2)：0.7071 * (105 + 9) + 6 ≈ 86.61
      expect(diagonal, closeTo(math.sqrt(0.5) * 114 + 6, 0.001));
    });

    test('padding / minOffset / labelSize 可调', () {
      // 水平：15（半高 9 + padding 6）低于 minOffset → 由 18 兜底。
      expect(
        m2mLabelClearance(
          start: const Offset(0, 0),
          end: const Offset(100, 0),
          padding: 0,
        ),
        closeTo(18, 0.0001),
      );
      // 标签变窄：垂直净空 = 半宽 30 + padding 6。
      expect(
        m2mLabelClearance(
          start: const Offset(0, 0),
          end: const Offset(0, 100),
          labelSize: const Size(60, 18),
        ),
        closeTo(36, 0.0001),
      );
      // 显式抬高下限。
      expect(
        m2mLabelClearance(
          start: const Offset(0, 0),
          end: const Offset(0, 100),
          minOffset: 200,
        ),
        closeTo(200, 0.0001),
      );
    });

    test('两点重合返回 minOffset', () {
      expect(
        m2mLabelClearance(start: const Offset(5, 5), end: const Offset(5, 5)),
        18,
      );
      expect(
        m2mLabelClearance(
          start: const Offset(5, 5),
          end: const Offset(5, 5),
          minOffset: 40,
        ),
        40,
      );
    });
  });

  group('关系列表条目（P2-5）', () {
    const fkBooks = ErRelation(
      localTable: 'books',
      localColumn: 'author_id',
      refTable: 'authors',
      refColumn: 'id',
      name: 'fk_books_author',
    );
    const fkReviews = ErRelation(
      localTable: 'reviews',
      localColumn: 'book_id',
      refTable: 'books',
      refColumn: 'id',
    );
    const suggestion = ErRelation(
      localTable: 'orders',
      localColumn: 'user_id',
      refTable: 'users',
      refColumn: 'id',
      origin: ErRelationOrigin.suggested,
    );
    ErManyToManyLink junctionLink({String table = 'order_items'}) =>
        ErManyToManyLink(
          junctionTable: table,
          relationA: ErRelation(
            localTable: table,
            localColumn: 'order_id',
            refTable: 'orders',
            refColumn: 'id',
          ),
          relationB: ErRelation(
            localTable: table,
            localColumn: 'product_id',
            refTable: 'products',
            refColumn: 'id',
          ),
        );

    List<ErRelationListItem> query(String filter) => relationListItems(
      relations: <ErRelation>[fkReviews, fkBooks],
      suggestions: <ErRelation>[suggestion],
      manyToMany: <ErManyToManyLink>[junctionLink()],
      filter: filter,
    );

    test('三类关系合并：外键 → 建议 → 多对多，原始关系保留', () {
      final items = query('');
      expect(items, hasLength(4));
      expect(items.map((item) => item.kind).toList(), <ErRelationListItemKind>[
        ErRelationListItemKind.foreignKey,
        ErRelationListItemKind.foreignKey,
        ErRelationListItemKind.suggested,
        ErRelationListItemKind.manyToMany,
      ]);
      // 同类型按本地表排序：books 在 reviews 前（输入是乱序的）。
      expect(items[0].localTable, 'books');
      expect(items[0].displayLabel, 'books.author_id → authors.id');
      expect(items[0].relation.name, 'fk_books_author');
      expect(items[1].displayLabel, 'reviews.book_id → books.id');
      expect(items[2].displayLabel, 'orders.user_id → users.id');
      expect(items[3].junctionTable, 'order_items');
      expect(items[3].displayLabel, '多对多 · order_items');
      expect(items[3].relation.localTable, 'orders');
      expect(items[3].relation.refTable, 'products');
      // key 稳定唯一，可直接做侧栏 widget key。
      expect(items.map((item) => item.key).toSet().length, items.length);
      expect(items[3].key, 'm2m:order_items');
    });

    test('filter 大小写不敏感，匹配表名 / 列名 / 展示文本 / 中间表名', () {
      expect(query('').length, 4, reason: '空 filter 不过滤');
      expect(query('   ').length, 4, reason: '只有空白也不过滤');
      expect(query('AUTHORS').single.kind, ErRelationListItemKind.foreignKey);
      expect(query('AUTHORS').single.localTable, 'books');
      expect(query('BOOK_ID').single.localColumn, 'book_id');
      expect(query('orders.user_id').single.kind, ErRelationListItemKind.suggested);
      expect(query('多对多').single.kind, ErRelationListItemKind.manyToMany);
      expect(query('order_items').single.junctionTable, 'order_items');
      expect(query('nope'), isEmpty);
    });

    test('filter 也匹配外键约束名；显示仍以 a.b → c.d 为主', () {
      final items = query('');
      expect(items[0].constraintName, 'fk_books_author');
      // 展示文本保持「表.列 → 表.列」，不把约束名塞进 displayLabel。
      expect(items[0].displayLabel, 'books.author_id → authors.id');
      expect(items[0].searchKey, contains('fk_books_author'));
      expect(query('FK_BOOKS_AUTHOR').single.constraintName, 'fk_books_author');
      expect(query('fk_books_author').single.localTable, 'books');
      // SQLite 风格的无名外键：constraintName 为空串，不影响展示 / 搜索。
      expect(items[1].constraintName, '');
      expect(query('reviews').single.constraintName, '');
    });

    test('行 tooltip：完整展示文本 +（有约束名时）约束名，英文同步', () {
      final items = query('');
      final fkItem = items[0];
      final withName = relationListItemTooltip(fkItem);
      expect(withName, contains('books.author_id → authors.id'));
      expect(withName, contains('约束名：fk_books_author'));
      // 无名约束（SQLite）只显示关系本身。
      expect(relationListItemTooltip(items[1]), 'reviews.book_id → books.id');
      expect(relationListItemTooltip(items[3]), '多对多 · order_items');

      I18n.setLang(AppLang.en);
      addTearDown(() => I18n.setLang(AppLang.zh));
      final english = relationListItemTooltip(fkItem);
      expect(english, contains('books.author_id → authors.id'));
      expect(english, contains('Constraint: fk_books_author'));
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(english), isFalse);
    });

    test('可删判定：SQLite / 无名约束不可删，MySQL/PG 有名约束可删', () {
      expect(
        relationListCanDelete(
          driver: 'sqlite',
          constraintName: 'fk_books_author',
        ),
        isFalse,
      );
      expect(
        relationListCanDelete(
          driver: 'SQLite',
          constraintName: 'fk_books_author',
        ),
        isFalse,
        reason: '驱动名大小写不敏感',
      );
      expect(
        relationListCanDelete(
          driver: 'mysql',
          constraintName: 'fk_books_author',
        ),
        isTrue,
      );
      expect(
        relationListCanDelete(
          driver: 'postgres',
          constraintName: 'fk_books_author',
        ),
        isTrue,
      );
      expect(
        relationListCanDelete(driver: 'mysql', constraintName: ''),
        isFalse,
      );
      expect(
        relationListCanDelete(driver: 'mysql', constraintName: '   '),
        isFalse,
      );
      // 无约束名时即使驱动支持 ALTER 也不能按名字删。
      expect(
        relationListCanDelete(driver: 'sqlite', constraintName: ''),
        isFalse,
      );
    });

    test('排序：类型优先，其次本地表 / 本地列（大小写不敏感）', () {
      const fkZeta = ErRelation(
        localTable: 'zeta',
        localColumn: 'id',
        refTable: 'a',
        refColumn: 'id',
      );
      const fkAlpha = ErRelation(
        localTable: 'Alpha',
        localColumn: 'b_id',
        refTable: 'a',
        refColumn: 'id',
      );
      const fkAlphaA = ErRelation(
        localTable: 'Alpha',
        localColumn: 'a_id',
        refTable: 'a',
        refColumn: 'id',
      );
      final items = relationListItems(
        relations: <ErRelation>[fkZeta, fkAlpha, fkAlphaA],
        suggestions: <ErRelation>[],
        manyToMany: <ErManyToManyLink>[],
      );
      expect(
        items.map((item) => '${item.localTable}.${item.localColumn}').toList(),
        <String>['Alpha.a_id', 'Alpha.b_id', 'zeta.id'],
      );
    });

    test('英文模式：多对多展示文本与搜索键同步翻译', () {
      I18n.setLang(AppLang.en);
      addTearDown(() => I18n.setLang(AppLang.zh));
      final items = relationListItems(
        relations: <ErRelation>[],
        suggestions: <ErRelation>[],
        manyToMany: <ErManyToManyLink>[junctionLink()],
      );
      expect(items.single.displayLabel, 'many-to-many · order_items');
      expect(items.single.searchKey, contains('many-to-many'));
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(items.single.displayLabel), isFalse);
    });
  });

  group('多对多标签宽度估算 / 画布适配（第 56 轮）', () {
    test('宽度估算：短标签下限 64，长标签上限 210，字号 / maxWidth 可调', () {
      // 3 个全角汉字 + 4 个半角字符（空格 / · / 空格 / a）：
      // 3*9.5 + 4*0.6*9.5 + 20 = 71.3。
      expect(estimatedM2MLabelWidth('多对多 · a'), closeTo(71.3, 0.0001));
      // 很短的纯半角标签取下限 64。
      expect(estimatedM2MLabelWidth('a'), 64);
      // 英文标签 16 个半角字符：16*0.6*9.5 + 20。
      expect(
        estimatedM2MLabelWidth('many-to-many · a'),
        closeTo(16 * 9.5 * 0.6 + 20, 0.0001),
      );
      final medium = estimatedM2MLabelWidth('多对多 · order_items');
      expect(medium, closeTo(3 * 9.5 + 14 * 9.5 * 0.6 + 20, 0.0001));
      expect(medium, greaterThan(64));
      expect(medium, lessThan(210));
      final long = estimatedM2MLabelWidth('多对多 · ${'x' * 60}');
      expect(long, 210);
      expect(
        estimatedM2MLabelWidth('多对多 · ${'x' * 60}', maxWidth: 120),
        120,
      );
      expect(
        estimatedM2MLabelWidth('多对多 · order_items', fontSize: 14),
        greaterThan(medium),
      );
    });

    test('同 rune 数下中文标签宽度 > ASCII 标签（全角 1.0 / 半角 0.6）', () {
      const chinese = '多对多标签宽度估算'; // 9 个全角汉字
      const ascii = 'abcdefghi'; // 9 个半角字母
      expect(chinese.runes.length, ascii.runes.length);
      final chineseWidth = estimatedM2MLabelWidth(chinese);
      final asciiWidth = estimatedM2MLabelWidth(ascii);
      expect(chineseWidth, greaterThan(asciiWidth));
      expect(chineseWidth, closeTo(9 * 9.5 + 20, 0.0001));
      expect(asciiWidth, closeTo(9 * 9.5 * 0.6 + 20, 0.0001));
    });

    test('CJK / 假名 / 谚文 / 全角标点 / 扩展表意都按全角计宽', () {
      final narrow = estimatedM2MLabelWidth('a' * 8);
      expect(narrow, closeTo(8 * 9.5 * 0.6 + 20, 0.0001));
      for (final wide in <String>[
        '中' * 8, // CJK 统一表意
        'あ' * 8, // 平假名
        'ア' * 8, // 片假名
        '한' * 8, // 谚文音节
        '、' * 8, // CJK 标点（0x3001）
        'Ａ' * 8, // 全角 ASCII（0xFF21）
        String.fromCharCode(0x20000) * 8, // CJK 扩展 B
      ]) {
        expect(
          estimatedM2MLabelWidth(wide),
          closeTo(8 * 9.5 + 20, 0.0001),
          reason: '全角字符应按 1.0*fontSize 计宽: $wide',
        );
        expect(estimatedM2MLabelWidth(wide), greaterThan(narrow));
      }
    });

    test('长中文 junction 名宽度接近 maxWidth 且垂直净空 > 60', () {
      final label = '多对多 · ${'订单项目' * 10}';
      final width = estimatedM2MLabelWidth(label);
      expect(width, 210);
      final clearance = m2mLabelClearance(
        start: const Offset(300, 100),
        end: const Offset(300, 600),
        labelSize: Size(width, 18),
      );
      expect(clearance, greaterThan(60));
      expect(clearance, closeTo(111, 0.0001));
    });

    test('垂直净空随估算宽度收敛：短标签 < 70，长标签仍 111', () {
      const start = Offset(300, 100);
      const end = Offset(300, 600);
      final shortWidth = estimatedM2MLabelWidth('多对多 · a');
      final longWidth = estimatedM2MLabelWidth('多对多 · ${'x' * 60}');
      expect(shortWidth, closeTo(71.3, 0.0001));
      expect(longWidth, 210);
      final shortClearance = m2mLabelClearance(
        start: start,
        end: end,
        labelSize: Size(shortWidth, 18),
      );
      final longClearance = m2mLabelClearance(
        start: start,
        end: end,
        labelSize: Size(longWidth, 18),
      );
      expect(shortClearance, lessThan(70));
      expect(shortClearance, closeTo(shortWidth / 2 + 6, 0.0001));
      expect(longClearance, closeTo(111, 0.0001));
    });

    test('m2mLabelFitsCanvas：宽 / 窄画布与 margin 边界', () {
      const size = Size(100, 18);
      const canvas = Size(400, 300);
      // 宽画布：放得下。
      expect(
        m2mLabelFitsCanvas(
          anchor: const Offset(150, 150),
          labelSize: size,
          canvasSize: canvas,
        ),
        isTrue,
      );
      // 左 / 右 / 上 / 下越界：放不下。
      expect(
        m2mLabelFitsCanvas(
          anchor: const Offset(40, 150),
          labelSize: size,
          canvasSize: canvas,
        ),
        isFalse,
      );
      expect(
        m2mLabelFitsCanvas(
          anchor: const Offset(370, 150),
          labelSize: size,
          canvasSize: canvas,
        ),
        isFalse,
      );
      expect(
        m2mLabelFitsCanvas(
          anchor: const Offset(150, 8),
          labelSize: size,
          canvasSize: canvas,
        ),
        isFalse,
      );
      expect(
        m2mLabelFitsCanvas(
          anchor: const Offset(150, 296),
          labelSize: size,
          canvasSize: canvas,
        ),
        isFalse,
      );
      // margin 边界：left 只有 2px，默认 margin 4 放不下，margin 0 可以。
      expect(
        m2mLabelFitsCanvas(
          anchor: const Offset(52, 150),
          labelSize: size,
          canvasSize: canvas,
        ),
        isFalse,
      );
      expect(
        m2mLabelFitsCanvas(
          anchor: const Offset(52, 150),
          labelSize: size,
          canvasSize: canvas,
          margin: 0,
        ),
        isTrue,
      );
      // 画布比标签窄：任何位置都放不下。
      expect(
        m2mLabelFitsCanvas(
          anchor: const Offset(50, 150),
          labelSize: const Size(120, 18),
          canvasSize: const Size(100, 300),
        ),
        isFalse,
      );
    });
  });

  group('多对多标签矩形与连线不相交（第 54~56 轮几何回归）', () {
    const labelHeight = 18.0;
    final mediumLabel = '多对多 · order_items';
    final mediumWidth = estimatedM2MLabelWidth(mediumLabel);

    Offset midpointOf(Offset a, Offset b) =>
        Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);

    /// 点到**直线**（不是线段）的垂直距离。
    double distanceToLine(Offset point, Offset start, Offset end) {
      final delta = end - start;
      final length = delta.distance;
      if (length == 0) return (point - start).distance;
      final normal = Offset(-delta.dy / length, delta.dx / length);
      final offset = point - start;
      return (offset.dx * normal.dx + offset.dy * normal.dy).abs();
    }

    /// 轴对齐标签矩形在连线法线方向上的「半径」：|nx|*半宽 + |ny|*半高。
    double rectNormalSupport(Offset start, Offset end, double width) {
      final delta = end - start;
      final length = delta.distance;
      if (length == 0) return width / 2;
      final nx = (-delta.dy / length).abs();
      final ny = (delta.dx / length).abs();
      return nx * (width / 2) + ny * (labelHeight / 2);
    }

    /// 轴对齐矩形与线段是否相交（Liang–Barsky 参数裁剪）。
    bool rectIntersectsSegment(Rect rect, Offset start, Offset end) {
      var t0 = 0.0;
      var t1 = 1.0;
      final dx = end.dx - start.dx;
      final dy = end.dy - start.dy;
      bool clip(double p, double q) {
        if (p == 0) return q >= 0;
        final r = q / p;
        if (p < 0) {
          if (r > t1) return false;
          if (r > t0) t0 = r;
        } else {
          if (r < t0) return false;
          if (r < t1) t1 = r;
        }
        return true;
      }

      return clip(-dx, start.dx - rect.left) &&
          clip(dx, rect.right - start.dx) &&
          clip(-dy, start.dy - rect.top) &&
          clip(dy, rect.bottom - start.dy);
    }

    Rect labelRect(Offset start, Offset end, double width) => Rect.fromCenter(
      center: m2mLabelAnchorFor(
        start: start,
        end: end,
        labelSize: Size(width, labelHeight),
      ),
      width: width,
      height: labelHeight,
    );

    test('水平连线：估算宽度标签矩形与连线段不相交，净空 9px', () {
      const a = Offset(100, 300);
      const b = Offset(600, 300);
      final rect = labelRect(a, b, mediumWidth);
      expect(rectIntersectsSegment(rect, a, b), isFalse);
      expect(rect.contains(midpointOf(a, b)), isFalse);
      // 水平时法线是竖直的，净空仍取 minOffset 18；减去半高 9px = 9px。
      expect(distanceToLine(rect.center, a, b), closeTo(18, 0.0001));
      expect(
        distanceToLine(rect.center, a, b) - labelHeight / 2,
        closeTo(9, 0.0001),
      );
    });

    test('垂直连线：估算宽度决定净空，矩形与连线段不相交且短标签 < 70', () {
      const a = Offset(300, 100);
      const b = Offset(300, 600);
      final shortWidth = estimatedM2MLabelWidth('多对多 · a');
      final longWidth = estimatedM2MLabelWidth('多对多 · ${'x' * 60}');
      expect(shortWidth, closeTo(71.3, 0.0001));
      expect(longWidth, 210);
      for (final width in <double>[shortWidth, mediumWidth, longWidth]) {
        final rect = labelRect(a, b, width);
        final clearance = m2mLabelClearance(
          start: a,
          end: b,
          labelSize: Size(width, labelHeight),
        );
        expect(distanceToLine(rect.center, a, b), closeTo(clearance, 0.0001));
        expect(rectIntersectsSegment(rect, a, b), isFalse);
        expect(
          clearance - rectNormalSupport(a, b, width),
          closeTo(6, 0.0001),
        );
      }
      expect(
        m2mLabelClearance(
          start: a,
          end: b,
          labelSize: Size(shortWidth, labelHeight),
        ),
        lessThan(70),
      );
    });

    test('斜线：估算宽度净空介于 18~111，矩形与连线段不相交', () {
      const a = Offset(100, 100);
      const b = Offset(500, 420);
      final rect = labelRect(a, b, mediumWidth);
      final clearance = m2mLabelClearance(
        start: a,
        end: b,
        labelSize: Size(mediumWidth, labelHeight),
      );
      expect(clearance, greaterThan(18));
      expect(clearance, lessThan(111));
      expect(distanceToLine(rect.center, a, b), closeTo(clearance, 0.0001));
      expect(rectIntersectsSegment(rect, a, b), isFalse);
      expect(
        clearance - rectNormalSupport(a, b, mediumWidth),
        closeTo(6, 0.0001),
      );
    });
  });

  group('自动带入关联表', () {
    test('BFS 沿父/子两个方向扩展，循环不重复', () {
      final expanded = expandRelatedTableNames(
        added: <String>{'a'},
        related: <String, List<String>>{
          'a': <String>['b'],
          'b': <String>['a', 'c'],
          'c': <String>['b', 'd'],
          'd': <String>['c', 'e'],
          'e': <String>['d'],
        },
        excluded: <String>{},
        maxTables: 5,
      );
      expect(expanded, <String>['b', 'c', 'd', 'e']);
    });

    test('上限截断（含已加入）', () {
      final expanded = expandRelatedTableNames(
        added: <String>{'a'},
        related: <String, List<String>>{
          'a': <String>['b'],
          'b': <String>['a', 'c'],
          'c': <String>['b', 'd'],
        },
        excluded: <String>{},
        maxTables: 3,
      );
      expect(expanded, <String>['b', 'c']);
    });

    test('用户移除过的表不再自动加回', () {
      final expanded = expandRelatedTableNames(
        added: <String>{'a'},
        related: <String, List<String>>{
          'a': <String>['b', 'c'],
          'c': <String>['a', 'd'],
        },
        excluded: <String>{'b'},
        maxTables: 5,
      );
      expect(expanded, <String>['c', 'd']);
    });

    test('已加入表之间互相引用时没有候选', () {
      final expanded = expandRelatedTableNames(
        added: <String>{'a', 'b'},
        related: <String, List<String>>{
          'a': <String>['b'],
          'b': <String>['a'],
        },
        excluded: <String>{},
        maxTables: 5,
      );
      expect(expanded, isEmpty);
    });
  });

  group('自动带入的说明文案（P2-8）', () {
    test('达到画布上限：说明已加入几张 / 上限几张 / 其余未加入', () {
      final notice = autoIncludeNotice(
        addedCount: 4,
        hasAnyForeignKey: true,
        reachedLimit: true,
        maxTables: 5,
      );
      expect(notice, isNotNull);
      expect(notice, contains('已自动加入 4 张'));
      expect(notice, contains('已达画布上限 5 张'));
      expect(notice, contains('其余关联表未加入'));
      expect(notice, contains('手动添加或先移除部分表'));
    });

    test('数据库没有外键：说明自动带入只沿已有外键，并指向建议外键', () {
      final notice = autoIncludeNotice(
        addedCount: 0,
        hasAnyForeignKey: false,
        reachedLimit: false,
        maxTables: 10,
      );
      expect(notice, isNotNull);
      expect(notice, contains('还没有外键'));
      expect(notice, contains('只能沿已有外键'));
      expect(notice, contains('建议外键'));
      expect(notice, contains('按列名'));
      expect(notice, contains('手动添加表'));
    });

    test('正常加入 / 有外键但没候选 / 未达上限时不打扰', () {
      expect(
        autoIncludeNotice(
          addedCount: 2,
          hasAnyForeignKey: true,
          reachedLimit: false,
          maxTables: 10,
        ),
        isNull,
      );
      expect(
        autoIncludeNotice(
          addedCount: 0,
          hasAnyForeignKey: true,
          reachedLimit: false,
          maxTables: 10,
        ),
        isNull,
      );
      // 库里有外键、只是没有候选（都已加入 / 被用户移除）→ 不显示。
      expect(
        autoIncludeNotice(
          addedCount: 0,
          hasAnyForeignKey: true,
          reachedLimit: true,
          maxTables: 10,
        ),
        isNull,
      );
    });

    test('英文模式：说明也是英文（没有中文残留）', () {
      I18n.setLang(AppLang.en);
      addTearDown(() => I18n.setLang(AppLang.zh));
      final limit = autoIncludeNotice(
        addedCount: 3,
        hasAnyForeignKey: true,
        reachedLimit: true,
        maxTables: 5,
      )!;
      expect(limit, contains('Added 3 tables automatically'));
      expect(limit, contains('limit of 5 tables'));
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(limit), isFalse);
      final noForeignKey = autoIncludeNotice(
        addedCount: 0,
        hasAnyForeignKey: false,
        reachedLimit: false,
        maxTables: 10,
      )!;
      expect(noForeignKey, contains('no foreign keys yet'));
      expect(noForeignKey, contains('Create suggested FKs'));
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(noForeignKey), isFalse);
    });
  });

  group('建议关系（列名推导）', () {
    ErTable idTable(String name, [List<ErColumn> extra = const <ErColumn>[]]) =>
        table(name, <ErColumn>[
          column('id', type: 'INTEGER', primary: true),
          ...extra,
        ]);

    List<ErTable> batch() => <ErTable>[
      idTable('users', <ErColumn>[column('name', type: 'TEXT')]),
      idTable('categories', <ErColumn>[column('name', type: 'TEXT')]),
      idTable('products', <ErColumn>[
        column('category_id', type: 'INTEGER'),
        column('name', type: 'TEXT'),
      ]),
      idTable('orders', <ErColumn>[column('user_id', type: 'INTEGER')]),
      idTable('order_items', <ErColumn>[
        column('order_id', type: 'INTEGER'),
        column('product_id', type: 'INTEGER'),
      ]),
    ];

    test('列名模式：user_id / userId / userID / category_id，普通列不误判', () {
      expect(suggestedForeignKeyBase('user_id'), 'user');
      expect(suggestedForeignKeyBase('userId'), 'user');
      expect(suggestedForeignKeyBase('userID'), 'user');
      expect(suggestedForeignKeyBase('category_id'), 'category');
      expect(suggestedForeignKeyBase('paid'), isNull);
      expect(suggestedForeignKeyBase('valid'), isNull);
      expect(suggestedForeignKeyBase('name'), isNull);
      expect(suggestedForeignKeyBase('id'), isNull);
    });

    test('导入批次里按列名推出 4 条建议关系（y → ies 复数）', () {
      final suggestions = suggestRelations(
        tables: batch(),
        relationsByTable: <String, List<ErRelation>>{},
      );
      final labels = <String>{
        for (final relation in suggestions) erLabel(relation),
      };
      expect(labels, <String>{
        'products.category_id→categories.id',
        'orders.user_id→users.id',
        'order_items.order_id→orders.id',
        'order_items.product_id→products.id',
      });
      expect(
        suggestions.every(
          (relation) => relation.origin == ErRelationOrigin.suggested,
        ),
        isTrue,
      );
    });

    test('默认最多 20 条建议边；可显式收紧', () {
      final targets = <ErTable>[for (var i = 1; i <= 10; i++) idTable('t$i')];
      final wide = table('wide', <ErColumn>[
        column('id', type: 'INTEGER', primary: true),
        for (var i = 1; i <= 10; i++) column('t${i}_id', type: 'INTEGER'),
      ]);
      final capped = suggestRelations(
        tables: <ErTable>[wide, ...targets],
        relationsByTable: <String, List<ErRelation>>{},
      );
      expect(capped.length, 10, reason: '默认上限 20 条，这里 10 条都应保留');
      final tighter = suggestRelations(
        tables: batch(),
        relationsByTable: <String, List<ErRelation>>{},
        maxResults: 2,
      );
      expect(tighter.length, 2);
    });

    test('已有外键只跳过对应列/目标：同表其它 _id 列继续建议（P2-7）', () {
      final suggestions = suggestRelations(
        tables: batch(),
        relationsByTable: <String, List<ErRelation>>{
          'orders': <ErRelation>[
            const ErRelation(
              localTable: 'orders',
              localColumn: 'user_id',
              refTable: 'users',
              refColumn: 'id',
              name: 'fk_orders_user',
            ),
          ],
          'products': <ErRelation>[
            const ErRelation(
              localTable: 'products',
              localColumn: 'category_id',
              refTable: 'outside',
              refColumn: 'id',
            ),
          ],
        },
      );
      final labels = <String>{
        for (final relation in suggestions) erLabel(relation),
      };
      // 已有外键的本地列不再建议；没有外键的 order_items 两条仍然在。
      expect(labels, <String>{
        'order_items.order_id→orders.id',
        'order_items.product_id→products.id',
      });
      expect(labels, isNot(contains('orders.user_id→users.id')));
      expect(labels, isNot(contains('products.category_id→categories.id')));
    });

    test('应用 1 条建议后，同表剩余建议仍然在（可逐步补齐）', () {
      final tables = batch();
      // order_items 已建好 order_id → orders.id，另一列 product_id 还没建。
      final remaining = suggestRelations(
        tables: tables,
        relationsByTable: <String, List<ErRelation>>{
          'order_items': <ErRelation>[
            const ErRelation(
              localTable: 'order_items',
              localColumn: 'order_id',
              refTable: 'orders',
              refColumn: 'id',
              name: 'fk_items_order',
            ),
          ],
        },
      );
      expect(
        <String>{for (final relation in remaining) erLabel(relation)},
        <String>{
          'products.category_id→categories.id',
          'orders.user_id→users.id',
          'order_items.product_id→products.id',
        },
      );
    });

    test('列模型已标记外键时即使没有 relationsByTable 也不再建议', () {
      final flagged = suggestRelations(
        tables: <ErTable>[
          idTable('users'),
          idTable('orders', <ErColumn>[
            column('user_id', type: 'INTEGER', foreignKey: true),
          ]),
        ],
        relationsByTable: <String, List<ErRelation>>{},
      );
      expect(flagged, isEmpty);
    });

    test('缺目标表 / 复合主键目标也跳过', () {
      // 缺目标表：只有 products.category_id 时没有 categories 表。
      final missing = suggestRelations(
        tables: <ErTable>[
          idTable('products', <ErColumn>[
            column('category_id', type: 'INTEGER'),
          ]),
        ],
        relationsByTable: <String, List<ErRelation>>{},
      );
      expect(missing, isEmpty);
      // 复合主键目标不能作为建议外键目标。
      final composite = suggestRelations(
        tables: <ErTable>[
          idTable('products', <ErColumn>[
            column('category_id', type: 'INTEGER'),
          ]),
          table('categories', <ErColumn>[
            column('a', type: 'INTEGER', primary: true),
            column('b', type: 'INTEGER', primary: true),
          ]),
        ],
        relationsByTable: <String, List<ErRelation>>{},
      );
      expect(composite, isEmpty);
    });
  });

  group('唯一列解析', () {
    test('单列主键 / 单列唯一索引；复合唯一索引不算单列唯一', () {
      final unique = erUniqueColumns(<String, dynamic>{
        'primary_key': <dynamic>['id'],
        'indexes': <dynamic>[
          <String, dynamic>{
            'INDEX_NAME': 'PRIMARY',
            'NON_UNIQUE': 0,
            'COLUMN_NAME': 'id',
          },
          <String, dynamic>{
            'INDEX_NAME': 'uq_email',
            'NON_UNIQUE': 0,
            'COLUMN_NAME': 'email',
          },
          <String, dynamic>{
            'INDEX_NAME': 'idx_name',
            'NON_UNIQUE': 1,
            'COLUMN_NAME': 'name',
          },
          <String, dynamic>{
            'INDEX_NAME': 'uq_pair',
            'NON_UNIQUE': 0,
            'COLUMN_NAME': 'a',
          },
          <String, dynamic>{
            'INDEX_NAME': 'uq_pair',
            'NON_UNIQUE': 0,
            'COLUMN_NAME': 'b',
          },
        ],
      });
      expect(unique, <String>{'id', 'email'});
    });

    test('复合主键本身不产生单列唯一列', () {
      final unique = erUniqueColumns(<String, dynamic>{
        'primary_key': <dynamic>['a', 'b'],
        'indexes': <dynamic>[],
      });
      expect(unique, isEmpty);
    });
  });

  group('分层自动布局', () {
    ErTable node(String name) =>
        table(name, <ErColumn>[column('id', type: 'INTEGER', primary: true)]);
    ErRelation edge(String from, String to) => ErRelation(
      localTable: from,
      localColumn: 'id',
      refTable: to,
      refColumn: 'id',
    );

    test('外键方向从左到右分层（输入顺序无关）', () {
      final tables = <ErTable>[node('c'), node('a'), node('b')];
      final positions = layeredErLayout(tables, <ErRelation>[
        edge('a', 'b'),
        edge('b', 'c'),
      ], viewportWidth: 1200);
      expect(positions['a']!.dx, lessThan(positions['b']!.dx));
      expect(positions['b']!.dx, lessThan(positions['c']!.dx));
    });

    test('有环（中间表双向边）也能收敛', () {
      final positions = layeredErLayout(
        <ErTable>[node('a'), node('b')],
        <ErRelation>[edge('a', 'b'), edge('b', 'a')],
        viewportWidth: 800,
      );
      expect(positions.length, 2);
      expect(positions['a']!.dx, isNot(positions['b']!.dx));
    });

    test('层内重心排序减少交叉：a→d、b→c 时 d 排在 c 上方', () {
      final tables = <ErTable>[node('a'), node('b'), node('c'), node('d')];
      final positions = layeredErLayout(tables, <ErRelation>[
        edge('a', 'd'),
        edge('b', 'c'),
      ], viewportWidth: 1200);
      expect(positions['d']!.dy, lessThan(positions['c']!.dy));
    });

    test('没有关系边时全部第 0 层，竖直排列', () {
      final positions = layeredErLayout(
        <ErTable>[node('a'), node('b')],
        const <ErRelation>[],
        viewportWidth: 900,
      );
      expect(positions['a']!.dx, positions['b']!.dx);
      expect(positions['a']!.dy, lessThan(positions['b']!.dy));
    });

    test('同一源表两条建议边按源列顺序排目标，不交叉', () {
      ErTable tableWith(String name, List<ErColumn> extra) => table(
        name,
        <ErColumn>[column('id', type: 'INTEGER', primary: true), ...extra],
      );
      final users = tableWith('users', const <ErColumn>[]);
      final categories = tableWith('categories', const <ErColumn>[]);
      final products = tableWith('products', <ErColumn>[
        column('category_id', type: 'INTEGER'),
      ]);
      final orders = tableWith('orders', <ErColumn>[
        column('user_id', type: 'INTEGER'),
      ]);
      final orderItems = tableWith('order_items', <ErColumn>[
        column('order_id', type: 'INTEGER'),
        column('product_id', type: 'INTEGER'),
      ]);
      // 与 golden 截图一致的 seed 顺序：users/categories/products/orders/order_items。
      final tables = <ErTable>[users, categories, products, orders, orderItems];
      final suggestions = suggestRelations(
        tables: tables,
        relationsByTable: <String, List<ErRelation>>{},
      );
      expect(suggestions.length, 4);
      final positions = layeredErLayout(
        tables,
        suggestions,
        viewportWidth: 1600,
      );
      // 分层：order_items 最左，orders/products 同层，users/categories 最右。
      expect(positions['order_items']!.dx, lessThan(positions['orders']!.dx));
      expect(positions['orders']!.dx, positions['products']!.dx);
      expect(positions['products']!.dx, lessThan(positions['users']!.dx));
      // 层内：order_id 在 order_items 第 1 行、product_id 第 2 行，
      // 所以 orders 必须排在 products 上面（否则两条建议边交叉成 X）。
      expect(positions['orders']!.dy, lessThan(positions['products']!.dy));
      expect(positions['users']!.dy, lessThan(positions['categories']!.dy));
    });

    test('列数放不下就折行：画布宽度锁在视口内（第 70 轮）', () {
      ErTable node(String name) =>
          table(name, <ErColumn>[column('id', type: 'INTEGER', primary: true)]);
      ErRelation edge(String from, String to) => ErRelation(
        localTable: from,
        localColumn: 'id',
        refTable: to,
        refColumn: 'id',
      );
      final names = <String>['a', 'b', 'c', 'd', 'e', 'f'];
      final tables = <ErTable>[for (final name in names) node(name)];
      final relations = <ErRelation>[
        for (var i = 0; i + 1 < names.length; i++) edge(names[i], names[i + 1]),
      ];
      const metrics = ErNodeMetrics();
      // 视口只放得下 2 列：六层链必须折成 3 行。
      final narrow = layeredErLayout(
        tables,
        relations,
        viewportWidth: (metrics.cardWidth + 52) * 2 + 48,
        metrics: metrics,
      );
      final xs = narrow.values.map((p) => p.dx).toSet().toList()..sort();
      expect(xs.length, 2, reason: '两列排满就换行，不应继续往右长');
      // 第 1 层与第 2 层换行：c 的 y 比 a 大（下一行）。
      expect(narrow['c']!.dy, greaterThan(narrow['a']!.dy));
      // 蛇形：偶数行左→右，奇数行右→左。所以行尾的 b 与下一行行首的 c
      // 落在同一列（上下相邻，不是对角），再往后的 d 才回退一列。
      expect(narrow['b']!.dx, greaterThan(narrow['a']!.dx));
      expect(narrow['c']!.dx, narrow['b']!.dx);
      expect(narrow['c']!.dy, greaterThan(narrow['b']!.dy));
      expect(narrow['d']!.dx, lessThan(narrow['c']!.dx));
      // 视口够宽时完全不折行，方向仍是逐列往右。
      final wide = layeredErLayout(
        tables,
        relations,
        viewportWidth: 4000,
        metrics: metrics,
      );
      expect(wide['c']!.dy, wide['a']!.dy);
      expect(wide['f']!.dx, greaterThan(wide['a']!.dx));
    });

    test('层距 = 卡片宽 + 间距', () {
      final positions = layeredErLayout(
        <ErTable>[node('a'), node('b')],
        <ErRelation>[edge('a', 'b')],
        viewportWidth: 1200,
      );
      expect(
        positions['b']!.dx - positions['a']!.dx,
        const ErNodeMetrics().cardWidth + 52,
      );
    });
  });

  group('外键前置校验', () {
    ErTable tableWith(String name, List<ErColumn> columns) =>
        table(name, columns);
    ErTable localTable() => tableWith('orders', <ErColumn>[
      column('id', type: 'INTEGER', primary: true),
      column('user_id', type: 'INTEGER'),
      column('note', type: 'TEXT'),
    ]);
    ErTable refTable() => tableWith('users', <ErColumn>[
      column('id', type: 'INTEGER', primary: true),
      column('email', type: 'VARCHAR(255)'),
      column('age', type: 'INTEGER'),
    ]);

    test('目标列是主键 → 通过', () {
      expect(
        validateForeignKeyCandidate(
          localTable: localTable(),
          localColumn: 'user_id',
          refTable: refTable(),
          refColumn: 'id',
        ),
        isNull,
      );
    });

    test('目标列非主键但在单列唯一索引里 → 通过', () {
      expect(
        validateForeignKeyCandidate(
          localTable: localTable(),
          localColumn: 'note',
          refTable: refTable(),
          refColumn: 'email',
          refUniqueColumns: <String>{'email'},
        ),
        isNull,
      );
    });

    test('目标列不是主键 / 唯一列 → refColumnNotUnique', () {
      final issue = validateForeignKeyCandidate(
        localTable: localTable(),
        localColumn: 'user_id',
        refTable: refTable(),
        refColumn: 'age',
      );
      expect(issue, isNotNull);
      expect(issue!.kind, ErFkIssueKind.refColumnNotUnique);
      expect(issue.refTable, 'users');
      expect(issue.refColumn, 'age');
    });

    test('本地表没有主键 → localTableNoPrimary', () {
      final issue = validateForeignKeyCandidate(
        localTable: tableWith('logs', <ErColumn>[
          column('message', type: 'TEXT'),
        ]),
        localColumn: 'message',
        refTable: refTable(),
        refColumn: 'id',
      );
      expect(issue!.kind, ErFkIssueKind.localTableNoPrimary);
      expect(issue.localTable, 'logs');
    });

    test('被引用表没有主键 → refTableNoPrimary', () {
      final issue = validateForeignKeyCandidate(
        localTable: localTable(),
        localColumn: 'user_id',
        refTable: tableWith('logs', <ErColumn>[column('code', type: 'TEXT')]),
        refColumn: 'code',
      );
      expect(issue!.kind, ErFkIssueKind.refTableNoPrimary);
      expect(issue.refTable, 'logs');
    });

    test('类型明显不兼容（INTEGER vs VARCHAR）→ typeIncompatible', () {
      final issue = validateForeignKeyCandidate(
        localTable: localTable(),
        localColumn: 'user_id',
        refTable: refTable(),
        refColumn: 'email',
        refUniqueColumns: <String>{'email'},
      );
      expect(issue!.kind, ErFkIssueKind.typeIncompatible);
      expect(issue.localType, 'INTEGER');
      expect(issue.refType, 'VARCHAR(255)');
    });

    test('类型粗粒度兼容：整数/小数/布尔、文本/字符、日期时间互不误拦', () {
      expect(erTypesCompatible('INTEGER', 'BIGINT'), isTrue);
      expect(erTypesCompatible('int unsigned', 'decimal(18,2)'), isTrue);
      expect(erTypesCompatible('TINYINT(1)', 'BOOLEAN'), isTrue);
      expect(erTypesCompatible('VARCHAR(255)', 'TEXT'), isTrue);
      expect(erTypesCompatible('DATE', 'DATETIME'), isTrue);
      expect(erTypesCompatible('', 'TEXT'), isTrue);
      expect(erTypesCompatible('weird_type', 'INTEGER'), isTrue);
      expect(erTypesCompatible('INTEGER', 'TEXT'), isFalse);
      expect(erTypesCompatible('TIMESTAMP', 'VARCHAR(32)'), isFalse);
      expect(erTypesCompatible('BLOB', 'VARCHAR(255)'), isFalse);
      expect(erTypesCompatible('POINT', 'INTEGER'), isTrue);
    });

    test('整数类型精确校验：位宽 / UNSIGNED 不一致一律不兼容（P0-1 前置）', () {
      ErTable local(String type) => tableWith('child', <ErColumn>[
        column('id', type: 'INTEGER', primary: true),
        column('parent_id', type: type),
      ]);
      ErTable parent(String type) => tableWith('parent', <ErColumn>[
        column('id', type: type, primary: true),
      ]);
      ErFkIssue? check(String childType, String parentType) =>
          validateForeignKeyCandidate(
            localTable: local(childType),
            localColumn: 'parent_id',
            refTable: parent(parentType),
            refColumn: 'id',
          );

      for (final pair in <List<String>>[
        <String>['INT', 'BIGINT'],
        <String>['BIGINT', 'INT'],
        <String>['INT', 'INT UNSIGNED'],
        <String>['INT UNSIGNED', 'INT'],
        <String>['TINYINT', 'INT'],
        <String>['BIGINT', 'BIGINT UNSIGNED'],
        <String>['DECIMAL(10,2)', 'DECIMAL(12,2)'],
        <String>['DECIMAL(10,2)', 'DECIMAL(10,4)'],
      ]) {
        final issue = check(pair[0], pair[1]);
        expect(
          issue?.kind,
          ErFkIssueKind.typeIncompatible,
          reason: '${pair[0]} vs ${pair[1]} 应该被前置校验拦住',
        );
      }

      for (final pair in <List<String>>[
        <String>['INT', 'INT'],
        <String>['INT', 'INTEGER'],
        <String>['BIGINT', 'BIGINT'],
        <String>['INT UNSIGNED', 'INT UNSIGNED'],
        <String>['INT UNSIGNED', 'INT(10) UNSIGNED'],
        <String>['TEXT', 'VARCHAR(255)'],
        <String>['DOUBLE', 'DOUBLE PRECISION'],
      ]) {
        expect(
          check(pair[0], pair[1]),
          isNull,
          reason: '${pair[0]} vs ${pair[1]} 应该保持兼容',
        );
      }
    });

    test('erIntegerTypeSignature 归一化：位宽 + 是否有符号', () {
      expect(erIntegerTypeSignature('INT'), '32:s');
      expect(erIntegerTypeSignature('integer'), '32:s');
      expect(erIntegerTypeSignature('INT(11) UNSIGNED'), '32:u');
      expect(erIntegerTypeSignature('TINYINT'), '8:s');
      expect(erIntegerTypeSignature('MEDIUMINT'), '24:s');
      expect(erIntegerTypeSignature('BIGINT UNSIGNED'), '64:u');
      expect(erIntegerTypeSignature('SMALLSERIAL'), '16:s');
      expect(erIntegerTypeSignature('SERIAL'), '32:s');
      expect(erIntegerTypeSignature('BIGSERIAL'), '64:s');
      // 非整数族交给粗粒度 / DECIMAL 精确比较。
      expect(erIntegerTypeSignature('BOOLEAN'), isNull);
      expect(erIntegerTypeSignature('DECIMAL(10,2)'), isNull);
      expect(erIntegerTypeSignature('TEXT'), isNull);
    });

    test('erDecimalTypeSignature：precision / scale；缺参数时放行', () {
      expect(erDecimalTypeSignature('DECIMAL(10,2)'), '10,2');
      expect(erDecimalTypeSignature('numeric(20,6)'), '20,6');
      expect(erDecimalTypeSignature('DECIMAL(10)'), '10,0');
      expect(erDecimalTypeSignature('DECIMAL'), isNull);
      expect(erDecimalTypeSignature('INT'), isNull);
    });

    test('按列名推导的建议关系全部能通过前置校验', () {
      final tables = <ErTable>[
        tableWith('users', <ErColumn>[
          column('id', type: 'INTEGER', primary: true),
        ]),
        tableWith('products', <ErColumn>[
          column('id', type: 'INTEGER', primary: true),
          column('user_id', type: 'INTEGER'),
        ]),
      ];
      final byName = <String, ErTable>{
        for (final item in tables) item.name: item,
      };
      final suggestions = suggestRelations(
        tables: tables,
        relationsByTable: <String, List<ErRelation>>{},
      );
      expect(suggestions.length, 1);
      final suggestion = suggestions.single;
      expect(
        validateForeignKeyCandidate(
          localTable: byName[suggestion.localTable]!,
          localColumn: suggestion.localColumn,
          refTable: byName[suggestion.refTable]!,
          refColumn: suggestion.refColumn,
        ),
        isNull,
      );
    });
  });

  group('危险操作确认 / 批量进度文案（P2-9 / P3）', () {
    test('删除外键确认：点名约束、说明不删数据且可重建', () {
      final message = erDeleteForeignKeyConfirmMessage('fk_orders_user');
      expect(message, contains('fk_orders_user'));
      expect(message, contains('引用约束会解除'));
      expect(message, contains('数据不会删除'));
      expect(message, contains('关系图重建'));
    });

    test('批量建议确认：条数 + 立即写库 + 不能一键全部撤销', () {
      final message = erBatchSuggestionConfirmMessage(3);
      expect(message, contains('3 条建议外键'));
      expect(message, contains('立即写入数据库'));
      expect(message, contains('不能一键全部撤销'));
    });

    test('批量进度文案 X/N', () {
      expect(erSuggestionProgressText(2, 5), '正在建立 2/5 条…');
    });

    test('英文模式：确认 / 进度文案也是英文', () {
      I18n.setLang(AppLang.en);
      addTearDown(() => I18n.setLang(AppLang.zh));
      final deleteMessage = erDeleteForeignKeyConfirmMessage('fk_orders_user');
      expect(deleteMessage, contains('Deleting foreign key fk_orders_user'));
      expect(deleteMessage, contains('data is not deleted'));
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(deleteMessage), isFalse);
      final batch = erBatchSuggestionConfirmMessage(3);
      expect(batch, contains('3 suggested foreign keys'));
      expect(batch, contains('cannot all be undone at once'));
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(batch), isFalse);
      expect(erSuggestionProgressText(2, 5), 'Creating 2/5…');
    });
  });

  // =====================================================================
  // 第 61 轮：新建外键的数据诊断（用户真实场景：学号 20260101 vs id 1）
  // =====================================================================

  FkOrphanReport userScenarioReport() => const FkOrphanReport(
        count: 30,
        childSamples: <String>['20260101', '20260102', '20260103'],
        parentSamples: <String>['1', '2', '3'],
        sameNameColumn: '学号',
        sameNameMatchCount: 30,
        childNonEmptyCount: 30,
      );

  group('外键诊断 SQL（第 61 轮）', () {
    test('按驱动引号：MySQL 反引号、PG/SQLite 双引号，且转义内部引号', () {
      expect(quoteIdentForDriver(ErDriver.mysql, 'order'), '`order`');
      expect(quoteIdentForDriver(ErDriver.postgres, 'order'), '"order"');
      expect(quoteIdentForDriver(ErDriver.sqlite, 'order'), '"order"');
      expect(quoteIdentForDriver(ErDriver.mysql, 'a`b'), '`a``b`');
      expect(quoteIdentForDriver(ErDriver.postgres, 'a"b'), '"a""b"');
    });

    test('孤儿 COUNT：LEFT JOIN + 子列非空 + 引用列 IS NULL', () {
      final sql = fkOrphanCountSql(
        driver: ErDriver.mysql,
        childTable: '年级成绩单',
        childColumn: '学号',
        refTable: '学生名单',
        refColumn: 'id',
      );
      expect(sql, contains('SELECT COUNT(*)'));
      expect(sql, contains('`年级成绩单`'));
      expect(sql, contains('`学生名单`'));
      expect(sql, contains('ON c.`学号` = p.`id`'));
      expect(sql, contains('c.`学号` IS NOT NULL'));
      expect(sql, contains('p.`id` IS NULL'));
    });

    test('样本 SQL 各 LIMIT 5；同名列匹配 / 非空计数', () {
      final child = fkOrphanChildSampleSql(
        driver: ErDriver.postgres,
        childTable: '年级成绩单',
        childColumn: '学号',
      );
      expect(child, contains('"年级成绩单"'));
      expect(child, contains('"学号" IS NOT NULL'));
      expect(child, contains('LIMIT 5'));
      final parent = fkOrphanParentSampleSql(
        driver: ErDriver.sqlite,
        refTable: '学生名单',
        refColumn: 'id',
      );
      expect(parent, contains('"学生名单"'));
      expect(parent, contains('LIMIT 5'));
      final same = fkSameNameMatchCountSql(
        driver: ErDriver.mysql,
        childTable: '年级成绩单',
        childColumn: '学号',
        refTable: '学生名单',
        sameNameColumn: '学号',
      );
      expect(same, contains('JOIN'));
      expect(same, contains('c.`学号` = p.`学号`'));
      expect(same, contains('c.`学号` IS NOT NULL'));
      final nonEmpty = fkChildNonEmptyCountSql(
        driver: ErDriver.mysql,
        childTable: '年级成绩单',
        childColumn: '学号',
      );
      expect(nonEmpty, contains('IS NOT NULL'));
    });
  });

  group('parseFkOrphanReport：解析 Api.query 结果（第 61 轮）', () {
    test('标准 results[].rows 形状 + 同名列数据', () {
      final report = parseFkOrphanReport(
        <String, dynamic>{
          'results': <dynamic>[
            <String, dynamic>{
              'rows': <dynamic>[
                <dynamic>[30],
              ],
            },
          ],
        },
        <String, dynamic>{
          'results': <dynamic>[
            <String, dynamic>{
              'rows': <dynamic>[
                <dynamic>['20260101'],
                <dynamic>['20260102'],
              ],
            },
          ],
        },
        <String, dynamic>{
          'results': <dynamic>[
            <String, dynamic>{
              'rows': <dynamic>[
                <dynamic>[1],
                <dynamic>[2],
              ],
            },
          ],
        },
        sameNameCountJson: <String, dynamic>{
          'rows': <dynamic>[
            <dynamic>[30],
          ],
        },
        childNonEmptyCountJson: <String, dynamic>{
          'results': <dynamic>[
            <String, dynamic>{
              'rows': <dynamic>[
                <dynamic>[30],
              ],
            },
          ],
        },
        sameNameColumn: '学号',
      );
      expect(report.count, 30);
      expect(report.childSamples, <String>['20260101', '20260102']);
      expect(report.parentSamples, <String>['1', '2']);
      expect(report.hasOrphans, isTrue);
      expect(report.sameNameColumn, '学号');
      expect(report.sameNameMatchCount, 30);
      expect(report.childNonEmptyCount, 30);
      expect(report.sameNameMostlyMatches, isTrue);
    });

    test('容忍顶层 rows / Map 行 / 缺失', () {
      final report = parseFkOrphanReport(
        <String, dynamic>{},
        <String, dynamic>{
          'rows': <dynamic>[
            <String, dynamic>{'value': '20260101'},
          ],
        },
        <String, dynamic>{
          'results': <dynamic>[<String, dynamic>{}],
        },
      );
      expect(report.count, 0);
      expect(report.childSamples, <String>['20260101']);
      expect(report.parentSamples, isEmpty);
      expect(report.hasOrphans, isFalse);
      expect(report.sameNameMatchRatio, isNull);
    });
  });

  group('fkOrphanWarningMessage：用户真实场景文案（第 61 轮）', () {
    test('中文：30 行孤儿 + 20260101 vs 1 + 学生名单.学号 + UNIQUE 索引', () {
      I18n.setLang(AppLang.zh);
      final message = fkOrphanWarningMessage(
        userScenarioReport(),
        localTable: '年级成绩单',
        localColumn: '学号',
        refTable: '学生名单',
        refColumn: 'id',
      );
      expect(message, contains('30 行'));
      expect(message, contains('20260101'));
      expect(message, contains('学生名单.学号'));
      expect(message, contains('UNIQUE 索引'));
      expect(message, contains('找不到对应记录'));
      expect(message, contains('建议'));
    });

    test('英文：同样给出示例、同名列与 UNIQUE index 建议', () {
      I18n.setLang(AppLang.en);
      addTearDown(() => I18n.setLang(AppLang.zh));
      final message = fkOrphanWarningMessage(
        userScenarioReport(),
        localTable: '年级成绩单',
        localColumn: '学号',
        refTable: '学生名单',
        refColumn: 'id',
      );
      expect(message, contains('30 row(s)'));
      expect(message, contains('20260101'));
      expect(message, contains('学生名单.学号'));
      expect(message, contains('UNIQUE index'));
      expect(message, contains('no matching record'));
    });

    test('同名列只有部分匹配时给出比例提示', () {
      I18n.setLang(AppLang.zh);
      final message = fkOrphanWarningMessage(
        const FkOrphanReport(
          count: 20,
          childSamples: <String>['A'],
          parentSamples: <String>['B'],
          sameNameColumn: '学号',
          sameNameMatchCount: 10,
          childNonEmptyCount: 30,
        ),
        localTable: '年级成绩单',
        localColumn: '学号',
        refTable: '学生名单',
        refColumn: 'id',
      );
      expect(message, contains('10/30'));
      expect(message, contains('UNIQUE 索引'));
    });

    test('没有同名列时只给孤儿数据建议', () {
      I18n.setLang(AppLang.zh);
      final message = fkOrphanWarningMessage(
        const FkOrphanReport(count: 5, childSamples: <String>['x']),
        localTable: 'child',
        localColumn: 'parent_id',
        refTable: 'parent',
        refColumn: 'id',
      );
      expect(message, contains('5 行'));
      expect(message, isNot(contains('UNIQUE')));
      expect(message, contains('建议'));
    });
  });

  // =====================================================================
  // 第 64 轮：同名列部分匹配也能一键改选（判定 + 诚实文案）
  // =====================================================================

  group('同名列可一键改选判定（第 64 轮）', () {
    FkOrphanReport reportWith(int? matchCount, int? total) => FkOrphanReport(
      count: 3,
      childSamples: const <String>['A'],
      parentSamples: const <String>['B'],
      sameNameColumn: '学号',
      sameNameMatchCount: matchCount,
      childNonEmptyCount: total,
    );

    test('ratio 0.99（99/100）→ 基本完全匹配，也是可一键改选', () {
      final report = reportWith(99, 100);
      expect(report.sameNameMatchRatio, closeTo(0.99, 1e-12));
      expect(report.sameNameMostlyMatches, isTrue);
      expect(report.sameNameHasMatches, isTrue);
      expect(report.sameNamePartiallyMatches, isFalse);
      expect(report.sameNameRemainingOrphans, 1);
    });

    test('ratio 0.9（27/30）→ 部分匹配，仍可一键改选', () {
      final report = reportWith(27, 30);
      expect(report.sameNameMostlyMatches, isFalse);
      expect(report.sameNameHasMatches, isTrue);
      expect(report.sameNamePartiallyMatches, isTrue);
      expect(report.sameNameRemainingOrphans, 3);
    });

    test('ratio 0（0/30）→ 没有匹配数据，不给一键改选', () {
      final report = reportWith(0, 30);
      expect(report.sameNameHasMatches, isFalse);
      expect(report.sameNamePartiallyMatches, isFalse);
      expect(report.sameNameRemainingOrphans, 30);
    });

    test('匹配数为 null（没查到）→ 保持第 63 轮行为：不给一键改选', () {
      final report = reportWith(null, 30);
      expect(report.sameNameMatchRatio, isNull);
      expect(report.sameNameHasMatches, isFalse);
      expect(report.sameNamePartiallyMatches, isFalse);
      expect(report.sameNameRemainingOrphans, isNull);
    });
  });

  group('同名列部分匹配文案（第 64 轮）', () {
    const partialReport = FkOrphanReport(
      count: 30,
      childSamples: <String>['20260101'],
      parentSamples: <String>['1'],
      sameNameColumn: '学号',
      sameNameMatchCount: 27,
      childNonEmptyCount: 30,
    );

    test('孤儿警告：说明只有 27/30 行匹配、仍有 3 行孤儿，不声称基本匹配', () {
      I18n.setLang(AppLang.zh);
      final message = fkOrphanWarningMessage(
        partialReport,
        localTable: '年级成绩单',
        localColumn: '学号',
        refTable: '学生名单',
        refColumn: 'id',
      );
      expect(message, contains('27/30'));
      expect(message, contains('3 行孤儿'));
      expect(message, contains('创建外键仍可能失败'));
      expect(message, contains('补齐数据'));
      expect(message, contains('UNIQUE 索引'));
      expect(message, isNot(contains('基本完全匹配')));
    });

    test('孤儿警告英文：同样说明匹配行数与剩余孤儿', () {
      I18n.setLang(AppLang.en);
      addTearDown(() => I18n.setLang(AppLang.zh));
      final message = fkOrphanWarningMessage(
        partialReport,
        localTable: 'grade',
        localColumn: '学号',
        refTable: 'students',
        refColumn: 'id',
      );
      expect(message, contains('27/30'));
      expect(message, contains('3 orphan row(s)'));
      expect(message, contains('fill in the missing data'));
      expect(message, isNot(contains('almost perfectly')));
    });

    test('基本完全匹配（99/100）保留第 63 轮文案', () {
      I18n.setLang(AppLang.zh);
      final message = fkOrphanWarningMessage(
        const FkOrphanReport(
          count: 1,
          sameNameColumn: '学号',
          sameNameMatchCount: 99,
          childNonEmptyCount: 100,
        ),
        localTable: '年级成绩单',
        localColumn: '学号',
        refTable: '学生名单',
        refColumn: 'id',
      );
      expect(message, contains('基本完全匹配'));
      expect(message, isNot(contains('行孤儿')));
    });

    test('1452 错误提示与警告一致：部分匹配给出 27/30、不暗示基本匹配', () {
      I18n.setLang(AppLang.zh);
      final message = fkConstraintFailureMessage(
        'ERROR 1452 (23000): Cannot add or update a child row: '
            'a foreign key constraint fails',
        localTable: '年级成绩单',
        refTable: '学生名单',
        localColumn: '学号',
        refColumn: 'id',
        report: partialReport,
      );
      expect(message, contains('27/30'));
      expect(message, contains('UNIQUE'));
      expect(message, contains('补齐数据'));
      expect(message, isNot(contains('基本完全匹配')));
    });
  });

  group('fkConstraintFailureMessage：错误映射（第 61 轮）', () {
    const mysql1452 =
        'Cannot add or update a child row: a foreign key constraint fails '
        '(clerk_cn_test.#sql-1004_4e, CONSTRAINT fk_grade_student '
        'FOREIGN KEY (学号) REFERENCES 学生名单 (id) ON DELETE CASCADE) '
        '(错误码 23000)';

    test('1452 / 23000 → 孤儿数据说明，带同名列 + UNIQUE 索引提示', () {
      I18n.setLang(AppLang.zh);
      final message = fkConstraintFailureMessage(
        StateError(mysql1452),
        localTable: '年级成绩单',
        refTable: '学生名单',
        localColumn: '学号',
        refColumn: 'id',
        report: userScenarioReport(),
      );
      expect(message, contains('找不到对应记录'));
      expect(message, contains('年级成绩单'));
      expect(message, contains('学生名单.学号'));
      expect(message, contains('UNIQUE 索引'));
      expect(message, isNot(contains('Cannot add or update a child row')));
    });

    test('1452 英文 + 无预检报告时仍给可行动建议', () {
      I18n.setLang(AppLang.en);
      addTearDown(() => I18n.setLang(AppLang.zh));
      final message = fkConstraintFailureMessage(
        mysql1452,
        localTable: '年级成绩单',
        refTable: '学生名单',
        localColumn: '学号',
        refColumn: 'id',
      );
      expect(message, contains('no matching record'));
      expect(message, contains('MySQL 1452'));
      expect(message, isNot(contains('Cannot add or update a child row')));
    });

    test('1826 约束名重复 / 1215 无法添加外键', () {
      I18n.setLang(AppLang.zh);
      expect(
        fkConstraintFailureMessage(
          'ERROR 1826 (HY000): Duplicate foreign key constraint name fk_x',
        ),
        contains('约束名重复'),
      );
      expect(
        fkConstraintFailureMessage('Cannot add foreign key constraint'),
        contains('1215'),
      );
    });

    test('其它错误保留原始文本', () {
      I18n.setLang(AppLang.zh);
      final message = fkConstraintFailureMessage('driver says boom');
      expect(message, contains('创建外键失败'));
      expect(message, contains('driver says boom'));
    });
  });

  group('FkPrecheckWarningException', () {
    test('toString 就是可读消息（弹窗直接显示）', () {
      const exception = FkPrecheckWarningException('有 30 行孤儿');
      expect(exception.toString(), '有 30 行孤儿');
      expect(exception.message, '有 30 行孤儿');
    });
  });

  // =====================================================================
  // 第 62 轮：引用列唯一性 / 一键建 UNIQUE 索引
  // =====================================================================

  group('引用列唯一性 SQL 与解析（第 62 轮）', () {
    test('COUNT(col) / COUNT(DISTINCT col) 按驱动引号', () {
      final mysql = erColumnUniquenessSql(
        driver: ErDriver.mysql,
        table: '学生名单',
        column: '学号',
      );
      expect(mysql, contains('COUNT(`学号`)'));
      expect(mysql, contains('COUNT(DISTINCT `学号`)'));
      expect(mysql, contains('FROM `学生名单`'));
      // 第 62 轮 GUI 抽测回归：MySQL 里 DISTINCT 是保留字，不能做裸别名。
      expect(mysql, contains('AS total_count'));
      expect(mysql, contains('AS distinct_count'));
      // 不能用 `AS distinct` / `AS total` 这种保留字裸别名（词边界匹配，
      // 避免把 total_count 误判成 total）。
      expect(mysql, isNot(matches(RegExp(r'AS distinct\b'))));
      expect(mysql, isNot(matches(RegExp(r'AS total\b'))));
      final pg = erDuplicateValuesSql(
        driver: ErDriver.postgres,
        table: '学生名单',
        column: '学号',
        limit: 2,
      );
      expect(pg, contains('"学生名单"'));
      expect(pg, contains('HAVING COUNT(*) > 1'));
      expect(pg, contains('LIMIT 2'));
    });

    test('解析 results/rows 与 Map 行；空结果降级', () {
      final uniqueness = parseErColumnUniqueness(<String, dynamic>{
        'results': <dynamic>[
          <String, dynamic>{
            'rows': <dynamic>[
              <dynamic>[30, 30],
            ],
          },
        ],
      });
      expect(uniqueness.total, 30);
      expect(uniqueness.distinct, 30);
      expect(uniqueness.isUnique, isTrue);
      expect(uniqueness.hasDuplicates, isFalse);

      final duplicates = parseErDuplicateValues(<String, dynamic>{
        'results': <dynamic>[
          <String, dynamic>{
            'rows': <dynamic>[
              <dynamic>['20260101', 30],
              <dynamic>['20260102', 2],
            ],
          },
        ],
      });
      expect(duplicates, hasLength(2));
      expect(duplicates.first.value, '20260101');
      expect(duplicates.first.count, 30);

      final empty = parseErColumnUniqueness(<String, dynamic>{});
      expect(empty.total, 0);
      expect(empty.distinct, 0);
      expect(empty.isUnique, isTrue, reason: '空列也能建唯一索引');
    });

    test('查询失败/空结果：必须返回 null，不能当成 0 行 0 个值', () {
      // MySQL 语法错误会作为 results[].error 返回而不抛异常（第 62 轮真实 bug）。
      expect(
        erQueryPayloadFailed(<String, dynamic>{
          'results': <dynamic>[
            <String, dynamic>{'error': 'ERROR 1064 (42000): syntax error'},
          ],
        }),
        isTrue,
      );
      expect(
        parseErColumnUniquenessResult(<String, dynamic>{
          'results': <dynamic>[
            <String, dynamic>{'error': 'ERROR 1064 (42000): syntax error'},
          ],
        }),
        isNull,
      );
      // failed>0 / results 为空 / 缺 rows 同样视为不可用。
      expect(erQueryPayloadFailed(<String, dynamic>{'failed': 1}), isTrue);
      expect(
        erQueryPayloadFailed(<String, dynamic>{'results': <dynamic>[]}),
        isTrue,
      );
      expect(
        parseErColumnUniquenessResult(<String, dynamic>{
          'results': <dynamic>[
            <String, dynamic>{'rows': <dynamic>[]},
          ],
        }),
        isNull,
      );
      // 正常结果：返回对象。
      final ok = parseErColumnUniquenessResult(<String, dynamic>{
        'results': <dynamic>[
          <String, dynamic>{
            'rows': <dynamic>[
              <dynamic>[30, 30],
            ],
          },
        ],
      });
      expect(ok, isNotNull);
      expect(ok!.total, 30);
      expect(ok.isUnique, isTrue);
      // 正常但 0 行的空表：合法（0/0 全唯一），不能与查询失败混淆。
      expect(
        erQueryPayloadFailed(<String, dynamic>{
          'results': <dynamic>[
            <String, dynamic>{
              'rows': <dynamic>[
                <dynamic>[0, 0],
              ],
            },
          ],
        }),
        isFalse,
      );
    });

    test('唯一性判定与重复行数', () {
      const unique = ErColumnUniqueness(total: 30, distinct: 30);
      expect(unique.isUnique, isTrue);
      expect(unique.duplicateRowCount, 0);
      const dup = ErColumnUniqueness(total: 30, distinct: 1);
      expect(dup.isUnique, isFalse);
      expect(dup.hasDuplicates, isTrue);
      expect(dup.duplicateRowCount, 29);
    });
  });

  group('唯一索引名生成（第 62 轮）', () {
    test('uk_<列>；冲突追加 _2/_3；大小写不敏感去重', () {
      expect(uniqueIndexNameFor('code', const <String>{}), 'uk_code');
      expect(uniqueIndexNameFor('code', <String>{'uk_code'}), 'uk_code_2');
      expect(
        uniqueIndexNameFor('code', <String>{'UK_CODE', 'uk_code_2'}),
        'uk_code_3',
      );
      expect(uniqueIndexNameFor('  学号 ', const <String>{}), 'uk_学号');
    });

    test('非法字符替换成下划线；名字不超过 60 字符', () {
      expect(uniqueIndexNameFor('a b-c', const <String>{}), 'uk_a_b_c');
      final long = uniqueIndexNameFor('x' * 80, const <String>{});
      expect(long.length, lessThanOrEqualTo(60));
      expect(long, startsWith('uk_'));
      final longConflict = uniqueIndexNameFor('x' * 80, <String>{long});
      expect(longConflict.length, lessThanOrEqualTo(60));
      expect(longConflict, endsWith('_2'));
    });

    test('已有索引名从 structure 行里取（INDEX_NAME / name）', () {
      expect(
        erIndexNamesOf(<dynamic>[
          <String, dynamic>{'INDEX_NAME': 'PRIMARY'},
          <String, dynamic>{'name': 'idx_code'},
          <String, dynamic>{},
        ]),
        <String>['PRIMARY', 'idx_code'],
      );
      expect(erIndexNamesOf(null), isEmpty);
    });
  });

  group('唯一列提示文案（第 62 轮）', () {
    test('中文：全唯一 → 提供建 UNIQUE 索引建议，并解释 web 差异', () {
      I18n.setLang(AppLang.zh);
      final message = erUniqueIndexSuggestionMessage(
        const ErColumnUniqueness(total: 30, distinct: 30),
        refTable: '学生名单',
        refColumn: '学号',
      );
      expect(message, contains('学生名单.学号'));
      expect(message, contains('30 个非空值'));
      expect(message, contains('全部唯一'));
      expect(message, contains('UNIQUE'));
      expect(message, contains('MySQL 8.4'));
      expect(message, contains('MariaDB'));
    });

    test('中文：有重复 → 数量 / 示例 / 不自动建索引', () {
      I18n.setLang(AppLang.zh);
      final message = erRefColumnDuplicateMessage(
        const ErColumnUniqueness(
          total: 30,
          distinct: 1,
          duplicates: <ErDuplicateValue>[ErDuplicateValue('20260101', 30)],
        ),
        refTable: '学生名单',
        refColumn: '学号',
      );
      expect(message, contains('30 行非空'));
      expect(message, contains('1 个不同值'));
      expect(message, contains('重复 29 行'));
      expect(message, contains('20260101'));
      expect(message, contains('出现 30 次'));
      expect(message, contains('不会自动创建索引'));
    });

    test('英文：唯一 / 重复两套文案', () {
      I18n.setLang(AppLang.en);
      addTearDown(() => I18n.setLang(AppLang.zh));
      final unique = erUniqueIndexSuggestionMessage(
        const ErColumnUniqueness(total: 30, distinct: 30),
        refTable: '学生名单',
        refColumn: '学号',
      );
      expect(unique, contains('30 non-null values'));
      expect(unique, contains('UNIQUE'));
      expect(unique, contains('MySQL 8.4'));
      final dup = erRefColumnDuplicateMessage(
        const ErColumnUniqueness(
          total: 30,
          distinct: 1,
          duplicates: <ErDuplicateValue>[ErDuplicateValue('X', 30)],
        ),
        refTable: 'p',
        refColumn: 'c',
      );
      expect(dup, contains('30 non-null rows'));
      expect(dup, contains('1 distinct values'));
      expect(dup, contains('appears 30 times'));
      expect(dup, contains('no index is created automatically'));
    });
  });
}

/// 测试辅助：关系的人读标签（模型没有 label 方法，用两端拼）。
String erLabel(ErRelation relation) =>
    '${relation.localTable}.${relation.localColumn}→${relation.refTable}.${relation.refColumn}';
