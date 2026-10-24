//! flutter_rust_bridge surface.
//!
//! Every former HTTP handler lives here as a plain async function. The web
//! build returned `serde_json::Value` from each handler; that shape is kept
//! verbatim so the Flutter code can consume exactly the same payloads the Vue
//! app did, and so the ported backend logic did not have to be rewritten.
//!
//! Conventions:
//! * functions that take structured input accept a `serde_json::Value` and
//!   deserialize it into the same request struct the HTTP layer used;
//! * functions return `serde_json::Value` matching the old response body;
//! * errors travel as `anyhow::Error`, whose message is the user-facing
//!   Chinese/English text the API used to put in the `error` field.

pub mod backup;
pub mod connections;
pub mod data_import;
pub mod explorer;
pub mod export;
pub mod files;
pub mod query;
pub mod query_types;
pub mod raw_buffer;
pub mod server;
pub mod sqlite;
pub mod sync;

use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use serde_json::{json, Value};

use crate::config::DesktopConfig;
use crate::error::{AppError, AppResult};
use crate::state::AppState;

static STATE: OnceLock<Arc<AppState>> = OnceLock::new();

/// The initialized application state, or an error if the Dart side forgot to
/// call `init_app`. Returning an error rather than panicking keeps a misuse
/// from tearing down the whole process.
pub(crate) fn state() -> AppResult<Arc<AppState>> {
    STATE
        .get()
        .cloned()
        .ok_or_else(|| AppError::Internal("应用尚未初始化，请先调用 initApp".to_string()))
}

/// Deserialize a bridge argument into the request struct the HTTP handler used.
///
/// The error names the argument so a malformed call from Dart is diagnosable
/// instead of silently producing defaults.
pub(crate) fn parse<T: serde::de::DeserializeOwned>(label: &str, value: Value) -> AppResult<T> {
    serde_json::from_value(value)
        .map_err(|e| AppError::bad(format!("参数 {} 无效: {e}", label)))
}


// ------------------------------------------------------------- shared SQL helpers

/// Strip leading whitespace and line / hash / block comments from a statement.
///
/// Statement splitting keeps comments attached to the following statement, so a
/// commented USE directive must be recognised by looking through them.
pub(crate) fn strip_leading_comments(mut text: &str) -> &str {
    loop {
        let trimmed = text.trim_start();
        if let Some(rest) = trimmed.strip_prefix("--") {
            match rest.find('\n') {
                Some(index) => {
                    text = &rest[index + 1..];
                    continue;
                }
                None => return "",
            }
        }
        if let Some(rest) = trimmed.strip_prefix("/*") {
            match rest.find("*/") {
                Some(index) => {
                    text = &rest[index + 2..];
                    continue;
                }
                None => return "",
            }
        }
        if let Some(rest) = trimmed.strip_prefix('#') {
            match rest.find('\n') {
                Some(index) => {
                    text = &rest[index + 1..];
                    continue;
                }
                None => return "",
            }
        }
        return trimmed;
    }
}

/// If a statement is a USE <name> directive, return the bare database name.
///
/// USE is never executed as SQL by the desktop backend: it is handled as a
/// validated database switch so it cannot bypass the connection's only_db /
/// hide_db visibility boundary (the old code rejected it outright, which broke
/// the natural USE db; prelude). Returns None for ordinary statements.
pub(crate) fn use_statement_target(statement: &str) -> Option<String> {
    let trimmed = strip_leading_comments(statement)
        .trim()
        .trim_end_matches(';')
        .trim();
    let lower = trimmed.to_ascii_lowercase();
    let rest = if lower == "use" {
        ""
    } else if lower.starts_with("use ")
        || lower.starts_with("use\t")
        || lower.starts_with("use\r")
        || lower.starts_with("use\n")
    {
        trimmed.get(3..).unwrap_or("")
    } else {
        return None;
    };
    let mut name = rest.trim();
    name = name.trim_matches('\u{60}').trim_matches('"').trim();
    Some(name.to_string())
}

