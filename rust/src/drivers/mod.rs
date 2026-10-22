pub mod builtin;
pub mod mysql;
pub mod postgres;
pub mod sqlite;

use base64::Engine as _;
use serde_json::{json, Value};
use std::time::Duration;

use sqlx::mysql::{MySqlPool, MySqlPoolOptions};
use sqlx::pool::PoolConnection;
use sqlx::postgres::{PgConnectOptions, PgPool, PgPoolOptions, PgSslMode};
use sqlx::sqlite::{SqliteConnectOptions, SqlitePool, SqlitePoolOptions};
use sqlx::{MySql, Postgres, Sqlite};

use crate::core::account::AccountAdmin;
use crate::db::{returns_rows, split_statements, ResultSet};
use crate::error::{AppError, AppResult};

// P2-1：DriverKind / ConnSpec 已搬进 core::config；这里保留旧路径的再导出，
// 旧代码 crate::drivers::{ConnSpec, DriverKind} 不需要改。api 新代码请直接用
// crate::core::config（或 core::connection::ConnectionConfig 别名）。
pub use crate::core::config::{ConnSpec, DriverKind};

// 33 轮拆 crate：契约层（DDL DTO / SQL 工具 / 账号 DTO / 隧道落点 / SSH 配置）
// 已独立成 dbpilot_core。这里保留旧路径的再导出，驱动与既有调用点不需要改；
// 具体实现都在 crates/dbpilot-core/src/{spec,sql,account,connection,ssh}.rs。
pub use dbpilot_core::account::{PrivilegeGrant, RoleAttributes, UserChange};
pub use dbpilot_core::connection::TunnelInfo;
pub use dbpilot_core::spec::{
    default_fk_name, fk_constraint_sql, fk_parts, AlterColumn, AlterIndex, AlterTableSpec,
    ColumnDef, CreateTableSpec, ForeignKeyDef, FkParts, RenameColumn,
};
pub use dbpilot_core::sql::{
    create_database_sql, literal, named_from, qi, qualify, quote_str_for, safe_default,
    safe_ident, safe_type,
};
pub use dbpilot_core::ssh::{SshAuth, SshHostKeyPolicy, SshSpec};

/// 账号能力的注册/分派表（P3 Step 4）：`DriverKind` → 静态实现。
///
/// 三个驱动在 `DatabaseDriver::account_admin()` 里都走这张表，新增驱动
/// 只需在这里登记一次。
///
/// SQLite 也登记实现：它的 `supports_accounts()` 是 false，读接口要维持
/// 旧契约（list_db_users → 空列表、user_privileges → supported:false 目录），
/// 写接口则继续返回「SQLite 没有数据库账号」——如果这里返回 None，这两个读
/// 接口会从「正常空结果」变成报错，属于 Dart 契约回退。
pub fn account_admin_for(kind: DriverKind) -> Option<&'static dyn AccountAdmin> {
    match kind {
        DriverKind::Mysql => Some(&mysql::account::MYSQL_ACCOUNT_ADMIN),
        DriverKind::Postgres => Some(&postgres::account::POSTGRES_ACCOUNT_ADMIN),
        DriverKind::Sqlite => Some(&sqlite::account::SQLITE_ACCOUNT_ADMIN),
    }
}

// P2-1/33 轮：SQLite 文件扫描依赖具体驱动，留在这里；拆 crate 后 ConnSpec
// 是外部类型，不能再写 inherent impl，因此改成自由函数。
/// Database files attached to the pool: every SQLite file in the connection
/// folder except the primary one.
///
/// Nothing is persisted here. The folder is the connection's state, so a
/// file the user drops in (or deletes) is picked up on the next refresh
/// instead of leaving a stale "known files" list behind.
pub fn sqlite_files(spec: &ConnSpec) -> Vec<String> {
    let Some(folder) = spec.sqlite_folder() else {
        return Vec::new();
    };
    let primary = spec.database().unwrap_or("");
    sqlite::scan_folder(std::path::Path::new(&folder), 500, 6)
        .into_iter()
        .map(|p| p.to_string_lossy().to_string())
        .filter(|p| !sqlite::same_path(p, primary))
        // SQLite limits how many databases a connection may have ATTACHed
        // (SQLITE_MAX_ATTACHED, 10 by default). Trying more fails for the
        // extra files, so only the first few are attached; the database
        // page lists the rest as "not opened" with the reason.
        .take(sqlite::MAX_ATTACHED)
        .collect()
}

