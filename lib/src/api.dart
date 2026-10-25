import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';

import 'query_metrics.dart';
import 'rust/api.dart' as rapi;
import 'rust/api/backup.dart' as rbackup;
import 'rust/api/connections.dart' as rconn;
import 'rust/api/data_import.dart' as rdata_import;
import 'rust/api/explorer.dart' as rexplorer;
import 'rust/api/export.dart' as rexport;
import 'rust/api/files.dart' as rfiles;
import 'rust/api/query.dart' as rquery;
import 'rust/api/query_types.dart';
import 'rust/api/server.dart' as rserver;
import 'rust/api/sqlite.dart' as rsqlite;
import 'rust/api/sync.dart' as rsync;

export 'rust/api/query_types.dart' show QueryEvent;

/// Thrown for every failed bridge call. The message is the user-facing text the
/// Rust side produced, which is exactly what the web API used to put in the
/// error JSON field, so views can keep showing it verbatim.
class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// JSON map alias; the Rust handlers return serde_json::Value which FRB
/// surfaces as Object?, decoded here into a Map.
typedef Json = Map<String, dynamic>;

Json _asMap(Object? value) {
  if (value == null) return <String, dynamic>{};
  if (value is Map) return Map<String, dynamic>.from(value);
  if (value is String) {
    final decoded = jsonDecode(value);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  }
  throw ApiException('返回值格式无效');
}

List<Json> _asList(Object? value) {
  if (value == null) return <Json>[];
  final raw = value is String ? jsonDecode(value) : value;
  if (raw is List) {
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }
  return <Json>[];
}

/// The startup store error reported by `listConnections`, when the saved
/// connections file could not be read/parsed at startup.
///
/// Returns null for the normal case (including a missing `store_error` field),
/// which is exactly what the connection manager uses to mean "show no banner".
String? connectionsStoreErrorFromPayload(Object? payload) {
  if (payload is! Map) return null;
  final raw = payload['store_error'];
  if (raw == null) return null;
  final text = raw.toString().trim();
  return text.isEmpty ? null : text;
}

/// Wrap a bridge call so any Rust error becomes an ApiException carrying the
/// original message, instead of leaking the FRB wrapper type into the UI.
Future<T> _guard<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on AnyhowException catch (e) {
    throw ApiException(_cleanMessage(e.message));
  } catch (e) {
    throw ApiException(_cleanMessage(e.toString()));
  }
}

/// FRB prefixes anyhow messages with AnyhowException(...); strip that so the
/// user sees the same sentence the web API returned.
///
/// The Rust side already collapses sqlx's duplicated "Caused by:" chain (see
/// `error.rs`); this also trims the generic "error returned from database:"
/// prefix for messages that reached Dart through another path (e.g. a ResultSet
/// error written before the normalisation existed).
String _cleanMessage(String raw) {
  var text = raw.trim();
  const prefix = 'AnyhowException(';
  if (text.startsWith(prefix)) {
    text = text.substring(prefix.length);
    if (text.endsWith(')')) text = text.substring(0, text.length - 1);
  }
  final cut = text.indexOf('\n\nCaused by:');
  if (cut > 0) text = text.substring(0, cut);
  text = text.trim();
  const dbPrefix = 'error returned from database: ';
  if (text.startsWith(dbPrefix)) text = text.substring(dbPrefix.length).trim();
  return text;
}

/// Format an error for display, adding the "this is a database permission"
/// explanation when the message is one.
///
/// Views use this instead of `e.toString()` so a permission failure reads as
/// something the user can act on (ask for a GRANT) rather than a driver dump.
String describeDbError(Object? error) {
  final text = error?.toString() ?? '';
  if (!isPermissionError(text)) return text;
  if (text.contains('请让数据库管理员') || text.contains('请让管理员')) return text;
  // The backend hint is already English? No: the Rust layer writes Chinese and
  // the UI translator turns the composed string into English when needed.
  return '$text\n提示：这是数据库账号自身的权限限制，不是应用出错。'
      '请让数据库管理员为该账号授权，或在连接管理里改用有权限的账号。';
}

/// Test hook for [_cleanMessage].
String cleanErrorMessageForTest(String raw) => _cleanMessage(raw);

