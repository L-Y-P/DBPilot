use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;
use uuid::Uuid;

use crate::error::{AppError, AppResult};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BackupMeta {
    pub id: String,
    pub file: String,
    pub driver: String,
    pub database: String,
    /// Physical database of a PostgreSQL backup (the schema is `database`).
    ///
    /// Older backups written before instance-level PostgreSQL connections do
    /// not have this field; they restore against the currently active database.
    #[serde(default)]
    pub server_database: Option<String>,
    #[serde(default)]
    pub table: Option<String>,
    pub created_at: String,
    /// Retained so indexes written by the web build still deserialize.
    #[serde(default)]
    pub created_by: String,
    pub size: u64,
}


/// Turn a database/table name into one portable file-name component.
///
/// The value comes from the database (or the user) and is embedded in a backup
/// file name, so it must be legal on every platform the app ships on. Replacing
/// only `/`, `\\` and spaces was enough on Unix but leaves characters Windows
/// rejects (`: * ? " < > |`), trailing dots/spaces (silently trimmed by Win32,
/// which makes the written name differ from the recorded one), and the reserved
/// device names (`CON`, `NUL`, `COM1`, ...) that cannot be created at all.
/// Everything else is preserved so the name stays recognisable.
fn safe_file_component(raw: &str) -> String {
    const RESERVED: [&str; 22] = [
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6",
        "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6",
        "LPT7", "LPT8", "LPT9",
    ];
    let mut out = String::with_capacity(raw.len());
    for c in raw.chars() {
        let replace = matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|')
            || c.is_control();
        if replace {
            // Collapse runs of replaced characters into one underscore.
            if !out.ends_with('_') {
                out.push('_');
            }
        } else {
            out.push(c);
        }
    }
    // Windows drops trailing dots and spaces from a path component.
    let trimmed = out.trim_end_matches(['.', ' ']).to_string();
    if trimmed.is_empty() {
        return "_".to_string();
    }
    // A reserved device name is rejected with or without an extension.
    let stem = trimmed.split('.').next().unwrap_or("").to_ascii_uppercase();
    if RESERVED.contains(&stem.as_str()) {
        return format!("{}_", trimmed);
    }
    trimmed
}

/// Read and parse one `index.json`; anything unreadable means "no backups".
fn read_index(dir: &std::path::Path) -> Vec<BackupMeta> {
    std::fs::read_to_string(dir.join("index.json"))
        .ok()
        .and_then(|text| serde_json::from_str::<Vec<BackupMeta>>(&text).ok())
        .unwrap_or_default()
}

#[derive(Clone)]
pub struct BackupStore {
    /// The active directory, behind a lock because the settings dialog can
    /// point the store at another directory while the app is running.
    dir: Arc<RwLock<PathBuf>>,
    inner: Arc<RwLock<Vec<BackupMeta>>>,
}

impl BackupStore {
    pub fn load(dir: PathBuf) -> Self {
        let entries = read_index(&dir);
        // Dumps contain real table data: keep the directory and index private.
        let _ = crate::secure::ensure_private_dir(&dir);
        crate::secure::harden_file(&dir.join("index.json"));
        Self {
            dir: Arc::new(RwLock::new(dir)),
            inner: Arc::new(RwLock::new(entries)),
        }
    }

    /// The backup directory currently in force.
    pub async fn dir(&self) -> PathBuf {
        self.dir.read().await.clone()
    }

    /// Point the store at another directory at runtime.
    ///
    /// The index is reloaded from the new directory (a missing or unreadable
    /// `index.json` means "no backups"), so listings and new dumps follow a
    /// settings change without restarting the app. Files in the previous
    /// directory are left alone: the user may switch back to them.
    pub async fn set_dir(&self, dir: PathBuf) -> AppResult<()> {
        crate::secure::ensure_private_dir(&dir)
            .map_err(|e| AppError::Internal(format!("无法创建备份目录: {e}")))?;
        let entries = read_index(&dir);
        crate::secure::harden_file(&dir.join("index.json"));
        *self.dir.write().await = dir;
        *self.inner.write().await = entries;
        Ok(())
    }

    pub async fn list(&self) -> Vec<BackupMeta> {
        let mut items = self.inner.read().await.clone();
        items.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        items
    }

    pub async fn get(&self, id: &str) -> Option<BackupMeta> {
        self.inner.read().await.iter().find(|b| b.id == id).cloned()
    }

