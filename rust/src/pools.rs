use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::core::connection::{ConnectionHandle, ConnectionConfig};
use crate::core::driver::PoolProvider;
use crate::drivers::{connect_full, ConnSpec, DriverKind, Pool, PoolSession};
use crate::error::{AppError, AppResult};

/// At most this many database pools are kept open per connection.
///
/// The PostgreSQL tree can list dozens of databases; opening one pool per
/// database upfront would exhaust the server's connection limit. Pools are
/// created on demand and the least-recently-used one is dropped when the cap is
/// reached. Dropping a pool does not cancel in-flight queries: sqlx closes it
/// once the last cloned handle is gone.
const MAX_POOLS: usize = 5;

#[derive(Default)]
struct Registry {
    /// Key -> pooled connection plus the tunnel it was dialled through (if any).
    pools: HashMap<String, (Pool, Option<crate::drivers::TunnelInfo>)>,
    order: VecDeque<String>,
}

/// Cache of driver pools, keyed by connection identity + selected database.
#[derive(Clone, Default)]
pub struct PoolRegistry {
    inner: Arc<RwLock<Registry>>,
}

// ------------------------------------------------------------ tunnel registry

/// Live SSH tunnels, keyed by the local forwarded port.
///
/// A tunnel must outlive the sqlx pool that uses it: closing it first makes
/// every query fail with "connection reset". The registry keeps it alive until
/// the pool is evicted or the connection is torn down. Entries are addressed by
/// local port because that is the pool's real endpoint.
fn tunnels() -> &'static std::sync::Mutex<std::collections::HashMap<u16, crate::ssh::SshTunnel>> {
    static TUNNELS: std::sync::OnceLock<
        std::sync::Mutex<std::collections::HashMap<u16, crate::ssh::SshTunnel>>,
    > = std::sync::OnceLock::new();
    TUNNELS.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()))
}

/// Keep a tunnel alive for the given local port.
pub fn register_tunnel(port: u16, tunnel: crate::ssh::SshTunnel) {
    if let Ok(mut guard) = tunnels().lock() {
        // Replacing an older tunnel on the same port closes it (its sender is
        // dropped), which is the desired behaviour after a reconnect.
        guard.insert(port, tunnel);
    }
}

/// Close the tunnel for a local port, if any.
pub fn release_tunnel(port: u16) {
    if let Ok(mut guard) = tunnels().lock() {
        guard.remove(&port);
    }
}

/// Number of tunnels currently held (diagnostics and tests).
pub fn tunnel_count() -> usize {
    tunnels().lock().map(|g| g.len()).unwrap_or(0)
}

/// Fingerprint of the jump host key for a local forwarded port.
pub fn tunnel_fingerprint(port: u16) -> Option<String> {
    tunnels()
        .lock()
        .ok()
        .and_then(|g| g.get(&port).map(|t| t.host_key_fingerprint.clone()))
}


/// 池身份 key：实现在 core::config::pool_identity_key（P2-1 从本文件搬走），
/// 这里保留薄封装，既有调用点与单元测试（super::key）不需要改。
fn key(spec: &ConnSpec, database: Option<&str>) -> String {
    crate::core::config::pool_identity_key(spec, database)
}

/// Close the SSH tunnel whose local port appears in a pool key.
///
/// Pool keys contain the dialled host/port; for tunnelled connections that
/// port is the local forwarder's, so it is the registry key.
fn release_tunnels_for(pool_key: &str) {
    let mut parts = pool_key.split('|');
    // driver|host|port|user|...
    let _driver = parts.next();
    let _host = parts.next();
    if let Some(port) = parts.next().and_then(|p| p.parse::<u16>().ok()) {
        release_tunnel(port);
    }
}

fn touch(reg: &mut Registry, key: &str) {
    if let Some(pos) = reg.order.iter().position(|k| k == key) {
        reg.order.remove(pos);
    }
    reg.order.push_back(key.to_string());
}

impl PoolRegistry {
    /// 打开/复用一条池化会话本身。
    ///
    /// 33 轮删除 `Db` 门面后，只有本模块（包装句柄）和固定会话
    /// （`ScriptSession::open`）需要池本体；api / state 一律拿
    /// [`ConnectionHandle`]。
    pub(crate) async fn pooled_session(
        &self,
        spec: &ConnSpec,
        database: Option<&str>,
    ) -> AppResult<PoolSession> {
        let k = key(spec, database);
        {
            let mut guard = self.inner.write().await;
            if let Some((pool, tunnel)) = guard.pools.get(&k).cloned() {
                if !pool.is_closed() {
                    touch(&mut guard, &k);
                    return Ok(PoolSession {
                        pool,
                        driver: spec.driver,
                        tunnel,
                    });
                }
                guard.pools.remove(&k);
                guard.order.retain(|item| item != &k);
            }
        }

        let (pool, tunnel) = connect_full(spec, database).await?;
        {
            let mut guard = self.inner.write().await;
            guard.pools.insert(k.clone(), (pool.clone(), tunnel.clone()));
            touch(&mut guard, &k);
            while guard.order.len() > MAX_POOLS {
                let Some(old) = guard.order.pop_front() else {
                    break;
                };
                // Do not call close() here: another caller may still hold a
                // clone of this pool, and closing it would abort its query.
                guard.pools.remove(&old);
                release_tunnels_for(&old);
            }
        }
        Ok(PoolSession {
            pool,
            driver: spec.driver,
            tunnel,
        })
    }

