import 'dart:io';

import 'package:flutter/material.dart' hide Text, Tooltip;
import '../text.dart';

import '../api.dart';
import '../i18n_literals.dart';
import '../notice.dart';
import '../paging.dart';
import '../sqlite_sources.dart' show pickSavePath;
import '../theme.dart';
import '../widgets.dart';
import '../components/data_grid.dart';

/// Renders a list of ResultSet objects, one card each.
///
/// Ports ResultTable.vue: statement header, error alert, a DataGrid for row
/// results (editable only when the statement is a single-table SELECT and a
/// database is known), and an "N rows affected" notice otherwise.
///
/// P8 (round 30): a whole-script run can produce hundreds of result sets. Past
/// [collapseThreshold] the result cards start collapsed (statement, error and
/// row count only) behind a summary bar, so the page does not build a
/// [DataGrid] for every statement and the accessibility tree stays small.
class ResultTable extends StatelessWidget {
  const ResultTable({
    super.key,
    required this.results,
    this.database,
    required this.notice,
    this.onRefresh,
    this.rowLimit,
  });

  /// Number of results above which the collapsed layout takes over.
  ///
  /// Up to this many results the original one-card-per-result layout is used
  /// unchanged, so small queries (and every golden) keep exactly the same tree.
  static const int collapseThreshold = 6;

  /// How many folded cards the collapsed layout builds per batch (P2-05).
  ///
  /// A whole-script run can produce 500+ result sets. Folding each card removed
  /// the [DataGrid] cost, but every folded card still adds a widget subtree and
  /// accessibility nodes, so a 533-result script still pushed the AX tree past
  /// 2000 elements. Only this many cards are built until the user asks for the
  /// next batch through "show more", which is the bound this fix guarantees.
  static const int collapsedCardBatch = 60;

