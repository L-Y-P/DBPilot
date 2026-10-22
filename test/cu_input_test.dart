// Computer-Use 文本注入桥的回归测试。
//
// 验证：只有启用后才注入；焦点切换后自动指向新的 EditableText；replace 与
// 光标插入两种语义正确。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/cu_input.dart';

void main() {
  testWidgets('injects into the focused EditableText controller', (tester) async {
    final first = TextEditingController();
    final second = TextEditingController();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          TextField(key: const ValueKey('first'), controller: first),
          TextField(key: const ValueKey('second'), controller: second),
        ]),
      ),
    ));
    final cu = CuTextInput.instance;
    addTearDown(cu.debugDisable);
    cu.debugEnable();

    // 没有焦点时不会乱写。
    expect(cu.inject('ignored'), isFalse);

    await tester.tap(find.byKey(const ValueKey('first')));
    await tester.pump();
    expect(cu.inject('hello'), isTrue);
    expect(first.text, 'hello');

    // 切到第二个输入框后，注入应落到第二个。
    await tester.tap(find.byKey(const ValueKey('second')));
    await tester.pump();
    expect(cu.inject('world', replace: true), isTrue);
    expect(second.text, 'world');
    expect(first.text, 'hello');
  });

  testWidgets('keeps injecting into the last focused field after focus leaves',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TextField(controller: controller)),
    ));
    final cu = CuTextInput.instance;
    addTearDown(cu.debugDisable);
    cu.debugEnable();
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(cu.inject('first'), isTrue);
    expect(controller.text, 'first');
    // 失焦（例如点了「执行」按钮）后仍应落到最近聚焦的输入框。
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(cu.inject(' again'), isTrue);
    expect(controller.text, 'first again');
  });

  testWidgets('stays inert until enabled', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TextField(controller: controller)),
    ));
    final cu = CuTextInput.instance;
    addTearDown(cu.debugDisable);
    cu.debugDisable();
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(cu.inject('nope'), isFalse);
    expect(controller.text, '');
  });
}