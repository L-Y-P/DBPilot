//! 表设计器「撤销未应用的修改」纯逻辑测试（第 55 轮）。
//!
//! 只覆盖 [tableDesignBodyEmpty] / [tableDesignHasPendingChanges] /
//! [currentTableComment]：按钮的可用态与「是否值得确认撤销」都由它们决定。
//! 完整 UI（按钮禁用态、确认框、重置后的字段/预览清空）由 GUI 抽测覆盖。

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/views/table_view.dart';

/// 设计器「没有任何修改」时 _buildAlter 返回的形状：列表字段都在但为空，
/// 没有 rename_to / comment 等 Option 字段。
Map<String, dynamic> baselineBody() => <String, dynamic>{
  'add_columns': <dynamic>[],
  'modify_columns': <dynamic>[],
  'drop_columns': <dynamic>[],
  'rename_columns': <dynamic>[],
  'add_indexes': <dynamic>[],
  'drop_indexes': <dynamic>[],
  'add_foreign_keys': <dynamic>[],
  'drop_foreign_keys': <dynamic>[],
};

void main() {
  group('tableDesignBodyEmpty：没有修改', () {
    test('空 Map / 设计器基线载荷都算「没有修改」', () {
      expect(tableDesignBodyEmpty(<String, dynamic>{}), isTrue);
      expect(tableDesignHasPendingChanges(<String, dynamic>{}), isFalse);
      expect(tableDesignBodyEmpty(baselineBody()), isTrue);
      expect(tableDesignHasPendingChanges(baselineBody()), isFalse);
    });

    test('null 值、空串选项、未知字段都不算修改', () {
      expect(
        tableDesignBodyEmpty(<String, dynamic>{
          'add_columns': null,
          'drop_indexes': null,
          'rename_to': null,
          'comment': null,
          'engine': null,
          'auto_increment': null,
        }),
        isTrue,
      );
      expect(
        tableDesignBodyEmpty(<String, dynamic>{
          'rename_to': '',
          'engine': '   ',
          'row_format': '',
          'charset': '',
          'collation': '',
        }),
        isTrue,
      );
      // 预览时附加的内部参数不能把按钮点亮。
      expect(tableDesignBodyEmpty(<String, dynamic>{'dry_run': true}), isTrue);
    });

    test('表本来就有注释、用户没改：comment 不进入载荷 → 不算修改', () {
      // 与 _buildAlter 相同的规则：只有和结构里的当前值不同才写 comment。
      final current = currentTableComment(<String, dynamic>{
        'info': <String, dynamic>{'TABLE_COMMENT': '已有注释'},
      });
      final body = <String, dynamic>{
        ...baselineBody(),
        if ('已有注释'.trim() != current) 'comment': '已有注释',
      };
      expect(tableDesignBodyEmpty(body), isTrue);
    });
  });

  group('tableDesignBodyEmpty：各类未应用修改', () {
    test('字段：新增 / 修改 / 删除 / 重命名', () {
      final cases = <String, dynamic>{
        'add_columns': <dynamic>[
          <String, dynamic>{'name': 'tmp', 'type': 'INT'},
        ],
        'modify_columns': <dynamic>[
          <String, dynamic>{'name': 'qty', 'type': 'BIGINT'},
        ],
        'drop_columns': <dynamic>['old_column'],
        'rename_columns': <dynamic>[
          <String, dynamic>{'from': 'a', 'to': 'b'},
        ],
      };
      for (final entry in cases.entries) {
        expect(
          tableDesignBodyEmpty(<String, dynamic>{entry.key: entry.value}),
          isFalse,
          reason: entry.key,
        );
        expect(
          tableDesignHasPendingChanges(<String, dynamic>{
            entry.key: entry.value,
          }),
          isTrue,
          reason: entry.key,
        );
      }
    });

    test('索引：新增 / 删除', () {
      expect(
        tableDesignBodyEmpty(<String, dynamic>{
          'add_indexes': <dynamic>[
            <String, dynamic>{
              'name': 'idx_name',
              'unique': false,
              'columns': <String>['name'],
            },
          ],
        }),
        isFalse,
      );
      expect(
        tableDesignBodyEmpty(<String, dynamic>{
          'drop_indexes': <dynamic>['idx_name'],
        }),
        isFalse,
      );
    });

    test('外键：新增 / 删除', () {
      expect(
        tableDesignBodyEmpty(<String, dynamic>{
          'add_foreign_keys': <dynamic>[
            <String, dynamic>{
              'columns': <String>['pid'],
              'ref_table': 'parent',
              'ref_columns': <String>['id'],
            },
          ],
        }),
        isFalse,
      );
      expect(
        tableDesignBodyEmpty(<String, dynamic>{
          'drop_foreign_keys': <dynamic>['fk_child_parent'],
        }),
        isFalse,
      );
    });

    test('表名 / 注释 / 主键', () {
      expect(
        tableDesignBodyEmpty(<String, dynamic>{'rename_to': 'orders_new'}),
        isFalse,
      );
      expect(
        tableDesignBodyEmpty(<String, dynamic>{'comment': '订单表'}),
        isFalse,
      );
      // Rust 的 Option<String>：null=不改，空串=清空注释（确实是修改）。
      expect(tableDesignBodyEmpty(<String, dynamic>{'comment': ''}), isFalse);
      expect(
        tableDesignBodyEmpty(<String, dynamic>{
          'set_primary_key': <String>['id'],
        }),
        isFalse,
      );
      // 与 Rust 一致：Some([]) 也是「有改动」。
      expect(
        tableDesignBodyEmpty(<String, dynamic>{'set_primary_key': <String>[]}),
        isFalse,
      );
    });

    test('表选项：engine / row_format / auto_increment / charset / collation', () {
      expect(
        tableDesignBodyEmpty(<String, dynamic>{'engine': 'InnoDB'}),
        isFalse,
      );
      expect(
        tableDesignBodyEmpty(<String, dynamic>{'row_format': 'DYNAMIC'}),
        isFalse,
      );
      expect(
        tableDesignBodyEmpty(<String, dynamic>{'auto_increment': 100}),
        isFalse,
      );
      expect(
        tableDesignBodyEmpty(<String, dynamic>{'charset': 'utf8mb4'}),
        isFalse,
      );
      expect(
        tableDesignBodyEmpty(<String, dynamic>{
          'collation': 'utf8mb4_general_ci',
        }),
        isFalse,
      );
    });

    test('列表字段给了非 List 的异常值时按「有修改」处理（不静默丢）', () {
      expect(
        tableDesignBodyEmpty(<String, dynamic>{'add_columns': 'oops'}),
        isFalse,
        reason: '异常载荷也要让用户有机会撤销，而不是当成没有修改',
      );
      expect(
        tableDesignBodyEmpty(<String, dynamic>{'drop_indexes': 1}),
        isFalse,
      );
    });
  });

  group('撤销后的 dirty 判断（纯逻辑）', () {
    test('有未应用修改 → dirty；按 _structure 重建基线后 → 不 dirty', () {
      final pending = <String, dynamic>{
        ...baselineBody(),
        'add_columns': <dynamic>[
          <String, dynamic>{'name': 'tmp', 'type': 'INT'},
        ],
        'drop_indexes': <dynamic>['idx_a'],
        'rename_to': 'renamed_table',
        'comment': '改过的注释',
      };
      expect(tableDesignHasPendingChanges(pending), isTrue);

      // 撤销 = _seedDesigner() 重建列 + 清空集合/控制器 + 清空 SQL/结果/错误，
      // 也就是回到基线载荷（这里用 baselineBody 表示该结果）。
      expect(tableDesignHasPendingChanges(baselineBody()), isFalse);
      expect(tableDesignBodyEmpty(baselineBody()), isTrue);
    });
  });

  group('currentTableComment', () {
    test('读取 info.TABLE_COMMENT，缺失 / 非 Map 时为空串', () {
      expect(
        currentTableComment(<String, dynamic>{
          'info': <String, dynamic>{'TABLE_COMMENT': ' 订单表 '},
        }),
        '订单表',
      );
      expect(
        currentTableComment(<String, dynamic>{'info': <String, dynamic>{}}),
        '',
      );
      expect(currentTableComment(<String, dynamic>{'info': 'not-a-map'}), '');
      expect(currentTableComment(<String, dynamic>{}), '');
    });
  });
}
