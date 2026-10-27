import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/update_apply.dart';
import 'package:rust_myadmin_desktop/src/update_check.dart';
import 'package:rust_myadmin_desktop/src/update_source.dart';

UpdateCheckResult _result({
  String version = '1.1.0',
  Map<String, String> assets = const <String, String>{},
}) =>
    UpdateCheckResult(
      hasUpdate: true,
      currentVersion: '1.0.0',
      latestVersion: version,
      notes: '',
      downloadUrl: '',
      assets: assets,
    );

void main() {
  group('autoUpdateAssetUrl', () {
    test('manifest assets win over the release naming convention', () {
      final result = _result(assets: <String, String>{
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

    test('falls back to the GitHub release naming convention', () {
      final result = _result();
      final expected = Platform.isMacOS
          ? 'https://github.com/$kUpdateRepoLabel/releases/download/v1.1.0/'
              'DBPilot-1.1.0-macos.zip'
          : Platform.isWindows
              ? 'https://github.com/$kUpdateRepoLabel/releases/download/v1.1.0/'
                  'DBPilot-1.1.0-windows-x64-setup.exe'
              : null; // Linux outside an AppImage cannot update in place.
      expect(autoUpdateAssetUrl(result), expected);
    });

    test('an empty version has no asset', () {
      expect(autoUpdateAssetUrl(_result(version: '   ')), isNull);
    });
  });

  group('updateFileNameFromUrl', () {
    test('uses the last path segment', () {
      expect(
        updateFileNameFromUrl(
            'https://github.com/L-Y-P/DBPilot/releases/download/v1.1.0/DBPilot-1.1.0-macos.zip'),
        'DBPilot-1.1.0-macos.zip',
      );
    });

    test('ignores query strings and fragments', () {
      expect(
        updateFileNameFromUrl('https://example.com/a/DBPilot-1.1.0.exe?x=1#y'),
        'DBPilot-1.1.0.exe',
      );
    });

    test('sanitizes unsafe characters', () {
      expect(updateFileNameFromUrl('https://example.com/a%20b.zip'),
          'a_b.zip');
      expect(updateFileNameFromUrl('https://example.com/'), 'DBPilot-update.bin');
    });
  });

  test('a missing package is rejected before touching the app', () async {
    await expectLater(
      applyUpdateAndRestart(File('/nonexistent/dbpilot-update.zip'), '1.1.0'),
      throwsA(isA<UpdateApplyException>()),
    );
  });

  test('macOS: extracts and swaps the app bundle in place', () async {
    if (!Platform.isMacOS) return;
    final temp = await Directory.systemTemp.createTemp('dbpilot-apply-test');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    // Fake "installed" app plus the newer app inside a real update zip.
    final parent = Directory('${temp.path}/Applications')
      ..createSync(recursive: true);
    final installedExeDir =
        Directory('${parent.path}/DBPilot.app/Contents/MacOS')
          ..createSync(recursive: true);
    File('${installedExeDir.path}/DBPilot').writeAsStringSync('old');

    final newAppRoot = Directory('${temp.path}/staging')
      ..createSync(recursive: true);
    final newExeDir = Directory(
        '${newAppRoot.path}/DBPilot.app/Contents/MacOS')
      ..createSync(recursive: true);
    File('${newExeDir.path}/DBPilot').writeAsStringSync('new');
    final zip = File('${temp.path}/DBPilot-9.9.9-macos.zip');
    final zipped = await Process.run('ditto', <String>[
      '-c',
      '-k',
      '--keepParent',
      '${newAppRoot.path}/DBPilot.app',
      zip.path,
    ]);
    expect(zipped.exitCode, 0, reason: zipped.stderr.toString());

    applyResolvedExecutable = () => '${installedExeDir.path}/DBPilot';
    final started = <String>[];
    applyProcessStart = (String executable, List<String> arguments) async {
      started.add('$executable ${arguments.join(' ')}');
    };
    addTearDown(() {
      applyResolvedExecutable = () => Platform.resolvedExecutable;
      applyProcessStart = (String executable, List<String> arguments) async {
        await Process.start(executable, arguments,
            mode: ProcessStartMode.detached);
      };
    });

    await applyUpdateAndRestart(zip, '9.9.9');

    expect(
      File('${parent.path}/DBPilot.app/Contents/MacOS/DBPilot')
          .readAsStringSync(),
      'new',
    );
    expect(Directory('${parent.path}/.DBPilot.app.old').existsSync(), isFalse);
    expect(Directory('${parent.path}/.DBPilot.app.updating').existsSync(),
        isFalse);
    expect(started.single, contains('open -n ${parent.path}/DBPilot.app'));
  });

  group('Windows 升级计划（真机事故的回归锁定）', () {
    const exe = r'C:\Program Files\DBPilot\DBPilot.exe';
    const pkg = r'C:\Users\u\AppData\Local\Temp\upd\setup.exe';
    const dir = r'C:\Program Files\DBPilot';

    test('把应用所在目录作为 /D= 传给安装包', () {
      final plan = buildWindowsApplyPlan(
        packagePath: pkg,
        executable: exe,
        installDir: dir,
      );
      // /D 被 .onInit 覆盖过，导致「装到别处」的机器升级时装出第二套；
      // 现在显式传，并且必须是不带引号的最后一项。
      expect(plan.cmdBody, contains('/S /D=$dir'));
      expect(plan.cmdBody, isNot(contains('"/D=')));
    });

    test('没有安装目录时只传 /S', () {
      final plan = buildWindowsApplyPlan(
        packagePath: pkg,
        executable: exe,
        installDir: null,
      );
      expect(plan.cmdBody, contains('/S'));
      expect(plan.cmdBody, isNot(contains('/D=')));
    });

    test('cmd 脚本用 CRLF 换行', () {
      final plan = buildWindowsApplyPlan(
        packagePath: pkg,
        executable: exe,
        installDir: dir,
      );
      // 只有 LF 的 .cmd 会被 cmd.exe 解析错行，安装根本不执行。
      // 用 codeUnits 断言，避免测试里的转义写法与源码各写各的。
      final units = plan.cmdBody.codeUnits;
      final cr = 0x0D;
      final lf = 0x0A;
      expect(units.contains(lf), isTrue);
      for (var i = 0; i < units.length; i++) {
        if (units[i] == lf) expect(units[i - 1], cr);
      }
    });

    test('安装包先复制再执行（原件可能在更新目录里被清理）', () {
      final plan = buildWindowsApplyPlan(
        packagePath: pkg,
        executable: exe,
        installDir: dir,
      );
      expect(plan.stagedPath, endsWith('DBPilot-setup-staged.exe'));
      expect(plan.cmdBody, contains(plan.stagedPath));
      expect(plan.cmdBody, isNot(contains(pkg)));
    });

    test('用 start /wait 等待安装结束后再重启应用', () {
      final plan = buildWindowsApplyPlan(
        packagePath: pkg,
        executable: exe,
        installDir: dir,
      );
      // 早先用 Start-Process -Verb RunAs 后 WaitForExit 会提前返回，
      // 旧版应用在安装写盘中途就被拉起 —— 用户看到「重启了但版本没变」。
      expect(plan.psScript, contains('start "" /wait'));
      expect(plan.psScript, contains('WaitForExit()'));
      expect(plan.psScript, contains(exe));
      expect(plan.psScript, isNot(contains('__SCRIPT__')));
      expect(plan.psScript, isNot(contains('__EXE__')));
      expect(plan.psScript, isNot(contains('@C@')));
    });
  });
}
