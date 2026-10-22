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
import 'package:rust_myadmin_desktop/src/views/data_import_wizard.dart';

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

  testWidgets('CSV import: inspect, preview, validate, probe and execute',
      (tester) async {
    await tester.runAsync(() => runSetup(
        'CREATE TABLE people(id INTEGER, name TEXT, age INTEGER);'));

    final csvPath = await tester.runAsync(() => writeFile(
        'people.csv',
        'id,name,age\n1,Ada,36\n2,Bob,41\n3,Cy,29\n4,Di,bad\n'));
    expect(csvPath, isNotNull);

    // inspect picks the format and suggests rules.
    final inspect = await tester.runAsync(
        () => Api.instance.importInspect(csvPath!));
    expect(inspect!['format'], 'delimited');
    expect((inspect['fields'] as Map)['header'], isTrue);

    // preview echoes the split record and header.
    final preview = await tester.runAsync(() => Api.instance.importPreview(
        csvPath!,
        <String, dynamic>{
          'read': inspect['read'],
          'fields': inspect['fields'],
          'limit': 4,
        }));
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
    final probe = await tester.runAsync(() => Api.instance.importProbe(
        'main',
        'people',
        <String, dynamic>{...baseParams, 'mapping': mapping}));
    expect(probe!['affected'], 1);
    expect((probe['row'] as Map)['name'], 'Ada');
    final afterProbe = await tester.runAsync(
        () => Api.instance.data('main', 'people', <String, dynamic>{}));
    expect((afterProbe!['total'] as num).toInt(), 0,
        reason: 'probe must roll back');

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
        () => Api.instance.data('main', 'people', <String, dynamic>{}));
    expect((afterExec!['total'] as num).toInt(), 3);
  });

  testWidgets('JSON array import through the keyed mapping', (tester) async {
    await tester.runAsync(() => runSetup(
        'CREATE TABLE items(id INTEGER, title TEXT, payload TEXT);'));
    final path = await tester.runAsync(() => writeFile('items.json',
        '[{"id":1,"title":"first","payload":{"a":1}},'
        '{"id":2,"title":"second","payload":{"b":[1,2]}}]'));
    final inspect = await tester
        .runAsync(() => Api.instance.importInspect(path!));
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
    final rows = await tester
        .runAsync(() => Api.instance.query('SELECT title FROM items ORDER BY id;'));
    final values = ((rows!['results'] as List).first as Map)['rows'] as List;
    expect((values.first as List).first, 'first');
  });

  testWidgets('SQL file executes in streaming mode and reports line positions',
      (tester) async {
    final good = await tester.runAsync(() => writeFile('good.sql',
        'CREATE TABLE colors(name TEXT);\n'
        "INSERT INTO colors VALUES ('red'), ('green');\n"
        "INSERT INTO colors VALUES ('blue');\n"));
    final preview = await tester
        .runAsync(() => Api.instance.sqlFilePreview(good!, maxBytes: 8));
    expect(preview!['truncated'], isTrue);
    expect((preview['text'] as String).length, lessThanOrEqualTo(8));

    final jobId = await tester.runAsync(() async {
      final res = await Api.instance.sqlFileExecuteStart(
          'main', good!, <String, dynamic>{'on_error': 'stop'});
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
        () => Api.instance.query('SELECT COUNT(*) AS c FROM colors;'));
    final value =
        (((count!['results'] as List).first as Map)['rows'] as List).first;
    expect((value as List).first, 3);

    // A failing statement stops at its line.
    final bad = await tester.runAsync(() => writeFile(
        'bad.sql',
        "INSERT INTO colors VALUES ('ok');\n"
        'INSERT INTO missing_table VALUES (1);\n'
        "INSERT INTO colors VALUES ('never');\n"));
    final badJobId = await tester.runAsync(() async {
      final res = await Api.instance.sqlFileExecuteStart(
          'main', bad!, <String, dynamic>{'on_error': 'stop'});
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
    final useAttempt =
        await tester.runAsync(() => Api.instance.query('USE main; SELECT 1'));
    final useResults = useAttempt!['results'] as List;
    expect(useResults.length, 1);
    expect((useResults.first as Map)['error'], contains('SQLite 没有 USE'));
  });


  testWidgets('import wizard dialog renders its guided steps', (tester) async {
    await tester.runAsync(
        () => runSetup('CREATE TABLE wizard_demo(id INTEGER, name TEXT);'));
    final notice = Notice();
    await tester.pumpWidget(MaterialApp(
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
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('数据导入向导'), findsOneWidget);
    expect(find.text('选择文件'), findsWidgets);
    expect(find.text('打开数据导入向导'), findsNothing);
    expect(find.text('下一步'), findsOneWidget);
    // No layout overflow in the dialog.
    expect(tester.takeException(), isNull);
  });
}
