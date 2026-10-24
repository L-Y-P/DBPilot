// 纯逻辑单测：E-R 关系设计器的模型 / 外键 payload / 中间表 / 命中检测 / 布局。
//
// 这里不需要 dylib，也不需要数据库：er_model.dart 不 import Flutter widget 层，
// 只依赖 dart:ui 的几何类型。

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
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
      expect(positions['b']!.dx - positions['a']!.dx, 230 + 48);
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
      expect(point.dx, 400 + 230 - 1 - 8);
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
      expect(curve!.start.dx, 230 - 1 - 8);
      expect(curve.end.dx, 230 - 1 - 8);
      expect(curve.control1.dx, greaterThan(230));
    });
  });
}
