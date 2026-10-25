// English-mode coverage: the whole desktop UI must render without Chinese copy.
//
// The English UI is produced by translating **rendered strings** (see
// i18n_literals.dart). That only works if every visible string passes through
// the translator, so this test renders the real shell in English and walks the
// widget tree looking for leftover Han characters in any text channel:
// Text/SelectableText content, Tooltip messages, input hints/labels, button
// labels and dialog titles.
//
// Fixtures are deliberately ASCII-only (connection name, database, table and
// column names), so a Chinese string in the tree is always untranslated UI copy
// and never user data.

import 'dart:io';

import 'package:flutter/material.dart' hide Text, Tooltip;
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';
import 'package:rust_myadmin_desktop/src/i18n_literals.dart';
import 'package:rust_myadmin_desktop/src/nav.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/shell.dart';
import 'package:rust_myadmin_desktop/src/text.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/tooltip.dart';
import 'package:rust_myadmin_desktop/src/views/relation_designer.dart';

final RegExp _han = RegExp(r'[\u4e00-\u9fff]');

Widget _app() => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const Shell(),
    );

Future<void> _settle(WidgetTester tester, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// Every user-visible string currently in the widget tree.
///
/// The translating [Text] and [Tooltip] wrappers hold their source copy, so
/// their content is passed through [trLiteral] exactly like the widget does at
/// build time; Flutter's own widgets already hold the final string.
List<String> _visibleStrings(WidgetTester tester) {
  final out = <String>[];
  for (final widget in tester.allWidgets) {
    if (widget is Text) {
      out.add(trLiteral(widget.data));
    } else if (widget is RichText) {
      out.add(widget.text.toPlainText());
    } else if (widget is SelectableText) {
      out.add(widget.data ?? widget.textSpan?.toPlainText() ?? '');
    } else if (widget is Tooltip) {
      final message = widget.message;
      if (message != null) out.add(trLiteral(message));
    } else if (widget is EditableText) {
      out.add(widget.controller.text);
    } else if (widget is TextField) {
      final decoration = widget.decoration;
      if (decoration != null) {
        out.add(decoration.hintText ?? '');
        out.add(decoration.labelText ?? '');
        out.add(decoration.helperText ?? '');
      }
    }
  }
  return out;
}

/// Copy that is intentionally written in its own language.
///
/// A language switcher names each language in that language ("中文"), which is
/// the convention everywhere and is not untranslated copy.
const Set<String> _allowedChinese = <String>{'中文'};

/// Fail with the offending strings, so a regression names what is missing.
void _expectNoChinese(WidgetTester tester, String where) {
  final offenders = <String>{};
  for (final value in _visibleStrings(tester)) {
    if (_han.hasMatch(value) && !_allowedChinese.contains(value)) {
      offenders.add(value);
    }
  }
  expect(
    offenders,
    isEmpty,
    reason: 'Untranslated Chinese copy rendered on "$where":\n'
        '${offenders.map((s) => '  - $s').join('\n')}',
  );
}

Future<void> _boot() async {
  final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
  if (!dylib.existsSync()) {
    fail('Run `cargo build --lib` in rust/ first: ${dylib.path} is missing');
  }
  await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));

  final dir = Directory('${Directory.systemTemp.path}/rma-en-ui');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  await dir.create(recursive: true);
  final dbFile = '${dir.path}/english.sqlite';
  await File(dbFile).create(recursive: true);

  final init = await Api.init(dir.path);
  expect(init['ok'], isTrue, reason: 'init_app failed: $init');
  await AppState.instance.bootstrap(dir.path);
  expect(AppState.instance.bootstrapError, isNull);

  // The backend seeds demo connections with Chinese names; they are data, not
  // UI copy, so remove them and keep the fixture ASCII-only. A Chinese string
  // in the tree then always means untranslated UI copy.
  for (final connection in await Api.instance.connections()) {
    await Api.instance.deleteConnection(connection['id'].toString());
  }

  final created = await Api.instance.createConnection({
    'name': 'English Demo',
    'driver': 'sqlite',
    'database': dbFile,
    'color': '#0f80cc',
  });
  final id = (created['connection'] as Map)['id'].toString();
  await AppState.instance.connect(id);
  await Api.instance.query(
      'CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER);');
  await Api.instance.query(
      "INSERT INTO people (name, age) VALUES ('Ada', 36), ('Bob', 41);");
  await AppState.instance.refreshDatabases();
  AppState.instance.notify();
}