/// True when a message describes a missing database privilege.
///
/// The UI uses this to offer the "需要服务器权限" explanation instead of the raw
/// driver text, and to mark the affected panel as unavailable.
bool isPermissionError(Object? error) {
  final text = error?.toString() ?? '';
  const markers = [
    'command denied',
    'Access denied',
    'permission denied',
    '权限不足',
    '没有',
    '所需',
    '42501',
    '1044',
    '1142',
    '1143',
    '1227',
  ];
  return markers.any(text.contains);
}

/// 从 ALTER TABLE 的原始返回里取出失败的语句错误。
///
/// Rust 的 `explorer.alter_table` 把 DDL 失败写在返回体里：
/// `{failed: 1, results: [{statement, error, ...}]}`，并不抛异常。这里的规则：
///
///   * 优先用 `results[].error` 的原文（保留技术细节，供 UI / 日志排查）；
///   * 只有 `failed` 计数、没有 error 文本时给出兜底消息，保证失败不会静默。
List<String> alterTableErrors(Json result) {
  final out = <String>[];
  for (final row in _asList(result['results'])) {
    final value = row['error'];
    if (value == null) continue;
    final text = value.toString().trim();
    if (text.isEmpty || text == 'null') continue;
    out.add(text);
  }
  if (out.isEmpty) {
    final failed = result['failed'];
    if (failed is num && failed > 0) {
      final count = failed.toInt();
      out.add(
        count == 1
            ? '语句执行失败（数据库未返回错误详情）'
            : '$count 条语句执行失败（数据库未返回错误详情）',
      );
    }
  }
  return out;
}

/// Typed facade over the generated bindings, mirroring web/src/api.ts so the
/// ported views read almost identically.
class Api {
  Api._();
  static final Api instance = Api._();

  // ---------------------------------------------------------------- lifecycle

  static Future<Json> init(String dataDir) async =>
      _asMap(await _guard(() async => rapi.initApp(dataDir: dataDir)));

  Future<Json> appConfig() async => _asMap(await _guard(rapi.appConfig));

  /// Version of the Rust core crate (shown in the settings dialog).
  String coreVersion() => rapi.coreVersion();

  Future<Json> getSettings() async => _asMap(await _guard(rapi.getSettings));

  Future<Json> saveSettings(Json settings) async =>
      _asMap(await _guard(() => rapi.saveSettings(settings: settings)));

  Future<Json> saveWindowState(Json patch) async =>
      _asMap(await _guard(() => rfiles.saveWindowState(body: patch)));

  Future<Json> dataDir() async => _asMap(await _guard(rfiles.dataDir));

  // -------------------------------------------------------------- connections

  Future<List<Json>> connections() async {
    // The Rust handler returns { "connections": [...] } (it mirrors the web
    // /connections payload). Unwrapping the envelope matters: decoding the
    // envelope as a list silently yielded an empty list, so every saved
    // connection disappeared from the manager after a save.
    final res = await _guard(rconn.listConnections);
    return _asList(_asMap(res)['connections']);
  }

  /// Why the saved connections could not be loaded at startup, if
  /// connections.json was corrupt.
  ///
  /// The Rust store preserves the bad file as `connections.json.corrupt-*` and
  /// reports the reason in the payload's `store_error`; surfacing only that
  /// field keeps [connections] unchanged for every existing caller. Null means
  /// the store loaded normally.
  Future<String?> connectionsStoreError() async {
    final res = await _guard(rconn.listConnections);
    return connectionsStoreErrorFromPayload(_asMap(res));
  }

  Future<Json> createConnection(Json entry) async =>
      _asMap(await _guard(() => rconn.createConnection(entry: entry)));

  Future<Json> updateConnection(String id, Json entry) async =>
      _asMap(await _guard(() => rconn.updateConnection(id: id, entry: entry)));

  Future<Json> deleteConnection(String id) async =>
      _asMap(await _guard(() => rconn.deleteConnection(id: id)));

  Future<Json> testConnection(Json probe) async =>
      _asMap(await _guard(() => rconn.testConnection(probe: probe)));

  Future<Json> connectConnection(String id) async =>
      _asMap(await _guard(() => rconn.connectConnection(id: id)));

