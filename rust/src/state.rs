//! Process-wide application state.
//!
//! In the web build this held a session store and an app-user store. The
//! desktop app is single-user: the "session" is simply the one connection the
//! user currently has open, held here behind a lock.

use serde_json::Value;
use std::path::PathBuf;
use std::sync::{Arc, RwLock as StdRwLock};
use tokio::sync::RwLock;

use crate::backups::BackupStore;
use crate::config::{DesktopConfig, Settings};
use crate::connections::{ConnEntry, ConnectionStore};
use crate::core::connection::{ConnectionConfig, ConnectionHandle};
use crate::core::dialect::DatabaseDialect;
use crate::core::driver::DatabaseDriver;
use crate::core::registry::DriverRegistry;
use crate::error::{AppError, AppResult};
use crate::history::HistoryStore;
use crate::pools::PoolRegistry;

/// The database connection the app currently has open. This replaces the
/// per-browser session binding of the web build.
#[derive(Clone, Debug)]
pub struct ActiveConnection {
    pub id: Option<String>,
    pub label: String,
    /// 驱动 id（"mysql" / "postgres" / "sqlite"），注册表的查询键。
    ///
    /// 不再靠 `match spec.driver` 分派：api / state 拿到它去注册表取
    /// `Arc<dyn DatabaseDriver>`。
    pub driver_id: String,
    pub spec: ConnectionConfig,
    pub only_db: Option<String>,
    pub hide_db: Option<String>,
}

impl ActiveConnection {
    pub fn from_entry(entry: &ConnEntry) -> Self {
        ActiveConnection {
            id: Some(entry.id.clone()),
            label: entry.display_name(),
            driver_id: entry.spec.driver.as_str().to_string(),
            spec: entry.spec.clone(),
            only_db: entry.only_db.clone(),
            hide_db: entry.hide_db.clone(),
        }
    }

    /// `only_db` / `hide_db` visibility check.
    pub fn visible(&self, name: &str) -> bool {
        crate::config::name_visible(self.only_db.as_deref(), self.hide_db.as_deref(), name)
    }

    /// Reject a namespace hidden by the connection's `only_db` / `hide_db`.
    ///
    /// This is the *only* remaining authorization boundary in the desktop app,
    /// so every operation that names a database must go through it — listing
    /// alone is not a boundary.
    pub fn ensure_visible(&self, name: &str) -> AppResult<()> {
        if self.visible(name) {
            Ok(())
        } else {
            Err(AppError::Forbidden(format!("没有访问数据库 '{}' 的权限", name)))
        }
    }

    /// 过滤掉被 only_db / hide_db 隐藏的列表行（按 `name` 字段）。
    ///
    /// 列表过滤**不能替代** `ensure_visible`：它只是让 UI 不展示点不开的库；
    /// 真正的边界仍是每个命名操作前的 `ensure_visible`。
    pub fn keep_visible_rows(&self, rows: Vec<Value>) -> Vec<Value> {
        rows.into_iter()
            .filter(|row| {
                row.get("name")
                    .and_then(|value| value.as_str())
                    .map(|name| self.visible(name))
                    .unwrap_or(false)
            })
            .collect()
    }
}

pub struct AppState {
    pub config: Arc<DesktopConfig>,
    /// 驱动注册表：连接/执行/元数据都先在这里按 `driver_id` 取驱动。
    pub driver_registry: Arc<DriverRegistry>,
    pub pools: PoolRegistry,
    pub connections: ConnectionStore,
    pub backups: BackupStore,
    pub history: HistoryStore,
    /// User preferences.
    ///
    /// Guarded by a `std` lock because the FFI surface mixes synchronous
    /// functions (`app_config`, `files::data_dir`) with async ones, and both
    /// need the same values. Every critical section only clones; none awaits
    /// while holding the guard.
    pub settings: Arc<StdRwLock<Settings>>,
    pub active: Arc<RwLock<Option<ActiveConnection>>>,
    /// Physical database selected in the explorer tree.
    ///
    /// PostgreSQL connections are instance-level: the connection no longer
    /// names a single database. Table APIs still receive a schema name, and
    /// this field tells `connection_for` which database pool that schema lives in.
    pub active_database: Arc<RwLock<Option<String>>>,
    /// Cancellation token of the SQL console query currently running.
    ///
    /// PostgreSQL has no client-side cancel in sqlx; the token is embedded as a
    /// SQL comment and `cancel_query` finds the backend in pg_stat_activity and
    /// calls pg_cancel_backend from a separate admin connection.
    pub cancel_token: Arc<RwLock<Option<String>>>,
    /// Token of the console run whose execution the user cancelled.
    ///
    /// `cancel_query` kills the MySQL connection / cancels the PostgreSQL
    /// backend, so the in-flight `run_query` comes back with a transport-level
    /// error ("expected to read 4 bytes, got 0 bytes at EOF"). This flag lets
    /// `run_query` recognise that outcome and show "查询已取消" instead of a
    /// low-level protocol message (N-07).
    pub cancelled_token: Arc<RwLock<Option<String>>>,
}

