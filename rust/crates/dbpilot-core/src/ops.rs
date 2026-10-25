//! 门面里「与具体驱动无关」的通用操作（P5）。
//!
//! 这些逻辑原本长在 drivers::Db 门面上，用 match self.driver 分派。P5 把它们
//! 抽成自由函数，参数是 &dyn DatabaseDriver + &ConnectionHandle：
//! * DatabaseDriver 的默认方法只需要一行转调，core 不用知道任何 SQL 细节；
//! * Db 门面保留同名方法做兼容（也转调这里），实现只有一份；
//! * api 直接用驱动 trait，不再接触门面。
//!
//! 分派原则：方言/DDL 文本用 driver.dialect() 或各驱动的纯函数；
//! 执行一律走 conn.execute / conn.run_one。

use serde_json::{json, Map, Value};

use crate::config::DriverKind;
use crate::connection::ConnectionHandle;
use crate::db::{split_statements, strip_leading_comments, ResultSet};
use crate::driver::DatabaseDriver;
use crate::error::{AppError, AppResult};
use crate::paging::{page_plan, DataPage};
use crate::spec::{fk_parts, AlterTableSpec, CreateTableSpec};
use crate::session::SessionHandle;
use crate::sql::{create_database_sql, safe_type};

fn scalar_i64(rs: &ResultSet) -> i64 {
    rs.rows
        .first()
        .and_then(|r| r.first())
        .and_then(|v| {
            v.as_i64()
                .or_else(|| v.as_u64().map(|u| u as i64))
                .or_else(|| v.as_str().and_then(|s| s.parse::<i64>().ok()))
        })
        .unwrap_or(0)
}

// ------------------------------------------------------------------ DDL 文本

/// CREATE DATABASE / CREATE SCHEMA 预览语句。
pub(crate) fn create_database_statement<D: DatabaseDriver + ?Sized>(
    driver: &D,
    name: &str,
    charset: Option<&str>,
    collation: Option<&str>,
    template: Option<&str>,
    encoding: Option<&str>,
    owner: Option<&str>,
    tablespace: Option<&str>,
) -> AppResult<String> {
    let kind = driver.kind();
    if kind == DriverKind::Sqlite {
        return Err(AppError::bad(
            "SQLite has no CREATE DATABASE; create the file instead",
        ));
    }
    create_database_sql(kind, name, charset, collation, template, encoding, owner, tablespace)
}

/// CREATE SCHEMA（仅 PostgreSQL 有独立 schema 概念）。
pub(crate) fn create_schema_statement<D: DatabaseDriver + ?Sized>(
    driver: &D,
    name: &str,
) -> AppResult<String> {
    if driver.supports(crate::dialect::DialectCapability::CreateSchema) {
        Ok(format!(
            "CREATE SCHEMA IF NOT EXISTS {}",
            driver.dialect().quote_ident(name)
        ))
    } else if driver.kind() == DriverKind::Mysql {
        Err(AppError::bad("MySQL 的 schema 就是数据库；请新建数据库"))
    } else {
        Err(AppError::bad("SQLite 不支持 CREATE SCHEMA"))
    }
}

/// DROP DATABASE（MySQL / PostgreSQL；SQLite 的库是文件）。
pub(crate) fn drop_namespace_sql<D: DatabaseDriver + ?Sized>(driver: &D, name: &str) -> AppResult<String> {
    if driver.is_file_based() {
        return Err(AppError::bad("SQLite has no DROP DATABASE"));
    }
    Ok(format!(
        "DROP DATABASE {}",
        driver.dialect().quote_ident(name)
    ))
}

/// DROP SCHEMA ... CASCADE（仅 PostgreSQL）。
pub(crate) fn drop_schema_sql<D: DatabaseDriver + ?Sized>(driver: &D, name: &str) -> AppResult<String> {
    if driver.supports(crate::dialect::DialectCapability::CreateSchema) {
        Ok(format!(
            "DROP SCHEMA {} CASCADE",
            driver.dialect().quote_ident(name)
        ))
    } else if driver.kind() == DriverKind::Mysql {
        Err(AppError::bad("MySQL 的 schema 就是数据库；请删除数据库"))
    } else {
        Err(AppError::bad("SQLite 不支持 DROP SCHEMA"))
    }
}

// ------------------------------------------------------------- CREATE TABLE

/// 建表所需的全部语句（PostgreSQL 的注释要单独发）。
pub(crate) fn create_table_statements<D: DatabaseDriver + ?Sized>(
    driver: &D,
    ns: &str,
    spec: &CreateTableSpec,
) -> AppResult<Vec<String>> {
    if spec.columns.is_empty() {
        return Err(AppError::bad("at least one column is required"));
    }
    for c in &spec.columns {
        if c.name.trim().is_empty() {
            return Err(AppError::bad("column name is required"));
        }
        if !safe_type(&c.col_type) {
            return Err(AppError::bad(format!(
                "unsupported column type '{}'",
                c.col_type
            )));
        }
    }
    for fk in &spec.foreign_keys {
        fk_parts(fk)?;
    }
    let dialect = driver.dialect();
    // 33 轮拆 crate：建表 DDL 通过方言 trait 回到驱动实现，
    // core 不再调用 drivers::mysql/postgres/sqlite 的具体函数。
    let mut out = vec![dialect.create_table_sql(ns, spec)?];
    if driver.kind() == DriverKind::Postgres {
        if let Some(comment) = spec.comment.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            out.push(format!(
                "COMMENT ON TABLE {} IS {}",
                dialect.qualify(ns, &spec.name),
                dialect.quote_string(comment)
            ));
        }
        // PostgreSQL 没有行内列注释语法：设计器的每列备注要单独发 COMMENT ON COLUMN。
        for column in &spec.columns {
            if let Some(comment) = column
                .comment
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                out.push(format!(
                    "COMMENT ON COLUMN {}.{} IS {}",
                    dialect.qualify(ns, &spec.name),
                    dialect.quote_ident(column.name.trim()),
                    dialect.quote_string(comment)
                ));
            }
        }
    }
    Ok(out)
}

/// ALTER TABLE 批次（设计器）。
pub(crate) fn alter_table_statements<D: DatabaseDriver + ?Sized>(
    driver: &D,
    ns: &str,
    table: &str,
    spec: &AlterTableSpec,
) -> AppResult<Vec<String>> {
    if spec.is_empty() {
        return Err(AppError::bad("没有需要应用的修改"));
    }
    for c in spec.add_columns.iter().chain(spec.modify_columns.iter()) {
        if c.name.trim().is_empty() {
            return Err(AppError::bad("字段名不能为空"));
        }
        if !c.col_type.is_empty() && !safe_type(&c.col_type) {
            return Err(AppError::bad(format!("不支持的字段类型 '{}'", c.col_type)));
        }
    }
    // 同上：ALTER 批次语句由方言提供（PostgreSQL 的注释语句仍在这里组装）。
    driver.dialect().alter_table_statements(ns, table, spec)
}

// ------------------------------------------------------------------- 执行类

pub(crate) async fn create_table<D: DatabaseDriver + ?Sized>(
    driver: &D,
    conn: &ConnectionHandle,
    ns: &str,
    spec: &CreateTableSpec,
) -> AppResult<()> {
    for sql in create_table_statements(driver, ns, spec)? {
        conn.exec(&sql).await?;
    }
    Ok(())
}

pub(crate) async fn create_schema<D: DatabaseDriver + ?Sized>(
    driver: &D,
    conn: &ConnectionHandle,
    name: &str,
) -> AppResult<()> {
    let sql = create_schema_statement(driver, name)?;
    conn.exec(&sql).await
}

pub(crate) async fn drop_schema<D: DatabaseDriver + ?Sized>(
    driver: &D,
    conn: &ConnectionHandle,
    name: &str,
) -> AppResult<()> {
    let sql = drop_schema_sql(driver, name)?;
    conn.exec(&sql).await
}