  final List<Json> results;
  final String? database;
  final Notice notice;
  final void Function(int index)? onRefresh;
  /// S-08: server-side cap for one statement, used in the truncation notice.
  final int? rowLimit;

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      return CardBox(child: Text('无结果', style: kMuted));
    }
    if (results.length > collapseThreshold) {
      return _CollapsedResultTable(
        results: results,
        cardBody: _resultCardBody,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < results.length; i++) _resultCard(context, i),
      ],
    );
  }

  Widget _resultCard(BuildContext context, int index) {
    return CardBox(child: _resultCardBody(context, index));
  }

  /// The contents of one result card.
  ///
  /// Split out of [_resultCard] so the collapsed layout can put its toggle
  /// header above the very same body instead of duplicating it.
  Widget _resultCardBody(BuildContext context, int index) {
    final result = results[index];
    final statement = (result['statement'] ?? '').toString();
    final error = result['error'] as String?;
    final kind = (result['kind'] ?? '').toString();
    final rowCount = (result['row_count'] as num?)?.toInt() ?? 0;
    final columns = _columns(result);
    final rows = _rows(result);
    final table = database == null ? null : inferSingleTable(statement, columns);
    final editable = table != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CodeBlock(statement, maxHeight: 120),
        const SizedBox(height: 8),
        if (error != null) AlertBox(error),
        if (rowLimit != null && result['truncated'] == true)
          AlertBox(
            pickText(
              '结果超出单次上限 ${_formatInt(rowLimit!)} 行，'
              '仅显示前 $rowCount 行；完整数据请加 WHERE / LIMIT，'
              '或到「表」页使用导出。',
              'The result exceeded the limit of ${_formatInt(rowLimit!)} rows; '
              'only the first $rowCount rows are shown. For the full data add '
              'WHERE / LIMIT, or use Export on the table page.',
            ),
            tone: AlertTone.warn,
          ),
        if (kind == 'rows')
          _RowsResultView(
            key: ValueKey('result-rows-$index'),
            columns: columns,
            rows: rows,
            statement: statement,
            database: database,
            resultIndex: index,
            rowCount: rowCount,
            truncated: result['truncated'] == true,
            editable: editable,
            notice: notice,
            onDeleteSelected: editable
                ? (indices) =>
                    _deleteRows(context, index, columns, rows, indices)
                : null,
            onSaveCell: editable
                ? (rowIndex, column, value, isNull) => _saveCell(context, index,
                    columns, rows, rowIndex, column, value, isNull)
                : null,
          )
        else
          AlertBox(
            '$rowCount 行受影响${(result['last_insert_id'] as num?)?.toInt() != null &&
                        (result['last_insert_id'] as num).toInt() > 0
                    ? '，最后插入 ID ${(result['last_insert_id'] as num).toInt()}'
                    : ''}',
            tone: AlertTone.ok,
          ),
      ],
    );
  }

  /// Group digits so a row cap reads naturally (50000 -> 50,000).
  static String _formatInt(int value) {
    final text = value.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      if (i > 0 && (text.length - i) % 3 == 0) buffer.write(',');
      buffer.write(text[i]);
    }
    return buffer.toString();
  }

  List<Json> _columns(Json result) {
    final value = result['columns'];
    if (value is! List) return <Json>[];
    return value.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  List<List<dynamic>> _rows(Json result) {
    final value = result['rows'];
    if (value is! List) return <List<dynamic>>[];
    return value.map((row) => row is List ? row : <dynamic>[]).toList();
  }

  /// Delete rows from a single-table result. Runs sequentially and stops at the
  /// first error, exactly like the web ResultTable.
  Future<void> _deleteRows(
    BuildContext context,
    int resultIndex,
    List<Json> columns,
    List<List<dynamic>> rows,
    List<int> indices,
  ) async {
    final table = inferSingleTable(
      (results[resultIndex]['statement'] ?? '').toString(),
      columns,
    );
    if (table == null || database == null) return;
    final ok = await confirmDialog(
      context,
      message: '确定删除选中的 ${indices.length} 行吗？',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    var deleted = 0;
    for (final index in indices) {
      final keys = <String, dynamic>{};
      for (var i = 0; i < columns.length; i++) {
        keys[columns[i]['name'].toString()] = index < rows.length && i < rows[index].length
            ? rows[index][i]
            : null;
      }
      try {
        await Api.instance.changeRow(database!, table, {
          'action': 'delete',
          'keys': keys,
          'limit_one': true,
        });
        deleted++;
      } catch (e) {
        notice.show('删除失败：$e');
        break;
      }
    }
    if (deleted > 0) {
      notice.show('已删除 $deleted 行');
      onRefresh?.call(resultIndex);
    }
  }

  Future<void> _saveCell(
    BuildContext context,
    int resultIndex,
    List<Json> columns,
    List<List<dynamic>> rows,
    int rowIndex,
    String column,
    Object? value,
    bool isNull,
  ) async {
    final table = inferSingleTable(
      (results[resultIndex]['statement'] ?? '').toString(),
      columns,
    );
    if (table == null || database == null) return;
    final keys = <String, dynamic>{};
    for (var i = 0; i < columns.length; i++) {
      keys[columns[i]['name'].toString()] =
          rowIndex < rows.length && i < rows[rowIndex].length ? rows[rowIndex][i] : null;
    }
    try {
      await Api.instance.changeRow(database!, table, {
        'action': 'update',
        'keys': keys,
        'values': {column: isNull ? null : value},
        'limit_one': true,
      });
      notice.show('单元格已保存');
      onRefresh?.call(resultIndex);
    } catch (e) {
      notice.show('保存失败：$e');
    }
  }
}

/// One row-returning result: paginated grid + result export.
///
/// The SQL console, the table page's SQL tab and a history re-run all show raw
/// query results here. Rows are paged 50 at a time (the same page size as the
/// table browser) instead of handing the full result to [DataGrid] at once,
/// and the export controls reuse the table page's exchange-format renderers
/// through [Api.exportQuery] — CSV / JSON / XML / HTML / TXT / Excel / Markdown,
/// not a second, weaker CSV writer.
class _RowsResultView extends StatefulWidget {
  const _RowsResultView({
    super.key,
    required this.columns,
    required this.rows,
    required this.statement,
    required this.database,
    required this.resultIndex,
    required this.rowCount,
    required this.truncated,
    required this.editable,
    required this.notice,
    this.onDeleteSelected,
    this.onSaveCell,
  });

  final List<Json> columns;
  final List<List<dynamic>> rows;
  final String statement;
  final String? database;
  final int resultIndex;
  final int rowCount;
  final bool truncated;
  final bool editable;
  final Notice notice;
  final void Function(List<int> indices)? onDeleteSelected;
  final void Function(int rowIndex, String column, Object? value, bool isNull)?
      onSaveCell;

  @override
  State<_RowsResultView> createState() => _RowsResultViewState();
}

class _RowsResultViewState extends State<_RowsResultView> {
  static const int _pageSize = 50;

  int _page = 1;
  bool _exporting = false;
  late List<Json> _formats;

  /// Built-in fallback so the dropdown works before/without the Rust probe
  /// (and in widget tests that only exercise the table).
  static const List<Json> _fallbackFormats = <Json>[
    <String, dynamic>{'id': 'csv', 'label': 'CSV'},
    <String, dynamic>{'id': 'json', 'label': 'JSON'},
    <String, dynamic>{'id': 'xml', 'label': 'XML'},
    <String, dynamic>{'id': 'html', 'label': 'HTML'},
    <String, dynamic>{'id': 'txt', 'label': 'TXT'},
    <String, dynamic>{'id': 'xls', 'label': 'Excel'},
    <String, dynamic>{'id': 'md', 'label': 'Markdown'},
  ];

  @override
  void initState() {
    super.initState();
    _formats = List<Json>.of(_fallbackFormats);
    _loadFormats();
  }

  @override
  void didUpdateWidget(covariant _RowsResultView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // New run / new result rows: start at the first page again.
    if (!identical(oldWidget.rows, widget.rows)) {
      _page = 1;
    }
  }

  Future<void> _loadFormats() async {
    try {
      final formats = await Api.instance.exportFormats();
      final usable = formats
          .where((format) =>
              (format['id'] ?? '').toString().isNotEmpty &&
              (format['id'] ?? '').toString() != 'sql')
          .toList();
      if (!mounted || usable.isEmpty) return;
      setState(() => _formats = usable);
    } catch (_) {
      // Keep the built-in list; the table itself is still usable.
    }
  }

  bool get _canExport =>
      widget.database != null &&
      widget.database!.trim().isNotEmpty &&
      widget.statement.trim().isNotEmpty &&
      !_isSessionDirective(widget.statement);

  /// USE results are rendered as row sets by the Rust session helper but must
  /// not be re-run as an export query.
  static bool _isSessionDirective(String statement) {
    var text = statement.trimLeft().toLowerCase();
    while (text.startsWith('--')) {
      final newline = text.indexOf('\n');
      if (newline < 0) return true;
      text = text.substring(newline + 1).trimLeft();
    }
    if (text.startsWith('/*')) {
      final end = text.indexOf('*/');
      if (end < 0) return true;
      text = text.substring(end + 2).trimLeft();
    }
    return text == 'use' || text.startsWith('use ') || text.startsWith('use\t');
  }

  String _extensionFor(String format) {
    switch (format) {
      case 'xls':
        return 'xls';
      case 'md':
        return 'md';
      default:
        return format;
    }
  }

  Future<void> _export(String format) async {
    final database = widget.database;
    if (!_canExport || _exporting || database == null) return;
    String? path;
    try {
      path = await pickSavePath(
        title: pickText('导出查询结果', 'Export query result'),
        fileName: 'query_result.${_extensionFor(format)}',
      );
      if (path == null || path.isEmpty) return;
      setState(() => _exporting = true);
      try {
        final response = await Api.instance.exportQuery(
          database,
          widget.statement,
          <String, dynamic>{'format': format, 'path': path},
        );
        final rows = (response['rows'] as num?)?.toInt() ?? 0;
        widget.notice.show(pickText(
          '已导出 $rows 行到 $path',
          'Exported $rows rows to $path',
        ));
      } catch (e) {
        // The native save dialog creates/truncates the file; do not leave an
        // empty file behind when the streamed export failed.
        try {
          final file = File(path);
          if (file.existsSync() && file.lengthSync() == 0) file.deleteSync();
        } catch (_) {
          // Best effort only; the error below is what matters.
        }
        widget.notice
            .show(pickText('导出失败：', 'Export failed: ') + e.toString());
      } finally {
        if (mounted) setState(() => _exporting = false);
      }
    } catch (e) {
      widget.notice
          .show(pickText('导出失败：', 'Export failed: ') + e.toString());
    }
  }

  /// One compact export entry: the format menu and the save action are merged
  /// into a single toolbar button, replacing the grid's two clipboard exports
  /// and the previous separate dropdown + button pair.
  Widget _exportMenu() {
    final enabled = _canExport && !_exporting;
    return PopupMenuButton<String>(
      key: ValueKey('result-export-${widget.resultIndex}'),
      enabled: enabled,
      color: AppColors.panel,
      elevation: 6,
      position: PopupMenuPosition.under,
      tooltip: pickText(
        '导出当前查询结果（与「表」页浏览导出分开，可选择文件格式）',
        'Export the current query result (separate from the table page export; '
            'choose a file format)',
      ),
      onSelected: _export,
      itemBuilder: (context) => <PopupMenuEntry<String>>[
        for (final format in _formats)
          PopupMenuItem<String>(
            value: (format['id'] ?? '').toString(),
            child: Text((format['label'] ?? format['id'] ?? '').toString()),
          ),
      ],
      child: IgnorePointer(
        child: Btn(
          _exporting
              ? pickText('导出中…', 'Exporting…')
              : pickText('导出结果', 'Export result'),
          small: true,
          icon: Icons.file_download,
          busy: _exporting,
          onPressed: enabled ? () {} : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    final pages = pageCountFor(rows.length, _pageSize);
    final page = clampPage(_page, rows.length, _pageSize);
    final base = (page - 1) * _pageSize;
    final pageRows = pageSlice(rows, page, _pageSize);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!widget.editable)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              pickText(
                '该结果为多表 / 表达式查询，无法定位到具体数据行，因此不提供改 / 删；'
                    '可导出为不同文件格式。',
                'This result spans multiple tables / expressions, so rows cannot be '
                    'edited or deleted; it can still be exported in several formats.',
              ),
              style: kSmallMuted,
            ),
          ),
        const SizedBox(height: 6),
        DataGrid(
          columns: widget.columns,
          rows: pageRows,
          primaryKey: const <String>[],
          selectable: widget.editable,
          showActions: false,
          rowOps: widget.editable,
          editable: widget.editable,
          maxHeight: 380,
          exportActions: _exportMenu(),
          onDeleteSelected: widget.onDeleteSelected == null
              ? null
              : (indices) => widget.onDeleteSelected!(
                  [for (final index in indices) base + index]),
          onSaveCell: widget.onSaveCell == null
              ? null
              : (rowIndex, column, value, isNull) => widget.onSaveCell!(
                  base + rowIndex, column, value, isNull),
        ),
        if (rows.isNotEmpty)
          TablePager(
            page: page,
            pages: pages,
            total: rows.length,
            visible: pageRows.length,
            onPage: (next) => setState(() => _page = next),
            keyPrefix: 'result-pager-${widget.resultIndex}',
          ),
      ],
    );
  }
}

