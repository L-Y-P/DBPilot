// E-R 关系设计器的纯数据模型与几何逻辑（第 50 轮）。
//
// 这个文件不 import Flutter 的 widget 层，也不触发任何 FFI 调用：表 / 关系模型、
// 外键 payload、中间表定义、箭头命中与自动布局都是纯函数，test/er_model_test.dart
// 不需要 dylib 就能覆盖。
//
// 规格见 docs/IMPORT_EXCEL_ER_DESIGN.md §5。

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// 数据库驱动，字符串与 Rust `DriverKind` / `AppState.driver` 一致。
enum ErDriver {
  mysql,
  postgres,
  sqlite;

  /// 把连接配置里的驱动 id 映射成设计器使用的枚举（未知值按 PostgreSQL 处理，
  /// 与 query_model.dart 的 builderDialectOf 保持一致）。
  static ErDriver fromName(String driver) {
    switch (driver) {
      case 'mysql':
        return ErDriver.mysql;
      case 'sqlite':
        return ErDriver.sqlite;
      default:
        return ErDriver.postgres;
    }
  }

  /// SQLite 只支持在建表语句里内联外键，`ALTER TABLE` 增删外键会直接报错，
  /// 所以画布上的连接点要禁用（已有外键仍然只读显示）。
  bool get supportsAlterForeignKey => this != ErDriver.sqlite;
}

/// 外键引用动作的 SQL 取值；空串表示不写动作（等价于 NO ACTION）。
///
/// 与 Rust `dbpilot_core::spec::fk_action` 的白名单一致。MySQL / InnoDB 不支持
/// `SET DEFAULT`，所以这里不提供。
const List<String> kErFkActions = <String>[
  '',
  'CASCADE',
  'SET NULL',
  'RESTRICT',
];

/// 关系来源，决定画布上的线条颜色和可编辑性。
enum ErRelationOrigin {
  /// 数据库里已经存在的外键（自动绘制）。
  existing,

  /// 本次会话里通过画布新建的外键。
  created,

  /// 自动创建的中间表带出来的两个外键。
  junction,

  /// 按列名推导出来的「建议」关系（只有虚线，尚未写入数据库）。
  suggested,
}

/// 设计器的一张表。
class ErTable {
  const ErTable({required this.name, required this.columns});

  final String name;
  final List<ErColumn> columns;

  ErColumn? columnNamed(String column) {
    for (final c in columns) {
      if (c.name == column) return c;
    }
    return null;
  }

  int? indexOfColumn(String column) {
    for (var i = 0; i < columns.length; i++) {
      if (columns[i].name == column) return i;
    }
    return null;
  }

  /// 主键列（只取第一列；复合主键保守地取第一列作为默认引用列）。
  ErColumn? get primaryColumn {
    for (final c in columns) {
      if (c.primary) return c;
    }
    return null;
  }

  bool get hasPrimary => primaryColumn != null;

  /// 全部主键列（复合主键时多于一个）。
  List<ErColumn> get primaryColumns => <ErColumn>[
    for (final c in columns)
      if (c.primary) c,
  ];

  /// 单列主键；复合主键或没有主键时返回 null（建议关系 / 中间表只认单列主键）。
  ErColumn? get singlePrimaryColumn =>
      primaryColumns.length == 1 ? primaryColumns.first : null;

  /// 从 `Api.structure` 的返回解析节点。
  ///
  /// 兼容三种驱动形状：MySQL / PostgreSQL 使用大写 `COLUMN_*` 键，SQLite 也是
  /// 同一套归一化列（drivers::column_json），外键行的 `CONSTRAINT_NAME` 在
  /// SQLite 下是 null（由 `SEQ` 区分）。
  factory ErTable.fromStructure(String name, Map<String, dynamic> payload) {
    final foreignColumns = <String>{};
    for (final row in erRowsOf(payload['foreign_keys'])) {
      final column = erStringOf(row['COLUMN_NAME'] ?? row['column']);
      if (column.isNotEmpty) foreignColumns.add(column);
    }
    final primaryNames = <String>{
      for (final value in erListOf(payload['primary_key'])) erStringOf(value),
    };
    final columns = <ErColumn>[];
    for (final row in erRowsOf(payload['columns'])) {
      final columnName = erStringOf(row['COLUMN_NAME'] ?? row['name']);
      if (columnName.isEmpty) continue;
      final key = erStringOf(row['COLUMN_KEY'] ?? row['key']);
      final extra = erStringOf(row['EXTRA'] ?? row['extra']);
      final defaultText = erStringOf(row['COLUMN_DEFAULT'] ?? row['default']);
      final identity = erStringOf(row['IS_IDENTITY']).toUpperCase() == 'YES';
      final nullable =
          erStringOf(row['IS_NULLABLE'] ?? row['nullable']).toUpperCase() !=
          'NO';
      columns.add(
        ErColumn(
          name: columnName,
          typeName: erColumnTypeOf(row),
          primary:
              key.toUpperCase() == 'PRI' || primaryNames.contains(columnName),
          foreignKey: foreignColumns.contains(columnName),
          autoIncrement:
              extra.toLowerCase().contains('auto_increment') ||
              defaultText.toLowerCase().contains('nextval(') ||
              identity,
          nullable: nullable,
        ),
      );
    }
    return ErTable(name: name, columns: columns);
  }

  /// 从 `Api.builderSchema` 的表对象解析节点（structure 读取失败时的兜底，
  /// 只有列名 / 类型 / 主键标记，没有真实约束名与引用动作）。
  factory ErTable.fromSchema(Map<String, dynamic> table) {
    final name = erStringOf(table['name']);
    final foreignColumns = <String>{
      for (final row in erRowsOf(table['foreign_keys']))
        erStringOf(row['column'] ?? row['COLUMN_NAME']),
    };
    final columns = <ErColumn>[];
    for (final row in erRowsOf(table['columns'])) {
      final columnName = erStringOf(row['name'] ?? row['COLUMN_NAME']);
      if (columnName.isEmpty) continue;
      final key = erStringOf(row['key'] ?? row['COLUMN_KEY']);
      final nullable = row.containsKey('nullable')
          ? row['nullable'] != false
          : erStringOf(row['IS_NULLABLE']).toUpperCase() != 'NO';
      columns.add(
        ErColumn(
          name: columnName,
          typeName: erColumnTypeOf(row),
          primary: key.toUpperCase() == 'PRI',
          foreignKey: foreignColumns.contains(columnName),
          nullable: nullable,
        ),
      );
    }
    return ErTable(name: name, columns: columns);
  }
}

/// 设计器的一列。
class ErColumn {
  const ErColumn({
    required this.name,
    this.typeName = '',
    this.primary = false,
    this.foreignKey = false,
    this.autoIncrement = false,
    this.nullable = true,
  });

  final String name;
  final String typeName;
  final bool primary;
  final bool foreignKey;
  final bool autoIncrement;

  /// 是否允许为 NULL（「置空」引用动作要求本表字段可空）。
  final bool nullable;

  /// 画布上显示的类型（结构读取失败时可能为空）。
  String get typeLabel => typeName.trim();

  @override
  String toString() =>
      'ErColumn($name $typeName primary=$primary fk=$foreignKey)';
}

/// 一条外键关系（画布上的一条边）。
///
/// 方向约定：`localTable.localColumn` 是拥有外键的一侧，`refTable.refColumn`
/// 是被引用的一侧。
class ErRelation {
  const ErRelation({
    required this.localTable,
    required this.localColumn,
    required this.refTable,
    required this.refColumn,
    this.name = '',
    this.onDelete = '',
    this.onUpdate = '',
    this.seq,
    this.origin = ErRelationOrigin.existing,
  });

  final String localTable;
  final String localColumn;
  final String refTable;
  final String refColumn;

  /// 约束名；SQLite 的 foreign_key_list 没有约束名，这里保持空串并用 [seq]
  /// 区分多条外键，画布改用「表.字段 → 表.字段」作为标签。
  final String name;
  final String onDelete;
  final String onUpdate;
  final int? seq;
  final ErRelationOrigin origin;

  /// 唯一键：同一张表上同一个约束名只有一条边。
  String get key => '$localTable.$localColumn>$refTable.$refColumn$name';

  /// 箭头标签：有约束名用约束名，否则用两端字段（SQLite）。
  String get displayLabel => name.isNotEmpty
      ? name
      : '$localTable.$localColumn → $refTable.$refColumn';

  /// 这条边是否连接 [a] 与 [b]（任一方向）。
  bool connects(String a, String b) =>
      (localTable == a && refTable == b) || (localTable == b && refTable == a);

  ErRelation withOrigin(ErRelationOrigin next) => ErRelation(
    localTable: localTable,
    localColumn: localColumn,
    refTable: refTable,
    refColumn: refColumn,
    name: name,
    onDelete: onDelete,
    onUpdate: onUpdate,
    seq: seq,
    origin: next,
  );

