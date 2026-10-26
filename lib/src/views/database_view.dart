import 'package:flutter/material.dart' hide Text, Tooltip;
import '../text.dart';
import '../tooltip.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n_literals.dart';
import '../i18n.dart';
import '../nav.dart';
import '../notice.dart';
import '../paging.dart';
import '../sqlite_actions.dart';
import '../theme.dart';
import '../widgets.dart';
import 'create_table_dialog.dart';
import 'quick_create_table_wizard.dart';
import 'relation_designer.dart';

/// Rows per page in the 数据表 and 对象 cards.
///
/// Both cards render through the same [GridTable] + [TablePager] pair as the
/// data browser, but they ask the driver for every row at once: slicing to one
/// page is what keeps the widget count bounded (120 tables used to build 120
/// rows of action buttons in one frame). 50 also stays below [GridTable]'s
/// virtualisation threshold, so the cards keep the original eager table
/// rendering and only the row set is sliced.
const int kDbTablePageSize = 50;

/// Database overview: the table list plus the schema-object browser.
///
/// Ports Database.vue. The web version also had a create-table modal with a
/// full visual designer; that lives in TableView's Design tab here so the two
/// share one implementation, and this view keeps the create-table dialog for
/// new tables.
class DatabaseView extends StatefulWidget {
  const DatabaseView({super.key, required this.db, required this.notice});
  final String db;
  final Notice notice;

  @override
  State<DatabaseView> createState() => _DatabaseViewState();
}

class _DatabaseViewState extends State<DatabaseView> {
  List<Json> _tables = <Json>[];
  Json _objects = <String, dynamic>{};
  String _objectFilter = '';
  String _objectTab = 'views';
  String? _error;
  bool _loading = true;

  /// 1-based page shown by the 数据表 card.
  int _tablePage = 1;

  /// 1-based page shown by the 对象 card; every object tab shares it.
  int _objectPage = 1;

  /// Physical database the current table list was loaded from.
  String? _loadedDatabase;
  int _loadedExplorerVersion = -1;
  int _loadGeneration = 0;

  /// Actions the database refused with a permission error (P12).
  ///
  /// They are stored in [AppState] keyed by connection + database + action, so
  /// the button stays greyed while this page is revisited and a reconnect
  /// clears it. The page-level banner explains the account/database/action.
  static const String _actionCreateTable = 'create_table';
  static const String _actionDropDatabase = 'drop_database';
  static const String _actionTruncateTable = 'truncate_table';
  static const Map<String, String> _actionLabels = <String, String>{
    _actionCreateTable: '新建表',
    _actionDropDatabase: '删除数据库',
    _actionTruncateTable: '清空表',
  };