/// Collapsed result list for large scripts (P8, bounded in round 34 / P2-05).
///
/// Only a bounded batch of folded cards is built at a time (see
/// [ResultTable.collapsedCardBatch]) plus a "show more" control; each folded
/// card shows its statement, error and row count and builds its real body only
/// when expanded. A 533-statement script therefore starts with one batch of
/// cheap cards instead of a grid (or a full [CodeBlock]) per statement.
class _CollapsedResultTable extends StatefulWidget {
  const _CollapsedResultTable({required this.results, required this.cardBody});

  final List<Json> results;

  /// Builds the full card body for a result; supplied by [ResultTable] so both
  /// layouts share exactly one implementation of the card.
  final Widget Function(BuildContext context, int index) cardBody;

  @override
  State<_CollapsedResultTable> createState() => _CollapsedResultTableState();
}

class _CollapsedResultTableState extends State<_CollapsedResultTable> {
  /// Result indices whose card is currently expanded.
  late Set<int> _expanded;

  /// How many cards of the current view are built (P2-05).
  ///
  /// Grows one [ResultTable.collapsedCardBatch] at a time through "show more".
  /// It never starts at the full result count, so a 533-statement script does
  /// not build 533 cards (or 533 accessibility subtrees) before the user asks
  /// for the next batch.
  late int _visible;

