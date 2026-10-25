import 'package:flutter/material.dart' hide Text, Tooltip;
import '../text.dart';
import '../tooltip.dart';

import '../api.dart';
import '../app_state.dart';
import '../connection_store_notice.dart';
import '../db_options.dart';
import '../i18n.dart';
import '../nav.dart';
import '../notice.dart';
import '../theme.dart';
import '../sqlite_sources.dart';
import '../widgets.dart';
import 'connection_progress_dialog.dart';

const List<String> _sslModes = ['disable', 'prefer', 'require'];

/// Certificate verification levels: encrypt only, verify the chain, or verify
/// the chain and the host name as well.
const List<String> _sslVerifyModes = ['require', 'verify-ca', 'verify-full'];

/// PostgreSQL uses one libpq `sslmode` value instead of MySQL's pair.
const List<String> _pgSslModes = <String>[
  'disable',
  'allow',
  'prefer',
  'require',
  'verify-ca',
  'verify-full',
];

/// Connection manager: list, create, edit, delete, test and open connections.
///
/// Ports Connections.vue. The web version gated New/Edit/Delete behind the
/// admin role; the desktop app has no roles, so every action is available.
class ConnectionsView extends StatefulWidget {
  const ConnectionsView({super.key, required this.notice});
  final Notice notice;

  @override
  State<ConnectionsView> createState() => _ConnectionsViewState();
}

class _ConnectionsViewState extends State<ConnectionsView> {
  List<Json> _connections = <Json>[];
  List<Json> _drivers = <Json>[];
  String? _error;
  /// Startup problem with connections.json (corrupt file was backed up).
  /// Rendered as a dismissible banner; once closed the session stays quiet.
  String? _storeError;
  bool _storeErrorDismissed = false;
  bool _loading = true;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;
  bool _opening = false;

  /// Bumped for every "open" so a superseded/cancelled attempt cannot apply
  /// its result (see [_open]).
  int _connectGeneration = 0;

  // Form state, mirroring the web reactive form object.
  String? _editingId;
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _database = TextEditingController();
  final _onlyDb = TextEditingController();
  final _hideDb = TextEditingController();
  /// SQLite: the folder whose database files are attached to the connection.
  final _sqliteDir = TextEditingController();
  final _sslCa = TextEditingController();
  final _sslCert = TextEditingController();
  final _sslKey = TextEditingController();
  String _driver = 'mysql';
  String _charset = '';
  String _sslMode = 'disable';
  String _sslVerify = 'verify-full';
  /// PostgreSQL has one libpq-style `sslmode` instead of MySQL's
  /// mode + separate certificate-verification pair.
  String _pgSsl = 'disable';
  String _color = '#f29111';

  // --- SSH tunnel ("connect through a jump host") ----------------------------
  bool _sshEnabled = false;
  final _sshHost = TextEditingController();
  final _sshPort = TextEditingController();
  final _sshUser = TextEditingController();
  String _sshAuth = 'password';
  final _sshPassword = TextEditingController();
  final _sshKey = TextEditingController();
  final _sshAgent = TextEditingController();
  final _sshHostKey = TextEditingController();
  String _sshHostKeyPolicy = 'accept-new';
  /// Selected tab of the connection editor: 0 = general, 1 = SSL, 2 = SSH.
  int _formTab = 0;

  bool get _isPostgres => _driver == 'postgres';

