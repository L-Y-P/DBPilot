import 'dart:convert';

import 'package:flutter/material.dart' hide Text, Tooltip;
import '../text.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n_literals.dart';
import '../i18n.dart';
import '../notice.dart';
import '../paging.dart';
import '../sqlite_sources.dart';
import '../theme.dart';
import '../widgets.dart';

/// 一次备份还原的结果文案（第 58 轮）。
///
/// 纯数据 + 纯函数，便于中英文 / 原子 / 回滚 / 旧后端降级单测；UI 用 [message]。
class RestoreOutcomeCopy {
  const RestoreOutcomeCopy({
    required this.zh,
    required this.en,
    required this.isError,
  });

  final String zh;
  final String en;

  /// 失败（有 failed 语句或整段回滚）时为 true；UI 据此决定是否展示错误列表。
  final bool isError;

  String get message => pickText(zh, en);
}

/// 把 restoreBackup 的返回翻译成用户提示（第 58 轮）。
///
/// 新后端（Rust）返回：
///   * `total_statements`：切分后的语句总数；
///   * `statements`：实际执行过的语句数（= results 数量，含失败的那条）；
///   * `skipped_statements`：原子还原中途失败后没执行的语句数；
///   * `atomic` / `rolled_back` / `failed`。
/// 规则：
///   * 失败且 `rolled_back == true`：整段事务已回滚，明确告诉用户「未写入任何
///     数据」，并给出 总数 / 已执行 / 跳过；
///   * 成功且 `atomic == true`：提示这是整段事务；
///   * 其它（旧后端没有这些字段 / MySQL 非原子）：沿用原提示；[mysql] 时补一句
///     「MySQL 的 DDL 会隐式提交，无法整段回滚」。
///
/// 兼容旧后端与 `executed` / `skipped` 这组备用字段名，缺失时按 `statements`
/// 与总数推断，保证降级时提示仍然合理。
RestoreOutcomeCopy describeRestoreOutcome(Json result, {bool mysql = false}) {
  final total =
      (result['total_statements'] as num?)?.toInt() ??
      (result['statements'] as num?)?.toInt() ??
      0;
  final failed = (result['failed'] as num?)?.toInt() ?? 0;
  final executed =
      (result['executed'] as num?)?.toInt() ??
      (result['statements'] as num?)?.toInt() ??
      0;
  final skipped =
      (result['skipped_statements'] as num?)?.toInt() ??
      (result['skipped'] as num?)?.toInt() ??
      (total - executed < 0 ? 0 : total - executed);
  final rolledBack = result['rolled_back'] == true;
  final atomic = result['atomic'] == true;
  final ok = result['ok'] != false;
  const mysqlHintZh = '；MySQL 的 DDL 会隐式提交，无法整段回滚';
  const mysqlHintEn =
      '; MySQL DDL commits implicitly, so the restore cannot roll back as a whole';
  if (failed > 0 || rolledBack || !ok) {
    if (rolledBack) {
      return RestoreOutcomeCopy(
        zh: '还原失败，已整体回滚，未写入任何数据'
            '（共 $total 条语句，已执行 $executed，跳过 $skipped）',
        en: 'Restore failed and was rolled back as a whole; no data was written '
            '($total statement(s) total, $executed executed, '
            '$skipped skipped)',
        isError: true,
      );
    }
    if (atomic) {
      return RestoreOutcomeCopy(
        zh: '还原失败（整段事务未提交；共 $total 条语句，跳过 $skipped）',
        en: 'Restore failed inside the whole-restore transaction and was not '
            'committed ($total statement(s) total, $skipped skipped)',
        isError: true,
      );
    }
    if (failed > 0) {
      return RestoreOutcomeCopy(
        zh: '备份还原完成，但 $failed / $total 条语句失败'
            '${mysql ? mysqlHintZh : ''}',
        en: 'Restore finished with $failed / $total statement(s) failed'
            '${mysql ? mysqlHintEn : ''}',
        isError: true,
      );
    }
    // 兜底：后端标记 ok=false 但没有逐条错误（理论上不会发生）。
    return RestoreOutcomeCopy(
      zh: '还原失败（共 $total 条语句，跳过 $skipped）'
          '${mysql ? mysqlHintZh : ''}',
      en: 'Restore failed ($total statement(s) total, $skipped skipped)'
          '${mysql ? mysqlHintEn : ''}',
      isError: true,
    );
  }
  if (atomic) {
    return RestoreOutcomeCopy(
      zh: '还原成功（整段事务，$total 条语句）',
      en: 'Restored successfully in one transaction ($total statement(s))',
      isError: false,
    );
  }
  return RestoreOutcomeCopy(
    zh: '备份已还原（$total 条语句）${mysql ? mysqlHintZh : ''}',
    en: 'Backup restored ($total statement(s))${mysql ? mysqlHintEn : ''}',
    isError: false,
  );
}

