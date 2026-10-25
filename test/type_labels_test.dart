// 类型标签的中文表达回归（第 51 轮 P2-1）。
//
// 覆盖三件事：
//  * VARCHAR / CHAR 菜单不能把 SQL token 拼两次（「文本（VARCHAR(255)）（VARCHAR(255)）」）；
//  * UNSIGNED / DOUBLE PRECISION / BLOB / citext 等常见写法必须有中文标签；
//  * 英文模式保持原始 SQL 类型，不做翻译。

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/db_options.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';
import 'package:rust_myadmin_desktop/src/type_labels.dart';

void main() {
  setUp(() => I18n.setLang(AppLang.zh));
  tearDown(() => I18n.setLang(AppLang.zh));

  test('VARCHAR / CHAR：SQL token 只出现一次（双重括号回归）', () {
    for (final sqlType in <String>['VARCHAR(255)', 'VARCHAR(64)', 'CHAR(36)']) {
      final label = columnTypeLabel(sqlType);
      final menu = columnTypeMenuLabel(sqlType);
      final tooltip = columnTypeTooltip(sqlType);
      final summary = columnTypeSummary(sqlType);
      expect(label, '文本（$sqlType）');
      expect(menu, label, reason: '菜单与关闭态必须一致，不再追加一次 token');
      expect(_count(menu, sqlType), 1, reason: menu);
      expect(_count(tooltip, sqlType), 1, reason: tooltip);
      expect(_count(summary, sqlType), 1, reason: summary);
      expect(menu.contains('）（'), isFalse, reason: menu);
    }
  });

  test('UNSIGNED / 多词 / BLOB / citext 有中文标签', () {
    expect(columnTypeLabel('INT UNSIGNED'), '无符号整数');
    expect(columnTypeLabel('INT(10) UNSIGNED'), '无符号整数');
    expect(columnTypeLabel('MEDIUMINT UNSIGNED'), '无符号整数');
    expect(columnTypeLabel('BIGINT UNSIGNED'), '无符号大整数');
    expect(columnTypeLabel('INT'), '整数');
    expect(columnTypeLabel('BIGINT'), '大整数');
    expect(columnTypeMenuLabel('BIGINT UNSIGNED'), '无符号大整数（BIGINT UNSIGNED）');
    // PostgreSQL 快速建表向导的默认浮点类型。
    expect(columnTypeLabel('DOUBLE PRECISION'), '浮点');
    expect(columnTypeMenuLabel('DOUBLE PRECISION'), '浮点（DOUBLE PRECISION）');
    expect(columnTypeLabel('MEDIUMBLOB'), '二进制');
    expect(columnTypeLabel('LONGBLOB'), '二进制');
    expect(columnTypeLabel('TINYBLOB'), '二进制');
    expect(columnTypeLabel('citext'), '不区分大小写的文本');
    expect(columnTypeLabel('TIMESTAMP WITH TIME ZONE'), '日期时间');
    expect(columnTypeLabel('CHARACTER VARYING(255)'), '文本（CHARACTER VARYING(255)）');
  });

  test('未知类型保持原文，不出现「FOO（FOO）」', () {
    expect(columnTypeLabel('weird_type'), 'weird_type');
    expect(columnTypeMenuLabel('weird_type'), 'weird_type');
    expect(columnTypeTooltip('weird_type'), 'weird_type');
    expect(columnTypeSummary('weird_type'), 'weird_type');
  });

  test('三种驱动的全部下拉类型：中文名 != SQL 类型，token 只出现一次', () {
    for (final driver in <String>['mysql', 'postgres', 'sqlite']) {
      for (final sqlType in typeOptionsFor(driver)) {
        final label = columnTypeLabel(sqlType);
        expect(label, isNot(sqlType), reason: '$driver：$sqlType 仍原样英文');
        final menu = columnTypeMenuLabel(sqlType);
        expect(
          _count(menu, sqlType),
          1,
          reason: '$driver：$sqlType 的菜单标签「$menu」token 次数不对',
        );
        expect(menu.contains('）（'), isFalse, reason: menu);
      }
    }
  });

  test('英文模式保持原始 SQL 类型', () {
    I18n.setLang(AppLang.en);
    for (final sqlType in <String>[
      'VARCHAR(255)',
      'INT UNSIGNED',
      'DOUBLE PRECISION',
      'citext',
      'MEDIUMBLOB',
    ]) {
      expect(columnTypeLabel(sqlType), sqlType);
      expect(columnTypeMenuLabel(sqlType), sqlType);
      expect(columnTypeSummary(sqlType), sqlType);
      expect(columnTypeTooltip(sqlType), startsWith(sqlType));
    }
    expect(columnTypeTooltip('VARCHAR(255)'), contains('text with a length limit'));
    expect(columnTypeTooltip('DOUBLE PRECISION'), contains('approximate'));
  });
}

int _count(String haystack, String needle) {
  var count = 0;
  var index = haystack.indexOf(needle);
  while (index >= 0) {
    count++;
    index = haystack.indexOf(needle, index + needle.length);
  }
  return count;
}