pub(crate) async fn drop_namespace<D: DatabaseDriver + ?Sized>(
    driver: &D,
    conn: &ConnectionHandle,
    name: &str,
) -> AppResult<()> {
    let sql = drop_namespace_sql(driver, name)?;
    conn.exec(&sql).await
}

/// DROP TABLE / DROP VIEW（先确认对象类型）。
pub(crate) async fn drop_table<D: DatabaseDriver + ?Sized>(
    driver: &D,
    conn: &ConnectionHandle,
    ns: &str,
    table: &str,
) -> AppResult<()> {
    let kind = driver
        .object_kind(conn, ns, table)
        .await?
        .ok_or_else(|| AppError::not_found(format!("'{}' does not exist", table)))?;
    let keyword = if kind.eq_ignore_ascii_case("VIEW") {
        "VIEW"
    } else {
        "TABLE"
    };
    let sql = format!("DROP {} {}", keyword, driver.dialect().qualify(ns, table));
    conn.exec(&sql).await
}

/// TRUNCATE（SQLite 用 DELETE FROM）。
pub(crate) async fn truncate<D: DatabaseDriver + ?Sized>(
    driver: &D,
    conn: &ConnectionHandle,
    ns: &str,
    table: &str,
) -> AppResult<()> {
    let kind = driver
        .object_kind(conn, ns, table)
        .await?
        .ok_or_else(|| AppError::not_found(format!("'{}' does not exist", table)))?;
    if kind.eq_ignore_ascii_case("VIEW") {
        return Err(AppError::bad("cannot truncate a view"));
    }
    let target = driver.dialect().qualify(ns, table);
    let sql = if driver.is_file_based() {
        format!("DELETE FROM {}", target)
    } else {
        format!("TRUNCATE TABLE {}", target)
    };
    conn.exec(&sql).await
}

/// 执行对象 DROP（SQL 文本由驱动提供）。
pub(crate) async fn drop_object<D: DatabaseDriver + ?Sized>(
    driver: &D,
    conn: &ConnectionHandle,
    ns: &str,
    kind: &str,
    name: &str,
) -> AppResult<()> {
    let sql = driver.object_drop_sql(ns, kind, name)?;
    conn.exec(&sql).await
}

/// 整段脚本（不含行数上限；控制台用 SessionHandle 的 run_limited）。
pub(crate) async fn run_sql<D: DatabaseDriver + ?Sized>(
    _driver: &D,
    conn: &ConnectionHandle,
    sql: &str,
) -> Vec<ResultSet> {
    let mut out = Vec::new();
    for stmt in split_statements(sql) {
        out.push(conn.run_one(stmt).await);
    }
    out
}


// ------------------------------------------------------------ backup restore

/// Largest number of DML statements wrapped into one restore transaction.
const RESTORE_BATCH_STATEMENTS: usize = 500;
/// Largest amount of DML SQL text wrapped into one restore transaction.
///
/// A dump INSERT is normally one 500-row statement, so 16 MB groups dozens of
/// them; the point is fewer commits (and therefore fewer fsyncs), not fewer
/// round trips. Keep the group well below the server's undo-log / packet
/// comfort zone.
const RESTORE_BATCH_BYTES: usize = 16 * 1024 * 1024;
/// Row cap used when a restore statement unexpectedly returns rows.
///
/// A dump never does, but `run_limited` needs a limit; this keeps a hand-edited
/// dump from materialising an unbounded result set.
const RESTORE_MAX_ROWS: usize = 1_000_000;

/// Largest dump that still runs as one transaction.
///
/// PostgreSQL must keep WAL/undo for the whole dump and holds locks until
/// COMMIT, so restoring a multi-GB dump in one transaction is the classic
/// "restore fills the disk / blocks everyone" failure. Above this size the
/// backup path automatically falls back to the grouped (commit per run) restore
/// — see [restore_atomic_eligible].
pub const RESTORE_ATOMIC_MAX_BYTES: usize = 256 * 1024 * 1024;

/// Strip leading whitespace and SQL comments so the keyword scan sees the real
/// statement start.
///
/// Only the prefix is removed: words inside the statement body (string literals
/// included) are never considered, so INSERT ... VALUES ('VACUUM') cannot look
/// like a VACUUM statement.
fn strip_leading_sql_noise(mut statement: &str) -> &str {
    loop {
        let trimmed = statement.trim_start();
        if let Some(rest) = trimmed.strip_prefix("--") {
            match rest.find('\n') {
                Some(index) => statement = &rest[index + 1..],
                None => return "",
            }
        } else if let Some(rest) = trimmed.strip_prefix("/*") {
            match rest.find("*/") {
                Some(index) => statement = &rest[index + 2..],
                None => return "",
            }
        } else {
            return trimmed;
        }
    }
}

/// Uppercase head words of one statement (comments stripped).
///
/// Only the first few words are examined, which is enough for the multi-word
/// forms below and keeps a word inside a long string literal from matching.
/// The scan stops at an inline comment marker, so a trailing
/// "ALTER TABLE t DETACH PARTITION p -- CONCURRENTLY" comment cannot turn the
/// statement into a blocker.
fn statement_head_words(statement: &str, max_words: usize) -> Vec<String> {
    let mut words: Vec<String> = Vec::new();
    for word in strip_leading_sql_noise(statement).split_whitespace() {
        if word.starts_with("--") || word.starts_with("/*") {
            break;
        }
        let cleaned = word
            .trim_matches(|c: char| !c.is_alphanumeric() && c != '_')
            .to_ascii_uppercase();
        if !cleaned.is_empty() {
            words.push(cleaned);
        }
        if words.len() >= max_words {
            break;
        }
    }
    words
}

/// One statement form that cannot run inside a transaction, or None.
///
/// The list is deliberately prefix-based: VACUUM / CREATE DATABASE / ... are
/// matched from the first word(s), and the CONCURRENTLY forms additionally
/// require the statement kind (so COMMENT ON INDEX ... IS 'concurrently' is not
/// mistaken for CREATE INDEX CONCURRENTLY).
fn statement_atomic_blocker(statement: &str, driver_id: &str) -> Option<&'static str> {
    let words = statement_head_words(statement, 12);
    let first = words.first().map(String::as_str).unwrap_or("");
    let second = words.get(1).map(String::as_str).unwrap_or("");
    let has = |word: &str| words.iter().any(|candidate| candidate == word);
    match driver_id {
        "postgres" => {
            if first == "VACUUM" {
                return Some("VACUUM");
            }
            if first == "CREATE" && second == "DATABASE" {
                return Some("CREATE DATABASE");
            }
            if first == "DROP" && second == "DATABASE" {
                return Some("DROP DATABASE");
            }
            if first == "ALTER" && second == "SYSTEM" {
                return Some("ALTER SYSTEM");
            }
            if first == "CREATE" && second == "TABLESPACE" {
                return Some("CREATE TABLESPACE");
            }
            if first == "DROP" && second == "TABLESPACE" {
                return Some("DROP TABLESPACE");
            }
            // CREATE [UNIQUE] INDEX ... CONCURRENTLY (with or without IF NOT EXISTS).
            let creates_index = first == "CREATE"
                && (second == "INDEX"
                    || (second == "UNIQUE"
                        && words.get(2).map(String::as_str) == Some("INDEX")));
            if creates_index && has("CONCURRENTLY") {
                return Some("CREATE INDEX CONCURRENTLY");
            }
            if first == "DROP" && second == "INDEX" && has("CONCURRENTLY") {
                return Some("DROP INDEX CONCURRENTLY");
            }
            if first == "REINDEX" && has("CONCURRENTLY") {
                return Some("REINDEX CONCURRENTLY");
            }
            if first == "REFRESH" && second == "MATERIALIZED" && has("CONCURRENTLY") {
                return Some("REFRESH MATERIALIZED VIEW CONCURRENTLY");
            }
            // ALTER TABLE ... DETACH PARTITION ... CONCURRENTLY (the plain
            // non-concurrent form is transactional and must not be blocked).
            if first == "ALTER"
                && second == "TABLE"
                && has("DETACH")
                && has("PARTITION")
                && has("CONCURRENTLY")
            {
                return Some("ALTER TABLE DETACH PARTITION CONCURRENTLY");
            }
            None
        }
        "sqlite" => {
            if first == "VACUUM" {
                return Some("VACUUM");
            }
            if first == "ATTACH" {
                return Some("ATTACH");
            }
            if first == "DETACH" {
                return Some("DETACH");
            }
            None
        }
        _ => None,
    }
}