/// 系统库判断改为问方言（`dialect.system_databases()`），不再在 state 里
/// 硬编码三家的系统库名单。
fn system_database(dialect: &dyn DatabaseDialect, name: &str) -> bool {
    dialect
        .system_databases()
        .iter()
        .any(|known| *known == name)
        || name.starts_with("pg_temp_")
        || name.starts_with("pg_toast_temp_")
}

/// Pick the database the UI should open first.
fn initial_database(
    conn: &ActiveConnection,
    rows: &[Value],
    admin_database: Option<&str>,
    dialect: &dyn DatabaseDialect,
) -> Option<String> {
    let names: Vec<String> = rows
        .iter()
        // pg_database is readable for databases the account cannot CONNECT to;
        // do not pick one of those as the initial database.
        .filter(|row| row.get("can_connect") != Some(&Value::Bool(false)))
        .filter_map(|row| row.get("name").and_then(|v| v.as_str()))
        .filter(|name| !name.is_empty() && conn.visible(name))
        .map(str::to_string)
        .collect();
    if let Some(preferred) = conn.spec.database() {
        if names.iter().any(|name| name == preferred) {
            return Some(preferred.to_string());
        }
    }
    if let Some(name) = names.iter().find(|name| !system_database(dialect, name)) {
        return Some(name.clone());
    }
    if let Some(admin) = admin_database {
        if conn.visible(admin) {
            return Some(admin.to_string());
        }
    }
    names.first().cloned()
}

impl AppState {
    pub fn new(config: Arc<DesktopConfig>) -> Arc<AppState> {
        let seed = crate::config::seed_connections(&config.data_dir);
        let store = ConnectionStore::load(config.connections_file.clone(), seed);
        // Settings are read first: the user may keep backups outside the data
        // directory, and the store has to open the directory actually in force.
        let settings = config.load_settings();
        let backups = BackupStore::load(config.backup_dir_for(&settings));
        let history = HistoryStore::load(config.history_file.clone());
        // 静态插件：内置驱动在这里注册一次。注册失败是编程错误（id 重复 /
        // 空 id），启动期直接暴露，而不是等到用户点连接才报「未知驱动」。
        let driver_registry = Arc::new(DriverRegistry::new());
        crate::core::plugin::activate(
            &crate::drivers::builtin::builtin_plugins(),
            &driver_registry,
        )
        .expect("内置驱动插件激活失败（编程错误）");
        Arc::new(AppState {
            config,
            driver_registry,
            pools: PoolRegistry::default(),
            connections: store,
            backups,
            history,
            settings: Arc::new(StdRwLock::new(settings)),
            active: Arc::new(RwLock::new(None)),
            active_database: Arc::new(RwLock::new(None)),
            cancel_token: Arc::new(RwLock::new(None)),
            cancelled_token: Arc::new(RwLock::new(None)),
        })
    }

    /// The currently open connection, or an error asking the user to pick one.
    pub async fn active(&self) -> AppResult<ActiveConnection> {
        self.active
            .read()
            .await
            .clone()
            .ok_or_else(|| AppError::BadRequest("请先选择一个数据库连接".to_string()))
    }

    pub async fn set_active(&self, conn: Option<ActiveConnection>) {
        *self.active.write().await = conn;
    }

    /// The database selected in the explorer tree.
    pub async fn active_database(&self) -> Option<String> {
        self.active_database.read().await.clone()
    }

    pub async fn set_active_database(&self, database: Option<String>) {
        *self.active_database.write().await = database;
    }

    pub async fn set_cancel_token(&self, token: Option<String>) {
        *self.cancel_token.write().await = token;
    }

    pub async fn cancel_token(&self) -> Option<String> {
        self.cancel_token.read().await.clone()
    }

    /// Clear only if the token is still ours (a second query may have started).
    pub async fn clear_cancel_token(&self, token: &str) {
        let mut guard = self.cancel_token.write().await;
        if guard.as_deref() == Some(token) {
            *guard = None;
        }
    }

