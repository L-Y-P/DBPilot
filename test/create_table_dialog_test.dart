// Regression tests for the create-table designer.
//
// Reported symptom: "创建数据库（表）里许多选项功能没实现" — the desktop dialog could
// only name a table and create a single column. The web build's engine /
// charset / collation / row-format / auto-increment / comment selects, the
// per-column extras and the foreign-key grid were all missing.
//
// These tests boot the real Rust core (SQLite), open the dialog, and pin that
// the options exist, that the payload the Rust side receives carries them, and
// that the generated DDL preview reflects them.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/create_table_dialog.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 120));
  }
}

final GlobalKey<CreateTableDialogState> dialogKey =
    GlobalKey<CreateTableDialogState>();

Widget host() => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(
        body: CreateTableDialog(key: dialogKey, database: 'main'),
      ),
    );

void main() {
  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run `cargo build --lib` in rust/ first');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    final dir = await Directory.systemTemp.createTemp('rma-create-table-');
    final init = await Api.init(dir.path);
    expect(init['ok'], isTrue, reason: 'init_app failed: $init');
    await AppState.instance.bootstrap(dir.path);

    // The database file must exist: a connection pointing at a missing file is
    // reported as missing instead of being silently created empty.
    File('${dir.path}/demo.sqlite').createSync(recursive: true);
    final created = await Api.instance.createConnection({
      'name': 'SQLite 示例库',
      'driver': 'sqlite',
      'database': '${dir.path}/demo.sqlite',
      'color': '#0f80cc',
    });
    final id = (created['connection'] as Map)['id'].toString();
    await AppState.instance.connect(id);
    await Api.instance.query(
        'CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT);');
  });

  testWidgets('dialog exposes the full option set', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host());
    await settle(tester);

    // Table level options (SQLite supports WITHOUT ROWID / STRICT).
    expect(find.text('表选项'), findsOneWidget);
    expect(find.text('字段'), findsOneWidget);
    expect(find.text('外键约束'), findsOneWidget);
    expect(find.text('WITHOUT ROWID'), findsOneWidget);
    expect(find.text('STRICT'), findsOneWidget);
    expect(find.text('添加字段'), findsOneWidget);
    expect(find.text('添加外键'), findsOneWidget);

    // The column grid is a real grid, not one hard-coded field.
    final fields = tester.widgetList<TextField>(find.byType(TextField)).length;
    expect(fields, greaterThanOrEqualTo(3),
        reason: 'name + column name/default/comment inputs');
  });

  testWidgets('payload carries the options into the generated DDL',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host());
    await settle(tester);

    // Fill the table name (first text field) and add a column.
    await tester.enterText(find.byType(TextField).first, 'rma_designer_probe');
    await tester.tap(find.text('添加字段'));
    // Deliberately no async settle here: an in-flight Rust preview would arm
    // timers that outlive the test body. The payload is read synchronously.
    await tester.pump();

    // Each column row contributes name / default / comment inputs in that
    // order, so the second column's name is the fourth input in the grid.
    final gridFields = find.descendant(
      of: find.byType(GridTable),
      matching: find.byType(TextField),
    );
    expect(gridFields.evaluate().length, 6,
        reason: 'two columns x (name, default, comment)');
    await tester.enterText(gridFields.at(3), 'extra_col');
    await tester.pump();

    final body = dialogKey.currentState!.body();
    expect(body['name'], 'rma_designer_probe');
    expect((body['columns'] as List).length, 2);
    expect(body['strict'], isFalse);
    expect(body['without_rowid'], isFalse);

    // Turn STRICT on and make sure it reaches the spec.
    await tester.tap(find.text('严格类型'));
    await tester.pump();
    expect(dialogKey.currentState!.body()['strict'], isTrue);

    // The preview is produced by the real Rust dry-run path; await it on the
    // real event loop (the fake clock inside a test body never resolves FFI).
    await tester.runAsync(() => dialogKey.currentState!.refreshPreview());
    await tester.pump();
    final preview = dialogKey.currentState!.preview;
    expect(preview, contains('CREATE TABLE'));
    expect(preview, contains('rma_designer_probe'));
    expect(preview, contains('STRICT'));
    expect(preview, contains('extra_col'));
  });

  testWidgets('标题栏提供「从文件建表」快速建表入口', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var quickCreateCalled = false;
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Btn(
            'open-designer',
            onPressed: () => showCreateTableDialog(
              context,
              database: 'main',
              onQuickCreate: () => quickCreateCalled = true,
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open-designer'));
    await settle(tester);
    expect(find.byType(CreateTableDialog), findsOneWidget);

    // The entry sits in the title bar (headerActions), not in the footer.
    expect(find.text('从文件建表'), findsOneWidget);
    await tester.tap(find.text('从文件建表'));
    await settle(tester, rounds: 4);

    // The designer closes first, then hands over to the wizard callback.
    expect(find.byType(CreateTableDialog), findsNothing);
    expect(quickCreateCalled, isTrue);
  });
}