/// Unique blocker labels for already-split dump statements, in first-seen order.
pub fn restore_atomic_blockers(statements: &[String], driver_id: &str) -> Vec<String> {
    let mut blockers: Vec<String> = Vec::new();
    for statement in statements {
        if let Some(label) = statement_atomic_blocker(statement, driver_id) {
            if !blockers.iter().any(|existing| existing == label) {
                blockers.push(label.to_string());
            }
        }
    }
    blockers
}

/// Human-readable MiB value: "256 MiB" for whole numbers, "320.5 MiB" otherwise.
fn format_mib(bytes: usize) -> String {
    const MIB: f64 = 1024.0 * 1024.0;
    let mib = bytes as f64 / MIB;
    if (mib - mib.round()).abs() < 0.05 {
        format!("{:.0} MiB", mib)
    } else {
        format!("{:.1} MiB", mib)
    }
}

/// Why this dump cannot be restored atomically; None when it can.
fn atomic_ineligible_reason(
    driver_id: &str,
    statements: &[String],
    bytes: usize,
) -> Option<String> {
    if driver_id == "mysql" {
        return Some(
            "MySQL 的 DDL 会隐式提交，无法整段原子还原（改为分组提交，失败时可能留下部分数据）"
                .to_string(),
        );
    }
    let blockers = restore_atomic_blockers(statements, driver_id);
    if !blockers.is_empty() {
        let label = if driver_id == "postgres" {
            "PostgreSQL"
        } else {
            "SQLite"
        };
        return Some(format!(
            "还原脚本包含 {label} 不能在事务中执行的语句：{}（改为分组提交，失败时无法整体回滚）",
            blockers.join("、")
        ));
    }
    if bytes > RESTORE_ATOMIC_MAX_BYTES {
        return Some(format!(
            "备份约 {}，超过 {} 自动改用分组提交，失败时可能留下部分数据",
            format_mib(bytes),
            format_mib(RESTORE_ATOMIC_MAX_BYTES)
        ));
    }
    None
}

/// Whether a whole dump can be restored in one transaction.
///
/// Returns the Chinese reason when it cannot: the dump contains a statement a
/// transaction rejects (PostgreSQL VACUUM / CREATE INDEX CONCURRENTLY / ...,
/// SQLite VACUUM / ATTACH / DETACH), it is larger than
/// [RESTORE_ATOMIC_MAX_BYTES], or the driver is MySQL (DDL implicitly commits).
/// The backup API shows the reason and falls back to [restore_sql] (grouped
/// commits, partial data possible on failure).
pub fn restore_atomic_eligible(driver_id: &str, sql: &str, bytes: usize) -> Result<(), String> {
    match atomic_ineligible_reason(driver_id, &split_statements(sql), bytes) {
        Some(reason) => Err(reason),
        None => Ok(()),
    }
}

/// Outcome of [restore_sql] / [restore_sql_atomic].
pub struct RestoreReport {
    /// One entry per executed dump statement, in dump order (same shape as
    /// [run_sql]). An atomic restore that fails early stops at the failing
    /// statement, so this may hold fewer entries than total_statements; a
    /// failed COMMIT appends one synthetic entry whose statement is COMMIT.
    pub results: Vec<ResultSet>,
    /// DML batches that finished with a COMMIT (diagnostics). The atomic path
    /// reports 1 on success (the whole dump is one transaction) and 0 otherwise.
    pub transaction_batches: u64,
    /// Statements committed inside those batches (diagnostics).
    pub statements_in_transactions: u64,
    /// Round trips sent to the server (diagnostics).
    pub round_trips: u64,
    /// True when the whole dump ran inside one transaction ([restore_sql_atomic]).
    /// False for the grouped path (MySQL, or an atomic-restore fallback).
    pub atomic: bool,
    /// True when the atomic transaction was rolled back (statement or COMMIT
    /// failed). Always false on the grouped path.
    pub rolled_back: bool,
    /// Number of statements in the dump after splitting (before execution).
    pub total_statements: usize,
}

impl RestoreReport {
    pub fn statements(&self) -> usize {
        self.results.len()
    }

    pub fn failed(&self) -> usize {
        self.results.iter().filter(|r| r.error.is_some()).count()
    }

    /// Statements that were never executed because an atomic restore stopped at
    /// the first failure. Always 0 on the grouped path (every statement runs).
    pub fn skipped_statements(&self) -> usize {
        self.total_statements.saturating_sub(self.results.len())
    }
}

#[derive(Debug, PartialEq)]
enum RestoreGroup {
    /// A statement that must run alone (DDL, session directive, ...).
    Single(usize),
    /// A run of DML statements that can share one transaction.
    Batch { start: usize, end: usize },
}

/// True when a dump statement is DML and can share one transaction.
///
/// Everything else (DDL, `SET`, `USE`, `LOCK TABLES`, ...) is a barrier:
///
/// * MySQL implicitly commits the active transaction on DDL, and a
///   `LOCK TABLES` would be released by a commit, so grouping them is wrong;
/// * PostgreSQL / SQLite have transactional DDL, but keeping DDL outside the
///   batching means a failed DML batch can be rolled back and replayed without
///   touching schema changes, and the old per-statement semantics for those
///   statements stay exactly the same.
fn is_transactional_restore_statement(statement: &str) -> bool {
    let first = strip_leading_comments(statement)
        .split_whitespace()
        .next()
        .unwrap_or("");
    matches!(
        first.to_ascii_uppercase().as_str(),
        "INSERT" | "REPLACE" | "UPDATE" | "DELETE"
    )
}

/// Partition the dump into executable units, preserving statement order.
fn restore_groups(statements: &[String]) -> Vec<RestoreGroup> {
    let mut groups = Vec::new();
    let mut index = 0;
    while index < statements.len() {
        if !is_transactional_restore_statement(&statements[index]) {
            groups.push(RestoreGroup::Single(index));
            index += 1;
            continue;
        }
        let start = index;
        let mut bytes = 0usize;
        while index < statements.len()
            && is_transactional_restore_statement(&statements[index])
            && index - start < RESTORE_BATCH_STATEMENTS
            && (index == start || bytes + statements[index].len() <= RESTORE_BATCH_BYTES)
        {
            bytes += statements[index].len();
            index += 1;
        }
        groups.push(RestoreGroup::Batch { start, end: index });
    }
    groups
}

/// Transaction-control SQL for one driver.
struct RestoreTx {
    begin: &'static str,
    commit: &'static str,
    rollback: &'static str,
    /// Restores the pre-restore autocommit mode (see [restore_tx_for]).
    reset: Option<&'static str>,
}

/// Transaction control has to match what the server's **prepared** protocol
/// accepts, because the pinned session executes everything through
/// `run_limited`:
///
/// * MySQL rejects `START TRANSACTION` / `BEGIN` in the prepared protocol
///   (error 1295), so a batch starts with `SET autocommit = 0` and ends with
///   `COMMIT`; autocommit is switched back so the barrier statements that
///   follow keep the old behaviour. DDL still implicitly commits (documented
///   in the restore report): a MySQL dump is never atomic as a whole.
/// * PostgreSQL and SQLite accept `BEGIN` / `COMMIT` / `ROLLBACK` in their
///   extended protocols, and their DDL is transactional, but the dump keeps DDL
///   outside the batching anyway (see [is_transactional_restore_statement]).
fn restore_tx_for(driver_id: &str) -> RestoreTx {
    if driver_id == "mysql" {
        RestoreTx {
            begin: "SET autocommit = 0",
            commit: "COMMIT",
            rollback: "ROLLBACK",
            reset: Some("SET autocommit = 1"),
        }
    } else {
        RestoreTx {
            begin: "BEGIN",
            commit: "COMMIT",
            rollback: "ROLLBACK",
            reset: None,
        }
    }
}

