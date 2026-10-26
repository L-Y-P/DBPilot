import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native menu bridge.
///
/// A right-click menu is a *system* surface: on macOS the only way to get the
/// real thing (correct material, type, accent, keyboard navigation, screen-edge
/// flipping, light/dark) is to let AppKit draw it. The Dart side ships the
/// labels across this channel and gets the chosen index back; the menu itself
/// never passes through Flutter.
const MethodChannel nativeMenuChannel = MethodChannel('dbpilot/menu');

/// Opt-in switch for the AppKit menu.
///
/// OFF by default, and it should stay that way. `NSMenu.popUp` runs a blocking
/// tracking loop **on the platform thread** — the thread Dart itself runs on.
/// A menu shown that way holds the whole app hostage until it closes, and in
/// practice the app comes back unable to receive clicks at all: every button in
/// every dialog is dead until some other activation cycle, such as another
/// right-click, shakes it loose. Three separate reports ("the menu does
/// nothing", "the dialog does nothing", "nothing responds") all came out of that
/// one API call. A context menu is not worth freezing the app for.
///
/// The Flutter-drawn menu in app_menu.dart is already tuned to look like the
/// system menu (22px rows, hairline separators, no icons, no animation, system
/// light/dark colours), never blocks, and is covered by widget tests and a
/// golden. Build with `--dart-define=DBPILOT_NATIVE_MENU=true` to try the AppKit
/// menu anyway.
const bool _nativeMenuEnabled = bool.fromEnvironment('DBPILOT_NATIVE_MENU');

/// True when the running build can hand menus to the platform.
///
/// The check is deliberately cheap and constant so callers can branch without
/// awaiting anything.
/// Test-only override, so widget tests can still exercise the AppKit path even
/// though production builds keep it off. Never set this from app code.
@visibleForTesting
bool debugNativeMenuEnabled = _nativeMenuEnabled;

bool get hasNativeMenu =>
    debugNativeMenuEnabled &&
    !kIsWeb &&
    defaultTargetPlatform == TargetPlatform.macOS;

/// Show a native menu at ([x], [y]) in Flutter logical pixels.
///
/// Three outcomes, and the difference matters:
///  * >= 0 — the user picked that item;
///  * -1   — the menu was shown and dismissed (Esc, click away). Callers must
///             *not* then draw their own menu;
///  * null — the platform has no menu bridge, so the caller should fall back
///             to the Flutter-drawn menu.
///
/// [items] is a list of maps with `label`, and optional `enabled`, `danger` and
/// `separator` keys.
Future<int?> showNativeMenu(
  List<Map<String, Object?>> items,
  double x,
  double y,
) async {
  if (!hasNativeMenu) return null;
  try {
    final index = await nativeMenuChannel.invokeMethod<int>('show', <String, Object?>{
      'items': items,
      'x': x,
      'y': y,
    });
    return index;
  } on MissingPluginException {
    // A build without the runner change (or a widget test) has no handler.
    return null;
  } on PlatformException {
    return null;
  }
}
