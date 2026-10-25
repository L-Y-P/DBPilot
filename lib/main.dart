import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide Text, Tooltip;
import 'src/text.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'src/api.dart';
import 'src/app_state.dart';
import 'src/app_version.dart';
import 'src/cu_input.dart';
import 'src/dpi_scale.dart';
import 'src/frame_trace.dart';
import 'src/i18n_literals.dart';
import 'src/settings_channel.dart';
import 'src/shell.dart';
import 'src/rust/frb_generated.dart';
import 'src/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 应用内帧耗时采样：只在 DBPILOT_FRAME_TRACE=1 时注册回调并周期性打印
  // FRAME_TRACE 统计行（默认关闭，零开销）。用环境变量而不是设置项，是因为它只服务于
  // 自动化/性能排查，且必须在首帧之前生效（见 src/frame_trace.dart 顶部注释）。
  FrameTrace.instance.maybeStart();

  // Computer-Use 文本注入桥（默认关闭）：只有 RMA_CU_INPUT=1 时才启动，
  // 监听全局焦点并允许本机回环 HTTP 往当前 EditableText 的 controller 写文本。
  await CuTextInput.instance.bootstrapFromEnvironment();

  // macOS delivers Cmd+, through the app menu, so the menu forwards it here
  // instead of the Flutter key handler (see settings_channel.dart).
  initSettingsChannel();

  // The generated FFI bridge must be loaded before any Rust function is called;
  // without this every bridge call throws "flutter_rust_bridge has not been
  // initialized".
  await RustLib.init();

  // file_picker 13 refuses to open a dialog on macOS unless the app carries a
  // user-selected-files entitlement. The app is deliberately not sandboxed (a
  // database client must reach the whole filesystem), so the entitlement is
  // declared in both .entitlements files *and* the plugin is told to skip its
  // App Sandbox pre-check. Without one of the two every 浏览 button died with
  // ENTITLEMENT_NOT_FOUND before the native panel appeared.
  if (Platform.isMacOS) {
    try {
      await FilePicker.skipEntitlementsChecks();
    } catch (_) {
      // An older plugin without the hook still works via the entitlement.
    }
  }

  // The Rust core owns the data directory, but Dart resolves it through
  // path_provider so the platform-correct location is used on every OS.
  var dataDir = '';
  try {
    final dir = await getApplicationSupportDirectory();
    dataDir = dir.path;
  } catch (_) {
    // Fall back to the Rust-side default; init_app handles an empty path.
  }

  final init = await Api.init(dataDir);
  if (init['ok'] != true) {
    runApp(_InitFailure((init['error'] ?? '初始化失败').toString()));
    return;
  }

  // Desktop window setup. The web build lived in a browser tab; here the app
  // remembers its size/position and enforces a usable minimum.
  final settings = await Api.instance.getSettings();
  final win =
      (settings['window'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
  final width = (win['width'] as num?)?.toDouble() ?? 1440;
  final height = (win['height'] as num?)?.toDouble() ?? 900;
  final x = (win['x'] as num?)?.toDouble();
  final y = (win['y'] as num?)?.toDouble();
  final maximized = win['maximized'] == true;

  await windowManager.ensureInitialized();
  final options = WindowOptions(
    size: Size(width, height),
    minimumSize: const Size(960, 600),
    center: x == null || y == null,
    title: kAppName,
    titleBarStyle: TitleBarStyle.normal,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    if (x != null && y != null && !maximized) {
      await windowManager.setPosition(Offset(x, y));
    }
    if (maximized) await windowManager.maximize();
    // 窗口底色已在 MainFlutterWindow.swift 里换成系统窗口底色（窗口 +
    // FlutterView 一起设），首帧前不会闪黑，这里直接显示即可。
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const RustMyAdminApp());
}

/// Shown when the Rust core could not create its data directory, instead of
/// starting a UI that would fail on every action.
class _InitFailure extends StatelessWidget {
  const _InitFailure(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 48, color: AppColors.danger),
                const SizedBox(height: 16),
                const Text('DBPilot 启动失败',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                SelectableText(trLiteral(message), textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class RustMyAdminApp extends StatefulWidget {
  const RustMyAdminApp({super.key});

  @override
  State<RustMyAdminApp> createState() => _RustMyAdminAppState();
}

class _RustMyAdminAppState extends State<RustMyAdminApp>
    with WindowListener, WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);
    // Bootstrap once the first frame exists so the UI can show progress.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      var dir = '';
      try {
        dir = (await getApplicationSupportDirectory()).path;
      } catch (_) {}
      await AppState.instance.bootstrap(dir);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(this);
    super.dispose();
  }

  /// The "follow system" appearance has to re-resolve the palette when macOS
  /// switches between light and dark; nothing else would repaint it.
  @override
  void didChangePlatformBrightness() {
    AppState.instance.applyAppearance();
  }

  @override
  void onWindowClose() async {
    await _persistWindowState();
    await windowManager.destroy();
  }

  @override
  void onWindowResized() => _persistWindowState();

  @override
  void onWindowMoved() => _persistWindowState();

  /// Remember geometry so the next launch restores it.
  Future<void> _persistWindowState() async {
    try {
      final maximized = await windowManager.isMaximized();
      final patch = <String, dynamic>{'maximized': maximized};
      if (!maximized) {
        final bounds = await windowManager.getBounds();
        patch['width'] = bounds.width;
        patch['height'] = bounds.height;
        patch['x'] = bounds.left;
        patch['y'] = bounds.top;
      }
      await Api.instance.saveWindowState(patch);
    } catch (_) {
      // Geometry persistence is best-effort.
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild the MaterialApp whenever the palette changes (settings dialog,
    // macOS appearance switch). The subtree is re-keyed as well: widgets read
    // AppColors directly rather than through Theme, so a plain theme swap would
    // not repaint them.
    return ValueListenableBuilder<AppPalette>(
      valueListenable: AppColors.notifier,
      builder: (context, palette, _) => MaterialApp(
        title: kAppName,
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        // Keeps the platform text scale inside the range the layout was
        // designed for, so a 125%/150% system font setting cannot push fixed
        // height controls out of their rows.
        builder: (context, child) =>
            applyTextScaleClamp(context, child ?? const SizedBox.shrink()),
        home: KeyedSubtree(
          key: ValueKey<String>('shell-${AppColors.revision}'),
          child: Shell(key: ValueKey<String>('shell-view-${AppColors.revision}')),
        ),
      ),
    );
  }
}