  Future<Json> disconnect() async => _asMap(await _guard(rconn.disconnect));

  Future<Json> activeConnection() async =>
      _asMap(await _guard(rconn.activeConnection));

  // ----------------------------------------------------------------- explorer

  /// Schemas of the active database (MySQL: the database list).
  Future<Json> databases() async => _asMap(await _guard(rexplorer.listDatabases));

  /// Physical databases of the instance, for the sidebar tree.
  Future<Json> instanceDatabases() async =>
      _asMap(await _guard(rexplorer.instanceDatabases));

  /// Switch the active database; returns its schemas plus the search_path.
  Future<Json> selectDatabase(String db) async =>
      _asMap(await _guard(() => rexplorer.selectDatabase(database: db)));

  /// Schemas of one database without changing the active database.
  Future<Json> listSchemas(String db) async =>
      _asMap(await _guard(() => rexplorer.listSchemas(database: db)));

  Future<Json> createSchema(String name) async =>
      _asMap(await _guard(() => rexplorer.createSchema(name: name)));

  Future<Json> dropSchema(String schema) async =>
      _asMap(await _guard(() => rexplorer.dropSchema(schema: schema)));

  // ------------------------------------------------------------ sqlite files

  /// Database files of the active SQLite connection, grouped by directory.
  ///
  /// `refresh` rebuilds the connection's pool first, which is what makes a file
  /// added to (or removed from) the folder appear. Only the current connection
  /// is refreshed.
  Future<Json> sqliteDatabases({bool refresh = false}) async =>
      _asMap(await _guard(() => rsqlite.sqliteDatabases(refresh: refresh)));

  /// Create a new database file in `dir` and register it as a connection.
  Future<Json> sqliteCreateDatabase({
    required String dir,
    required String name,
    String? content,
  }) async =>
      _asMap(
          await _guard(() => rsqlite.sqliteCreateDatabase(body: {
                'dir': dir,
                'name': name,
                'content': content,
              })));

  /// Import existing database files, or every database file inside a folder.
  Future<Json> sqliteImport(List<String> paths, {bool connect = true}) async =>
      _asMap(await _guard(() => rsqlite.sqliteImport(
          body: {'paths': paths, 'connect': connect})));

  /// Delete database files from disk.
  Future<Json> sqliteDeleteFile(List<String> paths) async => _asMap(
      await _guard(() => rsqlite.sqliteDeleteFile(body: {'paths': paths})));

  Future<Json> metaOptions() async => _asMap(await _guard(rexplorer.metaOptions));

  Future<Json> createDatabase(Json body, {bool dryRun = false}) async =>
      _asMap(await _guard(() => rexplorer.createDatabase(body: body, dryRun: dryRun)));

  Future<Json> dropDatabase(String db) async =>
      _asMap(await _guard(() => rexplorer.dropDatabase(database: db)));

  Future<List<Json>> tables(String db) async {
    final res = await _guard(() => rexplorer.listTables(database: db));
    return _asList(_asMap(res)['tables']);
  }

  /// Tables of an explicit database/schema without switching the active one.
  Future<List<Json>> tablesIn(String database, {String? schema}) async {
    final res = await _guard(
        () => rexplorer.listTablesIn(database: database, schema: schema));
    return _asList(_asMap(res)['tables']);
  }

  Future<Json> createTable(String db, Json body, {bool dryRun = false}) async =>
      _asMap(await _guard(
          () => rexplorer.createTable(database: db, body: body, dryRun: dryRun)));

  Future<Json> dropTable(String db, String table) async =>
      _asMap(await _guard(() => rexplorer.dropTable(database: db, table: table)));

  Future<Json> truncate(String db, String table) async =>
      _asMap(await _guard(() => rexplorer.truncateTable(database: db, table: table)));

  Future<Json> structure(String db, String table) async =>
      _asMap(await _guard(() => rexplorer.tableStructure(database: db, table: table)));

  Future<Json> data(String db, String table, Json params) async =>
      _asMap(await _guard(
          () => rexplorer.tableData(database: db, table: table, params: params)));

  Future<Json> changeRow(String db, String table, Json body) async =>
      _asMap(await _guard(
          () => rexplorer.changeRow(database: db, table: table, body: body)));

