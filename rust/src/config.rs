//! Desktop configuration: platform-native data directories and user settings.
//!
//! The web build read `config.json` from the working directory and kept an
//! HTTP session per browser. A desktop process is single-user, so all of that
//! collapses into: one data directory, one settings file, and one "current
//! connection" slot. Credentials still live in `connections.json` written
//! 0600 atomically through `crate::secure`.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::connections::ConnEntry;
use crate::error::{AppError, AppResult};

fn default_title() -> String {
    "DBPilot".to_string()
}
fn default_theme() -> String {
    "system".to_string()
}
/// Palette names the settings dialog offers. Kept in sync with the Dart palette.
const THEME_COLORS: [&str; 6] = ["default", "indigo", "teal", "forest", "rose", "violet"];

fn default_theme_color() -> String {
    "default".to_string()
}
fn default_language() -> String {
    "zh".to_string()
}
fn default_page_size() -> u32 {
    50
}
/// Performance toggles default to ON: the app is faster out of the box, and an
/// old settings.json without these keys keeps that behaviour.
fn default_true() -> bool {
    true
}
fn default_window_width() -> f64 {
    1440.0
}
fn default_window_height() -> f64 {
    900.0
}

/// Window geometry remembered between runs.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WindowState {
    #[serde(default = "default_window_width")]
    pub width: f64,
    #[serde(default = "default_window_height")]
    pub height: f64,
    #[serde(default)]
    pub x: Option<f64>,
    #[serde(default)]
    pub y: Option<f64>,
    #[serde(default)]
    pub maximized: bool,
}

impl Default for WindowState {
    fn default() -> Self {
        WindowState {
            width: default_window_width(),
            height: default_window_height(),
            x: None,
            y: None,
            maximized: false,
        }
    }
}

/// Everything the desktop app remembers about the user's preferences.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Settings {
    #[serde(default = "default_theme")]
    pub theme: String,
    /// Accent palette; one of THEME_COLORS, else "default".
    #[serde(default = "default_theme_color")]
    pub theme_color: String,
    #[serde(default = "default_language")]
    pub language: String,
    #[serde(default = "default_page_size")]
    pub page_size: u32,
    #[serde(default)]
    pub last_connection_id: Option<String>,
    /// User-chosen directory for database dumps. None means the default
    /// directory inside the data dir (data_dir/backups).
    #[serde(default)]
    pub backup_dir: Option<String>,
    /// Base URL of the release feed used by the update check. Empty disables it.
    #[serde(default)]
    pub update_url: String,
    /// Measure column widths from the data (off = fixed width, much cheaper on
    /// wide tables).
    #[serde(default = "default_true")]
    pub auto_column_width: bool,
    /// Render long cell values as a placeholder until the user asks for the
    /// full text.
    #[serde(default = "default_true")]
    pub lazy_big_fields: bool,
    #[serde(default)]
    pub window: WindowState,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            theme: default_theme(),
            theme_color: default_theme_color(),
            language: default_language(),
            page_size: default_page_size(),
            last_connection_id: None,
            backup_dir: None,
            update_url: String::new(),
            auto_column_width: default_true(),
            lazy_big_fields: default_true(),
            window: WindowState::default(),
        }
    }
}

impl Settings {
    /// Clamp values that the UI relies on being sane, so a hand-edited
    /// settings file cannot make the app render an unusable window.
    fn sanitize(&mut self) {
        if !matches!(self.theme.as_str(), "light" | "dark" | "system") {
            self.theme = default_theme();
        }
        let theme_color = self.theme_color.trim();
        self.theme_color = if THEME_COLORS.contains(&theme_color) {
            theme_color.to_string()
        } else {
            default_theme_color()
        };
        if !matches!(self.language.as_str(), "zh" | "en") {
            self.language = default_language();
        }
        // A dump directory must be absolute: a relative one would resolve
        // against whatever working directory the app happened to start in.
        self.backup_dir = self
            .backup_dir
            .take()
            .map(|dir| dir.trim().to_string())
            .filter(|dir| !dir.is_empty() && Path::new(dir).is_absolute());
        // The update check only ever speaks plain HTTP(S): anything else
        // (file://, a bare host, javascript:) is dropped instead of fetched.
        let update_url = self.update_url.trim();
        self.update_url = if update_url.starts_with("http://") || update_url.starts_with("https://")
        {
            update_url.to_string()
        } else {
            String::new()
        };
        self.page_size = self.page_size.clamp(1, 1000);
        self.window.width = self.window.width.clamp(640.0, 20000.0);
        self.window.height = self.window.height.clamp(480.0, 20000.0);
        if self.window.width.is_nan() || self.window.height.is_nan() {
            self.window = WindowState::default();
        }
    }
}

