use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::drivers::ConnSpec;
use crate::error::{AppError, AppResult};

/// A saved connection entry, the unit of multi-database management.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConnEntry {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(flatten)]
    pub spec: ConnSpec,
    #[serde(default)]
    pub only_db: Option<String>,
    #[serde(default)]
    pub hide_db: Option<String>,
    #[serde(default)]
    pub color: Option<String>,
}

impl ConnEntry {
    pub fn display_name(&self) -> String {
        if self.name.trim().is_empty() {
            format!("{}@{}", self.spec.driver.label(), self.spec.host)
        } else {
            self.name.clone()
        }
    }
}

#[derive(Clone)]
pub struct ConnectionStore {
    path: Arc<PathBuf>,
    inner: Arc<RwLock<Vec<ConnEntry>>>,
    /// Set when the file existed but could not be read/parsed at startup.
    /// The UI can surface this instead of silently showing an empty list.
    load_error: Option<Arc<str>>,
}

impl ConnectionStore {
    pub fn load(path: PathBuf, seed: Vec<ConnEntry>) -> Self {
        let mut load_error: Option<String> = None;
        let entries = match std::fs::read_to_string(&path) {
            Ok(text) => match serde_json::from_str::<Vec<ConnEntry>>(&text) {
                Ok(entries) => entries,
                Err(error) => {
                    // Never turn a broken file into an empty list: a subsequent
                    // save would destroy the user's connections (and passwords).
                    let message = format!(
                        "连接配置文件无法解析（{}）：{error}",
                        path.display()
                    );
                    tracing::warn!("{message}");
                    match preserve_corrupt_file(&path, &text) {
                        Some(backup) => {
                            load_error = Some(format!(
                                "{message}；原文件已原样保留为 {}",
                                backup.display()
                            ));
                            // The bad bytes are safe now, so starting from the
                            // seed (or an empty list) can be written back.
                            seed_or_empty(&path, seed)
                        }
                        None => {
                            // Without a preserved copy, do not overwrite the only
                            // record of the user's connections with the seed.
                            load_error = Some(format!(
                                "{message}；且原文件备份失败，本次不会覆盖该文件"
                            ));
                            seed
                        }
                    }
                }
            },
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                seed_or_empty(&path, seed)
            }
            Err(error) => {
                let message = format!("无法读取连接配置文件（{}）：{error}", path.display());
                tracing::warn!("{message}");
                load_error = Some(message);
                // Do not seed-write over a file we could not read: it may hold
                // the user's connections in a form we currently cannot see.
                seed
            }
        };
        // Files written by older builds were 0644; tighten them on startup.
        crate::secure::harden_file(&path);
        Self {
            path: Arc::new(path),
            inner: Arc::new(RwLock::new(entries)),
            load_error: load_error.map(Arc::from),
        }
    }

    /// Why the saved connections could not be loaded, if the file was corrupt.
    pub fn load_error(&self) -> Option<&str> {
        self.load_error.as_deref()
    }

    pub async fn list(&self) -> Vec<ConnEntry> {
        self.inner.read().await.clone()
    }

    pub async fn get(&self, id: &str) -> Option<ConnEntry> {
        self.inner.read().await.iter().find(|c| c.id == id).cloned()
    }

    pub async fn upsert(&self, mut entry: ConnEntry) -> AppResult<ConnEntry> {
        if entry.name.trim().is_empty() {
            entry.name = entry.display_name();
        }
        let mut guard = self.inner.write().await;
        // Persist before publishing the in-memory change. If the atomic write
        // fails (read-only profile, disk full), the caller gets an error and the
        // next list() must NOT show a connection that was never saved.
        let previous = guard.clone();
        if entry.id.trim().is_empty() {
            entry.id = format!("conn-{}", uuid::Uuid::new_v4().simple());
            guard.push(entry.clone());
        } else if let Some(existing) = guard.iter_mut().find(|c| c.id == entry.id) {
            *existing = entry.clone();
        } else {
            guard.push(entry.clone());
        }
        if let Err(error) = persist(&self.path, &guard).await {
            *guard = previous;
            return Err(error);
        }
        Ok(entry)
    }

    pub async fn remove(&self, id: &str) -> AppResult<bool> {
        let mut guard = self.inner.write().await;
        let previous = guard.clone();
        let before = guard.len();
        guard.retain(|c| c.id != id);
        let removed = guard.len() != before;
        if let Err(error) = persist(&self.path, &guard).await {
            *guard = previous;
            return Err(error);
        }
        Ok(removed)
    }

    pub async fn len(&self) -> usize {
        self.inner.read().await.len()
    }

    pub async fn is_empty(&self) -> bool {
        self.inner.read().await.is_empty()
    }
}