#[derive(Clone)]
pub enum Pool {
    MySql(MySqlPool),
    Postgres(PgPool),
    Sqlite(SqlitePool),
}

impl Pool {
    pub async fn close(&self) {
        match self {
            Pool::MySql(p) => p.close().await,
            Pool::Postgres(p) => p.close().await,
            Pool::Sqlite(p) => p.close().await,
        }
    }
    pub fn is_closed(&self) -> bool {
        match self {
            Pool::MySql(p) => p.is_closed(),
            Pool::Postgres(p) => p.is_closed(),
            Pool::Sqlite(p) => p.is_closed(),
        }
    }
}

/// `SqlSession` 的内部实现：持有一条 sqlx 池（以及可选 SSH 隧道落点）。
///
/// 33 轮删除了 `Db` 门面：`PoolRegistry` / `AppState` / api 一律直接持有
/// [`crate::core::connection::ConnectionHandle`]，本类型只在 crate 内部构造，
/// 从不出现在公开签名里；集成测试用 [`pooled_handle`] 从池构造句柄。
#[derive(Clone)]
pub(crate) struct PoolSession {
    pub(crate) pool: Pool,
    pub(crate) driver: DriverKind,
    /// Set when the connection was dialled through an SSH tunnel.
    pub(crate) tunnel: Option<TunnelInfo>,
}

impl PoolSession {
    /// 把内部会话包成 api 唯一认识的句柄（一次 Arc 分配，不新建连接）。
    pub(crate) fn into_handle(self) -> crate::core::connection::ConnectionHandle {
        crate::core::connection::ConnectionHandle::new(std::sync::Arc::new(self))
    }
}

/// 从一条已经打开的池构造 [`crate::core::connection::ConnectionHandle`]。
///
/// 公开是给集成测试用的（它们从 `drivers::connect*` 拿到裸池）；应用代码
/// 一律通过 `PoolRegistry` 取句柄，不直接构造内部会话。
pub fn pooled_handle(
    pool: Pool,
    driver: DriverKind,
    tunnel: Option<TunnelInfo>,
) -> crate::core::connection::ConnectionHandle {
    PoolSession {
        pool,
        driver,
        tunnel,
    }
    .into_handle()
}

/// Render a MySQL `'user'@'host'` account reference.
fn mysql_account(driver: DriverKind, user: &str, host: &str) -> String {
    format!(
        "{}@{}",
        quote_str_for(driver, user),
        quote_str_for(driver, host)
    )
}

/// Validate the account name pair before it reaches a statement.
pub(crate) fn check_account_name(user: &str, host: &str) -> AppResult<()> {
    if user.trim().is_empty() {
        return Err(AppError::bad("用户名不能为空"));
    }
    if user.contains('\0') || host.contains('\0') {
        return Err(AppError::bad("用户名/主机名包含非法字符"));
    }
    Ok(())
}

/// Names that must never be dropped or renamed through the account editor.
pub(crate) fn guard_system_account(user: &str) -> AppResult<()> {
    let lower = user.trim().to_ascii_lowercase();
    if lower == "root" || lower == "postgres" || lower.starts_with("pg_") {
        return Err(AppError::bad(format!(
            "拒绝删除或重命名系统账号 '{}'；如确需操作请使用 SQL 控制台",
            user
        )));
    }
    Ok(())
}

// ---------------------------------------------------------------- connecting

/// One resolved endpoint: where the driver should actually connect, plus the
/// tunnel that must stay alive for the pool to keep working.
pub struct DialTarget {
    pub host: String,
    pub port: u16,
    /// Kept for the lifetime of the pool: dropping it closes the local port.
    pub tunnel: Option<crate::ssh::SshTunnel>,
}

impl std::fmt::Debug for DialTarget {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DialTarget")
            .field("host", &self.host)
            .field("port", &self.port)
            .field("tunnelled", &self.tunnel.is_some())
            .finish()
    }
}