    pub async fn create(
        &self,
        driver: &str,
        database: &str,
        table: Option<&str>,
        content: String,
        server_database: Option<&str>,
    ) -> AppResult<BackupMeta> {
        let dir = self.dir.read().await.clone();
        let stamp = Utc::now().format("%Y%m%d-%H%M%S").to_string();
        let id = format!("bk-{}", Uuid::new_v4().simple());
        // The name becomes a real file on disk, so it has to be legal on every
        // platform: `/`, `\` and spaces were already replaced, and the rest of
        // the Windows-invalid set (`:` `*` `?` `"` `<` `>` `|`, control
        // characters) plus the reserved device names (CON, PRN, AUX, NUL,
        // COM1-9, LPT1-9) would otherwise make the backup write fail there.
        let safe_db = safe_file_component(database);
        let file_name = match table {
            Some(t) => format!("{}-{}-{}-{}.sql", stamp, driver, safe_db, safe_file_component(t)),
            None => format!("{}-{}-{}.sql", stamp, driver, safe_db),
        };
        let path = dir.join(&file_name);
        crate::secure::write_private(&path, &content)
            .map_err(|e| AppError::Internal(format!("无法写入备份文件: {e}")))?;
        let meta = BackupMeta {
            id,
            file: file_name,
            driver: driver.to_string(),
            database: database.to_string(),
            server_database: server_database.map(str::to_string),
            table: table.map(|t| t.to_string()),
            created_at: Utc::now().to_rfc3339(),
            created_by: "local".to_string(),
            size: content.len() as u64,
        };
        let mut guard = self.inner.write().await;
        guard.push(meta.clone());
        guard.sort_by(|a, b| b.created_at.cmp(&a.created_at));
        if guard.len() > 200 {
            let dropped: Vec<BackupMeta> = guard.split_off(200);
            for d in dropped {
                let _ = std::fs::remove_file(dir.join(&d.file));
            }
        }
        persist(&dir.join("index.json"), &guard).await?;
        Ok(meta)
    }

    pub async fn read(&self, id: &str) -> AppResult<(BackupMeta, String)> {
        let dir = self.dir.read().await.clone();
        let meta = self
            .get(id)
            .await
            .ok_or_else(|| AppError::not_found("备份不存在"))?;
        let content = std::fs::read_to_string(dir.join(&meta.file))
            .map_err(|e| AppError::Internal(format!("无法读取备份文件: {e}")))?;
        Ok((meta, content))
    }

    pub async fn remove(&self, id: &str) -> AppResult<bool> {
        let dir = self.dir.read().await.clone();
        let mut guard = self.inner.write().await;
        match guard.iter().position(|b| b.id == id) {
            Some(i) => {
                let meta = guard.remove(i);
                let _ = std::fs::remove_file(dir.join(&meta.file));
                persist(&dir.join("index.json"), &guard).await?;
                Ok(true)
            }
            None => Ok(false),
        }
    }
}

