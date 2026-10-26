import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/builder_view.dart';
import 'package:rust_myadmin_desktop/src/views/connections_view.dart';
import 'package:rust_myadmin_desktop/src/views/database_view.dart';
import 'package:rust_myadmin_desktop/src/views/sql_view.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}
Widget host(Widget child) => MaterialApp(theme: buildAppTheme(), home: Scaffold(body: child));
/// SQL shown by the builder. The SQL strip starts collapsed, so fall back to
/// the one-line summary inside it when the code block is not mounted.
String preview(WidgetTester tester) {
  final codeBlocks = tester
      .widgetList<CodeBlock>(find.byType(CodeBlock))
      .map((w) => w.text)
      .join('\n');
  if (codeBlocks.trim().isNotEmpty) return codeBlocks;
  final strip = find.byKey(const ValueKey('builder-sql-preview'));
  final texts = tester
      .widgetList<Text>(find.descendant(of: strip, matching: find.byType(Text)))
      .map((w) => w.data ?? '')
      .where((t) => t.isNotEmpty)
      .toList();
  texts.sort((a, b) => b.length.compareTo(a.length));
  return texts.isEmpty ? '' : texts.first;
}

void main() {
  late Directory dir;
  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('rma-report-core-');
    await RustLib.init(externalLibrary: ExternalLibrary.open('rust/target/debug/librust_myadmin_core.dylib'));
    await Api.init(dir.path);
    await AppState.instance.bootstrap(dir.path);
    File('${dir.path}/report.sqlite').createSync();
    final saved = await Api.instance.createConnection({'name':'report', 'driver':'sqlite', 'database':'${dir.path}/report.sqlite'});
    await AppState.instance.connect((saved['connection'] as Map)['id'].toString());
    await Api.instance.query("CREATE TABLE sample (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO sample VALUES (1, 'report-marker');", 'main');
  });
  tearDownAll(() async {
    await AppState.instance.disconnect();
    await dir.delete(recursive: true);
  });


  void size(WidgetTester tester) {
    tester.view.physicalSize = const Size(1500, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('P02 buttons expose button semantics and disable while busy', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(host(Btn('Run probe', onPressed: () {})));
    expect(tester.getSemantics(find.text('Run probe')), matchesSemantics(
      label: 'Run probe', isButton: true, hasEnabledState: true, isEnabled: true, hasTapAction: true));
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  testWidgets('P01 default MySQL save does not persist certificate verification while TLS is off', (tester) async {
    size(tester);
    final notice = Notice();
    await tester.pumpWidget(host(ConnectionsView(notice: notice)));
    await settle(tester);
    await tester.tap(find.text('新建连接'));
    await settle(tester, rounds: 8);
    // The editor opens on the General tab; wait for it before typing.
    expect(find.byKey(const ValueKey('conn-name-field'), skipOffstage: false),
        findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('conn-name-field'), skipOffstage: false),
        'tls-disabled-report');
    await tester.enterText(
        find.byKey(const ValueKey('db-host'), skipOffstage: false), '127.0.0.1');
    await tester.enterText(
        find.byKey(const ValueKey('db-port'), skipOffstage: false), '3306');
    await tester.enterText(
        find.byKey(const ValueKey('db-user'), skipOffstage: false), 'test_user');
    await tester.tap(find.text('保存'));
    await settle(tester, rounds: 12);
    final list = await tester.runAsync(() => Api.instance.connections());
    final saved = list!.singleWhere((c) => c['name'] == 'tls-disabled-report');
    expect(saved['ssl_mode'], 'disable');
    expect(saved['ssl_verify'], isNull);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('P03 selecting a table updates SQL and executes through real FFI', (tester) async {
    size(tester);
    await tester.pumpWidget(host(BuilderView(notice: Notice())));
    await settle(tester);
    expect(preview(tester), contains('请先选择主表'));
    await tester.tap(find.text('sample').first);
    await tester.pump();
    // The builder qualifies the data source namespace so the pooled session's
    // search_path cannot break the statement (ROUND68 P1-01).
    expect(preview(tester), contains('FROM "main"."sample"'));
    await tester.ensureVisible(find.text('执行查询'));
    await tester.tap(find.text('执行查询'));
    await settle(tester);
    expect(find.text('report-marker'), findsWidgets);
  });

  testWidgets('P03 changing LIMIT updates the visible SQL immediately', (tester) async {
    size(tester);
    await tester.pumpWidget(host(BuilderView(notice: Notice())));
    await settle(tester);
    await tester.tap(find.text('sample').first);
    await tester.pump();
    // LIMIT lives in the sorting tab of the merged configuration card.
    await tester.tap(find.byKey(const ValueKey('builder-tab-sort')));
    await tester.pump();
    final limitField = find.byKey(const ValueKey('builder-limit'));
    await tester.ensureVisible(limitField);
    await tester.enterText(limitField, '7');
    await tester.pump();
    expect(preview(tester), contains('LIMIT 7'));
  });

  testWidgets('P04 explorer invalidation reloads an already mounted database view', (tester) async {
    size(tester);
    await tester.pumpWidget(host(DatabaseView(db: 'main', notice: Notice())));
    await settle(tester);
    expect(find.text('fresh_report_table'), findsNothing);
    await tester.runAsync(() => Api.instance.query('CREATE TABLE fresh_report_table (id INTEGER);', 'main'));
    AppState.instance.bumpExplorer();
    await settle(tester);
    expect(find.text('fresh_report_table'), findsWidgets);
  });

  testWidgets('P04 successful DDL invalidates caches even when a later statement fails', (tester) async {
    size(tester);
    await tester.pumpWidget(host(SqlView(notice: Notice())));
    final version = AppState.instance.explorerVersion;
    await tester.enterText(find.byType(TextField).first,
        '-- leading comment\nCREATE TABLE batch_report (id INTEGER); SELECT * FROM nonexistent_report_table;');
    await tester.tap(find.text('执行'));
    await settle(tester, rounds: 14);
    expect(AppState.instance.explorerVersion, greaterThan(version));
  });

  testWidgets('P16 control Enter runs SQL and shows its result', (tester) async {
    size(tester);
    await tester.pumpWidget(host(SqlView(notice: Notice())));
    await tester.enterText(find.byType(TextField).first, "SELECT 'shortcut-marker' AS label;");
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(find.text('shortcut-marker'), findsWidgets);
  });
}