/// Resolve the address the driver should dial.
///
/// Without SSH this is just the configured host/port. With SSH the jump host
/// dials host:port (resolved on the jump host), and we connect to a local
/// 127.0.0.1 port instead. The database's host is therefore relative to the
/// jump host, which is what lets a database bound to the remote loopback work.
pub async fn dial_target(spec: &ConnSpec) -> AppResult<DialTarget> {
    let host = spec.host.trim().to_string();
    let port = spec.port();
    if !spec.uses_ssh() {
        return Ok(DialTarget { host, port, tunnel: None });
    }
    if host.is_empty() {
        return Err(AppError::bad("SSH 隧道需要填写数据库服务器地址（从跳板机视角）"));
    }
    let tunnel = crate::ssh::open(&spec.ssh, &host, port, Duration::from_secs(20)).await?;
    Ok(DialTarget {
        host: tunnel.local_addr.ip().to_string(),
        port: tunnel.local_addr.port(),
        tunnel: Some(tunnel),
    })
}

/// True when MySQL refused the *database* (1044) rather than the login.
///
/// The two are easy to conflate: both arrive as "Access denied", but 1044 means
/// the account is authenticated and simply has no GRANT on this schema, so the
/// message must not claim the connection itself failed.
fn is_database_permission_error(error: &sqlx::Error) -> bool {
    let sqlx::Error::Database(db) = error else {
        return false;
    };
    if db
        .try_downcast_ref::<sqlx::mysql::MySqlDatabaseError>()
        .is_some_and(|mysql_error| mysql_error.number() == 1044)
    {
        return true;
    }
    db.code().as_deref() == Some("42000") && db.message().contains("to database")
}

/// N-02: MySQL 8.0 + `caching_sha2_password` may refuse a plaintext login
/// even though the same credentials work over TLS or as
/// `mysql_native_password`. Point at the two practical fixes instead of
/// leaving the user with a bare "Access denied".
fn mysql_plaintext_auth_hint(spec: &ConnSpec, error: &sqlx::Error) -> Option<&'static str> {
    if !matches!(mysql::ssl_mode_for(spec), sqlx::mysql::MySqlSslMode::Disabled) {
        return None;
    }
    plaintext_auth_hint_for(&crate::error::database_message(error))
}

/// The TLS advice, only for a *login* rejection.
///
/// The decision is made on the already-normalised message rather than the raw
/// driver text because `clean_database_error` rewrites both cases into Chinese:
/// "用户名或密码不正确…" (1045) versus "当前数据库账号没有访问该数据库的权限…"
/// (1044). Appending the caching_sha2/TLS advice to the latter sent users
/// chasing certificate settings for a missing GRANT — reported with a `web`
/// account that only owned its own schema.
fn plaintext_auth_hint_for(message: &str) -> Option<&'static str> {
    let database_level = message.contains("没有访问该数据库的权限")
        || message.contains("to database")
        || message.contains("cannot be accessed");
    if database_level {
        return None;
    }
    let authentication_level = message.contains("用户名或密码不正确")
        || message.contains("using password")
        || message.contains("caching_sha2");
    if authentication_level {
        Some(
            "（提示：MySQL 8.0 的 caching_sha2_password 账号在未加密连接下可能认证失败；请到 SSL 标签页启用 TLS，或把该账号改为 mysql_native_password）",
        )
    } else {
        None
    }
}

/// Copy of a spec pointed at the local forwarded endpoint.
fn with_endpoint(spec: &ConnSpec, host: &str, port: u16) -> ConnSpec {
    let mut copy = spec.clone();
    copy.host = host.to_string();
    copy.port = Some(port);
    // SSH was already consumed by dial_target; clearing it stops a recursive
    // tunnel being opened for the local forwarded port.
    copy.ssh = crate::ssh::SshSpec::default();
    copy
}

pub async fn connect(spec: &ConnSpec, database: Option<&str>) -> AppResult<Pool> {
    Ok(connect_full(spec, database).await?.0)
}

/// Like [connect], but also reports the tunnel endpoint/fingerprint so callers
/// such as the connection probe can display and persist the jump host key.
pub async fn connect_full(
    spec: &ConnSpec,
    database: Option<&str>,
) -> AppResult<(Pool, Option<TunnelInfo>)> {
    let target = dial_target(spec).await?;
    connect_via(spec, database, target).await
}

