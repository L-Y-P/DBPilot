// P11 (round 30): the SQL editor and the connection-test outcome must expose
// stable accessibility values so UI automation can assert what they hold.
//
// The macOS AX tree did not surface the editor's text value, and the probe
// result was plain alert copy with no stable handle. Both now publish a single
// labelled semantics node; these tests drive the same nodes through Flutter's
// semantics tree. `_testResult` is private to the connections view, so the
// AlertBox live-region path it uses is exercised directly instead of reaching
// into private state.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  testWidgets('SqlEditor exposes its current SQL as a semantics value',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final controller = TextEditingController(text: 'SELECT 1;');
      addTearDown(controller.dispose);

      await tester.pumpWidget(host(SqlEditor(controller: controller)));
      await tester.pump();

      final editor = find.byKey(const ValueKey('sql-editor-semantics'));
      expect(editor, findsOneWidget);
      expect(tester.getSemantics(editor).label, contains('SQL'));
      expect(tester.getSemantics(editor).value, contains('SELECT 1;'));

      // Typing must keep the exposed value current (this is what automation
      // reads when it asserts the table page's default USE/SET prelude).
      await tester.enterText(find.byType(TextField), 'SELECT * FROM people;');
      await tester.pump();
      expect(
          tester.getSemantics(editor).value, contains('SELECT * FROM people;'));

      // Programmatic injection (the CU bridge / script import) updates it too.
      controller.text = 'SELECT 42;';
      await tester.pump();
      expect(tester.getSemantics(editor).value, contains('SELECT 42;'));
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('SqlEditor still runs on Ctrl+Enter after the semantics wrapper',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final controller = TextEditingController(text: 'SELECT 1;');
      addTearDown(controller.dispose);
      var runs = 0;

      await tester.pumpWidget(
          host(SqlEditor(controller: controller, onRun: () => runs++)));
      await tester.pump();
      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(runs, 1);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('connection-test AlertBox exposes a labelled live region',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      const message = 'Connection succeeded · PostgreSQL 16 · 7 个数据库 · 19 ms';
      final result = find.byKey(const ValueKey('conn-test-result'));

      await tester.pumpWidget(host(const AlertBox(message,
          key: ValueKey('conn-test-result'),
          tone: AlertTone.ok,
          liveRegion: true)));
      await tester.pump();

      expect(result, findsOneWidget);
      final node = tester.getSemantics(result);
      expect(node.label, contains(message));
      expect(node.getSemanticsData().flagsCollection.isLiveRegion, isTrue);

      // A failed probe keeps the same stable handle and message.
      await tester.pumpWidget(host(const AlertBox(
          'Connection failed: connection refused',
          key: ValueKey('conn-test-result'),
          tone: AlertTone.error,
          liveRegion: true)));
      await tester.pump();
      expect(tester.getSemantics(result).label,
          contains('Connection failed: connection refused'));
    } finally {
      semantics.dispose();
    }
  });
}
