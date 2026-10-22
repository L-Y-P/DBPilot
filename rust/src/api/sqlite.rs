//! SQLite database files.
//!
//! A SQLite "connection" is a folder of database files: the primary file is
//! opened as `main` and every other `.sqlite` / `.db` file in the folder is
//! ATTACHed. Nothing about that list is recorded — the folder on disk is the
//! state, so files added or removed outside the app are picked up on refresh.
//!
//! This module implements the operations the sidebar and the database page need:
//! list (grouped by directory), create a new database file in a chosen folder,
//! import existing files or folders, and delete a file from disk.

use std::path::{Path, PathBuf};

use serde::Deserialize;
use serde_json::{json, Value};

use super::{parse, state};
use crate::connections::ConnEntry;
use crate::drivers::{ConnSpec, DriverKind};
use crate::error::{AppError, AppResult};
use crate::state::AppState;

/// Files scanned under one connection folder.
///
/// Bounded so a folder accidentally pointed at `/` or a home directory cannot
/// stall the UI; the database page reports how many files it found.
const MAX_SCAN_FILES: usize = 500;
const MAX_SCAN_DEPTH: usize = 6;

/// The directory part of a path, as the UI shows it.
fn dir_of(path: &str) -> String {
    Path::new(path)
        .parent()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_default()
}

fn dir_label(dir: &str) -> String {
    Path::new(dir)
        .file_name()
        .and_then(|n| n.to_str())
        .map(|s| s.to_string())
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| dir.to_string())
}

/// The active connection, required to be SQLite.
async fn active_sqlite(state: &AppState) -> AppResult<crate::state::ActiveConnection> {
    let active = state.active().await?;
    if active.spec.driver != DriverKind::Sqlite {
        return Err(AppError::bad("当前连接不是 SQLite 连接"));
    }
    Ok(active)
}

fn entry_json(entry: &ConnEntry) -> Value {
    json!({
        "id": entry.id,
        "name": entry.name,
        "driver": entry.spec.driver.as_str(),
        "database": entry.spec.database(),
        "sqlite_dir": entry.spec.sqlite_folder(),
        "color": entry.color,
    })
}