/// Connect through an already-resolved endpoint.
///
/// The tunnel is moved into the global tunnel registry for the lifetime of the
/// pool; pool eviction releases it together with the pool. The returned
/// [TunnelInfo] is a copy of what was registered, so the caller can report it
/// without opening another tunnel.
pub async fn connect_via(
    spec: &ConnSpec,
    database: Option<&str>,
    target: DialTarget,
) -> AppResult<(Pool, Option<TunnelInfo>)> {
    let host = target.host.clone();
    let port = target.port;
    let tunnel_info = target.tunnel.as_ref().map(|tunnel| TunnelInfo {
        host: tunnel.local_addr.ip().to_string(),
        port: tunnel.local_addr.port(),
        fingerprint: tunnel.host_key_fingerprint.clone(),
    });
    if let Some(tunnel) = target.tunnel {
        crate::pools::register_tunnel(port, tunnel);
    }
    let spec = &with_endpoint(spec, &host, port);
    match spec.driver {
        DriverKind::Mysql => {
            // Build the options object rather than a URL: ssl-mode and the
            // certificate files cannot be expressed safely in a URL, and the URL
            // form used to hard-code `ssl-mode=DISABLED` (so a "require"
            // connection silently ran in plaintext).
            let mut opts = mysql::connect_options(spec, database)?;
            opts = opts.ssl_mode(mysql::ssl_mode_for(spec));
            let pool = MySqlPoolOptions::new()
                .max_connections(5)
                .acquire_timeout(Duration::from_secs(15))
                // Fix the string-escaping contract for this pool. The app
                // renders literals by doubling backslashes, which is only
                // correct when the server treats backslash as an escape
                // character. A server or user session with
                // NO_BACKSLASH_ESCAPES would read those doubled slashes
                // literally, so every connection removes that one flag while
                // keeping the rest of sql_mode untouched. Without this, the
                // same data silently matches/writes differently depending on
                // the server configuration.
                .after_connect(|conn, _meta| {
                    Box::pin(async move {
                        const SQL: &str = "SET SESSION sql_mode = REPLACE(@@SESSION.sql_mode, 'NO_BACKSLASH_ESCAPES', '')";
                        sqlx::query(SQL).execute(&mut *conn).await?;
                        Ok(())
                    })
                })
                .connect_with(opts)
                .await
                .map_err(|e| {
                    // A rejected database (MySQL 1044) is a permission problem on
                    // one schema, not a transport problem: route it through the
                    // same normalisation the query path uses so the user sees
                    // which GRANT is missing. Naming the database keeps it from
                    // reading as "the whole connection failed", which is how a
                    // limited account's error looked in the sidebar.
                    let detail = crate::error::database_message(&e);
                    let message = match database {
                        Some(name) if is_database_permission_error(&e) => {
                            format!("无法打开数据库 {name}：{detail}")
                        }
                        _ => format!("MySQL 连接失败：{detail}"),
                    };
                    let mut message = message;
                    if let Some(hint) = mysql_plaintext_auth_hint(spec, &e) {
                        message.push_str(hint);
                    }
                    AppError::BadRequest(message)
                })?;
            Ok((Pool::MySql(pool), tunnel_info))
        }
        DriverKind::Postgres => {
            let db = database.or_else(|| spec.database());
            let mut opts = PgConnectOptions::new()
                .host(spec.host.trim())
                .port(spec.port())
                .username(spec.user.trim())
                .password(&spec.password)
                .ssl_mode(match spec.ssl_mode() {
                    "verify-full" => PgSslMode::VerifyFull,
                    "verify-ca" => PgSslMode::VerifyCa,
                    "require" => PgSslMode::Require,
                    // libpq semantics: try plaintext first, then TLS if the
                    // server asks for it. MySQL has no equivalent, so this
                    // value only ever arrives from a PostgreSQL connection.
                    "allow" => PgSslMode::Allow,
                    "prefer" => PgSslMode::Prefer,
                    _ => PgSslMode::Disable,
                });
            // Certificate verification. `require` alone accepted any
            // certificate, so it encrypted without preventing a MITM.
            match spec.ssl_verify().as_str() {
                "verify-full" => opts = opts.ssl_mode(PgSslMode::VerifyFull),
                "verify-ca" => opts = opts.ssl_mode(PgSslMode::VerifyCa),
                _ => {}
            }
            if let Some(ca) = spec.ssl_ca() {
                opts = opts.ssl_root_cert(ca);
            }
            if let Some(cert) = spec.ssl_cert() {
                opts = opts.ssl_client_cert(cert);
            }
            if let Some(key) = spec.ssl_key() {
                opts = opts.ssl_client_key(key);
            }
            if let Some(db) = db {
                opts = opts.database(db);
            }
            let pool = PgPoolOptions::new()
                .max_connections(5)
                .acquire_timeout(Duration::from_secs(15))
                .connect_with(opts)
                .await
                .map_err(|e| {
                    AppError::BadRequest(format!(
                        "PostgreSQL 连接失败：{}",
                        crate::error::database_message(&e)
                    ))
                })?;
            Ok((Pool::Postgres(pool), tunnel_info))
        }
        DriverKind::Sqlite => {
            let path = spec
                .database()
                .ok_or_else(|| AppError::bad("SQLite connections require a database file path"))?;
            // Do not create the file implicitly: a database that disappeared
            // (deleted, volume unmounted, folder renamed) must be reported as
            // missing instead of silently becoming a new empty database.
            if !std::path::Path::new(path).exists() {
                return Err(AppError::not_found(format!("数据库文件不存在：{path}")));
            }
            let opts = SqliteConnectOptions::new()
                .filename(path)
                .create_if_missing(true)
                .busy_timeout(Duration::from_secs(10));
            // Attach the additional database files on every pooled connection:
            // a pool reopens connections, so running ATTACH once up front would
            // leave later connections without the attached schemas and queries
            // would fail with "no such table" seemingly at random.
            let mut attach: Vec<String> = Vec::new();
            for (index, file) in sqlite_files(spec).into_iter().enumerate() {
                let alias = sqlite::alias_for(&file, index);
                attach.push(format!(
                    "ATTACH DATABASE {} AS {}",
                    crate::db::quote_str(&file),
                    qi(DriverKind::Sqlite, &alias)
                ));
            }
            let mut pool_opts = SqlitePoolOptions::new()
                .max_connections(5)
                .acquire_timeout(Duration::from_secs(15));
            if !attach.is_empty() {
                pool_opts = pool_opts.after_connect(move |conn, _meta| {
                    let statements = attach.clone();
                    Box::pin(async move {
                        for stmt in statements {
                            // One unusable file must not take the whole
                            // connection down: a corrupted or half-written
                            // database made ATTACH fail, which surfaced as
                            // "pool timed out while waiting for an open
                            // connection" and hid the real cause. Skip it and
                            // let the database page report the file.
                            if let Err(e) = sqlx::query(&stmt).execute(&mut *conn).await {
                                tracing::warn!("sqlite attach skipped: {stmt}: {e}");
                            }
                        }
                        Ok(())
                    })
                });
            }
            let pool = pool_opts
                .connect_with(opts)
                .await
                .map_err(|e| AppError::BadRequest(format!("SQLite connection failed: {e}")))?;
            Ok((Pool::Sqlite(pool), tunnel_info))
        }
    }
}

