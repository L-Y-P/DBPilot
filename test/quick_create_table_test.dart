//! 快速建表向导（第 50 轮）测试。
//!
//! 纯逻辑部分不需要 FFI：类型映射、标识符清洗、去重、兜底推断、createTable /
//! importExecuteStart 载荷、校验。
//!
//! FFI 部分启动真实 Rust 核心 + 临时 SQLite 库，用向导 UI 走完整流程：
//! 选择文件 → 工作表与字段 → 创建并导入 → 建立关联。多工作表用例依赖
//! rust-excel 的 inspect.sheets / schema 契约，dylib 未就绪时按 skip 报告。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';
import 'package:rust_myadmin_desktop/src/i18n_literals.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/quick_create_table_wizard.dart';
import 'package:rust_myadmin_desktop/src/views/relation_designer.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 断言当前 widget 树里渲染出的文字没有中文（英文模式回归）。
void expectNoHanTexts(WidgetTester tester, String where) {
  final han = RegExp(r'[\u4e00-\u9fff]');
  final leaks = <String>[];
  for (final widget in tester.allWidgets) {
    String? text;
    if (widget is RichText) {
      text = widget.text.toPlainText();
    } else if (widget is EditableText) {
      text = widget.controller.text;
    } else if (widget is Tooltip) {
      text = widget.message;
    }
    if (text == null || text.trim().isEmpty) continue;
    if (han.hasMatch(text)) leaks.add(text);
  }
  expect(leaks, isEmpty, reason: '英文模式「$where」仍有中文文案：${leaks.join(' | ')}');
}

QuickTablePlan planFor({
  String name = 'demo',
  String sheet = '',
  bool header = true,
  List<QuickColumn>? columns,
}) => QuickTablePlan(
  name: name,
  sheet: sheet,
  header: header,
  columns:
      columns ??
      <QuickColumn>[
        QuickColumn(
          name: 'id',
          sourceLabel: 'id',
          sourceIndex: 0,
          inferred: 'integer',
          sqlType: 'INTEGER',
          nullable: false,
          primary: true,
        ),
        QuickColumn(
          name: 'name',
          sourceLabel: 'name',
          sourceIndex: 1,
          inferred: 'text',
          sqlType: 'TEXT',
        ),
      ],
);