/// Database visibility filtering with `%` and `_` wildcards.
///
/// `only_db` / `hide_db` come from a saved connection and are the desktop
/// app's only remaining authorization boundary, so this must stay strict:
/// a `None` `only_db` means "no allow-list restriction", not "allow nothing".
pub fn name_visible(only: Option<&str>, hide: Option<&str>, name: &str) -> bool {
    if let Some(only) = only {
        let matched = only.split(',').any(|d| {
            let d = d.trim();
            !d.is_empty() && (d == name || wildcard(d, name))
        });
        if !matched {
            return false;
        }
    }
    if let Some(hide) = hide {
        let matched = hide.split(',').any(|d| {
            let d = d.trim();
            !d.is_empty() && (d == name || wildcard(d, name))
        });
        if matched {
            return false;
        }
    }
    true
}

/// SQL-LIKE wildcard match supporting `%` (any run) and `_` (one char).
fn wildcard(pattern: &str, value: &str) -> bool {
    if !pattern.contains('%') && !pattern.contains('_') {
        return false;
    }
    let p: Vec<char> = pattern.chars().collect();
    let v: Vec<char> = value.chars().collect();
    let (mut pi, mut vi) = (0usize, 0usize);
    let (mut star, mut mark) = (None::<usize>, 0usize);
    while vi < v.len() {
        if pi < p.len() && (p[pi] == '_' || p[pi] == v[vi]) {
            pi += 1;
            vi += 1;
        } else if pi < p.len() && p[pi] == '%' {
            star = Some(pi);
            mark = vi;
            pi += 1;
        } else if let Some(s) = star {
            pi = s + 1;
            mark += 1;
            vi = mark;
        } else {
            return false;
        }
    }
    while pi < p.len() && p[pi] == '%' {
        pi += 1;
    }
    pi == p.len()
}

/// Resolve the per-user data directory for this platform without pulling in an
/// extra crate. Dart passes the authoritative path from `path_provider`; this
/// is the fallback used by tests and by a bare `cargo run`.
pub fn default_data_dir() -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        if let Some(home) = std::env::var_os("HOME") {
            return PathBuf::from(home)
                .join("Library")
                .join("Application Support")
                .join("DBPilot");
        }
    }
    #[cfg(target_os = "windows")]
    {
        if let Some(appdata) = std::env::var_os("APPDATA") {
            return PathBuf::from(appdata).join("DBPilot");
        }
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        if let Some(xdg) = std::env::var_os("XDG_DATA_HOME") {
            if !xdg.is_empty() {
                return PathBuf::from(xdg).join("rust-myadmin");
            }
        }
        if let Some(home) = std::env::var_os("HOME") {
            return PathBuf::from(home)
                .join(".local")
                .join("share")
                .join("rust-myadmin");
        }
    }
    std::env::temp_dir().join("rust-myadmin")
}

/// Resolved, absolute paths for every file the app persists.
#[derive(Clone, Debug)]
pub struct DesktopConfig {
    pub title: String,
    pub data_dir: PathBuf,
    pub connections_file: PathBuf,
    pub history_file: PathBuf,
    pub settings_file: PathBuf,
}

impl DesktopConfig {
    pub fn new(data_dir: PathBuf) -> Arc<DesktopConfig> {
        Arc::new(DesktopConfig {
            title: default_title(),
            connections_file: data_dir.join("connections.json"),
            history_file: data_dir.join("query_history.json"),
            settings_file: data_dir.join("settings.json"),
            data_dir,
        })
    }

    /// Where backups go when the user has not chosen a directory.
    pub fn default_backup_dir(&self) -> PathBuf {
        self.data_dir.join("backups")
    }

    /// The backup directory actually in force.
    ///
    /// The user's choice from `settings.backup_dir` when it is set (already
    /// validated as absolute by `Settings::sanitize`), otherwise the default
    /// directory inside the data dir.
    pub fn backup_dir_for(&self, settings: &Settings) -> PathBuf {
        settings
            .backup_dir
            .as_deref()
            .map(PathBuf::from)
            .unwrap_or_else(|| self.default_backup_dir())
    }

