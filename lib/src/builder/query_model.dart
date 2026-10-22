// SQL fragments are assembled piecemeal from identifiers, operator tokens and
// dialect branches; interpolation is unreadable for the multi-branch renderer,
// so this file keeps explicit concatenation.
// ignore_for_file: prefer_interpolation_to_compose_strings
//
// Pure data model and SQL generation for the graphical query builder.
//
// Nothing in this file imports Flutter: the view layer owns mutable instances
// of these classes and rebuilds the SQL whenever they change, so the whole
// generator can be unit-tested without a widget tree or a live database.

/// Join types offered by the builder.
///
/// MySQL has no FULL OUTER JOIN; [buildBuilderSql] rewrites that one case into
/// a UNION of two LEFT JOIN branches (the behaviour the ported web builder had).
const List<String> kJoinTypes = <String>[
  'INNER',
  'LEFT',
  'RIGHT',
  'FULL OUTER',
  'CROSS',
];

/// Aggregate choices for one output column. The empty string means "raw".
const List<String> kAggregates = <String>[
  '',
  'MIN',
  'MAX',
  'SUM',
  'AVG',
  'COUNT',
];

/// SQL dialect the builder renders for.
///
/// The builder was originally written against MySQL. The three engines agree on
/// most of the generated SELECT, but a few features differ and the renderer has
/// to branch on them instead of assuming MySQL:
///
///  * MySQL has no `FULL OUTER JOIN`; it is emulated with a UNION of two
///    LEFT JOIN branches (the ported web builder did the same). PostgreSQL and
///    SQLite (>= 3.39, bundled 3.46) support it natively.
///  * PostgreSQL has `ILIKE`; MySQL's `LIKE` is case-insensitive by default
///    and SQLite's is case-insensitive for ASCII, so the same control maps to
///    different SQL per engine.
///  * String literal escaping: MySQL treats a backslash as an escape character,
///    PostgreSQL/SQLite do not (standard_conforming_strings).
enum BuilderDialect { mysql, postgres, sqlite }

/// Map a connection driver id to its builder dialect.
BuilderDialect builderDialectOf(String driver) {
  switch (driver) {
    case 'mysql':
      return BuilderDialect.mysql;
    case 'sqlite':
      return BuilderDialect.sqlite;
    default:
      return BuilderDialect.postgres;
  }
}

/// True when the engine can run a native FULL OUTER JOIN.
bool builderSupportsFullOuter(BuilderDialect dialect) =>
    dialect != BuilderDialect.mysql;

/// Comparison operators offered by the filter rows.
///
/// [kOperators] is the common set (the model and saved modules keep using
/// these tokens); [builderOperatorsFor] adds the operators one engine can
/// express but the others cannot, so the picker never offers an option that
/// would be rewritten behind the user's back.
const List<String> kOperators = <String>[
  '=',
  '!=',
  '>',
  '>=',
  '<',
  '<=',
  'LIKE',
  'NOT LIKE',
  'IN',
  'IS NULL',
  'IS NOT NULL',
];

/// Filter operators to offer for [dialect].
List<String> builderOperatorsFor(BuilderDialect dialect) => <String>[
      ...kOperators,
      if (dialect == BuilderDialect.postgres) 'ILIKE',
    ];

/// Column-name fragments that normally hold personal / secret data.
///
/// This drives the small lock hint in the data source tree only; masking is a
/// server-side policy decision, so the UI never pretends to protect the value.
const List<String> kSensitiveColumnMarkers = <String>[
  'password',
  'passwd',
  'pwd',
  'secret',
  'token',
  'phone',
  'mobile',
  'email',
  'id_card',
  'idcard',
  'ssn',
  'bank',
  'card_no',
  'credit',
  'salt',
  'private_key',
  'api_key',
];

/// True when a column name looks like personal or secret data.
bool isSensitiveColumnName(String name) {
  final lower = name.toLowerCase();
  return kSensitiveColumnMarkers.any(lower.contains);
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  return <String, dynamic>{};
}

List<Object?> _asList(Object? value) => value is List ? value : <Object?>[];

String _str(Object? value) => value?.toString() ?? '';

bool _bool(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value == 'true') return true;
  if (value == 'false') return false;
  return fallback;
}

int _int(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(_str(value)) ?? fallback;
}

/// One column of a table, as returned by the Rust builder_schema handler.
class BuilderColumn {
  BuilderColumn({
    required this.name,
    this.type = '',
    this.nullable = true,
    this.key = '',
  });

  factory BuilderColumn.fromJson(Map<String, dynamic> json) => BuilderColumn(
        name: _str(json['name']),
        type: _str(json['type']),
        nullable: _bool(json['nullable'], fallback: true),
        key: _str(json['key']),
      );

  final String name;

  /// Driver-specific type text (varchar(255), numeric(10,2), ...).
  final String type;
  final bool nullable;

  /// PRI for primary-key columns (MySQL / SQLite).
  final String key;

  bool get isPrimaryKey => key.toUpperCase() == 'PRI';
  bool get isSensitive => isSensitiveColumnName(name);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'type': type,
        'nullable': nullable,
        'key': key,
      };
}

/// One declared foreign key on a table.
class BuilderForeignKey {
  BuilderForeignKey({
    required this.column,
    required this.refTable,
    required this.refColumn,
  });

  factory BuilderForeignKey.fromJson(Map<String, dynamic> json) =>
      BuilderForeignKey(
        column: _str(json['column']),
        refTable: _str(json['ref_table']),
        refColumn: _str(json['ref_column']),
      );

