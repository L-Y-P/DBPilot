// 「数据与卸载」区块的 widget 覆盖。
//
// 和 settings_dialog_test.dart 一样先把真实 Rust 核心跑起来（AppState 的行为
// 才和运行时一致），但数据目录的读取与清空全部走 seam 注入的假实现：
// 这组用例**绝不**碰真实用户目录，也不依赖 rust-core 是否已经编出
// data_dir_summary/wipe_user_data 两个入口。

import 'dart:io';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/data_dir_overview.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';
import 'package:rust_myadmin_desktop/src/i18n_literals.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/sqlite_sources.dart';
import 'package:rust_myadmin_desktop/src/text.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/settings_dialog.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

/// 假的盘点结果：3 个文件、2 MiB，内容是连接配置 + 历史 + 一个备份目录。
Json _summary({
  String path = '/tmp/dbpilot-data-test',
  int totalBytes = 2 * 1024 * 1024,
  int fileCount = 3,
  bool containsSecrets = true,
}) =>
    <String, dynamic>{
      'path': path,
      'exists': true,
      'total_bytes': totalBytes,
      'file_count': fileCount,
      'contains_secrets': containsSecrets,
      'files': <dynamic>[
        <String, dynamic>{
          'name': 'connections.json',
          'path': '$path/connections.json',
          'bytes': 1024,
          'count': 1,
          'kind': 'file',
        },
        <String, dynamic>{
          'name': 'history.json',
          'path': '$path/history.json',
          'bytes': 2048,
          'count': 1,
          'kind': 'file',
        },
        <String, dynamic>{
          'name': 'backups',
          'path': '$path/backups',
          'bytes': 2 * 1024 * 1024 - 3072,
          'count': 1,
          'kind': 'dir',
        },
      ],
    };

/// 清空之后 Rust 回报的体：占用归零，不再有敏感文件。
Json _emptiedSummary({String path = '/tmp/dbpilot-data-test'}) =>
    <String, dynamic>{
      'path': path,
      'exists': true,
      'total_bytes': 0,
      'file_count': 0,
      'contains_secrets': false,
      'files': <dynamic>[],
    };

Future<void> _boot() async {
  final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
  if (!dylib.existsSync()) {
    fail('Run `cargo build --lib` in rust/ first: ${dylib.path} is missing');
  }
  await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));

  final dir = Directory('${Directory.systemTemp.path}/rma-settings-data-ui');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  await dir.create(recursive: true);

  final init = await Api.init(dir.path);
  expect(init['ok'], isTrue, reason: 'init_app failed: $init');
  await AppState.instance.bootstrap(dir.path);
  expect(AppState.instance.bootstrapError, isNull,
      reason: 'bootstrap failed: ${AppState.instance.bootstrapError}');
  expect(AppState.instance.bootstrapped, isTrue);
}

/// Pump frames on a real event loop so the seam's futures can complete.
Future<void> _settle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Widget _harness() => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const ValueKey('open-settings'),
              onPressed: () {
                showSettingsDialog(context);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

Future<void> _openDialog(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_harness());
  await tester.tap(find.byKey(const ValueKey('open-settings')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('settings-data-path')), findsOneWidget);
}

String _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).data;

