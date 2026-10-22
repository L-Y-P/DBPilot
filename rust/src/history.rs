use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;
use uuid::Uuid;

use crate::error::{AppError, AppResult};

const MAX_ENTRIES: usize = 10_000;

/// Largest SQL text retained per history entry, in characters.
///
/// A multi-megabyte script imported through the SQL console used to be copied
/// into the history verbatim: one 3.6 MB pg_dump script made query_history.json
/// 31 MB, the history page froze while laying out every row (the row preview and
/// its tooltip received the whole string), and every history_list() call shipped
/// the same megabytes over FFI. History is for recalling/replaying statements,
/// not for archiving dumps: keep a bounded preview and record that it was cut.
pub const MAX_HISTORY_SQL_CHARS: usize = 32 * 1024;

/// One executed statement batch.
///
/// `user` is retained so history files written by the web build still load;
/// the desktop app is single-user and never filters on it.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub id: String,
    #[serde(default)]
    pub user: String,
    pub sql: String,
    #[serde(default)]
    pub database: Option<String>,
    pub at: String,
    pub ok: bool,
    pub statements: usize,
    pub failed: usize,
    pub elapsed_ms: u64,
    /// True when `sql` is only the first [MAX_HISTORY_SQL_CHARS] characters of
    /// the executed script (older history files are compacted on load).
    #[serde(default)]
    pub sql_truncated: bool,
    /// Original length of the executed SQL in characters.
    #[serde(default)]
    pub sql_chars: usize,
}

#[derive(Clone)]
pub struct HistoryStore {
    path: Arc<PathBuf>,
    inner: Arc<RwLock<Vec<HistoryEntry>>>,
}

impl HistoryStore {
    pub fn load(path: PathBuf) -> Self {
        let mut entries = std::fs::read_to_string(&path)
            .ok()
            .and_then(|text| serde_json::from_str::<Vec<HistoryEntry>>(&text).ok())
            .unwrap_or_default();
        // SQL history can quote data values; keep it owner-only.
        crate::secure::harden_file(&path);
        // Compact history written by older builds before it is ever shipped to
        // the UI again. Keep the previous oversized file as .bak, so nothing that
        // was stored is lost.
        let mut compacted = 0usize;
        for entry in &mut entries {
            if compact_entry(entry) {
                compacted += 1;
            }
        }
        if compacted > 0 {
            let backup = backup_path(&path);
            let _ = std::fs::copy(&path, &backup).map(|_| crate::secure::set_file_mode(&backup, 0o600));
            if let Ok(json) = serde_json::to_string_pretty(&entries) {
                if let Err(error) = crate::secure::write_private(&path, &json) {
                    tracing::warn!("could not compact query history: {error}");
                }
            }
            tracing::warn!(
                "compacted {compacted} oversized query-history entr{}",
                if compacted == 1 { "y" } else { "ies" }
            );
        }
        Self {
            path: Arc::new(path),
            inner: Arc::new(RwLock::new(entries)),
        }
    }

    /// Most recent entries first. `limit` is clamped to a sane range so a
    /// caller cannot ask for an unbounded allocation. Every returned entry has a
    /// bounded `sql` even if an older/hand-edited store still holds a huge one.
    pub async fn list(&self, limit: usize) -> Vec<HistoryEntry> {
        self.page(limit, 0).await.0
    }

    /// One page of history (newest first) plus the total number of entries.
    ///
    /// The Rust side paginates so the UI never receives more SQL than one page
    /// needs: history_list used to ship every stored script over FFI, which was
    /// the main reason the history page froze after large imports.
    pub async fn page(&self, limit: usize, offset: usize) -> (Vec<HistoryEntry>, usize) {
        let guard = self.inner.read().await;
        let total = guard.len();
        let mut refs: Vec<&HistoryEntry> = guard.iter().collect();
        refs.sort_by(|a, b| b.at.cmp(&a.at));
        let items = refs
            .into_iter()
            .skip(offset)
            .take(limit.clamp(1, MAX_ENTRIES))
            .map(compacted_copy)
            .collect();
        (items, total)
    }

    /// Total number of stored entries.
    pub async fn count(&self) -> usize {
        self.inner.read().await.len()
    }

    /// Every entry, used by the export function. SQL is bounded like [list].
    pub async fn list_all(&self) -> Vec<HistoryEntry> {
        let guard = self.inner.read().await;
        let mut refs: Vec<&HistoryEntry> = guard.iter().collect();
        refs.sort_by(|a, b| b.at.cmp(&a.at));
        refs.into_iter().map(compacted_copy).collect()
    }

    pub async fn push(&self, mut entry: HistoryEntry) -> AppResult<()> {
        compact_entry(&mut entry);
        let mut guard = self.inner.write().await;
        guard.push(entry);
        if guard.len() > MAX_ENTRIES {
            let drop_count = guard.len() - MAX_ENTRIES;
            guard.drain(0..drop_count);
        }
        persist(&self.path, &guard).await
    }

    pub async fn clear(&self) -> AppResult<()> {
        let mut guard = self.inner.write().await;
        guard.clear();
        persist(&self.path, &guard).await
    }
}

pub fn new_entry(
    sql: &str,
    database: Option<&str>,
    statements: usize,
    failed: usize,
    elapsed_ms: u64,
) -> HistoryEntry {
    let mut entry = HistoryEntry {
        id: format!("h-{}", Uuid::new_v4().simple()),
        user: "local".to_string(),
        sql: sql.to_string(),
        database: database.map(|d| d.to_string()),
        at: Utc::now().to_rfc3339(),
        ok: failed == 0,
        statements,
        failed,
        elapsed_ms,
        sql_truncated: false,
        sql_chars: 0,
    };
    compact_entry(&mut entry);
    entry
}

