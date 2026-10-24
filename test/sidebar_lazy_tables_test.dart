// 侧边栏「按需构建」回归测试：5000 张表的库展开不能一次性建完所有行。
//
// 背景（docs/PERFORMANCE_TESTING.md §3）：真实应用里展开一个 5005 张表的库要
// 7.4 秒，而 Rust 侧 list_tables 只要 159ms —— 差距全在「把 5005 个表名做成
// Widget」上。每个表行是一个 InkWell + EllipsisText，而 EllipsisText 还会在
// post-frame 里逐个测量是否溢出，所以旧实现是 O(表数) 的 Widget 构建 + 布局。
//
// 修复后 _SidebarState 只收集「怎么建这一行」的构建器，ListView.builder 只对
// 可见行调用它们。本测试用一个假的 5000 表列表验证：
//   1. 首帧渲染的表行数远小于 5000（只建视口内的行）；
//   2. 直接跳到底部能看到最后一张表（按需构建没有把数据丢掉）；
//   3. 点击表行仍然跳转到正确的路由（行为没有改变）。

import 'dart:io';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/nav.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/shell.dart';
import 'package:rust_myadmin_desktop/src/text.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';

/// 假数据库里的表数量，与性能报告里的 5005 张同一个量级。
const int kTableCount = 5000;

/// SQLite 连接的命名空间固定是 main（见 AppState.activeDatabase）。
const String kNamespace = 'main';

String tableName(int index) => 'tbl_${index.toString().padLeft(4, '0')}';

Future<void> bootWithSqlite() async {
  final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
  if (!dylib.existsSync()) {
    fail('Run cargo build --lib in rust/ first: $dylib.path is missing');
  }
  await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));

  final dir = Directory('${Directory.systemTemp.path}/rma-sidebar-lazy');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  await dir.create(recursive: true);
  final dbFile = '${dir.path}/demo.sqlite';

  final init = await Api.init(dir.path);
  expect(init['ok'], isTrue, reason: 'init_app failed: $init');
  await AppState.instance.bootstrap(dir.path);
  expect(AppState.instance.bootstrapError, isNull);
  await File(dbFile).create(recursive: true);
  final created = await Api.instance.createConnection({
    'name': 'SQLite 大库',
    'driver': 'sqlite',
    'database': dbFile,
    'color': '#0f80cc',
  });
  final id = (created['connection'] as Map)['id'].toString();
  await AppState.instance.connect(id);
  await AppState.instance.refreshDatabases();
  AppState.instance.notify();
}

/// 真时钟 + 显式 pump：FFI 的 future 需要真实事件循环才会完成。
Future<void> settle(WidgetTester tester, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Widget app() => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const Shell(),
    );

/// 当前已构建的侧边栏表行数量。
///
/// 侧边栏用 [EllipsisText]，内部渲染的是 src/text.dart 里的 Text（不是
/// Material 的 Text），所以按「渲染出来的字符串」统计，而不是按类型。
int builtTableRows() {
  final finder = find.byWidgetPredicate((widget) {
    final data = sourceTextOf(widget);
    return data != null && data.startsWith('tbl_');
  });
  return finder.evaluate().length;
}

void main() {
  setUpAll(() async {
    await bootWithSqlite();
  });

  testWidgets('5000 张表的库只构建视口内的行，跳到末尾也能拿到最后的表',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 侧边栏的展开态与表列表直接喂进缓存：这里只验证渲染，不验证取数。
    //
    // 故意不导航到数据库页：DatabaseView 加载后会用自己的（这里为空的）
    // 真实表列表覆盖 tablesByDb，把本测试喂进去的 5000 行冲掉。
    final nav = Navigation.instance;
    nav.expanded.add(kNamespace);
    nav.tablesByDb[kNamespace] =
        List<String>.generate(kTableCount, tableName);

    nav.go(AppRoute.connections);
    // 只计「第一次把侧边栏树建出来」的耗时：pumpWidget + 一次 pump。
    // settle() 里的真实等待是给 FFI future 用的，算进去就没有可比性了。
    // 诊断输出与 grid_table_virtual_test 的 GRIDTABLE_* 同一用途：把「展开
    // 5000 张表的库要多久」变成可比较的数字（旧实现是 7.4s / 5005 个 Widget）。
    final watch = Stopwatch()..start();
    await tester.pumpWidget(app());
    await tester.pump();
    watch.stop();
    debugPrint('SIDEBAR_5000_FIRST_FRAME_US=${watch.elapsedMicroseconds}');
    await settle(tester);

    // 1) 首帧只构建视口内的行。1000px 高、每行约 22px，最多几十行；
    //    留出充足余量，只要不是「一次性建 5000 行」就算通过。
    final built = builtTableRows();
    debugPrint('SIDEBAR_5000_BUILT_ROWS=$built');
    expect(built, greaterThan(0), reason: '至少要有可见的表行');
    expect(built, lessThan(400),
        reason: '5000 张表不能一次性建成 Widget，实际构建了 $built 行');

    // 2) 一路跳到底部：末尾的表必须存在（数据没丢，按需构建正常工作）。
    //
    // ListView.builder 的 maxScrollExtent 是**估算值**，随着后续行被构建会
    // 不断变大，所以单次 jumpTo 到不了真正的末尾；这里反复跳直到稳定。
    final scrollable = find
        .descendant(of: find.byType(Shell), matching: find.byType(Scrollable))
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    var previous = -1.0;
    for (var i = 0; i < 200; i++) {
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      if (position.pixels == previous) break;
      previous = position.pixels;
    }

    expect(find.text(tableName(kTableCount - 1)), findsOneWidget);

    // 跳到底部后也仍然不是全量构建（只多建了末尾视口那几十行）。
    expect(builtTableRows(), lessThan(400),
        reason: '滚动过程中构建过的行数也必须受视口约束');

    // 3) 行为不变：点一行表名仍然跳到那张表。
    await tester.tap(find.text(tableName(kTableCount - 1)));
    await tester.pump();
    expect(Navigation.instance.route.table, tableName(kTableCount - 1));
  });
}
