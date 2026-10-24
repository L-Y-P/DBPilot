//! SQL console: execute, EXPLAIN, and query history.
//!
//! Ports the web `routes/sql.rs`. History is no longer per-user: the desktop
//! app has a single user, so `HistoryStore` is queried without a username filter.
//!
//! This file is the flutter_rust_bridge surface only. The multi-statement
//! engine, the observer/batching machinery and every conversion that touches
//! `dbpilot-core` types (`ResultSet` / `ColumnMeta`) live in
//! `crate::query_engine`: FRB scans the whole `api` module tree and would
//! otherwise generate bare codecs for those external types.

use serde_json::{json, Value};

use super::query_types::{QueryEvent, QueryResponseDto};
use super::{parse, state, strip_leading_comments, switch_database_for_use, use_statement_target};
use crate::core::dialect::DialectCapability;
use crate::error::AppError;
use crate::frb_generated::StreamSink;
use crate::query_engine::{clean_database, QueryRequest};

/// Maximum rows a single SQL-console statement may materialise.
///
/// The console used to return every row of every statement. A plain
/// `SELECT *` over a 1,000,000-row table froze the UI for ~200s and used
/// ~1 GB of RSS; 3,000,000 rows froze it for over 6 minutes and had to be
/// force-killed (S-08). Capping the result keeps the console responsive and
/// bounded; the UI tells the user the output was cut off and to add
/// WHERE/LIMIT or use the export tab for the full data.
pub const MAX_CONSOLE_ROWS: usize = 50_000;

/// Run a SQL script (one or many statements) and record it in history.
///
/// Compatibility shim: keeps the pre-typed `serde_json::Value` contract so the
/// Dart UI and the Rust integration tests that treat the response as JSON keep
/// working. The payload is produced by [QueryResponseDto::to_json_value], which
/// is field-for-field identical to the old `json!(...)` response.
#[deprecated(
    note = "compatibility shim for the old JSON contract; integration tests only — use run_query_typed / run_query_stream"
)]
pub async fn run_query(body: Value) -> anyhow::Result<Value> {
    Ok(run_query_typed(body).await?.to_json_value())
}

/// Typed variant of [run_query] (optimisation layer 1).
///
/// Returns the result sets as structs instead of a JSON tree: no `to_value`
/// deep copy, no `to_string`, no Dart `jsonDecode`.
pub async fn run_query_typed(body: Value) -> anyhow::Result<QueryResponseDto> {
    crate::query_engine::run_typed(body).await
}

/// Streaming variant of [run_query] (optimisation layer 3).
///
/// Emits one `Started` per statement, zero or more `Batch` events, one
/// `StatementDone` per statement and a final `Done`; a top-level failure is
/// reported as `Failed`. Rows are handed to `sink` while the driver is still
/// reading them, so the console never materialises the whole result set.
pub async fn run_query_stream(sink: StreamSink<QueryEvent>, body: Value) -> anyhow::Result<()> {
    crate::query_engine::run_stream(sink, body).await
}

