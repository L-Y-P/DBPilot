import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text, Tooltip;
import '../text.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../app_state.dart';
import '../row_changes.dart';
import '../theme.dart';
import '../widgets.dart';

/// Character count above which a cell value is rendered as a preview.
///
/// See [AppState.lazyBigFields]: a TEXT/JSON cell can hold kilobytes, and only
/// the first few hundred pixels of it are ever visible.
const int kLazyBigFieldThreshold = 200;

/// Characters shown by the preview; the rest is summarised by a badge.
const int kLazyBigFieldPreview = 120;

/// Default cap for staged batch edits (cells across the whole table, 第 60 轮).
///
/// Each staged cell keeps its value and row keys in memory; without a cap a user
/// could stage edits across hundreds of pages and the batch payload / memory
/// would grow unbounded. Hosts pass this through [DataGrid.maxDirtyCells].
const int kMaxStagedCells = 2000;

/// One column filter in the DataGrid filter row, mirroring the web operators.
class GridFilter {
  GridFilter({this.op = 'LIKE', this.value = ''});
  String op;
  String value;

  static const operators = [
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

  bool get active => value.trim().isNotEmpty || op == 'IS NULL' || op == 'IS NOT NULL';
}

/// Sort descriptor used by the browse grid.
class SortSpec {
  const SortSpec(this.column, this.dir);
  final String column;
  final String dir;

  SortSpec toggled() => SortSpec(column, dir == 'asc' ? 'desc' : 'asc');
}

/// Sortable, filterable, selectable data grid with cell editing.
///
/// Ports DataGrid.vue. Behaviour preserved: click a header to sort (shift for
/// multi-sort), a per-column filter row, click a cell to copy it, double-click
/// to open the full-value editor, row checkboxes with select-all, CSV/JSON
/// export, and an optional actions column.
class DataGrid extends StatefulWidget {
  const DataGrid({
    super.key,
    required this.columns,
    required this.rows,
    this.sorts = const <SortSpec>[],
    this.primaryKey = const <String>[],
    this.selectable = true,
    this.showActions = true,
    this.rowOps = false,
    this.editable = false,
    this.maxHeight = 460,
    this.onSort,
    this.onEdit,
    this.onDelete,
    this.onFilters,
    this.onDeleteSelected,
    this.onSaveCell,
    this.onApplyEdits,
    this.onDirtyChanges,
    this.initialDirtyByKey,
    this.totalDirtyCount,
    this.maxDirtyCells,
    this.exportActions,
  });

  final List<Json> columns;
  final List<List<dynamic>> rows;
  final List<SortSpec> sorts;
  final List<String> primaryKey;
  final bool selectable;
  final bool showActions;
  final bool rowOps;
  final bool editable;
  final double maxHeight;
  final void Function(String column, bool additive)? onSort;
  final void Function(int index)? onEdit;
  final void Function(int index)? onDelete;
  final void Function(List<GridFilter> filters)? onFilters;
  final void Function(List<int> indices)? onDeleteSelected;
  final void Function(int rowIndex, String column, Object? value, bool isNull)?
      onSaveCell;

  /// Batch-edit sink: called with every staged cell edit when the user presses
  /// "保存全部改动". Non-null switches the grid from "save each cell at once"
  /// to "stage cells, apply them in one transaction"; returning true clears the
  /// staged edits (the caller reloads the rows), false keeps them so the user
  /// can retry.
  final Future<bool> Function(List<DirtyCell> edits)? onApplyEdits;

  /// Reports the current staged-edit list whenever it changes (第 57 轮).
  ///
  /// The host uses it to warn before a page/tab switch would discard the batch
  /// edits. Emitted after staging a cell, after a successful apply (empty),
  /// after "撤销改动" (empty), and after a rows replacement cleared stale edits
  /// (empty, one frame later because it happens during didUpdateWidget).
  final void Function(List<DirtyCell> edits)? onDirtyChanges;

  /// Host-owned staged edits for the **whole table**, keyed by
  /// [rowChangeKeyFor]（第 59 轮：跨页保持）.
  ///
  /// When non-null the grid is in "controlled" mode: after a page/sort/filter
  /// change it rebuilds its page-level dirty state from this map (matching rows
  /// by their row key) instead of clearing the staged edits. The host keeps the
  /// map authoritative and refreshes it from [onDirtyChanges].
  final Map<String, List<DirtyCell>>? initialDirtyByKey;

  /// Total number of staged edits across every page (host-managed).
  ///
  /// When it is larger than this page's edits the toolbar still offers
  /// 「保存全部改动」, labelled with this count, so a batch staged on another
  /// page can be saved from here.
  final int? totalDirtyCount;

  /// Cap on the number of staged cells (host passes [kMaxStagedCells]).
  ///
  /// Staging another cell when the current page + [totalDirtyCount] would exceed
  /// this cap is refused with a flash message instead of growing the batch
  /// without bound. Editing a cell that is already staged is always allowed.
  final int? maxDirtyCells;

  /// Optional replacement for the built-in "导出 CSV / 导出 JSON" buttons.
  ///
  /// The result tables pass a single format menu here so their export controls
  /// live in the same toolbar as the rest of the grid actions instead of adding
  /// a second, differently styled export row.
  final Widget? exportActions;

  @override
  State<DataGrid> createState() => _DataGridState();
}

class _DataGridState extends State<DataGrid> {
  late List<GridFilter> _filters;
  final Set<int> _selected = <int>{};

