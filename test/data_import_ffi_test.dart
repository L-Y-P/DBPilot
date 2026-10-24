//! End-to-end tests of the guided data import and SQL-file execution through
//! the real FFI bridge (Rust core + FRB + Dart Api facade).
//!
//! A throwaway SQLite database is used, so no server is required.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/data_import_wizard.dart';
import 'package:rust_myadmin_desktop/src/views/relation_designer.dart';

/// Let real FFI work complete while pumping the widget tree.
Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Tap a control that may be below the fold of the scrollable step content.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

/// Poll an import job to completion inside [WidgetTester.runAsync].
Future<Json?> pollImportJob(WidgetTester tester, String jobId) {
  return tester.runAsync<Json?>(() async {
    for (var i = 0; i < 600; i++) {
      final status = await Api.instance.importJobStatus(jobId);
      if (status['done'] == true) return status;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return null;
  });
}

void main() {
  late Directory temporary;
  late String connectionId;

  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run cargo build --lib in rust/ first: ${dylib.path} is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    temporary = await Directory.systemTemp.createTemp('rma-import-ffi-');
    final init = await Api.init(temporary.path);
    expect(init['ok'], isTrue, reason: 'init_app failed: $init');
    await AppState.instance.bootstrap(temporary.path);
    final dbFile = '${temporary.path}/import.sqlite';
    File(dbFile).createSync(recursive: true);
    final created = await Api.instance.createConnection(<String, dynamic>{
      'name': 'Import FFI',
      'driver': 'sqlite',
      'database': dbFile,
    });
    connectionId = ((created['connection'] as Map)['id']).toString();
    await AppState.instance.connect(connectionId);
  });

  tearDownAll(() async {
    try {
      await Api.instance.disconnect();
    } catch (_) {}
    try {
      temporary.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<Json> runSetup(String sql) async {
    final res = await Api.instance.query(sql);
    expect(
      (res['results'] as List).every((r) => (r as Map)['error'] == null),
      isTrue,
      reason: 'setup failed: $res',
    );
    return res;
  }

  Future<String> writeFile(String name, String content) async {
    final file = File('${temporary.path}/$name');
    await file.writeAsString(content);
    return file.path;
  }

  /// Workbook fixture generated once by rust-excel (see
  /// rust/tests/fixtures/gen_fixtures.py). Sheets: 员工 / 订单 / 配置.
  String excelFixture(String name) => 'rust/tests/fixtures/$name';

  Future<String> startValidate(WidgetTester tester, Json params) async {
    final res = await tester.runAsync(
      () => Api.instance.importValidateStart(params),
    );
    return (res!['job_id'] ?? '').toString();
  }

  Future<String> startExecute(WidgetTester tester, Json params) async {
    final res = await tester.runAsync(
      () => Api.instance.importExecuteStart(params),
    );
    return (res!['job_id'] ?? '').toString();
  }

  testWidgets('CSV import: inspect, preview, validate, probe and execute', (
    tester,
  ) async {
    await tester.runAsync(
      () =>
          runSetup('CREATE TABLE people(id INTEGER, name TEXT, age INTEGER);'),
    );

    final csvPath = await tester.runAsync(
      () => writeFile(
        'people.csv',
        'id,name,age\n1,Ada,36\n2,Bob,41\n3,Cy,29\n4,Di,bad\n',
      ),
    );
    expect(csvPath, isNotNull);

    // inspect picks the format and suggests rules.
    final inspect = await tester.runAsync(
      () => Api.instance.importInspect(csvPath!),
    );
    expect(inspect!['format'], 'delimited');
    expect((inspect['fields'] as Map)['header'], isTrue);

    // preview echoes the split record and header.
    final preview = await tester.runAsync(
      () => Api.instance.importPreview(csvPath!, <String, dynamic>{
        'read': inspect['read'],
        'fields': inspect['fields'],
        'limit': 4,
      }),
    );
    expect(preview!['header'], <dynamic>['id', 'name', 'age']);
    expect((preview['records'] as List).length, 4);

    final mapping = <String, dynamic>{
      'columns': <dynamic>[
        <String, dynamic>{'column': 'id', 'source': 'id'},
        <String, dynamic>{'column': 'name', 'source': 'name'},
        <String, dynamic>{'column': 'age', 'source': 'age'},
      ],
      'ignore_unknown': true,
      'empty_as_null': false,
      'null_tokens': <String>['\\N'],
      'trim_values': true,
    };
    final baseParams = <String, dynamic>{
      'path': csvPath,
      'read': inspect['read'],
      'fields': inspect['fields'],
    };

    // Whole-file read validation is clean.
    final readJobId = await tester.runAsync(() async {
      final res = await Api.instance.importValidateStart(baseParams);
      return res['job_id'].toString();
    });
    final readJob = await tester.runAsync(() async {
      for (var i = 0; i < 400; i++) {
        final status = await Api.instance.importJobStatus(readJobId!);
        if (status['done'] == true) return status;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return null;
    });
    expect(readJob!['state'], 'done');
    expect((readJob['result'] as Map)['invalid'], 0);

    // Field validation with the mapping names the bad line.
    final fieldJobId = await tester.runAsync(() async {
      final res = await Api.instance.importValidateStart(<String, dynamic>{
        ...baseParams,
        'mapping': mapping,
        'database': 'main',
        'table': 'people',
      });
      return res['job_id'].toString();
    });
    final fieldJob = await tester.runAsync(() async {
      for (var i = 0; i < 400; i++) {
        final status = await Api.instance.importJobStatus(fieldJobId!);
        if (status['done'] == true) return status;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return null;
    });
    expect(fieldJob!['state'], 'done');
    final fieldResult = fieldJob['result'] as Map;
    expect(fieldResult['invalid'], 1);
    final issues = fieldResult['issues'] as List;
    expect((issues.first as Map)['line'], 5);

    // Probe: insert inside a transaction, read it back, roll back.
    final probe = await tester.runAsync(
      () => Api.instance.importProbe('main', 'people', <String, dynamic>{
        ...baseParams,
        'mapping': mapping,
      }),
    );
    expect(probe!['affected'], 1);
    expect((probe['row'] as Map)['name'], 'Ada');
    final afterProbe = await tester.runAsync(
      () => Api.instance.data('main', 'people', <String, dynamic>{}),
    );
    expect(
      (afterProbe!['total'] as num).toInt(),
      0,
      reason: 'probe must roll back',
    );

    // Real import in skip mode: 3 rows written, bad row reported.
    final execJobId = await tester.runAsync(() async {
      final res = await Api.instance.importExecuteStart(<String, dynamic>{
        ...baseParams,
        'mapping': mapping,
        'database': 'main',
        'table': 'people',
        'options': <String, dynamic>{
          'batch_size': 2,
          'on_error': 'skip',
          'max_issues': 10,
        },
      });
      return res['job_id'].toString();
    });
    final execJob = await tester.runAsync(() async {
      for (var i = 0; i < 600; i++) {
        final status = await Api.instance.importJobStatus(execJobId!);
        if (status['done'] == true) return status;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return null;
    });
    expect(execJob!['state'], 'done');
    final execResult = execJob['result'] as Map;
    expect(execResult['rows_inserted'], 3);
    expect(execResult['rows_failed'], 1);
    final afterExec = await tester.runAsync(
      () => Api.instance.data('main', 'people', <String, dynamic>{}),
    );
    expect((afterExec!['total'] as num).toInt(), 3);
  });

  testWidgets('JSON array import through the keyed mapping', (tester) async {
    await tester.runAsync(
      () =>
          runSetup('CREATE TABLE items(id INTEGER, title TEXT, payload TEXT);'),
    );
    final path = await tester.runAsync(
      () => writeFile(
        'items.json',
        '[{"id":1,"title":"first","payload":{"a":1}},'
            '{"id":2,"title":"second","payload":{"b":[1,2]}}]',
      ),
    );
    final inspect = await tester.runAsync(
      () => Api.instance.importInspect(path!),
    );
    expect(inspect!['format'], 'json_array');
    final mapping = <String, dynamic>{
      'columns': <dynamic>[
        <String, dynamic>{'column': 'id', 'source': 'id'},
        <String, dynamic>{'column': 'title', 'source': 'title'},
        <String, dynamic>{'column': 'payload', 'source': 'payload'},
      ],
    };
    final jobId = await tester.runAsync(() async {
      final res = await Api.instance.importExecuteStart(<String, dynamic>{
        'path': path,
        'read': inspect['read'],
        'fields': inspect['fields'],
        'mapping': mapping,
        'database': 'main',
        'table': 'items',
        'options': <String, dynamic>{'batch_size': 100, 'on_error': 'stop'},
      });
      return res['job_id'].toString();
    });
    final job = await tester.runAsync(() async {
      for (var i = 0; i < 600; i++) {
        final status = await Api.instance.importJobStatus(jobId!);
        if (status['done'] == true) return status;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return null;
    });
    expect(job!['state'], 'done');
    expect((job['result'] as Map)['rows_inserted'], 2);
    final rows = await tester.runAsync(
      () => Api.instance.query('SELECT title FROM items ORDER BY id;'),
    );
    final values = ((rows!['results'] as List).first as Map)['rows'] as List;
    expect((values.first as List).first, 'first');
  });

  testWidgets(
    'SQL file executes in streaming mode and reports line positions',
    (tester) async {
      final good = await tester.runAsync(
        () => writeFile(
          'good.sql',
          'CREATE TABLE colors(name TEXT);\n'
              "INSERT INTO colors VALUES ('red'), ('green');\n"
              "INSERT INTO colors VALUES ('blue');\n",
        ),
      );
      final preview = await tester.runAsync(
        () => Api.instance.sqlFilePreview(good!, maxBytes: 8),
      );
      expect(preview!['truncated'], isTrue);
      expect((preview['text'] as String).length, lessThanOrEqualTo(8));

      final jobId = await tester.runAsync(() async {
        final res = await Api.instance.sqlFileExecuteStart(
          'main',
          good!,
          <String, dynamic>{'on_error': 'stop'},
        );
        return res['job_id'].toString();
      });
      final job = await tester.runAsync(() async {
        for (var i = 0; i < 600; i++) {
          final status = await Api.instance.importJobStatus(jobId!);
          if (status['done'] == true) return status;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        return null;
      });
      expect(job!['state'], 'done');
      final result = job['result'] as Map;
      expect(result['statements'], 3);
      expect(result['ok'], isTrue);
      final count = await tester.runAsync(
        () => Api.instance.query('SELECT COUNT(*) AS c FROM colors;'),
      );
      final value =
          (((count!['results'] as List).first as Map)['rows'] as List).first;
      expect((value as List).first, 3);

      // A failing statement stops at its line.
      final bad = await tester.runAsync(
        () => writeFile(
          'bad.sql',
          "INSERT INTO colors VALUES ('ok');\n"
              'INSERT INTO missing_table VALUES (1);\n'
              "INSERT INTO colors VALUES ('never');\n",
        ),
      );
      final badJobId = await tester.runAsync(() async {
        final res = await Api.instance.sqlFileExecuteStart(
          'main',
          bad!,
          <String, dynamic>{'on_error': 'stop'},
        );
        return res['job_id'].toString();
      });
      final badJob = await tester.runAsync(() async {
        for (var i = 0; i < 600; i++) {
          final status = await Api.instance.importJobStatus(badJobId!);
          if (status['done'] == true) return status;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        return null;
      });
      expect(badJob!['state'], 'done');
      final badResult = badJob['result'] as Map;
      expect(badResult['stopped'], isTrue);
      expect((badResult['issues'] as List).first['line'], 2);

      // USE is not valid SQLite syntax; the console reports a driver-specific
      // hint instead of forwarding the statement.
      final useAttempt = await tester.runAsync(
        () => Api.instance.query('USE main; SELECT 1'),
      );
      final useResults = useAttempt!['results'] as List;
      expect(useResults.length, 1);
      expect((useResults.first as Map)['error'], contains('SQLite 没有 USE'));
    },
  );

  testWidgets('import wizard dialog renders its guided steps', (tester) async {
    await tester.runAsync(
      () => runSetup('CREATE TABLE wizard_demo(id INTEGER, name TEXT);'),
    );
    final notice = Notice();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDataImportWizard(
                context,
                database: 'main',
                table: 'wizard_demo',
                notice: notice,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('数据导入向导'), findsOneWidget);
    expect(find.text('选择文件'), findsWidgets);
    expect(find.text('打开数据导入向导'), findsNothing);
    expect(find.text('下一步'), findsOneWidget);
    // No layout overflow in the dialog.
    expect(tester.takeException(), isNull);
  });

  // --------------------------------------------------------------- Excel

  testWidgets('xlsx: inspect lists worksheets, preview and import one sheet', (
    tester,
  ) async {
    final xlsx = excelFixture('excel_multi.xlsx');
    expect(
      File(xlsx).existsSync(),
      isTrue,
      reason: 'rust/tests/fixtures/excel_multi.xlsx must be committed',
    );
    await tester.runAsync(
      () => runSetup(
        'CREATE TABLE orders_import(order_no INTEGER, customer TEXT, amount NUMERIC);',
      ),
    );

    final inspect = (await tester.runAsync(
      () => Api.instance.importInspect(xlsx),
    ))!;
    expect(inspect['format'], 'xlsx');
    final sheets = (inspect['sheets'] as List).cast<Map>();
    expect(sheets.map((s) => s['name']).toList(), <dynamic>[
      '员工',
      '订单',
      '配置',
    ], reason: 'the hidden worksheet must not be offered');
    expect((sheets.first['rows'] as num).toInt(), greaterThanOrEqualTo(4));
    expect((sheets.first['cols'] as num).toInt(), 8);
    expect(inspect['sheet'], '员工');
    expect((inspect['read'] as Map)['sheet'], '员工');
    expect((inspect['fields'] as Map)['mode'], 'excel');
    expect((inspect['fields'] as Map)['header'], isTrue);

    // Default preview reads the first worksheet, with typed cell values.
    final preview = (await tester.runAsync(
      () => Api.instance.importPreview(xlsx, <String, dynamic>{
        'read': inspect['read'],
        'fields': inspect['fields'],
        'limit': 8,
      }),
    ))!;
    expect(preview['sheet_used'], '员工');
    expect(preview['header'], <dynamic>[
      'id',
      '姓名',
      '入职日期',
      '活跃',
      '评分',
      '备注',
      '登录时间',
      '打卡时间',
    ]);
    final dataRecords = (preview['records'] as List)
        .map((e) => e as Map)
        .where((r) => r['header'] != true)
        .toList();
    expect(dataRecords.length, 4);
    final firstValues = (dataRecords.first['values'] as List);
    expect(firstValues[0], 1);
    expect(firstValues[1], '张伟');
    expect(firstValues[2], '2021-03-05');
    expect(firstValues[3], isTrue);
    expect(firstValues[5], isNull);

    // A different worksheet returns different data (worksheet selection).
    final readOrders = Map<String, dynamic>.from(inspect['read'] as Map)
      ..['sheet'] = '订单';
    final ordersPreview = (await tester.runAsync(
      () => Api.instance.importPreview(xlsx, <String, dynamic>{
        'read': readOrders,
        'fields': inspect['fields'],
        'limit': 6,
      }),
    ))!;
    expect(ordersPreview['sheet_used'], '订单');
    expect(ordersPreview['header'], <dynamic>['订单号', '客户', '金额']);
    final orderRecords = (ordersPreview['records'] as List)
        .map((e) => e as Map)
        .where((r) => r['header'] != true)
        .toList();
    expect(orderRecords.length, 3);
    expect((orderRecords.first['values'] as List)[1], '甲公司');

    // Type inference (contract 2.3): preview always reports a schema.
    final schemaColumns = ((ordersPreview['schema'] as Map)['columns'] as List)
        .map((e) => e as Map)
        .toList();
    expect(schemaColumns.map((c) => c['name']).toList(), <dynamic>[
      '订单号',
      '客户',
      '金额',
    ]);
    expect(schemaColumns.map((c) => c['type']).toList(), <dynamic>[
      'integer',
      'text',
      'decimal',
    ]);

    // skip_rows applies before the header row is picked.
    final readConfig = Map<String, dynamic>.from(inspect['read'] as Map)
      ..['sheet'] = '配置'
      ..['skip_rows'] = 1;
    final configPreview = (await tester.runAsync(
      () => Api.instance.importPreview(xlsx, <String, dynamic>{
        'read': readConfig,
        'fields': inspect['fields'],
        'limit': 6,
      }),
    ))!;
    expect(configPreview['sheet_used'], '配置');
    expect(configPreview['header'], <dynamic>[
      'version',
      '1.0',
    ], reason: 'skip_rows=1 must skip the real header row');

    // validate + execute the selected worksheet with a column mapping.
    final mapping = <String, dynamic>{
      'columns': <dynamic>[
        <String, dynamic>{'column': 'order_no', 'source': '订单号'},
        <String, dynamic>{'column': 'customer', 'source': '客户'},
        <String, dynamic>{'column': 'amount', 'source': '金额'},
      ],
    };
    final baseParams = <String, dynamic>{
      'path': xlsx,
      'read': readOrders,
      'fields': inspect['fields'],
    };
    final readJobId = await startValidate(tester, baseParams);
    final readJob = await pollImportJob(tester, readJobId);
    expect(readJob!['state'], 'done');
    expect((readJob['result'] as Map)['invalid'], 0);

    final fieldJobId = await startValidate(tester, <String, dynamic>{
      ...baseParams,
      'mapping': mapping,
      'database': 'main',
      'table': 'orders_import',
    });
    final fieldJob = await pollImportJob(tester, fieldJobId);
    expect(fieldJob!['state'], 'done');
    expect((fieldJob['result'] as Map)['invalid'], 0);

    final execJobId = await startExecute(tester, <String, dynamic>{
      ...baseParams,
      'mapping': mapping,
      'database': 'main',
      'table': 'orders_import',
      'options': <String, dynamic>{'batch_size': 100, 'on_error': 'stop'},
    });
    final execJob = await pollImportJob(tester, execJobId);
    expect(execJob!['state'], 'done');
    expect((execJob['result'] as Map)['rows_inserted'], 3);
    final rows = (await tester.runAsync(
      () => Api.instance.query(
        'SELECT order_no, customer, amount FROM orders_import ORDER BY order_no;',
      ),
    ))!;
    final resultRows = ((rows['results'] as List).first as Map)['rows'] as List;
    expect(resultRows.length, 3);
    expect(((resultRows.first as List)[1]), '甲公司');
  });

  testWidgets(
    'wizard reaches the build-relations step after a successful import',
    (tester) async {
      await tester.runAsync(
        () => runSetup('CREATE TABLE wizard_rel(id INTEGER, name TEXT);'),
      );
      final csvPath = await tester.runAsync(
        () => writeFile('wizard_rel.csv', 'id,name\n1,Ada\n2,Bob\n'),
      );
      final wizardKey = GlobalKey<DataImportWizardDialogState>();
      final notice = Notice();
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          home: Scaffold(
            body: DataImportWizardDialog(
              key: wizardKey,
              database: 'main',
              table: 'wizard_rel',
              notice: notice,
            ),
          ),
        ),
      );
      await settle(tester);
      await tester.runAsync(
        () => wizardKey.currentState!.loadFileForTest(csvPath!),
      );
      await settle(tester);

      // Step 1: read rules -> validate the whole file.
      await tester.tap(find.text('下一步'));
      await settle(tester);
      await tapVisible(tester, find.text('开始校验'));
      await settle(tester, rounds: 30);
      expect(find.text('通过'), findsOneWidget);
      await tester.tap(find.text('下一步'));
      await settle(tester);

      // Step 2: trial insert + whole-file field validation.
      await tapVisible(tester, find.text('试插入'));
      await settle(tester);
      expect(find.textContaining('试插入成功'), findsOneWidget);
      await tapVisible(tester, find.text('开始校验'));
      await settle(tester, rounds: 30);
      expect(find.text('通过'), findsOneWidget);
      await tester.tap(find.text('下一步'));
      await settle(tester);

      // Step 3: the footer button is the only start point; after it finishes the
      // footer switches to the relations step instead of a bare "Done".
      await tester.tap(find.text('开始导入'));
      await settle(tester, rounds: 40);
      expect(find.textContaining('导入完成'), findsOneWidget);
      expect(find.text('下一步：建立关联'), findsOneWidget);
      await tester.tap(find.text('下一步：建立关联'));
      await settle(tester);

      // Step 5 hosts the E-R designer for the imported table.
      expect(find.text('完成并返回'), findsOneWidget);
      expect(find.byType(RelationDesigner), findsOneWidget);
      // The footer hint and the step body both mention this, and the footer hint
      // may be the only visible one; both are built, so just require a match.
      expect(find.textContaining('关系修改会立即写入数据库'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('xls: BIFF workbook is detected with all its worksheets', (
    tester,
  ) async {
    final xls = excelFixture('excel_multi.xls');
    expect(
      File(xls).existsSync(),
      isTrue,
      reason: 'rust/tests/fixtures/excel_multi.xls must be committed',
    );
    final inspect = (await tester.runAsync(
      () => Api.instance.importInspect(xls),
    ))!;
    expect(inspect['format'], 'xls');
    final sheets = (inspect['sheets'] as List).cast<Map>();
    expect(sheets.map((s) => s['name']).toList(), <dynamic>['员工', '订单', '配置']);
    expect((inspect['fields'] as Map)['mode'], 'excel');

    final readConfig = Map<String, dynamic>.from(inspect['read'] as Map)
      ..['sheet'] = '配置';
    final preview = (await tester.runAsync(
      () => Api.instance.importPreview(xls, <String, dynamic>{
        'read': readConfig,
        'fields': inspect['fields'],
        'limit': 6,
      }),
    ))!;
    expect(preview['sheet_used'], '配置');
    expect(preview['header'], <dynamic>['键', '值']);
    final dataRecords = (preview['records'] as List)
        .map((e) => e as Map)
        .where((r) => r['header'] != true)
        .toList();
    expect(dataRecords.length, 2);
  });

  testWidgets(
    'wizard text branch keeps the delimiter controls (no regression)',
    (tester) async {
      await tester.runAsync(
        () => runSetup('CREATE TABLE wizard_csv(id INTEGER, name TEXT);'),
      );
      final csvPath = await tester.runAsync(
        () => writeFile('wizard.csv', 'id,name\n1,Ada\n2,Bob\n'),
      );
      final wizardKey = GlobalKey<DataImportWizardDialogState>();
      final notice = Notice();
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          home: Scaffold(
            body: DataImportWizardDialog(
              key: wizardKey,
              database: 'main',
              table: 'wizard_csv',
              notice: notice,
            ),
          ),
        ),
      );
      await settle(tester);

      await tester.runAsync(
        () => wizardKey.currentState!.loadFileForTest(csvPath!),
      );
      await settle(tester);
      expect(find.textContaining('xlsx / Excel 工作簿'), findsNothing);

      await tester.tap(find.text('下一步'));
      await settle(tester);
      // The text path is untouched: record splitting controls stay visible and
      // there is no worksheet picker.
      expect(find.text('记录方式'), findsOneWidget);
      expect(find.text('记录分隔符'), findsOneWidget);
      expect(find.text('工作表'), findsNothing);

      await tapVisible(tester, find.text('开始校验'));
      await settle(tester, rounds: 30);
      expect(find.text('通过'), findsOneWidget);
      await tester.tap(find.text('下一步'));
      await settle(tester);
      expect(find.text('字段方式'), findsOneWidget);
      expect(find.text('字段分隔符'), findsOneWidget);
      expect(find.textContaining('字段方式固定为 Excel 单元格'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('wizard worksheet branch: picker shown, text controls hidden', (
    tester,
  ) async {
    await tester.runAsync(
      () => runSetup('CREATE TABLE wizard_xlsx(id INTEGER, name TEXT);'),
    );
    final wizardKey = GlobalKey<DataImportWizardDialogState>();
    final notice = Notice();
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: Scaffold(
          body: DataImportWizardDialog(
            key: wizardKey,
            database: 'main',
            table: 'wizard_xlsx',
            notice: notice,
          ),
        ),
      ),
    );
    await settle(tester);

    await tester.runAsync(
      () => wizardKey.currentState!.loadFileForTest(
        excelFixture('excel_multi.xlsx'),
      ),
    );
    await settle(tester);

    // Step 1: workbook format label instead of a text head preview.
    expect(find.textContaining('xlsx / Excel 工作簿'), findsOneWidget);
    expect(find.textContaining('工作簿是二进制'), findsOneWidget);
    expect(find.textContaining('在下一步选择'), findsOneWidget);

    await tester.tap(find.text('下一步'));
    await settle(tester);

    // Step 2: worksheet picker + header + skip rows, no text splitting.
    expect(find.text('工作表'), findsWidgets);
    expect(find.textContaining('员工'), findsWidgets);
    expect(find.text('首行为列名'), findsOneWidget);
    expect(find.text('跳过开头行数'), findsOneWidget);
    expect(find.text('记录方式'), findsNothing);
    expect(find.text('包裹开头'), findsNothing);
    expect(find.text('记录分隔符'), findsNothing);
    expect(find.text('引号字符'), findsNothing);
    expect(find.textContaining('文件含 3 个工作表'), findsOneWidget);

    // Validate the worksheet, then the field step hides the field-mode
    // dropdown and keeps the mapping grid.
    await tapVisible(tester, find.text('开始校验'));
    await settle(tester, rounds: 30);
    expect(find.text('通过'), findsOneWidget);
    await tester.tap(find.text('下一步'));
    await settle(tester);
    expect(find.textContaining('字段方式固定为 Excel 单元格'), findsOneWidget);
    expect(find.text('字段分隔符'), findsNothing);
    expect(find.textContaining('列映射'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
