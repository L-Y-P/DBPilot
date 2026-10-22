import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;

import 'api.dart';
import 'app_version.dart';
import 'i18n.dart';
import 'nav.dart';
import 'theme.dart';

/// Central UI state, replacing the web app's Pinia session + explorer stores.
///
/// The web version had to bootstrap a login, a session cookie and a per-user
/// connection list. The desktop app has none of that: this holds the current
/// connection, the database tree and the cached metadata, and notifies the
/// shell when any of it changes.
class AppState extends ChangeNotifier {
  AppState._();
  static final AppState instance = AppState._();

  String title = kAppName;
  String dataDir = '';
  bool bootstrapped = false;
  String? bootstrapError;

  // ------------------------------------------------------------- appearance

  /// Light/dark preference: `system` (default), `light` or `dark`.
  String themeMode = kDefaultThemeMode;

  /// Identity preset id for the theme colour picker (see [kThemePresets]).
  String themeColor = kDefaultThemePreset;

  /// Effective directory new backups are written to. Resolved by the Rust core
  /// from `Settings.backup_dir` (falling back to <data dir>/backups).
  String backupDir = '';

  // ------------------------------------------------------------ performance

  /// Whether the data grids measure every column from its content.
  ///
  /// Measuring a column costs one [TextPainter] layout per sampled cell, which
  /// is what keeps a wide result readable but also the most expensive part of
  /// the first frame. Turning this off pins every column to
  /// [kFixedGridColumnWidth] instead: no measuring pass at all, at the price of
  /// a uniform column width. Persisted as `auto_column_width`.
  bool autoColumnWidth = true;

  /// Whether very long cell values are rendered as a short preview first.
  ///
  /// A TEXT/JSON column can hold kilobytes per row; laying all of it out in
  /// every built cell is pure waste when the cell is 160-320px wide. With this
  /// on, a value longer than [kLazyBigFieldThreshold] renders its first
  /// [kLazyBigFieldPreview] characters plus a "… N 字符" badge; the whole value
  /// stays reachable on hover and in the double-click viewer. Persisted as
  /// `lazy_big_fields`.
  bool lazyBigFields = true;

  /// Version of this desktop bundle (see app_version.dart).
  String appVersion = kAppVersion;

  /// Version reported by the Rust core crate.
  String coreVersion = '';

  // ------------------------------------------------------------- connection

  Json? connection;
  String? serverVersion;

  /// Schemas of the active database (PostgreSQL) or all databases (MySQL).
  List<Json> databases = <Json>[];

  /// Physical databases of the instance, for the sidebar tree.
  ///
  /// PostgreSQL now connects to the instance rather than to one preselected
  /// database, so this list is the source of truth for the tree; `databases`
  /// stays the schema list of whichever database is active.
  List<Json> instanceDatabases = <Json>[];
  bool instanceDatabasesLoading = false;

  /// Namespaces the server rejected with a permission error during this
  /// session. They are hidden from every picker/tree so the UI stops offering
  /// a database the account cannot open; a reconnect clears the set.
  final Set<String> deniedDatabases = <String>{};

  bool isDatabaseDenied(String name) => deniedDatabases.contains(name);

  /// Remember that [name] is not accessible and refresh the tree.
  void markDatabaseDenied(String name) {
    if (name.isEmpty) return;
    if (deniedDatabases.add(name)) notifyListeners();
  }

  void clearDeniedDatabases() {
    if (deniedDatabases.isEmpty) return;
    deniedDatabases.clear();
    notifyListeners();
  }

  List<Json> _visibleDatabases(List<Json> list) => list
      .where((entry) => !deniedDatabases.contains((entry['name'] ?? '').toString()))
      .toList();

  /// Actions the database refused with a permission error during this session.
  ///
  /// The server probe only reports instance-level capabilities, so it cannot
  /// tell whether this account may e.g. CREATE TABLE in one schema. Instead of
  /// offering a button that can only come back with MySQL's terse
  /// "1142 ... command denied", a failed action is remembered and its button is
  /// greyed with the reason. The key is connection + database + action, and a
  /// reconnect / explicit refresh clears the set so a new GRANT is picked up.
  final Set<String> deniedActions = <String>{};

