// Regression tests for dragging the result preview sideways.
//
// Reported (round 34, user): 「查询构建器中结果浏览无法左右拖动查看」.
//
// Round 27 had already added a `Scrollbar(thumbVisibility: true)` and a
// `ScrollConfiguration(dragDevices: {..., mouse})` around the horizontal
// `SingleChildScrollView`, and its tests dragged on a **perfectly horizontal**
// path — which is why they stayed green while the real thing was still dead.
//
// The actual cause is the nested vertical `ListView`: it inherits the same
// dragDevices (the configuration is inherited), so a mouse drag that moves even
// one pixel vertically puts a `VerticalDragGestureRecognizer` into the gesture
// arena next to the horizontal one. The vertical recogniser is added first and
// self-declares as soon as `dy` clears the 1px precise-pointer hit slop, so it
// wins the arena and the horizontal offset never moves. A real mouse drag always
// wobbles a pixel or two, hence "0px, always".
//
// These tests therefore drag on realistic (slightly diagonal) paths, from the
// four places a user can start: a data cell, the header, empty space in the
// card, and the scrollbar thumb.
import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/builder/builder_editors.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/builder_view.dart';

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(body: child),
    );

List<BuilderPreviewColumn> columns(int count) => [
      for (var i = 0; i < count; i++)
        BuilderPreviewColumn('column_$i', 'TEXT'),
    ];

List<List<Object?>> rows(int rowCount, int columnCount) => [
      for (var r = 0; r < rowCount; r++)
        [for (var c = 0; c < columnCount; c++) 'r${r}c$c'],
    ];

Finder horizontalScroller() => find.byWidgetPredicate(
      (widget) =>
          widget is SingleChildScrollView &&
          widget.scrollDirection == Axis.horizontal,
      skipOffstage: false,
    );

ScrollController controllerOf(WidgetTester tester) =>
    tester.widget<SingleChildScrollView>(horizontalScroller()).controller!;

/// A mouse drag whose path wobbles vertically, like a real hand on a mouse.
///
/// The vertical component is what the nested [ListView] used to steal; keep it
/// in every drag helper so the regression cannot silently come back.
Future<double> mouseDrag(
  WidgetTester tester,
  Offset start, {
  double dx = -200,
  double dyPerStep = 2,
  int steps = 10,
}) async {
  final controller = controllerOf(tester);
  final before = controller.offset;
  final gesture =
      await tester.startGesture(start, kind: PointerDeviceKind.mouse);
  await tester.pump(const Duration(milliseconds: 16));
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(Offset(dx / steps, dyPerStep));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pumpAndSettle();
  return controller.offset - before;
}

