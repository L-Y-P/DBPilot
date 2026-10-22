// Paths and debug labels are composed from a temp directory; explicit
// concatenation is clearer than nested interpolation in the setup block.
// ignore_for_file: prefer_interpolation_to_compose_strings
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/builder_view.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

Future<void> settle(WidgetTester tester, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(body: child),
    );

/// SQL shown by the builder's SQL strip.
///
/// The strip starts collapsed (it only renders its one-line summary), so this
/// falls back to the longest text inside the strip when the code block is not
/// mounted. Both forms contain the same statement text.
String previewSql(WidgetTester tester) {
  final codeBlocks = tester
      .widgetList<CodeBlock>(find.byType(CodeBlock))
      .map((widget) => widget.text)
      .join(String.fromCharCode(10));
  if (codeBlocks.trim().isNotEmpty) return codeBlocks;
  final strip = find.byKey(const ValueKey('builder-sql-preview'));
  final texts = tester
      .widgetList<Text>(find.descendant(of: strip, matching: find.byType(Text)))
      .map((widget) => widget.data ?? '')
      .where((text) => text.isNotEmpty)
      .toList();
  texts.sort((a, b) => b.length.compareTo(a.length));
  return texts.isEmpty ? '' : texts.first;
}

/// Ordered widget-type skeleton of the mounted BuilderView subtree.
///
/// Sizes and offsets are deliberately not part of the signature: two renders
/// share a skeleton exactly when they walked the same build branches. A lazy
/// list (`ListView.builder`) is the one thing this cannot see through, so the
/// callers below keep the dataset small enough that both viewports build every
/// row.
String layoutSkeleton(WidgetTester tester) {
  final buffer = StringBuffer();
  void walk(Element element, int depth) {
    buffer.writeln('  ' * depth + element.widget.runtimeType.toString());
    element.visitChildren((child) => walk(child, depth + 1));
  }

  walk(find.byType(BuilderView).evaluate().single, 0);
  return buffer.toString();
}

/// The page-level padding BuilderView applies (10 narrow / 12 wide).
EdgeInsets pagePadding(WidgetTester tester) {
  final padding = tester.widget<Padding>(find
      .descendant(of: find.byType(BuilderView), matching: find.byType(Padding))
      .first);
  return padding.padding as EdgeInsets;
}

/// The page-level scroller exists only in the compact (short-window) layout, so
/// finding one above the toolbar means the page took the fallback branch.
Finder pageScroller() => find.ancestor(
      of: find.byKey(const ValueKey('builder-toolbar')),
      matching: find.byType(SingleChildScrollView),
    );

