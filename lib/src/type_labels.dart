// 标签由「中文名 + 括号 SQL token」拼成，显式拼接比插值更易读（同
// builder_labels.dart 的约定）。
// ignore_for_file: prefer_interpolation_to_compose_strings
import 'package:flutter/material.dart' hide Tooltip;

import 'i18n.dart';
import 'i18n_literals.dart';
import 'theme.dart';
import 'tooltip.dart';
import 'widgets.dart';

/// 数据库类型的「说人话」标签（第 50 轮 A 部分）。
///
/// 约定与查询构造器（builder/builder_labels.dart）一致：
///
///   * 中文界面里控件说人话，SQL token 只放在括号里方便对照；
///   * 英文界面直接显示原始 SQL 类型（INT / VARCHAR(255) / …）；
///   * 生成的 DDL / SQL 预览永远是真正的 SQL，不翻译任何关键字。
///
/// 每次调用都按当前语言计算（不缓存），所以切换语言后控件会立即换成另一套
/// 词汇。快速建表向导与新建表设计器共用这里，保证两个入口的说法一致。
bool get _chinese => I18n.current != AppLang.en;

/// 是否带 MySQL 的 UNSIGNED 后缀（大小写不敏感，忽略前后空白）。
bool _isUnsigned(String sqlType) =>
    RegExp(r'\bUNSIGNED\b', caseSensitive: false).hasMatch(sqlType);

/// 类型名（去掉长度/精度/枚举取值、UNSIGNED 后缀与多词别名后的族名）。
///
/// 数据库返回的写法很多：MySQL 的 `INT(11) UNSIGNED`、PostgreSQL 的
/// `double precision` / `character varying(255)` / `timestamp with time zone`。
/// 归一化后同一个「族」落到同一个 switch 分支，避免这些常见写法掉进
/// `default` 原样显示英文（第 51 轮 P2-1）。
String _typeFamily(String sqlType) {
  final upper = sqlType.trim().toUpperCase();
  if (upper.isEmpty) return '';
  // 带参数的写法：DECIMAL(18,2) / VARCHAR(255) / ENUM('a','b') / TIMESTAMP(3)。
  final paren = upper.indexOf('(');
  var head = (paren >= 0 ? upper.substring(0, paren) : upper).trim();
  // MySQL 的 UNSIGNED / ZEROFILL 是列的属性，不是类型族名。
  head = head.replaceAll(RegExp(r'\s+(UNSIGNED|ZEROFILL)\b'), '').trim();
  switch (head) {
    case 'DOUBLE PRECISION':
      return 'DOUBLE';
    case 'CHARACTER VARYING':
      return 'VARCHAR';
    case 'TIMESTAMP WITH TIME ZONE':
      return 'TIMESTAMPTZ';
    case 'TIMESTAMP WITHOUT TIME ZONE':
      return 'TIMESTAMP';
    case 'TIME WITH TIME ZONE':
      return 'TIMETZ';
    case 'TIME WITHOUT TIME ZONE':
      return 'TIME';
    default:
      final first = head.split(RegExp(r'\s+')).first;
      return first;
  }
}