void main() {
  // =====================================================================
  // 纯逻辑
  // =====================================================================

  group('类型映射 §4.3', () {
    test('MySQL', () {
      expect(sqlTypeFor('integer', 'mysql'), 'INT');
      expect(sqlTypeFor('bigint', 'mysql'), 'BIGINT');
      expect(sqlTypeFor('decimal', 'mysql'), 'DECIMAL(18,2)');
      expect(sqlTypeFor('float', 'mysql'), 'DOUBLE');
      expect(sqlTypeFor('boolean', 'mysql'), 'TINYINT(1)');
      expect(sqlTypeFor('date', 'mysql'), 'DATE');
      expect(sqlTypeFor('datetime', 'mysql'), 'DATETIME');
      expect(sqlTypeFor('time', 'mysql'), 'TIME');
      expect(sqlTypeFor('text', 'mysql'), 'TEXT');
      expect(sqlTypeFor('text', 'mysql', maxLength: 50), 'VARCHAR(50)');
      expect(sqlTypeFor('text', 'mysql', maxLength: 200), 'VARCHAR(200)');
      // 第 52 轮：后端对短文本给 255，长度上限放宽到 4000 内都用 VARCHAR。
      expect(sqlTypeFor('text', 'mysql', maxLength: 255), 'VARCHAR(255)');
      expect(sqlTypeFor('text', 'mysql', maxLength: 500), 'VARCHAR(500)');
      expect(sqlTypeFor('text', 'mysql', maxLength: 4000), 'VARCHAR(4000)');
      expect(sqlTypeFor('text', 'mysql', maxLength: 5000), 'TEXT');
    });

    test('PostgreSQL', () {
      expect(sqlTypeFor('integer', 'postgres'), 'INTEGER');
      expect(sqlTypeFor('bigint', 'postgres'), 'BIGINT');
      expect(sqlTypeFor('decimal', 'postgres'), 'NUMERIC(18,2)');
      expect(sqlTypeFor('float', 'postgres'), 'DOUBLE PRECISION');
      expect(sqlTypeFor('boolean', 'postgres'), 'BOOLEAN');
      expect(sqlTypeFor('datetime', 'postgres'), 'TIMESTAMP');
      expect(sqlTypeFor('text', 'postgres', maxLength: 120), 'VARCHAR(120)');
      expect(sqlTypeFor('text', 'postgres', maxLength: 300), 'VARCHAR(300)');
      expect(sqlTypeFor('text', 'postgres', maxLength: 5000), 'TEXT');
    });

    test('SQLite', () {
      expect(sqlTypeFor('integer', 'sqlite'), 'INTEGER');
      expect(sqlTypeFor('bigint', 'sqlite'), 'BIGINT');
      expect(sqlTypeFor('decimal', 'sqlite'), 'NUMERIC');
      expect(sqlTypeFor('float', 'sqlite'), 'REAL');
      expect(sqlTypeFor('boolean', 'sqlite'), 'INTEGER');
      expect(sqlTypeFor('date', 'sqlite'), 'TEXT');
      expect(sqlTypeFor('datetime', 'sqlite'), 'TEXT');
      expect(sqlTypeFor('time', 'sqlite'), 'TEXT');
      // SQLite 忽略长度，文本列固定 TEXT。
      expect(sqlTypeFor('text', 'sqlite', maxLength: 40), 'TEXT');
    });

    test('主键类型与整数判断', () {
      expect(pkColumnTypeFor('mysql'), 'BIGINT');
      expect(pkColumnTypeFor('postgres'), 'BIGINT');
      expect(pkColumnTypeFor('sqlite'), 'INTEGER');
      expect(looksIntegerType('INT'), isTrue);
      expect(looksIntegerType('INTEGER'), isTrue);
      expect(looksIntegerType('BIGINT'), isTrue);
      expect(looksIntegerType('TINYINT(1)'), isFalse);
      expect(looksIntegerType('NUMERIC'), isFalse);
    });

    test('常用类型下拉按驱动去重且包含主键类型', () {
      for (final driver in <String>['mysql', 'postgres', 'sqlite']) {
        final choices = quickTypeChoices(driver);
        expect(
          choices.toSet().length,
          choices.length,
          reason: 'must be unique',
        );
        expect(choices, contains(pkColumnTypeFor(driver)));
        expect(choices, contains(sqlTypeFor('text', driver)));
      }
    });
  });

  group('标识符清洗与去重', () {
    test('空白与引号替换为下划线并压缩', () {
      expect(sanitizeIdentifier('My Table'), 'My_Table');
      expect(sanitizeIdentifier('  a   b  '), 'a_b');
      expect(sanitizeIdentifier('"quoted"'), 'quoted');
      expect(sanitizeIdentifier('a-b.c'), 'a_b_c');
      expect(sanitizeIdentifier('order total'), 'order_total');
    });

    test('保留中文', () {
      expect(sanitizeIdentifier('订单 表'), '订单_表');
      expect(sanitizeIdentifier('用户'), '用户');
    });

    test('空名回退、数字开头补前缀', () {
      expect(sanitizeIdentifier(''), 'table');
      expect(sanitizeIdentifier('___', fallback: 'sheet'), 'sheet');
      expect(sanitizeIdentifier('123abc'), 't_123abc');
    });

    test('去重后缀', () {
      expect(uniqueName('users', <String>{}), 'users');
      expect(uniqueName('users', <String>{'users'}), 'users_2');
      expect(uniqueName('users', <String>{'users', 'users_2'}), 'users_3');
    });

    test('默认表名：文件名 / 工作表名', () {
      expect(fileStemOf('/tmp/销售 数据.csv'), '销售 数据');
      expect(defaultTableNameFor('/tmp/people.csv'), 'people');
      expect(
        defaultTableNameFor(
          '/tmp/book.xlsx',
          sheet: 'Sheet 1',
          multiSheet: true,
        ),
        'Sheet_1',
      );
      // 单工作表 Excel 仍按文件名命名。
      expect(
        defaultTableNameFor(
          '/tmp/book.xlsx',
          sheet: 'Sheet1',
          multiSheet: false,
        ),
        'book',
      );
    });
  });

  group('Dart 兜底类型推断', () {
    test('整数 / bigint / 小数', () {
      expect(inferTypeFromValues(<Object?>[1, 2, 3]), 'integer');
      expect(inferTypeFromValues(<Object?>[1, 3000000000]), 'bigint');
      expect(inferTypeFromValues(<Object?>[1.5, 2]), 'decimal');
      expect(inferTypeFromValues(<Object?>['1', '2', '3']), 'integer');
      expect(inferTypeFromValues(<Object?>['9.5', '8', '7.25']), 'decimal');
    });

    test('布尔 / 日期 / 时间 / 文本', () {
      expect(inferTypeFromValues(<Object?>[true, false, '否']), 'boolean');
      expect(
        inferTypeFromValues(<Object?>['2024-01-02', '2024-03-04']),
        'date',
      );
      expect(
        inferTypeFromValues(<Object?>[
          '2024-01-02 10:11:12',
          '2024-03-04 00:00:00',
        ]),
        'datetime',
      );
      expect(inferTypeFromValues(<Object?>['10:11', '12:30']), 'time');
      expect(inferTypeFromValues(<Object?>['Ada', 'Bob']), 'text');
    });

    test('空值不否定类型', () {
      expect(inferTypeFromValues(<Object?>[null, '', 1, 2, null]), 'integer');
      expect(inferTypeFromValues(<Object?>[]), 'text');
    });
  });

  group('importPreview 结果转列', () {
    test('优先使用 schema', () {
      final preview = <String, dynamic>{
        'header': <dynamic>['id', '姓名', 'score', 'created_at'],
        'schema': <String, dynamic>{
          'sample_count': 3,
          'columns': <dynamic>[
            <String, dynamic>{
              'name': 'id',
              'source': 0,
              'type': 'integer',
              'nullable': false,
              'primary_candidate': true,
            },
            <String, dynamic>{
              'name': '姓名',
              'source': 1,
              'type': 'text',
              'nullable': true,
              'max_length': 8,
              'samples': <dynamic>['张三', '李四'],
            },
            <String, dynamic>{
              'name': 'score',
              'source': 2,
              'type': 'decimal',
              'nullable': true,
            },
            <String, dynamic>{
              'name': 'created_at',
              'source': 3,
              'type': 'datetime',
              'nullable': true,
            },
          ],
        },
      };
      final columns = columnsFromPreview(preview, driver: 'mysql');
      expect(columns.map((c) => c.name).toList(), <String>[
        'id',
        '姓名',
        'score',
        'created_at',
      ]);
      // 第 53 轮：整数主键在计划层就统一成驱动的主键类型（MySQL 为 BIGINT），
      // 字段页显示与建表 DDL 不再出现「显示整数、实际 BIGINT」的割裂。
      expect(columns[0].sqlType, 'BIGINT');
      expect(columns[0].primary, isTrue);
      expect(columns[0].nullable, isFalse);
      expect(columns[0].sourceLabel, 'id');
      expect(columns[1].sqlType, 'VARCHAR(8)');
      expect(columns[1].sample, contains('张三'));
      expect(columns[2].sqlType, 'DECIMAL(18,2)');
      expect(columns[3].sqlType, 'DATETIME');
      expect(columns[3].sourceLabel, 'created_at');
    });

    test('多个 primary_candidate 只保留第一个', () {
      final preview = <String, dynamic>{
        'schema': <String, dynamic>{
          'columns': <dynamic>[
            <String, dynamic>{
              'name': 'a',
              'source': 0,
              'primary_candidate': true,
            },
            <String, dynamic>{
              'name': 'b',
              'source': 1,
              'primary_candidate': true,
            },
          ],
        },
      };
      final columns = columnsFromPreview(preview, driver: 'sqlite');
      expect(columns.where((c) => c.primary).length, 1);
      expect(columns.first.primary, isTrue);
    });

    test('schema 缺失时从记录兜底', () {
      final preview = <String, dynamic>{
        'header': <dynamic>['id', 'name', 'flag', 'when'],
        'records': <dynamic>[
          <String, dynamic>{
            'header': true,
            'values': <dynamic>['id', 'name', 'flag', 'when'],
          },
          <String, dynamic>{
            'kind': 'array',
            'field_count': 4,
            'values': <dynamic>[1, 'Ada', true, '2024-01-02'],
          },
          <String, dynamic>{
            'kind': 'array',
            'field_count': 4,
            'values': <dynamic>[2, 'Bob', false, '2024-03-04'],
          },
        ],
      };
      final columns = columnsFromPreview(preview, driver: 'sqlite');
      expect(columns.map((c) => c.name).toList(), <String>[
        'id',
        'name',
        'flag',
        'when',
      ]);
      expect(columns[0].inferred, 'integer');
      expect(columns[1].inferred, 'text');
      expect(columns[2].inferred, 'boolean');
      expect(columns[3].inferred, 'date');
      expect(columns[0].primary, isTrue);
      expect(columns[0].sourceLabel, 'id');
    });
  });

  group('请求载荷', () {
    test('read 参数透传规则并覆盖 sheet / skip_rows', () {
      final read = readParamsFor(
        <String, dynamic>{
          'mode': 'wrapped',
          'record_sep': '</Row>',
          'quote': '',
        },
        sheet: 'Sheet2',
        skipRows: 3,
      );
      expect(read['mode'], 'wrapped');
      expect(read['record_sep'], '</Row>');
      expect(read['sheet'], 'Sheet2');
      expect(read['skip_rows'], 3);
      // 非 Excel 文件不发送 sheet 键。
      final plain = readParamsFor(<String, dynamic>{
        'mode': 'line',
      }, skipRows: 0);
      expect(plain.containsKey('sheet'), isFalse);
      expect(plain['skip_rows'], 0);
    });

    test('fields 参数覆盖表头开关', () {
      final fields = fieldParamsFor(<String, dynamic>{
        'mode': 'excel',
      }, header: true);
      expect(fields['mode'], 'excel');
      expect(fields['header'], isTrue);
    });

    test('映射来源：有表头按列名，无表头按位置', () {
      final withHeader = planFor();
      final keyed = mappingParamsFor(withHeader);
      final keyedColumns = (keyed['columns'] as List).cast<Map>();
      expect(keyedColumns[0], <String, dynamic>{
        'column': 'id',
        'source': 'id',
      });
      expect(keyedColumns[1], <String, dynamic>{
        'column': 'name',
        'source': 'name',
      });
      expect(keyed['ignore_unknown'], isTrue);

      final withoutHeader = planFor(header: false);
      final positional = mappingParamsFor(withoutHeader);
      final positionalColumns = (positional['columns'] as List).cast<Map>();
      expect(positionalColumns[0], <String, dynamic>{
        'column': 'id',
        'source': 0,
      });
      expect(positionalColumns[1], <String, dynamic>{
        'column': 'name',
        'source': 1,
      });
    });

    test('importExecuteStart 参数完整', () {
      final plan = planFor(sheet: 'Sheet1');
      plan.skipRows = 2;
      final params = importParamsFor(
        path: '/tmp/a.xlsx',
        plan: plan,
        inspect: <String, dynamic>{
          'read': <String, dynamic>{'mode': 'wrapped', 'quote': ''},
          'fields': <String, dynamic>{'mode': 'excel', 'header': true},
        },
        database: 'main',
      );
      expect(params['path'], '/tmp/a.xlsx');
      expect(params['database'], 'main');
      expect(params['table'], 'demo');
      expect((params['read'] as Map)['sheet'], 'Sheet1');
      expect((params['read'] as Map)['skip_rows'], 2);
      expect((params['fields'] as Map)['mode'], 'excel');
      expect((params['options'] as Map)['on_error'], 'stop');
    });

    test('createTable body：整数主键默认不自增，显式 autoIncrement 才自增', () {
      // 学号/订单号这类业务编号：整数 + primary，但值来自文件，不能自增。
      final integerPlan = planFor();
      final mysqlBody = createTableBodyFor(integerPlan, 'mysql');
      final mysqlColumns = (mysqlBody['columns'] as List).cast<Map>();
      expect(mysqlColumns[0]['name'], 'id');
      expect(mysqlColumns[0]['type'], 'BIGINT');
      expect(mysqlColumns[0]['nullable'], isFalse);
      expect(mysqlColumns[0]['primary'], isTrue);
      expect(mysqlColumns[0]['auto_increment'], isFalse);

      final sqliteBody = createTableBodyFor(integerPlan, 'sqlite');
      expect(((sqliteBody['columns'] as List).first as Map)['type'], 'INTEGER');

      // 用户显式勾选「自增」后才打开（仅整数主键生效）。
      integerPlan.columns.first.autoIncrement = true;
      final autoBody = createTableBodyFor(integerPlan, 'mysql');
      expect(
        ((autoBody['columns'] as List).first as Map)['auto_increment'],
        isTrue,
      );

      // 「添加自增 id 主键」生成的列默认自增。
      final generatedPlan = planFor(
        columns: <QuickColumn>[
          QuickColumn(
            name: 'name',
            sourceLabel: 'name',
            sourceIndex: 0,
            inferred: 'text',
            sqlType: 'VARCHAR(255)',
          ),
        ],
      );
      final generated = addGeneratedPrimaryKey(generatedPlan, 'mysql');
      expect(generated.autoIncrement, isTrue);
      final generatedBody = createTableBodyFor(generatedPlan, 'mysql');
      final generatedColumn = (generatedBody['columns'] as List).first as Map;
      expect(generatedColumn['name'], 'id');
      expect(generatedColumn['primary'], isTrue);
      expect(generatedColumn['auto_increment'], isTrue);

      final textPlan = planFor(
        name: 'codes',
        columns: <QuickColumn>[
          QuickColumn(
            name: 'code',
            sourceLabel: 'code',
            sourceIndex: 0,
            inferred: 'text',
            sqlType: 'TEXT',
            primary: true,
            // 非整数主键即使勾了自增也不写 auto_increment。
            autoIncrement: true,
          ),
        ],
      );
      final pgBody = createTableBodyFor(textPlan, 'postgres');
      final pgColumn = (pgBody['columns'] as List).first as Map;
      expect(pgColumn['type'], 'VARCHAR(255)');
      expect(pgColumn['primary'], isTrue);
      expect(pgColumn['auto_increment'], isFalse);
    });
  });

  group('校验', () {
    test('合法计划通过', () {
      expect(validatePlans(<QuickTablePlan>[planFor()]), isNull);
    });

    test('表名非法 / 重复 / 已存在', () {
      expect(validatePlans(<QuickTablePlan>[planFor(name: '')]), isNotNull);
      expect(validatePlans(<QuickTablePlan>[planFor(name: 'a b')]), isNotNull);
      expect(
        validatePlans(<QuickTablePlan>[
          planFor(name: 'users'),
          planFor(name: 'Users'),
        ]),
        isNotNull,
      );
      expect(
        validatePlans(
          <QuickTablePlan>[planFor(name: 'users')],
          existingTables: <String>{'users'},
        ),
        isNotNull,
      );
    });

    test('字段问题', () {
      expect(
        validatePlans(<QuickTablePlan>[planFor(columns: <QuickColumn>[])]),
        isNotNull,
      );
      expect(
        validatePlans(<QuickTablePlan>[
          planFor(
            columns: <QuickColumn>[
              QuickColumn(
                name: 'a',
                sourceLabel: 'a',
                sourceIndex: 0,
                inferred: 'integer',
                sqlType: 'INTEGER',
                primary: true,
              ),
              QuickColumn(
                name: 'b',
                sourceLabel: 'b',
                sourceIndex: 1,
                inferred: 'integer',
                sqlType: 'INTEGER',
                primary: true,
              ),
            ],
          ),
        ]),
        isNotNull,
      );
      expect(
        validatePlans(<QuickTablePlan>[
          planFor(
            columns: <QuickColumn>[
              QuickColumn(
                name: 'a',
                sourceLabel: 'a',
                sourceIndex: 0,
                inferred: 'text',
                sqlType: 'TEXT',
              ),
              QuickColumn(
                name: 'a',
                sourceLabel: 'b',
                sourceIndex: 1,
                inferred: 'text',
                sqlType: 'TEXT',
              ),
            ],
          ),
        ]),
        isNotNull,
      );
      expect(
        validatePlans(<QuickTablePlan>[planFor()]),
        isNull,
        reason: '每张表最多一个主键，单主键合法',
      );
    });
  });

  group('主键兜底与生成列', () {
    test('没有主键时可一键插入自增 id（第一列、generated、唯一主键）', () {
      final plan = planFor(
        columns: <QuickColumn>[
          QuickColumn(
            name: 'name',
            sourceLabel: 'name',
            sourceIndex: 0,
            inferred: 'text',
            sqlType: 'TEXT',
          ),
        ],
      );
      expect(planHasPrimary(plan), isFalse);
      final id = addGeneratedPrimaryKey(plan, 'sqlite');
      expect(plan.columns.first, same(id));
      expect(id.name, 'id');
      expect(id.sourceIndex, -1);
      expect(id.sourceLabel, '');
      expect(id.generated, isTrue);
      expect(id.primary, isTrue);
      expect(id.nullable, isFalse);
      expect(id.inferred, 'integer');
      expect(id.sqlType, 'INTEGER');
      expect(id.autoIncrement, isTrue);
      expect(plan.columns.where((column) => column.primary).length, 1);
    });

    test('补 id 会取消原主键；已有 id 字段时生成 id_2', () {
      final plan = planFor(); // id(primary) + name
      expect(planHasPrimary(plan), isTrue);
      final generated = addGeneratedPrimaryKey(plan, 'mysql');
      expect(generated.name, 'id_2');
      expect(plan.columns.first, same(generated));
      // 原 id 不再是主键，整张表只剩生成列一个主键。
      expect(plan.columns[1].name, 'id');
      expect(plan.columns[1].primary, isFalse);
      expect(plan.columns.where((column) => column.primary).length, 1);
      expect(generated.sqlType, 'BIGINT');
    });

    test('创建载荷：生成列 auto_increment=true；取消主键后降级为普通可空列', () {
      final plan = planFor(
        columns: <QuickColumn>[
          QuickColumn(
            name: 'name',
            sourceLabel: 'name',
            sourceIndex: 0,
            inferred: 'text',
            sqlType: 'TEXT',
          ),
        ],
      );
      final id = addGeneratedPrimaryKey(plan, 'mysql');
      final body = createTableBodyFor(plan, 'mysql');
      final idBody = (body['columns'] as List).first as Map;
      expect(idBody['name'], 'id');
      expect(idBody['primary'], isTrue);
      expect(idBody['auto_increment'], isTrue);
      expect(idBody['nullable'], isFalse);

      // 用户取消了这个生成列的主键：保留列和名字，但不再自增；没有源数据，
      // 必须允许为空（否则 INSERT 会因缺值失败）。
      id.primary = false;
      id.nullable = true;
      final downgraded = createTableBodyFor(plan, 'mysql');
      final idColumn = (downgraded['columns'] as List).first as Map;
      expect(idColumn['primary'], isFalse);
      expect(idColumn['auto_increment'], isFalse);
      expect(idColumn['nullable'], isTrue);
    });

    test('导入 mapping 排除 generated 列', () {
      final plan = planFor(
        columns: <QuickColumn>[
          QuickColumn(
            name: 'name',
            sourceLabel: 'name',
            sourceIndex: 0,
            inferred: 'text',
            sqlType: 'TEXT',
          ),
          QuickColumn(
            name: 'score',
            sourceLabel: 'score',
            sourceIndex: 1,
            inferred: 'decimal',
            sqlType: 'NUMERIC',
          ),
        ],
      );
      addGeneratedPrimaryKey(plan, 'sqlite');
      final mapping = mappingParamsFor(plan);
      final columns = (mapping['columns'] as List).cast<Map>();
      expect(columns.length, 2);
      expect(columns.map((column) => column['column']).toList(), <String>[
        'name',
        'score',
      ]);
      expect(columns.any((column) => column['column'] == 'id'), isFalse);

      final params = importParamsFor(
        path: '/tmp/a.csv',
        plan: plan,
        inspect: <String, dynamic>{
          'read': <String, dynamic>{'mode': 'line'},
          'fields': <String, dynamic>{'mode': 'delimited', 'header': true},
        },
        database: 'main',
      );
      final mappings = ((params['mapping'] as Map)['columns'] as List)
          .cast<Map>();
      expect(mappings.map((column) => column['column']).toList(), <String>[
        'name',
        'score',
      ]);
    });

    test('没有主键不阻断校验（只提醒，不报错）', () {
      final plan = planFor(
        columns: <QuickColumn>[
          QuickColumn(
            name: 'name',
            sourceLabel: 'name',
            sourceIndex: 0,
            inferred: 'text',
            sqlType: 'TEXT',
          ),
        ],
      );
      expect(validatePlans(<QuickTablePlan>[plan]), isNull);
    });
  });

  group('外键预检与导入顺序', () {
    QuickTablePlan planNamed(String name) => QuickTablePlan(
      name: name,
      sheet: '',
      header: true,
      columns: <QuickColumn>[
        QuickColumn(
          name: 'id',
          sourceLabel: 'id',
          sourceIndex: 0,
          inferred: 'integer',
          sqlType: 'INTEGER',
        ),
      ],
    );

    QuickForeignKey fkOf(
      String child,
      String column,
      String parent,
      String refColumn, {
      String name = '',
    }) => QuickForeignKey(
      name: name,
      childTable: child,
      columns: <String>[column],
      refTable: parent,
      refColumns: <String>[refColumn],
    );

    test('父表先于子表；无关表沿用原顺序；环不死循环', () {
      final chain = importOrderFor(
        <QuickTablePlan>[
          planNamed('child'),
          planNamed('parent'),
          planNamed('grand'),
        ],
        <QuickForeignKey>[
          fkOf('child', 'pid', 'parent', 'id'),
          fkOf('parent', 'gid', 'grand', 'id'),
        ],
      );
      final names = chain.map((plan) => plan.name).toList();
      expect(names.length, 3);
      expect(names.indexOf('grand'), lessThan(names.indexOf('parent')));
      expect(names.indexOf('parent'), lessThan(names.indexOf('child')));

      // 无关表不会被拓扑排序挤掉。
      final mixed = importOrderFor(
        <QuickTablePlan>[planNamed('a'), planNamed('other'), planNamed('b')],
        <QuickForeignKey>[fkOf('a', 'bid', 'b', 'id')],
      );
      expect(mixed.map((plan) => plan.name).toList().length, 3);
      expect(
        mixed.map((plan) => plan.name).toList(),
        containsAll(<String>['a', 'b', 'other']),
      );

      // 环：两张表互相引用，仍然全部返回（按原顺序补全）。
      final cycle = importOrderFor(
        <QuickTablePlan>[planNamed('x'), planNamed('y'), planNamed('z')],
        <QuickForeignKey>[
          fkOf('x', 'yid', 'y', 'id'),
          fkOf('y', 'xid', 'x', 'id'),
        ],
      );
      expect(
        cycle.map((plan) => plan.name).toList(),
        containsAll(<String>['x', 'y', 'z']),
      );
      expect(cycle.length, 3);
    });

    test('样本比对：全部命中返回 null，NULL/空串跳过', () {
      expect(
        compareForeignKeySamples(
          foreignKey: fkOf('child', 'pid', 'parent', 'id'),
          parentValues: <Object?>[1, 2, '3'],
          childValues: <Object?>[1, '2', null, '', 3],
        ),
        isNull,
      );
    });

    test('样本比对：部分不匹配时统计数量并给示例值', () {
      final issue = compareForeignKeySamples(
        foreignKey: fkOf('child', 'pid', 'parent', 'id'),
        parentValues: <Object?>['A', 'B'],
        childValues: <Object?>['A', 'C', 'C', null, '', 'D'],
      );
      expect(issue, isNotNull);
      expect(issue!.total, 4);
      expect(issue.mismatched, 3);
      expect(issue.examples, <String>['C', 'D']);
      expect(issue.isHighRisk, isFalse);
    });

    test('数值宽松比较：数字/字符串/空白/前导零视为同一值', () {
      expect(normalizeForeignKeyValue(1), normalizeForeignKeyValue(' 1 '));
      expect(normalizeForeignKeyValue(1.0), normalizeForeignKeyValue('1.0'));
      expect(normalizeForeignKeyValue(1), normalizeForeignKeyValue('001'));
      expect(normalizeForeignKeyValue(null), isNull);
      expect(normalizeForeignKeyValue('  '), isNull);
      expect(
        compareForeignKeySamples(
          foreignKey: fkOf('child', 'pid', 'parent', 'id'),
          parentValues: <Object?>['1', 2.0],
          childValues: <Object?>[1, '2'],
        ),
        isNull,
      );
    });

    test('父表被引用列是 generated 自增列：高风险，即使子表样本为空', () {
      final issue = compareForeignKeySamples(
        foreignKey: fkOf('child', 'pid', 'parent', 'id'),
        parentValues: const <Object?>[],
        childValues: const <Object?>[],
        generatedParentColumn: true,
      );
      expect(issue, isNotNull);
      expect(issue!.isHighRisk, isTrue);
      expect(issue.generatedParentColumn, isTrue);
      expect(issue.mismatched, 0);
    });

    test('foreignKeysInWizard 只保留两端都在本次向导表里的外键', () {
      final schema = <String, dynamic>{
        'tables': <dynamic>[
          <String, dynamic>{
            'name': 'A',
            'columns': <dynamic>[],
            'foreign_keys': <dynamic>[
              <String, dynamic>{
                'column': 'bid',
                'ref_table': 'B',
                'ref_column': 'id',
              },
            ],
          },
          <String, dynamic>{
            'name': 'B',
            'columns': <dynamic>[],
            'foreign_keys': <dynamic>[],
          },
          <String, dynamic>{
            'name': 'C',
            'columns': <dynamic>[],
            'foreign_keys': <dynamic>[
              <String, dynamic>{
                'column': 'xid',
                'ref_table': 'outside',
                'ref_column': 'id',
              },
            ],
          },
        ],
      };
      final fks = foreignKeysInWizard(schema, <String>{'A', 'B', 'C'});
      expect(fks.length, 1);
      expect(fks.first.childTable, 'A');
      expect(fks.first.childColumn, 'bid');
      expect(fks.first.refTable, 'B');
      expect(fks.first.refColumn, 'id');
    });

    test('解析 MySQL 外键失败：约束名/子表/列/父表/列对齐到注入外键', () {
      const message =
          '批量插入失败: Cannot add or update a child row: '
          'a foreign key constraint fails (web.students, CONSTRAINT '
          'fk_students_grade FOREIGN KEY (学号) REFERENCES 学生名单 (id) '
          'ON DELETE CASCADE) (错误码 23000)';
      final injected = <QuickForeignKey>[
        fkOf('students', '学号', '学生名单', 'id', name: 'fk_students_grade'),
      ];
      final parsed = parseForeignKeyFailure(message, injected);
      expect(parsed, isNotNull);
      expect(parsed!.constraintName, 'fk_students_grade');
      expect(parsed.childTable, 'students');
      expect(parsed.childColumn, '学号');
      expect(parsed.refTable, '学生名单');
      expect(parsed.refColumn, 'id');
      expect(parsed.foreignKey, isNotNull);
      expect(parsed.path, 'students.学号 → 学生名单.id');
      expect(parsed.droppableName, 'fk_students_grade');

      // 用户截图里的真实 MySQL 报错（库名/表名/列名都带反引号）。
      final quoted = parseForeignKeyFailure(
        'Cannot add or update a child row: a foreign key constraint fails '
        '(`web`.`年级成绩单`, CONSTRAINT `fk_tujmxvt_cg09d` '
        'FOREIGN KEY (`学号`) REFERENCES `学生名单` (`id`) '
        'ON DELETE CASCADE) (错误码 23000)',
        <QuickForeignKey>[
          fkOf('年级成绩单', '学号', '学生名单', 'id', name: 'fk_tujmxvt_cg09d'),
        ],
      );
      expect(quoted, isNotNull);
      expect(quoted!.constraintName, 'fk_tujmxvt_cg09d');
      expect(quoted.childTable, '年级成绩单');
      expect(quoted.childColumn, '学号');
      expect(quoted.refTable, '学生名单');
      expect(quoted.refColumn, 'id');
      expect(quoted.path, '年级成绩单.学号 → 学生名单.id');
    });

    test('解析 SQLite / PostgreSQL / 非外键错误', () {
      final sqlite = parseForeignKeyFailure(
        'FOREIGN KEY constraint failed (code 787)',
        const <QuickForeignKey>[],
      );
      expect(sqlite, isNotNull);
      expect(
        isForeignKeyError('FOREIGN KEY constraint failed (code 787)'),
        isTrue,
      );
      expect(sqlite!.droppableName, '');

      const pg =
          'insert or update on table "grade" violates foreign key '
          'constraint "fk_grade_student"\n'
          'DETAIL: Key (student_id)=(9) is not present in table "students".';
      final parsedPg = parseForeignKeyFailure(pg, <QuickForeignKey>[
        fkOf('grade', 'student_id', 'students', 'id', name: 'fk_grade_student'),
      ]);
      expect(parsedPg, isNotNull);
      expect(parsedPg!.constraintName, 'fk_grade_student');
      expect(parsedPg.path, 'grade.student_id → students.id');

      expect(
        parseForeignKeyFailure(
          'duplicate key value violates unique constraint',
          const <QuickForeignKey>[],
        ),
        isNull,
      );
      expect(
        isForeignKeyError('duplicate key value violates unique constraint'),
        isFalse,
      );
    });
  });

  group('英文模式文案', () {
    test('向导与入口文案都有英文映射', () {
      I18n.setLang(AppLang.en);
      try {
        expect(trLiteral('从文件建表'), 'Create tables from file');
        expect(trLiteral('工作表与字段'), 'Worksheets and columns');
        expect(trLiteral('创建并导入'), 'Create and import');
        expect(trLiteral('建立关联'), 'Connect tables');
        expect(trLiteral('关系图'), 'Relationships');
        expect(
          trLiteral('全部导入（每张工作表建一张表）'),
          'Import all (one table per worksheet)',
        );
        expect(trLiteral('主键'), 'Primary key');
        expect(
          trLiteral('查看并编辑表之间的外键关系'),
          'View and edit foreign-key relationships between tables',
        );
        // 卡片标题 / 工作表列这类插值文案走 Rewrite 模式。
        expect(trLiteral('表 2 · Sheet1'), 'Table 2 · Sheet1');
        expect(trLiteral('工作表：Sheet1'), 'Worksheet: Sheet1');
      } finally {
        I18n.setLang(AppLang.zh);
      }
    });
  });

  // =====================================================================
  // 第 52 轮：类型对齐 / 自增 / 主键候选 / 删表顺序 / 表头 / 失败文案
  // =====================================================================

  QuickColumn quickColumn(
    String name,
    String sqlType, {
    bool primary = false,
    bool generated = false,
    bool autoIncrement = false,
    String primaryReason = '',
    int sourceIndex = 0,
  }) => QuickColumn(
    name: name,
    sourceLabel: name,
    sourceIndex: sourceIndex,
    inferred: 'integer',
    sqlType: sqlType,
    primary: primary,
    generated: generated,
    autoIncrement: autoIncrement,
    primaryReason: primaryReason,
  );

  group('业务外键列类型对齐（P0-1）', () {
    test('整数主键存在时 *_id / *Id / *ID 整数列对齐到驱动主键类型', () {
      final plan = planFor(
        columns: <QuickColumn>[
          quickColumn('id', 'BIGINT', primary: true),
          quickColumn('student_id', 'INT', sourceIndex: 1),
          quickColumn('orderId', 'INT', sourceIndex: 2),
          quickColumn('classID', 'INT', sourceIndex: 3),
          quickColumn('name', 'TEXT', sourceIndex: 4),
          quickColumn('score', 'DECIMAL(18,2)', sourceIndex: 5),
          quickColumn('code', 'INT', sourceIndex: 6),
        ],
      );
      expect(alignForeignKeyColumns(plan.columns, 'mysql'), isTrue);
      expect(plan.columns[1].sqlType, 'BIGINT');
      expect(plan.columns[2].sqlType, 'BIGINT');
      expect(plan.columns[3].sqlType, 'BIGINT');
      // 文本 / 小数 / 名字不匹配后缀的列不动。
      expect(plan.columns[4].sqlType, 'TEXT');
      expect(plan.columns[5].sqlType, 'DECIMAL(18,2)');
      expect(plan.columns[6].sqlType, 'INT');

      expect(alignForeignKeyColumns(plan.columns, 'sqlite'), isTrue);
      expect(plan.columns[1].sqlType, 'INTEGER');
      // 幂等：已经对齐过就不再改动。
      expect(alignForeignKeyColumns(plan.columns, 'sqlite'), isFalse);
    });

    test('没有整数主键（文本主键 / 无主键）时不对齐', () {
      final textPk = planFor(
        columns: <QuickColumn>[
          quickColumn('student_no', 'VARCHAR(20)', primary: true),
          quickColumn('class_id', 'INT', sourceIndex: 1),
        ],
      );
      expect(alignForeignKeyColumns(textPk.columns, 'mysql'), isFalse);
      expect(textPk.columns[1].sqlType, 'INT');

      final noPk = planFor(
        columns: <QuickColumn>[
          quickColumn('class_id', 'INT'),
          quickColumn('name', 'TEXT', sourceIndex: 1),
        ],
      );
      expect(alignForeignKeyColumns(noPk.columns, 'mysql'), isFalse);
    });

    test('一键添加自增 id 主键后自动对齐业务外键列', () {
      final plan = planFor(
        columns: <QuickColumn>[
          quickColumn('student_id', 'INT'),
          quickColumn('name', 'TEXT', sourceIndex: 1),
        ],
      );
      final generated = addGeneratedPrimaryKey(plan, 'mysql');
      expect(generated.sqlType, 'BIGINT');
      expect(generated.autoIncrement, isTrue);
      expect(plan.columns[1].name, 'student_id');
      expect(plan.columns[1].sqlType, 'BIGINT');
    });
  });

  group('主键整数类型统一（第 53 轮）', () {
    test('columnsFromPreview：整数主键按驱动统一成主键类型', () {
      final preview = <String, dynamic>{
        'schema': <String, dynamic>{
          'columns': <dynamic>[
            <String, dynamic>{
              'name': 'id',
              'source': 0,
              'type': 'integer',
              'nullable': false,
              'primary_candidate': true,
            },
            <String, dynamic>{
              'name': 'qty',
              'source': 1,
              'type': 'integer',
              'nullable': true,
            },
          ],
        },
      };
      for (final driver in <String>['mysql', 'postgres', 'sqlite']) {
        final columns = columnsFromPreview(preview, driver: driver);
        expect(
          columns[0].sqlType,
          pkColumnTypeFor(driver),
          reason: '$driver：主键整数列应该用主键类型',
        );
        expect(columns[0].primary, isTrue);
        // 非主键整数列仍用推断类型（MySQL 保持 INT），不跟着主键变。
        expect(columns[1].sqlType, sqlTypeFor('integer', driver));
        expect(columns[1].primary, isFalse);
      }
      expect(
        columnsFromPreview(preview, driver: 'mysql').first.sqlType,
        'BIGINT',
      );
    });

    test('normalizePrimaryColumnTypes：只改整数主键、幂等', () {
      final textPk = quickColumn('student_no', 'VARCHAR(20)', primary: true);
      expect(
        normalizePrimaryColumnTypes(<QuickColumn>[textPk], 'mysql'),
        isFalse,
        reason: '文本主键不是整数族，不能改成 BIGINT',
      );
      expect(textPk.sqlType, 'VARCHAR(20)');

      final id = quickColumn('id', 'INT', primary: true);
      expect(normalizePrimaryColumnTypes(<QuickColumn>[id], 'mysql'), isTrue);
      expect(id.sqlType, 'BIGINT');
      expect(
        normalizePrimaryColumnTypes(<QuickColumn>[id], 'mysql'),
        isFalse,
        reason: '已经是对的类型，幂等',
      );

      final sqliteId = quickColumn('id', 'INT', primary: true);
      expect(
        normalizePrimaryColumnTypes(<QuickColumn>[sqliteId], 'sqlite'),
        isTrue,
      );
      expect(sqliteId.sqlType, 'INTEGER');

      final normal = quickColumn('qty', 'INT');
      expect(
        normalizePrimaryColumnTypes(<QuickColumn>[normal], 'mysql'),
        isFalse,
      );
      expect(normal.sqlType, 'INT');
    });

    test('补自增 id 主键后表里不会残留 INT 主键', () {
      final plan = planFor(
        columns: <QuickColumn>[
          quickColumn('id', 'INT', primary: true),
          quickColumn('name', 'TEXT', sourceIndex: 1),
        ],
      );
      addGeneratedPrimaryKey(plan, 'mysql');
      final primary = plan.columns.where((column) => column.primary).single;
      expect(primary.generated, isTrue);
      expect(primary.sqlType, 'BIGINT');
      // 原业务 id 降级为普通列，类型不再被主键逻辑强制。
      expect(plan.columns[1].primary, isFalse);
    });
  });

  group('主键候选提示（P1-3）', () {
    test('columnsFromPreview 读取 reason；样本唯一列给出提示', () {
      final preview = <String, dynamic>{
        'header': <dynamic>['学号', '姓名'],
        'schema': <String, dynamic>{
          'columns': <dynamic>[
            <String, dynamic>{
              'name': '学号',
              'source': 0,
              'type': 'integer',
              'nullable': false,
              'unique': true,
              'primary_candidate': true,
              'primary_candidate_reason': 'unique_integer',
            },
            <String, dynamic>{
              'name': '姓名',
              'source': 1,
              'type': 'text',
              'primary_candidate': false,
            },
          ],
        },
      };
      final columns = columnsFromPreview(preview, driver: 'mysql');
      expect(columns[0].primary, isTrue);
      expect(columns[0].primaryReason, 'unique_integer');
      expect(columns[1].primaryReason, '');
      final plan = QuickTablePlan(
        name: 'students',
        sheet: '',
        header: true,
        columns: columns,
      );
      expect(sampledPrimaryCandidate(plan), '学号');
    });

    test('reason 为 id 或缺失（旧 dylib）时不提示', () {
      QuickTablePlan planWithReason(String reason) => QuickTablePlan(
        name: 't',
        sheet: '',
        header: true,
        columns: <QuickColumn>[
          quickColumn('id', 'BIGINT', primary: true, primaryReason: reason),
        ],
      );
      expect(sampledPrimaryCandidate(planWithReason('id')), isNull);
      expect(sampledPrimaryCandidate(planWithReason('')), isNull);
      expect(sampledPrimaryCandidate(planWithReason('first_column')), 'id');
      expect(sampledPrimaryCandidate(planWithReason('unique_text')), 'id');
    });
  });

  group('删表顺序（P1-4）', () {
    QuickForeignKey link(String child, String parent) => QuickForeignKey(
      name: '',
      childTable: child,
      columns: <String>['pid'],
      refTable: parent,
      refColumns: <String>['id'],
    );

    test('先删子表再删父表（与导入顺序相反）', () {
      expect(
        dropOrderFor(
          <String>['parent', 'child'],
          <QuickForeignKey>[link('child', 'parent')],
        ),
        <String>['child', 'parent'],
      );
    });

    test('三代表 child → parent → grand，删除顺序 child、parent、grand', () {
      final order = dropOrderFor(
        <String>['grand', 'parent', 'child'],
        <QuickForeignKey>[link('child', 'parent'), link('parent', 'grand')],
      );
      expect(order.indexOf('child'), lessThan(order.indexOf('parent')));
      expect(order.indexOf('parent'), lessThan(order.indexOf('grand')));
      expect(order.length, 3);
    });

    test('环不死循环、不漏表', () {
      final order = dropOrderFor(
        <String>['x', 'y', 'z'],
        <QuickForeignKey>[link('x', 'y'), link('y', 'x')],
      );
      expect(order.toSet(), <String>{'x', 'y', 'z'});
      expect(order.length, 3);
    });
  });

  group('每工作表表头判断（P1-7）', () {
    Map<String, dynamic> previewWith({
      List<String>? header,
      required List<List<Object?>> rows,
      bool keyed = false,
    }) => <String, dynamic>{
      'header': header,
      'records': <dynamic>[
        for (final row in rows)
          <String, dynamic>{
            'kind': keyed ? 'object' : 'array',
            'field_count': row.length,
            'values': keyed
                ? <String, dynamic>{
                    for (var index = 0; index < row.length; index++)
                      'k$index': row[index],
                  }
                : row,
          },
      ],
    };

    test('表头模式：正常列名保持；纯数字 / 纯日期表头判为误判', () {
      expect(
        suggestHeaderForPreview(
          previewWith(
            header: <String>['id', '姓名'],
            rows: <List<Object?>>[
              <Object?>[1, 'Ada'],
              <Object?>[2, 'Bob'],
            ],
          ),
          true,
        ),
        isTrue,
      );
      expect(
        suggestHeaderForPreview(
          previewWith(
            header: <String>['1001', '名称'],
            rows: <List<Object?>>[
              <Object?>[1, 'Ada'],
              <Object?>[2, 'Bob'],
            ],
          ),
          true,
        ),
        isFalse,
      );
      expect(
        suggestHeaderForPreview(
          previewWith(
            header: <String>['2024/01/02', '金额'],
            rows: <List<Object?>>[
              <Object?>[1, 'Ada'],
              <Object?>[2, 'Bob'],
            ],
          ),
          true,
        ),
        isFalse,
      );
    });

    test('非表头模式：首行全是非空文本且有第二行 → 判为表头', () {
      expect(
        suggestHeaderForPreview(
          previewWith(
            rows: <List<Object?>>[
              <Object?>['姓名', '城市'],
              <Object?>['Ada', '北京'],
            ],
          ),
          false,
        ),
        isTrue,
      );
      // 首行含数字 / 空值 → 保持无表头。
      expect(
        suggestHeaderForPreview(
          previewWith(
            rows: <List<Object?>>[
              <Object?>['Ada', 1],
              <Object?>['Bob', 2],
            ],
          ),
          false,
        ),
        isFalse,
      );
      expect(
        suggestHeaderForPreview(
          previewWith(
            rows: <List<Object?>>[
              <Object?>['Ada', null],
              <Object?>['Bob', 'x'],
            ],
          ),
          false,
        ),
        isFalse,
      );
      // 只有一行数据无法判断；keyed 记录没有表头概念。
      expect(
        suggestHeaderForPreview(
          previewWith(
            rows: <List<Object?>>[
              <Object?>['姓名', '城市'],
            ],
          ),
          false,
        ),
        isFalse,
      );
      expect(
        suggestHeaderForPreview(
          previewWith(
            rows: <List<Object?>>[
              <Object?>['Ada', '北京'],
              <Object?>['Bob', '上海'],
            ],
            keyed: true,
          ),
          false,
        ),
        isFalse,
      );
    });
  });

  group('导入失败文案（P1-8）', () {
    test('外键失败：主文案点名子表，中英都有', () {
      final message =
          "批量插入失败: Cannot add or update a child row: a foreign key "
          "constraint fails (web.年级成绩单, CONSTRAINT fk_score_student "
          "FOREIGN KEY (学号) REFERENCES 学生名单 (id)) (错误码 23000)";
      final copy = describeImportFailure(message);
      expect(copy.zh, startsWith('导入失败：'));
      expect(copy.zh, contains('外键'));
      expect(copy.zh, contains('年级成绩单'));
      expect(copy.en, contains('foreign key'));
      expect(copy.en, contains('年级成绩单'));
      expect(classifyImportFailure(message), ImportFailureKind.foreignKey);
    });

    test('重复值 / 超长 / 必填为空 / 数字越界分类与文案', () {
      expect(
        classifyImportFailure("Duplicate entry '1' for key 'PRIMARY'"),
        ImportFailureKind.duplicate,
      );
      expect(
        classifyImportFailure('Data too long for column name at row 3'),
        ImportFailureKind.tooLong,
      );
      expect(
        classifyImportFailure("Column 'name' cannot be null"),
        ImportFailureKind.notNull,
      );
      expect(
        classifyImportFailure('Out of range value for column id'),
        ImportFailureKind.numeric,
      );
      expect(
        describeImportFailure("Duplicate entry '1' for key 'PRIMARY'").zh,
        contains('重复值'),
      );
      final unknown = describeImportFailure('some strange database failure');
      expect(unknown.zh, contains('技术细节'));
      expect(unknown.en, contains('Technical details'));
    });
  });

  group('过期提示过滤（P2-2）', () {
    test('多工作表 / 整表载入内存提示过滤，其它保留', () {
      expect(
        isStaleQuickCreateWarning('检测到 3 个工作表：当前导入所选工作表；一次导入多个工作表请用「从文件建表」'),
        isTrue,
      );
      expect(isStaleQuickCreateWarning('工作簿较大：读取时会整表载入内存后分批插入'), isTrue);
      expect(isStaleQuickCreateWarning('已知文件暂未流式读取，请耐心等待'), isTrue);
      expect(isStaleQuickCreateWarning('已忽略 2 个隐藏工作表'), isFalse);
      expect(isStaleQuickCreateWarning('文件约 6.0 GB，会逐行流式读取，耗时较长'), isFalse);
      expect(isStaleQuickCreateWarning('   '), isTrue);
    });
  });

  group('导入后统计刷新（P2-10）', () {
    test('MySQL/PostgreSQL 生成 ANALYZE，SQLite 不生成', () {
      expect(
        analyzeStatisticsStatement('mysql', 'orders'),
        'ANALYZE TABLE `orders`',
      );
      expect(
        analyzeStatisticsStatement('postgres', 'orders'),
        'ANALYZE "orders"',
      );
      expect(analyzeStatisticsStatement('sqlite', 'orders'), isNull);
      expect(analyzeStatisticsStatement('mysql', '  '), isNull);
    });
  });

  // =====================================================================
  // FFI：真实 Rust 核心 + SQLite
  // =====================================================================

  late Directory temporary;

  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run cargo build --lib in rust/ first: ${dylib.path} is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    temporary = await Directory.systemTemp.createTemp('rma-quick-create-');
    final init = await Api.init(temporary.path);
    expect(init['ok'], isTrue, reason: 'init_app failed: $init');
    await AppState.instance.bootstrap(temporary.path);
    final dbFile = '${temporary.path}/quick.sqlite';
    File(dbFile).createSync(recursive: true);
    final created = await Api.instance.createConnection(<String, dynamic>{
      'name': 'Quick create FFI',
      'driver': 'sqlite',
      'database': dbFile,
    });
    final id = ((created['connection'] as Map)['id']).toString();
    await AppState.instance.connect(id);
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

  setUp(() => I18n.setLang(AppLang.zh));

  Future<String> writeFile(String name, String content) async {
    final file = File('${temporary.path}/$name');
    await file.writeAsString(content);
    return file.path;
  }

  /// 像真实入口一样用 showDialog 打开向导（这样「完成」能正常 pop）。
  Future<void> pumpWizard(
    WidgetTester tester,
    String path,
    Notice notice,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Btn(
              'open-quick-create',
              onPressed: () => showQuickCreateTableWizard(
                context,
                database: 'main',
                notice: notice,
                initialPath: path,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-quick-create'));
    await settle(tester, rounds: 6);
  }

  /// 打开向导并返回 State 句柄（测试要断言内部状态时用）。
  Future<GlobalKey<QuickCreateTableWizardState>> pumpWizardWithKey(
    WidgetTester tester,
    String path,
    Notice notice,
  ) async {
    final stateKey = GlobalKey<QuickCreateTableWizardState>();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Btn(
              'open-quick-create-key',
              onPressed: () => showQuickCreateTableWizard(
                context,
                database: 'main',
                notice: notice,
                initialPath: path,
                stateKey: stateKey,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-quick-create-key'));
    await settle(tester, rounds: 6);
    return stateKey;
  }

  Future<void> setFieldText(
    WidgetTester tester,
    String key,
    String text,
  ) async {
    final field = find.byKey(ValueKey<String>(key));
    expect(field, findsOneWidget, reason: 'field $key is missing');
    final textField = find.descendant(
      of: field,
      matching: find.byType(TextField),
    );
    await tester.enterText(textField, text);
    await tester.pump();
  }

  String fieldText(WidgetTester tester, String key) {
    final field = find.byKey(ValueKey<String>(key));
    expect(field, findsOneWidget, reason: 'field $key is missing');
    final textField = tester.widget<TextField>(
      find.descendant(of: field, matching: find.byType(TextField)),
    );
    return textField.controller?.text ?? '';
  }

  Finder primaryButton() =>
      find.byKey(const ValueKey<String>('quick-create-primary'));

  Future<int> countRows(WidgetTester tester, String table) async {
    // 引号包裹：xlsx fixture 的工作表名是中文，未加引号的标识符各驱动行为不同。
    final res = await tester.runAsync(
      () => Api.instance.query('SELECT COUNT(*) AS c FROM "$table";'),
    );
    final row =
        (((res!['results'] as List).first as Map)['rows'] as List).first;
    return ((row as List).first as num).toInt();
  }

  Future<List<String>> columnTypes(WidgetTester tester, String table) async {
    final structure = await tester.runAsync(
      () => Api.instance.structure('main', table),
    );
    return (structure!['columns'] as List? ?? const <dynamic>[])
        .map((column) => ((column as Map)['type_name'] ?? '').toString())
        .toList();
  }

  Future<List<String>> tableNames(WidgetTester tester) async {
    final tables = await tester.runAsync(() => Api.instance.tables('main'));
    return (tables ?? const <Json>[])
        .map((table) => (table['name'] ?? '').toString())
        .toList();
  }

  Future<List<dynamic>> queryRows(WidgetTester tester, String sql) async {
    final res = await tester.runAsync(() => Api.instance.query(sql));
    return ((res!['results'] as List).first as Map)['rows'] as List;
  }

  Future<String> tableDdl(WidgetTester tester, String table) async {
    final ddl = await tester.runAsync(() => Api.instance.ddl('main', table));
    return (ddl?['ddl'] ?? '').toString();
  }

  /// 走到「全部表的数据都导入完成」为止；返回 null 表示成功，否则返回页面错误。
  Future<String?> runUntilImported(WidgetTester tester) async {
    for (var i = 0; i < 240; i++) {
      await settle(tester, rounds: 1);
      if (find.textContaining('全部表的数据都导入完成').evaluate().isNotEmpty) {
        return null;
      }
      final failed =
          find.textContaining('导入失败').evaluate().isNotEmpty ||
          find.textContaining('等待导入任务超时').evaluate().isNotEmpty;
      if (failed) {
        final texts = tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data ?? '')
            .where((text) => text.isNotEmpty)
            .toList();
        return texts.join(' | ');
      }
    }
    return 'timeout';
  }

  testWidgets('CSV 单表：建表 + 导入 + 类型推断 + 建立关联步骤', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final csvPath = await tester.runAsync(
      () => writeFile(
        'people.csv',
        'id,name,score\n1,Ada,9.5\n2,Bob,8\n3,Cy,7.25\n',
      ),
    );
    final notice = Notice();
    addTearDown(notice.dispose);

    await pumpWizard(tester, csvPath!, notice);
    await settle(tester, rounds: 16);

    // 第 1 步：文件与格式识别。
    expect(find.text('数据文件'), findsOneWidget);
    expect(find.text('people.csv'), findsWidgets);

    // 下一步 → 工作表与字段（单表：表名取文件名）。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 20);
    expect(fieldText(tester, 'quick-table-name-0'), 'people');
    expect(find.text('源列名'), findsOneWidget);
    expect(find.text('首行是列名'), findsOneWidget);

    // 下一步：先建空表 → 进入「建立关联」步骤（表已存在但还没有数据）。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);
    expect(find.byType(RelationDesigner), findsOneWidget);
    expect(find.textContaining('先在这张画布上把表之间的关系连好'), findsOneWidget);
    final designer = tester.widget<RelationDesigner>(
      find.byType(RelationDesigner),
    );
    expect(designer.initialTables, <String>['people']);
    expect(designer.maxTables, kRelationSeedLimit);
    expect(await tableNames(tester), contains('people'));
    expect(await countRows(tester, 'people'), 0, reason: '关系步骤时只建空表，不导入数据');

    // 下一步 → 导入数据；第 3 步只做导入，不再 CREATE TABLE。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 4);
    expect(find.text('执行计划'), findsOneWidget);
    await tester.tap(primaryButton());
    final failure = await runUntilImported(tester);
    expect(failure, isNull, reason: 'import failed: $failure');

    // 真实数据库里：1 张表、3 行、类型按推断创建。
    expect(await countRows(tester, 'people'), 3);
    final types = await columnTypes(tester, 'people');
    expect(types[0], contains('INT'));
    expect(types[1], contains('TEXT'));
    expect(types[2], anyOf(contains('NUM'), contains('REAL')));

    // 完成：关闭向导并提示创建数量。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 6);
    expect(find.byType(QuickCreateTableWizard), findsNothing);
    expect(notice.message, contains('已创建 1 张表'));

    // notice 的成功提示有 2.6s / 3s 两个计时器；让它们走完再结束测试，
    // 否则 flutter_test 会以 "A Timer is still pending" 失败。
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('英文模式：向导首屏与字段步骤没有中文残留', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final csvPath = await tester.runAsync(
      () => writeFile('english.csv', 'id,name\n1,Ada\n2,Bob\n'),
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    I18n.setLang(AppLang.en);
    try {
      await pumpWizard(tester, csvPath!, notice);
      await settle(tester, rounds: 16);
      expect(find.text('Data file'), findsOneWidget);
      expectNoHanTexts(tester, '选择文件');

      await tester.tap(primaryButton());
      await settle(tester, rounds: 20);
      expect(find.text('Table name'), findsOneWidget);
      expectNoHanTexts(tester, '工作表与字段');
    } finally {
      I18n.setLang(AppLang.zh);
    }
    // notice 计时器不参与本测试，直接走完假时钟避免 pending timer。
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('多工作表 SpreadsheetML：全部导入建 2 张表', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fixture = _spreadsheetMl(<String, List<List<Object?>>>{
      'Orders': <List<Object?>>[
        <Object?>['order_id', 'customer', 'paid'],
        <Object?>[1, 'Ada', true],
        <Object?>[2, 'Bob', false],
      ],
      'Items': <List<Object?>>[
        <Object?>['item_id', 'title', 'price'],
        <Object?>[1, 'pen', 1.5],
        <Object?>[2, 'book', 9.9],
        <Object?>[3, 'bag', 20],
      ],
    });
    final path = await tester.runAsync(() => writeFile('book.xls', fixture));
    final capability = await tester.runAsync(
      () => Api.instance.importInspect(path!),
    );
    final sheets = capability?['sheets'];
    if (sheets is! List || sheets.isEmpty) {
      markTestSkipped(
        'rust-excel inspect.sheets 契约未就绪（当前 dylib 把 .xls 当成单表读取）',
      );
      return;
    }

    final notice = Notice();
    addTearDown(notice.dispose);
    await pumpWizard(tester, path!, notice);
    await settle(tester, rounds: 16);

    expect(
      find.text('全部导入（每张工作表建一张表）'),
      findsOneWidget,
      reason: '多工作表时应显示全部导入开关',
    );
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);

    expect(fieldText(tester, 'quick-table-name-0'), 'Orders');
    expect(fieldText(tester, 'quick-table-name-1'), 'Items');

    // 第 1 步 → 第 2 步：先建 2 张空表，再进入关系步骤。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 40);
    expect(find.byType(RelationDesigner), findsOneWidget);
    expect(await tableNames(tester), containsAll(<String>['Orders', 'Items']));
    expect(await countRows(tester, 'Orders'), 0);
    expect(await countRows(tester, 'Items'), 0);

    await tester.tap(primaryButton()); // 下一步：导入数据
    await settle(tester, rounds: 4);
    await tester.tap(primaryButton()); // 开始导入
    final failure = await runUntilImported(tester);
    expect(failure, isNull, reason: 'multi-sheet import failed: $failure');

    final names = await tableNames(tester);
    expect(names, containsAll(<String>['Orders', 'Items']));
    expect(await countRows(tester, 'Orders'), 2);
    expect(await countRows(tester, 'Items'), 3);
  });

  testWidgets('多工作表：自定义只选 1 张', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fixture = _spreadsheetMl(<String, List<List<Object?>>>{
      'Alpha': <List<Object?>>[
        <Object?>['id', 'label'],
        <Object?>[1, 'a'],
      ],
      'Beta': <List<Object?>>[
        <Object?>['id', 'label'],
        <Object?>[1, 'b'],
        <Object?>[2, 'c'],
      ],
    });
    final path = await tester.runAsync(() => writeFile('choice.xls', fixture));
    final capability = await tester.runAsync(
      () => Api.instance.importInspect(path!),
    );
    final sheets = capability?['sheets'];
    if (sheets is! List || sheets.isEmpty) {
      markTestSkipped(
        'rust-excel inspect.sheets 契约未就绪（当前 dylib 把 .xls 当成单表读取）',
      );
      return;
    }

    final notice = Notice();
    addTearDown(notice.dispose);
    await pumpWizard(tester, path!, notice);
    await settle(tester, rounds: 16);

    // 切到「自定义选择」，再取消 Alpha，只留 Beta。
    await tester.tap(find.text('全部导入（每张工作表建一张表）'));
    await tester.pump();
    await tester.tap(find.textContaining('Alpha').first);
    await tester.pump();
    expect(find.textContaining('将创建 1 张表'), findsOneWidget);

    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);
    expect(fieldText(tester, 'quick-table-name-0'), 'Beta');
    expect(
      find.byKey(const ValueKey<String>('quick-table-name-1')),
      findsNothing,
    );

    // 第 1 步 → 第 2 步：建空表并进入关系步骤。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 40);
    expect(find.byType(RelationDesigner), findsOneWidget);
    expect(await tableNames(tester), contains('Beta'));
    expect(await countRows(tester, 'Beta'), 0);

    await tester.tap(primaryButton()); // 下一步：导入数据
    await settle(tester, rounds: 4);
    await tester.tap(primaryButton()); // 开始导入
    final failure = await runUntilImported(tester);
    expect(failure, isNull, reason: 'custom-sheet import failed: $failure');

    final names = await tableNames(tester);
    expect(names, contains('Beta'));
    expect(names, isNot(contains('Alpha')));
    expect(await countRows(tester, 'Beta'), 2);
  });

  testWidgets('真实 xlsx fixture：多工作表全部导入（中文表头/日期/布尔）', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fixture = File('rust/tests/fixtures/excel_multi.xlsx');
    if (!fixture.existsSync()) {
      markTestSkipped(
        'rust-excel fixture 未提交（rust/tests/fixtures/excel_multi.xlsx）',
      );
      return;
    }
    final path = fixture.absolute.path;
    final inspect = await tester.runAsync(
      () => Api.instance.importInspect(path),
    );
    final sheets = (inspect?['sheets'] as List? ?? const <dynamic>[])
        .map((sheet) => ((sheet as Map)['name'] ?? '').toString())
        .toList();
    if (sheets.isEmpty) {
      markTestSkipped('dylib 未返回 inspect.sheets');
      return;
    }

    final notice = Notice();
    addTearDown(notice.dispose);
    await pumpWizard(tester, path, notice);
    await settle(tester, rounds: 20);

    // 3 个可见工作表 → 默认「全部导入」；每张表一个 Card。
    expect(find.text('全部导入（每张工作表建一张表）'), findsOneWidget);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 40);
    for (var i = 0; i < sheets.length; i++) {
      expect(
        fieldText(tester, 'quick-table-name-$i'),
        sanitizeIdentifier(sheets[i]),
        reason: '工作表 ${sheets[i]} 的默认表名不对',
      );
    }

    // 第 1 步 → 第 2 步：建 3 张空表并进入关系步骤；种子最多 10 张。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 60);
    expect(find.byType(RelationDesigner), findsOneWidget);
    final designer = tester.widget<RelationDesigner>(
      find.byType(RelationDesigner),
    );
    expect(designer.maxTables, 10);
    expect(designer.initialTables.length, sheets.length);
    final names = await tableNames(tester);
    for (final sheet in sheets) {
      final table = sanitizeIdentifier(sheet);
      expect(names, contains(table));
      expect(await countRows(tester, table), 0, reason: '关系步骤时表应为空');
    }

    await tester.tap(primaryButton()); // 下一步：导入数据
    await settle(tester, rounds: 4);
    await tester.tap(primaryButton()); // 开始导入
    final failure = await runUntilImported(tester);
    expect(failure, isNull, reason: 'xlsx import failed: $failure');

    // 每个可见工作表都导入了数据（含中文表名）。
    for (final sheet in sheets) {
      final table = sanitizeIdentifier(sheet);
      expect(await countRows(tester, table), greaterThan(0));
    }
  });

  testWidgets('State 测试钩子：注入文件 → 工作表与字段 → 建空表 → 导入数据', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final csvPath = await tester.runAsync(
      () => writeFile('hook_people.csv', 'id,name\n1,Ada\n2,Bob\n3,Cy\n'),
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = GlobalKey<QuickCreateTableWizardState>();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Btn(
              'open-hook',
              onPressed: () => showQuickCreateTableWizard(
                context,
                database: 'main',
                notice: notice,
                stateKey: stateKey,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-hook'));
    await settle(tester, rounds: 6);

    final state = stateKey.currentState;
    expect(state, isNotNull);
    expect(state!.stepForTest, 0);

    // 等价于用户在原生 picker 里选了 CSV。
    await tester.runAsync(() => state.loadFileForTest(csvPath!));
    await settle(tester, rounds: 16);
    expect(find.text('数据文件'), findsOneWidget);

    // 第 1 步 → 第 1 步（分析文件、生成字段）。
    await tester.runAsync(state.advanceForTest);
    await settle(tester, rounds: 24);
    expect(state.stepForTest, 1);
    expect(state.plannedTableNamesForTest, <String>['hook_people']);
    expect(
      find.byKey(const ValueKey<String>('quick-table-name-0')),
      findsOneWidget,
    );

    // 字段 → 建空表 + 建立关联（第 2 步）。
    await tester.runAsync(state.advanceForTest);
    await settle(tester, rounds: 24);
    expect(state.stepForTest, 2);
    expect(state.allTablesCreatedForTest, isTrue);
    expect(state.createdTablesForTest, <String>['hook_people']);
    expect(await countRows(tester, 'hook_people'), 0);

    // 关系 → 导入数据（第 3 步）。
    await tester.runAsync(state.advanceForTest);
    await settle(tester, rounds: 4);
    expect(state.stepForTest, 3);

    await tester.runAsync(state.advanceForTest); // 开始导入
    await settle(tester, rounds: 24);
    expect(state.importsDoneForTest, isTrue);
    expect(await countRows(tester, 'hook_people'), 3);
  });

  testWidgets('类型下拉：中文说人话，英文显示 SQL 类型', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final csvPath = await tester.runAsync(
      () => writeFile('typed.csv', 'id,name\n1,Alice\n2,Bob\n'),
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    addTearDown(() => I18n.setLang(AppLang.zh));
    final stateKey = GlobalKey<QuickCreateTableWizardState>();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Btn(
              'open-typed',
              onPressed: () => showQuickCreateTableWizard(
                context,
                database: 'main',
                notice: notice,
                initialPath: csvPath,
                stateKey: stateKey,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-typed'));
    await settle(tester, rounds: 18);
    final state = stateKey.currentState!;
    await tester.runAsync(state.advanceForTest);
    await settle(tester, rounds: 24);
    expect(state.stepForTest, 1);
    // 中文界面：类型控件说人话，不再直接显示 SQL 关键字。
    expect(find.text('整数'), findsWidgets);
    expect(find.text('文本'), findsWidgets);
    // 英文界面：回到原始 SQL 类型。
    I18n.setLang(AppLang.en);
    await settle(tester, rounds: 6);
    expect(find.text('INTEGER'), findsWidgets);
    expect(find.text('TEXT'), findsWidgets);
  });

  testWidgets('无主键表：提示 + 一键自增 id 主键 + 导入时数据库生成 id', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final csvPath = await tester.runAsync(
      () => writeFile(
        // 第一列故意重复：Rust 对「首列且值唯一」会给 primary_candidate，
        // 重复值才能构造出「源文件没有主键」的场景。
        'nopk.csv',
        'name,score\nAda,9.5\nAda,8\n',
      ),
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    await pumpWizard(tester, csvPath!, notice);
    await settle(tester, rounds: 16);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);

    // 第 1 步：醒目提示 + 一键补主键按钮。
    expect(find.textContaining('所有表都没有主键'), findsOneWidget);
    expect(find.textContaining('未设置主键'), findsWidgets);
    expect(find.text('添加自增 id 主键'), findsOneWidget);
    final state = tester.state<QuickCreateTableWizardState>(
      find.byType(QuickCreateTableWizard),
    );
    expect(
      state.plansForTest.single.columns.any((column) => column.primary),
      isFalse,
    );

    await tester.tap(find.byKey(const ValueKey<String>('quick-add-pk-0')));
    await settle(tester, rounds: 2);
    final plan = state.plansForTest.single;
    expect(plan.columns.first.name, 'id');
    expect(plan.columns.first.generated, isTrue);
    expect(plan.columns.first.primary, isTrue);
    expect(plan.columns.where((column) => column.primary).length, 1);
    expect(find.textContaining('所有表都没有主键'), findsNothing);

    // 第 1→2 步：建空表并进入关系步骤（已有主键，画布上方不再提示）。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 30);
    expect(find.byType(RelationDesigner), findsOneWidget);
    expect(find.textContaining('请返回工作表与字段设置主键'), findsNothing);
    expect(await tableNames(tester), contains('nopk'));
    expect(await countRows(tester, 'nopk'), 0);

    // 第 3 步：导入；generated id 不参与 mapping，由数据库生成。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 4);
    await tester.tap(primaryButton());
    final failure = await runUntilImported(tester);
    expect(failure, isNull, reason: 'nopk import failed: $failure');
    expect(await countRows(tester, 'nopk'), 2);
    final ddl = await tableDdl(tester, 'nopk');
    expect(ddl.toUpperCase(), contains('AUTOINCREMENT'));
    final ids = await queryRows(tester, 'SELECT id FROM "nopk" ORDER BY id;');
    expect(ids.map((row) => (row as List).first).toList(), <int>[1, 2]);

    await tester.tap(primaryButton()); // 完成
    await settle(tester, rounds: 6);
    expect(find.byType(QuickCreateTableWizard), findsNothing);
    expect(notice.message, contains('已创建 1 张表'));
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('取消原主键后出现提示；一键 id 会取消原主键', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final csvPath = await tester.runAsync(
      () => writeFile('pkreset.csv', 'id,name\n1,Ada\n2,Bob\n'),
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    await pumpWizard(tester, csvPath!, notice);
    await settle(tester, rounds: 16);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);
    // schema 识别出了 id 主键：此时没有提示。
    expect(find.textContaining('未设置主键'), findsNothing);

    // 用户取消原主键 → 提示立即出现。
    await tester.tap(find.byKey(const ValueKey<String>('quick-col-pk-0-0')));
    await settle(tester, rounds: 2);
    expect(find.textContaining('未设置主键'), findsWidgets);
    final state = tester.state<QuickCreateTableWizardState>(
      find.byType(QuickCreateTableWizard),
    );
    expect(
      state.plansForTest.single.columns.any((column) => column.primary),
      isFalse,
    );

    // 一键补 id：原 id 取消主键，生成列成为唯一主键（名字避免重复 → id_2）。
    await tester.tap(find.byKey(const ValueKey<String>('quick-add-pk-0')));
    await settle(tester, rounds: 2);
    final plan = state.plansForTest.single;
    expect(plan.columns.first.name, 'id_2');
    expect(plan.columns.first.generated, isTrue);
    expect(plan.columns.first.primary, isTrue);
    expect(plan.columns[1].name, 'id');
    expect(plan.columns[1].primary, isFalse);
    expect(plan.columns.where((column) => column.primary).length, 1);
    expect(find.textContaining('未设置主键'), findsNothing);

    // 建表 + 导入：原始 id 列来自文件，生成 id_2 由数据库生成。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 30);
    expect(find.byType(RelationDesigner), findsOneWidget);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 4);
    await tester.tap(primaryButton());
    final failure = await runUntilImported(tester);
    expect(failure, isNull, reason: 'pkreset import failed: $failure');
    expect(await countRows(tester, 'pkreset'), 2);
    final ids = await queryRows(
      tester,
      'SELECT id FROM "pkreset" ORDER BY id;',
    );
    expect(ids.map((row) => (row as List).first).toList(), <int>[1, 2]);
    final generatedIds = await queryRows(
      tester,
      'SELECT id_2 FROM "pkreset" ORDER BY id_2;',
    );
    expect(generatedIds.map((row) => (row as List).first).toList(), <int>[
      1,
      2,
    ]);

    await tester.tap(primaryButton()); // 完成
    await settle(tester, rounds: 6);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('取消生成列的主键：降级为普通列且提示重新出现', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final csvPath = await tester.runAsync(
      () => writeFile('pkdowngrade.csv', 'name\nAda\nAda\n'),
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await pumpWizardWithKey(tester, csvPath!, notice);
    await settle(tester, rounds: 16);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);

    // 先一键补 id 主键。
    await tester.tap(find.byKey(const ValueKey<String>('quick-add-pk-0')));
    await settle(tester, rounds: 2);
    var state = stateKey.currentState!;
    final generated = state.plansForTest.single.columns.first;
    expect(generated.generated, isTrue);
    expect(generated.primary, isTrue);
    expect(find.textContaining('未设置主键'), findsNothing);

    // 用户又取消了生成列的主键：列保留但降级为普通可空列，提示重新出现。
    await tester.tap(find.byKey(const ValueKey<String>('quick-col-pk-0-0')));
    await settle(tester, rounds: 2);
    state = stateKey.currentState!;
    final downgraded = state.plansForTest.single.columns.first;
    expect(downgraded.name, 'id');
    expect(downgraded.generated, isTrue);
    expect(downgraded.primary, isFalse);
    expect(downgraded.nullable, isTrue, reason: '生成列没有源数据，取消主键后必须允许为空');
    expect(
      state.plansForTest.single.columns.any((column) => column.primary),
      isFalse,
    );
    expect(find.textContaining('所有表都没有主键'), findsOneWidget);

    // 载荷侧行为：保留列但不自增。
    final body = createTableBodyFor(state.plansForTest.single, 'sqlite');
    final idColumn = (body['columns'] as List).first as Map;
    expect(idColumn['primary'], isFalse);
    expect(idColumn['auto_increment'], isFalse);
    expect(idColumn['nullable'], isTrue);
  });

  testWidgets('建表失败：留在工作表与字段步骤并显示错误', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final csvPath = await tester.runAsync(
      () => writeFile('failcreate.csv', 'id,name\n1,Ada\n'),
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await pumpWizardWithKey(tester, csvPath!, notice);
    await settle(tester, rounds: 16);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);

    // 把表名改成一个已存在的表，让 CREATE TABLE 真的失败。
    await setFieldText(tester, 'quick-table-name-0', 'failcreate_conflict');
    await tester.runAsync(
      () => Api.instance.query(
        'CREATE TABLE failcreate_conflict (x INTEGER);',
        'main',
      ),
    );
    await tester.tap(primaryButton());
    await settle(tester, rounds: 16);

    final state = stateKey.currentState!;
    expect(state.stepForTest, 1, reason: '建表失败必须停在工作表与字段步骤');
    expect(find.byType(RelationDesigner), findsNothing);
    expect(state.errorForTest, isNotNull);
    expect(state.errorForTest!, contains('failcreate_conflict'));
    expect(find.text('源列名'), findsOneWidget);
    expect(state.createdTablesForTest, isEmpty);
  });

  testWidgets('只有部分表没有主键：全局提示点名具体表，仍可继续', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fixture = _spreadsheetMl(<String, List<List<Object?>>>{
      'PkSheet': <List<Object?>>[
        <Object?>['id', 'label'],
        <Object?>[1, 'a'],
        <Object?>[2, 'b'],
      ],
      'NoPkSheet': <List<Object?>>[
        // 两列都重复 → 新后端不会把「唯一整数列」选成主键候选。
        <Object?>['name', 'score'],
        <Object?>['Ada', 1],
        <Object?>['Ada', 1],
      ],
    });
    final path = await tester.runAsync(() => writeFile('mixedpk.xls', fixture));
    final capability = await tester.runAsync(
      () => Api.instance.importInspect(path!),
    );
    final sheets = capability?['sheets'];
    if (sheets is! List || sheets.isEmpty) {
      markTestSkipped('rust-excel inspect.sheets 契约未就绪');
      return;
    }

    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await pumpWizardWithKey(tester, path!, notice);
    await settle(tester, rounds: 16);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 40);

    // 部分表缺主键：提示点名 NoPkSheet，且不把有主键的 PkSheet 也算进去。
    final warnings = tester
        .widgetList<AlertBox>(find.byType(AlertBox))
        .where((box) => box.message.contains('以下表没有主键'))
        .toList();
    expect(warnings, hasLength(1), reason: '应出现一条部分表缺主键的全局提示');
    // 提示只点名缺主键的那张表（精确匹配结尾，避免 PkSheet 是 NoPkSheet 的
    // 子串导致误判）。
    expect(warnings.single.message, endsWith('：NoPkSheet'));
    expect(stateKey.currentState!.plansForTest.length, 2);
    expect(
      stateKey.currentState!.plansForTest[0].columns.any(
        (column) => column.primary,
      ),
      isTrue,
    );
    expect(
      stateKey.currentState!.plansForTest[1].columns.any(
        (column) => column.primary,
      ),
      isFalse,
    );

    // 只提醒不阻断：仍然能建空表并进入关系步骤。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 40);
    expect(find.byType(RelationDesigner), findsOneWidget);
    expect(find.textContaining('没有主键，不能作为外键的被引用表'), findsWidgets);
    expect(stateKey.currentState!.createdTablesWithoutPrimaryForTest, <String>[
      'NoPkSheet',
    ]);

    // 关闭（只建了空表）→ 第 53 轮 P2-9：先三选一确认，保留已建表并关闭，
    // 再明确提示未导入数据。
    await tester.tap(find.text('关闭'));
    await settle(tester, rounds: 6);
    expect(find.text('关闭向导'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('quick-close-keep')));
    await settle(tester, rounds: 6);
    expect(notice.message, contains('未导入数据'));
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('无主键表在关系步骤提示；返回字段会删除已建空表', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final csvPath = await tester.runAsync(
      () => writeFile(
        // 重复的姓名：避免首列被识别成唯一主键候选。
        'backfields.csv',
        'name\nAda\nAda\n',
      ),
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await pumpWizardWithKey(tester, csvPath!, notice);
    await settle(tester, rounds: 16);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);

    // 建空表 → 关系步骤：没有主键的表在画布上方提示 + 返回按钮。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 30);
    var state = stateKey.currentState!;
    expect(state.stepForTest, 2);
    expect(find.byType(RelationDesigner), findsOneWidget);
    expect(find.textContaining('没有主键，不能作为外键的被引用表'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('quick-relations-back')),
      findsOneWidget,
    );
    expect(state.createdTablesWithoutPrimaryForTest, <String>['backfields']);
    expect(await tableNames(tester), contains('backfields'));

    // 返回字段步骤：先确认（会删除本次创建的表），再删除空表。
    await tester.tap(
      find.byKey(const ValueKey<String>('quick-relations-back')),
    );
    await settle(tester, rounds: 4);
    expect(find.textContaining('删除本次已创建的'), findsOneWidget);
    await tester.tap(find.text('删除并返回'));
    await settle(tester, rounds: 20);
    state = stateKey.currentState!;
    expect(state.stepForTest, 1);
    expect(find.text('源列名'), findsOneWidget);
    expect(await tableNames(tester), isNot(contains('backfields')));
    expect(state.createdTablesForTest, isEmpty);

    // 补上自增 id 后可以重新建表并进入关系步骤。
    await tester.tap(find.byKey(const ValueKey<String>('quick-add-pk-0')));
    await settle(tester, rounds: 2);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 30);
    state = stateKey.currentState!;
    expect(state.stepForTest, 2);
    expect(await tableNames(tester), contains('backfields'));
    expect(state.createdTablesWithoutPrimaryForTest, isEmpty);

    // 关闭（只建了空表 → 三选一确认 → 保留已建表并关闭，提示未导入）。
    await tester.tap(find.text('关闭'));
    await settle(tester, rounds: 6);
    expect(find.text('关闭向导'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('quick-close-keep')));
    await settle(tester, rounds: 6);
    expect(notice.message, contains('未导入数据'));
    await tester.pump(const Duration(seconds: 4));
  });

  // =====================================================================
  // 第 52 轮：外键数据预检 / 父表优先导入 / 外键失败恢复
  // =====================================================================

  /// 两张表、外键数据：父表 id = 1,2；子表 pid = 9,8（默认不匹配）。
  Future<String> writeFkFixture(
    WidgetTester tester, {
    String name = 'fkpre.xls',
    String parentName = 'ParSheet',
    String childName = 'ChiSheet',
    List<Object?> childValues = const <Object?>[9, 8],
    List<Object?> parentValues = const <Object?>[1, 2],
  }) async {
    final fixture = _spreadsheetMl(<String, List<List<Object?>>>{
      parentName: <List<Object?>>[
        <Object?>['id', 'label'],
        for (final value in parentValues) <Object?>[value, 'p'],
      ],
      childName: <List<Object?>>[
        <Object?>['pid', 'note'],
        for (final value in childValues) <Object?>[value, 'c'],
      ],
    });
    return (await tester.runAsync(() => writeFile(name, fixture)))!;
  }

  QuickForeignKey fkParChi({
    String name = 'fk_chi_par',
    String parentTable = 'ParSheet',
    String childTable = 'ChiSheet',
  }) => QuickForeignKey(
    name: name,
    childTable: childTable,
    columns: <String>['pid'],
    refTable: parentTable,
    refColumns: <String>['id'],
  );

  testWidgets('外键预检不匹配：返回建立关联，已建表保留', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final path = await writeFkFixture(tester);
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await pumpWizardWithKey(tester, path, notice);
    await settle(tester, rounds: 16);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);

    final state = stateKey.currentState!;
    state.setForeignKeysForTest(<QuickForeignKey>[fkParChi()]);

    // 先建空表 → 关系步骤。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 40);
    expect(state.stepForTest, 2);

    // 下一步：导入数据 → 外键样本比对发现 2/2 不匹配，弹确认框。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);
    expect(find.textContaining('外键数据可能不匹配'), findsOneWidget);
    expect(find.textContaining('ChiSheet.pid → ParSheet.id'), findsWidgets);
    expect(find.textContaining('2/2'), findsOneWidget);
    expect(find.textContaining('示例值'), findsOneWidget);

    // 返回建立关联：仍在第 2 步，已建表保留，未导入任何数据。
    await tester.tap(find.byKey(const ValueKey<String>('precheck-back')));
    await settle(tester, rounds: 12);
    expect(state.stepForTest, 2);
    expect(find.textContaining('外键数据可能不匹配'), findsNothing);
    expect(
      await tableNames(tester),
      containsAll(<String>['ParSheet', 'ChiSheet']),
    );
    expect(await countRows(tester, 'ChiSheet'), 0);
  });

  testWidgets('外键预检：仍然继续导入 → 进入第 3 步且不重复弹框', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final path = await writeFkFixture(
      tester,
      name: 'fkcontinue.xls',
      parentName: 'ParB',
      childName: 'ChiB',
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await pumpWizardWithKey(tester, path, notice);
    await settle(tester, rounds: 16);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);
    final state = stateKey.currentState!;
    state.setForeignKeysForTest(<QuickForeignKey>[
      fkParChi(name: 'fk_chi_b', parentTable: 'ParB', childTable: 'ChiB'),
    ]);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 40);
    expect(state.stepForTest, 2);

    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);
    expect(find.textContaining('外键数据可能不匹配'), findsOneWidget);
    // 安全动作「返回建立关联修改」必须是主按钮，冒险的「仍然继续导入」不是。
    expect(
      tester
          .widget<Btn>(find.byKey(const ValueKey<String>('precheck-back')))
          .primary,
      isTrue,
    );
    expect(
      tester
          .widget<Btn>(find.byKey(const ValueKey<String>('precheck-continue')))
          .primary,
      isFalse,
    );
    await tester.tap(find.byKey(const ValueKey<String>('precheck-continue')));
    await settle(tester, rounds: 12);
    expect(state.stepForTest, 3);
    expect(find.textContaining('外键数据可能不匹配'), findsNothing);

    // 「开始导入」前会再次预检，但同一组外键 + 数据已确认过 → 不再弹框。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 8);
    expect(find.textContaining('外键数据可能不匹配'), findsNothing);
    final failure = await runUntilImported(tester);
    expect(failure, isNull, reason: 'continue import failed: $failure');
    expect(state.importsDoneForTest, isTrue);
    expect(await countRows(tester, 'ParB'), 2);
    expect(await countRows(tester, 'ChiB'), 2);
  });

  testWidgets('外键预检：父表引用 generated 自增列 → 高风险提示', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fixture = _spreadsheetMl(<String, List<List<Object?>>>{
      'GenPar': <List<Object?>>[
        <Object?>['name'],
        <Object?>['Ada'],
        <Object?>['Ada'],
      ],
      'GenChi': <List<Object?>>[
        <Object?>['rid'],
        <Object?>[1],
        <Object?>[2],
      ],
    });
    final path = (await tester.runAsync(
      () => writeFile('fkgen.xls', fixture),
    ))!;
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await pumpWizardWithKey(tester, path, notice);
    await settle(tester, rounds: 16);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 30);

    // 父表没有主键：补一个自增 id，子表外键指向它 → 源文件无法核对。
    await tester.tap(find.byKey(const ValueKey<String>('quick-add-pk-0')));
    await settle(tester, rounds: 2);
    final state = stateKey.currentState!;
    expect(state.plansForTest.first.columns.first.generated, isTrue);
    state.setForeignKeysForTest(<QuickForeignKey>[
      QuickForeignKey(
        name: 'fk_gen_chi',
        childTable: 'GenChi',
        columns: <String>['rid'],
        refTable: 'GenPar',
        refColumns: <String>['id'],
      ),
    ]);

    await tester.tap(primaryButton());
    await settle(tester, rounds: 40);
    expect(state.stepForTest, 2);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);
    expect(find.textContaining('外键数据可能不匹配'), findsOneWidget);
    expect(find.textContaining('高风险'), findsWidgets);
    expect(find.textContaining('自动生成'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey<String>('precheck-back')));
    await settle(tester, rounds: 10);
    expect(state.stepForTest, 2);
  });

  /// 走到第 3 步（两张表、外键样本匹配，无预检弹框）。
  Future<GlobalKey<QuickCreateTableWizardState>> reachImportStep(
    WidgetTester tester,
    String path,
    Notice notice, {
    String fkName = 'fk_chi_par',
    String parentTable = 'ParSheet',
    String childTable = 'ChiSheet',
    String childColumn = 'pid',
    String refColumn = 'id',
  }) async {
    final stateKey = await pumpWizardWithKey(tester, path, notice);
    await settle(tester, rounds: 16);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);
    final state = stateKey.currentState!;
    state.setForeignKeysForTest(<QuickForeignKey>[
      QuickForeignKey(
        name: fkName,
        childTable: childTable,
        columns: <String>[childColumn],
        refTable: parentTable,
        refColumns: <String>[refColumn],
      ),
    ]);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 40);
    expect(state.stepForTest, 2);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);
    expect(state.stepForTest, 3);
    return stateKey;
  }

  testWidgets('外键失败面板：解析约束名并可返回建立关联（保留已建表）', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final path = await writeFkFixture(
      tester,
      name: 'fkfail.xls',
      parentName: 'ParD',
      childName: 'ChiD',
      childValues: const <Object?>[1, 2],
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await reachImportStep(
      tester,
      path,
      notice,
      fkName: 'fk_d',
      parentTable: 'ParD',
      childTable: 'ChiD',
    );
    final state = stateKey.currentState!;

    state.setFkFailureForTest(
      '批量插入失败: Cannot add or update a child row: a foreign key constraint '
      'fails (web.ChiD, CONSTRAINT fk_d FOREIGN KEY (pid) '
      'REFERENCES ParD (id) ON DELETE CASCADE) (错误码 23000)',
      table: 'ChiD',
    );
    await settle(tester, rounds: 4);
    expect(find.textContaining('外键约束导致导入失败'), findsWidgets);
    expect(find.textContaining('ChiD.pid → ParD.id'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('fk-back-relations')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('fk-drop-and-retry')),
      findsOneWidget,
    );
    expect(state.fkFailureForTest?.constraintName, 'fk_d');
    expect(state.fkFailurePathForTest, 'ChiD.pid → ParD.id');

    await tester.tap(find.byKey(const ValueKey<String>('fk-back-relations')));
    await settle(tester, rounds: 10);
    expect(state.stepForTest, 2);
    expect(state.fkFailureForTest, isNull);
    expect(await tableNames(tester), containsAll(<String>['ParD', 'ChiD']));
    expect(find.byType(RelationDesigner), findsOneWidget);
  });

  testWidgets('外键失败面板：删除该外键并重试导入', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final path = await writeFkFixture(
      tester,
      name: 'fkdrop.xls',
      parentName: 'ParE',
      childName: 'ChiE',
      childValues: const <Object?>[1, 2],
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await reachImportStep(
      tester,
      path,
      notice,
      fkName: 'fk_e',
      parentTable: 'ParE',
      childTable: 'ChiE',
    );
    final state = stateKey.currentState!;

    state.setFkFailureForTest(
      'a foreign key constraint fails (web.ChiE, CONSTRAINT fk_e '
      'FOREIGN KEY (pid) REFERENCES ParE (id)) (错误码 23000)',
      table: 'ChiE',
    );
    await settle(tester, rounds: 4);

    String? capturedTable;
    Json? capturedBody;
    state.setAlterTableOverrideForTest((table, body) async {
      capturedTable = table;
      capturedBody = body;
      return <String, dynamic>{'ok': true};
    });
    await tester.tap(find.byKey(const ValueKey<String>('fk-drop-and-retry')));
    await settle(tester, rounds: 6);
    expect(find.textContaining('删除外键'), findsOneWidget);
    await tester.tap(find.text('删除并重试'));
    await settle(tester, rounds: 8);

    expect(capturedTable, 'ChiE');
    expect((capturedBody!['drop_foreign_keys'] as List).first, 'fk_e');
    final failure = await runUntilImported(tester);
    expect(failure, isNull, reason: 'retry after drop failed: $failure');
    expect(state.importsDoneForTest, isTrue);
    expect(await countRows(tester, 'ParE'), 2);
    expect(await countRows(tester, 'ChiE'), 2);
  });

  testWidgets('父表导入失败：子表标记已跳过，不再继续插入', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final path = await writeFkFixture(
      tester,
      name: 'fkskip.xls',
      parentName: 'ParF',
      childName: 'ChiF',
      childValues: const <Object?>[1, 2],
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await reachImportStep(
      tester,
      path,
      notice,
      fkName: 'fk_f',
      parentTable: 'ParF',
      childTable: 'ChiF',
    );
    final state = stateKey.currentState!;

    // 父表优先：ParF 在 ChiF 之前。
    expect(state.importOrderForTest, <String>['ParF', 'ChiF']);

    // 外部把父表删掉，模拟父表导入失败。
    await tester.runAsync(() => Api.instance.dropTable('main', 'ParF'));
    await tester.tap(primaryButton());

    for (var i = 0; i < 160; i++) {
      await settle(tester, rounds: 1);
      if (find.textContaining('父表 ParF 未导入成功，已跳过').evaluate().isNotEmpty) {
        break;
      }
    }
    expect(find.textContaining('父表 ParF 未导入成功，已跳过'), findsOneWidget);
    expect(find.text('已跳过'), findsWidgets);
    expect(state.importsDoneForTest, isFalse);
    expect(await countRows(tester, 'ChiF'), 0);
  });

  // =====================================================================
  // 第 52 轮：自增 / 回退 / 部分写入重试 / 每工作表表头 / 中文失败横幅
  // =====================================================================

  testWidgets('自增列：业务整数主键默认不自增，勾选后才自增', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final csvPath = await tester.runAsync(
      () => writeFile('autoflag.csv', 'id,name\n1,Ada\n2,Bob\n'),
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await pumpWizardWithKey(tester, csvPath!, notice);
    await settle(tester, rounds: 16);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);

    final state = stateKey.currentState!;
    final plan = state.plansForTest.single;
    final idColumn = plan.columns.first;
    expect(idColumn.name, 'id');
    expect(idColumn.primary, isTrue);
    expect(idColumn.autoIncrement, isFalse, reason: '源文件已经提供 id 值，不能由数据库代填');

    // 字段页新增「自增」列：主键且整数时可勾选，非主键禁用。
    expect(find.text('自增'), findsOneWidget);
    final autoCheckbox = find.byKey(
      const ValueKey<String>('quick-col-auto-0-0'),
    );
    expect(autoCheckbox, findsOneWidget);
    expect(tester.widget<CheckBox>(autoCheckbox).value, isFalse);
    expect(tester.widget<CheckBox>(autoCheckbox).enabled, isTrue);
    final nameCheckbox = find.byKey(
      const ValueKey<String>('quick-col-auto-0-1'),
    );
    expect(
      tester.widget<CheckBox>(nameCheckbox).enabled,
      isFalse,
      reason: '非主键列的「自增」应禁用',
    );

    await tester.tap(autoCheckbox);
    await settle(tester, rounds: 2);
    expect(state.plansForTest.single.columns.first.autoIncrement, isTrue);
    final body = createTableBodyFor(state.plansForTest.single, 'sqlite');
    expect(((body['columns'] as List).first as Map)['auto_increment'], isTrue);

    // 取消主键后自增也关闭。
    await tester.tap(find.byKey(const ValueKey<String>('quick-col-pk-0-0')));
    await settle(tester, rounds: 2);
    expect(state.plansForTest.single.columns.first.autoIncrement, isFalse);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('步骤回退：导入 → 建立关联不删表；建立关联 → 字段先确认并反序删表', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final path = await writeFkFixture(
      tester,
      name: 'fkback.xls',
      parentName: 'ParBk',
      childName: 'ChiBk',
      childValues: const <Object?>[1, 2],
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await reachImportStep(
      tester,
      path,
      notice,
      fkName: 'fk_back',
      parentTable: 'ParBk',
      childTable: 'ChiBk',
    );
    final state = stateKey.currentState!;
    expect(state.stepForTest, 3);

    final back = find.byKey(const ValueKey<String>('quick-create-back'));
    expect(back, findsOneWidget, reason: '所有步骤都应该有「上一步」');

    // 导入数据 → 建立关联：只切步骤，表和数据都保留。
    await tester.tap(back);
    await settle(tester, rounds: 6);
    expect(state.stepForTest, 2);
    expect(find.byType(RelationDesigner), findsOneWidget);
    expect(await tableNames(tester), containsAll(<String>['ParBk', 'ChiBk']));

    // 建立关联 → 工作表与字段：确认后按外键反序删表（先子表后父表）。
    final dropped = <String>[];
    state.setDropTableOverrideForTest((table) async {
      dropped.add(table);
      return <String, dynamic>{'ok': true};
    });
    await tester.tap(back);
    await settle(tester, rounds: 4);
    expect(find.textContaining('删除本次已创建的'), findsOneWidget);
    await tester.tap(find.text('删除并返回'));
    await settle(tester, rounds: 10);
    expect(dropped, <String>[
      'ChiBk',
      'ParBk',
    ], reason: '父表先删会被 MySQL 拒绝，必须先删子表');
    expect(state.stepForTest, 1);
    expect(state.createdTablesForTest, isEmpty);
    expect(state.foreignKeysForTest, isEmpty);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('返回字段删表失败：中文横幅 + 清理并重试', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final path = await writeFkFixture(
      tester,
      name: 'fkdroperr.xls',
      parentName: 'ParGd',
      childName: 'ChiGd',
      childValues: const <Object?>[1, 2],
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await pumpWizardWithKey(tester, path, notice);
    await settle(tester, rounds: 16);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 40);
    final state = stateKey.currentState!;
    expect(state.stepForTest, 2);

    var parAttempts = 0;
    state.setDropTableOverrideForTest((table) async {
      if (table == 'ParGd') {
        parAttempts++;
        if (parAttempts == 1) throw StateError('drop blocked by test');
      }
      return <String, dynamic>{'ok': true};
    });
    await tester.tap(find.byKey(const ValueKey<String>('quick-create-back')));
    await settle(tester, rounds: 4);
    await tester.tap(find.text('删除并返回'));
    await settle(tester, rounds: 10);

    // 删除失败：留在关系步骤，横幅说明残留表，并给「清理并重试」。
    expect(state.stepForTest, 2, reason: '删表失败必须留在关系步骤');
    expect(state.errorForTest, contains('未能删除'));
    expect(state.pendingDropTablesForTest, <String>['ParGd']);
    expect(state.createdTablesForTest, <String>['ParGd']);
    expect(
      find.byKey(const ValueKey<String>('quick-drop-retry')),
      findsOneWidget,
    );

    // 再次清理成功后回到字段步骤。
    await tester.tap(find.byKey(const ValueKey<String>('quick-drop-retry')));
    await settle(tester, rounds: 10);
    expect(state.stepForTest, 1);
    expect(state.pendingDropTablesForTest, isEmpty);
    expect(state.createdTablesForTest, isEmpty);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('部分写入的表：主按钮「重试失败的表」，确认后先 truncate 再导入', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final csvPath = await tester.runAsync(
      () => writeFile('partialretry.csv', 'id,name\n1,Ada\n2,Bob\n'),
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await pumpWizardWithKey(tester, csvPath!, notice);
    await settle(tester, rounds: 16);
    final state = stateKey.currentState!;
    await tester.runAsync(state.advanceForTest);
    await settle(tester, rounds: 24);
    await tester.runAsync(state.advanceForTest);
    await settle(tester, rounds: 30);
    await tester.runAsync(state.advanceForTest);
    await settle(tester, rounds: 6);
    expect(state.stepForTest, 3);

    // 模拟「导入了 1 行后失败」：主按钮必须变成可点的「重试失败的表」。
    state.markFormPartiallyFailedForTest(0, rowsInserted: 1);
    await settle(tester, rounds: 4);
    expect(state.primaryLabelForTest, '重试失败的表');
    expect(state.primaryEnabledForTest, isTrue);
    expect(find.text('重试失败的表'), findsWidgets);

    final truncated = <String>[];
    state.setTruncateOverrideForTest((table) async {
      truncated.add(table);
      return <String, dynamic>{'ok': true};
    });
    await tester.tap(primaryButton());
    await settle(tester, rounds: 4);
    expect(find.textContaining('已经写入部分行'), findsOneWidget);
    await tester.tap(find.text('清空并重试'));
    await settle(tester, rounds: 30);
    expect(truncated, <String>['partialretry']);
    expect(state.importsDoneForTest, isTrue);
    expect(await countRows(tester, 'partialretry'), 2);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('每工作表表头判断：首行是数据的表不会被当成表头', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fixture = _spreadsheetMl(<String, List<List<Object?>>>{
      'WithHeader': <List<Object?>>[
        <Object?>['name', 'score'],
        <Object?>['Ada', 9.5],
        <Object?>['Bob', 8],
      ],
      'DataOnly': <List<Object?>>[
        <Object?>[1001, 'A'],
        <Object?>[1002, 'B'],
      ],
    });
    final path = await tester.runAsync(() => writeFile('headers.xls', fixture));
    final capability = await tester.runAsync(
      () => Api.instance.importInspect(path!),
    );
    final sheets = capability?['sheets'];
    if (sheets is! List || sheets.isEmpty) {
      markTestSkipped('rust-excel inspect.sheets 契约未就绪');
      return;
    }
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await pumpWizardWithKey(tester, path!, notice);
    await settle(tester, rounds: 16);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 40);

    final state = stateKey.currentState!;
    expect(state.stepForTest, 1);
    expect(state.plansForTest.length, 2);
    expect(state.plansForTest[0].header, isTrue);
    expect(state.plansForTest[1].header, isFalse, reason: '首行是数据的表应改回无表头');
    expect(state.plansForTest[1].columns.first.name, 'column_1');

    await tester.tap(primaryButton()); // 建空表 → 建立关联
    await settle(tester, rounds: 40);
    await tester.tap(primaryButton()); // 建立关联 → 导入数据
    await settle(tester, rounds: 4);
    await tester.tap(primaryButton()); // 开始导入
    final failure = await runUntilImported(tester);
    expect(
      failure,
      isNull,
      reason: 'header heal import failed: ${failure ?? ''}',
    );
    expect(await countRows(tester, 'WithHeader'), 2);
    expect(await countRows(tester, 'DataOnly'), 2);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('导入失败横幅：中文主文案 + 技术细节默认折叠', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final path = await writeFkFixture(
      tester,
      name: 'fkbanner.xls',
      parentName: 'ParBn',
      childName: 'ChiBn',
      childValues: const <Object?>[1, 2],
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await reachImportStep(
      tester,
      path,
      notice,
      fkName: 'fk_bn',
      parentTable: 'ParBn',
      childTable: 'ChiBn',
    );
    final state = stateKey.currentState!;
    const message =
        '批量插入失败: Cannot add or update a child row: a foreign key '
        'constraint fails (web.ChiBn, CONSTRAINT fk_bn FOREIGN KEY (pid) '
        'REFERENCES ParBn (id)) (错误码 23000)';
    state.setFkFailureForTest(message, table: 'ChiBn');
    await settle(tester, rounds: 4);

    expect(find.textContaining('导入失败：数据库外键约束拒绝'), findsWidgets);
    expect(find.text('技术细节'), findsOneWidget);
    // 默认折叠：原始 MySQL 英文错误不直接展示。
    expect(
      find.textContaining('Cannot add or update a child row'),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('quick-error-detail-toggle')),
    );
    await settle(tester, rounds: 2);
    expect(
      find.textContaining('Cannot add or update a child row'),
      findsWidgets,
    );
    expect(find.text('收起技术细节'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  // =====================================================================
  // 第 53 轮：主键显示/DDL 一致、重试不重复预检、删外键检查、关闭确认、术语表
  // =====================================================================

  testWidgets('主键整数列：字段页计划层就是主键类型（显示与 DDL 一致）', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final csvPath = await tester.runAsync(
      () => writeFile('pktype.csv', 'id,name\n1,Ada\n2,Bob\n'),
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await pumpWizardWithKey(tester, csvPath!, notice);
    await settle(tester, rounds: 16);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);

    final state = stateKey.currentState!;
    final plan = state.plansForTest.single;
    final id = plan.columns.first;
    expect(id.name, 'id');
    expect(id.primary, isTrue);
    // SQLite 的主键整数类型是 INTEGER（MySQL/PostgreSQL 为 BIGINT）；关键是
    // 计划层与 primarySqlTypeFor 的输出一致，字段页不再显示另一个类型。
    expect(id.sqlType, pkColumnTypeFor(AppState.instance.driver));
    expect(id.sqlType, primarySqlTypeFor(id, AppState.instance.driver));

    // 真实建表后的类型与计划层一致（不再出现 INT 显示 / BIGINT DDL 的割裂）。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 40);
    final types = await columnTypes(tester, 'pktype');
    expect(types.first.toUpperCase(), contains('INT'));
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('外键预检确认后导入失败：点重试不再重复弹预检框', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 父表没有 id 列（要补自增主键）→ 预检按高风险提示，确认弹框一定会出现。
    final fixture = _spreadsheetMl(<String, List<List<Object?>>>{
      'GenParR': <List<Object?>>[
        <Object?>['name'],
        // 两行同名 → Rust 不会把 name 当主键候选，父表真的没有主键。
        <Object?>['Ada'],
        <Object?>['Ada'],
      ],
      'GenChiR': <List<Object?>>[
        <Object?>['rid', 'note'],
        <Object?>[9, 'c'],
        <Object?>[8, 'c'],
      ],
    });
    final path = (await tester.runAsync(
      () => writeFile('fkretry.xls', fixture),
    ))!;
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await pumpWizardWithKey(tester, path, notice);
    await settle(tester, rounds: 16);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 30);
    final state = stateKey.currentState!;
    await tester.tap(find.byKey(const ValueKey<String>('quick-add-pk-0')));
    await settle(tester, rounds: 2);
    state.setForeignKeysForTest(<QuickForeignKey>[
      QuickForeignKey(
        name: 'fk_retry',
        childTable: 'GenChiR',
        columns: <String>['rid'],
        refTable: 'GenParR',
        refColumns: <String>['id'],
      ),
    ]);
    await tester.tap(primaryButton()); // 建空表 → 建立关联
    await settle(tester, rounds: 40);
    expect(state.stepForTest, 2);

    await tester.tap(primaryButton()); // 下一步：导入数据（触发预检）
    await settle(tester, rounds: 24);
    expect(find.textContaining('外键数据可能不匹配'), findsOneWidget);
    expect(find.textContaining('高风险'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey<String>('precheck-continue')));
    await settle(tester, rounds: 12);
    expect(state.stepForTest, 3);
    expect(find.textContaining('外键数据可能不匹配'), findsNothing);

    // 模拟真实导入时子表被外键拒绝 → 主按钮变成「重试失败的表」。
    state.setFkFailureForTest(
      'a foreign key constraint fails (web.GenChiR, CONSTRAINT fk_retry '
      'FOREIGN KEY (rid) REFERENCES GenParR (id)) (错误码 23000)',
      table: 'GenChiR',
    );
    await settle(tester, rounds: 4);
    expect(state.primaryLabelForTest, '重试失败的表');

    // 第 53 轮修复：外键集合没变，失败后点重试不应再弹预检确认框。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 10);
    expect(
      find.textContaining('外键数据可能不匹配'),
      findsNothing,
      reason: '同一组外键已经确认过，重试不应重复弹预检框',
    );
    final failure = await runUntilImported(tester);
    expect(failure, isNull, reason: 'retry after failure failed: $failure');
    expect(state.importsDoneForTest, isTrue);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('删除外键失败：中文前缀错误并保留外键失败面板', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final path = await writeFkFixture(
      tester,
      name: 'fkdropfail.xls',
      parentName: 'ParDf',
      childName: 'ChiDf',
      childValues: const <Object?>[1, 2],
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await reachImportStep(
      tester,
      path,
      notice,
      fkName: 'fk_df',
      parentTable: 'ParDf',
      childTable: 'ChiDf',
    );
    final state = stateKey.currentState!;
    state.setFkFailureForTest(
      'a foreign key constraint fails (web.ChiDf, CONSTRAINT fk_df '
      'FOREIGN KEY (pid) REFERENCES ParDf (id)) (错误码 23000)',
      table: 'ChiDf',
    );
    await settle(tester, rounds: 4);
    state.setAlterTableOverrideForTest((table, body) async {
      throw StateError('drop fk blocked by test');
    });
    await tester.tap(find.byKey(const ValueKey<String>('fk-drop-and-retry')));
    await settle(tester, rounds: 4);
    await tester.tap(find.text('删除并重试'));
    await settle(tester, rounds: 8);

    // 第 53 轮起底层走 alterTableChecked：失败会抛错并进入 catch，文案是中文
    // 前缀 + 数据库原始错误；失败面板保留，用户可以继续返回关系步骤。
    expect(state.errorForTest, contains('删除外键'));
    expect(state.errorForTest, contains('drop fk blocked by test'));
    expect(state.fkFailureForTest, isNotNull, reason: '删除失败要保留外键失败面板');
    expect(state.importsDoneForTest, isFalse);
    expect(
      find.byKey(const ValueKey<String>('fk-back-relations')),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('术语说明：header 按钮打开术语表并包含主键解释', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final csvPath = await tester.runAsync(
      () => writeFile('glossary.csv', 'id,name\n1,Ada\n'),
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    await pumpWizard(tester, csvPath!, notice);
    await settle(tester, rounds: 16);

    await tester.tap(find.byKey(const ValueKey<String>('quick-glossary')));
    await settle(tester, rounds: 6);
    expect(find.text('术语说明（说人话版）'), findsOneWidget);
    expect(find.text('主键'), findsWidgets);
    expect(find.text('PRIMARY KEY'), findsWidgets);
    expect(find.textContaining('唯一区分'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey<String>('glossary-close')));
    await settle(tester, rounds: 4);
    expect(find.text('术语说明（说人话版）'), findsNothing);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('关闭确认：取消留在向导；保留已建表并关闭不删表', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final csvPath = await tester.runAsync(
      () => writeFile('closekeep.csv', 'id,name\n1,Ada\n2,Bob\n'),
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await pumpWizardWithKey(tester, csvPath!, notice);
    await settle(tester, rounds: 16);
    await tester.tap(primaryButton()); // 工作表与字段
    await settle(tester, rounds: 24);
    await tester.tap(primaryButton()); // 建空表 → 建立关联
    await settle(tester, rounds: 40);
    final state = stateKey.currentState!;
    expect(state.stepForTest, 2);

    // 只建了空表就关闭：不再直接关掉，先弹三选一。
    await tester.tap(find.text('关闭'));
    await settle(tester, rounds: 6);
    expect(find.text('关闭向导'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('quick-close-keep')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('quick-close-drop')),
      findsOneWidget,
    );

    // 取消：留在向导、表还在。
    await tester.tap(find.byKey(const ValueKey<String>('quick-close-cancel')));
    await settle(tester, rounds: 4);
    expect(find.byType(QuickCreateTableWizard), findsOneWidget);
    expect(state.stepForTest, 2);
    expect(await tableNames(tester), contains('closekeep'));

    // 保留已建表并关闭：表保留，notice 明确说明没有导入数据。
    await tester.tap(find.text('关闭'));
    await settle(tester, rounds: 4);
    await tester.tap(find.byKey(const ValueKey<String>('quick-close-keep')));
    await settle(tester, rounds: 8);
    expect(find.byType(QuickCreateTableWizard), findsNothing);
    expect(notice.message, contains('未导入数据'));
    expect(await tableNames(tester), contains('closekeep'));
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('关闭确认：header X 也能删除本次已建表并关闭（反序删表）', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final path = await writeFkFixture(
      tester,
      name: 'fkclose.xls',
      parentName: 'ParCl',
      childName: 'ChiCl',
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await pumpWizardWithKey(tester, path, notice);
    await settle(tester, rounds: 16);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);
    final state = stateKey.currentState!;
    state.setForeignKeysForTest(<QuickForeignKey>[
      QuickForeignKey(
        name: 'fk_cl',
        childTable: 'ChiCl',
        columns: <String>['pid'],
        refTable: 'ParCl',
        refColumns: <String>['id'],
      ),
    ]);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 40);
    expect(state.stepForTest, 2);

    final dropped = <String>[];
    state.setDropTableOverrideForTest((table) async {
      dropped.add(table);
      return <String, dynamic>{'ok': true};
    });
    // header 的 X 与页脚「关闭」走同一个 _close。
    await tester.tap(find.byKey(const ValueKey<String>('quick-wizard-close')));
    await settle(tester, rounds: 6);
    expect(find.text('关闭向导'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('quick-close-drop')));
    await settle(tester, rounds: 10);

    expect(dropped, <String>['ChiCl', 'ParCl'], reason: '先删子表再删父表');
    expect(find.byType(QuickCreateTableWizard), findsNothing);
    expect(notice.message, contains('已删除本次创建的 2 张表'));
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('关闭确认：删除已建表失败时留在向导并显示残留表', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final csvPath = await tester.runAsync(
      () => writeFile('closedropfail.csv', 'id,name\n1,Ada\n'),
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await pumpWizardWithKey(tester, csvPath!, notice);
    await settle(tester, rounds: 16);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 40);
    final state = stateKey.currentState!;
    expect(state.stepForTest, 2);

    var attempts = 0;
    state.setDropTableOverrideForTest((table) async {
      attempts++;
      if (attempts == 1) throw StateError('drop blocked by test');
      return <String, dynamic>{'ok': true};
    });
    await tester.tap(find.text('关闭'));
    await settle(tester, rounds: 6);
    await tester.tap(find.byKey(const ValueKey<String>('quick-close-drop')));
    await settle(tester, rounds: 10);

    // 删表失败：向导不能关掉，显示残留表与「清理并重试」。
    expect(find.byType(QuickCreateTableWizard), findsOneWidget);
    expect(state.errorForTest, contains('未能删除'));
    expect(state.pendingDropTablesForTest, <String>['closedropfail']);
    expect(
      find.byKey(const ValueKey<String>('quick-drop-retry')),
      findsOneWidget,
    );

    // 再点「清理并重试」成功后残留列表清空，向导仍可继续操作。
    await tester.tap(find.byKey(const ValueKey<String>('quick-drop-retry')));
    await settle(tester, rounds: 10);
    expect(state.pendingDropTablesForTest, isEmpty);
    expect(state.createdTablesForTest, isEmpty);
    expect(find.byType(QuickCreateTableWizard), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('同名表预检：表名已存在时拦截进入建立关联', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 先真实建一张表；向导按文件名默认表名会自动避开重名（加 _2），所以把
    // 字段页的表名手改成一个已存在的名字，验证校验真的会拦截。
    await tester.runAsync(
      () => Api.instance.query(
        'CREATE TABLE taken_name (id INTEGER PRIMARY KEY);',
      ),
    );
    final csvPath = await tester.runAsync(
      () => writeFile('sameconflict.csv', 'id,name\n1,Ada\n'),
    );
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await pumpWizardWithKey(tester, csvPath!, notice);
    await settle(tester, rounds: 16);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);

    final state = stateKey.currentState!;
    expect(state.stepForTest, 1);
    await setFieldText(tester, 'quick-table-name-0', 'taken_name');
    await settle(tester, rounds: 2);
    expect(find.text('表名已存在'), findsOneWidget);
    expect(state.validationErrorForTest, contains('已存在'));
    expect(
      tester.widget<Btn>(primaryButton()).onPressed,
      isNull,
      reason: '表名已存在时不能进入建立关联',
    );

    // 改名后拦截解除，可以正常建表并进入关系步骤。
    await setFieldText(tester, 'quick-table-name-0', 'sameconflict_ok');
    await settle(tester, rounds: 2);
    expect(find.text('表名已存在'), findsNothing);
    expect(tester.widget<Btn>(primaryButton()).onPressed, isNotNull);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 40);
    expect(state.stepForTest, 2);
    expect(await tableNames(tester), contains('sameconflict_ok'));
    await tester.pump(const Duration(seconds: 4));
  });
}

/// 生成一份最小可用的 SpreadsheetML（Excel 2003 XML）工作簿文本。
///
/// rust-excel 用扩展名 .xls + mso-application 标记识别为 Excel；每个
/// Worksheet ss:Name=... 视为一张工作表，Cell 的 ss:Type 保留数字/布尔/文本
/// 类型，空 Cell 表示 NULL。
String _spreadsheetMl(Map<String, List<List<Object?>>> sheets) {
  String cell(Object? value) {
    if (value == null) return '<Cell/>';
    if (value is bool) {
      return '<Cell><Data ss:Type="Boolean">'
          '${value ? 1 : 0}'
          '</Data></Cell>';
    }
    if (value is num) {
      return '<Cell><Data ss:Type="Number">$value</Data></Cell>';
    }
    final text = value
        .toString()
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    return '<Cell><Data ss:Type="String">$text</Data></Cell>';
  }

  final buffer = StringBuffer()
    ..write('<?xml version="1.0"?>\n')
    ..write('<?mso-application progid="Excel.Sheet"?>\n')
    ..write('<Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet"\n')
    ..write(' xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">\n');
  sheets.forEach((name, rows) {
    buffer.write('<Worksheet ss:Name="$name"><Table>\n');
    for (final row in rows) {
      buffer.write('<Row>');
      for (final value in row) {
        buffer.write(cell(value));
      }
      buffer.write('</Row>\n');
    }
    buffer.write('</Table></Worksheet>\n');
  });
  buffer.write('</Workbook>\n');
  return buffer.toString();
}
