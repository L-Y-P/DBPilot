//! Internal SQL-console engine (optimisation layers 1 + 3).
//!
//! This module is deliberately **outside `crate::api`**: flutter_rust_bridge
//! scans every item in the `api` module tree and generates codecs for the types
//! its signatures mention, even behind `#[frb(ignore)]`. Types like
//! `ColumnMeta`, `ResultSet`, `ResultBatch` / `RawResultBatch` belong to
//! `dbpilot-core` and must never leak into that scan: codegen emitted bare
//! `ColumnMeta` impls without
//! importing them, which broke the generated file (E0425). The `api` surface
//! therefore only knows the FRB DTOs from `crate::api::query_types` and
//! delegates here.
//!
//! `run_query` / `run_query_typed` / `run_query_stream` share [run_engine] so the
//! legacy-JSON, typed and streaming paths cannot drift apart.

use std::sync::Arc;

use serde::Deserialize;
use serde_json::{json, Value};

use crate::api::query::MAX_CONSOLE_ROWS;
use crate::api::query_types::{
    CellValue, ColumnDto, QueryEvent, QueryResponseDto, QuerySummaryDto, ResultSetDto,
};
use crate::api::{
    parse, state, strip_leading_comments, switch_database_for_use, use_statement_target,
};
use crate::core::dialect::DialectCapability;
use crate::db::{ColumnMeta, RawCell, RawResultBatch, ResultSet};
use crate::error::{AppError, AppResult};
use crate::frb_generated::StreamSink;
use crate::history::new_entry;
use crate::state::AppState;

/// Row batch size of the streaming console path (optimisation layer 3).
///
/// 500 rows keeps one Dart event at tens of KB for typical result widths: the
/// UI can paint the first page before the whole result set exists, while the
/// per-event FFI/codec overhead stays negligible.
pub(crate) const STREAM_BATCH_SIZE: usize = 500;

/// Request body of every console entry point.
///
/// Lives here (not in `api`): `#[derive(Deserialize)]` is a `serde` concern of the
/// engine; the FRB surface only forwards the raw `Value`.
#[derive(Deserialize)]
pub(crate) struct QueryRequest {
    pub(crate) sql: String,
    #[serde(default)]
    pub(crate) database: Option<String>,
}

pub(crate) fn clean_database(value: Option<&String>) -> Option<&str> {
    value.map(String::as_str).map(str::trim).filter(|s| !s.is_empty())
}

/// Result entry for a handled session directive (USE), shown in the console.
pub(crate) fn session_result(statement: &str, message: &str) -> ResultSet {
    ResultSet {
        columns: vec![ColumnMeta {
            name: "结果".to_string(),
            type_name: "TEXT".to_string(),
        }],
        rows: vec![vec!(json!(message))],
        row_count: 1,
        last_insert_id: 0,
        statement: statement.to_string(),
        kind: "rows".to_string(),
        error: None,
        truncated: false,
    }
}

/// Result entry for a failed USE directive, so a whole batch is not thrown away
/// just because the switching statement was invalid.
pub(crate) fn session_error_result(statement: &str, message: &str) -> ResultSet {
    ResultSet {
        columns: Vec::new(),
        rows: Vec::new(),
        row_count: 0,
        last_insert_id: 0,
        statement: statement.to_string(),
        kind: "error".to_string(),
        error: Some(message.to_string()),
        truncated: false,
    }
}

/// Convert a driver result set into the typed DTO.
///
/// In streaming runs `result.rows` is already empty (rows travel through
/// batches); this then just becomes the statement meta.
pub(crate) fn result_set_dto(result: ResultSet) -> ResultSetDto {
    ResultSetDto {
        columns: result.columns.into_iter().map(column_dto).collect(),
        rows: result
            .rows
            .into_iter()
            .map(|row| row.into_iter().map(CellValue::from_json).collect())
            .collect(),
        row_count: result.row_count as i64,
        last_insert_id: result.last_insert_id as i64,
        statement: result.statement,
        kind: result.kind,
        error: result.error,
        truncated: result.truncated,
    }
}

/// Internal `ColumnMeta -> ColumnDto` conversion (not part of the FRB surface).
pub(crate) fn column_dto(meta: ColumnMeta) -> ColumnDto {
    ColumnDto {
        name: meta.name,
        type_name: meta.type_name,
    }
}

/// The same DTO without row data (the `StatementDone` event payload).
pub(crate) fn without_rows(mut dto: ResultSetDto) -> ResultSetDto {
    dto.rows.clear();
    dto
}

/// Typed console entry point (`run_query_typed` delegates here).
pub(crate) async fn run_typed(body: Value) -> anyhow::Result<QueryResponseDto> {
    let state = state()?;
    let req: QueryRequest = parse("query", body)?;
    if req.sql.trim().is_empty() {
        return Err(AppError::bad("SQL 语句不能为空").into());
    }
    let mut observer = CollectObserver::default();
    let summary = run_engine(state, req, &mut observer).await?;
    Ok(QueryResponseDto {
        results: observer.results,
        summary,
    })
}

/// Streaming console entry point (`run_query_stream` delegates here).
pub(crate) async fn run_stream(
    sink: StreamSink<QueryEvent>,
    body: Value,
) -> anyhow::Result<()> {
    let mut observer = StreamObserver::new(sink);
    if let Err(error) = run_stream_inner(&mut observer, body).await {
        // Top-level failures (bad body, no connection, ...) are delivered as an
        // event so they arrive in stream order; the returned Result stays Ok
        // because the sink is the actual error channel.
        let _ = observer.emit(QueryEvent::failed(error.to_string()));
    }
    Ok(())
}

async fn run_stream_inner<E: EventEmitter>(
    observer: &mut StreamObserver<E>,
    body: Value,
) -> anyhow::Result<()> {
    let state = state()?;
    let req: QueryRequest = parse("query", body)?;
    if req.sql.trim().is_empty() {
        return Err(AppError::bad("SQL 语句不能为空").into());
    }
    let summary = run_engine(state, req, observer).await?;
    let _ = observer.emit(QueryEvent::done(summary));
    Ok(())
}

