//! Data import + streaming SQL-file execution surface.
//!
//! Long-running work (validating a multi-GB file, importing it, executing a big
//! SQL dump) runs in a background task and reports progress through a small
//! in-memory job registry. The Dart side polls import_job_status; this keeps the
//! Flutter UI responsive and gives every operation a cancel button.
//!
//! Function arguments that carry structured data are JSON objects, matching the
//! convention used by the rest of the FFI surface (no FRB codegen changes for
//! new fields).

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{json, Value};

use super::{parse, state};
use crate::drivers::{literal, qi, qualify, DriverKind};
use crate::error::{AppError, AppResult};
use crate::importer::{
    self, ExecuteSpec, FieldSpec, ParseSpec, Progress, ReadSpec, ValidateSpec,
};

// ---------------------------------------------------------------- job registry

#[derive(Clone, Copy, PartialEq, Eq)]
enum JobState {
    Running,
    Done,
    Failed,
    Cancelled,
}

impl JobState {
    fn as_str(self) -> &'static str {
        match self {
            JobState::Running => "running",
            JobState::Done => "done",
            JobState::Failed => "failed",
            JobState::Cancelled => "cancelled",
        }
    }
}

struct Job {
    id: String,
    kind: &'static str,
    started: Instant,
    progress: Mutex<Progress>,
    cancel: AtomicBool,
    state: Mutex<JobState>,
    result: Mutex<Option<Value>>,
    error: Mutex<Option<String>>,
}

impl Job {
    fn new(kind: &'static str) -> Arc<Job> {
        Arc::new(Job {
            id: uuid::Uuid::new_v4().to_string(),
            kind,
            started: Instant::now(),
            progress: Mutex::new(Progress {
                total_bytes: 0,
                ..Default::default()
            }),
            cancel: AtomicBool::new(false),
            state: Mutex::new(JobState::Running),
            result: Mutex::new(None),
            error: Mutex::new(None),
        })
    }

    fn set_progress(&self, value: &Progress) {
        if let Ok(mut guard) = self.progress.lock() {
            *guard = value.clone();
        }
    }

    fn finish(&self, cancelled: bool, value: Value) {
        {
            let mut state = self.state.lock().unwrap();
            *state = if cancelled {
                JobState::Cancelled
            } else {
                JobState::Done
            };
        }
        *self.result.lock().unwrap() = Some(value);
    }

    fn fail(&self, message: String) {
        {
            let mut state = self.state.lock().unwrap();
            *state = JobState::Failed;
        }
        *self.error.lock().unwrap() = Some(message);
    }

    fn snapshot(&self) -> Value {
        let state = *self.state.lock().unwrap();
        let progress = self.progress.lock().unwrap().clone();
        let result = self.result.lock().unwrap().clone();
        let error = self.error.lock().unwrap().clone();
        json!({
            "job_id": self.id,
            "kind": self.kind,
            "state": state.as_str(),
            "done": state != JobState::Running,
            "progress": progress,
            "result": result,
            "error": error,
            "elapsed_ms": self.started.elapsed().as_millis() as u64,
        })
    }
}

fn jobs() -> &'static Mutex<HashMap<String, Arc<Job>>> {
    static JOBS: OnceLock<Mutex<HashMap<String, Arc<Job>>>> = OnceLock::new();
    JOBS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn register(job: Arc<Job>) -> String {
    let id = job.id.clone();
    if let Ok(mut map) = jobs().lock() {
        // Drop stale finished jobs so a long session does not accumulate them.
        map.retain(|_, j| {
            let state = *j.state.lock().unwrap();
            state == JobState::Running || j.started.elapsed() < Duration::from_secs(300)
        });
        map.insert(id.clone(), job);
    }
    id
}

fn lookup(job_id: &str) -> AppResult<Arc<Job>> {
    jobs()
        .lock()
        .ok()
        .and_then(|map| map.get(job_id).cloned())
        .ok_or_else(|| AppError::not_found("任务不存在或已结束"))
}

// ------------------------------------------------------------------ helpers

fn total_bytes(path: &str) -> AppResult<u64> {
    importer::file_info(path).map(|info| info.size)
}

