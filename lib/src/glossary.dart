import 'package:flutter/material.dart';

import 'i18n.dart';
import 'i18n_literals.dart';
import 'theme.dart';
import 'widgets.dart';

/// 一条术语说明：中文名 + SQL / 英文对照 + 一句白话解释 + 展开后的补充。
class GlossaryEntry {
  const GlossaryEntry({
    required this.term,
    required this.sqlTerm,
    required this.definition,
    required this.detail,
  });

  /// 中文界面显示的术语名（英文界面直接用 [sqlTerm]）。
  final String term;

  /// SQL / 英文术语，永远显示，方便与报错、文档对照。
  final String sqlTerm;

  /// 一句话白话解释（中文界面显示中文版，英文界面显示英文版）。
  final String definition;

  /// 展开后的补充说明（为什么重要、常见误解）。
  final String detail;

  String label() => I18n.current == AppLang.en ? sqlTerm : term;
}

/// 术语表（第 53 轮 P3：界面上只有「主键/外键/唯一/中间表/事务/约束」这类行话，
/// 文员看不懂）。保持纯数据，便于单测与后续复用。
List<GlossaryEntry> glossaryEntries() => <GlossaryEntry>[
  GlossaryEntry(
    term: '主键',
    sqlTerm: 'PRIMARY KEY',
    definition: pickText(
      '这一列（或几列）能唯一区分表里的每一行，而且不能重复、不能为空。',
      'The column (or columns) that uniquely identifies every row; it cannot repeat or be empty.',
    ),
    detail: pickText(
      '例如「学号」：每个学生一个学号，不会重复。没有主键的表不能作为外键的被引用表；'
          '自增 id 是一种常见的主键。',
      'For example a student number: one per student, never repeated. A table without a '
          'primary key cannot be referenced by foreign keys; an auto-increment id is a common primary key.',
    ),
  ),
  GlossaryEntry(
    term: '外键',
    sqlTerm: 'FOREIGN KEY',
    definition: pickText(
      '这一列的值必须在另一张表的某一列（通常是主键）里存在，用来把两张表关联起来。',
      'Values in this column must exist in another table\'s column (usually its primary key); '
          'this links the two tables.',
    ),
    detail: pickText(
      '例如订单表的「用户 id」必须能在用户表里找到。数据库会拒绝写入找不到对应父行'
          '的子表数据（常见报错：外键约束失败 / ERROR 1452 / 23000）。'
          '两边列的类型要完全一致（例如 INT 对 INT、BIGINT 对 BIGINT）。',
      'For example an order\'s user id must exist in the users table. The database rejects '
          'child rows whose parent is missing (foreign key constraint fails / ERROR 1452 / 23000). '
          'Both columns must have exactly the same type (INT to INT, BIGINT to BIGINT).',
    ),
  ),
  GlossaryEntry(
    term: '唯一',
    sqlTerm: 'UNIQUE',
    definition: pickText(
      '这一列的值不能重复（但允许为空，除非另外要求非空）。',
      'Values in this column cannot repeat (it may allow NULL unless it is also required).',
    ),
    detail: pickText(
      '唯一列也可以作为外键的被引用列。例如「邮箱」通常设为唯一，防止两个人共用一个邮箱。',
      'A unique column can also be referenced by a foreign key. For example email is often '
          'unique so two people cannot share one address.',
    ),
  ),
  GlossaryEntry(
    term: '约束',
    sqlTerm: 'CONSTRAINT',
    definition: pickText(
      '数据库强制执行的规则，例如不能为空、不能重复、必须能在父表找到对应值。',
      'Rules the database enforces, such as not null, unique, or must exist in the parent table.',
    ),
    detail: pickText(
      '外键、主键、唯一、非空都属于约束。违反约束时写入会被拒绝，而不是悄悄写进去。',
      'Foreign keys, primary keys, unique keys and NOT NULL are all constraints. Violating one '
          'rejects the write instead of storing wrong data silently.',
    ),
  ),
  GlossaryEntry(
    term: '索引',
    sqlTerm: 'INDEX',
    definition: pickText(
      '给某一列建的「目录」，让按这一列查找更快（类似书的目录）。',
      'A lookup structure on a column that makes searching by it faster (like a book index).',
    ),
    detail: pickText(
      '索引不改变数据内容，只影响查询速度；外键列通常会自动建索引。索引太多会拖慢写入。',
      'An index does not change the data, only query speed; foreign key columns usually get one '
          'automatically. Too many indexes slow writes down.',
    ),
  ),
  GlossaryEntry(
    term: '中间表',
    sqlTerm: 'JUNCTION TABLE',
    definition: pickText(
      '用来表示两张表「多对多」关系的第三张表，里面通常只有两个外键列。',
      'A third table that represents a many-to-many relation between two tables; it usually '
          'holds just two foreign keys.',
    ),
    detail: pickText(
      '例如「订单明细」表：一行表示某订单买了某商品，同时连着订单表和商品表。'
          '关系图里恰好有两个外键指向两张不同表的表会被标成中间表。',
      'For example an order_items table: one row means one order bought one product, linking '
          'orders and products. In the designer, a table with exactly two foreign keys pointing '
          'at two different tables is marked as a junction table.',
    ),
  ),
  GlossaryEntry(
    term: '多对多',
    sqlTerm: 'MANY-TO-MANY',
    definition: pickText(
      'A 的很多行可以对应 B 的很多行（例如一个订单有多个商品，一个商品出现在多个订单里）。',
      'Many rows of A can relate to many rows of B (an order has many products; a product '
          'appears in many orders).',
    ),
    detail: pickText(
      '多对多不能只靠两个外键列直接表示，通常需要中间表；关系图会把中间表折叠成一条'
          '橙色「多对多」连线。',
      'Many-to-many cannot be represented by two foreign key columns alone; it usually needs a '
          'junction table, which the designer collapses into an orange many-to-many line.',
    ),
  ),
  GlossaryEntry(
    term: '事务',
    sqlTerm: 'TRANSACTION',
    definition: pickText(
      '一组要么全部成功、要么全部撤销的写入操作。',
      'A group of writes that either all succeed or are all rolled back.',
    ),
    detail: pickText(
      '例如批量保存 100 行修改：中途第 50 行出错时，前面 49 行也会一起撤销，不会留下半套数据。',
      'For example saving 100 edited rows: if row 50 fails, the previous 49 changes are rolled '
          'back too, so no half-written data is left behind.',
    ),
  ),
  GlossaryEntry(
    term: '自增',
    sqlTerm: 'AUTO_INCREMENT',
    definition: pickText(
      '插入新行时由数据库自动填一个递增的整数，不用人工填。',
      'The database fills in an increasing integer for each new row, so nobody has to type it.',
    ),
    detail: pickText(
      '只适合「没有业务含义的 id」。学号、订单号、工号这类业务编号不要自增，'
          '否则漏填时数据库会生成不存在的编号；需要来自源文件。',
      'Only for ids without business meaning. Student/order/employee numbers must not be '
          'auto-increment, otherwise a missing value becomes a made-up number; they must come '
          'from the source file.',
    ),
  ),
  GlossaryEntry(
    term: '空值',
    sqlTerm: 'NULL',
    definition: pickText(
      '「没有填写」的单元格，和 0、空字符串都不一样：0 是一个数值，NULL 是未知/未填。',
      'A cell with no value; it differs from 0 and from an empty string — 0 is a number, NULL '
          'means unknown/not filled.',
    ),
    detail: pickText(
      '主键列不允许 NULL；外键列遇到 NULL 时数据库通常不检查引用（表示「没有关联」）。'
          'Excel 里的空白单元格导入后会变成 NULL。',
      'Primary key columns cannot be NULL; a NULL foreign key usually means "no relation" and '
          'is not checked. Blank Excel cells become NULL after import.',
    ),
  ),
];