/// Truncate one entry in place. Returns true when something changed.
fn compact_entry(entry: &mut HistoryEntry) -> bool {
    if entry.sql_chars == 0 {
        entry.sql_chars = entry.sql.chars().count();
    }
    if entry.sql_truncated {
        return false;
    }
    if entry.sql_chars <= MAX_HISTORY_SQL_CHARS {
        return false;
    }
    entry.sql = entry.sql.chars().take(MAX_HISTORY_SQL_CHARS).collect();
    entry.sql_truncated = true;
    true
}

/// Copy an entry with bounded SQL, without cloning a multi-megabyte string first.
fn compacted_copy(entry: &HistoryEntry) -> HistoryEntry {
    let chars = if entry.sql_chars > 0 {
        entry.sql_chars
    } else {
        entry.sql.chars().count()
    };
    let truncated = entry.sql_truncated || chars > MAX_HISTORY_SQL_CHARS;
    let sql = if truncated {
        entry.sql.chars().take(MAX_HISTORY_SQL_CHARS).collect()
    } else {
        entry.sql.clone()
    };
    HistoryEntry {
        id: entry.id.clone(),
        user: entry.user.clone(),
        sql,
        database: entry.database.clone(),
        at: entry.at.clone(),
        ok: entry.ok,
        statements: entry.statements,
        failed: entry.failed,
        elapsed_ms: entry.elapsed_ms,
        sql_truncated: truncated,
        sql_chars: chars,
    }
}

fn backup_path(path: &PathBuf) -> PathBuf {
    let mut name = path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "query_history.json".to_string());
    name.push_str(".bak");
    match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.join(name),
        _ => PathBuf::from(name),
    }
}

async fn persist(path: &PathBuf, items: &[HistoryEntry]) -> AppResult<()> {
    let json = serde_json::to_string_pretty(items).map_err(|e| AppError::Internal(e.to_string()))?;
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            let _ = std::fs::create_dir_all(parent);
        }
    }
    crate::secure::write_private(path, &json)
        .map_err(|e| AppError::Internal(format!("无法保存查询历史: {e}")))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_path(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "rma-history-test-{}",
            Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join(name)
    }

    #[test]
    fn new_entry_compacts_a_multi_megabyte_script() {
        let sql = "SELECT 1;".repeat(100_000);
        let entry = new_entry(&sql, Some("db"), 100_000, 0, 10);
        assert!(entry.sql_truncated, "huge SQL must be flagged as truncated");
        assert_eq!(entry.sql_chars, sql.chars().count());
        assert_eq!(entry.sql.chars().count(), MAX_HISTORY_SQL_CHARS);
    }

    #[test]
    fn load_compacts_oversized_history_and_keeps_a_backup() {
        let path = temp_path("query_history.json");
        let huge = "X".repeat(200_000);
        let entries = serde_json::json!([
            {
                "id": "h-old",
                "user": "local",
                "sql": huge,
                "database": "db",
                "at": "2026-01-01T00:00:00+00:00",
                "ok": true,
                "statements": 1,
                "failed": 0,
                "elapsed_ms": 5
            }
        ]);
        std::fs::write(&path, serde_json::to_string(&entries).unwrap()).unwrap();
        let store = HistoryStore::load(path.clone());
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let listed = rt.block_on(store.list(10));
        assert_eq!(listed.len(), 1);
        assert!(listed[0].sql_truncated);
        assert_eq!(listed[0].sql_chars, 200_000);
        assert_eq!(listed[0].sql.chars().count(), MAX_HISTORY_SQL_CHARS);

        let backup = backup_path(&path);
        assert!(backup.exists(), "original oversized history was not preserved");
        let backup_text = std::fs::read_to_string(&backup).unwrap();
        assert!(backup_text.contains("XXXXXXXXXX"), "backup lost the SQL");
        let rewritten = std::fs::read_to_string(&path).unwrap();
        assert!(
            rewritten.len() < 200_000,
            "history file was not compacted: {}",
            rewritten.len()
        );
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[tokio::test]
    async fn page_returns_the_requested_slice_and_the_total() {
        let path = temp_path("page.json");
        let store = HistoryStore::load(path.clone());
        for i in 0..5 {
            let mut entry = new_entry(&format!("SELECT {i}"), None, 1, 0, 1);
            entry.at = format!("2026-01-01T00:00:0{i}+00:00");
            store.push(entry).await.unwrap();
        }
        let (first, total) = store.page(2, 0).await;
        assert_eq!(total, 5);
        assert_eq!(first.len(), 2);
        assert_eq!(first[0].sql, "SELECT 4");
        assert_eq!(first[1].sql, "SELECT 3");

        let (last, total) = store.page(2, 4).await;
        assert_eq!(total, 5);
        assert_eq!(last.len(), 1);
        assert_eq!(last[0].sql, "SELECT 0");

        let (none, total) = store.page(2, 99).await;
        assert_eq!(total, 5);
        assert!(none.is_empty());
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[tokio::test]
    async fn push_and_list_keep_sql_bounded() {
        let path = temp_path("push.json");
        let store = HistoryStore::load(path.clone());
        let huge = "Y".repeat(MAX_HISTORY_SQL_CHARS * 3);
        store.push(new_entry(&huge, None, 1, 0, 1)).await.unwrap();
        store.push(new_entry("SELECT 1", None, 1, 0, 1)).await.unwrap();
        let listed = store.list(10).await;
        assert_eq!(listed.len(), 2);
        assert!(listed.iter().all(|e| e.sql.chars().count() <= MAX_HISTORY_SQL_CHARS));
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }
}
