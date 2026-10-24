//! MySQL 语句执行（P3 Step 5 从 db.rs 迁入）。
//!
//! 覆盖单条执行、带行数上限的流式执行、调用方持有连接的脚本执行与导出用流式扫描。

use futures::StreamExt;
use serde_json::Value;
use sqlx::mysql::{MySqlPool, MySqlRow};
use sqlx::Row;

use super::row::{columns_meta, raw_row_values, row_values};
use crate::db::{
    returns_rows, split_statements, strip_leading_comments, RawResultBatch, ResultBatch, ResultSet,
    ScanStats,
};
use crate::error::{AppError, AppResult};

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

/// Streaming variant of [run_one_limited_owned] (optimisation layer 3).
///
/// Rows are decoded and handed to `on_batch` as soon as `batch_size` of them
/// have been read, so a large SQL-console result never materialises as a whole.
/// Semantics match [run_one_limited_owned]:
///
/// * a statement that does not return rows reuses [run_one_limited_owned]
///   verbatim (simple-protocol fallback for LOCK TABLES / routines included);
/// * reading stops at `max_rows` rows, `truncated` is set and the caller closes
///   the connection (existing S-08 behaviour: never drain/decode the rest);
/// * `on_batch` returning `false` stops the scan immediately; the caller closes
///   the connection, which also cancels the server-side query.
///
/// The returned [ResultSet] carries metadata only (`rows` is empty — the rows
/// travelled through the callback). `columns` is filled from the first row, so
/// a zero-row result keeps the legacy "no columns" shape.
///
/// The connection is *moved in and returned* for the same rustc/`Send` reason
/// documented on [run_one_limited_owned]: a `&mut MySqlConnection` parameter
/// makes every reborrow lifetime require `Send`, which sqlx's executor impl
/// cannot satisfy.
pub async fn run_one_limited_batched_owned(
    conn: sqlx::pool::PoolConnection<sqlx::MySql>,
    raw_pool: &MySqlPool,
    stmt: String,
    max_rows: usize,
    batch_size: usize,
    on_batch: &mut (dyn FnMut(ResultBatch) -> bool + Send),
) -> (ResultSet, bool, bool, sqlx::pool::PoolConnection<sqlx::MySql>) {
    if !returns_rows(&stmt) {
        let (result, truncated, conn) =
            run_one_limited_owned(conn, raw_pool, stmt, max_rows).await;
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
                        columns = columns_meta(&row);
                    }
                    buffered.push(row_values(&row));
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


/// Raw-cell variant of [run_one_limited_batched_owned] (optimisation layer 4).
///
/// Identical control flow, row cap, truncation flag, close policy and
/// consumer-stop semantics; the only difference is that each row is decoded
/// straight into [crate::db::RawCell]s by [super::row::raw_row_values] instead
/// of building a `serde_json::Value` tree per cell and decoding it again in the
/// engine. The SQL-console typed/streaming path is the only caller.
pub async fn run_one_limited_batched_raw_owned(
    conn: sqlx::pool::PoolConnection<sqlx::MySql>,
    raw_pool: &MySqlPool,
    stmt: String,
    max_rows: usize,
    batch_size: usize,
    on_batch: &mut (dyn FnMut(RawResultBatch) -> bool + Send),
) -> (ResultSet, bool, bool, sqlx::pool::PoolConnection<sqlx::MySql>) {
    if !returns_rows(&stmt) {
        let (result, truncated, conn) =
            run_one_limited_owned(conn, raw_pool, stmt, max_rows).await;
        return (result, truncated, false, conn);
    }
    let mut conn = conn;
    let batch_size = batch_size.max(1);
    let mut columns: Vec<crate::db::ColumnMeta> = Vec::new();
    let mut buffered: Vec<Vec<crate::db::RawCell>> =
        Vec::with_capacity(batch_size.min(max_rows.max(1)));
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
                        columns = columns_meta(&row);
                    }
                    buffered.push(raw_row_values(&row));
                    row_count += 1;
                    if buffered.len() >= batch_size {
                        let batch = RawResultBatch {
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
            let batch = RawResultBatch {
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
            let batch = RawResultBatch {
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

/// Execute `statements` inside **one transaction**, one affected result each.
///
/// Transaction control goes through sqlx's transaction manager (which issues
/// `BEGIN` with the simple/text protocol). Issuing `BEGIN` yourself through
/// `sqlx::query` would use the prepared-statement protocol, which MySQL
/// rejects with error 1295 — `run_one_limited_owned` falls back to another
/// pooled connection for such statements, so a batch driven through it would
/// silently lose atomicity. This helper exists instead of looping over the
/// single-statement path.
///
/// The first failing statement rolls the whole batch back; its 1-based index is
/// part of the error message so the caller can point at the offending row.
pub async fn run_transaction(
    pool: &MySqlPool,
    statements: Vec<String>,
) -> AppResult<Vec<ResultSet>> {
    let mut tx = pool
        .begin()
        .await
        .map_err(|e| AppError::bad(crate::error::database_message(&e)))?;
    let mut results = Vec::with_capacity(statements.len());
    for (index, stmt) in statements.into_iter().enumerate() {
        match sqlx::query(stmt.as_str()).execute(&mut *tx).await {
            Ok(result) => results.push(ResultSet {
                columns: Vec::new(),
                rows: Vec::new(),
                row_count: result.rows_affected(),
                last_insert_id: result.last_insert_id(),
                statement: stmt,
                kind: "affected".to_string(),
                error: None,
                truncated: false,
            }),
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::query_types::CellValue;
    use crate::db::RawCell;
    use crate::drivers::mysql::row::{raw_cell, value_to_json};
    use sqlx::mysql::MySqlConnectOptions;
    use sqlx::Column;

    fn env_or(key: &str, default: &str) -> String {
        std::env::var(key).unwrap_or_else(|_| default.to_string())
    }

    fn live_pool_options() -> MySqlConnectOptions {
        MySqlConnectOptions::new()
            .host(&env_or("DBPILOT_TEST_MYSQL_HOST", "127.0.0.1"))
            .port(
                env_or("DBPILOT_TEST_MYSQL_PORT", "3306")
                    .parse()
                    .unwrap_or(3306),
            )
            .username(&env_or("DBPILOT_TEST_MYSQL_USER", "root"))
            // No default database: the test creates its own scratch schema.
            .password(&std::env::var("DBPILOT_TEST_MYSQL_PASSWORD").unwrap_or_default())
    }

    const CREATE_TYPES: &str = "CREATE TABLE raw_types (\
        c_int INT,\
        c_bigint BIGINT,\
        c_ubigint BIGINT UNSIGNED,\
        c_bool BOOLEAN,\
        c_float FLOAT,\
        c_double DOUBLE,\
        c_decimal DECIMAL(30,10),\
        c_date DATE,\
        c_datetime DATETIME(3),\
        c_timestamp TIMESTAMP NULL,\
        c_time TIME,\
        c_time_neg TIME,\
        c_json JSON,\
        c_text VARCHAR(100),\
        c_binary VARBINARY(16),\
        c_null VARCHAR(10),\
        c_year YEAR,\
        c_bit BIT(8)\
    )";

    const INSERT_TYPES: &str = "INSERT INTO raw_types VALUES (\
        -42, -9223372036854775808, 18446744073709551615, 1, 1.5, 3.141592653589793,\
        '12345678901234567890.1234000000', '2024-02-29', '2024-02-29 12:34:56.789',\
        '2024-02-29 12:34:56', '12:34:56', '-12:34:56', '{\"a\":1,\"b\":\"x\"}',\
        'hello 中文', X'00FF0100', NULL, 2024, b'00000101'\
    ), (\
        NULL, 9223372036854775807, 9223372036854775808, 0, NULL, NULL, NULL, NULL,\
        NULL, NULL, NULL, NULL, NULL, 'bin', X'', 'text', NULL, NULL\
    )";

    /// One cell: the raw decoder must produce the exact legacy JSON cell that
    /// `value_to_json` produced before optimisation layer 4, and the typed cell
    /// must be the same one `CellValue::from_json` produced.
    fn assert_cell_parity(row: &MySqlRow, idx: usize) -> Value {
        let legacy = value_to_json(row, idx);
        let raw = raw_cell(row, idx);
        let name = row.column(idx).name();
        assert_eq!(
            raw.clone().into_legacy_json(),
            legacy,
            "raw decoder changed the legacy JSON for column {name}"
        );
        assert_eq!(
            crate::query_engine::raw_to_cell(raw),
            CellValue::from_json(legacy.clone()),
            "typed cell changed for column {name}"
        );
        legacy
    }

    #[tokio::test]
    #[ignore = "requires a local MySQL server (DBPILOT_TEST_MYSQL_*)"]
    async fn raw_cells_match_the_legacy_json_decoder_for_every_type_branch() {
        let pool = sqlx::mysql::MySqlPoolOptions::new()
            .max_connections(1)
            .connect_with(live_pool_options())
            .await
            .expect("connect to MySQL (set DBPILOT_TEST_MYSQL_* if not localhost/root)");
        let mut conn = pool.acquire().await.expect("acquire");

        sqlx::query("CREATE DATABASE IF NOT EXISTS rma_raw_cell_test")
            .execute(&mut *conn)
            .await
            .expect("create scratch database");
        // USE is not supported by the prepared-statement protocol (MySQL error
        // 1295), which is exactly why the console session uses raw SQL for it.
        sqlx::raw_sql("USE rma_raw_cell_test")
            .execute(&mut *conn)
            .await
            .expect("use scratch database");
        sqlx::query("DROP TABLE IF EXISTS raw_types")
            .execute(&mut *conn)
            .await
            .expect("drop old table");
        sqlx::query(CREATE_TYPES)
            .execute(&mut *conn)
            .await
            .expect("create type table");
        sqlx::query(INSERT_TYPES)
            .execute(&mut *conn)
            .await
            .expect("insert type rows");

        let rows = sqlx::query("SELECT * FROM raw_types ORDER BY c_int IS NULL, c_int")
            .fetch_all(&mut *conn)
            .await
            .expect("fetch type rows");
        assert_eq!(rows.len(), 2);

        // Every cell of both rows must decode identically.
        let expected: Vec<Vec<Value>> = rows
            .iter()
            .map(|row| (0..row.len()).map(|idx| assert_cell_parity(row, idx)).collect())
            .collect();

        // Lock the interesting branches explicitly so a future refactor cannot
        // silently move a MySQL type to a different raw representation.
        let first = &rows[0];
        assert_eq!(raw_cell(first, 0), RawCell::Int(-42));
        assert_eq!(raw_cell(first, 1), RawCell::Int(i64::MIN));
        assert_eq!(raw_cell(first, 2), RawCell::UInt(u64::MAX));
        assert_eq!(
            raw_cell(first, 6),
            RawCell::Text("12345678901234567890.1234000000".to_string()),
            "DECIMAL must stay lossless text"
        );
        assert_eq!(
            raw_cell(first, 7),
            RawCell::Text("2024-02-29".to_string())
        );
        assert!(matches!(raw_cell(first, 10), RawCell::Text(ref t) if t == "12:34:56"));
        // Negative TIME: sqlx may decode it through either the NaiveTime or the
        // TimeDelta branch (the per-cell parity loop above proves both decoders
        // agree); pin that it stays text instead of falling through to bytes.
        assert!(
            matches!(raw_cell(first, 11), RawCell::Text(_)),
            "negative TIME must decode as text, got {:?}",
            raw_cell(first, 11)
        );
        assert_eq!(
            raw_cell(first, 14),
            RawCell::Bytes(vec![0, 255, 1, 0]),
            "binary columns must stay bytes (no base64 marker in the raw path)"
        );
        assert_eq!(raw_cell(first, 15), RawCell::Null);
        let second = &rows[1];
        assert_eq!(raw_cell(second, 0), RawCell::Null);
        assert_eq!(
            raw_cell(second, 2),
            RawCell::UInt(9_223_372_036_854_775_808),
            "BIGINT UNSIGNED above i64::MAX must stay unsigned"
        );

        // ------------------------------------------------ streaming raw function
        let sql = "SELECT * FROM raw_types ORDER BY c_int IS NULL, c_int".to_string();
        let mut value_batches: Vec<ResultBatch> = Vec::new();
        let (value_result, value_truncated, value_stopped, conn) =
            run_one_limited_batched_owned(conn, &pool, sql.clone(), 50, 1, &mut |batch| {
                value_batches.push(batch);
                true
            })
            .await;
        assert!(!value_truncated && !value_stopped);

        let mut raw_batches: Vec<RawResultBatch> = Vec::new();
        let (raw_result, raw_truncated, raw_stopped, conn) =
            run_one_limited_batched_raw_owned(conn, &pool, sql.clone(), 50, 1, &mut |batch| {
                raw_batches.push(batch);
                true
            })
            .await;
        assert!(!raw_truncated && !raw_stopped);
        assert_eq!(value_batches.len(), raw_batches.len());
        assert_eq!(value_batches.len(), 2, "batch_size 1 must stream both rows");
        // The streamed order/values must match the fully materialised fetch.
        let streamed_value_rows: Vec<Vec<Value>> = value_batches
            .iter()
            .flat_map(|batch| batch.rows.clone())
            .collect();
        assert_eq!(streamed_value_rows, expected, "streaming changed row order");
        for (value_batch, raw_batch) in value_batches.iter().zip(&raw_batches) {
            let value_meta: Vec<(&str, &str)> = value_batch
                .columns
                .iter()
                .map(|c| (c.name.as_str(), c.type_name.as_str()))
                .collect();
            let raw_meta: Vec<(&str, &str)> = raw_batch
                .columns
                .iter()
                .map(|c| (c.name.as_str(), c.type_name.as_str()))
                .collect();
            assert_eq!(value_meta, raw_meta, "column metadata drifted");
            assert_eq!(value_batch.truncated, raw_batch.truncated);
            let raw_json: Vec<Vec<Value>> = raw_batch
                .rows
                .iter()
                .map(|row| row.iter().cloned().map(RawCell::into_legacy_json).collect())
                .collect();
            assert_eq!(value_batch.rows, raw_json, "streamed rows drifted");
        }
        assert_eq!(raw_result.row_count, value_result.row_count);
        assert_eq!(raw_result.row_count, 2);
        assert!(raw_result.rows.is_empty(), "rows travel through the callback");
        assert_eq!(
            raw_result.columns.len(),
            value_result.columns.len()
        );
        assert_eq!(raw_result.truncated, value_result.truncated);
        assert_eq!(raw_result.statement, value_result.statement);

        // ------------------------------------------------------ row cap / stop
        let mut truncated_batches: Vec<RawResultBatch> = Vec::new();
        let (capped, capped_flag, capped_stopped, conn) =
            run_one_limited_batched_raw_owned(
                conn,
                &pool,
                sql.clone(),
                1,
                1,
                &mut |batch| {
                    truncated_batches.push(batch);
                    true
                },
            )
            .await;
        assert!(capped_flag, "max_rows=1 over 2 rows must be truncated");
        assert!(!capped_stopped);
        assert!(capped.truncated);
        assert_eq!(capped.row_count, 1);
        // First batch carries the single row, then the trailing empty batch so
        // the consumer observes `truncated` even on a batch boundary.
        assert_eq!(truncated_batches.len(), 2);
        assert_eq!(truncated_batches[0].rows.len(), 1);
        assert!(!truncated_batches[0].truncated);
        assert!(truncated_batches[1].rows.is_empty());
        assert!(truncated_batches[1].truncated);
        // The cap closes the socket: sqlx must not drain the rest of the result.
        conn.close().await.expect("close capped connection");

        // Consumer stop (Dart cancelled the stream): stop after the first batch.
        let mut conn = pool.acquire().await.expect("acquire for stop test");
        // The pool hands out a fresh connection, which has no default schema.
        sqlx::raw_sql("USE rma_raw_cell_test")
            .execute(&mut *conn)
            .await
            .expect("use scratch database on the second connection");
        let mut seen = 0usize;
        let (stopped_result, stopped_truncated, stopped_flag, conn) =
            run_one_limited_batched_raw_owned(
                conn,
                &pool,
                sql,
                50,
                1,
                &mut |_batch| {
                    seen += 1;
                    false
                },
            )
            .await;
        assert!(stopped_flag, "consumer stop must be reported");
        assert!(!stopped_truncated);
        assert_eq!(seen, 1);
        assert_eq!(stopped_result.row_count, 1);
        conn.close().await.expect("close stopped connection");
    }
}