/// Structure + columns of the target table, looked up exactly once per job.
async fn table_columns(
    state: &crate::state::AppState,
    database: Option<&str>,
    table: Option<&str>,
) -> AppResult<Option<Vec<importer::TableColumn>>> {
    let (Some(database), Some(table)) = (database, table) else {
        return Ok(None);
    };
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(Some(database)).await?;
    let structure = driver.table_structure(&conn, database, table).await?;
    Ok(Some(importer::columns_from_structure(&structure)))
}

fn span(message: impl Into<String>) -> AppError {
    AppError::bad(message.into())
}

// ------------------------------------------------------------------ inspect

#[derive(Deserialize)]
struct PreviewRequest {
    read: ReadSpec,
    fields: FieldSpec,
    #[serde(default)]
    limit: Option<usize>,
    /// 快速建表向导会带 infer: true；schema 无论传不传都会返回（契约 §2.3），
    /// 这里只是让旧前端/新前端都能安全传参。
    #[serde(default)]
    infer: Option<bool>,
}

/// Detect the file's format and suggest read/field rules.
pub async fn import_inspect(path: String) -> anyhow::Result<Value> {
    Ok(importer::inspect(&path)?)
}

/// Split and parse the first few records with the current rule so the wizard
/// can echo one complete record back to the user.
pub async fn import_preview(path: String, params: Value) -> anyhow::Result<Value> {
    let req: PreviewRequest = parse("params", params)?;
    // schema 总是返回（契约 §2.3）；infer 只是新前端的显式意图标记。
    let _infer = req.infer.unwrap_or(false);
    let spec = ParseSpec {
        path,
        read: req.read,
        fields: req.fields,
    };
    Ok(importer::preview(&spec, req.limit.unwrap_or(5))?)
}

// -------------------------------------------------------------------- probe

#[derive(Deserialize)]
struct ProbeRequest {
    #[serde(flatten)]
    spec: ValidateSpec,
}