/// Write the seed (when non-empty) to the path; used when no file exists yet.
fn seed_or_empty(path: &Path, seed: Vec<ConnEntry>) -> Vec<ConnEntry> {
    if seed.is_empty() {
        return seed;
    }
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            let _ = std::fs::create_dir_all(parent);
        }
    }
    if let Ok(json) = serde_json::to_string_pretty(&seed) {
        // Holds credentials: never world-readable.
        let _ = crate::secure::write_private(path, &json);
    }
    seed
}

/// Keep the corrupt file around before it is replaced, so the user's data
/// (including plaintext passwords) can still be recovered by hand.
fn preserve_corrupt_file(path: &Path, text: &str) -> Option<PathBuf> {
    let file_name = path.file_name()?.to_string_lossy().to_string();
    let stamp = chrono::Utc::now().format("%Y%m%dT%H%M%SZ");
    let mut target = path.with_file_name(format!("{file_name}.corrupt-{stamp}.json"));
    // Two corrupt loads within the same second must not overwrite each other.
    for suffix in 1..=100 {
        if !target.exists() {
            break;
        }
        target = path.with_file_name(format!("{file_name}.corrupt-{stamp}-{suffix}.json"));
    }
    let preserved = std::fs::copy(path, &target).is_ok()
        || crate::secure::write_private(&target, text).is_ok();
    if preserved {
        crate::secure::set_file_mode(&target, 0o600);
        tracing::warn!("kept corrupt connections file as {}", target.display());
        Some(target)
    } else {
        tracing::error!(
            "could not preserve corrupt connections file {}",
            path.display()
        );
        None
    }
}

/// Copy the current file to connections.json.bak before it is replaced.
///
/// Only a file that still parses as a connection list is kept: overwriting a
/// good backup with a garbage file would defeat the purpose. The .bak name is
/// deliberately not a load candidate, so load() never picks it up.
fn backup_previous(path: &Path) {
    let Ok(previous) = std::fs::read_to_string(path) else {
        return; // First save: there is nothing to keep yet.
    };
    if serde_json::from_str::<Vec<ConnEntry>>(&previous).is_err() {
        tracing::warn!(
            "not backing up {}: previous contents are not valid JSON",
            path.display()
        );
        return;
    }
    let Some(file_name) = path.file_name() else {
        return;
    };
    let backup = path.with_file_name(format!("{}.bak", file_name.to_string_lossy()));
    if let Err(error) = crate::secure::write_private(&backup, &previous) {
        // Best effort: a missing backup must not block saving the new state.
        tracing::warn!("could not write {}: {error}", backup.display());
    }
}

