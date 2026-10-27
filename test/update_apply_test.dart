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
}
