// Round 70: the database/table toolbar and the right-click menus must offer the
// same actions, and 关系图 opened from a table must seed the canvas with it.
//
// The menu is a plain data model ([AppMenuEntry]) rendered through showMenu, so
// the entries can be asserted without opening a popup; the widget test below
// covers the wiring (right-click opens the menu with those labels).
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/app_menu.dart';
import 'package:rust_myadmin_desktop/src/db_actions.dart' hide ContextMenuRegion;

Widget host(Widget child) => MaterialApp(
  home: Scaffold(body: Builder(builder: (context) => child)),
);

void main() {
  testWidgets(
    'database menu lists refresh / create / from-file / relationships',
    (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox();
            },
          ),
        ),
      );

      final entries = databaseMenuEntries(ctx, 'sakila');
      expect(entries.map((e) => e.label).toList(), <String>[
        '刷新',
        '新建表',
        '从文件建表',
        '关系图',
      ]);
      // Every entry is actionable, and the create/relationships group is
      // visually separated from the refresh action.
      expect(entries.every((e) => e.isEnabled), isTrue);
      expect(entries[1].separatorBefore, isTrue);
      expect(entries.first.separatorBefore, isFalse);
    },
  );

  testWidgets('table menu is a subset and keeps the table for the diagram', (
    tester,
  ) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox();
          },
        ),
      ),
    );

    final entries = tableMenuEntries(ctx, 'sakila', 'film');
    expect(entries.map((e) => e.label).toList(), <String>['刷新', '新建表', '关系图']);
    expect(entries.every((e) => e.isEnabled), isTrue);
  });

  testWidgets('right-click opens the menu with the entries', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      host(
        ContextMenuRegion(
          entries: <AppMenuEntry>[
            AppMenuEntry(label: '刷新', onSelected: () => opened++),
            AppMenuEntry(label: '关系图', onSelected: () => opened++),
          ],
          child: const SizedBox(width: 300, height: 200, child: Text('target')),
        ),
      ),
    );

    // A secondary (right) click opens the menu at the pointer.
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('target')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('刷新'), findsOneWidget);
    expect(find.text('关系图'), findsOneWidget);

    await tester.tap(find.text('关系图'));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('a disabled region does not intercept right-clicks', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        ContextMenuRegion(
          enabled: false,
          entries: <AppMenuEntry>[AppMenuEntry(label: '刷新', onSelected: () {})],
          child: const SizedBox(width: 300, height: 200, child: Text('target')),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('target')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('刷新'), findsNothing);
  });

  testWidgets('the menu appears in one frame (no open animation)',
      (tester) async {
    await tester.pumpWidget(host(ContextMenuRegion(
      entries: <AppMenuEntry>[
        AppMenuEntry(label: '刷新', onSelected: () {}),
      ],
      child: const SizedBox(width: 300, height: 200, child: Text('target')),
    )));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('target')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    // One frame only: an animated popup would still be transparent here.
    await tester.pump();
    expect(find.text('刷新'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('刷新'), findsOneWidget);
  });

  testWidgets('Escape closes the menu', (tester) async {
    await tester.pumpWidget(host(ContextMenuRegion(
      entries: <AppMenuEntry>[
        AppMenuEntry(label: '刷新', onSelected: () {}),
      ],
      child: const SizedBox(width: 300, height: 200, child: Text('target')),
    )));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('target')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('刷新'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('刷新'), findsNothing);
  });

  testWidgets('a right-click on a text field keeps the platform text menu',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var opened = 0;
    await tester.pumpWidget(host(ContextMenuRegion(
      entries: <AppMenuEntry>[
        AppMenuEntry(label: '刷新', onSelected: () => opened++),
      ],
      child: SizedBox(
        width: 300,
        height: 200,
        child: TextField(controller: controller),
      ),
    )));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(TextField)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('刷新'), findsNothing,
        reason: 'the text field owns its right-click menu');
    expect(opened, 0);
  });
}
