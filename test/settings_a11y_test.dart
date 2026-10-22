// Round34 P3-05 / P3-06 / P3-08b / P3-11: settings entry point and modal shell.
//
// These drive the real shell with a booted Rust core so the assertions describe
// what the OS accessibility layer and the default window actually see.

import 'dart:io';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';
import 'package:rust_myadmin_desktop/src/nav.dart';
import 'package:rust_myadmin_desktop/src/settings_channel.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/shell.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';

Future<void> _boot() async {
  final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
  if (!dylib.existsSync()) {
    fail('Run `cargo build --lib` in rust/ first: ${dylib.path} is missing');
  }
  await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));

  final dir = Directory('${Directory.systemTemp.path}/rma-settings-a11y');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  await dir.create(recursive: true);

  final init = await Api.init(dir.path);
  expect(init['ok'], isTrue, reason: 'init_app failed: $init');
  await AppState.instance.bootstrap(dir.path);
  expect(AppState.instance.bootstrapError, isNull,
      reason: 'bootstrap failed: ${AppState.instance.bootstrapError}');

  // The shell always needs an open connection to render its pages.
  final dbFile = '${dir.path}/a11y.sqlite';
  await File(dbFile).create(recursive: true);
  final created = await Api.instance.createConnection(<String, dynamic>{
    'name': 'a11y',
    'driver': 'sqlite',
    'database': dbFile,
  });
  await AppState.instance
      .connect((created['connection'] as Map)['id'].toString());
  await AppState.instance.refreshDatabases();
  AppState.instance.notify();

  // What main() does: the native "Settings…" menu item forwards Cmd+, here.
  initSettingsChannel();
}

/// Real-clock pumping: FFI futures need an event loop, not the fake clock.
Future<void> _settle(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Widget _app() => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const Shell(),
    );

void _window(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _sendOpenSettingsChord(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
  await tester.sendKeyEvent(LogicalKeyboardKey.comma);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
}

void main() {
  setUpAll(_boot);

  setUp(() {
    I18n.setLang(AppLang.zh);
    Navigation.instance.go(AppRoute.connections);
  });

  tearDown(() {
    I18n.setLang(AppLang.zh);
  });

  testWidgets('the gear is a labelled button and Cmd+, opens the settings dialog',
      (tester) async {
    _window(tester, const Size(1400, 900));
    // Disposed explicitly at the end: end-of-test verification runs before
    // tearDown hooks, so addTearDown would be too late for this handle.
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_app());
    await _settle(tester);

    final gear = find.byKey(const ValueKey('topbar-settings'));
    expect(gear, findsOneWidget);
    // P3-05: the AX tree must expose a button with a read-able label; before
    // the fix the gear was a bare Container + GestureDetector, so macOS only
    // reported the hover tooltip.
    final labelled = find.bySemanticsLabel(RegExp('设置'));
    expect(labelled, findsWidgets);
    final data = tester.getSemantics(labelled.first).getSemanticsData();
    expect(data.label, contains('设置'));
    expect(data.flagsCollection.isButton, isTrue);

    // The conventional preferences chord opens the same dialog.
    await _sendOpenSettingsChord(tester);
    await _settle(tester);
    expect(find.byKey(const ValueKey('settings-lang-zh')), findsOneWidget);

    // The gear itself is still clickable.
    await tester.tap(find.byKey(const ValueKey('dialog-close')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('settings-lang-zh')), findsNothing);
    await tester.tap(gear);
    await _settle(tester);
    expect(find.byKey(const ValueKey('settings-lang-zh')), findsOneWidget);
    // Explicit dispose: end-of-test verification runs before tearDown hooks.
    semantics.dispose();
  });

  testWidgets('a click outside the modal no longer dismisses it (P3-06)',
      (tester) async {
    _window(tester, const Size(1400, 900));
    await tester.pumpWidget(_app());
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('topbar-settings')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('settings-lang-zh')), findsOneWidget);

    // The barrier used to be exposed as a screen-wide, tappable "Dismiss" node;
    // a stray click closed the dialog and every half-filled form in it.
    expect(find.bySemanticsLabel(RegExp(r'^Dismiss$')), findsNothing);
    await tester.tapAt(const Offset(4, 4));
    await _settle(tester);
    expect(find.byKey(const ValueKey('settings-lang-zh')), findsOneWidget);
  });

  testWidgets('the dialog fits the default 1282x817 window (P3-11)',
      (tester) async {
    _window(tester, const Size(1282, 817));
    await tester.pumpWidget(_app());
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('topbar-settings')));
    await _settle(tester);
    expect(tester.takeException(), isNull,
        reason: 'opening the dialog must not overflow the window');

    // P3-11's narrow-window row is gone with the update-address field: the
    // check button now shares its line with a read-only caption, so it must
    // still be reachable and inside the dialog after scrolling it into view.
    await tester
        .ensureVisible(find.byKey(const ValueKey('settings-check-update')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final dialog = tester.getRect(find.byType(Dialog));
    final button =
        tester.getRect(find.byKey(const ValueKey('settings-check-update')));
    expect(button.left, greaterThanOrEqualTo(dialog.left));
    expect(button.right, lessThanOrEqualTo(dialog.right));
    expect(button.right, lessThanOrEqualTo(1282),
        reason: 'the button has to stay inside the window to be clickable');
    // The caption is read-only and must not turn into an editable control.
    expect(find.byKey(const ValueKey('settings-update-url')), findsNothing);
    expect(find.byKey(const ValueKey('settings-update-source')), findsOneWidget);
  });

  testWidgets('English mode translates the footer and the theme names (P3-08b)',
      (tester) async {
    _window(tester, const Size(1400, 900));
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_app());
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('topbar-settings')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('settings-lang-en')));
    await _settle(tester);
    expect(I18n.current, AppLang.en);

    // Footer action created in Chinese must re-render as English.
    expect(find.text('Close'), findsOneWidget);
    expect(find.text('关闭'), findsNothing);
    // The accent swatches only expose their name through semantics / tooltip;
    // both were hard-wired to labelZh.
    final swatch = find.byKey(const ValueKey('settings-color-indigo'));
    expect(swatch, findsOneWidget);
    expect(find.bySemanticsLabel('Indigo'), findsWidgets);
    semantics.dispose();
  });

  testWidgets('the native Settings menu request opens the dialog (macOS Cmd+,)',
      (tester) async {
    _window(tester, const Size(1400, 900));
    await tester.pumpWidget(_app());
    await _settle(tester);
    expect(find.byKey(const ValueKey('settings-lang-zh')), findsNothing);

    // Exactly what AppDelegate.openSettings sends: Cmd+, is consumed by the
    // AppKit menu, so the menu item forwards this method call instead.
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'dbpilot/settings',
      const StandardMethodCodec()
          .encodeMethodCall(const MethodCall('open')),
      (_) {},
    );
    await _settle(tester);

    expect(find.byKey(const ValueKey('settings-lang-zh')), findsOneWidget);
  });
}
