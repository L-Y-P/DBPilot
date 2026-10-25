use futures::StreamExt;
use serde_json::{json, Value};

use sqlx::sqlite::SqlitePool;
use sqlx::{Column, Decode, Row, TypeInfo, ValueRef};

pub mod account;
pub mod dialect;
pub mod driver;

use crate::core::connection::ConnectionHandle;
use crate::core::dialect::DatabaseDialect;
use crate::db::{ResultBatch, ResultSet, ScanStats};
use crate::drivers::{bytes_json, column_json, qi, qualify, quote_str_for, CreateTableSpec, DriverKind};
use crate::error::{AppError, AppResult};

// ------------------------------------------------------- file discovery
//
// A SQLite "database" is a plain file, and users keep folders full of them. The
// helpers below are shared by the driver (which attaches the files) and the API
// (which lists them), so "what counts as a database file" is defined once.

/// Extensions treated as SQLite database files when scanning a folder.
pub const SQLITE_EXTENSIONS: [&str; 4] = ["sqlite", "sqlite3", "db", "db3"];

/// How many database files one connection may ATTACH.
///
/// SQLite's own limit is SQLITE_MAX_ATTACHED (10 by default), and every attached
/// file costs file handles and memory, so opening a whole folder at once is
/// bounded here and the rest are reported to the user instead of silently
/// failing.
pub const MAX_ATTACHED: usize = 10;

/// True when the path looks like a SQLite database file.
pub fn is_sqlite_file(path: &std::path::Path) -> bool {
    match path.extension().and_then(|e| e.to_str()) {
        Some(ext) => SQLITE_EXTENSIONS.contains(&ext.to_ascii_lowercase().as_str()),
        None => false,
    }
}

/// Display name for a database file: the base name without the extension.
pub fn connection_name(path: &std::path::Path) -> String {
    path.file_stem()
        .and_then(|s| s.to_str())
        .filter(|s| !s.trim().is_empty())
        .map(|s| s.to_string())
        .unwrap_or_else(|| path.to_string_lossy().to_string())
}

/// Recursively collect SQLite files under `root`, sorted for stable output.
///
/// Bounded on purpose: pointing this at a home directory must not build a
/// hundred-thousand entry list, and an unreadable subdirectory is skipped rather
/// than failing the whole scan.
pub fn scan_folder(root: &std::path::Path, max_files: usize, max_depth: usize) -> Vec<std::path::PathBuf> {
    let mut found: Vec<std::path::PathBuf> = Vec::new();
    let mut visited: Vec<std::path::PathBuf> = Vec::new();
    walk(root, 0, max_depth, max_files, &mut found, &mut visited);
    found.sort();
    found
}

fn walk(
    dir: &std::path::Path,
    depth: usize,
    max_depth: usize,
    max_files: usize,
    found: &mut Vec<std::path::PathBuf>,
    visited: &mut Vec<std::path::PathBuf>,
) {
    if found.len() >= max_files || depth > max_depth {
        return;
    }
    if visited.iter().any(|v| v == dir) {
        return;
    }
    visited.push(dir.to_path_buf());
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(_) => return,
    };
    let mut items: Vec<std::path::PathBuf> = entries.filter_map(|e| e.ok()).map(|e| e.path()).collect();
    items.sort();
    for path in items {
        if found.len() >= max_files {
            return;
        }
        let hidden = path
            .file_name()
            .and_then(|n| n.to_str())
            .map(|n| n.starts_with('.'))
            .unwrap_or(false);
        if hidden {
            continue;
        }
        if path.is_dir() {
            walk(&path, depth + 1, max_depth, max_files, found, visited);
        } else if is_sqlite_file(&path) {
            found.push(path);
        }
    }
}

/// Canonical form of a path for comparisons.
///
/// SQLite reports the resolved path (on macOS `/private/var/...` for
/// `/var/...`), so comparing raw strings marks every database as a different
/// file and the list ends up with duplicates or missing entries.
pub fn same_path(a: &str, b: &str) -> bool {
    if a == b {
        return true;
    }
    let ca = std::fs::canonicalize(a).ok();
    let cb = std::fs::canonicalize(b).ok();
    matches!((ca, cb), (Some(x), Some(y)) if x == y)
}

/// True when the file starts with the SQLite header (a zero-byte file is a
/// valid new database: SQLite writes the header on first write).
pub fn is_readable(path: &std::path::Path) -> bool {
    use std::io::Read;
    let mut header = [0u8; 16];
    match std::fs::File::open(path) {
        Ok(mut file) => match file.read_exact(&mut header) {
            Ok(()) => &header[..] == b"SQLite format 3\0",
            Err(_) => std::fs::metadata(path).map(|m| m.len() == 0).unwrap_or(false),
        },
        Err(_) => false,
    }
}

/// Decode one cell, taking a fresh value ref per attempt (SqliteValueRef is not Clone).
fn try_decode<'r, T>(row: &'r sqlx::sqlite::SqliteRow, idx: usize) -> Option<T>
where
    T: Decode<'r, sqlx::Sqlite>,
{
    let raw = row.try_get_raw(idx).ok()?;
    if raw.is_null() {
        return None;
    }
    T::decode(raw).ok()
}

pub(crate) fn value_to_json(row: &sqlx::sqlite::SqliteRow, idx: usize) -> Value {
    if row.try_get_raw(idx).map(|r| r.is_null()).unwrap_or(true) {
        return Value::Null;
    }
    // The declared column type drives the decoder when it is known.
    let tname = row.column(idx).type_info().name().to_uppercase();
    if matches!(tname.as_str(), "INTEGER" | "INT" | "BIGINT" | "BOOLEAN" | "BOOL") {
        if let Some(v) = try_decode::<i64>(row, idx) {
            return json!(v);
        }
    }
    if matches!(tname.as_str(), "REAL" | "FLOAT" | "DOUBLE" | "NUMERIC" | "DECIMAL") {
        if let Some(v) = try_decode::<f64>(row, idx) {
            return json!(v);
        }
    }
    if tname == "BLOB" {
        if let Some(v) = try_decode::<Vec<u8>>(row, idx) {
            return bytes_json(&v);
        }
    }
    if matches!(tname.as_str(), "TEXT" | "VARCHAR" | "CHAR" | "CLOB") {
        if let Some(v) = try_decode::<String>(row, idx) {
            return json!(v);
        }
    }
    // Unknown/expression column (SQLite reports these as NULL type): SQLite is
    // dynamically typed, so infer the JSON shape from the text representation.
    if let Some(s) = try_decode::<String>(row, idx) {
        if let Ok(i) = s.parse::<i64>() {
            return json!(i);
        }
        if (s.contains('.') || s.contains('e') || s.contains('E')) && s.parse::<f64>().is_ok() {
            return json!(s.parse::<f64>().unwrap_or_default());
        }
        return json!(s);
    }
    if let Some(bytes) = try_decode::<Vec<u8>>(row, idx) {
        return bytes_json(&bytes);
    }
    Value::Null
}

pub async fn run_one(pool: &SqlitePool, stmt: String) -> ResultSet {
    let conn = match pool.acquire().await {
        Ok(conn) => conn,
        Err(e) => return error_set(stmt, e),
    };
    run_one_owned(conn, stmt).await.0
}

