// Regression tests for the overflow / data-file changes.
//
// Reported symptoms this pins:
//   * "有数据显示溢出显示框" — a long cell value rendered a tooltip wider than the
//     window, which is itself an overflow;
//   * groups were removed from the connection editor;
//   * SQLite must add many database files at once, and a typed folder must be
//     walked for SQLite files (a typed file stays one connection);
//   * "打开数据目录" was removed from the tools menu.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/components/data_grid.dart';
import 'package:rust_myadmin_desktop/src/sqlite_sources.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

Widget host(Widget child) => MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: child),
    );

void main() {
  group('tooltip overflow', () {
    testWidgets('a long cell value gets a bounded tooltip', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final longText = 'x' * 4000;
      await tester.pumpWidget(host(SizedBox(
        height: 400,
        child: DataGrid(
          columns: const [
            {'name': 'note', 'type_name': 'TEXT'},
          ],
          rows: [
            [longText],
          ],
          maxHeight: 300,
        ),
      )));
      await tester.pumpAndSettle();

      final tooltips = tester.widgetList<Tooltip>(find.byType(Tooltip)).toList();
      expect(tooltips, isNotEmpty, reason: 'no tooltip on the clipped cell');
      final bounded = tooltips
          .where((t) => t.constraints != null && t.constraints!.maxWidth.isFinite);
      expect(bounded, isNotEmpty,
          reason: 'an unbounded tooltip renders as one very wide line');
      expect(tester.takeException(), isNull);
    });

    testWidgets('gridCell caption is bounded too', (tester) async {
      await tester.pumpWidget(host(Padding(
        padding: const EdgeInsets.all(8),
        child: gridCell('SELECT ${'col, ' * 200}', title: 'y' * 3000),
      )));
      await tester.pumpAndSettle();
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.constraints, isNotNull);
      expect(tooltip.constraints!.maxWidth.isFinite, isTrue);
    });
  });

  group('sqlite sources', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('rma-scan-');
      File('${root.path}/alpha.sqlite').writeAsStringSync('');
      File('${root.path}/notes.txt').writeAsStringSync('');
      Directory('${root.path}/sub').createSync();
      File('${root.path}/sub/beta.db').writeAsStringSync('');
      File('${root.path}/sub/gamma.sqlite3').writeAsStringSync('');
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('only SQLite files are recognised', () {
      expect(isSqliteFile('/x/a.sqlite'), isTrue);
      expect(isSqliteFile('/x/a.sqlite3'), isTrue);
      expect(isSqliteFile('/x/a.db'), isTrue);
      expect(isSqliteFile('/x/a.txt'), isFalse);
      expect(isSqliteFile('/x/sqlite'), isFalse);
    });

    test('a folder is walked recursively', () {
      final found = scanSqliteFolder(root.path);
      expect(found.length, 3, reason: 'two top-level, one nested: $found');
      expect(found.any((p) => p.endsWith('alpha.sqlite')), isTrue);
      expect(found.any((p) => p.endsWith('beta.db')), isTrue);
      expect(found.any((p) => p.endsWith('gamma.sqlite3')), isTrue);
      expect(found.any((p) => p.endsWith('notes.txt')), isFalse);
    });

    test('typed paths split into files and folders', () {
      final file = '${root.path}/alpha.sqlite';
      final resolved = resolveSqlitePaths([file, root.path, '/nope/missing.db']);
      expect(resolved.files, [file]);
      expect(resolved.folders, [root.path]);
      expect(resolved.missing, ['/nope/missing.db']);
    });

    test('connection names come from the file name', () {
      expect(connectionNameFor('/a/b/app.sqlite'), 'app');
      expect(connectionNameFor('/a/b/no-extension'), 'no-extension');
    });
  });

  group('name visibility (only / hide)', () {
    test('matches exact names', () {
      expect(nameVisible(name: 'app'), isTrue);
      expect(nameVisible(only: 'app', name: 'app'), isTrue);
      expect(nameVisible(only: 'app', name: 'other'), isFalse);
    });

    test('supports SQL LIKE wildcards', () {
      expect(nameVisible(only: 'app%', name: 'approvals'), isTrue);
      expect(nameVisible(only: 'app%', name: 'myapp'), isFalse);
      expect(nameVisible(only: 'tmp_', name: 'tmp1'), isTrue);
      expect(nameVisible(only: 'tmp_', name: 'tmp12'), isFalse);
    });

    test('hide wins over only', () {
      expect(nameVisible(only: '%', hide: 'test%', name: 'testing'), isFalse);
      expect(nameVisible(only: '%', hide: 'test%', name: 'prod'), isTrue);
    });

    test('filters a scanned file list by connection name', () {
      final files = <String>['/a/app.sqlite', '/a/test1.db', '/a/notes.sqlite'];
      final kept = filterSqliteFiles(files, only: 'app,notes', hide: null);
      expect(kept, ['/a/app.sqlite', '/a/notes.sqlite']);
    });
  });
}
