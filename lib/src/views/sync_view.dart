import 'package:flutter/material.dart' hide Text, Tooltip;
import '../text.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../i18n_literals.dart';
import '../nav.dart';
import '../notice.dart';
import '../theme.dart';
import '../widgets.dart';

/// Schema compare and sync between two user namespaces of the active
/// connection (databases on MySQL, schemas on PostgreSQL, attached files on
/// SQLite).
///
/// Ported from the web Sync.vue, with three fixes learned from real use:
///
///  * system namespaces (information_schema, pg_catalog, ...) are not offered;
///    the old defaults picked `information_schema` and produced an empty diff,
///    which looked exactly like "structure sync is not implemented";
///  * the source defaults to the database being browsed (PostgreSQL: public),
///    not to whatever the server happened to list first;
///  * the optional table filter is a picker populated from the source instead
///    of a free-text field the user had to guess.
class SyncView extends StatefulWidget {
  const SyncView({super.key, required this.notice});
  final Notice notice;

  @override
  State<SyncView> createState() => _SyncViewState();
}

class _SyncViewState extends State<SyncView> {
  /// Source/target namespace: a schema on PostgreSQL, a database on MySQL /
  /// SQLite. `_sourceDatabase` is the physical database for PostgreSQL only.
  String? _source;
  String? _target;
  String? _sourceDatabase;
  String? _targetDatabase;

  List<Json> _sourceSchemas = <Json>[];
  List<Json> _targetSchemas = <Json>[];
  String? _sourceSchemasDb;
  String? _targetSchemasDb;
  bool _sourceSchemasLoading = false;
  bool _targetSchemasLoading = false;
  String? _schemaError;

  /// null means "every table".
  String? _table;
  List<String> _sourceTables = <String>[];
  String? _tablesLoadedFor;
  bool _tablesLoading = false;

  bool _allowDrop = false;
  Json? _result;
  List<Json> _syncResults = <Json>[];
  String? _error;
  bool _busy = false;

  bool get _isPostgres => AppState.instance.isPostgres;

  /// N-09: the header pill used to always show the currently browsed database,
  /// even after the user picked a different source/target pair, so a compare
  /// between two other databases looked like it ran against the wrong one.
  /// Report the actual pair once both sides are selected.
  String get _scopeLabel {
    final source = _source;
    final target = _target;
    final current = AppState.instance.activeDatabaseLabel;
    if (source == null || target == null || source.isEmpty || target.isEmpty) {
      return current.isEmpty ? '当前连接' : '当前连接库 $current';
    }
    if (_isPostgres) {
      final sourceDb = (_sourceDatabase ?? current).trim();
      final targetDb = (_targetDatabase ?? current).trim();
      return '对比 $sourceDb/$source → $targetDb/$target';
    }
    return '对比 $source → $target';
  }

  @override
  void initState() {
    super.initState();
  }

  /// Databases offered by the database selectors (PostgreSQL / MySQL).
  ///
  /// Hidden/system databases are excluded: comparing against postgres or a
  /// template can never produce a useful sync. Inaccessible PostgreSQL
  /// databases (`can_connect == false`) are not offered either.
  List<String> get _databaseCandidates {
    final state = AppState.instance;
    // Tests / older callers may only populate `databases`; MySQL's database
    // list is the same object there, so fall back to it instead of showing an
    // empty toolbar before the instance list arrives.
    final source = state.userInstanceDatabases.isNotEmpty
        ? state.userInstanceDatabases
        : (state.instanceDatabases.isNotEmpty
            ? state.instanceDatabases
            : (state.isMysql ? state.databases : <Json>[]));
    return source
        .where((d) => d['can_connect'] != false)
        .map((d) => (d['name'] ?? '').toString())
        .where((name) => name.isNotEmpty && !state.isSystemNamespace(name))
        .toList();
  }

  /// Namespaces offered for SQLite (attached databases / files).
  List<String> get _sqliteCandidates => AppState.instance.userDatabases
      .map((d) => (d['name'] ?? '').toString())
      .where((name) => name.isNotEmpty)
      .toList();

  List<String> _names(List<Json> rows) {
    final state = AppState.instance;
    return rows
        .map((d) => (d['name'] ?? '').toString())
        .where((name) => name.isNotEmpty && !state.isSystemNamespace(name))
        .toList();
  }

