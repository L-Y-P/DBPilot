// Regression tests for the layout and dialog defects reported after handover.
//
// Every test here pins a bug that shipped in the first desktop build:
//
//   * GridTable collapsed to zero width inside its horizontal scroller, which
//     turned the backup list (and every other table) into a one-character-wide
//     vertical strip;
//   * the structure-sync toolbar mixed a 69px field with 36px selects and a
//     25px checkbox, so the controls sat on three different baselines;
//   * "test connection" stored its result in state the dialog never rebuilt, so
//     nothing was ever shown, and "save" never closed the editor;
//   * Api.connections() unwrapped the Rust envelope incorrectly and returned an
//     empty list, so a saved connection vanished from the manager.
//
// The pure-widget cases run without a database; the dialog cases boot the real
// Rust core against a throwaway SQLite file, like app_shell_test.dart does.

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
import 'package:rust_myadmin_desktop/src/views/connections_view.dart';
import 'package:rust_myadmin_desktop/src/views/sync_view.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

/// Pump on a real event loop so bridge futures can complete (fake clock would
/// never let them finish); see app_shell_test.dart's settle().
Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(body: child),
    );

void main() {
  // The Rust core is a process-wide singleton (OnceLock), so it is booted once
  // for the whole file rather than per group.
  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run `cargo build --lib` in rust/ first: ${dylib.path} is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    final dir = await Directory.systemTemp.createTemp('rma-regress-');
    final init = await Api.init(dir.path);
    expect(init['ok'], isTrue, reason: 'init_app failed: $init');
    await AppState.instance.bootstrap(dir.path);
  });

  group('GridTable', () {
    testWidgets('gives every column a real width inside a horizontal scroller',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(host(CardBox(
        child: GridTable(
          headers: const [Text('文件'), Text('驱动'), Text('大小')],
          rows: const [
            TableRow(children: [Text('a.sql'), Text('mysql'), Text('6 KB')]),
          ],
        ),
      )));
      await tester.pumpAndSettle();

      final table = tester.getSize(find.byType(Table));
      // Regression: this used to be Size(0.0, ...) and every glyph was clipped.
      expect(table.width, greaterThan(100),
          reason: 'columns collapsed to zero width');
      for (final label in ['文件', '驱动', '大小']) {
        expect(tester.getSize(find.text(label)).width, greaterThan(0),
            reason: '$label column has no width');
      }
    });

    testWidgets('keeps an empty table visible', (tester) async {
      await tester.pumpWidget(host(CardBox(
        child: GridTable(
          headers: const [Text('A'), Text('B')],
          rows: const [],
          emptyText: '暂无备份。',
        ),
      )));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(Table)).width, greaterThan(0));
      expect(find.text('暂无备份。'), findsOneWidget);
    });
  });

  group('Field and ControlGroup', () {
    testWidgets('an empty label takes no vertical space', (tester) async {
      await tester.pumpWidget(host(const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 200, child: Field(label: '', hint: 'x')),
          SizedBox(width: 200, child: Field(label: '单表', hint: 'y')),
        ],
      )));
      await tester.pumpAndSettle();
      final unlabelled = tester.getSize(find.byType(Field).first);
      final labelled = tester.getSize(find.byType(Field).last);
      expect(labelled.height - unlabelled.height, greaterThan(10),
          reason: 'only the labelled field should carry a caption row');
    });

    testWidgets('toolbar controls share one height', (tester) async {
      await tester.pumpWidget(host(SizedBox(
        width: 900,
        child: Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            ControlGroup(
              label: '源',
              width: 200,
              child: SelectBox<String>(
                value: 'a',
                onChanged: (_) {},
                items: const [DropdownMenuItem(value: 'a', child: Text('a'))],
              ),
            ),
            ControlGroup(
              label: '单表',
              width: 200,
              height: kControlHeight,
              child: const Field(label: '', hint: 'employees', compact: true),
            ),
            ControlGroup(
              label: '',
              height: kControlHeight,
              child: const Btn('比较'),
            ),
          ],
        ),
      )));
      await tester.pumpAndSettle();

      double heightOf(Type type) => tester.getSize(find.byType(type).first).height;
      expect(heightOf(SelectBox<String>), kControlHeight);
      expect(heightOf(TextField), kControlHeight);
      expect(heightOf(Btn), kControlHeight);

      // Bottom edges must line up, which is what the eye reads as "one row".
      final bottoms = [
        tester.getBottomLeft(find.byType(SelectBox<String>)).dy,
        tester.getBottomLeft(find.byType(TextField)).dy,
        tester.getBottomLeft(find.byType(Btn)).dy,
      ];
      expect(bottoms.toSet().length, 1, reason: 'controls are not on one row');
    });
  });

  group('structure sync and backups toolbars', () {
    testWidgets('sync keeps its four controls on a single row', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // The toolbar only renders when at least two user namespaces exist; the
      // test boots without a connection, so provide a pair of fake ones. The
      // table probe is allowed to fail (the view catches it).
      final state = AppState.instance;
      final previousConnection = state.connection;
      final previousDatabases = state.databases;
      state.connection = <String, dynamic>{
        'driver': 'mysql',
        'driver_label': 'MySQL',
        'label': 'test',
      };
      state.databases = <Json>[
        <String, dynamic>{'name': 'a'},
        <String, dynamic>{'name': 'b'},
      ];
      addTearDown(() {
        state.connection = previousConnection;
        state.databases = previousDatabases;
      });

      await tester.pumpWidget(host(SyncView(notice: Notice())));
      await settle(tester);

      final groups = find.byType(ControlGroup);
      expect(groups.evaluate().length, 4);
      final bottoms = <double>[];
      for (var i = 0; i < 4; i++) {
        bottoms.add(tester.getBottomLeft(groups.at(i)).dy);
      }
      expect(bottoms.toSet().length, 1,
          reason: 'sync controls wrapped onto multiple lines: $bottoms');
      // The three captioned controls also share a top edge.
      final tops = <double>[];
      for (var i = 0; i < 3; i++) {
        tops.add(tester.getTopLeft(groups.at(i)).dy);
      }
      expect(tops.toSet().length, 1,
          reason: 'sync captions are not on one line: $tops');

      // The checkbox must line up with the inputs, not float above them.
      final checkbox = tester.getRect(find.byType(CheckBox));
      final select = tester.getRect(find.byType(SelectBox<String>).first);
      expect((checkbox.center.dy - select.center.dy).abs(), lessThan(2));
    });

    testWidgets('backup list renders a readable table', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(host(BackupsView(notice: Notice())));
      await settle(tester);

      final table = tester.getSize(find.byType(Table).first);
      expect(table.width, greaterThan(300),
          reason: 'backup table collapsed again');
      expect(find.text(t('backup_none')), findsOneWidget);
    });
  });

  group('connection editor', () {
    testWidgets('a failed probe is reported inside the dialog', (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(host(ConnectionsView(notice: Notice())));
      await settle(tester);
      await tester.tap(find.text('新建连接'));
      await settle(tester, rounds: 4);

      // Switch to SQLite and point it at a directory that does not exist: the
      // probe fails immediately (a refused TCP port would sit in the 15s
      // acquire_timeout and outlive the test's settle loop).
      await tester.tap(find.byType(SelectBox<String>).first);
      await settle(tester, rounds: 3);
      await tester.tap(find.text('SQLite').last);
      await settle(tester, rounds: 4);
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(1), '/nonexistent-dir/regress.sqlite');
      await settle(tester, rounds: 2);

      await tester.tap(find.text('测试连接'));
      await settle(tester, rounds: 16);

      expect(find.byType(Dialog), findsOneWidget);
      final alerts = find.byType(AlertBox);
      expect(alerts.evaluate(), isNotEmpty,
          reason: 'the probe result never reached the dialog');
      final message = tester.widget<AlertBox>(alerts.last).message;
      expect(message, contains('连接失败'), reason: message);
    });

    testWidgets('PostgreSQL editor is instance-level and starts without SSL',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(host(ConnectionsView(notice: Notice())));
      await settle(tester);
      await tester.tap(find.text('新建连接'));
      await settle(tester, rounds: 4);

      await tester.tap(find.byType(SelectBox<String>).first);
      await settle(tester, rounds: 3);
      await tester.tap(find.text('PostgreSQL').last);
      await settle(tester, rounds: 4);

      // The editor is split into General/SSL/SSH tabs.
      expect(find.text('默认数据库（可选）'), findsOneWidget);
      expect(find.text('仅显示数据库'), findsOneWidget);
      expect(find.text('隐藏数据库'), findsOneWidget);
      expect(find.text('连接字符集'), findsNothing);

      // SSL fields live on their own tab now. Switching there must show the
      // libpq mode and keep the MySQL idle `verify-full` out of the PG form.
      await tester.tap(find.text('SSL').last);
      await settle(tester, rounds: 3);
      expect(find.text('SSL 模式（libpq）'), findsOneWidget);
      expect(find.text('disable'), findsOneWidget);
      expect(find.text('verify-full'), findsNothing);
      expect(find.text('CA 证书'), findsNothing);
    });

    testWidgets('saving closes the dialog and lists the new connection',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final notice = Notice();
      await tester.pumpWidget(host(ConnectionsView(notice: notice)));
      await settle(tester);

      final before = await tester.runAsync(() => Api.instance.connections());
      await tester.tap(find.text('新建连接'));
      await settle(tester, rounds: 4);

      await tester.enterText(
          find.byKey(const ValueKey('conn-name-field'), skipOffstage: false), '回归测试连接');
      await tester.enterText(
          find.byKey(const ValueKey('db-host'), skipOffstage: false), '127.0.0.1');
      await tester.enterText(
          find.byKey(const ValueKey('db-user'), skipOffstage: false), 'root');

      await tester.tap(find.text('保存'));
      await settle(tester, rounds: 16);

      // The dialog must be gone, not left open behind a success toast.
      expect(find.byType(Dialog), findsNothing);
      expect(notice.message, '连接已保存');

      // ...and the list must actually contain the new entry.
      final after = await tester.runAsync(() => Api.instance.connections());
      expect(after!.length, before!.length + 1);
      expect(after.any((c) => c['name'] == '回归测试连接'), isTrue,
          reason: 'saved connection missing from Api.connections()');
      expect(find.text('回归测试连接'), findsWidgets,
          reason: 'the connection card did not render');

      // Let the notice timers expire so the test does not leak pending timers.
      await tester.pump(const Duration(seconds: 4));
    });
  });
}