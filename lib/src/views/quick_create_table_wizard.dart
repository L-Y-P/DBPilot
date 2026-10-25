import 'dart:async';

import 'package:flutter/material.dart' hide Text, Tooltip;

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../i18n_literals.dart';
import '../import_rules.dart';
import '../notice.dart';
import '../sqlite_sources.dart';
import '../text.dart';
import '../theme.dart';
import '../type_labels.dart';
import '../widgets.dart';
import 'relation_designer.dart';

/// 快速建表向导（第 50 轮）。
///
/// 一次数据文件导入往往就是一次「建表 + 灌数据」：用户要先在设计器里手工敲完
/// 所有字段，再去导入向导里逐列映射一遍。这个向导把两件事合并成一条流水线：
///
///   1. 选择文件（CSV / Excel / JSON / …，复用既有的导入管线，不生成 SQL）；
///   2. 每个工作表一张表：表名、表头、跳过行数、字段名/类型/主键/可空，类型来自
///      importPreview 的 schema（Rust 按真实单元格类型推断，Dart 侧有兜底推断）；
///   3. 先 createTable 建好空表，再嵌入 E-R 关系设计器建立关联（没有主键的表
///      可以一键补自增 id，也可以返回字段步骤修改）；
///   4. 最后逐表 importExecuteStart 导入数据，进度可取消，失败保留已建表。
///
/// 第 51 轮起「建立关联」提前到导入之前：外键要求列已经存在，先建表再连关系，
/// 用户就不会在导入完数据后才发现某张表缺主键、需要推倒重来。
///
/// 规格见 docs/IMPORT_EXCEL_ER_DESIGN.md §4。
Future<bool> showQuickCreateTableWizard(
  BuildContext context, {
  required String database,
  required Notice notice,
  // 预置待分析的文件（测试与未来的文件关联入口用）；正常入口从选择文件开始。
  String? initialPath,
  // 测试/自动化用的状态句柄，可抓取 [QuickCreateTableWizardState] 驱动步骤。
  GlobalKey<QuickCreateTableWizardState>? stateKey,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => QuickCreateTableWizard(
      key: stateKey,
      database: database,
      notice: notice,
      initialPath: initialPath,
    ),
  ).then((value) => value ?? false);
}

/// 四个步骤的标题（步骤条与页脚提示共用）。
///
/// 顺序是「选择文件 → 工作表与字段 → 建立关联 → 导入数据」：表在离开字段步骤
/// 时就创建好，关系画布操作的是真实存在的空表；导入放在最后，避免用户建完
/// 关系后才发现主键/字段要改。
///
/// 标题在 build 时按当前语言选（pickText），不依赖 i18n_en 映射表——向导是
/// 自绘 Dialog，语言切换时由 ValueListenableBuilder 重建，标题会立刻跟着变。
const int kQuickCreateStepCount = 4;

const List<String> _stepTitlesZh = <String>[
  '选择文件',
  '工作表与字段',
  '建立关联',
  '导入数据',
];

const List<String> _stepTitlesEn = <String>[
  'Choose file',
  'Worksheets and columns',
  'Connect tables',
  'Import data',
];

String quickCreateStepTitle(int index) {
  if (index < 0 || index >= kQuickCreateStepCount) return '';
  return pickText(_stepTitlesZh[index], _stepTitlesEn[index]);
}

// =========================================================================
// 纯逻辑：类型映射 / 标识符清洗 / 去重 / 推断兜底 / 载荷构造
// 全部是顶层函数或纯数据类，测试可以在没有 FFI 的情况下直接覆盖。
// =========================================================================

/// preview schema 里的中性类型名（见设计文档 §2.3）。
const List<String> kQuickInferredTypes = <String>[
  'integer',
  'bigint',
  'decimal',
  'float',
  'boolean',
  'date',
  'datetime',
  'time',
  'text',
];

/// 是否是整数族的推断类型。
bool isIntegerInferred(String inferred) =>
    inferred == 'integer' || inferred == 'bigint';

/// 一个 SQL 类型是否属于整数族（决定主键能否自增）。
bool looksIntegerType(String sqlType) {
  final type = sqlType.trim().toUpperCase();
  return const <String>{
    'INT',
    'INTEGER',
    'INT UNSIGNED',
    'BIGINT',
    'BIGINT UNSIGNED',
    'SMALLINT',
    'TINYINT',
  }.contains(type);
}

/// §4.3 的类型映射：Rust 推断出的中性类型 → 各驱动的 SQL 类型。
///
/// [maxLength] 是 schema 的 max_length（文本列的最大字符数）：MySQL/PostgreSQL
/// 在 0 < maxLength <= 200 时生成 VARCHAR(n)，其余情况用 TEXT。
String sqlTypeFor(String inferred, String driver, {int maxLength = 0}) {
  final mysql = driver == 'mysql';
  final postgres = driver == 'postgres';
  switch (inferred) {
    case 'integer':
      return mysql ? 'INT' : 'INTEGER';
    case 'bigint':
      return 'BIGINT';
    case 'decimal':
      return mysql
          ? 'DECIMAL(18,2)'
          : (postgres ? 'NUMERIC(18,2)' : 'NUMERIC');
    case 'float':
      return mysql ? 'DOUBLE' : (postgres ? 'DOUBLE PRECISION' : 'REAL');
    case 'boolean':
      // MySQL 没有真正的 BOOLEAN 存储：TINYINT(1) 是约定；SQLite 也用整数。
      return mysql ? 'TINYINT(1)' : (postgres ? 'BOOLEAN' : 'INTEGER');
    case 'date':
      return mysql ? 'DATE' : (postgres ? 'DATE' : 'TEXT');
    case 'datetime':
      return mysql ? 'DATETIME' : (postgres ? 'TIMESTAMP' : 'TEXT');
    case 'time':
      return mysql ? 'TIME' : (postgres ? 'TIME' : 'TEXT');
    case 'text':
    default:
      if ((mysql || postgres) && maxLength > 0 && maxLength <= 200) {
        return 'VARCHAR($maxLength)';
      }
      return 'TEXT';
  }
}

/// 主键整数列的建表类型。
///
/// 自增是 CreateTableSpec 的 auto_increment 标志，由 DDL 生成器翻译成
/// MySQL AUTO_INCREMENT / PostgreSQL GENERATED ... AS IDENTITY / SQLite
/// INTEGER PRIMARY KEY AUTOINCREMENT；这里只需要给整数类型本身。
String pkColumnTypeFor(String driver) => driver == 'sqlite' ? 'INTEGER' : 'BIGINT';

/// 类型下拉里给用户的常用类型：九种推断类型映射后的 SQL 类型（去重）+ 主键类型。
///
/// 复用了 db_options.dart 按驱动给常用类型的思路，但只暴露与本流程相关的类型，
/// 避免每列下拉几十项。
List<String> quickTypeChoices(String driver) {
  final choices = <String>[];
  for (final inferred in kQuickInferredTypes) {
    final sql = sqlTypeFor(inferred, driver);
    if (!choices.contains(sql)) choices.add(sql);
  }
  final pk = pkColumnTypeFor(driver);
  if (!choices.contains(pk)) choices.insert(0, pk);
  // 文本列的常用变体：schema 给出 VARCHAR(n) 时用户也能手动改回来。
  final varchar = driver == 'sqlite' ? 'TEXT' : 'VARCHAR(255)';
  if (!choices.contains(varchar)) choices.add(varchar);
  return choices;
}

/// 单个字符是否允许出现在标识符里。
///
/// 保留 ASCII 字母/数字/下划线，以及中日韩文字；其余（空白、引号、括号、控制
/// 字符……）一律替换成下划线。DDL 会 quote 标识符，所以中文可以原样保留。
bool _isIdentifierRune(int rune) {
  if (rune == 0x5f) return true; // _
  if (rune >= 0x30 && rune <= 0x39) return true; // 0-9
  if (rune >= 0x41 && rune <= 0x5a) return true; // A-Z
  if (rune >= 0x61 && rune <= 0x7a) return true; // a-z
  if (rune >= 0x3040 && rune <= 0x30ff) return true; // 日文假名
  if (rune >= 0x3400 && rune <= 0x4dbf) return true; // CJK 扩展 A
  if (rune >= 0x4e00 && rune <= 0x9fff) return true; // CJK 基本区
  if (rune >= 0xf900 && rune <= 0xfaff) return true; // CJK 兼容表意
  if (rune >= 0xac00 && rune <= 0xd7af) return true; // 谚文
  if (rune >= 0x20000 && rune <= 0x2ffff) return true; // CJK 扩展 B+
  return false;
}

/// 表名/字段名清洗：非法字符 → 下划线，压缩连续下划线，去首尾下划线。
///
/// 首字符是数字时补 t_ 前缀（各驱动对未加引号的数字开头标识符处理不一致，
/// 补前缀让建表结果可预期）。清洗后为空时使用 [fallback]。
String sanitizeIdentifier(String raw, {String fallback = 'table'}) {
  final buffer = StringBuffer();
  for (final rune in raw.runes) {
    buffer.write(_isIdentifierRune(rune) ? String.fromCharCode(rune) : '_');
  }
  var name = buffer.toString().replaceAll(RegExp(r'_+'), '_');
  name = name.replaceAll(RegExp(r'^_+|_+$'), '');
  if (name.isEmpty) name = fallback;
  final first = name.codeUnitAt(0);
  if (first >= 0x30 && first <= 0x39) name = 't_$name';
  return name;
}

/// 在 [used] 里给 [base] 找一个不冲突的名字：base、base_2、base_3……
String uniqueName(String base, Set<String> used) {
  if (!used.contains(base)) return base;
  for (var suffix = 2; suffix < 100000; suffix++) {
    final candidate = '${base}_$suffix';
    if (!used.contains(candidate)) return candidate;
  }
  return '${base}_${used.length + 1}';
}

