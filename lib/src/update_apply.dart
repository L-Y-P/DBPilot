import 'dart:io';

import 'update_check.dart';
import 'update_source.dart';

/// The update package could not be applied on this machine.
class UpdateApplyException implements Exception {
  const UpdateApplyException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Test seams for process launches.
///
/// `flutter test` has no platform installer, so tests substitute these with
/// recorders. Production code never reassigns them.
Future<ProcessResult> Function(String executable, List<String> arguments)
    applyProcessRun = Process.run;
Future<void> Function(String executable, List<String> arguments)
    applyProcessStart = (String executable, List<String> arguments) async {
  await Process.start(executable, arguments, mode: ProcessStartMode.detached);
};

/// Test seam: the path of the running app executable (normally
/// [Platform.resolvedExecutable]). Tests point it at a throwaway bundle so the
/// in-place swap can be exercised without touching /Applications.
String Function() applyResolvedExecutable = () => Platform.resolvedExecutable;

/// Picks the package that [applyUpdateAndRestart] can install on this host.
///
/// The manifest may advertise explicit asset URLs (`assets` in update.json);
/// when it does not, the GitHub release naming convention is used. Returns
/// null when this installation cannot be updated in place (for example a
/// Linux deb/rpm install, which needs the system package manager).
String? autoUpdateAssetUrl(UpdateCheckResult result) {
  final version = result.latestVersion.trim();
  if (version.isEmpty) return null;

  String pick(String manifestKey, String conventionalName) {
    final fromManifest = (result.assets[manifestKey] ?? '').trim();
    if (fromManifest.isNotEmpty) return fromManifest;
    return 'https://github.com/$kUpdateRepoLabel/releases/download/v$version/'
        '$conventionalName';
  }

  if (Platform.isMacOS) {
    return pick('macos_zip', 'DBPilot-$version-macos.zip');
  }
  if (Platform.isWindows) {
    return pick('windows_setup', 'DBPilot-$version-windows-x64-setup.exe');
  }
  if (Platform.isLinux) {
    final appImage = (Platform.environment['APPIMAGE'] ?? '').trim();
    if (appImage.isEmpty) return null;
    return pick('linux_appimage', 'DBPilot-$version-linux-x64.AppImage');
  }
  return null;
}

/// File name to use for a downloaded package URL.
String updateFileNameFromUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  String segment = '';
  if (uri != null && uri.pathSegments.isNotEmpty) {
    segment = uri.pathSegments.last;
  }
  if (segment.isEmpty || segment == '.' || segment == '..') {
    return 'DBPilot-update.bin';
  }
  final cleaned = segment.replaceAll(RegExp(r'[^A-Za-z0-9._+-]'), '_');
  return cleaned.isEmpty ? 'DBPilot-update.bin' : cleaned;
}

/// Installs [package] over the running app and starts the new build.
///
/// macOS: extracts the zip, swaps DBPilot.app in place and re-opens it.
/// Windows: starts the NSIS installer silently with elevation and relaunches
/// DBPilot when it returns. Linux: replaces the running AppImage.
///
/// The caller must quit the current process right after this returns.
Future<void> applyUpdateAndRestart(File package, String version) async {
  if (!package.existsSync()) {
    throw const UpdateApplyException('更新包不存在');
  }
  if (Platform.isMacOS) return _applyMacos(package);
  if (Platform.isWindows) return _applyWindows(package);
  if (Platform.isLinux) return _applyLinuxAppImage(package);
  throw const UpdateApplyException('当前平台不支持自动更新');
}

Future<void> _applyMacos(File package) async {
  final executable = applyResolvedExecutable();
  final marker = executable.indexOf('.app/');
  if (marker < 0) {
    throw const UpdateApplyException('无法定位 DBPilot.app 安装位置');
  }
  final bundlePath = executable.substring(0, marker + 4);
  final bundle = Directory(bundlePath);
  final parent = bundle.parent;

  final work = Directory('${package.parent.path}/dbpilot-extract');
  if (work.existsSync()) work.deleteSync(recursive: true);
  final extract = await applyProcessRun(
      'ditto', <String>['-x', '-k', package.path, work.path]);
  if (extract.exitCode != 0) {
    throw UpdateApplyException('解压更新包失败（ditto ${extract.exitCode}）');
  }
  final newApp = Directory('${work.path}/DBPilot.app');
  if (!newApp.existsSync()) {
    throw const UpdateApplyException('更新包里没有 DBPilot.app');
  }

  final staged = Directory('${parent.path}/.DBPilot.app.updating');
  final backup = Directory('${parent.path}/.DBPilot.app.old');
  if (staged.existsSync()) staged.deleteSync(recursive: true);
  if (backup.existsSync()) backup.deleteSync(recursive: true);
  final copy = await applyProcessRun('ditto', <String>[newApp.path, staged.path]);
  if (copy.exitCode != 0 || !staged.existsSync()) {
    throw UpdateApplyException('写入安装目录失败（ditto ${copy.exitCode}）');
  }

  try {
    bundle.renameSync(backup.path);
    staged.renameSync(bundle.path);
  } catch (e) {
    if (!bundle.existsSync() && backup.existsSync()) {
      try {
        backup.renameSync(bundle.path);
      } catch (_) {}
    }
    if (staged.existsSync()) {
      try {
        staged.deleteSync(recursive: true);
      } catch (_) {}
    }
    throw UpdateApplyException(
        '替换 DBPilot.app 失败：$e（如无写入权限，请用安装包手动更新）');
  }

  if (backup.existsSync()) {
    try {
      backup.deleteSync(recursive: true);
    } catch (_) {}
  }
  try {
    if (work.existsSync()) work.deleteSync(recursive: true);
  } catch (_) {}
  await applyProcessStart('open', <String>['-n', bundle.path]);
}

Future<void> _applyWindows(File package) async {
  final executable = applyResolvedExecutable();
  String quote(String value) => "'${value.replaceAll("'", "''")}'";
  final script = 'Start-Sleep -Seconds 2; '
      'try { \$p = Start-Process -FilePath ${quote(package.path)} '
      '-ArgumentList "/S" -Verb RunAs -PassThru; \$p.WaitForExit() } '
      'finally { Start-Process -FilePath ${quote(executable)} }';
  await applyProcessStart('powershell', <String>[
    '-NoProfile',
    '-WindowStyle',
    'Hidden',
    '-ExecutionPolicy',
    'Bypass',
    '-Command',
    script,
  ]);
}

Future<void> _applyLinuxAppImage(File package) async {
  final appImage = (Platform.environment['APPIMAGE'] ?? '').trim();
  if (appImage.isEmpty) {
    throw const UpdateApplyException(
        '当前安装方式不支持自动更新（仅 AppImage 支持应用内更新）');
  }
  final current = File(appImage);
  if (!current.existsSync()) {
    throw const UpdateApplyException('找不到当前 AppImage 文件');
  }
  final incoming = File('$appImage.updating');
  final backup = File('$appImage.old');
  await package.copy(incoming.path);
  final chmod = await applyProcessRun('chmod', <String>['+x', incoming.path]);
  if (chmod.exitCode != 0) {
    throw UpdateApplyException('设置可执行权限失败（chmod ${chmod.exitCode}）');
  }
  if (backup.existsSync()) backup.deleteSync();
  current.renameSync(backup.path);
  try {
    incoming.renameSync(appImage);
  } catch (e) {
    try {
      backup.renameSync(appImage);
    } catch (_) {}
    throw UpdateApplyException('替换 AppImage 失败：$e');
  }
  try {
    backup.deleteSync();
  } catch (_) {}
  await applyProcessStart(appImage, <String>[]);
}