  /// Collapse the stored (ssl_mode, ssl_verify) pair into libpq's single value.
  String _pgSslFrom(Json? entry) {
    final mode = (entry?['ssl_mode'] ?? 'disable').toString();
    final verify = (entry?['ssl_verify'] ?? '').toString();
    // A stored verify level only means TLS when the mode actually enables it:
    // the MySQL form keeps `ssl_verify = verify-full` as its idle default while
    // SSL is off, so trusting it unconditionally made a brand-new PostgreSQL
    // connection request certificate verification and fail.
    if (mode == 'disable' || mode == 'allow') return mode;
    if (verify == 'verify-ca' || verify == 'verify-full') return verify;
    return const ['prefer', 'require'].contains(mode) ? mode : 'disable';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _host,
      _port,
      _user,
      _password,
      _database,
      _onlyDb,
      _hideDb,
      _sqliteDir,
      _sslCa,
      _sslCert,
      _sslKey,
      _sshHost,
      _sshPort,
      _sshUser,
      _sshPassword,
      _sshKey,
      _sshAgent,
      _sshHostKey,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final config = await Api.instance.appConfig();
      final drivers = config['drivers'];
      final list = await Api.instance.connections();
      // A corrupt connections.json is backed up by the store at startup; the
      // list then comes back empty/seeded, so without this banner the user
      // would think their saved connections were deleted.
      final storeError = await Api.instance.connectionsStoreError();
      if (!mounted) return;
      setState(() {
        _drivers = drivers is List
            ? drivers.map((e) => Map<String, dynamic>.from(e as Map)).toList()
            : <Json>[];
        _connections = list;
        _storeError = storeError;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _openForm([Json? entry]) {
    _editingId = entry?['id']?.toString();
    _name.text = (entry?['name'] ?? '').toString();
    _driver = (entry?['driver'] ?? 'mysql').toString();
    _host.text = (entry?['host'] ?? '127.0.0.1').toString();
    _port.text = (entry?['port'] ?? '').toString();
    _user.text = (entry?['user'] ?? '').toString();
    // Editing pre-fills the stored password, like the web form did.
    _password.text = (entry?['password'] ?? '').toString();
    _database.text = (entry?['database'] ?? '').toString();
    _onlyDb.text = (entry?['only_db'] ?? '').toString();
    _hideDb.text = (entry?['hide_db'] ?? '').toString();
    _charset = (entry?['charset'] ?? '').toString();
    _sslMode = (entry?['ssl_mode'] ?? 'disable').toString();
    _sslVerify = (entry?['ssl_verify'] ?? 'verify-full').toString();
    _pgSsl = _pgSslFrom(entry);
    _sslCa.text = (entry?['ssl_ca'] ?? '').toString();
    _sslCert.text = (entry?['ssl_cert'] ?? '').toString();
    _sslKey.text = (entry?['ssl_key'] ?? '').toString();
    _sqliteDir.text = (entry?['sqlite_dir'] ?? '').toString();
    _color = (entry?['color'] ?? '#f29111').toString();
    _sshEnabled = (entry?['ssh_host'] ?? '').toString().isNotEmpty;
    _sshHost.text = (entry?['ssh_host'] ?? '').toString();
    _sshPort.text = (entry?['ssh_port'] ?? '').toString();
    _sshUser.text = (entry?['ssh_user'] ?? '').toString();
    _sshAuth = (entry?['ssh_auth'] ?? 'password').toString();
    _sshPassword.text = (entry?['ssh_password'] ?? '').toString();
    _sshKey.text = (entry?['ssh_key'] ?? '').toString();
    _sshAgent.text = (entry?['ssh_agent'] ?? '').toString();
    _sshHostKey.text = (entry?['ssh_host_key'] ?? '').toString();
    _sshHostKeyPolicy = (entry?['ssh_host_key_policy'] ?? 'accept-new').toString();
    _formTab = 0;
    // Clear the previous probe/save outcome so the dialog does not open with a
    // stale error from an earlier attempt.
    _testResult = null;
    _error = null;
    _showFormDialog();
  }

  /// Changing the driver copies its default port and user, matching the web
  /// behaviour where the driver list carried those defaults.
  void _onDriverChanged(String driver) {
    setState(() {
      final previous = _driver;
      String? defaultUserOf(String id) { 
        final meta = _drivers.firstWhere(
          (d) => d['id'] == id,
          orElse: () => <String, dynamic>{},
        );
        final value = meta['default_user'];
        return value?.toString();
      }

      _driver = driver;
      final meta = _drivers.firstWhere(
        (d) => d['id'] == driver,
        orElse: () => <String, dynamic>{},
      );
      final defaultPort = meta['default_port'];
      if (defaultPort != null) _port.text = defaultPort.toString();
      if (driver != 'sqlite' && _host.text.trim().isEmpty) {
        _host.text = '127.0.0.1';
      }
      final defaultUser = defaultUserOf(driver);
      // Replace the previous driver's default account (root -> postgres) but
      // never overwrite an account the user typed.
      if (defaultUser != null &&
          (_user.text.isEmpty || _user.text == defaultUserOf(previous))) {
        _user.text = defaultUser;
      }
      // Carry the current TLS intent across a driver switch so picking
      // PostgreSQL does not silently turn encryption back off.
      if (driver == 'postgres') {
        _pgSsl = _pgSslFrom(<String, dynamic>{
          'ssl_mode': _sslMode,
          'ssl_verify': _sslVerify,
        });
      } else if (driver == 'mysql' && previous == 'postgres') {
        // libpq's allow/prefer become "nothing special" on MySQL; the
        // verify-* values map to a required TLS connection with checks.
        _sslMode = (_pgSsl == 'disable' || _pgSsl == 'allow')
            ? 'disable'
            : 'require';
        _sslVerify = (_pgSsl == 'verify-ca' || _pgSsl == 'verify-full')
            ? _pgSsl
            : 'require';
      }
    });
  }

  Map<String, dynamic> _formBody() {
    final isSqlite = _driver == 'sqlite';
    final pgVerify = _pgSsl == 'verify-ca' || _pgSsl == 'verify-full';
    // The Rust side keeps MySQL's (ssl_mode, ssl_verify) pair and derives the
    // libpq mode from it: verify-* implies TLS and selects certificate checks.
    final sslMode = _isPostgres ? (pgVerify ? 'require' : _pgSsl) : _sslMode;
    final sslVerify =
        _isPostgres ? (pgVerify ? _pgSsl : 'require') : _sslVerify;
    final body = <String, dynamic>{
      'driver': _driver,
      'name': _name.text.trim(),
      'host': isSqlite ? '' : _host.text.trim(),
      'port': isSqlite ? null : int.tryParse(_port.text.trim()),
      'user': isSqlite ? '' : _user.text.trim(),
      'password': isSqlite ? '' : _password.text,
      'database': _database.text.trim().isEmpty ? null : _database.text.trim(),
      // Only MySQL has a connection character set.
      'charset': _driver == 'mysql' && _charset.isNotEmpty ? _charset : null,
      'ssl_mode': isSqlite ? null : sslMode,
      'ssl_verify': isSqlite || sslMode == 'disable' ? null : sslVerify,
      'ssl_ca': isSqlite || _sslCa.text.trim().isEmpty
          ? null
          : _sslCa.text.trim(),
      'ssl_cert': isSqlite || _sslCert.text.trim().isEmpty
          ? null
          : _sslCert.text.trim(),
      'ssl_key': isSqlite || _sslKey.text.trim().isEmpty
          ? null
          : _sslKey.text.trim(),
      // SQLite browses a folder: every database file inside it is attached, so
      // only the folder has to be stored (an empty value falls back to the
      // primary file's folder).
      'sqlite_dir': _driver == 'sqlite' && _sqliteDir.text.trim().isNotEmpty
          ? _sqliteDir.text.trim()
          : null,
      // Empty strings are normalised to null so the store does not persist
      // meaningless values, matching the web save path.
      'only_db': _onlyDb.text.trim().isEmpty ? null : _onlyDb.text.trim(),
      'hide_db': _hideDb.text.trim().isEmpty ? null : _hideDb.text.trim(),
      'color': _color,
      // SSH is flattened into the connection object in Rust. Omit the keys
      // entirely when the tunnel is off: sending explicit nulls made the
      // flattened struct reject the whole connection, because a null cannot be
      // deserialised as `String`/`SshAuth`.
      if (_sshEnabled && !isSqlite) ...<String, dynamic>{
        'ssh_host': _sshHost.text.trim(),
        'ssh_port': int.tryParse(_sshPort.text.trim()),
        'ssh_user': _sshUser.text.trim(),
        'ssh_auth': _sshAuth,
        'ssh_password': _sshPassword.text,
        if (_sshKey.text.trim().isNotEmpty) 'ssh_key': _sshKey.text.trim(),
        if (_sshAgent.text.trim().isNotEmpty)
          'ssh_agent': _sshAgent.text.trim(),
        if (_sshHostKey.text.trim().isNotEmpty)
          'ssh_host_key': _sshHostKey.text.trim(),
        'ssh_host_key_policy': _sshHostKeyPolicy,
      },
    };
    if (_editingId != null) body['id'] = _editingId;
    return body;
  }

  /// Probe the form's current values and put the outcome *inside the dialog*.
  ///
  /// This used to be wired to the page-level `setState`, which sits behind the
  /// modal route: the result was stored but the dialog never rebuilt, so a
  /// failing probe looked like a dead button. The dialog now owns this state
  /// (via [ModalHandle.rebuild]) and shows both success and failure inline.
  Future<void> _test(ModalHandle dialog) async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    dialog.rebuild();
    try {
      final res = await Api.instance.testConnection(_formBody());
      if (!mounted) return;
      // SSH: remember the jump host's key fingerprint on first success so later
      // connections are pinned. The value is shown in the form for the user to
      // review before saving.
      final fingerprint = (res['ssh_host_key_fingerprint'] ?? '').toString();
      if (fingerprint.isNotEmpty && _sshHostKey.text.trim().isEmpty) {
        _sshHostKey.text = fingerprint;
      }
      setState(() {
        _testing = false;
        _testOk = true;
        const unit = '个数据库';
        final tunnelled = res['tunnelled'] == true;
        final via = tunnelled
            ? ' · SSH 隧道 ${res['dial_host']}:${res['dial_port']}'
            : '';
        _testResult = '${t('conn_test_ok')} · ${res['version'] ?? ''} · '
            '${res['namespaces'] ?? 0} $unit · ${res['elapsed_ms'] ?? 0} ms$via';
      });
      if (fingerprint.isNotEmpty) {
        _testResult = '$_testResult · SSH 主机密钥 $fingerprint';
      }
      // A stored pin that differs from the key the jump host just presented is
      // worth surfacing: under accept-new it silently re-trusts, and the user
      // should at least see that the host changed.
      if (res['ssh_host_key_changed'] == true && fingerprint.isNotEmpty) {
        _testResult =
            '$_testResult · ⚠ 与已保存指纹不一致，请核对跳板机身份（当前：$fingerprint）';
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testOk = false;
        _testResult = '${t('conn_test_fail')}: $e';
      });
    }
    dialog.rebuild();
  }

  /// Persist the form. On success the dialog closes and the list reloads; on
  /// failure the message is shown in the dialog (and on the page behind it) so
  /// the user can fix the field instead of wondering whether the click worked.
  Future<void> _save(ModalHandle dialog) async {
    setState(() => _error = null);
    // N-11: ssh::open refuses strict mode without a stored fingerprint, so
    // saving one would only produce a connection that can never open. Catch it
    // in the form where the user can still fix it.
    if (_sshEnabled &&
        _driver != 'sqlite' &&
        _sshHostKeyPolicy == 'strict' &&
        _sshHostKey.text.trim().isEmpty) {
      setState(() => _error = '主机密钥策略为「仅信任已保存指纹」时必须填写指纹：'
          '请先点「测试连接」自动填入，或手动粘贴跳板机的 SHA256 指纹。');
      dialog.rebuild();
      return;
    }
    try {
      final body = _formBody();
      if (_editingId != null) {
        await Api.instance.updateConnection(_editingId!, body);
      } else {
        body.remove('id');
        await Api.instance.createConnection(body);
      }
      if (!mounted) return;
      dialog.close();
      widget.notice.show(t('conn_saved'));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
      dialog.rebuild();
    }
  }

  Future<void> _remove(Json entry) async {
    final ok = await confirmDialog(
      context,
      message: '确定删除连接 ${entry['name'] ?? entry['id']} 吗？',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    try {
      await Api.instance.deleteConnection(entry['id'].toString());
      // delete_connection disconnects the active connection in Rust. Mirror that
      // immediately in the UI, otherwise the topbar and sidebar keep showing the
      // deleted connection until the next full restart.
      await AppState.instance.syncActive();
      widget.notice.show('连接已删除');
      await _load();
      if (!mounted) return;
      if (!AppState.instance.connected &&
          Navigation.instance.route.needsConnection) {
        Navigation.instance.go(AppRoute.connections);
      }
    } catch (e) {
      // A failed save must not abort the UI half-way: re-read the Rust side so
      // the banner/tree match memory, then surface the real error.
      try {
        await AppState.instance.syncActive();
      } catch (_) {}
      if (mounted) {
        setState(() => _error = e.toString());
        await _load();
      }
    }
  }

  /// Close the active connection without deleting its saved entry.
  /// AppState.disconnect() clears the tree and explorer caches, so the shell
  /// cannot keep rendering the old database after this returns.
  Future<void> _disconnectActive() async {
    try {
      await AppState.instance.disconnect();
      widget.notice.show('已断开连接');
      if (!mounted) return;
      setState(() {});
      Navigation.instance.go(AppRoute.connections);
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  /// Open a connection. After connecting, land on the connection's default
  /// database when it has one (non-SQLite), otherwise the SQL console — the
  /// same destination logic the web app used.
  Future<void> _open(Json entry) async {
    if (_opening) return;
    setState(() => _opening = true);
    // The attempt cannot be aborted inside the driver, so a cancelled dialog
    // only means "stop caring about this attempt": the generation below makes
    // sure a late success/failure cannot move the UI or leave a half-open
    // session behind.
    final generation = ++_connectGeneration;
    try {
      final result = await showConnectionProgress(
        context,
        label: _progressLabel(entry),
        connect: () => AppState.instance.connect(entry['id'].toString()),
        onError: (error) {
          if (!mounted || generation != _connectGeneration) return;
          setState(() => _error = error.toString());
        },
      );
      if (!mounted || generation != _connectGeneration) return;
      if (result == ConnectionProgressResult.cancelled) {
        // A cancelled attempt may still have completed server-side; drop the
        // session so the tree and the next connect start from a known state.
        if (AppState.instance.connected) {
          await AppState.instance.disconnect();
        }
        widget.notice.show('已取消连接');
        return;
      }
      if (result == ConnectionProgressResult.failed) return;
      final state = AppState.instance;
      final database = state.connection?['database'];
      if (!mounted) return;
      if (state.isPostgres) {
        // PostgreSQL connects to the instance, then selects a database. Open
        // its default schema (normally public) rather than a database name.
        final schema = state.defaultDatabase;
        // expandTree:false — 连接成功后侧边栏保持收起，不再默认展开第一个
        // 数据库的表列表；用户点数据库 / schema 节点时才展开。
        if (schema != null) {
          Navigation.instance.go(AppRoute.database(schema), expandTree: false);
        } else {
          Navigation.instance.go(AppRoute.sql);
        }
      } else if (state.isMysql) {
        final active = state.activeDatabase;
        if (active != null && active.isNotEmpty) {
          Navigation.instance
              .go(AppRoute.database(active), expandTree: false);
        } else {
          Navigation.instance.go(AppRoute.sql);
        }
      } else if (database is String && database.isNotEmpty) {
        // A SQLite connection is addressed by its primary file; the database
        // page resolves that path to the namespace the driver reports.
        Navigation.instance.go(
            AppRoute.database(state.databaseNameForPath(database)),
            expandTree: false);
      } else {
        Navigation.instance.go(AppRoute.sql);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  /// One-line identity shown inside the progress dialog.
  String _progressLabel(Json entry) {
    final name = (entry['name'] ?? entry['id']).toString();
    final driver = (entry['driver'] ?? '').toString();
    if (driver == 'sqlite') {
      final path = (entry['database'] ?? '').toString();
      return path.isEmpty ? name : '$name · $path';
    }
    final host = (entry['host'] ?? '').toString();
    final port = entry['port']?.toString() ?? '';
    final address = port.isEmpty ? host : '$host:$port';
    return address.isEmpty ? name : '$name · $address';
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    // Dismissal is intentionally page state only: once the user closes the
    // startup warning, later refreshes in this session must not re-show it.
    final storeNotice =
        _storeErrorDismissed ? null : connectionsStoreNotice(_storeError);
    return PageScroll(
      padding: const EdgeInsets.all(AppMetrics.mainPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHead(
            title: t('conn_title'),
            meta: [Pill(_connections.length.toString())],
            actions: [
              Btn(t('conn_new'), primary: true, onPressed: () => _openForm()),
            ],
          ),
          if (storeNotice != null)
            AlertBox(
              storeNotice,
              tone: AlertTone.warn,
              onClose: () => setState(() => _storeErrorDismissed = true),
            ),
          if (state.connected)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: AlertBox(
                    '当前连接：${state.connectionLabel} (${state.driverLabel})',
                    tone: AlertTone.info,
                  ),
                ),
                const SizedBox(width: 8),
                Btn('断开连接', onPressed: _disconnectActive),
              ],
            ),
          if (_error != null) AlertBox(_error!),
          NoticeBanner(widget.notice),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_connections.isEmpty)
            // 首次启动（或删光连接后）的引导：应用不再预置任何示例连接，
            // 所以这里必须明确告诉用户下一步做什么，而不是只显示「暂无连接」。
            CardBox(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text('还没有任何数据库连接',
                      key: const ValueKey('connections-empty-title'),
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.bodyText)),
                  const SizedBox(height: 6),
                  Text('点击右上角「新建连接」，选择 MySQL / PostgreSQL / SQLite 并填写地址即可。',
                      key: const ValueKey('connections-empty-hint'),
                      style: kMuted),
                  const SizedBox(height: 12),
                  // 文案故意避开「新建连接」：顶部工具栏已经有同名按钮，
                  // 重复会让按文案查找控件的测试与自动化脚本产生歧义。
                  Btn('创建第一个连接',
                      key: const ValueKey('connections-empty-create'),
                      primary: true,
                      onPressed: () => _openForm()),
                ],
              ),
            )
          else
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: _connections.map(_card).toList(),
            ),
        ],
      ),
    );
  }

  Widget _card(Json entry) {
    final isSqlite = entry['driver'] == 'sqlite';
    final target = isSqlite
        ? (entry['database'] ?? '').toString()
        : '${entry['host'] ?? ''}:${entry['port'] ?? ''}${(entry['database'] ?? '').toString().isEmpty
                ? ''
                : ' / ${entry['database']}'}';
    final color = _parseColor((entry['color'] ?? '').toString());
    return Container(
      width: 340,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: EllipsisText(
                  (entry['name'] ?? entry['id']).toString(),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              Pill((entry['driver'] ?? '').toString()),
            ],
          ),
          const SizedBox(height: 6),
          // P3-04: a SQLite card carries a file path, and a tail ellipsis hid
          // exactly the part that identifies the connection
          // (`/Users/…/langu…`). Shorten it in the middle — the head and the
          // file name stay readable — and keep the full path on hover.
          MiddleEllipsisText(
            target,
            style: monoStyle(size: 12, color: AppColors.muted),
            tooltipMaxWidth: 520,
          ),
          if ((entry['only_db'] ?? '').toString().isNotEmpty)
            Text('仅显示：${entry['only_db']}',
                style: TextStyle(fontSize: 12, color: AppColors.muted)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              Btn('打开',
                  primary: true, busy: _opening, onPressed: () => _open(entry)),
              // SQLite connections point at a plain file, so "open the database
              // folder" is a meaningful action for them; for server drivers the
              // data lives on the server and there is nothing to reveal.
              if (isSqlite)
                Btn('打开目录', onPressed: () => _revealDatabase(entry)),
              Btn(t('edit'), onPressed: () => _openForm(entry)),
              Btn(t('delete'), danger: true, onPressed: () => _remove(entry)),
            ],
          ),
        ],
      ),
    );
  }

  /// Reveal a SQLite connection's database file in the system file manager.
  Future<void> _revealDatabase(Json entry) async {
    final path = (entry['database'] ?? '').toString();
    if (path.isEmpty) {
      widget.notice.show('该连接还没有数据库文件');
      return;
    }
    final ok = await revealInFileManager(path);
    if (!ok) {
      widget.notice.show('无法打开目录：$path');
    }
  }

  Color _parseColor(String hex) {
    final cleaned = hex.replaceAll('#', '').trim();
    if (cleaned.length == 6) {
      final value = int.tryParse(cleaned, radix: 16);
      if (value != null) return Color(0xFF000000 | value);
    }
    return const Color(0xFF8AA0BD);
  }

  /// Pick the primary SQLite database file.
  Future<void> _pickSqliteFile() async {
    try {
      final path = await pickSqliteFile();
      if (path == null || !mounted) return;
      setState(() => _database.text = path);
      _formHandle?.rebuild();
    } catch (e) {
      _pickerFailed(e);
    }
  }

  /// Show a picker failure inside the dialog instead of letting the exception
  /// die in the console — the button used to look simply dead.
  void _pickerFailed(Object error) {
    if (!mounted) return;
    setState(() => _error = '无法打开文件选择器：$error');
    _formHandle?.rebuild();
  }

  /// Pick a file into one of the certificate fields.
  Future<void> _pickPath(TextEditingController target, String title) async {
    try {
      final path = await pickAnyFile(title: title);
      if (path == null || !mounted) return;
      setState(() => target.text = path);
      _formHandle?.rebuild();
    } catch (e) {
      _pickerFailed(e);
    }
  }

  /// Pick the folder whose database files this connection browses.
  Future<void> _pickSqliteDir() async {
    try {
      final dir = await pickFolder(title: '选择数据库目录（会递归扫描其中的 SQLite 文件）');
      if (dir == null || !mounted) return;
      setState(() => _sqliteDir.text = dir);
      _formHandle?.rebuild();
    } catch (e) {
      _pickerFailed(e);
    }
  }

  /// The three certificate path rows shared by MySQL and PostgreSQL.
  List<Widget> _sslFileRows() => <Widget>[
        FormRow(
          label: 'CA 证书',
          child: Field(
            label: '',
            controller: _sslCa,
            hint: '/path/to/ca.pem',
            trailing: IconBtn(Icons.folder_open_outlined,
                tooltip: '浏览',
                small: true, onPressed: () => _pickPath(_sslCa, '选择 CA 证书')),
          ),
        ),
        FormRow(
          label: '客户端证书',
          child: Field(
            label: '',
            controller: _sslCert,
            hint: '/path/to/client-cert.pem（可选）',
            trailing: IconBtn(Icons.folder_open_outlined,
                tooltip: '浏览',
                small: true,
                onPressed: () => _pickPath(_sslCert, '选择客户端证书')),
          ),
        ),
        FormRow(
          label: '客户端私钥',
          child: Field(
            label: '',
            controller: _sslKey,
            hint: '/path/to/client-key.pem（可选）',
            trailing: IconBtn(Icons.folder_open_outlined,
                tooltip: '浏览',
                small: true, onPressed: () => _pickPath(_sslKey, '选择客户端私钥')),
          ),
        ),
      ];

  ModalHandle? _formHandle;

  /// Ask the open editor dialog to rebuild after a field change.
  ///
  /// The dialog owns its own state; without this a controller edit (SSL mode,
  /// SSH auth method, ...) would change the form model but not the visible
  /// fields.
  void _rebuildForm() {
    _formHandle?.rebuild();
  }

  /// The connection editor dialog, shown for both create and edit.
  Future<void> _showFormDialog() async {
    final handle = ModalHandle();
    _formHandle = handle;
    await showModalShell(
      context: context,
      title: _editingId == null ? t('conn_new') : t('conn_edit'),
      handle: handle,
      builder: (context, setModal) {
          void sync() => setModal(() {});
          final isSqlite = _driver == 'sqlite';
          final isPostgres = _driver == 'postgres';
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FormRow(
                label: t('driver'),
                child: SelectBox<String>(
                  value: _driver,
                  onChanged: (v) {
                    if (v != null) {
                      _onDriverChanged(v);
                      sync();
                    }
                  },
                  items: [
                    for (final d in _drivers)
                      DropdownMenuItem(
                        value: d['id'].toString(),
                        child: Text((d['label'] ?? d['id']).toString()),
                      ),
                  ],
                ),
              ),
              FormRow(
                label: t('conn_name'),
                child: Field(key: const ValueKey('conn-name-field'), label: '', controller: _name),
              ),
              // Tabbed editor: one connection object whose fields are
              // grouped so the long form is not a wall of inputs. SSL and SSH
              // are independent: a tunnel can carry a TLS session.
              FormTabs(
                labels: [
                  I18n.current == AppLang.en ? 'General' : '常规',
                  'SSL',
                  'SSH',
                ],
                index: _formTab,
                onChanged: (i) {
                  _formTab = i;
                  _rebuildForm();
                },
                children: [
                  _generalTab(isSqlite: isSqlite, isPostgres: isPostgres),
                  _sslTab(isSqlite: isSqlite, isPostgres: isPostgres),
                  _sshTab(isSqlite: isSqlite),
                ],
              ),
              // Both the probe outcome and a failed save are shown inside the
              // dialog; before, the probe wrote to state the dialog could not
              // rebuild and a failed save only painted the page behind it.
              if (_error != null) AlertBox(_error!),
              if (_testResult != null)
                // P11: keep the probe outcome in one stable node so automation
                // can assert "test connection" success/failure by key.
                AlertBox(_testResult!,
                    key: const ValueKey('conn-test-result'),
                    liveRegion: true,
                    tone: _testOk ? AlertTone.ok : AlertTone.error),
            ],
          );
      },
      actions: [
        Btn(_testing ? t('conn_testing') : t('conn_test'),
            busy: _testing,
            onPressed: _testing ? null : () => _test(handle)),
        Btn(t('save'), primary: true, onPressed: () => _save(handle)),
      ],
    );
  }
  Widget _generalTab({required bool isSqlite, required bool isPostgres}) {
    final isMysql = _driver == 'mysql';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isSqlite) ...[
          FormRow(
            label: '数据库文件',
            child: Field(
              label: '',
              controller: _database,
              hint: '/path/to/db.sqlite（主数据库，可留空由目录自动选择）',
              trailing: IconBtn(Icons.folder_open_outlined,
                tooltip: '浏览', small: true, onPressed: _pickSqliteFile),
            ),
          ),
          FormRow(
            label: '数据库目录',
            child: Field(
              label: '',
              controller: _sqliteDir,
              hint: '留空则使用主文件所在目录',
              trailing: IconBtn(Icons.folder_open_outlined,
                tooltip: '浏览', small: true, onPressed: _pickSqliteDir),
            ),
          ),
          Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: Text(
              '连接后会自动扫描该目录（含子目录）里所有 .sqlite / .sqlite3 / .db / .db3 文件，'
              '主文件作为当前库，其余文件自动附加；在目录里增删文件后点「刷新」即可生效。',
              style: kSmallMuted,
            ),
          ),
        ] else ...[
          FormRow(
            label: t('host'),
            child: Field(
              key: const ValueKey('db-host'),
              label: '',
              controller: _host,
              hint: isPostgres
                  ? '127.0.0.1 或 Unix socket 目录（如 /tmp）'
                  : null,
            ),
          ),
          FormRow(
            label: t('port'),
            child: Field(
                key: const ValueKey('db-port'),
                label: '',
                controller: _port,
                numeric: true),
          ),
          FormRow(
            label: t('username'),
            child: Field(
                key: const ValueKey('db-user'),
                label: '',
                controller: _user),
          ),
          FormRow(
            label: t('password'),
            child: Field(label: '', controller: _password, obscure: true),
          ),
          FormRow(
            label: isPostgres ? '默认数据库（可选）' : '${t('database')}（可选）',
            child: Field(
              label: '',
              controller: _database,
              hint: isPostgres
                  ? '留空自动选择可访问的数据库；连接后可在左侧树中切换'
                  : '留空自动选择可访问的数据库',
            ),
          ),
          if (isMysql)
            FormRow(
              label: '连接字符集',
              child: SelectBox<String>(
                value: _charset.isEmpty ? '' : _charset,
                onChanged: (v) {
                  _charset = v ?? '';
                  _rebuildForm();
                },
                items: [
                  const DropdownMenuItem(value: '', child: Text('（默认）')),
                  // Driver capability list, not the server's: MySQL 8.x
                  // advertises utf8mb3, which sqlx's client rejects at open time
                  // (round34 P2-02). See connectionCharsetsFor().
                  for (final cs in connectionCharsetsFor('mysql'))
                    DropdownMenuItem(value: cs, child: Text(cs)),
                ],
              ),
            ),
          FormRow(
            label: '仅显示数据库',
            child: Field(label: '', controller: _onlyDb, hint: 'db1,db2'),
          ),
          FormRow(
            label: '隐藏数据库',
            child: Field(label: '', controller: _hideDb, hint: 'test%,tmp%'),
          ),
        ],
        FormRow(
          label: '颜色',
          child: _ColorPicker(
            value: _color,
            onChanged: (v) {
              _color = v;
              _rebuildForm();
            },
          ),
        ),
      ],
    );
  }

  /// "SSL" tab: MySQL's mode + verification pair, or libpq's single sslmode.
  Widget _sslTab({required bool isSqlite, required bool isPostgres}) {
    if (isSqlite) {
      return Text('SQLite 没有网络连接，SSL 设置不适用。', style: kSmallMuted);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isPostgres) ...[
          FormRow(
            label: 'SSL 模式（libpq）',
            child: SelectBox<String>(
              value: _pgSsl,
              onChanged: (v) {
                _pgSsl = v ?? 'disable';
                _rebuildForm();
              },
              items: [
                for (final m in _pgSslModes)
                  DropdownMenuItem(value: m, child: Text(m)),
              ],
            ),
          ),
          if (_pgSsl != 'disable') ...[
            ..._sslFileRows(),
            Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Text(
                'require 只加密、不校验证书；要防止中间人攻击请选 verify-ca 或 verify-full。',
                style: kSmallMuted,
              ),
            ),
          ],
        ] else ...[
          FormRow(
            label: 'SSL 模式',
            child: SelectBox<String>(
              value: _sslMode,
              onChanged: (v) {
                _sslMode = v ?? 'disable';
                if (_sslMode == 'disable') {
                  _sslVerify = 'require';
                } else if (_sslVerify == 'require') {
                  _sslVerify = 'verify-full';
                }
                _rebuildForm();
              },
              items: [
                for (final m in _sslModes)
                  DropdownMenuItem(value: m, child: Text(m)),
              ],
            ),
          ),
          if (_sslMode != 'disable') ...[
            FormRow(
              label: '证书校验',
              child: SelectBox<String>(
                value: _sslVerify,
                onChanged: (v) {
                  _sslVerify = v ?? 'verify-full';
                  _rebuildForm();
                },
                items: [
                  for (final v in _sslVerifyModes)
                    DropdownMenuItem(value: v, child: Text(v)),
                ],
              ),
            ),
            ..._sslFileRows(),
            if (_sslVerify != 'require' && _sslCa.text.trim().isEmpty)
              Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Text(
                  '校验需要 CA 证书：不填会改用系统根证书，自签证书请指定 CA 文件。',
                  style: kSmallMuted,
                ),
              ),
          ],
        ],
        Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text(
            '建议：先用 require 确认能加密连接，再用 verify-ca / verify-full 校验证书。',
            style: kSmallMuted,
          ),
        ),
      ],
    );
  }


  /// "SSH" tab: jump host used to reach the database.
  Widget _sshTab({required bool isSqlite}) {
    if (isSqlite) {
      return Text('SQLite 是本地文件，无需 SSH 隧道。', style: kSmallMuted);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CheckBox(
          label: '通过 SSH 隧道连接（跳板机）',
          value: _sshEnabled,
          onChanged: (v) {
            _sshEnabled = v;
            _rebuildForm();
          },
        ),
        Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: Text(
            '数据库地址从跳板机解析：可填写只监听远程 127.0.0.1 或内网地址的数据库。'
            '本机 3306 等端口不会被暴露。',
            style: kSmallMuted,
          ),
        ),
        if (_sshEnabled) ...[
          FormRow(
            label: 'SSH 主机',
            child: Field(key: const ValueKey('ssh-host'), label: '', controller: _sshHost, hint: 'jump.example.com'),
          ),
          FormRow(
            label: 'SSH 端口',
            child: Field(
              label: '',
              key: const ValueKey('ssh-port'),
              controller: _sshPort,
              numeric: true,
              hint: '22',
            ),
          ),
          FormRow(
            label: 'SSH 用户名',
            child: Field(key: const ValueKey('ssh-user'), label: '', controller: _sshUser, hint: 'deploy'),
          ),
          FormRow(
            label: '认证方式',
            child: SelectBox<String>(
              value: _sshAuth,
              onChanged: (v) {
                _sshAuth = v ?? 'password';
                _rebuildForm();
              },
              items: const [
                DropdownMenuItem(value: 'password', child: Text('密码')),
                DropdownMenuItem(value: 'keyfile', child: Text('私钥文件')),
                DropdownMenuItem(value: 'agent', child: Text('ssh-agent')),
              ],
            ),
          ),
          if (_sshAuth == 'password') ...[
            FormRow(
              label: 'SSH 密码',
              child: Field(
                label: '',
                key: const ValueKey('ssh-password'),
                controller: _sshPassword,
                obscure: true,
              ),
            ),
          ] else if (_sshAuth == 'keyfile') ...[
            FormRow(
              label: '私钥文件',
              child: Field(
                label: '',
                controller: _sshKey,
                hint: '~/.ssh/id_ed25519（加密私钥请在下方填口令）',
                trailing: IconBtn(Icons.folder_open_outlined,
                tooltip: '浏览',
                    small: true,
                    onPressed: () => _pickPath(_sshKey, '选择 SSH 私钥')),
              ),
            ),
            FormRow(
              label: '私钥口令',
              child: Field(
                label: '',
                controller: _sshPassword,
                obscure: true,
                hint: '留空表示私钥未加密',
              ),
            ),
          ] else ...[
            FormRow(
              label: 'agent 套接字',
              child: Field(
                label: '',
                controller: _sshAgent,
                hint: '留空使用 SSH_AUTH_SOCK',
              ),
            ),
          ],
          FormRow(
            label: '主机密钥策略',
            child: SelectBox<String>(
              value: _sshHostKeyPolicy,
              onChanged: (v) {
                _sshHostKeyPolicy = v ?? 'accept-new';
                _rebuildForm();
              },
              items: const [
                DropdownMenuItem(
                    value: 'accept-new', child: Text('首次连接信任并记住')),
                DropdownMenuItem(value: 'strict', child: Text('仅信任已保存指纹')),
              ],
            ),
          ),
          // N-11: the fingerprint was computed and persisted but had no control
          // in the form, so the user could neither review nor correct it.
          FormRow(
            label: '主机密钥指纹',
            child: Field(
              label: '',
              key: const ValueKey('ssh-host-key'),
              controller: _sshHostKey,
              hint: 'SHA256:…（测试连接成功后自动填入，也可手动粘贴）',
              trailing: _sshHostKey.text.trim().isEmpty
                  ? null
                  : Btn(
                      '清空',
                      small: true,
                      onPressed: () {
                        _sshHostKey.clear();
                        _rebuildForm();
                      },
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              _sshHostKeyPolicy == 'strict'
                  ? 'strict 模式必须先有指纹：点「测试连接」自动填入，或手动粘贴 '
                      'SHA256 指纹；指纹缺失或不匹配都会拒绝连接。'
                  : '首次连接会用「测试连接」确认跳板机身份并自动填入指纹；'
                      '保存后指纹会被固定，以后指纹变化会拒绝连接。',
              style: kSmallMuted,
            ),
          ),
        ],
      ],
    );
  }


}
  /// "常规" tab: driver-specific addressing plus visibility rules.
