// End-to-end pagination for the backup list.
//
// A backup folder can hold hundreds of dumps. The view used to build a row and
// three action buttons per backup on every rebuild; it now pages 20 at a time
// through the same GridTable/TablePager as the data browser.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/backups_view.dart';

Future<void> settle(WidgetTester tester, {int rounds = 14}) async {
  for (var i = 0; i < rounds; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('rma-backup-paging-');
    final backups = Directory('${dir.path}/backups')..createSync(recursive: true);
    final entries = <Map<String, dynamic>>[
      for (var i = 0; i < 45; i++)
        <String, dynamic>{
          'id': 'bk-$i',
          'file': 'dump-$i.sql',
          'driver': 'mysql',
          'database': 'demo',
          'created_at': '2026-10-21T00:00:00+00:00',
          'created_by': 'local',
          'size': 1024,
        },
    ];
    File('${backups.path}/index.json').writeAsStringSync(jsonEncode(entries));
    await RustLib.init(
        externalLibrary:
            ExternalLibrary.open('rust/target/debug/librust_myadmin_core.dylib'));
    await Api.init(dir.path);
    await AppState.instance.bootstrap(dir.path);
  });

  tearDownAll(() async {
    await dir.delete(recursive: true);
  });

  testWidgets('45 backups are paged 20 at a time', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: BackupsView(notice: Notice())),
    ));
    await settle(tester);
    await tester.pump(const Duration(seconds: 2));

    // Without an open connection the view filters by the (empty) active driver;
    // tick "show other drivers" so the synthetic mysql backups are listed.
    await tester.tap(find.text('显示其他驱动的备份'));
    await settle(tester);

    expect(find.text('第 1 / 3 页'), findsOneWidget);
    expect(find.text('显示 20 / 45 项'), findsOneWidget);
    expect(find.text('dump-0.sql'), findsOneWidget);

    final next = find.byKey(const ValueKey('backup-pager-next'));
    await tester.ensureVisible(next);
    await tester.tap(next);
    await settle(tester);
    expect(find.text('第 2 / 3 页'), findsOneWidget);
    expect(find.text('dump-20.sql'), findsOneWidget);

    await tester.ensureVisible(next);
    await tester.tap(next);
    await settle(tester);
    expect(find.text('第 3 / 3 页'), findsOneWidget);
    expect(find.text('显示 5 / 45 项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