/// Execute one statement on an owned connection and hand it back.
///
/// Taking the connection by value (instead of `&mut SqliteConnection`) keeps the
/// future `Send` without a higher-ranked `Executor` obligation; see
/// `drivers::mysql::exec::run_one_limited_owned` for the full explanation.
pub async fn run_one_owned(
    mut conn: sqlx::pool::PoolConnection<sqlx::Sqlite>,
    stmt: String,
) -> (ResultSet, sqlx::pool::PoolConnection<sqlx::Sqlite>) {
    let wants_rows = crate::db::returns_rows(&stmt);
    let is_insert = stmt.trim_start().to_ascii_lowercase().starts_with("insert");
    if wants_rows {
        let result = match sqlx::query(stmt.as_str()).fetch_all(&mut *conn).await {
            Ok(rows) => {
                let columns = rows
                    .first()
                    .map(|row| crate::drivers::columns_meta(row))
                    .unwrap_or_default();
                let values: Vec<Vec<Value>> = rows
                    .iter()
                    .map(|r| (0..r.len()).map(|i| value_to_json(r, i)).collect())
                    .collect();
                ResultSet {
                    row_count: values.len() as u64,
                    columns,
                    rows: values,
                    last_insert_id: 0,
                    statement: stmt,
                    kind: "rows".to_string(),
                    error: None,
                    truncated: false,
                }
            }
            Err(e) => error_set(stmt, e),
        };
        (result, conn)
    } else {
        // last_insert_rowid() is per connection; this helper keeps the connection
        // it ran on so both statements see the same session.
        let result = match sqlx::query(stmt.as_str()).execute(&mut *conn).await {
            Ok(r) => {
                let mut last = 0u64;
                if is_insert {
                    if let Ok(row) = sqlx::query("SELECT last_insert_rowid()")
                        .fetch_one(&mut *conn)
                        .await
                    {
                        last = row.try_get::<i64, _>(0).unwrap_or(0).max(0) as u64;
                    }
                }
                ResultSet {
                    columns: Vec::new(),
                    rows: Vec::new(),
                    row_count: r.rows_affected(),
                    last_insert_id: last,
                    statement: stmt,
                    kind: "affected".to_string(),
                    error: None,
                    truncated: false,
                }
            }
            Err(e) => error_set(stmt, e),
        };
        (result, conn)
    }
}

/// Streaming counterpart of [run_one_owned] with a hard row cap.
pub async fn run_one_limited(
    pool: &SqlitePool,
    stmt: String,
    max_rows: usize,
) -> ResultSet {
    if !crate::db::returns_rows(&stmt) {
        return run_one(pool, stmt).await;
    }
    let conn = match pool.acquire().await {
        Ok(conn) => conn,
        Err(e) => return error_set(stmt, e),
    };
    let (result, _truncated, _conn) = run_one_limited_owned(conn, stmt, max_rows).await;
    result
}

pub async fn run_one_limited_owned(
    mut conn: sqlx::pool::PoolConnection<sqlx::Sqlite>,
    stmt: String,
    max_rows: usize,
) -> (ResultSet, bool, sqlx::pool::PoolConnection<sqlx::Sqlite>) {
    if !crate::db::returns_rows(&stmt) {
        let (result, conn) = run_one_owned(conn, stmt).await;
        return (result, false, conn);
    }
    let mut rows: Vec<sqlx::sqlite::SqliteRow> = Vec::new();
    let mut truncated = false;
    let mut failure: Option<sqlx::Error> = None;
    {
        let mut stream = sqlx::query(stmt.as_str()).fetch(&mut *conn);
        loop {
            match stream.next().await {
                Some(Ok(row)) => {
                    if rows.len() >= max_rows {
                        truncated = true;
                        break;
                    }
                    rows.push(row);
                }
                Some(Err(e)) => {
                    failure = Some(e);
                    break;
                }
                None => break,
            }
        }
    }
    if let Some(e) = failure {
        return (error_set(stmt, e), false, conn);
    }
    let columns = rows
        .first()
        .map(|row| crate::drivers::columns_meta(row))
        .unwrap_or_default();
    let values: Vec<Vec<Value>> = rows
        .iter()
        .map(|r| (0..r.len()).map(|i| value_to_json(r, i)).collect())
        .collect();
    let result = ResultSet {
        columns,
        row_count: values.len() as u64,
        rows: values,
        last_insert_id: 0,
        statement: stmt,
        kind: "rows".to_string(),
        error: None,
        truncated,
    };
    (result, truncated, conn)
}

/// Streaming variant of [run_one_limited_owned] (optimisation layer 3).
///
/// Same contract as the MySQL implementation in
/// `drivers/mysql/exec.rs::run_one_limited_batched_owned`, which is the
/// reference for the docs below:
///
/// * rows are decoded with [value_to_json] and handed to `on_batch` as soon as
///   `batch_size` of them have been read, so a large SQL-console result never
///   materialises as a whole;
/// * a statement that does not return rows reuses [run_one_limited_owned]
///   verbatim (one `affected` batch, `last_insert_rowid()` included);
/// * reading stops at `max_rows`, `truncated` is set and the caller closes the
///   connection (never drain/decode the rest);
/// * `on_batch` returning `false` stops the scan immediately; the caller closes
///   the connection, which also resets the in-process statement.
///
/// The returned [ResultSet] carries metadata only (`rows` is empty — the rows
/// travelled through the callback). The connection is moved in and returned for
/// the same rustc/`Send` reason documented on [run_one_limited_owned].
pub async fn run_one_limited_batched_owned(
    conn: sqlx::pool::PoolConnection<sqlx::Sqlite>,
    stmt: String,
    max_rows: usize,
    batch_size: usize,
    on_batch: &mut (dyn FnMut(ResultBatch) -> bool + Send),
) -> (
    ResultSet,
    bool,
    bool,
    sqlx::pool::PoolConnection<sqlx::Sqlite>,
) {
    if !crate::db::returns_rows(&stmt) {
        let (result, truncated, conn) = run_one_limited_owned(conn, stmt, max_rows).await;
        return (result, truncated, false, conn);
    }
    let mut conn = conn;
    let batch_size = batch_size.max(1);
    let mut columns: Vec<crate::db::ColumnMeta> = Vec::new();
    let mut buffered: Vec<Vec<Value>> = Vec::with_capacity(batch_size.min(max_rows.max(1)));
    let mut row_count: usize = 0;
    let mut truncated = false;
    let mut stopped = false;
    let mut failure: Option<sqlx::Error> = None;
    {
        let mut stream = sqlx::query(stmt.as_str()).fetch(&mut *conn);
        loop {
            match stream.next().await {
                Some(Ok(row)) => {
                    if row_count >= max_rows {
                        truncated = true;
                        break;
                    }
                    if columns.is_empty() {
                        columns = crate::drivers::columns_meta(&row);
                    }
                    buffered.push((0..row.len()).map(|i| value_to_json(&row, i)).collect());
                    row_count += 1;
                    if buffered.len() >= batch_size {
                        let batch = ResultBatch {
                            columns: columns.clone(),
                            rows: std::mem::take(&mut buffered),
                            truncated: false,
                        };
                        if !on_batch(batch) {
                            stopped = true;
                            break;
                        }
                    }
                }
                Some(Err(e)) => {
                    failure = Some(e);
                    break;
                }
                None => break,
            }
        }
    }
    if let Some(e) = failure {
        return (error_set(stmt, e), false, false, conn);
    }
    if !stopped {
        if !buffered.is_empty() {
            let batch = ResultBatch {
                columns: columns.clone(),
                rows: std::mem::take(&mut buffered),
                truncated,
            };
            if !on_batch(batch) {
                stopped = true;
            }
        } else if truncated {
            // The cap was reached exactly on a batch boundary: emit a trailing
            // empty batch so the consumer still observes `truncated`.
            let batch = ResultBatch {
                columns: columns.clone(),
                rows: Vec::new(),
                truncated: true,
            };
            if !on_batch(batch) {
                stopped = true;
            }
        }
    }
    let result = ResultSet {
        columns,
        rows: Vec::new(),
        row_count: row_count as u64,
        last_insert_id: 0,
        statement: stmt,
        kind: "rows".to_string(),
        error: None,
        truncated,
    };
    (result, truncated, stopped, conn)
}