    /// Return a cached pool, or open one lazily, as the handle api understands.
    pub async fn get(&self, spec: &ConnSpec, database: Option<&str>) -> AppResult<ConnectionHandle> {
        Ok(self.pooled_session(spec, database).await?.into_handle())
    }

    /// Open a brand new connection and verify it, without trusting any cached pool.
    pub async fn validate(&self, spec: &ConnSpec) -> AppResult<ConnectionHandle> {
        let (pool, tunnel) = connect_full(spec, None).await?;
        let handle = PoolSession {
            pool,
            driver: spec.driver,
            tunnel,
        }
        .into_handle();
        crate::drivers::builtin::driver_for(spec.driver)
            .ping(&handle)
            .await?;
        Ok(handle)
    }

    /// Open an instance-level connection.
    ///
    /// PostgreSQL refuses a connection when the account has no CONNECT privilege
    /// on the named database (or when `postgres` was removed). The admin pool is
    /// therefore tried against the configured database first, then the usual
    /// maintenance databases, and finally the account's own database. The actual
    /// database used is returned so the UI can display it.
    ///
    /// MySQL can always run `SHOW DATABASES` from a server-level connection, so
    /// the fallback is a connection without a default database.
    pub async fn connect_admin(
        &self,
        spec: &ConnSpec,
    ) -> AppResult<(ConnectionHandle, Option<String>)> {
        match spec.driver {
            DriverKind::Postgres => {
                let mut candidates: Vec<String> = Vec::new();
                let mut add = |name: &str| {
                    let name = name.trim();
                    if !name.is_empty() && !candidates.iter().any(|c| c == name) {
                        candidates.push(name.to_string());
                    }
                };
                if let Some(db) = spec.database() {
                    add(db);
                }
                add("postgres");
                add("template1");
                add(&spec.user);

                let attempted = candidates.join(", ");
                let mut first_err: Option<AppError> = None;
                for database in candidates {
                    match self.get(spec, Some(&database)).await {
                        Ok(conn) => return Ok((conn, Some(database))),
                        Err(error) => {
                            if first_err.is_none() {
                                first_err = Some(error);
                            }
                        }
                    }
                }
                let detail = first_err
                    .map(|error| error.to_string())
                    .unwrap_or_else(|| "未知错误".to_string());
                Err(AppError::bad(format!(
                    "无法建立 PostgreSQL 管理连接（已尝试：{attempted}）。\
                     如果账号只能访问某个业务库，请在连接表单里填写「默认数据库」。详情：{detail}"
                )))
            }
            DriverKind::Mysql => {
                // Prefer the configured database, but fall back to a connection
                // without a default schema when that database is not accessible.
                match self.get(spec, None).await {
                    Ok(conn) => Ok((conn, spec.database().map(str::to_string))),
                    Err(first) => {
                        // A refused port / bad host will fail the same way without a
                        // default schema; retrying only doubles the wait (30s).
                        let text = first.to_string();
                        if text.contains("连接被拒绝") || text.contains("无法解析") {
                            return Err(first);
                        }
                        let mut admin = spec.clone();
                        admin.database = None;
                        match self.get(&admin, None).await {
                            Ok(conn) => Ok((conn, None)),
                            Err(_) => Err(first),
                        }
                    }
                }
            }
            DriverKind::Sqlite => self
                .get(spec, None)
                .await
                .map(|conn| (conn, spec.database().map(str::to_string))),
        }
    }

    /// Drop cached pools for a connection identity.
    pub async fn evict(&self, spec: &ConnSpec) {
        let prefix = format!(
            "{}|{}|{}|{}|",
            spec.driver.as_str(),
            spec.host,
            spec.port(),
            spec.user
        );
        let mut guard = self.inner.write().await;
        let keys: Vec<String> = guard
            .pools
            .keys()
            .filter(|k| k.starts_with(&prefix))
            .cloned()
            .collect();
        for k in keys {
            if let Some((pool, _tunnel)) = guard.pools.remove(&k) {
                pool.close().await;
                release_tunnels_for(&k);
            }
        }
        guard.order.retain(|k| !k.starts_with(&prefix));
    }