  /// The database's explanation for a denied action (shown in the tooltip).
  final Map<String, String> deniedActionReasons = <String, String>{};

  String _deniedActionKey(String database, String action) =>
      '${connection?['id'] ?? ''}|$database|$action';

  bool isActionDenied(String database, String action) =>
      deniedActions.contains(_deniedActionKey(database, action));

  String? deniedActionReason(String database, String action) =>
      deniedActionReasons[_deniedActionKey(database, action)];

  /// Remember a permission failure so the matching button can be disabled.
  ///
  /// Returns true the first time the action was denied, so the caller can
  /// notify only when something actually changed.
  bool markActionDenied(String database, String action, Object? error) {
    if (database.isEmpty || action.isEmpty) return false;
    final key = _deniedActionKey(database, action);
    final reason = error?.toString() ?? '';
    if (reason.isNotEmpty) deniedActionReasons[key] = reason;
    if (deniedActions.add(key)) {
      notifyListeners();
      return true;
    }
    return false;
  }

  void clearDeniedActions() {
    if (deniedActions.isEmpty && deniedActionReasons.isEmpty) return;
    deniedActions.clear();
    deniedActionReasons.clear();
    notifyListeners();
  }

  /// Physical database selected in the explorer tree.
  String? activeDatabase;

  /// Session default schema (`SHOW search_path` on PostgreSQL; the database
  /// name on MySQL). Shown in the SQL console and database page.
  String searchPath = '';

  bool databasesLoading = false;

  /// Cached per-connection metadata; refreshed only after a reconnect, exactly
  /// like the web session store.
  Json? metaOptions;

  /// What the connected database account may do on the server (see
  /// `privileges.rs`). Probed on connect and whenever the user refreshes, so a
  /// GRANT applied while the app is open is picked up instead of leaving the UI
  /// locked behind a stale capability set.
  Json? serverPrivileges;

  /// Bumped whenever a table/database is created or dropped so the sidebar and
  /// views refresh their cached lists (the web explorer.version counter).
  int explorerVersion = 0;

  String get connectionLabel =>
      (connection?['label'] ?? '').toString().isEmpty
          ? '未连接'
          : connection!['label'].toString();

  String get driverLabel => (connection?['driver_label'] ?? '').toString();

  String get driver => (connection?['driver'] ?? '').toString();

  bool get connected => connection != null;

  /// Namespaces that are server internals rather than user data.
  ///
  /// They stay browsable from the sidebar (a DBA may genuinely need to look at
  /// them), but they must never be chosen by default and must not be offered as
  /// a structure-sync source or target: comparing against
  /// `information_schema` produces an empty diff and used to make 结构同步 look
  /// like it did nothing.
  static const Set<String> systemNamespaces = <String>{
    'information_schema',
    'performance_schema',
    'mysql',
    'sys',
    'pg_catalog',
    'pg_toast',
    'pg_temp_1',
    'pg_toast_temp_1',
    'template0',
    'template1',
    'postgres',
  };

  bool isSystemNamespace(String name) => systemNamespaces.contains(name);

  /// User namespaces, in the order the server returned them.
  List<Json> get userDatabases => databases
      .where((d) => !isSystemNamespace((d['name'] ?? '').toString()))
      .toList();

  /// User databases of the instance (the tree still lists system ones; this
  /// getter is for pickers and defaults).
  List<Json> get userInstanceDatabases => instanceDatabases
      .where((d) => !isSystemNamespace((d['name'] ?? '').toString()))
      .toList();

  /// The schema-level namespace word, used by structure sync.
  ///
  /// Callers embed it in a sentence; the resulting string is translated as a
  /// whole (trLiteral / pickText), so the word itself stays Chinese here.
  String get namespaceWord => isPostgres ? '模式' : '数据库';
  String get namespaceWordWithSchema => isPostgres ? '模式（schema）' : '数据库';