/// Observer of one console run.
///
/// The whole run (multi-statement split, pinned connection, USE switch, cancel
/// token, DDL pool eviction, search_path, history push) lives in [run_engine];
/// this trait only decides what happens to the rows. Implementing the run once
/// instead of three times is what keeps the typed, legacy-JSON and streaming
/// paths from drifting apart:
///
/// * [CollectObserver] rebuilds the classic result sets for `run_query` /
///   `run_query_typed`;
/// * [StreamObserver] forwards [QueryEvent]s to Dart as they arrive.
///
/// `batch` returning `false` means "stop the run" (the Dart stream was
/// cancelled); the engine finishes the current statement's bookkeeping and then
/// stops issuing statements.
#[flutter_rust_bridge::frb(ignore)]
trait QueryObserver: Send {
    fn started(&mut self, statement_index: i64, statement: &str);

    fn batch(
        &mut self,
        statement_index: i64,
        columns: Vec<ColumnMeta>,
        rows: Vec<Vec<RawCell>>,
        truncated: bool,
    ) -> bool;

    fn statement_done(&mut self, statement_index: i64, result: ResultSetDto);

    /// Post-run hook for the N-07 cancellation rewrite (the collected path can
    /// still rewrite results; the streaming path cannot rewrite events already
    /// sent, which is why the engine also rewrites per statement).
    fn rewrite_cancelled(&mut self, _message: &str) {}
}

/// Observer that materialises the legacy `Vec<ResultSetDto>` response.
#[derive(Default)]
#[flutter_rust_bridge::frb(ignore)]
struct CollectObserver {
    results: Vec<ResultSetDto>,
    rows: Vec<Vec<CellValue>>,
}

impl QueryObserver for CollectObserver {
    fn started(&mut self, _statement_index: i64, _statement: &str) {
        self.rows.clear();
    }

    fn batch(
        &mut self,
        _statement_index: i64,
        _columns: Vec<ColumnMeta>,
        rows: Vec<Vec<RawCell>>,
        _truncated: bool,
    ) -> bool {
        self.rows.extend(convert_raw_rows(rows));
        true
    }

    fn statement_done(&mut self, _statement_index: i64, mut result: ResultSetDto) {
        // Rows travelled through `batch`; the meta from the driver has none.
        result.rows = std::mem::take(&mut self.rows);
        self.results.push(result);
    }

    fn rewrite_cancelled(&mut self, message: &str) {
        for result in &mut self.results {
            if let Some(error) = result.error.as_mut() {
                if is_cancel_transport_error(error) {
                    *error = message.to_string();
                }
            }
        }
    }
}

/// Converts raw driver cells into the typed DTO cell (no JSON intermediate).
///
/// This is the raw-path replacement for `CellValue::from_json`, and the rules
/// must stay identical to it so the legacy `run_query` JSON response does not
/// change:
///
/// * a `UInt` that fits in `i64` became an integer before too (the legacy
///   number's `as_i64` succeeded first);
/// * a `UInt` above `i64::MAX` became **text** before too (`CellValue` has no
///   unsigned integer), keeping every digit instead of rounding through f64;
/// * a non-finite float was `Null` before too (`json!(f64::NAN)` is null).
pub(crate) fn raw_to_cell(cell: RawCell) -> CellValue {
    match cell {
        RawCell::Null => CellValue::null(),
        RawCell::Bool(value) => CellValue::bool(value),
        RawCell::Int(value) => CellValue::int(value),
        RawCell::UInt(value) => match i64::try_from(value) {
            Ok(value) => CellValue::int(value),
            Err(_) => CellValue::text(value.to_string()),
        },
        RawCell::Float(value) => {
            if value.is_finite() {
                CellValue::float(value)
            } else {
                CellValue::null()
            }
        }
        RawCell::Text(value) => CellValue::text(value),
        RawCell::Bytes(value) => CellValue::bytes(value),
    }
}

/// Converts a row batch's raw cells in place (no extra copy of the row vectors).
fn convert_raw_rows(rows: Vec<Vec<RawCell>>) -> Vec<Vec<CellValue>> {
    rows.into_iter()
        .map(|row| row.into_iter().map(raw_to_cell).collect())
        .collect()
}

/// Destination of the streaming events.
///
/// Abstracted over [StreamSink] so the event construction/ordering can be unit
/// tested without a live FFI stream.
#[flutter_rust_bridge::frb(ignore)]
trait EventEmitter: Send {
    fn emit_event(&self, event: QueryEvent) -> bool;
}

impl EventEmitter for StreamSink<QueryEvent> {
    fn emit_event(&self, event: QueryEvent) -> bool {
        self.add(event).is_ok()
    }
}

/// Observer that emits [QueryEvent]s as the driver reads rows.
#[flutter_rust_bridge::frb(ignore)]
struct StreamObserver<E: EventEmitter> {
    emitter: E,
    first_batch: bool,
}

impl<E: EventEmitter> StreamObserver<E> {
    fn new(emitter: E) -> Self {
        Self {
            emitter,
            first_batch: true,
        }
    }

    fn emit(&self, event: QueryEvent) -> bool {
        self.emitter.emit_event(event)
    }
}

impl<E: EventEmitter> QueryObserver for StreamObserver<E> {
    fn started(&mut self, statement_index: i64, statement: &str) {
        self.first_batch = true;
        self.emit(QueryEvent::started(statement_index, statement.to_string()));
    }

    fn batch(
        &mut self,
        statement_index: i64,
        columns: Vec<ColumnMeta>,
        rows: Vec<Vec<RawCell>>,
        truncated: bool,
    ) -> bool {
        // Column metadata is needed once per statement, not on every batch.
        let columns = if self.first_batch {
            self.first_batch = false;
            columns.into_iter().map(column_dto).collect()
        } else {
            Vec::new()
        };
        self.emit(QueryEvent::batch(
            statement_index,
            columns,
            convert_raw_rows(rows),
            truncated,
        ))
    }

