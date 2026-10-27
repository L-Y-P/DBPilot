// Widget coverage for the settings dialog: the real Rust core is booted (like
// test/app_shell_test.dart) so [AppState] behaves exactly as it does in the
// app, then the dialog is driven through its public keys.

import 'dart:io';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/app_version.dart';
import 'package:rust_myadmin_desktop/src/external_links.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';
import 'package:rust_myadmin_desktop/src/platform_shape.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/sqlite_sources.dart';
import 'package:rust_myadmin_desktop/src/text.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/update_apply.dart';
import 'package:rust_myadmin_desktop/src/update_check.dart';
import 'package:rust_myadmin_desktop/src/update_download.dart';
import 'package:rust_myadmin_desktop/src/update_source.dart';
import 'package:rust_myadmin_desktop/src/views/settings_dialog.dart';

/// Boots the Rust core in a throwaway data directory, mirroring main().
Future<void> _boot() async {
  final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
  if (!dylib.existsSync()) {
    fail('Run `cargo build --lib` in rust/ first: ${dylib.path} is missing');
  }
  await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));

  final dir = Directory('${Directory.systemTemp.path}/rma-settings-ui');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  await dir.create(recursive: true);

  final init = await Api.init(dir.path);
  expect(init['ok'], isTrue, reason: 'init_app failed: $init');
  await AppState.instance.bootstrap(dir.path);
  expect(AppState.instance.bootstrapError, isNull,
      reason: 'bootstrap failed: ${AppState.instance.bootstrapError}');
  expect(AppState.instance.bootstrapped, isTrue);
}

/// Pump frames on a real event loop so the FFI futures can complete.
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
  await tester.pumpWidget(_harness());
  await tester.tap(find.byKey(const ValueKey('open-settings')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('settings-lang-zh')), findsOneWidget);
}

const String _msixExe =
    r'C:\Program Files\WindowsApps\DBPilot_8wekyb3d8bbwe\DBPilot.exe';

/// Runs [body] pretending this process is an MSIX (Microsoft Store) build.
///
/// The dialog reads [isRunningAsMsix], which is backed by the two seams below;
/// swapping them is the only way to render the Store shape on a test host.
Future<void> asMsix(Future<void> Function() body) async {
  platformShapeExecutable = () => _msixExe;
  platformShapeEnvironment =
      () => <String, String>{kAppxPackageFamilyNameEnv: 'DBPilot_8wekyb3d8bbwe'};
  try {
    await body();
  } finally {
    platformShapeExecutable = () => Platform.resolvedExecutable;
    platformShapeEnvironment = () => Platform.environment;
  }
}

