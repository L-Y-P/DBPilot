//! Desktop-only file helpers.
//!
//! The web build never touched the local filesystem except for its own data
//! files; a desktop app must read SQL files for import and write exports and
//! backups wherever the user chooses. Dart owns the file dialogs; these
//! functions do the actual I/O so the atomic-write and 0600 guarantees from
//! `secure` apply to user-visible files too.

use serde_json::{json, Value};

use super::{parse, state};
use crate::error::AppError;

/// Upper bound for one imported SQL file.
///
/// `import_sql` already enforces 64 MiB, but the file was read in full before
/// that check, so a 10 GB path could exhaust memory first. The limit is applied
/// here, at the read boundary.
const MAX_IMPORT_BYTES: u64 = 64 * 1024 * 1024;

/// Read a UTF-8 text file. Used by the SQL import tab and the restore flow.
pub fn read_text_file(path: String) -> anyhow::Result<String> {
    let path = path.trim();
    if path.is_empty() {
        return Err(AppError::bad("请选择文件").into());
    }
    let meta = std::fs::metadata(path).map_err(|e| AppError::bad(format!("无法读取文件: {e}")))?;
    if !meta.is_file() {
        return Err(AppError::bad("选择的路径不是文件").into());
    }
    if meta.len() > MAX_IMPORT_BYTES {
        return Err(AppError::bad(format!(
            "文件过大：{} 字节，导入上限为 {} MiB",
            meta.len(),
            MAX_IMPORT_BYTES / 1024 / 1024
        ))
        .into());
    }
    let bytes = std::fs::read(path).map_err(|e| AppError::bad(format!("无法读取文件: {e}")))?;
    String::from_utf8(bytes)
        .map_err(|_| anyhow::Error::from(AppError::bad("文件不是 UTF-8 文本")))
}

/// Write a UTF-8 text file atomically, creating parent directories.
/// Returns the absolute path that was written.
pub fn write_text_file(path: String, content: String) -> anyhow::Result<String> {
    let path = path.trim();
    if path.is_empty() {
        return Err(AppError::bad("请选择保存位置").into());
    }
    if let Some(parent) = std::path::Path::new(path).parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)
                .map_err(|e| AppError::Internal(format!("无法创建目录: {e}")))?;
        }
    }
    crate::secure::write_private(std::path::Path::new(path), &content)
        .map_err(|e| AppError::Internal(format!("无法写入文件: {e}")))?;
    Ok(path.to_string())
}

/// Directory the app stores its own files in, for the "open data folder" action.
pub fn data_dir() -> anyhow::Result<Value> {
    let state = state()?;
    Ok(json!({
        "data_dir": state.config.data_dir.to_string_lossy(),
        "connections_file": state.config.connections_file.to_string_lossy(),
        "history_file": state.config.history_file.to_string_lossy(),
        "settings_file": state.config.settings_file.to_string_lossy(),
        "backup_dir": state.effective_backup_dir().to_string_lossy(),
    }))
}

/// Absolute path of one backup file, so the desktop shell can open or save it.
pub async fn backup_path(id: String) -> anyhow::Result<Value> {
    let state = state()?;
    let meta = state
        .backups
        .get(&id)
        .await
        .ok_or_else(|| AppError::not_found("备份不存在"))?;
    // The store knows which directory is in force; the config only knows the
    // default, so joining that one would point at the wrong file after the
    // user moved their backups.
    let path = state.backups.dir().await.join(&meta.file);
    Ok(json!({ "path": path.to_string_lossy(), "backup": meta }))
}

/// Persist a settings patch sent as a JSON object.
pub async fn save_window_state(body: Value) -> anyhow::Result<Value> {
    #[derive(serde::Deserialize)]
    struct Patch {
        #[serde(default)]
        width: Option<f64>,
        #[serde(default)]
        height: Option<f64>,
        #[serde(default)]
        x: Option<f64>,
        #[serde(default)]
        y: Option<f64>,
        #[serde(default)]
        maximized: Option<bool>,
    }
    let state = state()?;
    let patch: Patch = parse("window", body)?;
    let mut settings = state.settings();
    if let Some(v) = patch.width {
        settings.window.width = v;
    }
    if let Some(v) = patch.height {
        settings.window.height = v;
    }
    if let Some(v) = patch.x {
        settings.window.x = Some(v);
    }
    if let Some(v) = patch.y {
        settings.window.y = Some(v);
    }
    if let Some(v) = patch.maximized {
        settings.window.maximized = v;
    }
    let saved = state.update_settings(settings).await?;
    Ok(serde_json::to_value(saved.window).unwrap_or(Value::Null))
}

// ------------------------------------------------- 数据与卸载（用户数据清理）

/// 清空用户数据所需的确认短语。
///
/// 单独成常量而不是字面量：Dart 需要把它展示给用户照抄，测试也要断言大小写
/// 不敏感，三处必须同源。
const WIPE_CONFIRM_TOKEN: &str = "DELETE-USER-DATA";

/// 数据目录，供盘点/清空使用。
///
/// 面板要在 `initApp` 成功之前也能打开（用户可能正打算卸载），所以取不到全局
/// 状态时退回平台默认目录，而不是像其它接口那样直接报"应用尚未初始化"。
fn panel_data_dir() -> std::path::PathBuf {
    match state() {
        Ok(state) => state.config.data_dir.clone(),
        Err(_) => crate::config::default_data_dir(),
    }
}

/// 「数据与卸载」面板用的数据目录盘点。
///
/// 返回字段：
/// * `path` / `exists`：数据目录及是否已创建；
/// * `total_bytes` / `file_count`：整目录占用与文件数（符号链接不计入）；
/// * `files: [{name, path, bytes, count, kind}]`：顶层子项，按体积降序，
///   `kind` 为 `"file"` 或 `"dir"`；
/// * `contains_secrets`：是否仍存在 connections/settings/history 等敏感文件。
pub fn data_dir_summary() -> anyhow::Result<Value> {
    Ok(crate::uninstall::overview_json(&panel_data_dir()))
}

/// 清空用户数据目录（卸载/重置前置动作）。
///
/// `confirm` 必须与 [`WIPE_CONFIRM_TOKEN`] 完整相等（忽略大小写），否则返回
/// 错误且一个文件都不动。成功后返回 `{"ok": true, "removed_bytes": N, "path": ...}`。
///
/// 刻意**不重置**全局 `STATE`：连接池、备份索引与内存中的设置都还指着刚被删掉
/// 的文件，在这里顺手清理只会留下一个半初始化的状态。重启应用由 Dart 侧提示。
/// 全函数没有任何 `unwrap`/`panic!` 路径，失败一律走 `AppError`。
pub async fn wipe_user_data(confirm: String) -> anyhow::Result<Value> {
    let dir = panel_data_dir();
    // 体积必须在删除前统计：删完只剩空目录，回报不了"释放了多少"。
    let removed_bytes = crate::uninstall::data_dir_bytes(&dir);
    crate::uninstall::wipe_data_dir(&dir, &confirm, WIPE_CONFIRM_TOKEN).map_err(AppError::bad)?;
    Ok(json!({
        "ok": true,
        "removed_bytes": removed_bytes,
        "path": dir.to_string_lossy(),
    }))
}