    fn statement_done(&mut self, statement_index: i64, result: ResultSetDto) {
        self.emit(QueryEvent::statement_done(
            statement_index,
            // The event carries metadata only; rows were already batched.
            without_rows(result),
        ));
    }
}

/// Publish one fully materialised result (the client-handled USE statements)
/// through the observer. Returns false when the consumer asked to stop.
fn emit_result(
    observer: &mut dyn QueryObserver,
    statement_index: i64,
    result: ResultSet,
) -> bool {
    let ResultSet {
        columns,
        rows,
        row_count,
        last_insert_id,
        statement,
        kind,
        error,
        truncated,
    } = result;
    let mut keep = true;
    if !rows.is_empty() {
        // Fully materialised results (the client-handled USE statements) are
        // still built as legacy JSON by their producers; convert them at the
        // observer boundary so every observer sees one row representation.
        let rows: Vec<Vec<RawCell>> = rows
            .into_iter()
            .map(|row| row.into_iter().map(RawCell::from_legacy_json).collect())
            .collect();
        keep = observer.batch(statement_index, columns.clone(), rows, truncated);
    }
    let meta = ResultSetDto {
        columns: columns.into_iter().map(column_dto).collect(),
        rows: Vec::new(),
        row_count: row_count as i64,
        last_insert_id: last_insert_id as i64,
        statement,
        kind,
        error,
        truncated,
    };
    observer.statement_done(statement_index, meta);
    keep
}

