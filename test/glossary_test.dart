// 术语说明（第 53 轮 P3）：数据完整性与弹窗行为回归。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/glossary.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';

void main() {
  tearDown(() => I18n.setLang(AppLang.zh));

  test('术语表覆盖界面行话，中英文都有解释', () {
    I18n.setLang(AppLang.zh);
    final entries = glossaryEntries();
    expect(entries.length, greaterThanOrEqualTo(8));
    final terms = entries.map((entry) => entry.term).toSet();
    expect(
      terms,
      containsAll(<String>[
        '主键',
        '外键',
        '唯一',
        '约束',
        '索引',
        '中间表',
        '多对多',
        '事务',
        '自增',
        '空值',
      ]),
    );
    for (final entry in entries) {
      expect(entry.sqlTerm.trim(), isNotEmpty, reason: entry.term);
      expect(entry.definition.trim(), isNotEmpty, reason: entry.term);
      expect(entry.detail.trim(), isNotEmpty, reason: entry.term);
      expect(entry.label(), entry.term);
    }

    I18n.setLang(AppLang.en);
    final english = glossaryEntries();
    for (final entry in english) {
      expect(entry.label(), entry.sqlTerm, reason: '英文界面术语名应为 SQL token');
      expect(
        RegExp(r'[\u4e00-\u9fff]').hasMatch(entry.definition),
        isFalse,
        reason: '英文模式定义仍含中文：${entry.definition}',
      );
      expect(
        RegExp(r'[\u4e00-\u9fff]').hasMatch(entry.detail),
        isFalse,
        reason: '英文模式补充说明仍含中文：${entry.detail}',
      );
    }
  });

  testWidgets('showGlossaryDialog 列出术语，highlight 展开对应条目', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showGlossaryDialog(context, highlight: '外键'),
              child: const Text('open-glossary'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-glossary'));
    await tester.pumpAndSettle();

    expect(find.text('术语说明（说人话版）'), findsOneWidget);
    expect(find.text('PRIMARY KEY'), findsOneWidget);
    expect(find.text('FOREIGN KEY'), findsOneWidget);
    // highlight 的外键条目展开补充说明。
    expect(find.textContaining('两边列的类型要完全一致'), findsOneWidget);
    // 未高亮的条目只显示一句话解释，不展开 detail。
    expect(find.textContaining('不会留下半套数据'), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('glossary-close')));
    await tester.pumpAndSettle();
    expect(find.text('术语说明（说人话版）'), findsNothing);
  });
}
