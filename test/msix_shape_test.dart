// MSIX shape detection: the pure predicate that decides whether this process
// is a Microsoft Store (MSIX) build, plus the two places the update flow
// consults it (autoUpdateAssetUrl / applyUpdateAndRestart).
//
// Everything here runs on any host: the predicate takes the executable path and
// the environment as arguments, and the process-level seam is swapped, so the
// Windows/Store shape can be exercised from macOS or Linux CI.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/platform_shape.dart';
import 'package:rust_myadmin_desktop/src/update_apply.dart';
import 'package:rust_myadmin_desktop/src/update_check.dart';
import 'package:rust_myadmin_desktop/src/update_source.dart';

const String _msixExe =
    r'C:\Program Files\WindowsApps\DBPilot_8wekyb3d8bbwe\DBPilot.exe';
const String _nsisExe = r'C:\Program Files\DBPilot\DBPilot.exe';
const String _devExe =
    r'C:\Users\me\dev\dbpilot\desktop\build\windows\x64\runner\Release\DBPilot.exe';

UpdateCheckResult _result({
  String version = '1.1.0',
  Map<String, String> assets = const <String, String>{},
}) =>
    UpdateCheckResult(
      hasUpdate: true,
      currentVersion: '1.0.0',
      latestVersion: version,
      notes: '',
      downloadUrl: 'https://github.com/L-Y-P/DBPilot/releases/tag/v$version',
      assets: assets,
    );