  /// Physical database the current source/target selections belong to.
  String? _scope;

  /// Drop choices that belonged to the previously active physical database.
  void _syncScope() {
    final scope = AppState.instance.isSqlite
        ? 'sqlite'
        : (AppState.instance.activeDatabase ?? '');
    if (_scope == scope) return;
    _scope = scope;
    _source = null;
    _target = null;
    _sourceDatabase = null;
    _targetDatabase = null;
    _sourceSchemas = <Json>[];
    _targetSchemas = <Json>[];
    _sourceSchemasDb = null;
    _targetSchemasDb = null;
    _sourceSchemasLoading = false;
    _targetSchemasLoading = false;
    _schemaError = null;
    _table = null;
    _tablesLoadedFor = null;
    _sourceTables = <String>[];
    _result = null;
    _error = null;
  }

  /// Pick sensible source/target database selectors on first build.
  void _ensureDefaults() {
    final state = AppState.instance;
    if (!state.connected) return;
    if (state.isSqlite) {
      final names = _sqliteCandidates;
      if (names.isEmpty) {
        _source = null;
        _target = null;
        return;
      }
      final route = Navigation.instance.lastDatabase ??
          Navigation.instance.route.db;
      if (_source == null || !names.contains(_source)) {
        if (route != null && names.contains(route)) {
          _source = route;
        } else {
          final preferred = state.defaultDatabase;
          _source = names.contains(preferred) ? preferred : names.first;
        }
        _table = null;
      }
      final others = names.where((name) => name != _source).toList();
      if (_target == null || !names.contains(_target) || _target == _source) {
        _target = others.isEmpty ? null : others.first;
      }
      return;
    }

    final databases = _databaseCandidates;
    if (databases.isEmpty) {
      _sourceDatabase = null;
      _targetDatabase = null;
      _source = null;
      _target = null;
      return;
    }
    final active = state.activeDatabase;
    if (_sourceDatabase == null || !databases.contains(_sourceDatabase)) {
      _sourceDatabase =
          (active != null && databases.contains(active)) ? active : databases.first;
      _source = null;
    }
    if (_targetDatabase == null || !databases.contains(_targetDatabase)) {
      _targetDatabase = databases.firstWhere(
        (name) => name != _sourceDatabase,
        orElse: () => _sourceDatabase!,
      );
      _target = null;
    }
    if (state.isMysql) {
      // MySQL's database *is* the namespace; no schema selectors.
      _source = _sourceDatabase;
      _target = _targetDatabase;
    }
  }