// ---------------------------------------------------------------- facade impl

impl PoolSession {
    /// 执行一条语句（唯一实现；下面的 trait impl 与固定会话共用）。
    async fn run_one(&self, stmt: String) -> ResultSet {
        match &self.pool {
            Pool::MySql(p) => mysql::run_one(p, stmt).await,
            Pool::Postgres(p) => postgres::run_one(p, stmt).await,
            Pool::Sqlite(p) => sqlite::run_one(p, stmt).await,
        }
    }

    /// 执行一条语句并限制返回行数（SQL 控制台用）。
    async fn run_one_limited(&self, stmt: String, max_rows: usize) -> ResultSet {
        match &self.pool {
            Pool::MySql(p) => crate::drivers::mysql::exec::run_one_limited(p, stmt, max_rows).await,
            Pool::Postgres(p) => postgres::run_one_limited(p, stmt, max_rows).await,
            Pool::Sqlite(p) => sqlite::run_one_limited(p, stmt, max_rows).await,
        }
    }
}

// ------------------------------------------------- core trait impl (32 轮)

/// `PoolSession` 是 `SqlSession` 的唯一实现：api 只持有 `ConnectionHandle`，
/// 底下是现有 sqlx 池。门面方法已在 33 轮全部删除（池类型不离开本模块）。
#[async_trait::async_trait]
impl crate::core::connection::SqlSession for PoolSession {
    fn driver_id(&self) -> &'static str {
        self.driver.as_str()
    }

    fn dialect(&self) -> &dyn crate::core::dialect::DatabaseDialect {
        crate::drivers::builtin::dialect_for(self.driver)
    }

    async fn execute(&self, sql: &str) -> ResultSet {
        self.run_one(sql.to_string()).await
    }

    async fn execute_limited(&self, sql: &str, max_rows: usize) -> (ResultSet, bool) {
        let result = self.run_one_limited(sql.to_string(), max_rows).await;
        let truncated = result.truncated;
        (result, truncated)
    }

    async fn execute_raw(&self, sql: &str) -> ResultSet {
        match &self.pool {
            // 只有 MySQL 需要文本协议（prepared 拒绝存储过程/触发器/账号 DDL）。
            Pool::MySql(pool) => crate::drivers::mysql::exec::run_raw(pool, sql.to_string()).await,
            _ => self.run_one(sql.to_string()).await,
        }
    }

    async fn close(&self) {
        self.pool.close().await;
    }

    fn tunnel(&self) -> Option<TunnelInfo> {
        self.tunnel.clone()
    }

    async fn scan_rows_boxed<'a>(
        &'a self,
        sql: &'a str,
        on_row: Box<crate::core::connection::RowFn<'a>>,
    ) -> AppResult<crate::db::ScanStats> {
        let stmt = sql.trim().to_string();
        if stmt.is_empty() {
            return Err(AppError::bad("导出语句不能为空"));
        }
        match &self.pool {
            Pool::MySql(p) => crate::drivers::mysql::exec::scan_rows(p, stmt, on_row).await,
            Pool::Postgres(p) => postgres::scan_rows(p, stmt, on_row).await,
            Pool::Sqlite(p) => sqlite::scan_rows(p, stmt, on_row).await,
        }
    }

    async fn probe_insert(&self, insert: &str, select: &str) -> AppResult<Value> {
        match &self.pool {
            Pool::MySql(p) => mysql::probe_insert(p, insert, select).await,
            Pool::Postgres(p) => postgres::probe_insert(p, insert, select).await,
            Pool::Sqlite(p) => sqlite::probe_insert(p, insert, select).await,
        }
    }
}

