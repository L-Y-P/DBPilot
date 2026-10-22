//! Backup and restore.
//!
//! Ports the web `routes/backup.rs`. The web version restricted a backup to
//! its creator or an admin; a desktop app has one user, so every backup is
//! accessible. The dump content is still written 0600 through `BackupStore`.

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
    let mut body = format!(
        "-- DBPilot backup\n-- Driver: {}\n-- Database: {}\n-- Server database: {}\n-- Created: {}\n\n",
        driver.label(),
        database,
        server_database.as_deref().unwrap_or("-"),
        chrono::Utc::now().to_rfc3339()
    );
    match table {
        Some(name) => {
            body.push_str(
                &super::export::table_sql(driver.as_ref(), &conn, &database, name, true, true, true)
                    .await?,
            );
        }
        None => {
            let tables = driver.list_tables(&conn, &database).await?;
            for t in tables {
                if t.get("type").and_then(|v| v.as_str()) != Some("BASE TABLE") {
                    continue;
                }
                let name = t.get("name").and_then(|v| v.as_str()).unwrap_or("").to_string();
                if name.is_empty() {
                    continue;
                }
                body.push_str(
                    &super::export::table_sql(driver.as_ref(), &conn, &database, &name, true, true, true)
                        .await?,
                );
            }
        }
    }
    let meta = state
        .backups
        .create(
            driver.id(),
            &database,
            table,
            body,
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
pub async fn restore_backup(id: String) -> anyhow::Result<Value> {
    let state = state()?;
    let (meta, content) = state.backups.read(&id).await?;
    // PostgreSQL backups record the physical database; without it (an older
    // backup) the schema-only restore keeps using the active database.
    let driver = state.driver_for_active().await?;
    let conn = match meta.server_database.as_deref() {
        Some(database) => {
            let conn = state.connection_for_database(database).await?;
            if driver.kind() == crate::drivers::DriverKind::Postgres {
                state.set_active_database(Some(database.to_string())).await;
            }
            conn
        }
        None => state.connection_for(Some(&meta.database)).await?,
    };
    let results = driver.run_sql(&conn, &content).await;
    let statements = results.len();
    let failed = results.iter().filter(|r| r.error.is_some()).count();
    let errors: Vec<Value> = results
        .iter()
        .filter_map(|r| r.error.as_ref().map(|e| json!({ "statement": r.statement, "error": e })))
        .take(20)
        .collect();
    Ok(json!({
        "ok": failed == 0,
        "statements": statements,
        "failed": failed,
        "errors": errors,
    }))
}

pub async fn delete_backup(id: String) -> anyhow::Result<Value> {
    let state = state()?;
    let removed = state.backups.remove(&id).await?;
    Ok(json!({ "ok": true, "removed": removed }))
}
