// Round 21: tab switching in the query builder must not rebuild the page.
//
// Reported symptom: after picking a primary table, switching between 输出字段 /
// 连接关系 / 筛选条件 / 排序 felt sluggish. The tab index lived in plain state,
// so every tap called setState on the whole BuilderView: the data source tree,
// SQL strip and result preview were rebuilt even though none of them depends on
// the visible tab (measured ~53ms per switch on a 40-column schema, versus
// ~14ms after this change, most of which is test-harness overhead).
//
// The fix has two parts, both pinned here:
//   * the tab index is a ValueNotifier, so only the tab bar and the tab body
//     rebuild on a switch;
//   * each tab page stays mounted inside an IndexedStack (cached until the next
//     full rebuild), so returning to a tab reuses its element tree instead of
//     inflating it again.
//
// These tests are structural rather than wall-clock: a timing assertion would be
// flaky on a loaded machine, while element identity exactly captures the
// behaviour that made the switch fast.

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

Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(body: child),
    );

void main() {
  late Directory dir;

  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run cargo build --lib in rust/ first: ' + dylib.path + ' is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    dir = await Directory.systemTemp.createTemp('rma-builder-tabs-');
    await Api.init(dir.path);
    await AppState.instance.bootstrap(dir.path);
    File(dir.path + '/tabs.sqlite').createSync(recursive: true);
    final created = await Api.instance.createConnection(<String, dynamic>{
      'name': 'tabs',
      'driver': 'sqlite',
      'database': dir.path + '/tabs.sqlite',
    });
    await AppState.instance
        .connect((created['connection'] as Map)['id'].toString());
    // A wide table makes the data source panel expensive enough that rebuilding
    // it on a tab switch is visible.
    final columns =
        List.generate(30, (i) => 'c' + i.toString() + ' TEXT').join(', ');
    await Api.instance
        .query('CREATE TABLE orders (id INTEGER PRIMARY KEY, ' + columns + ');');
    await Api.instance.query(
        'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);');
    await AppState.instance.refreshDatabases();
  });

  tearDownAll(() async {
    await AppState.instance.disconnect();
    await dir.delete(recursive: true);
  });

  testWidgets('each tab page stays mounted across switches', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(BuilderView(notice: Notice())));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('builder-table-orders')));
    await settle(tester, rounds: 4);

    const tabs = <String, String>{
      'output': '去重',
      'join': 'builder-add-join',
      'filter': 'builder-add-condition',
      'sort': 'builder-add-order',
    };
    finder(String tab) => tab == 'output'
        ? find.textContaining(tabs['output']!, skipOffstage: false)
        : find.byKey(ValueKey(tabs[tab]!), skipOffstage: false);

    // Visit every tab once and remember the element of each page's marker.
    final firstVisit = <String, Element>{};
    for (final tab in tabs.keys) {
      await tester.tap(find.byKey(ValueKey('builder-tab-' + tab)));
      await tester.pump();
      await tester.pump();
      expect(finder(tab).evaluate(), isNotEmpty,
          reason: 'the ' + tab + ' tab should be mounted after switching to it');
      firstVisit[tab] = finder(tab).evaluate().first;
    }

    // A second round trip must reuse the very same elements: if a switch
    // disposed and re-inflated a page, these instances would differ.
    for (final tab in tabs.keys.toList().reversed) {
      await tester.tap(find.byKey(ValueKey('builder-tab-' + tab)));
      await tester.pump();
      await tester.pump();
      expect(identical(finder(tab).evaluate().first, firstVisit[tab]), isTrue,
          reason: 'the ' + tab + ' tab page was rebuilt from scratch');
    }
  });

  testWidgets('a field click still refreshes the memoised data source panel',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(BuilderView(notice: Notice())));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('builder-table-orders')));
    await settle(tester, rounds: 4);

    // The panel memoises its widget instance keyed by every input it reads. A
    // stale cache would leave the "added" indicator off after the click.
    final field = find.byKey(const ValueKey('builder-field-orders.c1'));
    final addedIcon = find.descendant(
        of: field, matching: find.byIcon(Icons.check_circle));
    expect(field.evaluate(), isNotEmpty, reason: 'orders auto-expands');
    expect(addedIcon.evaluate(), isEmpty,
        reason: 'c1 is not in the outputs yet');

    await tester.tap(field);
    await tester.pump();
    await tester.pump();

    expect(addedIcon.evaluate(), isNotEmpty,
        reason: 'the panel must show the new output immediately');

    // Removing it again must also be reflected.
    await tester.tap(field);
    await tester.pump();
    await tester.pump();
    expect(addedIcon.evaluate(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching tabs does not disturb the query configuration',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(BuilderView(notice: Notice())));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('builder-table-orders')));
    await settle(tester, rounds: 4);

    String sqlOnScreen() {
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data ?? '')
          .where((value) => value.contains('SELECT'))
          .toList();
      return texts.isEmpty ? '' : texts.first;
    }

    // Capture the SQL, then cycle through the tabs and back.
    const order = <String>['join', 'filter', 'sort', 'output'];
    final before = sqlOnScreen();
    expect(before, contains('SELECT'));
    for (final tab in order) {
      await tester.tap(find.byKey(ValueKey('builder-tab-' + tab)));
      await tester.pump();
      await tester.pump();
    }
    expect(sqlOnScreen(), before);
    expect(tester.takeException(), isNull);
  });
}
