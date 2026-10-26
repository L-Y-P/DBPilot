// The view assembles status sentences and CSV rows from many small model
// values; explicit concatenation keeps the one-liners readable.
// ignore_for_file: prefer_interpolation_to_compose_strings
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide Text, Tooltip;
import '../text.dart';
import '../tooltip.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../i18n_literals.dart';
import '../builder/builder_editors.dart';
import '../builder/builder_labels.dart';
import '../builder/builder_widgets.dart';
import '../builder/query_model.dart';
import '../notice.dart';
import '../sqlite_sources.dart' show pickAnyFile, pickSavePath, saveTextFile;
import '../theme.dart';
import '../widgets.dart';

/// Rewritten visual query builder.
///
/// Layout follows the whiteboard sketch and the follow-up reviews: a fixed page
/// (no page scroll) with a toolbar, a fixed-size data source panel on the left,
/// and one merged card on the right whose tab bar holds the four configuration
/// sections (output fields / joins / filters / sorting) with a collapsible SQL
/// strip at its bottom. The result preview sits below and owns most of the
/// remaining height. On very short windows the same content falls back to a
/// normal scrolling page with fixed section heights.
///
/// Advanced mode (跨库查询) can join tables from several databases; switching the
/// data source then only extends the table list and never resets the query.
class BuilderView extends StatefulWidget {
  const BuilderView({super.key, required this.notice});

  final Notice notice;

  @override
  State<BuilderView> createState() => _BuilderViewState();
}

class _BuilderViewState extends State<BuilderView> {
  /// Rows shown per result page.
  static const int _pageSize = 50;

  /// Hard cap on rows held for the preview. The user no longer configures a
  /// "max return": the builder always renders at most this many rows, and a
  /// larger result is reported as truncated (use export for everything).
  static const int _previewCap = 1000;

  /// How many foreign-key relations are added automatically after choosing a
  /// primary table. A large schema can reference one table from dozens of
  /// children; the cap keeps the generated query readable and says so.
  static const int _maxAutoJoins = 5;

  /// The SQL strip starts collapsed so the tab body and the result preview get
  /// the vertical space; the one-line summary stays visible in its header.
  bool _sqlExpanded = false;

  /// Tab definitions, in display order.
  static const List<({String key, String label, IconData icon})> _tabs =
      <({String key, String label, IconData icon})>[
    (
      key: 'output',
      label: '输出字段',
      icon: Icons.view_column_outlined,
    ),
    (key: 'join', label: '连接关系', icon: Icons.merge_type),
    (
      key: 'filter',
      label: '筛选条件',
      icon: Icons.filter_alt_outlined,
    ),
    (key: 'sort', label: '排序', icon: Icons.sort),
  ];

  // ---------------------------------------------------------------- schema
  String? _database;
  List<BuilderTable> _tables = <BuilderTable>[];
  bool _loadingSchema = false;
  String? _schemaError;

  /// Advanced mode: the namespaces whose tables are loaded together.
  bool _advanced = false;
  final List<String> _advancedDatabases = <String>[];
  final List<String> _deniedDatabases = <String>[];

  // ----------------------------------------------------------------- query
  BuilderQuery _query = BuilderQuery();
  final TextEditingController _limitController =
      TextEditingController(text: '100');
  final List<ScrollController> _tabScroll =
      List<ScrollController>.generate(4, (_) => ScrollController());
  /// Currently visible configuration tab.
  ///
  /// A [ValueNotifier] rather than plain state: tapping a tab is a purely local
  /// change, and calling [setState] rebuilt the whole page (data source tree,
  /// SQL strip, result preview) for it. Switching tabs between four sections
  /// measured ~37ms per tap, which is what "卡顿" felt like. Only the tab bar
  /// and the tab body listen here now.
  final ValueNotifier<int> _activeTab = ValueNotifier<int>(0);
  String? _note;

  // --------------------------------------------------------------- results
  List<Json> _results = <Json>[];
  List<BuilderPreviewColumn> _previewColumns = <BuilderPreviewColumn>[];
  List<List<Object?>> _previewRows = <List<Object?>>[];
  int _resultRowCount = 0;
  int _previewPage = 0;
  int _elapsedMs = 0;
  bool _running = false;
  bool _hasRun = false;
  bool _previewTruncated = false;
  String? _resultKind;
  String? _runError;

