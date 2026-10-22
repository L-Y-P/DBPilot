//! Regression tests for the desktop literal translator (N-10).
//!
//! The English UI is produced by translating every rendered UI string; these
//! tests pin both halves of that contract: known copy flips language, and
//! unknown text (table names, driver errors, user data) must pass through
//! untouched.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';
import 'package:rust_myadmin_desktop/src/i18n_literals.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(body: child),
    );

void main() {
  tearDown(() => I18n.setLang(AppLang.zh));

  group('trLiteral', () {
    test('zh returns the original text untouched', () {
      I18n.setLang(AppLang.zh);
      expect(trLiteral('删除模式'), '删除模式');
      expect(trLiteral('已删除 3 行'), '已删除 3 行');
    });

    test('translates buttons from the web dictionary', () {
      I18n.setLang(AppLang.en);
      expect(trLiteral('保存'), 'Save');
      expect(trLiteral('取消'), 'Cancel');
      expect(trLiteral('上一页'), 'Previous');
    });

    test('translates desktop-only copy', () {
      I18n.setLang(AppLang.en);
      expect(trLiteral('删除模式'), 'Delete schema');
      expect(trLiteral('已中断查询连接，下一次查询会自动重连'),
          contains('reconnects automatically'));
      expect(trLiteral('尚未连接数据库：备份需要先打开一个连接。'),
          contains('open a connection before using backups'));
    });

    test('translates interpolated prompts by pattern', () {
      I18n.setLang(AppLang.en);
      expect(trLiteral('已删除 3 行'), 'Deleted 3 row(s)');
      expect(trLiteral('已保存到 /tmp/a.sql'), 'Saved to /tmp/a.sql');
      expect(trLiteral('已导出到 /tmp/export.csv'), 'Exported to /tmp/export.csv');
      expect(trLiteral('同步完成 — 12 SQL, 1 failed'),
          'Sync finished — 12 SQL, 1 failed');
      expect(trLiteral('2 张表'), '2 tables');
      expect(trLiteral('列 (3/4)'), 'Columns (3/4)');
      expect(trLiteral('删除失败：Unknown column x'),
          'Delete failed: Unknown column x');
    });

    test('translates confirmation prompts', () {
      I18n.setLang(AppLang.en);
      expect(trLiteral('确定删除模式 app 吗？该模式下的所有表、视图和函数都会被删除，且无法恢复。'),
          contains('Delete schema app?'));
      expect(trLiteral('确定删除选中的 4 行吗？'),
          'Delete the 4 selected row(s)?');
    });

    test('translates the common backend error sentences', () {
      I18n.setLang(AppLang.en);
      expect(trLiteral('没有找到匹配的数据行'), 'No matching row was found');
      expect(trLiteral('SQL 语句不能为空'), 'The SQL statement is empty');
      expect(trLiteral('无法打开数据库 mysql：没有访问该数据库的权限'),
          contains('Cannot open database mysql'));
      expect(trLiteral('表不存在：可能已被删除，或当前库选择错误。'),
          contains('The table does not exist'));
    });

    test('never mangles identifiers, SQL or backend errors', () {
      I18n.setLang(AppLang.en);
      const passthrough = [
        'my_database',
        'SELECT * FROM t',
        "Unknown column 'nope' in 'field list' (1054)",
        'error communicating with database: EOF',
        'Pattern not translated 中文 identifier',
      ];
      for (final text in passthrough) {
        expect(trLiteral(text), text, reason: 'must pass through: $text');
      }
      expect(trLiteral(''), '');
    });

    test('pickText switches only interpolated prompts', () {
      I18n.setLang(AppLang.zh);
      expect(pickText('中文', 'English'), '中文');
      I18n.setLang(AppLang.en);
      expect(pickText('中文', 'English'), 'English');
    });
  });

  group('widgets translate copy in EN mode', () {
    testWidgets('button labels and tooltips switch language', (tester) async {
      I18n.setLang(AppLang.en);
      await tester.pumpWidget(host(Column(children: [
        Btn('删除模式', onPressed: () {}),
        IconBtn(Icons.close, tooltip: '关闭', onPressed: () {}),
      ])));
      await tester.pumpAndSettle();
      expect(find.text('Delete schema'), findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget);
    });

    testWidgets('alerts and toasts switch language', (tester) async {
      I18n.setLang(AppLang.en);
      final notice = Notice();
      addTearDown(notice.dispose);
      await tester.pumpWidget(host(Column(children: [
        AlertBox('尚未连接数据库：备份需要先打开一个连接。',
            tone: AlertTone.info),
        NoticeBanner(notice),
      ])));
      expect(
          find.textContaining('open a connection before using backups'),
          findsOneWidget);

      notice.show('表已删除');
      await tester.pump();
      expect(find.text('Table dropped'), findsOneWidget);
      // Let the 3s toast timers finish so the test leaves no pending timer.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('zh mode keeps the original Chinese copy', (tester) async {
      I18n.setLang(AppLang.zh);
      await tester.pumpWidget(host(Column(children: [
        Btn('删除模式', onPressed: () {}),
        AlertBox('尚未连接数据库：备份需要先打开一个连接。'),
      ])));
      await tester.pumpAndSettle();
      expect(find.text('删除模式'), findsOneWidget);
      expect(find.text('尚未连接数据库：备份需要先打开一个连接。'), findsOneWidget);
    });
  });
}