  /// Apply several row changes in **one transaction** ("保存全部改动").
  ///
  /// [changes] is the array built by `buildRowChanges` (one UPDATE per touched
  /// row). The Rust side validates every statement before it opens the
  /// transaction, and any server error rolls the whole batch back.
  Future<Json> applyRowChanges(
          String db, String table, List<Map<String, dynamic>> changes) async =>
      _asMap(await _guard(() => rexplorer.applyRowChanges(
          database: db, table: table, changes: changes)));

  Future<Json> builderSchema(String db) async =>
      _asMap(await _guard(() => rexplorer.builderSchema(database: db)));

  /// Builder metadata for several namespaces at once (advanced cross-database
  /// queries). Returns {schemas: [...], denied: [...]}; a namespace the
  /// account may not open lands in denied instead of failing the call.
  Future<Json> builderSchemaMulti(List<String> databases) async => _asMap(
      await _guard(() => rexplorer.builderSchemaMulti(databases: databases)));

  Future<Json> objects(String db) async =>
      _asMap(await _guard(() => rexplorer.listObjects(database: db)));

  Future<Json> createObject(String db, String sql) async =>
      _asMap(await _guard(
          () => rexplorer.createObject(database: db, body: {'sql': sql})));

  Future<Json> objectDefinition(String db, String kind, String name) async =>
      _asMap(await _guard(
          () => rexplorer.objectDefinition(database: db, kind: kind, name: name)));

  Future<Json> dropObject(String db, String kind, String name) async =>
      _asMap(await _guard(
          () => rexplorer.dropObject(database: db, kind: kind, name: name)));

  Future<Json> ddl(String db, String table) async =>
      _asMap(await _guard(() => rexplorer.tableDdl(database: db, table: table)));

  /// Raw ALTER TABLE batch result.
  ///
  /// Rust deliberately returns failures **inside** the payload
  /// (`{failed, results: [{statement, error, ...}]}`) instead of throwing, so
  /// callers that render the per-statement result (the table designer) can show
  /// what ran. Views where "did the DDL apply?" is a yes/no question must use
  /// [alterTableChecked] instead — otherwise a failed ALTER looks successful
  /// (round 51 P0-1: silent "create suggested foreign key").
  Future<Json> alterTable(String db, String table, Json body) async =>
      _asMap(await _guard(
          () => rexplorer.alterTable(database: db, table: table, body: body)));

  /// [alterTable] but throws when any statement failed.
  ///
  /// The exception message starts with the database's own error text so the
  /// technical detail is preserved; views add the localized prefix + the
  /// actionable hint from [describeDbError] at the catch site.
  Future<Json> alterTableChecked(String db, String table, Json body) async {
    final result = await alterTable(db, table, body);
    final errors = alterTableErrors(result);
    if (errors.isEmpty) return result;
    throw ApiException(errors.join('\n'));
  }

  // -------------------------------------------------------------------- query

  /// Run a SQL script (one or many statements) and return the legacy payload.
  ///
  /// Consumes [queryStream] and folds the events back into the flat Map shape
  /// every view consumes ([aggregateQueryEvents] wraps the same aggregator):
  /// rows are converted batch by batch while the driver is still reading them,
  /// so the whole result set never exists as one `QueryResponseDto` on the
  /// bridge. On the live-MySQL benchmark this measured 1.4–1.9× faster than
  /// the typed round trip (LIMIT 50000: 169 ms → 116 ms).
  Future<Json> query(String sql, [String? database]) async {
    final wall = Stopwatch()..start();
    final runId = QueryMetrics.instance.beginRun(sql: sql, source: 'api');
    try {
      final payload = _asMap(
        await _guard(() async {
          final aggregator = _QueryEventAggregator();
          final stream =
              rquery.runQueryStream(body: {'sql': sql, 'database': database});
          await for (final event in stream) {
            aggregator.add(event);
          }
          return aggregator.finish();
        }),
      );
      wall.stop();
      QueryMetrics.instance.finishRun(
        runId: runId,
        resultRows: resultRowsOf(payload),
        truncated: payload['truncated'] == true,
        rustElapsedMs: (payload['elapsed_ms'] as num?)?.toInt() ?? 0,
        wallMs: wall.elapsedMilliseconds,
        statementCount: (payload['statement_count'] as num?)?.toInt() ?? 0,
      );
      return payload;
    } catch (error) {
      wall.stop();
      QueryMetrics.instance.finishRun(
        runId: runId,
        resultRows: 0,
        truncated: false,
        rustElapsedMs: 0,
        wallMs: wall.elapsedMilliseconds,
        statementCount: 0,
        failed: true,
      );
      rethrow;
    }
  }