/// Execute `statements` inside **one transaction**, one affected result each.
///
/// Transaction control goes through sqlx's transaction manager; the first
/// failing statement rolls the whole batch back. SQLite is in-process, so no
/// protocol fallback is involved, but the same helper keeps the batched row-edit
/// path driver-agnostic.
///
/// INSERT detection mirrors [run_one_owned]: SQLite's `last_insert_rowid()` is
/// per connection and must be read on the same transaction connection.
/// The failing statement's 1-based index is part of the error message.
pub async fn run_transaction(
    pool: &SqlitePool,
    statements: Vec<String>,
) -> AppResult<Vec<ResultSet>> {
    let mut tx = pool
        .begin()
        .await
        .map_err(|e| AppError::bad(crate::error::database_message(&e)))?;
    let mut results = Vec::with_capacity(statements.len());
    for (index, stmt) in statements.into_iter().enumerate() {
        let is_insert = stmt.trim_start().to_ascii_lowercase().starts_with("insert");
        match sqlx::query(stmt.as_str()).execute(&mut *tx).await {
            Ok(result) => {
                let mut last_insert_id = 0u64;
                if is_insert {
                    if let Ok(row) = sqlx::query("SELECT last_insert_rowid()")
                        .fetch_one(&mut *tx)
                        .await
                    {
                        last_insert_id =
                            row.try_get::<i64, _>(0).unwrap_or(0).max(0) as u64;
                    }
                }
                results.push(ResultSet {
                    columns: Vec::new(),
                    rows: Vec::new(),
                    row_count: result.rows_affected(),
                    last_insert_id,
                    statement: stmt,
                    kind: "affected".to_string(),
                    error: None,
                    truncated: false,
                });
            }
            Err(e) => {
                let _ = tx.rollback().await;
                return Err(AppError::bad(format!(
                    "第 {} 条改动失败，整批已回滚：{}",
                    index + 1,
                    crate::error::database_message(&e)
                )));
            }
        }
    }
    tx.commit().await.map_err(|e| {
        AppError::bad(format!(
            "提交事务失败：{}",
            crate::error::database_message(&e)
        ))
    })?;
    Ok(results)
}

fn error_set(stmt: String, e: sqlx::Error) -> ResultSet {
    ResultSet {
        columns: Vec::new(),
        rows: Vec::new(),
        row_count: 0,
        last_insert_id: 0,
        statement: stmt,
        kind: "error".to_string(),
        // Same normalisation as AppError: one sentence, no duplicate
        // "Caused by:" tail, permission codes explained.
        error: Some(crate::error::database_message(&e)),
        truncated: false,
    }
}

/// Stream a row-returning statement to a callback (export path).
///
/// SQLite runs in-process: stopping the stream resets the statement, so the
/// connection is returned to the pool. Memory stays proportional to the row
/// currently being written instead of the whole table.
pub async fn scan_rows<'a>(
    pool: &SqlitePool,
    stmt: String,
    mut on_row: Box<crate::core::connection::RowFn<'a>>,
) -> AppResult<ScanStats> {
    let mut conn = pool
        .acquire()
        .await
        .map_err(|e| AppError::bad(crate::error::database_message(&e)))?;
    let mut stats = ScanStats::default();
    let mut failure: Option<sqlx::Error> = None;
    let mut stopped = false;
    {
        let mut stream = sqlx::query(stmt.as_str()).fetch(&mut *conn);
        while let Some(item) = stream.next().await {
            match item {
                Ok(row) => {
                    if stats.columns.is_empty() {
                        stats.columns = crate::drivers::columns_meta(&row);
                    }
                    let values: Vec<Value> =
                        (0..row.len()).map(|i| value_to_json(&row, i)).collect();
                    stats.rows += 1;
                    if !on_row(&stats.columns, &values) {
                        stopped = true;
                        break;
                    }
                }
                Err(e) => {
                    failure = Some(e);
                    break;
                }
            }
        }
    }
    if let Some(e) = failure {
        return Err(AppError::bad(crate::error::database_message(&e)));
    }
    stats.stopped_early = stopped;
    Ok(stats)
}

pub async fn version(_pool: &SqlitePool) -> AppResult<String> {
    Ok("SQLite (embedded)".to_string())
}

/// SQLite support targets the main database; unqualified names avoid the
/// double-quoted-schema parsing differences between bundled SQLite builds.
const MASTER: &str = "sqlite_master";

/// The attached-schema name carried by [ns], or `None` for the primary file.
///
/// The desktop UI addresses a SQLite connection by its **database file path**
/// (that is what `AppRoute.database` receives and what the connection stores),
/// while [ATTACH]ed files are addressed by the alias SQLite gave them. Anything
/// that is not a bare identifier is therefore the primary file: treating a path
/// as a schema produced `"…/x.sqlite".sqlite_master` and a "no such table"
/// error on every SQLite page.
fn schema_of(ns: &str) -> Option<&str> {
    let ns = ns.trim();
    if ns.is_empty() || ns.eq_ignore_ascii_case("main") {
        return None;
    }
    if ns.contains('/') || ns.contains('\\') || ns.contains(':') || ns.contains('.') {
        return None;
    }
    Some(ns)
}

/// `main`'s schema table, or `<ns>.sqlite_master` for an attached database.
///
/// A SQLite connection can carry several database files (the primary one plus
/// anything ATTACHed). Every catalog query has to be qualified with the
/// namespace or it only ever reports the primary file's tables.
fn master_of(ns: &str) -> String {
    match schema_of(ns) {
        Some(schema) => format!("{}.{}", quote_str_for(DriverKind::Sqlite, schema), MASTER),
        None => MASTER.to_string(),
    }
}

/// `PRAGMA <name>(<arg>)` addressed at one namespace.
///
/// `PRAGMA table_info(t)` always reads `main`; the schema-aware form is
/// `PRAGMA <ns>.table_info(t)`, so the namespace has to be spliced in.
fn pragma(schema: &str, name: &str, arg: &str) -> String {
    match schema_of(schema) {
        Some(schema) => format!(
            "PRAGMA {}.{}({})",
            quote_str_for(DriverKind::Sqlite, schema),
            name,
            arg
        ),
        None => format!("PRAGMA {}({})", name, arg),
    }
}

/// Stable alias for an attached database file, derived from its base name.
///
/// The alias is what the sidebar shows and what every catalog query qualifies
/// with, so it must be a legal identifier: dots, spaces and other punctuation in
/// a filename are replaced, and a numeric suffix keeps same-named files apart.
pub fn alias_for(file: &str, index: usize) -> String {
    let base = std::path::Path::new(file)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("");
    let mut out = String::new();
    for c in base.chars() {
        if c.is_ascii_alphanumeric() || c == '_' {
            out.push(c);
        } else if !out.ends_with('_') {
            out.push('_');
        }
    }
    let out = out.trim_matches('_').to_string();
    let sanitized = if out.is_empty() {
        format!("db{}", index + 1)
    } else if out.chars().next().map(|c| c.is_ascii_digit()).unwrap_or(false) {
        // A namespace cannot start with a digit without quoting; prefix it.
        format!("db_{}", out)
    } else {
        out
    };
    // Two files can share a base name (a/x.sqlite and b/x.sqlite). The index is
    // appended for every non-first entry so their namespaces never collide.
    if index == 0 {
        sanitized
    } else {
        format!("{}_{}", sanitized, index + 1)
    }
}

pub async fn namespaces(conn: &ConnectionHandle) -> AppResult<Vec<Value>> {
    // SQL 文本由方言拥有（drivers/sqlite/dialect.rs）。
    let rows = conn
        .fetch_named(dialect::SQLITE_DIALECT.list_databases_sql().sql)
        .await?;
    Ok(rows
        .into_iter()
        .filter(|r| r.get("name").and_then(|v| v.as_str()) != Some("temp"))
        .map(|r| {
            json!({
                "name": r.get("name").cloned().unwrap_or(Value::Null),
                "charset": "UTF-8",
                "collation": Value::Null,
                "file": r.get("file").cloned().unwrap_or(Value::Null),
            })
        })
        .collect())
}


/// INSERT one row inside a transaction, read it back and always roll back
/// (import probe / "试插入" step).
pub async fn probe_insert(pool: &SqlitePool, insert: &str, select: &str) -> AppResult<Value> {
    let mut tx = pool
        .begin()
        .await
        .map_err(|e| AppError::bad(crate::error::database_message(&e)))?;
    let affected = match sqlx::query(insert).execute(&mut *tx).await {
        Ok(result) => result.rows_affected(),
        Err(e) => {
            let _ = tx.rollback().await;
            return Err(AppError::bad(crate::error::database_message(&e)));
        }
    };
    let row = match sqlx::query(select).fetch_optional(&mut *tx).await {
        Ok(Some(row)) => {
            let mut map = serde_json::Map::new();
            for i in 0..row.len() {
                let name = row.column(i).name().to_string();
                map.insert(name, value_to_json(&row, i));
            }
            Value::Object(map)
        }
        _ => Value::Null,
    };
    let _ = tx.rollback().await;
    Ok(json!({ "affected": affected, "row": row }))
}