/// 打开术语说明对话框（第 53 轮 P3）。
///
/// [highlight] 命中某个术语时列表会把该条排在最前并展开补充说明（例如从
/// 「主键」旁的问号进入）。
Future<void> showGlossaryDialog(BuildContext context, {String? highlight}) {
  return showAppModal<void>(
    context: context,
    title: pickText('术语说明（说人话版）', 'Glossary (plain language)'),
    wide: true,
    builder: (context) => _GlossaryBody(highlight: highlight),
    actions: <Widget>[
      Builder(
        builder: (context) => Btn(
          pickText('关闭', 'Close'),
          key: const ValueKey<String>('glossary-close'),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
    ],
  );
}

class _GlossaryBody extends StatelessWidget {
  const _GlossaryBody({this.highlight});

  final String? highlight;

  @override
  Widget build(BuildContext context) {
    final entries = glossaryEntries();
    final index = highlight == null
        ? -1
        : entries.indexWhere(
            (entry) => entry.term == highlight || entry.sqlTerm == highlight,
          );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 520, maxWidth: 760),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              pickText(
                '这里用日常语言解释界面上出现的数据库术语；SQL 关键字放在括号里方便与报错对照。',
                'Every database term used in the UI is explained in plain language; the SQL keyword '
                    'is shown in the heading so it can be matched against error messages.',
              ),
              style: kSmallMuted,
            ),
            const SizedBox(height: 10),
            for (var i = 0; i < entries.length; i++)
              _GlossaryTile(
                entry: entries[i],
                expanded: i == index,
                key: ValueKey<String>('glossary-term-${entries[i].sqlTerm}'),
              ),
          ],
        ),
      ),
    );
  }
}

class _GlossaryTile extends StatelessWidget {
  const _GlossaryTile({required this.entry, required this.expanded, super.key});

  final GlossaryEntry entry;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(
          color: expanded ? AppColors.header : AppColors.border,
        ),
        borderRadius: BorderRadius.circular(AppMetrics.radiusControl),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text(
                entry.label(),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.bodyText,
                ),
              ),
              Text(entry.sqlTerm, style: kSmallMuted),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            entry.definition,
            style: TextStyle(fontSize: 12, color: AppColors.bodyText),
          ),
          if (expanded) ...<Widget>[
            const SizedBox(height: 4),
            Text(entry.detail, style: kSmallMuted),
          ],
        ],
      ),
    );
  }
}
