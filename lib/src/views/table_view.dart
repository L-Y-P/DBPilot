import 'dart:io';

import 'package:flutter/material.dart' hide Text, Tooltip;
import '../text.dart';

import '../api.dart';
import '../app_state.dart';
import '../components/data_grid.dart';
import '../i18n.dart';
import '../i18n_literals.dart';
import '../import_rules.dart';
import '../nav.dart';
import '../notice.dart';
import '../sql_highlight.dart';
import '../sqlite_sources.dart';
import '../theme.dart';
import 'data_import_wizard.dart';
import '../widgets.dart';
import 'result_table.dart';

/// Single-table workbench with tabs: Browse, Structure, Design, DDL, Insert,
/// SQL, Export, Import and Operations.
///
/// Ports Table.vue. The visual designer, the WHERE filter builder and the
/// per-cell editing all keep the web semantics, including the rule that a
/// row is only editable when the statement resolves to one table.
class TableView extends StatefulWidget {
  const TableView({
    super.key,
    required this.db,
    required this.table,
    required this.notice,
  });

  final String db;
  final String table;
  final Notice notice;

  @override
  State<TableView> createState() => _TableViewState();
}

class _TableViewState extends State<TableView> with SingleTickerProviderStateMixin {
  static const _tabs = [
    'browse',
    'structure',
    'design',
    'ddl',
    'insert',
    'sql',
    'export',
    'import',
    'operations',
  ];

  /// Placeholder of the insert form's dropdowns: leaving it selected means the
  /// column stays out of the INSERT and the database applies its default.
  static const _defaultInsertOption = '（默认）';

  late TabController _tabController;
  String _tab = 'browse';

  Json _data = <String, dynamic>{};
  Json _structure = <String, dynamic>{};
  List<SortSpec> _sorts = <SortSpec>[];
  final _where = TextEditingController();
  int _page = 1;
  int _perPage = 25;

  /// Keyset cursors, one per loaded page.
  ///
  /// Index 0 is always `null` (page 1 starts at the table head); index `i` holds
  /// the `next_cursor` of page `i`. Deep pages therefore become
  /// `WHERE pk > cursor` range scans instead of `OFFSET n`, which the server
  /// reports through `used_keyset`.
  final List<Object?> _cursors = <Object?>[null];

  /// Cursor for the page after the one currently displayed (null when the
  /// server could not use a keyset scan, or when the last page is reached).
  Object? _nextCursor;

  /// Last total the server reported.
  ///
  /// Cursor pages are fetched with `count: false` (a full COUNT(*) on a wide
  /// table often costs more than the page itself), so those responses carry
  /// `total: null`. Keeping the number from the last counted page stops the
  /// header's row-count pill from flickering away as soon as the user turns a
  /// page.
  int? _knownTotal;

  String? _ddl;
  String _sqlText = '';
  /// One controller for the SQL tab. Building a fresh TextEditingController on
  /// every build (as this used to) resets the caret to the start on each
  /// keystroke-driven rebuild.
  final SqlHighlightingController _sqlController = SqlHighlightingController();
  List<Json> _sqlResults = <Json>[];
  String? _error;
  String? _sqlError;
  bool _loading = true;
  /// SQL-file import runs as a Rust job; this polls its progress.
  bool _importing = false;
  String? _importPath;
  Json? _importFileInfo;
  Json? _importJobStatus;
  Json? _importResult;
  ImportJobPoller? _importPoller;
  String _exportFormat = 'sql';
  bool _exportStructure = true;
  bool _exportData = true;
  bool _exportDrop = false;
  String? _exportPreview;
  /// True while a streamed file export is running (large tables take a while).
  bool _exporting = false;
  List<Json> _builderTables = <Json>[];
  final List<Json> _insertValues = <Json>[];
  final List<bool> _insertNulls = <bool>[];
  /// One controller per insert row, keyed by column name.
  ///
  /// The insert form used to build a fresh, *uncontrolled* TextField on every
  /// rebuild. Clearing the pending values after a successful insert therefore
  /// left the old text on screen (a TextField keeps its own internal state), and
  /// the next "插入" submitted the now-empty values instead — which is why a
  /// second insert without retyping failed with a missing-field error.
  final Map<String, TextEditingController> _insertControllers =
      <String, TextEditingController>{};

