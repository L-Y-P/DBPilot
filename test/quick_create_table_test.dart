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

  /// 走到「全部完成」为止；返回 null 表示成功，否则返回页面上的错误文本。
  Future<String?> runUntilImported(WidgetTester tester) async {
    for (var i = 0; i < 240; i++) {
      await settle(tester, rounds: 1);
      if (find.textContaining('全部表已创建并导入完成').evaluate().isNotEmpty) {
        return null;
      }
      final failed = find.textContaining('执行失败').evaluate().isNotEmpty ||
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

    // 下一步 → 创建并导入，启动执行。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 4);
    expect(find.text('执行计划'), findsOneWidget);
    await tester.tap(primaryButton());

    final failure = await runUntilImported(tester);
    expect(failure, isNull, reason: 'import failed: $failure');

    // 真实数据库里：1 张表、3 行、类型按推断创建。
    expect(await tableNames(tester), contains('people'));
    expect(await countRows(tester, 'people'), 3);
    final types = await columnTypes(tester, 'people');
    expect(types[0], contains('INT'));
    expect(types[1], contains('TEXT'));
    expect(types[2], anyOf(contains('NUM'), contains('REAL')));

    // 下一步 → 建立关联：嵌入真实的关系设计器。
    await tester.tap(primaryButton());
    await settle(tester, rounds: 16);
    expect(find.byType(RelationDesigner), findsOneWidget);
    expect(find.textContaining('关系修改会立即写入数据库'), findsOneWidget);

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

    await tester.tap(primaryButton());
    await settle(tester, rounds: 4);
    await tester.tap(primaryButton());
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

    await tester.tap(primaryButton());
    await settle(tester, rounds: 4);
    await tester.tap(primaryButton());
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

    await tester.tap(primaryButton());
    await settle(tester, rounds: 4);
    await tester.tap(primaryButton());
    final failure = await runUntilImported(tester);
    expect(failure, isNull, reason: 'xlsx import failed: $failure');

    // 每个可见工作表都建了表并导入了数据（含中文表名）。
    final names = await tableNames(tester);
    for (final sheet in sheets) {
      final table = sanitizeIdentifier(sheet);
      expect(names, contains(table));
      expect(await countRows(tester, table), greaterThan(0));
    }
  });

  testWidgets('State 测试钩子：注入文件 → 工作表与字段 → 创建并导入', (tester) async {
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

    // 第 1 步 → 第 2 步：分析文件并生成每张表的字段。
    await tester.runAsync(state.advanceForTest);
    await settle(tester, rounds: 24);
    expect(state.stepForTest, 1);
    expect(state.plannedTableNamesForTest, <String>['hook_people']);
    expect(find.byKey(const ValueKey<String>('quick-table-name-0')),
        findsOneWidget);

    // 第 2 步 → 第 3 步（创建并导入）。
    await tester.runAsync(state.advanceForTest);
    await settle(tester, rounds: 4);
    expect(state.stepForTest, 2);

    await tester.runAsync(state.advanceForTest);
    await settle(tester, rounds: 24);
    expect(state.importsDoneForTest, isTrue);
    expect(state.createdTablesForTest, <String>['hook_people']);
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