/// Swatch row for the connection colour.
///
/// The web form had an `<input type="color">`; the desktop editor dropped it, so
/// every connection fell back to the same orange dot and the colour that
/// Connections.vue and the sidebar use to tell connections apart was not
/// editable at all. A fixed palette keeps it a single click and stays inside the
/// colours the rest of the UI uses.
class _ColorPicker extends StatelessWidget {
  const _ColorPicker({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  static const List<String> _palette = <String>[
    '#f29111',
    '#0f80cc',
    '#1e7e46',
    '#c0392b',
    '#7a5bb0',
    '#8a5a00',
    '#37455c',
    '#6b7684',
  ];

  @override
  Widget build(BuildContext context) {
    final current = value.trim().toUpperCase();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final hex in _palette)
          GestureDetector(
            onTap: () => onChanged(hex),
            child: Tooltip(
              message: hex,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: _parse(hex),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: current == hex.toUpperCase()
                        ? AppColors.bodyText
                        : AppColors.border,
                    width: current == hex.toUpperCase() ? 2 : 1,
                  ),
                ),
              ),
            ),
          ),
        Text(value.isEmpty ? '默认' : value, style: kSmallMuted),
      ],
    );
  }

  static Color _parse(String hex) {
    final cleaned = hex.replaceAll('#', '').trim();
    final parsed = int.tryParse(cleaned, radix: 16);
    if (cleaned.length == 6 && parsed != null) return Color(0xFF000000 | parsed);
    return const Color(0xFF8AA0BD);
  }
}