  // Design tab state
  final List<Json> _designColumns = <Json>[];
  final List<Json> _designNewIndexes = <Json>[];
  final List<Json> _designNewFks = <Json>[];
  final Set<String> _designDropIndexes = <String>{};
  final Set<String> _designDropFks = <String>{};
  String? _designSql;
  List<Json> _designResults = <Json>[];
  String? _designError;
  final _renameTo = TextEditingController();
  final _tableComment = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _sqlText = _defaultTableSql();
    _sqlController.text = _sqlText;
    _reloadAll();
  }

  @override
  void dispose() {
    _importPoller?.dispose();
    _tabController.dispose();
    _where.dispose();
    _renameTo.dispose();
    _sqlController.dispose();
    for (final controller in _insertControllers.values) {
      controller.dispose();
    }
    _tableComment.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TableView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.db != widget.db || oldWidget.table != widget.table) {
      _sqlText = _defaultTableSql();
      _sqlController.text = _sqlText;
      _reloadAll();
    }
  }

  /// Reset per-table state and reload data + structure, like the web reloadAll.
  Future<void> _reloadAll() async {
    setState(() {
      _tab = 'browse';
      _tabController.index = 0;
      _sorts = <SortSpec>[];
      _where.text = '';
      _page = 1;
      _ddl = null;
      _sqlResults = <Json>[];
      _error = null;
      _sqlError = null;
      _importPath = null;
      _importFileInfo = null;
      _importJobStatus = null;
      _importResult = null;
      _importPoller?.dispose();
      _importPoller = null;
      _importing = false;
      _exportPreview = null;
      _designColumns.clear();
      _designNewIndexes.clear();
      _designNewFks.clear();
      _designDropIndexes.clear();
      _designDropFks.clear();
      _designSql = null;
      _designResults = <Json>[];
      _designError = null;
      // Another table's total must not be shown while this one loads: the
      // header pill reads _data / _knownTotal, and both used to survive the
      // switch (round34 P2-01).
      _data = <String, dynamic>{};
      _knownTotal = null;
      _loading = true;
    });
    await Future.wait([_loadData(refreshCount: true), _loadStructure()]);
  }

  /// Reload the current page.
  ///
  /// [refreshCount] forces a fresh COUNT(*) even when the page was reached
  /// through a cursor (see [shouldCountTableRows]). Writes pass it because they
  /// change the row count the header's pill is drawn from.
  Future<void> _loadData({bool refreshCount = false}) async {
    try {
      // Every caller that changes the result set (sort, filter, per-page,
      // refresh) sets _page back to 1. Starting at the head invalidates any
      // cursors collected for the previous ordering, so the chain restarts here
      // instead of sending a cursor that belongs to a different WHERE/ORDER BY.
      if (_page <= 1) {
        _cursors
          ..clear()
          ..add(null);
        _nextCursor = null;
      }
      final sortText = _sorts.map((s) => '${s.column}:${s.dir}').join(',');
      // Only send a cursor for a page we actually reached through one; after a
      // sort/filter change the stack is reset, so this is always in range.
      final cursor = _page > 0 && _page <= _cursors.length ? _cursors[_page - 1] : null;
      final res = await Api.instance.data(widget.db, widget.table, {
        'page': _page,
        'per_page': _perPage,
        'sort': sortText.isEmpty ? null : sortText,
        'where': _where.text.trim().isEmpty ? null : _where.text.trim(),
        'after': ?cursor,
        // Counting a large table is often more expensive than fetching a page,
        // so a cursor page normally skips it (the header and pager then reuse
        // the total learned on page 1). A write or an explicit refresh asks for
        // a fresh count even on a cursor page, so the header's row-count pill
        // cannot stay on a stale number after an insert / delete (round34
        // P2-01) — that is one extra COUNT per user action, never per page.
        'count':
            shouldCountTableRows(cursor: cursor, refreshCount: refreshCount),
      });
      if (!mounted) return;
      setState(() {
        _data = res;
        _loading = false;
        final counted = (res['total'] as num?)?.toInt();
        if (counted != null) _knownTotal = counted;
        final usedKeyset = res['used_keyset'] == true;
        if (!usedKeyset) {
          // The server fell back to OFFSET (composite/no primary key, or a
          // sort the index cannot serve): drop the cursor chain so paging stays
          // consistent with the rows that were actually returned.
          _cursors
            ..clear()
            ..add(null);
          _nextCursor = null;
        } else {
          _nextCursor = res['next_cursor'];
          if (_cursors.length > _page) {
            _cursors.removeRange(_page, _cursors.length);
          }
          if (_nextCursor != null) {
            if (_cursors.length == _page) {
              _cursors.add(_nextCursor);
            } else {
              _cursors[_page] = _nextCursor;
            }
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Reload the current page after a statement that changes the row count
  /// (insert / delete / truncate / arbitrary SQL / import).
  ///
  /// The reload keeps the current page and its cursor chain but forces the
  /// COUNT(*), so 「行数：N」 shows the new total immediately instead of the
  /// number from whenever the table was last counted (round34 P2-01).
  Future<void> _reloadAfterWrite() => _loadData(refreshCount: true);

  Future<void> _loadStructure() async {
    try {
      final res = await Api.instance.structure(widget.db, widget.table);
      final schema = await Api.instance.builderSchema(widget.db);
      if (!mounted) return;
      setState(() {
        _structure = res;
        final tables = schema['tables'];
        _builderTables = tables is List
            ? tables.map((e) => Map<String, dynamic>.from(e as Map)).toList()
            : <Json>[];
        _seedInsertValues();
        _seedDesigner();
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = describeDbError(e));
      }
    }
  }

  List<Json> get _columns {
    final value = _data['columns'];
    if (value is! List) return <Json>[];
    return value.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  List<List<dynamic>> get _rows {
    final value = _data['rows'];
    if (value is! List) return <List<dynamic>>[];
    return value.map((row) => row is List ? row : <dynamic>[]).toList();
  }

  List<String> get _primaryKey {
    final value = _data['primary_key'];
    if (value is! List) return <String>[];
    return value.map((e) => e.toString()).toList();
  }

  List<Json> get _structureColumns {
    final value = _structure['columns'];
    if (value is! List) return <Json>[];
    return value.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  bool get _isView =>
      (_structure['info'] is Map) &&
      ((_structure['info'] as Map)['TABLE_TYPE'] ?? '').toString() == 'VIEW';

  void _seedInsertValues() {
    _insertValues.clear();
    _insertNulls.clear();
    for (final column in _structureColumns) {
      final name = (column['name'] ?? '').toString();
      _insertValues.add(<String, dynamic>{'value': '', 'isNull': false});
      _insertNulls.add(false);
      _insertControllers.putIfAbsent(name, () => TextEditingController());
    }
    // Drop controllers for columns that no longer exist, then clear the rest so
    // the visible inputs match the freshly cleared values.
    _insertControllers.removeWhere(
        (name, _) => !_structureColumns.any((c) => c['name'] == name));
    for (final controller in _insertControllers.values) {
      controller.clear();
    }
  }

  /// Copy the current columns into the designer snapshot.
  void _seedDesigner() {
    _designColumns.clear();
    for (final column in _structureColumns) {
      _designColumns.add(<String, dynamic>{
        'name': (column['name'] ?? '').toString(),
        'type': (column['type_name'] ?? '').toString(),
        'nullable': column['IS_NULLABLE'] == 'YES',
        'default': column['COLUMN_DEFAULT']?.toString() ?? '',
        'auto_increment':
            (column['EXTRA'] ?? '').toString().contains('auto_increment'),
        'comment': (column['COLUMN_COMMENT'] ?? '').toString(),
        'charset': (column['CHARACTER_SET_NAME'] ?? '').toString(),
        'collation': (column['COLLATION_NAME'] ?? '').toString(),
        'isNew': false,
        'original': (column['name'] ?? '').toString(),
      });
    }
    final info = _structure['info'];
    if (info is Map) {
      _renameTo.clear();
      _tableComment.text = (info['TABLE_COMMENT'] ?? '').toString();
    }
  }

  void _onSort(String column, bool additive) {
    setState(() {
      final existing = _sorts.indexWhere((s) => s.column == column);
      if (existing >= 0) {
        final current = _sorts[existing];
        if (additive) {
          _sorts[existing] = current.toggled();
        } else {
          _sorts = [current.toggled()];
        }
      } else if (additive) {
        _sorts = [..._sorts, SortSpec(column, 'asc')];
      } else {
        _sorts = [SortSpec(column, 'asc')];
      }
      _page = 1;
    });
    _loadData();
  }

  /// Build a WHERE clause from the DataGrid filter row, quoting identifiers
  /// for the active driver exactly like the web filtersToWhere().
  void _onFilters(List<GridFilter> filters) {
    final q = AppState.instance.quoteIdent;
    final conditions = <String>[];
    for (var i = 0; i < _columns.length && i < filters.length; i++) {
      final filter = filters[i];
      if (!filter.active) continue;
      final column = q(_columns[i]['name'].toString());
      if (filter.op == 'IS NULL' || filter.op == 'IS NOT NULL') {
        conditions.add('$column ${filter.op}');
        continue;
      }
      final raw = filter.value.trim();
      if (raw.isEmpty) continue;
      final numeric = num.tryParse(raw) != null;
      final literal = (numeric || raw.startsWith('('))
          ? raw
          : "'${raw.replaceAll("'", "''")}'";
      if (filter.op == 'LIKE' || filter.op == 'NOT LIKE') {
        final escaped = raw.replaceAll("'", "''");
        conditions.add("$column ${filter.op} '%$escaped%'");
      } else if (filter.op == 'IN') {
        final values = raw.startsWith('(') ? raw : '($raw)';
        conditions.add('$column IN $values');
      } else {
        conditions.add('$column ${filter.op} $literal');
      }
    }
    setState(() {
      _where.text = conditions.join(' AND ');
      _page = 1;
    });
    _loadData();
  }

  @override
  Widget build(BuildContext context) {
    return PageScroll(
      padding: const EdgeInsets.all(AppMetrics.mainPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(),
          if (_error != null)
            AlertBox(_error!, tone: AlertTone.error),
          if (_sqlError != null) AlertBox(_sqlError!),
          NoticeBanner(widget.notice),
          _tabBar(),
          const SizedBox(height: 12),
          _tabBody(),
        ],
      ),
    );
  }

  Widget _header() {
    final total = (_data['total'] as num?)?.toInt() ?? _knownTotal;
    return PageHead(
      titleWidget: Row(
        children: [
          InkWell(
            onTap: () => Navigation.instance.go(AppRoute.database(widget.db)),
            child: Text(widget.db, style: monoStyle(size: 14, color: AppColors.link)),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 6),
            child: Text('/', style: kMuted),
          ),
          Text(widget.table, style: monoStyle(size: 18, weight: FontWeight.w600)),
        ],
      ),
      actions: [
        if (total != null) Pill(I18n.current == AppLang.en ? 'Rows: $total' : '行数：$total'),
        const SizedBox(width: 8),
        Btn(t('back'),
            onPressed: () => Navigation.instance.go(AppRoute.database(widget.db))),
      ],
    );
  }

  Widget _tabBar() {
    final labels = <String, String>{
      'browse': t('tab_browse'),
      'structure': t('tab_structure'),
      'design': (I18n.current == AppLang.en ? 'Design' : '设计'),
      'ddl': 'DDL',
      'insert': t('tab_insert'),
      'sql': 'SQL',
      'export': t('tab_export'),
      'import': t('tab_import'),
      'operations': t('actions'),
    };
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Wrap(
        spacing: 2,
        children: [
          for (final tab in _tabs)
            GestureDetector(
              onTap: () => _switchTab(tab),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
                decoration: BoxDecoration(
                  color: _tab == tab ? AppColors.panel : Colors.transparent,
                  border: Border.all(
                      color: _tab == tab
                          ? AppColors.border
                          : Colors.transparent),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(5),
                    topRight: Radius.circular(5),
                  ),
                ),
                child: Text(
                  labels[tab] ?? tab,
                  style: TextStyle(
                    fontSize: 13,
                    color: _tab == tab ? AppColors.bodyText : AppColors.muted,
                    fontWeight:
                        _tab == tab ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _switchTab(String tab) {
    setState(() => _tab = tab);
    if (tab == 'ddl' && _ddl == null) _loadDdl();
  }

  Widget _tabBody() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    switch (_tab) {
      case 'browse':
        return _browseTab();
      case 'structure':
        return _structureTab();
      case 'design':
        return _designTab();
      case 'ddl':
        return _ddlTab();
      case 'insert':
        return _insertTab();
      case 'sql':
        return _sqlTab();
      case 'export':
        return _exportTab();
      case 'import':
        return _importTab();
      case 'operations':
        return _operationsTab();
    }
    return const SizedBox.shrink();
  }

  // ------------------------------------------------------------------ browse

  Widget _browseTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CardBox(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text((I18n.current == AppLang.en ? 'Apply WHERE' : '应用 WHERE'), style: kSmall),
                  SizedBox(
                    width: 320,
                    child: TextField(
                      controller: _where,
                      style: monoStyle(size: 12),
                      onSubmitted: (_) {
                        setState(() => _page = 1);
                        _loadData();
                      },
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: I18n.current == AppLang.en ? 'Optional WHERE condition' : '可选 WHERE 条件',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  Btn(t('filter'),
                      primary: true,
                      onPressed: () {
                        setState(() => _page = 1);
                        _loadData();
                      }),
                  if (_where.text.isNotEmpty)
                    Btn(t('clear'), onPressed: () {
                      _where.text = '';
                      setState(() => _page = 1);
                      _loadData();
                    }),
                  const Sep(),
                  Text((I18n.current == AppLang.en ? 'Per page' : '每页'), style: kSmall),
                  SelectBox<int>(
                    width: 90,
                    value: _perPage,
                    onChanged: (v) {
                      setState(() {
                        _perPage = v ?? 25;
                        _page = 1;
                      });
                      _loadData();
                    },
                    items: const [
                      DropdownMenuItem(value: 10, child: Text('10')),
                      DropdownMenuItem(value: 25, child: Text('25')),
                      DropdownMenuItem(value: 50, child: Text('50')),
                      DropdownMenuItem(value: 100, child: Text('100')),
                      DropdownMenuItem(value: 250, child: Text('250')),
                    ],
                  ),
                  // An explicit refresh must re-count even on a cursor page,
                  // otherwise the pill keeps the pre-refresh number and only
                  // walking back to page 1 updates it.
                  Btn(t('refresh'),
                      onPressed: () => _loadData(refreshCount: true)),
                ],
              ),
              if (_primaryKey.isEmpty) ...[
                const SizedBox(height: 8),
                const AlertBox(
                  '该表没有主键，行编辑将按整行匹配，可能影响多行。',
                  tone: AlertTone.info,
                ),
              ],
            ],
          ),
        ),
        DataGrid(
          columns: _columns,
          rows: _rows,
          sorts: _sorts,
          primaryKey: _primaryKey,
          rowOps: true,
          editable: true,
          maxHeight: 460,
          onSort: _onSort,
          onFilters: _onFilters,
          onEdit: _showRowEditor,
          onDelete: _deleteRow,
          onDeleteSelected: _deleteRows,
          onSaveCell: _saveCell,
        ),
        const SizedBox(height: 8),
        _pager(),
      ],
    );
  }

  Widget _pager() {
    final page = (_data['page'] as num?)?.toInt() ?? 1;
    final pages = (_data['pages'] as num?)?.toInt();
    final total = (_data['total'] as num?)?.toInt() ?? _knownTotal;
    final rows = _rows.length;
    // With a keyset scan the server no longer needs COUNT(*), so `pages` and
    // `total` can be absent (null). The pager then falls back to "there is a
    // next page while the server handed back a cursor", and reports the rows
    // seen so far instead of a total it does not have.
    final hasNext = _nextCursor != null || (pages != null && page < pages);
    final canPrev = page > 1;
    final pageLabel = pages == null ? '第 $page 页' : '第 $page / $pages 页';
    final countLabel =
        total == null ? '本页 $rows 行' : '显示 $rows / $total 行';
    return Row(
      children: [
        IconBtn(Icons.chevron_left,
            key: const ValueKey('pager-prev'),
            tooltip: '上一页',
            small: true,
            onPressed: canPrev
                ? () {
                    setState(() => _page = page - 1);
                    _loadData();
                  }
                : null),
        const SizedBox(width: 8),
        Text(pageLabel, style: kSmall),
        const SizedBox(width: 8),
        IconBtn(Icons.chevron_right,
            key: const ValueKey('pager-next'),
            tooltip: '下一页',
            small: true,
            onPressed: hasNext
                ? () {
                    setState(() => _page = page + 1);
                    _loadData();
                  }
                : null),
        const Spacer(),
        Text(countLabel, style: kSmallMuted),
      ],
    );
  }

  /// Row keys: primary key columns when present, otherwise every column.
  Map<String, dynamic> _rowKeys(int index) {
    final row = _rows[index];
    final keys = <String, dynamic>{};
    final target = _primaryKey.isEmpty
        ? _columns.map((c) => c['name'].toString()).toList()
        : _primaryKey;
    for (var i = 0; i < _columns.length; i++) {
      final name = _columns[i]['name'].toString();
      if (!target.contains(name)) continue;
      keys[name] = i < row.length ? row[i] : null;
    }
    return keys;
  }

  Future<void> _saveCell(
      int rowIndex, String column, Object? value, bool isNull) async {
    try {
      await Api.instance.changeRow(widget.db, widget.table, {
        'action': 'update',
        'keys': _rowKeys(rowIndex),
        'values': {column: isNull ? null : value},
        'limit_one': _primaryKey.isEmpty,
      });
      widget.notice.show('单元格已保存');
      await _loadData();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _deleteRow(int index) async {
    final ok = await confirmDialog(context,
        message: '确定删除该行吗？', confirmLabel: t('delete'), danger: true);
    if (!ok) return;
    try {
      await Api.instance.changeRow(widget.db, widget.table, {
        'action': 'delete',
        'keys': _rowKeys(index),
        'limit_one': _primaryKey.isEmpty,
      });
      widget.notice.show('行已删除');
      await _reloadAfterWrite();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _deleteRows(List<int> indices) async {
    final ok = await confirmDialog(context,
        message: '确定删除选中的 ${indices.length} 行吗？',
        confirmLabel: t('delete'),
        danger: true);
    if (!ok) return;
    var deleted = 0;
    for (final index in indices) {
      try {
        await Api.instance.changeRow(widget.db, widget.table, {
          'action': 'delete',
          'keys': _rowKeys(index),
          'limit_one': _primaryKey.isEmpty,
        });
        deleted++;
      } catch (e) {
        if (mounted) setState(() => _error = e.toString());
        break;
      }
    }
    if (deleted > 0) {
      widget.notice.show('已删除 $deleted 行');
      await _reloadAfterWrite();
    }
  }

  /// Row editor modal: one control per column, skipping primary-key columns on
  /// update because those identify the row.
  Future<void> _showRowEditor(int index) async {
    final row = _rows[index];
    final controllers = <String, TextEditingController>{};
    final nulls = <String, bool>{};
    for (var i = 0; i < _columns.length; i++) {
      final name = _columns[i]['name'].toString();
      final value = i < row.length ? row[i] : null;
      controllers[name] = TextEditingController(text: displayCell(value));
      nulls[name] = value == null;
    }
    await showAppModal(
      context: context,
      title: '编辑行',
      builder: (context) => StatefulBuilder(
        builder: (context, setModal) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < _columns.length; i++)
              _editorRow(_columns[i], controllers, nulls, setModal),
          ],
        ),
      ),
      actions: [
        Builder(
          builder: (context) => Btn(t('cancel'),
              onPressed: () => Navigator.of(context).pop()),
        ),
        Builder(
          builder: (context) => Btn(t('save_changes'),
              primary: true,
              onPressed: () async {
                final values = <String, dynamic>{};
                for (final column in _columns) {
                  final name = column['name'].toString();
                  if (_primaryKey.contains(name)) continue;
                  values[name] = nulls[name] == true
                      ? null
                      : _coerce(column, controllers[name]!.text);
                }
                try {
                  await Api.instance.changeRow(widget.db, widget.table, {
                    'action': 'update',
                    'keys': _rowKeys(index),
                    'values': values,
                    'limit_one': _primaryKey.isEmpty,
                  });
                  if (context.mounted) Navigator.of(context).pop();
                  widget.notice.show('行已更新');
                  await _loadData();
                } catch (e) {
                  if (mounted) setState(() => _error = e.toString());
                }
              }),
        ),
      ],
    );
  }

  Widget _editorRow(Json column, Map<String, TextEditingController> controllers,
      Map<String, bool> nulls, StateSetter setModal) {
    final name = column['name'].toString();
    final type = (column['type_name'] ?? '').toString().toLowerCase();
    final isBoolean = type.startsWith('bool') ||
        type.startsWith('tinyint(1)') ||
        type == 'boolean';
    final isLongText = type.contains('text') || type.contains('json');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 160,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: monoStyle(size: 12, weight: FontWeight.w600)),
                Text(column['type_name']?.toString() ?? '',
                    style: monoStyle(size: 11, color: AppColors.typeText)),
              ],
            ),
          ),
          Expanded(
            child: isBoolean
                ? SelectBox<String>(
                    value: controllers[name]!.text == 'true' ? 'true' : 'false',
                    enabled: nulls[name] != true,
                    onChanged: (v) => controllers[name]!.text = v ?? 'false',
                    items: const [
                      DropdownMenuItem(value: 'true', child: Text('true')),
                      DropdownMenuItem(value: 'false', child: Text('false')),
                    ],
                  )
                : TextField(
                    controller: controllers[name],
                    enabled: nulls[name] != true,
                    maxLines: isLongText ? 3 : 1,
                    style: monoStyle(size: 12),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
          ),
          const SizedBox(width: 8),
          CheckBox(
            label: 'NULL',
            value: nulls[name] == true,
            onChanged: (v) => setModal(() => nulls[name] = v),
          ),
        ],
      ),
    );
  }

  /// Coerce a text value to the JSON type the backend expects for the column.
  Object? _coerce(Json column, String raw) {
    final type = (column['type_name'] ?? '').toString().toLowerCase();
    final numeric = RegExp(r'int|decimal|numeric|float|double|real|bit|year|serial')
        .hasMatch(type);
    if (raw.isEmpty) return numeric ? null : '';
    if (numeric) return num.tryParse(raw) ?? raw;
    return raw;
  }

  // --------------------------------------------------------------- structure

  /// Human labels for the structure metrics; unknown keys are shown verbatim.
  Map<String, String> get _infoLabels => <String, String>{
    'TABLE_TYPE': '表类型',
    'ENGINE': '引擎',
    'TABLE_ROWS': AppState.instance.isSqlite
        ? (I18n.current == AppLang.en ? 'Rows' : '行数')
        : (I18n.current == AppLang.en ? 'Rows (estimated)' : '行数（估算）'),
    'DATA_LENGTH': '数据大小',
    'INDEX_LENGTH': '索引大小',
    'TABLE_COLLATION': '排序规则',
    'TABLE_COMMENT': t('comment'),
    'CREATE_TIME': '创建时间',
    'UPDATE_TIME': '更新时间',
    'AUTO_INCREMENT': '自增起始值',
    'TABLESPACE': '表空间',
    'UNLOGGED': 'UNLOGGED',
    'TABLE_SQL': '建表语句',
  };

  String _infoLabel(String key) => _infoLabels[key] ?? key;

  Widget _structureTab() {
    final info = _structure['info'];
    final indexes = _structure['indexes'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (info is Map)
          CardBox(
            title: (I18n.current == AppLang.en ? 'Table information' : '表信息'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Only show fields the driver actually filled. PostgreSQL has
                // no ENGINE / TABLE_COLLATION, and SQLite has neither, so the
                // old card was mostly "ENGINE: NULL" rows.
                for (final entry in info.entries)
                  if (entry.value != null &&
                      entry.value.toString().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 200,
                            child: Text(
                                _infoLabel(entry.key.toString()),
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.cardHeading)),
                          ),
                          Expanded(
                            child: SelectableText(
                              entry.value.toString(),
                              style: monoStyle(size: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          ),
        CardBox(
          title: t('columns'),
          child: GridTable(
            headers: [
              Text('#'),
              Text(t('column_name')),
              Text(t('column_type')),
              Text((I18n.current == AppLang.en ? 'Allow NULL' : '允许 NULL')),
              Text(t('default_value')),
              Text((I18n.current == AppLang.en ? 'Key' : '键')),
              Text((I18n.current == AppLang.en ? 'Extra' : '额外')),
              Text(t('comment')),
            ],
            emptyText: (I18n.current == AppLang.en ? '(none)' : '（无）'),
            rows: [
              for (final column in _structureColumns)
                TableRow(
                  children: [
                    gridCell(column['ORDINAL_POSITION']),
                    gridCell(column['name'], mono: true),
                    gridCell(column['type_name'], mono: true),
                    gridCell(column['IS_NULLABLE']),
                    gridCell(column['COLUMN_DEFAULT'] ?? 'NULL'),
                    gridCell(column['COLUMN_KEY']),
                    gridCell(column['EXTRA']),
                    gridCell(column['COLUMN_COMMENT']),
                  ],
                ),
            ],
          ),
        ),
        CardBox(
          title: (I18n.current == AppLang.en ? 'Indexes' : '索引'),
          child: GridTable(
            headers: [
              Text((I18n.current == AppLang.en ? 'Index name' : '索引名')),
              Text((I18n.current == AppLang.en ? 'Unique' : '唯一')),
              Text(t('columns')),
              Text((I18n.current == AppLang.en ? 'Sequence' : '序号')),
              Text((I18n.current == AppLang.en ? 'Cardinality' : '基数')),
              Text(t('column_type')),
            ],
            emptyText: (I18n.current == AppLang.en ? '(none)' : '（无）'),
            rows: [
              if (indexes is List)
                for (final idx in indexes)
                  TableRow(
                    children: [
                      gridCell((idx as Map)['INDEX_NAME'], mono: true),
                      gridCell(idx['NON_UNIQUE'] == 0 ? '是' : '否'),
                      gridCell(idx['COLUMN_NAME'], mono: true),
                      gridCell(idx['SEQ_IN_INDEX']),
                      gridCell(idx['CARDINALITY']),
                      gridCell(idx['INDEX_TYPE']),
                    ],
                  ),
            ],
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------- ddl

  Future<void> _loadDdl() async {
    try {
      final res = await Api.instance.ddl(widget.db, widget.table);
      if (mounted) setState(() => _ddl = (res['ddl'] ?? '').toString());
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Widget _ddlTab() {
    return CardBox(
      title: 'DDL',
      actions: [Btn(t('refresh'), small: true, onPressed: _loadDdl)],
      child: CodeBlock(_ddl ?? '加载中…'),
    );
  }

  // ----------------------------------------------------------------- design

  Widget _designTab() {
    final features = _features();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CardBox(
          title: (I18n.current == AppLang.en ? 'Table options' : '表选项'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FormRow(
                label: (I18n.current == AppLang.en ? 'Rename to' : '重命名为'),
                child: Field(label: '', controller: _renameTo,
                  hint: I18n.current == AppLang.en ? 'New table name (leave blank to keep)' : '新表名（留空不改）'),
              ),
              FormRow(
                label: t('table_comment'),
                child: Field(label: '', controller: _tableComment),
              ),
            ],
          ),
        ),
        CardBox(
          title: (I18n.current == AppLang.en ? 'Column design' : '字段设计'),
          actions: [
            Btn(t('add_column'), small: true, onPressed: _addDesignColumn),
          ],
          child: GridTable(
            headers: [
              Text(t('column_name')),
              Text(t('column_type')),
              Text((I18n.current == AppLang.en ? 'Allow NULL' : '允许 NULL')),
              Text(t('default_value')),
              Text(t('auto_increment')),
              Text(t('comment')),
              Text(t('tab_status')),
              Text(t('actions')),
            ],
            emptyText: (I18n.current == AppLang.en ? '(none)' : '（无）'),
            rows: [
              for (var i = 0; i < _designColumns.length; i++)
                _designColumnRow(i),
            ],
          ),
        ),
        if (features['index'] != false)
          CardBox(
            title: (I18n.current == AppLang.en ? 'Indexes' : '索引'),
            actions: [Btn('添加索引', small: true, onPressed: _addDesignIndex)],
            child: GridTable(
              headers: [
                Text((I18n.current == AppLang.en ? 'Index name' : '索引名')),
                Text((I18n.current == AppLang.en ? 'Unique' : '唯一')),
                Text(t('columns')),
                Text(t('actions')),
              ],
              emptyText: (I18n.current == AppLang.en ? '(none)' : '（无）'),
              rows: [
                for (final index in _structureIndexes())
                  _designIndexRow(index),
                for (var i = 0; i < _designNewIndexes.length; i++)
                  _designNewIndexRow(i),
              ],
            ),
          ),
        CardBox(
          title: (I18n.current == AppLang.en ? 'Foreign keys' : '外键'),
          actions: [
            Btn((I18n.current == AppLang.en ? 'Add foreign key' : '添加外键'),
                small: true,
                onPressed: AppState.instance.isSqlite ? null : _addDesignFk),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (AppState.instance.isSqlite)
                Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('SQLite 不支持通过设计器添加外键。', style: kSmallMuted),
                ),
              GridTable(
                headers: [
                  Text((I18n.current == AppLang.en ? 'Name' : '名称')),
                  Text(t('columns')),
                  Text((I18n.current == AppLang.en ? 'Referenced table' : '引用表')),
                  Text((I18n.current == AppLang.en ? 'Referenced column' : '引用字段')),
                  Text((I18n.current == AppLang.en ? 'On delete' : '删除时')),
                  Text((I18n.current == AppLang.en ? 'On update' : '更新时')),
                  Text(t('actions')),
                ],
                emptyText: (I18n.current == AppLang.en ? '(none)' : '（无）'),
                rows: [
                  for (final fk in _structureFks()) _designFkRow(fk),
                  for (var i = 0; i < _designNewFks.length; i++)
                    _designNewFkRow(i),
                ],
              ),
            ],
          ),
        ),
        CardBox(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Btn(t('preview_sql'), onPressed: _previewDesign),
                  Btn((I18n.current == AppLang.en ? 'Apply changes' : '应用修改'), primary: true, onPressed: _applyDesign),
                ],
              ),
              const SizedBox(height: 8),
              if (_designError != null) AlertBox(_designError!),
              if (_designSql != null) CodeBlock(_designSql!),
              for (final result in _designResults)
                AlertBox(
                  (result['statement'] ?? '').toString() +
                      ((result['error'] ?? '') == null
                          ? ' ✓'
                          : '\n${result['error']}'),
                  tone: (result['error'] ?? '') == null
                      ? AlertTone.ok
                      : AlertTone.error,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Map<String, dynamic> _features() {
    final meta = AppState.instance.metaOptions;
    final features = meta?['features'];
    if (features is Map) return Map<String, dynamic>.from(features);
    return <String, dynamic>{};
  }

  List<Json> _structureIndexes() {
    final value = _structure['indexes'];
    if (value is! List) return <Json>[];
    // Collapse the per-column index rows into one row per index name.
    final grouped = <String, Json>{};
    for (final raw in value) {
      final idx = Map<String, dynamic>.from(raw as Map);
      final name = (idx['INDEX_NAME'] ?? '').toString();
      if (name.isEmpty) continue;
      final existing = grouped[name];
      if (existing == null) {
        grouped[name] = {
          'INDEX_NAME': name,
          'NON_UNIQUE': idx['NON_UNIQUE'],
          'columns': <String>[idx['COLUMN_NAME'].toString()],
        };
      } else {
        (existing['columns'] as List).add(idx['COLUMN_NAME'].toString());
      }
    }
    return grouped.values.toList();
  }

  List<Json> _structureFks() {
    final value = _structure['foreign_keys'];
    if (value is! List) return <Json>[];
    return value.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  TableRow _designColumnRow(int index) {
    final column = _designColumns[index];
    final changed = _columnChanged(column);
    return TableRow(
      decoration: BoxDecoration(
        color: changed ? AppColors.rowSelected : Colors.transparent,
      ),
      children: [
        _textCell(column['name'], (v) => column['name'] = v, mono: true),
        _textCell(column['type'], (v) => column['type'] = v, mono: true),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: CheckBox(
            label: '',
            value: column['nullable'] == true,
            onChanged: (v) => setState(() => column['nullable'] = v),
          ),
        ),
        _textCell(column['default'], (v) => column['default'] = v),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: CheckBox(
            label: '',
            value: column['auto_increment'] == true,
            onChanged: (v) => setState(() => column['auto_increment'] = v),
          ),
        ),
        _textCell(column['comment'], (v) => column['comment'] = v),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Pill(
            column['isNew'] == true
                ? 'new'
                : (changed ? 'changed' : '—'),
            tone: column['isNew'] == true
                ? PillTone.info
                : (changed ? PillTone.warn : PillTone.neutral),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Btn(t('delete'),
              small: true,
              danger: true,
              onPressed: () => setState(() => _designColumns.removeAt(index))),
        ),
      ],
    );
  }

  bool _columnChanged(Json column) {
    if (column['isNew'] == true) return true;
    final originalName = (column['original'] ?? '').toString();
    final original = _structureColumns.firstWhere(
      (c) => (c['name'] ?? '').toString() == originalName,
      orElse: () => <String, dynamic>{},
    );
    if (original.isEmpty) return true;
    return (original['type_name'] ?? '').toString() != column['type'] ||
        (original['IS_NULLABLE'] == 'YES') != (column['nullable'] == true) ||
        (original['COLUMN_DEFAULT'] ?? '').toString() !=
            (column['default'] ?? '').toString() ||
        (original['EXTRA'] ?? '').toString().contains('auto_increment') !=
            (column['auto_increment'] == true) ||
        (original['COLUMN_COMMENT'] ?? '').toString() !=
            (column['comment'] ?? '').toString();
  }

  Widget _textCell(Object? value, ValueChanged<String> onChanged,
      {bool mono = false}) {
    final controller = TextEditingController(text: value?.toString() ?? '');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: SizedBox(
        width: 140,
        child: TextField(
          controller: controller,
          style: mono ? monoStyle(size: 12) : const TextStyle(fontSize: 12),
          onChanged: onChanged,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          ),
        ),
      ),
    );
  }

  void _addDesignColumn() {
    setState(() {
      _designColumns.add(<String, dynamic>{
        'name': '',
        'type': AppState.instance.isMysql ? 'VARCHAR(255)' : 'TEXT',
        'nullable': true,
        'default': '',
        'auto_increment': false,
        'comment': '',
        'isNew': true,
        'original': '',
      });
    });
  }

  TableRow _designIndexRow(Json index) {
    final name = (index['INDEX_NAME'] ?? '').toString();
    final isPrimary = name.toUpperCase() == 'PRIMARY';
    return TableRow(
      children: [
        gridCell(name, mono: true),
        gridCell(index['NON_UNIQUE'] == 0 ? '是' : '否'),
        gridCell((index['columns'] as List?)?.join(', '), mono: true),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: isPrimary
              ? Text('主键不可删除', style: kSmallMuted)
              : CheckBox(
                  label: t('delete'),
                  value: _designDropIndexes.contains(name),
                  onChanged: (v) => setState(() {
                    if (v) {
                      _designDropIndexes.add(name);
                    } else {
                      _designDropIndexes.remove(name);
                    }
                  }),
                ),
        ),
      ],
    );
  }

  TableRow _designNewIndexRow(int index) {
    final entry = _designNewIndexes[index];
    final columns = (entry['columns'] as List?)?.cast<String>() ?? <String>[];
    return TableRow(
      children: [
        _textCell(entry['name'], (v) => entry['name'] = v, mono: true),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: CheckBox(
            label: (I18n.current == AppLang.en ? 'Unique' : '唯一'),
            value: entry['unique'] == true,
            onChanged: (v) => setState(() => entry['unique'] = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(4),
          child: SizedBox(
            width: 200,
            child: Wrap(
              spacing: 4,
              children: [
                for (final column in _designColumns)
                  FilterChip(
                    label: Text((column['name'] ?? '').toString(),
                        style: const TextStyle(fontSize: 11)),
                    selected: columns.contains(column['name']),
                    onSelected: (selected) => setState(() {
                      if (selected) {
                        columns.add(column['name'].toString());
                      } else {
                        columns.remove(column['name']);
                      }
                      entry['columns'] = columns;
                    }),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Btn('移除',
              small: true,
              danger: true,
              onPressed: () =>
                  setState(() => _designNewIndexes.removeAt(index))),
        ),
      ],
    );
  }

  void _addDesignIndex() {
    setState(() {
      _designNewIndexes.add(<String, dynamic>{
        'name': '',
        'unique': false,
        'columns': <String>[],
      });
    });
  }

  TableRow _designFkRow(Json fk) {
    final name = (fk['CONSTRAINT_NAME'] ?? '').toString();
    return TableRow(
      children: [
        gridCell(name.isEmpty ? '（自动）' : name, mono: true),
        gridCell(fk['COLUMN_NAME'], mono: true),
        gridCell(fk['REFERENCED_TABLE_NAME'], mono: true),
        gridCell(fk['REFERENCED_COLUMN_NAME'], mono: true),
        gridCell(fk['DELETE_RULE']),
        gridCell(fk['UPDATE_RULE']),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: name.isEmpty
              ? Text('—', style: kSmallMuted)
              : CheckBox(
                  label: t('delete'),
                  value: _designDropFks.contains(name),
                  onChanged: (v) => setState(() {
                    if (v) {
                      _designDropFks.add(name);
                    } else {
                      _designDropFks.remove(name);
                    }
                  }),
                ),
        ),
      ],
    );
  }

  TableRow _designNewFkRow(int index) {
    final fk = _designNewFks[index];
    final tables = _builderTables.map((t) => t['name'].toString()).toList();
    return TableRow(
      children: [
        _textCell(fk['name'], (v) => fk['name'] = v, mono: true),
        _columnPicker(fk['columns'], (v) => setState(() => fk['columns'] = v)),
        Padding(
          padding: const EdgeInsets.all(4),
          child: SelectBox<String>(
            width: 150,
            value: (fk['ref_table'] ?? '').toString().isEmpty
                ? null
                : fk['ref_table'].toString(),
            onChanged: (v) => setState(() => fk['ref_table'] = v ?? ''),
            items: [
              const DropdownMenuItem(value: null, child: Text('选择表')),
              for (final table in tables)
                DropdownMenuItem(value: table, child: Text(table)),
            ],
          ),
        ),
        _textCell(fk['ref_columns'], (v) => fk['ref_columns'] = v),
        _actionPicker(fk, 'on_delete'),
        _actionPicker(fk, 'on_update'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Btn('移除',
              small: true,
              danger: true,
              onPressed: () => setState(() => _designNewFks.removeAt(index))),
        ),
      ],
    );
  }

  Widget _columnPicker(Object? value, ValueChanged<String> onChanged) {
    final current = value?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.all(4),
      child: SelectBox<String>(
        width: 140,
        value: current.isEmpty ? null : current,
        onChanged: (v) => onChanged(v ?? ''),
        items: [
          const DropdownMenuItem(value: null, child: Text('选择字段')),
          for (final column in _designColumns)
            DropdownMenuItem(
              value: column['name'].toString(),
              child: Text(column['name'].toString()),
            ),
        ],
      ),
    );
  }

  Widget _actionPicker(Json fk, String key) {
    const actions = ['', 'CASCADE', 'SET NULL', 'RESTRICT', 'NO ACTION'];
    final current = (fk[key] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.all(4),
      child: SelectBox<String>(
        width: 130,
        value: current.isEmpty ? '' : current,
        onChanged: (v) => setState(() => fk[key] = v ?? ''),
        items: [
          for (final action in actions)
            DropdownMenuItem(
              value: action,
              child: Text(action.isEmpty ? 'NO ACTION' : action),
            ),
        ],
      ),
    );
  }

  void _addDesignFk() {
    setState(() {
      _designNewFks.add(<String, dynamic>{
        'name': '',
        'columns': '',
        'ref_table': '',
        'ref_columns': '',
        'on_delete': '',
        'on_update': '',
      });
    });
  }

  /// Build the AlterTableSpec payload, sending only real differences.
  Map<String, dynamic> _buildAlter() {
    final addColumns = <Json>[];
    final modifyColumns = <Json>[];
    final dropColumns = <String>[];
    final kept = <String>{};

    for (final column in _designColumns) {
      final name = (column['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final payload = <String, dynamic>{
        'name': name,
        'type': (column['type'] ?? '').toString(),
        'nullable': column['nullable'] == true,
        'default': (column['default'] ?? '').toString().isEmpty
            ? null
            : column['default'].toString(),
        'auto_increment': column['auto_increment'] == true,
        'comment': (column['comment'] ?? '').toString().isEmpty
            ? null
            : column['comment'].toString(),
      };
      if (column['isNew'] == true) {
        addColumns.add(payload);
      } else {
        kept.add((column['original'] ?? name).toString());
        if (_columnChanged(column)) modifyColumns.add(payload);
      }
    }
    // A column that existed before and is neither kept nor renamed is dropped.
    for (final original in _structureColumns) {
      final name = (original['name'] ?? '').toString();
      if (!kept.contains(name)) dropColumns.add(name);
    }

    final addIndexes = <Json>[];
    for (final index in _designNewIndexes) {
      final columns = (index['columns'] as List?)?.cast<String>() ?? <String>[];
      if ((index['name'] ?? '').toString().trim().isEmpty || columns.isEmpty) {
        continue;
      }
      addIndexes.add(<String, dynamic>{
        'name': index['name'].toString().trim(),
        'unique': index['unique'] == true,
        'columns': columns,
      });
    }

    final addFks = <Json>[];
    for (final fk in _designNewFks) {
      final columns = (fk['columns'] ?? '').toString().trim();
      final refTable = (fk['ref_table'] ?? '').toString().trim();
      if (columns.isEmpty || refTable.isEmpty) continue;
      final refColumns = (fk['ref_columns'] ?? '').toString().trim();
      addFks.add(<String, dynamic>{
        'name': (fk['name'] ?? '').toString().trim().isEmpty
            ? null
            : fk['name'].toString().trim(),
        'columns': columns.split(',').map((s) => s.trim()).toList(),
        'ref_table': refTable,
        'ref_columns': refColumns.isEmpty
            ? <String>[]
            : refColumns.split(',').map((s) => s.trim()).toList(),
        'on_delete': (fk['on_delete'] ?? '').toString().isEmpty
            ? null
            : fk['on_delete'].toString(),
        'on_update': (fk['on_update'] ?? '').toString().isEmpty
            ? null
            : fk['on_update'].toString(),
      });
    }

    final body = <String, dynamic>{
      'add_columns': addColumns,
      'modify_columns': modifyColumns,
      'drop_columns': dropColumns,
      'rename_columns': <dynamic>[],
      'add_indexes': addIndexes,
      'drop_indexes': _designDropIndexes.toList(),
      'add_foreign_keys': addFks,
      'drop_foreign_keys': _designDropFks.toList(),
    };
    final renameTo = _renameTo.text.trim();
    if (renameTo.isNotEmpty && renameTo != widget.table) {
      body['rename_to'] = renameTo;
    }
    final comment = _tableComment.text.trim();
    if (comment.isNotEmpty) body['comment'] = comment;
    return body;
  }

  bool _designEmpty(Map<String, dynamic> body) {
    for (final key in [
      'add_columns',
      'modify_columns',
      'drop_columns',
      'add_indexes',
      'drop_indexes',
      'add_foreign_keys',
      'drop_foreign_keys',
    ]) {
      final value = body[key];
      if (value is List && value.isNotEmpty) return false;
    }
    return body['rename_to'] == null && body['comment'] == null;
  }

  Future<void> _previewDesign() async {
    final body = _buildAlter();
    if (_designEmpty(body)) {
      setState(() => _designError = '没有需要应用的修改');
      return;
    }
    try {
      final res = await Api.instance.alterTable(
        widget.db,
        widget.table,
        {...body, 'dry_run': true},
      );
      final statements = res['statements'];
      setState(() {
        _designError = null;
        _designSql = statements is List ? statements.join(';\n') : '';
        _designResults = <Json>[];
      });
    } catch (e) {
      setState(() => _designError = e.toString());
    }
  }


  Future<void> _applyDesign() async {
    final body = _buildAlter();
    if (_designEmpty(body)) {
      setState(() => _designError = '没有需要应用的修改');
      return;
    }
    try {
      final preview = await Api.instance.alterTable(
        widget.db,
        widget.table,
        {...body, 'dry_run': true},
      );
      final statements = preview['statements'];
      final sql = statements is List ? statements.join(';\n') : '';
      if (!mounted) return;
      final ok = await confirmDialog(
        context,
        message: '确定应用以下修改吗？',
        detail: sql,
        confirmLabel: '应用',
      );
      if (!ok) return;
      final res = await Api.instance.alterTable(widget.db, widget.table, body);
      final executed = res['results'];
      setState(() {
        _designError = null;
        _designSql = sql;
        _designResults = executed is List
            ? executed.map((e) => Map<String, dynamic>.from(e as Map)).toList()
            : <Json>[];
      });
      final failed = _designResults.where((r) => r['error'] != null).length;
      if (failed == 0) {
        widget.notice.show('修改已应用');
        await _reloadAll();
      } else {
        setState(() => _designError = '有 $failed 条语句执行失败，请查看下方结果');
      }
    } catch (e) {
      if (mounted) setState(() => _designError = describeDbError(e));
    }
  }


  // -------------------------------------------------------------------- sql

  /// First line of the table page SQL editor.
  ///
  /// MySQL has a real USE statement; the console intercepts it and applies it
  /// as a validated database switch (so it cannot bypass only_db / hide_db).
  /// PostgreSQL uses the equivalent SET search_path, and SQLite has no USE
  /// syntax, so a comment documents the attached namespace instead.
  String _defaultSqlPrelude() {
    final state = AppState.instance;
    if (state.isMysql) {
      return 'USE ${state.quoteIdent(widget.db)};';
    }
    if (state.isPostgres) {
      return 'SET search_path TO ${state.quoteIdent(widget.db)};';
    }
    return '-- 当前数据库: ${widget.db}';
  }

  String _defaultTableSql() =>
      '${_defaultSqlPrelude()}\n\n'
      'SELECT * FROM ${AppState.instance.qualify(widget.db, widget.table)} LIMIT 50;';

  Widget _sqlTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CardBox(
          title: 'SQL 控制台 — ${widget.db}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SqlEditor(
                controller: _sqlController,
                lines: 7,
                onChanged: (v) => _sqlText = v,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  Btn(t('run'), primary: true, onPressed: _runSql),
                  Btn('EXPLAIN', onPressed: _explainSql),
                ],
              ),
            ],
          ),
        ),
        ResultTable(
          results: _sqlResults,
          database: widget.db,
          notice: widget.notice,
          onRefresh: (_) => _rerunSql(),
        ),
      ],
    );
  }

  List<Json> _resultsOf(Object? value) {
    if (value is! List) return <Json>[];
    return value.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> _runSql() async {
    setState(() => _sqlError = null);
    try {
      final res = await Api.instance.query(_sqlText, widget.db);
      setState(() => _sqlResults = _resultsOf(res['results']));
      // The SQL tab can change the row count (INSERT / DELETE / TRUNCATE), so
      // the pill has to re-count here too.
      await _reloadAfterWrite();
    } catch (e) {
      if (mounted) setState(() => _sqlError = describeDbError(e));
    }
  }

  Future<void> _rerunSql() async {
    setState(() => _sqlError = null);
    try {
      final res = await Api.instance.query(_sqlText, widget.db);
      setState(() => _sqlResults = _resultsOf(res['results']));
    } catch (e) {
      if (mounted) setState(() => _sqlError = describeDbError(e));
    }
  }

  Future<void> _explainSql() async {
    setState(() => _sqlError = null);
    try {
      final res = await Api.instance.explain(_sqlText, widget.db);
      setState(() => _sqlResults = _resultsOf(res['results']));
    } catch (e) {
      if (mounted) setState(() => _sqlError = describeDbError(e));
    }
  }
  // ----------------------------------------------------------------- insert

  /// Error shown inside the insert card; the page banner is far above the form
  /// once the table has many columns.
  String? _insertError;

  /// N-04: inline success confirmation next to the insert form.
  ///
  /// The page-level toast is 3 s and can be above the fold on a table with many
  /// columns, which made a successful insert look like nothing happened. This
  /// stays next to the buttons until the next insert.
  String? _insertNotice;

  Widget _insertTab() {
    return CardBox(
      title: '插入行',
      actions: [
        Btn('插入', primary: true, onPressed: _insertRow),
        Btn(t('clear'), onPressed: () => setState(_seedInsertValues)),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('留空的字段将使用默认值。', style: kSmallMuted),
          ),
          if (_insertError != null) AlertBox(_insertError!),
          if (_insertNotice != null)
            AlertBox(_insertNotice!, tone: AlertTone.ok),
          for (var i = 0; i < _structureColumns.length; i++) _insertRowWidget(i),
        ],
      ),
    );
  }

  Widget _insertRowWidget(int index) {
    final column = _structureColumns[index];
    final name = column['name'].toString();
    final rawType = (column['type_name'] ?? '').toString();
    final type = rawType.toLowerCase();
    final isBoolean = type.startsWith('bool') || type.startsWith('tinyint(1)');
    final isLongText = type.contains('text') || type.contains('json');
    // MySQL spells the allowed values in COLUMN_TYPE, e.g.
    // enum('G','PG-13','R'). A free-text box let any string through and only
    // the server complained ("Data truncated for column 'rating'", round34
    // P3-01), so an enum column gets a dropdown built from its own definition.
    final enumOptions = enumColumnOptions(rawType);
    final setOptions = setColumnOptions(rawType);
    final nullable = column['IS_NULLABLE'] == 'YES';
    final state = _insertValues[index];
    final isNull = state['isNull'] == true;
    final current = (state['value'] ?? '').toString();

    // Every column owns a controller and _insertRow reads it as the
    // authoritative value (it is what the user sees in the box), so a dropdown
    // has to write through to the controller, not only to _insertValues.
    void setValue(String next) {
      setState(() {
        state['value'] = next;
        _insertControllers
            .putIfAbsent(name, () => TextEditingController())
            .text = next;
      });
    }

    final Widget field;
    if (enumOptions != null) {
      field = SelectBox<String>(
        value: current.isEmpty ? _defaultInsertOption : current,
        enabled: !isNull,
        onChanged: (v) => setValue(v == _defaultInsertOption ? '' : (v ?? '')),
        items: [
          const DropdownMenuItem(
              value: _defaultInsertOption, child: Text(_defaultInsertOption)),
          for (final option in enumOptions)
            DropdownMenuItem(
                value: option, child: Text(option, noTranslate: true)),
        ],
      );
    } else if (isBoolean) {
      field = SelectBox<String>(
        value: current.isEmpty ? _defaultInsertOption : current,
        enabled: !isNull,
        onChanged: (v) => setValue(v == _defaultInsertOption ? '' : (v ?? '')),
        items: const [
          DropdownMenuItem(
              value: _defaultInsertOption, child: Text(_defaultInsertOption)),
          DropdownMenuItem(value: 'true', child: Text('true')),
          DropdownMenuItem(value: 'false', child: Text('false')),
        ],
      );
    } else {
      field = TextField(
        // Controlled: the box mirrors _insertValues through this controller,
        // so clearing the form really clears the text.
        controller: _insertControllers.putIfAbsent(
            name, () => TextEditingController()),
        enabled: !isNull,
        maxLines: isLongText ? 2 : 1,
        style: monoStyle(size: 12),
        onChanged: (v) => state['value'] = v,
        decoration: InputDecoration(
          isDense: true,
          border: const OutlineInputBorder(),
          // A set(...) column takes several of these values, comma separated,
          // so it stays a text box; the hint lists what the definition allows.
          hintText: setOptions?.join(' / '),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 160,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: monoStyle(size: 12, weight: FontWeight.w600)),
                Text(column['type_name']?.toString() ?? '',
                    style: monoStyle(size: 11, color: AppColors.typeText)),
              ],
            ),
          ),
          Expanded(child: field),
          const SizedBox(width: 8),
          CheckBox(
            label: 'NULL',
            value: isNull,
            enabled: nullable,
            onChanged: (v) => setState(() => state['isNull'] = v),
          ),
        ],
      ),
    );
  }

  Future<void> _insertRow() async {
    final values = <String, dynamic>{};
    for (var i = 0; i < _structureColumns.length; i++) {
      final column = _structureColumns[i];
      final name = column['name'].toString();
      final state = _insertValues[i];
      if (state['isNull'] == true) {
        values[name] = null;
        continue;
      }
      // The controller is authoritative: it is what the user sees in the box.
      final raw = (_insertControllers[name]?.text ?? state['value'] ?? '')
          .toString();
      if (raw.isEmpty) continue;
      // Checked before the round trip: the server answers an enum/set value it
      // cannot store with "Data truncated for column 'x'" (English + error
      // code), which reads as an application failure instead of "pick one of
      // these" (round34 P3-01).
      final invalid =
          typedValueError(name, column['type_name']?.toString(), raw);
      if (invalid != null) {
        setState(() {
          _insertError = invalid;
          _insertNotice = null;
        });
        return;
      }
      values[name] = _coerce(column, raw);
    }
    if (values.isEmpty) {
      setState(() {
        _insertError = '请至少填写一个字段';
        _insertNotice = null;
      });
      return;
    }
    setState(() {
      _insertError = null;
      _insertNotice = null;
    });
    try {
      await Api.instance.changeRow(widget.db, widget.table, {
        'action': 'insert',
        'values': values,
      });
      widget.notice.show('行已插入');
      setState(() {
        _insertError = null;
        _insertNotice = '已插入 1 行（数据已刷新）';
        _seedInsertValues();
      });
      await _reloadAfterWrite();
    } catch (e) {
      if (mounted) {
        setState(
            () => _insertError = describeInsertError(e, _structureColumns));
      }
    }
  }

  // ----------------------------------------------------------------- export

  Widget _exportTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CardBox(
          title: t('export_title', {'name': widget.table}),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(I18n.current == AppLang.en ? 'Format' : '格式', style: kSmall),
              SelectBox<String>(
                width: 140,
                value: _exportFormat,
                onChanged: (v) => setState(() {
                  _exportFormat = v ?? 'sql';
                  _exportPreview = null;
                }),
                items: const [
                  DropdownMenuItem(value: 'sql', child: Text('SQL')),
                  DropdownMenuItem(value: 'csv', child: Text('CSV')),
                  DropdownMenuItem(value: 'json', child: Text('JSON')),
                  DropdownMenuItem(value: 'xml', child: Text('XML')),
                  DropdownMenuItem(value: 'html', child: Text('HTML')),
                  DropdownMenuItem(value: 'txt', child: Text('TXT')),
                  DropdownMenuItem(value: 'xls', child: Text('Excel')),
                  DropdownMenuItem(value: 'md', child: Text('Markdown')),
                ],
              ),
              if (_exportFormat == 'sql') ...[
                CheckBox(
                  label: I18n.current == AppLang.en ? 'Include structure' : t('export_structure'),
                  value: _exportStructure,
                  onChanged: (v) => setState(() => _exportStructure = v),
                ),
                CheckBox(
                  label: I18n.current == AppLang.en ? 'Include data' : t('export_data'),
                  value: _exportData,
                  onChanged: (v) => setState(() => _exportData = v),
                ),
                CheckBox(
                  label: I18n.current == AppLang.en ? 'Include DROP' : t('export_drop'),
                  value: _exportDrop,
                  onChanged: (v) => setState(() => _exportDrop = v),
                ),
              ],
              Btn(
                  _exporting
                      ? (I18n.current == AppLang.en
                          ? 'Exporting…'
                          : '导出中…')
                      : (I18n.current == AppLang.en
                          ? 'Export to file'
                          : '导出到文件'),
                  primary: true,
                  busy: _exporting,
                  onPressed: _exporting ? null : _doExport),
              Btn(t('preview'),
                  onPressed: _exporting ? null : _previewExport),
            ],
          ),
        ),
        if (_exportPreview != null) CodeBlock(_exportPreview!, maxHeight: 420),
      ],
    );
  }

  Json _exportParams() => <String, dynamic>{
        'format': _exportFormat,
        'structure': _exportStructure,
        'data': _exportData,
        'drop': _exportDrop,
      };

  /// Default file name the save dialog should propose for the active format.
  String _exportFileName() {
    final ext = switch (_exportFormat) {
      'markdown' => 'md',
      'excel' => 'xls',
      _ => _exportFormat,
    };
    return '${widget.table}.$ext';
  }

  Future<void> _previewExport() async {
    try {
      final res = await Api.instance
          .exportTable(widget.db, widget.table, _exportParams());
      final content = (res['content'] ?? '').toString();
      final truncated = res['truncated'] == true;
      final note = I18n.current == AppLang.en
          ? '\n…(preview truncated)'
          : '\n…（预览已截断）';
      setState(() => _exportPreview = truncated ? '$content$note' : content);
    } catch (e) {
      if (mounted) setState(() => _error = describeDbError(e));
    }
  }

  /// Export the table, streaming the file from Rust.
  ///
  /// The old path fetched the whole table as a String through the FFI bridge
  /// and handed it to the save dialog; on a million-row table that peaked
  /// around 1 GB of memory (test report §6.3 P1). The destination is chosen
  /// first, then the Rust core writes it row by row.
  Future<void> _doExport() async {
    if (_exporting) return;
    String? path;
    try {
      path = await pickSavePath(
        title: I18n.current == AppLang.en ? 'Export to file' : '导出到文件',
        fileName: _exportFileName(),
        initialDirectory: AppState.instance.dataDir,
      );
      if (path == null || path.isEmpty) return;
      if (!mounted) return;
      setState(() {
        _exporting = true;
        _error = null;
      });
      final res = await Api.instance.exportTable(
          widget.db, widget.table, {..._exportParams(), 'path': path});
      if (!mounted) return;
      final rows = (res['rows'] as num?)?.toInt() ?? 0;
      widget.notice.show(
          I18n.current == AppLang.en
              ? 'Exported $rows rows to $path'
              : '已导出 $rows 行到 $path');
    } catch (e) {
      // The native save dialog already created/truncated the destination; do
      // not leave an empty file behind when the streamed export failed.
      if (path != null && path.isNotEmpty) {
        try {
          final file = File(path);
          if (file.existsSync() && file.lengthSync() == 0) file.deleteSync();
        } catch (_) {
          // Best effort only; the export error below is what matters.
        }
      }
      if (mounted) setState(() => _error = describeDbError(e));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }
  // ----------------------------------------------------------------- import

  Widget _importTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _dataImportCard(),
        _sqlFileImportCard(),
      ],
    );
  }

  Widget _dataImportCard() {
    return CardBox(
      title: pickText('导入数据文件到 ${widget.table}',
          'Import data file into ${widget.table}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            pickText(
              '支持 CSV / TSV / 分隔文本 / JSON 数组 / JSON Lines / 自定义包裹与分隔的文本。'
              '通过向导逐步设置一条数据怎么切分、列怎么识别，先试插入一条并校验整个文件，通过后再分批写入。',
              'Supports CSV / TSV / delimited text / JSON arrays / JSON Lines / custom '
              'wrappers and separators. Step through the wizard to define how one '
              'record is split and how columns are detected; one row is trial-inserted '
              'and the whole file validated before batching.',
            ),
            style: kSmallMuted,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Btn('打开数据导入向导',
                  key: const ValueKey('data-import-wizard'),
                  primary: true,
                  icon: Icons.upload_file,
                  onPressed: _openDataImportWizard),
              Btn('保存格式示例',
                  key: const ValueKey('data-import-sample'),
                  onPressed: _saveImportSample),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sqlFileImportCard() {
    final info = _importFileInfo;
    final result = _importResult;
    final progress = asJsonMap(_importJobStatus?['progress']);
    final percent = (progress['percent'] as num?)?.toDouble() ?? 0;
    final jobRunning =
        _importJobStatus != null && _importJobStatus!['done'] != true;
    return CardBox(
      title: pickText(
          '执行 SQL 文件到 ${widget.db}', 'Run SQL file on ${widget.db}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            pickText(
              '选择 UTF-8 的 .sql 脚本（支持 DELIMITER 指令），从磁盘流式读取并逐条执行；'
              '大文件不会整个载入内存，执行过程中可取消。',
              'Choose a UTF-8 .sql script (DELIMITER supported); it is streamed from '
              'disk and executed statement by statement. Large files are never loaded '
              'into memory and the run can be cancelled.',
            ),
            style: kSmallMuted,
          ),
          const SizedBox(height: 4),
          Text(_importContextText(), style: kSmallMuted),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Btn('选择 SQL 文件',
                  key: const ValueKey('sql-import-pick'),
                  onPressed: _importing ? null : _pickImportFile),
              if (_importPath != null)
                Text(
                  '${info?['name'] ?? baseNameOf(_importPath!)}'
                  '${info == null ? '' : ' · ${formatBytes((info['size'] as num?)?.toInt())}'}',
                  style: kSmallMuted,
                ),
              Btn(jobRunning ? '执行中…' : '执行 SQL 文件',
                  key: const ValueKey('sql-import-run'),
                  primary: true,
                  busy: jobRunning,
                  onPressed:
                      _importPath == null || _importing ? null : _runImport),
              if (jobRunning)
                Btn('取消',
                    danger: true, onPressed: () => _importPoller?.cancelJob()),
            ],
          ),
          if (jobRunning) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: percent <= 0 ? null : (percent / 100).clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: AppColors.chipBg,
              valueColor:
                  AlwaysStoppedAnimation<Color>(AppColors.header),
            ),
            const SizedBox(height: 6),
            Text(
              '${formatBytes((progress['bytes'] as num?)?.toInt() ?? 0)}'
              ' / ${formatBytes((progress['total_bytes'] as num?)?.toInt() ?? 0)}'
              '（${percent.toStringAsFixed(1)}%） · 已执行 '
              '${formatCount((progress['records'] as num?))} 条语句 · 用时 '
              '${((progress['elapsed_ms'] as num?)?.toInt() ?? 0) / 1000} 秒',
              style: kSmallMuted,
            ),
          ],
          if (result != null) ...[
            const SizedBox(height: 10),
            AlertBox(
              _importResultText(result),
              tone: result['ok'] == true ? AlertTone.ok : AlertTone.error,
            ),
            if (result['use_database'] != null) ...[
              Text(
                '执行中切换数据库：${result['use_database']}',
                style: kSmallMuted,
              ),
              const SizedBox(height: 6),
            ],
            if ((result['issues'] as List? ?? const <dynamic>[]).isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final raw in (result['issues'] as List).take(10))
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    issuePositionLabel(asJsonMap(raw)),
                    style: TextStyle(
                        fontSize: 12, color: AppColors.errText),
                  ),
                ),
              if ((result['issues'] as List).length > 10)
                Text(
                  '（仅显示前 10 条，共 ${(result['issues'] as List).length} 条）',
                  style: kSmallMuted,
                ),
            ],
          ],
        ],
      ),
    );
  }

  /// Context line for the SQL file card: the first statement the backend
  /// establishes (equivalent to a USE database statement) is surfaced so the user knows
  /// which database the file will run against.
  String _importContextText() {
    final state = AppState.instance;
    if (state.isMysql) {
      return '执行上下文：首条自动切换到 USE ${state.quoteIdent(widget.db)};（由应用校验可见性后安全切换）。';
    }
    if (state.isPostgres) {
      return '执行上下文：目标模式 ${widget.db}（文件中的表名建议使用模式限定）。';
    }
    return pickText('执行上下文：目标命名空间 ${widget.db}。',
        'Execution context: target namespace ${widget.db}.');
  }

  String _importResultText(Json result) {
    final statements = (result['statements'] as num?)?.toInt() ?? 0;
    final succeeded = (result['succeeded'] as num?)?.toInt() ?? 0;
    final failed = (result['failed'] as num?)?.toInt() ?? 0;
    final seconds = ((result['elapsed_ms'] as num?)?.toInt() ?? 0) / 1000;
    if (result['cancelled'] == true) {
      return '已取消：共执行 ${formatCount(statements)} 条语句，成功 ${formatCount(succeeded)} 条。';
    }
    if (result['ok'] == true) {
      return '执行完成：${formatCount(statements)} 条语句全部成功，用时 $seconds 秒。';
    }
    final message = (result['message'] ?? '').toString();
    return '执行结束：共 ${formatCount(statements)} 条语句，成功 ${formatCount(succeeded)} 条，'
        '失败 ${formatCount(failed)} 条。${message.isEmpty ? '' : '\n$message'}';
  }

  Future<void> _openDataImportWizard() async {
    await showDataImportWizard(
      context,
      database: widget.db,
      table: widget.table,
      notice: widget.notice,
      onImported: () async {
        await _reloadAfterWrite();
        await _loadStructure();
      },
    );
  }

  Future<void> _saveImportSample() async {
    const sample = 'id,name,age\n1,Ada,36\n2,Bob,41\n';
    try {
      final path = await pickSavePath(
        title: '保存数据导入示例',
        fileName: '${widget.table}_sample.csv',
        initialDirectory: AppState.instance.dataDir,
      );
      if (path == null || path.isEmpty) return;
      await Api.instance.writeTextFile(path, sample);
      widget.notice.show('示例已保存到 $path');
    } catch (e) {
      if (mounted) setState(() => _error = describeDbError(e));
    }
  }

  Future<void> _pickImportFile() async {
    try {
      final path = await pickSqlFile(title: '选择要执行的 SQL 文件');
      if (path == null || path.trim().isEmpty) return;
      final info = await Api.instance.sqlFilePreview(path.trim(), maxBytes: 1024);
      if (!mounted) return;
      setState(() {
        _importPath = path.trim();
        _importFileInfo = info;
        _importResult = null;
        _importJobStatus = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = describeDbError(e));
    }
  }

  Future<void> _runImport() async {
    final path = _importPath;
    if (path == null) return;
    setState(() {
      _importing = true;
      _importResult = null;
      _importJobStatus = null;
    });
    try {
      final res = await Api.instance
          .sqlFileExecuteStart(widget.db, path, <String, dynamic>{
        'on_error': 'stop',
        'max_issues': 50,
      });
      final jobId = (res['job_id'] ?? '').toString();
      if (!mounted) return;
      if (jobId.isEmpty) {
        setState(() => _importing = false);
        return;
      }
      _importPoller?.dispose();
      _importPoller = ImportJobPoller(onUpdate: (status) {
        if (!mounted) return;
        setState(() {
          _importJobStatus = status;
          if (status['done'] != true) return;
          _importing = false;
          if (status['state'] == 'failed') {
            _importResult = <String, dynamic>{
              'ok': false,
              'message': (status['error'] ?? '任务失败').toString(),
            };
          } else {
            _importResult = asJsonMap(status['result']);
            if (_importResult?['ok'] == true) {
              widget.notice.show('SQL 文件执行完成');
              _reloadAll();
            }
          }
        });
      });
      _importPoller!.start(jobId);
    } catch (e) {
      if (mounted) {
        setState(() {
          _importing = false;
          _importResult = <String, dynamic>{
            'ok': false,
            'message': describeDbError(e),
          };
        });
      }
    }
  }

  // ------------------------------------------------------------- operations

  Widget _operationsTab() {
    return CardBox(
      title: '操作',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_isView)
            Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('视图不能清空或删除。', style: kSmallMuted),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Btn('清空表', onPressed: _isView ? null : _truncateTable),
              Btn('删除表', danger: true, onPressed: _isView ? null : _dropTable),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _truncateTable() async {
    final ok = await confirmDialog(
      context,
      message: '确定清空表 ${widget.table} 吗？',
      detail: 'TRUNCATE TABLE 会删除全部数据且无法回滚。',
      confirmLabel: '清空',
      danger: true,
    );
    if (!ok) return;
    try {
      await Api.instance.truncate(widget.db, widget.table);
      widget.notice.show('表已清空');
      await _reloadAfterWrite();
    } catch (e) {
      if (mounted) setState(() => _error = describeDbError(e));
    }
  }

  Future<void> _dropTable() async {
    final ok = await confirmDialog(
      context,
      message: '确定删除表 ${widget.table} 吗？',
      detail: 'DROP TABLE 会连同数据一起删除且无法回滚。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    try {
      await Api.instance.dropTable(widget.db, widget.table);
      widget.notice.show('表已删除');
      AppState.instance.bumpExplorer();
      if (mounted) Navigation.instance.go(AppRoute.database(widget.db));
    } catch (e) {
      if (mounted) setState(() => _error = describeDbError(e));
    }
  }
}
// -------------------------------------------------------------------- helpers

/// Whether a table-page request must run COUNT(*).
///
/// The round-34 keyset contract counts only the first, un-cursored page: a
/// cursor page comes back with total: null and reuses the total learned on
/// page 1, because a full count on a wide table often costs more than the page
/// itself. A write or an explicit refresh passes [refreshCount] so the header's
/// row-count pill is refreshed even on a cursor page — one extra count per user
/// action, never one per page.
bool shouldCountTableRows({required Object? cursor, bool refreshCount = false}) =>
    cursor == null || refreshCount;

/// Values declared by a MySQL enum(...) / set(...) column.
///
/// [columnType] is the raw COLUMN_TYPE from information_schema, which the
/// structure query exposes as type_name (for example enum('G','PG-13','R')).
/// [base] is enum or set; any other type — varchar(10), PostgreSQL's
/// USER-DEFINED — returns null, meaning no value list is available.
///
/// Values keep their original case: the column definition is the only place
/// they are spelled out, and the widgets lowercase the type for their own
/// checks, which would turn PG into pg and make every value look invalid.
List<String>? _declaredTypeOptions(String? columnType, String base) {
  final type = (columnType ?? '').trim();
  final opening = RegExp('^$base\\s*\\(', caseSensitive: false);
  final match = opening.matchAsPrefix(type);
  if (match == null || !type.endsWith(')')) return null;
  final body = type.substring(match.end, type.length - 1);
  final options = <String>[];
  final buffer = StringBuffer();
  var quote = '';
  for (var i = 0; i < body.length; i++) {
    final char = body[i];
    if (quote.isEmpty) {
      if (char == "'" || char == '"') {
        quote = char;
        buffer.clear();
      }
      continue;
    }
    if (char == '\\' && i + 1 < body.length) {
      buffer.write(body[++i]);
      continue;
    }
    if (char == quote) {
      // MySQL escapes a quote inside a value by doubling it: 'it''s'.
      if (i + 1 < body.length && body[i + 1] == char) {
        buffer.write(char);
        i++;
        continue;
      }
      quote = '';
      options.add(buffer.toString());
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  return options.isEmpty ? null : options;
}

/// Allowed values of an enum column, or null when the type is not an enum.
List<String>? enumColumnOptions(String? columnType) =>
    _declaredTypeOptions(columnType, 'enum');

/// Allowed values of a set column, or null when the type is not a set.
List<String>? setColumnOptions(String? columnType) =>
    _declaredTypeOptions(columnType, 'set');

/// Reject a value the column definition cannot hold, before it reaches the
/// server.
///
/// Returns the message to show, or null when the value is acceptable. The two
/// branches are interpolated, so the call site picks the language with
/// pickText instead of relying on an exact-match dictionary entry.
String? typedValueError(String columnName, String? columnType, String raw) {
  final options = enumColumnOptions(columnType);
  if (options != null && !options.contains(raw)) {
    return pickText(
      '「$columnName」只能填以下值之一：${options.join('、')}',
      '"$columnName" only accepts one of: ${options.join(', ')}',
    );
  }
  final setValues = setColumnOptions(columnType);
  if (setValues != null) {
    final unknown = raw
        .split(',')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty && !setValues.contains(part))
        .toList();
    if (unknown.isNotEmpty) {
      return pickText(
        '「$columnName」的取值必须来自：${setValues.join('、')}（多个值用英文逗号分隔）',
        '"$columnName" values must come from: ${setValues.join(', ')}'
        ' (separate several values with commas)',
      );
    }
  }
  return null;
}

/// The column a MySQL "Data truncated for column 'x'" error names.
///
/// Kept separate so the mapping from the driver text to a readable message can
/// be unit-tested without a server.
String? truncatedColumnName(Object? error) {
  final text = error?.toString() ?? '';
  final match =
      RegExp(r"data truncated for column '([^']+)'", caseSensitive: false)
          .firstMatch(text);
  return match?.group(1);
}

/// Turn a failed INSERT into copy the user can act on.
///
/// MySQL reports an out-of-range enum/set (or an over-long value) with
/// "Data truncated for column 'x'" plus an error code, which the user cannot
/// do anything with. [columns] is the structure list, used to recover the
/// allowed values of the named column.
String describeInsertError(Object error, List<Json> columns) {
  final name = truncatedColumnName(error);
  if (name == null) return describeDbError(error);
  final column = columns.firstWhere(
      (c) => (c['name'] ?? '').toString() == name,
      orElse: () => const <String, dynamic>{});
  final options = enumColumnOptions(column['type_name']?.toString());
  if (options != null) {
    return pickText(
      '「$name」的值不在允许范围内。可选值：${options.join('、')}',
      '"$name" is outside the allowed values. Allowed: ${options.join(', ')}',
    );
  }
  return pickText(
    '「$name」的值超出了列定义允许的范围（长度或数值范围），请检查后重试。',
    '"$name" is outside the range its definition allows (length or numeric '
        'range); check the value and try again.',
  );
}