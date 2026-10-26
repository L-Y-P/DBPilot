import 'package:flutter/material.dart' hide Text, Tooltip;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'text.dart';
import 'tooltip.dart';

import 'api.dart';
import 'app_state.dart';
import 'db_actions.dart';
import 'i18n.dart';
import 'i18n_literals.dart';
import 'nav.dart';
import 'notice.dart';
import 'settings_channel.dart';
import 'sqlite_actions.dart';
import 'theme.dart';
import 'widgets.dart';
import 'views/backups_view.dart';
import 'views/builder_view.dart';
import 'views/connections_view.dart';
import 'views/database_view.dart';
import 'views/history_view.dart';
import 'views/server_view.dart';
import 'views/settings_dialog.dart';
import 'views/sql_view.dart';
import 'views/sync_view.dart';
import 'views/table_view.dart';

/// The application shell: topbar, database sidebar and the active view.
///
/// This is the direct analogue of the web Layout.vue. The web version also
/// rendered a login/setup flow and a user menu; those are gone because the
/// desktop app has no accounts. The Tools menu keeps Backups / Schema sync /
/// History, which are real features, and drops User management.
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  final Notice _notice = Notice();

  @override
  void initState() {
    super.initState();
    AppState.instance.addListener(_onState);
    Navigation.instance.addListener(_onState);
    I18n.lang.addListener(_onState);
    settingsOpenRequests.addListener(_onSettingsRequested);
  }

  @override
  void dispose() {
    settingsOpenRequests.removeListener(_onSettingsRequested);
    AppState.instance.removeListener(_onState);
    Navigation.instance.removeListener(_onState);
    I18n.lang.removeListener(_onState);
    _notice.dispose();
    super.dispose();
  }

  /// The native "Preferences…" menu item (Cmd+,) asks for the settings dialog.
  ///
  /// The call can land while the frame is being built, so it is deferred to
  /// after the frame; [_openSettings] then ignores it while another modal is
  /// already on top.
  void _onSettingsRequested() {
    // A platform message arrives between frames, so the dialog can be opened
    // right away; a post-frame callback would only run once something else
    // scheduled a frame, which nothing does when the app is idle.
    if (!mounted) return;
    _openSettings();
  }

  void _onState() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    if (!state.bootstrapped) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (state.bootstrapError != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 48, color: AppColors.danger),
                const SizedBox(height: 12),
                SelectableText(trLiteral(state.bootstrapError!)),
              ],
            ),
          ),
        ),
      );
    }

    final route = Navigation.instance.route;
    final wide = MediaQuery.of(context).size.width > 900;
    return CallbackShortcuts(
      // P3-05: the gear used to be mouse-only. Cmd+, is the conventional
      // "open preferences" chord on macOS and Ctrl+, covers Windows/Linux,
      // so the settings dialog is reachable from the keyboard and from
      // automation that can send key events but not target the focused
      // button. Bindings only fire while the shell owns the focus, so they
      // cannot open a second dialog on top of an open modal route.
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.comma, meta: true):
            _openSettings,
        const SingleActivator(LogicalKeyboardKey.comma, control: true):
            _openSettings,
      },
      // Shortcut dispatch walks up from the primary focus, so the shell needs
      // a focused descendant of its own: a bare window with nothing focused
      // (no text field clicked yet) would otherwise never reach the binding.
      // autofocus only claims focus on the first frame, so clicking into a
      // field still moves focus normally.
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Column(
            children: [
              _Topbar(notice: _notice),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (wide) _Sidebar(notice: _notice),
                    Expanded(child: _viewFor(route, _notice)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Open the settings dialog, unless another route is already on top.
  ///
  /// Used by the Cmd+, / Ctrl+, binding (P3-05). [ModalRoute.isCurrent] is
  /// false while a dialog is open, so a repeated chord cannot stack dialogs.
  void _openSettings() {
    if (!mounted) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    showSettingsDialog(context);
  }

  Widget _viewFor(AppRoute route, Notice notice) {
    // A persisted route (or a page left open while the active connection was
    // deleted) must never render database views against a dead session. The
    // sidebar and topbar already say "未连接"; make the content area agree and
    // give the user one obvious way back.
    if (route.needsConnection && !AppState.instance.connected) {
      return const _DisconnectedView();
    }
    switch (route.section) {
      case 'connections':
        return ConnectionsView(notice: notice);
      case 'database':
        return DatabaseView(db: route.db!, notice: notice);
      case 'table':
        return TableView(db: route.db!, table: route.table!, notice: notice);
      case 'builder':
        return BuilderView(notice: notice);
      case 'sql':
        return SqlView(notice: notice);
      case 'server':
        return ServerView(notice: notice);
      case 'backups':
        return BackupsView(notice: notice);
      case 'sync':
        return SyncView(notice: notice);
      case 'history':
        return HistoryView(notice: notice);
      default:
        return ConnectionsView(notice: notice);
    }
  }
}

/// Content area shown for database routes while no connection is open.
///
/// The sidebar has its own small empty state; this one exists because a route
/// can outlive the connection (delete active connection, failed reconnect) and
/// rendering a stale SQL/server page against it is worse than one clear action.
class _DisconnectedView extends StatelessWidget {
  const _DisconnectedView();

  @override
  Widget build(BuildContext context) {
    return PageScroll(
      padding: const EdgeInsets.all(AppMetrics.mainPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHead(title: trLiteral('未连接数据库')),
          CardBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  trLiteral('当前没有打开的数据库连接。这个页面需要先连接数据库。'),
                  style: TextStyle(fontSize: 13, color: AppColors.muted),
                ),
                const SizedBox(height: 14),
                Btn('前往连接管理',
                    primary: true,
                    onPressed: () =>
                        Navigation.instance.go(AppRoute.connections)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 48px gradient bar with brand, connection badges, nav links and language
/// switch. Mirrors the web .topbar; the account badge and logout link are gone
/// because there is no user system.
class _Topbar extends StatefulWidget {
  const _Topbar({required this.notice});
  final Notice notice;

  @override
  State<_Topbar> createState() => _TopbarState();
}

class _TopbarState extends State<_Topbar> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _menu;

  @override
  void dispose() {
    _menu?.remove();
    super.dispose();
  }

  void _toggleMenu() {
    if (_menu != null) {
      _closeMenu();
      return;
    }
    final overlay = Overlay.of(context);
    _menu = OverlayEntry(
      builder: (context) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _closeMenu,
              child: const SizedBox.expand(),
            ),
          ),
          CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            offset: const Offset(-140, 34),
            child: Material(
              color: Colors.transparent,
              child: _ToolsMenu(
                  onPick: _closeMenu,
                  connected: AppState.instance.connected),
            ),
          ),
        ],
      ),
    );
    overlay.insert(_menu!);
    setState(() {});
  }

  void _closeMenu() {
    _menu?.remove();
    _menu = null;
    if (mounted) setState(() {});
  }

  /// Widest the connection info area may grow.
  ///
  /// Longer connection labels / account names are ellipsized and shown in full
  /// by a hover tooltip; the nav group keeps its distance from the right edge
  /// independent of the label length.
  static const double _topbarInfoMaxWidth = 560;

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final nav = Navigation.instance;
    final route = nav.route;
    final connected = state.connected;

    return Container(
      height: AppMetrics.topbarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        gradient: AppColors.topbarGradient,
        border: Border(bottom: BorderSide(color: AppColors.header2)),
      ),
      child: Row(
        children: [
          // Brand
          Text('*',
              style: TextStyle(
                  color: AppColors.accent,
                  fontSize: 16,
                  fontWeight: FontWeight.w700)),
          const SizedBox(width: 6),
          Text(
            state.title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(width: 14),

          // Connection info.
          //
          // This used to be a horizontally scrolling strip followed by a
          // Spacer. Both are flex children, so Flutter split the free space
          // between them; the strip did not use its half and the nav group
          // ended up far from the right edge on wide windows (the wider the
          // window, the larger the gap). The info area now claims the leftover
          // space itself and truncates long names, so the nav group is always
          // flush against the right padding.
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final infoWidth =
                    constraints.maxWidth.clamp(0.0, _topbarInfoMaxWidth);
                return Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: infoWidth,
                    child: _connectionInfo(state, maxWidth: infoWidth),
                  ),
                );
              },
            ),
          ),

          // Nav links
          _navLink('连接管理', AppRoute.connections, route.section == 'connections'),
          _navLink('查询构建器', AppRoute.builder,
              route.section == 'builder', enabled: connected),
          _navLink('SQL 控制台', AppRoute.sql, route.section == 'sql',
              enabled: connected),
          _navLink('服务器', AppRoute.server, route.section == 'server',
              enabled: connected),
          CompositedTransformTarget(
            link: _link,
            child: _navLink('工具 v', null, _menu != null, onTap: _toggleMenu),
          ),

          // Settings: language, appearance, backups, updates and the version
          // all moved into one dialog, replacing the old 中文 / EN pair.
          const SizedBox(width: 8),
          _settingsButton(),
        ],
      ),
    );
  }

  Widget _badge(String text, {required Color bg}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0xFF54688C)),
        ),
        child: Text(text,
            style: const TextStyle(fontSize: 11, color: Color(0xFFE6EEFC))),
      );

  /// Driver badge + connection label + database account for the topbar.
  ///
  /// Both texts are limited to one line and ellipsized, and each carries a
  /// tooltip with the full value (hover on desktop). A long connection name or
  /// account therefore cannot push the nav buttons away from the right edge.
  Widget _connectionInfo(AppState state, {required double maxWidth}) {
    if (!state.connected) {
      return Text(
        trLiteral('未连接数据库'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: AppColors.topbarMeta),
      );
    }
    final label = state.connectionLabel;
    final account = state.dbAccount.isNotEmpty ? '@${state.dbAccount}' : '';
    // Very narrow topbars cannot fit the badge without squeezing the label into
    // nothing; the label is the part carrying the information, so drop it.
    final showBadge = maxWidth >= 220;
    return Row(
      mainAxisSize: MainAxisSize.max,
      children: [
        if (showBadge) ...[
          _badge(state.driverLabel, bg: const Color(0xFF3B4D6B)),
          const SizedBox(width: 6),
        ],
        Flexible(
          flex: 3,
          child: Tooltip(
            message: label,
            constraints: kTooltipConstraints,
            waitDuration: const Duration(milliseconds: 300),
            child: Text(
              label,
              key: const ValueKey('topbar-connection'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(size: 12, color: AppColors.topbarMeta),
            ),
          ),
        ),
        // The database account decides what the server page can do, so surface
        // it next to the connection rather than only inside the banner.
        if (account.isNotEmpty) ...[
          const SizedBox(width: 6),
          Flexible(
            flex: 2,
            child: Tooltip(
              message: account,
              constraints: kTooltipConstraints,
              waitDuration: const Duration(milliseconds: 300),
              child: Text(
                account,
                key: const ValueKey('topbar-account'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: monoStyle(size: 11, color: AppColors.topbarMeta),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _navLink(String label, AppRoute? target, bool active,
      {bool enabled = true, VoidCallback? onTap}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: enabled ? (onTap ?? () => Navigation.instance.go(target!)) : null,
          child: Opacity(
            opacity: enabled ? 1 : 0.45,
            child: Text(
              trLiteral(label),
              style: TextStyle(
                fontSize: 13,
                color: active ? Colors.white : AppColors.topbarLink,
                fontWeight: active ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Gear button that opens the settings dialog.
  ///
  /// It replaces the old 中文 / EN toggle: the language picker now lives in the
  /// dialog next to appearance, the backup directory, the update check and the
  /// application version, so the topbar has one entry point instead of two
  /// buttons that only covered a single preference.
  Widget _settingsButton() {
    void open() => showSettingsDialog(context);
    return Padding(
      key: const ValueKey('topbar-settings'),
      padding: const EdgeInsets.only(left: 4),
      // P3-05: the gear is a plain Container + GestureDetector, so the macOS
      // AX tree only saw a hover tooltip — no button role, no label, and an
      // AX press resolved to "unverifiable". An explicit Semantics node gives
      // it the AXButton role, a localised label and a press action, which is
      // also what lets automation invoke it in the background. The label goes
      // through trLiteral like every other rendered string, so English mode
      // announces "Settings".
      child: Semantics(
        button: true,
        label: trLiteral('设置'),
        onTap: open,
        child: Tooltip(
          message: '设置',
          child: GestureDetector(
            onTap: open,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.logoutBorder),
                borderRadius: BorderRadius.circular(AppMetrics.radiusControl),
              ),
              child: Icon(Icons.settings_outlined,
                  size: 15, color: AppColors.topbarLink),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolsMenu extends StatelessWidget {
  const _ToolsMenu({required this.onPick, required this.connected});
  final VoidCallback onPick;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 190,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(6),
        boxShadow: const [
          BoxShadow(
            color: Color(0x2E0F1C2E),
            blurRadius: 30,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _item('备份', AppRoute.backups, enabled: connected),
          _item('结构同步', AppRoute.sync, enabled: connected),
          _item('历史记录', AppRoute.history),
        ],
      ),
    );
  }

  Widget _item(String label, AppRoute? route,
      {VoidCallback? onTap, bool enabled = true}) {
    return InkWell(
      onTap: enabled
          ? () {
              if (onTap != null) {
                onTap();
              } else {
                Navigation.instance.go(route!);
              }
              onPick();
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Text(trLiteral(label), style: const TextStyle(fontSize: 13)),
        ),
      ),
    );
  }

}

/// 268px database tree. Mirrors the web .sidebar: a head row with refresh and
/// new-database buttons, then expandable database nodes with their tables.
class _Sidebar extends StatefulWidget {
  const _Sidebar({required this.notice});
  final Notice notice;

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  bool _loading = false;
  String? _error;

  /// Namespaces whose table list is already being fetched.
  final Set<String> _loadingTables = <String>{};

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    final nav = Navigation.instance;
    final route = nav.route;

    // 惰性节点列表：每个元素只描述"怎么建这一行"，不会创建 Widget。
    final nodes = state.connected
        ? _databaseNodes(state, nav, route)
        : <Widget Function()>[];

    // A route can mark a namespace expanded without the tree having fetched its
    // tables (for example the connect flow lands on DatabaseView.public). Load
    // any such missing list, once.
    if (state.connected && !state.isSqlite) {
      for (final namespace in nav.expanded.toList()) {
        if (!nav.tablesByDb.containsKey(namespace) &&
            !_loadingTables.contains(namespace)) {
          _loadingTables.add(namespace);
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            try {
              await _loadTables(namespace);
            } finally {
              _loadingTables.remove(namespace);
            }
          });
        }
      }
    }

    return Container(
      width: AppMetrics.sidebarWidth,
      decoration: BoxDecoration(
        color: AppColors.sidebar,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    // The first level is always the instance's databases; a
                    // PostgreSQL database expands into its schemas.
                    trLiteral('数据库'),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                      color: AppColors.sidebarHead,
                    ),
                  ),
                ),
                if (state.connected) ...[
                  IconBtn(Icons.refresh,
                      key: const ValueKey('sidebar-refresh'),
                      tooltip: '刷新',
                      small: true,
                      onPressed: _loading ? null : () => _refresh(force: true)),
                  const SizedBox(width: 4),
                  if (state.isSqlite || state.can('database'))
                    Btn('+',
                        small: true,
                        tooltip: state.isSqlite
                            ? '新建 / 导入数据库文件'
                            : '新建数据库',
                        onPressed: () =>
                            showNewDatabase(context, widget.notice))
                  else
                    Btn('+',
                        small: true,
                        tooltip: '当前账号没有建库权限（需要 CREATEDB / 全局 CREATE）',
                        onPressed: null),
                ],
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: AlertBox(_error!, onClose: () => setState(() => _error = null)),
            ),
          Expanded(
            child: !state.connected
                ? _emptyState()
                // 节点按需构建：5000 张表的库有 5000 个表行，一次性建成 Widget
                // 会让展开卡住数秒（每个 EllipsisText 还要在 post-frame 里测量
                // 是否溢出）。这里只收集"怎么建这一行"的构建器（闭包很便宜），
                // ListView.builder 只对可见的行调用它们。
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: nodes.length,
                    itemBuilder: (context, index) => nodes[index](),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(trLiteral('未连接数据库'),
              style: TextStyle(fontSize: 13, color: AppColors.muted)),
          const SizedBox(height: 8),
          Btn('前往连接管理',
              small: true,
              onPressed: () => Navigation.instance.go(AppRoute.connections)),
        ],
      ),
    );
  }

  /// 侧边栏每一行的构建器。
  ///
  /// 返回的是 [Widget Function()] 而不是 Widget：数据库可能有 5000 张表，
  /// 一次性把它们都建成 Widget 会在展开时卡住数秒。ListView.builder 只会对
  /// 可见的行调用构建器，其余行连 Widget 都不会创建。
  List<Widget Function()> _databaseNodes(
      AppState state, Navigation nav, AppRoute route) {
    if (state.isSqlite) return _sqliteNodes(state, nav, route);
    if (state.isPostgres) return _postgresNodes(state, nav, route);
    return _flatDatabaseNodes(state, nav, route);
  }

  Widget _treeMessage(String text, {double indent = 26}) => Padding(
        padding: EdgeInsets.fromLTRB(indent, 2, 8, 6),
        child: Text(trLiteral(text),
            style: TextStyle(fontSize: 12, color: AppColors.muted)),
      );

  Widget _treeError(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(26, 2, 8, 6),
        child: Tooltip(
          message: tooltipText(text),
          constraints: kTooltipConstraints,
          waitDuration: const Duration(milliseconds: 300),
          child: Text(text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: AppColors.danger)),
        ),
      );

  /// MySQL / MariaDB: a flat database list, each database with its tables.
  List<Widget Function()> _flatDatabaseNodes(
      AppState state, Navigation nav, AppRoute route) {
    final databases = (state.instanceDatabases.isNotEmpty
            ? state.instanceDatabases
            : state.databases)
        .where((db) =>
            !state.isDatabaseDenied((db['name'] ?? '').toString()))
        .toList();
    if (databases.isEmpty) {
      return [
        () => _treeMessage(state.instanceDatabasesLoading ||
                state.databasesLoading
            ? '连接中…'
            : '（无数据库）'),
      ];
    }
    final nodes = <Widget Function()>[];
    for (final db in databases) {
      final name = (db['name'] ?? '').toString();
      if (name.isEmpty) continue;
      final active = state.activeDatabase == name || route.db == name;
      final expanded = nav.expanded.contains(name);
      nodes.add(() => ContextMenuRegion(
            entries: databaseMenuEntries(
              context,
              name,
              notice: widget.notice,
              onChanged: () => _loadTables(name, force: true),
            ),
            child: _dbRow(
              name,
              name,
              active,
              expanded,
              onOpen: () => _openMySQLDatabase(name),
              onToggle: () => _toggleMySQLDatabase(name),
            ),
          ));
      if (expanded) {
        nodes.addAll(_tableRows(name, nav, route));
      }
    }
    return nodes;
  }

  Future<void> _openMySQLDatabase(String name) async {
    try {
      if (AppState.instance.activeDatabase != name) {
        await AppState.instance.selectDatabase(name);
      }
      Navigation.instance.go(AppRoute.database(name));
      if (!Navigation.instance.expanded.contains(name)) {
        Navigation.instance.expanded.add(name);
        await _loadTables(name);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _toggleMySQLDatabase(String name) async {
    final nav = Navigation.instance;
    try {
      if (!nav.expanded.contains(name) &&
          AppState.instance.activeDatabase != name) {
        await AppState.instance.selectDatabase(name);
      }
      nav.toggleExpanded(name);
      if (nav.expanded.contains(name)) await _loadTables(name);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// PostgreSQL: databases → schemas → tables.
  ///
  /// The instance connection lists every database without opening a pool per
  /// database. Expanding a database lazily opens one pool and loads its
  /// schemas; clicking a schema switches the active database (if needed) and
  /// loads the tables for that schema.
  List<Widget Function()> _postgresNodes(
      AppState state, Navigation nav, AppRoute route) {
    if (state.instanceDatabases.isEmpty) {
      return [
        () => _treeMessage(
            state.instanceDatabasesLoading ? '连接中…' : '（无数据库）'),
      ];
    }
    final nodes = <Widget Function()>[];
    for (final db in state.instanceDatabases) {
      final name = (db['name'] ?? '').toString();
      if (name.isEmpty || state.isDatabaseDenied(name)) continue;
      final active = state.activeDatabase == name;
      final expanded = nav.expandedDatabases.contains(name);
      // The driver already drops databases this account cannot CONNECT to
      // (postgres::databases filters on has_database_privilege), so this flag
      // is normally true. It is still honoured: a stale cached list from an
      // older build, or a privilege revoked mid-session, must grey the row and
      // explain rather than expand into a failing query.
      final canConnect = db['can_connect'] != false;
      nodes.add(() => _instanceRow(name, active, expanded,
          canConnect: canConnect,
          onToggle: () => _togglePostgresDatabase(name, canConnect)));
      if (!expanded) continue;

      if (nav.loadingSchemas.contains(name)) {
        nodes.add(() => _treeMessage('加载模式…', indent: 22));
        continue;
      }
      final error = nav.schemaErrors[name];
      if (error != null) {
        nodes.add(() => _treeError(error));
        continue;
      }
      final schemas = nav.schemasByDb[name];
      if (schemas == null) {
        nodes.add(() => _treeMessage('...', indent: 22));
        continue;
      }
      final path = state.searchPathSchemas;
      int rank(String schemaName) {
        final index = path.indexOf(schemaName);
        return index < 0 ? 1000 : index;
      }

      final visible = schemas
          .where((s) =>
              !state.isSystemNamespace((s['name'] ?? '').toString()))
          .toList()
        ..sort((a, b) {
          final an = (a['name'] ?? '').toString();
          final bn = (b['name'] ?? '').toString();
          final byPath = rank(an).compareTo(rank(bn));
          return byPath != 0 ? byPath : an.compareTo(bn);
        });
      if (visible.isEmpty) {
        nodes.add(() => _noSchemaRow(name));
        continue;
      }
      final defaultSchema = state.searchPathDefaultSchema;
      for (final schema in visible) {
        final schemaName = (schema['name'] ?? '').toString();
        if (schemaName.isEmpty) continue;
        final activeSchema = active && route.db == schemaName;
        final schemaExpanded = active && nav.expanded.contains(schemaName);
        nodes.add(() => ContextMenuRegion(
              entries: databaseMenuEntries(
                context,
                schemaName,
                notice: widget.notice,
                onChanged: () => _loadTables(schemaName, force: true),
              ),
              child: _schemaRow(
                name,
                schemaName,
                activeSchema,
                schemaExpanded,
                isDefault: active && schemaName == defaultSchema,
                onOpen: () => _openSchema(name, schemaName),
                onToggle: () => _toggleSchema(name, schemaName),
              ),
            ));
        if (schemaExpanded) {
          nodes.addAll(
              _tableRows(schemaName, nav, route, indent: 38));
        }
      }
    }
    return nodes;
  }

  /// Empty schema level: PostgreSQL always has at least `public` unless the
  /// database was created with a custom template or public was dropped. The
  /// user still needs to be able to create a schema from here.
  Widget _noSchemaRow(String database) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 2, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text('（无模式）',
                style: TextStyle(fontSize: 12, color: AppColors.muted)),
          ),
          Btn('新建模式',
              small: true, onPressed: () => _createSchemaIn(database)),
        ],
      ),
    );
  }

  /// Create a schema in [database] and open it, selecting the database first.
  Future<void> _createSchemaIn(String database) async {
    final name = await promptDialog(
      context,
      title: '新建模式',
      label: '模式名',
      initial: '',
    );
    final schema = (name ?? '').trim();
    if (schema.isEmpty || !mounted) return;
    try {
      if (AppState.instance.activeDatabase != database) {
        await AppState.instance.selectDatabase(database);
      }
      await Api.instance.createSchema(schema);
      widget.notice.show('模式已创建');
      AppState.instance.bumpExplorer();
      await AppState.instance.refreshDatabases();
      Navigation.instance.setSchemas(database, AppState.instance.databases);
      if (!mounted) return;
      Navigation.instance.go(AppRoute.database(schema));
      Navigation.instance.expanded.add(schema);
      await _loadTables(schema);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _togglePostgresDatabase(String name, bool canConnect) async {
    if (!canConnect) {
      widget.notice.show('当前账号没有连接数据库 $name 的权限');
      return;
    }
    final state = AppState.instance;
    final nav = Navigation.instance;
    // P14: clicking a database node must also make it the active database,
    // exactly like MySQL's tree. Expanding alone left every table page / the SQL
    // console on the previous database until the user clicked a schema.
    if (state.activeDatabase != name) {
      try {
        await state.selectDatabase(name);
      } catch (e) {
        // Do not expand a database that cannot be opened: the error explains
        // why and the previous selection stays active.
        if (mounted) setState(() => _error = e.toString());
        return;
      }
      if (!mounted) return;
      // selectDatabase already fetched this database's schemas in the same
      // round trip; reuse them instead of issuing a second query on expand.
      nav.setSchemas(name, state.databases);
    }
    nav.toggleExpandedDatabase(name);
    if (nav.expandedDatabases.contains(name) &&
        !nav.schemasByDb.containsKey(name) &&
        !nav.loadingSchemas.contains(name)) {
      await _loadSchemas(name);
    }
  }

  Future<void> _loadSchemas(String database) async {
    final nav = Navigation.instance;
    nav.setSchemaLoading(database, true);
    try {
      final res = await Api.instance.listSchemas(database);
      final list = res['schemas'];
      nav.setSchemas(
        database,
        list is List
            ? list.map((e) => Map<String, dynamic>.from(e as Map)).toList()
            : <Json>[],
      );
      // A lazily opened database also reports the session search_path. Apply it
      // when it belongs to the active database, so the database / SQL page
      // subtitles have the real default schema instead of "（未知）" (P13).
      final searchPath = res['search_path'];
      final state = AppState.instance;
      if (searchPath is String &&
          searchPath.isNotEmpty &&
          state.activeDatabase == database) {
        state.searchPath = searchPath;
        state.notify();
      }
    } catch (e) {
      nav.setSchemaError(database, e.toString());
    }
  }

  Future<void> _openSchema(String database, String schema) async {
    try {
      if (AppState.instance.activeDatabase != database) {
        await AppState.instance.selectDatabase(database);
      }
      if (!mounted) return;
      Navigation.instance.go(AppRoute.database(schema));
      Navigation.instance.expanded.add(schema);
      await _loadTables(schema);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _toggleSchema(String database, String schema) async {
    try {
      if (AppState.instance.activeDatabase != database) {
        await AppState.instance.selectDatabase(database);
      }
      final nav = Navigation.instance;
      nav.toggleExpanded(schema);
      if (nav.expanded.contains(schema)) await _loadTables(schema);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// One PostgreSQL database node: clicking it selects the database and
  /// expands its schema level (P14).
  Widget _instanceRow(String name, bool active, bool expanded,
      {required bool canConnect, required VoidCallback onToggle}) {
    return InkWell(
      onTap: onToggle,
      child: Tooltip(
        message: canConnect ? name : '$name（无连接权限）',
        waitDuration: const Duration(milliseconds: 400),
        child: Container(
          color: active ? AppColors.dbItemActive : Colors.transparent,
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Row(
            children: [
              GestureDetector(
                onTap: onToggle,
                child: SizedBox(
                  width: 12,
                  child: Text(expanded ? 'v' : '>',
                      style: TextStyle(
                          fontSize: 11, color: AppColors.sidebarHead)),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: EllipsisText(
                  name,
                  tooltip: canConnect ? name : '$name（无连接权限）',
                  style: monoStyle(
                      size: 13,
                      color:
                          canConnect ? AppColors.bodyText : AppColors.muted,
                      weight: active ? FontWeight.w600 : FontWeight.normal),
                ),
              ),
              if (!canConnect)
                const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Pill('无权限', tone: PillTone.warn),
                )
              else if (active)
                const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Pill('DB', tone: PillTone.info),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// One PostgreSQL schema node (indented under its database).
  Widget _schemaRow(
    String database,
    String schema,
    bool active,
    bool expanded, {
    required bool isDefault,
    required VoidCallback onOpen,
    required VoidCallback onToggle,
  }) {
    // Caret and label are separate targets: the caret toggles the table list,
    // the label opens the schema page. Nesting both in one InkWell lost the
    // label action in the accessibility tree.
    return Tooltip(
      message: '$database.$schema',
      waitDuration: const Duration(milliseconds: 400),
      child: Container(
        color: active ? AppColors.dbItemActive : Colors.transparent,
        child: Row(
          children: [
            InkWell(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 3, 0, 3),
                child: SizedBox(
                  width: 12,
                  child: Text(expanded ? 'v' : '>',
                      style: TextStyle(
                          fontSize: 11, color: AppColors.sidebarHead)),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: InkWell(
                onTap: onOpen,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 3, 8, 3),
                  child: Row(
                    children: [
                      Expanded(
                        child: EllipsisText(
                          schema,
                          tooltip: '$database.$schema',
                          style: monoStyle(
                              size: 12,
                              color: AppColors.tableLink,
                              weight:
                                  active ? FontWeight.w600 : FontWeight.normal),
                        ),
                      ),
                      if (isDefault)
                        const Padding(
                          padding: EdgeInsets.only(left: 4),
                          child: Pill('默认', tone: PillTone.ok),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }


  /// Directories the user collapsed. They start expanded because the whole
  /// point of the grouping is to show the files without extra clicks.
  final Set<String> _collapsedDirs = <String>{};

  List<Widget Function()> _sqliteNodes(
      AppState state, Navigation nav, AppRoute route) {
    final nodes = <Widget Function()>[];
    final groups = state.databaseGroups;
    if (groups.isEmpty) {
      // The list can be empty while the pool reports nothing (broken primary,
      // unreadable folder); say so instead of rendering a blank sidebar.
      nodes.add(
        () => Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            state.databasesLoading ? '...' : '（该目录下没有可用的数据库）',
            style: TextStyle(fontSize: 13, color: AppColors.muted),
          ),
        ),
      );
      return nodes;
    }
    for (final group in groups) {
      final dir = (group['dir'] ?? '').toString();
      final label = (group['name'] ?? '').toString().isEmpty
          ? dir
          : group['name'].toString();
      final expanded = !_collapsedDirs.contains(dir);
      final databases = group['databases'] is List
          ? (group['databases'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList()
          : <Json>[];
      nodes.add(() => _dirRow(dir, label, expanded, databases.length));
      if (!expanded) continue;
      for (final db in databases) {
        final name = (db['name'] ?? '').toString();
        if (name.isEmpty) continue;
        final path = (db['path'] ?? '').toString();
        final title = (db['title'] ?? '').toString().isEmpty
            ? name
            : db['title'].toString();
        final isActive = route.db == name;
        final open = nav.expanded.contains(name);
        nodes.add(() => ContextMenuRegion(
              entries: databaseMenuEntries(
                context,
                name,
                notice: widget.notice,
                onChanged: () => _loadTables(name, force: true),
              ),
              child: _dbRow(name, title, isActive, open,
                  indent: 22, tooltip: path),
            ));
        if (open) {
          nodes.addAll(_tableRows(name, nav, route));
        }
      }
    }
    // Opening hundreds of files is what the attach limit exists for; say so
    // instead of silently showing a shorter list than the folder contains.
    if (state.sqliteOverflow.isNotEmpty) {
      nodes.add(
        () => Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
          child: Tooltip(
            message: state.sqliteOverflow
                .map((u) => (u['path'] ?? '').toString())
                .join('\n'),
            waitDuration: const Duration(milliseconds: 400),
            child: Text(
              '另有 ${state.sqliteOverflow.length} 个数据库未打开'
              '（最多同时附加 ${state.sqliteAttachLimit} 个）',
              style: TextStyle(fontSize: 11, color: AppColors.muted),
            ),
          ),
        ),
      );
    }
    return nodes;
  }

  /// One directory heading in the SQLite tree.
  Widget _dirRow(String dir, String label, bool expanded, int count) {
    return InkWell(
      onTap: () => setState(() {
        if (_collapsedDirs.contains(dir)) {
          _collapsedDirs.remove(dir);
        } else {
          _collapsedDirs.add(dir);
        }
      }),
      child: Tooltip(
        message: dir,
        waitDuration: const Duration(milliseconds: 400),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 5, 6, 5),
          child: Row(
            children: [
              Text(expanded ? 'v' : '>',
                  style: TextStyle(fontSize: 11, color: AppColors.sidebarHead)),
              const SizedBox(width: 4),
              Expanded(
                child: EllipsisText(
                  label,
                  tooltip: dir.isEmpty ? label : dir,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.sidebarHead,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Pill(count.toString()),
            ],
          ),
        ),
      ),
    );
  }


  /// One database node.
  ///
  /// [name] is the namespace used for routing and table lookups; [label] is what
  /// the tree shows (for SQLite the file name, because the namespace is `main`).
  /// Passing the label as the route made the database page open `TransparencyModel`
  /// instead of `main` and fail with "no such table".
  Widget _dbRow(
    String name,
    String label,
    bool active,
    bool expanded, {
    double indent = 10,
    String? tooltip,
    VoidCallback? onOpen,
    VoidCallback? onToggle,
  }) {
    // Keep the caret and the label as separate tap targets. Nesting the caret
    // inside the label's InkWell made the accessibility tree expose only the
    // caret action, so assistive tech (and UI automation) could expand a
    // database but never open it.
    final shown = tooltip ?? '';
    final body = Container(
      color: active ? AppColors.dbItemActive : Colors.transparent,
      child: Row(
        children: [
          InkWell(
            onTap: onToggle ??
                () {
                  Navigation.instance.toggleExpanded(name);
                  _loadTables(name);
                },
            child: Padding(
              padding: EdgeInsets.fromLTRB(indent, 4, 0, 4),
              child: SizedBox(
                width: 12,
                child: Text(expanded ? 'v' : '>',
                    style: TextStyle(
                        fontSize: 11, color: AppColors.sidebarHead)),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: InkWell(
              onTap: onOpen ?? () => Navigation.instance.go(AppRoute.database(name)),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 4, 10, 4),
                child: EllipsisText(
                  label,
                  tooltip: shown.isEmpty ? label : shown,
                  style: monoStyle(
                      size: 13,
                      color: AppColors.bodyText,
                      weight: active ? FontWeight.w600 : FontWeight.normal),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    if (shown.isEmpty) return body;
    // The full path does not fit in a 268px sidebar; the label already carries a
    // bounded hover tooltip from [EllipsisText], so the path is only added when
    // it differs from the label.
    return Tooltip(
      message: tooltipText(shown),
      constraints: kTooltipConstraints,
      waitDuration: const Duration(milliseconds: 400),
      child: body,
    );
  }

  /// One row per table, as builders (see [_databaseNodes]).
  ///
  /// This is the hot path for a 5000-table database: the old version built every
  /// row up front, and each [EllipsisText] scheduled its own post-frame overflow
  /// measurement, so expanding the database blocked the UI for seconds. Now the
  /// list holds one cheap closure per table and the ListView only materialises
  /// the rows that are actually on screen.
  List<Widget Function()> _tableRows(String db, Navigation nav, AppRoute route,
      {double indent = 26}) {
    final tables = nav.tablesByDb[db];
    if (tables == null) {
      return [
        () => Padding(
              padding: EdgeInsets.fromLTRB(indent, 2, 0, 6),
              child: Text('...',
                  style: TextStyle(fontSize: 12, color: AppColors.muted)),
            ),
      ];
    }
    if (tables.isEmpty) {
      return [
        () => Padding(
              padding: EdgeInsets.fromLTRB(indent, 2, 0, 6),
              child: Text('（无）',
                  style: TextStyle(fontSize: 12, color: AppColors.muted)),
            ),
      ];
    }
    return [
      for (final table in tables)
        // Right-click a table in the tree for its menu; 关系图 is seeded with
        // that table, so the canvas opens on it and its neighbours.
        () => ContextMenuRegion(
              entries: tableMenuEntries(
                context,
                db,
                table,
                notice: widget.notice,
                onChanged: () => _loadTables(db, force: true),
              ),
              child: InkWell(
              onTap: () =>
                  Navigation.instance.go(AppRoute.tableRoute(db, table)),
              child: Container(
                color: route.db == db && route.table == table
                    ? AppColors.dbItemActive
                    : Colors.transparent,
                padding: EdgeInsets.fromLTRB(indent, 2, 6, 2),
                child: EllipsisText(
                  table,
                  tooltip: '$db.$table',
                  style: monoStyle(
                    size: 12,
                    color: route.db == db && route.table == table
                        ? AppColors.bodyText
                        : AppColors.tableLink,
                    weight: route.db == db && route.table == table
                        ? FontWeight.w600
                        : FontWeight.normal,
                  ),
                ),
              ),
              ),
            ),
    ];
  }

  /// Load a database's tables into the sidebar cache, unless already cached.
  Future<void> _loadTables(String db, {bool force = false}) async {
    final nav = Navigation.instance;
    if (!force && nav.tablesByDb.containsKey(db)) return;
    try {
      final tables = await Api.instance.tables(db);
      nav.tablesByDb[db] = tables
          .map((t) => (t['name'] ?? '').toString())
          .where((n) => n.isNotEmpty)
          .toList();
      nav.notify();
    } catch (e) {
      // Cache the failure as an empty list so the auto-load in build() does
      // not retry it on every frame; the error is still shown above.
      nav.tablesByDb[db] = <String>[];
      nav.notify();
      // A permission failure hides the namespace instead of offering a
      // database every later action would fail on again.
      if (isPermissionError(e)) AppState.instance.markDatabaseDenied(db);
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _refresh({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final state = AppState.instance;
      final nav = Navigation.instance;
      // Refresh the instance list (physical databases) first, then the schemas
      // of the active database. SQLite re-scans its folder instead.
      await state.refreshInstanceDatabases();
      await state.refreshDatabases(refreshFiles: true);
      nav.clearTablesCache();
      nav.clearSchemas();
      for (final database in nav.expandedDatabases.toList()) {
        await _loadSchemas(database);
      }
      for (final namespace in nav.expanded.toList()) {
        await _loadTables(namespace, force: true);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

}