/// A path that shortens in the middle and keeps the full value on hover.
///
/// The connection card used a plain [EllipsisText], which clips at the end: a
/// SQLite connection rendered as `/Users/…/langu…`, hiding the database file
/// name — the only part that tells two SQLite connections apart (round34
/// P3-04). This keeps the head and the last path segment, measures how much of
/// the head fits against the real constraint (no hard-coded character count or
/// width), and attaches the untruncated path as the hover tooltip whenever
/// anything was dropped.
class MiddleEllipsisText extends StatelessWidget {
  const MiddleEllipsisText(
    this.text, {
    super.key,
    this.style,
    this.tooltipMaxWidth = 520,
  });

  final String text;
  final TextStyle? style;
  final double tooltipMaxWidth;

  static const String _ellipsis = '…';

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    // Measure with the style the text is really painted with: the inherited
    // size / family from DefaultTextStyle is part of the width, and guessing
    // it would split the path in the wrong place.
    final effective = DefaultTextStyle.of(context).style.merge(style);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        if (!maxWidth.isFinite ||
            maxWidth <= 0 ||
            _width(text, effective) <= maxWidth) {
          return _body(text, effective);
        }
        return Tooltip(
          // A path is a data value, never UI copy.
          message: text,
          noTranslate: true,
          constraints: BoxConstraints(
            maxWidth: tooltipMaxWidth,
            maxHeight: kTooltipConstraints.maxHeight,
          ),
          waitDuration: const Duration(milliseconds: 300),
          child: _body(_shorten(text, maxWidth, effective), effective),
        );
      },
    );
  }

  Widget _body(String value, TextStyle style) => Text(
        value,
        style: style,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
      );

  double _width(String value, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.width;
  }

  /// Keep the last path segment whole and as much of the head as fits.
  String _shorten(String value, double maxWidth, TextStyle style) {
    final separator = value.lastIndexOf(RegExp(r'[/\\]'));
    final tail = separator >= 0 ? value.substring(separator) : '';
    if (tail.isEmpty || _width('$_ellipsis$tail', style) > maxWidth) {
      return _shortenTail(value, maxWidth, style);
    }
    var low = 0;
    var high = separator;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (_width('${value.substring(0, mid)}$_ellipsis$tail', style) <=
          maxWidth) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    var head = value.substring(0, low);
    // Never leave a dangling separator in front of the ellipsis.
    while (head.endsWith('/') || head.endsWith(r'\')) {
      head = head.substring(0, head.length - 1);
    }
    return '$head$_ellipsis$tail';
  }

  /// The file name alone does not fit: drop characters from the front instead.
  String _shortenTail(String value, double maxWidth, TextStyle style) {
    var low = 0;
    var high = value.length;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (_width('$_ellipsis${value.substring(value.length - mid)}', style) <=
          maxWidth) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return '$_ellipsis${value.substring(value.length - low)}';
  }
}