  /// Streaming variant of [query] for the SQL console (optimisation layer 3).
  ///
  /// Emits a `started` event per statement, zero or more `batch` events while
  /// the driver is still reading rows, one `statement_done` per statement and
  /// a final `done` with the run summary. A top-level failure arrives as a
  /// `failed` event (not a thrown exception), so the console can keep whatever
  /// it already painted.
  Stream<QueryEvent> queryStream(String sql, [String? database]) =>
      rquery.runQueryStream(body: {'sql': sql, 'database': database});

  Future<Json> explain(String sql, [String? database]) async =>
      _asMap(await _guard(() => rquery.explain(
            body: {'sql': sql, 'database': database},
          )));

  /// Cancel the PostgreSQL query currently running from the SQL console.
  Future<Json> cancelQuery() async =>
      _asMap(await _guard(rquery.cancelQuery));

  /// One page of query history plus the total number of stored entries.
  ///
  /// Pagination lives in Rust: shipping all stored SQL over FFI is what made the
  /// history view slow after large imports, so the view asks for exactly one
  /// page at a time.
  Future<Json> historyPage({int limit = 50, int offset = 0}) async {
    final res =
        await _guard(() => rquery.historyList(limit: limit, offset: offset));
    return _asMap(res);
  }

  /// Convenience wrapper for callers/tests that only need the entries.
  Future<List<Json>> history([int limit = 200]) async {
    final page = await historyPage(limit: limit);
    return _asList(page['history']);
  }

  Future<Json> clearHistory() async => _asMap(await _guard(rquery.historyClear));

  // ------------------------------------------------------------------- export

  Future<Json> exportTable(String db, String table, Json params) async =>
      _asMap(await _guard(() =>
          rexport.exportTable(database: db, table: table, params: params)));

  Future<Json> exportDatabase(String db) async =>
      _asMap(await _guard(() => rexport.exportDatabase(database: db)));

  /// Export the rows of an arbitrary SELECT (the query builder's result).
  ///
  /// Uses the same streaming exchange-format renderers as the table page, so
  /// CSV / JSON / XML / HTML / TXT / Excel / Markdown all work. params.path
  /// streams straight to that file; without it a bounded preview comes back.
  Future<Json> exportQuery(String db, String sql, Json params) async =>
      _asMap(await _guard(() => rexport.exportQuery(
            database: db,
            sql: sql,
            params: params,
          )));

  Future<Json> importSql(String db, String sql) async =>
      _asMap(await _guard(() => rexport.importSql(database: db, sql: sql)));

  Future<List<Json>> exportFormats() async => _asList(rexport.exportFormats());

  // ------------------------------------------------------------ data import

  /// Detect a data file's format and suggest read/field rules.
  Future<Json> importInspect(String path) async =>
      _asMap(await _guard(() => rdata_import.importInspect(path: path)));

  /// Split + parse the first few records with the current read/field rule.
  Future<Json> importPreview(String path, Json params) async => _asMap(
      await _guard(() => rdata_import.importPreview(path: path, params: params)));

  /// Parse the first data record, map it onto the table and INSERT it inside a
  /// transaction that is rolled back (the "试插入" step).
  Future<Json> importProbe(String db, String table, Json params) async =>
      _asMap(await _guard(() => rdata_import.importProbe(
            database: db,
            table: table,
            params: params,
          )));

  /// Start a full-file validation job; poll [importJobStatus] for progress.
  Future<Json> importValidateStart(Json params) async => _asMap(
      await _guard(() => rdata_import.importValidateStart(params: params)));