async fn persist(path: &PathBuf, entries: &[ConnEntry]) -> AppResult<()> {
    let json = serde_json::to_string_pretty(entries).map_err(|e| AppError::Internal(e.to_string()))?;
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            let _ = std::fs::create_dir_all(parent);
        }
    }
    // One generation of undo before the atomic rename replaces the old file.
    backup_previous(path);
    // Connection passwords live here, so the file is written 0600 atomically.
    crate::secure::write_private(path, &json)
        .map_err(|e| AppError::Internal(format!("无法保存连接：{e}")))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn tolerates_explicit_nulls_in_ssh_fields() {
        // Older/third-party clients send nulls for unused SSH fields; a
        // flattened struct must not reject the whole connection because of it.
        let json = serde_json::json!({
            "name": "plain",
            "driver": "mysql",
            "ssh_host": "",
            "ssh_auth": null,
            "ssh_host_key_policy": null,
            "ssh_port": null
        });
        let entry: ConnEntry = serde_json::from_value(json).expect("parse with nulls");
        assert!(!entry.spec.ssh.enabled());
        assert_eq!(entry.spec.ssh.ssh_auth, crate::ssh::SshAuth::Password);
    }

    #[test]
    fn serialises_ssh_fields_back_into_the_flat_object() {
        let json = serde_json::json!({
            "name": "tunnel",
            "driver": "mysql",
            "ssh_host": "jump.internal",
            "ssh_auth": "keyfile",
            "ssh_host_key_policy": "strict"
        });
        let entry: ConnEntry = serde_json::from_value(json).expect("parse");
        let round = serde_json::to_value(&entry).expect("serialise");
        assert_eq!(round["ssh_host"], "jump.internal", "round trip: {round}");
        assert_eq!(round["ssh_auth"], "keyfile", "round trip: {round}");
        assert_eq!(round["ssh_host_key_policy"], "strict", "round trip: {round}");
    }

    #[test]
    fn parses_ssh_fields_from_the_flat_connection_object() {
        let json = serde_json::json!({
            "name": "tunnel",
            "driver": "mysql",
            "host": "db.internal",
            "ssh_host": "jump.internal",
            "ssh_port": 2222,
            "ssh_user": "deploy",
            "ssh_auth": "password",
            "ssh_host_key_policy": "strict"
        });
        let entry: ConnEntry = serde_json::from_value(json).expect("parse");
        assert_eq!(entry.spec.ssh.ssh_host, "jump.internal");
        assert_eq!(entry.spec.ssh.ssh_port, Some(2222));
        assert_eq!(entry.spec.ssh.ssh_user, "deploy");
        assert_eq!(entry.spec.ssh.ssh_auth, crate::ssh::SshAuth::Password);
        assert_eq!(
            entry.spec.ssh.ssh_host_key_policy,
            crate::ssh::SshHostKeyPolicy::Strict
        );
    }


    use crate::drivers::{ConnSpec, DriverKind};

    fn entry(id: &str, name: &str) -> ConnEntry {
        ConnEntry {
            id: id.to_string(),
            name: name.to_string(),
            spec: ConnSpec {
                driver: DriverKind::Sqlite,
                host: String::new(),
                port: None,
                user: String::new(),
                password: String::new(),
                // Any path works: these tests only persist and list the entry.
                database: Some(
                    std::env::temp_dir()
                        .join("x.sqlite")
                        .to_string_lossy()
                        .to_string(),
                ),
                charset: None,
                ssl_mode: None,
                ssl_verify: None,
                ssl_ca: None,
                ssl_cert: None,
                ssl_key: None,
                sqlite_dir: None,
                ssh: crate::ssh::SshSpec::default(),
            },
            only_db: None,
            hide_db: None,
            color: None,
        }
    }

    /// Using a directory as the JSON path makes the atomic write fail. The
    /// store must roll back its in-memory change, not show a phantom entry.
    fn failing_store(seed: Vec<ConnEntry>) -> (ConnectionStore, PathBuf) {
        let dir = std::env::temp_dir().join(format!(
            "rma-connection-store-test-{}",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&dir).expect("temp dir");
        (ConnectionStore::load(dir.clone(), seed), dir)
    }

    #[tokio::test]
    async fn failed_upsert_is_not_published() {
        let (store, dir) = failing_store(Vec::new());
        let error = store.upsert(entry("", "bad")).await.expect_err("write must fail");
        assert!(error.to_string().contains("无法保存连接"), "{error}");
        assert!(store.list().await.is_empty(), "failed upsert leaked into memory");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn failed_remove_keeps_the_entry() {
        let (store, dir) = failing_store(vec![entry("conn-x", "keep")]);
        let error = store.remove("conn-x").await.expect_err("write must fail");
        assert!(error.to_string().contains("无法保存连接"), "{error}");
        let entries = store.list().await;
        assert_eq!(entries.len(), 1, "failed remove leaked into memory");
        assert_eq!(entries[0].id, "conn-x");
        let _ = std::fs::remove_dir_all(dir);
    }

    fn store_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "rma-connection-store-test-{}",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&dir).expect("temp dir");
        dir
    }

    fn files_with_prefix(dir: &Path, prefix: &str) -> Vec<PathBuf> {
        let mut found: Vec<PathBuf> = std::fs::read_dir(dir)
            .expect("read dir")
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.path())
            .filter(|path| {
                path.file_name()
                    .map(|name| name.to_string_lossy().starts_with(prefix))
                    .unwrap_or(false)
            })
            .collect();
        found.sort();
        found
    }

    #[cfg(unix)]
    fn mode_of(path: &Path) -> u32 {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path)
            .expect("metadata")
            .permissions()
            .mode()
            & 0o777
    }

    /// A corrupt connections.json must never become an empty list that the next
    /// save writes over: the original bytes must survive in a .corrupt copy, the
    /// store must report the problem, and later saves must not destroy the copy.
    #[tokio::test]
    async fn corrupt_connections_file_is_preserved_not_silently_emptied() {
        let dir = store_dir();
        let path = dir.join("connections.json");
        // Truncated JSON, as if the process died in the middle of a save.
        let broken = r#"[{"name":"prod","driver":"mysql","password":"s3cret"},"#;
        std::fs::write(&path, broken).expect("write corrupt file");

        let store = ConnectionStore::load(path.clone(), Vec::new());
        assert!(
            store.load_error().is_some(),
            "a corrupt file must be reported, not hidden"
        );
        assert!(store.list().await.is_empty());

        let corrupt = files_with_prefix(&dir, "connections.json.corrupt-");
        assert_eq!(corrupt.len(), 1, "expected one preserved copy: {corrupt:?}");
        assert_eq!(
            std::fs::read_to_string(&corrupt[0]).expect("read copy"),
            broken,
            "the preserved copy must be byte-identical"
        );
        #[cfg(unix)]
        assert_eq!(
            mode_of(&corrupt[0]),
            0o600,
            "the preserved copy holds passwords and must be private"
        );

        // Saving now starts from an empty list; the user's data must still be
        // recoverable from the preserved copy afterwards.
        store.upsert(entry("", "fresh")).await.expect("save");
        assert_eq!(
            std::fs::read_to_string(&corrupt[0]).expect("read copy"),
            broken
        );
        let current = std::fs::read_to_string(&path).expect("read current");
        assert!(current.contains("fresh"), "new save missing: {current}");
        assert!(
            !current.contains("s3cret"),
            "corrupt content leaked into the new file: {current}"
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    /// With a seed available, a corrupt file still starts from the seed and the
    /// corrupt copy is kept next to the rewritten file.
    #[tokio::test]
    async fn corrupt_file_starts_from_seed_when_available() {
        let dir = store_dir();
        let path = dir.join("connections.json");
        std::fs::write(&path, "{not json").expect("write corrupt file");

        let store = ConnectionStore::load(path.clone(), vec![entry("seed-1", "seeded")]);
        assert!(store.load_error().is_some());
        let entries = store.list().await;
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].id, "seed-1");

        assert_eq!(files_with_prefix(&dir, "connections.json.corrupt-").len(), 1);
        let on_disk: Vec<ConnEntry> =
            serde_json::from_str(&std::fs::read_to_string(&path).expect("read"))
                .expect("rewritten file parses");
        assert_eq!(on_disk.len(), 1);
        let _ = std::fs::remove_dir_all(dir);
    }

    /// Every save keeps one generation of undo in connections.json.bak (0600),
    /// and that backup is never loaded as the live file.
    #[tokio::test]
    async fn save_keeps_the_previous_generation_in_bak() {
        let dir = store_dir();
        let path = dir.join("connections.json");
        let backup = path.with_file_name("connections.json.bak");
        let store = ConnectionStore::load(path.clone(), Vec::new());

        store.upsert(entry("", "first")).await.expect("first save");
        assert!(!backup.exists(), "first save has no previous file to keep");
        let first = std::fs::read_to_string(&path).expect("read first save");

        store.upsert(entry("", "second")).await.expect("second save");
        let kept = std::fs::read_to_string(&backup).expect("read backup");
        assert_eq!(kept, first, "the backup must be the previous generation");
        let previous: Vec<ConnEntry> = serde_json::from_str(&kept).expect("backup parses");
        assert_eq!(previous.len(), 1);
        #[cfg(unix)]
        assert_eq!(mode_of(&backup), 0o600, "the backup must be private");
        let current: Vec<ConnEntry> =
            serde_json::from_str(&std::fs::read_to_string(&path).expect("read current"))
                .expect("current parses");
        assert_eq!(current.len(), 2);

        // A leftover .bak must not be picked up when the live file is missing.
        std::fs::remove_file(&path).expect("remove live file");
        let reloaded = ConnectionStore::load(path.clone(), Vec::new());
        assert!(
            reloaded.list().await.is_empty(),
            "connections.json.bak must never be loaded as the live file"
        );
        let _ = std::fs::remove_dir_all(dir);
    }
}