  /// Physical database word (always 数据库).
  String get databaseWord => '数据库';

  /// Short label for the active database, for page headers.
  String get activeDatabaseLabel =>
      activeDatabase ?? (isSqlite ? 'main' : '');

  /// Schemas from the current search_path, in precedence order.
  ///
  /// PostgreSQL returns `"$user", public`; the implicit user schema and the
  /// system catalogs are not useful for highlighting a tree node.
  List<String> get searchPathSchemas {
    final result = <String>[];
    for (final raw in searchPath.split(',')) {
      var name = raw.trim();
      if (name.isEmpty) continue;
      if (name.length >= 2 &&
          name.startsWith('"') &&
          name.endsWith('"')) {
        name = name.substring(1, name.length - 1).replaceAll('""', '"');
      }
      final lower = name.toLowerCase();
      if (lower == '\$user' ||
          lower == 'pg_catalog' ||
          lower.startsWith('pg_temp') ||
          lower.startsWith('pg_toast')) {
        continue;
      }
      if (!result.contains(name)) result.add(name);
    }
    return result;
  }

  /// First explicit schema in the search_path (the `默认` tree marker).
  String? get searchPathDefaultSchema {
    final schemas = searchPathSchemas;
    return schemas.isEmpty ? null : schemas.first;
  }

  /// Human label for the session's default schema, for page subtitles.
  ///
  /// PostgreSQL always starts with `public` in its search_path unless the
  /// account changed it, so an empty or not-yet-probed search_path must not
  /// render as "unknown": that was the P13 subtitle. MySQL has no schema
  /// concept here (its databases are the namespaces), so it has no such label.
  String get defaultSchemaLabel {
    if (isPostgres) return searchPathDefaultSchema ?? 'public';
    return '';
  }

  /// Cached PG search_path probe in flight (avoids one request per rebuild).
  bool _searchPathRefreshing = false;

  /// Fill [searchPath] after a PostgreSQL switch that did not carry it.
  ///
  /// Expanding a database in the tree, restoring a route or refreshing the
  /// explorer can change [activeDatabase] without a `selectDatabase` response,
  /// which used to leave the page subtitle with an empty search_path. The
  /// subtitle falls back to `public`, and this fills the real value when it is
  /// cheap to do so; failure is not fatal.
  Future<void> ensureSearchPath() async {
    if (!isPostgres || _searchPathRefreshing) return;
    final database = activeDatabase;
    if (database == null || database.isEmpty || searchPath.isNotEmpty) return;
    _searchPathRefreshing = true;
    try {
      final res = await Api.instance.listSchemas(database);
      final path = (res['search_path'] ?? '').toString();
      if (path.isNotEmpty) {
        searchPath = path;
        notifyListeners();
      }
    } catch (_) {
      // The subtitle already falls back to public; nothing else depends on it.
    } finally {
      _searchPathRefreshing = false;
    }
  }

  /// The database to preselect, mirroring session.defaultDatabase.
  ///
  /// Order: the connection's own database when it is a browsable namespace,
  /// PostgreSQL's `public`, then the first non-system namespace. The previous
  /// fallback was `databases.first`, which on a fresh MySQL connection is
  /// `information_schema` — every page then opened on a schema with no user
  /// tables.
  String? get defaultDatabase {
    String? nameOf(Json entry) => entry['name']?.toString();
    final names = databases.map(nameOf).whereType<String>().toList();
    // MySQL's active database is the one selected in the tree / SQL console.
    if (isMysql &&
        activeDatabase != null &&
        names.contains(activeDatabase) &&
        !isSystemNamespace(activeDatabase!)) {
      return activeDatabase;
    }
    final fromConnection = connection?['database'];
    if (fromConnection is String &&
        fromConnection.isNotEmpty &&
        names.contains(fromConnection) &&
        !isSystemNamespace(fromConnection)) {
      return fromConnection;
    }
    if (isPostgres && names.contains('public')) return 'public';
    for (final name in names) {
      if (!isSystemNamespace(name)) return name;
    }
    return names.isEmpty ? null : names.first;
  }