async fn persist(path: &PathBuf, items: &[BackupMeta]) -> AppResult<()> {
    let json = serde_json::to_string_pretty(items).map_err(|e| AppError::Internal(e.to_string()))?;
    crate::secure::write_private(path, &json)
        .map_err(|e| AppError::Internal(format!("无法保存备份索引: {e}")))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{safe_file_component, BackupStore};
    use std::path::PathBuf;

    /// A fresh, unique directory per test; the caller creates subdirectories.
    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "rma-backups-{tag}-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4().simple()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[tokio::test]
    async fn set_dir_reloads_the_index_and_redirects_writes() {
        let root = temp_dir("switch");
        let old_dir = root.join("old");
        let new_dir = root.join("new");

        let store = BackupStore::load(old_dir.clone());
        let old = store
            .create("sqlite", "main", None, "SELECT 1;".into(), None)
            .await
            .expect("create in the default directory");
        assert!(old_dir.join(&old.file).exists());
        assert_eq!(store.list().await.len(), 1);

        // A second store seeds the new directory with a different backup, the
        // way a previously used custom directory would already hold dumps.
        let other = BackupStore::load(new_dir.clone());
        let fresh = other
            .create("sqlite", "other", None, "SELECT 2;".into(), None)
            .await
            .expect("create in the target directory");

        store.set_dir(new_dir.clone()).await.expect("switch directory");
        assert_eq!(store.dir().await, new_dir);

        // list() reflects only the new directory...
        let listed = store.list().await;
        assert_eq!(listed.len(), 1, "{listed:?}");
        assert_eq!(listed[0].id, fresh.id);
        assert_eq!(listed[0].database, "other");
        // ...the old entry is no longer addressable, though its file survives.
        assert!(store.get(&old.id).await.is_none());
        assert!(
            old_dir.join(&old.file).exists(),
            "switching directories must not delete the old files"
        );

        // create() writes into the directory now in force.
        let third = store
            .create("sqlite", "third", None, "SELECT 3;".into(), None)
            .await
            .expect("create after switching");
        assert!(new_dir.join(&third.file).exists());
        assert!(!old_dir.join(&third.file).exists());
        assert_eq!(store.list().await.len(), 2);

        // The reloaded index was extended in the new directory, not the old one.
        let index: Vec<serde_json::Value> =
            serde_json::from_str(&std::fs::read_to_string(new_dir.join("index.json")).unwrap())
                .unwrap();
        assert_eq!(index.len(), 2);
        let old_index: Vec<serde_json::Value> =
            serde_json::from_str(&std::fs::read_to_string(old_dir.join("index.json")).unwrap())
                .unwrap();
        assert_eq!(old_index.len(), 1);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[tokio::test]
    async fn set_dir_creates_a_missing_directory_and_starts_empty() {
        let root = temp_dir("missing");
        let target = root.join("deep").join("dumps");

        let store = BackupStore::load(root.join("initial"));
        store.set_dir(target.clone()).await.expect("switch directory");

        assert!(target.is_dir(), "set_dir must create the directory");
        assert!(store.list().await.is_empty());
        assert_eq!(store.dir().await, target);
        assert!(store.get("missing").await.is_none());
        assert!(store.read("missing").await.is_err());

        let _ = std::fs::remove_dir_all(&root);
    }

    #[tokio::test]
    async fn set_dir_survives_a_corrupt_index() {
        // The index is written atomically, but the directory is user visible
        // and can be edited by hand: a broken file must degrade to "no
        // backups" instead of failing the switch.
        let root = temp_dir("corrupt");
        let dir = root.join("dumps");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("index.json"), "{not json").unwrap();

        let store = BackupStore::load(root.join("initial"));
        store.set_dir(dir.clone()).await.expect("switch directory");
        assert!(store.list().await.is_empty());
        assert!(dir.join("index.json").exists());

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn backup_file_names_are_legal_on_every_platform() {
        // Unix separators and spaces were already replaced; the Windows-only
        // illegal characters must be too, or the backup write fails there.
        assert_eq!(safe_file_component("a/b"), "a_b");
        assert_eq!(safe_file_component("a\\b"), "a_b");
        assert_eq!(safe_file_component("a b"), "a b");
        assert_eq!(safe_file_component("a:b*c?d\"e<f>g|h"), "a_b_c_d_e_f_g_h");
        // Runs collapse so the name does not fill with underscores.
        assert_eq!(safe_file_component("a:::b"), "a_b");
        // A tab is a control character.
        assert_eq!(safe_file_component("a\tb"), "a_b");
    }

    #[test]
    fn windows_reserved_device_names_get_a_suffix() {
        // Win32 refuses to create `CON.sql`, with or without an extension.
        for reserved in ["CON", "con", "PRN", "AUX", "NUL", "COM1", "LPT9"] {
            let safe = safe_file_component(reserved);
            assert_ne!(safe, reserved, "{reserved} must be changed");
            assert!(safe.ends_with('_'), "{safe} should end with an underscore");
        }
        // A name that merely starts with a reserved word is fine.
        assert_eq!(safe_file_component("CONSOLE"), "CONSOLE");
    }

    #[test]
    fn trailing_dots_and_spaces_are_stripped() {
        // Win32 silently trims these, so the written file would not match the
        // name recorded in the index.
        assert_eq!(safe_file_component("db."), "db");
        assert_eq!(safe_file_component("db "), "db");
        assert_eq!(safe_file_component("db. . "), "db");
        // An empty result would be an unnamed file: fall back to a placeholder.
        assert_eq!(safe_file_component("..."), "_");
        assert_eq!(safe_file_component(""), "_");
    }
}
