import 'dart:io';

/// Test seam for opening a URL in the platform's default browser.
///
/// `flutter test` has no platform process, so widget tests substitute this
/// function with a recorder instead of launching a real browser on the build
/// machine. Production code never reassigns it.
Future<bool> Function(String url) openExternalUrl = openUrlInBrowser;

/// Opens [url] with the platform's default handler and reports whether the
/// handler was started successfully.
///
/// Only http/https URLs are accepted: anything else (`file:`,
/// `javascript:`, arbitrary custom schemes) is rejected before it can reach
/// the OS, so a malformed manifest or a typo can never turn into a command.
Future<bool> openUrlInBrowser(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return false;
  }
  final target = uri.toString();
  try {
    final ProcessResult result;
    if (Platform.isMacOS) {
      result = await Process.run('open', <String>[target]);
    } else if (Platform.isWindows) {
      // `start` is a cmd builtin, so use the ShellExecute-based rundll32
      // handler which behaves the same for http(s) URLs without a shell.
      result = await Process.run(
        'rundll32',
        <String>['url.dll,FileProtocolHandler', target],
      );
    } else {
      result = await Process.run('xdg-open', <String>[target]);
    }
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}