/// The one console engine behind `run_query`, `run_query_typed` and
/// `run_query_stream`.
///
/// A `USE <database>` statement is handled as a validated database switch
/// instead of being forwarded to the server: the console's only_db / hide_db
/// boundary is checked exactly like the database picker, then following
/// statements run against the new database. That makes the natural
/// "USE db;" prelude work without letting raw SQL escape the visibility rules.
async fn run_engine(
    state: Arc<AppState>,
    req: QueryRequest,
    observer: &mut dyn QueryObserver,
) -> anyhow::Result<QuerySummaryDto> {
    // P4：按方言切分（DELIMITER 只对声明支持它的方言是客户端指令）。
    let driver_impl = state.driver_for_active().await?;
    let statements = crate::db::split_statements_for(driver_impl.dialect(), &req.sql);
    if statements.is_empty() {
        return Err(AppError::bad("SQL 语句不能为空").into());
    }
    let mut database: Option<String> =
        clean_database(req.database.as_ref()).map(str::to_string);
    // P3/P5: pin one connection for the whole script. Session state set by one
    // statement (FOREIGN_KEY_CHECKS, user variables, LOCK TABLES, search_path)
    // then applies to every following statement, like the mysql/psql CLI.
    let mut session = open_console_session(state.clone(), database.as_deref()).await?;
    // P3 Step 2：会话是 Box<dyn SessionHandle>，api 不再认识 ScriptSession/SessionConn。
    let driver_id = session.driver_id().to_string();
    // P2-4：能力判断走注册表的驱动对象（driver_impl 已在切分前取到）。
    let started = std::time::Instant::now();
    // Cancellation: embed a per-run token in every statement as a comment.
    // PostgreSQL finds it in pg_stat_activity and calls pg_cancel_backend;
    // MySQL finds it in information_schema.PROCESSLIST and KILLs the connection.
    // The comment is stripped from the displayed results below.
    // (驱动决定「怎么找、怎么杀」，见 DatabaseDriver::cancel_session_by_token。)
    let cancelable = driver_impl.supports(DialectCapability::KillSession);
    let mut cancel_token: Option<String> = None;
    let mut result_tag: Option<String> = None;
    if cancelable {
        let token = uuid::Uuid::new_v4().simple().to_string();
        result_tag = Some(format!("/*rma_cancel:{token}*/ "));
        state.set_cancel_token(Some(token.clone())).await;
        cancel_token = Some(token);
    }
    let mut statement_count: i64 = 0;
    let mut failed: i64 = 0;
    let mut truncated_any = false;
    let mut last_use: Option<String> = None;
    // Databases created from the console: their cached pools (if any) are
    // invalidated after the script so a later `db_for()` dials the new database
    // instead of a half-dead cached connection (P2). Dropped databases are
    // evicted immediately after the DROP statement, below.
    let mut touched_databases: Vec<String> = Vec::new();
    // Session state that must survive a mid-script `USE` switch. A switch needs a
    // connection whose default database is the target, and MySQL cannot run
    // `USE` through sqlx's prepared protocol, so the session is re-pinned from
    // that database's pool. Replaying the SET/RESET preludes keeps
    // FOREIGN_KEY_CHECKS, user variables and sql_mode in effect (P3/P5).
    let mut session_preludes: Vec<String> = Vec::new();
    // Set when the consumer asked to stop (stream cancelled / sink closed).
    let mut stop_requested = false;
    for (position, statement) in statements.into_iter().enumerate() {
        let statement_index = position as i64;
        observer.started(statement_index, &statement);
        if let Some(target) = use_statement_target(&statement) {
            match switch_database_for_use(&state, &target).await {
                Ok(()) => {
                    database = Some(target.clone());
                    last_use = Some(target.clone());
                    // 与 db_for 相同的解析 + 授权路径，只是返回固定会话。
                    let rebound = state.open_session(Some(&target)).await;
                    match rebound {
                        Ok(mut next) => {
                            for prelude in &session_preludes {
                                let replayed =
                                    next.run_limited(prelude.clone(), MAX_CONSOLE_ROWS).await;
                                if let Some(error) = replayed.error {
                                    tracing::warn!(
                                        "could not replay session setting after USE {target}: {error}"
                                    );
                                }
                            }
                            session = next;
                        }
                        Err(e) => {
                            let result = session_error_result(&statement, &e.to_string());
                            statement_count += 1;
                            failed += 1;
                            observer.statement_done(
                                statement_index,
                                without_rows(result_set_dto(result)),
                            );
                            break;
                        }
                    }
                    let result =
                        session_result(&statement, &format!("已切换到数据库：{}", target));
                    let truncated = result.truncated;
                    truncated_any |= truncated;
                    statement_count += 1;
                    if !emit_result(observer, statement_index, result) {
                        break;
                    }
                }
                Err(e) => {
                    let result = session_error_result(&statement, &e.to_string());
                    statement_count += 1;
                    failed += 1;
                    observer.statement_done(
                        statement_index,
                        without_rows(result_set_dto(result)),
                    );
                    break;
                }
            }
            continue;
        }
        // Classify before the cancellation comment is prepended.
        let database_ddl = database_ddl_target(driver_impl.dialect(), &statement);
        let session_prelude = if is_session_prelude(&statement) {
            Some(statement.clone())
        } else {
            None
        };
        let tagged = match result_tag.as_deref() {
            Some(tag) => format!("{tag}{statement}"),
            None => statement,
        };
        // S-08: cap the console result set instead of materialising everything.
        // The statement is already fully split by split_statements(); no second
        // split happens here (that second split used to cut PostgreSQL function
        // bodies and MySQL DELIMITER scripts into fragments — P1).
        let mut result = {
            let mut on_batch = |batch: RawResultBatch| -> bool {
                let keep = observer.batch(
                    statement_index,
                    batch.columns,
                    batch.rows,
                    batch.truncated,
                );
                if !keep {
                    stop_requested = true;
                }
                keep
            };
            session
                .run_batched_raw(
                    tagged,
                    MAX_CONSOLE_ROWS,
                    STREAM_BATCH_SIZE,
                    &mut on_batch,
                )
                .await
        };
        // N-07: a cancelled MySQL connection / canceled PostgreSQL backend fails
        // the in-flight query with a transport error. Replace that raw protocol
        // message with the user-facing explanation *before* the statement result
        // is published — the streaming path cannot rewrite an event afterwards.
        if result
            .error
            .as_deref()
            .is_some_and(is_cancel_transport_error)
        {
            if let Some(token) = cancel_token.as_deref() {
                if let Some(cancelled) = state.take_cancelled().await {
                    if cancelled == token {
                        result.error =
                            Some(driver_impl.dialect().cancel_message().to_string());
                    }
                }
            }
        }
        // The cancellation comment is an implementation detail of the token;
        // strip it before exposing the statement text.
        if let Some(tag) = result_tag.as_deref() {
            if let Some(rest) = result.statement.strip_prefix(tag) {
                result.statement = rest.to_string();
            }
        }
        if result.error.is_none() {
            if let Some(change) = database_ddl {
                match change {
                    DatabaseDdl::Drop(name) => {
                        // Evict immediately: after DROP DATABASE, other pooled
                        // connections can keep a NULL default database and later
                        // DDL (`No database selected`) fails depending on which
                        // connection the pool happens to hand out. Release the
                        // pinned connection first because `Pool::close()` waits
                        // for checked-out connections.
                        let active = state.active().await?;
                        let was_active =
                            state.active_database().await.as_deref() == Some(name.as_str())
                                || active.spec.database() == Some(name.as_str());
                        if was_active {
                            session.release().await;
                        }
                        state.pools.evict_database(&active.spec, &name).await;
                        if active.spec.database() == Some(name.as_str()) {
                            state.pools.evict_default(&active.spec).await;
                        }
                        if state.active_database().await.as_deref() == Some(name.as_str()) {
                            // Do not leave the tree pointing at a dropped database;
                            // a following script can CREATE + USE it again.
                            state.set_active_database(None).await;
                        }
                        if was_active {
                            // Re-open a session without a default database so the
                            // following CREATE DATABASE / USE statements can run.
                            session = open_console_session(state.clone(), None).await?;
                        }
                    }
                    DatabaseDdl::Create(name) => touched_databases.push(name),
                }
            }
            if let Some(prelude) = session_prelude {
                session_preludes.push(prelude);
            }
        }
        truncated_any |= result.truncated;
        if result.error.is_some() {
            failed += 1;
        }
        statement_count += 1;
        observer.statement_done(
            statement_index,
            without_rows(result_set_dto(result)),
        );
        if stop_requested {
            break;
        }
    }
    if let Some(token) = cancel_token.as_deref() {
        state.clear_cancel_token(token).await;
    }
    // Leftover cancellation marker (e.g. the run finished between the KILL and
    // this point): the collected path can still rewrite its results.
    if let Some(cancelled) = state.take_cancelled().await {
        if cancel_token.as_deref() == Some(cancelled.as_str()) {
            observer.rewrite_cancelled(driver_impl.dialect().cancel_message());
        }
    }
    let elapsed_ms = started.elapsed().as_millis() as i64;
    // A SET/RESET of search_path changes the session default schema; return the
    // new value so the tree can highlight/sort by it immediately.
    let touched_search_path = driver_impl.supports(DialectCapability::Schemas)
        && req.sql.split(';').any(|statement| {
            let lower = statement.trim_start().to_ascii_lowercase();
            (lower.starts_with("set ") || lower.starts_with("reset "))
                && lower.contains("search_path")
        });
    let search_path = if touched_search_path {
        Some(session.search_path().await)
    } else {
        None
    };
    // Release the pinned connection before evicting pools. sqlx's Pool::close()
    // waits for checked-out connections, so evicting the session's own pool while
    // still holding its connection would deadlock.
    drop(session);
    // Invalidate pools for databases the script created, now that it finished.
    if !touched_databases.is_empty() {
        let active = state.active().await?;
        for name in touched_databases {
            // A recreated database may still have a half-dead cached pool;
            // force the next db_for() to dial it again.
            state.pools.evict_database(&active.spec, &name).await;
        }
    }
    // The SQL console sends no database when it targets the active one. Record
    // the physical database (and, for PostgreSQL, the schema) so history is
    // still meaningful.
    let history_database: Option<String> = match database.as_deref() {
        Some(schema) if driver_impl.supports(DialectCapability::Schemas) => {
            let active = state.active_database().await.unwrap_or_default();
            if active.is_empty() {
                Some(schema.to_string())
            } else {
                Some(format!("{active}/{schema}"))
            }
        }
        Some(name) => Some(name.to_string()),
        None => state.active_database().await,
    };
    let entry = new_entry(
        &req.sql,
        history_database.as_deref(),
        statement_count as usize,
        failed as usize,
        elapsed_ms as u64,
    );
    let _ = state.history.push(entry).await;
    Ok(QuerySummaryDto {
        statement_count,
        failed,
        elapsed_ms,
        driver: driver_id,
        search_path,
        database,
        use_database: last_use,
        // S-08: the UI shows a "result truncated" banner when this is true.
        truncated: truncated_any,
        row_limit: MAX_CONSOLE_ROWS as i64,
    })
}