  /// Staged cell edits (rowIndex -> column -> edit) while [DataGrid.onApplyEdits]
  /// is set. These are applied together, in one transaction, by "保存全部改动".
  final Map<int, Map<String, DirtyCell>> _dirtyCells =
      <int, Map<String, DirtyCell>>{};

  final Set<String> _hidden = <String>{};
  bool _showFilters = false;
  bool _showChooser = false;
  String? _flash;

  /// Explicit controllers for the two axes.
  ///
  /// A [Scrollbar] with no controller attaches to the PrimaryScrollController,
  /// which is the page-level scroller — not these inner ones. The thumb was
  /// therefore drawn but not draggable: it looked like a scrollbar and ignored
  /// the mouse. Giving each axis its own controller (and telling the Scrollbar
  /// about it) is what makes drag-to-scroll work.
  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();

  /// Horizontal scroll offset, used to pick the visible column range.
  double _hOffset = 0;

  /// Measured column widths, kept until the result or the sort changes.
  ///
  /// Widths come from sampling up to [_measureSampleRows] values per column
  /// with a [TextPainter]; recomputing them on every rebuild cost ~440ms on a
  /// 40-column result (the whole grid rebuilt anyway), so they are cached and
  /// only re-measured when the columns, rows or sort order change.
  Map<String, double>? _widthCache;
  String? _widthCacheKey;

  /// Last seen values of the two performance switches (see [AppState]).
  ///
  /// [AppState] notifies for plenty of unrelated reasons (a query finished, the
  /// tree refreshed), so the grid only rebuilds when a switch it renders from
  /// actually changed instead of on every notification.
  bool _autoColumnWidth = true;
  bool _lazyBigFields = true;

  @override
  void initState() {
    super.initState();
    _filters = List.generate(widget.columns.length, (_) => GridFilter());
    _restoreDirtyFromInitial();
    _horizontal.addListener(_onHorizontalScroll);
    _syncPerfSettings();
    AppState.instance.addListener(_onAppStateChanged);
  }

  void _syncPerfSettings() {
    _autoColumnWidth = AppState.instance.autoColumnWidth;
    _lazyBigFields = AppState.instance.lazyBigFields;
  }

  void _onAppStateChanged() {
    if (!mounted) return;
    final auto = AppState.instance.autoColumnWidth;
    final lazy = AppState.instance.lazyBigFields;
    if (auto == _autoColumnWidth && lazy == _lazyBigFields) return;
    setState(() {
      _autoColumnWidth = auto;
      _lazyBigFields = lazy;
    });
  }

  void _onHorizontalScroll() {
    if (!_horizontal.hasClients) return;
    final next = _horizontal.offset;
    if ((next - _hOffset).abs() >= 1) {
      setState(() => _hOffset = next);
    }
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_onAppStateChanged);
    _horizontal.removeListener(_onHorizontalScroll);
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  List<String> get _columnNames =>
      widget.columns.map((c) => c['name'].toString()).toList();

  List<String> get _visibleColumns =>
      _columnNames.where((n) => !_hidden.contains(n)).toList();

  @override
  void didUpdateWidget(covariant DataGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.columns.length != widget.columns.length) {
      _filters = List.generate(widget.columns.length, (_) => GridFilter());
    }
    final rowsReplaced = _rowsReplaced(oldWidget.rows, widget.rows);
    if (rowsReplaced) _selected.clear();
    if (widget.initialDirtyByKey != null) {
      // Controlled mode (第 59 轮): the host owns the cross-page batch, so a page
      // flip restores this page's edits by row key instead of dropping them.
      _restoreDirtyFromInitial();
    } else if (rowsReplaced) {
      // Legacy mode: staged edits index into the old list, so keeping them
      // would write to the wrong row.
      final hadDirtyEdits = _dirtyCells.isNotEmpty;
      _dirtyCells.clear();
      // didUpdateWidget runs during build: the host's callback normally calls
      // setState, which must wait for the next frame.
      if (hadDirtyEdits) _notifyDirtyChanges(postFrame: true);
    }
  }

  /// Rebuild this page's dirty state from [DataGrid.initialDirtyByKey].
  ///
  /// Rows are matched by their captured row key, so edits staged on another
  /// page are harmless (they simply do not match here) and the same row after a
  /// sort/filter still shows its staged cells. The [DirtyCell.rowIndex] is
  /// rewritten to the current row position.
  void _restoreDirtyFromInitial() {
    final initial = widget.initialDirtyByKey;
    if (initial == null) return;
    _dirtyCells.clear();
    if (initial.isEmpty) return;
    final columnNames = _columnNames.toSet();
    for (var index = 0; index < widget.rows.length; index++) {
      final key = rowChangeKey(
        columns: widget.columns,
        row: widget.rows[index],
        primaryKey: widget.primaryKey,
      );
      final edits = initial[key];
      if (edits == null || edits.isEmpty) continue;
      final row = <String, DirtyCell>{};
      for (final edit in edits) {
        if (!columnNames.contains(edit.column)) continue;
        row[edit.column] = DirtyCell(
          rowIndex: index,
          column: edit.column,
          value: edit.value,
          isNull: edit.isNull,
          keys: edit.keys,
        );
      }
      if (row.isNotEmpty) _dirtyCells[index] = row;
    }
  }