// ------------------------------------------------------- console script session

/// The live connection pinned for one SQL-console script.
pub enum SessionConn {
    MySql(PoolConnection<MySql>),
    Postgres(PoolConnection<Postgres>),
    Sqlite(PoolConnection<Sqlite>),
}

/// One connection held for the duration of a multi-statement console run.
///
/// Session state (`SET FOREIGN_KEY_CHECKS=0`, user variables, `LOCK TABLES`,
/// `SET search_path`) belongs to the connection it was set on. The console used
/// to ask the pool for a connection per statement, so the next statement could
/// run on a different session and silently lose that state (P3/P5): a dump with
/// `SET FOREIGN_KEY_CHECKS=0` plus forward foreign keys failed, and
/// `SET @OLD_*=@@...` read NULL at the end. Pinning one connection makes a
/// multi-statement run behave like the mysql/psql CLI.
pub struct ScriptSession {
    db: PoolSession,
    conn: Option<SessionConn>,
}

// P3 Step 3：`Db::script_session()` 已删除 —— 外部（pools / api）一律通过
// `core::SessionHandle`，构造入口只有 `ScriptSession::open`（crate 内部）。
impl ScriptSession {
    /// Pin one connection for a multi-statement script.
    pub(crate) async fn open(db: PoolSession) -> AppResult<ScriptSession> {
        let conn = Self::acquire(&db).await?;
        Ok(ScriptSession {
            db,
            conn: Some(conn),
        })
    }