  final String column;
  final String refTable;
  final String refColumn;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'column': column,
        'ref_table': refTable,
        'ref_column': refColumn,
      };
}

/// A table plus its columns / foreign keys.
///
/// Advanced (cross-database) queries can use tables from more than one
/// namespace. [database] then holds that namespace and [name] is the bare
/// table name; [key] (database.name) is the identity used by every clause,
/// so two databases with an `orders` table never collide.
class BuilderTable {
  BuilderTable({
    required this.name,
    this.database = '',
    List<BuilderColumn>? columns,
    List<BuilderForeignKey>? foreignKeys,
  })  : columns = columns ?? <BuilderColumn>[],
        foreignKeys = foreignKeys ?? <BuilderForeignKey>[];

  factory BuilderTable.fromJson(Map<String, dynamic> json) => BuilderTable(
        name: _str(json['name']),
        database: _str(json['database']),
        columns: _asList(json['columns'])
            .map((e) => BuilderColumn.fromJson(_asMap(e)))
            .toList(),
        foreignKeys: _asList(json['foreign_keys'])
            .map((e) => BuilderForeignKey.fromJson(_asMap(e)))
            .toList(),
      );

  final String name;

  /// Namespace the table lives in for advanced cross-database queries.
  /// Empty for tables of the current data source (unqualified SQL).
  final String database;
  final List<BuilderColumn> columns;
  final List<BuilderForeignKey> foreignKeys;

  /// Unique identity inside one builder query.
  String get key => database.isEmpty ? name : database + '.' + name;

  /// Label shown in pickers / chips.
  String get label => key;

  bool get isCrossDatabase => database.isNotEmpty;

  BuilderColumn? column(String name) {
    for (final column in columns) {
      if (column.name == name) return column;
    }
    return null;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'database': database,
        'columns': columns.map((c) => c.toJson()).toList(),
        'foreign_keys': foreignKeys.map((f) => f.toJson()).toList(),
      };
}

/// Parse the {schema, tables:[...]} payload of builderSchema.
///
/// [database] is set for advanced cross-database sources so every table keeps
/// a qualified identity; the plain call leaves it empty (unqualified SQL).
List<BuilderTable> builderTablesFromSchema(Object? raw, {String database = ''}) {
  final map = _asMap(raw);
  final namespace = database.isEmpty ? _str(map['database']) : database;
  return _asList(map['tables'])
      .map((e) => BuilderTable.fromJson(_asMap(e)))
      .map((table) => namespace.isEmpty
          ? table
          : BuilderTable(
              name: table.name,
              database: namespace,
              columns: table.columns,
              foreignKeys: table.foreignKeys,
            ))
      .toList();
}

/// Parse the {schemas:[...], denied:[...]} payload of builderSchemaMulti.
///
/// Tables from every loaded namespace are merged; a namespace the account may
/// not open is skipped and reported in [CrossDatabaseSchema.denied].
class CrossDatabaseSchema {
  const CrossDatabaseSchema({required this.tables, required this.denied});

  final List<BuilderTable> tables;
  final List<String> denied;
}

CrossDatabaseSchema builderTablesFromMultiSchema(Object? raw) {
  final map = _asMap(raw);
  final tables = <BuilderTable>[];
  for (final entry in _asList(map['schemas'])) {
    final schema = _asMap(entry);
    final namespace = _str(schema['database']);
    final parsed = builderTablesFromSchema(schema, database: namespace);
    tables.addAll(parsed);
  }
  final denied = <String>[];
  for (final entry in _asList(map['denied'])) {
    final item = _asMap(entry);
    final name = _str(item['database']);
    if (name.isNotEmpty) denied.add(name);
  }
  return CrossDatabaseSchema(tables: tables, denied: denied);
}

/// One requested output column.
class OutputField {
  OutputField({
    required this.table,
    required this.column,
    this.aggregate = '',
    this.alias = '',
  });

  factory OutputField.fromJson(Map<String, dynamic> json) => OutputField(
        table: _str(json['table']),
        column: _str(json['column']),
        aggregate: _str(json['aggregate']),
        alias: _str(json['alias']),
      );

  String table;
  String column;

  /// Empty for a raw column, otherwise one of [kAggregates].
  String aggregate;

  /// Optional SQL alias (AS ...).
  String alias;

  bool get isAggregate => aggregate.isNotEmpty;

  /// table.column, used by labels and duplicate checks.
  String get key => '$table.$column';

  String get label => alias.isEmpty ? key : '$key AS $alias';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'table': table,
        'column': column,
        'aggregate': aggregate,
        'alias': alias,
      };
}

/// One JOIN clause.
class JoinSpec {
  JoinSpec({
    this.type = 'LEFT',
    this.leftTable = '',
    this.rightTable = '',
    this.leftColumn = '',
    this.rightColumn = '',
  });

  factory JoinSpec.fromJson(Map<String, dynamic> json) => JoinSpec(
        type: _str(json['type']).isEmpty ? 'LEFT' : _str(json['type']),
        leftTable: _str(json['left_table']),
        rightTable: _str(json['right_table']),
        leftColumn: _str(json['left_column']),
        rightColumn: _str(json['right_column']),
      );

  String type;
  String leftTable;
  String rightTable;
  String leftColumn;
  String rightColumn;