/// 中文模式下的一句话类型说明（用于菜单/悬停提示）。
///
/// 说明按**具体类型**写，不按类型族写：中文标签本来就会撞车（SMALLINT /
/// MEDIUMINT / INT 都叫「整数」，TEXT / MEDIUMTEXT / LONGTEXT 都叫「文本」，
/// DATETIME / TIMESTAMP 都叫「日期时间」）。同族成员之间的差别 —— 取值范围、
/// 存储大小、是否带时区、单值还是多值 —— 正是用户唯一想知道的东西，所以这里
/// 写具体数字与语义，而不是一句通用的「整数，适合编号」。
String _typeDescription(String sqlType) {
  final family = _typeFamily(sqlType);
  final upper = sqlType.toUpperCase();
  final unsigned = _isUnsigned(sqlType);
  switch (family) {
    case 'TINYINT':
      if (upper.contains('(1)')) return '只有「是 / 否」两种取值';
      return unsigned ? '最小整数 0–255，适合状态、等级' : '最小整数 -128–127，适合状态、等级';
    case 'SMALLINT':
      return unsigned ? '小范围整数 0–65535' : '小范围整数 -32768–32767';
    case 'MEDIUMINT':
      return unsigned ? '中范围整数 0–16777215' : '中范围整数 -8388608–8388607';
    case 'INT':
    case 'INTEGER':
      return unsigned
          ? '常用整数 0–约 42 亿，适合编号、数量'
          : '常用整数 -21 亿–21 亿，适合编号、数量';
    case 'BIGINT':
      return unsigned
          ? '大范围整数 0–约 1844 亿亿'
          : '大范围整数 ±922 亿亿，常用作自增主键';
    case 'SERIAL':
    case 'BIGSERIAL':
    case 'SMALLSERIAL':
      return '插入时自动递增的整数，常用作主键';
    case 'DECIMAL':
      return '精确小数，需指定总位数与小数位（如 DECIMAL(18,2)），适合金额';
    case 'NUMERIC':
      return '精确小数，与 DECIMAL 等价（PostgreSQL 的叫法）';
    case 'MONEY':
      return '货币金额，固定小数位数';
    case 'FLOAT':
      return '单精度近似小数，约 7 位有效数字';
    case 'DOUBLE':
      return '双精度近似小数，约 15 位有效数字';
    case 'REAL':
      return '单精度近似小数（PostgreSQL 写法）';
    case 'BOOLEAN':
    case 'BOOL':
      return '只有「是 / 否」两种取值';
    case 'BIT':
      return '位字段：BIT(1) 常当布尔用，BIT(n) 存 n 位二进制';
    case 'DATE':
      return '只记录年月日';
    case 'DATETIME':
      return '日期加时间，按字面保存，不做时区换算';
    case 'TIMESTAMP':
      return '日期加时间，按会话时区换算（MySQL 只到 2038 年）';
    case 'TIMESTAMPTZ':
      return '日期加时间，存 UTC 并按查询时区显示';
    case 'TIME':
      return '只记录时分秒';
    case 'TIMETZ':
      return '时分秒加时区偏移';
    case 'TINYTEXT':
      return '短文本，最长 255 字节';
    case 'TEXT':
      return '长文本，最长 64KB';
    case 'MEDIUMTEXT':
      return '中等文本，最长 16MB';
    case 'LONGTEXT':
      return '超长文本，最长 4GB';
    case 'CLOB':
      return '大文本对象';
    case 'VARCHAR':
      return '变长文本，括号里是字符数上限';
    case 'CHAR':
      return '定长文本，不足长度会用空格补齐';
    case 'CHARACTER':
      return '定长文本，PostgreSQL 的 CHAR 别名';
    case 'CITEXT':
      return '不区分大小写的文本，适合邮箱';
    case 'JSON':
      return 'JSON 文本，原样保存，查询较慢';
    case 'JSONB':
      return '二进制 JSON，可建索引，查询更快（PostgreSQL）';
    case 'ENUM':
      return '只能从列出的值里选一个';
    case 'SET':
      return '从列出的值里选，可多选（MySQL）';
    case 'TINYBLOB':
      return '二进制数据，最长 255 字节';
    case 'BLOB':
      return '二进制数据，最长 64KB';
    case 'MEDIUMBLOB':
      return '二进制数据，最长 16MB';
    case 'LONGBLOB':
      return '二进制数据，最长 4GB';
    case 'BINARY':
      return '定长二进制，不足会用 0 补齐';
    case 'VARBINARY':
      return '变长二进制';
    case 'BYTEA':
      return '二进制数据（PostgreSQL）';
    case 'YEAR':
      return '只有年份';
    case 'UUID':
      return '全局唯一标识符';
    case 'XML':
      return 'XML 文本';
    case 'INTERVAL':
      return '一段时间（如 1 天、2 小时）';
    case 'INET':
      return 'IPv4 / IPv6 地址';
    case 'CIDR':
      return 'IP 网段（如 192.168.0.0/24）';
    case 'MACADDR':
      return 'MAC 地址';
    case 'POINT':
      return '平面坐标点';
    case 'TSVECTOR':
      return '全文检索用的词元';
    default:
      return '';
  }
}