/// 文件路径的「去扩展名」名字（不含目录）。
String fileStemOf(String path) {
  final name = baseNameOf(path);
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// 默认表名：多工作表按工作表名，单表/非 Excel 文件按文件名去扩展名。
String defaultTableNameFor(
  String path, {
  String sheet = '',
  bool multiSheet = false,
}) {
  if (multiSheet && sheet.trim().isNotEmpty) {
    return sanitizeIdentifier(sheet, fallback: 'sheet');
  }
  return sanitizeIdentifier(fileStemOf(path), fallback: 'imported_table');
}

final RegExp _datePattern = RegExp(r'^\d{4}-\d{1,2}-\d{1,2}$');
final RegExp _dateTimePattern =
    RegExp(r'^\d{4}-\d{1,2}-\d{1,2}[ T]\d{1,2}:\d{2}(:\d{2})?$');
final RegExp _timePattern = RegExp(r'^\d{1,2}:\d{2}(:\d{2})?$');
const Set<String> _trueTokens = <String>{'true', '是', 'yes', 'y', 't', 'on'};
const Set<String> _falseTokens = <String>{'false', '否', 'no', 'n', 'f', 'off'};

/// Dart 兜底推断：Rust 的 preview schema 缺失时（旧版 dylib）按采样值猜类型。
///
/// 规则与 §2.3 对齐：忽略空值；全部整数且在 i32 内 → integer，否则 bigint；
/// 有小数 → decimal；≥90% 布尔 → boolean；日期/时间按格式；其余 text。
String inferTypeFromValues(Iterable<Object?> rawValues) {
  final values = rawValues
      .where((value) =>
          value != null && !(value is String && value.trim().isEmpty))
      .toList();
  if (values.isEmpty) return 'text';
  var boolCount = 0;
  var intCount = 0;
  var numberCount = 0;
  var dateCount = 0;
  var dateTimeCount = 0;
  var timeCount = 0;
  var intsFit = true;
  void trackInt(int value) {
    if (value < -2147483648 || value > 2147483647) intsFit = false;
  }

  for (final value in values) {
    if (value is bool) {
      boolCount++;
      continue;
    }
    if (value is int) {
      intCount++;
      numberCount++;
      trackInt(value);
      continue;
    }
    if (value is double) {
      numberCount++;
      if (value == value.roundToDouble()) {
        intCount++;
        trackInt(value.toInt());
      }
      continue;
    }
    final text = value.toString().trim();
    final lower = text.toLowerCase();
    if (_trueTokens.contains(lower) || _falseTokens.contains(lower)) {
      boolCount++;
      continue;
    }
    final intValue = int.tryParse(text);
    if (intValue != null) {
      intCount++;
      numberCount++;
      trackInt(intValue);
      continue;
    }
    if (double.tryParse(text) != null) {
      numberCount++;
      continue;
    }
    if (_dateTimePattern.hasMatch(text)) {
      dateTimeCount++;
      continue;
    }
    if (_datePattern.hasMatch(text)) {
      dateCount++;
      continue;
    }
    if (_timePattern.hasMatch(text)) {
      timeCount++;
      continue;
    }
  }
  final total = values.length;
  if (boolCount > 0 && intCount == 0 && boolCount / total >= 0.9) {
    return 'boolean';
  }
  if (numberCount / total >= 0.99) {
    if (intCount == total) return intsFit ? 'integer' : 'bigint';
    return 'decimal';
  }
  if (dateTimeCount / total >= 0.99) return 'datetime';
  if (dateCount / total >= 0.99) return 'date';
  if (timeCount / total >= 0.99) return 'time';
  return 'text';
}

/// 快速建表里的一列（目标列 + 源列信息 + 推断结果）。
class QuickColumn {
  QuickColumn({
    required this.name,
    required this.sourceLabel,
    required this.sourceIndex,
    required this.inferred,
    required this.sqlType,
    this.nullable = true,
    this.primary = false,
    this.sample = '',
    this.generated = false,
  });

  /// 目标表字段名（用户可改）。
  String name;

  /// 源列名：表头存在时是表头原文（按列名映射的来源），否则是位置标签。
  String sourceLabel;

  /// 源列位置（0-based，按位置映射时使用）。
  final int sourceIndex;

  /// 中性推断类型（integer/bigint/...）。
  String inferred;

  /// 当前选中的 SQL 类型（用户可改）。
  String sqlType;

  bool nullable;
  bool primary;

  /// 前几个示例值的展示串。
  String sample;

  /// 该列不是从源文件映射来的（「添加自增 id 主键」生成的列）。
  ///
  /// generated 列只参与 CREATE TABLE（整数主键自增），不参与导入 mapping，
  /// 因此它的值由数据库生成；它也没有源列（[sourceIndex] 为 -1）。
  bool generated;

  /// 是否参与导入列映射（生成列 / 没有源位置的列不映射）。
  bool get importable => !generated && sourceIndex >= 0;
}

/// 一张待创建的表（一个工作表 / 一个非 Excel 文件）。
class QuickTablePlan {
  QuickTablePlan({
    required this.name,
    required this.sheet,
    required this.header,
    this.skipRows = 0,
    List<QuickColumn>? columns,
  }) : columns = columns ?? <QuickColumn>[];

  /// 目标表名。
  String name;

  /// 工作表名；非 Excel 文件为空串（不发送 sheet 参数）。
  final String sheet;

  /// 第一条记录是否是表头。
  bool header;

  /// 跳过工作表最前面的 N 行（Excel 的「标题行」场景）。
  int skipRows;

  List<QuickColumn> columns;

  bool get isWorkbook => sheet.isNotEmpty;
}

/// 表里是否已经有一个主键列。
bool planHasPrimary(QuickTablePlan plan) =>
    plan.columns.any((column) => column.primary);

/// 给表加一个「数据库自动生成」的整数自增主键 id（放在第一列）。
///
/// 用户场景：源文件里没有主键（或用户取消了原来的主键）时，没有主键的表不能
/// 作为外键的被引用表。这个按钮让用户一键补一个自增 id，同时取消原有主键，
/// 保证每张表最多一个主键。
///
/// 返回插入的列，方便调用方/测试断言。生成列的名字默认 id，与现有字段重名时
/// 自动退到 id_2、id_3……
QuickColumn addGeneratedPrimaryKey(QuickTablePlan plan, String driver) {
  for (final column in plan.columns) {
    column.primary = false;
  }
  final usedNames = <String>{
    for (final column in plan.columns) column.name.trim().toLowerCase(),
  };
  final column = QuickColumn(
    name: uniqueName('id', usedNames),
    sourceLabel: '',
    sourceIndex: -1,
    inferred: 'integer',
    sqlType: pkColumnTypeFor(driver),
    nullable: false,
    primary: true,
    sample: pickText('（数据库自动生成）', '(generated by the database)'),
    generated: true,
  );
  plan.columns.insert(0, column);
  return column;
}

/// schema 缺失时，从 preview 的记录回退构造列。
List<QuickColumn> _columnsFromRecords(Json preview, String driver) {
  final header = (preview['header'] as List? ?? const <dynamic>[])
      .map((e) => e.toString())
      .toList();
  final records = (preview['records'] as List? ?? const <dynamic>[])
      .map((e) => asJsonMap(e))
      .where((record) => record['header'] != true && record['values'] != null)
      .toList();
  final sample = records.isNotEmpty ? records.first : <String, dynamic>{};
  final keyed = (sample['kind'] ?? '') == 'object';
  final fieldCount = header.isNotEmpty
      ? header.length
      : ((sample['field_count'] as num?)?.toInt() ?? 0);
  if (fieldCount <= 0) return <QuickColumn>[];
  final keys = keyed
      ? (sample['keys'] as List? ?? const <dynamic>[])
          .map((e) => e.toString())
          .toList()
      : const <String>[];
  final columns = <QuickColumn>[];
  final usedNames = <String>{};
  for (var index = 0; index < fieldCount; index++) {
    final fallbackName = 'column_${index + 1}';
    final rawName = header.isNotEmpty
        ? header[index]
        : (keyed && index < keys.length ? keys[index] : fallbackName);
    var name = sanitizeIdentifier(rawName, fallback: fallbackName);
    name = uniqueName(name, usedNames);
    usedNames.add(name);
    final values = <Object?>[];
    for (final record in records) {
      final raw = record['values'];
      if (raw is List) {
        values.add(index < raw.length ? raw[index] : null);
      } else if (raw is Map) {
        values.add(raw[rawName]);
      }
    }
    final inferred = inferTypeFromValues(values);
    final nonEmptySamples = values
        .where((value) =>
            value != null && !(value is String && value.trim().isEmpty))
        .take(3)
        .map((value) => value.toString())
        .toList();
    columns.add(QuickColumn(
      name: name,
      sourceLabel: rawName,
      sourceIndex: index,
      inferred: inferred,
      sqlType: sqlTypeFor(inferred, driver),
      nullable: true,
      primary: index == 0 && rawName.toLowerCase() == 'id',
      sample: nonEmptySamples.join(', '),
    ));
  }
  return columns;
}

/// 从 importPreview 的返回值构造列。
///
/// 优先使用 Rust 的 schema（真实单元格类型 + primary_candidate + max_length）；
/// 旧 dylib 没有 schema 时退回 [inferTypeFromValues]，保证向导仍可用。
List<QuickColumn> columnsFromPreview(Json preview, {required String driver}) {
  final header = (preview['header'] as List? ?? const <dynamic>[])
      .map((e) => e.toString())
      .toList();
  final schema = asJsonMap(preview['schema']);
  final rawColumns =
      (schema['columns'] as List? ?? const <dynamic>[]).map(asJsonMap).toList();
  if (rawColumns.isEmpty) return _columnsFromRecords(preview, driver);

  final columns = <QuickColumn>[];
  final usedNames = <String>{};
  var primaryTaken = false;
  for (var index = 0; index < rawColumns.length; index++) {
    final raw = rawColumns[index];
    final sourceIndex = (raw['source'] as num?)?.toInt() ?? index;
    final schemaName = (raw['name'] ?? '').toString();
    final fallbackName = 'column_${index + 1}';
    var name = sanitizeIdentifier(
      schemaName.isEmpty ? fallbackName : schemaName,
      fallback: fallbackName,
    );
    name = uniqueName(name, usedNames);
    usedNames.add(name);
    final inferred = (raw['type'] ?? 'text').toString();
    final maxLength = (raw['max_length'] as num?)?.toInt() ?? 0;
    final candidate = raw['primary_candidate'] == true && !primaryTaken;
    if (candidate) primaryTaken = true;
    final samples =
        (raw['samples'] as List? ?? const <dynamic>[]).take(3).toList();
    columns.add(QuickColumn(
      name: name,
      sourceLabel: header.isNotEmpty && sourceIndex < header.length
          ? header[sourceIndex]
          : (schemaName.isEmpty ? name : schemaName),
      sourceIndex: sourceIndex,
      inferred: inferred,
      sqlType: sqlTypeFor(inferred, driver, maxLength: maxLength),
      nullable: raw['nullable'] != false,
      primary: candidate,
      sample: samples.map((e) => e.toString()).join(', '),
    ));
  }
  return columns;
}

/// 构造 preview/validate/execute 的 read 参数：透传 inspect 的规则，覆盖工作表
/// 与跳过行数。非 Excel 文件不发送 sheet 键。
Map<String, dynamic> readParamsFor(
  Json inspectRead, {
  String sheet = '',
  int skipRows = 0,
}) {
  final read = Map<String, dynamic>.from(inspectRead);
  if (sheet.isNotEmpty) read['sheet'] = sheet;
  read['skip_rows'] = skipRows;
  return read;
}

/// 构造 fields 参数：透传 inspect 的字段规则，覆盖表头开关。
Map<String, dynamic> fieldParamsFor(Json inspectFields, {required bool header}) {
  final fields = Map<String, dynamic>.from(inspectFields);
  fields['header'] = header;
  return fields;
}

/// 构造列映射：表头存在时按表头原文映射（keyed），否则按位置映射。
Map<String, dynamic> mappingParamsFor(QuickTablePlan plan) {
  return <String, dynamic>{
    'columns': <Map<String, dynamic>>[
      for (final column in plan.columns)
        // 生成列（自增 id）没有源数据，不进 INSERT；否则数据库自增会被覆盖。
        if (column.name.trim().isNotEmpty && column.importable)
          <String, dynamic>{
            'column': column.name.trim(),
            'source': plan.header && column.sourceLabel.isNotEmpty
                ? column.sourceLabel
                : column.sourceIndex,
          },
    ],
    'ignore_unknown': true,
    'empty_as_null': false,
    'null_tokens': <String>['\\N'],
    'trim_values': true,
  };
}

/// 构造 importExecuteStart 的完整参数（逐表导入）。
Map<String, dynamic> importParamsFor({
  required String path,
  required QuickTablePlan plan,
  required Json inspect,
  required String database,
}) {
  return <String, dynamic>{
    'path': path,
    'read': readParamsFor(
      asJsonMap(inspect['read']),
      sheet: plan.sheet,
      skipRows: plan.skipRows,
    ),
    'fields': fieldParamsFor(
      asJsonMap(inspect['fields']),
      header: plan.header,
    ),
    'mapping': mappingParamsFor(plan),
    'database': database,
    'table': plan.name,
    'options': <String, dynamic>{
      'batch_size': 500,
      'on_error': 'stop',
      'max_issues': 100,
    },
  };
}

/// 主键列的建表类型：整数主键用各驱动的整数自增类型，文本主键退到可索引类型。
String primarySqlTypeFor(QuickColumn column, String driver) {
  if (looksIntegerType(column.sqlType)) return pkColumnTypeFor(driver);
  final upper = column.sqlType.toUpperCase();
  if (driver != 'sqlite' && upper.contains('TEXT')) return 'VARCHAR(255)';
  return column.sqlType;
}

/// 构造 createTable 的 body（CreateTableSpec 的 JSON 形态）。
///
/// 自增只对整数主键打开：MySQL → AUTO_INCREMENT，PostgreSQL → IDENTITY，
/// SQLite → INTEGER PRIMARY KEY AUTOINCREMENT，都由 Rust 的 DDL 生成器负责。
Map<String, dynamic> createTableBodyFor(QuickTablePlan plan, String driver) {
  return <String, dynamic>{
    'name': plan.name.trim(),
    'columns': <Map<String, dynamic>>[
      for (final column in plan.columns)
        if (column.name.trim().isNotEmpty)
          <String, dynamic>{
            'name': column.name.trim(),
            'type': column.primary
                ? primarySqlTypeFor(column, driver)
                : column.sqlType,
            'nullable': column.primary ? false : column.nullable,
            'primary': column.primary,
            'auto_increment':
                column.primary && looksIntegerType(column.sqlType),
          },
    ],
  };
}

bool isValidQuickIdentifier(String name) {
  if (name.isEmpty) return false;
  return RegExp(r'^[A-Za-z0-9_\u3400-\u9fff]+$').hasMatch(name);
}

/// 校验整组待建表；返回第一条错误，全部合法时返回 null。
///
/// [existingTables] 是数据库里已有表的**小写**名字集合（避免重名建表失败）。
String? validatePlans(
  List<QuickTablePlan> plans, {
  Set<String> existingTables = const <String>{},
}) {
  if (plans.isEmpty) {
    return pickText('请至少选择一个工作表', 'Select at least one worksheet');
  }
  final names = <String>{};
  for (final plan in plans) {
    final name = plan.name.trim();
    if (name.isEmpty) {
      return pickText('表名不能为空', 'The table name cannot be empty');
    }
    if (!isValidQuickIdentifier(name)) {
      return pickText(
        '表名 $name 不合法：只能包含字母、数字、中文和下划线',
        'Invalid table name $name: use letters, digits, Chinese characters and underscores only',
      );
    }
    final lower = name.toLowerCase();
    if (existingTables.contains(lower)) {
      return pickText(
        '表 $name 已存在，请换一个表名',
        'Table $name already exists; choose another name',
      );
    }
    if (!names.add(lower)) {
      return pickText('表名 $name 重复', 'Duplicate table name $name');
    }
    if (plan.columns.isEmpty) {
      return pickText(
        '表 $name 至少需要一个字段',
        'Table $name needs at least one column',
      );
    }
    if (plan.columns.where((c) => c.primary).length > 1) {
      return pickText(
        '表 $name 只能有一个主键',
        'Table $name can have only one primary key',
      );
    }
    final columnNames = <String>{};
    for (final column in plan.columns) {
      final columnName = column.name.trim();
      if (columnName.isEmpty) {
        return pickText(
          '表 $name 有字段名为空',
          'Table $name has a column with an empty name',
        );
      }
      if (!isValidQuickIdentifier(columnName)) {
        return pickText(
          '字段名 $columnName 不合法',
          'Invalid column name $columnName',
        );
      }
      if (!columnNames.add(columnName.toLowerCase())) {
        return pickText(
          '表 $name 的字段名 $columnName 重复',
          'Table $name has duplicate column name $columnName',
        );
      }
    }
  }
  return null;
}


/// E-R 画布最多同时容纳的表数（与 RelationDesigner 的 maxTables 对齐）。
const int kRelationSeedLimit = 10;

/// 从已创建的表里挑出要带进 E-R 画布的种子（最多 [limit] 张）。
///
/// 多出来的表不画在画布上，但用户仍可从数据库页的「关系图」入口再添加，
/// 所以这里只截断、不丢数据。
List<String> relationSeedTables(
  List<String> createdTables, {
  int limit = kRelationSeedLimit,
}) {
  if (limit <= 0) return const <String>[];
  return createdTables.take(limit).toList();
}

/// 种子被截断时的提示；没有超出时返回 null。
String? relationSeedWarning(
  int createdCount, {
  int limit = kRelationSeedLimit,
}) {
  if (createdCount <= limit) return null;
  return pickText(
    '本次创建了 $createdCount 张表，关系图最多同时显示 $limit 张；'
    '其余表可以在数据库页的「关系图」里继续添加。',
    'Created $createdCount tables; the relationship canvas shows up to '
    '$limit at once. Add the rest later from Relationships on the database '
    'page.',
  );
}

// =========================================================================
// 运行期模型
// =========================================================================

/// 单张表的导入状态（建表在字段步骤完成，这里只跟踪导入）。
enum _RunStatus { idle, importing, done, failed }

String _statusLabel(_RunStatus status) {
  return switch (status) {
    _RunStatus.idle => pickText('待导入', 'Pending'),
    _RunStatus.importing => pickText('导入中', 'Importing'),
    _RunStatus.done => pickText('完成', 'Done'),
    _RunStatus.failed => pickText('失败', 'Failed'),
  };
}

PillTone _statusTone(_RunStatus status) {
  return switch (status) {
    _RunStatus.idle => PillTone.neutral,
    _RunStatus.importing => PillTone.info,
    _RunStatus.done => PillTone.ok,
    _RunStatus.failed => PillTone.danger,
  };
}

/// 向导内部的一张表表单：纯数据计划 + 输入控制器 + 执行进度。
class _TableForm {
  _TableForm(this.plan)
      : nameCtrl = TextEditingController(text: plan.name),
        skipCtrl = TextEditingController(text: '${plan.skipRows}'),
        header = plan.header {
    rebuildColumnControllers();
  }

  final QuickTablePlan plan;
  final TextEditingController nameCtrl;
  final TextEditingController skipCtrl;
  bool header;
  List<TextEditingController> columnCtrls = <TextEditingController>[];

  bool created = false;
  bool imported = false;
  int rowsInserted = 0;
  int rowsFailed = 0;
  _RunStatus status = _RunStatus.idle;
  String? error;

  void rebuildColumnControllers() {
    for (final controller in columnCtrls) {
      controller.dispose();
    }
    columnCtrls = <TextEditingController>[
      for (final column in plan.columns)
        TextEditingController(text: column.name),
    ];
  }

  void dispose() {
    nameCtrl.dispose();
    skipCtrl.dispose();
    for (final controller in columnCtrls) {
      controller.dispose();
    }
    columnCtrls = <TextEditingController>[];
  }
}


// =========================================================================
// 向导 widget
// =========================================================================

class QuickCreateTableWizard extends StatefulWidget {
  const QuickCreateTableWizard({
    super.key,
    required this.database,
    required this.notice,
    this.initialPath,
  });

  final String database;
  final Notice notice;

  /// 预先载入的文件路径（测试与文件关联入口用；正常流程从选择文件开始）。
  final String? initialPath;

  @override
  State<QuickCreateTableWizard> createState() => QuickCreateTableWizardState();
}

class QuickCreateTableWizardState extends State<QuickCreateTableWizard> {
  int _step = 0;
  bool _busy = false;
  String? _error;

  String? _path;
  Json? _inspect;
  String _format = '';
  bool _isWorkbook = false;
  List<String> _sheets = <String>[];
  bool _allSheets = true;
  final Set<String> _selectedSheets = <String>{};

  List<_TableForm> _forms = <_TableForm>[];
  Set<String> _existingTables = <String>{};

  bool _executing = false;
  bool _importsDone = false;
  Json? _jobStatus;
  String? _currentJobId;
  int _currentFormIndex = -1;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialPath;
    if (initial != null && initial.trim().isNotEmpty) {
      // 预置文件只影响首屏，后续行为与手工选择完全一致。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadFile(initial.trim());
      });
    }
  }

  @override
  void dispose() {
    _disposeForms();
    super.dispose();
  }

  void _disposeForms() {
    for (final form in _forms) {
      form.dispose();
    }
    _forms = <_TableForm>[];
  }

  // ------------------------------------------------- 测试 / 自动化驱动入口
  //
  // 原生文件选择器无法在 widget 测试里点击，截图/自动化工具也不方便每次都
  // 走原生 picker。下面这组入口与真实用户点击完全共用同一套状态机：
  // 注入路径 == 选择文件；advanceForTest == 点页脚主按钮。
  // 产品代码不调用它们。

  /// 跳过原生文件选择器，按已经选好的路径加载文件（等价于用户选完文件）。
  @visibleForTesting
  Future<void> loadFileForTest(String path) => _loadFile(path);

  /// 等价于点击页脚当前的主按钮：
  /// 0→1（分析文件）、1→2（建空表并进入建立关联）、2→3（进入导入数据）、
  /// 3→执行/重试导入。
  @visibleForTesting
  Future<void> advanceForTest() => _onPrimary();

  /// 当前步骤（0-based），供测试断言。
  @visibleForTesting
  int get stepForTest => _step;

  /// 是否正在分析/执行（测试等待用）。
  @visibleForTesting
  bool get busyForTest => _busy || _executing;

  /// 当前计划创建的表名（第 2 步起可用）。
  @visibleForTesting
  List<String> get plannedTableNamesForTest =>
      <String>[for (final form in _forms) form.plan.name];

  /// 已创建的表（第 3 步后可用）。
  @visibleForTesting
  List<String> get createdTablesForTest => _createdTables;

  /// 是否全部表都已导入完成。
  @visibleForTesting
  bool get importsDoneForTest => _importsDone;

  /// 关系步骤实际会带进画布的种子表（最多 [kRelationSeedLimit] 张）。
  @visibleForTesting
  List<String> get relationSeedTablesForTest =>
      relationSeedTables(_createdTables);

  /// 当前每张表的计划（字段/主键/generated 等），测试断言用。
  @visibleForTesting
  List<QuickTablePlan> get plansForTest =>
      <QuickTablePlan>[for (final form in _forms) form.plan];

  /// 是否所有表都已创建（第 1→2 步之后应为 true）。
  @visibleForTesting
  bool get allTablesCreatedForTest => _allTablesCreated;

  /// 已创建但没有主键的表名。
  @visibleForTesting
  List<String> get createdTablesWithoutPrimaryForTest =>
      _createdTablesWithoutPrimary;

  /// 等价于点某张表卡片上的「添加自增 id 主键」。
  @visibleForTesting
  void addGeneratedPrimaryKeyForTest(int index) =>
      _addGeneratedPrimaryKey(index);

  /// 等价于点「返回工作表与字段」（画布上方的提示按钮/设计器错误对话框）。
  @visibleForTesting
  Future<void> returnToFieldsForTest() => _returnToFields();

  /// 当前顶部错误条文本（测试断言建表/导入失败用）。
  @visibleForTesting
  String? get errorForTest => _error;

  /// 当前字段步骤的校验结果（测试诊断「下一步按钮为何不可点」用）。
  @visibleForTesting
  String? get validationErrorForTest => _validationError();

  String get _driver => AppState.instance.driver;

  String get _fileName =>
      (_inspect?['name'] ?? (_path == null ? '' : baseNameOf(_path!)))
          .toString();

  static const Set<String> _workbookFormats = <String>{
    'excel',
    'xlsx',
    'xls',
    'xlsb',
    'ods',
  };

  bool get _multiSheet => _isWorkbook && _sheets.length > 1;

  bool get _allImported =>
      _forms.isNotEmpty && _forms.every((form) => form.imported);

  List<String> get _createdTables => _forms
      .where((form) => form.created)
      .map((form) => form.plan.name)
      .toList();

  /// 还有「没建表/没导入且没有已写入行」的表需要执行。
  ///
  /// 首次进入执行步骤时全部表单都满足（状态 idle、行数 0），这就是主按钮显示
  /// 「创建表并导入」的依据；导入中断后它也覆盖可安全重试的表。
  bool get _hasPendingWork =>
      _forms.any((form) => !form.imported && form.rowsInserted == 0);

  /// 失败且可以安全重试的表（已经写入过部分行的表不在此列：重试会重复导入）。
  bool get _hasRetryableFailure => _forms.any((form) =>
      !form.imported &&
      form.status == _RunStatus.failed &&
      form.rowsInserted == 0);

  /// 还没有主键的表（第 1 步卡片/全局提示用）。
  List<_TableForm> get _formsWithoutPrimary =>
      _forms.where((form) => !planHasPrimary(form.plan)).toList();

  /// 还没有主键的表名。
  List<String> get _tableNamesWithoutPrimary =>
      <String>[for (final form in _formsWithoutPrimary) form.plan.name];

  /// 已经创建、但没有主键的表名（关系画布上方提示用）。
  List<String> get _createdTablesWithoutPrimary => <String>[
        for (final form in _forms)
          if (form.created && !planHasPrimary(form.plan)) form.plan.name,
      ];

  /// 是否所有表都已经建好（第 1→2 步之后应为 true）。
  bool get _allTablesCreated =>
      _forms.isNotEmpty && _forms.every((form) => form.created);

  List<String> _chosenSheets() {
    if (!_isWorkbook || _sheets.isEmpty) return const <String>[''];
    if (_sheets.length == 1) return <String>[_sheets.first];
    if (_allSheets) return List<String>.from(_sheets);
    return _sheets.where(_selectedSheets.contains).toList();
  }

  String _formatLabel(String format) {
    return switch (format) {
      'delimited' => '分隔文本（CSV / TSV / 自定义分隔符）',
      'json_array' => 'JSON 数组',
      'json_lines' => 'JSON Lines（每行一个 JSON）',
      'xml' => 'XML（<rows> / <row> / <col>）',
      'html' => 'HTML 表格（<table>）',
      'excel' => 'Excel（SpreadsheetML .xls）',
      'xlsx' => 'Excel 工作簿（.xlsx）',
      'xls' => 'Excel 97-2003（.xls）',
      'xlsb' => 'Excel 二进制工作簿（.xlsb）',
      'ods' => 'OpenDocument 表格（.ods）',
      'markdown' => 'Markdown 表格（| a | b |）',
      _ => format.isEmpty ? '未知' : format,
    };
  }

  // ------------------------------------------------------------- file IO

  Future<void> _pickFile() async {
    if (_executing) return;
    try {
      final path = await pickDataFile(
        title: pickText('选择要用于建表的数据文件', 'Choose a data file to create tables from'),
      );
      if (path == null || path.trim().isEmpty) return;
      await _loadFile(path.trim());
    } catch (error) {
      if (mounted) setState(() => _error = describeDbError(error));
    }
  }

  Future<void> _loadFile(String path) async {
    setState(() {
      _busy = true;
      _error = null;
      _path = null;
      _inspect = null;
      _format = '';
      _isWorkbook = false;
      _sheets = <String>[];
      _selectedSheets.clear();
      _allSheets = true;
      _step = 0;
      _jobStatus = null;
      _currentJobId = null;
      _importsDone = false;
      _disposeForms();
    });
    try {
      final inspect = await Api.instance.importInspect(path);
      if (!mounted) return;
      final format = (inspect['format'] ?? '').toString();
      final sheets = (inspect['sheets'] as List? ?? const <dynamic>[])
          .map(asJsonMap)
          .where((sheet) => (sheet['name'] ?? '').toString().isNotEmpty)
          .toList();
      final workbook = _workbookFormats.contains(format) && sheets.isNotEmpty;
      setState(() {
        _path = path;
        _inspect = inspect;
        _format = format;
        _isWorkbook = workbook;
        _sheets = <String>[
          for (final sheet in sheets) (sheet['name'] ?? '').toString(),
        ];
        _allSheets = true;
        _selectedSheets
          ..clear()
          ..addAll(_sheets);
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeDbError(error);
      });
    }
  }

  // -------------------------------------------------------- plans (step 2)

  Future<Set<String>> _loadExistingTables() async {
    try {
      final tables = await Api.instance.tables(widget.database);
      return <String>{
        for (final table in tables)
          (table['name'] ?? '').toString().toLowerCase(),
      }..remove('');
    } catch (_) {
      // 表列表拿不到时不做重名校验，真正的错误留给 createTable 报告。
      return <String>{};
    }
  }

  Future<_TableForm> _previewForm(
    String path,
    Json inspect,
    String sheet, {
    required Set<String> usedNames,
  }) async {
    final read = readParamsFor(asJsonMap(inspect['read']), sheet: sheet);
    final header = asJsonMap(inspect['fields'])['header'] == true;
    final fields = fieldParamsFor(asJsonMap(inspect['fields']), header: header);
    final preview = await Api.instance.importPreview(path, <String, dynamic>{
      'read': read,
      'fields': fields,
      'limit': 200,
      'infer': true,
    });
    final defaultName = uniqueName(
      defaultTableNameFor(path, sheet: sheet, multiSheet: _multiSheet),
      usedNames,
    );
    final plan = QuickTablePlan(
      name: defaultName,
      sheet: _isWorkbook ? sheet : '',
      header: header,
      columns: columnsFromPreview(preview, driver: _driver),
    );
    return _TableForm(plan);
  }

  Future<void> _loadPlans() async {
    final path = _path;
    final inspect = _inspect;
    if (path == null || inspect == null) return;
    final sheets = _chosenSheets();
    if (sheets.isEmpty) {
      setState(() =>
          _error = pickText('请至少选择一个工作表', 'Select at least one worksheet'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final existing = await _loadExistingTables();
      final used = <String>{...existing};
      final forms = <_TableForm>[];
      for (final sheet in sheets) {
        final form = await _previewForm(path, inspect, sheet, usedNames: used);
        used.add(form.plan.name.toLowerCase());
        forms.add(form);
      }
      if (!mounted) return;
      _disposeForms();
      setState(() {
        _existingTables = existing;
        _forms = forms;
        _step = 1;
        _busy = false;
        _importsDone = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeDbError(error);
      });
    }
  }

  /// 重新推断一张表的字段（改表头/跳过行数后使用）。
  Future<void> _reinfer(int index) async {
    final path = _path;
    final inspect = _inspect;
    if (path == null || inspect == null || _busy || _executing) return;
    if (index < 0 || index >= _forms.length) return;
    final form = _forms[index];
    _syncForms();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final read = readParamsFor(
        asJsonMap(inspect['read']),
        sheet: form.plan.sheet,
        skipRows: form.plan.skipRows,
      );
      final fields =
          fieldParamsFor(asJsonMap(inspect['fields']), header: form.header);
      final preview = await Api.instance.importPreview(path, <String, dynamic>{
        'read': read,
        'fields': fields,
        'limit': 200,
        'infer': true,
      });
      if (!mounted) return;
      setState(() {
        // 重新推断只替换源数据列；用户手动补的自增 id 主键必须保留，否则
        // 勾选「首行是列名」之类的操作会把刚补的主键悄悄弄丢。
        final generatedColumns =
            form.plan.columns.where((column) => column.generated).toList();
        final reinferred = columnsFromPreview(preview, driver: _driver);
        if (generatedColumns.isNotEmpty) {
          for (final column in reinferred) {
            column.primary = false;
          }
          form.plan.columns = <QuickColumn>[
            ...generatedColumns,
            ...reinferred,
          ];
        } else {
          form.plan.columns = reinferred;
        }
        form.rebuildColumnControllers();
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeDbError(error);
      });
    }
  }

  /// 把输入框内容同步回纯数据计划（校验与构造载荷前调用）。
  void _syncForms() {
    for (final form in _forms) {
      form.plan.name = form.nameCtrl.text.trim();
      form.plan.skipRows = int.tryParse(form.skipCtrl.text.trim()) ?? 0;
      form.plan.header = form.header;
      for (var index = 0;
          index < form.plan.columns.length &&
              index < form.columnCtrls.length;
          index++) {
        form.plan.columns[index].name = form.columnCtrls[index].text.trim();
      }
    }
  }

  String? _validationError() {
    _syncForms();
    return validatePlans(
      <QuickTablePlan>[for (final form in _forms) form.plan],
      existingTables: _existingTables,
    );
  }

  /// 单张表的就地错误（卡片内标红）。
  String? _formError(_TableForm form) {
    final plan = form.plan;
    final name = plan.name.trim();
    if (name.isEmpty) {
      return pickText('表名不能为空', 'The table name cannot be empty');
    }
    if (!isValidQuickIdentifier(name)) {
      return pickText('表名不合法', 'Invalid table name');
    }
    if (_existingTables.contains(name.toLowerCase())) {
      return pickText('表名已存在', 'Table already exists');
    }
    if (plan.columns.any((column) => column.name.trim().isEmpty)) {
      return pickText('有字段名为空', 'A column name is empty');
    }
    final uniqueColumns = plan.columns
        .map((column) => column.name.trim().toLowerCase())
        .toSet()
        .length;
    if (plan.columns.length != uniqueColumns) {
      return pickText('字段名重复', 'Duplicate column names');
    }
    if (plan.columns.where((column) => column.primary).length > 1) {
      return pickText('只能有一个主键', 'Only one primary key is allowed');
    }
    return null;
  }

  /// 第 1 步卡片按钮：给这张表补一个自增 id 主键。
  void _addGeneratedPrimaryKey(int index) {
    if (_busy || _executing) return;
    if (index < 0 || index >= _forms.length) return;
    _syncForms();
    final form = _forms[index];
    addGeneratedPrimaryKey(form.plan, _driver);
    form.rebuildColumnControllers();
    setState(() {});
  }

  /// 第 1 步顶部的「没有主键」提示文案（全部没有 / 部分没有两种说法）。
  String? get _primaryWarningText {
    final missing = _tableNamesWithoutPrimary;
    if (missing.isEmpty) return null;
    if (missing.length == _forms.length) {
      return pickText(
        '所有表都没有主键：只能导入数据，无法建立外键关系；建议先点每张表的「添加自增 id 主键」。',
        'No table has a primary key: data can still be imported, but these tables cannot be referenced by foreign keys. Use "Add auto-increment id as primary key" on each table first.',
      );
    }
    return pickText(
      '以下表没有主键，不能作为外键的被引用表：${missing.join('、')}',
      'These tables have no primary key and cannot be referenced by foreign keys: ${missing.join(', ')}',
    );
  }

  // ------------------------------------------- step 1 → 2：先建空表再连关系

  /// 第 1 步「下一步」：先校验字段，再逐表 createTable 建空表；全部成功才
  /// 进入「建立关联」步骤。
  ///
  /// 建表失败时留在第 1 步，把错误显示在卡片的错误条里；已经建好的表保留，
  /// 再次点「下一步」会跳过它们。
  Future<void> _createTablesAndContinue() async {
    _syncForms();
    final error = _validationError();
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    if (_forms.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    for (var index = 0; index < _forms.length; index++) {
      final form = _forms[index];
      if (form.created) continue;
      if (!mounted) return;
      setState(() {
        _currentFormIndex = index;
        form.error = null;
      });
      try {
        await Api.instance.createTable(
          widget.database,
          createTableBodyFor(form.plan, _driver),
        );
        if (!mounted) return;
        form.created = true;
        form.status = _RunStatus.idle;
      } catch (createError) {
        if (!mounted) return;
        form.error = describeDbError(createError);
        setState(() {
          _busy = false;
          _currentFormIndex = -1;
          _error = form.error;
        });
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _currentFormIndex = -1;
      _importsDone = false;
      _step = 2;
    });
  }

  // ------------------------------------------------------------- step 4 run

  /// 第 3 步：只导入数据（表已经在第 1→2 步创建好），不再调用 createTable。
  Future<void> _runImport() async {
    final path = _path;
    final inspect = _inspect;
    if (path == null || inspect == null) return;
    setState(() {
      _executing = true;
      _error = null;
    });
    for (var index = 0; index < _forms.length; index++) {
      final form = _forms[index];
      if (form.imported) continue;
      // 上次中断时已经写入过部分行：再导入会重复，留给用户手工检查。
      if (form.rowsInserted > 0) continue;
      if (!mounted) return;
      setState(() {
        _currentFormIndex = index;
        form.status = _RunStatus.importing;
        form.error = null;
      });
      try {
        final start = await Api.instance.importExecuteStart(
          importParamsFor(
            path: path,
            plan: form.plan,
            inspect: inspect,
            database: widget.database,
          ),
        );
        final jobId = (start['job_id'] ?? '').toString();
        if (jobId.isEmpty) {
          throw StateError(
              pickText('导入任务启动失败', 'Could not start the import task'));
        }
        _currentJobId = jobId;
        final result = await _watchImportJob(jobId);
        _currentJobId = null;
        if (!mounted) return;
        form.rowsInserted = (result['rows_inserted'] as num?)?.toInt() ?? 0;
        form.rowsFailed = (result['rows_failed'] as num?)?.toInt() ?? 0;
        if (result['ok'] != true) {
          form.status = _RunStatus.failed;
          form.error = (result['message'] ?? '').toString().isEmpty
              ? pickText('导入结束但有问题', 'The import finished with errors')
              : result['message'].toString();
          setState(() => _error = form.error);
          break;
        }
        form.status = _RunStatus.done;
        form.imported = true;
      } catch (runError) {
        if (!mounted) return;
        _currentJobId = null;
        form.status = _RunStatus.failed;
        form.error = describeDbError(runError);
        setState(() => _error = form.error);
        break;
      }
      setState(() {});
    }
    if (!mounted) return;
    setState(() {
      _executing = false;
      _currentFormIndex = -1;
      _jobStatus = null;
      _importsDone = _allImported;
    });
  }

  // ------------------------------------------------ 从关系步骤返回字段步骤

  /// 第 2 步的「返回工作表与字段」：删除本次已创建的空表，清掉建表/导入状态，
  /// 回到字段步骤重新设置（主键、列名、类型等）。
  ///
  /// 走到这里时还没有导入任何数据（导入在第 3 步），所以删表不会丢数据。
  /// 删除是 best-effort：失败只记录在顶部错误条里，不阻断回退。
  Future<void> _returnToFields() async {
    if (_executing) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final droppedFailures = <String>[];
    for (final form in _forms) {
      if (!form.created) continue;
      try {
        await Api.instance.dropTable(widget.database, form.plan.name);
      } catch (dropError) {
        droppedFailures
            .add('${form.plan.name}：${describeDbError(dropError)}');
      }
      form.created = false;
      form.imported = false;
      form.rowsInserted = 0;
      form.rowsFailed = 0;
      form.status = _RunStatus.idle;
      form.error = null;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _importsDone = false;
      _step = 1;
      if (droppedFailures.isNotEmpty) {
        _error = pickText(
          '返回时未能删除这些已建表（可以改表名后重试）：${droppedFailures.join('；')}',
          'Could not drop these created tables when going back (rename and retry): ${droppedFailures.join('; ')}',
        );
      }
    });
  }

  /// 轮询导入任务直到结束；任务失败或超时会抛错。
  Future<Json> _watchImportJob(String jobId) async {
    for (var attempt = 0; attempt < 6000; attempt++) {
      final status = await Api.instance.importJobStatus(jobId);
      if (!mounted) return <String, dynamic>{};
      setState(() => _jobStatus = status);
      if (status['done'] == true) {
        if (status['state'] == 'failed') {
          throw StateError(
            (status['error'] ?? pickText('任务失败', 'Task failed')).toString());
        }
        return asJsonMap(status['result']);
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    throw StateError(
        pickText('等待导入任务超时', 'Timed out waiting for the import task'));
  }

  Future<void> _cancelImport() async {
    final jobId = _currentJobId;
    if (jobId == null) return;
    try {
      await Api.instance.importJobCancel(jobId);
    } catch (_) {
      // 任务可能刚好结束；轮询会自己读到最终状态。
    }
  }

  Future<void> _retry() async {
    for (final form in _forms) {
      if (!form.imported && form.status == _RunStatus.failed) {
        form.status = _RunStatus.idle;
        form.error = null;
      }
    }
    setState(() {});
    await _runImport();
  }

  // ---------------------------------------------------------------- close

  void _close() {
    if (_executing) return;
    final created = _createdTables.length;
    final imported = _forms.where((form) => form.imported).length;
    if (created > 0) {
      if (imported == 0) {
        // 用户建完空表就关闭：表保留，但明确提示还没有导入数据。
        widget.notice.show(pickText(
          '已创建 $created 张空表（未导入数据）',
          'Created $created empty table(s) (no data imported)',
        ));
      } else if (imported == created) {
        widget.notice.show(
          pickText('已创建 $created 张表', 'Created $created table(s)'),
        );
      } else {
        widget.notice.show(pickText(
          '已创建 $created 张表，已导入 $imported 张表的数据',
          'Created $created table(s); imported data into $imported',
        ));
      }
    }
    Navigator.of(context).pop(created > 0);
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    // 类型标签、提示语都在 build 时按当前语言计算。这个向导是自绘 Dialog
    // （不经过 showAppModal 的语言重建外壳），所以自己监听语言变化，保证
    // 对话框打开期间切到英文也能立即换成原始 SQL 类型。
    return ValueListenableBuilder<AppLang>(
      valueListenable: I18n.lang,
      builder: (context, lang, _) => _buildDialog(context),
    );
  }

  Widget _buildDialog(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final width = screen.width < 1140 ? screen.width * 0.96 : 1100.0;
    final height = screen.height < 900 ? screen.height * 0.94 : 820.0;
    return PopScope(
      canPop: !_executing,
      child: Dialog(
        insetPadding: const EdgeInsets.all(20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppMetrics.radiusModal),
          side: BorderSide(color: AppColors.border),
        ),
        child: SizedBox(
          width: width,
          height: height,
          child: Column(
            children: [
              _header(),
              _stepIndicator(),
              Divider(height: 1, color: AppColors.border),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_error != null) ...[
                        AlertBox(_error!, tone: AlertTone.error),
                        const SizedBox(height: 10),
                      ],
                      _stepContent(),
                    ],
                  ),
                ),
              ),
              Divider(height: 1, color: AppColors.border),
              _footer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Row(
        children: [
          Icon(Icons.drive_file_move_outline,
              size: 18, color: AppColors.header),
          const SizedBox(width: 8),
          Text('从文件建表',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.header)),
          const SizedBox(width: 10),
          Pill(widget.database),
          const Spacer(),
          if (_fileName.isNotEmpty)
            Flexible(
              child: EllipsisText(
                _fileName,
                tooltip: _path,
                tooltipMaxWidth: 520,
                style: kSmallMuted,
              ),
            ),
          const SizedBox(width: 8),
          IconBtn(
            Icons.close,
            tooltip: '关闭',
            onPressed: _executing ? null : _close,
          ),
        ],
      ),
    );
  }

  Widget _stepIndicator() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Row(
        children: [
          for (var index = 0; index < kQuickCreateStepCount; index++) ...[
            if (index > 0)
              Expanded(
                child: Container(
                  height: 1,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  color: index <= _step ? AppColors.header : AppColors.border,
                ),
              ),
            _stepChip(index),
          ],
        ],
      ),
    );
  }

  Widget _stepChip(int index) {
    final active = index == _step;
    final done = index < _step;
    final color = active || done ? AppColors.header : AppColors.muted;
    final chip = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active || done ? AppColors.header : AppColors.chipBg,
            border: Border.all(color: AppColors.border),
          ),
          child: done
              ? const Icon(Icons.check, size: 12, color: Colors.white)
              : Text('${index + 1}',
                  style: TextStyle(
                      fontSize: 11,
                      color: active ? Colors.white : AppColors.muted)),
        ),
        const SizedBox(width: 6),
        Text(quickCreateStepTitle(index),
            style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
      ],
    );
    // 建表开始后不允许回到前面的步骤（数据库里已经有表了）。
    if (index >= _step || _executing || _createdTables.isNotEmpty) return chip;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(() => _step = index),
        child: chip,
      ),
    );
  }

  Widget _stepContent() {
    // 步骤顺序：选择文件 → 工作表与字段 → 建立关联 → 导入数据。
    return switch (_step) {
      0 => _stepFile(),
      1 => _stepTables(),
      2 => _stepRelations(),
      _ => _stepRun(),
    };
  }

  // ------------------------------------------------------------ step 1 UI

  Widget _stepFile() {
    final inspect = _inspect;
    final warnings = (inspect?['warnings'] as List? ?? const <dynamic>[])
        .map((warning) => warning.toString())
        .where((warning) => warning.isNotEmpty)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CardBox(
          title: '数据文件',
          actions: [
            Btn(
              _path == null ? '选择文件' : '重新选择文件',
              small: true,
              icon: Icons.folder_open_outlined,
              onPressed: _busy || _executing ? null : _pickFile,
            ),
          ],
          child: _path == null
              ? Text(
                  pickText(
                    '选择 CSV / Excel / JSON 等数据文件，直接建表并导入数据（不经过 SQL）。',
                    'Choose a CSV / Excel / JSON data file to create tables and import the data directly (no SQL involved).',
                  ),
                  style: kSmallMuted,
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _keyValue('文件名', _fileName),
                    _keyValue('格式', _formatLabel(_format), translate: true),
                    _keyValue(
                        '大小', formatBytes((inspect?['size'] as num?)?.toInt())),
                    if (_path!.isNotEmpty) _keyValue('路径', _path!),
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: LinearProgressIndicator(minHeight: 3),
                      ),
                  ],
                ),
        ),
        if (inspect != null) _sheetsCard(),
        if (warnings.isNotEmpty) ...[
          AlertBox(warnings.join('\n'), tone: AlertTone.warn),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _sheetsCard() {
    if (!_isWorkbook) {
      final defaultName = defaultTableNameFor(_path ?? '');
      return CardBox(
        title: '工作表',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              pickText(
                '该格式没有工作表概念：整个文件创建 1 张表，表名默认取文件名。',
                'This format has no worksheets: one table is created from the whole file, named after the file.',
              ),
              style: kSmallMuted,
            ),
            const SizedBox(height: 6),
            Text(
              pickText(
                '默认表名：$defaultName（下一步可修改）',
                'Default table name: $defaultName (editable in the next step)',
              ),
              style: kSmall,
            ),
          ],
        ),
      );
    }
    final sheetMeta = <String, Json>{
      for (final raw in (_inspect?['sheets'] as List? ?? const <dynamic>[])
          .map(asJsonMap))
        (raw['name'] ?? '').toString(): raw,
    };
    final chosen = _chosenSheets();
    return CardBox(
      title: '工作表',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _multiSheet
                ? pickText(
                    '文件含 ${_sheets.length} 个工作表，可以全部导入（每张工作表建一张表），也可以自定义选择。',
                    'The file has ${_sheets.length} worksheets: import them all (one table per worksheet) or choose a subset.',
                  )
                : pickText(
                    '文件含 1 个工作表，将创建 1 张表（表名默认取文件名）。',
                    'The file has 1 worksheet; one table will be created (named after the file).',
                  ),
            style: kSmallMuted,
          ),
          if (_multiSheet) ...[
            const SizedBox(height: 8),
            CheckBox(
              label: '全部导入（每张工作表建一张表）',
              value: _allSheets,
              onChanged: (value) => setState(() {
                _allSheets = value;
                if (value) _selectedSheets.addAll(_sheets);
              }),
            ),
          ],
          const SizedBox(height: 4),
          for (final sheet in _sheets) _sheetRow(sheet, sheetMeta[sheet]),
          const SizedBox(height: 6),
          Text(
            pickText(
              '将创建 ${chosen.length} 张表',
              '${chosen.length} table(s) will be created',
            ),
            style: kSmall,
          ),
        ],
      ),
    );
  }

  Widget _sheetRow(String sheet, Json? meta) {
    final rows = (meta?['rows'] as num?)?.toInt();
    final cols = (meta?['cols'] as num?)?.toInt();
    final detail = rows == null && cols == null
        ? ''
        : pickText(
            '（${rows ?? '?'} 行 × ${cols ?? '?'} 列）',
            '(${rows ?? '?'} rows x ${cols ?? '?'} columns)',
          );
    if (!_multiSheet || _allSheets) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text('$sheet $detail', style: kSmall),
      );
    }
    return CheckBox(
      label: '$sheet $detail',
      value: _selectedSheets.contains(sheet),
      onChanged: (value) {
        setState(() {
          if (value) {
            _selectedSheets.add(sheet);
          } else {
            _selectedSheets.remove(sheet);
          }
        });
      },
    );
  }

  // ------------------------------------------------------------ step 2 UI

  Widget _stepTables() {
    if (_busy && _forms.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: LinearProgressIndicator(minHeight: 3),
          ),
        Text(
          pickText(
            '确认每张表的表名与字段。类型由文件内容自动推断（可改），整数主键建表时自动自增。',
            'Review the name and columns of every table. Types are inferred from the data (editable); integer primary keys are created auto-increment.',
          ),
          style: kSmallMuted,
        ),
        if (_primaryWarningText != null) ...[
          const SizedBox(height: 10),
          AlertBox(_primaryWarningText!, tone: AlertTone.warn),
        ],
        const SizedBox(height: 10),
        for (var index = 0; index < _forms.length; index++) _tableCard(index),
      ],
    );
  }

  Widget _tableCard(int index) {
    final form = _forms[index];
    final plan = form.plan;
    final formError = _formError(form);
    final typeChoices = quickTypeChoices(_driver);
    final sourceValue = plan.sheet.isEmpty ? _fileName : plan.sheet;
    final title = plan.sheet.isEmpty
        ? '表 ${index + 1} · $_fileName'
        : '表 ${index + 1} · ${plan.sheet}';
    return CardBox(
      title: title,
      actions: [
        Text('工作表：$sourceValue', style: kSmallMuted),
        const SizedBox(width: 8),
        Btn(
          '重新推断',
          small: true,
          onPressed: _busy || _executing ? null : () => _reinfer(index),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 14,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              SizedBox(
                width: 240,
                child: Field(
                  key: ValueKey<String>('quick-table-name-$index'),
                  label: '表名',
                  controller: form.nameCtrl,
                  enabled: !_busy && !_executing,
                  onChanged: (value) =>
                      setState(() => plan.name = value.trim()),
                ),
              ),
              SizedBox(
                width: 150,
                child: Field(
                  label: '跳过开头行数',
                  controller: form.skipCtrl,
                  numeric: true,
                  enabled: !_busy && !_executing,
                  onChanged: (value) => setState(() {
                    plan.skipRows = int.tryParse(value.trim()) ?? 0;
                  }),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: CheckBox(
                  label: '首行是列名',
                  value: form.header,
                  enabled: !_busy && !_executing,
                  onChanged: _executing
                      ? null
                      : (value) async {
                          setState(() {
                            form.header = value;
                            plan.header = value;
                          });
                          await _reinfer(index);
                        },
                ),
              ),
            ],
          ),
          if (plan.skipRows > 0 || !form.header)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Text(
                '修改「首行是列名 / 跳过行数」后会自动重新推断；也可以点「重新推断」按当前设置刷新。',
                style: kSmallMuted,
              ),
            ),
          if (formError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text(formError,
                  style: TextStyle(fontSize: 12, color: AppColors.danger)),
            ),
          if (!planHasPrimary(plan))
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AlertBox(
                    pickText(
                      '未设置主键：没有主键的表不能作为外键的被引用表',
                      'No primary key: a table without a primary key cannot be referenced by foreign keys',
                    ),
                    tone: AlertTone.warn,
                  ),
                  const SizedBox(height: 6),
                  Btn(
                    pickText(
                      '添加自增 id 主键',
                      'Add auto-increment id as primary key',
                    ),
                    key: ValueKey<String>('quick-add-pk-$index'),
                    small: true,
                    icon: Icons.add,
                    onPressed: _busy || _executing
                        ? null
                        : () => _addGeneratedPrimaryKey(index),
                  ),
                ],
              ),
            ),
          if (form.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Text(form.error!,
                  style: TextStyle(fontSize: 12, color: AppColors.danger)),
            ),
          const SizedBox(height: 6),
          GridTable(
            headers: [
              const Text('源列名'),
              const Text('列名'),
              const Text('类型'),
              const Text('主键'),
              const Text('允许空'),
              const Text('示例值'),
            ],
            emptyText: '文件里没有可导入的列',
            rows: [
              for (var columnIndex = 0;
                  columnIndex < plan.columns.length;
                  columnIndex++)
                _columnRow(index, columnIndex, typeChoices),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            pickText(
              '主键：每张表最多 1 个；整数主键建表时自动自增。没有主键的表可以点上面的「添加自增 id 主键」补一个。字段可空：主键列强制非空。',
              'Primary key: at most one per table; integer keys become auto-increment. Add one with "Add auto-increment id as primary key" when a table has none. Nullable is forced off for the key column.',
            ),
            style: kSmallMuted,
          ),
        ],
      ),
    );
  }

  TableRow _columnRow(
      int formIndex, int columnIndex, List<String> typeChoices) {
    final form = _forms[formIndex];
    final column = form.plan.columns[columnIndex];
    final choices = <String>[...typeChoices];
    if (!choices.contains(column.sqlType)) choices.insert(0, column.sqlType);
    return TableRow(
      key: ObjectKey(column),
      children: [
        Padding(
          padding: const EdgeInsets.all(4),
          child: EllipsisText(
            column.generated
                ? pickText('（自动生成）', '(generated)')
                : column.sourceLabel,
            tooltip: column.generated
                ? pickText('该列由数据库自动生成，不从文件导入',
                    'Generated by the database, not imported from the file')
                : column.sourceLabel,
            style: monoStyle(size: 12),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(4),
          child: SizedBox(
            width: 150,
            child: Field(
              key: ValueKey<String>(
                  'quick-col-name-$formIndex-$columnIndex'),
              label: '',
              controller: columnIndex < form.columnCtrls.length
                  ? form.columnCtrls[columnIndex]
                  : null,
              compact: true,
              enabled: !_busy && !_executing,
              onChanged: (value) {
                setState(() => column.name = value.trim());
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(4),
          child: ColumnTypePicker(
            key: ValueKey<String>('quick-col-type-$formIndex-$columnIndex'),
            value: column.sqlType,
            types: choices,
            enabled: !_busy && !_executing,
            width: 170,
            onChanged: (value) {
              if (value == null) return;
              setState(() => column.sqlType = value);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(4),
          child: Center(
            child: CheckBox(
              key: ValueKey<String>('quick-col-pk-$formIndex-$columnIndex'),
              label: '',
              value: column.primary,
              enabled: !_busy && !_executing,
              onChanged: (value) {
                setState(() {
                  if (value) {
                    for (final other in form.plan.columns) {
                      other.primary = false;
                      // 生成列失去主键后不再自增；它没有源数据，必须允许为空，
                      // 否则 INSERT 会因为缺少这一列的值而失败。
                      if (other.generated) other.nullable = true;
                    }
                    column.primary = true;
                    column.nullable = false;
                    if (looksIntegerType(column.sqlType)) {
                      column.sqlType = pkColumnTypeFor(_driver);
                    }
                  } else {
                    column.primary = false;
                    if (column.generated) {
                      // 「降级为普通列」：保留列与名字，但不再自增。
                      column.nullable = true;
                    }
                  }
                });
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(4),
          child: Center(
            child: CheckBox(
              key:
                  ValueKey<String>('quick-col-nullable-$formIndex-$columnIndex'),
              label: '',
              value: !column.primary && column.nullable,
              enabled: !_busy && !_executing && !column.primary,
              onChanged: (value) {
                setState(() => column.nullable = value);
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(4),
          child: SizedBox(
            width: 160,
            child: EllipsisText(
              column.sample,
              tooltip: column.sample,
              style: kSmallMuted,
            ),
          ),
        ),
      ],
    );
  }

  // ----------------------------------------------- step 4 UI（导入数据）

  Widget _stepRun() {
    final progress = asJsonMap(_jobStatus?['progress']);
    final percent = (progress['percent'] as num?)?.toDouble() ?? 0;
    final rows = (progress['rows'] as num?)?.toInt() ?? 0;
    final failedTotal =
        _forms.where((form) => form.status == _RunStatus.failed).length;
    final currentName =
        _currentFormIndex >= 0 && _currentFormIndex < _forms.length
            ? _forms[_currentFormIndex].plan.name
            : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          pickText(
            '表已经在前面创建好；这一步只按列映射把数据逐表导入。失败会停下，已建表会保留，可以重试。',
            'The tables were created earlier; this step only imports each table with its column mapping. On failure the run stops, created tables are kept and you can retry.',
          ),
          style: kSmallMuted,
        ),
        const SizedBox(height: 10),
        CardBox(
          title: '执行计划',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < _forms.length; index++)
                _runRow(index),
            ],
          ),
        ),
        if (_executing) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  currentName.isEmpty
                      ? pickText('正在执行…', 'Running…')
                      : pickText(
                          '正在处理 $currentName', 'Processing $currentName'),
                  style: kSmall,
                ),
              ),
              Btn('取消导入', danger: true, onPressed: _cancelImport),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: percent > 0 ? (percent / 100).clamp(0.0, 1.0) : null,
            minHeight: 6,
            backgroundColor: AppColors.chipBg,
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.header),
          ),
          const SizedBox(height: 4),
          Text(
            pickText(
              '已处理 ${formatCount(rows)} 行 · ${percent.toStringAsFixed(0)}%',
              'Processed ${formatCount(rows)} rows · ${percent.toStringAsFixed(0)}%',
            ),
            style: kSmallMuted,
          ),
        ] else if (failedTotal > 0) ...[
          const SizedBox(height: 6),
          AlertBox(
            pickText(
              '有 $failedTotal 张表导入失败；已建表会保留（不会自动删除），修正后可以重试。',
              '$failedTotal table(s) failed to import; the created tables are kept (not dropped). Retry after fixing the problem.',
            ),
            tone: AlertTone.warn,
          ),
        ],
        if (!_executing && _importsDone) ...[
          const SizedBox(height: 6),
          AlertBox(
            pickText(
              '全部表的数据都导入完成，可以点「完成」返回数据库页。',
              'All tables were imported. Press Done to return to the database page.',
            ),
            tone: AlertTone.ok,
          ),
        ],
      ],
    );
  }

  Widget _runRow(int index) {
    final form = _forms[index];
    final plan = form.plan;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('${index + 1}. ${plan.name}',
                    style: monoStyle(size: 12)),
              ),
              Pill(_statusLabel(form.status), tone: _statusTone(form.status)),
              const SizedBox(width: 8),
              Text(
                pickText(
                  '${plan.columns.length} 个字段',
                  '${plan.columns.length} column(s)',
                ),
                style: kSmallMuted,
              ),
              if (form.imported) ...[
                const SizedBox(width: 10),
                Text(
                  pickText(
                    '写入 ${formatCount(form.rowsInserted)} 行',
                    '${formatCount(form.rowsInserted)} rows imported',
                  ),
                  style: TextStyle(fontSize: 12, color: AppColors.ok),
                ),
              ],
            ],
          ),
          if (form.error != null)
            Padding(
              padding: const EdgeInsets.only(left: 18, top: 2),
              child: Text(form.error!,
                  style: TextStyle(fontSize: 12, color: AppColors.danger)),
            ),
        ],
      ),
    );
  }

  // ----------------------------------------------- step 3 UI（建立关联）

  Widget _stepRelations() {
    final created = _createdTables;
    final tables = relationSeedTables(created);
    final overflowHint = relationSeedWarning(created.length);
    final missingPrimary = _createdTablesWithoutPrimary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          pickText(
            '先在这张画布上把表之间的关系连好（外键会立即写入数据库），下一步再导入数据。关系可以稍后从数据库页的「关系图」入口继续配置。',
            'Connect the tables here first (foreign keys are written to the database immediately), then import the data in the next step. You can also configure relationships later from the database page.',
          ),
          style: kSmallMuted,
        ),
        if (overflowHint != null) ...[
          const SizedBox(height: 8),
          AlertBox(overflowHint, tone: AlertTone.warn),
        ],
        if (missingPrimary.isNotEmpty) ...[
          const SizedBox(height: 8),
          AlertBox(
            pickText(
              '表 ${missingPrimary.join('、')} 没有主键，不能作为外键的被引用表；请返回工作表与字段设置主键。',
              'Table(s) ${missingPrimary.join(', ')} have no primary key and cannot be referenced by foreign keys. Go back to the fields step to add one.',
            ),
            tone: AlertTone.warn,
          ),
          const SizedBox(height: 6),
          Btn(
            pickText('返回工作表与字段', 'Back to worksheets and fields'),
            key: const ValueKey<String>('quick-relations-back'),
            small: true,
            icon: Icons.arrow_back,
            onPressed: _busy || _executing ? null : _returnToFields,
          ),
        ],
        const SizedBox(height: 10),
        if (tables.isEmpty)
          const AlertBox('没有已创建的表可以建立关联。', tone: AlertTone.info)
        else
          RelationDesigner(
            database: widget.database,
            initialTables: tables,
            // 关系画布上限（第 51 轮由 5 调到 10）：种子最多带 10 张表。
            maxTables: kRelationSeedLimit,
            height: 440,
            compact: true,
            // 关系创建失败/被前置条件阻止时，设计器会提供「返回工作表与字段
            // 修改」按钮，点它回到第 1 步（先删掉本次已创建的空表）。
            onRequestEditFields: _returnToFields,
          ),
      ],
    );
  }

  // ---------------------------------------------------------------- footer

  Widget _footer() {
    final validation = _step == 1 ? _validationError() : null;
    final canNext = switch (_step) {
      0 => _path != null && !_busy,
      1 => validation == null && !_busy,
      _ => true,
    };
    final failed = _forms
        .where((form) => !form.imported && form.status == _RunStatus.failed)
        .length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(child: Text(_footerHint(), style: kSmallMuted)),
          if (_busy || _executing) ...[
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
          ],
          Btn('关闭', onPressed: _executing ? null : _close),
          const SizedBox(width: 8),
          if (_step == 1)
            Btn('上一步',
                onPressed: _busy || _executing
                    ? null
                    : () => setState(() => _step = 0)),
          if (_step == 1) const SizedBox(width: 8),
          if (_step == 3 && !_importsDone && failed > 0 && !_executing)
            Btn(pickText('重试失败的表', 'Retry failed tables'),
                onPressed: _retry),
          if (_step == 3 && !_importsDone && failed > 0 && !_executing)
            const SizedBox(width: 8),
          Btn(
            _primaryLabel(),
            key: const ValueKey<String>('quick-create-primary'),
            primary: true,
            busy: _executing,
            onPressed: _primaryEnabled(canNext) ? _onPrimary : null,
          ),
        ],
      ),
    );
  }

  String _primaryLabel() {
    return switch (_step) {
      0 => pickText('下一步', 'Next'),
      1 => pickText('下一步：建立关联', 'Next: connect tables'),
      2 => pickText('下一步：导入数据', 'Next: import data'),
      _ => _importsDone
          ? pickText('完成', 'Done')
          : (_executing
              ? pickText('导入中…', 'Importing…')
              : (_hasRetryableFailure
                  ? pickText('重试失败的表', 'Retry failed tables')
                  : pickText('开始导入', 'Start import'))),
    };
  }

  bool _primaryEnabled(bool canNext) {
    if (_executing || _busy) return false;
    return switch (_step) {
      0 => canNext,
      1 => canNext,
      2 => _allTablesCreated,
      3 => _importsDone || _hasPendingWork,
      _ => true,
    };
  }

  Future<void> _onPrimary() async {
    switch (_step) {
      case 0:
        await _loadPlans();
      case 1:
        // 先建空表；失败留在本步骤并显示错误。
        await _createTablesAndContinue();
      case 2:
        setState(() {
          _step = 3;
          _importsDone = false;
          _error = null;
        });
      case 3:
        if (_importsDone) {
          _close();
        } else if (_hasRetryableFailure) {
          await _retry();
        } else if (_hasPendingWork) {
          await _runImport();
        }
      default:
        _close();
    }
  }

  String _footerHint() {
    return switch (_step) {
      0 => _busy
          ? pickText('正在分析文件…', 'Analyzing the file…')
          : pickText(
              '选择数据文件后点击「下一步」分析格式与工作表。',
              'Choose a data file, then continue to analyze its format and worksheets.',
            ),
      1 => _busy
          ? pickText('正在创建空表…', 'Creating the tables…')
          : pickText(
              '先确认表名与字段；下一步会先创建空表，再进入建立关联。',
              'Review the table names and columns; the next step creates the empty tables and then opens the relationship canvas.',
            ),
      2 => pickText(
          '关系会立即写入数据库；确认后下一步导入数据。',
          'Relationships are written immediately; continue to import the data next.',
        ),
      _ => _importsDone
          ? pickText(
              '全部完成。点击「完成」返回数据库页。',
              'Everything is done. Press Done to return to the database page.',
            )
          : pickText(
              '只导入数据，表已经在前面创建；失败会停下并保留已建表。',
              'Only data is imported here; the tables already exist. On failure the run stops and keeps what was created.',
            ),
    };
  }

  // --------------------------------------------------------------- helpers

  Widget _keyValue(String label, String value, {bool translate = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 70, child: Text(label, style: kSmallMuted)),
          Expanded(
            child: EllipsisText(
              value,
              tooltip: translate ? null : value,
              translate: translate,
              style: kSmall,
              tooltipMaxWidth: 620,
            ),
          ),
        ],
      ),
    );
  }
}
