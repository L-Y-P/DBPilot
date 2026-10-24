import 'package:flutter/material.dart' hide Text, Tooltip;
import '../text.dart';

import '../api.dart';
import '../query_metrics.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../i18n_literals.dart';
import '../import_rules.dart';
import '../nav.dart';
import '../notice.dart';
import '../sql_highlight.dart';
import '../sqlite_sources.dart';
import '../theme.dart';
import '../widgets.dart';
import 'result_table.dart';

/// Free-form SQL console. Ports Sql.vue: a database picker, a statement editor,
/// Run / Clear / Explain, and the result table.
class SqlView extends StatefulWidget {
  const SqlView({super.key, required this.notice});
  final Notice notice;

  @override
  State<SqlView> createState() => _SqlViewState();
}

class _SqlViewState extends State<SqlView> {
  final _editor = SqlHighlightingController(text: 'SELECT 1;');
  String? _database;
  List<Json> _results = <Json>[];
  String? _error;
  bool _running = false;
  int? _elapsed;
  int? _statements;
  /// S-08: set when the backend cut the result off at its row limit.
  bool _truncated = false;
  int? _rowLimit;

  /// Query-metrics run id of the last console run (for paging telemetry).
  int? _metricRunId;

  /// SQL-file execution: the Rust core streams the file and executes it
  /// statement by statement; this state polls progress and shows the summary.
  String? _filePath;
  Json? _fileJobStatus;
  Json? _fileJobResult;
  ImportJobPoller? _filePoller;
  bool _fileRunning = false;

  @override
  void initState() {
    super.initState();
    final state = AppState.instance;
    _database = state.isSqlite
        ? state.defaultDatabase
        : (state.activeDatabase ?? state.defaultDatabase);
    // PostgreSQL: the subtitle shows the session default schema; fill the
    // search_path when a tree switch did not carry it (P13).
    state.ensureSearchPath();
    // The global console keeps the harmless SELECT 1; starter. USE is only a
    // default in the table page SQL tab (where the table's database is the
    // obvious context); here the database picker above the editor is the
    // explicit way to choose it.
  }
  /// PostgreSQL / MySQL execute against the active database (selected in the
  /// tree or this picker); SQLite needs the namespace to pick the attached file.
  String? get _queryDatabase =>
      AppState.instance.isSqlite ? _database : null;

  Future<void> _selectDatabase(String? value) async {
    if (value == null) return;
    final state = AppState.instance;
    if (!state.isSqlite && value != state.activeDatabase) {
      setState(() => _running = true);
      try {
        await state.selectDatabase(value);
      } catch (e) {
        if (mounted) setState(() => _error = e.toString());
        return;
      } finally {
        if (mounted) setState(() => _running = false);
      }
    }
    if (!mounted) return;
    setState(() {
      _database = value;
      _results = <Json>[];
      _error = null;
      _truncated = false;
    });
  }