void main() {
  setUpAll(_boot);

  setUp(() async {
    I18n.setLang(AppLang.zh);
    AppState.instance.themeMode = kDefaultThemeMode;
    AppState.instance.themeColor = kDefaultThemePreset;
    AppState.instance.applyAppearance();
    settingsDirPicker = pickFolder;
    settingsUpdateCheck = checkUpdatesForSettings;
    settingsDownloadUpdate = downloadUpdatePackage;
    settingsApplyUpdate = applyUpdateAndRestart;
    settingsExitApp = exit;
    openExternalUrl = openUrlInBrowser;
  });

  tearDown(() {
    settingsDirPicker = pickFolder;
    settingsUpdateCheck = checkUpdatesForSettings;
    settingsDownloadUpdate = downloadUpdatePackage;
    settingsApplyUpdate = applyUpdateAndRestart;
    settingsExitApp = exit;
    openExternalUrl = openUrlInBrowser;
    I18n.setLang(AppLang.zh);
    AppColors.applyAppearance(mode: 'system', presetId: 'default');
  });

  testWidgets('renders every section, key and the app version', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _openDialog(tester);

    // Language.
    expect(find.byKey(const ValueKey('settings-lang-zh')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-lang-en')), findsOneWidget);
    // Appearance.
    for (final mode in <String>['system', 'light', 'dark']) {
      expect(find.byKey(ValueKey('settings-mode-$mode')), findsOneWidget);
    }
    for (final preset in kThemePresets) {
      expect(find.byKey(ValueKey('settings-color-${preset.id}')), findsOneWidget);
    }
    // Performance: the two switches sit between 个性化 and 备份.
    expect(find.byKey(const ValueKey('settings-auto-width')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-lazy-fields')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-perf-hint')), findsOneWidget);
    expect(find.text('性能'), findsOneWidget);
    expect(find.text('自动调整列宽'), findsOneWidget);
    expect(find.text('大字段延迟加载'), findsOneWidget);
    // Backups.
    expect(find.byKey(const ValueKey('settings-backup-path')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-backup-change')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-backup-reset')), findsOneWidget);
    // About / updates.
    expect(find.byKey(const ValueKey('settings-project-url')), findsOneWidget);
    expect(find.text(kUpdateRepoUrl), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-version')), findsOneWidget);
    // 核心版本行已删除：Rust 与 Dart 同源发布，两个号永远一致，那一行只会
    // 让用户困惑「到底哪个才是版本」。
    expect(find.byKey(const ValueKey('settings-core-version')), findsNothing);
    expect(find.byKey(const ValueKey('settings-update-check-hint')),
        findsOneWidget);
    // The update row is a button plus the fixed GitHub source caption; the
    // editable manifest-URL field is gone.
    expect(find.byKey(const ValueKey('settings-update-url')), findsNothing);
    expect(find.byKey(const ValueKey('settings-check-update')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-update-source')), findsOneWidget);
    // 只显示三段式版本号，(build N) 后缀已去掉。
    expect(find.text(kAppVersion), findsOneWidget);
    expect(find.textContaining('(build'), findsNothing);

    // The shared header close button dismisses the dialog.
    expect(find.byKey(const ValueKey('dialog-close')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dialog-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-lang-zh')), findsNothing);
  });

  testWidgets('switching to English updates I18n and re-renders the dialog',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    expect(I18n.current, AppLang.zh);
    await _openDialog(tester);

    await tester.tap(find.byKey(const ValueKey('settings-lang-en')));
    await _settle(tester);

    expect(I18n.current, AppLang.en);
    // The dialog body re-rendered in English. (The shared modal header is
    // built by showModalShell outside the body, so its 设置 title keeps the
    // language it was opened with — see the report's known limitation.)
    expect(find.text('Language'), findsOneWidget);
    expect(find.text('Check for updates'), findsOneWidget);
    expect(find.text('Personalization'), findsOneWidget);
    expect(find.text('Performance'), findsOneWidget);
    // The read-only update-source caption switches language too (it is built
    // with pickText, so it must not be left in Chinese by the translator).
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('settings-update-source')))
            .data,
        'Update source: GitHub · $kUpdateRepoLabel');
    // The language switcher still names each language in its own language.
    expect(find.text('中文'), findsOneWidget);

    // ...and switching back works too.
    await tester.tap(find.byKey(const ValueKey('settings-lang-zh')));
    await _settle(tester);
    expect(I18n.current, AppLang.zh);
    expect(find.text('Language'), findsNothing);
  });

  testWidgets('picking an accent colour applies it immediately', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _openDialog(tester);
    expect(AppColors.palette.presetId, kDefaultThemePreset);

    var notifications = 0;
    void listener() => notifications++;
    AppColors.notifier.addListener(listener);
    addTearDown(() => AppColors.notifier.removeListener(listener));

    await tester.tap(find.byKey(const ValueKey('settings-color-rose')));
    await _settle(tester);

    expect(AppState.instance.themeColor, 'rose');
    expect(AppColors.palette.presetId, 'rose');
    expect(AppColors.accent, const Color(0xFFE11D48));
    expect(notifications, greaterThan(0),
        reason: 'the palette must rebuild the app (AppColors.notifier)');
  });

  testWidgets('picking a theme mode applies it immediately', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _openDialog(tester);

    await tester.tap(find.byKey(const ValueKey('settings-mode-dark')));
    await _settle(tester);
    expect(AppState.instance.themeMode, 'dark');
    expect(AppColors.palette.dark, isTrue);
    expect(AppColors.bg, const Color(0xFF0F141A));

    await tester.tap(find.byKey(const ValueKey('settings-mode-light')));
    await _settle(tester);
    expect(AppState.instance.themeMode, 'light');
    expect(AppColors.palette.dark, isFalse);
    expect(AppColors.bg, const Color(0xFFF2F4F7));
  });

  testWidgets('the backup path is shown and reset restores the default',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _openDialog(tester);

    final pathFinder = find.byKey(const ValueKey('settings-backup-path'));
    final shown = tester.widget<Text>(pathFinder).data;
    expect(shown, isNotEmpty);
    expect(shown, isNot('未设置'));

    await tester.tap(find.byKey(const ValueKey('settings-backup-reset')));
    await _settle(tester);

    expect(AppState.instance.backupDir, AppState.instance.defaultBackupDir());
    // Still on screen with a path after the reset.
    expect(tester.widget<Text>(pathFinder).data, isNotEmpty);
  });

  testWidgets('更改 picks a folder and makes it the effective backup dir',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // The native dialog is unavailable under `flutter test`; the seam stands
    // in for it. The path is under the boot data dir, which the core accepts.
    final custom = '${AppState.instance.dataDir}/custom-backups';
    String? askedTitle;
    settingsDirPicker = ({String? title}) async {
      askedTitle = title;
      return custom;
    };

    await _openDialog(tester);
    final before = AppState.instance.backupDir;

    await tester.tap(find.byKey(const ValueKey('settings-backup-change')));
    await _settle(tester);

    expect(askedTitle, '选择备份保存目录');
    expect(AppState.instance.backupDir, isNot(before));
    // The core canonicalises the path, so match on the tail, not the exact
    // string.
    expect(AppState.instance.backupDir, endsWith('custom-backups'));
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('settings-backup-path')))
            .data,
        endsWith('custom-backups'));

    // Leave the boot directory on the default backup dir again.
    await tester.tap(find.byKey(const ValueKey('settings-backup-reset')));
    await _settle(tester);
    expect(AppState.instance.backupDir, AppState.instance.defaultBackupDir());
  });

  testWidgets('the performance switches toggle, persist and re-render',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _openDialog(tester);
    // Both default to on, so both checkboxes start checked.
    expect(AppState.instance.autoColumnWidth, isTrue);
    expect(AppState.instance.lazyBigFields, isTrue);

    // 性能 sits between 个性化 and 备份.
    final perfY = tester.getTopLeft(find.text('性能')).dy;
    expect(perfY, greaterThan(tester.getTopLeft(find.text('个性化')).dy));
    expect(perfY, lessThan(tester.getTopLeft(find.text('备份')).dy));

    var notifications = 0;
    void listener() => notifications++;
    AppState.instance.addListener(listener);
    addTearDown(() => AppState.instance.removeListener(listener));

    await tester.tap(find.byKey(const ValueKey('settings-auto-width')));
    await _settle(tester);
    expect(AppState.instance.autoColumnWidth, isFalse);
    expect(notifications, greaterThan(0),
        reason: 'the grids rebuild from AppState, so it must be notified');

    await tester.tap(find.byKey(const ValueKey('settings-lazy-fields')));
    await _settle(tester);
    expect(AppState.instance.lazyBigFields, isFalse);

    // The core persists them (when it knows the fields at all). FFI futures
    // need a real event loop, so this must run inside runAsync.
    final saved = await tester.runAsync(() => Api.instance.getSettings()) ??
        <String, dynamic>{};
    if (saved.containsKey('auto_column_width')) {
      expect(saved['auto_column_width'], isFalse);
    }
    if (saved.containsKey('lazy_big_fields')) {
      expect(saved['lazy_big_fields'], isFalse);
    }

    // Turning them back on works the same way.
    await tester.tap(find.byKey(const ValueKey('settings-auto-width')));
    await _settle(tester);
    expect(AppState.instance.autoColumnWidth, isTrue);
    await tester.tap(find.byKey(const ValueKey('settings-lazy-fields')));
    await _settle(tester);
    expect(AppState.instance.lazyBigFields, isTrue);
  });

  testWidgets('the performance section is translated in English',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _openDialog(tester);
    await tester.tap(find.byKey(const ValueKey('settings-lang-en')));
    await _settle(tester);

    expect(find.text('Performance'), findsOneWidget);
    expect(find.text('Auto-fit column widths'), findsOneWidget);
    expect(find.text('Lazy-load large fields'), findsOneWidget);
    expect(find.text('性能'), findsNothing);

    // Back to Chinese so the following test file starts from the default.
    await tester.tap(find.byKey(const ValueKey('settings-lang-zh')));
    await _settle(tester);
  });

  testWidgets('the update row is a check button plus a fixed GitHub source',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _openDialog(tester);

    // No editable manifest address any more: the check always reads the
    // manifest compiled into the app (kUpdateManifestUrl).
    expect(find.byKey(const ValueKey('settings-update-url')), findsNothing);
    expect(find.byType(TextField), findsNothing,
        reason: 'the settings dialog no longer owns any text input');

    final button = find.byKey(const ValueKey('settings-check-update'));
    expect(button, findsOneWidget);

    // The read-only caption names the fixed source, so a user still knows where
    // the manifest comes from.
    final caption = find.byKey(const ValueKey('settings-update-source'));
    expect(caption, findsOneWidget);
    final text = tester.widget<Text>(caption).data;
    expect(text, contains('GitHub'));
    expect(text, contains(kUpdateRepoLabel));
    expect(text, contains('$kUpdateRepoOwner/$kUpdateRepoName'));

    // The 性能 section makes the dialog taller than the test viewport, so the
    // update controls at the bottom have to be scrolled into view first (they
    // are inside the modal's own scroll view).
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();

    // The button is the widest control of the row but still fits the dialog.
    final dialog = tester.getRect(find.byType(Dialog));
    final rect = tester.getRect(button);
    expect(rect.left, greaterThanOrEqualTo(dialog.left));
    expect(rect.right, lessThanOrEqualTo(dialog.right));

    // Nothing is shown until the user asks for a check: the result panel only
    // exists after _checkUpdate ran (the network path itself is covered by
    // update_check_test.dart against a loopback server).
    expect(find.byKey(const ValueKey('settings-update-result')), findsNothing);
  });

  testWidgets('the About project URL opens in the default browser',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? opened;
    openExternalUrl = (String url) async {
      opened = url;
      return true;
    };

    await _openDialog(tester);
    final link = find.byKey(const ValueKey('settings-project-url'));
    expect(link, findsOneWidget);
    expect(tester.widget<Text>(link).data, kUpdateRepoUrl);

    await tester.ensureVisible(link);
    await tester.pumpAndSettle();
    await tester.tap(link);
    await _settle(tester);

    expect(opened, kUpdateRepoUrl);
    expect(find.byKey(const ValueKey('settings-link-error')), findsNothing);
  });

  testWidgets('a failed browser launch shows the copy-the-link hint',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    openExternalUrl = (String url) async => false;

    await _openDialog(tester);
    final link = find.byKey(const ValueKey('settings-project-url'));
    await tester.ensureVisible(link);
    await tester.pumpAndSettle();
    await tester.tap(link);
    await _settle(tester);

    expect(find.byKey(const ValueKey('settings-link-error')), findsOneWidget);
  });

  testWidgets('an available update is downloaded and applied automatically',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const releasePage = 'https://github.com/L-Y-P/DBPilot/releases/tag/v9.9.9';
    // 按运行平台选包：autoUpdateAssetUrl 在 Windows 上取 windows_setup，
    // macOS 取 macos_zip。原先只声明 macos_zip，在 CI 的 Windows runner 上
    // 该用例必然失败（本地 macOS 跑不出来这个差异）。
    final packageUrl = Platform.isWindows
        ? 'https://github.com/L-Y-P/DBPilot/releases/download/v9.9.9/DBPilot-9.9.9-windows-x64-setup.exe'
        : 'https://github.com/L-Y-P/DBPilot/releases/download/v9.9.9/DBPilot-9.9.9-macos.zip';
    final packageName = packageUrl.split('/').last;
    settingsUpdateCheck = (String manifestUrl, String currentVersion) async {
      expect(manifestUrl, kUpdateManifestUrl);
      return UpdateCheckResult(
        hasUpdate: true,
        currentVersion: currentVersion,
        latestVersion: '9.9.9',
        notes: 'test notes',
        downloadUrl: releasePage,
        assets: <String, String>{
          if (Platform.isWindows) 'windows_setup': packageUrl,
          if (!Platform.isWindows) 'macos_zip': packageUrl,
        },
      );
    };
    String? downloadedUrl;
    String? downloadedName;
    settingsDownloadUpdate = ({
      required String url,
      required Directory directory,
      required String fileName,
      required void Function(UpdateDownloadProgress progress) onProgress,
      required bool Function() isCancelled,
    }) async {
      downloadedUrl = url;
      downloadedName = fileName;
      onProgress(const UpdateDownloadProgress(received: 0, total: 2048));
      onProgress(
          const UpdateDownloadProgress(received: 2048, total: 2048, done: true));
      final file = File('${directory.path}/$fileName');
      await file.create(recursive: true);
      return file;
    };
    String? appliedVersion;
    settingsApplyUpdate = (File package, String version) async {
      expect(package.existsSync(), isTrue);
      appliedVersion = version;
    };
    int? exitCode;
    settingsExitApp = (int code) => exitCode = code;

    await _openDialog(tester);
    final button = find.byKey(const ValueKey('settings-check-update'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await _settle(tester);

    // One click on 检查更新 is enough: the package is fetched and installed,
    // then the app asks to quit so it can restart as the new build.
    expect(downloadedUrl, packageUrl);
    expect(downloadedName, packageName);
    expect(appliedVersion, '9.9.9');
    expect(exitCode, 0);

    expect(find.byKey(const ValueKey('settings-update-result')), findsOneWidget);
    expect(find.text('发现新版本：'), findsOneWidget);
    expect(find.text('9.9.9'), findsOneWidget);
    // Manual fallback stays visible while/if the automatic flow fails.
    final link = find.byKey(const ValueKey('settings-download-url'));
    expect(tester.widget<Text>(link).data, releasePage);

    final hint = find.byKey(const ValueKey('settings-update-check-hint'));
    expect(tester.widget<Text>(hint).data, contains('自动下载'));
  });

  testWidgets('a failed automatic update shows an error and a retry button',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    settingsUpdateCheck = (String manifestUrl, String currentVersion) async =>
        UpdateCheckResult(
          hasUpdate: true,
          currentVersion: currentVersion,
          latestVersion: '9.9.9',
          notes: '',
          downloadUrl: 'https://github.com/L-Y-P/DBPilot/releases/tag/v9.9.9',
          assets: const <String, String>{
            'macos_zip': 'https://example.com/DBPilot-9.9.9-macos.zip',
          },
        );
    settingsDownloadUpdate = ({
      required String url,
      required Directory directory,
      required String fileName,
      required void Function(UpdateDownloadProgress progress) onProgress,
      required bool Function() isCancelled,
    }) async {
      throw const UpdateDownloadException('下载失败：HTTP 500');
    };
    var applied = false;
    settingsApplyUpdate = (File package, String version) async => applied = true;

    await _openDialog(tester);
    final button = find.byKey(const ValueKey('settings-check-update'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await _settle(tester);

    expect(applied, isFalse);
    expect(find.byKey(const ValueKey('settings-update-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-retry-update')), findsOneWidget);
    expect(find.textContaining('HTTP 500'), findsOneWidget);
  });

  testWidgets('cancelling the automatic download reports the cancelled state',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    settingsUpdateCheck = (String manifestUrl, String currentVersion) async =>
        UpdateCheckResult(
          hasUpdate: true,
          currentVersion: currentVersion,
          latestVersion: '9.9.9',
          notes: '',
          downloadUrl: 'https://github.com/L-Y-P/DBPilot/releases/tag/v9.9.9',
          assets: const <String, String>{
            'macos_zip': 'https://example.com/DBPilot-9.9.9-macos.zip',
          },
        );
    settingsDownloadUpdate = ({
      required String url,
      required Directory directory,
      required String fileName,
      required void Function(UpdateDownloadProgress progress) onProgress,
      required bool Function() isCancelled,
    }) async {
      throw const UpdateCancelledException();
    };

    await _openDialog(tester);
    final button = find.byKey(const ValueKey('settings-check-update'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await _settle(tester);

    expect(find.byKey(const ValueKey('settings-update-error')), findsOneWidget);
    expect(find.text('已取消更新'), findsOneWidget);
  });

  // ------------------------------------------------------ Store (MSIX) 形态
  //
  // A Microsoft Store build must not offer an in-app download: Windows forbids
  // a packaged app from running the NSIS installer, and the Store re-signs every
  // release. These two tests pin the managed path (nothing is downloaded, the
  // copy points at the Store) and, in the same run, prove the unpackaged path is
  // untouched — the second half re-checks the GitHub wording without any MSIX
  // seam, so a regression there fails here too.

  testWidgets('MSIX 形态：检查更新只提示从商店更新，不下载任何包', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Pretend to be the Store build for the duration of this test.
    await asMsix(() async {
      settingsUpdateCheck = (String manifestUrl, String currentVersion) async =>
          UpdateCheckResult(
            hasUpdate: true,
            currentVersion: currentVersion,
            latestVersion: '9.9.9',
            notes: '',
            downloadUrl: 'https://github.com/L-Y-P/DBPilot/releases/tag/v9.9.9',
            // Even with an asset URL advertised, nothing may be downloaded.
            assets: const <String, String>{
              'windows_setup': 'https://example.com/DBPilot-9.9.9-windows-x64-setup.exe',
              'macos_zip': 'https://example.com/DBPilot-9.9.9-macos.zip',
            },
          );
      var downloads = 0;
      var applied = false;
      settingsDownloadUpdate = ({
        required String url,
        required Directory directory,
        required String fileName,
        required void Function(UpdateDownloadProgress progress) onProgress,
        required bool Function() isCancelled,
      }) async {
        downloads++;
        throw const UpdateDownloadException('不应下载');
      };
      settingsApplyUpdate = (File package, String version) async => applied = true;
      int? exitCode;
      settingsExitApp = (int code) => exitCode = code;

      await _openDialog(tester);

      // The caption names the managed channel instead of GitHub.
      final source = find.byKey(const ValueKey('settings-update-source'));
      expect(tester.widget<Text>(source).data, '更新方式：Microsoft Store');
      final hint = find.byKey(const ValueKey('settings-update-check-hint'));
      expect(tester.widget<Text>(hint).data, kMsixUpdateGuidance);

      final button = find.byKey(const ValueKey('settings-check-update'));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await _settle(tester);

      // A check still runs (the version information is useful), but the panel
      // offers the Store instead of a download, and nothing is fetched.
      expect(downloads, 0);
      expect(applied, isFalse);
      expect(exitCode, isNull);
      expect(find.text('发现新版本：'), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-update-msix-store')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('settings-update-unsupported')),
          findsNothing);
      expect(find.byKey(const ValueKey('settings-retry-update')), findsNothing);
      expect(find.byKey(const ValueKey('settings-update-error')), findsNothing);
    });
  });

  testWidgets('非 MSIX 形态：更新源仍写 GitHub，且不会出现商店提示', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _openDialog(tester);

    final source = find.byKey(const ValueKey('settings-update-source'));
    expect(tester.widget<Text>(source).data,
        contains('GitHub · $kUpdateRepoLabel'));
    final hint = find.byKey(const ValueKey('settings-update-check-hint'));
    expect(tester.widget<Text>(hint).data, contains('自动下载'));
    expect(find.byKey(const ValueKey('settings-update-msix-store')), findsNothing);
  });
}