  /// When true the view lists only results with a non-null `error` (P2-05,
  /// §9.3 "仅失败"): after a whole-script run that is what the user needs.
  bool _onlyFailures = false;

  @override
  void initState() {
    super.initState();
    _resetView();
  }

  @override
  void didUpdateWidget(covariant _CollapsedResultTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new run replaces the whole list; start from the default layout again.
    if (!identical(oldWidget.results, widget.results)) {
      _resetView();
    }
  }

  void _resetView() {
    _expanded = _defaultExpanded();
    _visible = ResultTable.collapsedCardBatch;
    _onlyFailures = false;
  }

  /// Failures and the first result open by default: those are what the user
  /// needs to inspect after a whole-script run, everything else stays folded.
  Set<int> _defaultExpanded() {
    final expanded = <int>{};
    if (widget.results.isNotEmpty) expanded.add(0);
    for (var i = 0; i < widget.results.length; i++) {
      if ((widget.results[i]['error'] as String?) != null) expanded.add(i);
    }
    return expanded;
  }

  int get _failureCount =>
      widget.results.where((result) => (result['error'] as String?) != null).length;

  /// Result indices the current view lists, in script order.
  ///
  /// Building this list of ints is cheap (a few KB for 500+ results); what must
  /// stay bounded is the number of *widgets* built from it.
  List<int> get _listIndices {
    if (!_onlyFailures) {
      return List<int>.generate(widget.results.length, (i) => i);
    }
    return <int>[
      for (var i = 0; i < widget.results.length; i++)
        if ((widget.results[i]['error'] as String?) != null) i,
    ];
  }

