// Performance switches: the settings-dialog section, their persistence, and the
// two places the grids consume them.
//
// Contract pinned here:
//   * both switches default to ON, including when the settings file predates
//     them (the Rust core may not return the keys at all yet);
//   * turning auto-fit off makes the DataGrid pin every column to one fixed
//     width and skip the TextPainter measuring pass;
//   * turning lazy loading on renders a long value as a short preview plus a
//     "… N 字符" badge, while the full value stays available (hover + the
//     double-click viewer);
//   * flipping a switch updates an already-built grid without a restart.

import 'dart:io';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/components/data_grid.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';
import 'package:rust_myadmin_desktop/src/i18n_literals.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/text.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

/// Boots the real Rust core, like test/settings_dialog_test.dart does, so the
/// persistence path below is the production one.
Future<void> _boot() async {
  final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
  if (!dylib.existsSync()) {
    fail('Run `cargo build --lib` in rust/ first: ${dylib.path} is missing');
  }
  await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
  final dir = Directory('${Directory.systemTemp.path}/rma-perf-settings');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  await dir.create(recursive: true);
  final init = await Api.init(dir.path);
  expect(init['ok'], isTrue, reason: 'init_app failed: $init');
  await AppState.instance.bootstrap(dir.path);
  expect(AppState.instance.bootstrapError, isNull,
      reason: 'bootstrap failed: ${AppState.instance.bootstrapError}');
}

Widget _host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

List<Map<String, dynamic>> _columns(int count) => <Map<String, dynamic>>[
      for (var i = 0; i < count; i++)
        <String, dynamic>{'name': 'column_$i', 'type_name': 'TEXT'},
    ];

Finder _header(String name) =>
    find.byWidgetPredicate((widget) => widget is Text && widget.data == name);

/// Left edge of every built data cell of the first row.
///
/// The cells are looked up by their rendered text: `_rows` writes "r0cN".
List<double> _cellLefts(WidgetTester tester, List<String> values) => <double>[
      for (final value in values)
        tester
            .getTopLeft(find.byWidgetPredicate(
                (widget) => widget is Text && widget.data == value))
            .dx,
    ];