    /// Remember that the user asked to cancel the run identified by `token`.
    ///
    /// Marked *before* the KILL/pg_cancel_backend round trip so the in-flight
    /// query can never observe the cancel and finish before the flag is set.
    pub async fn mark_cancelled(&self, token: &str) {
        *self.cancelled_token.write().await = Some(token.to_string());
    }

    /// Consume the cancelled-run marker, if any.
    pub async fn take_cancelled(&self) -> Option<String> {
        self.cancelled_token.write().await.take()
    }

    /// 按 id 取驱动实现（api / state 只依赖 `core` 的 trait）。
    pub fn driver(&self, driver_id: &str) -> AppResult<Arc<dyn DatabaseDriver>> {
        self.driver_registry.get(driver_id)
    }

    /// 当前活动连接的驱动实现。
    pub async fn driver_for_active(&self) -> AppResult<Arc<dyn DatabaseDriver>> {
        let conn = self.active().await?;
        self.driver(&conn.driver_id)
    }

    /// Resolve (or lazily open) the pool that owns the namespace named by the
    /// caller.
    ///
    /// PostgreSQL schema operations pass the **schema** name (`public`, `app`);
    /// the database pool is chosen from `active_database`. MySQL still uses the
    /// argument as the database itself. SQLite has one pool for all attached
    /// files. **物理库由驱动解析**（`DatabaseDriver::resolve_database`），
    /// 可见性授权仍在这里用 `ensure_visible` 统一执行。
    pub async fn connection_for(&self, database: Option<&str>) -> AppResult<ConnectionHandle> {
        let (conn, target) = self.resolve_target(database).await?;
        self.pools.get(&conn.spec, target.as_deref()).await
    }

    /// 命名空间 →（活动连接, 物理库）：connection_for / open_session 共用。
    ///
    /// 授权只在这里做一次（ensure_visible）；调用方拿到的 target 已经过闸门。
    /// SQLite 的 file/alias 参数也按原语义校验。
    async fn resolve_target(
        &self,
        database: Option<&str>,
    ) -> AppResult<(ActiveConnection, Option<String>)> {
        let conn = self.active().await?;
        let driver = self.driver(&conn.driver_id)?;
        let active = self.active_database().await;
        let target = driver.resolve_database(&conn.spec, database, active.as_deref())?;
        if let Some(name) = target.as_deref() {
            conn.ensure_visible(name)?;
        }
        if driver.is_file_based() {
            if let Some(name) = database {
                conn.ensure_visible(name)?;
            }
        }
        Ok((conn, target))
    }

    /// 打开一条被固定的会话（P3 Step 1）：SQL 控制台整段脚本共用它。
    ///
    /// 走与 connection_for 完全相同的解析 + 授权路径，然后由驱动/池供给方给出会话；
    /// api 只拿到 Box<dyn SessionHandle>，不再接触内部 PoolSession / ScriptSession。
    pub async fn open_session(
        &self,
        database: Option<&str>,
    ) -> AppResult<Box<dyn crate::core::session::SessionHandle>> {
        let (conn, target) = self.resolve_target(database).await?;
        let driver = self.driver(&conn.driver_id)?;
        driver
            .open_session(&self.pools, &conn.spec, target.as_deref())
            .await
    }

    /// Pool for one explicit physical database.
    ///
    /// Used by the instance-level tree (`list_schemas`) and by the SQL console;
    /// unlike [`connection_for`] it never falls back to the active database.
    pub async fn connection_for_database(
        &self,
        database: &str,
    ) -> AppResult<ConnectionHandle> {
        let conn = self.active().await?;
        let driver = self.driver(&conn.driver_id)?;
        if driver.is_file_based() {
            return self.connection_for(None).await;
        }
        conn.ensure_visible(database)?;
        self.pools.get(&conn.spec, Some(database)).await
    }

    /// 指定 spec 的管理连接句柄（DROP DATABASE 前需要换一个不带默认库的 spec）。
    ///
    /// P5.1：api 不再持有旧门面时，这条路径也要能拿句柄。
    pub async fn admin_connection_for(
        &self,
        spec: &ConnectionConfig,
    ) -> AppResult<(ConnectionHandle, Option<String>)> {
        self.pools.connect_admin(spec).await
    }

    /// 实例级（管理）连接句柄：PostgreSQL 会做「换一个可连库」的回退。
    pub async fn admin_connection(&self) -> AppResult<(ConnectionHandle, Option<String>)> {
        let conn = self.active().await?;
        let driver = self.driver(&conn.driver_id)?;
        driver.admin_connect(&self.pools, &conn.spec).await
    }