/// True when a statement changes connection-local state that must be replayed
/// after a `USE` re-binds the session.
fn is_session_prelude(statement: &str) -> bool {
    let first = strip_leading_comments(statement)
        .split_whitespace()
        .next()
        .unwrap_or("");
    first.eq_ignore_ascii_case("set") || first.eq_ignore_ascii_case("reset")
}

/// What a CREATE / DROP DATABASE statement did, for pool invalidation.
#[flutter_rust_bridge::frb(ignore)]
enum DatabaseDdl {
    Create(String),
    Drop(String),
}

/// Parse a CREATE / DROP DATABASE statement so the console can invalidate the
/// cached pools afterwards.
///
/// MySQL also accepts SCHEMA as a synonym for DATABASE; PostgreSQL's DROP SCHEMA
/// is a schema inside the active database, so it must NOT evict a pool.
fn database_ddl_target(
    dialect: &dyn crate::core::dialect::DatabaseDialect,
    statement: &str,
) -> Option<DatabaseDdl> {
    let trimmed = strip_leading_comments(statement)
        .trim()
        .trim_end_matches(';')
        .trim();
    let tokens: Vec<&str> = trimmed.split_whitespace().collect();
    let create = match tokens.first()?.to_ascii_uppercase().as_str() {
        "CREATE" => true,
        "DROP" => false,
        _ => return None,
    };
    let object = tokens.get(1)?.to_ascii_uppercase();
    // MySQL 认 DATABASE 与 SCHEMA；PostgreSQL 的 SCHEMA 是库内对象，不能触发
    // 库级池失效；SQLite 走文件路径。名单由方言给出（P2-4/§database_ddl_keywords）。
    if !dialect
        .database_ddl_keywords()
        .iter()
        .any(|keyword| *keyword == object)
    {
        return None;
    }
    let mut index = 2;
    if tokens.get(index).is_some_and(|t| t.eq_ignore_ascii_case("IF")) {
        index += 1;
    }
    if tokens.get(index).is_some_and(|t| t.eq_ignore_ascii_case("NOT")) {
        index += 1;
    }
    if tokens.get(index).is_some_and(|t| t.eq_ignore_ascii_case("EXISTS")) {
        index += 1;
    }
    let raw = tokens.get(index)?.trim();
    // A quoted name containing spaces was split by split_whitespace(); do not
    // guess a truncated name and evict the wrong pool.
    if (raw.starts_with('`') && !raw.ends_with('`'))
        || (raw.starts_with('"') && !raw.ends_with('"'))
    {
        return None;
    }
    if raw.matches('`').count() > 2 || raw.matches('"').count() > 2 {
        return None;
    }
    let name = raw.trim_matches('`').trim_matches('"').trim();
    if name.is_empty() || name.contains(';') || name.contains(' ') {
        return None;
    }
    Some(if create {
        DatabaseDdl::Create(name.to_string())
    } else {
        DatabaseDdl::Drop(name.to_string())
    })
}

/// Open the pinned connection for a console run.
///
/// MySQL: the remembered database may have just been dropped, together with the
/// connection's configured default database; a script that recreates it
/// (`CREATE DATABASE ...; USE ...`) still has to run, so fall back to a session
/// without a default database instead of failing before the first statement.
async fn open_console_session(
    state: std::sync::Arc<AppState>,
    database: Option<&str>,
) -> AppResult<Box<dyn crate::core::session::SessionHandle>> {
    match state.open_session(database).await {
        Ok(session) => Ok(session),
        Err(error) => {
            let active = state.active().await?;
            // MySQL 可以在没有默认库的情况下连接（脚本会自己 CREATE + USE）；
            // PostgreSQL 必须有物理库，SQLite 走文件。用能力位表达，不 match 驱动。
            let driver = state.driver(&active.driver_id)?;
            if !driver.is_file_based() && !driver.requires_database() {
                let mut spec = active.spec.clone();
                spec.database = None;
                // 走驱动/池供给方打开固定会话（不再调用 Db::script_session）。
                if let Ok(session) = driver.open_session(&state.pools, &spec, None).await {
                    return Ok(session);
                }
            }
            Err(error)
        }
    }
}

/// Does this error look like the connection was killed / backend cancelled
/// while the query was running, rather than a genuine SQL error?
///
/// MySQL `KILL CONNECTION` and PostgreSQL `pg_cancel_backend` both tear down
/// the in-flight exchange, so sqlx reports transport-level failures such as
/// "expected to read 4 bytes, got 0 bytes at EOF".
fn is_cancel_transport_error(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    [
        "error communicating with database",
        "expected to read",
        "got 0 bytes",
        "at eof",
        "connection reset",
        "connection closed",
        "connection was closed",
        "broken pipe",
        "server closed the connection",
        "terminating connection",
        "canceling statement",
        "cancelling statement",
        "query canceled",
        "query cancelled",
        "operation was canceled",
    ]
    .iter()
    .any(|needle| lower.contains(needle))
}