  bool get isCross => type == 'CROSS';
  bool get isComplete =>
      rightTable.isNotEmpty &&
      (isCross || (leftColumn.isNotEmpty && rightColumn.isNotEmpty));

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type,
        'left_table': leftTable,
        'right_table': rightTable,
        'left_column': leftColumn,
        'right_column': rightColumn,
      };
}

/// One comparison inside a filter row or a filter group.
class FilterCondition {
  FilterCondition({
    this.table = '',
    this.column = '',
    this.op = '=',
    this.value = '',
  });

  factory FilterCondition.fromJson(Map<String, dynamic> json) =>
      FilterCondition(
        table: _str(json['table']),
        column: _str(json['column']),
        op: _str(json['op']).isEmpty ? '=' : _str(json['op']),
        value: _str(json['value']),
      );

  String table;
  String column;
  String op;
  String value;

  bool get noValue => op == 'IS NULL' || op == 'IS NOT NULL';
  bool get hasColumn => table.isNotEmpty && column.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'table': table,
        'column': column,
        'op': op,
        'value': value,
      };
}

/// One entry of the top-level filter list: either a single condition or an
/// AND / OR group of conditions (one nesting level, as the design notes: a
/// deeper tree can later be modelled as a group AST).
class FilterEntry {
  FilterEntry.condition(this.condition)
      : isGroup = false,
        logic = 'AND',
        children = <FilterCondition>[];

  FilterEntry.group({
    this.logic = 'OR',
    List<FilterCondition>? children,
  })  : isGroup = true,
        condition = FilterCondition(),
        children = children ?? <FilterCondition>[];

  factory FilterEntry.fromJson(Map<String, dynamic> json) {
    final connector = _str(json['connector']).isEmpty
        ? 'AND'
        : _str(json['connector']);
    if (_bool(json['is_group'])) {
      final group = FilterEntry.group(
        logic: _str(json['logic']).isEmpty ? 'OR' : _str(json['logic']),
        children: _asList(json['children'])
            .map((e) => FilterCondition.fromJson(_asMap(e)))
            .toList(),
      );
      group.connector = connector;
      return group;
    }
    final entry = FilterEntry.condition(
        FilterCondition.fromJson(_asMap(json['condition'])));
    entry.connector = connector;
    return entry;
  }

  /// Connector to the previous top-level entry (AND / OR).
  String connector = 'AND';

  final bool isGroup;
  final FilterCondition condition;
  String logic;
  final List<FilterCondition> children;

  /// Number of conditions this entry contributes to the SQL / counter.
  int get count => isGroup ? children.length : 1;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'connector': connector,
        'is_group': isGroup,
        'logic': logic,
        'condition': condition.toJson(),
        'children': children.map((c) => c.toJson()).toList(),
      };
}

/// One ORDER BY term.
class OrderSpec {
  OrderSpec({
    this.table = '',
    this.column = '',
    this.dir = 'ASC',
  });

  factory OrderSpec.fromJson(Map<String, dynamic> json) => OrderSpec(
        table: _str(json['table']),
        column: _str(json['column']),
        dir: _str(json['dir']).toUpperCase() == 'DESC' ? 'DESC' : 'ASC',
      );

  String table;
  String column;
  String dir;

  bool get hasColumn => table.isNotEmpty && column.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'table': table,
        'column': column,
        'dir': dir,
      };
}

/// Everything the builder configures for one SELECT.
class BuilderQuery {
  BuilderQuery();

  factory BuilderQuery.fromJson(Map<String, dynamic> json) {
    final query = BuilderQuery()
      ..primaryTable = _str(json['primary_table']).isEmpty
          ? null
          : _str(json['primary_table'])
      ..distinct = _bool(json['distinct'])
      ..limit = _int(json['limit'], fallback: 100)
      ..maxReturn = _int(json['max_return'], fallback: 1000);
    for (final raw in _asList(json['outputs'])) {
      query.outputs.add(OutputField.fromJson(_asMap(raw)));
    }
    for (final raw in _asList(json['joins'])) {
      query.joins.add(JoinSpec.fromJson(_asMap(raw)));
    }
    for (final raw in _asList(json['filters'])) {
      query.filters.add(FilterEntry.fromJson(_asMap(raw)));
    }
    for (final raw in _asList(json['orders'])) {
      query.orders.add(OrderSpec.fromJson(_asMap(raw)));
    }
    return query;
  }

  String? primaryTable;
  bool distinct = false;
  int limit = 100;
  int maxReturn = 1000;
  final List<OutputField> outputs = <OutputField>[];
  final List<JoinSpec> joins = <JoinSpec>[];
  final List<FilterEntry> filters = <FilterEntry>[];
  final List<OrderSpec> orders = <OrderSpec>[];

  /// Clear every clause but keep the chosen limit / max-return defaults.
  void clearClauses({bool keepLimit = true}) {
    outputs.clear();
    joins.clear();
    filters.clear();
    orders.clear();
    distinct = false;
    if (!keepLimit) {
      limit = 100;
      maxReturn = 1000;
    }
  }

  /// Tables participating in the query, in FROM / JOIN order.
  ///
  /// Values are table keys: the bare name for tables of the current data
  /// source, `database.name` for advanced cross-database tables.
  List<String> queryTables() {
    final result = <String>[];
    void add(String name) {
      if (name.isNotEmpty && !result.contains(name)) result.add(name);
    }

    if (primaryTable != null) add(primaryTable!);
    for (final join in joins) {
      add(join.leftTable);
      add(join.rightTable);
    }
    return result;
  }