  /// Start the real import job; poll [importJobStatus] for progress.
  Future<Json> importExecuteStart(Json params) async => _asMap(
      await _guard(() => rdata_import.importExecuteStart(params: params)));

  /// Poll an import/validation/SQL-file job.
  Future<Json> importJobStatus(String jobId) async => _asMap(
      await _guard(() => rdata_import.importJobStatus(jobId: jobId)));

  /// Ask a running job to stop; the task returns partial results.
  Future<Json> importJobCancel(String jobId) async => _asMap(
      await _guard(() => rdata_import.importJobCancel(jobId: jobId)));

  /// Bounded preview of a SQL script (never loads the whole file).
  Future<Json> sqlFilePreview(String path, {int maxBytes = 256 * 1024}) async =>
      _asMap(await _guard(() => rdata_import.sqlFilePreview(
            path: path,
            maxBytes: BigInt.from(maxBytes),
          )));

  /// Execute a SQL file statement by statement, streaming from disk.
  Future<Json> sqlFileExecuteStart(String db, String path, Json options) async =>
      _asMap(await _guard(() => rdata_import.sqlFileExecuteStart(
            database: db,
            path: path,
            options: options,
          )));

  // ------------------------------------------------------------------ backups

  Future<List<Json>> backups() async {
    final res = await _guard(rbackup.listBackups);
    return _asList(_asMap(res)['backups']);
  }

  Future<Json> createBackup(Json body) async =>
      _asMap(await _guard(() => rbackup.createBackup(body: body)));

  Future<Json> readBackup(String id) async =>
      _asMap(await _guard(() => rbackup.readBackup(id: id)));

  Future<Json> backupPath(String id) async =>
      _asMap(await _guard(() => rfiles.backupPath(id: id)));

  Future<Json> restoreBackup(String id) async =>
      _asMap(await _guard(() => rbackup.restoreBackup(id: id)));

  Future<Json> deleteBackup(String id) async =>
      _asMap(await _guard(() => rbackup.deleteBackup(id: id)));

  // --------------------------------------------------------------------- sync

  Future<Json> schemaDiff(Json body) async =>
      _asMap(await _guard(() => rsync.schemaDiff(body: body)));

  Future<Json> schemaSync(Json body) async =>
      _asMap(await _guard(() => rsync.schemaSync(body: body)));

  // ------------------------------------------------------------------- server

  /// What the connected database account may do (accounts / processes / kill).
  ///
  /// Probed on connect and on refresh so the UI can disable the panels the
  /// account has no privilege for and name the GRANT it needs, instead of
  /// letting the user hit a raw "1142 SELECT command denied" later.
  Future<Json> serverPrivileges() async =>
      _asMap(await _guard(rserver.serverPrivileges));

  Future<Json> status() async => _asMap(await _guard(rserver.status));

  Future<List<Json>> variables([String? filter]) async {
    final res = await _guard(() => rserver.variables(params: {'filter': filter}));
    return _asList(_asMap(res)['variables']);
  }

  Future<List<Json>> processes() async {
    final res = await _guard(rserver.processes);
    return _asList(_asMap(res)['processes']);
  }

  Future<Json> killProcess(int id) async =>
      _asMap(await _guard(() => rserver.killProcess(id: id)));

  Future<Json> dbUsers() async => _asMap(await _guard(rserver.listDbUsers));

  Future<Json> userPrivileges([String? user]) async =>
      _asMap(await _guard(
          () => rserver.userPrivileges(params: {'user': user})));

  Future<Json> createDbUser(Json body, {bool dryRun = false}) async =>
      _asMap(await _guard(() => rserver.createDbUser(body: body, dryRun: dryRun)));

  Future<Json> updateDbUser(String user, String host, Json body,
          {bool dryRun = false}) async =>
      _asMap(await _guard(() => rserver.updateDbUser(
            user: user, host: host, body: body, dryRun: dryRun,
          )));

  Future<Json> dropDbUser(String user, String host) async =>
      _asMap(await _guard(() => rserver.dropDbUser(user: user, host: host)));

  Future<Json> dbUserGrants(String user, String host) async =>
      _asMap(await _guard(() => rserver.dbUserGrants(user: user, host: host)));

  // -------------------------------------------------------------------- files