    /// Acquire the driver-specific connection wrapper.
    async fn acquire(db: &PoolSession) -> AppResult<SessionConn> {
        let error = |e: sqlx::Error| AppError::bad(crate::error::database_message(&e));
        match &db.pool {
            Pool::MySql(p) => p.acquire().await.map(SessionConn::MySql).map_err(error),
            Pool::Postgres(p) => p
                .acquire()
                .await
                .map(SessionConn::Postgres)
                .map_err(error),
            Pool::Sqlite(p) => p.acquire().await.map(SessionConn::Sqlite).map_err(error),
        }
    }

    /// Close the pinned connection and forget it.
    ///
    /// Used before evicting a pool whose connection we are holding: sqlx's
    /// `Pool::close()` waits for checked-out connections, so evicting first
    /// would deadlock. The next `run_limited` re-acquires from the pool.
    pub async fn release(&mut self) {
        if let Some(conn) = self.conn.take() {
            match conn {
                SessionConn::MySql(c) => {
                    let _ = c.close().await;
                }
                SessionConn::Postgres(c) => {
                    let _ = c.close().await;
                }
                SessionConn::Sqlite(c) => {
                    let _ = c.close().await;
                }
            }
        }
    }

    /// Run one statement with a row cap, on the pinned connection.
    pub async fn run_limited(&mut self, stmt: String, max_rows: usize) -> ResultSet {
        let conn = match self.conn.take() {
            Some(conn) => conn,
            None => match ScriptSession::acquire(&self.db).await {
                Ok(conn) => conn,
                Err(error) => return session_error_result(stmt, error.to_string()),
            },
        };
        // Move the connection into the runner and take it back. sqlx's futures
        // borrow `&mut Connection`, and a `&mut` parameter would make rustc
        // require `Send` for every reborrow lifetime, which sqlx's Executor impl
        // cannot satisfy (see drivers::mysql::exec::run_one_limited_owned).
        let (result, truncated, conn) = match conn {
            SessionConn::MySql(conn) => {
                let raw_pool = match &self.db.pool {
                    Pool::MySql(pool) => pool,
                    // Unreachable: the connection variant and the driver agree.
                    _ => {
                        let _ = conn.close().await;
                        return session_error_result(
                            stmt,
                            "内部错误：MySQL 会话与连接池类型不一致".to_string(),
                        );
                    }
                };
                let (result, truncated, conn) =
                    crate::drivers::mysql::exec::run_one_limited_owned(conn, raw_pool, stmt, max_rows).await;
                (result, truncated, SessionConn::MySql(conn))
            }
            SessionConn::Postgres(conn) => {
                let (result, truncated, conn) =
                    postgres::run_one_limited_owned(conn, stmt, max_rows).await;
                (result, truncated, SessionConn::Postgres(conn))
            }
            SessionConn::Sqlite(conn) => {
                let (result, truncated, conn) =
                    sqlite::run_one_limited_owned(conn, stmt, max_rows).await;
                (result, truncated, SessionConn::Sqlite(conn))
            }
        };
        if truncated {
            // Closing the socket stops the server-side stream instead of letting
            // sqlx drain (and decode) rows the console will never show. The next
            // statement re-acquires a fresh connection.
            match conn {
                SessionConn::MySql(c) => {
                    let _ = c.close().await;
                }
                SessionConn::Postgres(c) => {
                    let _ = c.close().await;
                }
                SessionConn::Sqlite(c) => {
                    let _ = c.close().await;
                }
            }
        } else {
            self.conn = Some(conn);
        }
        result
    }

    /// Default schema of the pinned session.
    ///
    /// PostgreSQL's `SET search_path` lives on the session, so reading it from
    /// the pool (a different connection) would report the old value.
    pub async fn search_path(&mut self) -> String {
        // 方言给 SQL（SQLite 直接返回 main，不额外查询），不再 match 驱动族。
        let dialect = crate::drivers::builtin::dialect_for(self.db.driver);
        let Some(sql) = dialect.current_schema_sql() else {
            return "main".to_string();
        };
        let result = self.run_limited(sql.to_string(), 10).await;
        if result.error.is_none() {
            if let Some(value) = result.rows.first().and_then(|row| row.first()) {
                return match value {
                    Value::String(text) => text.clone(),
                    other => other.to_string(),
                };
            }
        }
        String::new()
    }
}

