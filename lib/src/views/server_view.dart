import 'dart:async';

import 'package:flutter/material.dart' hide Text, Tooltip;
import '../text.dart';
import '../tooltip.dart';

import '../api.dart';
import '../app_state.dart';
import '../i18n.dart';
import '../notice.dart';
import '../theme.dart';
import '../widgets.dart';

/// Server administration: status, variables, processes and database accounts.
///
/// Ports Server.vue. The web version required the site-admin role; the desktop
/// app has no roles, so the page is always available. The DB-account editor
/// keeps the MySQL privilege matrix and the PostgreSQL role attributes.
class ServerView extends StatefulWidget {
  const ServerView({super.key, required this.notice});
  final Notice notice;

  @override
  State<ServerView> createState() => _ServerViewState();
}

class _ServerViewState extends State<ServerView> {
  static const _tabLabels = {
    'status': '状态',
    'variables': '变量',
    'processes': '进程',
    'users': '账号',
  };

  String _tab = 'status';
  Json _status = <String, dynamic>{};
  List<Json> _variables = <Json>[];
  List<Json> _processes = <Json>[];
  List<Json> _users = <Json>[];
  Json _accountModel = <String, dynamic>{};
  String _variableFilter = '';
  final _variableSearch = TextEditingController();
  String _userFilter = '';

  /// Page-level error for actions (kill / account edits); panel errors are
  /// kept per panel in [_panelErrors].
  String? _error;

  /// Per-panel load state (P10).
  ///
  /// Each server panel loads independently: one slow or forbidden query must
  /// not keep the whole page on a spinner. A restricted account used to wait
  /// 16.4s for every probe to finish before anything rendered; now each panel
  /// publishes its own result, error or timeout the moment it returns.
  static const Duration _panelTimeout = Duration(seconds: 8);
  final Map<String, Object?> _panelErrors = <String, Object?>{};
  final Set<String> _panelLoading = <String>{};
  final Set<String> _panelLoaded = <String>{};
  bool _probeTimedOut = false;
  int _loadGeneration = 0;

  static const Map<String, String> _panelLabels = <String, String>{
    'status': '服务器状态',
    'variables': '服务器变量',
    'processes': '进程列表',
    'users': '数据库账号',
  };