/// 英文模式下的一句话类型说明（用于菜单/悬停提示）。
///
/// Same rule as the Chinese side: per concrete type, not per family, so the
/// members of a family that share one translated label stay distinguishable.
String _typeDescriptionEn(String sqlType) {
  final family = _typeFamily(sqlType);
  final upper = sqlType.toUpperCase();
  final unsigned = _isUnsigned(sqlType);
  switch (family) {
    case 'TINYINT':
      return upper.contains('(1)')
          ? 'true / false'
          : (unsigned ? 'smallest integer, 0-255' : 'smallest integer, -128-127');
    case 'SMALLINT':
      return unsigned ? 'small integer, 0-65535' : 'small integer, -32768-32767';
    case 'MEDIUMINT':
      return unsigned
          ? 'medium integer, 0-16777215'
          : 'medium integer, -8388608-8388607';
    case 'INT':
    case 'INTEGER':
      return unsigned
          ? 'common integer, 0 to about 4.29e9'
          : 'common integer, about -2.1e9 to 2.1e9';
    case 'BIGINT':
      return unsigned
          ? 'large integer, 0 to about 1.8e19'
          : 'large integer, about +/-9.2e18';
    case 'SERIAL':
    case 'BIGSERIAL':
    case 'SMALLSERIAL':
      return 'auto-increment integer, usually a primary key';
    case 'DECIMAL':
      return 'exact decimal, needs total and fractional digits (e.g. DECIMAL(18,2))';
    case 'NUMERIC':
      return 'exact decimal, PostgreSQL name for DECIMAL';
    case 'MONEY':
      return 'currency amount with a fixed number of decimals';
    case 'FLOAT':
      return 'single-precision approximate decimal, about 7 significant digits';
    case 'DOUBLE':
      return 'double-precision approximate decimal, about 15 significant digits';
    case 'REAL':
      return 'single-precision approximate decimal (PostgreSQL)';
    case 'BOOLEAN':
    case 'BOOL':
      return 'true / false';
    case 'BIT':
      return 'bit field: BIT(1) behaves like a boolean, BIT(n) holds n bits';
    case 'DATE':
      return 'calendar date';
    case 'DATETIME':
      return 'date and time, stored as written, no time-zone conversion';
    case 'TIMESTAMP':
      return 'date and time, converted per the session time zone';
    case 'TIMESTAMPTZ':
      return 'date and time stored as UTC, shown in the query time zone';
    case 'TIME':
      return 'time of day';
    case 'TIMETZ':
      return 'time of day with a time-zone offset';
    case 'TINYTEXT':
      return 'short text, up to 255 bytes';
    case 'TEXT':
      return 'long text, up to 64KB';
    case 'MEDIUMTEXT':
      return 'medium text, up to 16MB';
    case 'LONGTEXT':
      return 'very long text, up to 4GB';
    case 'CLOB':
      return 'character large object';
    case 'VARCHAR':
      return 'variable-length text with a length limit';
    case 'CHAR':
      return 'fixed-length text, padded with spaces';
    case 'CHARACTER':
      return 'fixed-length text, PostgreSQL alias of CHAR';
    case 'CITEXT':
      return 'case-insensitive text';
    case 'JSON':
      return 'JSON text, stored verbatim, slower to query';
    case 'JSONB':
      return 'binary JSON, indexable and faster to query (PostgreSQL)';
    case 'ENUM':
      return 'exactly one of the listed values';
    case 'SET':
      return 'zero or more of the listed values (MySQL)';
    case 'TINYBLOB':
      return 'binary data, up to 255 bytes';
    case 'BLOB':
      return 'binary data, up to 64KB';
    case 'MEDIUMBLOB':
      return 'binary data, up to 16MB';
    case 'LONGBLOB':
      return 'binary data, up to 4GB';
    case 'BINARY':
      return 'fixed-length binary, zero padded';
    case 'VARBINARY':
      return 'variable-length binary';
    case 'BYTEA':
      return 'binary data (PostgreSQL)';
    case 'YEAR':
      return 'year only';
    case 'UUID':
      return 'globally unique identifier';
    case 'XML':
      return 'XML text';
    case 'INTERVAL':
      return 'a span of time (1 day, 2 hours)';
    case 'INET':
      return 'IPv4 / IPv6 address';
    case 'CIDR':
      return 'IP network (e.g. 192.168.0.0/24)';
    case 'MACADDR':
      return 'MAC address';
    case 'POINT':
      return 'planar point';
    case 'TSVECTOR':
      return 'document tokens for full-text search';
    default:
      return '';
  }
}