  /// Formats offered by the export dialog, in display order.
  List<Json> _exportFormats = <Json>[];
  String _exportFormat = 'csv';
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _database = AppState.instance.defaultDatabase;
    if (_database != null) {
      _loadSchema();
    }
    _loadExportFormats();
  }

  @override
  void dispose() {
    _limitController.dispose();
    for (final controller in _tabScroll) {
      controller.dispose();
    }
    _activeTab.dispose();
    super.dispose();
  }

  Future<void> _loadExportFormats() async {
    try {
      final formats = await Api.instance.exportFormats();
      if (!mounted) return;
      setState(() {
        // SQL dumps table structure; a free SELECT has none, so it is excluded
        // here (the table page still offers it).
        _exportFormats = formats
            .where((format) => (format['id'] ?? '').toString() != 'sql')
            .toList();
      });
    } catch (_) {
      // The dropdown keeps its built-in defaults when the probe fails.
    }
  }

  BuilderTable? _table(String? key) {
    if (key == null) return null;
    for (final table in _tables) {
      if (table.key == key) return table;
    }
    return null;
  }

  void _syncControllers() {
    _limitController.text = _query.limit.toString();
  }

  Future<void> _loadSchema() async {
    final database = _database;
    setState(() {
      _loadingSchema = true;
      _schemaError = null;
      _tables = <BuilderTable>[];
      _query = BuilderQuery();
      _syncControllers();
      _clearResult();
      _note = null;
      _deniedDatabases.clear();
    });
    if (database == null) {
      setState(() => _loadingSchema = false);
      return;
    }
    try {
      final raw = await Api.instance.builderSchema(database);
      final tables = builderTablesFromSchema(raw);
      if (!mounted) return;
      setState(() {
        _tables = tables;
        _loadingSchema = false;
      });
    } catch (e) {
      if (!mounted) return;
      // A database the account cannot open is dropped from the pickers instead
      // of being offered again on every refresh.
      if (isPermissionError(e)) AppState.instance.markDatabaseDenied(database);
      setState(() {
        _schemaError = e.toString();
        _loadingSchema = false;
      });
    }
  }

  /// Load the tables of every namespace selected in advanced mode.
  ///
  /// Unlike [_loadSchema] this merges into the existing table list and keeps the
  /// query, because switching the data source in advanced mode must not reset
  /// the configuration.
  Future<void> _loadAdvancedSchema() async {
    setState(() {
      _loadingSchema = true;
      _schemaError = null;
      _deniedDatabases.clear();
    });
    try {
      final raw = await Api.instance.builderSchemaMulti(_advancedDatabases);
      final schema = builderTablesFromMultiSchema(raw);
      if (!mounted) return;
      for (final denied in schema.denied) {
        AppState.instance.markDatabaseDenied(denied);
      }
      setState(() {
        _tables = schema.tables;
        _loadingSchema = false;
        _deniedDatabases
          ..clear()
          ..addAll(schema.denied);
        // Drop clauses that reference tables which are no longer loaded.
        final keys = _tables.map((table) => table.key).toSet();
        _query.outputs.removeWhere((output) => !keys.contains(output.table));
        _query.joins.removeWhere((join) =>
            !keys.contains(join.leftTable) && !keys.contains(join.rightTable));
        _query.orders.removeWhere((order) => !keys.contains(order.table));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _schemaError = e.toString();
        _loadingSchema = false;
      });
    }
  }

  /// Turn advanced mode on (or extend the namespace selection).
  ///
  /// Adding / removing a data source in advanced mode must not reset the
  /// query: the existing table keys stay valid as long as their namespace is
  /// still loaded, and clauses that lose their table are pruned instead.
  Future<void> _editAdvancedDatabases() async {
    final picked = await _pickAdvancedDatabases();
    if (picked == null || picked.isEmpty) return;
    final wasAdvanced = _advanced;
    setState(() {
      _advanced = true;
      _advancedDatabases
        ..clear()
        ..addAll(picked);
    });
    if (!wasAdvanced) {
      // Entering advanced mode changes table identities (bare -> db.table),
      // so a query configured against one source cannot be carried over.
      setState(() {
        _query = BuilderQuery();
        _syncControllers();
        _clearResult();
        _note = null;
      });
    }
    await _loadAdvancedSchema();
  }

  /// Leave advanced mode and go back to one data source.
  Future<void> _exitAdvanced() async {
    final confirmed = await confirmDialog(
      context,
      message: '退出高级查询会回到单数据源模式并清空当前配置，是否继续？',
      confirmLabel: '退出高级查询',
    );
    if (!confirmed) return;
    setState(() {
      _advanced = false;
      _advancedDatabases.clear();
      _database = AppState.instance.defaultDatabase;
    });
    await _loadSchema();
  }

  /// Multi-select dialog for the namespaces of an advanced query.
  Future<List<String>?> _pickAdvancedDatabases() async {
    // MySQL / SQLite namespaces are physical databases; PostgreSQL namespaces
    // are schemas inside the active database, so the schema list is the right
    // source there (and the only one the builder can qualify against).
    final state = AppState.instance;
    final candidates = state.isPostgres
        ? state.databases
        : (state.instanceDatabases.isNotEmpty
            ? state.instanceDatabases
            : state.databases);
    final names = <String>[
      for (final entry in candidates)
        (entry['name'] ?? '').toString(),
    ].where((name) => name.isNotEmpty).toList();
    if (names.isEmpty) return null;
    final selected = <String>{
      if (_advancedDatabases.isEmpty) ?_database,
      ..._advancedDatabases,
    };
    final result = await showAppModal<List<String>>(
      context: context,
      title: '高级查询 · 选择数据源',
      wide: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '勾选参与本次查询的数据库 / 模式。跨库连接无法自动推导外键，'
              'ON 条件需要手动选择；没有权限的数据源会被自动跳过。',
              style: kSmallMuted,
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final name in names)
                      Tooltip(
                        message: tooltipText(name),
                        constraints: kTooltipConstraints,
                        waitDuration: const Duration(milliseconds: 300),
                        child: FilterChip(
                          label: Text(name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12)),
                          selected: selected.contains(name),
                          onSelected: (value) => setModalState(() {
                            if (value) {
                              selected.add(name);
                            } else {
                              selected.remove(name);
                            }
                          }),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        Builder(
          builder: (context) =>
              Btn('取消', onPressed: () => Navigator.of(context).pop()),
        ),
        Builder(
          builder: (context) => Btn(
            '确定',
            primary: true,
            onPressed: () =>
                Navigator.of(context).pop(selected.toList()..sort()),
          ),
        ),
      ],
    );
    return result;
  }

  void _clearResult() {
    _results = <Json>[];
    _previewColumns = <BuilderPreviewColumn>[];
    _previewRows = <List<Object?>>[];
    _resultRowCount = 0;
    _previewPage = 0;
    _elapsedMs = 0;
    _hasRun = false;
    _previewTruncated = false;
    _resultKind = null;
  }

  // ------------------------------------------------------------ edit actions

  /// Click a table in the data source tree.
  ///
  /// Selection priority: the first click defines the primary table when none is
  /// set yet; afterwards every click adds / removes that table as a joined
  /// ("接入") table, no matter how many joins exist. Clicking an already
  /// selected table again cancels the selection.
  Future<void> _toggleTable(String key) async {
    if (_running) return;
    final primary = _query.primaryTable;
    if (primary == null) {
      setState(() {
        _query = BuilderQuery()
          ..primaryTable = key
          ..limit = _query.limit;
        _syncControllers();
        _clearResult();
        _runError = null;
        _note = null;
      });
      _autoDeriveJoins(key);
      return;
    }
    if (key == primary) {
      final hasWork = _query.outputs.isNotEmpty ||
          _query.filters.isNotEmpty ||
          _query.orders.isNotEmpty;
      if (hasWork) {
        final confirmed = await confirmDialog(
          context,
          message: '再次点击主表会取消主表并清空当前配置，是否继续？',
          confirmLabel: '取消主表',
        );
        if (!confirmed) return;
      }
      setState(() {
        _query = BuilderQuery()..limit = _query.limit;
        _syncControllers();
        _clearResult();
        _runError = null;
        _note = null;
      });
      return;
    }
    final joined = _query.joins.any((join) => join.rightTable == key);
    if (joined) {
      setState(() {
        _query.joins.removeWhere((join) => join.rightTable == key);
        _pruneDangling();
      });
      return;
    }
    _addJoinForTable(key);
  }

  /// Add every foreign-key relation that involves [primary], in both
  /// directions (the tables it points to and the tables pointing at it).
  ///
  /// Only tables of the same database are considered: a foreign key cannot
  /// cross a database boundary, so a cross-database relation is never guessed.
  void _autoDeriveJoins(String primary) {
    final primaryTable = _table(primary);
    if (primaryTable == null) return;
    final derived = <JoinSpec>[];
    final seen = <String>{primary};
    for (final fk in primaryTable.foreignKeys) {
      final related = _tableOfName(primaryTable.database, fk.refTable);
      if (related == null || seen.contains(related.key)) continue;
      derived.add(JoinSpec(
        type: 'LEFT',
        leftTable: primary,
        rightTable: related.key,
        leftColumn: fk.column,
        rightColumn: fk.refColumn,
      ));
      seen.add(related.key);
    }
    for (final table in _tables) {
      if (seen.contains(table.key)) continue;
      if (table.database != primaryTable.database) continue;
      for (final fk in table.foreignKeys) {
        if (fk.refTable != primaryTable.name) continue;
        derived.add(JoinSpec(
          type: 'LEFT',
          leftTable: primary,
          rightTable: table.key,
          leftColumn: fk.refColumn,
          rightColumn: fk.column,
        ));
        seen.add(table.key);
        break;
      }
    }
    final capped = derived.take(_maxAutoJoins).toList();
    setState(() {
      _query.joins.addAll(capped);
      if (derived.length > capped.length) {
        _note = pickText(
          '已自动推导 ' +
              capped.length.toString() +
              ' 个外键关联（共 ' +
              derived.length.toString() +
              ' 个），其余可在「连接关系」中手动添加',
          'Automatically inferred ' +
              capped.length.toString() +
              ' foreign-key joins (of ' +
              derived.length.toString() +
              '); add the rest manually on the Joins tab',
        );
      } else if (capped.isNotEmpty) {
        _note = pickText(
            '已自动推导 ' + capped.length.toString() + ' 个外键关联',
            'Automatically inferred ' +
                capped.length.toString() +
                ' foreign-key joins');
      }
    });
  }

  /// Resolve a bare table name inside one namespace (empty = current source).
  BuilderTable? _tableOfName(String database, String name) {
    for (final table in _tables) {
      if (table.name == name && table.database == database) return table;
    }
    // Advanced mode may load a table from another namespace than the primary;
    // fall back to the first same-named table so a join still resolves.
    for (final table in _tables) {
      if (table.name == name) return table;
    }
    return null;
  }

  /// Add [key] as a joined table, preferring an existing query table that has
  /// a declared foreign-key relation with it so the ON clause fills itself.
  void _addJoinForTable(String key) {
    final primary = _query.primaryTable;
    if (primary == null) return;
    var left = primary;
    final clicked = _table(key);
    for (final tableName in _query.queryTables()) {
      final table = _table(tableName);
      if (table == null) continue;
      if (table.foreignKeys.any((fk) => fk.refTable == clicked?.name)) {
        left = tableName;
        break;
      }
      if (clicked != null &&
          clicked.foreignKeys.any((fk) => fk.refTable == table.name)) {
        left = tableName;
        break;
      }
    }
    final join = JoinSpec(type: 'LEFT', leftTable: left, rightTable: key);
    final note = autoFillJoin(join, _tables);
    setState(() {
      _query.joins.add(join);
      // A cross-database relation has no metadata to infer from, so point the
      // user at the join tab instead of leaving a silently unusable join.
      _note = note ??
          (isCrossDatabaseJoin(join, _tables)
              ? pickText(
                  '已接入跨库表 ' +
                      (_table(key)?.label ?? key) +
                      '：请在「连接关系」中手动选择匹配字段',
                  'Joined cross-database table ' +
                      (_table(key)?.label ?? key) +
                      ': choose the matching columns on the Joins tab',
                )
              : null);
      _activeTab.value = 1;
    });
  }

  void _toggleOutput(String table, String column) {
    setState(() {
      final index = _query.outputs.indexWhere(
          (output) => output.table == table && output.column == column);
      if (index >= 0) {
        _query.outputs.removeAt(index);
      } else {
        _query.outputs.add(OutputField(table: table, column: column));
      }
    });
  }

  void _addAllOutputs() {
    setState(() {
      for (final tableName in _query.queryTables()) {
        final table = _table(tableName);
        if (table == null) continue;
        for (final column in table.columns) {
          final exists = _query.outputs.any((output) =>
              output.table == tableName && output.column == column.name);
          if (!exists) {
            _query.outputs
                .add(OutputField(table: tableName, column: column.name));
          }
        }
      }
    });
  }

  void _addJoin() {
    final primary = _query.primaryTable;
    if (primary == null) return;
    final participating = _query.queryTables();
    String right = '';
    for (final table in _tables) {
      if (!participating.contains(table.key)) {
        right = table.key;
        break;
      }
    }
    if (right.isEmpty && _tables.length > 1) {
      right = _tables.first.key == primary
          ? _tables[1].key
          : _tables.first.key;
    }
    final join = JoinSpec(
      type: 'LEFT',
      leftTable: primary,
      rightTable: right,
    );
    final note = autoFillJoin(join, _tables);
    setState(() {
      _query.joins.add(join);
      _note = note;
      _pruneDangling();
    });
  }

  void _removeJoin(int index) {
    setState(() {
      _query.joins.removeAt(index);
      _pruneDangling();
    });
  }

  /// Drop clauses that reference a table which is no longer part of the query.
  void _pruneDangling() {
    final tables = _query.queryTables();
    _query.outputs.removeWhere((output) => !tables.contains(output.table));
    _query.orders.removeWhere((order) => !tables.contains(order.table));
    _query.filters.removeWhere((entry) {
      if (entry.isGroup) {
        entry.children.removeWhere(
            (child) => !child.hasColumn || !tables.contains(child.table));
        return entry.children.isEmpty;
      }
      return !entry.condition.hasColumn ||
          !tables.contains(entry.condition.table);
    });
  }

  FilterCondition _newCondition() {
    final primary = _query.primaryTable;
    final table = _table(primary);
    final column = table != null && table.columns.isNotEmpty
        ? table.columns.first.name
        : '';
    return FilterCondition(table: primary ?? '', column: column);
  }

  void _addCondition() {
    setState(() {
      _query.filters.add(FilterEntry.condition(_newCondition()));
    });
  }

  void _addGroup(String logic) {
    setState(() {
      final group = FilterEntry.group(
        logic: logic,
        children: <FilterCondition>[_newCondition()],
      );
      group.connector = 'AND';
      _query.filters.add(group);
    });
  }

  void _addGroupChild(FilterEntry group) {
    setState(() {
      group.children.add(_newCondition());
    });
  }

  void _addOrder() {
    final primary = _query.primaryTable;
    final table = _table(primary);
    final column = table != null && table.columns.isNotEmpty
        ? table.columns.first.name
        : '';
    setState(() {
      _query.orders.add(OrderSpec(table: primary ?? '', column: column));
    });
  }

  void _removeOrder(int index) {
    setState(() => _query.orders.removeAt(index));
  }

  void _onLimitChanged(String value) {
    final parsed = int.tryParse(value);
    setState(() {
      _query.limit = parsed == null ? 0 : parsed.clamp(0, 50000);
    });
  }

  void _reset() {
    setState(() {
      _query = BuilderQuery();
      _syncControllers();
      _clearResult();
      _runError = null;
      _note = null;
    });
  }

  // ---------------------------------------------------------------- SQL/run

  /// The first filter row that needs a value but has none, if any.
  ///
  /// Drives the red hint in the filter tab and the pre-execution guard.
  BuilderMissingValue? get _missingValue =>
      builderMissingConditionValue(_query);

  BuilderSql _buildSql() => buildBuilderSql(
        _query,
        _tables,
        quote: AppState.instance.quoteIdent,
        dialect: _dialect,
        // Qualify every table of the current data source: the statement runs on
        // a pooled connection, which may still carry an empty search_path from
        // a previous script (pg_dump emits
        // SELECT pg_catalog.set_config('search_path', '', false);), and an
        // unqualified name then fails with 42P01 (ROUND68 P1-01).
        defaultNamespace: _advanced ? '' : (_database ?? ''),
      );

  /// Engine the generated SQL is rendered for. The builder branches on this
  /// (native vs emulated FULL OUTER JOIN, ILIKE, literal escaping) instead of
  /// assuming MySQL.
  BuilderDialect get _dialect =>
      builderDialectOf(AppState.instance.driver);

  String _previewSqlText(BuilderSql sql) {
    final buffer = StringBuffer(sql.preview);
    if (sql.hasParams) {
      buffer.write('\n');
      buffer.write(pickText('-- 参数: ', '-- Parameters: '));
      buffer.write(sql.params
          .map((param) => param.placeholder + '=' + param.displayValue)
          .join(', '));
      buffer.write('\n');
      buffer.write(pickText(
          '-- 预览中的占位参数在执行前按驱动规则安全转义为字面量',
          '-- Preview placeholders are safely escaped to literals before execution'));
    }
    return buffer.toString();
  }

  void _copySql() {
    copyText(_previewSqlText(_buildSql()));
    widget.notice.show('已复制 SQL');
  }

  Future<void> _run() async {
    if (_running) return;
    if (_query.primaryTable == null) {
      setState(() => _runError = '请先选择主表');
      return;
    }
    // A row that needs a value but has none is dropped from the SQL, so running
    // the query would silently ignore that filter — and used to send a
    // statement the server rejected (round 34, P2-07). Ask for the value before
    // touching the database instead.
    final missing = _missingValue;
    if (missing != null) {
      final message = pickText(
        '请填写条件值：' + missing.field,
        'Enter a filter value: ' + missing.field,
      );
      setState(() {
        _runError = message;
        _note = message;
      });
      widget.notice.show(message);
      return;
    }
    final sql = _buildSql();
    // Incomplete joins are excluded from the SQL, which keeps the statement
    // valid but silently drops a table the user selected. Say so before the
    // query runs instead of returning a result that is missing columns.
    if (sql.warnings.isNotEmpty) {
      final warning = sql.warnings.first;
      setState(() => _note = warning);
      widget.notice.show(warning);
    }
    setState(() {
      _running = true;
      _runError = null;
    });
    try {
      final response = await Api.instance.query(sql.executable, _database);
      final rawResults = response['results'];
      final results = rawResults is List
          ? rawResults
              .map((entry) => Map<String, dynamic>.from(entry as Map))
              .toList()
          : <Json>[];
      final elapsed = (response['elapsed_ms'] as num?)?.toInt() ?? 0;
      if (!mounted) return;
      setState(() {
        _running = false;
        _elapsedMs = elapsed;
        _results = results;
        _applyFirstResult();
        _previewPage = 0;
      });
    } catch (e) {
      if (!mounted) return;
      // A cross-database query may fail on a database the account cannot open;
      // hide it from the pickers so it is not offered again.
      _markDeniedFromError(e);
      setState(() {
        _running = false;
        _runError = e.toString();
        _clearResult();
      });
    }
  }

  /// Hide the database named in a permission error, if any.
  void _markDeniedFromError(Object error) {
    final text = error.toString();
    if (!isPermissionError(text)) return;
    for (final database in <String>[
      ..._advancedDatabases,
      ?_database,
    ]) {
      if (text.contains(database)) {
        AppState.instance.markDatabaseDenied(database);
        _deniedDatabases.add(database);
      }
    }
  }

  void _applyFirstResult() {
    // Reset only the preview/derived state: _results was just assigned by the
    // caller and must survive this method.
    _previewColumns = <BuilderPreviewColumn>[];
    _previewRows = <List<Object?>>[];
    _resultRowCount = 0;
    _previewPage = 0;
    _previewTruncated = false;
    _resultKind = null;
    _hasRun = true;
    if (_results.isEmpty) return;
    final result = _results.first;
    _resultKind = (result['kind'] ?? '').toString();
    _resultRowCount = (result['row_count'] as num?)?.toInt() ?? 0;
    final error = result['error'];
    if (error != null && error.toString().isNotEmpty) {
      _runError = error.toString();
      return;
    }
    final rawColumns = result['columns'];
    final columns = rawColumns is List
        ? rawColumns
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList()
        : <Json>[];
    _previewColumns = <BuilderPreviewColumn>[
      for (final column in columns)
        BuilderPreviewColumn(
          (column['name'] ?? '').toString(),
          (column['type_name'] ?? '').toString(),
        ),
    ];
    final rawRows = result['rows'];
    final sourceRows = rawRows is List ? rawRows : const <dynamic>[];
    // Convert only the rows the preview can ever show. The previous version
    // copied every row of the result into a List<Object?> (a 50k-row query paid
    // ~50k list copies plus a sublist), then dropped everything past the cap.
    // The full result stays in [_results] for export, which re-runs the SQL and
    // streams from the server.
    final rowCount = sourceRows.length;
    final limit = rowCount > _previewCap ? _previewCap : rowCount;
    final previewRows = <List<Object?>>[];
    for (var index = 0; index < limit; index++) {
      final row = sourceRows[index];
      previewRows.add(row is List ? List<Object?>.from(row) : const <Object?>[]);
    }
    _previewRows = previewRows;
    if (rowCount > _previewCap) _previewTruncated = true;
    if (result['truncated'] == true) _previewTruncated = true;
  }

  // ----------------------------------------------------------- export/module

  /// Export the result through the table page's exchange-format renderers.
  ///
  /// The SQL is streamed straight into the chosen file by Rust, so a large
  /// result never crosses the FFI boundary as one String and every format the
  /// table page supports (CSV / JSON / XML / HTML / TXT / Excel / Markdown) is
  /// available here too.
  Future<void> _exportResult() async {
    if (_running || _exporting) return;
    if (_query.primaryTable == null) {
      widget.notice.show('请先配置查询');
      return;
    }
    final format = _exportFormat;
    final extension = _extensionFor(format);
    try {
      final path = await pickSavePath(
        title: '导出查询结果',
        fileName: 'query_result.$extension',
      );
      if (path == null) return;
      setState(() => _exporting = true);
      try {
        final response = await Api.instance.exportQuery(
          _database ?? '',
          _buildSql().executable,
          <String, dynamic>{'format': format, 'path': path},
        );
        final rows = (response['rows'] as num?)?.toInt() ?? 0;
        widget.notice.show(pickText(
            '已导出 ' + rows.toString() + ' 行到 ' + path,
            'Exported ' + rows.toString() + ' rows to ' + path));
      } catch (e) {
        // A failed stream may leave an empty/partial file behind.
        try {
          final file = File(path);
          if (file.existsSync()) file.deleteSync();
        } catch (_) {
          // Best effort only; the export error is what matters.
        }
        _markDeniedFromError(e);
        setState(() => _runError =
            pickText('导出失败：', 'Export failed: ') + e.toString());
      } finally {
        if (mounted) setState(() => _exporting = false);
      }
    } catch (e) {
      setState(() =>
          _runError = pickText('导出失败：', 'Export failed: ') + e.toString());
    }
  }

  String _extensionFor(String format) {
    switch (format) {
      case 'markdown':
        return 'md';
      case 'excel':
        return 'xls';
      default:
        return format;
    }
  }

  Future<void> _saveModule() async {
    final payload = <String, dynamic>{
      'app': 'rust-myadmin-query-module',
      'version': 2,
      'saved_at': DateTime.now().toIso8601String(),
      'database': _database,
      'advanced': _advanced,
      'advanced_databases': _advancedDatabases,
      'query': _query.toJson(),
      'sql': _buildSql().preview,
    };
    try {
      final path = await saveTextFile(
        content: const JsonEncoder.withIndent('  ').convert(payload),
        title: '保存查询模块',
        fileName: ((_query.primaryTable ?? 'query') + '_module.json'),
      );
      if (path != null) widget.notice.show('查询模块已保存');
    } catch (e) {
      widget.notice.show('保存失败：' + e.toString());
    }
  }

  Future<void> _openModule() async {
    try {
      final path = await pickAnyFile(title: '打开查询模块');
      if (path == null) return;
      final text = await File(path).readAsString();
      final decoded = jsonDecode(text);
      if (decoded is! Map) throw const FormatException('文件内容不是查询模块');
      final map = Map<String, dynamic>.from(decoded);
      final queryRaw = map['query'];
      if (queryRaw is! Map) throw const FormatException('缺少 query 字段');
      final loaded =
          BuilderQuery.fromJson(Map<String, dynamic>.from(queryRaw));
      final advanced = map['advanced'] == true;
      final advancedDatabases = <String>[
        for (final raw in (map['advanced_databases'] as List?) ?? <Object?>[])
          raw.toString(),
      ].where((name) => name.isNotEmpty).toList();
      if (advanced && advancedDatabases.isNotEmpty) {
        setState(() {
          _advanced = true;
          _advancedDatabases
            ..clear()
            ..addAll(advancedDatabases);
        });
        await _loadAdvancedSchema();
      } else {
        final database = (map['database'] ?? '').toString();
        final databases = AppState.instance.databases
            .map((entry) => (entry['name'] ?? '').toString())
            .toList();
        final target =
            database.isNotEmpty && databases.contains(database)
                ? database
                : _database;
        final changed = target != _database;
        if (target != null) {
          setState(() => _database = target);
          if (changed) await _loadSchema();
        }
      }
      if (!mounted) return;
      setState(() {
        _query = loaded;
        _syncControllers();
        _clearResult();
        _runError = null;
        _note = null;
      });
      widget.notice.show('已打开查询模块');
    } catch (e) {
      setState(() => _runError = '打开查询模块失败：' + e.toString());
    }
  }

  Future<void> _editAlias(OutputField field) async {
    final controller = TextEditingController(text: field.alias);
    final result = await showAppModal<String>(
      context: context,
      title: '输出别名',
      builder: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
              pickText('为 ', 'Set an SQL alias for ') +
                  field.key +
                  pickText(' 设置 SQL 别名，留空表示不设置。',
                      '; leave blank to keep the default.'),
              style: kSmallMuted),
          const SizedBox(height: 10),
          TextField(
            controller: controller,
            autofocus: true,
            style: monoStyle(size: 12),
            decoration: InputDecoration(
              isDense: true,
              hintText: trLiteral('例如 total_amount'),
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        Builder(
          builder: (context) => Btn('取消',
              onPressed: () => Navigator.of(context).pop()),
        ),
        Builder(
          builder: (context) => Btn('确定',
              primary: true,
              onPressed: () =>
                  Navigator.of(context).pop(controller.text.trim())),
        ),
      ],
    );
    controller.dispose();
    if (result == null) return;
    setState(() => field.alias = result);
  }

  // ------------------------------------------------------------------ layout

  @override
  Widget build(BuildContext context) {
    // A full rebuild means the query (or a related input) may have changed:
    // drop the memoised tab pages so they are rebuilt from the current state.
    _invalidateTabCache();
    final sql = _buildSql();
    return LayoutBuilder(
      builder: (context, constraints) {
        // Below this height the fixed layout cannot show the data source, the
        // configuration card and the result preview at once, so the page
        // scrolls instead.
        final compact = constraints.maxHeight < 640;
        const padding = AppMetrics.mainPadding;
        return Padding(
          padding: EdgeInsets.all(padding),
          child: compact
              ? SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _toolbar(),
                      NoticeBanner(widget.notice),
                      const SizedBox(height: 8),
                      SizedBox(height: 240, child: _dataSourcePanelCached()),
                      const SizedBox(height: 8),
                      SizedBox(height: 380, child: _configCard(sql)),
                      const SizedBox(height: 10),
                      SizedBox(height: 460, child: _resultCard(sql)),
                    ],
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _toolbar(),
                    NoticeBanner(widget.notice),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: _dataSourceWidth(constraints.maxWidth),
                            child: _dataSourcePanelCached(),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.stretch,
                              children: [
                                // The merged configuration card keeps the SQL
                                // strip inside it; the result preview below gets
                                // the larger share of the page height.
                                Expanded(flex: 4, child: _configCard(sql)),
                                const SizedBox(height: 10),
                                Expanded(flex: 6, child: _resultCard(sql)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  // The panel narrows on smaller pages so the configuration card and the
  // result preview keep enough room.
  double _dataSourceWidth(double pageWidth) =>
      pageWidth < 1100 ? 272 : 300;

  Widget _toolbar() {
    final actions = <Widget>[
      Btn(
        _advanced ? '编辑数据源' : '高级查询',
        key: const ValueKey('builder-advanced'),
        icon: Icons.hub_outlined,
        tooltip: _advanced
            ? '增加 / 移除跨库查询的数据源（不会重置当前配置）'
            : '跨库查询：选择多个数据源',
        onPressed: _running ? null : _editAdvancedDatabases,
      ),
      if (_advanced)
        IconBtn(
          Icons.close,
          key: const ValueKey('builder-exit-advanced'),
          tooltip: '退出高级查询',
          onPressed: _running ? null : _exitAdvanced,
        ),
      IconBtn(
        Icons.folder_open,
        tooltip: '打开查询模块',
        onPressed: _openModule,
      ),
      Btn(
        '重置',
        key: const ValueKey('builder-reset'),
        tooltip: '清空当前查询的全部配置',
        onPressed: _reset,
      ),
      Btn(
        _running ? '执行中…' : '执行查询',
        key: const ValueKey('builder-run'),
        primary: true,
        busy: _running,
        icon: Icons.play_arrow,
        onPressed: _running ? null : _run,
      ),
    ];
    final dataSource = _advanced
        ? BuilderTag(
            pickText('跨库 · ', 'Cross-database · ') +
                _advancedDatabases.join(' / '),
            tone: builderPurpleTone,
            icon: Icons.hub_outlined,
            maxWidth: 300,
            tooltip: _advancedDatabases.join(', '),
          )
        : BuilderDrop<String>(
            value: _database,
            width: 190,
            hint: '选择数据源',
            tooltip: '当前连接下的数据库 / 模式',
            items: [
              for (final database in AppState.instance.databases)
                if (!AppState.instance
                    .isDatabaseDenied((database['name'] ?? '').toString()))
                  DropdownMenuItem<String>(
                    value: (database['name'] ?? '').toString(),
                    child: Text(
                      dataSourceOptionLabel(
                        (database['name'] ?? '').toString(),
                        database: AppState.instance.activeDatabase,
                        postgres: AppState.instance.isPostgres,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
            ],
            onChanged: (value) {
              if (value == null || value == _database) return;
              setState(() => _database = value);
              _loadSchema();
            },
          );
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _run,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _run,
      },
      child: PageHead(
        key: const ValueKey('builder-toolbar'),
        titleWidget: Text(
          '查询构建器',
          style: monoStyle(size: 20, weight: FontWeight.w600),
        ),
        meta: [
          Text('数据源（库/模式）', style: kSmallMuted),
          dataSource,
          _statusChip(),
        ],
        actions: actions,
      ),
    );
  }

  Widget _statusChip() {
    BuilderTone tone;
    IconData icon;
    String text;
    if (_loadingSchema) {
      tone = builderInfoTone;
      icon = Icons.sync;
      text = '正在加载表结构…';
    } else if (!_advanced && _database == null) {
      tone = builderWarnTone;
      icon = Icons.warning_amber_rounded;
      text = '请先选择数据源';
    } else if (_query.primaryTable == null) {
      tone = builderWarnTone;
      icon = Icons.warning_amber_rounded;
      text = '请选择主表';
    } else {
      tone = builderOkTone;
      icon = Icons.check_circle_outline;
      final primary = _table(_query.primaryTable);
      text = pickText('主表：', 'Main table: ') +
          (primary?.label ?? _query.primaryTable!);
      final joined = _query.joins.length;
      if (joined > 0) {
        text = text +
            pickText(' · 接入 ' + joined.toString() + ' 个',
                ' · ' + joined.toString() + ' joined');
      }
    }
    return BuilderTag(
      text,
      tone: tone,
      icon: icon,
      maxWidth: 300,
      tooltip: _statusTooltip(),
    );
  }

  /// Explanation for the toolbar status badge; the badge itself is width-capped
  /// and can ellipsize, so hovering it must reveal both the full text and what
  /// to do next (round 18: no truncated container without a hover read-out).
  String _statusTooltip() {
    if (_loadingSchema) return '正在读取当前数据源的表结构';
    if (!_advanced && _database == null) return '请先选择要查询的数据库 / 模式';
    if (_query.primaryTable == null) {
      return '在主表中点击一张表作为查询的主表（FROM 表）';
    }
    final primary = _table(_query.primaryTable);
    return pickText(
      '主表：' +
          (primary?.label ?? _query.primaryTable!) +
          '；点其他表可接入连接，点字段可加入输出',
      'Main table: ' +
          (primary?.label ?? _query.primaryTable!) +
          '; click another table to join it, or a column to add it to the output',
    );
  }

  /// Memoised data source panel.
  ///
  /// The panel is the most expensive subtree on the page (every table and
  /// column is a widget), and a full-page rebuild happens for every query edit
  /// — including edits the panel does not depend on (sorting, DISTINCT, an
  /// alias). Returning the *same widget instance* lets Flutter's updateChild
  /// fast path skip the whole subtree. The signature covers every input the
  /// panel reads, so a real change still rebuilds it.
  Widget? _panelCache;
  String? _panelSignature;

  String _panelSignatureNow() {
    final buffer = StringBuffer()
      // The language is part of the signature: the memoised panel instance
      // carries copy translated at build time, so returning the cached widget
      // after a language switch kept the previous language on screen until the
      // page was rebuilt (round 34, P3-08a).
      ..write(I18n.current.name)
      ..write('|')
      ..write(identityHashCode(_tables))
      ..write('|')
      ..write(_query.primaryTable ?? '')
      ..write('|')
      ..write(_query.queryTables().join(','))
      ..write('|');
    for (final output in _query.outputs) {
      buffer
        ..write(output.key)
        ..write(',');
    }
    buffer
      ..write('|')
      ..write(_loadingSchema)
      ..write('|')
      ..write(_schemaError ?? '')
      ..write('|')
      ..write(_running)
      ..write('|')
      ..write(_advanced)
      ..write('|')
      ..write(_deniedDatabases.join(','));
    return buffer.toString();
  }

  Widget _dataSourcePanelCached() {
    final signature = _panelSignatureNow();
    if (_panelCache != null && signature == _panelSignature) {
      return _panelCache!;
    }
    _panelSignature = signature;
    _panelCache = _dataSourcePanel();
    return _panelCache!;
  }

  Widget _dataSourcePanel() {
    final outputKeys = _query.outputs.map((output) => output.key).toSet();
    return BuilderDataSourcePanel(
      key: const ValueKey('builder-data-source'),
      tables: _tables,
      primaryTable: _query.primaryTable,
      participating: _query.queryTables().toSet(),
      outputKeys: outputKeys,
      loading: _loadingSchema,
      error: _schemaError,
      enabled: !_running,
      groupByDatabase: _advanced,
      deniedDatabases: _deniedDatabases,
      onToggleTable: _toggleTable,
      onToggleOutput: _toggleOutput,
    );
  }

  // ------------------------------------------------------- merged config card

  Widget _configCard(BuilderSql sql) {
    return Container(
      key: const ValueKey('builder-config'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppMetrics.radiusCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Only these two rebuild when the tab changes: the surrounding page
          // (data source, SQL strip, result preview) is untouched by a switch.
          ValueListenableBuilder<int>(
            valueListenable: _activeTab,
            builder: (context, _, child) => _tabBar(),
          ),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: _activeTab,
              builder: (context, _, child) => _tabBody(),
            ),
          ),
          _sqlStrip(sql),
        ],
      ),
    );
  }

  Widget _tabBar() {
    return Container(
      height: 38,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          for (var index = 0; index < _tabs.length; index++) _tabButton(index),
          const Spacer(),
          if (_advanced && _advancedDatabases.length > 1)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: BuilderTag(
                '跨库查询 · 外键需手动',
                tone: builderWarnTone,
                icon: Icons.info_outline,
              ),
            ),
        ],
      ),
    );
  }

  Widget _tabButton(int index) {
    final tab = _tabs[index];
    final active = _activeTab.value == index;
    final count = _tabCount(index);
    return InkWell(
      key: ValueKey('builder-tab-' + tab.key),
      onTap: () => _activeTab.value = index,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? AppColors.header : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              tab.icon,
              size: 14,
              color: active ? AppColors.header : AppColors.muted,
            ),
            const SizedBox(width: 5),
            Text(
              tab.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                color: active ? AppColors.header : AppColors.muted,
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 5),
              BuilderTag(
                count.toString(),
                tone: active ? builderPrimaryTone : builderNeutralTone,
              ),
            ],
          ],
        ),
      ),
    );
  }

  int _tabCount(int index) {
    switch (index) {
      case 0:
        return _query.outputs.length;
      case 1:
        return _query.joins.length;
      case 2:
        return _query.filterCount;
      default:
        return _query.orders.length;
    }
  }

  /// Built pages of the four tabs, kept alive until the next full rebuild.
  ///
  /// Switching tabs used to inflate the target page from scratch (and the four
  /// sections differ a lot in cost). Keeping each page's element tree alive
  /// makes a return visit an index change plus layout instead of a rebuild; the
  /// cache is dropped whenever [build] runs, because that is when the query may
  /// have changed and a cached page could be stale.
  final List<Widget?> _tabCache = List<Widget?>.filled(4, null);

  void _invalidateTabCache() {
    for (var i = 0; i < _tabCache.length; i++) {
      _tabCache[i] = null;
    }
  }

  Widget _tabBody() {
    final index = _activeTab.value;
    _tabCache[index] ??= _buildTabPage(index);
    return IndexedStack(
      index: index,
      sizing: StackFit.expand,
      children: [
        for (var i = 0; i < _tabCache.length; i++)
          _tabCache[i] ?? const SizedBox.shrink(),
      ],
    );
  }

  Widget _buildTabPage(int index) {
    final controller = _tabScroll[index];
    return Scrollbar(
      controller: controller,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        child: switch (index) {
          0 => _outputTab(),
          1 => _joinTab(),
          2 => _filterTab(),
          _ => _sortTab(),
        },
      ),
    );
  }

  /// Compact right-aligned action row shared by every tab.
  Widget _tabActions(List<Widget> actions) {
    return Row(
      children: [
        const Spacer(),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: actions,
        ),
      ],
    );
  }

  Widget _outputTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _tabActions([
          Tooltip(
            message: '相同的查询结果只保留一条',
            waitDuration: const Duration(milliseconds: 300),
            child: CheckBox(
              label: distinctLabel(),
              value: _query.distinct,
              onChanged: (value) => setState(() => _query.distinct = value),
            ),
          ),
          Btn('全部', small: true, onPressed: _addAllOutputs),
          Btn(
            '清空',
            small: true,
            onPressed: _query.outputs.isEmpty
                ? null
                : () => setState(_query.outputs.clear),
          ),
        ]),
        const SizedBox(height: 8),
        if (_query.outputs.isEmpty)
          // Not const: the copy is translated at build time, and a const
          // instance would keep the previous language after a switch.
          BuilderEmptyHint(
            icon: Icons.touch_app_outlined,
            text: trLiteral('在左侧数据源点击字段即可加入输出；「全部」返回所有参与表的字段'),
            padding: EdgeInsets.symmetric(vertical: 12),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final field in _query.outputs)
                BuilderOutputChip(
                  key: ObjectKey(field),
                  field: field,
                  onAggregateChanged: (value) =>
                      setState(() => field.aggregate = value),
                  onEditAlias: () => _editAlias(field),
                  onRemove: () => setState(() => _query.outputs.remove(field)),
                ),
            ],
          ),
      ],
    );
  }

  Widget _joinTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _tabActions([
          Btn(
            '+ 添加连接',
            key: const ValueKey('builder-add-join'),
            small: true,
            tooltip: '把另一张表接入查询，并设置两张表的匹配字段',
            onPressed: _query.primaryTable == null ? null : _addJoin,
          ),
        ]),
        const SizedBox(height: 8),
        if (_query.joins.isEmpty)
          BuilderEmptyHint(
            icon: Icons.merge,
            text: '点击数据源中的其他表即可接入；同库外键关系会自动填入匹配字段，跨库需手动选择匹配字段',
            padding: const EdgeInsets.symmetric(vertical: 12),
          )
        else
          for (var i = 0; i < _query.joins.length; i++)
            BuilderJoinRow(
              key: ObjectKey(_query.joins[i]),
              index: i,
              join: _query.joins[i],
              tables: _tables,
              participating: _query.queryTables(),
              onChanged: () => setState(_pruneDangling),
              onRemove: () => _removeJoin(i),
            ),
        if (_note != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline,
                    size: 12, color: AppColors.warnText),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _note!,
                    style: TextStyle(
                        fontSize: 11, color: AppColors.warnText),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _filterTab() {
    final filters = _query.filters;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _tabActions([
          Btn(
            '+ 条件',
            key: const ValueKey('builder-add-condition'),
            small: true,
            tooltip: '添加一条筛选条件',
            onPressed: _query.primaryTable == null ? null : _addCondition,
          ),
          Btn(
            '+ AND 组',
            key: const ValueKey('builder-add-group-and'),
            small: true,
            tooltip: '添加一组需要同时满足的条件',
            onPressed:
                _query.primaryTable == null ? null : () => _addGroup('AND'),
          ),
          Btn(
            '+ OR 组',
            key: const ValueKey('builder-add-group-or'),
            small: true,
            tooltip: '添加一组满足任意一条即可的条件',
            onPressed:
                _query.primaryTable == null ? null : () => _addGroup('OR'),
          ),
        ]),
        const SizedBox(height: 8),
        if (filters.isEmpty)
          BuilderEmptyHint(
            icon: Icons.filter_alt_off_outlined,
            text: trLiteral(
                '还没有筛选条件。可用「+ 条件」添加单条条件，或用「+ AND 组 / + OR 组」添加一组条件'),
            padding: EdgeInsets.symmetric(vertical: 12),
          )
        else
          for (var i = 0; i < filters.length; i++)
            if (filters[i].isGroup)
              BuilderFilterGroupCard(
                key: ObjectKey(filters[i]),
                entry: filters[i],
                tables: _tables,
                participating: _query.queryTables(),
                operators: builderOperatorsFor(_dialect),
                onChanged: () => setState(() {}),
                onRemove: () => setState(() => filters.remove(filters[i])),
                onAddChild: () => _addGroupChild(filters[i]),
              )
            else
              BuilderFilterConditionRow(
                key: ObjectKey(filters[i].condition),
                index: i + 1,
                condition: filters[i].condition,
                tables: _tables,
                participating: _query.queryTables(),
                operators: builderOperatorsFor(_dialect),
                connector: _rootConnector(filters[i], i),
                onChanged: () => setState(() {}),
                onRemove: () => setState(() => filters.remove(filters[i])),
              ),
        // The empty value keeps the query from running (see [_run]); mark it in
        // red next to the rows instead of only reporting it on click.
        if (_missingValue != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, size: 12, color: AppColors.danger),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    pickText(
                      '请填写条件值：' + _missingValue!.field,
                      'Enter a filter value: ' + _missingValue!.field,
                    ),
                    style: TextStyle(fontSize: 11, color: AppColors.danger),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _rootConnector(FilterEntry entry, int index) {
    if (index == 0) {
      return BuilderTag(
        whereLabel(),
        tone: builderInfoTone,
        tooltip: '以下条件共同决定查询结果',
        maxWidth: 130,
      );
    }
    return BuilderDrop<String>(
      value: entry.connector,
      width: 104,
      tooltip: '这一条件与上一条件如何组合',
      items: [
        for (final logic in <String>['AND', 'OR'])
          DropdownMenuItem<String>(
            value: logic,
            child: Text(
              connectorLabel(logic),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
      ],
      selectedLabel: connectorLabel,
      menuWidth: 170,
      onChanged: (value) {
        setState(() => entry.connector = value ?? 'AND');
      },
    );
  }

  Widget _sortTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _tabActions([
          Btn(
            '+ 添加排序',
            key: const ValueKey('builder-add-order'),
            small: true,
            tooltip: '按某个字段升序或降序排列结果',
            onPressed: _query.primaryTable == null ? null : _addOrder,
          ),
        ]),
        const SizedBox(height: 8),
        if (_query.orders.isEmpty)
          BuilderEmptyHint(
            icon: Icons.sort,
            text: trLiteral('还没有排序字段，点击「+ 添加排序」选择主表字段'),
            padding: EdgeInsets.symmetric(vertical: 12),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < _query.orders.length; i++)
                BuilderSortChip(
                  key: ObjectKey(_query.orders[i]),
                  order: _query.orders[i],
                  onChanged: () => setState(() {}),
                  onRemove: () => _removeOrder(i),
                ),
            ],
          ),
        const SizedBox(height: 12),
        Divider(height: 1, color: AppColors.border),
        const SizedBox(height: 10),
        BuilderLimitFields(
          limitController: _limitController,
          onLimitChanged: _onLimitChanged,
        ),
      ],
    );
  }

  Widget _sqlStrip(BuilderSql sql) {
    final preview = _previewSqlText(sql);
    final oneLine = preview.replaceAll('\n', ' ');
    return Container(
      key: const ValueKey('builder-sql-preview'),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            key: const ValueKey('builder-sql-toggle'),
            onTap: () => setState(() => _sqlExpanded = !_sqlExpanded),
            child: SizedBox(
              height: 32,
              child: Row(
                children: [
                  const SizedBox(width: 10),
                  Icon(Icons.code, size: 14, color: AppColors.muted),
                  const SizedBox(width: 6),
                  Text(
                    'SQL 预览',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.cardHeading,
                    ),
                  ),
                  if (sql.hasParams) ...[
                    const SizedBox(width: 6),
                    Text(
                      pickText('参数 ' + sql.params.length.toString(),
                          sql.params.length.toString() + ' parameters'),
                      style:
                          TextStyle(fontSize: 10, color: AppColors.muted),
                    ),
                  ],
                  if (sql.warnings.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: tooltipText(sql.warnings.join('\n')),
                      constraints: kTooltipConstraints,
                      child: Icon(Icons.warning_amber_rounded,
                          size: 14, color: AppColors.warnText),
                    ),
                  ],
                  const SizedBox(width: 8),
                  Expanded(
                    child: Tooltip(
                      message: tooltipText(preview),
                      constraints: kTooltipConstraints,
                      child: Text(
                        oneLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(size: 11.5, color: AppColors.muted),
                      ),
                    ),
                  ),
                  IconBtn(
                    Icons.copy,
                    key: const ValueKey('builder-copy-sql'),
                    tooltip: '复制 SQL',
                    small: true,
                    onPressed: _copySql,
                  ),
                  IconBtn(
                    _sqlExpanded ? Icons.expand_more : Icons.expand_less,
                    tooltip: _sqlExpanded ? '收起 SQL' : '展开 SQL',
                    small: true,
                    onPressed: () =>
                        setState(() => _sqlExpanded = !_sqlExpanded),
                  ),
                  const SizedBox(width: 6),
                ],
              ),
            ),
          ),
          if (_sqlExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: SizedBox(
                height: 110,
                child: CodeBlock(preview, dark: true, maxHeight: 110),
              ),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- result card

  Widget _resultCard(BuilderSql sql) {
    final summary = _resultSummary(sql);
    return Container(
      key: const ValueKey('builder-result-preview'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppMetrics.radiusCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.table_view_outlined,
                  size: 15, color: AppColors.muted),
              const SizedBox(width: 6),
              Text(
                '结果预览',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.cardHeading,
                ),
              ),
              if (summary.isNotEmpty) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: EllipsisText(
                    summary,
                    style:
                        TextStyle(fontSize: 11, color: AppColors.muted),
                  ),
                ),
              ] else
                const Spacer(),
              if (_running)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(child: _resultBody(sql)),
          _resultFooter(),
        ],
      ),
    );
  }

  String _resultSummary(BuilderSql sql) {
    if (!_hasRun) return '';
    final parts = <String>[];
    if (sql.groupBy.isNotEmpty) {
      parts.add(pickText('按 ' + sql.groupBy.join('、') + ' 分组',
          'Grouped by ' + sql.groupBy.join(', ')));
    }
    parts.add(pickText('共 ' + _resultRowCount.toString() + ' 条',
        _resultRowCount.toString() + ' rows'));
    // A one-to-many join repeats the primary row once per child, so the count
    // is no longer the primary table's row count. Say which tables cause it
    // instead of leaving users to read the rows as duplicates (ROUND68 P3-02).
    final amplifiers = builderJoinRowAmplifiers(_query, _tables);
    if (amplifiers.isNotEmpty && _resultRowCount > 0) {
      parts.add(pickText(
          '一对多连接可能放大行数（' + amplifiers.join('、') + '）',
          'one-to-many joins can multiply rows: ' + amplifiers.join(', ')));
    }
    if (_elapsedMs > 0) {
      parts.add(pickText('耗时 ' + _elapsedMs.toString() + 'ms',
          'took ' + _elapsedMs.toString() + 'ms'));
    }
    if (_previewTruncated) {
      parts.add(pickText('仅预览前 ' + _previewRows.length.toString() + ' 条',
          'previewing the first ' + _previewRows.length.toString() + ' rows'));
    }
    return parts.join(' · ');
  }

  Widget _resultBody(BuilderSql sql) {
    if (_runError != null) {
      return SingleChildScrollView(child: AlertBox(_runError!));
    }
    if (!_hasRun) {
      return BuilderEmptyHint(
        icon: Icons.play_circle_outline,
        text: trLiteral('选择主表并配置好查询后，点击「执行查询」在这里查看结果'),
      );
    }
    if (_resultKind != 'rows') {
      return Center(
        child: AlertBox(
          (sql.warnings.isEmpty
                  ? ''
                  : sql.warnings.join(pickText('；', '; ')) + '  ') +
              _resultRowCount.toString() +
              pickText(' 行受影响', ' rows affected'),
          tone: AlertTone.ok,
        ),
      );
    }
    if (_previewColumns.isEmpty) {
      return BuilderEmptyHint(
        icon: Icons.inbox_outlined,
        text: trLiteral('查询没有返回数据行'),
      );
    }
    final pages = _pageCount();
    final page = _previewPage.clamp(0, pages - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_previewTruncated)
          Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
              '结果行数超过预览上限，仅显示前 1000 行；导出会包含完整结果。',
              style: TextStyle(fontSize: 10, color: AppColors.warnText),
            ),
          ),
        Expanded(child: _previewTableCached(page)),
      ],
    );
  }

  /// Memoised preview table, one instance per result page.
  ///
  /// The preview is the heaviest subtree once a query has run: a 40-column
  /// result page renders ~950 cells (each an [EllipsisText]). Rebuilding them on
  /// an edit that cannot change the rows — toggling DISTINCT, sorting, an alias
  /// — measured 216ms per rebuild, and every page turn cost another 225ms.
  ///
  /// The cache is keyed by the *identity* of the result lists plus the page
  /// number, so:
  ///  * an unrelated edit reuses the table widget instance and Flutter's
  ///    `updateChild` fast path skips the whole subtree;
  ///  * a new run (new `_previewRows`) or a different page builds a new table;
  ///  * returning to a page already visited in this run reuses its instance.
  List<BuilderPreviewColumn>? _previewCacheColumns;
  List<List<Object?>>? _previewCacheRows;
  final Map<int, Widget> _previewPageCache = <int, Widget>{};

  /// Language the cached preview pages were built in; the table's own empty
  /// state is translated, so a language switch has to rebuild it (P3-08a).
  AppLang? _previewCacheLang;

  Widget _previewTableCached(int page) {
    if (!identical(_previewCacheColumns, _previewColumns) ||
        !identical(_previewCacheRows, _previewRows) ||
        _previewCacheLang != I18n.current) {
      _previewCacheColumns = _previewColumns;
      _previewCacheRows = _previewRows;
      _previewCacheLang = I18n.current;
      _previewPageCache.clear();
    }
    final cached = _previewPageCache[page];
    if (cached != null) return cached;
    // Slice the page only when it is actually built; on a cache hit (unrelated
    // edit, paging back to a visited page) no row list is allocated at all.
    final start = page * _pageSize;
    final end = start + _pageSize;
    final pageRows = _previewRows.sublist(
      start,
      end > _previewRows.length ? _previewRows.length : end,
    );
    return _previewPageCache[page] = BuilderPreviewTable(
      columns: _previewColumns,
      rows: pageRows,
    );
  }

  int _pageCount() {
    if (_previewRows.isEmpty) return 1;
    return (_previewRows.length + _pageSize - 1) ~/ _pageSize;
  }

  Widget _resultFooter() {
    if (_resultKind != 'rows' || _previewColumns.isEmpty) {
      return const SizedBox.shrink();
    }
    final pages = _pageCount();
    final page = _previewPage.clamp(0, pages - 1);
    final buttons = Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        BuilderDrop<String>(
          value: _exportFormat,
          width: 108,
          hint: '格式',
          tooltip: '导出格式（与表页导出一致）',
          items: [
            for (final format in _exportFormats)
              DropdownMenuItem<String>(
                value: (format['id'] ?? '').toString(),
                child: Text(
                  (format['label'] ?? format['id'] ?? '').toString(),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
          onChanged: (value) =>
              setState(() => _exportFormat = value ?? 'csv'),
        ),
        Btn(
          _exporting ? '导出中…' : '导出结果',
          key: const ValueKey('builder-export'),
          small: true,
          busy: _exporting,
          onPressed: _exporting ? null : _exportResult,
        ),
        Btn(
          '保存为查询模块',
          key: const ValueKey('builder-save-module'),
          small: true,
          onPressed: _saveModule,
        ),
      ],
    );
    final pagination = BuilderPagination(
      page: page,
      pageCount: pages,
      totalRows: _previewRows.length,
      pageSize: _pageSize,
      onPage: (value) => setState(() => _previewPage = value),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 720) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                buttons,
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: pagination,
                ),
              ],
            );
          }
          return Row(
            children: [
              buttons,
              const Spacer(),
              pagination,
            ],
          );
        },
      ),
    );
  }
}