/// Backup list and restore actions. Ports Backups.vue: create a dump of a whole
/// database or a single table, then save a copy, restore it, or delete the file.
class BackupsView extends StatefulWidget {
  const BackupsView({super.key, required this.notice});
  final Notice notice;

  @override
  State<BackupsView> createState() => _BackupsViewState();
}

class _BackupsViewState extends State<BackupsView> {
  List<Json> _backups = <Json>[];
  List<Json> _tables = <Json>[];
  String? _database;
  String? _table;
  String? _error;
  bool _busy = false;
  bool _loading = true;
  bool _showOtherDrivers = false;

  /// Backups per page. A backup folder can hold hundreds of files; rendering
  /// (and building the action buttons for) all of them on every rebuild used to
  /// stutter, so the list is paginated like the data browser.
  static const int _pageSize = 20;
  int _page = 1;

  /// Physical database the backup selector/tables were loaded from.
  String? _scope;

  /// Database the backup controls act on.
  ///
  /// P3-10: the subtitle used to print [AppState.activeDatabaseLabel] (the
  /// database selected in the tree) while the picker above it could point at
  /// another one, so the page described "rma_big" while it created a backup of
  /// rma_gui_test. The picker is what _create() sends to the backend, so it is
  /// the only honest source for the subtitle and for the restore confirmation's
  /// fallback label.
  String get _targetLabel {
    final db = _database;
    if (db != null && db.isNotEmpty) return db;
    return AppState.instance.activeDatabaseLabel;
  }

  /// Restore-confirmation fallback for a backup that recorded no database:
  /// name the database currently selected, or keep the generic wording when
  /// there is nothing to name.
  String get _restoreTargetFallback {
    final label = _targetLabel;
    return label.isEmpty ? pickText('当前数据库', 'current database') : label;
  }

  @override
  void initState() {
    super.initState();
    _scope = AppState.instance.isSqlite
        ? 'sqlite'
        : (AppState.instance.activeDatabase ?? '');
    _database = AppState.instance.defaultDatabase;
    _loadTables();
    _load();
  }

