//! Backup and restore.
//!
//! Ports the web `routes/backup.rs`. The web version restricted a backup to
//! its creator or an admin; a desktop app has one user, so every backup is
//! accessible. The dump content is still written 0600 through `BackupStore`.

use std::io::Write;

use serde::Deserialize;
use serde_json::{json, Value};

use super::{parse, state};
use crate::error::AppError;

pub async fn list_backups() -> anyhow::Result<Value> {
    let state = state()?;
    let items = state.backups.list().await;
    Ok(json!({ "backups": items }))
}

#[derive(Deserialize)]
struct CreateBackupRequest {
    database: String,
    #[serde(default)]
    table: Option<String>,
}

/// Dump a whole database (or one table) into a new backup file.
///
/// The dump is **streamed** into a private temp file in the backup directory
/// (one multi-row INSERT per 500 rows via [super::export::table_sql_stream]),
/// then committed with one atomic rename. The old implementation built each
/// table's whole dump as a `String` — and the whole database dump as one giant
/// `String` — which for a large table meant holding every row in memory at
/// once (backup of a 500k-row table could add hundreds of MB of RSS).
pub async fn create_backup(body: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let req: CreateBackupRequest = parse("backup", body)?;
    let database = req.database.trim().to_string();
    if database.is_empty() {
        return Err(AppError::bad("请选择数据库").into());
    }
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(Some(&database)).await?;
    let server_database = if driver.kind() == crate::drivers::DriverKind::Postgres {
        state.active_database().await
    } else {
        None
    };
    let table = req.table.as_deref().map(str::trim).filter(|s| !s.is_empty());
    // Which tables to dump (the explicit one, or every base table).
    let table_names: Vec<String> = match table {
        Some(name) => vec![name.to_string()],
        None => driver
            .list_tables(&conn, &database)
            .await?
            .into_iter()
            .filter(|t| t.get("type").and_then(|v| v.as_str()) == Some("BASE TABLE"))
            .filter_map(|t| {
                t.get("name")
                    .and_then(|v| v.as_str())
                    .map(str::to_string)
                    .filter(|name| !name.is_empty())
            })
            .collect(),
    };

    let temp = state.backups.temp_dump_path().await?;
    let written: anyhow::Result<()> = async {
        let file = std::fs::OpenOptions::new()
            .write(true)
            .truncate(true)
            .open(&temp)
            .map_err(|e| AppError::Internal(format!("无法创建备份文件: {e}")))?;
        // 1 MiB buffer: rows are written in 500-row batches, so a bigger buffer
        // only delays the first flush without helping throughput.
        let mut writer = std::io::BufWriter::with_capacity(1 << 20, file);
        write!(
            writer,
            "-- DBPilot backup\n-- Driver: {}\n-- Database: {}\n-- Server database: {}\n-- Created: {}\n\n",
            driver.label(),
            database,
            server_database.as_deref().unwrap_or("-"),
            chrono::Utc::now().to_rfc3339()
        )?;
        for name in &table_names {
            super::export::table_sql_stream(
                driver.as_ref(),
                &conn,
                &database,
                name,
                true,
                true,
                true,
                &mut writer,
                0,
            )
            .await?;
        }
        writer.flush()?;
        Ok(())
    }
    .await;
    if let Err(error) = written {
        // Do not leave a half-written dump in the backup directory.
        let _ = std::fs::remove_file(&temp);
        return Err(error);
    }
    let meta = state
        .backups
        .create_from_path(
            driver.id(),
            &database,
            table,
            &temp,
            server_database.as_deref(),
        )
        .await?;
    Ok(json!({ "ok": true, "backup": meta }))
}

/// Read one backup file so the UI can preview or save it.
pub async fn read_backup(id: String) -> anyhow::Result<Value> {
    let state = state()?;
    let (meta, content) = state.backups.read(&id).await?;
    Ok(json!({ "backup": meta, "content": content }))
}

/// Execute every statement in a backup against its original database.
///
/// The dump runs through **one pinned connection** and consecutive DML
/// statements are grouped into transactions (see
/// [dbpilot_core::ops::restore_sql]): a 500k-row dump pays a handful of commits
/// instead of one autocommit per INSERT. Failure reporting is unchanged — one
/// entry per dump statement, the first 20 errors are returned — and a failed
/// batch is rolled back and replayed so every other statement is still
/// attempted.
pub async fn restore_backup(id: String) -> anyhow::Result<Value> {
    let state = state()?;
    let (meta, content) = state.backups.read(&id).await?;
    let driver = state.driver_for_active().await?;
    // PostgreSQL backups record the physical database; without it (an older
    // backup) the schema-only restore keeps using the active database.
    let target_database = match meta.server_database.as_deref() {
        Some(database) => {
            if driver.kind() == crate::drivers::DriverKind::Postgres {
                state.set_active_database(Some(database.to_string())).await;
            }
            Some(database.to_string())
        }
        // MySQL / SQLite: the backup database is the namespace to restore into.
        None => Some(meta.database.clone()),
    };
    // Pinned connection: consecutive statements share session state, which is
    // what lets the DML batches run in a transaction (and makes a dump's
    // USE / SET FOREIGN_KEY_CHECKS actually apply to the next statement).
    let mut session = state.open_session(target_database.as_deref()).await?;
    let report = dbpilot_core::ops::restore_sql(session.as_mut(), &content).await;
    drop(session);
    let statements = report.statements();
    let failed = report.failed();
    let errors: Vec<Value> = report
        .results
        .iter()
        .filter_map(|r| {
            r.error
                .as_ref()
                .map(|e| json!({ "statement": r.statement, "error": e }))
        })
        .take(20)
        .collect();
    Ok(json!({
        "ok": failed == 0,
        "statements": statements,
        "failed": failed,
        "errors": errors,
        // Additive diagnostics: how the restore was batched. MySQL DDL
        // implicitly commits, so statements_in_transactions covers only the
        // consecutive DML runs; a dump is never atomic as a whole on MySQL.
        "transaction_batches": report.transaction_batches,
        "statements_in_transactions": report.statements_in_transactions,
        "round_trips": report.round_trips,
    }))
}

pub async fn delete_backup(id: String) -> anyhow::Result<Value> {
    let state = state()?;
    let removed = state.backups.remove(&id).await?;
    Ok(json!({ "ok": true, "removed": removed }))
}