fn restore_ok_result(statement: &str) -> ResultSet {
    ResultSet {
        columns: Vec::new(),
        rows: Vec::new(),
        row_count: 0,
        last_insert_id: 0,
        statement: statement.to_string(),
        kind: "affected".to_string(),
        error: None,
        truncated: false,
    }
}

/// Execute one statement on the pinned session and count the round trip.
async fn run_restore_statement(
    session: &mut (dyn SessionHandle + Send),
    statement: &str,
    report: &mut RestoreReport,
) -> ResultSet {
    report.round_trips += 1;
    session
        .run_limited(statement.to_string(), RESTORE_MAX_ROWS)
        .await
}

/// Run a whole batch one statement at a time in autocommit mode.
///
/// Used when transaction control itself is unavailable (the driver refused
/// `BEGIN` / `SET autocommit = 0`) and to replay a rolled-back prefix.
async fn run_restore_autocommit(
    session: &mut (dyn SessionHandle + Send),
    statements: &[String],
    start: usize,
    end: usize,
    report: &mut RestoreReport,
) {
    for index in start..end {
        let result = run_restore_statement(session, &statements[index], report).await;
        report.results.push(result);
    }
}

/// Run one DML run inside a transaction.
///
/// Happy path: one BEGIN, N statements, one COMMIT, so N autocommits become a
/// single fsync. Error path keeps the old per-statement outcome exactly: the
/// transaction is rolled back, its successful prefix is replayed in autocommit
/// mode (so those statements stay applied, as they did before the optimisation),
/// the failing statement is recorded, and the remaining statements run in
/// autocommit mode so later failures are still reported individually.
async fn run_restore_batch(
    session: &mut (dyn SessionHandle + Send),
    statements: &[String],
    start: usize,
    end: usize,
    report: &mut RestoreReport,
) {
    let tx = restore_tx_for(session.driver_id());
    let begin = run_restore_statement(session, tx.begin, report).await;
    if begin.error.is_some() {
        // No usable transaction control: keep the old behaviour instead of
        // failing the restore.
        run_restore_autocommit(session, statements, start, end, report).await;
        return;
    }
    let mut failed_at: Option<(usize, String)> = None;
    for index in start..end {
        let result = run_restore_statement(session, &statements[index], report).await;
        if let Some(error) = result.error {
            failed_at = Some((index, error));
            break;
        }
    }
    match failed_at {
        None => {
            let commit = run_restore_statement(session, tx.commit, report).await;
            if commit.error.is_none() {
                for index in start..end {
                    report
                        .results
                        .push(restore_ok_result(&statements[index]));
                }
                report.transaction_batches += 1;
                report.statements_in_transactions += (end - start) as u64;
                if let Some(reset) = tx.reset {
                    let _ = run_restore_statement(session, reset, report).await;
                }
            } else {
                // COMMIT itself failed: undo, then replay one by one so every
                // statement is still attempted exactly like the old path.
                let _ = run_restore_statement(session, tx.rollback, report).await;
                if let Some(reset) = tx.reset {
                    let _ = run_restore_statement(session, reset, report).await;
                }
                run_restore_autocommit(session, statements, start, end, report).await;
            }
        }
        Some((index, error)) => {
            let _ = run_restore_statement(session, tx.rollback, report).await;
            if let Some(reset) = tx.reset {
                let _ = run_restore_statement(session, reset, report).await;
            }
            // The rollback undid the successful prefix; replay it in
            // autocommit mode (the old path had applied it immediately).
            for replay in start..index {
                let result =
                    run_restore_statement(session, &statements[replay], report).await;
                report.results.push(result);
            }
            let mut failed = restore_ok_result(&statements[index]);
            failed.kind = "error".to_string();
            failed.error = Some(error);
            report.results.push(failed);
            run_restore_autocommit(session, statements, index + 1, end, report).await;
        }
    }
}

/// Execute a backup dump through one pinned session, in commit-saving groups.
///
/// This is the **non-atomic** path. It replaces the old driver.run_sql loop
/// (one prepared statement per call, autocommit):
///
/// * consecutive DML statements share one transaction, so a 500k-row dump pays
///   a handful of commits instead of one per INSERT — that is the dominant
///   restore cost on InnoDB;
/// * statements are executed on the **same pinned connection**, so session
///   state written by one dump statement (USE, SET FOREIGN_KEY_CHECKS,
///   SET search_path) still applies to the next one;
/// * failure reporting is unchanged: [RestoreReport::results] still has one
///   entry per dump statement, and a failed batch is rolled back and replayed
///   so every other statement is attempted exactly once.
///
/// MySQL must use this path: its DDL implicitly commits, so a whole-dump
/// transaction is impossible. PostgreSQL / SQLite should use
/// [restore_sql_atomic] instead; this function is also its fallback when the
/// driver refuses BEGIN.
pub async fn restore_sql(
    session: &mut (dyn SessionHandle + Send),
    sql: &str,
) -> RestoreReport {
    let statements = split_statements(sql);
    let mut report = RestoreReport {
        results: Vec::with_capacity(statements.len()),
        transaction_batches: 0,
        statements_in_transactions: 0,
        round_trips: 0,
        atomic: false,
        rolled_back: false,
        total_statements: statements.len(),
    };
    for group in restore_groups(&statements) {
        match group {
            RestoreGroup::Single(index) => {
                let result =
                    run_restore_statement(session, &statements[index], &mut report).await;
                report.results.push(result);
            }
            RestoreGroup::Batch { start, end } if end - start == 1 => {
                let result =
                    run_restore_statement(session, &statements[start], &mut report).await;
                report.results.push(result);
            }
            RestoreGroup::Batch { start, end } => {
                run_restore_batch(session, &statements, start, end, &mut report).await;
            }
        }
    }
    report
}

/// Execute a whole backup dump as one transaction (PostgreSQL / SQLite).
///
/// Both drivers have transactional DDL, so a dump can be all-or-nothing:
///
/// * success: BEGIN -> every statement -> COMMIT. transaction_batches = 1 and
///   statements_in_transactions = total_statements (one commit for the dump).
/// * failure: BEGIN -> statements until the first failure -> ROLLBACK and stop.
///   results holds the statements that were executed (the failing one last,
///   with its error), rolled_back = true, and the statements after the failure
///   never run (see RestoreReport::skipped_statements).
/// * a failed COMMIT appends one synthetic COMMIT error entry so failed()
///   counts it, rolls back best-effort and stops.
/// * if BEGIN itself is rejected (unusual proxy / driver), the old grouped path
///   runs instead and the report says atomic = false, so a dump that used to
///   restore does not start failing outright;
/// * if the dump contains a statement a transaction rejects (VACUUM,
///   CREATE INDEX CONCURRENTLY, ...) or is larger than
///   [RESTORE_ATOMIC_MAX_BYTES], the same grouped fallback is used (call
///   [restore_atomic_eligible] first to get the user-facing reason).
///
/// MySQL must keep using [restore_sql]: its DDL implicitly commits, so a
/// whole-dump transaction is impossible there. A MySQL session handed to this
/// function is forwarded to [restore_sql] instead of pretending to be atomic.
pub async fn restore_sql_atomic(
    session: &mut (dyn SessionHandle + Send),
    sql: &str,
) -> RestoreReport {
    if session.driver_id() == "mysql" {
        return restore_sql(session, sql).await;
    }
    let statements = split_statements(sql);
    let total = statements.len();
    // Transaction-illegal statements or an oversized dump: fall back to the
    // grouped path so the restore still completes (the API reports why through
    // restore_atomic_eligible).
    if atomic_ineligible_reason(session.driver_id(), &statements, sql.len()).is_some() {
        return restore_sql(session, sql).await;
    }
    let tx = restore_tx_for(session.driver_id());
    let mut report = RestoreReport {
        results: Vec::with_capacity(total),
        transaction_batches: 0,
        statements_in_transactions: 0,
        round_trips: 0,
        atomic: true,
        rolled_back: false,
        total_statements: total,
    };
    let begin = run_restore_statement(session, tx.begin, &mut report).await;
    if begin.error.is_some() {
        // No usable transaction control: fall back to the grouped path so the
        // dump still restores (old behaviour) instead of failing outright.
        return restore_sql(session, sql).await;
    }
    for statement in &statements {
        let result = run_restore_statement(session, statement, &mut report).await;
        if result.error.is_some() {
            let _ = run_restore_statement(session, tx.rollback, &mut report).await;
            report.rolled_back = true;
            report.results.push(result);
            return report;
        }
        report.results.push(result);
    }
    let commit = run_restore_statement(session, tx.commit, &mut report).await;
    if let Some(error) = commit.error {
        let _ = run_restore_statement(session, tx.rollback, &mut report).await;
        report.rolled_back = true;
        let mut failed = restore_ok_result(tx.commit);
        failed.kind = "error".to_string();
        failed.error = Some(error);
        report.results.push(failed);
        return report;
    }
    report.transaction_batches = 1;
    report.statements_in_transactions = total as u64;
    report
}