  /// Distinct namespaces used by the query (cross-database support).
  List<String> queryDatabases() {
    final result = <String>[];
    for (final key in queryTables()) {
      final index = key.indexOf('.');
      if (index <= 0) continue;
      final database = key.substring(0, index);
      if (!result.contains(database)) result.add(database);
    }
    return result;
  }

  bool get isCrossDatabase => queryDatabases().isNotEmpty;

  bool participates(String table) => queryTables().contains(table);

  int get filterCount =>
      filters.fold<int>(0, (sum, entry) => sum + entry.count);

  bool get hasAggregate => outputs.any((o) => o.isAggregate);

  /// Columns the result is grouped by, for the result-preview caption.
  List<String> groupByColumns() {
    if (!hasAggregate) return <String>[];
    return outputs
        .where((o) => !o.isAggregate)
        .map((o) => o.column)
        .toList();
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'primary_table': primaryTable,
        'distinct': distinct,
        'limit': limit,
        'max_return': maxReturn,
        'outputs': outputs.map((o) => o.toJson()).toList(),
        'joins': joins.map((j) => j.toJson()).toList(),
        'filters': filters.map((f) => f.toJson()).toList(),
        'orders': orders.map((o) => o.toJson()).toList(),
      };
}

/// One value bound by the preview SQL.
class SqlParam {
  const SqlParam({
    required this.position,
    required this.value,
    required this.numeric,
  });

  final int position;
  final String value;
  final bool numeric;

  String get placeholder => r'$' '$position';

  /// Human-readable form used in the -- 参数: ... preview line.
  String get displayValue {
    if (numeric) return value;
    return "'" + value.replaceAll("'", "''") + "'";
  }
}

/// Result of [buildBuilderSql].
class BuilderSql {
  const BuilderSql({
    required this.preview,
    required this.executable,
    required this.params,
    required this.tables,
    required this.groupBy,
    this.warnings = const <String>[],
  });

  /// Human-facing SQL: values are shown as ${...} style placeholders.
  final String preview;

  /// SQL actually sent to the server: values are escaped literals, because the
  /// desktop bridge executes a single SQL string and has no bind-parameter
  /// channel. Quoting is driver-aware, so this is equivalent to binding.
  final String executable;

  final List<SqlParam> params;
  final List<String> tables;
  final List<String> groupBy;
  final List<String> warnings;

  bool get hasParams => params.isNotEmpty;
}

/// A column type is numeric enough that a filter value should not be quoted.
bool _numericColumnType(String type) {
  final lower = type.toLowerCase();
  if (lower.contains('char') ||
      lower.contains('text') ||
      lower.contains('date')) {
    return false;
  }
  return lower.contains('int') ||
      lower.contains('numeric') ||
      lower.contains('decimal') ||
      lower.contains('float') ||
      lower.contains('double') ||
      lower.contains('real') ||
      lower.contains('serial');
}

String _quoteLiteral(String raw,
    {required bool numeric, required BuilderDialect dialect}) {
  if (numeric) return raw;
  var escaped = raw.replaceAll("'", "''");
  // MySQL treats a backslash as an escape character in string literals; with
  // PostgreSQL's default standard_conforming_strings and in SQLite a backslash
  // is literal data. Doubling it only for MySQL keeps a value containing "\"
  // intact on every engine instead of silently corrupting it on two of them.
  if (dialect == BuilderDialect.mysql) {
    final backslash = String.fromCharCode(92);
    final doubled = String.fromCharCodes(const <int>[92, 92]);
    escaped = escaped.replaceAll(backslash, doubled);
  }
  return "'" + escaped + "'";
}

class _Emitter {
  _Emitter({
    required this.previewMode,
    required this.quote,
    required this.dialect,
    required this.tables,
  });

  final bool previewMode;
  final String Function(String) quote;
  final BuilderDialect dialect;
  final Map<String, BuilderTable> tables;
  final List<SqlParam> params = <SqlParam>[];
  final List<String> warnings = <String>[];

  /// Render one table reference: `database.table` for cross-database tables,
  /// the bare quoted name otherwise.
  String tableRef(String tableKey) {
    final table = tables[tableKey];
    if (table == null || table.database.isEmpty) return quote(tableKey);
    return quote(table.database) + '.' + quote(table.name);
  }

  String columnRef(String table, String column) =>
      tableRef(table) + '.' + quote(column);

  BuilderColumn? _column(String table, String column) =>
      tables[table]?.column(column);

  /// Bind / inline one value for a condition.
  ///
  /// [processedValue] is the value after operator shaping (e.g. the %...%
  /// wrapper of LIKE); [numeric] comes from the column's declared type.
  String value(String processedValue, {required bool numeric}) {
    if (!previewMode) {
      return _quoteLiteral(processedValue, numeric: numeric, dialect: dialect);
    }
    final position = params.length + 1;
    params.add(SqlParam(
      position: position,
      value: processedValue,
      numeric: numeric,
    ));
    return r'$' '$position';
  }