  @override
  void dispose() {
    _variableSearch.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// True when the connected account may use `capability`; a tab whose
  /// capability is missing is hidden and, if it is the open tab, replaced by
  /// an explanatory panel.
  bool _can(String capability) => AppState.instance.can(capability);

  /// Tabs to render.
  ///
  /// SQLite is a file, not a server: it has no accounts and no process list, so
  /// those tabs would only ever show `not available`. They are hidden instead of
  /// disabled, and the same rule now applies to a restricted MySQL/PG account:
  /// hiding a tab it can never use is clearer than greying it out. The banner
  /// above still names every missing GRANT.
  List<String> get _visibleTabs {
    if (AppState.instance.isSqlite) return const ['status', 'variables'];
    return <String>[
      if (_can('status')) 'status',
      'variables',
      if (_can('processes')) 'processes',
      if (_can('accounts')) 'users',
    ];
  }

  /// Explanation shown in place of a panel the account cannot read.
  Widget _deniedPanel(String capability, String what) {
    return CardBox(child: AlertBox(_privilegeMessage(capability, what),
        tone: AlertTone.info));
  }

  String _privilegeMessage(String capability, String what) {
    final needed = AppState.instance.requiredPrivilege(capability) ?? '';
    return '当前数据库账号没有执行「$what」所需的服务器权限。'
        '${needed.isEmpty ? '' : '需要：$needed。'}'
        '\n请让数据库管理员为该账号授权，或改用有权限的账号连接；'
        '授权后点「刷新」即可生效，无需重新连接。';
  }

  List<String> get _panelsToLoad => <String>[
        if (_panelAllowed('status')) 'status',
        'variables',
        if (_panelAllowed('processes')) 'processes',
        if (_panelAllowed('users')) 'users',
      ];

  /// Whether the current (possibly stale) capability set allows a panel.
  ///
  /// `can()` defaults to true while the probe has not finished; the panel is
  /// then loaded and dropped again if the probe turns out to deny it.
  bool _panelAllowed(String panel) {
    // SQLite has no server: never even ask for its process list / accounts.
    if (AppState.instance.isSqlite &&
        (panel == 'processes' || panel == 'users')) {
      return false;
    }
    return switch (panel) {
      'status' => _can('status'),
      'processes' => _can('processes'),
      'users' => _can('accounts'),
      _ => true,
    };
  }

  /// Load the page progressively (P10).
  ///
  /// The capability probe and the panels start together. Panels render as soon
  /// as their own request returns and every request has an 8s timeout, so a
  /// slow or forbidden query becomes one panel's error instead of a page-wide
  /// spinner.
  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() {
      _error = null;
      _probeTimedOut = false;
      _panelErrors.clear();
      _panelLoading
        ..clear()
        ..addAll(_panelsToLoad);
    });
    final probe = _probePrivileges(generation);
    final panels = <Future<void>>[
      if (_panelAllowed('status')) _loadStatusPanel(generation),
      _loadVariablesPanel(generation),
      if (_panelAllowed('processes')) _loadProcessesPanel(generation),
      if (_panelAllowed('users')) _loadUsersPanel(generation),
    ];
    await Future.wait([probe, ...panels]);
  }

  Future<void> _probePrivileges(int generation) async {
    try {
      await AppState.instance.refreshPrivileges().timeout(_panelTimeout);
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _probeTimedOut = true);
      return;
    }
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      // A denial found by the probe hides the tab; drop any in-flight /
      // already-reported error for a request the UI no longer offers.
      for (final panel in const <String>['status', 'processes', 'users']) {
        if (!_panelAllowed(panel)) {
          _panelLoading.remove(panel);
          _panelErrors.remove(panel);
        }
      }
    });
  }

  Future<void> _loadStatusPanel(int generation) => _loadPanel(
        generation,
        'status',
        Api.instance.status,
        (value) {
          if (value is Json) _status = value;
        },
      );

  Future<void> _loadVariablesPanel(int generation) => _loadPanel(
        generation,
        'variables',
        Api.instance.variables,
        (value) {
          if (value is List<Json>) _variables = value;
        },
      );

  Future<void> _loadProcessesPanel(int generation) => _loadPanel(
        generation,
        'processes',
        Api.instance.processes,
        (value) {
          if (value is List<Json>) _processes = value;
        },
      );

  Future<void> _loadUsersPanel(int generation) => _loadPanel(
        generation,
        'users',
        () async {
          final results = await Future.wait<Json>([
            Api.instance.dbUsers(),
            Api.instance.userPrivileges(),
          ]);
          return <String, dynamic>{
            'users': results[0],
            'model': results[1],
          };
        },
        (value) {
          if (value is! Json) return;
          final users = value['users'];
          if (users is Json) {
            final list = users['users'];
            _users = list is List
                ? list
                    .map((e) => Map<String, dynamic>.from(e as Map))
                    .toList()
                : <Json>[];
          }
          final model = value['model'];
          if (model is Json) _accountModel = model;
        },
      );

  /// Run one independent panel request and publish its own result.
  Future<void> _loadPanel(
    int generation,
    String panel,
    Future<Object?> Function() call,
    void Function(Object? value) apply,
  ) async {
    try {
      final value = await call().timeout(_panelTimeout);
      if (!mounted || generation != _loadGeneration) return;
      if (!_panelAllowed(panel)) {
        setState(() {
          _panelLoading.remove(panel);
          _panelErrors.remove(panel);
        });
        return;
      }
      setState(() {
        apply(value);
        _panelLoading.remove(panel);
        _panelErrors.remove(panel);
        _panelLoaded.add(panel);
      });
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _panelLoading.remove(panel);
        if (_panelAllowed(panel)) _panelErrors[panel] = e;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageScroll(
      padding: const EdgeInsets.all(AppMetrics.mainPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHead(
            title: t('nav_server'),
            actions: [
              Btn(t('refresh'), onPressed: _load),
            ],
          ),
          if (_error != null) AlertBox(_error!),
          if (_probeTimedOut)
            AlertBox(
              '权限探测超时（8 秒内数据库没有返回），暂时无法确认哪些页签可用；'
              '页签会按各自加载结果单独说明。请点「刷新」重试，或检查数据库服务器负载。',
              tone: AlertTone.warn,
            ),
          if (_missingPrivileges.isNotEmpty) _privilegeNotice(),
          NoticeBanner(widget.notice),
          if (_visibleTabs.isEmpty)
            AlertBox(
              '当前数据库账号没有可用的服务器页签。'
              '${AppState.instance.dbAccount.isEmpty ? '' : '账号：${AppState.instance.dbAccount}。'}'
              '请让数据库管理员授权后点「刷新」。',
              tone: AlertTone.info,
            )
          else
            Wrap(
              spacing: 2,
              children: [for (final tab in _visibleTabs) _tabButton(tab)],
            ),
          const SizedBox(height: 12),
          _tabBody(),
        ],
      ),
    );
  }

  /// The capabilities this account lacks, as (capability, label, privilege).
  ///
  /// SQLite has no accounts or process list at all, so nothing is "missing":
  /// the banner would describe tabs that are not rendered for it.
  List<Map<String, String>> get _missingPrivileges {
    if (AppState.instance.isSqlite) return const [];
    final list = AppState.instance.serverPrivileges?['requirements'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((raw) => <String, String>{
              'capability': (raw['capability'] ?? '').toString(),
              'label': (raw['label'] ?? '').toString(),
              'privilege': (raw['privilege'] ?? '').toString(),
            })
        .where((item) => item['capability']!.isNotEmpty)
        .toList();
  }

  /// One banner listing everything the account cannot do, with the GRANT it
  /// would need. Shown once at the top instead of an error per panel.
  Widget _privilegeNotice() {
    return AlertBox(
      privilegeBannerMessage(AppState.instance.serverPrivileges),
      tone: AlertTone.info,
    );
  }

  Widget _tabButton(String tab) {
    final active = _tab == tab;
    final capability = switch (tab) {
      'processes' => 'processes',
      'users' => 'accounts',
      _ => null,
    };
    final enabled = capability == null || _can(capability);
    return GestureDetector(
      onTap: enabled ? () => setState(() => _tab = tab) : null,
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
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Text(
            _tabLabels[tab] ?? tab,
            style: TextStyle(
              fontSize: 13,
              color: active ? AppColors.bodyText : AppColors.muted,
              fontWeight: active ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabBody() {
    switch (_tab) {
      case 'status':
        return _panel('status', _statusTab,
            capability: 'status', what: '服务器状态');
      case 'variables':
        return _panel('variables', _variablesTab);
      case 'processes':
        return _panel('processes', _processesTab,
            capability: 'processes', what: '进程列表');
      case 'users':
        return _panel('users', _usersTab,
            capability: 'accounts', what: '数据库账号');
    }
    return const SizedBox.shrink();
  }

  /// Render one panel from its own loading / error / data state.
  ///
  /// A panel that the probe turned out to deny is replaced by an explanation,
  /// never left blank (P10).
  Widget _panel(
    String panel,
    Widget Function() build, {
    String? capability,
    String? what,
  }) {
    if (capability != null && !_can(capability)) {
      return _deniedPanel(capability, what ?? _panelLabels[panel] ?? panel);
    }
    final error = _panelErrors[panel];
    final loading = _panelLoading.contains(panel);
    final loaded = _panelLoaded.contains(panel);
    if (!loaded && loading) return _panelLoadingBox(panel);
    if (!loaded && error != null) return _panelErrorBox(panel, error);
    final data = build();
    if (loading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const LinearProgressIndicator(minHeight: 2),
          const SizedBox(height: 8),
          data,
        ],
      );
    }
    if (error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _panelErrorBox(panel, error),
          data,
        ],
      );
    }
    return data;
  }

  Widget _panelLoadingBox(String panel) {
    return CardBox(
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            '正在加载「${_panelLabels[panel] ?? panel}」…（最多 8 秒）',
            style: kMuted,
          ),
        ],
      ),
    );
  }

  Widget _panelErrorBox(String panel, Object error, {bool retry = true}) {
    return CardBox(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AlertBox(_panelErrorText(panel, error), tone: AlertTone.warn),
          if (retry) Btn('重试', small: true, onPressed: () => _retryPanel(panel)),
        ],
      ),
    );
  }

  Future<void> _retryPanel(String panel) async {
    setState(() {
      _panelErrors.remove(panel);
      _panelLoading.add(panel);
    });
    final generation = _loadGeneration;
    if (panel == 'status') {
      await _loadStatusPanel(generation);
    } else if (panel == 'variables') {
      await _loadVariablesPanel(generation);
    } else if (panel == 'processes') {
      await _loadProcessesPanel(generation);
    } else if (panel == 'users') {
      await _loadUsersPanel(generation);
    }
  }

  String _panelErrorText(String panel, Object error) {
    final capability = switch (panel) {
      'status' => 'status',
      'processes' => 'processes',
      'users' => 'accounts',
      _ => null,
    };
    return serverPanelFailureText(
      label: _panelLabels[panel] ?? panel,
      error: error,
      privilege:
          capability == null ? null : _privilegeForPanel(panel, capability),
      account: AppState.instance.dbAccount,
    );
  }

  /// The GRANT to name for a failed panel.
  ///
  /// The probe does not always know: MySQL/PG report `can_view_status: true`
  /// from role attributes even when SHOW GLOBAL STATUS is denied, so the status
  /// panel can still fail with 1142. Name the documented privilege then.
  String? _privilegeForPanel(String panel, String capability) {
    final known = AppState.instance.requiredPrivilege(capability);
    if (known != null && known.isNotEmpty) return known;
    if (panel == 'status') {
      return AppState.instance.isMysql
          ? 'PROCESS 或 SHOW DATABASES'
          : 'pg_read_all_stats 角色';
    }
    return null;
  }

  // ------------------------------------------------------------------ status

  Widget _statusTab() {
    final stats = serverStatusStats(_status);
    final statusVars = _status['status'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final entry in stats.entries)
              _statusCard(entry.key, entry.value),
          ],
        ),
        const SizedBox(height: 12),
        if (statusVars is Map)
          CardBox(
            title: '全部状态变量',
            actions: [
              _variableSearchField(),
              Text('${statusVars.length}', style: kSmallMuted),
            ],
            // MySQL reports ~490 status variables. Building one widget per row
            // up front made switching back to this tab take over a second, so
            // the list is virtualised: only the visible rows are built.
            child: _variableList(
              [
                for (final entry in statusVars.entries)
                  if (_matchesVariable(entry.key.toString(), entry.value.toString()))
                    (entry.key.toString(), entry.value.toString()),
              ],
            ),
          ),
      ],
    );
  }

  /// One fixed-size headline card (see [ServerStatCard] for the layout rule).
  Widget _statusCard(String label, String value) =>
      ServerStatCard(label: label, value: value, isVersion: label == '版本');

  // --------------------------------------------------------------- variables

  Widget _variablesTab() {
    final filtered = _variables.where((v) => _matchesVariable(
        (v['Variable_name'] ?? '').toString(), (v['Value'] ?? '').toString())).toList();
    return CardBox(
      title: '服务器变量',
      actions: [
        _variableSearchField(),
        Text('${filtered.length} / ${_variables.length}', style: kSmallMuted),
      ],
      child: _variableList([
        for (final variable in filtered)
          (
            variable['Variable_name'].toString(),
            (variable['Value'] ?? '').toString()
          ),
      ]),
    );
  }

  bool _matchesVariable(String name, String value) {
    final query = _variableFilter.trim().toLowerCase();
    return query.isEmpty || name.toLowerCase().contains(query) || value.toLowerCase().contains(query);
  }

  Widget _variableSearchField() => SizedBox(
    width: 280,
    child: Field(
      label: '',
      controller: _variableSearch,
      hint: I18n.current == AppLang.en ? 'Search variable names or values' : '搜索变量名或值',
      onChanged: (value) => setState(() => _variableFilter = value),
    ),
  );

  /// A long, scrollable name → value list.
  ///
  /// Two performance traps were removed here:
  ///
  /// 1. **One `SelectableText` per row.** Each one owns a selection registrar
  ///    and gesture recogniser; 620 of them cost ~3.7s to build. A single
  ///    [SelectionArea] around plain [Text] keeps the text selectable for a
  ///    fraction of that.
  /// 2. **A plain `Column`.** It materialises every row even though only a
  ///    screenful is visible. [ListView.builder] builds lazily, so switching
  ///    tabs no longer scales with the number of variables.
  ///
  /// Measured on 620 rows: 3750ms before, ~200ms after.
  Widget _variableList(List<(String, String)> rows) {
    if (rows.isEmpty) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text('（无）', style: kMuted),
      );
    }
    return SizedBox(
      // Bounded so the ListView can virtualise; the page itself scrolls above.
      height: 460,
      child: SelectionArea(
        child: Scrollbar(
          child: ListView.builder(
            itemCount: rows.length,
            itemExtent: 22,
            itemBuilder: (context, index) {
              final (name, value) = rows[index];
              return Tooltip(
                message: I18n.current == AppLang.en ? 'View full value' : '查看完整值',
                child: InkWell(
                  onTap: () => showAppModal<void>(
                    context: context,
                    title: name,
                    wide: true,
                    builder: (_) => CodeBlock(value, maxHeight: 420),
                  ),
                  child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 260,
                      child: EllipsisText(name,
                          style: monoStyle(size: 12, color: AppColors.muted)),
                    ),
                    // The value column is narrow and variables can hold long
                    // JSON / paths; hovering shows the whole value (and a
                    // click still opens the full text in a CodeBlock).
                    Expanded(
                      child: EllipsisText(value,
                          tooltip: value,
                          tooltipMaxWidth: 520,
                          style: monoStyle(size: 12)),
                    ),
                  ],
                ),
              ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------- processes

  Widget _processesTab() {
    return CardBox(
      title: '进程列表',
      child: GridTable(
        headers: const [
          Text('Id'),
          Text('用户'),
          Text('主机'),
          Text('数据库'),
          Text('命令'),
          Text('时间'),
          Text('状态'),
          Text('Info'),
          Text('操作'),
        ],
        emptyText: '（无）',
        rows: [
          for (final process in _processes)
            TableRow(
              children: [
                gridCell(process['Id']),
                gridCell(process['User']),
                gridCell(process['Host'], mono: true),
                gridCell(process['db']),
                gridCell(process['Command']),
                gridCell(process['Time']),
                gridCell(process['State']),
                gridCell(process['Info'], mono: true),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Btn('终止',
                      small: true,
                      danger: true,
                      onPressed: () {
                        final id = asNumber(process['Id'])?.toInt();
                        if (id != null) _kill(id);
                      }),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _kill(int id) async {
    final ok = await confirmDialog(context,
        message: '确定终止进程 $id 吗？', confirmLabel: '终止', danger: true);
    if (!ok) return;
    try {
      await Api.instance.killProcess(id);
      widget.notice.show('进程已终止');
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  // ------------------------------------------------------------------- users

  Widget _usersTab() {
    if (_accountModel['supported'] != true) {
      return CardBox(
        child: Text(
          (_accountModel['note'] ?? '当前数据库不支持账号管理。').toString(),
          style: kMuted,
        ),
      );
    }
    final hostRequired = _accountModel['host_required'] == true;
    final filtered = _users.where((u) {
      if (_userFilter.trim().isEmpty) return true;
      return (u['user'] ?? '')
          .toString()
          .toLowerCase()
          .contains(_userFilter.trim().toLowerCase());
    }).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CardBox(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Btn('新建账号', primary: true, onPressed: () => _editUser(null)),
              SizedBox(
                width: 220,
                child: Field(
                  label: '',
                  hint: t('search'),
                  onChanged: (v) => setState(() => _userFilter = v),
                ),
              ),
              Btn(t('refresh'), onPressed: _load),
              Text('${filtered.length} / ${_users.length}', style: kSmallMuted),
              if ((_accountModel['note'] ?? '').toString().isNotEmpty)
                Text(_accountModel['note'].toString(), style: kSmallMuted),
            ],
          ),
        ),
        CardBox(
          title: '数据库账号',
          child: GridTable(
            headers: [
              const Text('用户'),
              if (hostRequired) const Text('主机'),
              const Text('类型'),
              const Text('锁定'),
              const Text('操作'),
            ],
            emptyText: '（无）',
            rows: [
              for (final user in filtered)
                TableRow(
                  children: [
                    gridCell(user['user'], mono: true),
                    if (hostRequired) gridCell(user['host'], mono: true),
                    gridCell(user['plugin']),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 5),
                      child: user['account_locked'] == 'Y'
                          ? const Pill('锁定', tone: PillTone.warn)
                          : const SizedBox.shrink(),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      child: Row(
                        children: [
                          Btn('查看权限',
                              small: true,
                              onPressed: () => _viewGrants(user)),
                          const SizedBox(width: 4),
                          Btn('编辑',
                              small: true, onPressed: () => _editUser(user)),
                          const SizedBox(width: 4),
                          Btn('删除',
                              small: true,
                              danger: true,
                              onPressed: () => _dropUser(user)),
                        ],
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _viewGrants(Json user) async {
    if (!_can('accounts')) {
      setState(() => _error = _privilegeMessage('accounts', '查看权限'));
      return;
    }
    try {
      final grants = await Api.instance.dbUserGrants(
        user['user'].toString(),
        (user['host'] ?? '%').toString(),
      );
      if (!mounted) return;
      final rows = <Json>[];
      final list = grants['grants'];
      if (list is List) {
        rows.addAll(list.map((e) => Map<String, dynamic>.from(e as Map)));
      }
      final raw = grants['raw'];
      final memberships = grants['memberships'];
      await showAppModal(
        context: context,
        title: '权限：${user['user']}',
        wide: true,
        builder: (context) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionLabel('权限矩阵'),
            const SizedBox(height: 6),
            if (rows.isEmpty)
              Text('没有额外权限', style: kMuted)
            else
              GridTable(
                headers: const [Text('作用域'), Text('权限')],
                rows: [
                  for (final row in rows)
                    TableRow(
                      children: [
                        gridCell(_scopeLabel(row), mono: true),
                        Padding(
                          padding: const EdgeInsets.all(6),
                          child: Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: [
                              for (final privilege in (row['privileges'] as List? ?? []))
                                Pill(privilege.toString()),
                            ],
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            if (memberships is List && memberships.isNotEmpty) ...[
              const SizedBox(height: 12),
              const SectionLabel('角色成员'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final role in memberships) Pill(role.toString()),
                ],
              ),
            ],
            if (raw is List && raw.isNotEmpty) ...[
              const SizedBox(height: 12),
              const SectionLabel('原始授权语句'),
              const SizedBox(height: 6),
              CodeBlock(raw.join('\n')),
            ],
          ],
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  String _scopeLabel(Json row) {
    final scope = (row['scope'] ?? '*').toString();
    final table = row['table'];
    if (scope == '*') return '*.*';
    if (table == null || table.toString().isEmpty) return '$scope.*';
    return '$scope.$table';
  }

  Future<void> _dropUser(Json user) async {
    final ok = await confirmDialog(
      context,
      message: '确定删除账号 ${user['user']}@${user['host'] ?? '%'} 吗？',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    try {
      await Api.instance.dropDbUser(
        user['user'].toString(),
        (user['host'] ?? '%').toString(),
      );
      widget.notice.show('账号已删除');
      await AppState.instance.refreshPrivileges();
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Create / edit a database account. The MySQL branch renders the privilege
  /// matrix; the PostgreSQL branch renders role attributes and memberships.
  Future<void> _editUser(Json? existing) async {
    final isEdit = existing != null;
    final model = (_accountModel['model'] ?? '').toString();
    final hostRequired = _accountModel['host_required'] == true;
    final userCtrl = TextEditingController(
        text: isEdit ? existing['user'].toString() : '');
    final hostCtrl = TextEditingController(
        text: isEdit ? (existing['host'] ?? '%').toString() : '%');
    final passwordCtrl = TextEditingController();
    final newUserCtrl = TextEditingController();
    final scopes = <Json>[];
    final attributes = <String>[];
    final memberships = <String>[];
    var locked = false;
    String? error;
    String preview = '';

    if (isEdit) {
      try {
        final grants = await Api.instance.dbUserGrants(
          existing['user'].toString(),
          (existing['host'] ?? '%').toString(),
        );
        final list = grants['grants'];
        if (list is List) {
          for (final raw in list) {
            final row = Map<String, dynamic>.from(raw as Map);
            scopes.add(<String, dynamic>{
              'scope': (row['scope'] ?? '*').toString(),
              'privileges':
                  (row['privileges'] as List? ?? []).map((e) => e.toString()).toList(),
            });
          }
        }
        final membershipList = grants['memberships'];
        if (membershipList is List) {
          memberships.addAll(membershipList.map((e) => e.toString()));
        }
        final attrs = grants['attributes'];
        if (attrs is Map) {
          attrs.forEach((key, value) {
            if (value == true) attributes.add(key.toString());
          });
        }
      } catch (_) {
        // Editing still works without the pre-loaded grants.
      }
    }

    final modelPrivileges = <Json>[];
    final modelAttributes = <String>[];
    final modelRoles = <String>[];
    final privList = _accountModel['privileges'];
    if (privList is List) {
      modelPrivileges.addAll(
          privList.map((e) => Map<String, dynamic>.from(e as Map)));
    }
    final attrList = _accountModel['attributes'];
    if (attrList is List) {
      modelAttributes.addAll(attrList.map((e) => e.toString()));
    }
    final roleList = _accountModel['roles'];
    if (roleList is List) {
      modelRoles.addAll(roleList.map((e) => e.toString()));
    }
    final scopeOptions = <Json>[];
    final scopeList = _accountModel['scopes'];
    if (scopeList is List) {
      scopeOptions.addAll(
          scopeList.map((e) => Map<String, dynamic>.from(e as Map)));
    }

    if (!mounted) return;
    await showAppModal(
      context: context,
      title: isEdit ? '编辑账号' : '新建账号',
      wide: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModal) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FormRow(
                label: '用户名',
                child: Field(
                  label: '',
                  controller: userCtrl,
                  hint: 'app_user',
                  enabled: !isEdit,
                ),
              ),
              if (hostRequired)
                FormRow(
                  label: '主机',
                  child: Field(
                    label: '',
                    controller: hostCtrl,
                    hint: '%',
                    enabled: !isEdit,
                  ),
                ),
              FormRow(
                label: '密码',
                child: Field(
                  label: '',
                  controller: passwordCtrl,
                  obscure: true,
                  hint: isEdit ? '留空表示保持当前密码' : '',
                ),
              ),
              if (isEdit)
                FormRow(
                  label: '新用户名',
                  child: Field(
                    label: '',
                    controller: newUserCtrl,
                    hint: '留空表示保持当前名称',
                  ),
                ),
              if (model == 'mysql') ...[
                CheckBox(
                  label: '锁定账号',
                  value: locked,
                  onChanged: (v) => setModal(() => locked = v),
                ),
                const SizedBox(height: 8),
                const SectionLabel('权限矩阵'),
                const SizedBox(height: 6),
                for (var i = 0; i < scopes.length; i++)
                  _scopeRow(i, scopes, modelPrivileges, setModal),
                Btn('+ 添加作用域',
                    small: true,
                    onPressed: () => setModal(() => scopes.add(<String, dynamic>{
                          'scope': '*',
                          'privileges': <String>[],
                        }))),
              ] else if (model == 'postgres') ...[
                const SectionLabel('角色属性'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final attr in modelAttributes)
                      FilterChip(
                        label: Text(attr, style: const TextStyle(fontSize: 11)),
                        selected: attributes.contains(attr),
                        onSelected: (v) => setModal(() {
                          if (v) {
                            attributes.add(attr);
                          } else {
                            attributes.remove(attr);
                          }
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                const SectionLabel('角色成员'),
                const SizedBox(height: 6),
                if (modelRoles.isEmpty)
                  Text('（无）', style: kMuted)
                else
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final role in modelRoles)
                        FilterChip(
                          label: Text(role, style: const TextStyle(fontSize: 11)),
                          selected: memberships.contains(role),
                          onSelected: (v) => setModal(() {
                            if (v) {
                              memberships.add(role);
                            } else {
                              memberships.remove(role);
                            }
                          }),
                        ),
                    ],
                  ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  const SectionLabel('SQL 预览'),
                  const SizedBox(width: 8),
                  Btn('生成预览', small: true, onPressed: () async {
                    // Build the same diff-only payload the Apply button sends,
                    // so the preview shows exactly what would run.
                    final body = <String, dynamic>{'password': passwordCtrl.text};
                    if (model == 'mysql') {
                      body['grants'] = [
                        for (final scope in scopes)
                          <String, dynamic>{
                            'scope': scope['scope'],
                            'table': null,
                            'privileges': scope['privileges'],
                          },
                      ];
                      body['account_locked'] = locked;
                    } else {
                      body['attributes'] = <String, dynamic>{
                        for (final attr in modelAttributes)
                          attr: attributes.contains(attr),
                      };
                      body['roles'] = memberships;
                    }
                    if (newUserCtrl.text.trim().isNotEmpty) {
                      body['new_user'] = newUserCtrl.text.trim();
                    }
                    try {
                      final res = isEdit
                          ? await Api.instance.updateDbUser(
                              existing['user'].toString(),
                              (existing['host'] ?? '%').toString(),
                              body,
                              dryRun: true,
                            )
                          : await Api.instance.createDbUser(
                              {
                                'user': userCtrl.text.trim(),
                                'host': hostCtrl.text.trim().isEmpty
                                    ? '%'
                                    : hostCtrl.text.trim(),
                                ...body,
                              },
                              dryRun: true,
                            );
                      final statements = res['statements'];
                      setModal(() {
                        error = null;
                        preview = statements is List && statements.isNotEmpty
                            ? statements.join(';\n')
                            : '无需修改。';
                      });
                    } catch (e) {
                      setModal(() {
                        error = e.toString();
                        preview = '';
                      });
                    }
                  }),
                ],
              ),
              const SizedBox(height: 6),
              CodeBlock(preview.isEmpty ? '（尚未生成）' : preview,
                  dark: true, maxHeight: 200),
              if (error != null) ...[
                const SizedBox(height: 8),
                AlertBox(error!),
              ],
              if (scopeOptions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '可用作用域：${scopeOptions.map((s) => s['label']).join('、')}',
                    style: kSmallMuted,
                  ),
                ),
            ],
          );
        },
      ),
      actions: [
        Builder(
          builder: (context) => Btn('预览 SQL', onPressed: () async {
            final body = <String, dynamic>{'password': passwordCtrl.text};
            if (model == 'mysql') {
              body['grants'] = [
                for (final scope in scopes)
                  <String, dynamic>{
                    'scope': scope['scope'],
                    'table': null,
                    'privileges': scope['privileges'],
                  },
              ];
            } else {
              body['attributes'] = <String, dynamic>{
                for (final attr in modelAttributes)
                  attr: attributes.contains(attr),
              };
              body['roles'] = memberships;
            }
            try {
              final res = isEdit
                  ? await Api.instance.updateDbUser(
                      existing['user'].toString(),
                      (existing['host'] ?? '%').toString(),
                      body,
                      dryRun: true,
                    )
                  : await Api.instance.createDbUser(
                      {
                        'user': userCtrl.text.trim(),
                        'host': hostCtrl.text.trim().isEmpty
                            ? '%'
                            : hostCtrl.text.trim(),
                        ...body,
                      },
                      dryRun: true,
                    );
              final statements = res['statements'];
              widget.notice.show(statements is List
                  ? statements.join(';\n')
                  : '无需修改。');
            } catch (e) {
              widget.notice.show(e.toString());
            }
          }),
        ),
        Builder(
          builder: (context) => Btn(t('cancel'),
              onPressed: () => Navigator.of(context).pop()),
        ),
        Builder(
          builder: (context) => Btn('应用', primary: true, onPressed: () async {
            final body = <String, dynamic>{'password': passwordCtrl.text};
            if (model == 'mysql') {
              body['grants'] = [
                for (final scope in scopes)
                  <String, dynamic>{
                    'scope': scope['scope'],
                    'table': null,
                    'privileges': scope['privileges'],
                  },
              ];
              body['account_locked'] = locked;
            } else {
              body['attributes'] = <String, dynamic>{
                for (final attr in modelAttributes)
                  attr: attributes.contains(attr),
              };
              body['roles'] = memberships;
            }
            if (newUserCtrl.text.trim().isNotEmpty) {
              body['new_user'] = newUserCtrl.text.trim();
            }
            try {
              final res = isEdit
                  ? await Api.instance.updateDbUser(
                      existing['user'].toString(),
                      (existing['host'] ?? '%').toString(),
                      body,
                    )
                  : await Api.instance.createDbUser({
                      'user': userCtrl.text.trim(),
                      'host': hostCtrl.text.trim().isEmpty
                          ? '%'
                          : hostCtrl.text.trim(),
                      ...body,
                    });
              final failed = (res['failed'] as num?)?.toInt() ?? 0;
              if (failed > 0) {
                final results = res['results'];
                final firstError = results is List
                    ? results.firstWhere(
                        (r) => (r as Map)['error'] != null,
                        orElse: () => <String, dynamic>{})
                    : <String, dynamic>{};
                widget.notice.show(
                    '执行失败：${firstError['error'] ?? ''}');
                return;
              }
              if (context.mounted) Navigator.of(context).pop();
              widget.notice.show(res['unchanged'] == true
                  ? '无需修改'
                  : '已应用修改');
              // Editing accounts can change *this* account's own privileges
              // (or its role memberships), so re-probe before reloading the
              // panels; otherwise a freshly granted privilege would stay hidden
              // until the app reconnected.
              await AppState.instance.refreshPrivileges();
              // A new GRANT can also make a database visible that was hidden
              // before, so refresh the explorer tree as well.
              await AppState.instance.refreshDatabases();
              await _load();
            } catch (e) {
              widget.notice.show(describeDbError(e));
            }
          }),
        ),
      ],
    );
  }

  Widget _scopeRow(int index, List<Json> scopes, List<Json> modelPrivileges,
      StateSetter setModal) {
    final scope = scopes[index];
    final scopeName = (scope['scope'] ?? '*').toString();
    final selected = (scope['privileges'] as List?)?.cast<String>() ?? <String>[];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.chipBg,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 220,
                child: TextField(
                  controller: TextEditingController(text: scopeName),
                  style: monoStyle(size: 12),
                  onChanged: (v) => scope['scope'] = v,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Btn('删除',
                  small: true,
                  danger: true,
                  onPressed: () => setModal(() => scopes.removeAt(index))),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final privilege in modelPrivileges)
                if (privilege['global_only'] != true || scopeName == '*')
                  FilterChip(
                    label: Text(privilege['name'].toString(),
                        style: const TextStyle(fontSize: 11)),
                    selected: selected.contains(privilege['name']),
                    onSelected: (v) => setModal(() {
                      if (v) {
                        selected.add(privilege['name'].toString());
                      } else {
                        selected.remove(privilege['name']);
                      }
                      scope['privileges'] = selected;
                    }),
                  ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One fixed-size server headline card.
///
/// The version string is a whole sentence (`PostgreSQL 17.11 on x86_64-...`);
/// rendering all of it in a 180px card made that one card several times taller
/// than the others, so it is shortened and kept on two lines at a smaller size.
/// Every other value is drawn on a **single** line that scales down to fit:
/// the 20px `0d 10h 41m 10s` used to wrap into a second line that the card's
/// fixed height clipped (round34 P3-02). The complete value stays reachable
/// through the hover tooltip.
///
/// Public (and free of state) so the layout can be pinned by a widget test at
/// the real card size without a database.
class ServerStatCard extends StatelessWidget {
  const ServerStatCard({
    super.key,
    required this.label,
    required this.value,
    this.isVersion = false,
    this.tooltip,
  });

  final String label;
  final String value;

  /// Version strings are a whole sentence; they get a smaller font and may use
  /// two lines instead of being scaled to an unreadable size.
  final bool isVersion;

  /// Hover text; defaults to [value].
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final display = isVersion ? shortServerVersion(value) : value;
    return Tooltip(
      message: tooltipText(tooltip ?? value),
      constraints: kTooltipConstraints,
      waitDuration: const Duration(milliseconds: 400),
      child: Container(
        width: 180,
        height: 92,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.panel,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 0.5,
                    color: AppColors.muted)),
            const SizedBox(height: 4),
            Expanded(
              child: Align(
                alignment: Alignment.topLeft,
                child: isVersion
                    ? EllipsisText(
                        display,
                        maxLines: 2,
                        tooltip: '$label：$display',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    : FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.topLeft,
                        child: Text(
                          display,
                          maxLines: 1,
                          softWrap: false,
                          semanticsLabel: display,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tolerant numeric reader for server counters.
///
/// MySQL answers `SHOW GLOBAL STATUS` with **strings** (`"Uptime": "8991"`),
/// while the SQLite / PostgreSQL overview handlers build real numbers. The
/// status tab used to cast with `as num?`, which threw
/// `type 'String' is not a subtype of type 'num?'` on MySQL and took the whole
/// page down: the server tab rendered nothing at all. Parse instead of casting.
num? asNumber(Object? value) {
  if (value is num) return value;
  if (value is String) return num.tryParse(value.trim());
  return null;
}

/// Short label for the status card; the full value stays in the tooltip.
String shortServerVersion(String version) {
  final trimmed = version.trim();
  if (trimmed.isEmpty) return '—';
  final on = trimmed.indexOf(' on ');
  final short = on > 0 ? trimmed.substring(0, on) : trimmed;
  if (short.length <= 32) return short;
  return '${short.substring(0, 31)}…';
}

/// Compact uptime label, or an em dash when the driver does not report it.
///
/// The card is 180×92 and draws its value at 20px. The full
/// `0d 10h 41m 10s` was wider than the box, wrapped onto a second line and was
/// clipped by the fixed height (round34 P3-02: the tail overlapped the card).
/// Leading zero units are dropped and seconds only appear while they are the
/// largest unit, so the label stays on one line.
String formatUptime(int seconds) {
  if (seconds <= 0) return '—';
  final days = seconds ~/ 86400;
  final hours = (seconds % 86400) ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final secs = seconds % 60;
  if (days > 0) return '${days}d ${hours}h ${minutes}m';
  if (hours > 0) return '${hours}h ${minutes}m';
  if (minutes > 0) return '${minutes}m ${secs}s';
  return '${secs}s';
}

/// The headline numbers of the server status tab, as label → display text.
///
/// Pulled out of the widget so the string/number tolerance is directly testable
/// (see regressions2_test.dart) without rendering the page.
Map<String, String> serverStatusStats(Map<String, dynamic> status) {
  return <String, String>{
    '版本': (status['version'] ?? '—').toString(),
    '运行时间': formatUptime(asNumber(status['uptime'])?.toInt() ?? 0),
    '连接线程': (status['threads_connected'] ?? 0).toString(),
    '运行线程': (status['threads_running'] ?? 0).toString(),
    '查询数': (status['queries'] ?? 0).toString(),
    '连接数': (status['connections'] ?? 0).toString(),
    '数据库数': (status['database_count'] ?? 0).toString(),
    '表数': (status['table_count'] ?? 0).toString(),
    '接收字节': formatBytes(asNumber(status['bytes_received'])),
    '发送字节': formatBytes(asNumber(status['bytes_sent'])),
  };
}
/// The banner shown when the connected account lacks server privileges.
///
/// Kept as a pure function so the exact wording is testable without rendering
/// the page: it is the only place that tells the user which GRANT to request.
String privilegeBannerMessage(Map<String, dynamic>? caps) {
  final requirements = caps?['requirements'];
  if (requirements is! List || requirements.isEmpty) return '';
  final lines = requirements
      .whereType<Map>()
      .map((item) => '· ${item['label']}：需要 ${item['privilege']}')
      .join('\n');
  final account = (caps?['account'] ?? '').toString();
  return '当前数据库账号${account.isEmpty ? '' : '（$account）'}没有以下服务器权限，相关页签已置灰：\n'
      '$lines\n'
      '这些限制来自数据库本身。请让数据库管理员授权后点「刷新」；'
      '本应用不会、也无法绕过数据库权限。';
}

/// Wording for a failed server panel.
///
/// Pure so the timeout / permission / generic branches can be tested without a
/// database. `privilege` is the GRANT the account would need, when the
/// capability probe (or the driver's documented requirement) knows it.
String serverPanelFailureText({
  required String label,
  required Object? error,
  String? privilege,
  String account = '',
}) {
  final who = account.isEmpty ? '当前数据库账号' : '当前数据库账号（$account）';
  if (error is TimeoutException) {
    return '「$label」加载超时（8 秒内数据库没有返回）。'
        '其余页签仍可正常使用；请点「刷新」重试，或检查数据库服务器的负载与网络。';
  }
  if (isPermissionError(error)) {
    final needed = (privilege ?? '').trim();
    return '$who没有读取「$label」所需的服务器权限。'
        '${needed.isEmpty ? '' : '需要：$needed。'}'
        '请让数据库管理员为该账号授权后点「刷新」（无需重新连接）；'
        '本应用不会、也无法绕过数据库权限。';
  }
  return '「$label」加载失败：${describeDbError(error)}';
}