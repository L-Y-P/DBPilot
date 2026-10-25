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
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
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
  expect(leaks, isEmpty,
      reason: '英文模式「$where」仍有中文文案：${leaks.join(' | ')}');
}

QuickTablePlan planFor({
  String name = 'demo',
  String sheet = '',
  bool header = true,
  List<QuickColumn>? columns,
}) =>
    QuickTablePlan(
      name: name,
      sheet: sheet,
      header: header,
      columns: columns ??
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
      expect(sqlTypeFor('text', 'mysql', maxLength: 500), 'TEXT');
    });

    test('PostgreSQL', () {
      expect(sqlTypeFor('integer', 'postgres'), 'INTEGER');
      expect(sqlTypeFor('bigint', 'postgres'), 'BIGINT');
      expect(sqlTypeFor('decimal', 'postgres'), 'NUMERIC(18,2)');
      expect(sqlTypeFor('float', 'postgres'), 'DOUBLE PRECISION');
      expect(sqlTypeFor('boolean', 'postgres'), 'BOOLEAN');
      expect(sqlTypeFor('datetime', 'postgres'), 'TIMESTAMP');
      expect(sqlTypeFor('text', 'postgres', maxLength: 120), 'VARCHAR(120)');
      expect(sqlTypeFor('text', 'postgres', maxLength: 300), 'TEXT');
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
        expect(choices.toSet().length, choices.length, reason: 'must be unique');
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
        defaultTableNameFor('/tmp/book.xlsx',
            sheet: 'Sheet 1', multiSheet: true),
        'Sheet_1',
      );
      // 单工作表 Excel 仍按文件名命名。
      expect(
        defaultTableNameFor('/tmp/book.xlsx',
            sheet: 'Sheet1', multiSheet: false),
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
      expect(inferTypeFromValues(<Object?>['2024-01-02', '2024-03-04']), 'date');
      expect(
        inferTypeFromValues(
            <Object?>['2024-01-02 10:11:12', '2024-03-04 00:00:00']),
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
      expect(columns.map((c) => c.name).toList(),
          <String>['id', '姓名', 'score', 'created_at']);
      expect(columns[0].sqlType, 'INT');
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
      expect(columns.map((c) => c.name).toList(),
          <String>['id', 'name', 'flag', 'when']);
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
      final plain =
          readParamsFor(<String, dynamic>{'mode': 'line'}, skipRows: 0);
      expect(plain.containsKey('sheet'), isFalse);
      expect(plain['skip_rows'], 0);
    });

    test('fields 参数覆盖表头开关', () {
      final fields =
          fieldParamsFor(<String, dynamic>{'mode': 'excel'}, header: true);
      expect(fields['mode'], 'excel');
      expect(fields['header'], isTrue);
    });

    test('映射来源：有表头按列名，无表头按位置', () {
      final withHeader = planFor();
      final keyed = mappingParamsFor(withHeader);
      final keyedColumns = (keyed['columns'] as List).cast<Map>();
      expect(keyedColumns[0], <String, dynamic>{'column': 'id', 'source': 'id'});
      expect(
          keyedColumns[1], <String, dynamic>{'column': 'name', 'source': 'name'});
      expect(keyed['ignore_unknown'], isTrue);

      final withoutHeader = planFor(header: false);
      final positional = mappingParamsFor(withoutHeader);
      final positionalColumns = (positional['columns'] as List).cast<Map>();
      expect(
          positionalColumns[0], <String, dynamic>{'column': 'id', 'source': 0});
      expect(
          positionalColumns[1], <String, dynamic>{'column': 'name', 'source': 1});
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

    test('createTable body：整数主键自增、非整数主键只标 primary', () {
      final integerPlan = planFor();
      final mysqlBody = createTableBodyFor(integerPlan, 'mysql');
      final mysqlColumns = (mysqlBody['columns'] as List).cast<Map>();
      expect(mysqlColumns[0]['name'], 'id');
      expect(mysqlColumns[0]['type'], 'BIGINT');
      expect(mysqlColumns[0]['nullable'], isFalse);
      expect(mysqlColumns[0]['primary'], isTrue);
      expect(mysqlColumns[0]['auto_increment'], isTrue);

      final sqliteBody = createTableBodyFor(integerPlan, 'sqlite');
      expect(((sqliteBody['columns'] as List).first as Map)['type'], 'INTEGER');

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
        validatePlans(<QuickTablePlan>[
          planFor(columns: <QuickColumn>[]),
        ]),
        isNotNull,
      );
      expect(
        validatePlans(<QuickTablePlan>[
          planFor(columns: <QuickColumn>[
            QuickColumn(
                name: 'a',
                sourceLabel: 'a',
                sourceIndex: 0,
                inferred: 'integer',
                sqlType: 'INTEGER',
                primary: true),
            QuickColumn(
                name: 'b',
                sourceLabel: 'b',
                sourceIndex: 1,
                inferred: 'integer',
                sqlType: 'INTEGER',
                primary: true),
          ]),
        ]),
        isNotNull,
      );
      expect(
        validatePlans(<QuickTablePlan>[
          planFor(columns: <QuickColumn>[
            QuickColumn(
                name: 'a',
                sourceLabel: 'a',
                sourceIndex: 0,
                inferred: 'text',
                sqlType: 'TEXT'),
            QuickColumn(
                name: 'a',
                sourceLabel: 'b',
                sourceIndex: 1,
                inferred: 'text',
                sqlType: 'TEXT'),
          ]),
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
      expect(columns.map((column) => column['column']).toList(),
          <String>['name', 'score']);
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
      final mappings =
          ((params['mapping'] as Map)['columns'] as List).cast<Map>();
      expect(mappings.map((column) => column['column']).toList(),
          <String>['name', 'score']);
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

  group('英文模式文案', () {
    test('向导与入口文案都有英文映射', () {
      I18n.setLang(AppLang.en);
      try {
        expect(trLiteral('从文件建表'), 'Create tables from file');
        expect(trLiteral('工作表与字段'), 'Worksheets and columns');
        expect(trLiteral('创建并导入'), 'Create and import');
        expect(trLiteral('建立关联'), 'Connect tables');
        expect(trLiteral('关系图'), 'Relationships');
        expect(trLiteral('全部导入（每张工作表建一张表）'),
            'Import all (one table per worksheet)');
        expect(trLiteral('主键'), 'Primary key');
        expect(trLiteral('查看并编辑表之间的外键关系'),
            'View and edit foreign-key relationships between tables');
        // 卡片标题 / 工作表列这类插值文案走 Rewrite 模式。
        expect(trLiteral('表 2 · Sheet1'), 'Table 2 · Sheet1');
        expect(trLiteral('工作表：Sheet1'), 'Worksheet: Sheet1');
      } finally {
        I18n.setLang(AppLang.zh);
      }
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
      WidgetTester tester, String path, Notice notice) async {
    await tester.pumpWidget(MaterialApp(
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
    ));
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
    await tester.pumpWidget(MaterialApp(
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
    ));
    await tester.tap(find.text('open-quick-create-key'));
    await settle(tester, rounds: 6);
    return stateKey;
  }

  Future<void> setFieldText(
      WidgetTester tester, String key, String text) async {
    final field = find.byKey(ValueKey<String>(key));
    expect(field, findsOneWidget, reason: 'field $key is missing');
    final textField = find.descendant(of: field, matching: find.byType(TextField));
    await tester.enterText(textField, text);
    await tester.pump();
  }

  String fieldText(WidgetTester tester, String key) {
    final field = find.byKey(ValueKey<String>(key));
    expect(field, findsOneWidget, reason: 'field $key is missing');
    final textField = tester.widget<TextField>(
        find.descendant(of: field, matching: find.byType(TextField)));
    return textField.controller?.text ?? '';
  }

  Finder primaryButton() =>
      find.byKey(const ValueKey<String>('quick-create-primary'));

  Future<int> countRows(WidgetTester tester, String table) async {
    // 引号包裹：xlsx fixture 的工作表名是中文，未加引号的标识符各驱动行为不同。
    final res = await tester.runAsync(
        () => Api.instance.query('SELECT COUNT(*) AS c FROM "$table";'));
    final row =
        (((res!['results'] as List).first as Map)['rows'] as List).first;
    return ((row as List).first as num).toInt();
  }

  Future<List<String>> columnTypes(WidgetTester tester, String table) async {
    final structure =
        await tester.runAsync(() => Api.instance.structure('main', table));
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
      final failed = find.textContaining('导入失败').evaluate().isNotEmpty ||
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

    final csvPath = await tester.runAsync(() => writeFile(
          'people.csv',
          'id,name,score\n1,Ada,9.5\n2,Bob,8\n3,Cy,7.25\n',
        ));
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
    final designer =
        tester.widget<RelationDesigner>(find.byType(RelationDesigner));
    expect(designer.initialTables, <String>['people']);
    expect(designer.maxTables, kRelationSeedLimit);
    expect(await tableNames(tester), contains('people'));
    expect(await countRows(tester, 'people'), 0,
        reason: '关系步骤时只建空表，不导入数据');

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

    final csvPath = await tester.runAsync(() => writeFile(
          'english.csv',
          'id,name\n1,Ada\n2,Bob\n',
        ));
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
    final capability =
        await tester.runAsync(() => Api.instance.importInspect(path!));
    final sheets = capability?['sheets'];
    if (sheets is! List || sheets.isEmpty) {
      markTestSkipped(
          'rust-excel inspect.sheets 契约未就绪（当前 dylib 把 .xls 当成单表读取）');
      return;
    }

    final notice = Notice();
    addTearDown(notice.dispose);
    await pumpWizard(tester, path!, notice);
    await settle(tester, rounds: 16);

    expect(find.text('全部导入（每张工作表建一张表）'),
        findsOneWidget, reason: '多工作表时应显示全部导入开关');
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);

    expect(fieldText(tester, 'quick-table-name-0'), 'Orders');
    expect(fieldText(tester, 'quick-table-name-1'), 'Items');

    // 第 1 步 → 第 2 步：先建 2 张空表，再进入关系步骤。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 40);
    expect(find.byType(RelationDesigner), findsOneWidget);
    expect(await tableNames(tester),
        containsAll(<String>['Orders', 'Items']));
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
    final capability =
        await tester.runAsync(() => Api.instance.importInspect(path!));
    final sheets = capability?['sheets'];
    if (sheets is! List || sheets.isEmpty) {
      markTestSkipped(
          'rust-excel inspect.sheets 契约未就绪（当前 dylib 把 .xls 当成单表读取）');
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
    expect(find.byKey(const ValueKey<String>('quick-table-name-1')),
        findsNothing);

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

  testWidgets('真实 xlsx fixture：多工作表全部导入（中文表头/日期/布尔）',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fixture = File('rust/tests/fixtures/excel_multi.xlsx');
    if (!fixture.existsSync()) {
      markTestSkipped(
          'rust-excel fixture 未提交（rust/tests/fixtures/excel_multi.xlsx）');
      return;
    }
    final path = fixture.absolute.path;
    final inspect = await tester.runAsync(
        () => Api.instance.importInspect(path));
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
      expect(fieldText(tester, 'quick-table-name-$i'),
          sanitizeIdentifier(sheets[i]),
          reason: '工作表 ${sheets[i]} 的默认表名不对');
    }

    // 第 1 步 → 第 2 步：建 3 张空表并进入关系步骤；种子最多 10 张。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 60);
    expect(find.byType(RelationDesigner), findsOneWidget);
    final designer =
        tester.widget<RelationDesigner>(find.byType(RelationDesigner));
    expect(designer.maxTables, 10);
    expect(designer.initialTables.length, sheets.length);
    final names = await tableNames(tester);
    for (final sheet in sheets) {
      final table = sanitizeIdentifier(sheet);
      expect(names, contains(table));
      expect(await countRows(tester, table), 0,
          reason: '关系步骤时表应为空');
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

  testWidgets('State 测试钩子：注入文件 → 工作表与字段 → 建空表 → 导入数据',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final csvPath = await tester.runAsync(() => writeFile(
          'hook_people.csv',
          'id,name\n1,Ada\n2,Bob\n3,Cy\n',
        ));
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = GlobalKey<QuickCreateTableWizardState>();
    await tester.pumpWidget(MaterialApp(
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
    ));
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
    expect(find.byKey(const ValueKey<String>('quick-table-name-0')),
        findsOneWidget);

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
        () => writeFile('typed.csv', 'id,name\n1,Alice\n2,Bob\n'));
    final notice = Notice();
    addTearDown(notice.dispose);
    addTearDown(() => I18n.setLang(AppLang.zh));
    final stateKey = GlobalKey<QuickCreateTableWizardState>();
    await tester.pumpWidget(MaterialApp(
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
    ));
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

    final csvPath = await tester.runAsync(() => writeFile(
          // 第一列故意重复：Rust 对「首列且值唯一」会给 primary_candidate，
          // 重复值才能构造出「源文件没有主键」的场景。
          'nopk.csv',
          'name,score\nAda,9.5\nAda,8\n',
        ));
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
        find.byType(QuickCreateTableWizard));
    expect(
        state.plansForTest.single.columns.any((column) => column.primary),
        isFalse);

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
    final ids =
        await queryRows(tester, 'SELECT id FROM "nopk" ORDER BY id;');
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

    final csvPath = await tester.runAsync(() => writeFile(
          'pkreset.csv',
          'id,name\n1,Ada\n2,Bob\n',
        ));
    final notice = Notice();
    addTearDown(notice.dispose);
    await pumpWizard(tester, csvPath!, notice);
    await settle(tester, rounds: 16);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);
    // schema 识别出了 id 主键：此时没有提示。
    expect(find.textContaining('未设置主键'), findsNothing);

    // 用户取消原主键 → 提示立即出现。
    await tester
        .tap(find.byKey(const ValueKey<String>('quick-col-pk-0-0')));
    await settle(tester, rounds: 2);
    expect(find.textContaining('未设置主键'), findsWidgets);
    final state = tester.state<QuickCreateTableWizardState>(
        find.byType(QuickCreateTableWizard));
    expect(state.plansForTest.single.columns.any((column) => column.primary),
        isFalse);

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
    final ids = await queryRows(tester, 'SELECT id FROM "pkreset" ORDER BY id;');
    expect(ids.map((row) => (row as List).first).toList(), <int>[1, 2]);
    final generatedIds =
        await queryRows(tester, 'SELECT id_2 FROM "pkreset" ORDER BY id_2;');
    expect(generatedIds.map((row) => (row as List).first).toList(),
        <int>[1, 2]);

    await tester.tap(primaryButton()); // 完成
    await settle(tester, rounds: 6);
    await tester.pump(const Duration(seconds: 4));
  });


  testWidgets('取消生成列的主键：降级为普通列且提示重新出现', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final csvPath = await tester.runAsync(() => writeFile(
          'pkdowngrade.csv',
          'name\nAda\nAda\n',
        ));
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
    await tester
        .tap(find.byKey(const ValueKey<String>('quick-col-pk-0-0')));
    await settle(tester, rounds: 2);
    state = stateKey.currentState!;
    final downgraded = state.plansForTest.single.columns.first;
    expect(downgraded.name, 'id');
    expect(downgraded.generated, isTrue);
    expect(downgraded.primary, isFalse);
    expect(downgraded.nullable, isTrue,
        reason: '生成列没有源数据，取消主键后必须允许为空');
    expect(state.plansForTest.single.columns.any((column) => column.primary),
        isFalse);
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

    final csvPath = await tester.runAsync(() => writeFile(
          'failcreate.csv',
          'id,name\n1,Ada\n',
        ));
    final notice = Notice();
    addTearDown(notice.dispose);
    final stateKey = await pumpWizardWithKey(tester, csvPath!, notice);
    await settle(tester, rounds: 16);
    await tester.tap(primaryButton());
    await settle(tester, rounds: 24);

    // 把表名改成一个已存在的表，让 CREATE TABLE 真的失败。
    await setFieldText(tester, 'quick-table-name-0', 'failcreate_conflict');
    await tester.runAsync(() => Api.instance.query(
        'CREATE TABLE failcreate_conflict (x INTEGER);',
        'main'));
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
        // 第一列重复 → 不会被识别成主键候选。
        <Object?>['name', 'score'],
        <Object?>['Ada', 1],
        <Object?>['Ada', 2],
      ],
    });
    final path = await tester.runAsync(() => writeFile('mixedpk.xls', fixture));
    final capability =
        await tester.runAsync(() => Api.instance.importInspect(path!));
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
        stateKey.currentState!.plansForTest[0].columns
            .any((column) => column.primary),
        isTrue);
    expect(
        stateKey.currentState!.plansForTest[1].columns
            .any((column) => column.primary),
        isFalse);

    // 只提醒不阻断：仍然能建空表并进入关系步骤。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 40);
    expect(find.byType(RelationDesigner), findsOneWidget);
    expect(find.textContaining('没有主键，不能作为外键的被引用表'), findsWidgets);
    expect(
        stateKey.currentState!.createdTablesWithoutPrimaryForTest,
        <String>['NoPkSheet']);

    // 关闭（只建了空表）→ 明确提示未导入数据。
    await tester.tap(find.text('关闭'));
    await settle(tester, rounds: 6);
    expect(notice.message, contains('未导入数据'));
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('无主键表在关系步骤提示；返回字段会删除已建空表', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final csvPath = await tester.runAsync(() => writeFile(
          // 重复的姓名：避免首列被识别成唯一主键候选。
          'backfields.csv',
          'name\nAda\nAda\n',
        ));
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
        findsOneWidget);
    expect(state.createdTablesWithoutPrimaryForTest, <String>['backfields']);
    expect(await tableNames(tester), contains('backfields'));

    // 返回字段步骤：删除本次创建的空表。
    await tester
        .tap(find.byKey(const ValueKey<String>('quick-relations-back')));
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

    // 关闭（只建了空表 → 提示未导入）。
    await tester.tap(find.text('关闭'));
    await settle(tester, rounds: 6);
    expect(notice.message, contains('未导入数据'));
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