void main() {
  setUpAll(_boot);

  setUp(() {
    I18n.setLang(AppLang.zh);
    AppState.instance.autoColumnWidth = true;
    AppState.instance.lazyBigFields = true;
  });

  tearDown(() {
    AppState.instance.autoColumnWidth = true;
    AppState.instance.lazyBigFields = true;
    I18n.setLang(AppLang.zh);
  });

  group('defaults and persistence', () {
    test('both switches default to on', () {
      expect(AppState.instance.autoColumnWidth, isTrue);
      expect(AppState.instance.lazyBigFields, isTrue);
    });

    test('a missing or unparsable setting keeps the default (on)', () {
      // A core that predates the fields returns no key at all; a hand-edited
      // file can hold a string. Neither may silently disable the feature.
      expect(AppState.readBoolSetting(null), isTrue);
      expect(AppState.readBoolSetting(true), isTrue);
      expect(AppState.readBoolSetting(false), isFalse);
      expect(AppState.readBoolSetting(1), isTrue);
      expect(AppState.readBoolSetting(0), isFalse);
      expect(AppState.readBoolSetting('true'), isTrue);
      expect(AppState.readBoolSetting('false'), isFalse);
      expect(AppState.readBoolSetting('off'), isFalse);
      expect(AppState.readBoolSetting('nonsense'), isTrue);
    });

    test('bootstrap reads the persisted fields from the core', () async {
      await AppState.instance.setAutoColumnWidth(false);
      await AppState.instance.setLazyBigFields(false);

      // The Rust core owns the settings file. It may not know these two fields
      // yet (they are added by the backend task), in which case saving drops
      // them and the UI must fall back to "on" rather than crash or disable the
      // features. Both outcomes are correct; only a silent mismatch is not.
      final settings = await Api.instance.getSettings();
      final coreKnowsAutoWidth = settings.containsKey('auto_column_width');
      final coreKnowsLazyFields = settings.containsKey('lazy_big_fields');

      if (coreKnowsAutoWidth) {
        expect(settings['auto_column_width'], isFalse,
            reason: 'a switch that was turned off must persist as false');
      }
      if (coreKnowsLazyFields) {
        expect(settings['lazy_big_fields'], isFalse);
      }

      // A fresh bootstrap re-reads whatever the core holds: the persisted false
      // when the field exists, the safe default (true) when it does not.
      AppState.instance.autoColumnWidth = true;
      AppState.instance.lazyBigFields = true;
      await AppState.instance.bootstrap(AppState.instance.dataDir);
      expect(AppState.instance.autoColumnWidth, coreKnowsAutoWidth ? isFalse : isTrue);
      expect(AppState.instance.lazyBigFields, coreKnowsLazyFields ? isFalse : isTrue);

      // Leave the persisted state on the defaults for the widget tests below.
      await AppState.instance.setAutoColumnWidth(true);
      await AppState.instance.setLazyBigFields(true);
    });

    test('the setters notify and persist', () async {
      var notifications = 0;
      void listener() => notifications++;
      AppState.instance.addListener(listener);
      addTearDown(() => AppState.instance.removeListener(listener));

      await AppState.instance.setAutoColumnWidth(false);
      expect(AppState.instance.autoColumnWidth, isFalse);
      expect(notifications, 1,
          reason: 'the grid rebuilds from AppState, so it must be notified');

      // A no-op write does not notify twice.
      await AppState.instance.setAutoColumnWidth(false);
      expect(notifications, 1);

      await AppState.instance.setLazyBigFields(false);
      expect(AppState.instance.lazyBigFields, isFalse);
      expect(notifications, 2);

      // Restore for the widget tests below (and for the next test file).
      await AppState.instance.setAutoColumnWidth(true);
      await AppState.instance.setLazyBigFields(true);
      expect(notifications, 4);
    });
  });

  group('auto column width', () {
    testWidgets('off pins every column to the fixed width', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      AppState.instance.autoColumnWidth = false;
      // Deliberately very different value lengths: with measuring on, the
      // columns would end up different widths.
      final rows = <List<dynamic>>[
        <dynamic>['a', 'b' * 120, 'c'],
      ];
      await tester.pumpWidget(_host(DataGrid(
        columns: _columns(3),
        rows: rows,
      )));
      await tester.pumpAndSettle();

      final lefts = _cellLefts(tester, <String>['a', 'b' * 120, 'c']);
      for (var i = 1; i < lefts.length; i++) {
        expect(lefts[i] - lefts[i - 1], kFixedGridColumnWidth,
            reason: 'column $i must be exactly the fixed width');
      }
      // The header row uses the same map, so it lines up with the cells.
      final headerLeft = tester.getTopLeft(_header('column_1(TEXT)')).dx;
      expect((headerLeft - lefts[1]).abs(), lessThan(0.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('on measures the content instead', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      AppState.instance.autoColumnWidth = true;
      final rows = <List<dynamic>>[
        <dynamic>['a', 'b' * 120, 'c'],
      ];
      await tester.pumpWidget(_host(DataGrid(
        columns: _columns(3),
        rows: rows,
      )));
      await tester.pumpAndSettle();

      final lefts = _cellLefts(tester, <String>['a', 'b' * 120, 'c']);
      // The middle column carries the long value, so it is measurably wider
      // than the fixed width would be.
      expect(lefts[2] - lefts[1], greaterThan(kFixedGridColumnWidth));
      expect(tester.takeException(), isNull);
    });

    testWidgets('flipping the switch re-lays out a grid that is already built',
        (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final rows = <List<dynamic>>[
        <dynamic>['a', 'b' * 120, 'c'],
      ];
      await tester.pumpWidget(_host(DataGrid(
        columns: _columns(3),
        rows: rows,
      )));
      await tester.pumpAndSettle();
      final values = <String>['a', 'b' * 120, 'c'];
      final measured = _cellLefts(tester, values);
      expect(measured[2] - measured[1], greaterThan(kFixedGridColumnWidth));

      // No rebuild of the widget tree: only the notifier fires.
      await tester.runAsync(() => AppState.instance.setAutoColumnWidth(false));
      await tester.pumpAndSettle();
      final fixed = _cellLefts(tester, values);
      expect(fixed[1] - fixed[0], kFixedGridColumnWidth);
      expect(fixed[2] - fixed[1], kFixedGridColumnWidth);
    });

    testWidgets('GridTable skips the measuring pass and uses fixed widths',
        (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      AppState.instance.autoColumnWidth = false;
      // Above virtualizeAfter so the virtualised (measuring) path is taken.
      final rows = <TableRow>[
        for (var r = 0; r < 200; r++)
          TableRow(children: <Widget>[
            Text('r$r-${'x' * 40}'),
            Text('s$r'),
            Text('m$r'),
          ]),
      ];
      await tester.pumpWidget(_host(GridTable(
        headers: const <Widget>[Text('A'), Text('B'), Text('C')],
        rows: rows,
      )));
      // Two pumps: no measure-then-freeze dance is needed, but the frame has to
      // be built at all.
      await tester.pump();
      await tester.pump();

      // Fixed widths: the header cells are exactly one constant apart...
      final a = tester.getRect(find.text('A').first);
      final b = tester.getRect(find.text('B').first);
      expect((b.left - a.left).abs(), kFixedGridColumnWidth);
      // ...and the body columns use the very same constant, so header and rows
      // cannot drift apart.
      final cellA = tester.getRect(find.text('r0-${'x' * 40}'));
      final cellB = tester.getRect(find.text('s0'));
      expect((cellB.left - cellA.left).abs(), kFixedGridColumnWidth);
      expect(tester.takeException(), isNull);
    });
  });

  group('English copy', () {
    test('the performance section and the badge are translated', () {
      I18n.setLang(AppLang.en);
      expect(trLiteral('性能'), 'Performance');
      expect(trLiteral('自动调整列宽'), 'Auto-fit column widths');
      expect(trLiteral('大字段延迟加载'), 'Lazy-load large fields');
      expect(trLiteral('关闭自动列宽后所有列使用固定宽度，宽表首帧更快；'
              '大字段延迟加载只渲染长值的前 120 个字符，双击单元格仍可查看完整内容。'),
          contains('every column uses a fixed width'));
      // The lazy badge is UI copy with a number in it: it must read naturally
      // in English too, not fall back to the Chinese template.
      expect(trLiteral('… 1536 字符'), '… 1536 chars');
      I18n.setLang(AppLang.zh);
    });
  });

  group('lazy big fields', () {
    /// A value comfortably above the 200-character threshold.
    final String bigValue = 'START-${'x' * 400}-END';

    testWidgets('a long value renders a preview and a badge', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      AppState.instance.lazyBigFields = true;
      await tester.pumpWidget(_host(DataGrid(
        columns: _columns(1),
        rows: <List<dynamic>>[
          <dynamic>[bigValue],
        ],
      )));
      await tester.pumpAndSettle();

      // Only the preview is in the tree, not the whole value.
      final preview = bigValue.substring(0, kLazyBigFieldPreview);
      expect(find.text(preview), findsOneWidget);
      expect(find.text(bigValue), findsNothing,
          reason: 'the full value must not be laid out in the cell');
      // ...and the badge says how much there is.
      expect(find.byKey(const ValueKey('grid-lazy-badge')), findsOneWidget);
      expect(find.text('… ${bigValue.length} 字符'), findsOneWidget);
    });

    testWidgets('with the switch off the whole value is rendered',
        (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      AppState.instance.lazyBigFields = false;
      await tester.pumpWidget(_host(DataGrid(
        columns: _columns(1),
        rows: <List<dynamic>>[
          <dynamic>[bigValue],
        ],
      )));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('grid-lazy-badge')), findsNothing);
      expect(find.text(bigValue), findsOneWidget);
    });

    testWidgets('a short value is never previewed', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      AppState.instance.lazyBigFields = true;
      final short = 'x' * (kLazyBigFieldThreshold - 1);
      await tester.pumpWidget(_host(DataGrid(
        columns: _columns(1),
        rows: <List<dynamic>>[
          <dynamic>[short],
        ],
      )));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('grid-lazy-badge')), findsNothing);
      expect(find.text(short), findsOneWidget);
    });

    testWidgets('double-clicking a previewed cell still shows the whole value',
        (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      AppState.instance.lazyBigFields = true;
      await tester.pumpWidget(_host(DataGrid(
        columns: _columns(1),
        rows: <List<dynamic>>[
          <dynamic>[bigValue],
        ],
      )));
      await tester.pumpAndSettle();

      // The preview text is the cell's hit target.
      await tester.tap(find.text(bigValue.substring(0, kLazyBigFieldPreview)));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(find.text(bigValue.substring(0, kLazyBigFieldPreview)));
      await tester.pumpAndSettle();

      // The viewer is a TextField holding the FULL value.
      final fields = tester
          .widgetList<TextField>(find.byType(TextField, skipOffstage: false))
          .toList();
      expect(fields, isNotEmpty, reason: 'double-click opens the value viewer');
      expect(fields.any((f) => f.controller?.text == bigValue), isTrue,
          reason: 'the viewer must hold the complete value, not the preview');
    });

    testWidgets('the hover tooltip still carries the whole value',
        (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      AppState.instance.lazyBigFields = true;
      await tester.pumpWidget(_host(DataGrid(
        columns: _columns(1),
        rows: <List<dynamic>>[
          <dynamic>[bigValue],
        ],
      )));
      await tester.pumpAndSettle();

      // The preview is wider than the fixed/measured cell, so [EllipsisText]
      // exposes the full value through a tooltip message.
      final tooltip = tester
          .widgetList<Tooltip>(find.byType(Tooltip, skipOffstage: false))
          .where((t) => (t.message ?? '').contains('-END'))
          .toList();
      expect(tooltip, isNotEmpty,
          reason: 'hovering a previewed cell must still reach the full value');
      expect(tooltip.first.message, contains(bigValue.substring(0, 100)));
    });
  });
}