void main() {
  late Directory dir;

  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run cargo build --lib in rust/ first: ' + dylib.path + ' is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    dir = await Directory.systemTemp.createTemp('rma-builder-ui-');
    final init = await Api.init(dir.path);
    expect(init['ok'], isTrue, reason: 'init_app failed: ' + init.toString());
    await AppState.instance.bootstrap(dir.path);
    File(dir.path + '/builder.sqlite').createSync(recursive: true);
    final created = await Api.instance.createConnection(<String, dynamic>{
      'name': 'builder-ui',
      'driver': 'sqlite',
      'database': dir.path + '/builder.sqlite',
    });
    final id = (created['connection'] as Map)['id'].toString();
    await AppState.instance.connect(id);
    await Api.instance.query(
      'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, phone TEXT);'
      "INSERT INTO users VALUES (1, 'Ada', '13800000000');",
    );
    await Api.instance.query(
      'CREATE TABLE orders (id INTEGER PRIMARY KEY, '
      'user_id INTEGER REFERENCES users(id), '
      'amount NUMERIC, status TEXT, created_at TEXT);'
      "INSERT INTO orders VALUES (1, 1, 128.5, 'paid', '2026-10-01 12:03:11');"
      "INSERT INTO orders VALUES (2, 1, 240, 'open', '2026-10-02 09:15:42');",
    );
    await AppState.instance.refreshDatabases();
  });

  tearDownAll(() async {
    await AppState.instance.disconnect();
    await dir.delete(recursive: true);
  });

  void size(WidgetTester tester, {double width = 1440, double height = 940}) {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Renders a fresh BuilderView at each `content` area and returns the layout
  /// skeleton of each render. Every render must take the FIXED page layout: no
  /// page scroller, the wide 12px padding and the wide 300px data source panel.
  Future<Map<Size, String>> skeletonsAt(
    WidgetTester tester,
    List<Size> areas,
    String tag,
  ) async {
    final skeletons = <Size, String>{};
    for (final content in areas) {
      final label = tag + '-' + content.toString();
      size(tester, width: content.width, height: content.height);
      // A fresh key forces a new State, so each size starts from the same
      // empty query rather than inheriting the previous render's selections.
      await tester.pumpWidget(host(BuilderView(
        key: ValueKey('builder-bounds-' + label),
        notice: Notice(),
      )));
      await settle(tester);
      expect(find.text('orders'), findsWidgets, reason: 'schema not loaded: ' + label);
      expect(pageScroller(), findsNothing, reason: 'compact layout at ' + label);
      expect(
        tester.getSize(find.byKey(const ValueKey('builder-data-source'))).width,
        300.0,
        reason: 'narrow data source panel at ' + label,
      );
      expect(pagePadding(tester), const EdgeInsets.all(12),
          reason: 'narrow page padding at ' + label);
      expect(tester.takeException(), isNull, reason: 'exception at ' + label);
      skeletons[content] = layoutSkeleton(tester);
    }
    return skeletons;
  }

  testWidgets('fixed layout picks a primary table, adds a field and runs',
      (tester) async {
    size(tester);
    await tester.pumpWidget(host(BuilderView(notice: Notice())));
    await settle(tester);

    // The four fixed regions of the sketch are on screen.
    expect(find.byKey(const ValueKey('builder-toolbar')), findsOneWidget);
    expect(find.byKey(const ValueKey('builder-data-source')), findsOneWidget);
    expect(find.byKey(const ValueKey('builder-config')), findsOneWidget);
    expect(find.byKey(const ValueKey('builder-sql-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('builder-result-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('builder-tab-output')), findsOneWidget);
    expect(find.byKey(const ValueKey('builder-tab-join')), findsOneWidget);
    expect(find.byKey(const ValueKey('builder-tab-filter')), findsOneWidget);
    expect(find.byKey(const ValueKey('builder-tab-sort')), findsOneWidget);
    expect(find.text('orders'), findsWidgets);
    expect(find.text('users'), findsWidgets);
    expect(previewSql(tester), contains('请先选择主表'));

    // Clicking a table name makes it the FROM table.
    await tester.tap(find.byKey(const ValueKey('builder-table-orders')));
    await settle(tester, rounds: 3);
    expect(find.text('主表'), findsOneWidget);
    expect(previewSql(tester), contains('FROM "orders"'));

    // Choosing a primary expands its field list automatically, so its columns
    // are immediately reachable; clicking one adds it to the output fields.
    final field = find.byKey(const ValueKey('builder-field-orders.amount'));
    expect(field, findsOneWidget);
    await tester.tap(field);
    await settle(tester, rounds: 2);
    expect(previewSql(tester), contains('SELECT "orders"."amount"'));
    expect(find.text('amount'), findsWidgets);

    // LIMIT lives in the sorting tab and edits the SQL immediately.
    await tester.tap(find.byKey(const ValueKey('builder-tab-sort')));
    await tester.pump();
    final limit = find.byKey(const ValueKey('builder-limit'));
    await tester.ensureVisible(limit);
    await tester.enterText(limit, '5');
    await tester.pump();
    expect(previewSql(tester), contains('LIMIT 5'));
    await tester.tap(find.byKey(const ValueKey('builder-tab-output')));
    await tester.pump();

    // Execute against the real SQLite database and show the preview rows.
    await tester.tap(find.byKey(const ValueKey('builder-run')));
    await settle(tester, rounds: 14);
    expect(find.text('128.5'), findsWidgets);
    expect(find.text('240'), findsWidgets);
    expect(find.byKey(const ValueKey('builder-export')), findsOneWidget);
    expect(find.text('保存为查询模块'), findsOneWidget);
  });

  testWidgets('short window falls back to the scrolling layout without overflow',
      (tester) async {
    // The fixed layout needs vertical room; below 640px of content height the
    // page switches to fixed-height sections inside a page scroller.
    size(tester, width: 960, height: 600);
    await tester.pumpWidget(host(BuilderView(notice: Notice())));
    await settle(tester);

    expect(find.byKey(const ValueKey('builder-toolbar')), findsOneWidget);
    expect(find.byKey(const ValueKey('builder-data-source')), findsOneWidget);
    expect(find.byKey(const ValueKey('builder-config')), findsOneWidget);
    expect(find.byKey(const ValueKey('builder-sql-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('builder-result-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('builder-tab-output')), findsOneWidget);
    expect(find.byKey(const ValueKey('builder-tab-join')), findsOneWidget);
    expect(find.byKey(const ValueKey('builder-tab-filter')), findsOneWidget);
    expect(find.byKey(const ValueKey('builder-tab-sort')), findsOneWidget);
    // Any RenderFlex overflow would surface here and fail the test.
    expect(tester.takeException(), isNull);
  });

  testWidgets('second table click joins it and re-click cancels it',
      (tester) async {
    size(tester);
    await tester.pumpWidget(host(BuilderView(notice: Notice())));
    await settle(tester);

    // First click defines the primary table; a declared FK between orders and
    // users is derived automatically (orders.user_id -> users.id).
    await tester.tap(find.byKey(const ValueKey('builder-table-orders')));
    await settle(tester, rounds: 3);
    expect(find.text('主表'), findsOneWidget);
    expect(find.text('接入'), findsOneWidget);
    expect(previewSql(tester), contains('LEFT JOIN "users"'));

    // Clicking another table while a primary exists joins it.
    await tester.tap(find.byKey(const ValueKey('builder-table-users')));
    await settle(tester, rounds: 2);
    // It is already joined from the FK derivation, so the click removes it.
    expect(find.text('接入'), findsNothing);
    expect(previewSql(tester), isNot(contains('LEFT JOIN "users"')));

    // Clicking it once more joins it again.
    await tester.tap(find.byKey(const ValueKey('builder-table-users')));
    await settle(tester, rounds: 2);
    expect(find.text('接入'), findsOneWidget);
    expect(previewSql(tester), contains('LEFT JOIN "users"'));

    // Clicking the primary table again cancels the primary selection.
    await tester.tap(find.byKey(const ValueKey('builder-table-orders')));
    await settle(tester, rounds: 4);
    final dialog = find.text('取消主表');
    if (dialog.evaluate().isNotEmpty) {
      await tester.tap(dialog);
      await settle(tester, rounds: 3);
    }
    expect(previewSql(tester), contains('请先选择主表'));
  });

  testWidgets('conditions, groups, sorting and DISTINCT shape the SQL',
      (tester) async {
    size(tester);
    await tester.pumpWidget(host(BuilderView(notice: Notice())));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('builder-table-orders')));
    await settle(tester, rounds: 3);

    // Filtering lives in its own tab of the merged configuration card.
    await tester.tap(find.byKey(const ValueKey('builder-tab-filter')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('builder-add-condition')));
    await tester.pump();
    // Round34 P2-07: a row with a field but no value is dropped from the SQL —
    // and the view refuses to run — instead of emitting `= $1` / a dangling
    // `AND (...)`. The red hint names what is missing.
    expect(previewSql(tester), isNot(contains('WHERE')));
    expect(find.textContaining('请填写条件值'), findsOneWidget);

    Finder conditionValueField() => find.byWidgetPredicate((widget) =>
        widget is TextField && widget.decoration?.hintText == '输入值…');

    await tester.enterText(conditionValueField().first, '100');
    await tester.pump();
    expect(previewSql(tester), contains('WHERE'));

    await tester.tap(find.byKey(const ValueKey('builder-add-group-or')));
    await tester.pump();
    // The group's first condition needs a value too before it reaches the SQL.
    await tester.enterText(conditionValueField().last, '1');
    await tester.pump();
    // The group is a second top-level item, so it is joined with AND.
    expect(previewSql(tester), contains(' AND ('));
    await tester.tap(find.text('+ 组内条件'));
    await tester.pump();
    await tester.enterText(conditionValueField().last, '2');
    await tester.pump();
    expect(previewSql(tester), contains(' OR '));

    await tester.tap(find.byKey(const ValueKey('builder-tab-sort')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('builder-add-order')));
    await tester.pump();
    expect(previewSql(tester), contains('ORDER BY "orders"."id"'));

    await tester.tap(find.byKey(const ValueKey('builder-tab-output')));
    await tester.pump();
    // The control is labelled in plain Chinese now; DISTINCT itself is still
    // toggled and visible in the SQL preview. Its trailing SQL token is the
    // stable substring to tap.
    await tester.tap(find.textContaining('去重'));
    await tester.pump();
    expect(previewSql(tester), contains('SELECT DISTINCT'));
  });

  testWidgets('translated labels do not overflow at narrow widths',
      (tester) async {
    // The Chinese operator / join-type labels are longer than "LEFT"/"="; the
    // dense rows wrap instead of overflowing, at both the fixed layout and the
    // compact fallback.
    for (final sizeConstraint in const [
      (1100.0, 800.0),
      (960.0, 600.0),
    ]) {
      size(tester, width: sizeConstraint.$1, height: sizeConstraint.$2);
      // A fresh key forces a new State: re-pumping the same widget type would
      // keep the previous iteration's primary table, and tapping it again opens
      // the "取消主表" confirmation.
      await tester.pumpWidget(host(BuilderView(
        key: ValueKey('builder-narrow-' + sizeConstraint.toString()),
        notice: Notice(),
      )));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('builder-table-orders')));
      await settle(tester, rounds: 3);
      await tester.tap(find.byKey(const ValueKey('builder-tab-join')));
      await tester.pump();
      expect(find.textContaining('左连接'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('builder-tab-filter')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('builder-add-condition')));
      await tester.pump();
      expect(find.textContaining('等于'), findsWidgets);
      expect(tester.takeException(), isNull,
          reason: 'overflow at ' + sizeConstraint.toString());
    }
  });


  testWidgets('1280x720 and 1920x1080 page sizes take one identical layout',
      (tester) async {
    // Both are above the builder's 1100x640 fixed-layout requirement when the
    // view gets the whole surface, so both must build the same tree. This is a
    // plain regression guard on the 640 / 1100 breakpoints, independent of
    // whatever window size the user runs.
    final skeletons = await skeletonsAt(
      tester,
      const <Size>[Size(1280, 720), Size(1920, 1080)],
      'raw',
    );
    final rendered = skeletons.values.toList();
    expect(rendered.first, rendered.last,
        reason: '1280x720 and 1920x1080 rendered different widget trees');
  });
}