  /// 解析 `Api.structure` 的外键行。
  ///
  /// 复合外键（多列共用同一个约束名）只保留一条边：删除时按约束名整体删除，
  /// 多画几条会让用户以为可以分开删。
  static List<ErRelation> fromStructure(
    String table,
    Map<String, dynamic> payload,
  ) {
    final out = <ErRelation>[];
    final seenNames = <String>{};
    for (final row in erRowsOf(payload['foreign_keys'])) {
      final localColumn = erStringOf(row['COLUMN_NAME'] ?? row['column']);
      final refTable = erStringOf(
        row['REFERENCED_TABLE_NAME'] ?? row['ref_table'],
      );
      final refColumn = erStringOf(
        row['REFERENCED_COLUMN_NAME'] ?? row['ref_column'],
      );
      if (localColumn.isEmpty || refTable.isEmpty) continue;
      final name = erStringOf(row['CONSTRAINT_NAME'] ?? row['name']);
      if (name.isNotEmpty && !seenNames.add(name)) continue;
      out.add(
        ErRelation(
          localTable: table,
          localColumn: localColumn,
          refTable: refTable,
          refColumn: refColumn,
          name: name,
          onDelete: erStringOf(row['DELETE_RULE']).toUpperCase(),
          onUpdate: erStringOf(row['UPDATE_RULE']).toUpperCase(),
          seq: (row['SEQ'] as num?)?.toInt(),
        ),
      );
    }
    return out;
  }

  /// 解析 `Api.builderSchema` 的外键行（structure 兜底路径）。
  static List<ErRelation> fromSchema(
    String table,
    Map<String, dynamic> payload,
  ) {
    final out = <ErRelation>[];
    for (final row in erRowsOf(payload['foreign_keys'])) {
      final localColumn = erStringOf(row['column'] ?? row['COLUMN_NAME']);
      final refTable = erStringOf(
        row['ref_table'] ?? row['REFERENCED_TABLE_NAME'],
      );
      final refColumn = erStringOf(
        row['ref_column'] ?? row['REFERENCED_COLUMN_NAME'],
      );
      if (localColumn.isEmpty || refTable.isEmpty) continue;
      out.add(
        ErRelation(
          localTable: table,
          localColumn: localColumn,
          refTable: refTable,
          refColumn: refColumn,
        ),
      );
    }
    return out;
  }

  @override
  String toString() => 'ErRelation($displayLabel)';
}

// ---------------------------------------------------------------- 外键命名

/// 约束名允许的字符：Rust 的 default_fk_name 只保留 ASCII 字母数字与下划线
/// （其余字符在 DDL 白名单里会直接报「非法外键名」），这里生成默认名时保持一致。
String sanitizeFkNamePart(String raw) =>
    raw.trim().replaceAll(RegExp(r'[^0-9A-Za-z_]'), '_');

/// 默认约束名 `fk_<表>_<字段>`，与 Rust 的 default_fk_name 语义一致。
///
/// 中文 / 带空格等需要清洗的名字会被压成下划线：MySQL 的 InnoDB 要求外键约束
/// 名在同一个库里唯一，两个中文表名塌缩后都会变成 `fk_rel`，建第二条外键时
/// 就会撞名；`用户id` 和 `商品id` 也会塌缩成同一个 `_id`。所以只要清洗改变
/// 了原串（说明丢了信息），该部分就改用稳定短哈希标记（如 `fk_to7hv_c1ab2`）；
/// 纯 ASCII 的合法名字仍保持 `fk_<table>_<column>` 的可读形式。
String defaultFkName(String table, String column) {
  final tableName = _fkNamePart(table, 't');
  final columnName = _fkNamePart(column, 'c');
  final raw = 'fk_${tableName}_$columnName';
  var name = raw.replaceAll(RegExp(r'_{2,}'), '_');
  name = name.replaceAll(RegExp(r'_+$'), '');
  if (name == 'fk' || name.isEmpty) return 'fk_rel';
  return name;
}

/// 约束名里的一段：纯 ASCII 合法名保持原样，否则用前缀 + 稳定短哈希。
String _fkNamePart(String raw, String prefix) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '${prefix}0';
  final sanitized = sanitizeFkNamePart(trimmed);
  // 清洗没有丢信息（原串就只含字母数字下划线）时保留可读名字。
  return trimmed == sanitized ? sanitized : prefix + _shortHash(trimmed);
}