  /// True when the active driver is MySQL, which decides identifier quoting
  /// and which designer features are offered.
  bool get isMysql => driver == 'mysql';
  bool get isPostgres => driver == 'postgres';
  bool get isSqlite => driver == 'sqlite';

  /// Quote one identifier the way the active driver expects. Mirrors the
  /// web helper used by Table.vue / Builder.vue.
  String quoteIdent(String name) {
    if (isMysql) {
      return '`${name.replaceAll('`', '``')}`';
    }
    return '"${name.replaceAll('"', '""')}"';
  }

  String qualify(String db, String table) =>
      '${quoteIdent(db)}.${quoteIdent(table)}';

  // -------------------------------------------------------------- lifecycle

  Future<void> bootstrap(String resolvedDataDir) async {
    try {
      final init = await Api.init(resolvedDataDir);
      if (init['ok'] != true) {
        bootstrapError = (init['error'] ?? '初始化失败').toString();
        bootstrapped = true;
        notifyListeners();
        return;
      }
      dataDir = (init['data_dir'] ?? '').toString();
      final config = await Api.instance.appConfig();
      title = (config['title'] ?? kAppName).toString();
      backupDir = (config['backup_dir'] ?? '').toString();
      try {
        coreVersion = Api.instance.coreVersion();
      } catch (_) {
        coreVersion = (config['version'] ?? '').toString();
      }
      final settings = await Api.instance.getSettings();
      final lang = (settings['language'] ?? 'zh').toString();
      I18n.setLang(lang == 'en' ? AppLang.en : AppLang.zh);
      themeMode = normalizeThemeMode((settings['theme'] ?? kDefaultThemeMode).toString());
      themeColor =
          normalizeThemePreset((settings['theme_color'] ?? kDefaultThemePreset).toString());
      // settings['update_url'] is intentionally ignored: the update manifest
      // address is compiled in (see update_source.dart), and the Rust Settings
      // field stays only so an older settings.json still loads unchanged.
      // The performance switches default to ON: a settings file written before
      // they existed (or a Rust core that does not know them yet) simply omits
      // the keys, and omitting them must not silently degrade the grid.
      autoColumnWidth = readBoolSetting(settings['auto_column_width']);
      lazyBigFields = readBoolSetting(settings['lazy_big_fields']);
      // Apply the persisted appearance before the first frame is painted with
      // the default palette, so a dark-mode user never sees a white flash.
      applyAppearance();
      final active = await Api.instance.activeConnection();
      _applyConnection(active['connection'] as Json?);
      if (connection != null) {
        await refreshInstanceDatabases();
        await refreshDatabases();
        await refreshPrivileges();
      }
      bootstrapped = true;
      notifyListeners();
    } catch (e) {
      bootstrapError = e.toString();
      bootstrapped = true;
      notifyListeners();
    }
  }

  Future<void> setLanguage(AppLang lang) async {
    I18n.setLang(lang);
    notifyListeners();
    await _patchSettings(lang == AppLang.en ? 'en' : 'zh');
  }