    /// Create the data directory tree with owner-only permissions.
    pub fn prepare(&self) -> AppResult<()> {
        crate::secure::ensure_private_dir(&self.data_dir)
            .map_err(|e| AppError::Internal(format!("无法创建数据目录: {e}")))?;
        crate::secure::ensure_private_dir(&self.default_backup_dir())
            .map_err(|e| AppError::Internal(format!("无法创建备份目录: {e}")))?;
        Ok(())
    }

    pub fn load_settings(&self) -> Settings {
        let mut settings = match std::fs::read_to_string(&self.settings_file) {
            Ok(text) => serde_json::from_str::<Settings>(&text).unwrap_or_default(),
            Err(_) => Settings::default(),
        };
        settings.sanitize();
        crate::secure::harden_file(&self.settings_file);
        settings
    }

    /// Persist settings, returning the sanitized value.
    ///
    /// The sanitized copy is returned rather than discarded so the in-memory
    /// state matches the file: previously a hand-edited value was clamped on
    /// disk but the live state kept the raw one until the next restart.
    pub fn save_settings(&self, settings: &Settings) -> AppResult<Settings> {
        let mut settings = settings.clone();
        settings.sanitize();
        let json = serde_json::to_string_pretty(&settings)
            .map_err(|e| AppError::Internal(e.to_string()))?;
        crate::secure::write_private(&self.settings_file, &json)
            .map_err(|e| AppError::Internal(format!("无法保存设置: {e}")))?;
        Ok(settings)
    }
}

