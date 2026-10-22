//! Saved connection management + connecting/disconnecting.
//!
//! Ports `server/src/routes/connections.rs`. The web version filtered the
//! list by the logged-in user's `allowed_connections` and required the admin
//! role to create/edit/delete; a desktop process has one user, so those checks
//! are gone. The connection's own `only_db` / `hide_db` rules are still
//! enforced at the `db_for` boundary.

use serde::Deserialize;
use serde_json::{json, Value};

use super::{parse, state};
use crate::connections::ConnEntry;
use crate::drivers::{ConnSpec, DriverKind};
use crate::error::{AppError, AppResult};
use crate::state::{ActiveConnection, AppState};

/// List every saved connection.
///
/// `store_error` reports a startup problem with connections.json: the file
/// existed but could not be read/parsed, so the saved list may be missing even
/// though the original bytes were preserved as `connections.json.corrupt-*`.
/// It is `null` when the store loaded normally. The UI shows it as a
/// dismissible startup banner instead of silently presenting an empty list.
pub async fn list_connections() -> anyhow::Result<Value> {
    let state = state()?;
    let entries = state.connections.list().await;
    Ok(list_payload(entries, state.connections.load_error()))
}

/// Build the `/connections` payload.
///
/// Kept separate from the handler so the `store_error` plumbing can be tested
/// against a real [ConnectionStore] without initializing the global state.
fn list_payload(entries: Vec<ConnEntry>, store_error: Option<&str>) -> Value {
    json!({ "connections": entries, "store_error": store_error })
}

/// Fill in what a SQLite connection implies from the rest of its fields.
///
/// The form can be saved with only a folder (the user picked a directory and
/// expects to browse it), but a connection needs a primary file: the first
/// usable database in that folder becomes it. The connection is also named after
/// its database file when the user left the name empty.
fn normalize(state: &AppState, mut entry: ConnEntry) -> ConnEntry {
    // 文件发现是驱动能力（仅 SQLite 有），api 不再 use 具体驱动模块。
    let driver = match state.driver(entry.spec.driver.as_str()) {
        Ok(driver) => driver,
        Err(_) => return entry,
    };
    if !driver.is_file_based() {
        return entry;
    }
    if entry.spec.database().is_none() {
        if let Some(dir) = entry.spec.sqlite_folder() {
            if let Some(file) = driver.discover_database(&dir) {
                entry.spec.database = Some(file);
            }
        }
    }
    if entry.name.trim().is_empty() {
        if let Some(database) = entry.spec.database() {
            if let Some(name) = driver.suggest_connection_name(database) {
                entry.name = name;
            }
        }
    }
    entry
}

/// Create a connection. A client-supplied id is ignored so the store always
/// mints a fresh one, matching the web handler.
pub async fn create_connection(entry: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let mut parsed: ConnEntry = parse("connection", entry)?;
    parsed.id = String::new();
    let saved = state.connections.upsert(normalize(&state, parsed)).await?;
    Ok(json!({ "ok": true, "connection": saved }))
}

/// Update an existing connection by id.
pub async fn update_connection(id: String, entry: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let mut parsed: ConnEntry = parse("connection", entry)?;
    parsed.id = id;
    let saved = state.connections.upsert(normalize(&state, parsed)).await?;
    Ok(json!({ "ok": true, "connection": saved }))
}

/// Delete a connection. If it is the active one, it is disconnected first so
/// the app cannot keep using a pool for a connection that no longer exists.
pub async fn delete_connection(id: String) -> anyhow::Result<Value> {
    let state = state()?;
    let active_id = state.active().await.ok().and_then(|c| c.id);
    // Persist first. If the save fails, the connection must stay both on disk
    // and in memory, and the active session must NOT have been disconnected as
    // a side effect of a failed delete.
    let removed = state.connections.remove(&id).await?;
    if active_id.as_deref() == Some(id.as_str()) {
        state.disconnect().await?;
    }
    Ok(json!({ "ok": true, "removed": removed }))
}

#[derive(Deserialize)]
struct ProbeRequest {
    #[serde(default)]
    connection_id: Option<String>,
    #[serde(default)]
    driver: Option<DriverKind>,
    #[serde(default)]
    host: Option<String>,
    #[serde(default)]
    port: Option<u16>,
    #[serde(default)]
    user: Option<String>,
    #[serde(default)]
    password: Option<String>,
    #[serde(default)]
    database: Option<String>,
    #[serde(default)]
    charset: Option<String>,
    #[serde(default)]
    ssl_mode: Option<String>,
    #[serde(default)]
    ssl_verify: Option<String>,
    #[serde(default)]
    ssl_ca: Option<String>,
    #[serde(default)]
    ssl_cert: Option<String>,
    #[serde(default)]
    ssl_key: Option<String>,
    /// SQLite: folder whose database files are attached to the connection.
    #[serde(default)]
    sqlite_dir: Option<String>,
    /// Optional SSH jump host, flattened so the form can send ssh_* fields
    /// alongside the database fields (single connection object).
    #[serde(flatten)]
    ssh: crate::ssh::SshSpec,
}