    /// Remove the cached pool for one database without closing it.
    ///
    /// Used after MySQL `KILL CONNECTION`: the killed query may still hold a
    /// clone of the pool while its error propagates. Removing the registry entry
    /// makes the next query open a fresh pool, while the old pool closes when its
    /// last clone is dropped.
    pub async fn forget_database(&self, spec: &ConnSpec, database: &str) {
        let k = key(spec, Some(database));
        let mut guard = self.inner.write().await;
        guard.pools.remove(&k);
        guard.order.retain(|item| item != &k);
        release_tunnels_for(&k);
    }

    /// Drop the cached pool for the connection's default database.
    ///
    /// MySQL / PostgreSQL pools opened without an explicit database still hold
    /// connections whose default database was the connection's configured one.
    /// After that database is dropped (and maybe recreated), those sessions are
    /// stale ("No database selected"), so the console evicts this key too.
    pub async fn evict_default(&self, spec: &ConnSpec) {
        let k = key(spec, None);
        let mut guard = self.inner.write().await;
        if let Some((pool, _tunnel)) = guard.pools.remove(&k) {
            guard.order.retain(|item| item != &k);
            pool.close().await;
            release_tunnels_for(&k);
        }
    }

    /// Drop the pool for one physical database (used before DROP DATABASE).
    pub async fn evict_database(&self, spec: &ConnSpec, database: &str) {
        let k = key(spec, Some(database));
        let mut guard = self.inner.write().await;
        if let Some((pool, _tunnel)) = guard.pools.remove(&k) {
            guard.order.retain(|item| item != &k);
            pool.close().await;
            release_tunnels_for(&k);
        }
    }

    pub async fn len(&self) -> usize {
        self.inner.read().await.pools.len()
    }

    pub async fn is_empty(&self) -> bool {
        self.inner.read().await.pools.is_empty()
    }
}

/// `PoolRegistry` 是驱动看到的唯一池来源。
///
/// 驱动只调用 `pooled` / `admin_pooled`；LRU 上限、key 计算、隧道注册与
/// 释放全部留在本模块（硬性要求 5：池与隧道仍由 state/pools/ssh 管理）。
#[async_trait::async_trait]
impl PoolProvider for PoolRegistry {
    async fn pooled(
        &self,
        config: &ConnectionConfig,
        database: Option<&str>,
    ) -> AppResult<ConnectionHandle> {
        self.get(config, database).await
    }

    async fn admin_pooled(
        &self,
        config: &ConnectionConfig,
    ) -> AppResult<(ConnectionHandle, Option<String>)> {
        self.connect_admin(config).await
    }

    /// 固定会话（P3 Step 1）：池提供连接，固定/复用语义在 ScriptSession 里。
    async fn session(
        &self,
        config: &ConnectionConfig,
        database: Option<&str>,
    ) -> AppResult<Box<dyn crate::core::session::SessionHandle>> {
        let session = self.pooled_session(config, database).await?;
        Ok(Box::new(crate::drivers::ScriptSession::open(session).await?))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn sqlite_spec(path: &PathBuf) -> ConnSpec {
        ConnSpec {
            driver: DriverKind::Sqlite,
            host: String::new(),
            port: None,
            user: String::new(),
            password: String::new(),
            database: Some(path.to_string_lossy().to_string()),
            charset: None,
            ssl_mode: None,
            ssl_verify: None,
            ssl_ca: None,
            ssl_cert: None,
            ssl_key: None,
            sqlite_dir: None,
            ssh: crate::ssh::SshSpec::default(),
        }
    }

    #[tokio::test]
    async fn repair_get_separates_connection_settings() {
        let spec = ConnSpec { driver: DriverKind::Mysql, ..Default::default() };
        for field in ["password", "charset", "ssl_mode", "ssl_verify", "ssl_ca", "ssl_cert", "ssl_key"] {
            let mut value = serde_json::to_value(&spec).unwrap();
            value[field] = serde_json::json!("synthetic-test-setting");
            let changed: ConnSpec = serde_json::from_value(value).unwrap();
            assert_ne!(
                super::key(&spec, None),
                super::key(&changed, None),
                "configuration omitted from pool identity: {field}"
            );
        }
    }

    #[tokio::test]
    async fn lazy_pools_are_capped() {
        let dir = std::env::temp_dir().join(format!("rma-pools-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let registry = PoolRegistry::default();
        for i in 0..(MAX_POOLS + 3) {
            let path = dir.join(format!("db{i}.sqlite"));
            std::fs::File::create(&path).unwrap();
            registry.get(&sqlite_spec(&path), None).await.unwrap();
        }
        assert_eq!(registry.len().await, MAX_POOLS);
        let _ = std::fs::remove_dir_all(&dir);
    }
}