/// List the active SQLite connection's databases, grouped by directory.
///
/// `refresh` rebuilds the pool first, which is what makes a file copied into the
/// folder (or deleted from it) appear: the pool attaches the folder's files at
/// creation time. Only the current connection is refreshed.
pub async fn sqlite_databases(refresh: bool) -> anyhow::Result<Value> {
    let state = state()?;
    // P2-3：文件发现走驱动能力（SQLite 实现），api 不再 import 具体驱动模块。
    let driver = state.driver(DriverKind::Sqlite.as_str())?;
    let active = active_sqlite(&state).await?;
    if refresh {
        // A missing or corrupt primary file must not make the *list* fail: the
        // page shows which file is broken instead of an empty sidebar.
        if let Err(e) = state.refresh_active().await {
            tracing::warn!("sqlite refresh failed: {e}");
        }
    }
    let primary = active.spec.database().unwrap_or("").to_string();
    let folder = active.spec.sqlite_folder().unwrap_or_default();
    let primary_exists = !primary.is_empty() && Path::new(&primary).exists();
    let folder_exists = !folder.is_empty() && Path::new(&folder).is_dir();

    // The list comes from what the pool actually attached, not from what the
    // folder contains: a file ATTACH rejected (corrupt, truncated) would
    // otherwise be listed under an alias no namespace answers to.
    // P5：命名空间列表通过驱动 + 句柄获取（与浏览路径同语义）。
    let attached: Vec<(String, String)> = match state.connection_for(None).await {
        Ok(handle) => driver
            .list_namespaces(&handle)
            .await
            .unwrap_or_default()
            .into_iter()
            .filter_map(|ns| {
                let name = ns.get("name")?.as_str()?.to_string();
                let file = ns.get("file").and_then(|f| f.as_str()).unwrap_or("").to_string();
                Some((name, file))
            })
            .filter(|(name, _)| name != "temp")
            .collect(),
        Err(e) => {
            tracing::warn!("sqlite namespaces failed: {e}");
            Vec::new()
        }
    };

    let scanned: Vec<String> = if folder_exists {
        driver.list_database_files(&folder, MAX_SCAN_FILES, MAX_SCAN_DEPTH)
    } else {
        Vec::new()
    };
    // Spellings the user (and the connection record) use. SQLite reports the
    // resolved path — /private/var/... on macOS for /var/... — and a database
    // route built from that would not match the stored connection, so the
    // recorded spelling always wins.
    let mut recorded: Vec<String> = Vec::new();
    if !primary.is_empty() {
        recorded.push(primary.clone());
    }
    recorded.extend(scanned.iter().cloned());

    let mut databases: Vec<Value> = Vec::new();
    for (namespace, file) in &attached {
        let path = if file.is_empty() { namespace.clone() } else { file.clone() };
        let display = recorded
            .iter()
            .find(|p| driver.same_database_path(p, &path))
            .cloned()
            .unwrap_or_else(|| path.clone());
        let dir = dir_of(&display);
        databases.push(json!({
            "name": namespace.clone(),
            "path": display,
            "file": path,
            "title": driver.connection_name_for_path(&display),
            "dir": dir,
            "primary": !primary.is_empty() && driver.same_database_path(&path, &primary),
            "exists": Path::new(&display).exists(),
        }));
    }

    // Files the folder contains but the pool could not attach: a corrupt or
    // truncated database. Reported by name so the user knows which file is bad.
    let mut unreadable: Vec<Value> = Vec::new();
    for text in &scanned {
        let text = text.clone();
        if attached.iter().any(|(_, f)| driver.same_database_path(f, &text)) {
            continue;
        }
        if !primary.is_empty() && driver.same_database_path(&text, &primary) {
            continue;
        }
        let readable = driver.is_readable_database(&text);
        unreadable.push(json!({
            "path": text,
            "title": driver.connection_name_for_path(&text),
            "dir": dir_of(&text),
            // A readable file that is not attached was skipped because the
            // attach limit was reached (or the file is locked); a corrupt file
            // is a different problem and is worded differently.
            "overflow": readable,
            "reason": if readable {
                "未打开：SQLite 同时附加的数据库数量已达上限（默认 10 个），或文件正被其他程序占用"
            } else {
                "文件不是可读的 SQLite 数据库（可能已损坏或被截断）"
            },
        }));
    }

    // Group by directory: one node per folder, databases underneath. A folder
    // import scans recursively, so several groups are normal.
    let mut groups: Vec<Value> = Vec::new();
    let mut group_dirs: Vec<String> = Vec::new();
    for db in &databases {
        let dir = db.get("dir").and_then(|d| d.as_str()).unwrap_or("").to_string();
        let index = match group_dirs.iter().position(|d| d == &dir) {
            Some(i) => i,
            None => {
                group_dirs.push(dir.clone());
                groups.push(json!({
                    "dir": dir,
                    "name": dir_label(&dir),
                    "databases": Vec::<Value>::new(),
                }));
                groups.len() - 1
            }
        };
        if let Some(list) = groups[index].get_mut("databases").and_then(|d| d.as_array_mut()) {
            list.push(db.clone());
        }
    }
    for group in groups.iter_mut() {
        if let Some(list) = group.get_mut("databases").and_then(|d| d.as_array_mut()) {
            list.sort_by_key(|d| {
                d.get("title")
                    .and_then(|t| t.as_str())
                    .unwrap_or("")
                    .to_ascii_lowercase()
            });
        }
    }

    Ok(json!({
        "folder": folder,
        "folder_name": dir_label(&folder),
        "folder_exists": folder_exists,
        "primary": primary,
        "primary_exists": primary_exists,
        "databases": databases,
        "groups": groups,
        "unreadable": unreadable,
        "scanned": scanned.len(),
        "attach_limit": driver.max_attached_databases(),
    }))
}