  /// Render one condition (without a leading connector). Returns null when the
  /// row is incomplete and must be skipped.
  String? condition(FilterCondition condition) {
    if (!condition.hasColumn) return null;
    final column = _column(condition.table, condition.column);
    if (column == null) {
      warnings.add('条件引用了不存在的字段：' +
          condition.table +
          '.' +
          condition.column);
      return null;
    }
    final ref = columnRef(condition.table, condition.column);
    var op = condition.op.isEmpty ? '=' : condition.op;
    if (op == 'IS NULL' || op == 'IS NOT NULL') return ref + ' ' + op;
    // ILIKE is PostgreSQL-only. A module saved against PostgreSQL and opened on
    // MySQL / SQLite must still run: degrade to LIKE and say so instead of
    // sending a statement the server rejects.
    if (op == 'ILIKE' && dialect != BuilderDialect.postgres) {
      warnings.add('ILIKE 仅在 PostgreSQL 可用，已按 LIKE 生成');
      op = 'LIKE';
    }

    final raw = condition.value.trim();
    final numeric = _numericColumnType(column.type);
    // A row that needs a value but has none used to render as `= ''` / `= $1`;
    // inside a group it could even leave a dangling `AND (...)`, which the
    // server rejected with a syntax error (round 34, P2-07). Drop the row — the
    // view blocks execution before it gets here — and say what to fix.
    final emptyValue = op == 'IN'
        ? !raw.split(',').any((item) => item.trim().isNotEmpty)
        : raw.isEmpty;
    if (emptyValue) {
      warnings.add('条件值不能为空：' +
          condition.table +
          '.' +
          condition.column +
          '（' +
          op +
          '）；请填写条件值或改用「为空」');
      return null;
    }
    if (op == 'IN') {
      final items = raw
          .split(',')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList();
      final bound =
          items.map((item) => value(item, numeric: numeric)).join(', ');
      return ref + ' IN (' + bound + ')';
    }
    if (op == 'LIKE' || op == 'NOT LIKE' || op == 'ILIKE' || op == 'NOT ILIKE') {
      return ref + ' ' + op + ' ' + value('%' + raw + '%', numeric: false);
    }
    return ref + ' ' + op + ' ' + value(raw, numeric: numeric);
  }

  /// Render the top-level filter list into a WHERE clause ('' when empty).
  String whereClause(List<FilterEntry> entries) {
    final parts = <String>[];
    for (final entry in entries) {
      String? sql;
      if (entry.isGroup) {
        final inner = <String>[];
        for (final child in entry.children) {
          final rendered = condition(child);
          if (rendered != null) inner.add(rendered);
        }
        if (inner.isEmpty) continue;
        final logic = entry.logic == 'OR' ? ' OR ' : ' AND ';
        sql = '(' + inner.join(logic) + ')';
      } else {
        sql = condition(entry.condition);
      }
      if (sql == null) continue;
      final prefix = parts.isEmpty ? '' : entry.connector + ' ';
      parts.add(prefix + sql);
    }
    return parts.isEmpty ? '' : ' WHERE ' + parts.join(' ');
  }
}

/// One filter row that compares a column against a value but has none.
class BuilderMissingValue {
  const BuilderMissingValue({
    required this.table,
    required this.column,
    required this.op,
  });

  final String table;
  final String column;
  final String op;

  /// `table.column`, the way the builder names a field elsewhere.
  String get field => table + '.' + column;
}

/// The first (depth-first) filter row that requires a value but has none.
///
/// Rows without a column are ignored: the emitter skips them too, so they
/// cannot produce broken SQL. The view refuses to execute while this is
/// non-null and the emitter drops the row with a warning, because an empty
/// value used to render as `= ''` / `= $1` — and a group whose only row was
/// dropped left a dangling `AND (...)` that PostgreSQL rejected with
/// `syntax error at or near "AND"` (round 34, P2-07).
BuilderMissingValue? builderMissingConditionValue(BuilderQuery query) {
  BuilderMissingValue? check(FilterCondition condition) {
    if (!condition.hasColumn || condition.noValue) return null;
    final raw = condition.value.trim();
    final missing =
        condition.op == 'IN' ? raw.replaceAll(',', '').trim().isEmpty : raw.isEmpty;
    if (!missing) return null;
    return BuilderMissingValue(
      table: condition.table,
      column: condition.column,
      op: condition.op.isEmpty ? '=' : condition.op,
    );
  }

  for (final entry in query.filters) {
    if (!entry.isGroup) {
      final missing = check(entry.condition);
      if (missing != null) return missing;
      continue;
    }
    for (final child in entry.children) {
      final missing = check(child);
      if (missing != null) return missing;
    }
  }
  return null;
}

/// Build the SELECT for [query].
///
/// [tables] is the schema payload; [quote] quotes one identifier the way the
/// active driver expects (see AppState.quoteIdent). Everything is driven by
/// [BuilderQuery], so an incomplete configuration yields a -- ... comment
/// instead of an exception.
BuilderSql buildBuilderSql(
  BuilderQuery query,
  List<BuilderTable> tables, {
  required String Function(String) quote,
  BuilderDialect? dialect,
  bool isMysql = false,
}) {
  final resolvedDialect =
      dialect ?? (isMysql ? BuilderDialect.mysql : BuilderDialect.postgres);
  final tableMap = <String, BuilderTable>{
    for (final table in tables) table.key: table,
  };
  final primary = query.primaryTable;
  final participating = query.queryTables();
  if (primary == null || primary.isEmpty || !tableMap.containsKey(primary)) {
    const message = '-- 请先选择主表';
    return const BuilderSql(
      preview: message,
      executable: message,
      params: <SqlParam>[],
      tables: <String>[],
      groupBy: <String>[],
    );
  }

  final previewEmitter = _Emitter(
    previewMode: true,
    quote: quote,
    dialect: resolvedDialect,
    tables: tableMap,
  );
  final executableEmitter = _Emitter(
    previewMode: false,
    quote: quote,
    dialect: resolvedDialect,
    tables: tableMap,
  );
  final preview = _renderSelect(
    query,
    previewEmitter,
    primary,
    participating,
    quote,
    resolvedDialect,
  );
  final executable = _renderSelect(
    query,
    executableEmitter,
    primary,
    participating,
    quote,
    resolvedDialect,
  );
  final warnings = <String>{
    ...previewEmitter.warnings,
    ...executableEmitter.warnings,
  }.toList();
  return BuilderSql(
    preview: preview,
    executable: executable,
    params: List<SqlParam>.unmodifiable(previewEmitter.params),
    tables: participating,
    groupBy: query.groupByColumns(),
    warnings: warnings,
  );
}

