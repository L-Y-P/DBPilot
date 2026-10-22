//! MySQL 语句执行（P3 Step 5 从 db.rs 迁入）。
//!
//! 覆盖单条执行、带行数上限的流式执行、调用方持有连接的脚本执行与导出用流式扫描。

use futures::StreamExt;
use serde_json::Value;
use sqlx::mysql::{MySqlPool, MySqlRow};
use sqlx::Row;

use super::row::{columns_meta, row_values};
use crate::db::{
    returns_rows, split_statements, strip_leading_comments, ResultSet, ScanStats,
};
use crate::error::AppError;

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

/// Execute DDL that the MySQL prepared-statement protocol rejects (stored routines,
/// triggers, events) using sqlx's raw SQL interface, which does not prepare.
pub async fn run_raw(pool: &MySqlPool, stmt: String) -> ResultSet {
    match sqlx::raw_sql(stmt.as_str()).execute(pool).await {
        Ok(r) => ResultSet {
            columns: Vec::new(),
            rows: Vec::new(),
            row_count: r.rows_affected(),
            last_insert_id: r.last_insert_id(),
            statement: stmt,
            kind: "affected".to_string(),
            error: None,
            truncated: false,
        },
        Err(e) => error_set(stmt, e),
    }
}
pub async fn run_one(pool: &MySqlPool, stmt: String) -> ResultSet {
    if returns_rows(&stmt) {
        match sqlx::query(stmt.as_str()).fetch_all(pool).await {
            Ok(rows) => {
                let columns = rows.first().map(columns_meta).unwrap_or_default();
                let values = rows.iter().map(row_values).collect();
                ResultSet {
                    columns,
                    row_count: rows.len() as u64,
                    rows: values,
                    last_insert_id: 0,
                    statement: stmt,
                    kind: "rows".to_string(),
                    error: None,
                    truncated: false,
                }
            }
            Err(e) => error_set(stmt, e),
        }
    } else {
        match sqlx::query(stmt.as_str()).execute(pool).await {
            Ok(r) => ResultSet {
                columns: Vec::new(),
                rows: Vec::new(),
                row_count: r.rows_affected(),
                last_insert_id: r.last_insert_id(),
                statement: stmt,
                kind: "affected".to_string(),
                error: None,
                truncated: false,
            },
            Err(e) => error_set(stmt, e),
        }
    }
}

/// Execute a row-returning statement, stopping after `max_rows` rows.
///
/// Unlike [run_one], this streams rows one at a time instead of materialising
/// the whole result set, so a `SELECT *` over a million-row table costs at
/// most `max_rows` decoded rows. When the cap is hit the result is marked
/// `truncated` and the connection is closed instead of being returned to the
/// pool: sqlx would otherwise drain (and decode!) the rest of the result set in
/// the background before the connection could be reused. Closing the socket
/// also stops the server-side query, which is exactly what the SQL console
/// needs after telling the user the result was cut off.
pub async fn run_one_limited(pool: &MySqlPool, stmt: String, max_rows: usize) -> ResultSet {
    if !returns_rows(&stmt) {
        return run_one(pool, stmt).await;
    }
    let mut conn = match pool.acquire().await {
        Ok(conn) => conn,
        Err(e) => return error_set(stmt, e),
    };
    let mut rows: Vec<MySqlRow> = Vec::new();
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
        return error_set(stmt, e);
    }
    if truncated {
        let _ = conn.close().await;
    }
    let columns = rows.first().map(columns_meta).unwrap_or_default();
    let values = rows.iter().map(row_values).collect();
    ResultSet {
        columns,
        row_count: rows.len() as u64,
        rows: values,
        last_insert_id: 0,
        statement: stmt,
        kind: "rows".to_string(),
        error: None,
        truncated,
    }
}

/// True when a statement is MySQL `LOCK TABLES` / `UNLOCK TABLES`.
fn is_lock_statement(stmt: &str) -> bool {
    let first = strip_leading_comments(stmt)
        .split_whitespace()
        .next()
        .unwrap_or("");
    first.eq_ignore_ascii_case("lock") || first.eq_ignore_ascii_case("unlock")
}

/// True when the server rejected a statement because the prepared-statement
/// protocol does not support it (MySQL error 1295).
fn prepared_protocol_unsupported(error: &sqlx::Error) -> bool {
    match error {
        sqlx::Error::Database(db) => {
            db.code().as_deref() == Some("1295")
                || db.message().contains("prepared statement protocol")
        }
        _ => false,
    }
}