#[cfg(test)]
mod tests {
    use base64::Engine as _;

    use super::*;
    use crate::drivers::DriverKind;

    #[test]
    fn recognises_use_directives_through_comments_and_quotes() {
        assert_eq!(use_statement_target("USE db").as_deref(), Some("db"));
        assert_eq!(
            use_statement_target("  use \u{60}my-db\u{60};").as_deref(),
            Some("my-db")
        );
        assert_eq!(
            use_statement_target("-- switch\nUSE hidden_db").as_deref(),
            Some("hidden_db")
        );
        assert_eq!(
            use_statement_target("/* comment */ use \"quoted\"").as_deref(),
            Some("quoted")
        );
        assert_eq!(use_statement_target("USE ").as_deref(), Some(""));
    }

    #[test]
    fn does_not_treat_ordinary_statements_as_use() {
        for sql in [
            "SELECT 'USE hidden_db'",
            "SELECT used FROM t",
            "SELECT 1; SELECT 2",
            "USERS",
            "USE_CASE",
            "-- just a comment",
        ] {
            assert_eq!(use_statement_target(sql), None, "false positive for {sql}");
        }
    }

    #[test]
    fn recognises_cancelled_run_transport_errors() {
        // Real messages observed after MySQL KILL CONNECTION / PG cancel.
        let cancelled = [
            "error communicating with database: expected to read 4 bytes, got 0 bytes at EOF",
            "error communicating with database: Connection reset by peer (os error 54)",
            "connection was closed",
            "canceling statement due to user request",
            "query canceled",
        ];
        for message in cancelled {
            assert!(
                is_cancel_transport_error(message),
                "should be treated as cancellation: {message}"
            );
        }
        // Genuine SQL errors must keep their own message.
        let real_errors = [
            "Unknown column 'nope' in 'field list' (1054)",
            "syntax error at or near \"SELEC\"",
            "relation \"missing\" does not exist",
        ];
        for message in real_errors {
            assert!(
                !is_cancel_transport_error(message),
                "must not be rewritten: {message}"
            );
        }
        // The user-facing text must explain the outcome, not leak protocol noise.
        // P2-4：文案由方言提供（不再在 api 里 match DriverKind）。
        for driver in [DriverKind::Mysql, DriverKind::Postgres] {
            let text = crate::drivers::builtin::dialect_for(driver).cancel_message();
            assert!(text.contains("查询已取消"), "{driver:?}: {text}");
            assert!(!text.contains("EOF"), "{driver:?}: {text}");
        }
        assert!(MAX_CONSOLE_ROWS >= 1_000, "row cap must still allow useful results");
    }

    // --------------------------------------------- layer-1 / layer-3 behaviour

    /// Minimal pinned session used to exercise the trait's default
    /// `run_batched` (the code path PostgreSQL / SQLite take).
    struct FakeSession {
        result: Option<ResultSet>,
        seen_max_rows: Vec<usize>,
    }

    #[async_trait::async_trait]
    impl crate::core::session::SessionHandle for FakeSession {
        fn driver_id(&self) -> &'static str {
            "fake"
        }

        async fn run_limited(&mut self, _statement: String, max_rows: usize) -> ResultSet {
            self.seen_max_rows.push(max_rows);
            self.result.take().expect("run_limited must be called once")
        }

        async fn search_path(&mut self) -> String {
            String::new()
        }

