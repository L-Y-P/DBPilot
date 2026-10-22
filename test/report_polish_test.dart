import 'dart:convert';
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
import 'package:rust_myadmin_desktop/src/views/backups_view.dart';
import 'package:rust_myadmin_desktop/src/views/create_table_dialog.dart';
import 'package:rust_myadmin_desktop/src/views/server_view.dart';
import 'package:rust_myadmin_desktop/src/views/table_view.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Widget host(Widget child) => MaterialApp(theme: buildAppTheme(), home: Scaffold(body: child));

void size(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  late Directory temporary;
  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('rma-report-polish-');
    final backups = Directory('${temporary.path}/backups')..createSync();
    File('${backups.path}/index.json').writeAsStringSync(jsonEncode([
      for (final driver in ['mysql', 'sqlite'])
        {'id': 'fixture-$driver', 'file': '$driver-fixture.sql', 'driver': driver,
          'database': 'main', 'created_at': '2026-10-18T01:02:03+00:00', 'size': 1},
    ]));
    await RustLib.init(externalLibrary: ExternalLibrary.open('rust/target/debug/librust_myadmin_core.dylib'));
    expect((await Api.init(temporary.path))['ok'], isTrue);
    await AppState.instance.bootstrap(temporary.path);
    File('${temporary.path}/test.sqlite').createSync();
    final connection = await Api.instance.createConnection({
      'name': 'report-polish', 'driver': 'sqlite', 'database': '${temporary.path}/test.sqlite',
    });
    await AppState.instance.connect((connection['connection'] as Map)['id'].toString());
    await AppState.instance.refreshDatabases();
    await Api.instance.query('CREATE TABLE report_books (book_id INTEGER PRIMARY KEY, title TEXT);');
    await Api.instance.query("INSERT INTO report_books (title) VALUES ('initial');");
  });
  tearDownAll(() async {
    await Api.instance.disconnect();
    // Only this test-created temporary directory is removed; no user data.
    await temporary.delete(recursive: true);
  });
  setUp(() => I18n.setLang(AppLang.zh));

  testWidgets('P06 WHERE example is only a hint and blank filtering succeeds', (tester) async {
    size(tester);
    final notice = Notice(); addTearDown(notice.dispose);
    await tester.pumpWidget(host(TableView(db: 'main', table: 'report_books', notice: notice)));
    await settle(tester);
    final where = tester.widget<TextField>(find.byType(TextField).first);
    expect(where.controller!.text, isEmpty);
    expect(where.decoration!.hintText, isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('grid-filter-toggle')));
    await settle(tester);
    expect(find.text('initial'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('P09 successful insert visibly confirms and clears form', (tester) async {
    size(tester);
    final notice = Notice(); addTearDown(notice.dispose);
    await tester.pumpWidget(host(TableView(db: 'main', table: 'report_books', notice: notice)));
    await settle(tester);
    await tester.tap(find.text('插入')); await tester.pump();
    await tester.enterText(find.byType(TextField).last, 'insert-feedback');
    await tester.tap(find.text('插入').last); await settle(tester);
    expect(find.text('行已插入'), findsWidgets);
    expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text, isEmpty);
    final data = await tester.runAsync(() => Api.instance.data('main', 'report_books', {'page': 1, 'per_page': 50}));
    expect(data!['rows'].toString(), contains('insert-feedback'));
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('P14 clicking export preview displays generated SQL', (tester) async {
    size(tester);
    final notice = Notice(); addTearDown(notice.dispose);
    await tester.pumpWidget(host(TableView(db: 'main', table: 'report_books', notice: notice)));
    await settle(tester);
    await tester.tap(find.text('导出')); await tester.pump();
    await tester.tap(find.text('预览')); await settle(tester);
    expect(find.byType(CodeBlock), findsOneWidget);
    expect(find.byType(SelectableText).evaluate().map((e) => (e.widget as SelectableText).data).join(), contains('CREATE TABLE'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('P10 variable tab search matches names without overflow', (tester) async {
    size(tester);
    final notice = Notice(); addTearDown(notice.dispose);
    await tester.pumpWidget(host(ServerView(notice: notice))); await settle(tester);
    await tester.tap(find.text('变量')); await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'zz-no-variable'); await tester.pump();
    expect(find.text('（无）'), findsOneWidget);
    await tester.enterText(find.byType(TextField), ''); await tester.pump();
    expect(find.byType(ListView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('P11 Flutter text semantics preserve table and column values', (tester) async {
    size(tester);
    final semantics = tester.ensureSemantics();
    final key = GlobalKey<CreateTableDialogState>();
    await tester.pumpWidget(host(SingleChildScrollView(child: CreateTableDialog(key: key, database: 'main'))));
    await settle(tester);
    final name = find.byType(TextField).first;
    final column = find.descendant(of: find.byType(GridTable).first, matching: find.byType(TextField)).first;
    await tester.enterText(name, 't_books');
    await tester.enterText(column, 'book_id'); await settle(tester);
    expect(tester.getSemantics(find.descendant(of: name, matching: find.byType(EditableText))).value, 't_books');
    expect(tester.getSemantics(find.descendant(of: column, matching: find.byType(EditableText))).value, 'book_id');
    expect(key.currentState!.body()['name'], 't_books');
    expect((key.currentState!.body()['columns'] as List).first['name'], 'book_id');
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  testWidgets('P12 design is scrollable at 1200px and P13 rename starts empty', (tester) async {
    size(tester);
    final notice = Notice(); addTearDown(notice.dispose);
    await tester.pumpWidget(host(TableView(db: 'main', table: 'report_books', notice: notice))); await settle(tester);
    await tester.tap(find.text('设计')); await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byWidgetPredicate((w) => w is Scrollbar && w.thumbVisibility == true), findsWidgets);
    final rename = tester.widget<TextField>(find.byType(TextField).first);
    expect(rename.controller!.text, isEmpty);
    expect(rename.decoration!.hintText, '新表名（留空不改）');
  });

  testWidgets('P18 backup list defaults to active driver and offers all drivers', (tester) async {
    size(tester);
    final notice = Notice(); addTearDown(notice.dispose);
    await tester.pumpWidget(host(BackupsView(notice: notice))); await settle(tester);
    expect(find.text('sqlite-fixture.sql'), findsOneWidget);
    expect(find.text('mysql-fixture.sql'), findsNothing);
    await tester.tap(find.text('显示其他驱动的备份')); await tester.pump();
    expect(find.text('mysql-fixture.sql'), findsOneWidget);
  });

  testWidgets('P07 backup timestamps explicitly identify local timezone', (tester) async {
    size(tester);
    final notice = Notice(); addTearDown(notice.dispose);
    await tester.pumpWidget(host(BackupsView(notice: notice))); await settle(tester);
    expect(find.textContaining('UTC'), findsWidgets);
    expect(find.text('2026-10-18T01:02:03+00:00'), findsNothing);
  });

  testWidgets('P08 English table tabs and export options are translated', (tester) async {
    size(tester); I18n.setLang(AppLang.en);
    final notice = Notice(); addTearDown(notice.dispose);
    await tester.pumpWidget(host(TableView(db: 'main', table: 'report_books', notice: notice))); await settle(tester);
    expect(find.text('Browse'), findsOneWidget);
    expect(find.text('Structure'), findsOneWidget);
    await tester.tap(find.text('Export')); await tester.pump();
    expect(find.text('Include structure'), findsOneWidget);
    expect(find.text('Include data'), findsOneWidget);
    expect(find.text('Preview'), findsOneWidget);
    expect(find.text('包含结构'), findsNothing);
  });
}