#[derive(Deserialize)]
struct CreateRequest {
    /// Folder that receives the new file.
    dir: String,
    name: String,
    #[serde(default)]
    content: Option<String>,
}

/// Create a new database file in `dir` and register it as a connection.
///
/// The file is created on disk first, so a folder the OS does not let the app
/// write to surfaces as a permission error instead of a database that silently
/// does not exist.
pub async fn sqlite_create_database(body: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let driver = state.driver(DriverKind::Sqlite.as_str())?;
    let req: CreateRequest = parse("dir", body)?;
    let dir = req.dir.trim().to_string();
    if dir.is_empty() {
        return Err(AppError::bad("请选择数据库文件保存目录").into());
    }
    let mut name = req.name.trim().to_string();
    if name.is_empty() {
        return Err(AppError::bad("请填写数据库文件名").into());
    }
    // A filename, not a path: the destination is chosen separately.
    if name.contains('/') || name.contains('\\') || name.contains("..") {
        return Err(AppError::bad("文件名不能包含路径分隔符或 ..").into());
    }
    // Characters Windows rejects in a file name. Checked on every platform so a
    // connection created on macOS/Linux still opens on Windows (the file would
    // otherwise be created successfully here and fail to even be listed there).
    if name
        .chars()
        .any(|c| matches!(c, ':' | '*' | '?' | '"' | '<' | '>' | '|') || c.is_control())
    {
        return Err(AppError::bad(
            "文件名不能包含 : * ? \" < > | 等字符（Windows 不允许）",
        )
        .into());
    }
    // Windows strips a trailing dot or space, which would make the created file
    // differ from the requested name; reserved device names cannot be created.
    if name.ends_with('.') || name.ends_with(' ') {
        return Err(AppError::bad("文件名不能以点或空格结尾（Windows 不允许）").into());
    }
    {
        const RESERVED: [&str; 22] = [
            "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5",
            "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4",
            "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
        ];
        let stem = name.split('.').next().unwrap_or("").to_ascii_uppercase();
        if RESERVED.contains(&stem.as_str()) {
            return Err(AppError::bad(format!(
                "{stem} 是 Windows 保留的设备名，请换一个文件名"
            ))
            .into());
        }
    }
    if !name.contains('.') {
        name.push_str(".sqlite");
    }
    let folder = Path::new(&dir);
    if !folder.is_dir() {
        return Err(AppError::not_found(format!("目录不存在：{dir}")).into());
    }
    let path = folder.join(&name);
    if path.exists() {
        return Err(AppError::bad(format!("文件已存在：{}", path.display())).into());
    }
    create_empty(&path).map_err(|e| {
        // Permission denied / read-only volume: name the operation and keep the
        // OS message so the user knows whether to pick another folder.
        AppError::bad(format!("无法在 {dir} 创建数据库文件：{e}"))
    })?;

    // Optional starter script, run through a pool of its own.
    if let Some(text) = req.content.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        let spec = ConnSpec {
            driver: DriverKind::Sqlite,
            database: Some(path.to_string_lossy().to_string()),
            ..Default::default()
        };
        let handle = crate::core::driver::PoolProvider::pooled(&state.pools, &spec, None).await?;
        for statement in crate::db::split_statements_for(driver.dialect(), text) {
            handle.exec(&statement).await?;
        }
    }

    let entry = ConnEntry {
        id: String::new(),
        name: driver.connection_name_for_path(&path.to_string_lossy()),
        spec: ConnSpec {
            driver: DriverKind::Sqlite,
            database: Some(path.to_string_lossy().to_string()),
            sqlite_dir: Some(dir.clone()),
            ..Default::default()
        },
        only_db: None,
        hide_db: None,
        color: None,
    };
    let saved = state.connections.upsert(entry).await?;
    let bound = state
        .bind_connection(crate::state::ActiveConnection::from_entry(&saved))
        .await?;
    let mut settings = state.settings();
    settings.last_connection_id = bound.id.clone();
    let _ = state.update_settings(settings).await;
    Ok(json!({
        "ok": true,
        "path": path.to_string_lossy(),
        "connection": entry_json(&saved),
    }))
}

