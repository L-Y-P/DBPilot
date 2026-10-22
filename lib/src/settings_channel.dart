import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Requests to open the settings dialog that come from outside Flutter.
///
/// On macOS `Cmd+,` is an AppKit *menu key equivalent*: the "Preferences…"
/// menu item consumes it before the key ever reaches Flutter, so the
/// [SingleActivator] binding in the shell can never fire in the packaged app
/// even though it works in widget tests. The menu item now calls an action in
/// `AppDelegate`, which forwards a method call here; the shell listens and
/// opens the same dialog. Other platforms (and the Ctrl+, binding) still go
/// through the Flutter shortcut.
final ValueNotifier<int> settingsOpenRequests = ValueNotifier<int>(0);

const MethodChannel _channel = MethodChannel('dbpilot/settings');

/// Wire the native menu to [settingsOpenRequests]. Call once at startup.
void initSettingsChannel() {
  _channel.setMethodCallHandler((MethodCall call) async {
    if (call.method == 'open') {
      settingsOpenRequests.value += 1;
    }
  });
}
