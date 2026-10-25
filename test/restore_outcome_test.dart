// 第 58 轮：备份还原结果提示（describeRestoreOutcome）的纯逻辑测试。
//
// 覆盖新后端的 atomic / rolled_back / skipped、旧后端字段缺失的降级，以及
// MySQL 非原子时的额外说明；中英文两套文案都断言。

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/views/backups_view.dart';

void main() {
  group('describeRestoreOutcome：成功', () {
    test('atomic 成功 → 整段事务提示', () {
      final copy = describeRestoreOutcome(<String, dynamic>{
        'ok': true,
        'statements': 12,
        'failed': 0,
        'skipped': 0,
        'atomic': true,
      });
      expect(copy.isError, isFalse);
      expect(copy.zh, contains('还原成功（整段事务'));
      expect(copy.zh, contains('12 条语句'));
      expect(copy.en, contains('one transaction'));
    });

    test('旧后端（无 atomic）→ 原提示；MySQL 附加隐式提交说明', () {
      final old = describeRestoreOutcome(<String, dynamic>{
        'ok': true,
        'statements': 5,
        'failed': 0,
      });
      expect(old.isError, isFalse);
      expect(old.zh, '备份已还原（5 条语句）');
      expect(old.en, 'Backup restored (5 statement(s))');
      expect(old.zh, isNot(contains('MySQL')));

      final mysql = describeRestoreOutcome(<String, dynamic>{
        'ok': true,
        'statements': 5,
        'failed': 0,
        'atomic': false,
      }, mysql: true);
      expect(mysql.isError, isFalse);
      expect(mysql.zh, contains('备份已还原（5 条语句）'));
      expect(mysql.zh, contains('MySQL 的 DDL 会隐式提交'));
      expect(mysql.en, contains('MySQL DDL commits implicitly'));
    });

    test('空结果降级为 0 条语句', () {
      final copy = describeRestoreOutcome(<String, dynamic>{});
      expect(copy.isError, isFalse);
      expect(copy.zh, '备份已还原（0 条语句）');
    });
  });

  group('describeRestoreOutcome：失败', () {
    test('rolled_back → 已整体回滚、未写入任何数据、带 N/X/S', () {
      final copy = describeRestoreOutcome(<String, dynamic>{
        'ok': false,
        'statements': 10,
        'failed': 1,
        'executed': 4,
        'skipped': 6,
        'atomic': true,
        'rolled_back': true,
      });
      expect(copy.isError, isTrue);
      expect(copy.zh, contains('还原失败，已整体回滚，未写入任何数据'));
      expect(copy.zh, contains('共 10 条语句，已执行 4，跳过 6'));
      expect(copy.en, contains('rolled back as a whole'));
      expect(copy.en, contains('no data was written'));
    });

    test('新后端字段：total_statements / statements / skipped_statements', () {
      // Rust 实际返回：statements=已执行条数，total_statements=总数，
      // skipped_statements=回滚后没执行的条数。
      final copy = describeRestoreOutcome(<String, dynamic>{
        'ok': false,
        'statements': 5,
        'total_statements': 8,
        'failed': 1,
        'skipped_statements': 3,
        'atomic': true,
        'rolled_back': true,
      });
      expect(copy.zh, contains('共 8 条语句，已执行 5，跳过 3'));
    });

    test('新后端没给 skipped_statements → 用 total-statements 推断', () {
      final copy = describeRestoreOutcome(<String, dynamic>{
        'ok': false,
        'statements': 4,
        'total_statements': 9,
        'failed': 1,
        'rolled_back': true,
      });
      expect(copy.zh, contains('共 9 条语句，已执行 4，跳过 5'));
    });

    test('非原子部分失败（旧后端 / MySQL）→ 原提示 + MySQL 说明', () {
      final old = describeRestoreOutcome(<String, dynamic>{
        'ok': false,
        'statements': 5,
        'failed': 2,
      });
      expect(old.isError, isTrue);
      expect(old.zh, '备份还原完成，但 2 / 5 条语句失败');
      expect(old.zh, isNot(contains('MySQL')));

      final mysql = describeRestoreOutcome(<String, dynamic>{
        'ok': false,
        'statements': 5,
        'failed': 2,
        'atomic': false,
      }, mysql: true);
      expect(mysql.zh, contains('备份还原完成，但 2 / 5 条语句失败'));
      expect(mysql.zh, contains('MySQL 的 DDL 会隐式提交'));
    });

    test('atomic 失败但未标记 rolled_back → 事务未提交提示', () {
      final copy = describeRestoreOutcome(<String, dynamic>{
        'ok': false,
        'statements': 6,
        'failed': 1,
        'skipped': 5,
        'atomic': true,
      });
      expect(copy.isError, isTrue);
      expect(copy.zh, contains('整段事务未提交'));
      expect(copy.zh, contains('共 6 条语句，跳过 5'));
    });
  });
}
