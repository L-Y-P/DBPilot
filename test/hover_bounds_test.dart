// Round 20 requirements pinned by these tests.
//
//  1. A container that used to hide content and now reveals it on hover must not
//     replace the old truncation bug with a new one: a tooltip or an open menu
//     carrying a very long value must never grow to cover the window. Flutter's
//     Tooltip only sets a *minimum* height by default, so a long JSON cell used
//     to render a bubble 592px tall on a 600px-high window.
//  2. The MySQL "databases the account cannot open" filtering (round 19) has to
//     hold for PostgreSQL too: `information_schema.schemata` lists a schema as
//     soon as the role has *any* privilege on it, including CREATE without USAGE,
//     so a schema the role cannot query was still offered in the tree.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Tooltip;
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/tooltip.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(body: Center(child: child)),
    );

Future<void> hover(WidgetTester tester, Finder target) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  await tester.pump();
  await gesture.moveTo(tester.getCenter(target));
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 300));
}

/// Size of the tooltip paragraph whose text starts with [prefix].
Size? tipSize(WidgetTester tester, String prefix) {
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    if (rich.text.toPlainText().startsWith(prefix)) {
      return tester.getSize(find.byWidget(rich));
    }
  }
  return null;
}

void main() {
  group('hover reveal stays inside the window', () {
    testWidgets('a tooltip carrying a huge value is capped on both axes',
        (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // ~1.4KB: a realistic long TEXT cell. Before the fix this rendered a
      // bubble as tall as the window.
      final json = '{"id":123,"name":"some long value"},' * 40;
      await tester.pumpWidget(host(SizedBox(
        width: 160,
        child: EllipsisText(json, tooltip: json, tooltipMaxWidth: 520),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await hover(tester, find.byType(SizedBox));
      final size = tipSize(tester, '{"id"');
      expect(size, isNotNull, reason: 'the tooltip should have opened');
      expect(size!.height, lessThanOrEqualTo(320),
          reason: 'a tall bubble covers the window it explains');
      expect(size.width, lessThanOrEqualTo(520));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the theme caps plain Tooltip usage too', (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(host(Tooltip(
        message: 'word ' * 9000,
        child: const Text('hover'),
      )));
      await hover(tester, find.text('hover'));
      final size = tipSize(tester, 'word');
      expect(size, isNotNull);
      expect(size!.height, lessThanOrEqualTo(320));
      expect(size.width, lessThanOrEqualTo(480));
    });

    testWidgets('an over-long tooltip string says that it was shortened',
        (tester) async {
      // Flutter silently clips at the height cap, which makes a cut-off value
      // look complete. Clamping the string itself keeps that honest.
      const long = kTooltipMaxChars + 500;
      final text = 'a' * long;
      final clamped = tooltipText(text);
      expect(clamped.length, lessThan(text.length));
      expect(clamped, contains('未显示'));
      // Surrogate pairs survive the cut.
      final emoji = '😀' * (kTooltipMaxChars + 10);
      expect(() => tooltipText(emoji), returnsNormally);
      // Short values pass through untouched.
      expect(tooltipText('short'), 'short');
    });

    testWidgets('an open dropdown menu stays one line per entry',
        (tester) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final long = 'a_very_long_database_and_table_name_' * 30;
      await tester.pumpWidget(host(SelectBox<String>(
        width: 220,
        value: 'a',
        items: [
          DropdownMenuItem(value: 'a', child: Text(long)),
          const DropdownMenuItem(value: 'b', child: Text('b')),
        ],
        onChanged: (_) {},
      )));
      await tester.tap(find.byType(SelectBox<String>));
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.text(long, skipOffstage: false).first);
      // A menu row growing with its label used to produce a 600px-tall entry.
      expect(rect.height, lessThan(40));
      // The open menu is a separate overlay route: the trigger's tooltip does
      // not cover it, so each entry carries its own.
      final tips = tester
          .widgetList<Tooltip>(find.byType(Tooltip, skipOffstage: false))
          .where((tooltip) => tooltip.message == long);
      expect(tips, isNotEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a long Pill cannot overflow its row', (tester) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final long = 'a_very_long_role_name_' * 20;
      await tester.pumpWidget(host(Row(children: [Pill(long)])));
      // Pill caps its own width, so the label truncates; EllipsisText decides
      // whether to attach the tooltip after a frame, so let it settle first.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Measured 5412px wide (a RenderFlex overflow) before the width cap.
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(Pill)).width, lessThanOrEqualTo(221));
      // The complete value is still reachable.
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip).first);
      expect(tooltip.message, long);
    });
  });
}