  @override
  void initState() {
    super.initState();
    _loadedDatabase = AppState.instance.activeDatabase;
    _loadedExplorerVersion = AppState.instance.explorerVersion;
    AppState.instance.addListener(_onAppState);
    _load();
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_onAppState);
    super.dispose();
  }

  /// Switching from dbA/public to dbB/public does not change the schema route,
  /// so Flutter reuses this State; the physical database must still reload the
  /// table list.
  void _onAppState() {
    final active = AppState.instance.activeDatabase;
    final version = AppState.instance.explorerVersion;
    if (active == _loadedDatabase && version == _loadedExplorerVersion) return;
    _loadedDatabase = active;
    _loadedExplorerVersion = version;
    _load();
  }

  @override
  void didUpdateWidget(covariant DatabaseView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadedDatabase = AppState.instance.activeDatabase;
    if (oldWidget.db != widget.db) _load();
  }

  /// Namespace actually addressed by this page.
  ///
  /// A SQLite connection has exactly one namespace per file, and the primary
  /// file's namespace is always `main`. An old route (or a hand-typed URL) may
  /// still carry a file name, which is not a valid schema; falling back keeps the
  /// page usable instead of showing "no such table".
  String get _namespace {
    if (!isSqlite) return widget.db;
    for (final db in AppState.instance.databases) {
      if ((db['name'] ?? '').toString() == widget.db) return widget.db;
      if ((db['title'] ?? '').toString() == widget.db) {
        return (db['name'] ?? widget.db).toString();
      }
    }
    return widget.db;
  }

  Future<void> _load({bool refreshFiles = false}) async {
    final generation = ++_loadGeneration;
    final namespace = _namespace;
    setState(() {
      _loading = true;
      _error = null;
    });
    // PostgreSQL: a tree expansion / restored route can change the active
    // database without a selectDatabase response carrying its search_path.
    // Fill it in the background so the subtitle never shows "（未知）"; the
    // page itself must not wait for this probe.
    AppState.instance.ensureSearchPath();
    try {
      // A refresh re-reads the *current* connection's folder and rebuilds its
      // pool, so a database file added (or deleted) outside the app is picked
      // up here rather than only on reconnect.
      if (refreshFiles) {
        await AppState.instance.refreshDatabases(refreshFiles: true);
        if (!mounted) return;
      }
      final tables = await Api.instance.tables(namespace);
      final objects = await Api.instance.objects(namespace);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _tables = tables;
        _objects = objects;
        // New rows (another database, a refresh that added or dropped tables)
        // invalidate the old page number, so both cards start over at 1.
        _tablePage = 1;
        _objectPage = 1;
        _loading = false;
      });
      // Keep the sidebar table cache in step.
      Navigation.instance.tablesByDb[namespace] = tables
          .map((t) => (t['name'] ?? '').toString())
          .where((n) => n.isNotEmpty)
          .toList();
      Navigation.instance.notify();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }


  /// True when a permission failure taught the page that [action] is denied.
  bool _denied(String action) =>
      AppState.instance.isActionDenied(_namespace, action);

  /// Tooltip for a greyed-out action: account, database and what is missing.
  String _deniedTooltip(String action) {
    final state = AppState.instance;
    final label = _actionLabels[action] ?? action;
    final account = state.dbAccount;
    final who = account.isEmpty ? '当前数据库账号' : '当前数据库账号（$account）';
    final reason = state.deniedActionReason(_namespace, action);
    return '$who在数据库 $_namespace 上没有执行「$label」的权限，该按钮已置灰。'
        '${reason == null ? '' : '\n$reason'}'
        '\n授予权限后点「刷新」重新检测。';
  }

  /// Record a permission failure and explain it on the page instead of leaving
  /// the user with MySQL's raw "1142 ... command denied".
  void _learnPermissionFailure(String action, Object error) {
    final state = AppState.instance;
    state.markActionDenied(_namespace, action, describeDbError(error));
    if (!mounted) return;
    setState(() => _error = _permissionActionMessage(action, error));
  }

  String _permissionActionMessage(String action, Object error) {
    final state = AppState.instance;
    final account = state.dbAccount;
    final who = account.isEmpty ? '当前数据库账号' : '当前数据库账号（$account）';
    final label = _actionLabels[action] ?? action;
    return '$who在数据库 $_namespace 上没有执行「$label」的权限，数据库拒绝了该操作。\n'
        '${describeDbError(error)}\n'
        '相关按钮已置灰；请让数据库管理员授予相应权限，然后点「刷新」重新检测。';
  }

  /// The actions this page has learned are refused, in tab order.
  List<String> get _deniedActions => _actionLabels.keys
      .where((action) => AppState.instance.isActionDenied(_namespace, action))
      .toList();

  /// One banner listing every learned denial for this database.
  Widget _deniedActionsNotice() {
    final state = AppState.instance;
    final account = state.dbAccount;
    final who = account.isEmpty ? '当前数据库账号' : '当前数据库账号（$account）';
    final labels = _deniedActions
        .map((action) => _actionLabels[action] ?? action)
        .join('、');
    return AlertBox(
      '$who在数据库 $_namespace 上缺少以下操作权限，相关按钮已置灰：$labels。\n'
      '这是根据数据库刚才的拒绝结果学习的；授予权限后点「刷新」重新检测。',
      tone: AlertTone.info,
    );
  }

  /// Refresh clears learned denials so a newly granted privilege is retried.
  Future<void> _refresh() async {
    AppState.instance.clearDeniedActions();
    await _load(refreshFiles: true);
  }

  /// Explanation for databases that exist but were not opened.
  String _overflowText() {
    final state = AppState.instance;
    final extra = state
        .sqliteOverflow
        .map((u) => '· ${u['path']}')
        .join('\n');
    return '同时打开的数据库过多：已打开 ${state.databases.length} 个，'
        '另有 ${state.sqliteOverflow.length} 个未打开。'
        'SQLite 一个连接最多同时附加 ${state.sqliteAttachLimit} 个数据库，'
        '打开过多也会占用文件句柄与内存。\n$extra';
  }

  /// Explanation for files the folder contains but the pool could not attach.
  String _unreadableText() {
    final lines = AppState.instance.sqliteCorrupt
        .map((u) => '· ${u['path']} — ${u['reason'] ?? ''}')
        .join('\n');
    return '以下文件不是可用的 SQLite 数据库，未加入列表：\n$lines\n'
        '如果文件确实损坏，请备份后重新创建；如果只是被其他程序占用，关闭占用后再刷新。';
  }

  /// The database entry this page shows, if the list has it.
  Json? get _currentDatabase {
    for (final db in AppState.instance.databases) {
      if ((db['name'] ?? '').toString() == _namespace) return db;
    }
    return null;
  }

  /// True when this page shows the connection's primary (main) file.
  bool get _isPrimaryFile => _currentDatabase?['primary'] == true;

  /// Reveal the database folder in the system file manager.
  Future<void> _revealDatabaseFolder() async {
    final path = AppState.instance.sqliteFolder.isNotEmpty
        ? AppState.instance.sqliteFolder
        : (_currentDatabase?['path'] ?? '').toString();
    await revealDatabasePath(context, widget.notice, path);
  }

  /// Delete the current SQLite database file from disk.
  Future<void> _deleteSqliteFile() async {
    final path = (_currentDatabase?['path'] ?? '').toString();
    if (path.isEmpty) {
      setState(() => _error = '找不到该数据库对应的文件路径');
      return;
    }
    final ok = await confirmDialog(
      context,
      message: '确定删除数据库文件 $path 吗？文件会从磁盘上删除，无法恢复。',
      confirmLabel: '删除文件',
      danger: true,
    );
    if (!ok) return;
    try {
      await Api.instance.sqliteDeleteFile(<String>[path]);
      await AppState.instance.refreshDatabases();
      if (!mounted) return;
      widget.notice.show('数据库文件已删除');
      Navigation.instance.go(AppRoute.connections);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Object categories available on this driver, in tab order.
  ///
  /// SQLite has no stored procedures, functions or scheduled events, so those
  /// tabs are not rendered at all (they used to show a permanent "0").
  List<String> get _objectTabs {
    final tabs = <String>['views'];
    if (isSqlite) {
      if (_objects['triggers'] != null) tabs.add('triggers');
      return tabs;
    }
    if (_objects['routines'] != null) tabs.add('routines');
    if (_objects['triggers'] != null) tabs.add('triggers');
    // PostgreSQL has no scheduled events. The backend still returns an empty
    // `events` array, which used to render a permanent zero-count tab.
    if (!isPostgres && _objects['events'] != null) tabs.add('events');
    return tabs;
  }

  /// Objects the driver filtered out because the account may not use them.
  ///
  /// Round34 P2-03: the panel counted every routine and trigger in the schema
  /// even for a role that could not read the table behind it. The driver now
  /// reports how many it hid, so the counts above can be explained instead of
  /// looking like "this schema has none".
  int get _hiddenObjects => hiddenObjectCount(_objects);

  List<Json> _objectsFor(String tab) {
    final value = _objects[tab];
    if (value is! List) return <Json>[];
    return value
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((o) {
      if (_objectFilter.trim().isEmpty) return true;
      return (o['name'] ?? '')
          .toString()
          .toLowerCase()
          .contains(_objectFilter.trim().toLowerCase());
    }).toList();
  }

  /// MySQL: drop the whole database (the page's namespace is the database).
  Future<void> _dropDatabase() async {
    final ok = await confirmDialog(
      context,
      message: '确定删除数据库 ${widget.db} 吗？该操作不可恢复。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    try {
      await Api.instance.dropDatabase(widget.db);
      AppState.instance.bumpExplorer();
      await _reloadAfterDatabaseDrop();
      if (mounted) {
        final next = AppState.instance.defaultDatabase;
        Navigation.instance.go(
            next != null ? AppRoute.database(next) : AppRoute.connections);
      }
    } catch (e) {
      if (isPermissionError(e)) {
        _learnPermissionFailure(_actionDropDatabase, e);
      } else if (mounted) {
        setState(() => _error = describeDbError(e));
      }
    }
  }

  String? get _activeDatabase => AppState.instance.activeDatabase;

  /// Re-read the instance list after a database disappeared, then make sure the
  /// Rust-side active database still points at something the UI can open.
  Future<void> _reloadAfterDatabaseDrop() async {
    final state = AppState.instance;
    await state.refreshInstanceDatabases();
    final active = state.activeDatabase;
    if (active != null && active.isNotEmpty) {
      try {
        await state.selectDatabase(active);
        return;
      } catch (_) {
        // Fall through to the plain list refresh.
      }
    }
    try {
      await state.refreshDatabases();
    } catch (_) {
      // No accessible database remains; the connection page is the next step.
      state.activeDatabase = null;
      state.notify();
    }
  }

  /// PostgreSQL: create a schema in the active database.
  Future<void> _createSchema() async {
    final name = await promptDialog(
      context,
      title: '新建模式',
      label: '模式名',
      initial: '',
    );
    final trimmed = (name ?? '').trim();
    if (trimmed.isEmpty || !mounted) return;
    final database = _activeDatabase;
    try {
      await Api.instance.createSchema(trimmed);
      widget.notice.show('模式已创建');
      AppState.instance.bumpExplorer();
      await AppState.instance.refreshDatabases();
      if (database != null) {
        Navigation.instance.setSchemas(database, AppState.instance.databases);
      }
      if (!mounted) return;
      Navigation.instance.go(AppRoute.database(trimmed));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// PostgreSQL: DROP SCHEMA ... CASCADE (destructive, explains that).
  Future<void> _dropSchema() async {
    final ok = await confirmDialog(
      context,
      message: '确定删除模式 ${widget.db} 吗？该模式下的所有表、视图和函数都会被删除，且无法恢复。',
      confirmLabel: '删除模式',
      danger: true,
    );
    if (!ok) return;
    final database = _activeDatabase;
    try {
      await Api.instance.dropSchema(widget.db);
      widget.notice.show('模式已删除');
      AppState.instance.bumpExplorer();
      await AppState.instance.refreshDatabases();
      if (database != null) {
        Navigation.instance.setSchemas(database, AppState.instance.databases);
      }
      Navigation.instance.expanded.remove(widget.db);
      final next = AppState.instance.defaultDatabase;
      if (!mounted) return;
      if (next != null) {
        Navigation.instance.go(AppRoute.database(next));
      } else {
        Navigation.instance.go(AppRoute.connections);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// PostgreSQL: drop the physical database this schema belongs to.
  Future<void> _dropActiveDatabase() async {
    final database = _activeDatabase;
    if (database == null || database.isEmpty) {
      setState(() => _error = '当前没有选中的数据库');
      return;
    }
    final ok = await confirmDialog(
      context,
      message: '确定删除数据库 $database 吗？该数据库下的所有模式、表和对象都会被删除，且无法恢复。',
      confirmLabel: '删除数据库',
      danger: true,
    );
    if (!ok) return;
    try {
      await Api.instance.dropDatabase(database);
      widget.notice.show('数据库已删除');
      await _reloadAfterDatabaseDrop();
      if (!mounted) return;
      final next = AppState.instance.defaultDatabase;
      if (next != null) {
        Navigation.instance.go(AppRoute.database(next));
      } else {
        Navigation.instance.go(AppRoute.connections);
      }
    } catch (e) {
      if (isPermissionError(e)) {
        _learnPermissionFailure(_actionDropDatabase, e);
      } else if (mounted) {
        setState(() => _error = describeDbError(e));
      }
    }
  }

  Future<void> _dropTable(String table) async {
    final ok = await confirmDialog(
      context,
      message: '确定删除表 $table 吗？',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    try {
      await Api.instance.dropTable(_namespace, table);
      widget.notice.show('表已删除');
      AppState.instance.bumpExplorer();
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _truncate(String table) async {
    final ok = await confirmDialog(
      context,
      message: '确定清空表 $table 的全部数据吗？',
      confirmLabel: '清空',
      danger: true,
    );
    if (!ok) return;
    try {
      await Api.instance.truncate(_namespace, table);
      widget.notice.show('表已清空');
      await _load();
    } catch (e) {
      if (isPermissionError(e)) {
        _learnPermissionFailure(_actionTruncateTable, e);
      } else if (mounted) {
        setState(() => _error = describeDbError(e));
      }
    }
  }

  Future<void> _dropObject(String kind, String name) async {
    final ok = await confirmDialog(
      context,
      message: '确定删除 $kind $name 吗？',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    try {
      await Api.instance.dropObject(_namespace, kind, name);
      widget.notice.show('对象已删除');
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _showObjectDdl(String kind, String name) async {
    try {
      final res = await Api.instance.objectDefinition(_namespace, kind, name);
      if (!mounted) return;
      await showAppModal(
        context: context,
        title: name,
        wide: true,
        builder: (context) => CodeBlock((res['ddl'] ?? '').toString()),
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  bool get isSqlite => AppState.instance.isSqlite;
  bool get isPostgres => AppState.instance.isPostgres;
  bool get isMysql => AppState.instance.isMysql;

  /// Display name: for SQLite the namespace is `main`, so show the file name.
  String get _title {
    if (!isSqlite) return widget.db;
    for (final db in AppState.instance.databases) {
      if ((db['name'] ?? '').toString() == widget.db) {
        return (db['title'] ?? widget.db).toString();
      }
    }
    return widget.db;
  }

  @override
  Widget build(BuildContext context) {
    return PageScroll(
      padding: const EdgeInsets.all(AppMetrics.mainPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHead(
            titleWidget: Text(_title,
                style: monoStyle(size: 20, weight: FontWeight.w600)),
            meta: [
              Pill('${_tables.length} 张表'),
              if (isPostgres)
                Pill('数据库 ${AppState.instance.activeDatabaseLabel}',
                    tone: PillTone.info),
            ],
            actions: [
              // Refresh re-reads the folder, so a database file added outside
              // the app shows up here.
              Btn(t('refresh'), onPressed: _refresh),
              Btn('新建表',
                  primary: true,
                  tooltip: _denied(_actionCreateTable)
                      ? _deniedTooltip(_actionCreateTable)
                      : null,
                  onPressed: _denied(_actionCreateTable)
                      ? null
                      : () => _showCreateTableDialog()),
              // Round 50: the second way to create tables — from a data file.
              // It goes through the same CREATE TABLE + import pipeline as the
              // import wizard instead of writing SQL by hand.
              Btn('从文件建表',
                  tooltip: '选择 CSV / Excel 等数据文件，按工作表快速建表并导入数据',
                  onPressed:
                      _denied(_actionCreateTable) ? null : _showQuickCreateWizard),
              // Round 50: the place to configure relationships created during an
              // import. The importer's last step opens the same designer seeded
              // with the imported table; this entry reopens it later.
              Btn('关系图',
                  tooltip: '查看并编辑表之间的外键关系',
                  onPressed: _showRelationDesigner),
              if (isSqlite) ...[
                Btn('打开目录', onPressed: _revealDatabaseFolder),
                // The primary file *is* the connection: deleting it would break
                // the connection, so only attached files offer deletion.
                if (!_isPrimaryFile)
                  Btn('删除数据库文件',
                      danger: true, onPressed: _deleteSqliteFile),
              ] else if (isPostgres) ...[
                Btn('新建模式', onPressed: _createSchema),
                Btn('删除模式', danger: true, onPressed: _dropSchema),
                Btn('删除数据库',
                    danger: true,
                    tooltip: _denied(_actionDropDatabase)
                        ? _deniedTooltip(_actionDropDatabase)
                        : null,
                    onPressed: _denied(_actionDropDatabase)
                        ? null
                        : _dropActiveDatabase),
              ] else
                Btn('删除数据库',
                    danger: true,
                    tooltip: _denied(_actionDropDatabase)
                        ? _deniedTooltip(_actionDropDatabase)
                        : null,
                    onPressed: _denied(_actionDropDatabase)
                        ? null
                        : _dropDatabase),
            ],
          ),
          if (!isSqlite)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 8),
              child: Text(
                isPostgres
                    ? '数据库 ${AppState.instance.activeDatabaseLabel}'
                        ' · 默认 schema ${AppState.instance.defaultSchemaLabel}'
                    : '数据库 ${AppState.instance.activeDatabaseLabel}',
                style: kSmallMuted,
              ),
            ),
          if (_error != null) AlertBox(_error!),
          if (!isSqlite && _deniedActions.isNotEmpty) _deniedActionsNotice(),
          if (isSqlite && !AppState.instance.sqliteFolderExists)
            AlertBox(
              '数据库目录不存在（可能已被移动、删除，或磁盘未挂载）：'
              '${AppState.instance.sqliteFolder}',
              tone: AlertTone.error,
            ),
          if (isSqlite && !AppState.instance.sqlitePrimaryExists)
            AlertBox(
              pickText(
                '主数据库文件不存在：${AppState.instance.sqlitePrimary}\n'
                '请在连接管理里重新选择数据库文件，或删除该连接。',
                'The primary database file does not exist: '
                '${AppState.instance.sqlitePrimary}\n'
                'Pick another database file in connection management, or delete '
                'this connection.',
              ),
              tone: AlertTone.error,
            ),
          if (isSqlite && AppState.instance.sqliteCorrupt.isNotEmpty)
            AlertBox(_unreadableText(), tone: AlertTone.error),
          if (isSqlite && AppState.instance.sqliteOverflow.isNotEmpty)
            AlertBox(_overflowText(), tone: AlertTone.info),
          NoticeBanner(widget.notice),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            _tablesCard(),
            _objectsCard(),
          ],
        ],
      ),
    );
  }

  Widget _tablesCard() {
    final page = clampPage(_tablePage, _tables.length, kDbTablePageSize);
    final pageRows = pageSlice(_tables, page, kDbTablePageSize);
    return CardBox(
      title: '数据表',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GridTable(
            // SQLite has no storage engine and no per-table collation, so those
            // columns would be empty for every row.
            headers: [
              const Text('表名'),
              const Text('类型'),
              // MySQL reports a storage engine and a table collation; PostgreSQL
              // has neither (its per-column collations live on the structure tab)
              // but does have tablespaces. Only render what the driver can fill.
              if (isMysql) const Text('引擎'),
              if (isPostgres) const Text('表空间'),
              Tooltip(
                // N-12: SQLite's row count comes from COUNT(*), which is exact;
                // calling it an estimate was misleading. MySQL/PG expose server
                // statistics, which really are estimates.
                message: AppState.instance.isSqlite
                    ? (I18n.current == AppLang.en
                        ? 'Exact COUNT(*) for SQLite.'
                        : 'SQLite 使用 COUNT(*)，该列是精确值。')
                    : (I18n.current == AppLang.en
                        ? 'Server statistics; may differ from the live count in Browse.'
                        : '服务端统计值；可能与浏览页的实时行数不同。'),
                child: Text(AppState.instance.isSqlite
                    ? (I18n.current == AppLang.en ? 'Rows (exact)' : '行数（精确）')
                    : (I18n.current == AppLang.en ? 'Rows (estimate)' : '行数（估算）')),
              ),
              if (isSqlite)
                Tooltip(
                  // Round34 P3-03: SQLite keeps every table in one file, so the
                  // column needs to say which of the two sizes it is showing.
                  message: I18n.current == AppLang.en
                      ? 'SQLite stores the whole database in one file. The table '
                          '(its index pages included) is measured when the driver '
                          'can; otherwise this is the file-level size, not a '
                          'per-table estimate.'
                      : 'SQLite 把整个数据库存在一个文件里。可按表统计时显示该表'
                          '（含索引）占用的页数；否则显示文件级大小，不按表估算。',
                  child: const Text('大小'),
                )
              else
                const Text('大小'),
              if (isMysql) const Text('排序规则'),
              const Text('备注'),
              const Text('操作'),
            ],
            emptyText: '（无）',
            maxHeight: 360,
            rows: [
              for (final table in pageRows)
                TableRow(
                  children: [
                    InkWell(
                      onTap: () => Navigation.instance
                          .go(AppRoute.tableRoute(_namespace, table['name'].toString())),
                      child: gridCell(table['name'], mono: true, title: table['name']?.toString()),
                    ),
                    gridCell(table['type']),
                    if (isMysql) gridCell(table['engine']),
                    if (isPostgres)
                      gridCell(
                          (table['tablespace'] ?? '').toString().isEmpty
                              ? '—'
                              : table['tablespace'],
                          mono: true),
                    tableRowCountCell(table,
                        driver: AppState.instance.driver),
                    _sizeCell(table),
                    if (isMysql) gridCell(table['collation'], mono: true),
                    gridCell(table['comment']),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      child: Row(
                        children: [
                          if ((table['type'] ?? '').toString() == 'BASE TABLE')
                            Btn('清空',
                                small: true,
                                tooltip: _denied(_actionTruncateTable)
                                    ? _deniedTooltip(_actionTruncateTable)
                                    : null,
                                onPressed: _denied(_actionTruncateTable)
                                    ? null
                                    : () => _truncate(table['name'].toString())),
                          const SizedBox(width: 4),
                          Btn('删除',
                              small: true,
                              danger: true,
                              onPressed: () => _dropTable(table['name'].toString())),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),
          if (_tables.isNotEmpty)
            TablePager(
              page: page,
              pages: pageCountFor(_tables.length, kDbTablePageSize),
              total: _tables.length,
              visible: pageRows.length,
              onPage: (next) => setState(() => _tablePage = next),
              keyPrefix: 'db-tables',
            ),
        ],
      ),
    );
  }

  /// The 大小 cell of one table row (see [tableSizeLabel]).
  Widget _sizeCell(Json table) => gridCell(tableSizeLabel(table));

  Widget _objectsCard() {
    final current = _objectsFor(_objectTab);
    final total = _objectTabs
        .map((tab) => _objectsFor(tab).length)
        .fold<int>(0, (a, b) => a + b);
    final page = clampPage(_objectPage, current.length, kDbTablePageSize);
    final pageRows = pageSlice(current, page, kDbTablePageSize);
    return CardBox(
      title: '对象',
      actions: [
        Pill(total.toString()),
        SizedBox(
          width: 160,
          child: Field(
            label: '',
            hint: t('search'),
            onChanged: (v) => setState(() {
              _objectFilter = v;
              // A narrower list can be shorter than the page being shown.
              _objectPage = 1;
            }),
          ),
        ),
        Btn(t('refresh'), small: true, onPressed: _load),
        Btn('新建对象',
            small: true, primary: true, onPressed: _showObjectEditor),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 2,
            children: [
              for (final tab in _objectTabs) _objectTabButton(tab),
            ],
          ),
          if (_hiddenObjects > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                I18n.current == AppLang.en
                    ? '$_hiddenObjects object(s) are hidden: the current '
                        'account has no privilege on them.'
                    : '已按权限隐藏 $_hiddenObjects 个对象（当前账号无对应权限）。',
                style: kSmallMuted,
              ),
            ),
          const SizedBox(height: 10),
          GridTable(
            headers: const [
              Text('名称'),
              Text('类型'),
              Text('详情'),
              Text('操作'),
            ],
            emptyText: _objectFilter.isEmpty ? '（无）' : '无匹配对象',
            maxHeight: 300,
            rows: [
              for (final object in pageRows)
                TableRow(
                  children: [
                    gridCell(object['name'], mono: true),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                      child: Pill(_objectKind(object)),
                    ),
                    gridCell(_objectDetail(object)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      child: Row(
                        children: [
                          Btn('查看 DDL',
                              small: true,
                              onPressed: () => _showObjectDdl(
                                  _objectKind(object), object['name'].toString())),
                          const SizedBox(width: 4),
                          Btn('删除',
                              small: true,
                              danger: true,
                              onPressed: () => _dropObject(
                                  _objectKind(object), object['name'].toString())),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),
          if (current.isNotEmpty)
            TablePager(
              page: page,
              pages: pageCountFor(current.length, kDbTablePageSize),
              total: current.length,
              visible: pageRows.length,
              onPage: (next) => setState(() => _objectPage = next),
              keyPrefix: 'db-objects',
              unit: '项',
            ),
        ],
      ),
    );
  }

  Widget _objectTabButton(String tab) {
    final active = _objectTab == tab;
    return GestureDetector(
      onTap: () => setState(() {
        _objectTab = tab;
        // Each tab is its own list: page 3 of 视图 must not become page 3 of
        // 触发器.
        _objectPage = 1;
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
        decoration: BoxDecoration(
          color: active ? AppColors.panel : Colors.transparent,
          border: Border.all(
              color: active ? AppColors.border : Colors.transparent),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(5),
            topRight: Radius.circular(5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_tabLabel(tab),
                style: TextStyle(
                  fontSize: 13,
                  color: active ? AppColors.bodyText : AppColors.muted,
                  fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                )),
            const SizedBox(width: 5),
            Pill(_objectsFor(tab).length.toString()),
          ],
        ),
      ),
    );
  }

  String _tabLabel(String tab) {
    switch (tab) {
      case 'views':
        return '视图';
      case 'routines':
        return '存储过程 / 函数';
      case 'triggers':
        return '触发器';
      case 'events':
        return '事件';
    }
    return tab;
  }

  String _objectKind(Json object) {
    final explicit = (object['kind'] ?? '').toString();
    if (explicit.isNotEmpty) return explicit;
    final type = (object['type'] ?? '').toString().toUpperCase();
    if (type.contains('PROCEDURE')) return 'procedure';
    if (type.contains('FUNCTION')) return 'function';
    if (type.contains('TRIGGER')) return 'trigger';
    if (type.contains('EVENT')) return 'event';
    return 'view';
  }

  /// Join the non-empty descriptive fields the way the web view did.
  String _objectDetail(Json object) {
    final parts = <String>[];
    for (final key in [
      'table',
      'timing',
      'event',
      'returns',
      'definer',
      'updatable',
    ]) {
      final value = object[key];
      if (value != null && value.toString().isNotEmpty) {
        parts.add(value.toString());
      }
    }
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  /// Minimal object editor: pick a kind, name it, and edit a starter template.
  Future<void> _showObjectEditor() async {
    final kinds = <String>['view'];
    if (AppState.instance.isMysql) {
      kinds.addAll(['procedure', 'function', 'trigger', 'event']);
    } else if (AppState.instance.isPostgres) {
      kinds.addAll(['procedure', 'function', 'trigger']);
    } else {
      kinds.add('trigger');
    }
    var kind = kinds.first;
    final name = TextEditingController();
    final sql = TextEditingController(text: _objectTemplate(kind));
    String? error;

    await showAppModal(
      context: context,
      title: '新建对象',
      wide: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModal) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FormRow(
              label: '类型',
              child: SelectBox<String>(
                value: kind,
                onChanged: (v) {
                  kind = v ?? 'view';
                  sql.text = _objectTemplate(kind);
                  setModal(() {});
                },
                items: [
                  for (final k in kinds)
                    DropdownMenuItem(value: k, child: Text(k)),
                ],
              ),
            ),
            Field(label: t('name'), controller: name, hint: 'my_object'),
            TextField(
              controller: sql,
              maxLines: 12,
              style: monoStyle(size: 12),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              AlertBox(error!),
            ],
          ],
        ),
      ),
      actions: [
        Builder(
          builder: (context) => Btn(t('cancel'),
              onPressed: () => Navigator.of(context).pop()),
        ),
        Builder(
          builder: (context) => Btn('保存', primary: true, onPressed: () async {
            try {
              await Api.instance.createObject(_namespace, sql.text);
              if (context.mounted) Navigator.of(context).pop();
              widget.notice.show('对象已保存');
              await _load();
            } catch (e) {
              if (context.mounted) {
                setState(() {});
                error = e.toString();
              }
            }
          }),
        ),
      ],
    );
  }

  /// Starter SQL per object kind, quoting identifiers for the active driver.
  String _objectTemplate(String kind) {
    final q = AppState.instance.quoteIdent;
    switch (kind) {
      case 'view':
        return 'CREATE VIEW ${q('v_my_view')} AS\nSELECT 1 AS id;';
      case 'procedure':
        return 'CREATE PROCEDURE ${q('my_procedure')}()\nBEGIN\n  SELECT 1;\nEND;';
      case 'function':
        return 'CREATE FUNCTION ${q('my_function')}() RETURNS INT\nBEGIN\n  RETURN 1;\nEND;';
      case 'trigger':
        return 'CREATE TRIGGER ${q('my_trigger')}\nBEFORE INSERT ON ${q('my_table')}\nFOR EACH ROW\nBEGIN\n  SET @x = 1;\nEND;';
      case 'event':
        // Deliberately inert: an event template must not delete data.
        return 'CREATE EVENT ${q('my_event')}\nON SCHEDULE EVERY 1 DAY\nDO SET @rma_event_tick = NOW();';
    }
    return '';
  }

  /// Create-table designer (the full one: table options, columns, foreign
  /// keys and a live DDL preview). It used to be a single-field form here, which
  /// left most of the create-table feature set unreachable.
  Future<void> _showCreateTableDialog() async {
    final created = await showCreateTableDialog(
      context,
      database: _namespace,
      // The dialog owns its error banner; this lets the page learn a permission
      // denial so the button can be greyed out instead of failing again (P12).
      onError: (error) {
        if (isPermissionError(error)) {
          _learnPermissionFailure(_actionCreateTable, error);
        }
      },
      // The title-bar entry closes the designer and hands over to the wizard.
      onQuickCreate: _showQuickCreateWizard,
    );
    if (!created || !mounted) return;
    widget.notice.show('表已创建');
    AppState.instance.bumpExplorer();
    await _load();
  }

  /// 从文件建表（第 50 轮）：选择数据文件 → 工作表与字段 → 建表并导入 → 建立关联。
  ///
  /// The wizard shows its own success toast ("已创建 N 张表") because it alone
  /// knows the final count; this page only refreshes the table list afterwards.
  Future<void> _showQuickCreateWizard() async {
    final created = await showQuickCreateTableWizard(
      context,
      database: _namespace,
      notice: widget.notice,
    );
    if (!created || !mounted) return;
    AppState.instance.bumpExplorer();
    await _load();
  }

  /// 打开独立的 E-R 关系设计器，用于稍后继续配置导入时建立/遗漏的外键。
  Future<void> _showRelationDesigner() async {
    await showRelationDesigner(
      context,
      database: _namespace,
      notice: widget.notice,
      onChanged: () async {
        AppState.instance.bumpExplorer();
        await _load();
      },
    );
  }
}
/// Text of the 大小 cell for one table row.
///
/// Round34 P3-03: the column was a bare "—" for every SQLite table. The driver
/// returns `data_length` when it measured the table (and its index pages) with
/// `dbstat`; otherwise it reports the whole database file with
/// `size_scope: "file"`, and the label says so instead of pretending the table
/// has no size. A view has neither number and keeps the dash.
String tableSizeLabel(Json table) {
  final bytes = (table['data_length'] as num?)?.toInt();
  if (bytes != null) {
    return formatBytes(bytes + ((table['index_length'] as num?)?.toInt() ?? 0));
  }
  final scope = (table['size_scope'] ?? '').toString();
  final fileSize = (table['file_size'] as num?)?.toInt();
  if (scope == 'file' && fileSize != null && fileSize > 0) {
    return I18n.current == AppLang.en
        ? 'File-level · ${formatBytes(fileSize)}'
        : '文件级 · ${formatBytes(fileSize)}';
  }
  return '—';
}

/// Text of the 行数 cell for one table row.
///
/// MySQL's TABLE_ROWS and PostgreSQL's n_live_tup are server statistics, so the
/// header calls them estimates; the cell marks them with "≈" as well. The value
/// that must not look exact is InnoDB's 0 for a table that already has storage
/// pages allocated: the statistics are stale (or the table really is empty), so
/// the cell says so instead of passing the 0 off as a precise count.
String tableRowCountLabel(Json table, {required String driver}) {
  final count = (table['row_count'] as num?)?.toInt();
  if (count == null) return '';
  if (driver == 'sqlite') return count.toString();
  if (driver == 'mysql' && count == 0 && _dataLengthOf(table) > 0) {
    return pickText('0（统计可能过期）', '0 (statistics may be stale)');
  }
  return '≈$count';
}

/// Hover explanation for the 行数 cell; null when the plain value says enough.
String? tableRowCountTooltip(Json table, {required String driver}) {
  if (driver != 'mysql') return null;
  final count = (table['row_count'] as num?)?.toInt();
  if (count != 0 || _dataLengthOf(table) <= 0) return null;
  return pickText(
    '服务端统计（TABLE_ROWS）显示 0 行，但该表已分配存储空间：统计可能过期，'
        '也可能确实是空表。打开表页可看到浏览时的精确行数；'
        '也可以在 SQL 控制台执行 ANALYZE TABLE 刷新统计。',
    'Server statistics (TABLE_ROWS) report 0 rows, but the table has storage '
        'allocated: the statistics may be stale, or the table really is empty. '
        'Open the table page for the exact count while browsing, or run '
        'ANALYZE TABLE in the SQL console to refresh them.',
  );
}

/// The 行数 cell of one table row (see [tableRowCountLabel]).
///
/// The tooltip is attached explicitly (not through [gridCell]'s overflow-only
/// hover) so the stale-statistics explanation is always reachable.
Widget tableRowCountCell(Json table, {required String driver}) {
  final cell = gridCell(tableRowCountLabel(table, driver: driver));
  final tooltip = tableRowCountTooltip(table, driver: driver);
  return tooltip == null ? cell : Tooltip(message: tooltip, child: cell);
}

int _dataLengthOf(Json table) =>
    (table['data_length'] as num?)?.toInt() ?? 0;

/// Number of objects the driver hid from the object panel (round34 P2-03).
///
/// The driver reports the count it filtered out, so the tab counters can be
/// explained instead of looking like the schema really has none.
int hiddenObjectCount(Json objects) {
  final hidden = objects['hidden'];
  if (hidden is! Map) return 0;
  return hidden.values
      .map((v) => v is num ? v.toInt() : 0)
      .fold<int>(0, (a, b) => a + b);
}