/// Read the first data record, convert it with the column mapping, INSERT it
/// inside a transaction and roll the transaction back.
///
/// The response shows the generated SQL and the row read back inside the
/// transaction: proof that the rule + mapping + conversion work before a single
/// row is committed.
pub async fn import_probe(database: String, table: String, params: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let mut req: ProbeRequest = parse("params", params)?;
    req.spec.database = Some(database.clone());
    req.spec.table = Some(table.clone());
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(Some(&database)).await?;
    let structure = driver.table_structure(&conn, &database, &table).await?;
    let columns = importer::columns_from_structure(&structure);
    let probe = importer::probe_first_row(&req.spec, &columns)?;
    let column_names: Vec<String> = probe["columns"]
        .as_array()
        .map(|list| {
            list.iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    let values: Vec<Value> = probe["values"].as_array().cloned().unwrap_or_default();
    let insert_sql = importer::build_single_insert_sql(
        driver.kind(),
        &database,
        &table,
        &column_names,
        &values,
    );
    let select_sql = probe_select_sql(driver.kind(), &database, &table, &columns, &values);
    let outcome = match conn.probe_insert(&insert_sql, &select_sql).await {
        Ok(value) => value,
        Err(e) => json!({ "affected": 0, "row": Value::Null, "error": e.to_string() }),
    };
    let mut response = probe;
    response["insert_sql"] = json!(insert_sql);
    response["select_sql"] = json!(select_sql);
    response["affected"] = outcome["affected"].clone();
    response["row"] = outcome["row"].clone();
    response["probe_error"] = outcome.get("error").cloned().unwrap_or(Value::Null);
    Ok(response)
}

/// Null-safe "find the row we just inserted" predicate used inside the probe
/// transaction. MySQL uses the null-safe equals operator, PostgreSQL uses IS
/// NOT DISTINCT FROM, SQLite uses IS.
fn probe_select_sql(
    kind: DriverKind,
    database: &str,
    table: &str,
    columns: &[crate::importer::TableColumn],
    values: &[Value],
) -> String {
    // JSON and binary columns do not compare reliably to a plain literal across
    // drivers (JSON normalises whitespace/keys, json has no equality operator,
    // bytea needs a cast). The probe only needs *a* sample row inside the
    // rolled-back transaction, so those columns are left out of the predicate.
    let conditions: Vec<String> = columns
        .iter()
        .zip(values.iter())
        .filter(|(column, _)| {
            !matches!(
                crate::importer::column_kind(if column.data_type.trim().is_empty() {
                    &column.type_name
                } else {
                    &column.data_type
                }),
                crate::importer::ColumnKind::Json | crate::importer::ColumnKind::Binary
            )
        })
        .map(|(column, value)| {
            let column = qi(kind, &column.name);
            if value.is_null() {
                format!("{column} IS NULL")
            } else {
                match kind {
                    DriverKind::Mysql => format!("{column} <=> {}", literal(kind, value)),
                    DriverKind::Postgres => format!(
                        "{column} IS NOT DISTINCT FROM {}",
                        literal(kind, value)
                    ),
                    DriverKind::Sqlite => format!("{column} IS {}", literal(kind, value)),
                }
            }
        })
        .collect();
    let target = qualify(kind, database, table);
    if conditions.is_empty() {
        return format!("SELECT * FROM {target} LIMIT 1");
    }
    format!(
        "SELECT * FROM {target} WHERE {} LIMIT 1",
        conditions.join(" AND ")
    )
}

// ----------------------------------------------------------------- validate

#[derive(Deserialize)]
struct ValidateRequest {
    #[serde(flatten)]
    spec: ValidateSpec,
    #[serde(default)]
    max_issues: Option<usize>,
}

/// Start a full-file validation job. Returns a job id immediately.
pub async fn import_validate_start(params: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let req: ValidateRequest = parse("params", params)?;
    let total = total_bytes(&req.spec.parse.path)?;
    let columns = table_columns(
        &state,
        req.spec.database.as_deref(),
        req.spec.table.as_deref(),
    )
    .await?;
    if req.spec.mapping.is_some() && columns.is_none() {
        return Err(span("校验列映射需要目标数据库和目标表").into());
    }
    let max_issues = req.max_issues.unwrap_or(importer::DEFAULT_MAX_ISSUES);
    let job = Job::new("validate");
    let job_id = register(job.clone());
    let job_progress = job.clone();
    let job_cancel = job.clone();
    let job_finish = job.clone();
    tokio::spawn(async move {
        let spec = req.spec;
        let columns = columns;
        let progress = move |value: &Progress| job_progress.set_progress(value);
        let result = tokio::task::spawn_blocking(move || {
            importer::validate(
                &spec,
                columns.as_deref(),
                max_issues,
                total,
                &progress,
                &job_cancel.cancel,
            )
        })
        .await;
        match result {
            Ok(Ok(value)) => {
                let cancelled = value["cancelled"].as_bool().unwrap_or(false);
                job_finish.finish(cancelled, value);
            }
            Ok(Err(e)) => job_finish.fail(e.to_string()),
            Err(e) => job_finish.fail(format!("校验任务失败: {e}")),
        }
    });
    Ok(json!({ "job_id": job_id }))
}

// ------------------------------------------------------------------ execute

#[derive(Deserialize)]
struct ExecuteRequest {
    #[serde(flatten)]
    spec: ExecuteSpec,
}

/// Start the real import job. Returns a job id immediately; the Dart side polls
/// progress and can cancel.
pub async fn import_execute_start(params: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let req: ExecuteRequest = parse("params", params)?;
    let database = req
        .spec
        .validate
        .database
        .clone()
        .ok_or_else(|| span("缺少目标数据库"))?;
    let table = req
        .spec
        .validate
        .table
        .clone()
        .ok_or_else(|| span("缺少目标表"))?;
    if req.spec.validate.mapping.is_none() {
        return Err(span("请先设置列映射").into());
    }
    let total = total_bytes(&req.spec.validate.parse.path)?;
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(Some(&database)).await?;
    let structure = driver.table_structure(&conn, &database, &table).await?;
    let columns = importer::columns_from_structure(&structure);
    let job = Job::new("import");
    let job_id = register(job.clone());
    let job_progress = job.clone();
    let job_cancel = job.clone();
    let job_finish = job.clone();
    tokio::spawn(async move {
        let spec = req.spec;
        let progress = move |value: &Progress| job_progress.set_progress(value);
        let result = importer::execute(
            driver.as_ref(),
            &conn,
            &spec,
            &columns,
            total,
            &progress,
            &job_cancel.cancel,
        )
        .await;
        match result {
            Ok(value) => {
                let cancelled = value["cancelled"].as_bool().unwrap_or(false);
                job_finish.finish(cancelled, value);
            }
            Err(e) => job_finish.fail(e.to_string()),
        }
    });
    Ok(json!({ "job_id": job_id }))
}

// --------------------------------------------------------------- job status

/// Poll a job. Once a job is finished its result is returned and the job is
/// removed from the registry.
pub fn import_job_status(job_id: String) -> anyhow::Result<Value> {
    let job = lookup(&job_id)?;
    let snapshot = job.snapshot();
    if snapshot["done"].as_bool().unwrap_or(false) {
        if let Ok(mut map) = jobs().lock() {
            map.remove(&job_id);
        }
    }
    Ok(snapshot)
}

/// Request cancellation. The running task checks the flag between records /
/// batches and returns partial results.
pub fn import_job_cancel(job_id: String) -> anyhow::Result<Value> {
    let job = lookup(&job_id)?;
    job.cancel.store(true, Ordering::Relaxed);
    Ok(json!({ "cancelled": true, "job_id": job_id }))
}

// -------------------------------------------------------------- SQL files

/// Bounded preview of a SQL script for the console editor.
///
/// Large files are never loaded in full: the console shows the first max_bytes
/// and offers to execute the file in streaming mode instead.
pub async fn sql_file_preview(path: String, max_bytes: Option<u64>) -> anyhow::Result<Value> {
    let info = importer::file_info(&path)?;
    let limit = max_bytes.unwrap_or(256 * 1024).clamp(1, 8 * 1024 * 1024) as usize;
    let take = limit.min(info.size.max(1) as usize);
    let head = importer::read_prefix(&path, take)?;
    let (bom, encoding) = importer::detect_bom(&head);
    if encoding == "utf-16le" || encoding == "utf-16be" {
        return Err(span("文件是 UTF-16 编码，暂不支持；请另存为 UTF-8 后重试").into());
    }
    let body = &head[bom.min(head.len())..];
    let text = String::from_utf8(body.to_vec())
        .map_err(|_| span("文件不是有效的 UTF-8 文本（可能是 GBK/GB18030），请另存为 UTF-8 后重试"))?;
    Ok(json!({
        "path": path,
        "name": info.name,
        "size": info.size,
        "encoding": encoding,
        "text": text,
        "truncated": (info.size as usize) > body.len(),
    }))
}

/// Execute a SQL file statement by statement, streaming from disk.
///
/// This is what the SQL console and the SQL import tab use for large dumps: the
/// file never crosses the FFI bridge as one big String and never sits in memory
/// whole. Returns a job id.
pub async fn sql_file_execute_start(
    database: String,
    path: String,
    options: Value,
) -> anyhow::Result<Value> {
    let state = state()?;
    let total = total_bytes(&path)?;
    let conn = state.connection_for(Some(&database)).await?;
    let skip_errors = options
        .get("on_error")
        .and_then(|v| v.as_str())
        .map(|v| v == "skip")
        .unwrap_or(false);
    let max_issues = options
        .get("max_issues")
        .and_then(|v| v.as_u64())
        .map(|v| v as usize)
        .unwrap_or(importer::DEFAULT_MAX_ISSUES)
        .clamp(1, 1_000);
    let job = Job::new("sql_file");
    let job_id = register(job.clone());
    let job_progress = job.clone();
    let job_cancel = job.clone();
    let job_finish = job.clone();
    // Needed inside the task to validate and apply USE statements through the
    // same visibility check as the database picker.
    let state_handle = state.clone();
    let mut current_database = database;
    tokio::spawn(async move {
        let mut reader = match importer::SqlScriptReader::open(&path) {
            Ok(reader) => reader,
            Err(e) => {
                job_finish.fail(e.to_string());
                return;
            }
        };
        let mut conn = conn;
        let mut statements = 0u64;
        let mut last_use: Option<String> = None;
        let mut succeeded = 0u64;
        let mut failed = 0u64;
        let mut issues: Vec<Value> = Vec::new();
        let mut cancelled = false;
        let mut stopped = false;
        let mut stop_message = String::new();
        let started = Instant::now();
        loop {
            if job_cancel.cancel.load(Ordering::Relaxed) {
                cancelled = true;
                break;
            }
            let item = match reader.next_statement() {
                Ok(Some(item)) => item,
                Ok(None) => break,
                Err(e) => {
                    stop_message = e.to_string();
                    stopped = true;
                    break;
                }
            };
            let statement = match item {
                importer::ScriptItem::Statement(statement) => statement,
                importer::ScriptItem::Problem(problem) => {
                    failed += 1;
                    if issues.len() < max_issues {
                        issues.push(json!({
                            "statement": "",
                            "line": problem.line,
                            "offset": problem.offset,
                            "error": problem.message,
                        }));
                    }
                    if problem.fatal {
                        stop_message = problem.message;
                        stopped = true;
                        break;
                    }
                    continue;
                }
            };
            // USE is applied as a validated database switch, never forwarded to
            // the server: raw USE would change a pooled session and could
            // outlive the only_db / hide_db check.
            if let Some(target) = super::use_statement_target(&statement.sql) {
                match super::switch_database_for_use(&state_handle, &target).await {
                    Ok(()) => match state_handle.connection_for(Some(&target)).await {
                        Ok(updated) => {
                            conn = updated;
                            current_database = target.clone();
                            last_use = Some(target.clone());
                            statements += 1;
                            succeeded += 1;
                            let bytes = reader.bytes_read().min(total);
                            job_progress.set_progress(&Progress {
                                phase: "executing".to_string(),
                                bytes,
                                total_bytes: total,
                                records: statements,
                                rows: succeeded,
                                failed,
                                percent: if total > 0 {
                                    (bytes as f64 / total as f64 * 100.0).clamp(0.0, 100.0)
                                } else {
                                    0.0
                                },
                                elapsed_ms: started.elapsed().as_millis() as u64,
                                message: String::new(),
                            });
                            continue;
                        }
                        Err(e) => {
                            failed += 1;
                            if issues.len() < max_issues {
                                issues.push(json!({
                                    "statement": statement.sql,
                                    "line": statement.line,
                                    "offset": statement.offset,
                                    "error": e.to_string(),
                                }));
                            }
                            stop_message = e.to_string();
                            stopped = true;
                            break;
                        }
                    },
                    Err(e) => {
                        failed += 1;
                        if issues.len() < max_issues {
                            issues.push(json!({
                                "statement": statement.sql,
                                "line": statement.line,
                                "offset": statement.offset,
                                "error": e.to_string(),
                            }));
                        }
                        stop_message = e.to_string();
                        stopped = true;
                        break;
                    }
                }
            }
            statements += 1;
            let result = conn.run_one(statement.sql.clone()).await;
            if let Some(error) = result.error {
                failed += 1;
                if issues.len() < max_issues {
                    issues.push(json!({
                        "statement": importer::snippet(&statement.sql, 200),
                        "line": statement.line,
                        "offset": statement.offset,
                        "error": error,
                    }));
                }
                if !skip_errors {
                    stop_message = error;
                    stopped = true;
                    break;
                }
            } else {
                succeeded += 1;
            }
            let bytes = reader.bytes_read().min(total);
            job_progress.set_progress(&Progress {
                phase: "executing".to_string(),
                bytes,
                total_bytes: total,
                records: statements,
                rows: succeeded,
                failed,
                percent: if total > 0 {
                    (bytes as f64 / total as f64 * 100.0).clamp(0.0, 100.0)
                } else {
                    0.0
                },
                elapsed_ms: started.elapsed().as_millis() as u64,
                message: String::new(),
            });
        }
        let value = json!({
            "ok": failed == 0 && !stopped && !cancelled,
            "cancelled": cancelled,
            "stopped": stopped,
            "message": stop_message,
            "statements": statements,
            "succeeded": succeeded,
            "failed": failed,
            "issues": issues,
            "bytes": reader.bytes_read().min(total),
            "total_bytes": total,
            "elapsed_ms": started.elapsed().as_millis() as u64,
            // The database/schema this file ran against, plus the last explicit
            // USE switch (the UI shows it as the effective session prelude).
            "database": current_database,
            "use_database": last_use,
        });
        job_finish.finish(cancelled, value);
    });
    Ok(json!({ "job_id": job_id }))
}