/// 稳定的短哈希（base36），用于把中文表 / 字段名映射成互不相同的 ASCII 标记。
String _shortHash(String value) {
  var hash = 0;
  for (final unit in value.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return hash.toRadixString(36);
}

/// 在 [taken] 里给 [base] 找一个不冲突的名字（base、base_2、base_3…）。
String uniqueName(String base, Set<String> taken) {
  if (base.isNotEmpty && !taken.contains(base)) return base;
  var index = 2;
  while (taken.contains('${base}_$index')) {
    index++;
  }
  return '${base}_$index';
}

/// 默认外键名并去重（同一张表上已存在的约束名）。
String uniqueFkName(String table, String column, Set<String> taken) =>
    uniqueName(defaultFkName(table, column), taken);

/// 单列外键的 add_foreign_keys payload（Rust ForeignKeyDef 的 JSON 形状）。
///
/// [onDelete] / [onUpdate] 传空串表示不写引用动作；Rust 侧会把它当作 None。
Map<String, dynamic> foreignKeyPayload({
  required String name,
  required String localColumn,
  required String refTable,
  required String refColumn,
  String onDelete = '',
  String onUpdate = '',
}) {
  return <String, dynamic>{
    'name': name.trim(),
    'columns': <String>[localColumn],
    'ref_table': refTable,
    'ref_columns': <String>[refColumn],
    'on_delete': onDelete.trim().toUpperCase(),
    'on_update': onUpdate.trim().toUpperCase(),
  };
}

/// 两表之间是否已经有一条关系（任一方向）。
bool hasRelationBetween(
  List<ErRelation> relations,
  String tableA,
  String tableB,
) => relationBetween(relations, tableA, tableB) != null;

/// 两表之间的第一条关系（任一方向）；没有返回 null。
ErRelation? relationBetween(
  List<ErRelation> relations,
  String tableA,
  String tableB,
) {
  for (final relation in relations) {
    if (relation.connects(tableA, tableB)) return relation;
  }
  return null;
}

// ---------------------------------------------------------------- 中间表

/// 多对多中间表的定义：id 主键自增 + 两个引用两端主键的外键列。
class ErJunctionPlan {
  const ErJunctionPlan({
    required this.name,
    required this.tableA,
    required this.primaryColumnA,
    required this.columnA,
    required this.typeA,
    required this.tableB,
    required this.primaryColumnB,
    required this.columnB,
    required this.typeB,
    required this.idColumn,
    required this.idType,
    required this.driver,
  });

  /// 中间表名（已去重，可被用户改写）。
  final String name;
  final String tableA;
  final String primaryColumnA;

  /// 中间表里指向 [tableA] 的列名，如 users_id。
  final String columnA;
  final String typeA;
  final String tableB;
  final String primaryColumnB;
  final String columnB;
  final String typeB;
  final String idColumn;
  final String idType;
  final ErDriver driver;

  /// 中间表自己的 id 列（画布节点显示用）。
  List<ErColumn> get columns => <ErColumn>[
    ErColumn(
      name: idColumn,
      typeName: idType,
      primary: true,
      autoIncrement: true,
    ),
    ErColumn(name: columnA, typeName: typeA, foreignKey: true, nullable: false),
    ErColumn(name: columnB, typeName: typeB, foreignKey: true, nullable: false),
  ];

  /// 中间表带出来的两条边（用于画布上立即显示，随后会被数据库重读覆盖）。
  List<ErRelation> get relations => <ErRelation>[
    ErRelation(
      localTable: name,
      localColumn: columnA,
      refTable: tableA,
      refColumn: primaryColumnA,
      name: fkNameA,
      origin: ErRelationOrigin.junction,
    ),
    ErRelation(
      localTable: name,
      localColumn: columnB,
      refTable: tableB,
      refColumn: primaryColumnB,
      name: fkNameB,
      origin: ErRelationOrigin.junction,
    ),
  ];

  /// 两个外键的默认约束名（同一张表内去重，避免中文表名塌缩后撞名）。
  String get fkNameA => defaultFkName(name, columnA);

  String get fkNameB =>
      uniqueName(defaultFkName(name, columnB), <String>{fkNameA});

  /// `Api.createTable` 的 body：一次事务里建表 + 两个内联外键。
  ///
  /// 自增主键不用 SERIAL 之类的类型字符串：三种驱动都走 auto_increment:true
  /// + primary:true，由 Rust 生成各自的 DDL（MySQL AUTO_INCREMENT / PG
  /// GENERATED BY DEFAULT AS IDENTITY / SQLite INTEGER PRIMARY KEY AUTOINCREMENT）。
  Map<String, dynamic> createTableBody() {
    return <String, dynamic>{
      'name': name,
      'columns': <Map<String, dynamic>>[
        <String, dynamic>{
          'name': idColumn,
          'type': idType,
          'nullable': false,
          'primary': true,
          'auto_increment': true,
        },
        <String, dynamic>{'name': columnA, 'type': typeA, 'nullable': false},
        <String, dynamic>{'name': columnB, 'type': typeB, 'nullable': false},
      ],
      'foreign_keys': <Map<String, dynamic>>[
        foreignKeyPayload(
          name: fkNameA,
          localColumn: columnA,
          refTable: tableA,
          refColumn: primaryColumnA,
        ),
        foreignKeyPayload(
          name: fkNameB,
          localColumn: columnB,
          refTable: tableB,
          refColumn: primaryColumnB,
        ),
      ],
    };
  }

  @override
  String toString() =>
      'ErJunctionPlan($name: $columnA→$tableA.$primaryColumnA, '
      '$columnB→$tableB.$primaryColumnB)';
}

/// 表名 / 列名里允许保留的字符（DDL 会给标识符加引号，中文可以保留）。
String identifierPart(String raw) => raw
    .trim()
    .replaceAll(RegExp(r'[^0-9A-Za-z_\u4e00-\u9fff]'), '_')
    .replaceAll(RegExp(r'_{2,}'), '_');

/// 默认中间表名 `表1_表2`；已存在时依次尝试 `base_rel`、`base_2`…
String junctionTableName(String tableA, String tableB, Set<String> taken) {
  final base = '${identifierPart(tableA)}_${identifierPart(tableB)}';
  if (!taken.contains(base)) return base;
  final rel = '${base}_rel';
  if (!taken.contains(rel)) return rel;
  var index = 2;
  while (taken.contains('${base}_$index')) {
    index++;
  }
  return '${base}_$index';
}

/// 生成多对多中间表；两表缺主键或为同一张表时返回 null（由调用方提示原因）。
///
/// [name] 非空时直接用它作为中间表名（用户在提示对话框里改过的名字），否则按
/// [junctionTableName] 去重生成。
ErJunctionPlan? planJunction({
  required ErDriver driver,
  required ErTable localTable,
  required ErTable refTable,
  required Set<String> existingTableNames,
  String? name,
}) {
  if (localTable.name == refTable.name) return null;
  final primaryA = localTable.primaryColumn;
  final primaryB = refTable.primaryColumn;
  if (primaryA == null || primaryB == null) return null;
  final preferred = name?.trim() ?? '';
  final tableName = preferred.isNotEmpty
      ? preferred
      : junctionTableName(localTable.name, refTable.name, existingTableNames);
  final columnA = uniqueName(
    '${identifierPart(localTable.name)}_${identifierPart(primaryA.name)}',
    <String>{'id'},
  );
  final columnB = uniqueName(
    '${identifierPart(refTable.name)}_${identifierPart(primaryB.name)}',
    <String>{'id', columnA},
  );
  final idColumn = uniqueName('id', <String>{columnA, columnB});
  return ErJunctionPlan(
    name: tableName,
    tableA: localTable.name,
    primaryColumnA: primaryA.name,
    columnA: columnA,
    typeA: erForeignKeyColumnType(driver, primaryA.typeName),
    tableB: refTable.name,
    primaryColumnB: primaryB.name,
    columnB: columnB,
    typeB: erForeignKeyColumnType(driver, primaryB.typeName),
    idColumn: idColumn,
    idType: erIntegerType(driver),
    driver: driver,
  );
}

/// 中间表自增主键的类型（与各驱动的建表 DDL 配合）。
String erIntegerType(ErDriver driver) {
  switch (driver) {
    case ErDriver.mysql:
    case ErDriver.postgres:
      return 'BIGINT';
    case ErDriver.sqlite:
      return 'INTEGER';
  }
}

/// 外键列的类型：从被引用列的真实类型取，保证 MySQL 的 FK 类型匹配。
///
/// PostgreSQL 的 serial / bigserial 是自增别名，直接拿来建列会再造一个序列，
/// 所以映射回对应的整数类型。
String erForeignKeyColumnType(ErDriver driver, String raw) {
  final type = raw.trim();
  if (type.isEmpty) return erIntegerType(driver);
  if (driver == ErDriver.postgres) {
    final lower = type.toLowerCase();
    if (lower.startsWith('bigserial')) return 'bigint';
    if (lower.startsWith('smallserial')) return 'smallint';
    if (lower.startsWith('serial')) return 'integer';
  }
  return type;
}

// ---------------------------------------------------------------- 画布几何

/// 表卡片的尺寸度量：画布排版与命中检测共用，保证画出来的行和点击的行一致。
class ErNodeMetrics {
  const ErNodeMetrics({
    // 非 compact 卡片略加宽（244），字段名 + 类型列更不容易互相挤压。
    this.cardWidth = 244,
    this.headerHeight = 32,
    this.rowHeight = 24,
    this.bottomPadding = 6,
    this.circleInset = 8,
    this.borderInset = 1,
  });

  /// 向导内嵌（compact）时的紧凑尺寸。
  const ErNodeMetrics.compact()
    : cardWidth = 200,
      headerHeight = 30,
      rowHeight = 22,
      bottomPadding = 4,
      circleInset = 8,
      borderInset = 1;

  factory ErNodeMetrics.forMode(bool compact) =>
      compact ? const ErNodeMetrics.compact() : const ErNodeMetrics();

  final double cardWidth;
  final double headerHeight;
  final double rowHeight;
  final double bottomPadding;

  /// 卡片边框占用的内边距（Container 的 decoration.border 会把子节点缩进
  /// 1px；布局和命中检测都要把这 2px 算进去，否则标题 + 行高刚好溢出 2px）。
  final double borderInset;

  /// 连接点圆心到卡片右边缘的距离（圆点画在行末）。
  final double circleInset;

  /// 卡片总高度：上下边框 + 表头 + 字段行 + 底部留白。
  double heightOf(ErTable table) =>
      borderInset * 2 +
      headerHeight +
      table.columns.length * rowHeight +
      bottomPadding;

  /// 第 [columnIndex] 行的垂直中心（内容从边框内侧开始）。
  double rowCenterY(Offset node, int columnIndex) =>
      node.dy +
      borderInset +
      headerHeight +
      columnIndex * rowHeight +
      rowHeight / 2;

  /// 字段行右侧连接点的圆心（右端拖拽起点）。
  Offset connectionPoint(Offset node, int columnIndex) => Offset(
    node.dx + cardWidth - borderInset - circleInset,
    rowCenterY(node, columnIndex),
  );

  /// 字段行左侧连接点的圆心（左端拖拽起点）。
  Offset leftConnectionPoint(Offset node, int columnIndex) => Offset(
    node.dx + borderInset + circleInset,
    rowCenterY(node, columnIndex),
  );

  /// 字段行左边界（左进锚点；箭头尖端正好落在卡片边界上）。
  Offset leftBoundary(Offset node, int columnIndex) =>
      Offset(node.dx, rowCenterY(node, columnIndex));

  /// 字段行右边界（右出锚点 / 镜像关系的箭头尖端）。
  Offset rightBoundary(Offset node, int columnIndex) =>
      Offset(node.dx + cardWidth, rowCenterY(node, columnIndex));

  /// 兼容旧名：左边界锚点。
  Offset leftAnchor(Offset node, int columnIndex) =>
      leftBoundary(node, columnIndex);
}

/// 画布布局：每张表的左上角坐标 + 尺寸度量。
class ErCanvasLayout {
  ErCanvasLayout({
    required List<ErTable> tables,
    required Map<String, Offset> positions,
    this.metrics = const ErNodeMetrics(),
  }) : tables = List<ErTable>.unmodifiable(tables),
       positions = Map<String, Offset>.unmodifiable(positions);

  final List<ErTable> tables;
  final Map<String, Offset> positions;
  final ErNodeMetrics metrics;

  ErTable? tableNamed(String name) {
    for (final table in tables) {
      if (table.name == name) return table;
    }
    return null;
  }

  Offset? positionOf(String name) => positions[name];

  Rect? rectOf(String name) {
    final table = tableNamed(name);
    final position = positions[name];
    if (table == null || position == null) return null;
    return Rect.fromLTWH(
      position.dx,
      position.dy,
      metrics.cardWidth,
      metrics.heightOf(table),
    );
  }

  /// 画布坐标落在哪个字段行上（节点从后往前找，后加入的节点在上层）。
  ErFieldRef? fieldAt(Offset point) {
    for (var i = tables.length - 1; i >= 0; i--) {
      final table = tables[i];
      final position = positions[table.name];
      if (position == null) continue;
      final rect = Rect.fromLTWH(
        position.dx,
        position.dy,
        metrics.cardWidth,
        metrics.heightOf(table),
      );
      if (!rect.contains(point)) continue;
      final dy =
          point.dy - position.dy - metrics.borderInset - metrics.headerHeight;
      if (dy < 0) return null;
      final index = (dy / metrics.rowHeight).floor();
      if (index < 0 || index >= table.columns.length) return null;
      return ErFieldRef(table.name, index);
    }
    return null;
  }

  /// 字段行右侧连接点；列不存在时返回 null。
  Offset? connectionPoint(String table, String column) {
    final node = tableNamed(table);
    final position = positions[table];
    if (node == null || position == null) return null;
    final index = node.indexOfColumn(column);
    if (index == null) return null;
    return metrics.connectionPoint(position, index);
  }

  /// 字段行左侧连接点；列不存在时返回 null。
  Offset? leftConnectionPoint(String table, String column) {
    final node = tableNamed(table);
    final position = positions[table];
    if (node == null || position == null) return null;
    final index = node.indexOfColumn(column);
    if (index == null) return null;
    return metrics.leftConnectionPoint(position, index);
  }

  /// 字段行左边缘锚点；列不存在时返回 null。
  Offset? refAnchor(String table, String column) {
    final node = tableNamed(table);
    final position = positions[table];
    if (node == null || position == null) return null;
    final index = node.indexOfColumn(column);
    if (index == null) return null;
    return metrics.leftAnchor(position, index);
  }

  /// 画布内容尺寸：节点包围盒 + 留白，且不小于视口（背景铺满）。
  Size contentSize({Size viewport = Size.zero, double margin = 32}) {
    var width = viewport.width;
    var height = viewport.height;
    for (final table in tables) {
      final position = positions[table.name];
      if (position == null) continue;
      width = math.max(width, position.dx + metrics.cardWidth + margin);
      height = math.max(height, position.dy + metrics.heightOf(table) + margin);
    }
    return Size(math.max(width, margin * 2), math.max(height, margin * 2));
  }
}

/// 画布上的一个字段位置（节点名 + 行号）。
class ErFieldRef {
  const ErFieldRef(this.table, this.columnIndex);

  final String table;
  final int columnIndex;

  @override
  bool operator ==(Object other) =>
      other is ErFieldRef &&
      other.table == table &&
      other.columnIndex == columnIndex;

  @override
  int get hashCode => Object.hash(table, columnIndex);

  @override
  String toString() => 'ErFieldRef($table[$columnIndex])';
}

/// 网格自动布局：按画布宽度把卡片排成若干列，行高取该行最高卡片。
Map<String, Offset> autoErLayout(
  List<ErTable> tables, {
  required double viewportWidth,
  ErNodeMetrics metrics = const ErNodeMetrics(),
  double gap = 48,
  double margin = 24,
}) {
  if (tables.isEmpty) return <String, Offset>{};
  final usable = math.max(metrics.cardWidth, viewportWidth - margin * 2);
  final perRow = math.max(
    1,
    ((usable + gap) / (metrics.cardWidth + gap)).floor(),
  );
  final positions = <String, Offset>{};
  var x = margin;
  var y = margin;
  var rowHeight = 0.0;
  var column = 0;
  for (final table in tables) {
    positions[table.name] = Offset(x, y);
    rowHeight = math.max(rowHeight, metrics.heightOf(table));
    column++;
    if (column >= perRow) {
      column = 0;
      x = margin;
      y += rowHeight + gap;
      rowHeight = 0;
    } else {
      x += metrics.cardWidth + gap;
    }
  }
  return positions;
}

/// 分层自动布局：按「已有外键 / 建议关系 / 中间表多对多」的父 → 子方向
/// 从左到右分层，层内按相邻层邻居的重心排序减少交叉。
///
/// 首载 / 自动带入 / 「自动布局」按钮都走这里；用户拖动过的节点由调用方保留
/// 坐标（这个函数只负责给出建议坐标）。没有关系边时所有表都在第 0 层。
Map<String, Offset> layeredErLayout(
  List<ErTable> tables,
  List<ErRelation> relations, {
  required double viewportWidth,
  ErNodeMetrics metrics = const ErNodeMetrics(),
  double gapX = 72,
  double gapY = 40,
  double margin = 24,
}) {
  if (tables.isEmpty) return <String, Offset>{};
  final names = <String>[for (final table in tables) table.name];
  final nameSet = names.toSet();
  final tableByName = <String, ErTable>{
    for (final table in tables) table.name: table,
  };
  int columnIndex(ErTable? table, String column) {
    if (table == null || column.isEmpty) return 0;
    return table.indexOfColumn(column) ?? 0;
  }

  final edges = <_LayerEdge>[];
  for (final relation in relations) {
    if (relation.localTable == relation.refTable) continue;
    if (!nameSet.contains(relation.localTable)) continue;
    if (!nameSet.contains(relation.refTable)) continue;
    edges.add(
      _LayerEdge(
        relation.localTable,
        relation.refTable,
        sourceColumnIndex: columnIndex(
          tableByName[relation.localTable],
          relation.localColumn,
        ),
        targetColumnIndex: columnIndex(
          tableByName[relation.refTable],
          relation.refColumn,
        ),
      ),
    );
  }
  // 1) 最长路径分层（限制迭代次数，允许互相引用的环）。
  final layer = <String, int>{for (final name in names) name: 0};
  for (var pass = 0; pass < names.length; pass++) {
    var changed = false;
    for (final edge in edges) {
      final next = (layer[edge.from] ?? 0) + 1;
      if ((layer[edge.to] ?? 0) < next) {
        layer[edge.to] = next;
        changed = true;
      }
    }
    if (!changed) break;
  }
  final minLayer = layer.values.reduce(math.min);
  for (final name in names) {
    layer[name] = (layer[name] ?? 0) - minLayer;
  }
  final maxLayer = layer.values.reduce(math.max);
  final layers = <int, List<String>>{
    for (var i = 0; i <= maxLayer; i++) i: <String>[],
  };
  for (final name in names) {
    layers[layer[name]!]!.add(name);
  }
  // 2) 层内排序：重心为主 + 「来源列 / 目标列顺序」做 tie-break，双向扫描 2 轮。
  //
  // 只做单向左→右 barycenter 时，同一张源表（如 order_items）发出的两条边
  // 在下一层会得到相同重心，退化成按表加入顺序排目标，导致 order_id→orders
  // 与 product_id→products 上下颠倒交叉成 X。这里把「上一行位置 + 源列序号」
  // 组成 port 键：order_id 在 product_id 上面，orders 就排在 products 上面。
  final incoming = <String, List<_LayerEdge>>{};
  final outgoing = <String, List<_LayerEdge>>{};
  for (final edge in edges) {
    incoming.putIfAbsent(edge.to, () => <_LayerEdge>[]).add(edge);
    outgoing.putIfAbsent(edge.from, () => <_LayerEdge>[]).add(edge);
  }
  final orderIndex = <String, int>{};
  void refreshOrderIndex(int layerIndex) {
    final list = layers[layerIndex]!;
    for (var i = 0; i < list.length; i++) {
      orderIndex[list[i]] = i;
    }
  }

  void sortLayer(int layerIndex, {required bool fromLeft}) {
    final current = layers[layerIndex]!;
    if (current.length > 1) {
      final keys = <String, _LayerSortKey>{};
      for (final name in current) {
        final neighbourEdges =
            (fromLeft ? incoming[name] : outgoing[name]) ??
            const <_LayerEdge>[];
        final neighbourPositions = <double>[];
        final ports = <double>[];
        for (final edge in neighbourEdges) {
          final neighbour = fromLeft ? edge.from : edge.to;
          final position = orderIndex[neighbour];
          if (position == null) continue;
          neighbourPositions.add(position.toDouble());
          final columnIndex = fromLeft
              ? edge.sourceColumnIndex
              : edge.targetColumnIndex;
          ports.add(position.toDouble() * 1000 + columnIndex);
        }
        keys[name] = _LayerSortKey(
          barycenter: neighbourPositions.isEmpty
              ? double.infinity
              : neighbourPositions.reduce((a, b) => a + b) /
                    neighbourPositions.length,
          port: ports.isEmpty
              ? double.infinity
              : ports.reduce((a, b) => a + b) / ports.length,
          tableOrder: names.indexOf(name),
        );
      }
      current.sort((a, b) => keys[a]!.compareTo(keys[b]!));
    }
    refreshOrderIndex(layerIndex);
  }

  refreshOrderIndex(0);
  for (var round = 0; round < 2; round++) {
    for (var i = 1; i <= maxLayer; i++) {
      sortLayer(i, fromLeft: true);
    }
    for (var i = maxLayer - 1; i >= 0; i--) {
      sortLayer(i, fromLeft: false);
    }
  }
  // 3) 坐标：每层垂直居中，水平从 margin（或居中）开始逐层递增。
  final layerHeights = <int, double>{};
  for (var i = 0; i <= maxLayer; i++) {
    final list = layers[i]!;
    var height = 0.0;
    for (var j = 0; j < list.length; j++) {
      if (j > 0) height += gapY;
      height += metrics.heightOf(tableByName[list[j]]!);
    }
    layerHeights[i] = height;
  }
  final maxHeight = layerHeights.values.reduce(math.max);
  final totalWidth = maxLayer * (metrics.cardWidth + gapX) + metrics.cardWidth;
  final left = totalWidth + margin * 2 < viewportWidth
      ? (viewportWidth - totalWidth) / 2
      : margin;
  final positions = <String, Offset>{};
  for (var i = 0; i <= maxLayer; i++) {
    final list = layers[i]!;
    var y = margin + (maxHeight - (layerHeights[i] ?? 0)) / 2;
    final x = left + i * (metrics.cardWidth + gapX);
    for (final name in list) {
      positions[name] = Offset(x, y);
      y += metrics.heightOf(tableByName[name]!) + gapY;
    }
  }
  return positions;
}

class _LayerEdge {
  const _LayerEdge(
    this.from,
    this.to, {
    required this.sourceColumnIndex,
    required this.targetColumnIndex,
  });

  final String from;
  final String to;

  /// 源 / 目标字段在各自表里的行号：层内排序 tie-break 用（同一源表的
  /// order_id 在 product_id 上面时，目标 orders 也应排在 products 上面）。
  final int sourceColumnIndex;
  final int targetColumnIndex;
}

/// 层内排序键：重心（相邻层邻居平均位置）→ port 键（邻居位置 + 列序号）
/// → 表加入顺序，保证排序稳定且同源相邻列的边不交叉。
class _LayerSortKey {
  const _LayerSortKey({
    required this.barycenter,
    required this.port,
    required this.tableOrder,
  });

  final double barycenter;
  final double port;
  final int tableOrder;

  int compareTo(_LayerSortKey other) {
    var result = barycenter.compareTo(other.barycenter);
    if (result != 0) return result;
    result = port.compareTo(other.port);
    if (result != 0) return result;
    return tableOrder.compareTo(other.tableOrder);
  }
}

/// 两点到线段的距离（箭头命中检测的基础）。
double distanceToSegment(Offset point, Offset start, Offset end) {
  final dx = end.dx - start.dx;
  final dy = end.dy - start.dy;
  final lengthSquared = dx * dx + dy * dy;
  if (lengthSquared == 0) return (point - start).distance;
  var t =
      ((point.dx - start.dx) * dx + (point.dy - start.dy) * dy) / lengthSquared;
  t = t.clamp(0.0, 1.0);
  final projection = Offset(start.dx + t * dx, start.dy + t * dy);
  return (point - projection).distance;
}

/// 一条关系的三次贝塞尔曲线：默认「左进右出」——源表在左时从源字段右边界
/// 出发、进入目标字段左边界；源表在右时镜像。控制点用水平切线，端点始终落在
/// 卡片边界上（箭头尖端在边界、不被卡片遮住）。
///
/// 同表自引用（如 manager_id → employees.id）从右侧出、绕到右侧回，避免线
/// 穿过卡片。
class ErRelationCurve {
  const ErRelationCurve({
    required this.relation,
    required this.start,
    required this.end,
    required this.control1,
    required this.control2,
  });

  final ErRelation relation;
  final Offset start;
  final Offset end;
  final Offset control1;
  final Offset control2;

  /// 曲线在参数 t 处的点。
  Offset pointAt(double t) {
    final one = 1 - t;
    final a = one * one * one;
    final b = 3 * one * one * t;
    final c = 3 * one * t * t;
    final d = t * t * t;
    return Offset(
      a * start.dx + b * control1.dx + c * control2.dx + d * end.dx,
      a * start.dy + b * control1.dy + c * control2.dy + d * end.dy,
    );
  }

  /// 箭头标签的锚点（曲线中点）。
  Offset get labelAnchor => pointAt(0.5);

  /// 采样折线，命中检测复用。
  List<Offset> sample({int segments = 24}) {
    final points = <Offset>[];
    for (var i = 0; i <= segments; i++) {
      points.add(pointAt(i / segments));
    }
    return points;
  }

  /// 箭头方向（终点切线；退化为起点→终点方向）。
  Offset get endDirection {
    var tangent = end - control2;
    if (tangent.distanceSquared < 0.0001) tangent = end - start;
    if (tangent.distanceSquared < 0.0001) tangent = const Offset(1, 0);
    return tangent;
  }
}

/// 一条关系两端使用的锚点侧（右出/左进，或镜像）。
class ErAnchorSide {
  const ErAnchorSide({required this.startOnRight, required this.endOnRight});

  /// 起点是否用卡片右边界（true）还是左边界。
  final bool startOnRight;

  /// 终点是否用卡片右边界（true）还是左边界。
  final bool endOnRight;

  ErAnchorSide get mirrored =>
      ErAnchorSide(startOnRight: !startOnRight, endOnRight: !endOnRight);

  @override
  bool operator ==(Object other) =>
      other is ErAnchorSide &&
      other.startOnRight == startOnRight &&
      other.endOnRight == endOnRight;

  @override
  int get hashCode => Object.hash(startOnRight, endOnRight);

  @override
  String toString() =>
      'ErAnchorSide(startOnRight: $startOnRight, endOnRight: $endOnRight)';
}

/// 默认锚点「左进右出」：源卡片在目标左侧时源右边界出、目标左边界进；
/// 源在右侧时镜像；同 x（或重叠）时按上下选更顺的一侧（源在上方走默认路由）。
ErAnchorSide relationAnchorSide(ErCanvasLayout layout, ErRelation relation) {
  final localPosition = layout.positions[relation.localTable];
  final refPosition = layout.positions[relation.refTable];
  if (localPosition == null || refPosition == null) {
    return const ErAnchorSide(startOnRight: true, endOnRight: false);
  }
  final metrics = layout.metrics;
  final localCenter = localPosition.dx + metrics.cardWidth / 2;
  final refCenter = refPosition.dx + metrics.cardWidth / 2;
  final sourceOnLeft = localCenter == refCenter
      ? localPosition.dy <= refPosition.dy
      : localCenter < refCenter;
  return ErAnchorSide(startOnRight: sourceOnLeft, endOnRight: !sourceOnLeft);
}

/// 按当前布局计算一条关系的曲线（默认锚点「左进右出」）。
///
/// 源卡片在目标左侧：源字段右边界出、目标字段左边界进（箭头在左端）；
/// 源在右侧镜像（左边界出、右边界进）；自引用从右侧出、右侧回。
/// [startFan] / [endFan] 给同一字段的多条边做垂直扇出，避免叠成一条线。
ErRelationCurve? relationCurve(
  ErCanvasLayout layout,
  ErRelation relation, {
  double startFan = 0,
  double endFan = 0,
}) {
  final localTable = layout.tableNamed(relation.localTable);
  final refTable = layout.tableNamed(relation.refTable);
  final localPosition = layout.positions[relation.localTable];
  final refPosition = layout.positions[relation.refTable];
  if (localTable == null ||
      refTable == null ||
      localPosition == null ||
      refPosition == null) {
    return null;
  }
  final metrics = layout.metrics;
  final localIndex = localTable.indexOfColumn(relation.localColumn) ?? 0;
  final refIndex = refTable.indexOfColumn(relation.refColumn) ?? 0;
  // 扇出偏移作用在锚点 y 上（同一字段的多条边上下错开），切线保持水平。
  if (relation.localTable == relation.refTable) {
    final start =
        metrics.rightBoundary(localPosition, localIndex) + Offset(0, startFan);
    final end =
        metrics.rightBoundary(refPosition, refIndex) + Offset(0, endFan);
    return ErRelationCurve(
      relation: relation,
      start: start,
      end: end,
      control1: start + const Offset(72, 0),
      control2: end + const Offset(72, 0),
    );
  }
  final side = relationAnchorSide(layout, relation);
  final start =
      (side.startOnRight
          ? metrics.rightBoundary(localPosition, localIndex)
          : metrics.leftBoundary(localPosition, localIndex)) +
      Offset(0, startFan);
  final end =
      (side.endOnRight
          ? metrics.rightBoundary(refPosition, refIndex)
          : metrics.leftBoundary(refPosition, refIndex)) +
      Offset(0, endFan);
  final dx = end.dx - start.dx;
  if (dx.abs() >= 48) {
    return ErRelationCurve(
      relation: relation,
      start: start,
      end: end,
      control1: start + Offset(dx / 2, 0),
      control2: end - Offset(dx / 2, 0),
    );
  }
  // 水平间距太小（两卡几乎重叠）：先向中间绕一小圈再进，避免直线穿过卡片。
  final sign = side.startOnRight ? 1.0 : -1.0;
  return ErRelationCurve(
    relation: relation,
    start: start,
    end: end,
    control1: start + Offset(sign * 84, 0),
    control2: end - Offset(sign * 84, 0),
  );
}

/// 画布上的全部关系曲线（任一端不在画布上的关系被跳过）。
///
/// 同一字段（同一行锚点）有多条边时按 [fanGap] 做垂直扇出：起点/终点分组，
/// 组内按顺序上下分布，避免多条线叠成一条。
List<ErRelationCurve> relationCurves(
  ErCanvasLayout layout,
  List<ErRelation> relations, {
  double fanGap = 12,
}) {
  final base = <ErRelationCurve>[];
  for (final relation in relations) {
    final curve = relationCurve(layout, relation);
    if (curve != null) base.add(curve);
  }
  if (base.length <= 1) return base;
  String pointKey(Offset point) => '${point.dx.round()}:${point.dy.round()}';
  final startGroups = <String, List<int>>{};
  final endGroups = <String, List<int>>{};
  for (var i = 0; i < base.length; i++) {
    startGroups.putIfAbsent(pointKey(base[i].start), () => <int>[]).add(i);
    endGroups.putIfAbsent(pointKey(base[i].end), () => <int>[]).add(i);
  }
  final out = <ErRelationCurve>[];
  for (var i = 0; i < base.length; i++) {
    final startGroup = startGroups[pointKey(base[i].start)]!;
    final endGroup = endGroups[pointKey(base[i].end)]!;
    final startIndex = startGroup.indexOf(i);
    final endIndex = endGroup.indexOf(i);
    final startFan = startGroup.length <= 1
        ? 0.0
        : (startIndex - (startGroup.length - 1) / 2) * fanGap;
    final endFan = endGroup.length <= 1
        ? 0.0
        : (endIndex - (endGroup.length - 1) / 2) * fanGap;
    final curve = relationCurve(
      layout,
      base[i].relation,
      startFan: startFan,
      endFan: endFan,
    );
    if (curve != null) out.add(curve);
  }
  return out;
}

/// 点中哪条关系（距曲线 ≤ [tolerance] 像素）；返回下标，没点中返回 null。
int? hitTestRelationCurves(
  List<ErRelationCurve> curves,
  Offset point, {
  double tolerance = 8,
}) {
  int? best;
  var bestDistance = tolerance;
  for (var i = 0; i < curves.length; i++) {
    final points = curves[i].sample();
    for (var j = 0; j + 1 < points.length; j++) {
      final distance = distanceToSegment(point, points[j], points[j + 1]);
      if (distance <= bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
  }
  return best;
}

// ---------------------------------------------------------- 箭头几何 / 多对多

/// 一条关系在目标端的箭头几何：尖端在曲线终点，沿终点切线方向回退。
class ErArrowHead {
  const ErArrowHead({
    required this.tip,
    required this.direction,
    required this.base,
    required this.left,
    required this.right,
  });

  /// 尖端（曲线终点）。
  final Offset tip;

  /// 单位切线方向（指向目标表）。
  final Offset direction;

  /// 底边中点。
  final Offset base;

  /// 底边两端。
  final Offset left;
  final Offset right;

  /// 填充三角形的三个顶点。
  List<Offset> get triangle => <Offset>[tip, left, right];

  /// 箭头长度（尖端到底边的距离）。
  double get length => (tip - base).distance;

  /// 按曲线终点切线方向生成箭头；退化曲线返回 null。
  ///
  /// [length] / [halfWidth] 由画布给值（普通 12/5.5，compact 稍小），这样
  /// 箭头永远落在目标端且不会因为曲线方向反转而指错方向。
  static ErArrowHead? forCurve(
    ErRelationCurve curve, {
    double length = 12,
    double halfWidth = 5.5,
  }) {
    final tangent = curve.endDirection;
    final total = tangent.distance;
    if (total < 0.0001) return null;
    final unit = tangent / total;
    final normal = Offset(-unit.dy, unit.dx);
    final base = curve.end - unit * length;
    return ErArrowHead(
      tip: curve.end,
      direction: unit,
      base: base,
      left: base + normal * halfWidth,
      right: base - normal * halfWidth,
    );
  }
}

/// 中间表识别结果：恰好两个单列外键，指向两张不同的实体表。
class ErJunctionInfo {
  const ErJunctionInfo({
    required this.junctionTable,
    required this.relationA,
    required this.relationB,
  });

  final String junctionTable;
  final ErRelation relationA;
  final ErRelation relationB;

  String get tableA => relationA.refTable;
  String get tableB => relationB.refTable;

  /// 这张中间表是否连着 [a] 与 [b]（任一方向）。
  bool connects(String a, String b) =>
      (tableA == a && tableB == b) || (tableA == b && tableB == a);
}

/// 识别中间表：一张已加入的表恰好有 2 个外键，指向 2 张不同的已加入表。
///
/// 只统计两端都在画布上的外键；指向画布外的外键不参与判断（否则用户只加入
/// 中间表时会被误判）。
Map<String, ErJunctionInfo> detectJunctionTables({
  required Map<String, List<ErRelation>> relationsByTable,
  required Set<String> tables,
}) {
  final out = <String, ErJunctionInfo>{};
  for (final entry in relationsByTable.entries) {
    if (!tables.contains(entry.key)) continue;
    final local = <ErRelation>[
      for (final relation in entry.value)
        if (tables.contains(relation.refTable) &&
            relation.refTable != entry.key)
          relation,
    ];
    if (local.length != 2) continue;
    if (local[0].refTable == local[1].refTable) continue;
    out[entry.key] = ErJunctionInfo(
      junctionTable: entry.key,
      relationA: local[0],
      relationB: local[1],
    );
  }
  return out;
}

/// 多对多链路：中间表 + 它连接的两张实体表。
class ErManyToManyLink {
  const ErManyToManyLink({
    required this.junctionTable,
    required this.relationA,
    required this.relationB,
  });

  final String junctionTable;
  final ErRelation relationA;
  final ErRelation relationB;

  String get tableA => relationA.refTable;
  String get tableB => relationB.refTable;

  String get key => 'm2m:$junctionTable';

  /// 画多对多连线用的合成关系（两端实体表之间，没有具体列）。
  ErRelation get syntheticRelation => ErRelation(
    localTable: tableA,
    localColumn: '',
    refTable: tableB,
    refColumn: '',
    origin: ErRelationOrigin.junction,
  );
}

/// 从中间表识别结果生成多对多连线（一张中间表一条）。
List<ErManyToManyLink> manyToManyLinks(Map<String, ErJunctionInfo> junctions) {
  return <ErManyToManyLink>[
    for (final info in junctions.values)
      ErManyToManyLink(
        junctionTable: info.junctionTable,
        relationA: info.relationA,
        relationB: info.relationB,
      ),
  ];
}

/// 两张实体表之间的多对多连线：从 A 卡片右边缘中部到 B 卡片左边缘中部。
ErRelationCurve? manyToManyCurve(ErCanvasLayout layout, ErManyToManyLink link) {
  final tableA = layout.tableNamed(link.tableA);
  final tableB = layout.tableNamed(link.tableB);
  final positionA = layout.positions[link.tableA];
  final positionB = layout.positions[link.tableB];
  if (tableA == null ||
      tableB == null ||
      positionA == null ||
      positionB == null) {
    return null;
  }
  final metrics = layout.metrics;
  final start = Offset(
    positionA.dx + metrics.cardWidth,
    positionA.dy + metrics.heightOf(tableA) / 2,
  );
  final end = Offset(positionB.dx, positionB.dy + metrics.heightOf(tableB) / 2);
  final synthetic = link.syntheticRelation;
  final dx = end.dx - start.dx;
  if (dx >= 48) {
    return ErRelationCurve(
      relation: synthetic,
      start: start,
      end: end,
      control1: start + Offset(dx / 2, 0),
      control2: end - Offset(dx / 2, 0),
    );
  }
  return ErRelationCurve(
    relation: synthetic,
    start: start,
    end: end,
    control1: start + const Offset(84, 0),
    control2: end - const Offset(84, 0),
  );
}

// -------------------------------------------------- 自动带入关联表

/// 从已加入的表出发，沿已有外键（父表 + 子表两个方向）做 BFS，返回候选表名。
///
/// [related] 是「表 → 有外键关联的表名列表」；[excluded] 是用户手动移除 / 撤销
/// 自动加入过的表，永远不会再被自动带回；[maxTables] 是画布上限（含已加入）。
/// 结果按 BFS 顺序返回，调用方加载完再决定是否真的加入。
List<String> expandRelatedTableNames({
  required Set<String> added,
  required Map<String, List<String>> related,
  required Set<String> excluded,
  required int maxTables,
}) {
  final out = <String>[];
  final visited = <String>{...added};
  final queue = <String>[...added];
  while (queue.isNotEmpty && added.length + out.length < maxTables) {
    final current = queue.removeAt(0);
    for (final neighbor in related[current] ?? const <String>[]) {
      if (!visited.add(neighbor)) continue;
      if (excluded.contains(neighbor)) continue;
      out.add(neighbor);
      queue.add(neighbor);
      if (added.length + out.length >= maxTables) break;
    }
  }
  return out;
}

// -------------------------------------------------- 建议关系（列名推导）

/// 从列名推导建议外键的基数部分：user_id / userId / userID -> user。
///
/// 以下划线 id 结尾时忽略大小写；驼峰 / 全大写 ID 也识别。普通列名（name、
/// valid、paid）不会误判。
String? suggestedForeignKeyBase(String column) {
  final snake = RegExp(r'^(.+?)_id$', caseSensitive: false).firstMatch(column);
  if (snake != null) return snake.group(1);
  final camel = RegExp(r'^(.+?)Id$').firstMatch(column);
  if (camel != null) return camel.group(1);
  final upper = RegExp(r'^(.+?)ID$').firstMatch(column);
  if (upper != null) return upper.group(1);
  return null;
}

/// 按列名推导「建议关系」。
///
/// 只跳过「已经有外键的本地列」和「与已有外键完全相同的目标」；同一张表上
/// 其它还没有外键的 `x_id` 列仍然会推导（第 51 轮 P2-7：应用第 1 条建议后
/// 其余建议不能整批消失，允许逐步补齐）。
///
/// 列名 `x_id` / `xId` 指向画布上表 x / xs / xes（y -> ies）的单列主键。
/// 返回的 ErRelation 带 [ErRelationOrigin.suggested]，由画布画成虚线，用户点
/// 「建立建议外键」后才会真正写库。
///
/// [maxResults] 限制虚线建议边数量（默认 20，支持 10 张表的批次）：一批宽表
/// 可能推出几十条建议，全画出来会让画布拥挤、命中检测变慢；剩下的可以在应用
/// 后重新推导。
List<ErRelation> suggestRelations({
  required List<ErTable> tables,
  required Map<String, List<ErRelation>> relationsByTable,
  int maxResults = 20,
}) {
  final byLowerName = <String, ErTable>{
    for (final table in tables) table.name.toLowerCase(): table,
  };
  final limit = maxResults <= 0 ? 0 : maxResults;
  final out = <ErRelation>[];
  for (final table in tables) {
    if (out.length >= limit) break;
    final existing = relationsByTable[table.name] ?? const <ErRelation>[];
    // 已有外键占用的本地列不再建议；已有外键的「目标列」也去重，避免对同一条
    // 关系重复画出建议虚线。
    final existingLocalColumns = <String>{
      for (final relation in existing)
        if (relation.localColumn.isNotEmpty) relation.localColumn,
    };
    final existingTargets = <String>{
      for (final relation in existing)
        if (relation.refTable.isNotEmpty && relation.refColumn.isNotEmpty)
          '${relation.refTable}.${relation.refColumn}'.toLowerCase(),
    };
    for (final column in table.columns) {
      if (out.length >= limit) break;
      if (column.primary) continue;
      if (column.foreignKey || existingLocalColumns.contains(column.name)) {
        continue;
      }
      final base = suggestedForeignKeyBase(column.name);
      if (base == null) continue;
      final target = _suggestedTarget(base, table, byLowerName);
      if (target == null) continue;
      final primary = target.singlePrimaryColumn;
      if (primary == null) continue;
      final targetKey = '${target.name}.${primary.name}'.toLowerCase();
      if (existingTargets.contains(targetKey)) continue;
      out.add(
        ErRelation(
          localTable: table.name,
          localColumn: column.name,
          refTable: target.name,
          refColumn: primary.name,
          origin: ErRelationOrigin.suggested,
        ),
      );
    }
  }
  return out;
}

ErTable? _suggestedTarget(
  String base,
  ErTable local,
  Map<String, ErTable> byLowerName,
) {
  final lower = base.toLowerCase();
  final candidates = <String>[lower, '${lower}s', '${lower}es'];
  if (lower.endsWith('y') && lower.length > 1) {
    candidates.add('${lower.substring(0, lower.length - 1)}ies');
  }
  if (lower.endsWith('s') && lower.length > 1) {
    candidates.add(lower.substring(0, lower.length - 1));
  }
  for (final candidate in candidates) {
    final table = byLowerName[candidate];
    if (table == null || table.name == local.name) continue;
    if (table.singlePrimaryColumn != null) return table;
  }
  return null;
}

// -------------------------------------------------- structure 唯一列

/// 从 Api.structure 的返回提取「单列唯一」字段（单列主键 / 单列唯一索引）。
///
/// 用来判断新建外键时被引用列能不能单独作为 FK 目标：复合唯一索引的每一列
/// 都不是单独唯一的，所以只收集「该索引只包含一列」的情况。
Set<String> erUniqueColumns(Map<String, dynamic> structure) {
  final out = <String>{};
  final primary = <String>[
    for (final value in erListOf(structure['primary_key'])) erStringOf(value),
  ].where((name) => name.isNotEmpty).toList();
  if (primary.length == 1) out.add(primary.first);
  final groups = <String, List<String>>{};
  var anonymous = 0;
  for (final row in erRowsOf(structure['indexes'])) {
    final unique = erStringOf(row['NON_UNIQUE'] ?? row['non_unique']) == '0';
    if (!unique) continue;
    final column = erStringOf(row['COLUMN_NAME'] ?? row['column']);
    if (column.isEmpty) continue;
    var name = erStringOf(row['INDEX_NAME'] ?? row['name'] ?? row['KEY_NAME']);
    if (name.isEmpty) name = '__${anonymous++}';
    groups.putIfAbsent(name, () => <String>[]).add(column);
  }
  for (final columns in groups.values) {
    if (columns.length == 1) out.add(columns.first);
  }
  return out;
}

// ---------------------------------------------------------- 外键前置校验

/// 外键前置校验发现的问题类型。
enum ErFkIssueKind {
  /// 本地表没有主键。
  localTableNoPrimary,

  /// 被引用表没有主键。
  refTableNoPrimary,

  /// 被引用列不是主键 / 单列唯一键。
  refColumnNotUnique,

  /// 本地列与目标列粗粒度类型不兼容。
  typeIncompatible,
}

/// 一条外键在本地前置校验里的失败原因（带具体表 / 列名，供 UI 组织文案）。
class ErFkIssue {
  const ErFkIssue({
    required this.kind,
    required this.localTable,
    required this.localColumn,
    required this.refTable,
    required this.refColumn,
    this.localType = '',
    this.refType = '',
  });

  final ErFkIssueKind kind;
  final String localTable;
  final String localColumn;
  final String refTable;
  final String refColumn;
  final String localType;
  final String refType;
}

/// 字段类型的粗粒度家族：只用来拦住「整数 vs 文本」这类明显不兼容的组合。
enum ErTypeFamily { numeric, boolean, text, temporal, binary, unknown }

/// 把列类型字符串归类成粗粒度家族；识别不了返回 [ErTypeFamily.unknown]。
ErTypeFamily erTypeFamily(String rawType) {
  final type = rawType.toLowerCase().trim();
  if (type.isEmpty) return ErTypeFamily.unknown;
  bool has(List<String> needles) => needles.any(type.contains);
  // 几何 / 网络等特殊类型先排除，避免 point 里的 int 被当成数值。
  if (has(<String>[
    'point',
    'polygon',
    'line',
    'circle',
    'path',
    'box',
    'inet',
    'cidr',
    'macaddr',
    'tsvector',
  ])) {
    return ErTypeFamily.unknown;
  }
  if (has(<String>['bool', 'bit'])) return ErTypeFamily.boolean;
  if (has(<String>[
    'json',
    'uuid',
    'char',
    'text',
    'clob',
    'enum',
    'set',
    'citext',
    'xml',
  ])) {
    return ErTypeFamily.text;
  }
  if (has(<String>['date', 'time', 'year', 'interval'])) {
    return ErTypeFamily.temporal;
  }
  if (has(<String>['blob', 'binary', 'bytea'])) return ErTypeFamily.binary;
  if (has(<String>[
    'int',
    'serial',
    'decimal',
    'numeric',
    'real',
    'double',
    'float',
    'money',
    'number',
  ])) {
    return ErTypeFamily.numeric;
  }
  return ErTypeFamily.unknown;
}

/// 粗粒度类型兼容性：只拦明显不兼容的组合（整数/小数 vs 文本/日期/二进制），
/// 拿不准（空类型、自定义类型）返回 true，交给数据库给出精确错误。
///
/// 这是第一层过滤；外键前置校验还要再过 [erForeignKeyTypesCompatible] 的数值
/// 精确比较（整数位宽 / UNSIGNED / DECIMAL 精度）。
bool erTypesCompatible(String localType, String refType) {
  final a = erTypeFamily(localType);
  final b = erTypeFamily(refType);
  if (a == ErTypeFamily.unknown || b == ErTypeFamily.unknown) return true;
  if (a == b) return true;
  // MySQL 的 BOOLEAN 就是 TINYINT(1)，数值/布尔之间不拦。
  if ((a == ErTypeFamily.numeric || a == ErTypeFamily.boolean) &&
      (b == ErTypeFamily.numeric || b == ErTypeFamily.boolean)) {
    return true;
  }
  return false;
}

/// 类型名（去掉括号参数、UNSIGNED / ZEROFILL 后缀后的大写族名）。
String _erTypeHead(String rawType) {
  final upper = rawType.trim().toUpperCase();
  if (upper.isEmpty) return '';
  final paren = upper.indexOf('(');
  var head = (paren >= 0 ? upper.substring(0, paren) : upper).trim();
  head = head.replaceAll(RegExp(r'\s+(UNSIGNED|ZEROFILL)\b'), '').trim();
  final first = head.split(RegExp(r'\s+')).first;
  // 多词别名（PostgreSQL 的 DOUBLE PRECISION）单独归一化。
  if (head.startsWith('DOUBLE PRECISION')) return 'DOUBLE PRECISION';
  return first;
}

/// 整数族的「精确身份」：位宽 + 是否有符号（例如 `32:u` / `64:s`）。
///
/// MySQL 外键要求两列的整数位宽与 UNSIGNED 完全一致（否则 ERROR 3780）；
/// PostgreSQL 则要求类型相同。SERIAL 族按 PostgreSQL 语义归一到对应位宽
/// （SMALLSERIAL=16、SERIAL=32、BIGSERIAL=64，均有符号；MySQL 的 SERIAL 是
/// BIGINT UNSIGNED，但类型下拉不提供它，这里不特判）。
///
/// 不是整数族（含 BOOLEAN——它在 MySQL 是 TINYINT(1)，但语义上按粗粒度处理）
/// 返回 null。
String? erIntegerTypeSignature(String rawType) {
  final head = _erTypeHead(rawType);
  int? bits;
  switch (head) {
    case 'TINYINT':
      bits = 8;
    case 'SMALLINT':
      bits = 16;
    case 'MEDIUMINT':
      bits = 24;
    case 'INT':
    case 'INTEGER':
    case 'INT4':
      bits = 32;
    case 'BIGINT':
    case 'INT8':
      bits = 64;
    case 'SMALLINT2':
    case 'INT2':
      bits = 16;
    case 'SMALLSERIAL':
      bits = 16;
    case 'SERIAL':
    case 'SERIAL4':
      bits = 32;
    case 'BIGSERIAL':
    case 'SERIAL8':
      bits = 64;
    default:
      return null;
  }
  final unsigned = RegExp(
    r'\bUNSIGNED\b',
    caseSensitive: false,
  ).hasMatch(rawType);
  return '$bits:${unsigned ? 'u' : 's'}';
}

/// DECIMAL / NUMERIC 的精确身份：`precision,scale`。
///
/// 没有显式写参数（数据库默认值各家不同，例如 MySQL DECIMAL 默认 (10,0)，
/// PostgreSQL 的 NUMERIC 不限制精度）时返回 null，交给数据库判断。
String? erDecimalTypeSignature(String rawType) {
  final upper = rawType.trim().toUpperCase();
  final head = _erTypeHead(upper);
  if (head != 'DECIMAL' && head != 'NUMERIC' && head != 'DEC') return null;
  final match = RegExp(
    r'\(\s*(\d+)\s*(?:,\s*(\d+)\s*)?\)',
  ).firstMatch(upper);
  if (match == null) return null;
  final precision = match.group(1);
  final scale = match.group(2) ?? '0';
  return '$precision,$scale';
}

/// 外键类型兼容：粗粒度过滤 + 数值类型精确比较。
///
/// 1. 先过 [erTypesCompatible]（整数/文本/日期等明显不兼容的组合）；
/// 2. 整数族比较「位宽 + 是否有符号」（INT vs BIGINT、INT vs INT UNSIGNED 都
///    会被拦住，而不是等数据库报 ERROR 3780）；
/// 3. DECIMAL / NUMERIC 比较 precision / scale；
/// 4. 其余（浮点之间、拿不到信息的类型）保持粗粒度放行。
bool erForeignKeyTypesCompatible(String localType, String refType) {
  if (!erTypesCompatible(localType, refType)) return false;
  final localInt = erIntegerTypeSignature(localType);
  final refInt = erIntegerTypeSignature(refType);
  if (localInt != null && refInt != null) return localInt == refInt;
  final localDecimal = erDecimalTypeSignature(localType);
  final refDecimal = erDecimalTypeSignature(refType);
  if (localDecimal != null && refDecimal != null) {
    return localDecimal == refDecimal;
  }
  return true;
}

/// 关系创建前的前置校验（纯逻辑，可无 FFI 单测）。
///
/// 规则（按顺序，返回第一个问题）：
/// 1. 本地表必须有主键；
/// 2. 被引用表必须有主键；
/// 3. 被引用列必须是主键或单列唯一键（[refUniqueColumns] 来自 structure 的
///    单列唯一索引；拿不到唯一信息时只认 primary）；
/// 4. 本地列与目标列类型必须兼容：粗粒度过滤 + 整数位宽 / UNSIGNED /
///    DECIMAL 精度的精确比较（拿不准交给数据库报错）。
ErFkIssue? validateForeignKeyCandidate({
  required ErTable localTable,
  required String localColumn,
  required ErTable refTable,
  required String refColumn,
  Set<String> refUniqueColumns = const <String>{},
}) {
  if (!localTable.hasPrimary) {
    return ErFkIssue(
      kind: ErFkIssueKind.localTableNoPrimary,
      localTable: localTable.name,
      localColumn: localColumn,
      refTable: refTable.name,
      refColumn: refColumn,
    );
  }
  if (!refTable.hasPrimary) {
    return ErFkIssue(
      kind: ErFkIssueKind.refTableNoPrimary,
      localTable: localTable.name,
      localColumn: localColumn,
      refTable: refTable.name,
      refColumn: refColumn,
    );
  }
  final ref = refTable.columnNamed(refColumn);
  final refIsUnique =
      (ref?.primary ?? false) || refUniqueColumns.contains(refColumn);
  if (ref == null || !refIsUnique) {
    return ErFkIssue(
      kind: ErFkIssueKind.refColumnNotUnique,
      localTable: localTable.name,
      localColumn: localColumn,
      refTable: refTable.name,
      refColumn: refColumn,
      refType: ref?.typeName ?? '',
    );
  }
  final local = localTable.columnNamed(localColumn);
  final localType = local?.typeName ?? '';
  if (!erForeignKeyTypesCompatible(localType, ref.typeName)) {
    return ErFkIssue(
      kind: ErFkIssueKind.typeIncompatible,
      localTable: localTable.name,
      localColumn: localColumn,
      refTable: refTable.name,
      refColumn: refColumn,
      localType: localType,
      refType: ref.typeName,
    );
  }
  return null;
}

// ------------------------------------------------------------ JSON 小工具

/// `Api.structure` / `Api.builderSchema` 返回的列表字段。
List<Map<String, dynamic>> erRowsOf(Object? value) {
  if (value is! List) return const <Map<String, dynamic>>[];
  final out = <Map<String, dynamic>>[];
  for (final item in value) {
    if (item is Map) out.add(Map<String, dynamic>.from(item));
  }
  return out;
}

/// 列表字段的原始元素（如 structure 的 primary_key）。
List<Object?> erListOf(Object? value) =>
    value is List ? List<Object?>.from(value) : const <Object?>[];

/// 宽松的字符串取值（null、数字都转成字符串）。
String erStringOf(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  return value.toString();
}

/// 一列的真实类型字符串：structure 用 COLUMN_TYPE / type_name，
/// builderSchema 用 type，SQLite 的 PRAGMA table_info 只有 type。
String erColumnTypeOf(Map<String, dynamic> row) {
  for (final key in const <String>[
    'COLUMN_TYPE',
    'type_name',
    'DATA_TYPE',
    'type',
  ]) {
    final value = erStringOf(row[key]);
    if (value.isNotEmpty) return value;
  }
  return '';
}