/// 中文类型名；英文模式返回原始 SQL 类型。
String columnTypeLabel(String sqlType) {
  if (!_chinese) return sqlType;
  final family = _typeFamily(sqlType);
  final unsigned = _isUnsigned(sqlType);
  switch (family) {
    case 'TINYINT':
      if (sqlType.toUpperCase().contains('(1)')) return '布尔';
      return unsigned ? '无符号小整数' : '整数';
    case 'SMALLINT':
    case 'MEDIUMINT':
    case 'INT':
    case 'INTEGER':
      return unsigned ? '无符号整数' : '整数';
    case 'BIGINT':
      return unsigned ? '无符号大整数' : '大整数';
    case 'SERIAL':
    case 'SMALLSERIAL':
      return '自增整数';
    case 'BIGSERIAL':
      return '自增大整数';
    case 'DECIMAL':
    case 'NUMERIC':
    case 'MONEY':
      return '小数';
    case 'FLOAT':
    case 'DOUBLE':
    case 'REAL':
      return '浮点';
    case 'BOOLEAN':
    case 'BOOL':
      return '布尔';
    case 'DATE':
      return '日期';
    case 'DATETIME':
    case 'TIMESTAMP':
    case 'TIMESTAMPTZ':
      return '日期时间';
    case 'TIME':
    case 'TIMETZ':
      return '时间';
    case 'TEXT':
    case 'TINYTEXT':
    case 'MEDIUMTEXT':
    case 'LONGTEXT':
    case 'CLOB':
      return '文本';
    case 'VARCHAR':
    case 'CHAR':
    case 'CHARACTER':
      // 长度是用户需要看到的差异（TEXT 与 VARCHAR(255) 的约束不同）。
      return '文本（' + sqlType + '）';
    case 'CITEXT':
      return '不区分大小写的文本';
    case 'JSON':
    case 'JSONB':
      return 'JSON 数据';
    case 'ENUM':
    case 'SET':
      return '枚举';
    case 'BLOB':
    case 'TINYBLOB':
    case 'MEDIUMBLOB':
    case 'LONGBLOB':
    case 'BINARY':
    case 'VARBINARY':
    case 'BYTEA':
      return '二进制';
    case 'YEAR':
      return '年份';
    case 'UUID':
      return 'UUID';
    case 'BIT':
      return '位';
    case 'XML':
      return 'XML 文本';
    case 'INTERVAL':
      return '时间间隔';
    case 'INET':
    case 'CIDR':
    case 'MACADDR':
      return '网络地址';
    case 'POINT':
      return '坐标点';
    case 'TSVECTOR':
      return '全文词元';
    default:
      return sqlType;
  }
}

/// 「中文名（SQL token）」；label 自己已经带了 SQL token 时不再重复拼接。
///
/// 第 51 轮 P2-1：VARCHAR / CHAR 的 label 本身就是「文本（VARCHAR(255)）」，
/// 早期这里又追加了一次 token，导致菜单里出现
/// 「文本（VARCHAR(255)）（VARCHAR(255)）」。
String _labelWithSqlType(String label, String sqlType) {
  if (label == sqlType) return sqlType;
  if (label.contains(sqlType)) return label;
  return label + '（' + sqlType + '）';
}

/// 下拉菜单里的类型标签：中文名 + 括号 SQL token；英文模式只显示 SQL 类型。
///
/// 未知类型（用户手输的自定义类型）直接返回原文，避免出现「FOO（FOO）」。
String columnTypeMenuLabel(String sqlType) {
  if (!_chinese) return sqlType;
  return _labelWithSqlType(columnTypeLabel(sqlType), sqlType);
}