/// Build a `ConnSpec` from either a saved connection id or raw form fields.
async fn resolve_spec(state: &crate::state::AppState, req: &ProbeRequest) -> AppResult<ConnSpec> {
    if let Some(id) = req.connection_id.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        let entry = state
            .connections
            .get(id)
            .await
            .ok_or_else(|| AppError::not_found("连接不存在"))?;
        let mut spec = entry.spec.clone();
        // A supplied password overrides the stored one (used by "test" while
        // the user is still typing); an empty one means "keep the stored value".
        if let Some(p) = &req.password {
            if !p.is_empty() {
                spec.password = p.clone();
            }
        }
        return Ok(spec);
    }
    Ok(ConnSpec {
        driver: req.driver.unwrap_or(DriverKind::Mysql),
        host: req.host.clone().unwrap_or_else(|| "127.0.0.1".to_string()),
        port: req.port,
        user: req.user.clone().unwrap_or_default(),
        password: req.password.clone().unwrap_or_default(),
        database: req.database.clone(),
        charset: req.charset.clone(),
        ssl_mode: req.ssl_mode.clone(),
        ssl_verify: req.ssl_verify.clone(),
        ssl_ca: req.ssl_ca.clone(),
        ssl_cert: req.ssl_cert.clone(),
        ssl_key: req.ssl_key.clone(),
        sqlite_dir: req
            .sqlite_dir
            .clone()
            .map(|d| d.trim().to_string())
            .filter(|d| !d.is_empty()),
        ssh: req.ssh.clone(),
    })
}

/// Open a connection, ping it, and report version + namespace count.
/// Always uses a fresh pool so a stale cached one cannot mask a bad password.
pub async fn test_connection(probe: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let req: ProbeRequest = parse("probe", probe)?;
    let spec = resolve_spec(&state, &req).await?;
    let started = std::time::Instant::now();
    // MySQL / PostgreSQL: prove the instance connection, using the admin
    // fallback so a user without access to `postgres` can still connect. SQLite
    // keeps the direct file probe.
    let (conn, database) = match spec.driver {
        DriverKind::Sqlite => (state.pools.validate(&spec).await?, None),
        _ => state.pools.connect_admin(&spec).await?,
    };
    // Report where the driver actually landed. For a tunnelled connection the
    // database host is resolved on the jump host, so showing the configured
    // host would hide whether SSH worked at all.
    //
    // The endpoint and fingerprint come from the pool we just built. This used
    // to call dial_target() a second time and look the fingerprint up in the
    // tunnel registry by that *second*, unregistered tunnel's port — so the
    // fingerprint was always empty and TOFU pinning never worked (N-01/N-11).
    let (dial_host, dial_port, tunnelled, tunnel_host_key) = match conn.tunnel() {
        Some(info) => (
            info.host.clone(),
            info.port,
            true,
            Some(info.fingerprint.clone()),
        ),
        None => (spec.host.clone(), spec.port(), false, None),
    };
    let driver = state.driver(spec.driver.as_str())?;
    let version = driver.server_version(&conn).await.unwrap_or_default();
    let namespaces = driver
        .list_instance_databases(&conn)
        .await
        .map(|n| n.len())
        .unwrap_or(0);
    Ok(json!({
        "ok": true,
        "driver": spec.driver.as_str(),
        "version": version,
        "namespaces": namespaces,
        "database": database,
        "elapsed_ms": started.elapsed().as_millis() as u64,
        "tunnelled": tunnelled,
        "dial_host": dial_host,
        "dial_port": dial_port,
        "ssh_host_key_fingerprint": tunnel_host_key,
        "ssh_host_key_changed": spec.uses_ssh()
            && spec.ssh.ssh_host_key.as_deref().map(str::trim).filter(|s| !s.is_empty()).is_some_and(|pin| tunnel_host_key.as_deref() != Some(pin)),
    }))
}

