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

/// 类型名（去掉长度/精度/枚举取值后的族名）。
String _typeFamily(String sqlType) {
  final upper = sqlType.trim().toUpperCase();
  if (upper.isEmpty) return '';
  // 带参数的写法：DECIMAL(18,2) / VARCHAR(255) / ENUM('a','b') / TIMESTAMP(3)。
  final paren = upper.indexOf('(');
  final head = paren >= 0 ? upper.substring(0, paren).trim() : upper;
  return head;
}

/// 中文模式下的一句话类型说明（用于菜单/悬停提示）。
String _typeDescription(String sqlType) {
  final family = _typeFamily(sqlType);
  switch (family) {
    case 'TINYINT':
      // MySQL 的 TINYINT(1) 是布尔约定；其余 TINYINT 仍是整数。
      if (sqlType.toUpperCase().contains('(1)')) {
        return '只有「是 / 否」两种取值';
      }
      return '很小的整数，适合状态、等级等';
    case 'SMALLINT':
    case 'MEDIUMINT':
    case 'INT':
    case 'INTEGER':
      return '整数，适合编号、数量等没有小数的值';
    case 'BIGINT':
      return '大整数，常用作自增主键';
    case 'SERIAL':
    case 'BIGSERIAL':
    case 'SMALLSERIAL':
      return '会自动递增的整数，常用作主键';
    case 'DECIMAL':
    case 'NUMERIC':
    case 'MONEY':
      return '带小数的精确数字，适合金额、成绩等';
    case 'FLOAT':
    case 'DOUBLE':
    case 'REAL':
      return '近似小数，适合比率、科学计算等';
    case 'BOOLEAN':
    case 'BOOL':
      return '只有「是 / 否」两种取值';
    case 'DATE':
      return '只记录年月日';
    case 'DATETIME':
    case 'TIMESTAMP':
    case 'TIMESTAMPTZ':
      return '日期加时间（精确到时分秒）';
    case 'TIME':
    case 'TIMETZ':
      return '只记录时分秒';
    case 'TEXT':
    case 'TINYTEXT':
    case 'MEDIUMTEXT':
    case 'LONGTEXT':
    case 'CLOB':
      return '长文本，适合备注、说明等';
    case 'VARCHAR':
    case 'CHAR':
    case 'CHARACTER':
      return '有长度上限的文本';
    case 'JSON':
    case 'JSONB':
      return 'JSON 数据，适合结构不固定的内容';
    case 'ENUM':
    case 'SET':
      return '只能取列出的几个值之一';
    case 'BLOB':
    case 'BINARY':
    case 'VARBINARY':
    case 'BYTEA':
      return '二进制数据（图片、文件内容等）';
    case 'YEAR':
      return '只有年份';
    case 'UUID':
      return '全局唯一标识符';
    case 'BIT':
      return '位值（0 / 1）';
    case 'XML':
      return 'XML 文本';
    case 'INTERVAL':
      return '一段时间（如 1 天、2 小时）';
    case 'INET':
    case 'CIDR':
    case 'MACADDR':
      return '网络地址';
    case 'POINT':
      return '平面坐标点';
    case 'TSVECTOR':
      return '全文检索用的词元';
    default:
      return '';
  }
}

/// 英文模式下的一句话类型说明（用于菜单/悬停提示）。
String _typeDescriptionEn(String sqlType) {
  final family = _typeFamily(sqlType);
  switch (family) {
    case 'TINYINT':
      return sqlType.toUpperCase().contains('(1)')
          ? 'true / false'
          : 'small integer';
    case 'SMALLINT':
    case 'MEDIUMINT':
    case 'INT':
    case 'INTEGER':
      return 'whole numbers';
    case 'BIGINT':
      return 'large integers, common for auto-increment keys';
    case 'SERIAL':
    case 'BIGSERIAL':
    case 'SMALLSERIAL':
      return 'auto-increment integer, usually a primary key';
    case 'DECIMAL':
    case 'NUMERIC':
    case 'MONEY':
      return 'exact decimal numbers (money, scores)';
    case 'FLOAT':
    case 'DOUBLE':
    case 'REAL':
      return 'approximate decimal numbers';
    case 'BOOLEAN':
    case 'BOOL':
      return 'true / false';
    case 'DATE':
      return 'calendar date';
    case 'DATETIME':
    case 'TIMESTAMP':
    case 'TIMESTAMPTZ':
      return 'date and time';
    case 'TIME':
    case 'TIMETZ':
      return 'time of day';
    case 'TEXT':
    case 'TINYTEXT':
    case 'MEDIUMTEXT':
    case 'LONGTEXT':
    case 'CLOB':
      return 'long text';
    case 'VARCHAR':
    case 'CHAR':
    case 'CHARACTER':
      return 'text with a length limit';
    case 'JSON':
    case 'JSONB':
      return 'JSON document';
    case 'ENUM':
    case 'SET':
      return 'one of a fixed set of values';
    case 'BLOB':
    case 'BINARY':
    case 'VARBINARY':
    case 'BYTEA':
      return 'binary data';
    default:
      return '';
  }
}

/// 中文类型名；英文模式返回原始 SQL 类型。
String columnTypeLabel(String sqlType) {
  if (!_chinese) return sqlType;
  final family = _typeFamily(sqlType);
  switch (family) {
    case 'TINYINT':
      return sqlType.toUpperCase().contains('(1)') ? '布尔' : '整数';
    case 'SMALLINT':
    case 'MEDIUMINT':
    case 'INT':
    case 'INTEGER':
      return '整数';
    case 'BIGINT':
      return '大整数';
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
    case 'JSON':
    case 'JSONB':
      return 'JSON 数据';
    case 'ENUM':
    case 'SET':
      return '枚举';
    case 'BLOB':
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

/// 下拉菜单里的类型标签：中文名 + 括号 SQL token；英文模式只显示 SQL 类型。
///
/// 未知类型（用户手输的自定义类型）直接返回原文，避免出现「FOO（FOO）」。
String columnTypeMenuLabel(String sqlType) {
  if (!_chinese) return sqlType;
  final label = columnTypeLabel(sqlType);
  if (label == sqlType) return sqlType;
  return label + '（' + sqlType + '）';
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
  final label = columnTypeLabel(sqlType);
  final head = label == sqlType ? sqlType : label + '（' + sqlType + '）';
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
  final label = columnTypeLabel(sqlType);
  return label == sqlType ? sqlType : label + '（' + sqlType + '）';
}

/// 便于在无 BuildContext 的纯逻辑里按当前语言取文案（测试用）。
String pickTypeText(String zh, String en) => pickText(zh, en);