/// Connections pre-populated on a brand-new install.
///
/// 故意返回空列表：预置 `root@127.0.0.1` / `postgres@127.0.0.1` 这类连接会带来三个问题 ——
///
/// 1. 用户没装对应数据库时，点这些条目只会得到「连接失败」，看起来像应用坏了；
/// 2. `root` / `postgres` 是超级用户账号，会让人误以为应用要求用管理员账号；
/// 3. 空密码的 root 连接在任何安全审计里都是红线。
///
/// 主流数据库客户端首次启动都是空列表 + 新建引导，这里保持一致。
///
/// 保留这个函数（而不是让调用方直接传 `Vec::new()`）有两个原因：
/// - `ConnectionStore::load` 的签名需要它，且将来若要重新提供示例数据只改一处；
/// - 现有单元测试与集成测试通过它构造「全新安装」场景。
pub fn seed_connections(_data_dir: &Path) -> Vec<ConnEntry> {
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    /// Deserialize + sanitize, the exact path `load_settings` takes.
    fn sanitized(raw: &str) -> Settings {
        let mut settings: Settings = serde_json::from_str(raw).expect("settings must deserialize");
        settings.sanitize();
        settings
    }

    #[test]
    fn old_settings_files_without_the_new_fields_still_load() {
        // A settings.json written by an older build has none of the fields the
        // new settings dialog offers; it must load with defaults rather than
        // making the whole file unreadable.
        let settings = sanitized(
            r#"{"theme":"dark","language":"en","page_size":25,"window":{"width":1200,"height":800}}"#,
        );
        assert_eq!(settings.theme, "dark");
        assert_eq!(settings.language, "en");
        assert_eq!(settings.page_size, 25);
        assert_eq!(settings.theme_color, "default");
        assert_eq!(settings.backup_dir, None);
        assert_eq!(settings.update_url, "");
        // Performance toggles were added in a later round: an older file has
        // neither key and must load with both switched on.
        assert!(settings.auto_column_width, "旧 settings.json 的自动列宽应默认为开");
        assert!(settings.lazy_big_fields, "旧 settings.json 的大字段延迟加载应默认为开");
    }

    #[test]
    fn performance_toggles_round_trip_and_can_be_switched_off() {
        let raw = serde_json::json!({
            "auto_column_width": false,
            "lazy_big_fields": false,
        });
        let settings = sanitized(&raw.to_string());
        assert!(!settings.auto_column_width);
        assert!(!settings.lazy_big_fields);

        // Serialized back out, the keys are present so the next launch keeps
        // the user's choice (and the Dart side can read them).
        let json = serde_json::to_value(&settings).expect("settings must serialize");
        assert_eq!(json.get("auto_column_width"), Some(&Value::Bool(false)));
        assert_eq!(json.get("lazy_big_fields"), Some(&Value::Bool(false)));

        // Defaults are on, both in Default::default() and in the file path.
        assert!(Settings::default().auto_column_width);
        assert!(Settings::default().lazy_big_fields);
    }

    #[test]
    fn theme_color_falls_back_to_default_unless_whitelisted() {
        for color in THEME_COLORS {
            assert_eq!(
                sanitized(&format!(r#"{{"theme_color":"{color}"}}"#)).theme_color,
                color
            );
        }
        // A padded value still matches the whitelist...
        assert_eq!(sanitized(r#"{"theme_color":"  teal  "}"#).theme_color, "teal");
        // ...but unknown names, wrong case, empties and injected values do not.
        for bad in ["neon", "Indigo", "", "   ", "default;evil"] {
            assert_eq!(
                sanitized(&format!(r#"{{"theme_color":"{bad}"}}"#)).theme_color,
                "default",
                "{bad} must fall back to the default palette"
            );
        }
    }

    #[test]
    fn backup_dir_must_be_absolute() {
        let abs = std::env::temp_dir().join("rma-dumps");
        let abs = abs.to_string_lossy().to_string();
        let kept = sanitized(&serde_json::json!({ "backup_dir": format!("  {abs}  ") }).to_string());
        assert_eq!(
            kept.backup_dir.as_deref(),
            Some(abs.as_str()),
            "an absolute directory is trimmed and kept"
        );

        for bad in ["", "   ", "backups", "relative/dumps", "./dumps"] {
            let settings = sanitized(&serde_json::json!({ "backup_dir": bad }).to_string());
            assert_eq!(settings.backup_dir, None, "{bad:?} must be rejected");
        }
    }

    #[test]
    fn update_url_only_accepts_plain_http_urls() {
        for good in [
            "https://example.com/releases.json",
            "http://127.0.0.1:8080/updates",
        ] {
            let settings = sanitized(&serde_json::json!({ "update_url": good }).to_string());
            assert_eq!(settings.update_url, good);
        }
        let padded = sanitized(r#"{"update_url":"  https://example.com/u.json  "}"#);
        assert_eq!(padded.update_url, "https://example.com/u.json");

        for bad in [
            "",
            "example.com/u.json",
            "ftp://example.com/u",
            "file:///etc/passwd",
            "HTTP://EXAMPLE.COM",
            "javascript:alert(1)",
        ] {
            let settings = sanitized(&serde_json::json!({ "update_url": bad }).to_string());
            assert_eq!(settings.update_url, "", "{bad} must be dropped");
        }
    }

    #[test]
    fn title_is_branded_and_defaults_are_sane() {
        assert_eq!(default_title(), "DBPilot");
        let settings = Settings::default();
        assert_eq!(settings.theme_color, "default");
        assert_eq!(settings.theme, "system");
        assert_eq!(settings.language, "zh");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_default_data_dir_uses_the_app_name() {
        if std::env::var_os("HOME").is_none() {
            return; // no HOME: the fallback temp dir is used instead.
        }
        assert_eq!(
            default_data_dir().file_name().and_then(|name| name.to_str()),
            Some("DBPilot")
        );
    }


    #[test]
    fn effective_backup_dir_prefers_the_configured_directory() {
        let config = DesktopConfig::new(std::env::temp_dir().join("rma-settings-test"));
        assert_eq!(config.default_backup_dir(), config.data_dir.join("backups"));
        assert_eq!(
            config.backup_dir_for(&Settings::default()),
            config.default_backup_dir()
        );

        let mut settings = Settings::default();
        settings.backup_dir = Some("/Volumes/dumps".to_string());
        assert_eq!(
            config.backup_dir_for(&settings),
            PathBuf::from("/Volumes/dumps")
        );
    }

    /// 全新安装不得预置任何数据库连接。
    ///
    /// 曾经这里会 seed `root@127.0.0.1:3306` 与 `postgres@127.0.0.1:5432`，
    /// 发布后被用户当成「应用里带了开发者的连接信息」。预置超级用户账号
    /// 既误导用户，也会在安全审计里被标红，所以锁定为空列表。
    #[test]
    fn brand_new_install_ships_no_connections() {
        let dir = std::env::temp_dir().join("rma-seed-test");
        let seeded = seed_connections(&dir);
        assert!(
            seeded.is_empty(),
            "全新安装不应预置任何连接，实际有 {} 条",
            seeded.len()
        );
    }
}