String _renderSelect(
  BuilderQuery query,
  _Emitter emitter,
  String primary,
  List<String> participating,
  String Function(String) quote,
  BuilderDialect dialect,
) {
  final multiTable = participating.length > 1;

  String columnExpr(OutputField output) {
    final ref = emitter.columnRef(output.table, output.column);
    final core = output.isAggregate
        ? output.aggregate + '(' + ref + ')'
        : ref;
    if (output.alias.isNotEmpty) {
      return core + ' AS ' + quote(output.alias);
    }
    // Without an alias, multi-table results would otherwise return several
    // columns with the same bare name; qualifying them keeps the preview
    // headers unambiguous (the ported web builder did the same).
    if (multiTable) return core + ' AS ' + quote(output.key);
    return core;
  }

  // Only tables that really appear in FROM / JOIN may be listed in SELECT:
  // a join that is skipped below (no ON condition yet) must not leave its
  // table in the column list, or the server sees an unknown table.
  final joinedTables = <String>{primary};

  final joinClauses = <String>[];
  // Indices (into [BuilderQuery.joins]) of the joins that really made it into
  // [joinClauses]. The MySQL FULL OUTER mirror branch replays exactly these.
  final renderedJoins = <int>[];
  // MySQL only: the first FULL OUTER join is the pivot of the UNION rewrite.
  // [fullOuterOn] is the reversed ON condition the second branch needs, and
  // [fullOuterJoins] counts every FULL OUTER join (more than one cannot be
  // expressed as a single UNION, see below).
  String? fullOuterRight;
  String? fullOuterLeft;
  String? fullOuterOn;
  int? fullOuterIndex;
  var fullOuterJoins = 0;
  for (var index = 0; index < query.joins.length; index++) {
    final join = query.joins[index];
    final right = join.rightTable;
    if (right.isEmpty) continue;
    if (join.isCross) {
      joinClauses.add('CROSS JOIN ' + emitter.tableRef(right));
      joinedTables.add(right);
      renderedJoins.add(index);
      continue;
    }
    final left = join.leftTable.isEmpty ? primary : join.leftTable;
    if (left.isEmpty || join.leftColumn.isEmpty || join.rightColumn.isEmpty) {
      final crossDatabase =
          emitter.tables[left]?.database != emitter.tables[right]?.database;
      emitter.warnings.add('连接 ' +
          (left.isEmpty ? '?' : left) +
          ' → ' +
          (right.isEmpty ? '?' : right) +
          (crossDatabase
              ? ' 缺少匹配条件：跨库连接无法自动推导外键，请手动选择连接字段'
              : ' 缺少连接字段') +
          '（该表已暂时排除）');
      continue;
    }
    // A join whose left table is itself not part of FROM cannot be rendered:
    // emitting it would reference an unknown table (the same class of bug as the
    // cross-database SELECT leak fixed in round 17). Skip it and say so.
    if (!joinedTables.contains(left)) {
      emitter.warnings.add('连接 ' +
          left +
          ' → ' +
          right +
          ' 的左表尚未接入查询，已跳过该连接');
      continue;
    }
    joinedTables.add(right);
    joinedTables.add(left);
    renderedJoins.add(index);
    final on = emitter.columnRef(left, join.leftColumn) +
        ' = ' +
        emitter.columnRef(right, join.rightColumn);
    if (join.type == 'FULL OUTER') {
      // PostgreSQL and SQLite (>= 3.39) run a native FULL OUTER JOIN; MySQL has
      // no such syntax, so it keeps the ported LEFT ... UNION ... LEFT rewrite.
      if (builderSupportsFullOuter(dialect)) {
        joinClauses.add('FULL OUTER JOIN ' + emitter.tableRef(right) + ' ON ' + on);
      } else {
        // MySQL is the only dialect that reaches this branch, and a FULL OUTER
        // join cannot be written there: render the pair as a LEFT JOIN and let
        // the UNION below add the opposite direction. Only the first pair can
        // become the UNION's pivot, so the others are counted.
        joinClauses.add('LEFT JOIN ' + emitter.tableRef(right) + ' ON ' + on);
        fullOuterJoins++;
        if (fullOuterRight == null) {
          fullOuterRight = right;
          fullOuterLeft = left;
          fullOuterIndex = index;
          fullOuterOn = emitter.columnRef(right, join.rightColumn) +
              ' = ' +
              emitter.columnRef(left, join.leftColumn);
        }
      }
    } else {
      joinClauses.add(join.type + ' JOIN ' + emitter.tableRef(right) + ' ON ' + on);
    }
  }

  // Build the column list from the tables that actually survived the join
  // loop, so an incomplete join cannot leak an unknown table into SELECT.
  final visibleTables =
      participating.where(joinedTables.contains).toList(growable: false);
  final selectTables =
      visibleTables.isEmpty ? participating : visibleTables;
  final selectList = query.outputs.isEmpty
      ? selectTables
          .map((table) => emitter.tableRef(table) + '.*')
          .join(', ')
      : query.outputs.map(columnExpr).join(', ');
  final head = 'SELECT ' + (query.distinct ? 'DISTINCT ' : '') + selectList;

  final where = emitter.whereClause(query.filters);

  // GROUP BY every non-aggregate output when an aggregate is used.
  var groupClause = '';
  if (query.hasAggregate) {
    final raw = query.outputs
        .where((o) => !o.isAggregate)
        .map((o) => emitter.columnRef(o.table, o.column))
        .toList();
    if (raw.isNotEmpty) groupClause = ' GROUP BY ' + raw.join(', ');
  }

  // ORDER BY has to respect the engine's DISTINCT / GROUP BY rules.
  //
  // MySQL (only_full_group_by) and PostgreSQL both reject sorting by a column
  // that is neither in the select list (DISTINCT) nor grouped/aggregated
  // (GROUP BY); SQLite is permissive. Rewriting the sort to the selected output
  // keeps the same query valid on all three instead of failing on two of them,
  // and a sort that cannot be expressed is dropped with a warning rather than
  // silently producing a statement the server rejects.
  // With no explicit outputs the statement selects every column, so any sort
  // column is already in the select list: nothing to rewrite.
  final restrictsSort =
      (query.distinct || query.hasAggregate) && query.outputs.isNotEmpty;
  final orderParts = <String>[];
  for (final order in query.orders) {
    if (!order.hasColumn) continue;
    if (restrictsSort) {
      OutputField? match;
      for (final output in query.outputs) {
        if (output.table == order.table && output.column == order.column) {
          match = output;
          break;
        }
      }
      if (match == null) {
        emitter.warnings.add('去重 / 聚合查询只能按输出字段排序，已忽略排序：' +
            order.table +
            '.' +
            order.column);
        continue;
      }
      final target = match.alias.isNotEmpty
          ? quote(match.alias)
          : match.isAggregate
              ? match.aggregate +
                  '(' +
                  emitter.columnRef(match.table, match.column) +
                  ')'
              : emitter.columnRef(match.table, match.column);
      orderParts.add(target + ' ' + order.dir);
      continue;
    }
    orderParts.add(emitter.columnRef(order.table, order.column) +
        ' ' +
        order.dir);
  }
  final orderClause =
      orderParts.isEmpty ? '' : ' ORDER BY ' + orderParts.join(', ');
  final limitClause = query.limit > 0 ? ' LIMIT ' + query.limit.toString() : '';
  // MySQL has no FULL OUTER JOIN: the first pair is emulated with a UNION of
  // two LEFT JOIN branches (below). More than one such pair cannot be expressed
  // that way, so those queries stay a plain LEFT JOIN query and say so.
  if (dialect == BuilderDialect.mysql && fullOuterJoins > 1) {
    emitter.warnings.add('MySQL 不支持 FULL OUTER JOIN：本次有多个全连接，无法改写为 UNION，'
        '已按 LEFT JOIN 生成 SQL');
  }
  String plainSql() {
    final joins = joinClauses.isEmpty ? '' : '\n' + joinClauses.join('\n');
    return head +
        '\nFROM ' +
        emitter.tableRef(primary) +
        joins +
        where +
        groupClause +
        orderClause +
        limitClause;
  }

  // The unsupported cases fall back to the plain LEFT JOIN form. Checking them
  // here (rather than through a boolean) also promotes the pivot fields to
  // non-null for the rewrite below.
  if (dialect != BuilderDialect.mysql ||
      fullOuterJoins != 1 ||
      fullOuterRight == null ||
      fullOuterLeft == null ||
      fullOuterOn == null ||
      fullOuterIndex == null) {
    return plainSql();
  }

  // MySQL FULL OUTER rewrite: union the two mirrored LEFT JOIN branches.
  //
  // Both branches must select the same column list, so \`table.*\` cannot be
  // used (the two FROM tables differ). Without explicit outputs the rewrite is
  // not expressible; fall back to a plain LEFT JOIN query and say so.
  if (query.outputs.isEmpty) {
    emitter.warnings.add('MySQL 不支持 FULL OUTER JOIN，改写为 UNION 需要先选择输出字段；'
        '已按 LEFT JOIN 生成 SQL');
    return plainSql();
  }

  // The second branch starts from the pivot's right table, re-attaches the
  // pivot's left table with the reversed ON condition, and then appends the
  // remaining joins **exactly as they are** (never mirrored): starting from the
  // other table, a mirrored RIGHT JOIN of the first branch would reference
  // tables this branch never introduced ("Not unique table/alias", round 34
  // P1-01).
  final mirrorTables = <String>{fullOuterRight, fullOuterLeft};
  final mirroredClauses = <String>[
    'LEFT JOIN ' + emitter.tableRef(fullOuterLeft) + ' ON ' + fullOuterOn,
  ];
  var mirrorComplete = true;
  for (final index in renderedJoins) {
    if (index == fullOuterIndex) continue;
    final join = query.joins[index];
    final right = join.rightTable;
    final left = join.leftTable.isEmpty ? primary : join.leftTable;
    // A join hanging off a table only the first branch reaches cannot be
    // rendered here; dropping it would silently change the result.
    if (!mirrorTables.contains(left)) {
      mirrorComplete = false;
      break;
    }
    if (join.isCross) {
      mirroredClauses.add('CROSS JOIN ' + emitter.tableRef(right));
      mirrorTables.add(right);
      continue;
    }
    mirroredClauses.add(join.type +
        ' JOIN ' +
        emitter.tableRef(right) +
        ' ON ' +
        emitter.columnRef(left, join.leftColumn) +
        ' = ' +
        emitter.columnRef(right, join.rightColumn));
    mirrorTables.add(right);
  }
  // A UNION needs both branches to select the same columns; if the table sets
  // differ the rewrite is not expressible, so the statement falls back to a
  // valid (if not "full") LEFT JOIN query instead of invalid SQL.
  if (!mirrorComplete ||
      mirrorTables.length != joinedTables.length ||
      !mirrorTables.containsAll(joinedTables)) {
    emitter.warnings.add('MySQL 不支持 FULL OUTER JOIN：改写为 UNION 需要两个分支的表集合一致，'
        '当前的连接顺序无法满足，已按 LEFT JOIN 生成 SQL');
    return plainSql();
  }

  final leftBranch = head +
      '\nFROM ' +
      emitter.tableRef(primary) +
      (joinClauses.isEmpty ? '' : '\n' + joinClauses.join('\n')) +
      where +
      groupClause;
  // The mirrored branch starts from the FULL OUTER pair's right table, so it
  // has to be rendered as a qualified reference; a bare \`quote(name)\` broke
  // cross-database queries (the namespace was dropped).
  final rightBranch = head +
      '\nFROM ' +
      emitter.tableRef(fullOuterRight) +
      (mirroredClauses.isEmpty ? '' : '\n' + mirroredClauses.join('\n')) +
      where +
      groupClause;
  // A UNION's ORDER BY can only reference the select list; when the sort
  // column is not part of the output, drop it and say so instead of
  // producing a query MySQL rejects.
  var unionOrder = '';
  for (final order in query.orders) {
    if (!order.hasColumn) continue;
    OutputField? match;
    for (final output in query.outputs) {
      if (output.table == order.table && output.column == order.column) {
        match = output;
        break;
      }
    }
    if (match == null) {
      emitter.warnings.add('FULL OUTER 改写为 UNION 时，排序字段 ' +
          order.table +
          '.' +
          order.column +
          ' 不在输出字段中，已忽略该排序');
      continue;
    }
    final target =
        match.alias.isNotEmpty ? quote(match.alias) : quote(match.key);
    unionOrder += (unionOrder.isEmpty ? ' ORDER BY ' : ', ') +
        target +
        ' ' +
        order.dir;
  }
  return leftBranch +
      '\nUNION\n' +
      rightBranch +
      unionOrder +
      limitClause;
}

