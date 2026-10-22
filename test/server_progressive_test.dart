// Structural regression test for P10: the server page must render immediately
// and degrade per panel instead of waiting for every probe (the restricted
// account used to sit on a page-wide spinner for 16.4s).
//
// This test does not need a real database: it points the page at a fake
// connection so every bridge call fails, then asserts that
//   * the tab bar and per-panel placeholders are painted on the first frames,
//   * each panel reports its own error (no blank page, no page-wide spinner),
//   * the capability probe hides the tabs the account cannot use.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/server_view.dart';

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(body: child),
    );

void main() {
  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run cargo build --lib in rust/ first: the dylib is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    final dir = await Directory.systemTemp.createTemp('rma-server-progressive-');
    final init = await Api.init(dir.path);
    expect(init['ok'], isTrue, reason: 'init_app failed');
    await AppState.instance.bootstrap(dir.path);
  });

  tearDown(() {
    AppState.instance.connection = null;
    AppState.instance.serverPrivileges = null;
    AppState.instance.clearDeniedActions();
  });

  testWidgets('server page paints first and degrades one panel at a time',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // A connection the Rust side does not actually have: every panel request
    // and the capability probe fail independently.
    AppState.instance.connection = <String, dynamic>{
      'id': 'fake-server',
      'driver': 'mysql',
      'label': 'fake-server',
    };
    AppState.instance.serverPrivileges = null;

    final notice = Notice();
    addTearDown(notice.dispose);
    await tester.pumpWidget(host(ServerView(notice: notice)));
    // The first frame must already contain the page, not a page-wide spinner.
    expect(find.text('状态'), findsOneWidget,
        reason: 'the tab bar must render without waiting for any probe');
    expect(find.text('变量'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsWidgets,
        reason: 'each panel shows its own loading placeholder');

    // Let the failed bridge calls and the capability probe complete. The probe
    // reports a conservative set here, so 进程 / 账号 disappear.
    for (var i = 0; i < 80; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('进程').evaluate().isEmpty) break;
    }

    expect(find.text('进程'), findsNothing,
        reason: 'a denied process panel must not be offered');
    expect(find.text('账号'), findsNothing,
        reason: 'a denied accounts panel must not be offered');
    expect(find.text('状态'), findsOneWidget);
    expect(find.text('变量'), findsOneWidget);

    // Every failed panel explains itself; the page never goes blank and never
    // stays on a page-wide spinner.
    expect(find.textContaining('加载失败'), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