/// Schema a `PRAGMA` / `dbstat` reference can address.
///
/// Unlike [`schema_of`], the primary file is addressable here: its page counts
/// are what the database page reports, and `dbstat` only ever knows about it.
fn addressable_schema(ns: &str) -> Option<&str> {
    let ns = ns.trim();
    if ns.is_empty() || ns.eq_ignore_ascii_case("main") {
        return Some("main");
    }
    schema_of(ns)
}

/// `PRAGMA <ns>.page_count` / `page_size` for one namespace.
///
/// The pair is the namespace's own file-level byte count; it is the honest
/// answer when a per-table estimate is not available.
pub fn file_size_pragmas(ns: &str) -> Option<(String, String)> {
    let schema = addressable_schema(ns)?;
    // A bare `PRAGMA page_count` already reads `main`; the qualified form is
    // only needed for an ATTACHed alias.
    if schema == "main" {
        return Some((
            "PRAGMA page_count".to_string(),
            "PRAGMA page_size".to_string(),
        ));
    }
    let quoted = quote_str_for(DriverKind::Sqlite, schema);
    Some((
        format!("PRAGMA {}.page_count", quoted),
        format!("PRAGMA {}.page_size", quoted),
    ))
}

/// One-pass per-table byte estimate over the `dbstat` virtual table.
///
/// `dbstat` lists every page of the `main` file together with the table or
/// index it belongs to, so joining `sqlite_master` attributes index pages to
/// their table and one scan covers the whole file. It is a `main`-only
/// virtual table, so an attached namespace returns `None` and falls back to
/// the file size. `None` also means the build has no dbstat at all.
pub fn dbstat_size_sql(ns: &str) -> Option<String> {
    let schema = addressable_schema(ns)?;
    if schema != "main" {
        return None;
    }
    Some(format!(
        "SELECT m.tbl_name AS \"name\", SUM(d.pgsize) AS \"bytes\" FROM dbstat d JOIN {} m ON m.name = d.name WHERE m.type IN ('table', 'index') GROUP BY m.tbl_name",
        master_of(ns)
    ))
}

/// File-level byte count of one namespace, or None when it cannot be read.
async fn file_size_of(conn: &ConnectionHandle, ns: &str) -> Option<i64> {
    let (count_sql, size_sql) = file_size_pragmas(ns)?;
    let page_count = conn.fetch_i64(count_sql).await.ok()?;
    let page_size = conn.fetch_i64(size_sql).await.ok()?;
    if page_count <= 0 || page_size <= 0 {
        return None;
    }
    Some(page_count * page_size)
}

