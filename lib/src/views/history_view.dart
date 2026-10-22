import 'package:flutter/material.dart' hide Text, Tooltip;
import '../text.dart';

import '../api.dart';
import '../history_preview.dart';
import '../i18n.dart';
import '../i18n_literals.dart';
import '../notice.dart';
import '../paging.dart';
import '../theme.dart';
import '../tooltip.dart';
import '../widgets.dart';
import 'result_table.dart';

/// Query history. Ports History.vue: a table of past statements with copy and
/// re-run actions, plus a clear-all button.
class HistoryView extends StatefulWidget {
  const HistoryView({super.key, required this.notice});
  final Notice notice;

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  /// Rows per page. Rust returns only this page, so the FFI payload stays small
  /// even when the history file holds thousands of entries.
  static const int _pageSize = 50;

  List<Json> _entries = <Json>[];
  List<Json> _results = <Json>[];
  /// Database of the history entry last re-run; passed to ResultTable so its
  /// rows can be exported through the same exchange-format writers as the table
  /// page (a history re-run has no other database context).
  String? _resultDatabase;
  String? _error;
  bool _loading = true;
  int _page = 1;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool resetPage = false}) async {
    if (resetPage) _page = 1;
    setState(() {
      _loading = true;
      _error = null;
    });
    final requested = _page;
    try {
      final data = await Api.instance.historyPage(
        limit: _pageSize,
        offset: (requested - 1) * _pageSize,
      );
      if (!mounted) return;
      final raw = data['history'];
      final list = raw is List
          ? raw.map((e) => Map<String, dynamic>.from(e as Map)).toList()
          : <Json>[];
      final total = (data['total'] as num?)?.toInt() ?? list.length;
      final pages = pageCountFor(total, _pageSize);
      final target = requested > pages ? pages : requested;
      setState(() {
        _entries = list;
        _total = total;
        _page = target;
        _loading = false;
      });
      if (target != requested) {
        // The current page disappeared (e.g. entries were cleared/deleted
        // elsewhere): load the last valid page instead of showing an empty grid.
        await _load();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _changePage(int page) {
    if (page == _page) return;
    setState(() => _page = page);
    _load();
  }

  void _copy(Json entry) {
    copyText((entry['sql'] ?? '').toString());
    widget.notice.show('已复制');
  }

  Future<void> _rerun(Json entry) async {
    _resultDatabase = (entry['database'] ?? '').toString().trim().isEmpty
        ? null
        : entry['database'].toString();
    if (historySqlTruncated(entry)) {
      widget.notice.show(pickText(
        '该条历史只保存了前 32 KB SQL（原文 ${historySqlChars(entry)} 字符），无法直接重跑；请用原始脚本重新执行。',
        'This history entry kept only the first 32 KB of SQL (original: ${historySqlChars(entry)} characters) and cannot be re-run; execute the original script instead.',
      ));
      return;
    }
    try {
      final res = await Api.instance.query(
        (entry['sql'] ?? '').toString(),
        (entry['database'] ?? '').toString().isEmpty
            ? null
            : entry['database'].toString(),
      );
      final value = res['results'];
      setState(() {
        _results = value is List
            ? value.map((e) => Map<String, dynamic>.from(e as Map)).toList()
            : <Json>[];
      });
      await _load(resetPage: true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _clear() async {
    final ok = await confirmDialog(context,
        message: '确定清空全部查询历史吗？', confirmLabel: '清空', danger: true);
    if (!ok) return;
    try {
      await Api.instance.clearHistory();
      await _load(resetPage: true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Show one statement in full.
  ///
  /// The history grid clips every cell to its column, so a long statement used
  /// to be unreachable: the ellipsis hid the rest of the SQL and nothing opened
  /// it. Tapping the cell now brings the whole statement up in a scrollable,
  /// selectable block.
  Future<void> _showSql(Json entry) async {
    final sql = (entry['sql'] ?? '').toString();
    final database = (entry['database'] ?? '').toString();
    final chars = historySqlChars(entry);
    final shown = historySqlDisplay(entry);
    final clipped = shown.length < sql.length;
    final truncated = historySqlTruncated(entry);
    await showAppModal(
      context: context,
      title: '完整 SQL',
      wide: true,
      builder: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (database.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('数据库：$database', style: kSmallMuted),
            ),
          if (truncated || clipped)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AlertBox(
                pickText(
                  '该脚本过长（原文 $chars 字符），历史仅保存/显示前 ${shown.length} 字符；'
                      '如需完整内容请用原始 SQL 文件重新执行。',
                  'This script is very long (original: $chars characters); only the first '
                      '${shown.length} characters are stored/shown. Re-run the original SQL file '
                      'for the full content.',
                ),
                tone: AlertTone.warn,
              ),
            ),
          CodeBlock(shown, maxHeight: 360),
        ],
      ),
      actions: [
        Builder(
          builder: (context) => IconBtn(Icons.copy,
              key: const ValueKey('history-copy'),
              tooltip: '复制',
              small: false,
              onPressed: () {
                copyText(sql);
                widget.notice.show('已复制');
              }),
        ),
        Builder(
          builder: (context) => IconBtn(Icons.close,
              key: const ValueKey('history-close'),
              tooltip: '关闭',
              small: false,
              onPressed: () => Navigator.of(context).pop()),
        ),
      ],
    );
  }

  /// One page of history in the same grid/pager used by the data browser.
  Widget _historyCard() {
    // Natural height for a short page, capped so a 50-row page scrolls inside
    // the card instead of growing the whole page.
    final wanted = 36.0 * (_entries.length + 1) + 2;
    final height = wanted < 440.0 ? wanted : 440.0;
    return CardBox(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: height,
            child: GridTable(
              maxHeight: height,
              // Always take the pinned-header/virtual body: its horizontal
              // scrollbar sits at the bottom of the viewport instead of below
              // the last row, so left/right dragging works without scrolling
              // the 50-row page to the end first.
              virtualizeAfter: 0,
              emptyText: '暂无历史记录',
              // Fixed widths avoid an intrinsic-measure pass over every SQL
              // preview; the SQL column is wide enough for the bounded preview
              // and the table scrolls horizontally on narrow windows.
              widths: const <TableColumnWidth>[
                FixedColumnWidth(170),
                FixedColumnWidth(72),
                FixedColumnWidth(140),
                FixedColumnWidth(72),
                FixedColumnWidth(84),
                FixedColumnWidth(420),
                FixedColumnWidth(120),
              ],
              headers: [
                Text('时间'),
                Text('状态'),
                Text('数据库'),
                Text('语句数'),
                Text('耗时'),
                Text('SQL'),
                Text('操作'),
              ],
              rows: [for (final entry in _entries) _historyRow(entry)],
            ),
          ),
          TablePager(
            page: _page,
            pages: pageCountFor(_total, _pageSize),
            total: _total,
            visible: _entries.length,
            onPage: _changePage,
            keyPrefix: 'history-pager',
          ),
        ],
      ),
    );
  }

  TableRow _historyRow(Json entry) {
    final preview = historySqlPreview(entry);
    final truncated = historySqlTruncated(entry);
    final chars = historySqlChars(entry);
    final ok = entry['ok'] == true;
    final database = (entry['database'] ?? '').toString();
    return TableRow(
      children: [
        gridCell((entry['at'] ?? '').toString(), muted: true),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Pill(ok ? 'ok' : 'failed',
                tone: ok ? PillTone.ok : PillTone.danger),
          ),
        ),
        gridCell(database.isEmpty ? '—' : database, mono: true),
        gridCell(entry['statements']),
        gridCell('${entry['elapsed_ms'] ?? 0} ms', muted: true),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => _showSql(entry),
                  child: EllipsisText(
                    preview,
                    tooltip: '$preview\n'
                        '${truncated ? pickText('（SQL 已截断，点击查看详情 / 原文字符数：$chars）', '(SQL truncated; click for details / original chars: $chars)') : pickText('（点击查看完整 SQL）', '(click to view the full SQL)')}',
                    tooltipMaxWidth: 520,
                    style: monoStyle(size: 12),
                  ),
                ),
              ),
              if (truncated)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Tooltip(
                    message: pickText(
                      'SQL 过长：历史仅保存前 32 KB（原文 $chars 字符），因此不能直接重跑。',
                      'SQL too long: history kept only the first 32 KB (original $chars characters), so it cannot be re-run.',
                    ),
                    child: Icon(Icons.content_cut,
                        size: 12, color: AppColors.muted),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            children: [
              IconBtn(Icons.copy,
                  key: const ValueKey('history-row-copy'),
                  tooltip: '复制',
                  small: true,
                  onPressed: () => _copy(entry)),
              const SizedBox(width: 4),
              IconBtn(Icons.replay,
                  key: const ValueKey('history-row-rerun'),
                  tooltip: truncated
                      ? pickText(
                          '该条历史 SQL 已截断（原文 $chars 字符），无法直接重跑',
                          'This history SQL was truncated (original $chars characters) and cannot be re-run',
                        )
                      : '重跑',
                  small: true,
                  primary: true,
                  onPressed: truncated ? null : () => _rerun(entry)),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PageScroll(
      padding: const EdgeInsets.all(AppMetrics.mainPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHead(
            title: '查询历史',
            meta: [Pill(_total.toString())],
            actions: [
              Btn(t('refresh'), onPressed: _load),
              Btn('清空历史', danger: true, onPressed: _clear),
            ],
          ),
          if (_error != null) AlertBox(_error!),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_total == 0)
            CardBox(child: Text('暂无历史记录', style: kMuted))
          else
            _historyCard(),
          ResultTable(
            results: _results,
            database: _resultDatabase,
            notice: widget.notice,
          ),
        ],
      ),
    );
  }
}