  Future<String> readTextFile(String path) async =>
      _guard(() => rfiles.readTextFile(path: path));

  Future<String> writeTextFile(String path, String content) async =>
      _guard(() => rfiles.writeTextFile(path: path, content: content));
}

/// The web app rendered null cells as empty text and binary cells as a
/// [BLOB n bytes] chip. Kept here so every grid shares one implementation.
String displayCell(Object? value) {
  if (value == null) return '';
  if (value is Map) {
    final binary = value['__binary__'];
    if (binary != null) return '[BLOB ${value['len'] ?? 0} bytes]';
    return jsonEncode(value);
  }
  return value.toString();
}

/// True when a decoded cell is the binary marker object.
bool isBinaryCell(Object? value) =>
    value is Map && value.containsKey('__binary__');

/// Formats a byte count the way the web UI did (B / KB / MB / GB, 2 decimals).
String formatBytes(num? bytes) {
  if (bytes == null) return '—';
  var value = bytes.toDouble();
  if (value <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  if (i == 0) return '${value.toInt()} B';
  return '${value.toStringAsFixed(2)} ${units[i]}';
}

/// Debug helper used by the startup self-check.
void logApiError(Object error) {
  debugPrint('[rust-myadmin] $error');
}

// ------------------------------------------------------- query result adapter

// The generated Dart bindings do not emit the Rust `CELL_KIND_*` /
// `EVENT_KIND_*` constants, so the numeric tags are pinned here.
//
// `CellValue.kind`: 0=null, 1=bool, 2=int, 3=float, 4=text, 5=bytes.
const int cellKindNull = 0;
const int cellKindBool = 1;
const int cellKindInt = 2;
const int cellKindFloat = 3;
const int cellKindText = 4;
const int cellKindBytes = 5;

// `QueryEvent.kind`: 0=started, 1=batch, 2=statement_done, 3=done, 4=failed.
const int queryEventStarted = 0;
const int queryEventBatch = 1;
const int queryEventStatementDone = 2;
const int queryEventDone = 3;
const int queryEventFailed = 4;

/// Type-safe dispatch over [CellValue.kind].
///
/// The kind codes are a hand-written convention (FRB does not generate the
/// Rust `CELL_KIND_*` constants), so a missed case must fail loudly instead of
/// silently falling through. `tools/check_api_surface.py` keeps the Rust/Dart
/// constant tables in sync; this extension keeps every switch exhaustive.
extension CellValueX on CellValue {
  T when<T>({
    required T Function() null_,
    required T Function(bool value) bool_,
    required T Function(int value) int_,
    required T Function(double value) float_,
    required T Function(String value) text_,
    required T Function(Uint8List value) bytes_,
  }) {
    switch (kind) {
      case cellKindNull:
        return null_();
      case cellKindBool:
        return bool_(boolValue!);
      case cellKindInt:
        return int_(intValue!);
      case cellKindFloat:
        return float_(floatValue!);
      case cellKindText:
        return text_(textValue!);
      case cellKindBytes:
        return bytes_(bytesValue!);
      default:
        throw StateError(
            'unknown CellValue.kind $kind (Rust/Dart kind tables out of sync?)');
    }
  }
}

/// Convert one typed cell back to the legacy JSON cell shape.
///
/// Shared by [aggregateQueryEvents] (which rebuilds the legacy Map payload the
/// non-console views consume) and the SQL console's streaming renderer, so both
/// paths decode a cell exactly the same way. Binary cells keep the old
/// `{"__binary__": base64, "len": n}` marker object [displayCell] and
/// [isBinaryCell] understand.
Object? cellValueToJson(CellValue cell) => cell.when<Object?>(
      null_: () => null,
      bool_: (value) => value,
      int_: (value) => value,
      float_: (value) => value,
      text_: (value) => value,
      bytes_: (value) => <String, dynamic>{
        '__binary__': base64Encode(value),
        'len': value.length,
      },
    );
/// The legacy `columns` list shape ([{name, type_name}, ...]).
List<Json> columnsToJson(List<ColumnDto> columns) => List<Json>.generate(
      columns.length,
      (index) => <String, dynamic>{
        'name': columns[index].name,
        'type_name': columns[index].typeName,
      },
      growable: false,
    );

/// Folds streaming console events back into the legacy flat JSON payload that
/// `run_query` returns.
///
/// Optimisation layer 3 moved the console to [Api.queryStream]; [Api.query]
/// feeds the same events through this aggregator instead of asking Rust for a
/// whole `QueryResponseDto` at once. Streaming keeps the peak at one batch of
/// `CellValue` objects on both sides of the bridge, while the Map contract
/// every non-console view consumes stays field-for-field identical:
/// `results[].{columns,rows,row_count,last_insert_id,statement,kind,error,
/// truncated}` plus the flattened summary (`statement_count`, `failed`,
/// `elapsed_ms`, `driver`, `search_path`, `database`, `use_database`,
/// `truncated`, `row_limit`).
class _QueryEventAggregator {
  final List<Json> _results = <Json>[];
  QuerySummaryDto? _summary;

  /// Empty result map for one statement; the stream events fill it in.
  static Json _emptyResult() => <String, dynamic>{
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

  void add(QueryEvent event) {
    switch (event.kind) {
      case queryEventStarted:
        {
          final index = event.statementIndex.toInt();
          _ensureResultSlot(index);
          _results[index] = _emptyResult()
            ..['statement'] = event.statement ?? '';
        }
      case queryEventBatch:
        {
          final index = event.statementIndex.toInt();
          _ensureResultSlot(index);
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
          // A batch means this statement returns rows: mark the kind now so a
          // console rendering the payload can paint before statement_done.
          if (event.columns.isNotEmpty || event.rows.isNotEmpty) {
            result['kind'] = 'rows';
          }
          if (event.truncated) result['truncated'] = true;
        }
      case queryEventStatementDone:
        {
          final meta = event.result;
          if (meta == null) return;
          final index = event.statementIndex.toInt();
          _ensureResultSlot(index);
          final result = _results[index];
          result['statement'] = meta.statement;
          result['kind'] = meta.kind;
          result['row_count'] = meta.rowCount;
          result['last_insert_id'] = meta.lastInsertId;
          result['error'] = meta.error;
          result['truncated'] = meta.truncated;
          // A rows statement that returned zero rows emits no batch at all, so
          // its columns only arrive here.
          final columns = result['columns'];
          if (columns is List && columns.isEmpty && meta.columns.isNotEmpty) {
            result['columns'] = columnsToJson(meta.columns);
          }
        }
      case queryEventDone:
        _summary = event.summary;
      case queryEventFailed:
        // Same contract as the old `run_query`: a top-level failure threw
        // (an [ApiException] via [_guard]) rather than returning a payload.
        throw ApiException(_cleanMessage(event.message ?? ''));
      default:
        break;
    }
  }

  Json finish() {
    final summary = _summary;
    final results = List<Json>.of(_results, growable: false);
    return <String, dynamic>{
      'results': results,
      'statement_count': summary?.statementCount ?? results.length,
      'failed': summary?.failed ?? 0,
      'elapsed_ms': summary?.elapsedMs ?? 0,
      'driver': summary?.driver ?? '',
      'search_path': summary?.searchPath,
      'database': summary?.database,
      'use_database': summary?.useDatabase,
      'truncated': summary?.truncated ?? false,
      'row_limit': summary?.rowLimit ?? 0,
    };
  }
}

/// Fold a completed [Api.queryStream] event sequence into the legacy flat JSON
/// payload.
///
/// Pure (no FFI, no database), which is what lets the adapter be unit tested;
/// [Api.query] drives the same aggregator incrementally while the stream is
/// still arriving, so events are never all retained at once.
@visibleForTesting
Json aggregateQueryEvents(Iterable<QueryEvent> events) {
  final aggregator = _QueryEventAggregator();
  for (final event in events) {
    aggregator.add(event);
  }
  return aggregator.finish();
}
/// Rows actually materialised into the payload (the UI's paging source).
@visibleForTesting
int resultRowsOf(Json payload) {
  final results = payload['results'];
  if (results is! List) return 0;
  var total = 0;
  for (final result in results) {
    if (result is Map) {
      final rows = result['rows'];
      if (rows is List) total += rows.length;
    }
  }
  return total;
}