/// Per-table byte estimates, or None when dbstat is not usable here.
async fn table_sizes_of(
    conn: &ConnectionHandle,
    ns: &str,
) -> Option<std::collections::BTreeMap<String, i64>> {
    let sql = dbstat_size_sql(ns)?;
    let rows = conn.fetch_named(sql).await.ok()?;
    let mut out = std::collections::BTreeMap::new();
    for row in rows {
        if let (Some(name), Some(bytes)) = (
            row.get("name").and_then(|v| v.as_str()),
            row.get("bytes").and_then(|v| v.as_i64()),
        ) {
            out.insert(name.to_string(), bytes);
        }
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

/// Tables of one namespace.
///
/// Round34 P3-03: `data_length` was NULL for every SQLite table, so the
/// database page's 大小 column showed a bare "—". It is filled here from the
/// page accounting: `dbstat` gives a per-table number (index pages included)
/// in a single pass, and when that is unavailable the file-level
/// `page_count * page_size` is reported with `size_scope: "file"` so the UI can
/// say *what* the number describes instead of hiding it.
pub async fn tables(conn: &ConnectionHandle, ns: &str) -> AppResult<Vec<Value>> {
    let mut rows = conn
        .fetch_named(dialect::SQLITE_DIALECT.list_tables_sql(ns).sql)
        .await?;
    let file_size = file_size_of(conn, ns).await;
    let per_table = table_sizes_of(conn, ns).await;
    for row in rows.iter_mut() {
        if row.get("type").and_then(|v| v.as_str()) == Some("BASE TABLE") {
            if let Some(name) = row.get("name").and_then(|v| v.as_str()).map(|s| s.to_string()) {
                let count = conn
                    .fetch_i64(format!("SELECT COUNT(*) FROM {}", qualify(conn.driver_kind(), ns, &name)))
                    .await
                    .unwrap_or(0);
                row["row_count"] = json!(count);
                match per_table.as_ref().and_then(|m| m.get(&name)) {
                    Some(bytes) => {
                        row["data_length"] = json!(bytes);
                        row["size_scope"] = json!("table");
                    }
                    None => {
                        row["size_scope"] = json!(if file_size.is_some() {
                            "file"
                        } else {
                            "none"
                        });
                    }
                }
            }
        }
        if let Some(bytes) = file_size {
            row["file_size"] = json!(bytes);
        }
    }
    Ok(rows)
}

pub async fn object_kind(_conn: &ConnectionHandle, _ns: &str, table: &str) -> AppResult<Option<String>> {
    Ok(Some(table.to_string()))
}

pub async fn structure(conn: &ConnectionHandle, ns: &str, table: &str) -> AppResult<Value> {
    let info_rows = conn
        .fetch_named(format!(
            "SELECT type AS \"TABLE_TYPE\", NULL AS \"ENGINE\", NULL AS \"TABLE_ROWS\", NULL AS \"DATA_LENGTH\", NULL AS \"INDEX_LENGTH\", NULL AS \"TABLE_COLLATION\", '' AS \"TABLE_COMMENT\", NULL AS \"CREATE_TIME\", NULL AS \"UPDATE_TIME\", NULL AS \"AUTO_INCREMENT\", sql AS \"TABLE_SQL\" FROM {} WHERE name = {}",
            master_of(ns),
            quote_str_for(conn.driver_kind(), table)
        ))
        .await?;
    let mut info = info_rows
        .into_iter()
        .next()
        .ok_or_else(|| AppError::not_found(format!("table '{}' does not exist", table)))?;
    let kind = info
        .get("TABLE_TYPE")
        .and_then(|v| v.as_str())
        .map(|s| if s == "view" { "VIEW" } else { "BASE TABLE" })
        .unwrap_or("BASE TABLE");
    info["TABLE_TYPE"] = json!(kind);
    let ddl = info.get("TABLE_SQL").and_then(|v| v.as_str()).unwrap_or("").to_string();
    if let Some(obj) = info.as_object_mut() {
        obj.remove("TABLE_SQL");
    }
    let (collations, without_rowid, strict) = parse_table_options(&ddl);
    info["WITHOUT_ROWID"] = json!(if without_rowid { "YES" } else { "NO" });
    info["STRICT"] = json!(if strict { "YES" } else { "NO" });

    let raw_columns = conn
        .fetch_named(dialect::SQLITE_DIALECT.list_columns_sql(ns, table).sql)
        .await?;

    let mut columns = Vec::new();
    let mut primary_key: Vec<Value> = Vec::new();
    for c in raw_columns {
        let get = |k: &str| c.get(k).cloned().unwrap_or(Value::Null);
        let s = |k: &str| get(k).as_str().unwrap_or_default().to_string();
        let name = s("name");
        let notnull = get("notnull").as_i64().unwrap_or(0);
        let pk = get("pk").as_i64().unwrap_or(0);
        let type_name = s("type");
        let key = if pk > 0 {
            primary_key.push(json!(name.clone()));
            "PRI"
        } else {
            ""
        };
        columns.push(column_json(
            &name,
            &type_name,
            &type_name,
            if notnull == 0 { "YES" } else { "NO" },
            get("dflt_value"),
            key,
            "",
            "",
            Value::Null,
            collations
                .get(&name.to_ascii_uppercase())
                .cloned()
                .map(Value::String)
                .unwrap_or(Value::Null),
            get("cid").as_i64().unwrap_or(0) + 1,
            Value::Null,
            Value::Null,
        ));
    }

    let mut indexes: Vec<Value> = Vec::new();
    let index_list = conn
        .fetch_named(pragma(ns, "index_list", &quote_str_for(conn.driver_kind(), table)))
        .await
        .unwrap_or_default();
    for idx in index_list {
        let idx_name = idx.get("name").and_then(|v| v.as_str()).unwrap_or_default().to_string();
        let unique = idx.get("unique").and_then(|v| v.as_i64()).unwrap_or(0);
        let info_rows = conn
            .fetch_named(format!("PRAGMA index_info({})", quote_str_for(conn.driver_kind(), &idx_name)))
            .await
            .unwrap_or_default();
        // PRAGMA index_list origin: "c" = explicitly created, "u" = UNIQUE
        // constraint, "pk" = primary key. Only "c" indexes can be recreated
        // by name (the sqlite_autoindex_* names are reserved by the engine).
        let origin = idx.get("origin").and_then(|v| v.as_str()).unwrap_or("c");
        for col in info_rows {
            indexes.push(json!({
                "INDEX_NAME": idx_name,
                "NON_UNIQUE": if unique == 1 { 0 } else { 1 },
                "IS_PRIMARY": origin == "pk",
                "IS_AUTO": origin != "c",
                "SEQ_IN_INDEX": col.get("seqno").cloned().unwrap_or(Value::Null),
                "COLUMN_NAME": col.get("name").cloned().unwrap_or(Value::Null),
                "COLLATION": Value::Null,
                "CARDINALITY": Value::Null,
                "INDEX_TYPE": "BTREE",
            }));
        }
    }

    let fk_rows = conn
        .fetch_named(pragma(ns, "foreign_key_list", &quote_str_for(conn.driver_kind(), table)))
        .await
        .unwrap_or_default();
    let foreign_keys: Vec<Value> = fk_rows
        .iter()
        .map(|r| {
            json!({
                "CONSTRAINT_NAME": Value::Null,
                "COLUMN_NAME": r.get("from").cloned().unwrap_or(Value::Null),
                "REFERENCED_TABLE_NAME": r.get("table").cloned().unwrap_or(Value::Null),
                "REFERENCED_COLUMN_NAME": r.get("to").cloned().unwrap_or(Value::Null),
                "DELETE_RULE": r.get("on_delete").cloned().unwrap_or(Value::Null),
                "UPDATE_RULE": r.get("on_update").cloned().unwrap_or(Value::Null),
                "SEQ": r.get("id").cloned().unwrap_or(Value::Null),
            })
        })
        .collect();

    Ok(json!({
        "database": ns,
        "table": table,
        "info": info,
        "columns": columns,
        "indexes": indexes,
        "primary_key": primary_key,
        "foreign_keys": foreign_keys,
    }))
}

pub async fn overview(conn: &ConnectionHandle) -> AppResult<Value> {
    let version = version_of(conn).await;
    let page_count = conn.fetch_i64("PRAGMA page_count".to_string()).await.unwrap_or(0);
    let page_size = conn.fetch_i64("PRAGMA page_size".to_string()).await.unwrap_or(0);
    let table_count = conn
        .fetch_i64("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'".to_string())
        .await
        .unwrap_or(0);
    let status = json!({
        "page_count": page_count,
        "page_size": page_size,
        "encoding": conn.fetch_string("PRAGMA encoding".to_string()).await.unwrap_or_default(),
        "journal_mode": conn.fetch_string("PRAGMA journal_mode".to_string()).await.unwrap_or_default(),
        "foreign_keys": conn.fetch_string("PRAGMA foreign_keys".to_string()).await.unwrap_or_default(),
    });
    Ok(json!({
        "version": version,
        "version_comment": "SQLite (embedded)",
        "uptime": Value::Null,
        "threads_connected": 1,
        "threads_running": 1,
        "queries": Value::Null,
        "questions": Value::Null,
        "slow_queries": Value::Null,
        "connections": 1,
        "bytes_received": Value::Null,
        "bytes_sent": Value::Null,
        "aborted_connects": Value::Null,
        "database_count": 1,
        "table_count": table_count,
        "status": status,
    }))
}

async fn version_of(conn: &ConnectionHandle) -> String {
    match conn.fetch_string("SELECT sqlite_version()".to_string()).await {
        Ok(v) => format!("SQLite {}", v),
        Err(_) => "SQLite".to_string(),
    }
}

pub async fn variables(conn: &ConnectionHandle, filter: Option<&str>) -> AppResult<Vec<Value>> {
    let names = [
        "page_size", "page_count", "encoding", "journal_mode", "foreign_keys", "synchronous",
        "auto_vacuum", "cache_size", "busy_timeout", "user_version",
    ];
    let mut out = Vec::new();
    for name in names {
        if let Some(f) = filter {
            if !name.to_lowercase().contains(&f.to_lowercase()) {
                continue;
            }
        }
        let value = conn.fetch_string(format!("PRAGMA {}", name)).await.unwrap_or_default();
        out.push(json!({ "Variable_name": name, "Value": value }));
    }
    Ok(out)
}

pub async fn users(_conn: &ConnectionHandle) -> AppResult<Vec<Value>> {
    Ok(Vec::new())
}

pub async fn builder_schema(conn: &ConnectionHandle, ns: &str) -> AppResult<Value> {
    let tables_raw = conn
        .fetch_named(format!(
            "SELECT name AS \"name\" FROM {} WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
            master_of(ns)
        ))
        .await?;
    let mut tables: Vec<Value> = Vec::new();
    for t in tables_raw {
        let name = t.get("name").and_then(|v| v.as_str()).unwrap_or_default().to_string();
        let cols = conn
            .fetch_named(pragma(ns, "table_info", &quote_str_for(conn.driver_kind(), &name)))
            .await
            .unwrap_or_default();
        let columns: Vec<Value> = cols
            .iter()
            .map(|c| {
                json!({
                    "name": c.get("name").cloned().unwrap_or(Value::Null),
                    "type": c.get("type").cloned().unwrap_or(Value::Null),
                    "nullable": c.get("notnull").and_then(|v| v.as_i64()).unwrap_or(0) == 0,
                    "key": if c.get("pk").and_then(|v| v.as_i64()).unwrap_or(0) > 0 { "PRI" } else { "" },
                })
            })
            .collect();
        let fk_rows = conn
            .fetch_named(pragma(ns, "foreign_key_list", &quote_str_for(conn.driver_kind(), &name)))
            .await
            .unwrap_or_default();
        let foreign_keys: Vec<Value> = fk_rows
            .iter()
            .map(|f| {
                json!({
                    "column": f.get("from").cloned().unwrap_or(Value::Null),
                    "ref_table": f.get("table").cloned().unwrap_or(Value::Null),
                    "ref_column": f.get("to").cloned().unwrap_or(Value::Null),
                })
            })
            .collect();
        tables.push(json!({ "name": name, "columns": columns, "foreign_keys": foreign_keys }));
    }
    Ok(json!({ "schema": ns, "tables": tables }))
}

pub async fn table_ddl(conn: &ConnectionHandle, ns: &str, table: &str) -> AppResult<Option<String>> {
    let rows = conn
        .fetch_named(format!(
            "SELECT sql AS \"ddl\" FROM {} WHERE name = {}",
            master_of(ns),
            quote_str_for(conn.driver_kind(), table)
        ))
        .await?;
    Ok(rows
        .first()
        .and_then(|r| r.get("ddl"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string()))
}

pub fn create_table_sql(ns: &str, spec: &CreateTableSpec) -> AppResult<String> {
    let driver = DriverKind::Sqlite;
    let mut defs: Vec<String> = Vec::new();
    let mut primary: Vec<String> = Vec::new();
    for column in &spec.columns {
        let name = column.name.trim();
        if column.auto_increment && column.primary {
            defs.push(format!("{} INTEGER PRIMARY KEY AUTOINCREMENT", crate::drivers::qi(driver, name)));
            continue;
        }
        let mut def = format!("{} {}", crate::drivers::qi(driver, name), column.col_type.trim());
        if let Some(collation) = column.collation.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            if !ident_ok(collation) {
                return Err(AppError::bad(format!("非法排序规则 '{}'", collation)));
            }
            def.push_str(&format!(" COLLATE {}", collation));
        }
        if let Some(value) = column.default.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            def.push_str(&format!(" DEFAULT {}", crate::drivers::safe_default(value)?));
        }
        if !column.nullable {
            def.push_str(" NOT NULL");
        }
        if column.primary {
            primary.push(crate::drivers::qi(driver, name));
        }
        defs.push(def);
    }
    if !primary.is_empty() {
        defs.push(format!("PRIMARY KEY ({})", primary.join(", ")));
    }
    for fk in &spec.foreign_keys {
        defs.push(crate::drivers::fk_constraint_sql(driver, &spec.name, fk)?);
    }
    let mut opts: Vec<&str> = Vec::new();
    if spec.without_rowid == Some(true) {
        opts.push("WITHOUT ROWID");
    }
    if spec.strict == Some(true) {
        opts.push("STRICT");
    }
    let tail = if opts.is_empty() {
        String::new()
    } else {
        format!(" {}", opts.join(", "))
    };
    Ok(format!(
        "CREATE TABLE {} (\n  {}\n){}",
        qualify(driver, ns, &spec.name),
        defs.join(",\n  "),
        tail
    ))
}

pub fn alter_table_statements(
    ns: &str,
    table: &str,
    spec: &crate::drivers::AlterTableSpec,
) -> AppResult<Vec<String>> {
    let d = DriverKind::Sqlite;
    let target = qualify(d, ns, table);
    if !spec.modify_columns.is_empty() {
        return Err(AppError::bad("SQLite 不支持修改字段定义，请通过重建表实现"));
    }
    if spec.set_primary_key.is_some() {
        return Err(AppError::bad("SQLite 不支持新增主键"));
    }
    if spec.engine.is_some() || spec.charset.is_some() || spec.collation.is_some()
        || spec.unlogged.is_some() || spec.tablespace.is_some()
    {
        return Err(AppError::bad("SQLite 不支持存储引擎 / 字符集 / 表空间选项"));
    }
    if spec.without_rowid.is_some() || spec.strict.is_some() {
        return Err(AppError::bad("SQLite 的 WITHOUT ROWID / STRICT 只能在建表时指定"));
    }
    if !spec.add_foreign_keys.is_empty() || !spec.drop_foreign_keys.is_empty() {
        return Err(AppError::bad("SQLite 不支持用 ALTER 增删外键，请在新建表时指定或重建表"));
    }
    let mut out: Vec<String> = Vec::new();
    for c in &spec.add_columns {
        if c.auto_increment || c.comment.as_deref().map(|v| !v.is_empty()).unwrap_or(false) {
            return Err(AppError::bad("SQLite 新增字段不支持自增 / 注释"));
        }
        let mut s = format!("ALTER TABLE {} ADD COLUMN {} {}", target, qi(d, c.name.trim()), c.col_type.trim());
        if let Some(collation) = c.collation.as_deref().map(str::trim).filter(|v| !v.is_empty()) {
            if !ident_ok(collation) {
                return Err(AppError::bad(format!("非法排序规则 '{}'", collation)));
            }
            s.push_str(&format!(" COLLATE {}", collation));
        }
        if let Some(value) = c.default.as_deref().map(str::trim).filter(|v| !v.is_empty()) {
            s.push_str(&format!(" DEFAULT {}", crate::drivers::safe_default(value)?));
        }
        if !c.nullable {
            s.push_str(" NOT NULL");
        }
        out.push(s);
    }
    for name in &spec.drop_columns {
        out.push(format!("ALTER TABLE {} DROP COLUMN {}", target, qi(d, name)));
    }
    for r in &spec.rename_columns {
        out.push(format!(
            "ALTER TABLE {} RENAME COLUMN {} TO {}",
            target,
            qi(d, &r.from),
            qi(d, &r.to)
        ));
    }
    // Drop before add: a replaced index keeps its name, and the other order
    // would create the new definition and then drop it again.
    for name in &spec.drop_indexes {
        out.push(format!("DROP INDEX {}", qi(d, name)));
    }
    for idx in &spec.add_indexes {
        if idx.name.trim().is_empty() || idx.columns.is_empty() {
            continue;
        }
        let cols: Vec<String> = idx.columns.iter().map(|c| qi(d, c)).collect();
        out.push(format!(
            "CREATE {}INDEX {} ON {} ({})",
            if idx.unique { "UNIQUE " } else { "" },
            qi(d, idx.name.trim()),
            target,
            cols.join(", ")
        ));
    }
    if let Some(new_name) = spec.rename_to.as_deref().map(str::trim).filter(|v| !v.is_empty()) {
        out.push(format!("ALTER TABLE {} RENAME TO {}", target, qi(d, new_name)));
    }
    if out.is_empty() {
        return Err(AppError::bad("没有可用的修改"));
    }
    Ok(out)
}

fn ident_ok(value: &str) -> bool {
    !value.is_empty() && value.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

fn is_quote(c: char) -> bool {
    c == '\'' || c == '"' || c == '\u{60}'
}

fn trim_ident(value: &str) -> &str {
    value.trim_matches(|c| c == '"' || c == '\u{60}' || c == '[' || c == ']')
}

/// Pull per-column COLLATE clauses plus the WITHOUT ROWID / STRICT flags out of a
/// stored CREATE TABLE statement (PRAGMA table_info does not expose them).
fn parse_table_options(
    ddl: &str,
) -> (std::collections::HashMap<String, String>, bool, bool) {
    use std::collections::HashMap;
    let mut map: HashMap<String, String> = HashMap::new();
    let mut without_rowid = false;
    let mut strict = false;
    let upper = ddl.to_ascii_uppercase();
    if let Some(pos) = upper.rfind(')') {
        for token in ddl[pos + 1..].to_ascii_uppercase().split(|c: char| c == ',' || c.is_whitespace()) {
            match token {
                "WITHOUT" => without_rowid = true,
                "ROWID" => without_rowid = true,
                "STRICT" => strict = true,
                _ => {}
            }
        }
    }
    let (body, _) = match (ddl.find('('), ddl.rfind(')')) {
        (Some(a), Some(b)) if b > a => (&ddl[a + 1..b], &ddl[b + 1..]),
        _ => ("", ddl),
    };
    let mut depth = 0i32;
    let mut current = String::new();
    let mut parts: Vec<String> = Vec::new();
    let mut quote: Option<char> = None;
    for ch in body.chars() {
        if is_quote(ch) {
            quote = if quote == Some(ch) { None } else { Some(ch) };
            current.push(ch);
        } else if ch == '(' && quote.is_none() {
            depth += 1;
            current.push(ch);
        } else if ch == ')' && quote.is_none() {
            depth -= 1;
            current.push(ch);
        } else if ch == ',' && quote.is_none() && depth == 0 {
            parts.push(std::mem::take(&mut current));
        } else {
            current.push(ch);
        }
    }
    if !current.trim().is_empty() {
        parts.push(current);
    }
    for part in parts {
        let trimmed = part.trim();
        if trimmed.is_empty() {
            continue;
        }
        let first = trim_ident(trimmed.split_whitespace().next().unwrap_or(""));
        if first.is_empty() {
            continue;
        }
        let head = first.to_ascii_uppercase();
        if matches!(head.as_str(), "PRIMARY" | "UNIQUE" | "CHECK" | "FOREIGN" | "CONSTRAINT") {
            continue;
        }
        if let Some(pos) = trimmed.to_ascii_uppercase().find("COLLATE") {
            let after = &trimmed[pos + "COLLATE".len()..];
            let raw = after.split_whitespace().next().unwrap_or("");
            let name = trim_ident(raw).trim_end_matches(|c| c == ',' || c == ')');
            if !name.is_empty() {
                map.insert(first.to_ascii_uppercase(), name.to_string());
            }
        }
    }
    (map, without_rowid, strict)
}

pub async fn meta_options(_conn: &ConnectionHandle) -> AppResult<Value> {
    Ok(json!({
        "charsets": [
            { "charset": "UTF-8", "default_collation": "BINARY", "maxlen": 4, "description": "Unicode (推荐)" },
            { "charset": "UTF-16", "default_collation": "BINARY", "maxlen": 4, "description": "Unicode" },
            { "charset": "UTF-16le", "default_collation": "BINARY", "maxlen": 4, "description": "Unicode 小端" },
            { "charset": "UTF-16be", "default_collation": "BINARY", "maxlen": 4, "description": "Unicode 大端" }
        ],
        "collations": [
            { "collation": "BINARY", "charset": "UTF-8", "is_default": "Yes" },
            { "collation": "NOCASE", "charset": "UTF-8", "is_default": "" },
            { "collation": "RTRIM", "charset": "UTF-8", "is_default": "" }
        ],
        "engines": [],
        "row_formats": [],
        "tablespaces": [],
        "default_charset": "UTF-8",
        "default_collation": "BINARY",
        "features": {
            "charset": false,
            "table_charset": false,
            "collation": true,
            "engine": false,
            "row_format": false,
            "auto_increment": true,
            "comment": false,
            "unlogged": false,
            "tablespace": false,
            "without_rowid": true,
            "strict": true,
        },
    }))
}

pub async fn objects(conn: &ConnectionHandle, _ns: &str) -> AppResult<Value> {
    let rows = conn
        .fetch_named(
            "SELECT name AS \"name\", type AS \"raw_type\", sql AS \"sql\", tbl_name AS \"tbl\" FROM sqlite_master WHERE type IN ('view', 'trigger') ORDER BY type, name".to_string(),
        )
        .await?;
    let mut views: Vec<Value> = Vec::new();
    let mut triggers: Vec<Value> = Vec::new();
    for row in rows {
        let raw = row.get("raw_type").and_then(|v| v.as_str()).unwrap_or_default();
        let item = json!({
            "name": row.get("name").cloned().unwrap_or(Value::Null),
            "kind": if raw == "view" { "view" } else { "trigger" },
            "type": raw.to_ascii_uppercase(),
            "tbl": row.get("tbl").cloned().unwrap_or(Value::Null),
            "definition": row.get("sql").cloned().unwrap_or(Value::Null),
        });
        if raw == "view" {
            views.push(item);
        } else {
            triggers.push(item);
        }
    }
    let routines: Vec<Value> = Vec::new();
    let events: Vec<Value> = Vec::new();
    Ok(json!({ "views": views, "routines": routines, "triggers": triggers, "events": events }))
}

/// CREATE statement stored in sqlite_master (SQLite keeps the original text).
pub async fn object_definition(conn: &ConnectionHandle, ns: &str, kind: &str, name: &str) -> AppResult<String> {
    let raw_kind = match kind {
        "view" => "view",
        "trigger" => "trigger",
        other => return Err(AppError::bad(format!("SQLite 不支持查看对象类型 '{}'", other))),
    };
    let rows = conn
        .fetch_named(format!(
            "SELECT sql AS ddl FROM {} WHERE type = {} AND name = {}",
            master_of(ns),
            quote_str_for(conn.driver_kind(), raw_kind),
            quote_str_for(conn.driver_kind(), name)
        ))
        .await?;
    rows.first()
        .and_then(|r| r.get("ddl"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| AppError::not_found(format!("对象 '{}' 不存在", name)))
}

/// DROP statement for one object (identifier-quoted and kind-checked).
pub fn object_drop_sql(_ns: &str, kind: &str, name: &str) -> AppResult<String> {
    let d = DriverKind::Sqlite;
    let head = match kind {
        "view" => "DROP VIEW",
        "trigger" => "DROP TRIGGER",
        other => return Err(AppError::bad(format!("SQLite 不支持删除对象类型 '{}'", other))),
    };
    Ok(format!("{} {}", head, qi(d, name)))
}

// ------------------------------------------------------------ database accounts
//
// SQLite has no server-side account system: the file is the security boundary.
// Every account entry point reports that explicitly instead of silently doing
// nothing.

pub fn account_model() -> Value {
    json!({
        "supported": false,
        "model": "sqlite",
        "host_required": false,
        "note": "SQLite 没有数据库账号体系（权限由文件系统决定），本页签不可用。",
    })
}

pub async fn user_grants(
    _conn: &ConnectionHandle,
    _user: &str,
    _host: &str,
) -> AppResult<Value> {
    Err(AppError::bad("SQLite 没有数据库账号"))
}

/// DROP 一个账号：SQLite 没有账号体系，与其它账号入口返回同一文案。
pub fn drop_account_statement(_user: &str, _host: &str) -> AppResult<String> {
    Err(AppError::bad("SQLite 没有数据库账号"))
}

pub fn create_account_statements(
    _user: &str,
    _host: &str,
    _password: &str,
    _change: &crate::drivers::UserChange,
) -> AppResult<Vec<String>> {
    Err(AppError::bad("SQLite 没有数据库账号"))
}

pub async fn alter_account_statements(
    _conn: &ConnectionHandle,
    _user: &str,
    _host: &str,
    _change: &crate::drivers::UserChange,
) -> AppResult<Vec<String>> {
    Err(AppError::bad("SQLite 没有数据库账号"))
}
#[cfg(test)]
mod size_tests {
    use super::*;
    use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};

    /// A one-connection pool over a fresh file. An in-memory database is
    /// per-connection, and page accounting is what is under test here, so the
    /// test uses a real file it deletes afterwards.
    async fn temp_pool(tag: &str) -> (SqlitePool, std::path::PathBuf) {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let path = std::env::temp_dir().join(format!(
            "rma-sqlite-size-{}-{}-{}.sqlite",
            tag,
            std::process::id(),
            nanos
        ));
        let _ = std::fs::remove_file(&path);
        let opts = SqliteConnectOptions::new()
            .filename(&path)
            .create_if_missing(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(opts)
            .await
            .expect("open the temp database");
        (pool, path)
    }

    /// `PRAGMA <ns>.page_count * page_size` is the file-level estimate, and the
    /// namespace has to be spliced in safely (an attached alias is not `main`).
    #[tokio::test]
    async fn file_size_pragmas_read_the_page_accounting() {
        let (pool, path) = temp_pool("file").await;
        sqlx::query("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO t (v) VALUES ('a'), ('b')")
            .execute(&pool)
            .await
            .unwrap();
        let (count_sql, size_sql) = file_size_pragmas("main").expect("main is addressable");
        let count: i64 = sqlx::query_scalar(&count_sql).fetch_one(&pool).await.unwrap();
        let size: i64 = sqlx::query_scalar(&size_sql).fetch_one(&pool).await.unwrap();
        assert!(count > 0, "{count_sql} returned {count}");
        assert!(size > 0, "{size_sql} returned {size}");
        // The product is the file's own byte count, so it can never be smaller
        // than the page file SQLite reported through the filesystem.
        let on_disk = std::fs::metadata(&path).map(|m| m.len() as i64).unwrap_or(0);
        assert!(
            count * size >= on_disk,
            "{} * {} < {on_disk} on disk",
            count,
            size
        );
        pool.close().await;
        let _ = std::fs::remove_file(&path);
    }

    /// Round34 P3-03: with dbstat the per-table number must include the pages of
    /// the indexes declared on that table, not just the table's own b-tree.
    #[tokio::test]
    async fn dbstat_attributes_index_pages_to_their_table() {
        let (pool, path) = temp_pool("dbstat").await;
        sqlx::query("CREATE TABLE sized (id INTEGER PRIMARY KEY, v TEXT)")
            .execute(&pool)
            .await
            .unwrap();
        for i in 0..400 {
            sqlx::query("INSERT INTO sized (v) VALUES (?)")
                .bind(format!("value-{i}"))
                .execute(&pool)
                .await
                .unwrap();
        }
        sqlx::query("CREATE INDEX sized_v ON sized(v)")
            .execute(&pool)
            .await
            .unwrap();
        let sql = dbstat_size_sql("main").expect("dbstat ships with bundled SQLite");
        let rows: Vec<(String, i64)> = sqlx::query_as(&sql).fetch_all(&pool).await.unwrap();
        let attributed = rows
            .iter()
            .find(|(name, _)| name == "sized")
            .map(|(_, bytes)| *bytes)
            .unwrap_or(0);
        let table_only: i64 =
            sqlx::query_scalar("SELECT COALESCE(SUM(pgsize), 0) FROM dbstat WHERE name = 'sized'")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert!(table_only > 0, "the table has pages");
        assert!(
            attributed > table_only,
            "index pages must be attributed too: {attributed} vs {table_only}"
        );
        pool.close().await;
        let _ = std::fs::remove_file(&path);
    }

    /// dbstat only exists for `main`, so an attached file is measured by its own
    /// pragmas and must not silently borrow main's pages.
    #[tokio::test]
    async fn attached_namespace_falls_back_to_file_level() {
        let (pool, path) = temp_pool("attach").await;
        let aux = path.with_extension("aux.sqlite");
        let _ = std::fs::remove_file(&aux);
        sqlx::query(&format!("ATTACH DATABASE '{}' AS aux", aux.display()))
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("CREATE TABLE aux.t (id INTEGER)")
            .execute(&pool)
            .await
            .unwrap();
        assert!(dbstat_size_sql("aux").is_none());
        let (count_sql, size_sql) = file_size_pragmas("aux").expect("aux is addressable");
        let count: i64 = sqlx::query_scalar(&count_sql).fetch_one(&pool).await.unwrap();
        let size: i64 = sqlx::query_scalar(&size_sql).fetch_one(&pool).await.unwrap();
        assert!(count > 0 && size > 0, "{count_sql}={count}, {size_sql}={size}");
        pool.close().await;
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(&aux);
    }
}

/// Driver-level behaviour of the streaming console path (optimisation layer 3).
///
/// `ScriptSession::run_batched` -> `run_one_limited_batched_owned` must hand
/// rows over in `batch_size` chunks instead of materialising the whole result
/// set, mark truncation only on the last delivered batch, and stop reading when
/// the consumer returns `false` (Dart cancelled the stream).
#[cfg(test)]
mod batch_stream_tests {
    use super::*;
    use serde_json::json;
    use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// 进程内单调递增的临时库序号。
    ///
    /// 之前用 SystemTime::now().as_nanos() 做唯一后缀，但并行启动的测试线程
    /// 完全可能取到同一纳秒（实测 4 线程同时取 68.7% 会重复）→ 两个测试打开
    /// 同一个临时库，第二个 CREATE TABLE 报 "table t already exists"。
    /// 计数器在进程内由原子操作分配，天然唯一（配合 pid 跨进程也唯一）。
    static TEST_DB_SEQ: AtomicUsize = AtomicUsize::new(0);

    async fn temp_pool(tag: &str) -> (SqlitePool, std::path::PathBuf) {
        let seq = TEST_DB_SEQ.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "rma-sqlite-stream-{}-{}-{}.sqlite",
            tag,
            std::process::id(),
            seq
        ));
        let _ = std::fs::remove_file(&path);
        let opts = SqliteConnectOptions::new()
            .filename(&path)
            .create_if_missing(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(opts)
            .await
            .expect("open the temp database");
        (pool, path)
    }

    /// Pool whose `t` table holds `rows` consecutive integers.
    async fn pool_with_rows(rows: i64) -> (SqlitePool, std::path::PathBuf) {
        let (pool, path) = temp_pool("rows").await;
        sqlx::query("CREATE TABLE t (x INTEGER NOT NULL)")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query(&format!(
            "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < {rows})              INSERT INTO t (x) SELECT x FROM c"
        ))
        .execute(&pool)
        .await
        .unwrap();
        (pool, path)
    }

    fn sizes(batches: &[ResultBatch]) -> Vec<usize> {
        batches.iter().map(|batch| batch.rows.len()).collect()
    }

    fn flags(batches: &[ResultBatch]) -> Vec<bool> {
        batches.iter().map(|batch| batch.truncated).collect()
    }

    async fn cleanup(pool: SqlitePool, path: std::path::PathBuf) {
        pool.close().await;
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn reads_1200_rows_in_three_batches_without_truncating() {
        let (pool, path) = pool_with_rows(1200).await;
        let conn = pool.acquire().await.unwrap();
        let mut batches: Vec<ResultBatch> = Vec::new();
        let (result, truncated, stopped, conn) = run_one_limited_batched_owned(
            conn,
            "SELECT x FROM t ORDER BY x".to_string(),
            10_000,
            500,
            &mut |batch| {
                batches.push(batch);
                true
            },
        )
        .await;

        assert_eq!(sizes(&batches), vec![500, 500, 200]);
        // Under the cap: no batch may carry the truncation flag.
        assert_eq!(flags(&batches), vec![false, false, false]);
        assert_eq!(
            batches[0].rows.first().and_then(|row| row.first()),
            Some(&json!(1))
        );
        assert_eq!(
            batches[2].rows.last().and_then(|row| row.first()),
            Some(&json!(1200))
        );
        // Column metadata is repeated on every batch.
        assert!(batches.iter().all(|batch| batch.columns.len() == 1));

        // Rows only travelled through the callback; the ResultSet is metadata.
        assert!(result.rows.is_empty());
        assert_eq!(result.row_count, 1200);
        assert_eq!(result.columns.len(), 1);
        assert!(!result.truncated);
        assert!(!truncated);
        assert!(!stopped);
        let _ = conn.close().await;
        cleanup(pool, path).await;
    }

    #[tokio::test]
    async fn truncation_marks_only_the_last_batch() {
        let (pool, path) = pool_with_rows(1200).await;
        let conn = pool.acquire().await.unwrap();

        // 1,200 rows under a 1,100-row cap: 500 + 500 + 100, the final batch
        // (the one that hit the cap) is flagged, the earlier ones are not.
        let mut batches: Vec<ResultBatch> = Vec::new();
        let (result, truncated, stopped, conn) = run_one_limited_batched_owned(
            conn,
            "SELECT x FROM t ORDER BY x".to_string(),
            1_100,
            500,
            &mut |batch| {
                batches.push(batch);
                true
            },
        )
        .await;
        assert_eq!(sizes(&batches), vec![500, 500, 100]);
        assert_eq!(flags(&batches), vec![false, false, true]);
        assert_eq!(result.row_count, 1_100);
        assert!(result.truncated);
        assert!(truncated);
        assert!(!stopped);

        // A truncated scan stops in the middle of the sqlite statement; the
        // caller contract is to close that connection instead of reusing it
        // (ScriptSession::run_batched does exactly that). Reusing it here hangs.
        let _ = conn.close().await;
        let conn = pool.acquire().await.unwrap();

        // The cap lands exactly on a batch boundary (1,000 rows read, row 1,001
        // stops the scan): a trailing empty batch still reports the cap, the same
        // contract as the MySQL driver.
        let mut batches: Vec<ResultBatch> = Vec::new();
        let (result, truncated, stopped, conn) = run_one_limited_batched_owned(
            conn,
            "SELECT x FROM t ORDER BY x".to_string(),
            1_000,
            500,
            &mut |batch| {
                batches.push(batch);
                true
            },
        )
        .await;
        assert_eq!(sizes(&batches), vec![500, 500, 0]);
        assert_eq!(flags(&batches), vec![false, false, true]);
        assert_eq!(result.row_count, 1_000);
        assert!(result.truncated);
        assert!(truncated);
        assert!(!stopped);
        let _ = conn.close().await;
        cleanup(pool, path).await;
    }

    #[tokio::test]
    async fn consumer_stop_ends_the_scan() {
        let (pool, path) = pool_with_rows(1200).await;
        let conn = pool.acquire().await.unwrap();
        let mut batches: Vec<ResultBatch> = Vec::new();
        let (result, truncated, stopped, conn) = run_one_limited_batched_owned(
            conn,
            "SELECT x FROM t ORDER BY x".to_string(),
            10_000,
            300,
            &mut |batch| {
                batches.push(batch);
                false
            },
        )
        .await;

        // The callback refused the first batch: the scan must stop immediately.
        assert_eq!(sizes(&batches), vec![300]);
        assert!(stopped);
        assert!(!truncated);
        assert_eq!(result.row_count, 300);
        assert!(!result.truncated);
        // `stopped` tells the caller to close the connection (it is not reused).
        let _ = conn.close().await;
        cleanup(pool, path).await;
    }

    #[tokio::test]
    async fn non_row_statement_reports_one_affected_result() {
        let (pool, path) = pool_with_rows(1).await;
        let conn = pool.acquire().await.unwrap();
        let mut calls = 0usize;
        let (result, truncated, stopped, conn) = run_one_limited_batched_owned(
            conn,
            "INSERT INTO t (x) VALUES (2)".to_string(),
            10,
            500,
            &mut |_batch| {
                calls += 1;
                true
            },
        )
        .await;

        // Affected statements go through the ResultSet (kind "affected"), exactly
        // like the MySQL driver: the caller is told once via statement_done.
        assert_eq!(calls, 0, "no row batch for a non-row statement");
        assert_eq!(result.kind, "affected");
        assert_eq!(result.row_count, 1);
        assert!(result.error.is_none());
        assert!(!truncated);
        assert!(!stopped);
        let _ = conn.close().await;
        cleanup(pool, path).await;
    }
}