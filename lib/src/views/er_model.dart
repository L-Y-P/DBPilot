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
    this.cardWidth = 230,
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

  /// 字段行右侧连接点的圆心（拖拽起点 / 箭头起点）。
  Offset connectionPoint(Offset node, int columnIndex) => Offset(
    node.dx + cardWidth - borderInset - circleInset,
    rowCenterY(node, columnIndex),
  );

  /// 字段行左边缘（箭头终点）。
  Offset leftAnchor(Offset node, int columnIndex) =>
      Offset(node.dx, rowCenterY(node, columnIndex));
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

/// 一条关系的三次贝塞尔曲线：起点在本表字段右侧，终点在引用表字段左侧。
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

/// 按当前布局计算一条关系的曲线；任一端不在画布上时返回 null。
ErRelationCurve? relationCurve(ErCanvasLayout layout, ErRelation relation) {
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
  final start = relColumnFocus(localPosition, localIndex, metrics);
  final end = relColumnFocus(refPosition, refIndex, metrics);
  if (relation.localTable == relation.refTable) {
    // 自引用：右侧出、右侧回。
    return ErRelationCurve(
      relation: relation,
      start: start,
      end: end,
      control1: start + const Offset(72, 0),
      control2: end + const Offset(72, 0),
    );
  }
  final dx = end.dx - start.dx;
  if (dx >= 48) {
    return ErRelationCurve(
      relation: relation,
      start: start,
      end: end,
      control1: start + Offset(dx / 2, 0),
      control2: end - Offset(dx / 2, 0),
    );
  }
  // 目标在左侧（回绕）：从右侧绕出去再回来。
  return ErRelationCurve(
    relation: relation,
    start: start,
    end: end,
    control1: start + const Offset(84, 0),
    control2: end - const Offset(84, 0),
  );
}

/// 关系起点 / 终点在卡片上的锚点（行不存在时落在卡片中部）。
Offset relColumnFocus(Offset node, int columnIndex, ErNodeMetrics metrics) {
  return Offset(
    node.dx + metrics.cardWidth - metrics.borderInset - metrics.circleInset,
    metrics.rowCenterY(node, columnIndex),
  );
}

/// 画布上的全部关系曲线（任一端不在画布上的关系被跳过）。
List<ErRelationCurve> relationCurves(
  ErCanvasLayout layout,
  List<ErRelation> relations,
) {
  final out = <ErRelationCurve>[];
  for (final relation in relations) {
    final curve = relationCurve(layout, relation);
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
