// Builder labels are assembled from a label plus its SQL token in parentheses;
// explicit concatenation keeps those one-liners readable.
// ignore_for_file: prefer_interpolation_to_compose_strings
import '../i18n.dart';

/// Human-readable labels for the query builder controls.
///
/// The builder is aimed at people who are **not** database developers: the
/// configuration UI must not ask them to reason about "INNER", "IS NOT NULL" or
/// "DESC". In Chinese the controls therefore speak plain Chinese (with the SQL
/// token kept in parentheses, so the generated statement stays teachable); in
/// English the plain SQL keywords are shown, exactly as before.
///
/// Only the **controls** are translated. The SQL preview is always real SQL:
/// translating keywords inside it would produce a statement nobody can run.
///
/// Every function is evaluated at build time (not cached), so switching the
/// language in the top bar re-renders the builder with the other vocabulary.

bool get _chinese => I18n.current != AppLang.en;

/// Join type as shown inside the closed join-type picker.
String joinTypeLabel(String type) {
  if (!_chinese) return type;
  switch (type) {
    case 'INNER':
      return '内连接';
    case 'LEFT':
      return '左连接';
    case 'RIGHT':
      return '右连接';
    case 'FULL OUTER':
      return '全连接';
    case 'CROSS':
      return '交叉连接';
    default:
      return type;
  }
}

/// Join type as shown in the picker menu: Chinese name plus the SQL token.
String joinTypeMenuLabel(String type) =>
    _chinese ? joinTypeLabel(type) + '（' + type + '）' : type;

/// One-sentence explanation of what a join type does, for the tooltip / menu.
String joinTypeDescription(String type) {
  if (!_chinese) {
    switch (type) {
      case 'INNER':
        return 'Only rows that match in both tables';
      case 'LEFT':
        return 'All left rows; unmatched right columns are NULL';
      case 'RIGHT':
        return 'All right rows; unmatched left columns are NULL';
      case 'FULL OUTER':
        return 'All rows from both tables; unmatched sides are NULL'
            '（PostgreSQL / SQLite run it natively, MySQL rewrites it as two LEFT JOINs merged with UNION）';
      case 'CROSS':
        return 'Every row combined with every row of the other table (no match condition)';
      default:
        return '';
    }
  }
  switch (type) {
    case 'INNER':
      return '只保留两张表都能对应上的行（两个表都要有匹配数据）';
    case 'LEFT':
      return '保留左边表的全部行；右边表没有对应数据时显示为空';
    case 'RIGHT':
      return '保留右边表的全部行；左边表没有对应数据时显示为空';
    case 'FULL OUTER':
      return '两张表的行都保留，没有对应的一侧显示为空；'
          'MySQL 会自动改写成两次左连接再合并（PostgreSQL / SQLite 原生支持）';
    case 'CROSS':
      return '两张表的每一行都和另一张表的每一行两两组合（不需要匹配条件）';
    default:
      return '';
  }
}

/// Comparison operator as shown in the closed picker.
String operatorLabel(String op) {
  if (!_chinese) return op;
  switch (op) {
    case '=':
      return '等于（=）';
    case '!=':
      return '不等于（≠）';
    case '>':
      return '大于（>）';
    case '>=':
      return '大于等于（≥）';
    case '<':
      return '小于（<）';
    case '<=':
      return '小于等于（≤）';
    case 'LIKE':
      return '包含（LIKE）';
    case 'NOT LIKE':
      return '不包含（NOT LIKE）';
    case 'IN':
      return '属于其中任意一个（IN）';
    case 'IS NULL':
      return '为空（IS NULL）';
    case 'IS NOT NULL':
      return '不为空（IS NOT NULL）';
    case 'ILIKE':
      return '包含·忽略大小写（ILIKE）';
    default:
      return op;
  }
}

/// Explanation of a comparison operator, used as the picker tooltip.
String operatorDescription(String op) {
  if (!_chinese) return 'Comparison operator';
  switch (op) {
    case 'LIKE':
    case 'NOT LIKE':
      return '按文字内容模糊匹配，不需要输入 % 通配符';
    case 'ILIKE':
      return '按文字内容模糊匹配，且不区分大小写（仅 PostgreSQL）';
    case 'IN':
      return '值可以填多个，用英文逗号分隔，例如：已支付, 已发货';
    case 'IS NULL':
    case 'IS NOT NULL':
      return '判断这一列是否为空，不需要填写值';
    default:
      return '比较运算符：满足该关系的数据才会被查询出来';
  }
}

/// Sort direction label (ASC / DESC).
String orderDirectionLabel(String dir) {
  if (!_chinese) return dir;
  return dir == 'DESC' ? '降序（DESC）' : '升序（ASC）';
}

/// One aggregate function label. Empty string is "raw column".
String aggregateLabel(String aggregate) {
  if (!_chinese) return aggregate.isEmpty ? 'Raw' : aggregate;
  switch (aggregate) {
    case '':
      return '原始值';
    case 'MIN':
      return '最小值（MIN）';
    case 'MAX':
      return '最大值（MAX）';
    case 'SUM':
      return '合计（SUM）';
    case 'AVG':
      return '平均值（AVG）';
    case 'COUNT':
      return '计数（COUNT）';
    default:
      return aggregate;
  }
}

/// AND / OR connector label.
String connectorLabel(String logic) {
  if (!_chinese) return logic;
  return logic == 'OR' ? '或者（OR）' : '并且（AND）';
}

/// The "combine with previous condition" caption.
String connectorCaption() => _chinese ? '与上一条件的关系' : 'Combine with';

/// The "combine inside the group" caption.
String groupConnectorCaption() => _chinese ? '组内条件的关系' : 'Within group';

/// The filter group heading, e.g. "并且 条件组".
String filterGroupTitle(String logic) => _chinese
    ? connectorLabel(logic).replaceAll(RegExp(r'（.*?）'), '') + '条件组'
    : logic + ' group';

/// Root filter tag: the web builder wrote WHERE; Chinese users get a sentence.
String whereLabel() => _chinese ? '满足以下条件' : 'WHERE';

/// The join match keyword between the two ON columns.
String onLabel() => _chinese ? '匹配' : 'ON';

/// The join comparison between the two ON columns.
String joinEqualsLabel() => _chinese ? '等于' : '=';

/// DISTINCT checkbox label.
String distinctLabel() =>
    _chinese ? '去重（相同结果只保留一条）' : 'DISTINCT';

/// LIMIT caption in the sorting tab.
String limitLabel() => _chinese ? '最多返回多少行（LIMIT）' : 'LIMIT';

/// Aggregate picker heading.
String aggregateCaption() => _chinese ? '聚合方式' : 'Aggregate';

/// Sorting direction caption.
String directionCaption() => _chinese ? '排序方向' : 'Direction';

/// Label of one entry of the data source picker.
///
/// PostgreSQL lists the **schemas** of the active database while MySQL lists
/// the databases themselves; prefixing the physical database in PostgreSQL
/// makes the two engines read the same way ("pagila_r34.public" is the schema
/// `public` of database `pagila_r34`), which is what the round-34 report
/// asked for (P3-07). `database` is ignored when it is empty, identical to the
/// schema, or when the connection is not PostgreSQL.
String dataSourceOptionLabel(
  String namespace, {
  String? database,
  bool postgres = false,
}) {
  if (!postgres) return namespace;
  if (database == null || database.isEmpty || database == namespace) {
    return namespace;
  }
  return database + '.' + namespace;
}