  /// Persist one preference into settings.json, ignoring write failures.
  ///
  /// The settings file is read-modify-written as a whole because that is the
  /// only shape the bridge exposes; a failed write must never break the UI, so
  /// errors are swallowed exactly like the previous language-only setter did.
  Future<Json> _patchSettings(Object? languageValue,
      {Map<String, Object?>? patch}) async {
    try {
      final settings = await Api.instance.getSettings();
      if (languageValue != null) settings['language'] = languageValue;
      if (patch != null) settings.addAll(patch);
      final saved = await Api.instance.saveSettings(settings);
      final resolved = (saved['backup_dir'] ?? '').toString();
      if (resolved.isNotEmpty) backupDir = resolved;
      return saved;
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// Rebuild the active [AppColors] palette from the current preferences.
  ///
  /// `system` follows the platform brightness reported by the engine, so the
  /// app tracks a macOS appearance change without a restart.
  void applyAppearance() {
    AppColors.applyAppearance(
      mode: themeMode,
      presetId: themeColor,
      platformBrightness:
          WidgetsBinding.instance.platformDispatcher.platformBrightness,
    );
  }

  /// Switch between the system / light / dark appearance.
  Future<void> setThemeMode(String mode) async {
    final next = normalizeThemeMode(mode);
    if (next != themeMode) {
      themeMode = next;
      applyAppearance();
      notifyListeners();
    }
    await _patchSettings(null, patch: <String, Object?>{'theme': next});
  }

  /// Switch the identity colour preset (kThemePresets).
  Future<void> setThemeColor(String presetId) async {
    final next = normalizeThemePreset(presetId);
    if (next != themeColor) {
      themeColor = next;
      applyAppearance();
      notifyListeners();
    }
    await _patchSettings(null, patch: <String, Object?>{'theme_color': next});
  }

  /// Change where backups are stored. An empty [path] restores the default
  /// (<data dir>/backups); the Rust core creates the directory and reloads the
  /// backup index, then reports the effective path back.
  Future<void> setBackupDir(String path) async {
    final trimmed = path.trim();
    final saved = await _patchSettings(
      null,
      patch: <String, Object?>{'backup_dir': trimmed.isEmpty ? null : trimmed},
    );
    final resolved = (saved['backup_dir'] ?? '').toString();
    // A rejected path (not absolute, unwritable) keeps the previous value; the
    // core only echoes what it actually accepted.
    if (resolved.isNotEmpty || trimmed.isEmpty) {
      final next = resolved.isNotEmpty ? resolved : defaultBackupDir();
      if (next != backupDir) {
        backupDir = next;
        notifyListeners();
      }
    }
  }

  /// The <data dir>/backups path the core falls back to.
  String defaultBackupDir() =>
      dataDir.isEmpty ? '' : '$dataDir/backups';

  /// A persisted boolean setting, tolerant of a missing / unexpected value.
  ///
  /// The performance fields are written by the Rust core; a core that predates
  /// them returns no key at all, and a hand-edited settings file can hold a
  /// string. Both mean "keep the default" rather than "turn the feature off".
  ///
  /// Public so the tolerance itself is testable without a Rust core that
  /// already knows the fields.
  static bool readBoolSetting(Object? value) {
    if (value == null) return true;
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = value.toString().trim().toLowerCase();
    if (text == 'false' || text == '0' || text == 'no' || text == 'off') {
      return false;
    }
    return true;
  }

  /// Turn content-based column measuring on/off (see [autoColumnWidth]).
  ///
  /// Applies to the already-built grids immediately: every grid listens to this
  /// notifier, so the next frame re-lays the columns out. The write is
  /// best-effort, like every other preference.
  Future<void> setAutoColumnWidth(bool value) async {
    if (value != autoColumnWidth) {
      autoColumnWidth = value;
      notifyListeners();
    }
    await _patchSettings(
        null, patch: <String, Object?>{'auto_column_width': value});
  }

  /// Turn the long-value preview on/off (see [lazyBigFields]).
  Future<void> setLazyBigFields(bool value) async {
    if (value != lazyBigFields) {
      lazyBigFields = value;
      notifyListeners();
    }
    await _patchSettings(null, patch: <String, Object?>{'lazy_big_fields': value});
  }

  // ------------------------------------------------------------- connections

  /// Copy the connection-level fields returned by connect/active.
  void _applyConnection(Json? conn) {
    connection = conn;
    final active = (conn?['active_database'] ?? '').toString();
    activeDatabase = active.isEmpty ? null : active;
    searchPath = (conn?['search_path'] ?? '').toString();
  }

  Future<void> connect(String id) async {
    try {
      final res = await Api.instance.connectConnection(id);
      Navigation.instance.resetTree();
      _applyConnection(res['connection'] as Json?);
      serverVersion = (res['server_version'] ?? '').toString();
      metaOptions = null;
      serverPrivileges = null;
      // A fresh connection may see databases / perform actions the previous
      // account could not; learned permission denials are connection-scoped.
      clearDeniedDatabases();
      deniedActions.clear();
      deniedActionReasons.clear();
      await refreshInstanceDatabases();
      await refreshDatabases();
      // Probe the account's server capabilities up front: the server page must
      // know which panels to disable before the user clicks into them.
      await refreshPrivileges();
      notifyListeners();
    } catch (e) {
      // The Rust side only swaps the active binding after the new server
      // accepted the pool, but a later step (initial database, version probe)
      // can still fail after the swap. Reconcile instead of leaving the UI on a
      // connection the backend no longer has (or vice versa), then rethrow so
      // the page can show the real error.
      try {
        await syncActive();
      } catch (_) {
        // Keep the original error; the sync is best-effort.
      }
      rethrow;
    }
  }

  /// Adopt whatever connection the Rust side currently has open.
  ///
  /// Creating or importing a SQLite database makes that database's connection
  /// the active one on the Rust side, so the UI has to re-read the binding
  /// instead of keeping the previous connection label and database list.
  Future<void> syncActive() async {
    final active = await Api.instance.activeConnection();
    Navigation.instance.resetTree();
    _applyConnection(active['connection'] as Json?);
    serverVersion = null;
    metaOptions = null;
    serverPrivileges = null;
    if (!connected) {
      _clearExplorerState();
      notifyListeners();
      return;
    }
    await refreshInstanceDatabases();
    await refreshDatabases();
    await refreshPrivileges();
    notifyListeners();
  }

  /// Drop every cached explorer value that belongs to a connection. Used when
  /// the active connection is deleted/disconnected: the shell must not paint a
  /// stale database tree, and the next connection must start clean.
  void _clearExplorerState() {
    databases = <Json>[];
    instanceDatabases = <Json>[];
    instanceDatabasesLoading = false;
    activeDatabase = null;
    searchPath = '';
    databasesLoading = false;
    databaseGroups = <Json>[];
    sqliteUnreadable = <Json>[];
    sqliteFolder = '';
    sqlitePrimary = '';
    sqlitePrimaryExists = true;
    sqliteFolderExists = true;
    deniedActions.clear();
    deniedActionReasons.clear();
    explorerVersion++;
    Navigation.instance.resetTree();
  }

  Future<void> disconnect() async {
    await Api.instance.disconnect();
    connection = null;
    serverVersion = null;
    metaOptions = null;
    serverPrivileges = null;
    _clearExplorerState();
    notifyListeners();
  }

  /// Re-read the account's server capabilities.
  ///
  /// Call this after anything that could change them (reconnect, a GRANT made
  /// from the account editor, the user pressing 刷新) so the app never keeps
  /// showing a permission the database has already granted, or vice versa.
  Future<void> refreshPrivileges() async {
    if (!connected) {
      serverPrivileges = null;
      notifyListeners();
      return;
    }
    try {
      serverPrivileges = await Api.instance.serverPrivileges();
    } catch (_) {
      // An account that cannot be probed gets a conservative capability set
      // rather than a broken app; the server page explains what is missing.
      serverPrivileges = <String, dynamic>{
        'can_manage_accounts': false,
        'can_view_processes': false,
        'can_view_status': true,
        'can_kill_processes': false,
        'requirements': <dynamic>[],
      };
    }
    notifyListeners();
  }

  /// Capability name (as used by `requirements`) -> JSON flag from the probe.
  static const Map<String, String> _capabilityFlags = <String, String>{
    'accounts': 'can_manage_accounts',
    'database': 'can_create_database',
    'processes': 'can_view_processes',
    'status': 'can_view_status',
    'kill': 'can_kill_processes',
  };

  /// Test hook: the JSON flag behind a capability name.
  static String? capabilityFlagForTest(String capability) =>
      _capabilityFlags[capability];

  /// True when the probed capabilities allow `capability`.
  ///
  /// `capability` is the short name the requirements list uses ("accounts",
  /// "processes", "status", "kill"); the probe reports it as a `can_*` flag, so
  /// the two are mapped here rather than at every call site.
  ///
  /// Defaults to true while the probe has not completed, so a slow probe does
  /// not flash every panel as disabled.
  bool can(String capability) {
    final caps = serverPrivileges;
    if (caps == null) return true;
    final flag = _capabilityFlags[capability];
    if (flag == null) return true;
    return caps[flag] == true;
  }

  /// The database account the app is connected as (user@host / role), or an
  /// empty string before the first probe completes.
  String get dbAccount =>
      (serverPrivileges?['account'] ?? '').toString();

  /// The privilege the account would need for `capability`, if it lacks it.
  String? requiredPrivilege(String capability) {
    final list = serverPrivileges?['requirements'];
    if (list is! List) return null;
    for (final raw in list) {
      if (raw is Map && raw['capability'] == capability) {
        return (raw['privilege'] ?? '').toString();
      }
    }
    return null;
  }

  /// SQLite: the folder browsed by the current connection.
  String sqliteFolder = '';

  /// SQLite: the connection's primary database file (the file opened as `main`).
  String sqlitePrimary = '';

  /// SQLite: false when the primary file disappeared from disk.
  bool sqlitePrimaryExists = true;

  /// SQLite: false when the connection's folder is gone (unmounted, removed).
  bool sqliteFolderExists = true;

  /// SQLite: how many database files one connection may attach at once.
  int sqliteAttachLimit = 10;

  /// SQLite: databases grouped by directory, for the sidebar.
  ///
  /// A folder import scans recursively, so one connection can span several
  /// directories; each becomes one top-level node with its files underneath.
  List<Json> databaseGroups = <Json>[];

  /// SQLite: files in the folder that are not usable databases.
  ///
  /// They are reported instead of listed, because opening one fails and the
  /// user needs to know which file is broken rather than seeing a database that
  /// silently does nothing.
  List<Json> sqliteUnreadable = <Json>[];

  /// SQLite: databases that exist but were not opened because the engine's
  /// ATTACH limit was reached — a performance hint, not an error.
  List<Json> get sqliteOverflow => sqliteUnreadable
      .where((u) => u['overflow'] == true)
      .toList();

  /// SQLite: files in the folder that are not valid databases at all.
  List<Json> get sqliteCorrupt => sqliteUnreadable
      .where((u) => u['overflow'] != true)
      .toList();

  /// Reload the physical database list (the sidebar tree's first level).
  Future<void> refreshInstanceDatabases() async {
    if (!connected || isSqlite) {
      instanceDatabases = <Json>[];
      instanceDatabasesLoading = false;
      notifyListeners();
      return;
    }
    instanceDatabasesLoading = true;
    notifyListeners();
    try {
      final res = await Api.instance.instanceDatabases();
      instanceDatabases = _visibleDatabases(_mapList(res['databases']));
      final active = (res['active_database'] ?? '').toString();
      if (active.isNotEmpty) activeDatabase = active;
      if (activeDatabase == null && instanceDatabases.isNotEmpty) {
        final first = instanceDatabases.firstWhere(
          (d) => !isSystemNamespace((d['name'] ?? '').toString()),
          orElse: () => instanceDatabases.first,
        );
        activeDatabase = (first['name'] ?? '').toString();
      }
      if (connection != null) {
        connection!['driver'] = res['driver'];
        connection!['driver_label'] = res['driver_label'];
      }
    } catch (_) {
      instanceDatabases = <Json>[];
    } finally {
      instanceDatabasesLoading = false;
    }
    notifyListeners();
  }

  /// Switch the active physical database.
  ///
  /// PostgreSQL returns the schemas of the new database (and its search_path),
  /// so the sidebar, sync and SQL console update in one round trip. MySQL keeps
  /// its full database list and only changes the selected pool.
  Future<void> selectDatabase(String database) async {
    final Json res;
    try {
      res = await Api.instance.selectDatabase(database);
    } catch (e) {
      // A database the account may not open must stop appearing in the tree,
      // otherwise every later action repeats the same permission error.
      if (isPermissionError(e)) markDatabaseDenied(database);
      rethrow;
    }
    activeDatabase = (res['database'] ?? database).toString();
    searchPath = (res['search_path'] ?? '').toString();
    if (isPostgres) {
      final schemas = res['schemas'];
      if (schemas is List) databases = _mapList(schemas);
    }
    metaOptions = null;
    explorerVersion++;
    Navigation.instance.clearTablesCache();
    Navigation.instance.clearExpandedNamespaces();
    notifyListeners();
  }

  /// Reload the database list.
  ///
  /// [refreshFiles] re-reads the SQLite folder (and rebuilds that connection's
  /// pool) so a file added or removed outside the app is picked up. It only
  /// touches the currently connected connection.
  Future<void> refreshDatabases({bool refreshFiles = false}) async {
    if (!connected) {
      databases = <Json>[];
      databaseGroups = <Json>[];
      sqliteUnreadable = <Json>[];
      sqliteFolder = '';
      sqlitePrimary = '';
      notifyListeners();
      return;
    }
    databasesLoading = true;
    notifyListeners();
    try {
      // A SQLite connection browses a folder, not a server-side namespace list,
      // so its databases come from the file system scan.
      if (driver == 'sqlite') {
        _applySqlite(await Api.instance.sqliteDatabases(refresh: refreshFiles));
      } else {
        final res = await Api.instance.databases();
        final list = res['databases'];
        databases = _visibleDatabases(list is List
            ? list.map((e) => Map<String, dynamic>.from(e as Map)).toList()
            : <Json>[]);
        databaseGroups = <Json>[];
        sqliteUnreadable = <Json>[];
        sqliteFolder = '';
        sqlitePrimary = '';
        if (connection != null) {
          connection!['driver'] = res['driver'];
          connection!['driver_label'] = res['driver_label'];
        }
        if (isMysql &&
            (activeDatabase == null ||
                !databases.any(
                    (d) => (d['name'] ?? '').toString() == activeDatabase))) {
          activeDatabase = defaultDatabase;
          if (activeDatabase != null) searchPath = activeDatabase!;
        }
      }
    } finally {
      databasesLoading = false;
      notifyListeners();
    }
  }

  void _applySqlite(Json res) {
    sqliteFolder = (res['folder'] ?? '').toString();
    sqlitePrimary = (res['primary'] ?? '').toString();
    sqlitePrimaryExists = res['primary_exists'] != false;
    sqliteFolderExists = res['folder_exists'] != false;
    sqliteAttachLimit = (res['attach_limit'] as num?)?.toInt() ?? 10;
    databases = _mapList(res['databases']);
    databaseGroups = _mapList(res['groups']);
    sqliteUnreadable = _mapList(res['unreadable']);
  }

  static List<Json> _mapList(Object? raw) {
    if (raw is! List) return <Json>[];
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// SQLite namespace for a database file path.
  ///
  /// The primary file is addressed as `main`; an attached file as the alias the
  /// driver gave it. Routing by file path does not work because a path is not a
  /// SQL identifier, so the namespace comes from the scanned list.
  String databaseNameForPath(String path) {
    for (final db in databases) {
      if ((db['path'] ?? '').toString() == path) {
        return (db['name'] ?? '').toString();
      }
    }
    return 'main';
  }

  /// Cached metadata options, loaded once per connection like the web store.
  Future<Json> loadMetaOptions() async {
    if (metaOptions != null) return metaOptions!;
    final res = await Api.instance.metaOptions();
    metaOptions = res;
    notifyListeners();
    return res;
  }

  /// Invalidate cached lists after a schema change.
  void bumpExplorer() {
    explorerVersion++;
    notifyListeners();
  }

  void notify() => notifyListeners();
}
