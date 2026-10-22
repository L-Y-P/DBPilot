import 'package:flutter/foundation.dart';

import 'api.dart';

/// A lightweight route model replacing vue-router.
///
/// The web app had URL routes (db/:db, db/:db/table/:table, builder, sql, ...).
/// A desktop window has no address bar, so the same shape is kept in memory:
/// the shell reads this to decide which view to render, and the sidebar drives
/// it. Keeping the web route names makes the ported views line up one-to-one.
class AppRoute {
  const AppRoute(this.section, {this.db, this.table});

  final String section;
  final String? db;
  final String? table;

  static const connections = AppRoute('connections');
  static const builder = AppRoute('builder');
  static const sql = AppRoute('sql');
  static const server = AppRoute('server');
  static const backups = AppRoute('backups');
  static const sync = AppRoute('sync');
  static const history = AppRoute('history');

  static AppRoute database(String db) => AppRoute('database', db: db);
  /// Named tableRoute because a static member cannot share the name of
  /// the instance field table.
  static AppRoute tableRoute(String db, String table) =>
      AppRoute('table', db: db, table: table);

  /// Routes that need an open database connection, mirroring the web guard's
  /// NEEDS_CONNECTION list plus the /db/* prefix.
  bool get needsConnection =>
      section == 'builder' ||
      section == 'sql' ||
      section == 'server' ||
      section == 'backups' ||
      section == 'sync' ||
      section == 'database' ||
      section == 'table';

  @override
  bool operator ==(Object other) =>
      other is AppRoute &&
      other.section == section &&
      other.db == db &&
      other.table == table;

  @override
  int get hashCode => Object.hash(section, db, table);
}

/// The shell's navigation state, observable by the sidebar and topbar.
class Navigation extends ChangeNotifier {
  Navigation._();
  static final Navigation instance = Navigation._();

  AppRoute _route = AppRoute.connections;
  AppRoute get route => _route;

  /// Namespaces (schemas / MySQL databases) whose table list is expanded.
  final Set<String> expanded = <String>{};

  /// Physical databases whose schema level is expanded in the sidebar.
  final Set<String> expandedDatabases = <String>{};

  /// Schemas per physical database, loaded lazily when a database is opened.
  final Map<String, List<Json>> schemasByDb = <String, List<Json>>{};

  /// Databases whose schema list is currently being loaded.
  final Set<String> loadingSchemas = <String>{};

  /// Schema-load failures, keyed by database.
  final Map<String, String> schemaErrors = <String, String>{};

  /// Cached table lists per namespace, invalidated by the explorer version.
  final Map<String, List<String>> tablesByDb = <String, List<String>>{};

  /// The last database the user actually opened.
  ///
  /// Routes such as `sync` and `backups` have no `db`, so by the time the
  /// structure-sync page is built the current route no longer names the
  /// database being browsed. Remembering it keeps "source" on that database
  /// instead of falling back to the first one.
  String? _lastDb;
  String? get lastDatabase => _lastDb;

  void go(AppRoute route) {
    if (_route == route) return;
    _route = route;
    if (route.db != null) {
      _lastDb = route.db;
      expanded.add(route.db!);
    }
    notifyListeners();
  }

  void toggleExpanded(String db) {
    if (expanded.contains(db)) {
      expanded.remove(db);
    } else {
      expanded.add(db);
    }
    notifyListeners();
  }

  void expandDatabase(String db) {
    if (expandedDatabases.add(db)) notifyListeners();
  }

  void expandNamespace(String namespace) {
    if (expanded.add(namespace)) notifyListeners();
  }

  void toggleExpandedDatabase(String db) {
    if (expandedDatabases.contains(db)) {
      expandedDatabases.remove(db);
    } else {
      expandedDatabases.add(db);
    }
    notifyListeners();
  }

  void setSchemas(String db, List<Json> schemas) {
    schemasByDb[db] = schemas;
    schemaErrors.remove(db);
    loadingSchemas.remove(db);
    notifyListeners();
  }

  void setSchemaLoading(String db, bool loading) {
    if (loading) {
      loadingSchemas.add(db);
      schemaErrors.remove(db);
    } else {
      loadingSchemas.remove(db);
    }
    notifyListeners();
  }

  void setSchemaError(String db, String message) {
    schemaErrors[db] = message;
    loadingSchemas.remove(db);
    notifyListeners();
  }

  /// Forget every tree cache after a connection switch.
  void resetTree() {
    expanded.clear();
    expandedDatabases.clear();
    schemasByDb.clear();
    schemaErrors.clear();
    loadingSchemas.clear();
    tablesByDb.clear();
    _lastDb = null;
    notifyListeners();
  }

  void clearSchemas({String? db}) {
    if (db == null) {
      schemasByDb.clear();
      schemaErrors.clear();
      loadingSchemas.clear();
    } else {
      schemasByDb.remove(db);
      schemaErrors.remove(db);
      loadingSchemas.remove(db);
    }
    notifyListeners();
  }

  /// Collapse the schema/table level when the active database changes.
  ///
  /// The remembered namespace also belongs to the previous database; keeping it
  /// would make structure sync default to a schema that does not exist in the
  /// newly selected database.
  void clearExpandedNamespaces() {
    expanded.clear();
    _lastDb = null;
    notifyListeners();
  }

  /// Public invalidation hook; notifyListeners is protected so callers
  /// outside this class cannot use it directly.
  void notify() => notifyListeners();

  void clearTablesCache() {
    tablesByDb.clear();
    notifyListeners();
  }
}