  void _toggle(int index) {
    setState(() {
      if (!_expanded.remove(index)) _expanded.add(index);
    });
  }

  void _setOnlyFailures(bool value) {
    setState(() {
      _onlyFailures = value;
      // Restart at one batch: a script where every statement failed must not
      // build all failure cards in one frame either.
      _visible = ResultTable.collapsedCardBatch;
    });
  }

  void _showMore() {
    setState(() => _visible += ResultTable.collapsedCardBatch);
  }

  /// Expand every card the current view has built.
  ///
  /// Scoped to the built window on purpose: "expand all" on a 533-result script
  /// used to build 533 grids in a single frame, which is the peak this fix
  /// removes. Cards are revealed a batch at a time, so at most one batch of
  /// grids exists per user action.
  void _expandShown(List<int> shown) {
    setState(() => _expanded = <int>{..._expanded, ...shown});
  }

  void _collapseAll() {
    setState(_expanded.clear);
  }

  @override
  Widget build(BuildContext context) {
    final indices = _listIndices;
    final built = _visible < indices.length ? _visible : indices.length;
    final shown = indices.sublist(0, built);
    final remaining = indices.length - built;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _summaryBar(shown),
        for (final index in shown) _collapsedCard(context, index),
        if (shown.isEmpty)
          CardBox(
            child: Text(
              pickText('没有失败的结果', 'No failed results'),
              key: const ValueKey('results-empty-filter'),
              style: kMuted,
            ),
          ),
        if (remaining > 0) _showMoreBar(remaining),
      ],
    );
  }

  /// The end of the current batch: one more batch of folded cards on demand.
  Widget _showMoreBar(int remaining) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Btn(
        pickText(
          '显示更多（还有 $remaining 条）',
          'Show more ($remaining remaining)',
        ),
        key: const ValueKey('results-show-more'),
        small: true,
        icon: Icons.expand_more,
        onPressed: _showMore,
      ),
    );
  }

  Widget _summaryBar(List<int> shown) {
    final count = widget.results.length;
    final failures = _failureCount;
    final text = pickText(
      '共 $count 条结果 · 失败 $failures 条',
      '$count result(s) · $failures failed',
    );
    return CardBox(
      key: const ValueKey('results-summary-bar'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.unfold_more, size: 16, color: AppColors.muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              key: const ValueKey('results-summary-text'),
              style: failures > 0
                  ? kSmall.copyWith(color: AppColors.errText)
                  : kSmall,
            ),
          ),
          // P2-05 / §9.3: after a whole-script run the user wants the failures,
          // not 500+ folded cards. The toggle narrows the list to results whose
          // `error` is non-null; the list stays batched either way.
          Btn(
            pickText('仅看失败', 'Failures only'),
            key: const ValueKey('results-only-failures'),
            small: true,
            primary: _onlyFailures,
            icon: _onlyFailures ? Icons.check_box : Icons.check_box_outline_blank,
            tooltip: pickText(
              '只列出执行失败的结果（仍按批加载）',
              'List only the results that failed (still loaded in batches)',
            ),
            onPressed: () => _setOnlyFailures(!_onlyFailures),
          ),
          const SizedBox(width: 6),
          // "Expand all" used to expand every result of a 533-statement script
          // and build 533 grids in one frame; it now expands only the cards the
          // view has built, and the rest arrive a batch at a time.
          Btn(
            pickText('展开已显示', 'Expand shown'),
            key: const ValueKey('results-expand-all'),
            small: true,
            tooltip: pickText(
              '展开当前已列出的结果（每次只展开一批）',
              'Expand the results currently listed (one batch at a time)',
            ),
            onPressed: () => _expandShown(shown),
          ),
          const SizedBox(width: 6),
          Btn(
            pickText('全部折叠', 'Collapse all'),
            key: const ValueKey('results-collapse-all'),
            small: true,
            onPressed: _collapseAll,
          ),
        ],
      ),
    );
  }

  Widget _collapsedCard(BuildContext context, int index) {
    final result = widget.results[index];
    final error = result['error'] as String?;
    final expanded = _expanded.contains(index);
    final header = _header(index, expanded: expanded);

    if (expanded) {
      return CardBox(
        key: ValueKey('result-card-$index'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            header,
            const SizedBox(height: 8),
            widget.cardBody(context, index),
          ],
        ),
      );
    }

    final statement = (result['statement'] ?? '').toString();
    return CardBox(
      key: ValueKey('result-card-$index'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          const SizedBox(height: 6),
          // The statement stays readable even when folded; only the card body
          // (statement [CodeBlock] + grid, the expensive part) is deferred
          // until the card is expanded. [_FoldedStatementPreview] is the
          // cheapest possible renderer: no SelectableText and no scroll
          // containers, so a whole batch of folded cards costs a fraction of
          // the previous tree. Expanding gives the full selectable card body.
          _FoldedStatementPreview(statement),
          if (error != null) ...[
            const SizedBox(height: 8),
            AlertBox(error),
          ],
        ],
      ),
    );
  }

  Widget _header(int index, {required bool expanded}) {
    final result = widget.results[index];
    final error = (result['error'] as String?) != null;
    final kind = (result['kind'] ?? '').toString();
    final rowCount = (result['row_count'] as num?)?.toInt() ?? 0;
    final truncated = result['truncated'] == true;
    final lastInsertId = (result['last_insert_id'] as num?)?.toInt();
    // One text node per card on purpose: a 575-result script must not grow the
    // accessibility tree by several nodes per statement.
    final summary = _summaryText(kind, rowCount, truncated, lastInsertId);
    final label = error
        ? pickText('第 ${index + 1} 条 · 执行失败', 'Result ${index + 1} · failed')
        : expanded
            ? pickText('第 ${index + 1} 条结果', 'Result ${index + 1}')
            : pickText('第 ${index + 1} 条结果 · $summary',
                'Result ${index + 1} · $summary');
    return InkWell(
      key: ValueKey('result-card-toggle-$index'),
      onTap: () => _toggle(index),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
              color: AppColors.muted,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                label,
                style: error ? kSmall.copyWith(color: AppColors.errText) : kSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One-line result size shown next to a folded card's title.
  String _summaryText(String kind, int rowCount, bool truncated, int? lastInsertId) {
    if (kind == 'rows') {
      return truncated
          ? pickText('$rowCount 行（已截断）', '$rowCount row(s) (truncated)')
          : pickText('$rowCount 行', '$rowCount row(s)');
    }
    if (kind == 'error') return pickText('失败', 'failed');
    final last = lastInsertId != null && lastInsertId > 0
        ? pickText('，最后插入 ID $lastInsertId', ', last insert ID $lastInsertId')
        : '';
    return pickText('$rowCount 行受影响$last', '$rowCount row(s) affected$last');
  }
}

/// The folded statement preview of one result card (P2-05).
///
/// Deliberately cheaper than [CodeBlock], which every folded card used to
/// build: no [SelectableText] (an EditableText plus its selection machinery,
/// dozens of widgets and an accessibility node per result), no nested scroll
/// views and no syntax pipeline. One clipped, non-selectable text node is
/// enough while the card is folded; expanding swaps in the full card body,
/// which still renders the statement through [CodeBlock].
///
/// SQL is user data, so the label opts out of the literal translator — a
/// statement must never be rewritten because it happens to equal a UI string.
class _FoldedStatementPreview extends StatelessWidget {
  const _FoldedStatementPreview(this.statement);

  final String statement;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.code,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        statement.isEmpty ? ' ' : statement,
        noTranslate: true,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: monoStyle(size: 12, color: AppColors.bodyText),
      ),
    );
  }
}