/// P3 Step 1/2：api 只认 `core::session::SessionHandle`，实现在这里。
///
/// `run_limited` / `search_path` / `release` 的语义与原来的固有方法逐字一致，
/// 只是换了调用面；池类型（SessionConn）仍不离开本模块。
#[async_trait::async_trait]
impl crate::core::session::SessionHandle for ScriptSession {
    fn driver_id(&self) -> &'static str {
        self.db.driver.as_str()
    }

    async fn run_limited(&mut self, statement: String, max_rows: usize) -> ResultSet {
        ScriptSession::run_limited(self, statement, max_rows).await
    }

    async fn search_path(&mut self) -> String {
        ScriptSession::search_path(self).await
    }

    async fn release(&mut self) {
        ScriptSession::release(self).await
    }
}

fn session_error_result(stmt: String, message: String) -> ResultSet {
    ResultSet {
        columns: Vec::new(),
        rows: Vec::new(),
        row_count: 0,
        last_insert_id: 0,
        statement: stmt,
        kind: "error".to_string(),
        error: Some(message),
        truncated: false,
    }
}

pub fn bytes_json(bytes: &[u8]) -> Value {
    json!({
        "__binary__": base64::engine::general_purpose::STANDARD.encode(bytes),
        "len": bytes.len(),
    })
}

/// Build the normalized column object shared by every driver and the UI.
#[allow(clippy::too_many_arguments)]
pub fn column_json(
    name: &str,
    data_type: &str,
    column_type: &str,
    nullable: &str,
    default: Value,
    key: &str,
    extra: &str,
    comment: &str,
    charset: Value,
    collation: Value,
    position: i64,
    precision: Value,
    scale: Value,
) -> Value {
    json!({
        "name": name,
        "type_name": column_type,
        "COLUMN_NAME": name,
        "DATA_TYPE": data_type,
        "COLUMN_TYPE": column_type,
        "IS_NULLABLE": nullable,
        "COLUMN_DEFAULT": default,
        "COLUMN_KEY": key,
        "EXTRA": extra,
        "COLUMN_COMMENT": comment,
        "CHARACTER_SET_NAME": charset,
        "COLLATION_NAME": collation,
        "ORDINAL_POSITION": position,
        "NUMERIC_PRECISION": precision,
        "NUMERIC_SCALE": scale,
    })
}

pub fn statement_count(sql: &str) -> usize {
    split_statements(sql).len()
}

pub fn statement_returns_rows(sql: &str) -> bool {
    returns_rows(sql)
}


#[cfg(test)]
mod wording_tests {
    use super::*;

    #[test]
    fn tls_hint_only_for_login_failures() {
        // 1045 (bad password) is normalised to this sentence by
        // clean_database_error; it is the one case the TLS advice is for.
        assert!(plaintext_auth_hint_for(
            "用户名或密码不正确，或该账号不允许从当前主机登录。"
        )
        .is_some());
        // 1044 means "authenticated but no GRANT on this schema": the advice
        // would send the user chasing certificates for a privilege problem.
        assert!(plaintext_auth_hint_for(
            "当前数据库账号没有访问该数据库的权限。请让管理员执行 GRANT ... ON 该库.* TO 该账号，或改用有权限的账号连接。"
        )
        .is_none());
        // Anything unrelated gets no advice either.
        assert!(plaintext_auth_hint_for("表不存在").is_none());
    }

    #[test]
    fn database_prefix_is_applied_once() {
        let message = crate::error::AppError::bad("没有访问该数据库的权限")
            .for_database("mysql")
            .to_string();
        assert_eq!(message, "无法打开数据库 mysql：没有访问该数据库的权限");
        // The driver layer may already have named the database; stacking the
        // prefix twice is what made the banner unreadable in review.
        let twice = crate::error::AppError::bad(&message)
            .for_database("mysql")
            .to_string();
        assert_eq!(twice, message);
    }
}