  /// Load schemas for the selected PostgreSQL database(s), lazily.
  void _scheduleSchemaLoads() {
    if (!_isPostgres) return;
    final sourceDb = _sourceDatabase;
    if (sourceDb != null &&
        _sourceSchemasDb != sourceDb &&
        !_sourceSchemasLoading) {
      _sourceSchemasLoading = true;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _loadSchemas(true, sourceDb));
    }
    final targetDb = _targetDatabase;
    if (targetDb != null &&
        _targetSchemasDb != targetDb &&
        !_targetSchemasLoading) {
      _targetSchemasLoading = true;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _loadSchemas(false, targetDb));
    }
  }

  Future<void> _loadSchemas(bool source, String database) async {
    try {
      final res = await Api.instance.listSchemas(database);
      final raw = res['schemas'];
      final rows = raw is List
          ? raw.map((e) => Map<String, dynamic>.from(e as Map)).toList()
          : <Json>[];
      if (!mounted) return;
      setState(() {
        if (source) {
          _sourceSchemas = rows;
          _sourceSchemasDb = database;
          _sourceSchemasLoading = false;
          final names = _names(rows);
          if (_source == null || !names.contains(_source)) {
            _source = _preferredSource(names);
          }
        } else {
          _targetSchemas = rows;
          _targetSchemasDb = database;
          _targetSchemasLoading = false;
          final names = _names(rows);
          if (_target == null || !names.contains(_target)) {
            _target = _preferredTarget(names);
          }
        }
        _schemaError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (source) {
          _sourceSchemasLoading = false;
          _sourceSchemasDb = database;
        } else {
          _targetSchemasLoading = false;
          _targetSchemasDb = database;
        }
        _schemaError = e.toString();
      });
    }
  }

  String? _preferredSource(List<String> names) {
    if (names.isEmpty) return null;
    final route = Navigation.instance.lastDatabase ??
        Navigation.instance.route.db;
    if (route != null && names.contains(route)) return route;
    final path = AppState.instance.searchPathDefaultSchema;
    if (path != null && names.contains(path)) return path;
    if (names.contains('public')) return 'public';
    return names.first;
  }

  String? _preferredTarget(List<String> names) {
    if (names.isEmpty) return null;
    if (_targetDatabase == _sourceDatabase) {
      final other = names.firstWhere(
        (name) => name != _source,
        orElse: () => names.first,
      );
      return other;
    }
    return _preferredSource(names);
  }

  /// Fetch the table list for a newly selected source, once per database/schema.
  void _scheduleTableLoad() {
    final source = _source;
    if (source == null) return;
    final key = '${_sourceDatabase ?? ''}|$source';
    if (key == _tablesLoadedFor) return;
    _tablesLoadedFor = key;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadTables(source));
  }

  Future<void> _loadTables(String source) async {
    final state = AppState.instance;
    final database = state.isPostgres ? _sourceDatabase : source;
    if (database == null || database.isEmpty) return;
    setState(() => _tablesLoading = true);
    try {
      final rows = await Api.instance.tablesIn(
        database,
        schema: state.isPostgres ? source : null,
      );
      final tables = rows
          .where((row) => (row['type'] ?? 'BASE TABLE').toString() == 'BASE TABLE')
          .map((row) => (row['name'] ?? '').toString())
          .where((name) => name.isNotEmpty)
          .toList();
      if (!mounted) return;
      setState(() {
        _sourceTables = tables;
        _tablesLoading = false;
        if (_table != null && !tables.contains(_table)) _table = null;
      });
    } catch (_) {
      // The compare action reports the real error; a failed table probe must
      // not block the page.
      if (!mounted) return;
      setState(() {
        _sourceTables = <String>[];
        _tablesLoading = false;
        _table = null;
      });
    }
  }

  Json _body(bool dryRun) => <String, dynamic>{
        'source': _source,
        'target': _target,
        'source_database': _isPostgres ? _sourceDatabase : null,
        'target_database': _isPostgres ? _targetDatabase : null,
        'table': _table,
        'allow_drop': _allowDrop,
        'dry_run': dryRun,
      };

  /// Change the source physical database (PostgreSQL) / database (MySQL).
  void _setSourceDatabase(String? value) {
    if (value == null) return;
    setState(() {
      _sourceDatabase = value;
      _source = null;
      _sourceSchemas = <Json>[];
      _sourceSchemasDb = null;
      _sourceSchemasLoading = false;
      _tablesLoadedFor = null;
      _sourceTables = <String>[];
      _table = null;
      _result = null;
      _syncResults = <Json>[];
      _schemaError = null;
      if (!_isPostgres) _source = value;
    });
  }

  void _setTargetDatabase(String? value) {
    if (value == null) return;
    setState(() {
      _targetDatabase = value;
      _target = null;
      _targetSchemas = <Json>[];
      _targetSchemasDb = null;
      _targetSchemasLoading = false;
      _result = null;
      _syncResults = <Json>[];
      _schemaError = null;
      if (!_isPostgres) _target = value;
    });
  }

  int _statementCount(Json result) {
    final tables = result['tables'];
    if (tables is! List) return 0;
    var total = 0;
    for (final table in tables) {
      if (table is Map && table['statements'] is List) {
        total += (table['statements'] as List).length;
      }
    }
    return total;
  }

  int _changedCount(Json? result) =>
      (result?['changed'] as num?)?.toInt() ?? 0;

  List<Json> get _resultTables {
    final tables = _result?['tables'];
    if (tables is! List) return <Json>[];
    return tables.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  bool get _hasDatabases => AppState.instance.isSqlite
      ? _sqliteCandidates.length >= 2
      : _databaseCandidates.isNotEmpty;

  bool get _hasPair {
    if (_source == null || _target == null) return false;
    final state = AppState.instance;
    if (state.isPostgres) {
      return _sourceDatabase != null &&
          _targetDatabase != null &&
          !(_sourceDatabase == _targetDatabase && _source == _target);
    }
    return _source != _target;
  }

  /// Run the structural comparison.
  ///
  /// [keepRunResults] keeps the execution log of a sync that just ran, so the
  /// automatic re-compare after an execution (P3-09) does not wipe the record
  /// of what was executed.
  Future<void> _compare({bool keepRunResults = false}) async {
    if (!_hasPair) {
      setState(() => _error =
          AppState.instance.isPostgres
              ? '请选择不同的源/目标（同一库中不同模式，或不同数据库）'
              : '源数据库与目标数据库不能相同');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      if (!keepRunResults) _syncResults = <Json>[];
    });
    try {
      final res = await Api.instance.schemaDiff(_body(true));
      if (!mounted) return;
      setState(() => _result = res);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _result = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run() async {
    final result = _result;
    if (result == null) return;
    final statements = _statementCount(result);
    if (statements == 0) {
      widget.notice.show('结构一致，无需同步');
      return;
    }
    final ok = await confirmDialog(
      context,
      message: '${t('sync_run_confirm')}\n\n$statements ${t('sync_statements')}',
    );
    if (!ok) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await Api.instance.schemaSync(_body(false));
      if (!mounted) return;
      final results = res['results'];
      setState(() {
        _syncResults = results is List
            ? results.map((e) => Map<String, dynamic>.from(e as Map)).toList()
            : <Json>[];
        final summary = res['summary'];
        if (summary is Map) {
          _result = Map<String, dynamic>.from(summary);
        }
      });
      final executed = (res['executed'] as num?)?.toInt() ?? 0;
      final failed = (res['failed'] as num?)?.toInt() ?? 0;
      widget.notice.show('同步完成 — $executed SQL, $failed failed');
      if (_source != null) _loadTables(_source!);
      // P3-09: `summary` is the diff computed *before* the DDL ran, so storing
      // it in _result left the page claiming "1 张表待同步" with the old
      // "目标缺失" pill (and an armed 执行同步 button) after a successful
      // CREATE TABLE. The only truthful state is a fresh comparison: the
      // target has changed since the last one. Re-run it now that the
      // statements executed — the execution log below stays visible.
      if (mounted) await _compare(keepRunResults: true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _reset() {
    setState(() {
      _result = null;
      _syncResults = <Json>[];
      _error = null;
      _table = null;
      _allowDrop = false;
    });
    widget.notice.clear();
  }

  String _statusLabel(Object? status) {
    switch ((status ?? '').toString()) {
      case 'same':
        return t('sync_same');
      case 'missing':
        return t('sync_missing');
      case 'target_only':
        return '仅目标有';
      default:
        return t('sync_differs');
    }
  }

  Widget _statementsCell(Json table) {
    final value = table['statements'];
    final statements =
        value is List ? value.map((e) => e.toString()).toList() : <String>[];
    final added = t('sync_added', {'n': table['columns_added'] ?? 0});
    final changed = t('sync_changed', {'n': table['columns_changed'] ?? 0});
    final dropped = t('sync_dropped', {'n': table['columns_dropped'] ?? 0});
    final summary =
        '$added, $changed, $dropped, +${table['indexes_added'] ?? 0} / '
        '-${table['indexes_dropped'] ?? 0} index';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (statements.isEmpty)
            Text('—', style: kSmallMuted)
          else
            SelectableText(statements.join('\n'), style: monoStyle(size: 12)),
          const SizedBox(height: 2),
          Text(summary, style: kSmallMuted),
        ],
      ),
    );
  }

  Widget _warningsCell(Json table) {
    final value = table['warnings'];
    final warnings =
        value is List ? value.map((e) => e.toString()).toList() : <String>[];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: warnings.isEmpty
          ? Text('—', style: kSmallMuted)
          : Text(warnings.join('\n'), style: kSmallMuted),
    );
  }

  Widget _emptyState() {
    final state = AppState.instance;
    if (state.isPostgres) {
      final databases = _databaseCandidates;
      return CardBox(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('结构同步需要选择源数据库/模式与目标数据库/模式。',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              databases.isEmpty
                  ? '当前连接没有可访问的数据库。请检查账号权限或 only/hide 规则。'
                  : '可以比较同一数据库中的两个模式，也可以比较两个数据库中的模式。'
                      '如果只有一个模式，请先新建一个模式或数据库。',
              style: kSmallMuted,
            ),
          ],
        ),
      );
    }
    final word = state.namespaceWord;
    return CardBox(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(pickText(
            '结构同步需要同一个连接里至少两个$word。',
            'Structure sync needs at least two ${state.isPostgres ? 'schemas' : 'databases'} in the same connection.',
          ), style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            state.isSqlite
                ? 'SQLite 支持比较同一目录中的多个数据库文件。请在左侧「+」新建或导入另一个文件，然后刷新。'
                : pickText(
                    '当前可用的$word不足两个。'
                    '请先在左侧「+」新建一个$word，或连接一个包含多个数据库/模式的服务器。',
                    'Fewer than two ${state.isPostgres ? 'schemas' : 'databases'} are available. '
                    'Create one with "+" on the left, or connect to a server that has several.',
                  ),
            style: kSmallMuted,
          ),
        ],
      ),
    );
  }

  Widget _databaseSelector({required bool source}) {
    final names = _databaseCandidates;
    return SelectBox<String>(
      value: source ? _sourceDatabase : _targetDatabase,
      enabled: names.isNotEmpty,
      onChanged: source ? _setSourceDatabase : _setTargetDatabase,
      items: [
        for (final name in names)
          DropdownMenuItem(value: name, child: Text(name)),
      ],
    );
  }

  Widget _schemaSelector({required bool source}) {
    final names = _names(source ? _sourceSchemas : _targetSchemas);
    final loading = source ? _sourceSchemasLoading : _targetSchemasLoading;
    return SelectBox<String>(
      value: source ? _source : _target,
      enabled: names.isNotEmpty && !loading,
      onChanged: (value) {
        if (value == null) return;
        setState(() {
          if (source) {
            _source = value;
            _tablesLoadedFor = null;
            _sourceTables = <String>[];
          } else {
            _target = value;
          }
          _table = null;
          _result = null;
          _syncResults = <Json>[];
        });
      },
      items: [
        for (final name in names)
          DropdownMenuItem(value: name, child: Text(name)),
      ],
    );
  }

  Widget _sqliteSelector({required bool source}) {
    final names = _sqliteCandidates;
    return SelectBox<String>(
      value: source ? _source : _target,
      onChanged: (value) {
        if (value == null) return;
        setState(() {
          if (source) {
            _source = value;
            _tablesLoadedFor = null;
            _sourceTables = <String>[];
          } else {
            _target = value;
          }
          _table = null;
          _result = null;
          _syncResults = <Json>[];
        });
      },
      items: [
        for (final name in names)
          DropdownMenuItem(value: name, child: Text(name)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    _syncScope();
    _ensureDefaults();
    _scheduleSchemaLoads();
    _scheduleTableLoad();
    final notConnected = !state.connected;
    final hasDatabases = _hasDatabases;
    final result = _result;
    final changed = _changedCount(result);
    final statements = result == null ? 0 : _statementCount(result);
    return PageScroll(
      padding: const EdgeInsets.all(AppMetrics.mainPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHead(
            title: '结构同步',
            meta: [
              // N-09: follow the selected source/target instead of the current
              // connection database.
              if (!AppState.instance.isSqlite)
                Pill(_scopeLabel, tone: PillTone.info),
              if (result != null)
                Pill(
                  changed == 0 ? '结构一致' : '$changed 张表有待同步',
                  tone: changed == 0 ? PillTone.ok : PillTone.warn,
                ),
            ],
            actions: [Btn('清空', onPressed: _reset)],
          ),
          if (notConnected)
            const AlertBox(
              '尚未连接数据库：结构同步需要先打开一个连接。',
              tone: AlertTone.info,
            )
          else if (!hasDatabases)
            _emptyState(),
          if (!notConnected && hasDatabases && !_hasPair &&
              !_sourceSchemasLoading && !_targetSchemasLoading && result == null)
            const AlertBox(
              '请选择不同的源/目标：同一数据库中的两个模式，或两个数据库中的模式。',
              tone: AlertTone.info,
            ),
          if (_schemaError != null) AlertBox(_schemaError!, tone: AlertTone.error),
          if (_error != null) AlertBox(_error!),
          NoticeBanner(widget.notice),
          if (!notConnected && hasDatabases)
            CardBox(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Every control shares the same caption row and the same
                  // 36px control height, so the inputs sit on one baseline.
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.end,
                    children: [
                      if (state.isPostgres) ...[
                        ControlGroup(
                          label: '源数据库',
                          width: 180,
                          child: _databaseSelector(source: true),
                        ),
                        ControlGroup(
                          label: '源模式',
                          width: 180,
                          child: _schemaSelector(source: true),
                        ),
                        ControlGroup(
                          label: '目标数据库',
                          width: 180,
                          child: _databaseSelector(source: false),
                        ),
                        ControlGroup(
                          label: '目标模式',
                          width: 180,
                          child: _schemaSelector(source: false),
                        ),
                      ] else if (state.isMysql) ...[
                        ControlGroup(
                          label: t('sync_source'),
                          width: 210,
                          child: _databaseSelector(source: true),
                        ),
                        ControlGroup(
                          label: t('sync_target'),
                          width: 210,
                          child: _databaseSelector(source: false),
                        ),
                      ] else ...[
                        ControlGroup(
                          label: t('sync_source'),
                          width: 210,
                          child: _sqliteSelector(source: true),
                        ),
                        ControlGroup(
                          label: t('sync_target'),
                          width: 210,
                          child: _sqliteSelector(source: false),
                        ),
                      ],
                      ControlGroup(
                        label: t('sync_table_optional'),
                        width: 230,
                        child: SelectBox<String>(
                          value: _table ?? '',
                          onChanged: (v) =>
                              setState(() => _table = (v ?? '').isEmpty ? null : v),
                          items: [
                            DropdownMenuItem(
                              value: '',
                              child: Text(
                                  _tablesLoading ? '（全部表，加载中…）' : '（全部表）'),
                            ),
                            for (final table in _sourceTables)
                              DropdownMenuItem(value: table, child: Text(table)),
                          ],
                        ),
                      ),
                      ControlGroup(
                        label: null,
                        height: kControlHeight,
                        child: CheckBox(
                          label: t('sync_allow_drop'),
                          value: _allowDrop,
                          onChanged: (v) => setState(() => _allowDrop = v),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Btn(t('sync_compare'),
                          onPressed: (_busy || !_hasPair) ? null : _compare),
                      Btn(t('sync_run'),
                          primary: true,
                          tooltip: statements == 0
                              ? '没有需要执行的语句'
                              : '在目标数据库执行生成的 DDL',
                          onPressed:
                              (_busy || statements == 0) ? null : _run),
                      if (result != null)
                        Text(
                          '${_resultTables.length} 张表比对，$statements 条 SQL',
                          style: kSmallMuted,
                        ),
                    ],
                  ),
                  if (result != null && changed == 0) ...[
                    const SizedBox(height: 10),
                    const AlertBox(
                      '结构一致：源库与目标库没有差异。',
                      tone: AlertTone.ok,
                    ),
                  ],
                  if (result != null && changed > 0) ...[
                    const SizedBox(height: 10),
                    const AlertBox(
                      '只同步字段、主键与索引；外键、触发器和函数不会被创建。'
                      '删除目标库多出的字段/索引需勾选「允许删除」；仅目标存在的表只提示，不会自动删除。',
                      tone: AlertTone.info,
                    ),
                  ],
                ],
              ),
            ),
          if (result != null)
            CardBox(
              title: t('sync_status'),
              child: _resultTables.isEmpty
                  ? Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        '源库没有可比对的表（或所选表不存在）。',
                        style: kSmallMuted,
                      ),
                    )
                  : GridTable(
                      emptyText: '（无）',
                      headers: [
                        Text(t('table_name')),
                        Text(t('sync_status')),
                        Text(t('sync_statements')),
                        Text(t('sync_warnings')),
                      ],
                      rows: [
                        for (final table in _resultTables)
                          TableRow(
                            children: [
                              gridCell(table['name'], mono: true),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 5),
                                child: Pill(
                                  _statusLabel(table['status']),
                                  tone:
                                      (table['status'] ?? '').toString() == 'same'
                                          ? PillTone.ok
                                          : PillTone.warn,
                                ),
                              ),
                              _statementsCell(table),
                              _warningsCell(table),
                            ],
                          ),
                      ],
                    ),
            ),
          if (_syncResults.isNotEmpty)
            CardBox(
              title: t('sync_run'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final row in _syncResults)
                    AlertBox(
                      row['error'] != null
                          ? '${row['statement'] ?? ''} — ${row['error']}'
                          : (row['statement'] ?? '').toString(),
                      tone: row['error'] != null
                          ? AlertTone.error
                          : AlertTone.ok,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
