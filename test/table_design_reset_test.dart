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

  // =====================================================================
  // 第 56 轮：逐列还原 / 表名·注释重置
  // =====================================================================

  Map<String, dynamic> designStructure() => <String, dynamic>{
    'columns': <dynamic>[
      <String, dynamic>{
        'name': 'id',
        'type_name': 'BIGINT',
        'IS_NULLABLE': 'NO',
        'COLUMN_DEFAULT': null,
        'EXTRA': 'auto_increment',
        'COLUMN_COMMENT': '主键',
      },
      <String, dynamic>{
        'name': 'name',
        'type_name': 'VARCHAR(50)',
        'IS_NULLABLE': 'YES',
        'COLUMN_DEFAULT': '无名',
        'EXTRA': '',
        'COLUMN_COMMENT': '',
      },
      <String, dynamic>{
        'name': 'score',
        'type_name': 'DECIMAL(10,2)',
        'IS_NULLABLE': 'YES',
        'COLUMN_DEFAULT': 0,
        'EXTRA': '',
        'COLUMN_COMMENT': '',
      },
    ],
  };

  group('tableDesignColumnBaseline：基线提取（第 56 轮）', () {
    test('按列名规范化六个可编辑字段', () {
      final baseline = tableDesignColumnBaseline(designStructure());
      expect(baseline.keys.toList(), <String>['id', 'name', 'score']);
      expect(baseline['id'], <String, dynamic>{
        'name': 'id',
        'type': 'BIGINT',
        'nullable': false,
        'default': '',
        'auto_increment': true,
        'comment': '主键',
      });
      expect(baseline['name']!['type'], 'VARCHAR(50)');
      expect(baseline['name']!['nullable'], isTrue);
      expect(baseline['name']!['default'], '无名');
      expect(baseline['name']!['auto_increment'], isFalse);
      expect(baseline['score']!['default'], '0', reason: '数值默认值转成字符串');
      expect(baseline['score']!['comment'], '');
    });

    test('空 / 异常 structure 返回空 Map', () {
      expect(tableDesignColumnBaseline(<String, dynamic>{}), isEmpty);
      expect(
        tableDesignColumnBaseline(<String, dynamic>{'columns': 'x'}),
        isEmpty,
      );
      expect(
        tableDesignColumnBaseline(<String, dynamic>{
          'columns': <dynamic>[
            <String, dynamic>{'name': ''},
            'not-a-map',
          ],
        }),
        isEmpty,
      );
    });
  });

  group('tableDesignColumnRowDirty：逐列 dirty 判断（第 56 轮）', () {
    Map<String, dynamic> baselineRow() => <String, dynamic>{
      'name': 'qty',
      'type': 'INT',
      'nullable': false,
      'default': '',
      'auto_increment': false,
      'comment': '',
    };
    Map<String, dynamic> withPatch(
      Map<String, dynamic> row, [
      Map<String, dynamic> patch = const <String, dynamic>{},
    ]) => <String, dynamic>{...row, ...patch};

    test('完全相同 / 忽略 UI 附加键 → 不 dirty', () {
      final base = baselineRow();
      expect(tableDesignColumnRowDirty(base, withPatch(base)), isFalse);
      expect(
        tableDesignColumnRowDirty(
          base,
          withPatch(base, <String, dynamic>{
            'isNew': false,
            'original': 'qty',
            'charset': 'utf8mb4',
            'collation': 'utf8mb4_general_ci',
          }),
        ),
        isFalse,
        reason: 'UI 附加键不参与比较',
      );
    });

    test('六个可编辑字段任一变化 → dirty', () {
      final base = baselineRow();
      expect(
        tableDesignColumnRowDirty(base, withPatch(base, {'name': 'qty2'})),
        isTrue,
      );
      expect(
        tableDesignColumnRowDirty(base, withPatch(base, {'type': 'BIGINT'})),
        isTrue,
      );
      expect(
        tableDesignColumnRowDirty(base, withPatch(base, {'nullable': true})),
        isTrue,
      );
      expect(
        tableDesignColumnRowDirty(base, withPatch(base, {'default': '0'})),
        isTrue,
      );
      expect(
        tableDesignColumnRowDirty(
          base,
          withPatch(base, {'auto_increment': true}),
        ),
        isTrue,
      );
      expect(
        tableDesignColumnRowDirty(base, withPatch(base, {'comment': '数量'})),
        isTrue,
      );
      // 列名按 trim 比较（_buildAlter 里的列名也是 trim 过的）。
      expect(
        tableDesignColumnRowDirty(base, withPatch(base, {'name': ' qty '})),
        isFalse,
      );
    });

    test('默认值 / 注释的 null 与空串等价；缺失键按空处理', () {
      final base = baselineRow();
      expect(
        tableDesignColumnRowDirty(base, <String, dynamic>{
          'name': 'qty',
          'type': 'INT',
          'nullable': false,
          'default': null,
          'auto_increment': false,
          'comment': null,
        }),
        isFalse,
      );
      expect(
        tableDesignColumnRowDirty(base, <String, dynamic>{'name': 'qty'}),
        isTrue,
        reason: 'type 缺失（空）与 INT 不同，仍算改过',
      );
      // 基线有默认值、用户清空 → dirty。
      expect(
        tableDesignColumnRowDirty(<String, dynamic>{
          ...base,
          'default': '0',
        }, base),
        isTrue,
      );
    });
  });

  group('tableDesignResetColumnRow：还原行（第 56 轮）', () {
    test('深拷贝且可编辑字段与基线等值', () {
      final baseline = tableDesignColumnBaseline(designStructure())['id']!;
      final row = tableDesignResetColumnRow(baseline);
      expect(row['name'], 'id');
      expect(row['type'], 'BIGINT');
      expect(row['nullable'], isFalse);
      expect(row['default'], '');
      expect(row['auto_increment'], isTrue);
      expect(row['comment'], '主键');
      // 可直接放进 _designColumns 的 UI 元数据。
      expect(row['isNew'], isFalse);
      expect(row['original'], 'id');
      expect(tableDesignColumnRowDirty(baseline, row), isFalse);

      // 深拷贝：改行不影响基线。
      row['type'] = 'TEXT';
      row['nullable'] = true;
      expect(baseline['type'], 'BIGINT');
      expect(baseline['nullable'], isFalse);
      expect(identical(row, baseline), isFalse);
    });

    test('还原后该列不再产生 modify_columns → 载荷回到空（dirty 回到 false）', () {
      final baseline = tableDesignColumnBaseline(designStructure())['name']!;
      final edited = <String, dynamic>{...baseline, 'type': 'TEXT'};
      expect(tableDesignColumnRowDirty(baseline, edited), isTrue);

      // 模拟 _buildAlter：只有 dirty 的现有列才进 modify_columns。
      List<dynamic> modifyFor(Map<String, dynamic> row) =>
          tableDesignColumnRowDirty(baseline, row)
          ? <dynamic>[row]
          : <dynamic>[];

      final before = <String, dynamic>{
        ...baselineBody(),
        'modify_columns': modifyFor(edited),
      };
      expect(tableDesignHasPendingChanges(before), isTrue);

      final restored = tableDesignResetColumnRow(baseline);
      final after = <String, dynamic>{
        ...baselineBody(),
        'modify_columns': modifyFor(restored),
      };
      expect(tableDesignHasPendingChanges(after), isFalse);
    });
  });

  // =====================================================================
  // 第 56 轮补充：列重命名真正生效（rename_columns）
  // =====================================================================

  group('tableDesignRenameColumns：列重命名（第 56 轮补充）', () {
    Map<String, dynamic> designColumn(
      String original,
      String name, {
      bool isNew = false,
    }) => <String, dynamic>{
      'name': name,
      'original': original,
      'isNew': isNew,
      'type': 'INT',
      'nullable': false,
      'default': '',
      'auto_increment': false,
      'comment': '',
    };

    test('existing 列改名才生成 from/to；未改名 / 新列 / 空名不生成', () {
      expect(
        tableDesignRenameColumns(<Map<String, dynamic>>[
          designColumn('qty', 'quantity'),
          designColumn('price', 'price'),
          designColumn('', 'new_col', isNew: true),
          designColumn('note', '   '),
        ]),
        <Map<String, dynamic>>[
          <String, dynamic>{'from': 'qty', 'to': 'quantity'},
        ],
      );
    });

    test('多列改名保持列顺序；目标重名只保留第一个', () {
      expect(
        tableDesignRenameColumns(<Map<String, dynamic>>[
          designColumn('a', 'alpha'),
          designColumn('b', 'beta'),
          designColumn('c', 'alpha'),
        ]),
        <Map<String, dynamic>>[
          <String, dynamic>{'from': 'a', 'to': 'alpha'},
          <String, dynamic>{'from': 'b', 'to': 'beta'},
        ],
      );
    });

    test('改成其它列现有名字 / 两列互换名字都不生成（逐条 RENAME 会撞名）', () {
      expect(
        tableDesignRenameColumns(<Map<String, dynamic>>[
          designColumn('a', 'b'),
          designColumn('b', 'b'),
        ]),
        isEmpty,
      );
      expect(
        tableDesignRenameColumns(<Map<String, dynamic>>[
          designColumn('a', 'b'),
          designColumn('b', 'a'),
        ]),
        isEmpty,
      );
    });

    test('名字 trim 后比较：前后空格不算改名', () {
      expect(
        tableDesignRenameColumns(<Map<String, dynamic>>[
          designColumn('qty', '  qty  '),
        ]),
        isEmpty,
      );
      expect(
        tableDesignRenameColumns(<Map<String, dynamic>>[
          designColumn(' qty ', 'quantity'),
        ]),
        <Map<String, dynamic>>[
          <String, dynamic>{'from': 'qty', 'to': 'quantity'},
        ],
      );
    });

    test('改名 + 改类型：modify payload 用新列名（RENAME 先执行）；未改名用原名', () {
      // 改名并改类型：rename 已生成 → MODIFY 用新名（RENAME 先作为独立语句
      // 执行，旧名此时已不存在）。
      final renamed = <String, dynamic>{
        ...designColumn('old_b', 'new_b'),
        'type': 'BIGINT',
      };
      final renames = tableDesignRenameColumns(<Map<String, dynamic>>[renamed]);
      expect(renames, <Map<String, dynamic>>[
        <String, dynamic>{'from': 'old_b', 'to': 'new_b'},
      ]);
      final payload = tableDesignColumnAlterPayload(renamed, renames);
      expect(payload['name'], 'new_b');
      expect(payload['type'], 'BIGINT');
      expect(payload['nullable'], isFalse);
      expect(payload['default'], isNull);
      expect(payload['auto_increment'], isFalse);
      expect(payload['comment'], isNull);

      // 未改名（只改类型）：仍用原名。
      final plain = <String, dynamic>{
        ...designColumn('qty', 'qty'),
        'type': 'BIGINT',
      };
      expect(
        tableDesignColumnAlterPayload(
          plain,
          const <Map<String, dynamic>>[],
        )['name'],
        'qty',
      );

      // 撞名导致 rename 被跳过：MODIFY 回退原名，避免指向不存在的列。
      final conflict = <String, dynamic>{
        ...designColumn('a', 'b'),
        'type': 'TEXT',
      };
      final conflictRenames = tableDesignRenameColumns(<Map<String, dynamic>>[
        conflict,
        designColumn('b', 'b'),
      ]);
      expect(conflictRenames, isEmpty);
      expect(
        tableDesignColumnAlterPayload(conflict, conflictRenames)['name'],
        'a',
      );

      // 新加的列用当前名。
      expect(
        tableDesignColumnAlterPayload(
          designColumn('', 'new_col', isNew: true),
          const <Map<String, dynamic>>[],
        )['name'],
        'new_col',
      );

      // 列名规则本身也可单独测。
      expect(tableDesignColumnAlterName(renamed, renames), 'new_b');
    });

    test('改名后载荷非空；仅改名不产生 modify；还原行后 rename 为空', () {
      final columns = <Map<String, dynamic>>[designColumn('qty', 'quantity')];
      final renames = tableDesignRenameColumns(columns);
      expect(renames, isNotEmpty);

      // 仅改名：rename_columns 让载荷非空，modify_columns 仍为空
      // （_columnChanged 不比较列名，只改名的现有列不会进 modify）。
      final body = <String, dynamic>{
        ...baselineBody(),
        'rename_columns': renames,
      };
      expect(tableDesignHasPendingChanges(body), isTrue);
      expect(body['modify_columns'], isEmpty);

      // 「还原该列」用基线行替换后名字回到原名 → 不再有 rename。
      final baseline = <String, dynamic>{
        'name': 'qty',
        'type': 'INT',
        'nullable': false,
        'default': '',
        'auto_increment': false,
        'comment': '',
      };
      final restored = tableDesignResetColumnRow(baseline);
      expect(
        tableDesignRenameColumns(<Map<String, dynamic>>[restored]),
        isEmpty,
      );
      final after = <String, dynamic>{
        ...baselineBody(),
        'rename_columns': tableDesignRenameColumns(<Map<String, dynamic>>[
          restored,
        ]),
      };
      expect(tableDesignHasPendingChanges(after), isFalse);
    });
  });
}