// ------------------------------------------------------------- 数据浏览/编辑

pub(crate) async fn data<D: DatabaseDriver + ?Sized>(
    driver: &D,
    conn: &ConnectionHandle,
    ns: &str,
    table: &str,
    query: &DataPage<'_>,
) -> AppResult<Value> {
    let structure = driver.table_structure(conn, ns, table).await?;
    let columns = structure
        .get("columns")
        .and_then(|c| c.as_array())
        .cloned()
        .unwrap_or_default();
    let primary_key_json = structure
        .get("primary_key")
        .cloned()
        .unwrap_or_else(|| json!([]));

    let (page, per_page) = query.normalized();
    let dialect = driver.dialect();

    // 排序按真实列名校验：未知列在这里就报错，绝不把调用方的字符串拼进 SQL。
    let mut sorts: Vec<(String, String)> = Vec::new();
    for (column, direction) in query.sorts {
        let column = column.trim();
        if column.is_empty() {
            continue;
        }
        let known = columns
            .iter()
            .any(|c| c.get("name").and_then(|v| v.as_str()) == Some(column));
        if !known {
            return Err(AppError::bad(format!("unknown column '{}'", column)));
        }
        sorts.push((column.to_string(), direction.to_string()));
    }
    let primary_key: Vec<String> = primary_key_json
        .as_array()
        .map(|names| {
            names
                .iter()
                .filter_map(|name| name.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();

    // 过滤文本永不直接拼接：按真实列名重新解析，只放行简单比较。
    let safe_filter = match query.filter.map(str::trim).filter(|s| !s.is_empty()) {
        Some(filter) => {
            let column_names: Vec<String> = columns
                .iter()
                .filter_map(|c| c.get("name").and_then(|v| v.as_str()).map(|s| s.to_string()))
                .collect();
            Some(crate::filter::parse_filter(filter, &column_names, driver.kind())?)
        }
        None => None,
    };

    // 游标只接受标量：对象/数组无法安全地变成 SQL 字面量比较。
    if let Some(after) = query.after {
        if !after.is_string() && !after.is_number() && !after.is_boolean() {
            return Err(AppError::bad("after 游标必须是字符串或数字"));
        }
    }

    let target = dialect.qualify(ns, table);
    let plan = page_plan(
        dialect,
        &target,
        &primary_key,
        &sorts,
        safe_filter.as_deref(),
        per_page,
        query.offset(),
        query.after,
        query.count,
        query.deferred,
    );

    // count=false 时跳过整表计数（宽表上 COUNT(*) 往往比取一页还贵）。
    let total = match plan.count_sql {
        Some(sql) => {
            let count = conn.run_one(sql).await;
            if let Some(err) = count.error {
                return Err(AppError::bad(err));
            }
            Some(scalar_i64(&count))
        }
        None => None,
    };

    let result = conn.run_one(plan.sql.clone()).await;
    if let Some(err) = result.error {
        return Err(AppError::bad(err));
    }

    let pages = total.map(|total| {
        if total <= 0 {
            1
        } else {
            ((total as u64) + per_page - 1) / per_page
        }
    });
    // 游标只在本页「装满」时给出：最后一页不满 per_page 说明后面没有行了，
    // 再返回一个游标会让 UI 多翻一页空白。这个判据对 keyset 与 OFFSET 都成立
    // （keyset 下本页同样从游标起连续取 per_page 行）。
    let next_cursor = if (result.rows.len() as u64) < per_page {
        None
    } else {
        plan.cursor_column
            .as_deref()
            .and_then(|column| crate::paging::next_cursor(&result.columns, &result.rows, column))
    };
    // `used_keyset` 的含义是「本次查询的游标分页生效」而不是「这一页真的收到了
    // after」：第一页没有游标，但客户端要据此决定能否把 next_cursor 接成链条
    // （table_view 在 used_keyset=false 时会退回 OFFSET 并丢弃游标栈）。
    let keyset_in_effect = plan.cursor_column.is_some();
    Ok(json!({
        "database": ns,
        "table": table,
        "columns": result.columns,
        "rows": result.rows,
        // count=false 时 total / pages 为 null（字段仍然存在，Dart 契约不变）。
        "total": total,
        "page": page,
        "per_page": per_page,
        "pages": pages,
        "primary_key": primary_key_json,
        "next_cursor": next_cursor,
        // 游标分页是否生效（形态允许 keyset）；第一页即 true，便于 UI 接链条。
        "used_keyset": keyset_in_effect,
        // 这一页是否真的用 after 代替了 OFFSET（第一页没有游标，故为 false）。
        "used_cursor": plan.used_keyset,
        "used_deferred": plan.used_deferred,
        // 实际执行的 SQL，便于测试与排查执行计划。
        "sql": plan.sql,
    }))
}

/// Build — but do not execute — the SQL for one row-level change.
///
/// Shared by [change_row] and the batched apply path
/// (`DatabaseDriver::change_row_sql` -> `api::explorer::apply_row_changes`), so
/// both quote identifiers/literals and validate keys/values exactly the same
/// way. Keeping it pure also lets the batched path validate every change
/// *before* it opens a transaction, so a malformed item never leaves a
/// half-executed transaction behind.
pub(crate) fn change_row_sql<D: DatabaseDriver + ?Sized>(
    driver: &D,
    ns: &str,
    table: &str,
    action: &str,
    keys: &Map<String, Value>,
    values: &Map<String, Value>,
    limit_one: bool,
) -> AppResult<String> {
    let dialect = driver.dialect();
    let target = dialect.qualify(ns, table);
    let wheres = keys
        .iter()
        .map(|(c, v)| {
            if v.is_null() {
                format!("{} IS NULL", dialect.quote_ident(c))
            } else {
                format!("{} = {}", dialect.quote_ident(c), dialect.literal(v))
            }
        })
        .collect::<Vec<_>>()
        .join(" AND ");
    // 用全部列匹配可能命中多行，所以收窄到一行。
    let (cond, tail) = if limit_one {
        match driver.kind() {
            DriverKind::Postgres => (
                format!("ctid = (SELECT ctid FROM {} WHERE {} LIMIT 1)", target, wheres),
                "",
            ),
            DriverKind::Sqlite => (
                format!("rowid = (SELECT rowid FROM {} WHERE {} LIMIT 1)", target, wheres),
                "",
            ),
            DriverKind::Mysql => (wheres.clone(), " LIMIT 1"),
        }
    } else {
        (wheres.clone(), "")
    };
    Ok(match action {
        "insert" => {
            if values.is_empty() {
                return Err(AppError::bad("insert requires at least one column"));
            }
            let cols: Vec<String> = values.keys().map(|c| dialect.quote_ident(c)).collect();
            let vals: Vec<String> = values.values().map(|v| dialect.literal(v)).collect();
            format!(
                "INSERT INTO {} ({}) VALUES ({})",
                target,
                cols.join(", "),
                vals.join(", ")
            )
        }
        "update" => {
            if values.is_empty() {
                return Err(AppError::bad("update requires at least one column"));
            }
            if keys.is_empty() {
                return Err(AppError::bad("update requires a row key"));
            }
            let sets: Vec<String> = values
                .iter()
                .map(|(c, v)| format!("{} = {}", dialect.quote_ident(c), dialect.literal(v)))
                .collect();
            format!(
                "UPDATE {} SET {} WHERE {}{}",
                target,
                sets.join(", "),
                cond,
                tail
            )
        }
        "delete" => {
            if keys.is_empty() {
                return Err(AppError::bad("delete requires a row key"));
            }
            format!("DELETE FROM {} WHERE {}{}", target, cond, tail)
        }
        other => return Err(AppError::bad(format!("unknown row action '{}'", other))),
    })
}

/// Build — but do not execute — the "does this row key still exist?" probe.
///
/// [change_row_sql] renders the UPDATE / DELETE, but a zero affected-row count
/// can mean two different things: the key matched nothing, or (MySQL counts only
/// rows whose values actually changed) the row was there with identical values.
/// The batched apply path runs this probe after the transaction committed; it
/// reuses the same dialect quoting/literals, so no user value is pasted into SQL.
pub(crate) fn row_exists_sql<D: DatabaseDriver + ?Sized>(
    driver: &D,
    ns: &str,
    table: &str,
    keys: &Map<String, Value>,
) -> AppResult<String> {
    if keys.is_empty() {
        return Err(AppError::bad("row existence check requires a row key"));
    }
    let dialect = driver.dialect();
    let target = dialect.qualify(ns, table);
    let wheres = keys
        .iter()
        .map(|(c, v)| {
            if v.is_null() {
                format!("{} IS NULL", dialect.quote_ident(c))
            } else {
                format!("{} = {}", dialect.quote_ident(c), dialect.literal(v))
            }
        })
        .collect::<Vec<_>>()
        .join(" AND ");
    // LIMIT 1 is valid on MySQL, PostgreSQL and SQLite; the probe only needs to
    // know whether at least one row still matches the key.
    Ok(format!("SELECT 1 FROM {} WHERE {} LIMIT 1", target, wheres))
}

pub(crate) async fn change_row<D: DatabaseDriver + ?Sized>(
    driver: &D,
    conn: &ConnectionHandle,
    ns: &str,
    table: &str,
    action: &str,
    keys: &Map<String, Value>,
    values: &Map<String, Value>,
    limit_one: bool,
) -> AppResult<Value> {
    let sql = change_row_sql(driver, ns, table, action, keys, values, limit_one)?;
    let result = conn.run_one(sql).await;
    if let Some(err) = result.error {
        return Err(AppError::bad(err));
    }
    Ok(json!({
        "ok": true,
        "action": action,
        "rows_affected": result.row_count,
        "last_insert_id": result.last_insert_id,
    }))
}

#[cfg(test)]
mod tests {
    use super::{
        is_transactional_restore_statement, restore_atomic_blockers, restore_atomic_eligible,
        restore_groups, restore_sql, restore_sql_atomic, restore_tx_for, split_statements,
        RestoreGroup, RESTORE_ATOMIC_MAX_BYTES, RESTORE_BATCH_BYTES, RESTORE_BATCH_STATEMENTS,
    };
    use crate::db::ResultSet;
    use crate::session::SessionHandle;

    fn statements(sql_parts: &[&str]) -> Vec<String> {
        sql_parts.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn only_dml_joins_a_restore_transaction() {
        for dml in [
            "INSERT INTO t VALUES (1)",
            "  insert into t values (1)",
            "REPLACE INTO t VALUES (1)",
            "UPDATE t SET x = 1",
            "DELETE FROM t",
            "-- comment\nINSERT INTO t VALUES (1)",
        ] {
            assert!(
                is_transactional_restore_statement(dml),
                "{dml} should be transactional"
            );
        }
        for barrier in [
            "DROP TABLE IF EXISTS t",
            "CREATE TABLE t (id INT)",
            "ALTER TABLE t ADD COLUMN c INT",
            "SET FOREIGN_KEY_CHECKS=0",
            "USE db",
            "LOCK TABLES t WRITE",
            "BEGIN",
            "COMMIT",
        ] {
            assert!(
                !is_transactional_restore_statement(barrier),
                "{barrier} must stay a barrier"
            );
        }
    }

    #[test]
    fn restore_groups_keep_order_and_merge_consecutive_dml() {
        let stmts = statements(&[
            "DROP TABLE IF EXISTS t",
            "CREATE TABLE t (id INT)",
            "INSERT INTO t VALUES (1)",
            "INSERT INTO t VALUES (2)",
            "UPDATE t SET id = 3",
            "SET FOREIGN_KEY_CHECKS=1",
            "DELETE FROM t",
        ]);
        assert_eq!(
            restore_groups(&stmts),
            vec![
                RestoreGroup::Single(0),
                RestoreGroup::Single(1),
                RestoreGroup::Batch { start: 2, end: 5 },
                RestoreGroup::Single(5),
                RestoreGroup::Batch { start: 6, end: 7 },
            ]
        );
    }

    #[test]
    fn restore_groups_split_runs_on_the_statement_cap() {
        let mut stmts = Vec::new();
        for _ in 0..(RESTORE_BATCH_STATEMENTS + 2) {
            stmts.push("INSERT INTO t VALUES (1)".to_string());
        }
        let groups = restore_groups(&stmts);
        assert_eq!(groups.len(), 2, "{groups:?}");
        assert_eq!(
            groups[0],
            RestoreGroup::Batch {
                start: 0,
                end: RESTORE_BATCH_STATEMENTS
            }
        );
        assert_eq!(
            groups[1],
            RestoreGroup::Batch {
                start: RESTORE_BATCH_STATEMENTS,
                end: RESTORE_BATCH_STATEMENTS + 2
            }
        );
    }

    #[test]
    fn restore_groups_split_runs_on_the_byte_budget() {
        // Two statements of a bit more than half the budget each: the second
        // one must start a new batch instead of pushing the first past the cap.
        let half_plus = "x".repeat(RESTORE_BATCH_BYTES / 2 + 1);
        let big = vec![
            format!("INSERT INTO t VALUES ('{half_plus}')"),
            format!("INSERT INTO t VALUES ('{half_plus}')"),
        ];
        assert_eq!(
            restore_groups(&big),
            vec![
                RestoreGroup::Batch { start: 0, end: 1 },
                RestoreGroup::Batch { start: 1, end: 2 },
            ]
        );
    }

    #[test]
    fn mysql_batches_start_with_autocommit_off_because_prepared_begin_is_rejected() {
        let mysql = restore_tx_for("mysql");
        assert_eq!(mysql.begin, "SET autocommit = 0");
        assert_eq!(mysql.commit, "COMMIT");
        assert_eq!(mysql.rollback, "ROLLBACK");
        assert_eq!(
            mysql.reset,
            Some("SET autocommit = 1"),
            "barrier statements after a batch must run in the old autocommit mode"
        );
        let postgres = restore_tx_for("postgres");
        assert_eq!(postgres.begin, "BEGIN");
        assert_eq!(postgres.reset, None);
        let sqlite = restore_tx_for("sqlite");
        assert_eq!(sqlite.begin, "BEGIN");
    }

    // ------------------------------------------------ restore_sql_atomic (round 58)

    /// Scripted session for the restore path: records the statements it is
    /// asked to run and fails those matching a configured needle.
    struct FakeSession {
        driver: &'static str,
        executed: Vec<String>,
        fail_contains: Vec<&'static str>,
    }

    impl FakeSession {
        fn new(driver: &'static str) -> Self {
            FakeSession {
                driver,
                executed: Vec::new(),
                fail_contains: Vec::new(),
            }
        }

        fn executed(&self) -> Vec<&str> {
            self.executed.iter().map(String::as_str).collect()
        }
    }

    #[async_trait::async_trait]
    impl SessionHandle for FakeSession {
        fn driver_id(&self) -> &'static str {
            self.driver
        }

        async fn run_limited(&mut self, statement: String, _max_rows: usize) -> ResultSet {
            self.executed.push(statement.clone());
            let fails = self
                .fail_contains
                .iter()
                .any(|needle| statement.contains(needle));
            ResultSet {
                columns: Vec::new(),
                rows: Vec::new(),
                row_count: if fails { 0 } else { 1 },
                last_insert_id: 0,
                kind: if fails { "error" } else { "affected" }.to_string(),
                error: fails.then(|| format!("boom: {statement}")),
                statement,
                truncated: false,
            }
        }

        async fn search_path(&mut self) -> String {
            String::new()
        }

        async fn release(&mut self) {}
    }

    #[tokio::test]
    async fn atomic_restore_runs_the_whole_dump_in_one_transaction() {
        let mut session = FakeSession::new("postgres");
        let report = restore_sql_atomic(
            &mut session,
            "CREATE TABLE t (id INT); INSERT INTO t VALUES (1); INSERT INTO t VALUES (2)",
        )
        .await;
        // Order matters: BEGIN first, every statement, then one COMMIT.
        assert_eq!(
            session.executed(),
            vec![
                "BEGIN",
                "CREATE TABLE t (id INT)",
                "INSERT INTO t VALUES (1)",
                "INSERT INTO t VALUES (2)",
                "COMMIT",
            ]
        );
        assert!(report.atomic);
        assert!(!report.rolled_back);
        assert_eq!(report.total_statements, 3);
        assert_eq!(report.statements(), 3);
        assert_eq!(report.failed(), 0);
        assert_eq!(report.skipped_statements(), 0);
        // One transaction group covers the whole dump.
        assert_eq!(report.transaction_batches, 1);
        assert_eq!(report.statements_in_transactions, 3);
    }

    #[tokio::test]
    async fn atomic_restore_rolls_back_at_the_first_failure_and_skips_the_rest() {
        let mut session = FakeSession::new("postgres");
        session.fail_contains.push("BROKEN");
        let report = restore_sql_atomic(
            &mut session,
            "CREATE TABLE t (id INT); INSERT INTO t VALUES (1); INSERT INTO t VALUES BROKEN; INSERT INTO t VALUES (3)",
        )
        .await;
        // Stops at the failing statement: BEGIN, 3 executed, ROLLBACK; no COMMIT.
        assert_eq!(
            session.executed(),
            vec![
                "BEGIN",
                "CREATE TABLE t (id INT)",
                "INSERT INTO t VALUES (1)",
                "INSERT INTO t VALUES BROKEN",
                "ROLLBACK",
            ]
        );
        assert!(report.atomic);
        assert!(report.rolled_back);
        assert_eq!(report.total_statements, 4);
        assert_eq!(report.statements(), 3, "results only hold executed statements");
        assert_eq!(report.failed(), 1);
        assert_eq!(
            report.results.last().map(|r| r.statement.as_str()),
            Some("INSERT INTO t VALUES BROKEN")
        );
        assert_eq!(report.skipped_statements(), 1);
        assert_eq!(report.transaction_batches, 0);
        assert_eq!(report.statements_in_transactions, 0);
    }

    #[tokio::test]
    async fn atomic_restore_rolls_back_when_the_commit_itself_fails() {
        let mut session = FakeSession::new("postgres");
        session.fail_contains.push("COMMIT");
        let report = restore_sql_atomic(&mut session, "INSERT INTO t VALUES (1)").await;
        // BEGIN, INSERT, COMMIT (fails), best-effort ROLLBACK.
        assert_eq!(
            session.executed(),
            vec!["BEGIN", "INSERT INTO t VALUES (1)", "COMMIT", "ROLLBACK"]
        );
        assert!(report.atomic);
        assert!(report.rolled_back);
        assert_eq!(report.total_statements, 1);
        assert_eq!(
            report.statements(),
            2,
            "one dump statement plus the synthetic COMMIT error entry"
        );
        assert_eq!(report.failed(), 1);
        assert_eq!(report.results.last().map(|r| r.statement.as_str()), Some("COMMIT"));
        assert_eq!(report.skipped_statements(), 0);
        assert_eq!(report.transaction_batches, 0);
    }

    #[tokio::test]
    async fn atomic_restore_falls_back_to_grouped_execution_when_begin_is_rejected() {
        let mut session = FakeSession::new("postgres");
        session.fail_contains.push("BEGIN");
        let report = restore_sql_atomic(
            &mut session,
            "INSERT INTO t VALUES (1); INSERT INTO t VALUES (2)",
        )
        .await;
        // The atomic BEGIN failed, then the grouped fallback tries its own BEGIN
        // (also rejected) and runs every statement in autocommit mode.
        assert_eq!(
            session.executed(),
            vec![
                "BEGIN",
                "BEGIN",
                "INSERT INTO t VALUES (1)",
                "INSERT INTO t VALUES (2)",
            ]
        );
        assert!(!report.atomic, "a rejected BEGIN must not pretend to be atomic");
        assert!(!report.rolled_back);
        assert_eq!(report.total_statements, 2);
        assert_eq!(report.statements(), 2);
        assert_eq!(report.failed(), 0);
        assert_eq!(report.skipped_statements(), 0);
    }

    #[tokio::test]
    async fn atomic_restore_for_a_mysql_session_uses_the_grouped_path() {
        // MySQL DDL implicitly commits: calling the atomic entry point with a
        // MySQL session must not pretend to be atomic.
        let mut session = FakeSession::new("mysql");
        let report = restore_sql_atomic(
            &mut session,
            "INSERT INTO t VALUES (1); INSERT INTO t VALUES (2)",
        )
        .await;
        assert!(!report.atomic);
        assert!(!report.rolled_back);
        assert!(!session.executed().iter().any(|s| *s == "BEGIN"));
        // The grouped path uses MySQL's autocommit toggle instead of BEGIN.
        assert!(session.executed().contains(&"SET autocommit = 0"));
        assert!(session.executed().contains(&"COMMIT"));
        assert_eq!(report.total_statements, 2);
        assert_eq!(report.statements(), 2);
    }

    #[tokio::test]
    async fn atomic_restore_also_uses_one_transaction_for_sqlite() {
        // SQLite has transactional DDL too, so the backup path uses the same
        // atomic entry point there.
        let mut session = FakeSession::new("sqlite");
        let report = restore_sql_atomic(
            &mut session,
            "CREATE TABLE t (id INT); INSERT INTO t VALUES (1)",
        )
        .await;
        assert_eq!(
            session.executed(),
            vec![
                "BEGIN",
                "CREATE TABLE t (id INT)",
                "INSERT INTO t VALUES (1)",
                "COMMIT",
            ]
        );
        assert!(report.atomic);
        assert!(!report.rolled_back);
        assert_eq!(report.transaction_batches, 1);
        assert_eq!(report.statements_in_transactions, 2);
    }

    #[tokio::test]
    async fn grouped_restore_stays_non_atomic_and_attempts_every_statement() {
        let mut session = FakeSession::new("mysql");
        let report =
            restore_sql(&mut session, "INSERT INTO t VALUES (1); INSERT INTO t VALUES (2)").await;
        assert!(!report.atomic);
        assert!(!report.rolled_back);
        assert_eq!(report.total_statements, 2);
        assert_eq!(report.statements(), 2);
        assert_eq!(report.transaction_batches, 1);
        assert_eq!(report.statements_in_transactions, 2);
        assert!(session.executed().contains(&"COMMIT"));
    }

    // ------------------------------------------------ atomic fallback (round 59)

    fn blockers_for(driver: &str, sql: &str) -> Vec<String> {
        restore_atomic_blockers(&split_statements(sql), driver)
    }

    #[test]
    fn postgres_transaction_illegal_statements_are_detected() {
        for (sql, expected) in [
            ("VACUUM t", "VACUUM"),
            ("vacuum (full, analyze) t", "VACUUM"),
            ("CREATE DATABASE app", "CREATE DATABASE"),
            ("drop database if exists app", "DROP DATABASE"),
            ("CREATE TABLESPACE ts LOCATION '/data'", "CREATE TABLESPACE"),
            ("DROP TABLESPACE ts", "DROP TABLESPACE"),
            ("ALTER SYSTEM SET work_mem = '1GB'", "ALTER SYSTEM"),
            ("CREATE INDEX CONCURRENTLY idx ON t (c)", "CREATE INDEX CONCURRENTLY"),
            ("CREATE UNIQUE INDEX CONCURRENTLY idx ON t (c)", "CREATE INDEX CONCURRENTLY"),
            (
                "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx ON t (c)",
                "CREATE INDEX CONCURRENTLY",
            ),
            (
                "CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx ON t (c)",
                "CREATE INDEX CONCURRENTLY",
            ),
            ("DROP INDEX CONCURRENTLY idx", "DROP INDEX CONCURRENTLY"),
            ("DROP INDEX CONCURRENTLY IF EXISTS idx", "DROP INDEX CONCURRENTLY"),
            ("REINDEX TABLE CONCURRENTLY t", "REINDEX CONCURRENTLY"),
            ("REINDEX (CONCURRENTLY) TABLE t", "REINDEX CONCURRENTLY"),
            ("REINDEX (VERBOSE, CONCURRENTLY) INDEX idx", "REINDEX CONCURRENTLY"),
            (
                "ALTER TABLE ONLY app.tbl DETACH PARTITION app.p CONCURRENTLY",
                "ALTER TABLE DETACH PARTITION CONCURRENTLY",
            ),
            (
                "alter table if exists t detach partition p concurrently",
                "ALTER TABLE DETACH PARTITION CONCURRENTLY",
            ),
            (
                "REFRESH MATERIALIZED VIEW CONCURRENTLY mv",
                "REFRESH MATERIALIZED VIEW CONCURRENTLY",
            ),
        ] {
            assert_eq!(
                blockers_for("postgres", sql),
                vec![expected.to_string()],
                "{sql}"
            );
        }
    }

    #[test]
    fn sqlite_transaction_illegal_statements_are_detected() {
        for (sql, expected) in [
            ("VACUUM", "VACUUM"),
            ("VACUUM INTO 'backup.db'", "VACUUM"),
            ("ATTACH DATABASE 'x.db' AS x", "ATTACH"),
            ("attach 'x.db' as x", "ATTACH"),
            ("DETACH DATABASE x", "DETACH"),
        ] {
            assert_eq!(
                blockers_for("sqlite", sql),
                vec![expected.to_string()],
                "{sql}"
            );
        }
        // PostgreSQL-only forms are not blockers for SQLite.
        assert!(blockers_for("sqlite", "CREATE DATABASE app").is_empty());
    }

    #[test]
    fn blocker_scan_handles_comments_case_multi_statements_and_dedup() {
        let sql = "-- header
/* block */ vacuum t;
CREATE TABLE t (id int);
  -- trailing
  CREATE INDEX CONCURRENTLY idx ON t (id);";
        assert_eq!(
            blockers_for("postgres", sql),
            vec!["VACUUM".to_string(), "CREATE INDEX CONCURRENTLY".to_string()]
        );
        // Repeated forms are reported once.
        assert_eq!(
            blockers_for("postgres", "VACUUM a; VACUUM b"),
            vec!["VACUUM".to_string()]
        );
        // A leading comment must not hide the keyword.
        assert_eq!(
            blockers_for("sqlite", "-- note
/* other */ ATTACH 'x' AS x"),
            vec!["ATTACH".to_string()]
        );
    }

    #[test]
    fn blocker_scan_does_not_match_words_inside_strings_or_comments() {
        for sql in [
            "INSERT INTO t VALUES ('VACUUM')",
            "UPDATE t SET note = 'CREATE DATABASE app'",
            "SELECT 'CONCURRENTLY' AS word",
            "COMMENT ON INDEX idx IS 'concurrently'",
            "CREATE TABLE t (vacuum text, concurrently int)",
            "CREATE TABLE t (id int); -- VACUUM inside a trailing comment\n SELECT 1",
            // The non-concurrent DETACH PARTITION form is transactional, and a
            // trailing comment mentioning CONCURRENTLY must not change that.
            "ALTER TABLE t DETACH PARTITION p",
            "ALTER TABLE t DETACH PARTITION p -- CONCURRENTLY",
            "INSERT INTO t VALUES ('ALTER TABLE x DETACH PARTITION y CONCURRENTLY')",
            // A column named index plus a string containing CONCURRENTLY is not
            // CREATE INDEX CONCURRENTLY (the prefix must be CREATE [UNIQUE] INDEX).
            "CREATE TABLE t (index text, note text DEFAULT 'CONCURRENTLY')",
            "SELECT 'CREATE UNIQUE INDEX CONCURRENTLY'",
        ] {
            assert!(blockers_for("postgres", sql).is_empty(), "{sql}");
        }
        for sql in [
            "INSERT INTO t VALUES ('ATTACH')",
            "SELECT 'VACUUM'",
            "CREATE TABLE vacuum (id int)",
        ] {
            assert!(blockers_for("sqlite", sql).is_empty(), "{sql}");
        }
    }

    #[test]
    fn atomic_eligibility_reports_reasons_and_size_threshold() {
        let normal = "CREATE TABLE t (id int); INSERT INTO t VALUES (1)";
        assert!(restore_atomic_eligible("postgres", normal, 1024).is_ok());
        assert!(restore_atomic_eligible("sqlite", normal, 1024).is_ok());

        // MySQL is never atomic (its DDL implicitly commits).
        let mysql = restore_atomic_eligible("mysql", normal, 1024).unwrap_err();
        assert!(mysql.contains("MySQL"), "{mysql}");
        assert!(mysql.contains("分组提交"), "{mysql}");

        // Transaction-illegal statement: the reason names driver + form.
        let pg = restore_atomic_eligible("postgres", "VACUUM t; SELECT 1", 1024).unwrap_err();
        assert!(pg.contains("PostgreSQL"), "{pg}");
        assert!(pg.contains("VACUUM"), "{pg}");
        assert!(pg.contains("不能在事务中执行的语句"), "{pg}");
        let sqlite =
            restore_atomic_eligible("sqlite", "ATTACH DATABASE 'x' AS x", 1024).unwrap_err();
        assert!(sqlite.contains("SQLite"), "{sqlite}");
        assert!(sqlite.contains("ATTACH"), "{sqlite}");

        // Exactly the limit is still atomic; one byte over is not.
        assert!(
            restore_atomic_eligible("postgres", normal, RESTORE_ATOMIC_MAX_BYTES).is_ok(),
            "the threshold itself is still atomic"
        );
        let over =
            restore_atomic_eligible("postgres", normal, RESTORE_ATOMIC_MAX_BYTES + 1).unwrap_err();
        assert!(over.contains("256 MiB"), "{over}");
        assert!(over.contains("分组提交"), "{over}");
        let big = restore_atomic_eligible(
            "postgres",
            normal,
            RESTORE_ATOMIC_MAX_BYTES + 64 * 1024 * 1024,
        )
        .unwrap_err();
        assert!(big.contains("320 MiB"), "{big}");
        assert!(big.contains("256 MiB"), "{big}");
        assert!(big.contains("失败时可能留下部分数据"), "{big}");
    }

    #[tokio::test]
    async fn atomic_restore_falls_back_when_the_dump_uses_a_transaction_illegal_statement() {
        let mut session = FakeSession::new("postgres");
        let report = restore_sql_atomic(&mut session, "VACUUM t; CREATE TABLE t (id INT)").await;
        assert!(!report.atomic, "VACUUM must force the grouped path");
        assert!(!report.rolled_back);
        assert_eq!(report.total_statements, 2);
        assert_eq!(report.statements(), 2);
        // The grouped path does not open a transaction for these barrier statements.
        assert!(!session.executed().iter().any(|s| *s == "BEGIN"));
        assert!(session.executed().contains(&"VACUUM t"));
    }
}