/// Stable value used by the field pickers: table + NUL + column.
///
/// A record (Dart record type) would also work as a DropdownButton value, but a
/// string keeps the JSON-backed model and the widget layer simple.
String builderFieldKey(String table, String column) => table + '\u0000' + column;

/// Split a [builderFieldKey] back into (table, column).
(String, String) splitBuilderFieldKey(String key) {
  final index = key.indexOf('\u0000');
  if (index < 0) return (key, '');
  return (key.substring(0, index), key.substring(index + 1));
}

/// Suggested join columns for [join], using the schema's declared foreign keys
/// first, then the first shared column name, then the first column of each side.
///
/// Returns a short note when the pair had no obvious relation (the UI shows it
/// as a hint); returns null when a foreign key or shared column was used.
/// True when a join crosses a namespace boundary.
///
/// Cross-database relations cannot be inferred from metadata (a foreign key
/// only exists inside one database), so the ON condition is left to the user
/// instead of guessing from a shared column name.
bool isCrossDatabaseJoin(JoinSpec join, List<BuilderTable> tables) {
  final left = _findTable(tables, join.leftTable);
  final right = _findTable(tables, join.rightTable);
  if (left == null || right == null) return false;
  return left.database != right.database;
}

String? autoFillJoin(JoinSpec join, List<BuilderTable> tables) {
  final left = _findTable(tables, join.leftTable);
  final right = _findTable(tables, join.rightTable);
  if (left == null || right == null) return null;
  if (left.database != right.database) {
    // Cross-database: never guess. Keep whatever the user picked, and only
    // suggest a starting point when nothing is configured yet.
    if (join.leftColumn.isEmpty && join.rightColumn.isEmpty) {
      return '跨库连接无法自动推导外键，请手动选择匹配字段';
    }
    return null;
  }
  for (final fk in left.foreignKeys) {
    if (fk.refTable == right.name) {
      join.leftColumn = fk.column;
      join.rightColumn = fk.refColumn;
      return null;
    }
  }
  for (final fk in right.foreignKeys) {
    if (fk.refTable == left.name) {
      join.leftColumn = fk.refColumn;
      join.rightColumn = fk.column;
      return null;
    }
  }
  for (final leftColumn in left.columns) {
    for (final rightColumn in right.columns) {
      if (leftColumn.name == rightColumn.name) {
        join.leftColumn = leftColumn.name;
        join.rightColumn = rightColumn.name;
        return null;
      }
    }
  }
  if (left.columns.isNotEmpty && right.columns.isNotEmpty) {
    join.leftColumn = left.columns.first.name;
    join.rightColumn = right.columns.first.name;
    return '两个表之间没有明显关系，请确认连接条件。';
  }
  return null;
}

BuilderTable? _findTable(List<BuilderTable> tables, String name) {
  for (final table in tables) {
    if (table.key == name) return table;
  }
  return null;
}

