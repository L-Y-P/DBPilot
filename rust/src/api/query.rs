//! SQL console: execute, EXPLAIN, and query history.
//!
//! Ports the web `routes/sql.rs`. History is no longer per-user: the desktop
//! app has a single user, so `HistoryStore` is queried without a username filter.

use serde::Deserialize;
use serde_json::{json, Value};

use super::{
    parse, session_error_result, session_result, state, strip_leading_comments,
    switch_database_for_use, use_statement_target,
};
use crate::core::dialect::DialectCapability;
use crate::error::{AppError, AppResult};
use crate::history::new_entry;
use crate::state::AppState;

/// Maximum rows a single SQL-console statement may materialise.
///
/// The console used to return every row of every statement. A plain
/// `SELECT *` over a 1,000,000-row table froze the UI for ~200s and used
/// ~1 GB of RSS; 3,000,000 rows froze it for over 6 minutes and had to be
/// force-killed (S-08). Capping the result keeps the console responsive and
/// bounded; the UI tells the user the output was cut off and to add
/// WHERE/LIMIT or use the export tab for the full data.
pub const MAX_CONSOLE_ROWS: usize = 50_000;

#[derive(Deserialize)]
struct QueryRequest {
    sql: String,
    #[serde(default)]
    database: Option<String>,
}

fn clean_database(value: Option<&String>) -> Option<&str> {
    value.map(String::as_str).map(str::trim).filter(|s| !s.is_empty())
}

/// Run a SQL script (one or many statements) and record it in history.
///
/// A `USE <database>` statement is handled as a validated database switch
/// instead of being forwarded to the server: the console's only_db / hide_db
/// boundary is checked exactly like the database picker, then following
/// statements run against the new database. That makes the natural
/// "USE db;" prelude work without letting raw SQL escape the visibility rules.
pub async fn run_query(body: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let req: QueryRequest = parse("query", body)?;
    if req.sql.trim().is_empty() {
        return Err(AppError::bad("SQL 语句不能为空").into());
    }
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
    let driver_id = session.driver_id();
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
    let mut results: Vec<crate::db::ResultSet> = Vec::new();
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
    for statement in statements {
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
                                let replayed = next.run_limited(prelude.clone(), MAX_CONSOLE_ROWS).await;
                                if let Some(error) = replayed.error {
                                    tracing::warn!(
                                        "could not replay session setting after USE {target}: {error}"
                                    );
                                }
                            }
                            session = next;
                        }
                        Err(e) => {
                            results.push(session_error_result(&statement, &e.to_string()));
                            break;
                        }
                    }
                    results.push(session_result(
                        &statement,
                        &format!("已切换到数据库：{}", target),
                    ));
                }
                Err(e) => {
                    results.push(session_error_result(&statement, &e.to_string()));
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
        let result = session.run_limited(tagged, MAX_CONSOLE_ROWS).await;
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
        results.push(result);
    }
    if let Some(token) = cancel_token.as_deref() {
        state.clear_cancel_token(token).await;
    }
    // N-07: a cancelled MySQL connection / canceled PostgreSQL backend fails the
    // in-flight query with a transport error. Replace that raw protocol message
    // with a user-facing "query cancelled" explanation.
    if let Some(cancelled) = state.take_cancelled().await {
        if cancel_token.as_deref() == Some(cancelled.as_str()) {
            let message = driver_impl.dialect().cancel_message();
            for result in &mut results {
                if let Some(error) = result.error.as_mut() {
                    if is_cancel_transport_error(error) {
                        *error = message.to_string();
                    }
                }
            }
        }
    }
    if let Some(tag) = result_tag.as_deref() {
        for result in &mut results {
            if let Some(rest) = result.statement.strip_prefix(tag) {
                result.statement = rest.to_string();
            }
        }
    }
    let elapsed_ms = started.elapsed().as_millis() as u64;
    let failed = results.iter().filter(|r| r.error.is_some()).count();
    let count = results.len();
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
        count,
        failed,
        elapsed_ms,
    );
    let _ = state.history.push(entry).await;
    Ok(json!({
        "results": results,
        "statement_count": count,
        "failed": failed,
        "elapsed_ms": elapsed_ms,
        "driver": driver_id,
        "search_path": search_path,
        "database": database,
        "use_database": last_use,
        // S-08: the UI shows a "result truncated" banner when this is true.
        "truncated": truncated_any,
        "row_limit": MAX_CONSOLE_ROWS,
    }))
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
        return Err(AppError::bad(
            "SQLite 在应用进程内执行查询，无法安全取消；请等待查询完成",
        )
        .into());
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
    let mut database: Option<String> =
        clean_database(req.database.as_ref()).map(str::to_string);
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
    let already_explain = first.trim_start().to_ascii_uppercase().starts_with("EXPLAIN");
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

#[cfg(test)]
mod tests {
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
}

/// Query history, most recent first.
pub async fn history_list(
    limit: Option<u32>,
    offset: Option<u32>,
) -> anyhow::Result<Value> {
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