  /// Whether [after] really replaced the rendered rows (reload / page flip).
  ///
  /// The host passes a freshly built outer list on every rebuild (its rows
  /// getter maps the data payload each time), while the row objects themselves
  /// are unchanged. Comparing row identities keeps staged edits across an
  /// unrelated parent rebuild but still clears them on a real data reload.
  static bool _rowsReplaced(
    List<List<dynamic>> before,
    List<List<dynamic>> after,
  ) {
    if (identical(before, after)) return false;
    if (before.length != after.length) return true;
    for (var i = 0; i < before.length; i++) {
      if (!identical(before[i], after[i])) return true;
    }
    return false;
  }

  List<DirtyCell> get _dirtyEdits => <DirtyCell>[
        for (final row in _dirtyCells.values) ...row.values,
      ];

  /// Staged cells across the whole table (host count wins when provided).
  int get _totalDirtyCount => widget.totalDirtyCount ?? _dirtyEdits.length;

  /// Toolbar label for the save button. Shows `N/limit` when a cap is set.
  String get _applyDirtyLabel {
    final limit = widget.maxDirtyCells;
    return limit == null
        ? '保存全部改动 ($_totalDirtyCount)'
        : '保存全部改动 ($_totalDirtyCount/$limit)';
  }

  /// Report the current staged edits to [DataGrid.onDirtyChanges].
  ///
  /// Use [postFrame] from didUpdateWidget: the host's callback usually calls
  /// setState, which throws during this widget's build.
  void _notifyDirtyChanges({bool postFrame = false}) {
    final callback = widget.onDirtyChanges;
    if (callback == null) return;
    final edits = _dirtyEdits;
    if (!postFrame) {
      callback(edits);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) callback(edits);
    });
  }

  bool get _rowOps => widget.rowOps || widget.primaryKey.isNotEmpty;
  bool get _selectable => widget.selectable && _rowOps;
  bool get _editable => widget.editable && _rowOps;

  void _flashMessage(String message) {
    setState(() => _flash = message);
    Future<void>.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _flash = null);
    });
  }

  /// Send every staged cell edit to the caller's batch endpoint.
  ///
  /// The caller owns the transaction (Rust applies all changes atomically and
  /// reloads the rows on success), so this only manages the local staged state.
  Future<void> _applyDirtyEdits() async {
    final apply = widget.onApplyEdits;
    if (apply == null) return;
    final edits = _dirtyEdits;
    // Controlled mode: the host may hold edits from other pages while this page
    // has none; still hand over the (possibly empty) page edits so it can save
    // the whole cross-page batch.
    if (edits.isEmpty && (widget.totalDirtyCount ?? 0) == 0) return;
    final keepGoing = await apply(edits);
    if (!mounted) return;
    if (keepGoing) {
      setState(_dirtyCells.clear);
      _notifyDirtyChanges();
      _flashMessage('已保存 ${edits.length} 个改动');
    }
  }

  /// Emit the active filters in the order the backend expects.
  void _emitFilters() {
    widget.onFilters?.call(_filters);
  }

  @override
  Widget build(BuildContext context) {
    // The grid fills the height it is given (rather than always asking for its
    // full maxHeight), so placing it inside a fixed-height parent does not
    // overflow by the height of the toolbar and the hint line. When the parent
    // is unbounded (a plain scrolling page) it falls back to maxHeight.
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounded = constraints.maxHeight.isFinite;
        final tableHeight = bounded
            ? null
            : widget.maxHeight;
        final body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: bounded ? MainAxisSize.max : MainAxisSize.min,
          children: [
            _toolbar(),
            if (_showChooser) _chooser(),
            if (bounded)
              Expanded(child: _table(height: null))
            else
              _table(height: tableHeight),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('单击复制，双击查看完整内容', style: kSmallMuted),
            ),
          ],
        );
        return body;
      },
    );
  }

  Widget _toolbar() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Btn('列 (${_visibleColumns.length}/${widget.columns.length})',
              small: true,
              onPressed: () => setState(() => _showChooser = !_showChooser)),
          IconBtn(Icons.filter_list,
              key: const ValueKey('grid-filter-toggle'),
              tooltip: _showFilters ? '隐藏筛选' : '筛选',
              small: true,
              onPressed: () => setState(() => _showFilters = !_showFilters)),
          if (_selectable) ...[
            Btn('复制选中',
                small: true,
                onPressed: _selected.isEmpty ? null : _copySelected),
            Btn('删除选中',
                small: true,
                danger: true,
                onPressed: _selected.isEmpty || !_rowOps
                    ? null
                    : () => widget.onDeleteSelected?.call(_selected.toList())),
            Text('已选 ${_selected.length}', style: kSmallMuted),
          ],
          if (widget.onApplyEdits != null &&
              (_dirtyCells.isNotEmpty || (widget.totalDirtyCount ?? 0) > 0)) ...[
            Btn(
                _applyDirtyLabel,
                key: const ValueKey('grid-apply-dirty'),
                small: true,
                primary: true,
                onPressed: _applyDirtyEdits),
            // 撤销只清当前页（跨页 map 由宿主按本页上报的 edits 删除本页键）。
            if (_dirtyCells.isNotEmpty)
              Btn('撤销改动',
                  key: const ValueKey('grid-discard-dirty'),
                  small: true,
                  onPressed: () {
                    setState(_dirtyCells.clear);
                    _notifyDirtyChanges();
                  }),
          ],
          const SizedBox(width: 12),
          Text('本页 ${widget.rows.length} 行', style: kSmallMuted),
          if (widget.exportActions != null)
            widget.exportActions!
          else ...[
            Btn('导出 CSV', small: true, onPressed: _exportCsv),
            Btn('导出 JSON', small: true, onPressed: _exportJson),
          ],
          if (_flash != null) Pill(_flash!),
        ],
      ),
    );
  }

  Widget _chooser() {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(8),
      constraints: const BoxConstraints(maxHeight: 160),
      decoration: BoxDecoration(
        color: AppColors.chipBg,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        child: Wrap(
          spacing: 10,
          runSpacing: 2,
          children: [
            for (final name in _columnNames)
              CheckBox(
                label: name,
                value: !_hidden.contains(name),
                onChanged: (v) => setState(() {
                  if (v) {
                    _hidden.remove(name);
                  } else {
                    _hidden.add(name);
                  }
                }),
              ),
          ],
        ),
      ),
    );
  }

  /// Width of one data column, measured from its widest cell.
  ///
  /// The grid used to lay each row out as its own `Row` whose cells sized
  /// themselves to their content. Independent Rows know nothing about each
  /// other, so every row ended up with different column boundaries and the
  /// header no longer lined up with the data below it. Measuring once and
  /// pinning every cell to that width keeps the columns in a single grid, the
  /// way the web table does.
  /// Cached widths for [visible], measured on demand.
  ///
  /// The key covers everything the measurement depends on: the column list, the
  /// result rows and the sort order (which adds a sort-indicator allowance).
  Map<String, double> _widths(List<String> visible) {
    // Fixed-width mode: no TextPainter sampling at all. Every column is
    // [kFixedGridColumnWidth] wide, and the header, the filter row and the data
    // rows all read this same map, so they stay aligned by construction.
    if (!_autoColumnWidth) {
      return <String, double>{
        for (final name in visible) name: kFixedGridColumnWidth,
      };
    }
    final key = [
      identityHashCode(widget.columns).toString(),
      identityHashCode(widget.rows).toString(),
      widget.sorts.map((sort) => '${sort.column}:${sort.dir}').join(','),
    ].join('|');
    if (_widthCache == null || key != _widthCacheKey) {
      _widthCache = <String, double>{};
      _widthCacheKey = key;
    }
    final cache = _widthCache!;
    return <String, double>{
      for (final name in visible) name: cache.putIfAbsent(name, () => _widthFor(name)),
    };
  }

  double _widthFor(String name) {
    final index = _columnNames.indexOf(name);
    final type = widget.columns
        .firstWhere((c) => c['name'] == name,
            orElse: () => <String, dynamic>{})['type_name'];
    final label = type == null ? name : '$name($type)';
    var widest = _measure(label, const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)) +
        _sortIndicatorWidth(name);
    // S-08: measuring each cell of a 50,000-row result with TextPainter froze
    // the UI. Widths are clamped to [110, 320] anyway, so a sample of the first
    // rows is enough to lay the grid out; scanning every row (times every
    // column) was pure waste and scaled with the result size.
    final sample = widget.rows.length > _measureSampleRows
        ? widget.rows.take(_measureSampleRows)
        : widget.rows;
    for (final row in sample) {
      final value = index >= 0 && index < row.length ? row[index] : null;
      final text = value == null
          ? 'NULL'
          : (isBinaryCell(value) ? '${(value as Map)['len'] ?? 0} bytes' : displayCell(value));
      widest = math.max(widest, _measure(text, monoStyle(size: 12)));
    }
    // Horizontal padding (8 + 8) plus the left border.
    return (widest + 18).clamp(110.0, 320.0);
  }

  double _sortIndicatorWidth(String name) {
    if (!widget.sorts.any((s) => s.column == name)) return 0;
    return widget.sorts.length > 1 ? 22 : 12;
  }

  static double _measure(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.width;
  }

  Widget _table({double? height}) {
    final visible = _visibleColumns;
    final sortRank = <String, int>{};
    for (var i = 0; i < widget.sorts.length; i++) {
      sortRank[widget.sorts[i].column] = i + 1;
    }
    final widths = _widths(visible);
    final limit = height ?? widget.maxHeight;

    return LayoutBuilder(
      builder: (context, constraints) {
        // The enclosing Container draws a 1px border on each side, so the
        // usable width is 2px narrower. Sizing the table to the raw constraint
        // overflowed by exactly that much (the yellow/black stripes).
        final viewport = constraints.maxWidth.isFinite
            ? math.max(0.0, constraints.maxWidth - 2)
            : 0.0;
        final totalWidth = _tableWidth(visible, widths, viewport);
        final stretched = _stretchedWidths(visible, widths, totalWidth);
        // Column virtualisation: only the columns on screen are built.
        final (first, last) = _columnRange(visible, stretched, viewport);

        Widget table(List<String> vis, Map<String, double> w, {Widget? body}) {
          return SizedBox(
            width: totalWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _headerRow(vis, sortRank, w, first, last),
                if (_showFilters) _filterRow(vis, w, first, last),
                ?body,
              ],
            ),
          );
        }

        // A wide table can overflow the viewport even when it only has one or
        // two rows. The short-table branch used to render the raw table with no
        // horizontal scroller, so such a grid was clipped at the right window
        // edge and could not be dragged (reported on a 14-column, 1-row table).
        final horizontalNeeded =
            constraints.maxWidth.isFinite && totalWidth > viewport + 0.5;

        /// Wrap the table in a horizontal scroller + draggable scrollbar when
        /// its measured width exceeds the viewport.
        Widget horizontalScroll(Widget child) {
          if (!horizontalNeeded) return child;
          return Scrollbar(
            controller: _horizontal,
            thumbVisibility: true,
            notificationPredicate: (notification) => notification.depth == 0,
            child: SingleChildScrollView(
              controller: _horizontal,
              scrollDirection: Axis.horizontal,
              child: child,
            ),
          );
        }

        // How tall the rows would be if every one were laid out.
        final needed = _headerHeight +
            (_showFilters ? _filterHeight : 0) +
            (widget.rows.isEmpty ? _emptyHeight : widget.rows.length * _rowHeight);

        // Short tables lay out naturally: no viewport, no clipped last row.
        // This is also why a two-row table no longer reserves 460px. A wide
        // short table still gets horizontal scrolling (and a bottom gutter for
        // the scrollbar thumb).
        if (needed <= limit) {
          Widget shortTable = table(
            visible,
            stretched,
            body: widget.rows.isEmpty
                ? Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('无结果', style: kMuted),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < widget.rows.length; i++)
                        _dataRow(i, visible, stretched, first, last),
                    ],
                  ),
          );
          if (horizontalNeeded) {
            // Reserve the strip the scrollbar thumb paints over so it never
            // covers the last data row.
            shortTable = Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: shortTable,
            );
          }
          return Container(
            decoration: _boxDecoration,
            child: horizontalScroll(shortTable),
          );
        }

        // Long tables scroll: only the visible window is built.
        //
        // The body height comes from the *inner* box (after the border), so the
        // Column cannot overflow by the border width.
        Widget scrollable(double available) {
          final bodyHeight =
              available - _headerHeight - (_showFilters ? _filterHeight : 0);
          return horizontalScroll(
            table(
              visible,
              stretched,
              body: SizedBox(
                height: bodyHeight < _rowHeight ? _rowHeight : bodyHeight,
                child: _body(visible, stretched, first, last),
              ),
            ),
          );
        }

        return Container(
          decoration: _boxDecoration,
          constraints: BoxConstraints(maxHeight: limit),
          height: limit,
          child: LayoutBuilder(
            builder: (context, inner) {
              final available =
                  inner.maxHeight.isFinite ? inner.maxHeight : limit - 2;
              return Scrollbar(
                controller: _vertical,
                thumbVisibility: true,
                child: scrollable(available),
              );
            },
          ),
        );

      },
    );
  }

  // A getter, not a static cached value: the border colour depends on the
  // active palette, so a one-time field would keep painting the light-theme
  // border after the user switches to a dark scheme.
  BoxDecoration get _boxDecoration => BoxDecoration(
        border: Border.fromBorderSide(BorderSide(color: AppColors.border)),
        borderRadius: const BorderRadius.all(Radius.circular(6)),
      );

  Widget _body(
      List<String> visible, Map<String, double> widths, int first, int last) {
    if (widget.rows.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(12),
        child: Text('无结果', style: kMuted),
      );
    }
    return ListView.builder(
      controller: _vertical,
      itemCount: widget.rows.length,
      itemExtent: _rowHeight,
      itemBuilder: (context, index) =>
          _dataRow(index, visible, widths, first, last),
    );
  }

  /// How many rows are inspected when measuring column widths.
  ///
  /// Only the visible window of a long result is ever built (see [_body]), so
  /// there is no reason to measure the full table; a sample keeps the layout
  /// cost independent of the result size. Widths are clamped to [110, 320]
  /// anyway, so 50 rows are representative: measuring 200 of them cost ~650ms
  /// on a 40-column result in the debug VM before the first frame appeared.
  static const int _measureSampleRows = 50;

  /// Height of one body row, fixed so [ListView] can virtualise. It must match
  /// the header row, otherwise the two drift apart vertically.
  static const double _rowHeight = 30;

  /// Height of the per-column filter row.
  ///
  /// It stacks an operator dropdown (24px) and a value input (26px) inside the
  /// row's 4px padding, so it is taller than a data row. Reusing the data-row
  /// height here made every filter cell overflow by 28px.
  static const double _filterHeight = 58;

  /// Header and filter rows are pinned to the same height as body rows so the
  /// three never drift apart, and so the "does it fit?" sum below is exact.
  static const double _headerHeight = _rowHeight;

  /// Height reserved by the empty-state message.
  static const double _emptyHeight = 40;

  /// Total width used by the fixed leading columns.
  double get _fixedWidth =>
      (_selectable ? _checkWidth : 0) + (widget.showActions ? _actionsWidth : 0);

  static const double _checkWidth = 34;
  static const double _actionsWidth = 90;

  /// Width of the table.
  ///
  /// Columns are measured from their content, but the table then **stretches**
  /// to fill the viewport: a 3-column table on a wide window used to hug its
  /// content and leave a large empty gutter on the right, which reads as the
  /// table being "fixed width". When the measured width exceeds the viewport
  /// the extra is kept and the horizontal scrollbar appears.
  double _tableWidth(
      List<String> visible, Map<String, double> widths, double viewport) {
    var total = _fixedWidth;
    for (final name in visible) {
      total += widths[name] ?? 110;
    }
    return total < viewport ? viewport : total;
  }

  /// Per-column widths after stretching to [total] (when there is room).
  ///
  /// The surplus is shared out in proportion to each column's natural width,
  /// so a wide text column absorbs more of it than a numeric one.
  ///
  /// Fixed-width mode does not stretch: "fixed" means the same 160px column
  /// everywhere, not a column that happens to start at 160 on a narrow window.
  Map<String, double> _stretchedWidths(
      List<String> visible, Map<String, double> widths, double total) {
    final natural = <String, double>{
      for (final name in visible) name: widths[name] ?? 110,
    };
    if (!_autoColumnWidth) return natural;
    final content = natural.values.fold<double>(0, (a, b) => a + b);
    final surplus = total - _fixedWidth - content;
    if (surplus <= 0 || content <= 0) return natural;
    return <String, double>{
      for (final entry in natural.entries)
        entry.key: entry.value + surplus * (entry.value / content),
    };
  }

  /// First and last visible column index for the current horizontal offset.
  ///
  /// A wide result kept every column in every visible row: 40 columns x ~30
  /// rows measured 1200 cells and a ~300ms rebuild (debug). Only the columns
  /// that intersect the viewport are built; the rest becomes a single spacer of
  /// exactly their combined width, so alignment and the scroll range are
  /// unchanged.
  (int, int) _columnRange(
      List<String> visible, Map<String, double> widths, double viewport) {
    final total = _tableWidth(visible, widths, viewport);
    final maxOffset = (total - viewport).clamp(0.0, double.infinity);
    if (maxOffset <= 0) return (0, visible.length);
    final offset = _hOffset.clamp(0.0, maxOffset);
    var start = 0;
    var x = _fixedWidth;
    while (start < visible.length &&
        x + (widths[visible[start]] ?? 110) <= offset) {
      x += widths[visible[start]] ?? 110;
      start++;
    }
    var end = start;
    while (end < visible.length && x < offset + viewport) {
      x += widths[visible[end]] ?? 110;
      end++;
    }
    return (start, end);
  }

  /// Combined width of [visible] outside [from, to).
  double _sideWidth(
      List<String> visible, Map<String, double> widths, int from, int to) {
    var total = 0.0;
    for (var i = from; i < to; i++) {
      total += widths[visible[i]] ?? 110;
    }
    return total;
  }

  /// Column indices of [visible] in table order.
  List<int> _visibleIndices(List<String> visible) {
    final names = _columnNames;
    final result = <int>[];
    for (var i = 0; i < names.length; i++) {
      if (visible.contains(names[i])) result.add(i);
    }
    return result;
  }

  Widget _headerRow(List<String> visible, Map<String, int> sortRank,
      Map<String, double> widths, int first, int last) {
    return Container(
      height: _headerHeight,
      color: AppColors.panel,
      child: Row(
        children: [
          if (_selectable)
            SizedBox(
              width: _checkWidth,
              child: Checkbox(
                value: widget.rows.isNotEmpty &&
                    _selected.length == widget.rows.length,
                onChanged: (v) => setState(() {
                  _selected.clear();
                  if (v == true) {
                    for (var i = 0; i < widget.rows.length; i++) {
                      _selected.add(i);
                    }
                  }
                }),
                visualDensity: VisualDensity.compact,
                activeColor: AppColors.header,
              ),
            ),
          if (widget.showActions)
            SizedBox(
              width: _actionsWidth,
              // 7px matches the small buttons' own text inset, so the title and
              // the buttons below it share a left edge.
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 7, vertical: 6),
                child: Text('操作',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.cardHeading)),
              ),
            ),
          if (first > 0) SizedBox(width: _sideWidth(visible, widths, 0, first)),
          for (var i = first; i < last; i++)
            _headerCell(visible[i], sortRank[visible[i]], widths[visible[i]] ?? 110),
          if (last < visible.length)
            SizedBox(width: _sideWidth(visible, widths, last, visible.length)),
        ],
      ),
    );
  }

  Widget _headerCell(String name, int? rank, double width) {
    final type = widget.columns
        .firstWhere((c) => c['name'] == name,
            orElse: () => <String, dynamic>{})['type_name'];
    final sort = widget.sorts.where((s) => s.column == name).toList();
    return InkWell(
      onTap: () => widget.onSort?.call(name, HardwareKeyboard.instance.isShiftPressed),
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: EllipsisText(
                type == null ? name : '$name($type)',
                tooltip: type == null ? name : '$name · $type',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.cardHeading,
                ),
              ),
            ),
            if (sort.isNotEmpty) ...[
              const SizedBox(width: 3),
              Text(sort.first.dir == 'asc' ? '^' : 'v',
                  style: TextStyle(
                      fontSize: 10, color: AppColors.accent)),
              if ((rank ?? 0) > 1 || widget.sorts.length > 1)
                Text('$rank',
                    style: TextStyle(
                        fontSize: 9, color: AppColors.accent)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _filterRow(
      List<String> visible, Map<String, double> widths, int first, int last) {
    return Container(
      height: _filterHeight,
      color: AppColors.filterRow,
      child: Row(
        children: [
          if (_selectable) const SizedBox(width: _checkWidth),
          if (widget.showActions) const SizedBox(width: _actionsWidth),
          if (first > 0) SizedBox(width: _sideWidth(visible, widths, 0, first)),
          for (var i = first; i < last; i++)
            Container(
              width: widths[visible[i]] ?? 110,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: AppColors.border)),
              ),
              child: _filterCell(visible[i]),
            ),
          if (last < visible.length)
            SizedBox(width: _sideWidth(visible, widths, last, visible.length)),
        ],
      ),
    );
  }

  Widget _filterCell(String name) {
    final index = _columnNames.indexOf(name);
    final filter = _filters[index];
    final noValue = filter.op == 'IS NULL' || filter.op == 'IS NOT NULL';
    return Column(
      children: [
        SizedBox(
          height: 24,
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: filter.op,
              isDense: true,
              isExpanded: true,
              style: TextStyle(fontSize: 11, color: AppColors.bodyText),
              // The operators are short, but the menu still belongs to the
              // common dropdown contract: bounded height, one-line entries.
              menuMaxHeight: 360,
              items: [
                for (final op in GridFilter.operators)
                  DropdownMenuItem(
                    value: op,
                    child: Text(op,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) {
                setState(() => filter.op = v ?? 'LIKE');
                _emitFilters();
              },
            ),
          ),
        ),
        SizedBox(
          height: 26,
          child: TextField(
            enabled: !noValue,
            style: monoStyle(size: 11),
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) {
              filter.value = v;
              _emitFilters();
            },
          ),
        ),
      ],
    );
  }

  Widget _dataRow(
      int index, List<String> visible, Map<String, double> widths, int first, int last) {
    final row = widget.rows[index];
    final selected = _selected.contains(index);
    return Container(
      color: selected
          ? AppColors.rowSelected
          : (index.isEven ? AppColors.rowEven : AppColors.panel),
      child: Row(
        children: [
          if (_selectable)
            SizedBox(
              width: _checkWidth,
              child: Checkbox(
                value: selected,
                onChanged: (v) => setState(() {
                  if (v == true) {
                    _selected.add(index);
                  } else {
                    _selected.remove(index);
                  }
                }),
                visualDensity: VisualDensity.compact,
                activeColor: AppColors.header,
              ),
            ),
          if (widget.showActions)
            SizedBox(
              width: _actionsWidth,
              // The small buttons carry 7px of their own horizontal padding, so
              // no extra inset here: their text then lines up with the header
              // title (which sits 6px inside its cell) to within 1px.
              child: Padding(
                padding: EdgeInsets.zero,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconBtn(Icons.edit_outlined,
                        key: const ValueKey('row-edit'),
                        tooltip: '编辑',
                        small: true,
                        onPressed:
                            _rowOps ? () => widget.onEdit?.call(index) : null),
                    const SizedBox(width: 4),
                    IconBtn(Icons.delete_outline,
                        key: const ValueKey('row-delete'),
                        tooltip: '删除',
                        small: true,
                        danger: true,
                        onPressed:
                            _rowOps ? () => widget.onDelete?.call(index) : null),
                  ],
                ),
              ),
            ),
          if (first > 0) SizedBox(width: _sideWidth(visible, widths, 0, first)),
          for (var v = first; v < last; v++)
            _cell(index, _visibleIndices(visible)[v], row, widths[visible[v]] ?? 110),
          if (last < visible.length)
            SizedBox(width: _sideWidth(visible, widths, last, visible.length)),
        ],
      ),
    );
  }

  Widget _cell(int rowIndex, int columnIndex, List<dynamic> row, double width) {
    final name = _columnNames[columnIndex];
    final value = columnIndex < row.length ? row[columnIndex] : null;
    final binary = isBinaryCell(value);
    final dirty = _dirtyCells[rowIndex]?.containsKey(name) ?? false;
    Widget content;
    if (value == null) {
      content = Text('NULL',
          style: TextStyle(
              fontSize: 12, color: AppColors.nullText, fontStyle: FontStyle.italic));
    } else if (binary) {
      content = Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: AppColors.blobBg,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text('${(value as Map)['len'] ?? 0} bytes',
            style: monoStyle(size: 11, color: AppColors.blobText)),
      );
    } else {
      final text = displayCell(value);
      // The cell width is fixed, so the value is clipped: [EllipsisText] keeps
      // the whole value reachable on hover, and only when it really overflows.
      // The bubble is width-bounded and wraps here because a long JSON blob
      // used to render as one line wider than the window (an overflow of its
      // own); it is never cut at 120/2000 characters — showing the whole
      // content on hover is the point.
      final big = _lazyBigFields && text.length > kLazyBigFieldThreshold;
      final label = EllipsisText(
        // Only the preview is laid out; the full value stays in the tooltip and
        // in the double-click viewer. See [AppState.lazyBigFields].
        big ? text.substring(0, kLazyBigFieldPreview) : text,
        // The hover bubble always carries the WHOLE value, preview or not, so
        // turning the preview on never takes the full content away.
        tooltip: big ? text : null,
        style: monoStyle(size: 12),
        tooltipMaxWidth: 520,
      );
      content = big
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Flexible(child: label),
                const SizedBox(width: 4),
                _lazyBadge(text.length),
              ],
            )
          : label;
    }

    return InkWell(
      onTap: () {
        copyText(binary
            ? ((value as Map)['__binary__'] ?? '').toString()
            : displayCell(value));
        _flashMessage('已复制');
      },
      onDoubleTap: () => _showCellDialog(rowIndex, name, value),
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: AppColors.border)),
          // Staged cell edits get a tint so "保存全部改动" has a visible target.
          color: dirty ? AppColors.chipBg : null,
        ),
        child: content,
      ),
    );
  }

  /// The "… N 字符" badge shown next to a lazily-rendered value.
  ///
  /// It is deliberately small and muted: it tells the reader that what they see
  /// is a preview (and how much is left), without competing with the value.
  Widget _lazyBadge(int length) => Container(
        key: const ValueKey('grid-lazy-badge'),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: AppColors.chipBg,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(3),
        ),
        // UI copy (not data): the translator turns "… N 字符" into
        // "… N chars" through enSettings' rewrite list.
        child: Text(
          '… $length 字符',
          style: TextStyle(fontSize: 10, color: AppColors.muted),
        ),
      );

  /// Full-value viewer / editor, mirroring the web cell modal.
  Future<void> _showCellDialog(int rowIndex, String column, Object? value) async {
    final controller = TextEditingController(text: displayCell(value));
    var isNull = value == null;
    final canEdit =
        _editable && (widget.onSaveCell != null || widget.onApplyEdits != null);
    final result = await showAppModal<bool>(
      context: context,
      title: column,
      builder: (context) => StatefulBuilder(
        builder: (context, setModal) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (canEdit)
              CheckBox(
                label: 'NULL',
                value: isNull,
                onChanged: (v) => setModal(() => isNull = v),
              ),
            const SizedBox(height: 6),
            TextField(
              controller: controller,
              enabled: canEdit && !isNull,
              maxLines: 6,
              style: monoStyle(size: 12),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (canEdit) ...[
              const SizedBox(height: 6),
              Text('保存会把该值写回数据库。', style: kSmallMuted),
            ],
          ],
        ),
      ),
      actions: [
        IconBtn(Icons.copy,
            key: const ValueKey('cell-copy'),
            tooltip: '复制内容',
            small: false,
            onPressed: () => copyText(displayCell(value))),
        if (canEdit)
          Btn('保存',
              primary: true,
              onPressed: () => Navigator.of(context).pop(true)),
      ],
    );
    if (result == true && canEdit) {
      if (widget.onApplyEdits != null) {
        // Batch mode: keep the edit in the grid until "保存全部改动".
        final alreadyStaged =
            _dirtyCells[rowIndex]?.containsKey(column) ?? false;
        final limit = widget.maxDirtyCells;
        if (limit != null && !alreadyStaged && _totalDirtyCount + 1 > limit) {
          // 第 60 轮：超过宿主给的暂存上限时拒绝新增（重新编辑已暂存的单元
          // 格不受限），提示先保存全部改动。
          _flashMessage('暂存改动过多（上限 $limit 个单元格），请先保存全部改动');
          return;
        }
        setState(() {
          final row = _dirtyCells[rowIndex] ??= <String, DirtyCell>{};
          final existing = row[column];
          row[column] = DirtyCell(
            rowIndex: rowIndex,
            column: column,
            value: controller.text,
            isNull: isNull,
            // 第 59 轮：捕获编辑前的原始行键。跨页恢复/保存都靠它定位行；
            // 编辑主键列本身时也仍指向旧行的键。
            keys: existing?.keys ??
                rowChangeKeys(
                  columns: widget.columns,
                  row: widget.rows[rowIndex],
                  primaryKey: widget.primaryKey,
                ),
          );
        });
        _notifyDirtyChanges();
        _flashMessage('已暂存，点「保存全部改动」生效');
      } else {
        widget.onSaveCell!(
          rowIndex,
          column,
          isNull ? null : controller.text,
          isNull,
        );
      }
    }
  }

  void _copySelected() {
    final lines = <String>[];
    for (final index in _selected.toList()..sort()) {
      final row = widget.rows[index];
      final values = <String>[];
      for (var i = 0; i < _columnNames.length; i++) {
        if (!_visibleColumns.contains(_columnNames[i])) continue;
        final value = i < row.length ? row[i] : null;
        values.add(isBinaryCell(value) ? '[BLOB]' : displayCell(value));
      }
      lines.add(values.join('\t'));
    }
    copyText(lines.join('\n'));
    _flashMessage('已复制');
  }

  String _tsv() {
    final visible = _visibleColumns;
    final header = visible.join('\t');
    final body = <String>[];
    for (final row in widget.rows) {
      final values = <String>[];
      for (var i = 0; i < _columnNames.length; i++) {
        if (!visible.contains(_columnNames[i])) continue;
        final value = i < row.length ? row[i] : null;
        values.add(isBinaryCell(value) ? '[BLOB]' : displayCell(value));
      }
      body.add(values.join('\t'));
    }
    return [header, ...body].join('\n');
  }

  String _jsonText() {
    final visible = _visibleColumns;
    final items = <Map<String, dynamic>>[];
    for (final row in widget.rows) {
      final item = <String, dynamic>{};
      for (var i = 0; i < _columnNames.length; i++) {
        if (!visible.contains(_columnNames[i])) continue;
        item[_columnNames[i]] = i < row.length ? row[i] : null;
      }
      items.add(item);
    }
    return const JsonEncoder.withIndent('  ').convert(items);
  }

  void _exportCsv() {
    // The desktop app has no download directory; the content is put on the
    // clipboard and the user is told, which is the closest equivalent.
    copyText(_tsv());
    _flashMessage('CSV 已复制到剪贴板');
  }

  void _exportJson() {
    copyText(_jsonText());
    _flashMessage('JSON 已复制到剪贴板');
  }
}