  @override
  void dispose() {
    _filePoller?.dispose();
    _editor.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_running || _editor.text.trim().isEmpty) return;
    final sql = _editor.text;
    final wall = Stopwatch()..start();
    final runId = QueryMetrics.instance.beginRun(sql: sql, source: 'console');
    _metricRunId = runId;
    // The console consumes the streaming API (optimisation layer 3): every
    // event paints into the result list, so the first page shows up while the
    // server is still reading rows instead of after the whole result set has
    // crossed the bridge and been materialised.
    setState(() {
      _running = true;
      _error = null;
      // Drop a previous run's truncation banner immediately; the new response
      // decides whether it applies again.
      _truncated = false;
      _results = <Json>[];
    });
    try {
      await for (final event in Api.instance.queryStream(sql, _queryDatabase)) {
        if (!mounted) return;
        switch (event.kind) {
          case queryEventStarted:
            _streamStarted(event);
          case queryEventBatch:
            _streamBatch(event);
          case queryEventStatementDone:
            _streamStatementDone(event);
          case queryEventDone:
            await _streamDone(event);
          case queryEventFailed:
            setState(() => _error = event.message);
          default:
            break;
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      wall.stop();
      QueryMetrics.instance.finishRun(
        runId: runId,
        resultRows: _rowsInResults(),
        truncated: _truncated,
        rustElapsedMs: _elapsed ?? 0,
        wallMs: wall.elapsedMilliseconds,
        statementCount: _statements ?? _results.length,
        failed: _error != null,
      );
      if (mounted) setState(() => _running = false);
    }
  }

  /// Rows currently rendered by the console (sum over result sets).
  int _rowsInResults() {
    var total = 0;
    for (final result in _results) {
      final rows = result['rows'];
      if (rows is List) total += rows.length;
    }
    return total;
  }

  /// Empty result map for one statement; the stream events fill it in.
  Json _emptyResult() => <String, dynamic>{
        'statement': '',
        'columns': <dynamic>[],
        'rows': <dynamic>[],
        'kind': '',
        'row_count': 0,
        'last_insert_id': 0,
        'error': null,
        'truncated': false,
      };

  /// Grow [_results] so `index` is addressable. Statement indexes are
  /// sequential; the loop keeps a skipped index from being fatal.
  void _ensureResultSlot(int index) {
    while (_results.length <= index) {
      _results.add(_emptyResult());
    }
  }

  /// `started` event: put the statement's card on screen immediately.
  void _streamStarted(QueryEvent event) {
    final index = event.statementIndex.toInt();
    setState(() {
      _ensureResultSlot(index);
      _results[index] = _emptyResult()
        ..['statement'] = event.statement ?? '';
    });
  }

  /// `batch` event: append the rows read so far (the grid only builds the
  /// first page, so one setState per batch stays cheap even for 50k rows).
  void _streamBatch(QueryEvent event) {
    final index = event.statementIndex.toInt();
    if (index >= _results.length) return;
    setState(() {
      final result = _results[index];
      final rows = result['rows'] as List<dynamic>;
      for (final row in event.rows) {
        rows.add(<dynamic>[
          for (final cell in row) cellValueToJson(cell),
        ]);
      }
      // Column metadata only rides on the first batch of the statement.
      if (event.columns.isNotEmpty) {
        result['columns'] = columnsToJson(event.columns);
      }
      // A batch means this statement returns rows: mark the kind now so the
      // grid paints its first page while later batches are still arriving
      // (waiting for statement_done would defeat the progressive rendering).
      if (event.columns.isNotEmpty || event.rows.isNotEmpty) {
        result['kind'] = 'rows';
      }
      if (event.truncated) result['truncated'] = true;
    });
  }

  /// `statement_done` event: merge the per-statement metadata. The event's
  /// rows are empty by contract — the batches already delivered them.
  void _streamStatementDone(QueryEvent event) {
    final meta = event.result;
    final index = event.statementIndex.toInt();
    if (meta == null || index >= _results.length) return;
    setState(() {
      final result = _results[index];
      result['statement'] = meta.statement;
      result['kind'] = meta.kind;
      result['row_count'] = meta.rowCount;
      result['last_insert_id'] = meta.lastInsertId;
      result['error'] = meta.error;
      result['truncated'] = meta.truncated;
      // A rows statement that returns zero rows emits no batch at all, so its
      // columns only arrive here. Filling an empty header does not overwrite
      // the columns accumulated by the batches.
      final columns = result['columns'];
      if (columns is List && columns.isEmpty && meta.columns.isNotEmpty) {
        result['columns'] = columnsToJson(meta.columns);
      }
    });
  }

  /// `done` event: run summary, search_path, then the post-DDL tree refresh.
  Future<void> _streamDone(QueryEvent event) async {
    final summary = event.summary;
    if (summary != null) {
      setState(() {
        _elapsed = summary.elapsedMs.toInt();
        _statements = summary.statementCount.toInt();
        _truncated = summary.truncated;
        _rowLimit = summary.rowLimit.toInt();
      });
      // null / empty search_path is skipped by [_applySearchPath] itself.
      _applySearchPath(<String, dynamic>{'search_path': summary.searchPath});
    }
    // Refresh the tree using the same result maps the grid is showing, so a
    // successful DDL makes the new table/schema appear without a manual
    // refresh (errors inside are ignored).
    await _refreshAfterDdl(<String, dynamic>{'results': _results});
    if (mounted) setState(() {});
  }

  /// Ask the backend to cancel the running PostgreSQL query.
  Future<void> _cancel() async {
    try {
      final res = await Api.instance.cancelQuery();
      final cancelled = (res['cancelled'] as num?)?.toInt() ?? 0;
      final reconnected = res['reconnected'] == true;
      if (cancelled <= 0) {
        widget.notice.show('没有找到正在执行的查询（可能已结束）');
      } else if (reconnected) {
        widget.notice.show('已中断查询连接，下一次查询会自动重连');
      } else {
        widget.notice.show('已发送取消请求');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _explain() async {
    if (_running || _editor.text.trim().isEmpty) return;
    setState(() {
      _running = true;
      _error = null;
      _truncated = false;
    });
    try {
      final res = await Api.instance.explain(_editor.text, _queryDatabase);
      if (!mounted) return;
      setState(() {
        _results = _asResults(res['results']);
        _elapsed = null;
        _statements = 1;
        _truncated = false;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// Re-run a single statement from a previous result, replacing that entry.
  Future<void> _rerun(int index) async {
    if (_running) return;
    final statement = (_results[index]['statement'] ?? '').toString();
    if (statement.isEmpty) return;
    setState(() => _running = true);
    try {
      final res = await Api.instance.query(statement, _queryDatabase);
      _applySearchPath(res);
      await _refreshAfterDdl(res);
      final fresh = _asResults(res['results']);
      if (!mounted) return;
      setState(() {
        if (fresh.isNotEmpty) {
          _results[index] = fresh.first;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// The backend returns the new session search_path after SET/RESET.
  void _applySearchPath(Json res) {
    final value = res['search_path'];
    if (value is! String || value.isEmpty) return;
    final state = AppState.instance;
    state.searchPath = value;
    state.notify();
  }

  /// After DDL, re-read the tree so a new table/schema/database appears without
  /// a manual refresh. Errors are ignored: the executed statement result is
  /// more important than a failed background cache refresh.
  Future<void> _refreshAfterDdl(Json response) async {
    // Result classification comes from the executed batch, not a regex over
    // editor text: comments and successful DDL before a later error count too.
    final results = _asResults(response['results']);
    if (!results.any((r) => r['error'] == null && r['kind'] == 'affected')) return;
    final state = AppState.instance;
    Navigation.instance.clearTablesCache();
    state.bumpExplorer();
    try {
      await state.refreshInstanceDatabases();
      await state.refreshDatabases();
      final database = state.activeDatabase;
      if (state.isPostgres && database != null) {
        final res = await Api.instance.listSchemas(database);
        final list = res['schemas'];
        if (list is List) {
          Navigation.instance.setSchemas(
            database,
            list.map((e) => Map<String, dynamic>.from(e as Map)).toList(),
          );
        }
      }

    } catch (_) {
      // The SQL result is already shown; a stale tree can be refreshed by hand.
    }
  }

  List<Json> _asResults(Object? value) {
    if (value is! List) return <Json>[];
    return value.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Group digits so "50000" reads as "50,000" in the limit banner.
  String _formatLimit(int? limit) {
    final value = limit ?? 0;
    final text = value.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      if (i > 0 && (text.length - i) % 3 == 0) buffer.write(',');
      buffer.write(text[i]);
    }
    return buffer.toString();
  }

  // ------------------------------------------------------- SQL file execution

  /// Pick a .sql file: small scripts load into the editor, large ones offer
  /// either a bounded preview or direct streaming execution.
  Future<void> _importSqlFile() async {
    try {
      final path = await pickSqlFile(title: '导入 SQL 文件');
      if (path == null || path.trim().isEmpty) return;
      // Read enough to decide whether the whole file fits the editor; the
      // "large file" dialog re-reads a bounded 128 KB preview when needed.
      final preview = await Api.instance
          .sqlFilePreview(path.trim(), maxBytes: 256 * 1024);
      if (!mounted) return;
      final name = (preview['name'] ?? path).toString();
      final size = (preview['size'] as num?)?.toInt() ?? 0;
      final truncated = preview['truncated'] == true;
      if (!truncated && size <= 200 * 1024) {
        setState(() {
          _editor.text = (preview['text'] ?? '').toString();
          _error = null;
          _results = <Json>[];
          _truncated = false;
        });
        widget.notice.show('已载入 $name（${formatBytes(size)}）');
        return;
      }
      final choice = await _chooseLargeSqlFile(name, size);
      if (!mounted || choice == null) return;
      if (choice == 'editor') {
        final part = await Api.instance
            .sqlFilePreview(path.trim(), maxBytes: 128 * 1024);
        if (!mounted) return;
        setState(() {
          _editor.text = (part['text'] ?? '').toString();
          _error = null;
          _results = <Json>[];
        });
        widget.notice.show('文件较大：已载入前 128 KB 供查看，直接执行可用「执行 SQL 文件」');
      } else if (choice == 'execute') {
        await _startSqlFileJob(path.trim(), name: name);
      }
    } catch (e) {
      if (mounted) setState(() => _error = describeDbError(e));
    }
  }

  Future<String?> _chooseLargeSqlFile(String name, int size) {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppMetrics.radiusModal),
          side: BorderSide(color: AppColors.border),
        ),
        child: SizedBox(
          width: 560,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('文件较大',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.header)),
                const SizedBox(height: 8),
                Text(
                  '$name 有 ${formatBytes(size)}，整个载入编辑器会占用大量内存。',
                  style: kSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  '可以只载入前 128 KB 查看/编辑，或直接让数据库流式执行整个文件'
                  '（逐条读取，不占内存，执行过程可在页面上取消）。',
                  style: kSmallMuted,
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Btn('取消',
                        onPressed: () => Navigator.of(dialogContext).pop()),
                    const SizedBox(width: 8),
                    Btn('载入前 128 KB',
                        onPressed: () =>
                            Navigator.of(dialogContext).pop('editor')),
                    const SizedBox(width: 8),
                    Btn('直接执行文件',
                        primary: true,
                        onPressed: () =>
                            Navigator.of(dialogContext).pop('execute')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Pick a .sql file and execute it by streaming from disk (no editor load).
  Future<void> _executeSqlFile() async {
    try {
      final path = await pickSqlFile(title: '选择要执行的 SQL 文件');
      if (path == null || path.trim().isEmpty) return;
      final info =
          await Api.instance.sqlFilePreview(path.trim(), maxBytes: 1);
      if (!mounted) return;
      final name = (info['name'] ?? path).toString();
      final size = (info['size'] as num?)?.toInt() ?? 0;
      final ok = await confirmDialog(
        context,
        message: '执行 SQL 文件 $name？',
        detail: '将逐条执行文件中的 SQL 语句（${formatBytes(size)}），'
            '不会载入编辑器；执行过程可取消。',
        confirmLabel: '执行',
      );
      if (!ok || !mounted) return;
      await _startSqlFileJob(path.trim(), name: name);
    } catch (e) {
      if (mounted) setState(() => _error = describeDbError(e));
    }
  }

  Future<void> _startSqlFileJob(String path, {String? name}) async {
    final state = AppState.instance;
    final database =
        _database ?? state.activeDatabase ?? state.defaultDatabase ?? '';
    setState(() {
      _fileRunning = true;
      _filePath = path;
      _fileJobStatus = null;
      _fileJobResult = null;
      _error = null;
    });
    try {
      final res = await Api.instance
          .sqlFileExecuteStart(database, path, <String, dynamic>{
        'on_error': 'stop',
        'max_issues': 50,
      });
      final jobId = (res['job_id'] ?? '').toString();
      if (!mounted) return;
      if (jobId.isEmpty) {
        setState(() => _fileRunning = false);
        return;
      }
      _filePoller?.dispose();
      _filePoller = ImportJobPoller(onUpdate: (status) {
        if (!mounted) return;
        setState(() {
          _fileJobStatus = status;
          if (status['done'] != true) return;
          _fileRunning = false;
          if (status['state'] == 'failed') {
            _fileJobResult = <String, dynamic>{
              'ok': false,
              'message': (status['error'] ?? '任务失败').toString(),
            };
            return;
          }
          final result = asJsonMap(status['result']);
          _fileJobResult = result;
          final executedDatabase = (result['database'] ?? '').toString();
          if (executedDatabase.isNotEmpty && executedDatabase != _database) {
            _database = executedDatabase;
            if (!state.isSqlite) {
              state.activeDatabase = executedDatabase;
              state.notify();
            }
          }
          if (result['ok'] == true) {
            widget.notice.show(
                'SQL 文件执行完成：${formatCount((result['statements'] as num?))} 条语句');
            _refreshAfterDdl(<String, dynamic>{
              'results': <dynamic>[
                <String, dynamic>{'error': null, 'kind': 'affected'},
              ],
            });
          }
        });
      });
      _filePoller!.start(jobId);
    } catch (e) {
      if (mounted) {
        setState(() {
          _fileRunning = false;
          _error = describeDbError(e);
        });
      }
    }
  }

  String _sqlFileContextText() {
    final state = AppState.instance;
    final database = _database ?? state.activeDatabase ?? state.defaultDatabase ?? '';
    if (state.isMysql) {
      return '执行上下文：首条自动切换到 USE ${state.quoteIdent(database)};（由应用校验可见性后安全切换）';
    }
    if (state.isPostgres) {
      return '执行上下文：目标模式 $database';
    }
    return '执行上下文：目标命名空间 $database';
  }

  Widget _sqlFileJobCard() {
    final result = _fileJobResult;
    final status = _fileJobStatus;
    final progress = asJsonMap(status?['progress']);
    final percent = (progress['percent'] as num?)?.toDouble() ?? 0;
    final issues = (result?['issues'] as List? ?? const <dynamic>[])
        .map((e) => asJsonMap(e))
        .toList();
    return CardBox(
      title: 'SQL 文件执行',
      actions: [
        if (_fileRunning)
          Btn('取消',
              small: true,
              danger: true,
              onPressed: () => _filePoller?.cancelJob()),
        if (!_fileRunning)
          IconBtn(
            Icons.close,
            tooltip: '关闭结果',
            onPressed: () => setState(() {
              _fileJobStatus = null;
              _fileJobResult = null;
              _filePath = null;
            }),
          ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          EllipsisText(_filePath ?? '',
              style: kSmallMuted, tooltipMaxWidth: 520),
          if (!_fileRunning) Text(_sqlFileContextText(), style: kSmallMuted),
          if (_fileRunning) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: percent <= 0 ? null : (percent / 100).clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: AppColors.chipBg,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.header),
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
            const SizedBox(height: 8),
            AlertBox(
              _sqlFileResultText(result),
              tone: result['ok'] == true ? AlertTone.ok : AlertTone.error,
            ),
            if (result['use_database'] != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '执行中切换数据库：${result['use_database']}',
                  style: kSmallMuted,
                ),
              ),
            if (issues.isNotEmpty) ...[
              for (final issue in issues.take(10))
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(issuePositionLabel(issue),
                      style: TextStyle(
                          fontSize: 12, color: AppColors.errText)),
                ),
              if (issues.length > 10)
                Text('（仅显示前 10 条，共 ${issues.length} 条）',
                    style: kSmallMuted),
            ],
          ],
        ],
      ),
    );
  }

  String _sqlFileResultText(Json result) {
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

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    // PostgreSQL / MySQL pick a physical database; SQLite picks an attached
    // namespace (main / file alias).
    final entries = state.isSqlite ? state.databases : state.instanceDatabases;
    final names = entries
        .map((d) => (d['name'] ?? '').toString())
        .where((n) => n.isNotEmpty)
        .toList();
    final selected = names.contains(_database) ? _database : null;
    return PageScroll(
      padding: const EdgeInsets.all(AppMetrics.mainPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHead(
            title: t('nav_sql'),
            actions: [
              SelectBox<String>(
                width: 220,
                value: selected,
                onChanged: _running || _fileRunning ? null : _selectDatabase,
                items: [
                  // SQLite has a fixed set of attached namespaces; PostgreSQL /
                  // MySQL always have an active physical database once connected,
                  // so no empty "choose one" entry is needed there.
                  if (state.isSqlite)
                    const DropdownMenuItem(value: null, child: Text('（无）')),
                  for (final name in names)
                    DropdownMenuItem(value: name, child: Text(name)),
                ],
              ),
            ],
          ),
          if (!state.isSqlite)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 8),
              child: Text(
                state.isPostgres
                    ? '当前数据库 ${state.activeDatabaseLabel}'
                        ' · 默认 schema ${state.defaultSchemaLabel}'
                    : '当前数据库 ${state.activeDatabaseLabel}',
                style: kSmallMuted,
              ),
            ),
          if (_error != null) AlertBox(_error!),
          if (_truncated)
            AlertBox(
              pickText(
                '结果超过单次查询上限（${_formatLimit(_rowLimit)} 行），已截断：'
                '仅显示前 ${_formatLimit(_rowLimit)} 行。请加 WHERE / LIMIT 缩小结果集，'
                '或到「表」页使用导出获取完整数据。',
                'The result exceeded the single-query limit '
                '(${_formatLimit(_rowLimit)} rows) and was truncated: only the '
                'first ${_formatLimit(_rowLimit)} rows are shown. Add WHERE / LIMIT '
                'to narrow the result, or use Export on the table page for the full data.',
              ),
              tone: AlertTone.warn,
            ),
          CardBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SqlEditor(
                  controller: _editor,
                  lines: 9,
                  hint: '输入 SQL，多条语句用分号分隔（Cmd/Ctrl+Enter 执行）',
                  onRun: _running ? null : _run,
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Btn(_running ? '执行中…' : t('run'),
                        key: const ValueKey('sql-run'),
                        primary: true,
                        busy: _running,
                        onPressed: _running ? null : _run),
                    Btn('取消',
                        danger: true,
                        tooltip: !_running
                            ? '当前没有正在执行的查询'
                            : state.isMysql
                                ? '中断执行查询的连接（KILL CONNECTION），下次查询自动重连'
                                : state.isPostgres
                                    ? '取消正在执行的查询（pg_cancel_backend）'
                                    : 'SQLite 在应用进程内执行，无法安全取消；点击查看说明',
                        onPressed: _running ? _cancel : null),
                    Btn(t('clear'), onPressed: () => _editor.text = ''),
                    Btn('EXPLAIN',
                        key: const ValueKey('sql-explain'),
                        tooltip: '对第一条语句执行 EXPLAIN',
                        onPressed: _running ? null : _explain),
                    Btn('历史记录',
                        onPressed: () => Navigation.instance.go(AppRoute.history)),
                    Btn('导入 SQL 文件',
                        key: const ValueKey('sql-import-file'),
                        icon: Icons.file_open,
                        tooltip: '小文件载入编辑器；大文件可预览前 128 KB 或直接流式执行',
                        onPressed: _running || _fileRunning ? null : _importSqlFile),
                    Btn('执行 SQL 文件',
                        key: const ValueKey('sql-exec-file'),
                        tooltip: '选择 .sql 文件并从磁盘流式执行（不载入编辑器）',
                        onPressed: _running || _fileRunning ? null : _executeSqlFile),
                    if (_elapsed != null)
                      Text('$_elapsed ms · ${_statements ?? 0} 条语句',
                          style: kSmallMuted),
                  ],
                ),
              ],
            ),
          ),
          if (_fileJobStatus != null) _sqlFileJobCard(),
          ResultTable(
            results: _results,
            database: _database,
            notice: widget.notice,
            rowLimit: _rowLimit,
            onRefresh: _rerun,
            onPaged: () {
              final id = _metricRunId;
              if (id != null) QueryMetrics.instance.markPaged(runId: id);
            },
          ),
        ],
      ),
    );
  }
}