/// 类型控件/菜单项的悬停说明：中文名（SQL token）：一句话解释。
///
/// 英文模式返回「SQL 类型: explanation」，保持和原生 SQL 一致的阅读方式。
String columnTypeTooltip(String sqlType) {
  if (!_chinese) {
    final description = _typeDescriptionEn(sqlType);
    return description.isEmpty ? sqlType : sqlType + ': ' + description;
  }
  final description = _typeDescription(sqlType);
  final head = _labelWithSqlType(columnTypeLabel(sqlType), sqlType);
  return description.isEmpty ? head : head + '：' + description;
}

/// 类型下拉：关闭态显示中文类型名，菜单项显示「中文名（SQL token）」。
///
/// 选择值仍是原始 SQL 类型（[value]/[onChanged] 使用 SQL 字符串），所以建表
/// 预览和最终 DDL 不受影响。样式与 [SelectBox] 保持一致；不能直接复用
/// SelectBox 是因为它的关闭态与菜单项共用同一个 child，无法同时做到「关闭态
/// 说人话、菜单里带 SQL token」。
class ColumnTypePicker extends StatelessWidget {
  const ColumnTypePicker({
    super.key,
    required this.value,
    required this.types,
    required this.onChanged,
    this.enabled = true,
    this.width,
  });

  /// 当前 SQL 类型。
  final String value;

  /// 可选 SQL 类型（顺序即菜单顺序）。
  final List<String> types;

  final ValueChanged<String?>? onChanged;
  final bool enabled;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final items = <String>[...types];
    if (value.isNotEmpty && !items.contains(value)) items.insert(0, value);
    final hasValue = value.isNotEmpty && items.contains(value);
    final style = TextStyle(fontSize: 13, color: AppColors.bodyText);

    final boundedItems = <DropdownMenuItem<String>>[
      for (final type in items)
        DropdownMenuItem<String>(
          value: type,
          child: Tooltip(
            message: columnTypeTooltip(type),
            constraints: kTooltipConstraints,
            waitDuration: const Duration(milliseconds: 400),
            child: DefaultTextStyle.merge(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              child: Text(columnTypeMenuLabel(type), style: style),
            ),
          ),
        ),
    ];
    // 关闭态必须是轻量 Text（不能用带 Tooltip/MouseRegion 的菜单项，否则
    // DropdownButton 的 IndexedStack 会为每个类型都建一个 Tooltip）。
    final closedItems = <Widget>[
      for (final type in items)
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            columnTypeLabel(type),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
    ];
    final dropdown = DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: hasValue ? value : null,
        items: boundedItems,
        selectedItemBuilder: (context) => closedItems,
        onChanged: enabled ? onChanged : null,
        isDense: true,
        isExpanded: true,
        style: style,
        icon: Icon(Icons.expand_more, size: 16, color: AppColors.muted),
        dropdownColor: AppColors.panel,
        borderRadius: BorderRadius.circular(AppMetrics.radiusControl),
        menuMaxHeight: 360,
      ),
    );

    final box = Container(
      height: kControlHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: enabled ? AppColors.panel : AppColors.chipBg,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppMetrics.radiusControl),
      ),
      child: dropdown,
    );
    final shown = hasValue
        ? Tooltip(
            message: columnTypeTooltip(value),
            constraints: kTooltipConstraints,
            waitDuration: const Duration(milliseconds: 400),
            child: box,
          )
        : box;
    if (width == null) return shown;
    return SizedBox(width: width, child: shown);
  }
}

/// 中文界面的「当前类型 + 说明」一行文字（步骤卡片、汇总行等地方用）。
///
/// 英文模式返回原文 SQL 类型，不做任何翻译。
String columnTypeSummary(String sqlType) {
  if (!_chinese) return sqlType;
  return _labelWithSqlType(columnTypeLabel(sqlType), sqlType);
}

/// 便于在无 BuildContext 的纯逻辑里按当前语言取文案（测试用）。
String pickTypeText(String zh, String en) => pickText(zh, en);