/// Infer the single table a SELECT statement reads from.
///
/// Ports sqlparse.ts: only a plain single-table SELECT is editable, because a
/// join or expression has no unambiguous row identity. Returns null when the
/// statement cannot be tied to exactly one table.
String? inferSingleTable(String statement, List<Json> columns) {
  if (columns.isEmpty) return null;
  final text = statement.trim();
  final upper = text.toUpperCase();
  if (!upper.startsWith('SELECT')) return null;
  // Reject the constructs that make a row ambiguous.
  for (final marker in [' JOIN ', ' UNION ', ' INTERSECT ', ' EXCEPT ']) {
    if (upper.contains(marker)) return null;
  }
  // A qualified identifier is one or more parts, each either quoted with
  // backticks / double quotes / brackets or bare, joined by dots. Matching the
  // parts individually is what lets `db`.`users` be read as db.users rather
  // than stopping at the first backtick.
  const part = r'(`[^`]*`|"[^"]*"|\[[^\]]*\]|[A-Za-z0-9_$]+)';
  final pattern = RegExp('\\bFROM\\s+($part(?:\\s*\\.\\s*$part)*)',
      caseSensitive: false);
  final match = pattern.firstMatch(text);
  if (match == null) return null;
  final qualified = match.group(1)!;
  // Drop the quoting characters and keep the last dotted part, which is the
  // table name itself (any earlier parts are the schema / database).
  final cleaned = qualified.replaceAll(RegExp(r'[`"\[\]]'), '');
  final table = cleaned.split('.').last.trim();
  if (table.isEmpty) return null;
  return table;
}
