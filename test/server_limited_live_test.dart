// Live check for P10 on the local restricted MySQL account.
//
// 这是 live 测试：需要一个只读 sakila 两张表的受限 MySQL 账号。端点与账号来自
// 环境变量（DBPILOT_TEST_MYSQL_* / DBPILOT_TEST_MYSQL_RESTRICTED_*，见
// test/live_db_env.dart），仓库里不留任何账号密码字面量；账号/库不可用时自动 SKIP。
//
// What it pins: opening the server page with a restricted account must not
// leave the page on a page-wide spinner; the usable tabs keep working and the
// tabs that need PROCESS / account access are hidden, with the required GRANT
// named in the banner.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/database_view.dart';
import 'package:rust_myadmin_desktop/src/views/server_view.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

import 'live_db_env.dart';

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(body: child),
    );

/// Open the local restricted MySQL account. Real FFI calls must run through
/// [WidgetTester.runAsync]; a plain await uses the fake clock and never finishes.
Future<bool> connectLimited(WidgetTester tester) async {
  final connected = await tester.runAsync(() async {
    try {
      final created = await Api.instance.createConnection(
        connectionPayload(
          'mysql',
          mysqlRestrictedEndpoint(),
          name: 'server-limited-live',
        ),
      );
      final id = (created['connection'] as Map)['id'].toString();
      await AppState.instance.connect(id);
      return true;
    } catch (_) {
      return false;
    }
  });
  return connected == true;
}

/// Pump real time until [done] is true, so future completions actually run.
Future<bool> pumpUntil(WidgetTester tester, bool Function() done,
    {int rounds = 120}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
    if (done()) return true;
  }
  return done();
}

void main() {
  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run cargo build --lib in rust/ first: the dylib is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    final dir = await Directory.systemTemp.createTemp('rma-server-limited-');
    final init = await Api.init(dir.path);
    expect(init['ok'], isTrue, reason: 'init_app failed');
    await AppState.instance.bootstrap(dir.path);
  });

  tearDownAll(() async {
    try {
      await AppState.instance.disconnect();
    } catch (_) {}
  });

  testWidgets('restricted account: page renders, unusable tabs are hidden',
      (tester) async {
    if (!await connectLimited(tester)) {
      markTestSkipped('restricted MySQL account (DBPILOT_TEST_MYSQL_RESTRICTED_*) not available');
      return;
    }
    if (AppState.instance.can('processes') || AppState.instance.can('accounts')) {
      await tester.runAsync(() => AppState.instance.disconnect());
      markTestSkipped('the restricted account unexpectedly has PROCESS / account rights');
      return;
    }

    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final notice = Notice();
    addTearDown(notice.dispose);
    final started = DateTime.now();
    await tester.pumpWidget(host(ServerView(notice: notice)));
    await tester.pump();

    // The tab bar must be painted immediately; the old page showed only a
    // spinner until every probe finished.
    expect(find.text('变量'), findsOneWidget);

    // Wait (real time; FFI futures need runAsync) for every panel to settle.
    final panelsSettled = await pumpUntil(
        tester, () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
    expect(panelsSettled, isTrue,
        reason: 'panels must settle on their own timeout, never hang the page');
    final elapsed = DateTime.now().difference(started);

    // Denied tabs are hidden, not merely greyed; the banner names PROCESS.
    expect(find.text('进程'), findsNothing);
    expect(find.text('账号'), findsNothing);
    expect(find.text('状态'), findsOneWidget);
    expect(find.text('变量'), findsOneWidget);
    expect(find.textContaining('PROCESS'), findsWidgets);

    // The default status panel either rendered or explains itself; it is never
    // a blank page and never a raw 1142-only dump.
    final statusRendered = find.text('全部状态变量').evaluate().isNotEmpty;
    final statusExplained = find
        .textContaining('服务器状态')
        .evaluate()
        .any((element) => element.widget is! Text ||
            ((element.widget as Text).data ?? '').contains('权限') ||
            ((element.widget as Text).data ?? '').contains('超时') ||
            ((element.widget as Text).data ?? '').contains('加载'));
    expect(statusRendered || statusExplained, isTrue);
    expect(find.textContaining('Caused by'), findsNothing);
    expect(tester.takeException(), isNull);

    // The page became usable well inside the old 16.4s (the panels have an 8s
    // cap each and run concurrently).
    expect(elapsed.inSeconds, lessThan(15),
        reason: 'restricted server page took ${elapsed.inSeconds}s');
    await tester.runAsync(() => AppState.instance.disconnect());
  }, timeout: const Timeout(Duration(minutes: 2)));
  testWidgets('restricted account: a denied TRUNCATE disables the Clear buttons',
      (tester) async {
    if (!await connectLimited(tester)) {
      markTestSkipped('restricted MySQL account (DBPILOT_TEST_MYSQL_RESTRICTED_*) not available');
      return;
    }
    if (AppState.instance.can('accounts')) {
      await tester.runAsync(() => AppState.instance.disconnect());
      markTestSkipped('the restricted account unexpectedly has account rights');
      return;
    }

    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final restricted = mysqlRestrictedEndpoint();
    final notice = Notice();
    addTearDown(notice.dispose);
    await tester.pumpWidget(
        host(DatabaseView(db: restricted.database, notice: notice)));

    // The page must load the two granted tables; the Clear buttons are the
    // actions we are about to fail on.
    final loaded = await pumpUntil(
        tester, () => find.text('清空').evaluate().isNotEmpty);
    expect(loaded, isTrue,
        reason: 'the limited account should still see the granted tables');

    // Truncate: open the confirmation, then run it. The database refuses with
    // 1142; the page must learn that and grey every Clear button.
    await tester.tap(find.text('清空').first);
    await tester.pump();
    await pumpUntil(tester, () => find.text('清空').evaluate().length > 1,
        rounds: 20);
    await tester.tap(find.text('清空').last);

    final learned = await pumpUntil(tester,
        () => find.textContaining('缺少以下操作权限').evaluate().isNotEmpty);
    expect(learned, isTrue,
        reason: 'a permission failure must disable the action, not just toast');
    // Let the confirmation modal finish closing before inspecting the buttons.
    await pumpUntil(tester, () => find.text('取消').evaluate().isEmpty,
        rounds: 20);

    final clears = tester
        .widgetList<Btn>(find.widgetWithText(Btn, '清空'))
        .toList();
    expect(clears, isNotEmpty);
    expect(clears.every((button) => button.onPressed == null), isTrue,
        reason: 'every Clear button must be disabled after the learned denial');

    // The tooltip names account + database + action and the database reason.
    final tooltip = clears.first.tooltip ?? '';
    expect(tooltip, contains(restricted.user));
    expect(tooltip, contains(restricted.database));
    expect(tooltip, contains('清空表'));
    // The database's own wording is kept as detail (with the cleaned prefix).
    expect(tooltip, contains('数据库原始信息'));
    expect(tooltip, contains('denied'));
    expect(tester.takeException(), isNull);

    await tester.runAsync(() => AppState.instance.disconnect());
  }, timeout: const Timeout(Duration(minutes: 2)));
}