/// Cancel the query currently running from the SQL console.
///
/// PostgreSQL: find the backend through pg_stat_activity and call
/// pg_cancel_backend. MySQL: find the connection through PROCESSLIST and KILL
/// CONNECTION; the pool entry is forgotten so the next query opens a fresh
/// connection. SQLite runs in-process and cannot be safely interrupted.
pub async fn cancel_query() -> anyhow::Result<Value> {
    let state = state()?;
    let active = state.active().await?;
    let token = state
        .cancel_token()
        .await
        .ok_or_else(|| AppError::bad("没有正在执行的查询"))?;
    if token.is_empty() || !token.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(AppError::bad("查询取消令牌无效").into());
    }
    let pattern = format!("%rma_cancel:{token}%");
    let driver = state.driver(&active.driver_id)?;
    if !driver.supports(DialectCapability::KillSession) {
        return Err(
            AppError::bad("SQLite 在应用进程内执行查询，无法安全取消；请等待查询完成").into(),
        );
    }
    // 用活动连接的句柄取消；不再额外取一次 admin 连接。
    let handle = state.connection_for(None).await?;

    // Mark before cancelling: the in-flight query must observe the marker no
    // matter who wins the race between the cancellation and its own error
    // handling.
    state.mark_cancelled(&token).await;
    // P2-4：方言 SQL（PROCESSLIST / pg_stat_activity / KILL / pg_cancel_backend）
    // 由驱动持有；api 只负责令牌、状态标记与池失效。
    let cancelled = match driver.cancel_session_by_token(&handle, &pattern).await {
        Ok(count) => count,
        Err(error) => {
            // Nothing was cancelled, so drop the marker again.
            let _ = state.take_cancelled().await;
            return Err(error.into());
        }
    };
    let reconnected = cancelled > 0 && driver.dialect().reconnect_after_cancel();
    if reconnected {
        // The killed connection is gone; drop the cached pool so the next query
        // reconnects instead of handing back a dead session.
        let database = state
            .active_database()
            .await
            .or_else(|| active.spec.database().map(str::to_string));
        if let Some(database) = database {
            state.pools.forget_database(&active.spec, &database).await;
        }
    } else if cancelled == 0 {
        // No matching backend: the query had already finished.
        let _ = state.take_cancelled().await;
    }
    Ok(json!({
        "ok": true,
        "cancelled": cancelled,
        "driver": driver.id(),
        "reconnected": reconnected,
    }))
}

/// EXPLAIN / EXPLAIN QUERY PLAN for the first real statement of the request.
///
/// A leading USE prelude is applied as a validated database switch first (it
/// cannot be explained, and users naturally include it in the console buffer).
pub async fn explain(body: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let req: QueryRequest = parse("query", body)?;
    if req.sql.trim().is_empty() {
        return Err(AppError::bad("SQL 语句不能为空").into());
    }
    let mut database: Option<String> = clean_database(req.database.as_ref()).map(str::to_string);
    let splitter = state.driver_for_active().await?;
    let mut first: Option<String> = None;
    for statement in crate::db::split_statements_for(splitter.dialect(), &req.sql) {
        if let Some(target) = use_statement_target(&statement) {
            switch_database_for_use(&state, &target).await?;
            database = Some(target);
            continue;
        }
        // Session preludes (the table page opens with SET search_path for
        // PostgreSQL) cannot be EXPLAINed; apply them and explain the next real
        // statement.
        let lower = strip_leading_comments(&statement)
            .trim_start()
            .to_ascii_lowercase();
        if lower.starts_with("set ") || lower.starts_with("reset ") {
            let handle = state.connection_for(database.as_deref()).await?;
            let _ = handle.execute(&statement).await;
            continue;
        }
        first = Some(statement);
        break;
    }
    let first = first.ok_or_else(|| AppError::bad("没有可 EXPLAIN 的语句"))?;
    let driver = state.driver_for_active().await?;
    let handle = state.connection_for(database.as_deref()).await?;
    // Do not double-prefix a statement the user already wrote as EXPLAIN.
    let already_explain = first
        .trim_start()
        .to_ascii_uppercase()
        .starts_with("EXPLAIN");
    // P2-4：EXPLAIN / EXPLAIN QUERY PLAN 的前缀由方言决定。
    let statement = if already_explain {
        first
    } else {
        driver.dialect().explain_sql(&first)
    };
    let result = handle.execute(&statement).await;
    if let Some(err) = result.error {
        return Err(AppError::bad(err).into());
    }
    Ok(json!({ "results": [result] }))
}

/// Query history, most recent first.
pub async fn history_list(limit: Option<u32>, offset: Option<u32>) -> anyhow::Result<Value> {
    let state = state()?;
    let limit = limit.unwrap_or(100).clamp(1, 10_000) as usize;
    let offset = offset.unwrap_or(0) as usize;
    let (entries, total) = state.history.page(limit, offset).await;
    Ok(json!({
        "history": entries,
        "total": total,
        "limit": limit,
        "offset": offset,
    }))
}

pub async fn history_clear() -> anyhow::Result<Value> {
    let state = state()?;
    state.history.clear().await?;
    Ok(json!({ "ok": true }))
}