    /// Re-bind the active connection after its record changed on disk.
    ///
    /// SQLite attaches the recorded files when a pool is created, so accepting,
    /// hiding or deleting a database file has to drop the cached pools and
    /// reopen. A failed reopen is reported: the connection is unusable at that
    /// point and silently keeping the stale pool would hide it.
    pub async fn refresh_active(&self) -> AppResult<()> {
        let active = self.active().await?;
        self.pools.evict(&active.spec).await;
        // The in-memory binding still holds the *old* spec, so re-reading the
        // stored record is what makes a newly accepted / hidden / deleted file
        // take effect. Validating the stale copy reopened the previous file set
        // and the change appeared to do nothing.
        let fresh = match active.id.as_deref() {
            Some(id) => self.connections.get(id).await,
            None => None,
        };
        let spec = match fresh {
            Some(entry) => {
                let binding = ActiveConnection::from_entry(&entry);
                let updated = ActiveConnection {
                    only_db: active.only_db.clone(),
                    hide_db: active.hide_db.clone(),
                    ..binding
                };
                self.set_active(Some(updated.clone())).await;
                updated.spec
            }
            None => active.spec.clone(),
        };
        self.pools.validate(&spec).await?;
        // `validate` opens a fresh pool but does not cache it, so the next
        // `connection_for` would hand back the evicted-but-still-referenced one. Drop
        // again and cache the new pool so the change is actually visible.
        self.pools.evict(&spec).await;
        let target = self.active_database().await;
        self.pools.get(&spec, target.as_deref()).await?;
        Ok(())
    }

    /// Open a connection, verify it, and make it the active one.
    ///
    /// The instance connection is established through the admin fallback; the
    /// initial database is then chosen from the visible list and warmed. No
    /// database has to be typed into the connection form.
    pub async fn bind_connection(&self, binding: ActiveConnection) -> AppResult<ActiveConnection> {
        let driver = self.driver(&binding.driver_id)?;
        let (admin, admin_database) = self.pools.connect_admin(&binding.spec).await?;
        driver.ping(&admin).await?;

        let initial = if driver.is_file_based() {
            None
        } else {
            let driver = self.driver(&binding.driver_id)?;
            let databases = driver
                .list_instance_databases(&admin)
                .await
                .unwrap_or_default();
            let preferred = initial_database(
                &binding,
                &databases,
                admin_database.as_deref(),
                driver.dialect(),
            );
            match preferred {
                Some(database) => match self.pools.get(&binding.spec, Some(&database)).await {
                    Ok(_) => Some(database),
                    Err(error) => {
                        tracing::warn!("could not open initial database {database}: {error}");
                        admin_database.clone()
                    }
                },
                None => admin_database.clone(),
            }
        };

        if driver.requires_database() && initial.is_none() {
            return Err(AppError::bad(
                "连接成功，但该账号没有可访问的数据库；请填写默认数据库，或调整 only/hide 规则",
            ));
        }
        self.set_active_database(initial).await;
        self.set_active(Some(binding.clone())).await;
        Ok(binding)
    }

    /// Close the active connection and drop its cached pools.
    pub async fn disconnect(&self) -> AppResult<()> {
        if let Some(conn) = self.active.write().await.take() {
            self.pools.evict(&conn.spec).await;
            self.set_active_database(None).await;
        }
        Ok(())
    }

    /// Current preferences. Synchronous so the sync half of the FFI surface
    /// can read them too.
    pub fn settings(&self) -> Settings {
        self.settings
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    /// Backup directory currently in force.
    ///
    /// The directory chosen in the settings when there is one, otherwise
    /// `<data_dir>/backups`. This is what `app_config`, `data_dir` and the
    /// backup store itself must all agree on.
    pub fn effective_backup_dir(&self) -> PathBuf {
        self.config.backup_dir_for(&self.settings())
    }

    pub async fn update_settings(&self, settings: Settings) -> AppResult<Settings> {
        // Store the sanitized value the writer produced, so memory and disk
        // cannot disagree about the effective settings.
        let previous_backup_dir = self.effective_backup_dir();
        let saved = self.config.save_settings(&settings)?;
        let next_backup_dir = self.config.backup_dir_for(&saved);
        // Changing the backup directory is more than a settings write: the
        // store caches its directory and index in memory, so it has to reload
        // them or listings and new dumps keep using the old path. Done before
        // the in-memory settings change, so a failure leaves the reported
        // effective directory consistent with the store.
        if next_backup_dir != previous_backup_dir {
            self.backups.set_dir(next_backup_dir).await?;
        }
        *self
            .settings
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = saved.clone();
        Ok(saved)
    }

    pub async fn data_dir(&self) -> PathBuf {
        self.config.data_dir.clone()
    }
}