/// Connect to a saved connection and make it the active one.
pub async fn connect_connection(id: String) -> anyhow::Result<Value> {
    let state = state()?;
    let entry = state
        .connections
        .get(&id)
        .await
        .ok_or_else(|| AppError::not_found("连接不存在"))?;
    let binding = ActiveConnection::from_entry(&entry);
    let bound = state.bind_connection(binding).await?;
    // The initial database is chosen from the visible list; the pool is cached.
    // P5：连接信息通过驱动 + 句柄获取，api 不再持有旧门面 Db。
    let driver = state.driver_for_active().await?;
    let handle = state.connection_for(None).await?;
    let version = driver.server_version(&handle).await.unwrap_or_default();
    let search_path = driver.current_schema(&handle).await;
    let active_database = state.active_database().await;
    // TOFU pinning (N-01): an accept-new SSH connection remembers the jump
    // host key on first successful connect. Without this the UI's
    // "first connection trusts and remembers" promise was false — every
    // connect re-trusted a new key unless the user had pressed "test" and
    // saved the form back.
    if let Some(fingerprint) = handle.tunnel().map(|info| info.fingerprint.clone()) {
        if let Some(entry) = state.connections.get(&id).await {
            let ssh = &entry.spec.ssh;
            let stored = ssh
                .ssh_host_key
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty());
            if ssh.enabled()
                && stored.is_none()
                && ssh.ssh_host_key_policy == crate::ssh::SshHostKeyPolicy::AcceptNew
            {
                let mut updated = entry.clone();
                updated.spec.ssh.ssh_host_key = Some(fingerprint);
                if state.connections.upsert(updated).await.is_ok() {
                    // Keep the running session in sync: future pools created
                    // for this connection must also verify the pinned key.
                    let mut active = bound.clone();
                    active.spec.ssh.ssh_host_key =
                        state.connections.get(&id).await.and_then(|e| e.spec.ssh.ssh_host_key);
                    state.set_active(Some(active)).await;
                }
            }
        }
    }
    // Remember the last connection for the next launch.
    let mut settings = state.settings();
    settings.last_connection_id = bound.id.clone();
    let _ = state.update_settings(settings).await;
    Ok(json!({
        "ok": true,
        "connection": {
            "id": bound.id,
            "label": bound.label,
            "driver": bound.spec.driver.as_str(),
            "driver_label": bound.spec.driver.label(),
            "database": bound.spec.database(),
            "host": bound.spec.host,
            "port": bound.spec.port(),
            "user": bound.spec.user,
            "only_db": bound.only_db,
            "hide_db": bound.hide_db,
            "active_database": active_database,
            "search_path": search_path,
        },
        "server_version": version,
    }))
}

/// Close the active connection and drop its pools.
pub async fn disconnect() -> anyhow::Result<Value> {
    let state = state()?;
    state.disconnect().await?;
    Ok(json!({ "ok": true }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connections::ConnectionStore;

    /// A throwaway directory, never the real profile: these tests only exercise
    /// ConnectionStore::load() + the list payload.
    fn temp_dir() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "rma-api-connections-test-{}",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&dir).expect("temp dir");
        dir
    }

    /// A corrupt file is preserved as connections.json.corrupt-* and the error
    /// must reach the UI through list_connections' payload, not be swallowed.
    #[tokio::test]
    async fn list_payload_reports_a_corrupt_connections_file() {
        let dir = temp_dir();
        let path = dir.join("connections.json");
        std::fs::write(&path, r#"[{"name":"prod","driver":"mysql"},"#)
            .expect("write corrupt file");

        let store = ConnectionStore::load(path.clone(), Vec::new());
        let payload = list_payload(store.list().await, store.load_error());

        let message = payload["store_error"]
            .as_str()
            .expect("a corrupt file must be reported in store_error");
        assert!(
            message.contains("connections.json.corrupt-"),
            "the user must be told where the backup is: {message}"
        );
        assert!(
            payload["connections"].as_array().is_some_and(|list| list.is_empty()),
            "the store must still start from an empty list: {payload}"
        );
        // No global STATE was needed: the test proves the plumbing the handler
        // uses, without initApp().
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A file that parses normally must not show a banner (store_error = null)
    /// and its entries must pass through unchanged.
    #[tokio::test]
    async fn list_payload_has_null_store_error_for_a_valid_file() {
        let dir = temp_dir();
        let path = dir.join("connections.json");
        let saved = serde_json::json!([{ "name": "kept", "driver": "sqlite" }]);
        std::fs::write(&path, serde_json::to_string_pretty(&saved).unwrap())
            .expect("write valid file");

        let store = ConnectionStore::load(path.clone(), Vec::new());
        assert!(store.load_error().is_none(), "a valid file must not report an error");
        let payload = list_payload(store.list().await, store.load_error());

        assert!(
            payload["store_error"].is_null(),
            "the UI must not show a startup banner for a valid file: {payload}"
        );
        let entries = payload["connections"].as_array().expect("connections array");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0]["name"], "kept");
        let _ = std::fs::remove_dir_all(&dir);
    }
}

/// The currently active connection, or `null` when none is open.
pub async fn active_connection() -> anyhow::Result<Value> {
    let state = state()?;
    match state.active().await {
        Ok(conn) => {
            let active_database = state.active_database().await;
            let search_path = match state.driver_for_active().await {
                Ok(driver) => match state.connection_for(None).await {
                    Ok(handle) => driver.current_schema(&handle).await,
                    Err(_) => String::new(),
                },
                Err(_) => String::new(),
            };
            Ok(json!({
                "connection": {
                    "id": conn.id,
                    "label": conn.label,
                    "driver": conn.spec.driver.as_str(),
                    "driver_label": conn.spec.driver.label(),
                    "database": conn.spec.database(),
                    "active_database": active_database,
                    "search_path": search_path,
                    "host": conn.spec.host,
                    "port": conn.spec.port(),
                    "user": conn.spec.user,
                    "only_db": conn.only_db,
                    "hide_db": conn.hide_db,
                }
            }))
        }
        Err(_) => Ok(json!({ "connection": null })),
    }
}