/// Validate and apply one USE <database> directive.
///
/// MySQL: the target must pass the connection's visibility rules and be
/// reachable; the active database records the switch (so the UI picker and tree
/// stay in sync). PostgreSQL / SQLite have no USE statement, so they return a
/// driver-specific hint instead of forwarding the raw SQL.
pub(crate) async fn switch_database_for_use(state: &AppState, name: &str) -> AppResult<()> {
    let name = name.trim();
    if name.is_empty() {
        return Err(AppError::bad("USE 后面需要数据库名"));
    }
    let active = state.active().await?;
    let driver = state.driver(&active.driver_id)?;
    // 「有没有 USE」是方言能力，不支持时的提示语也由方言给出，
    // api 不再 match 具体驱动。
    if !driver.supports(crate::core::dialect::DialectCapability::UseStatement) {
        return Err(AppError::bad(driver.dialect().use_statement_hint()));
    }
    active.ensure_visible(name)?;
    let handle = state.connection_for_database(name).await?;
    driver.ping(&handle).await?;
    state.set_active_database(Some(name.to_string())).await;
    Ok(())
}

/// Initialize the Rust core. `data_dir` comes from Dart's `path_provider`
/// so the Rust side never has to guess a platform-specific location; when it
/// is empty the built-in per-platform default is used instead.
///
/// Safe to call more than once: the first call wins and later calls are a
/// no-op, which matters because Flutter may rebuild the root widget.
#[flutter_rust_bridge::frb(sync)]
pub fn init_app(data_dir: String) -> Value {
    let dir = if data_dir.trim().is_empty() {
        crate::config::default_data_dir()
    } else {
        PathBuf::from(data_dir.trim())
    };
    let config = DesktopConfig::new(dir);
    if STATE.get().is_none() {
        if let Err(e) = config.prepare() {
            return json!({ "ok": false, "error": e.to_string() });
        }
        let _ = STATE.set(AppState::new(config));
    }
    match STATE.get() {
        Some(state) => json!({
            "ok": true,
            "data_dir": state.config.data_dir.to_string_lossy(),
            "connections_file": state.config.connections_file.to_string_lossy(),
            "backup_dir": state.effective_backup_dir().to_string_lossy(),
        }),
        None => json!({ "ok": false, "error": "初始化失败" }),
    }
}

/// Core crate version, shown in the About area and used by the smoke test.
#[flutter_rust_bridge::frb(sync)]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Static description of the app for the shell header.
pub fn app_config() -> anyhow::Result<Value> {
    let state = state()?;
    let settings = state.settings();
    Ok(json!({
        "title": state.config.title,
        "version": env!("CARGO_PKG_VERSION"),
        "data_dir": state.config.data_dir.to_string_lossy(),
        // The effective backup directory, not necessarily the default one.
        "backup_dir": state.effective_backup_dir().to_string_lossy(),
        "theme": settings.theme,
        "theme_color": settings.theme_color,
        "language": settings.language,
        "update_url": settings.update_url,
        "drivers": driver_options(),
    }))
}

/// Driver metadata, mirroring the web `/api/config` driver list so the
/// connection editor keeps working unchanged.
#[flutter_rust_bridge::frb(sync)]
pub fn driver_options() -> Value {
    // 已初始化：直接读注册表（新增驱动自动出现在表单里）。
    if let Ok(state) = state() {
        return crate::core::registry::driver_options_json(&state.driver_registry);
    }
    // 未初始化（Dart 在 initApp 之前调用）：返回内置驱动的静态元数据，
    // 与注册表用的是同一份 DriverMetadata。
    crate::drivers::builtin::builtin_options_json()
}

/// Current user preferences.
pub async fn get_settings() -> anyhow::Result<Value> {
    let state = state()?;
    let settings = state.settings();
    Ok(serde_json::to_value(settings).unwrap_or(Value::Null))
}

/// Persist user preferences and return the sanitized result.
///
/// A changed `backup_dir` is picked up here too: `AppState::update_settings`
/// reloads the backup store against the effective directory, so no extra FFI
/// function (and no restart) is needed.
pub async fn save_settings(settings: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let parsed: crate::config::Settings = parse("settings", settings)?;
    let saved = state.update_settings(parsed).await?;
    Ok(serde_json::to_value(saved).unwrap_or(Value::Null))
}
