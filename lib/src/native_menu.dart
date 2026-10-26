import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native menu bridge.
///
/// A right-click menu is a *system* surface: on macOS the only way to get the
/// real thing (correct material, type, accent, keyboard navigation, screen-edge
/// flipping, light/dark) is to let AppKit draw it. The Dart side ships the
/// labels across this channel and gets the chosen index back; the menu itself
/// never passes through Flutter.
///
/// Everything else — widget tests, Windows, Linux, and any macOS build whose
/// channel is missing — falls back to the Flutter-drawn menu in app_menu.dart,
/// so the feature degrades instead of disappearing.
const MethodChannel nativeMenuChannel = MethodChannel('dbpilot/menu');

/// True when the running build can hand menus to the platform.
///
/// Only macOS has a bridge today. The check is deliberately cheap and constant
/// so callers can branch without awaiting anything.
bool get hasNativeMenu =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

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