void main() {
  setUpAll(_boot);
  tearDownAll(() async {
    await Api.instance.disconnect();
    final dir = Directory('${Directory.systemTemp.path}/rma-en-ui');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    I18n.setLang(AppLang.zh);
  });

  testWidgets('English mode renders no Chinese copy anywhere', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // The language switch lives in the settings dialog now; drive the real
    // transition path (AppState.setLanguage -> I18n listener -> rebuild).
    Navigation.instance.go(AppRoute.connections);
    await tester.pumpWidget(_app());
    await _settle(tester);
    expect(I18n.current, AppLang.zh);

    await tester.tap(find.byKey(const ValueKey('topbar-settings')));
    await _settle(tester, rounds: 3);
    expect(find.byKey(const ValueKey('settings-lang-en')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-lang-en')));
    await _settle(tester, rounds: 3);
    expect(I18n.current, AppLang.en);
    await tester.tap(find.byKey(const ValueKey('dialog-close')));
    // pumpAndSettle (not _settle) so the route's exit animation actually
    // finishes before the finder is asked whether the dialog is gone.
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-lang-en')), findsNothing);

    // The settings dialog is a separate route, so the page walk below never
    // sees it. Reopen it now that English is already the active language: the
    // shared modal header (title and close button) is built once when the
    // dialog opens and does not re-translate in place, so only a freshly
    // opened dialog reflects the current language.
    await tester.tap(find.byKey(const ValueKey('topbar-settings')));
    await _settle(tester, rounds: 3);
    expect(find.text('Settings'), findsOneWidget);
    _expectNoChinese(tester, 'settings dialog');
    await tester.tap(find.byKey(const ValueKey('dialog-close')));
    await tester.pumpAndSettle();

    final routes = <String, AppRoute>{
      'connections': AppRoute.connections,
      'database': AppRoute.database('main'),
      'table': AppRoute.tableRoute('main', 'people'),
      'builder': AppRoute.builder,
      'sql': AppRoute.sql,
      'server': AppRoute.server,
      'backups': AppRoute.backups,
      'sync': AppRoute.sync,
      'history': AppRoute.history,
    };
    for (final entry in routes.entries) {
      Navigation.instance.go(entry.value);
      await tester.pump();
      await _settle(tester, rounds: 4);
      _expectNoChinese(tester, entry.key);
    }

    // Dialogs are separate routes, so the page walk above never sees them.
    // Open the connection editor and the create-table dialog, then check them.
    Navigation.instance.go(AppRoute.connections);
    await tester.pump();
    await _settle(tester, rounds: 3);
    await tester.tap(find.text('New connection'));
    await _settle(tester, rounds: 3);
    _expectNoChinese(tester, 'connection editor');
    await tester.tap(find.byKey(const ValueKey('dialog-close')));
    await _settle(tester, rounds: 2);

    Navigation.instance.go(AppRoute.tableRoute('main', 'people'));
    await tester.pump();
    await _settle(tester, rounds: 4);
    await tester.tap(find.text('Structure'));
    await _settle(tester, rounds: 3);
    _expectNoChinese(tester, 'table structure');

    // The create-table designer (columns, indexes, foreign keys, options).
    Navigation.instance.go(AppRoute.database('main'));
    await tester.pump();
    await _settle(tester, rounds: 3);
    await tester.tap(find.text('New table'));
    await _settle(tester, rounds: 3);
    _expectNoChinese(tester, 'create table dialog');
    await tester.tap(find.byKey(const ValueKey('dialog-close')));
    await _settle(tester, rounds: 2);

    // The data import wizard is the largest dialog in the app.
    Navigation.instance.go(AppRoute.tableRoute('main', 'people'));
    await tester.pump();
    await _settle(tester, rounds: 3);
    await tester.tap(find.text('Import'));
    await _settle(tester, rounds: 3);
    await tester.tap(find.text('Open the import wizard'));
    await _settle(tester, rounds: 4);
    _expectNoChinese(tester, 'data import wizard');
    // The wizard has its own header (not the shared modal shell), so close it
    // through its header button rather than the shared dialog-close key.
    await tester.tap(find.byTooltip('Close').last);
    await _settle(tester, rounds: 2);

    // The E-R relation designer (round 51 P2-12): empty state, add-table picker,
    // canvas toolbar/legend, suggestion help and the blocked-FK dialog must all
    // render English copy. It is not reachable through the route walk above, so
    // mount it directly with the same SQLite connection.
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: Scaffold(
          body: RelationDesigner(database: 'main', height: 520),
        ),
      ),
    );
    await _settle(tester);
    _expectNoChinese(tester, 'E-R designer (empty state)');
    await tester.tap(find.byKey(const ValueKey('er-empty-add-table')));
    await _settle(tester, rounds: 4);
    _expectNoChinese(tester, 'E-R add-table picker');
    await tester.tap(find.byKey(const ValueKey('er-picker-people')));
    await _settle(tester, rounds: 2);
    await tester.tap(find.byKey(const ValueKey('er-picker-join')));
    await _settle(tester);
    _expectNoChinese(tester, 'E-R designer canvas');
    // P2-8：这个 SQLite 库只有 people、没有任何外键，自动带入必须给出英文说明
    // （原来什么也不发生、也没有提示）。
    expect(
      find.byKey(const ValueKey('er-auto-include-notice')),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            (widget.data ?? '').contains('no foreign keys yet'),
      ),
      findsOneWidget,
    );

    // P3：工具栏的术语说明入口。全树扫描覆盖 tooltip，这里再断言译名，并打开
    // 对话框扫描正文（词条是 pickText 双语，不能漏一条中文）。
    final glossaryTooltip = tester.widget<Tooltip>(
      find
          .descendant(
            of: find.byKey(const ValueKey('er-glossary')),
            matching: find.byType(Tooltip),
          )
          .first,
    );
    expect(glossaryTooltip.message, 'Glossary');
    await tester.tap(find.byKey(const ValueKey('er-glossary')));
    await _settle(tester, rounds: 4);
    expect(find.text('Glossary (plain language)'), findsOneWidget);
    _expectNoChinese(tester, 'E-R glossary');
    await tester.tap(find.byKey(const ValueKey('glossary-close')));
    await _settle(tester, rounds: 3);
    await tester.tap(find.byKey(const ValueKey('er-suggestion-help')));
    await _settle(tester, rounds: 3);
    _expectNoChinese(tester, 'E-R suggestion help');
    await tester.tap(find.byKey(const ValueKey('dialog-close')));
    await _settle(tester, rounds: 3);

    // The local FK pre-check dialog ("Back to worksheets and fields").
    var backCalled = false;
    final blocked = showForeignKeyBlockedDialog(
      tester.element(find.byType(RelationDesigner)),
      message: 'Blocked by the local pre-check',
      onRequestEditFields: () => backCalled = true,
    );
    await _settle(tester, rounds: 3);
    expect(find.text('Cannot create the foreign key'), findsOneWidget);
    _expectNoChinese(tester, 'blocked foreign-key dialog');
    expect(find.text('Back to worksheets and fields'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('er-back-to-fields')));
    await _settle(tester, rounds: 3);
    await blocked;
    expect(backCalled, isTrue);
  });
}