#[derive(Deserialize)]
struct ImportRequest {
    #[serde(default)]
    paths: Vec<String>,
    /// Connect to the first imported database (default true).
    connect: Option<bool>,
}

/// Import existing database files, or every database file inside a folder.
///
/// Each imported file / folder becomes a saved SQLite connection, so the sidebar
/// can show it like any other connection. A folder that contains no database
/// file is reported instead of creating an empty connection.
pub async fn sqlite_import(body: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let driver = state.driver(DriverKind::Sqlite.as_str())?;
    let req: ImportRequest = parse("paths", body)?;
    let mut created: Vec<Value> = Vec::new();
    let mut failed: Vec<Value> = Vec::new();
    let mut first_id: Option<String> = None;

    for raw in &req.paths {
        let path = raw.trim();
        if path.is_empty() {
            continue;
        }
        let meta = std::fs::metadata(path);
        let meta = match meta {
            Ok(m) => m,
            Err(e) => {
                failed.push(json!({ "path": path, "error": format!("无法读取：{e}") }));
                continue;
            }
        };
        // A folder becomes one connection with the first readable file inside it
        // as the primary database; the rest are attached from the same folder.
        let (primary, dir, name) = if meta.is_dir() {
            let files = driver.list_database_files(path, MAX_SCAN_FILES, MAX_SCAN_DEPTH);
            let first = files
                .into_iter()
                .find(|file| driver.is_readable_database(file));
            match first {
                Some(file) => (file, path.to_string(), dir_label(path)),
                None => {
                    failed.push(json!({
                        "path": path,
                        "error": "该目录里没有可用的 SQLite 数据库文件",
                    }));
                    continue;
                }
            }
        } else {
            if !driver.is_database_file(path) {
                failed.push(json!({
                    "path": path,
                    "error": "不是 .sqlite / .sqlite3 / .db / .db3 文件",
                }));
                continue;
            }
            if !driver.is_readable_database(path) {
                failed.push(json!({
                    "path": path,
                    "error": "不是有效的 SQLite 数据库文件（可能已损坏）",
                }));
                continue;
            }
            (
                path.to_string(),
                dir_of(path),
                driver.connection_name_for_path(path),
            )
        };
        let entry = ConnEntry {
            id: String::new(),
            name,
            spec: ConnSpec {
                driver: DriverKind::Sqlite,
                database: Some(primary),
                sqlite_dir: Some(dir),
                ..Default::default()
            },
            only_db: None,
            hide_db: None,
            color: None,
        };
        // A file that is already registered is reused instead of duplicated: an
        // import is idempotent, so importing the same folder twice does nothing.
        let existing = state
            .connections
            .list()
            .await
            .into_iter()
            .find(|c| {
                c.spec.driver == DriverKind::Sqlite
                    && c.spec
                        .database()
                        .map(|d| driver.same_database_path(d, entry.spec.database().unwrap_or("")))
                        .unwrap_or(false)
            });
        let saved = match existing {
            Some(entry) => entry,
            None => state.connections.upsert(entry).await?,
        };
        if first_id.is_none() {
            first_id = Some(saved.id.clone());
        }
        created.push(entry_json(&saved));
    }

    if created.is_empty() {
        return Err(AppError::bad(
            failed
                .first()
                .and_then(|f| f.get("error"))
                .and_then(|e| e.as_str())
                .unwrap_or("没有可导入的数据库文件")
                .to_string(),
        )
        .into());
    }

    if req.connect.unwrap_or(true) {
        if let Some(id) = first_id.as_deref() {
            if let Some(entry) = state.connections.get(id).await {
                let bound = state
                    .bind_connection(crate::state::ActiveConnection::from_entry(&entry))
                    .await?;
                let mut settings = state.settings();
                settings.last_connection_id = bound.id.clone();
                let _ = state.update_settings(settings).await;
            }
        }
    }
    Ok(json!({ "ok": true, "created": created, "failed": failed }))
}