        async fn release(&mut self) {}
    }

    #[tokio::test]
    async fn default_run_batched_caps_at_max_rows_and_chunks_rows() {
        use crate::core::session::SessionHandle as _;

        let result = ResultSet {
            columns: vec![ColumnMeta {
                name: "x".to_string(),
                type_name: "INT".to_string(),
            }],
            rows: (0..5).map(|value| vec![json!(value)]).collect(),
            row_count: 5,
            last_insert_id: 0,
            statement: "SELECT x".to_string(),
            kind: "rows".to_string(),
            error: None,
            truncated: true,
        };
        let mut session = FakeSession {
            result: Some(result),
            seen_max_rows: Vec::new(),
        };
        let mut sizes = Vec::new();
        let mut flags = Vec::new();
        let result = session
            .run_batched(
                "SELECT x".to_string(),
                MAX_CONSOLE_ROWS,
                2,
                &mut |batch| {
                    sizes.push(batch.rows.len());
                    flags.push(batch.truncated);
                    true
                },
            )
            .await;
        // The row cap is still enforced by `run_limited`, not by the chunker.
        assert_eq!(session.seen_max_rows, vec![MAX_CONSOLE_ROWS]);
        assert_eq!(sizes, vec![2, 2, 1]);
        assert_eq!(flags, vec![false, false, true]);
        // Rows are delivered through the callback only.
        assert!(result.rows.is_empty());
        assert_eq!(result.row_count, 5);
        assert!(result.truncated);
        assert_eq!(result.columns.len(), 1);
    }


    #[tokio::test]
    async fn default_run_batched_raw_converts_value_batches_to_raw_cells() {
        use crate::core::session::SessionHandle as _;
        use crate::db::RawCell;

        let result = ResultSet {
            columns: vec![ColumnMeta {
                name: "x".to_string(),
                type_name: "BIGINT".to_string(),
            }],
            rows: vec![
                vec![json!(1), json!("text")],
                vec![Value::Null, json!(u64::MAX)],
            ],
            row_count: 2,
            last_insert_id: 0,
            statement: "SELECT x".to_string(),
            kind: "rows".to_string(),
            error: None,
            truncated: true,
        };
        let mut session = FakeSession {
            result: Some(result),
            seen_max_rows: Vec::new(),
        };
        let mut batches: Vec<RawResultBatch> = Vec::new();
        let result = session
            .run_batched_raw("SELECT x".to_string(), MAX_CONSOLE_ROWS, 1, &mut |batch| {
                batches.push(batch);
                true
            })
            .await;
        let rows: Vec<Vec<RawCell>> = batches.iter().flat_map(|b| b.rows.clone()).collect();
        assert_eq!(
            rows,
            vec![
                vec![RawCell::Int(1), RawCell::Text("text".to_string())],
                vec![RawCell::Null, RawCell::UInt(u64::MAX)],
            ]
        );
        let flags: Vec<bool> = batches.iter().map(|b| b.truncated).collect();
        assert_eq!(flags, vec![false, true]);
        assert!(result.rows.is_empty());
        assert_eq!(result.row_count, 2);
        assert!(result.truncated);
    }

    #[test]
    fn raw_cells_convert_to_the_same_typed_cells_as_legacy_json() {
        for value in [
            Value::Null,
            json!(true),
            json!(false),
            json!(-7),
            json!(42),
            json!(i64::MAX),
            // Above i64::MAX: CellValue has no unsigned variant, so the typed
            // cell is text (all digits preserved).
            json!(u64::MAX),
            json!(9_223_372_036_854_775_808u64),
            json!(1.25),
            json!("text"),
            json!(""),
            // DECIMAL/DATE/DATETIME/JSON arrive as strings.
            json!("12345678901234567890.1234"),
            binary_cell(&[0, 1, 254, 255]),
            binary_cell(&[]),
            json!({ "a": 1 }),
            json!([1, 2]),
        ] {
            assert_eq!(
                raw_to_cell(RawCell::from_legacy_json(value.clone())),
                CellValue::from_json(value.clone()),
                "raw and legacy decoding disagree for {value}"
            );
        }
        // Non-finite floats: the legacy `json!(NaN)` was null.
        assert_eq!(raw_to_cell(RawCell::Float(f64::NAN)), CellValue::null());
        assert_eq!(
            raw_to_cell(RawCell::Float(f64::INFINITY)),
            CellValue::null()
        );
    }

    #[test]
    fn legacy_json_is_byte_identical_between_the_raw_and_value_paths() {
        for value in [
            Value::Null,
            json!(true),
            json!(-7),
            json!(1.5),
            json!("text"),
            binary_cell(&[9, 8, 7]),
        ] {
            assert_eq!(
                raw_to_cell(RawCell::from_legacy_json(value.clone())).into_json(),
                CellValue::from_json(value.clone()).into_json(),
                "legacy JSON changed for {value}"
            );
        }
        // u64 boundary: the typed console has always emitted text here (see
        // `CellValue::from_json`), so the raw path must not "restore" a number.
        assert_eq!(
            raw_to_cell(RawCell::UInt(u64::MAX)).into_json(),
            json!(u64::MAX.to_string())
        );
        // Small unsigned integers stay integers.
        assert_eq!(raw_to_cell(RawCell::UInt(7)).into_json(), json!(7));
    }

    #[derive(Default)]
    struct RecordingEmitter {
        events: std::cell::RefCell<Vec<QueryEvent>>,
    }

    impl EventEmitter for RecordingEmitter {
        fn emit_event(&self, event: QueryEvent) -> bool {
            self.events.borrow_mut().push(event);
            true
        }
    }

    #[test]
    fn stream_observer_emits_started_batches_statement_done_then_done() {
        let mut observer = StreamObserver::new(RecordingEmitter::default());
        observer.started(0, "SELECT x");
        let columns = vec![ColumnMeta {
            name: "x".to_string(),
            type_name: "INT".to_string(),
        }];
        assert!(observer.batch(
            0,
            columns.clone(),
            vec![
                vec![RawCell::Int(1)],
                vec![RawCell::Int(2)],
            ],
            false
        ));
        // Later batches must not repeat the column metadata.
        assert!(observer.batch(
            0,
            columns,
            vec![vec![RawCell::Int(3)]],
            true
        ));
        let result = ResultSet {
            columns: vec![ColumnMeta {
                name: "x".to_string(),
                type_name: "INT".to_string(),
            }],
            rows: Vec::new(),
            row_count: 3,
            last_insert_id: 0,
            statement: "SELECT x".to_string(),
            kind: "rows".to_string(),
            error: None,
            truncated: true,
        };
        observer.statement_done(0, result_set_dto(result));
        assert!(observer.emit(QueryEvent::done(QuerySummaryDto {
            statement_count: 1,
            failed: 0,
            elapsed_ms: 3,
            driver: "mysql".to_string(),
            search_path: None,
            database: None,
            use_database: None,
            truncated: true,
            row_limit: MAX_CONSOLE_ROWS as i64,
        })));

        let events = observer.emitter.events.borrow();
        let kinds: Vec<u8> = events.iter().map(|event| event.kind).collect();
        assert_eq!(
            kinds,
            vec![
                crate::api::query_types::EVENT_KIND_STARTED,
                crate::api::query_types::EVENT_KIND_BATCH,
                crate::api::query_types::EVENT_KIND_BATCH,
                crate::api::query_types::EVENT_KIND_STATEMENT_DONE,
                crate::api::query_types::EVENT_KIND_DONE,
            ]
        );
        // Started carries the statement text and its index.
        assert_eq!(events[0].statement.as_deref(), Some("SELECT x"));
        assert_eq!(events[0].statement_index, 0);
        // First batch carries columns, the second one does not.
        assert_eq!(events[1].columns.len(), 1);
        assert!(events[2].columns.is_empty());
        assert_eq!(
            events[1].rows,
            vec![vec![CellValue::int(1)], vec![CellValue::int(2)]]
        );
        assert!(!events[1].truncated);
        assert!(events[2].truncated);
        // StatementDone carries meta only (no rows), Done carries the summary.
        let done_meta = events[3].result.as_ref().expect("statement_done payload");
        assert!(done_meta.rows.is_empty());
        assert_eq!(done_meta.row_count, 3);
        assert!(done_meta.truncated);
        let summary = events[4].summary.as_ref().expect("done payload");
        assert_eq!(summary.statement_count, 1);
        assert_eq!(summary.row_limit, MAX_CONSOLE_ROWS as i64);
        assert!(summary.truncated);
    }

    // ------------------------------- legacy JSON compatibility (moved here) --

    fn binary_cell(bytes: &[u8]) -> Value {
        json!({
            "__binary__": base64::engine::general_purpose::STANDARD.encode(bytes),
            "len": bytes.len(),
        })
    }

    fn sample_result_set() -> ResultSet {
        ResultSet {
            columns: vec![
                ColumnMeta {
                    name: "id".to_string(),
                    type_name: "BIGINT".to_string(),
                },
                ColumnMeta {
                    name: "blob".to_string(),
                    type_name: "BLOB".to_string(),
                },
            ],
            rows: vec![
                vec![json!(1), binary_cell(&[0, 255])],
                vec![json!(2), Value::Null],
            ],
            row_count: 2,
            last_insert_id: 0,
            statement: "SELECT id, blob FROM t".to_string(),
            kind: "rows".to_string(),
            error: None,
            truncated: false,
        }
    }

    #[test]
    fn response_json_matches_the_legacy_run_query_shape() {
        let dto = QueryResponseDto {
            results: vec![result_set_dto(sample_result_set())],
            summary: QuerySummaryDto {
                statement_count: 1,
                failed: 0,
                elapsed_ms: 12,
                driver: "mysql".to_string(),
                search_path: None,
                database: Some("app".to_string()),
                use_database: None,
                truncated: false,
                row_limit: 50_000,
            },
        };
        let expected = json!({
            "results": [{
                "columns": [
                    { "name": "id", "type_name": "BIGINT" },
                    { "name": "blob", "type_name": "BLOB" },
                ],
                "rows": [
                    [1, binary_cell(&[0, 255])],
                    [2, null],
                ],
                "row_count": 2,
                "last_insert_id": 0,
                "statement": "SELECT id, blob FROM t",
                "kind": "rows",
                "error": null,
                "truncated": false,
            }],
            "statement_count": 1,
            "failed": 0,
            "elapsed_ms": 12,
            "driver": "mysql",
            "search_path": null,
            "database": "app",
            "use_database": null,
            "truncated": false,
            "row_limit": 50_000,
        });
        assert_eq!(dto.to_json_value(), expected);
    }

    #[test]
    fn legacy_response_keeps_the_flat_top_level_key_set() {
        let dto = QueryResponseDto {
            results: vec![result_set_dto(sample_result_set())],
            summary: QuerySummaryDto {
                statement_count: 4,
                failed: 1,
                elapsed_ms: 7,
                driver: "postgres".to_string(),
                search_path: Some("public".to_string()),
                database: Some("app".to_string()),
                use_database: Some("other".to_string()),
                truncated: true,
                row_limit: 50_000,
            },
        };
        let value = dto.to_json_value();
        let object = value
            .as_object()
            .expect("legacy response must be an object");
        let keys: std::collections::BTreeSet<&str> = object.keys().map(String::as_str).collect();
        let expected: std::collections::BTreeSet<&str> = [
            "results",
            "statement_count",
            "failed",
            "elapsed_ms",
            "driver",
            "search_path",
            "database",
            "use_database",
            "truncated",
            "row_limit",
        ]
        .into_iter()
        .collect();
        assert_eq!(keys, expected, "legacy run_query top-level keys changed");
        // Spot-check that the summary fields are flat (not nested under summary).
        assert_eq!(object["statement_count"], json!(4));
        assert_eq!(object["failed"], json!(1));
        assert_eq!(object["driver"], json!("postgres"));
        assert_eq!(object["search_path"], json!("public"));
        assert_eq!(object["use_database"], json!("other"));
        assert_eq!(object["truncated"], json!(true));
        assert_eq!(object["row_limit"], json!(50_000));
        assert!(object.get("summary").is_none(), "summary must stay internal");
    }


    #[test]
    fn collect_observer_builds_the_same_legacy_json_from_raw_batches() {
        let mut observer = CollectObserver::default();
        observer.started(0, "SELECT id, blob FROM t");
        let columns = vec![
            ColumnMeta {
                name: "id".to_string(),
                type_name: "BIGINT".to_string(),
            },
            ColumnMeta {
                name: "blob".to_string(),
                type_name: "BLOB".to_string(),
            },
        ];
        assert!(observer.batch(
            0,
            columns.clone(),
            vec![
                vec![RawCell::Int(1), RawCell::Bytes(vec![0, 255])],
                vec![RawCell::UInt(u64::MAX), RawCell::Null],
            ],
            false
        ));
        observer.statement_done(
            0,
            ResultSetDto {
                columns: columns.into_iter().map(column_dto).collect(),
                rows: Vec::new(),
                row_count: 2,
                last_insert_id: 0,
                statement: "SELECT id, blob FROM t".to_string(),
                kind: "rows".to_string(),
                error: None,
                truncated: false,
            },
        );
        let dto = observer.results.pop().expect("one result");
        assert_eq!(
            dto.rows,
            vec![
                vec![CellValue::int(1), CellValue::bytes(vec![0, 255])],
                // u64 above i64::MAX is text, exactly like the value path.
                vec![CellValue::text(u64::MAX.to_string()), CellValue::null()],
            ]
        );
        // ... and the legacy JSON cells are the pre-change shapes.
        let json = dto.to_json_value();
        assert_eq!(
            json["rows"],
            json!([
                [1, binary_cell(&[0, 255])],
                [u64::MAX.to_string(), null],
            ])
        );
    }

    #[test]
    fn statement_done_meta_drops_rows_but_keeps_metadata() {
        let dto = without_rows(result_set_dto(sample_result_set()));
        assert!(dto.rows.is_empty());
        assert_eq!(dto.row_count, 2);
        assert_eq!(dto.columns.len(), 2);
        assert_eq!(dto.kind, "rows");
    }
}

