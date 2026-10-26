// Renders the context menu so its visual style can be reviewed as an image.
//
// The menu itself is verified by widget tests elsewhere; this golden exists to
// pin the *look* (row height, hairline separators, macOS-style highlight) so a
// future style tweak is a visible diff rather than an accident.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/app_menu.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';

void main() {
  testWidgets('context menu look', (tester) async {
    tester.view.physicalSize = const Size(640, 420);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        backgroundColor: AppColors.bg,
        body: ContextMenuRegion(
          entries: <AppMenuEntry>[
            AppMenuEntry(label: '刷新', onSelected: () {}),
            AppMenuEntry(
              label: '新建表',
              separatorBefore: true,
              onSelected: () {},
            ),
            AppMenuEntry(label: '从文件建表', onSelected: () {}),
            AppMenuEntry(label: '关系图', onSelected: () {}),
            AppMenuEntry(
              label: '删除数据库',
              danger: true,
              separatorBefore: true,
              onSelected: () {},
            ),
            AppMenuEntry(
              label: '需要更高权限的动作',
              enabled: false,
              separatorBefore: true,
            ),
          ],
          child: const SizedBox.expand(child: Text('target')),
        ),
      ),
    ));

    final gesture = await tester.startGesture(
      const Offset(80, 60),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/context_menu.png'),
    );
  });
}