  /// Rebuild the schema/table pickers when the tree switches database.
  void _syncScope() {
    final state = AppState.instance;
    final scope = state.isSqlite ? 'sqlite' : (state.activeDatabase ?? '');
    if (_scope == scope) return;
    _scope = scope;
    _database = null;
    _table = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _loading = true;
      _page = 1;
    });
    try {
      final list = await Api.instance.backups();
      if (!mounted) return;
      setState(() => _backups = list);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
    // The database list may arrive after this view is built, so re-derive the
    // selection instead of only checking it once during initState.
    final names = AppState.instance.databases.map((d) => d['name'].toString());
    if (_database == null || !names.contains(_database)) {
      final next = AppState.instance.defaultDatabase;
      if (next != _database) {
        _database = next;
        await _loadTables();
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadTables() async {
    setState(() => _table = null);
    final db = _database;
    if (db == null || db.isEmpty) {
      setState(() => _tables = <Json>[]);
      return;
    }
    try {
      final list = await Api.instance.tables(db);
      if (!mounted) return;
      setState(() {
        _tables = list
            .where((t) => (t['type'] ?? '').toString() == 'BASE TABLE')
            .toList();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tables = <Json>[];
        _error = e.toString();
      });
    }
  }

  Future<void> _create() async {
    final db = _database;
    if (db == null || db.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.instance.createBackup(<String, dynamic>{
        'database': db,
        'table': (_table == null || _table!.isEmpty) ? null : _table,
      });
      widget.notice.show('备份已创建');
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveAs(Json entry) async {
    final file = (entry['file'] ?? '').toString();
    setState(() => _error = null);
    try {
      final res = await Api.instance.readBackup(entry['id'].toString());
      final content = (res['content'] ?? '').toString();
      if (!mounted) return;
      // Native save dialog, so the destination is browsable instead of typed.
      final path = await saveTextFile(
        content: content,
        title: '另存为',
        fileName: file.isEmpty ? 'backup.sql' : file,
        initialDirectory: AppState.instance.dataDir,
      );
      if (path == null || path.isEmpty) return;
      widget.notice.show('已保存到 $path');
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _restore(Json entry) async {
    final target = (entry['server_database'] ?? '').toString();
    final database = (entry['database'] ?? '').toString();
    final restoreTarget = target.isEmpty ? database : '$target / $database';
    final scope = (entry['table'] ?? '').toString();
    final file = (entry['file'] ?? '').toString();
    // N-08: the old confirmation only repeated the action. A restore imports
    // the dump into the live schema and is not transactional across all
    // statements, so it can overwrite or append data with no undo. Say that
    // before the user commits, and offer "先备份" guidance.
    final ok = await confirmDialog(
      context,
      message: '${t('backup_restore_confirm')}\n\n'
          '${pickText('目标', 'Target')}：'
          '${restoreTarget.isEmpty ? _restoreTargetFallback : restoreTarget}\n'
          '${pickText('备份文件', 'Backup file')}：$file\n'
          '${pickText('范围', 'Scope')}：'
          '${scope.isEmpty ? pickText('整个库', 'entire database') : '${pickText('表', 'table')} $scope'}\n\n'
          '⚠ ${pickText('恢复会把 SQL 依次导入目标库，可能覆盖或追加现有数据，且不可撤销。', 'Restore runs the dump against the target database; it may overwrite or append data and cannot be undone.')}\n'
          '${pickText('建议先为当前数据创建一份备份再恢复。', 'Create a backup of the current data before restoring.')}',
      confirmLabel: '恢复',
      danger: true,
    );
    if (!ok) return;
    setState(() => _error = null);
    try {
      final res = await Api.instance.restoreBackup(entry['id'].toString());
      // 第 58 轮：新后端会返回 atomic / rolled_back / skipped，按结果给出
      // 「整段事务 / 已整体回滚」等更准确的提示；旧后端自动降级到原提示。
      final outcome = describeRestoreOutcome(
        res,
        mysql: AppState.instance.isMysql,
      );
      widget.notice.show(outcome.message);
      // A PostgreSQL backup records its physical database; follow it if the
      // restore switched the Rust-side active database.
      final state = AppState.instance;
      await state.refreshInstanceDatabases();
      final target = (entry['server_database'] ?? '').toString();
      if (target.isNotEmpty && target != state.activeDatabase) {
        try {
          await state.selectDatabase(target);
        } catch (_) {
          // The list refresh is still enough to show the database.
        }
      }
      await _loadTables();
      if (outcome.isError && mounted) {
        // 回滚/部分失败都保留逐条错误列表，方便定位失败的语句。
        setState(() => _error = _prettyErrors(res['errors']));
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _delete(Json entry) async {
    final ok = await confirmDialog(
      context,
      message: t('backup_delete_confirm'),
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    setState(() => _error = null);
    try {
      await Api.instance.deleteBackup(entry['id'].toString());
      widget.notice.show('备份已删除');
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// The web view stringified the first three restore errors; keep them
  /// indented so a long SQL statement stays readable inside the alert box.
  String _prettyErrors(Object? errors) {
    if (errors is! List) return errors?.toString() ?? '';
    return const JsonEncoder.withIndent('  ').convert(errors.take(3).toList());
  }

  void _changePage(int page) {
    if (page == _page) return;
    setState(() => _page = page);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    _syncScope();
    final visibleBackups = _backups.where((entry) => _showOtherDrivers ||
        entry['driver'] == state.driver).toList();
    final pages = pageCountFor(visibleBackups.length, _pageSize);
    final page = clampPage(_page, visibleBackups.length, _pageSize);
    final pageRows = pageSlice(visibleBackups, page, _pageSize);
    return PageScroll(
      padding: const EdgeInsets.all(AppMetrics.mainPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHead(
            title: '备份',
            meta: [
              Pill(visibleBackups.length.toString()),
              // P3-10: the header pill names the same database the controls
              // act on, not the tree selection.
              if (!state.isSqlite && _targetLabel.isNotEmpty)
                Pill('数据库 $_targetLabel', tone: PillTone.info),
            ],
            actions: [Btn(t('refresh'), onPressed: _load)],
          ),
          if (!state.isSqlite && _targetLabel.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 8),
              child: Text(
                state.isPostgres
                    ? '备份作用于当前数据库 $_targetLabel 中的模式；恢复时会切换回备份记录的数据库。'
                    : '备份作用于当前数据库 $_targetLabel。',
                style: kSmallMuted,
              ),
            ),
          if (!state.connected)
            const AlertBox(
              '尚未连接数据库：备份需要先打开一个连接。',
              tone: AlertTone.info,
            ),
          if (_error != null) AlertBox(_error!),
          NoticeBanner(widget.notice),
          CardBox(
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                ControlGroup(
                  label: state.isPostgres ? '模式' : t('backup_database'),
                  width: 200,
                  child: SelectBox<String>(
                    value: _database,
                    onChanged: (v) {
                      setState(() => _database = v);
                      _loadTables();
                    },
                    items: [
                      for (final db in state.databases)
                        DropdownMenuItem(
                          value: db['name'].toString(),
                          child: Text(db['name'].toString()),
                        ),
                    ],
                  ),
                ),
                ControlGroup(
                  label: t('backup_table'),
                  width: 200,
                  child: SelectBox<String>(
                    value: _table,
                    onChanged: (v) => setState(() => _table = v),
                    items: [
                      DropdownMenuItem<String>(
                        value: null,
                        child: Text(t('backup_all_tables')),
                      ),
                      for (final tb in _tables)
                        DropdownMenuItem(
                          value: tb['name'].toString(),
                          child: Text(tb['name'].toString()),
                        ),
                    ],
                  ),
                ),
                ControlGroup(
                  label: null,
                  height: kControlHeight,
                  child: Btn(
                    _busy ? t('loading') : t('backup_create'),
                    primary: true,
                    onPressed:
                        (_busy || _database == null || _database!.isEmpty)
                            ? null
                            : _create,
                  ),
                ),
              ],
            ),
          ),
          CheckBox(
            label: I18n.current == AppLang.en
                ? 'Show backups from other drivers' : '显示其他驱动的备份',
            value: _showOtherDrivers,
            onChanged: (value) => setState(() {
              _showOtherDrivers = value;
              _page = 1;
            }),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(I18n.current == AppLang.en
                ? 'Filtered by driver, not connection. Backups do not record a connection ID.'
                : '按驱动筛选，不按连接筛选；备份未记录连接标识。', style: kSmallMuted),
          ),
          CardBox(
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      GridTable(
                        emptyText: t('backup_none'),
                        headers: [
                          Text(t('backup_file')),
                          Text(t('driver')),
                          Text(t('backup_database')),
                          Text(t('backup_scope')),
                          Text(t('backup_size')),
                          Text(t('backup_created_at')),
                          Text(t('actions')),
                        ],
                        rows: [
                          for (final entry in pageRows)
                            TableRow(
                              children: [
                                gridCell(entry['file'],
                                    mono: true,
                                    title: entry['file']?.toString()),
                                gridCell(entry['driver']),
                                gridCell(
                                  (entry['server_database'] ?? '')
                                          .toString()
                                          .isEmpty
                                      ? entry['database']
                                      : '${entry['server_database']} / ${entry['database']}',
                                  mono: true,
                                ),
                                gridCell(
                                    (entry['table'] ?? '').toString().isEmpty
                                        ? t('backup_all_tables')
                                        : entry['table']),
                                gridCell(
                                    formatBytes(entry['size'] as num?)),
                                gridCell(
                                    formatBackupTimestamp(
                                        entry['created_at']),
                                    muted: true,
                                    title: entry['created_at']?.toString()),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  child: Row(
                                    children: [
                                      Btn(t('backup_download'),
                                          small: true,
                                          onPressed: () => _saveAs(entry)),
                                      const SizedBox(width: 4),
                                      Btn(t('backup_restore'),
                                          small: true,
                                          onPressed: state.connected &&
                                                  entry['driver'] ==
                                                      state.driver
                                              ? () => _restore(entry)
                                              : null),
                                      const SizedBox(width: 4),
                                      Btn(t('delete'),
                                          small: true,
                                          danger: true,
                                          onPressed: () => _delete(entry)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                      if (visibleBackups.isNotEmpty)
                        TablePager(
                          page: page,
                          pages: pages,
                          total: visibleBackups.length,
                          visible: pageRows.length,
                          onPage: _changePage,
                          keyPrefix: 'backup-pager',
                          unit: '项',
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// Render zoned backup instants locally, with an explicit numeric offset.
/// Preserve legacy zone-less values: their timezone cannot be inferred.
String formatBackupTimestamp(Object? value) {
  final raw = value?.toString() ?? '';
  if (raw.isEmpty) return '—';
  final zoned = RegExp(r'(Z|[+-]\d{2}:?\d{2})$', caseSensitive: false).hasMatch(raw);
  final parsed = DateTime.tryParse(raw);
  if (!zoned || parsed == null) return raw;
  final local = parsed.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final minutes = local.timeZoneOffset.inMinutes;
  final sign = minutes < 0 ? '-' : '+';
  final offset = minutes.abs();
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)} '
      '(UTC$sign${two(offset ~/ 60)}:${two(offset % 60)})';
}