Future<void> pumpWidePreview(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(host(SizedBox(
    width: 880,
    height: 400,
    child: BuilderPreviewTable(columns: columns(12), rows: rows(50, 12)),
  )));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a mouse drag from a data cell scrolls sideways', (tester) async {
    await pumpWidePreview(tester);
    expect(controllerOf(tester).offset, 0);

    // Before the round-34 fix this delta was exactly 0.0: the inner vertical
    // ListView won the arena because the drag had a 2px vertical component.
    final delta = await mouseDrag(tester, tester.getCenter(find.text('r3c2')));
    expect(delta, greaterThan(100),
        reason: 'a drag started on a cell must move the table sideways');
  });

  testWidgets('a mouse drag from the header scrolls sideways', (tester) async {
    await pumpWidePreview(tester);
    final delta = await mouseDrag(tester, tester.getCenter(find.text('column_1')));
    expect(delta, greaterThan(100),
        reason: 'the header is part of the table and must drag too');
  });

  testWidgets('a mouse drag from the empty card area scrolls sideways',
      (tester) async {
    await pumpWidePreview(tester);
    // Below the last row of a 50-row list is not empty, so use the scrollbar
    // gutter strip instead: the bottom 10px of the viewport, over the table but
    // not over a cell.
    final rect = tester.getRect(find.byType(BuilderPreviewTable));
    final delta =
        await mouseDrag(tester, Offset(rect.center.dx, rect.bottom - 4));
    expect(delta, greaterThan(100),
        reason: 'the scrollbar gutter is part of the drag surface');
  });

  testWidgets('dragging the scrollbar thumb scrolls sideways', (tester) async {
    await pumpWidePreview(tester);
    final controller = controllerOf(tester);
    final bars = tester
        .widgetList<Scrollbar>(find.byType(Scrollbar, skipOffstage: false))
        .where((bar) => identical(bar.controller, controller));
    expect(bars, hasLength(1));
    final barRect = tester.getRect(find.byWidget(bars.single));
    await tester.dragFrom(
      Offset(barRect.left + 30, barRect.bottom - 6),
      const Offset(-200, 0),
    );
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
  });

  testWidgets('a downward-drifting drag still scrolls sideways',
      (tester) async {
    await pumpWidePreview(tester);
    // A steep arc: 6px down per 20px left. The horizontal drag must still win,
    // otherwise a user who does not move the mouse perfectly straight gets a
    // dead table (the reported symptom).
    final delta = await mouseDrag(
      tester,
      tester.getCenter(find.text('r5c1')),
      dyPerStep: 6,
    );
    expect(delta, greaterThan(100));
  });

  testWidgets('vertical scrolling still works with the wheel', (tester) async {
    await pumpWidePreview(tester);
    final vertical = tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .map((state) => state.position)
        .firstWhere((position) => position.axis == Axis.vertical);
    expect(vertical.maxScrollExtent, greaterThan(0));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.text('r3c2'))),
    );
    // Positive dy scrolls the content up (i.e. moves towards later rows).
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
    await tester.pumpAndSettle();
    expect(vertical.pixels, greaterThan(0),
        reason: 'the fix must not break wheel scrolling');
    // And the wheel must not have scrolled the table sideways.
    expect(controllerOf(tester).offset, 0);
  });

  testWidgets('the horizontal thumb is visible on the dark palette',
      (tester) async {
    // Reported alongside "拖不动": the user saw **no** scrollbar at all. The
    // app-wide thumb is 0x55000000 (33% black); composited onto the dark
    // panel (#161D26) it differs from the background by ~7/255, i.e. invisible.
    AppColors.apply(AppPalette.darkBase);
    addTearDown(() => AppColors.apply(AppPalette.lightBase));
    await pumpWidePreview(tester);

    final controller = controllerOf(tester);
    final bar = tester
        .widgetList<Scrollbar>(find.byType(Scrollbar, skipOffstage: false))
        .singleWhere((bar) => identical(bar.controller, controller));
    expect(bar.thumbVisibility, isTrue);

    // The theme the bar resolves must produce a thumb that actually contrasts
    // with the preview's background.
    final theme = tester.widget<ScrollbarTheme>(find.ancestor(
      of: find.byWidget(bar),
      matching: find.byType(ScrollbarTheme),
    ));
    final thumb =
        theme.data.thumbColor!.resolve(const <WidgetState>{})!;
    final background = AppColors.panel;
    final composited = Color.alphaBlend(thumb, background);
    double channelDelta(Color a, Color b) {
      final dr = (a.r - b.r).abs() * 255;
      final dg = (a.g - b.g).abs() * 255;
      final db = (a.b - b.b).abs() * 255;
      return dr + dg + db;
    }

    expect(channelDelta(composited, background), greaterThan(30),
        reason: 'a thumb indistinguishable from the panel is not a scrollbar');
  });

  testWidgets('a narrow preview stays scrollbar-free', (tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(SizedBox(
      width: 880,
      height: 400,
      child: BuilderPreviewTable(columns: columns(2), rows: rows(3, 2)),
    )));
    await tester.pumpAndSettle();
    expect(horizontalScroller(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  group('inside the real builder layout chain', () {
    late Directory dir;

    setUpAll(() async {
      final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
      if (!dylib.existsSync()) {
        fail('Run cargo build --lib in rust/ first: ${dylib.path}');
      }
      await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
      dir = await Directory.systemTemp.createTemp('rma-preview-drag-');
      final init = await Api.init(dir.path);
      expect(init['ok'], isTrue, reason: 'init_app failed: $init');
      await AppState.instance.bootstrap(dir.path);
      final databasePath = '${dir.path}/drag.sqlite';
      File(databasePath).createSync(recursive: true);
      final created = await Api.instance.createConnection(<String, dynamic>{
        'name': 'preview-drag',
        'driver': 'sqlite',
        'database': databasePath,
      });
      final id = (created['connection'] as Map)['id'].toString();
      await AppState.instance.connect(id);
      final fields = [for (var i = 1; i <= 40; i++) 'c$i TEXT'];
      await Api.instance.query(
          'CREATE TABLE wide40 (id INTEGER PRIMARY KEY, ${fields.join(', ')});');
      final values = [for (var i = 1; i <= 40; i++) "'r1_c$i'"];
      await Api.instance.query(
          'INSERT INTO wide40 VALUES (1, ${values.join(', ')});');
      await AppState.instance.refreshDatabases();
    });

    tearDownAll(() async {
      await AppState.instance.disconnect();
      await dir.delete(recursive: true);
    });

    Future<void> settle(WidgetTester tester, {int rounds = 10}) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 80)));
        await tester.pump(const Duration(milliseconds: 80));
      }
    }

    testWidgets('the preview gets a finite width and drags in the real card',
        (tester) async {
      // 1222x810 is the window size the user reported the bug at.
      tester.view.physicalSize = const Size(1222, 810);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(host(BuilderView(notice: Notice())));
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('builder-table-wide40')));
      await settle(tester, rounds: 3);
      await tester.tap(find.text('全部'));
      await settle(tester, rounds: 2);
      await tester.tap(find.byKey(const ValueKey('builder-run')));
      await settle(tester, rounds: 16);

      final preview = find.byType(BuilderPreviewTable);
      expect(preview, findsOneWidget);
      // The card must hand the preview a *finite* width; an unbounded one would
      // silently pick the narrow branch (no scroller, no scrollbar) and clip the
      // right-hand columns instead of scrolling them.
      final width = tester.getSize(preview).width;
      expect(width.isFinite, isTrue);
      expect(width, greaterThan(300));

      expect(horizontalScroller(), findsOneWidget,
          reason: '40 columns in a ~860px card must overflow');

      final controller = controllerOf(tester);
      expect(controller.position.maxScrollExtent, greaterThan(0));
      final cell = find.text('r1_c2');
      expect(cell, findsOneWidget);
      final delta = await mouseDrag(tester, tester.getCenter(cell));
      expect(delta, greaterThan(100),
          reason: 'the reported bug: dragging the real preview did nothing');
      expect(tester.takeException(), isNull);
    });
  });
}