/// Create an empty SQLite database file (or fail with the OS error).
///
/// An empty file *is* a valid new SQLite database: SQLite writes the header on
/// the first write. Hand-writing a header page produced files that ATTACH
/// rejected as "database disk image is malformed".
fn create_empty(path: &Path) -> std::io::Result<()> {
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)?;
    Ok(())
}

/// True when `path` (after resolving symlinks) lives inside `folder`.
///
/// Both sides are canonicalised so `../outside.sqlite` and a symlinked
/// directory cannot escape the connection folder. A path that does not exist is
/// rejected: nothing to delete, and its real location cannot be proven.
fn path_is_inside(folder: &str, path: &str) -> bool {
    if folder.trim().is_empty() {
        return false;
    }
    let Ok(folder) = std::fs::canonicalize(folder) else {
        return false;
    };
    let Ok(target) = std::fs::canonicalize(path) else {
        return false;
    };
    target.starts_with(&folder) && target != folder
}

#[derive(Deserialize)]
struct PathList {
    #[serde(default)]
    paths: Vec<String>,
}

/// Delete database files from disk.
///
/// A real filesystem delete: if the OS refuses (read-only volume, no permission,
/// file in use) the error is returned instead of pretending the file is gone.
pub async fn sqlite_delete_file(body: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let driver = state.driver(DriverKind::Sqlite.as_str())?;
    let req: PathList = parse("paths", body)?;
    let active = active_sqlite(&state).await?;
    let primary = active.spec.database().unwrap_or("").to_string();
    // Only files inside the connection folder may be deleted. Without this the
    // API accepted any `.sqlite*` path on the machine, so a UI bug or a crafted
    // call could remove unrelated databases. Validate the whole batch first: a
    // partial delete followed by a rejected path would leave the list half gone.
    let folder = active.spec.sqlite_folder().unwrap_or_default();
    let mut targets: Vec<String> = Vec::new();
    for raw in req.paths {
        let path = raw.trim().to_string();
        if path.is_empty() {
            continue;
        }
        if !primary.is_empty() && driver.same_database_path(&path, &primary) {
            return Err(AppError::bad(
                "这是当前连接的主数据库文件，请改用删除连接或在连接编辑里更换主文件",
            )
            .into());
        }
        if !path_is_inside(&folder, &path) {
            return Err(AppError::bad(format!(
                "只允许删除当前连接目录内的数据库文件：{path}"
            ))
            .into());
        }
        if !driver.is_database_file(&path) {
            return Err(AppError::bad(format!(
                "不是 SQLite 数据库文件，拒绝删除：{path}"
            ))
            .into());
        }
        targets.push(path);
    }
    // Close the pooled connections before touching the files.
    //
    // Every attached database is held open by the active pool. Unix unlinks an
    // open file happily, so this used to work there, but Windows refuses to
    // delete a file that still has a handle open (`ERROR_SHARING_VIOLATION`),
    // which made "delete database file" fail on every Windows build. Closing
    // first is correct on both platforms: nothing may keep writing to a file
    // that is about to disappear.
    state.pools.evict(&active.spec).await;
    let mut deleted: Vec<String> = Vec::new();
    for path in targets {
        let file = Path::new(&path);
        if file.exists() {
            std::fs::remove_file(file).map_err(|e| {
                AppError::BadRequest(format!("删除数据库文件失败 {}：{e}", file.display()))
            })?;
        }
        // Sidecars belong to the database; leaving them behind would make a
        // later file with the same name inherit stale WAL/journal content.
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = PathBuf::from(format!("{}{}", path, suffix));
            if sidecar.exists() {
                let _ = std::fs::remove_file(sidecar);
            }
        }
        deleted.push(path);
    }
    // Rebuild the pool from the refreshed record so the attached set matches
    // disk again (the deleted file is no longer scanned or attached).
    if let Err(e) = state.refresh_active().await {
        tracing::warn!("sqlite delete refresh failed: {e}");
    }
    Ok(json!({ "ok": true, "deleted": deleted }))
}
