import 'dart:io';

import 'platform_shape.dart';
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

/// Message shown wherever the Store build would otherwise offer an in-app
/// update. Kept next to the code that refuses the update so the dialog, the
/// exception and the tests cannot drift apart.
const String kMsixUpdateGuidance =
    '当前为 Microsoft Store 版本，应用内自动更新已停用，请从 Microsoft Store 更新。';

/// English of [kMsixUpdateGuidance].
///
/// The dialog renders one of the two via `pickText`; the exception carries the
/// Chinese copy and the translator rewrites it (see en_settings.dart), so both
/// surfaces agree word for word.
const String kMsixUpdateGuidanceEn =
    'This is the Microsoft Store version: in-app updates are disabled. '
    'Please update from the Microsoft Store.';

/// Picks the package that [applyUpdateAndRestart] can install on this host.
///
/// The manifest may advertise explicit asset URLs (`assets` in update.json);
/// when it does not, the GitHub release naming convention is used. Returns
/// null when this installation cannot be updated in place (for example a
/// Linux deb/rpm install, which needs the system package manager, or an MSIX
/// build, which only the Store may update).
String? autoUpdateAssetUrl(UpdateCheckResult result) {
  // MSIX/Store builds are re-signed on every release and may not run an
  // external installer, so there is no package this process is allowed to
  // apply. Returning null leaves the dialog on its manual/managed path.
  if (isRunningAsMsix()) return null;

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
///
/// An MSIX (Microsoft Store) build refuses before looking at the package:
/// Windows does not let a packaged app run the NSIS installer to replace
/// itself, and the Store re-signs every release, so updating is its job.
Future<void> applyUpdateAndRestart(File package, String version) async {
  if (isRunningAsMsix()) {
    throw const UpdateApplyException(kMsixUpdateGuidance);
  }
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

/// 从正在运行的可执行文件路径反推安装目录（Windows）。
///
/// `Platform.resolvedExecutable` 形如 `C:\\Program Files\\DBPilot\\DBPilot.exe`，
/// 取父目录即可。拿不到（例如在 IDE 里跑调试产物）时返回 null，调用方退回
/// 不带 `/D=` 的调用，让安装包按注册表里的旧路径升级。
String? _windowsInstallDir(String executable) {
  final sep = executable.lastIndexOf('\\');
  if (sep <= 0) return null;
  final dir = executable.substring(0, sep);
  // 盘符根（`C:`）不可能是安装目录，宁可返回 null 让安装包自己决定。
  if (dir.length <= 2) return null;
  return dir;
}

/// Windows 升级脚本的纯逻辑部分（便于单测，不碰真实进程）。
///
/// 拆出来是为了能在 `flutter test` 里断言「/D= 位置正确、没有多余引号、
/// cmd 用 CRLF、占位符被替换」这些细节 —— 每一条都对应一次真机事故。
class WindowsApplyPlan {
  const WindowsApplyPlan({
    required this.stagedPath,
    required this.cmdBody,
    required this.cmdScriptPath,
    required this.psScript,
  });

  /// 复制出来的安装包副本（原包在 %TEMP% 的更新目录里，可能中途被清理）。
  final String stagedPath;

  /// .cmd 内容。CRLF 换行：cmd.exe 对只有 LF 的脚本会解析错行。
  final String cmdBody;

  /// .cmd 落盘路径。
  final String cmdScriptPath;

  /// 交给 powershell 的提权启动脚本。
  final String psScript;
}

/// 组装 Windows 升级所需的全部内容（不执行任何进程）。
///
/// [installDir] 为空时只传 `/S`，让安装包按注册表里的旧路径升级。
WindowsApplyPlan buildWindowsApplyPlan({
  required String packagePath,
  required String executable,
  required String? installDir,
}) {
  final cut = packagePath.lastIndexOf(RegExp(r'[/\\]'));
  final work = cut > 0 ? packagePath.substring(0, cut) : '.';
  final stagedPath = '$work/DBPilot-setup-staged.exe';
  final logPath = '$work/update-install.log';
  final scriptPath = '$work/apply-update.cmd';

  // /D= 必须是最后一项，且**不加引号**：NSIS 取的是原样字符串，引号会进路径。
  final nsisArgs = (installDir == null || installDir.isEmpty)
      ? '/S'
      : '/S /D=$installDir';

  final cmdBody = <String>[
    '@echo off',
    '"$stagedPath" $nsisArgs',
    'echo EXITCODE=%ERRORLEVEL% > "$logPath"',
    'exit /b %ERRORLEVEL%',
  ].join('\r\n');

  // 美元符用 fromCharCode 取：它在 Dart 字符串里是插值前缀，写字面量编译不过。
  final dollar = String.fromCharCode(0x24);
  final psScript = (
      'Start-Sleep -Seconds 2; '
      '@C@p = Start-Process -FilePath ''cmd.exe'' '
      '-ArgumentList ''/c start "" /wait ""__SCRIPT__""'' '
      '-Verb RunAs -WindowStyle Hidden -PassThru; '
      '@C@p.WaitForExit(); '
      'Start-Process -FilePath ''__EXE__''')
      .replaceAll('@C@', dollar)
      .replaceAll('__SCRIPT__', scriptPath)
      .replaceAll('__EXE__', executable);

  return WindowsApplyPlan(
    stagedPath: stagedPath,
    cmdBody: cmdBody,
    cmdScriptPath: scriptPath,
    psScript: psScript,
  );
}

Future<void> _applyWindows(File package) async {
  final executable = applyResolvedExecutable();
  final plan = buildWindowsApplyPlan(
    packagePath: package.path,
    executable: executable,
    installDir: _windowsInstallDir(executable),
  );
  final staged = File(plan.stagedPath);
  await package.copy(staged.path);
  await File(plan.cmdScriptPath).writeAsString(plan.cmdBody);
  await applyProcessStart('powershell', <String>[
    '-NoProfile',
    '-WindowStyle',
    'Hidden',
    '-ExecutionPolicy',
    'Bypass',
    '-Command',
    plan.psScript,
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