/// Execute one statement on a connection owned by the caller, with a row cap.
///
/// The SQL console pins one connection per script, so session state
/// (`SET FOREIGN_KEY_CHECKS=0`, user variables, `LOCK TABLES`) applies to every
/// following statement (P3/P5). The connection is *moved in and returned* rather
/// than borrowed: a `&mut MySqlConnection` parameter makes rustc require
/// `Send` for every reborrow lifetime, which conflicts with sqlx's
/// `impl<'c> Executor<'c> for &'c mut MySqlConnection` ("implementation of
/// `Send` is not general enough").
///
/// Non-row statements use sqlx's simple protocol: the prepared protocol rejects
/// `LOCK TABLES` / `UNLOCK TABLES` and stored routines / triggers with error
/// 1295, which is why mysqldump-style scripts failed one statement at a time
/// (P4/P5). Executable comments (`/*!50001 ... */`) are forwarded verbatim; the
/// server expands them.
pub async fn run_one_limited_owned(
    mut conn: sqlx::pool::PoolConnection<sqlx::MySql>,
    // Only used when the prepared protocol cannot execute a statement (MySQL
    // error 1295: stored routines / triggers / events). That fallback runs on
    // another pooled connection: such statements are DDL and do not depend on
    // the session state the pinned connection carries (P4).
    raw_pool: &MySqlPool,
    stmt: String,
    max_rows: usize,
) -> (ResultSet, bool, sqlx::pool::PoolConnection<sqlx::MySql>) {
    if !returns_rows(&stmt) {
        if is_lock_statement(&stmt) {
            // mysqldump's data script wraps INSERTs in LOCK TABLES ... WRITE /
            // UNLOCK TABLES. The prepared protocol rejects those (error 1295),
            // and a *different* connection cannot obey them anyway. Importing a
            // dump does not need the dump-side locking, so report them as a
            // successful no-op instead of failing the whole script (P5).
            let result = ResultSet {
                columns: Vec::new(),
                rows: Vec::new(),
                row_count: 0,
                last_insert_id: 0,
                statement: stmt,
                kind: "affected".to_string(),
                error: None,
                truncated: false,
            };
            return (result, false, conn);
        }
        let result = match sqlx::query(stmt.as_str()).execute(&mut *conn).await {
            Ok(r) => ResultSet {
                columns: Vec::new(),
                rows: Vec::new(),
                row_count: r.rows_affected(),
                last_insert_id: r.last_insert_id(),
                statement: stmt,
                kind: "affected".to_string(),
                error: None,
                truncated: false,
            },
            Err(e) if prepared_protocol_unsupported(&e) => {
                match sqlx::raw_sql(stmt.as_str()).execute(raw_pool).await {
                    Ok(r) => ResultSet {
                        columns: Vec::new(),
                        rows: Vec::new(),
                        row_count: r.rows_affected(),
                        last_insert_id: r.last_insert_id(),
                        statement: stmt,
                        kind: "affected".to_string(),
                        error: None,
                        truncated: false,
                    },
                    Err(e) => error_set(stmt, e),
                }
            }
            Err(e) => error_set(stmt, e),
        };
        return (result, false, conn);
    }
    let mut rows: Vec<MySqlRow> = Vec::new();
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
    let columns = rows.first().map(columns_meta).unwrap_or_default();
    let values = rows.iter().map(row_values).collect();
    let result = ResultSet {
        columns,
        row_count: rows.len() as u64,
        rows: values,
        last_insert_id: 0,
        statement: stmt,
        kind: "rows".to_string(),
        error: None,
        truncated,
    };
    (result, truncated, conn)
}

/// Stream a row-returning statement to a callback, one row at a time./// Stream a row-returning statement to a callback, one row at a time.
///
/// Used by the export path so a large table is written to disk without ever
/// holding the full result set in memory. Returning `false` from the callback
/// stops the scan; the connection is closed then, which also stops the
/// server-side query (sqlx would otherwise drain the rest of the result set
/// before the connection is reusable).
pub async fn scan_rows<'a>(
    pool: &MySqlPool,
    stmt: String,
    mut on_row: Box<crate::core::connection::RowFn<'a>>,
) -> crate::error::AppResult<ScanStats> {
    let mut conn = pool
        .acquire()
        .await
        .map_err(|e| crate::error::AppError::bad(crate::error::database_message(&e)))?;
    let mut stats = ScanStats::default();
    let mut failure: Option<sqlx::Error> = None;
    let mut stopped = false;
    {
        let mut stream = sqlx::query(stmt.as_str()).fetch(&mut *conn);
        while let Some(item) = stream.next().await {
            match item {
                Ok(row) => {
                    if stats.columns.is_empty() {
                        stats.columns = columns_meta(&row);
                    }
                    let values = row_values(&row);
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
        return Err(crate::error::AppError::bad(
            crate::error::database_message(&e),
        ));
    }
    stats.stopped_early = stopped;
    if stopped {
        let _ = conn.close().await;
    }
    Ok(stats)
}

pub async fn run_sql(pool: &MySqlPool, sql: &str) -> Vec<ResultSet> {
    let mut results = Vec::new();
    for stmt in split_statements(sql) {
        results.push(run_one(pool, stmt).await);
    }
    results
}

pub type DynQuery<'q> = sqlx::query::Query<'q, sqlx::MySql, sqlx::mysql::MySqlArguments>;

/// Bind a JSON value to a query parameter, choosing a matching MySQL type.
pub fn bind_json<'q>(q: DynQuery<'q>, v: &Value) -> DynQuery<'q> {
    match v {
        Value::Null => q.bind(Option::<String>::None),
        Value::Bool(b) => q.bind(*b),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                q.bind(i)
            } else if let Some(u) = n.as_u64() {
                q.bind(u)
            } else {
                q.bind(n.as_f64().unwrap_or(0.0))
            }
        }
        Value::String(s) => q.bind(s.clone()),
        other => q.bind(other.to_string()),
    }
}

pub async fn primary_key_columns(pool: &MySqlPool, db: &str, table: &str) -> Result<Vec<String>, AppError> {
    let rows = sqlx::query("SELECT COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND INDEX_NAME = 'PRIMARY' ORDER BY SEQ_IN_INDEX")
        .bind(db)
        .bind(table)
        .fetch_all(pool)
        .await?;
    Ok(rows.iter().map(|r| r.try_get::<String, _>(0).unwrap_or_default()).collect())
}

pub async fn table_exists(pool: &MySqlPool, db: &str, table: &str) -> Result<bool, AppError> {
    let row = sqlx::query("SELECT COUNT(*) AS c FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?")
        .bind(db)
        .bind(table)
        .fetch_one(pool)
        .await?;
    let c: i64 = row.try_get("c").unwrap_or(0);
    Ok(c > 0)
}
