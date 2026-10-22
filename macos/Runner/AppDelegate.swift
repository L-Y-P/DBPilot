import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// "Preferences…" (Cmd+,) from the app menu.
  ///
  /// On macOS `Cmd+,` is an AppKit menu key equivalent, so the menu item
  /// consumes the chord before it can reach Flutter's key handler; without an
  /// action it also did nothing at all. Forward it to the Dart side, which
  /// opens the same settings dialog as the topbar gear
  /// (see lib/src/settings_channel.dart).
  @IBAction func openSettings(_ sender: Any?) {
    let controller = NSApp.windows
      .compactMap { $0.contentViewController as? FlutterViewController }
      .first
    guard let controller = controller else { return }
    let channel = FlutterMethodChannel(
      name: "dbpilot/settings",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.invokeMethod("open", arguments: nil)
  }
}