/// Runs [body] pretending to be an MSIX process, then restores the seams.
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
  tearDown(() {
    platformShapeExecutable = () => Platform.resolvedExecutable;
    platformShapeEnvironment = () => Platform.environment;
  });

  group('isMsixPackaged — 环境变量优先', () {
    test('APPX_PACKAGE_FAMILY_NAME 存在即 MSIX（路径无关）', () {
      // 商店版本一定会带这个变量；此时连 exe 路径都不用看。
      expect(
        isMsixPackaged(
          executablePath: _nsisExe,
          environment: <String, String>{kAppxPackageFamilyNameEnv: 'DBPilot_8wekyb3d8bbwe'},
        ),
        isTrue,
      );
      expect(
        isMsixPackaged(
          executablePath: '',
          environment: <String, String>{kAppxPackageFamilyNameEnv: 'X' },
        ),
        isTrue,
      );
    });

    test('变量为空串/纯空白时不算（未打包进程可能继承空值）', () {
      for (final value in <String>['', '   ']) {
        expect(
          isMsixPackaged(
            executablePath: _nsisExe,
            environment: <String, String>{kAppxPackageFamilyNameEnv: value},
          ),
          isFalse,
        );
      }
    });

    test('变量缺失时回退到路径判断', () {
      expect(
        isMsixPackaged(executablePath: _msixExe, environment: const <String, String>{}),
        isTrue,
      );
    });
  });

  group('isMsixPackaged — 路径回退', () {
    test('WindowsApps 目录下判定为 MSIX', () {
      expect(
        isMsixPackaged(executablePath: _msixExe, environment: const <String, String>{}),
        isTrue,
      );
    });

    test('大小写与正斜杠都认（Windows 路径不区分大小写）', () {
      for (final path in <String>[
        r'C:\PROGRAM FILES\WINDOWSAPPS\DBPilot_x\DBPilot.exe',
        'C:/Program Files/WindowsApps/DBPilot_x/DBPilot.exe',
      ]) {
        expect(
          isMsixPackaged(executablePath: path, environment: const <String, String>{}),
          isTrue,
          reason: path,
        );
      }
    });

    test('NSIS 安装目录、开发构建目录都不是 MSIX', () {
      for (final path in <String>[_nsisExe, _devExe]) {
        expect(
          isMsixPackaged(executablePath: path, environment: const <String, String>{}),
          isFalse,
          reason: path,
        );
      }
    });

    test('名字相近的兄弟目录（WindowsApps-backup）不算', () {
      // 只有 \\WindowsApps\\ 这一段本身才算；否则自制备份副本会被当成商店版，
      // 自动更新被无故禁用。
      expect(
        isMsixPackaged(
          executablePath: r'C:\Users\me\WindowsApps-backup\DBPilot\DBPilot.exe',
          environment: const <String, String>{},
        ),
        isFalse,
      );
    });

    test('空路径与 macOS/Linux 路径都不算', () {
      for (final path in <String>[
        '',
        '   ',
        '/Applications/DBPilot.app/Contents/MacOS/DBPilot',
        '/opt/DBPilot/DBPilot',
      ]) {
        expect(
          isMsixPackaged(executablePath: path, environment: const <String, String>{}),
          isFalse,
          reason: 'path=$path',
        );
      }
    });
  });

  test('isRunningAsMsix 读取测试缝', () async {
    expect(isRunningAsMsix(), isFalse);
    await asMsix(() async {
      expect(isRunningAsMsix(), isTrue);
    });
    expect(isRunningAsMsix(), isFalse);
  });

  group('MSIX 形态：自动更新被禁用', () {
    test('autoUpdateAssetUrl 返回 null，即使清单里明确给了资产地址', () async {
      await asMsix(() async {
        final result = _result(assets: const <String, String>{
          'windows_setup': 'https://example.com/DBPilot-1.1.0-windows-x64-setup.exe',
          'macos_zip': 'https://example.com/DBPilot-1.1.0-macos.zip',
        });
        expect(autoUpdateAssetUrl(result), isNull);
        // 版本号为空时本来就返回 null，这里只是确认两条路径都走不到下载。
        expect(autoUpdateAssetUrl(_result(version: '  ')), isNull);
      });
    });

    test('applyUpdateAndRestart 直接拒绝，且不碰外部安装包', () async {
      await asMsix(() async {
        // 故意给一个存在的文件：拒绝必须发生在任何进程启动/文件写入之前。
        final temp = await Directory.systemTemp.createTemp('dbpilot-msix-test');
        addTearDown(() {
          if (temp.existsSync()) temp.deleteSync(recursive: true);
        });
        final package = File('${temp.path}/DBPilot-1.1.0-windows-x64-setup.exe')
          ..writeAsStringSync('not really an installer');
        final started = <String>[];
        applyProcessStart = (String exe, List<String> args) async {
          started.add(exe);
        };
        applyProcessRun = (String exe, List<String> args) async {
          started.add(exe);
          return ProcessResult(0, 0, '', '');
        };
        addTearDown(() {
          applyProcessStart = (String exe, List<String> args) async {
            await Process.start(exe, args, mode: ProcessStartMode.detached);
          };
          applyProcessRun = Process.run;
        });

        await expectLater(
          applyUpdateAndRestart(package, '1.1.0'),
          throwsA(isA<UpdateApplyException>().having(
            (UpdateApplyException e) => e.message,
            'message',
            kMsixUpdateGuidance,
          )),
        );
        // 商店版不得落地任何外部流程（NSIS / ditto / AppImage 替换）。
        expect(started, isEmpty);
      });
    });

    test('提示文案明确指向 Microsoft Store', () {
      expect(kMsixUpdateGuidance, contains('Microsoft Store'));
      expect(kMsixUpdateGuidanceEn, contains('Microsoft Store'));
    });
  });

  group('非 MSIX 形态行为不变（回归锁）', () {
    test('autoUpdateAssetUrl 仍按清单资产地址返回', () {
      // 本机是 macOS/Linux 时用清单里的 macos/linux 地址断言；Windows 真机用
      // windows_setup。关键是：没有 MSIX 环境时，行为与本次改动之前一致。
      final result = _result(assets: const <String, String>{
        'macos_zip': 'https://example.com/custom-macos.zip',
        'windows_setup': 'https://example.com/custom-setup.exe',
        'linux_appimage': 'https://example.com/custom.AppImage',
      });
      final expected = Platform.isMacOS
          ? 'https://example.com/custom-macos.zip'
          : Platform.isWindows
              ? 'https://example.com/custom-setup.exe'
              : null;
      expect(autoUpdateAssetUrl(result), expected);
    });

    test('GitHub 命名约定仍然生效（macOS）', () {
      if (!Platform.isMacOS) return;
      expect(
        autoUpdateAssetUrl(_result()),
        'https://github.com/$kUpdateRepoLabel/releases/download/v1.1.0/'
        'DBPilot-1.1.0-macos.zip',
      );
    });

    test('Windows 升级计划与本机路径不受 MSIX 判定影响', () {
      // buildWindowsApplyPlan 是纯函数，MSIX 分支不该改变它（商店版根本走不到）。
      final plan = buildWindowsApplyPlan(
        packagePath: r'C:\Users\u\AppData\Local\Temp\upd\setup.exe',
        executable: _nsisExe,
        installDir: r'C:\Program Files\DBPilot',
      );
      expect(plan.cmdBody, contains(r'/S /D=C:\Program Files\DBPilot'));
    });
  });
}