void main() {
  setUpAll(_boot);

  setUp(() {
    I18n.setLang(AppLang.zh);
    settingsDirPicker = pickFolder;
    settingsRevealDataDir = revealInFileManager;
    settingsDataDirSummary = () async => _summary();
    settingsWipeUserData = (String confirm) async =>
        <String, dynamic>{'ok': true, 'removed_bytes': 2 * 1024 * 1024};
  });

  tearDown(() {
    settingsDirPicker = pickFolder;
    settingsRevealDataDir = revealInFileManager;
    settingsDataDirSummary = Api.instance.dataDirSummary;
    settingsWipeUserData = (String confirm) =>
        Api.instance.wipeUserData(confirm: confirm);
    I18n.setLang(AppLang.zh);
    AppColors.applyAppearance(mode: 'system', presetId: 'default');
  });

  testWidgets('显示数据目录路径、占用与内容摘要', (tester) async {
    await _openDialog(tester);
    await _settle(tester);

    // 区块标题与位置：在「备份」之后、「关于」之前。
    final sectionY = tester.getTopLeft(find.text('数据与卸载')).dy;
    expect(sectionY, greaterThan(tester.getTopLeft(find.text('备份')).dy));
    expect(sectionY, lessThan(tester.getTopLeft(find.text('关于')).dy));

    // 路径是真实路径，原样（不翻译）显示。
    expect(_textOf(tester, 'settings-data-path'), '/tmp/dbpilot-data-test');

    // 占用：共 N 个文件 + KB/MB/GB 格式化。
    final size = _textOf(tester, 'settings-data-size');
    expect(size, contains('共 3 个文件'));
    expect(size, contains('2.00 MB'));

    // 内容摘要按 files 列表逐条生成。
    expect(find.byKey(const ValueKey('settings-data-contents')), findsOneWidget);
    expect(find.text('connections.json · 1 个文件 · 1.00 KB'), findsOneWidget);
    expect(find.text('history.json · 1 个文件 · 2.00 KB'), findsOneWidget);
    expect(find.text('backups · 1 个文件 · 2.00 MB'), findsOneWidget);

    // 卸载说明必须写清楚“卸载不会自动删数据”。
    final hint = _textOf(tester, 'settings-data-uninstall-hint');
    // 这组用例跑在中文模式：提示就是中文原文，断言中文要点本身。
    // （英文渲染由下面的「英文模式下不残留中文」用例负责。）
    expect(I18n.current, AppLang.zh);
    expect(hint, contains('不会自动删除'));
    expect(hint, contains('手动删除'));
    expect(hint, contains('Windows 安装包'));

    // 三个按钮都在。
    expect(find.byKey(const ValueKey('settings-data-open')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-data-wipe')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-data-refresh')), findsOneWidget);
  });

  testWidgets('清空：确认后调用带确认短语的 API 并刷新占用', (tester) async {
    final calls = <String>[];
    var summaryCalls = 0;
    settingsDataDirSummary = () async {
      summaryCalls++;
      // 第一次是打开设置时的扫描，之后（清空完）返回空目录。
      return summaryCalls == 1 ? _summary() : _emptiedSummary();
    };
    settingsWipeUserData = (String confirm) async {
      calls.add(confirm);
      return <String, dynamic>{'ok': true, 'removed_bytes': 2 * 1024 * 1024};
    };

    await _openDialog(tester);
    await _settle(tester);
    expect(calls, isEmpty);

    await tester
        .ensureVisible(find.byKey(const ValueKey('settings-data-wipe')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-data-wipe')));
    await tester.pumpAndSettle();

    // 危险操作先弹确认；此时还没调用 Rust。
    expect(find.text('确定清空用户数据吗？'), findsOneWidget);
    expect(calls, isEmpty);

    await tester.tap(find.text('清空'));
    await _settle(tester);

    // 确认短语必须和 Rust 侧同源。
    expect(calls, <String>[wipeUserDataConfirmToken]);

    // 清空后重新扫描，占用归零。
    expect(summaryCalls, greaterThanOrEqualTo(2));
    expect(_textOf(tester, 'settings-data-size'), '空目录（0 B）');
    expect(find.byKey(const ValueKey('settings-data-contents')), findsNothing);

    // 成功提示说明释放了多少、并明确要重启才生效；不自动退出应用。
    expect(find.byKey(const ValueKey('settings-data-wipe-result')), findsOneWidget);
    expect(find.textContaining('重新启动应用后生效'), findsOneWidget);
  });

  testWidgets('取消确认时不清空、不改变占用', (tester) async {
    final calls = <String>[];
    settingsWipeUserData = (String confirm) async {
      calls.add(confirm);
      return <String, dynamic>{'ok': true, 'removed_bytes': 0};
    };

    await _openDialog(tester);
    await _settle(tester);

    await tester
        .ensureVisible(find.byKey(const ValueKey('settings-data-wipe')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-data-wipe')));
    await tester.pumpAndSettle();
    expect(find.text('确定清空用户数据吗？'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await _settle(tester);

    expect(calls, isEmpty);
    expect(find.text('确定清空用户数据吗？'), findsNothing);
    expect(find.byKey(const ValueKey('settings-data-wipe-result')), findsNothing);
    expect(_textOf(tester, 'settings-data-size'), contains('共 3 个文件'));
  });

  testWidgets('清空失败时显示错误且保留原占用', (tester) async {
    settingsWipeUserData = (String confirm) async =>
        throw ApiException('拒绝执行：确认短语不正确');

    await _openDialog(tester);
    await _settle(tester);

    await tester
        .ensureVisible(find.byKey(const ValueKey('settings-data-wipe')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-data-wipe')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await _settle(tester);

    expect(find.byKey(const ValueKey('settings-data-error')), findsOneWidget);
    expect(find.textContaining('拒绝执行'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-data-wipe-result')), findsNothing);
    // 失败不该静默把占用清零。
    expect(_textOf(tester, 'settings-data-size'), contains('共 3 个文件'));
  });

  testWidgets('读取失败时显示占位而不是崩溃', (tester) async {
    settingsDataDirSummary = () async => throw ApiException('core 尚未就绪');

    await _openDialog(tester);
    await _settle(tester);

    expect(_textOf(tester, 'settings-data-path'), '数据目录不可用');
    expect(_textOf(tester, 'settings-data-size'), '占用未知');
    expect(find.byKey(const ValueKey('settings-data-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-data-contents')), findsNothing);
    // 读不到就无从清空，按钮禁用。
    final wipe =
        tester.widget<Btn>(find.byKey(const ValueKey('settings-data-wipe')));
    expect(wipe.onPressed, isNull);
  });

  testWidgets('空目录时禁用清空按钮', (tester) async {
    settingsDataDirSummary = () async => _emptiedSummary();

    await _openDialog(tester);
    await _settle(tester);

    expect(_textOf(tester, 'settings-data-size'), '空目录（0 B）');
    final wipe =
        tester.widget<Btn>(find.byKey(const ValueKey('settings-data-wipe')));
    expect(wipe.onPressed, isNull);
  });

  testWidgets('打开数据目录走系统文件管理器', (tester) async {
    final opened = <String>[];
    settingsRevealDataDir = (String path) async {
      opened.add(path);
      return true;
    };

    await _openDialog(tester);
    await _settle(tester);

    await tester
        .ensureVisible(find.byKey(const ValueKey('settings-data-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-data-open')));
    await _settle(tester);

    expect(opened, <String>['/tmp/dbpilot-data-test']);
    expect(find.byKey(const ValueKey('settings-data-error')), findsNothing);
  });

  testWidgets('打开目录失败时给出提示', (tester) async {
    settingsRevealDataDir = (String path) async => false;

    await _openDialog(tester);
    await _settle(tester);

    await tester
        .ensureVisible(find.byKey(const ValueKey('settings-data-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-data-open')));
    await _settle(tester);

    expect(find.byKey(const ValueKey('settings-data-error')), findsOneWidget);
    expect(find.textContaining('无法打开目录'), findsOneWidget);
  });

  testWidgets('英文模式下不残留中文', (tester) async {
    await _openDialog(tester);
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('settings-lang-en')));
    await _settle(tester);

    expect(find.text('Data & uninstall'), findsOneWidget);
    expect(find.text('Open data folder'), findsOneWidget);
    final size = _textOf(tester, 'settings-data-size');
    expect(size, contains('3 files'));
    expect(size, contains('2.00 MB'));
    // 英文单复数：单个文件是 "1 file"，不是 "1 files"。
    expect(find.text('connections.json · 1 file · 1.00 KB'), findsOneWidget);
    expect(find.text('backups · 1 file · 2.00 MB'), findsOneWidget);
    expect(entryRowText(const DataDirEntry(
      name: 'history.json',
      path: '/tmp/history.json',
      bytes: 2048,
      count: 1,
      isDir: false,
    )), 'history.json · 1 file · 2.00 KB');
    expect(fileCountLabelEn(2), '2 files');
    expect(trLiteral(_textOf(tester, 'settings-data-uninstall-hint')),
        contains('does not delete'));

    // 区块内可见文案不能残留中文。Text.data 保存的是源码里的中文原文
    // （noTranslate 的条目也一样），所以要先过一遍 trLiteral，拿到的才是
    // 屏幕上真正渲染的字符串——和 english_ui_test 的扫描规则一致。
    final han = RegExp(r'[\u4e00-\u9fff]');
    for (final key in <String>[
      'settings-data-path',
      'settings-data-size',
      'settings-data-uninstall-hint',
    ]) {
      final rendered = trLiteral(_textOf(tester, key));
      expect(han.hasMatch(rendered), isFalse, reason: '$key: $rendered');
    }
    expect(trLiteral('数据与卸载'), 'Data & uninstall');

    await tester.tap(find.byKey(const ValueKey('settings-lang-zh')));
    await _settle(tester);
  });

  testWidgets('DataDirOverview 解析缺字段的返回体不抛异常', (tester) async {
    final overview = DataDirOverview.fromJson(<String, dynamic>{'path': '/x'});
    expect(overview.path, '/x');
    expect(overview.exists, isFalse);
    expect(overview.totalBytes, 0);
    expect(overview.entries, isEmpty);

    final bad = DataDirOverview.fromJson(<String, dynamic>{
      'path': '/x',
      'exists': true,
      'total_bytes': '2048',
      'file_count': 2.0,
      'files': <dynamic>[
        <String, dynamic>{},
        <String, dynamic>{'name': 'a.json', 'bytes': 12, 'kind': 'file'},
      ],
    });
    // 空名字的条目被丢弃，字符串/浮点数字段按数字解析。
    expect(bad.entries, hasLength(1));
    expect(bad.entries.single.name, 'a.json');
    expect(bad.totalBytes, 2048);
    expect(bad.fileCount, 2);
  });
}
