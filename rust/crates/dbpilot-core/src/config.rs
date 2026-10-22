//! 连接配置与驱动标识：core 层的「连接配置」类型。
//!
//! 32 轮 P2 把原本定义在 drivers/mod.rs 的 DriverKind / ConnSpec 搬到这里，
//! 并接管池身份（pool identity）计算 —— 它只依赖配置字段，不依赖任何 sqlx
//! 池类型，放在 core 才不会让 core 反向依赖 drivers。
//!
//! 兼容：
//! * drivers 模块继续 pub use 这两个名字（旧路径 crate::drivers::ConnSpec 仍可用）；
//! * core::connection::ConnectionConfig 是 ConnSpec 的别名，api 只用后者名；
//! * ConnSpec::sqlite_files() 依赖 SQLite 文件扫描，留在 drivers 里做扩展 impl，
//!   保证 core 不依赖具体驱动。

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

use serde::{Deserialize, Serialize};

/// 驱动标识。序列化仍是小写字符串（connections.json 的 driver 字段）。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DriverKind {
    #[default]
    Mysql,
    Postgres,
    Sqlite,
}

impl DriverKind {
    pub fn as_str(self) -> &'static str {
        match self {
            DriverKind::Mysql => "mysql",
            DriverKind::Postgres => "postgres",
            DriverKind::Sqlite => "sqlite",
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            DriverKind::Mysql => "MySQL / MariaDB",
            DriverKind::Postgres => "PostgreSQL",
            DriverKind::Sqlite => "SQLite",
        }
    }
    pub fn default_port(self) -> Option<u16> {
        match self {
            DriverKind::Mysql => Some(3306),
            DriverKind::Postgres => Some(5432),
            DriverKind::Sqlite => None,
        }
    }
    pub fn is_mysql(self) -> bool {
        matches!(self, DriverKind::Mysql)
    }
}

/// Everything needed to open a connection, one entry per saved connection.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ConnSpec {
    pub driver: DriverKind,
    #[serde(default)]
    pub host: String,
    #[serde(default)]
    pub port: Option<u16>,
    #[serde(default)]
    pub user: String,
    #[serde(default)]
    pub password: String,
    /// MySQL/PostgreSQL: default database. SQLite: the database file path.
    #[serde(default)]
    pub database: Option<String>,
    #[serde(default)]
    pub charset: Option<String>,
    #[serde(default)]
    pub ssl_mode: Option<String>,
    /// Certificate verification for MySQL/PostgreSQL: require encrypts but
    /// accepts any certificate, verify-ca validates the chain, verify-full
    /// also matches the host name.
    #[serde(default)]
    pub ssl_verify: Option<String>,
    /// PEM file holding the CA certificate(s) used for verification.
    #[serde(default)]
    pub ssl_ca: Option<String>,
    #[serde(default)]
    pub ssl_cert: Option<String>,
    #[serde(default)]
    pub ssl_key: Option<String>,
    /// SQLite: the folder browsed by this connection.
    ///
    /// A connection is "a folder of database files": every SQLite file inside
    /// it (recursively) is attached and listed, so adding or removing a file on
    /// disk is enough — nothing about the file list is recorded. Empty falls
    /// back to the primary file's folder.
    #[serde(default)]
    pub sqlite_dir: Option<String>,
    /// Optional SSH jump host. Empty ssh_host means a direct connection.
    ///
    /// #[serde(flatten)] 必须随结构体一起搬：connections.json 的 SSH 字段是
    /// 平铺的顶层键，改成嵌套对象会读不出旧文件。
    #[serde(flatten)]
    pub ssh: crate::ssh::SshSpec,
}

/// api 只认这个名字；与 ConnSpec 是同一个类型。
pub type ConnectionConfig = ConnSpec;

impl ConnSpec {
    pub fn port(&self) -> u16 {
        self.port.or_else(|| self.driver.default_port()).unwrap_or(0)
    }

    /// True when this connection is expected to go through an SSH tunnel.
    pub fn uses_ssh(&self) -> bool {
        self.ssh.enabled() && self.driver != DriverKind::Sqlite
    }

    pub fn database(&self) -> Option<&str> {
        self.database.as_deref().map(str::trim).filter(|s| !s.is_empty())
    }

    /// Effective TLS mode. verify-ca / verify-full imply TLS, exactly as
    /// libpq treats them.
    pub fn ssl_mode(&self) -> &str {
        // An explicit "disable" is authoritative: the connection form keeps
        // ssl_verify = verify-full as its idle default while TLS is off, and
        // letting that idle value force TLS made a brand-new local MySQL
        // connection demand certificate verification (the reported P-01).
        let mode = self.ssl_mode.as_deref().unwrap_or("disable").trim().to_ascii_lowercase();
        if mode == "disable" {
            return "disable";
        }
        match self.ssl_verify().as_str() {
            "verify-ca" | "verify-full" => "require",
            _ => self.ssl_mode.as_deref().unwrap_or("disable"),
        }
    }

    pub fn ssl_verify(&self) -> String {
        self.ssl_verify
            .as_deref()
            .unwrap_or("require")
            .trim()
            .to_ascii_lowercase()
    }

    pub fn ssl_ca(&self) -> Option<&str> {
        self.ssl_ca.as_deref().map(str::trim).filter(|s| !s.is_empty())
    }

    pub fn ssl_cert(&self) -> Option<&str> {
        self.ssl_cert.as_deref().map(str::trim).filter(|s| !s.is_empty())
    }

    pub fn ssl_key(&self) -> Option<&str> {
        self.ssl_key.as_deref().map(str::trim).filter(|s| !s.is_empty())
    }

    /// Folder browsed by a SQLite connection.
    ///
    /// Defaults to the primary file's folder, so a connection created by picking
    /// one file still lists its neighbours without extra configuration.
    pub fn sqlite_folder(&self) -> Option<String> {
        if let Some(dir) = self
            .sqlite_dir
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            return Some(dir.to_string());
        }
        let path = self.database()?;
        let parent = std::path::Path::new(path).parent()?;
        let text = parent.to_string_lossy().to_string();
        if text.is_empty() {
            None
        } else {
            Some(text)
        }
    }
}

/// 连接池/隧道缓存的 key（P2-1 从 pools.rs 原样搬来，逻辑逐字未改）。
///
/// 任何会改变「实际连到哪个服务器/哪个库/用什么凭证」的配置都必须进入 key，
/// 否则编辑连接后会复用到旧配置的池。密码只以哈希形式进入 key。
pub fn pool_identity_key(spec: &ConnSpec, database: Option<&str>) -> String {
    // A SQLite pool attaches every file in its folder when it is created, so the
    // folder is part of the pool's identity: pointing the connection at another
    // directory must not hand back the pools of the previous one.
    let folder = if spec.driver == DriverKind::Sqlite {
        spec.sqlite_folder().unwrap_or_default()
    } else {
        String::new()
    };
    let password = {
        let mut hasher = DefaultHasher::new();
        spec.password.hash(&mut hasher);
        hasher.finish()
    };
    format!(
        "{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}",
        spec.driver.as_str(),
        spec.host,
        spec.port(),
        spec.user,
        password,
        spec.charset.as_deref().unwrap_or(""),
        spec.ssl_mode(),
        spec.ssl_verify(),
        spec.ssl_ca().unwrap_or(""),
        spec.ssl_cert().unwrap_or(""),
        spec.ssl_key().unwrap_or(""),
        database.unwrap_or(""),
        format!("{}|{}", spec.database().unwrap_or(""), folder)
    ) + &ssh_identity(spec)
}

/// SSH settings belong to the pool identity: a different jump host, user or
/// authentication method must never reuse a cached pool that was created
/// through the previous tunnel.
fn ssh_identity(spec: &ConnSpec) -> String {
    if !spec.uses_ssh() {
        return String::new();
    }
    format!(
        "|ssh:{}|{}|{}|{}|{:?}|{}|{}",
        spec.ssh.ssh_host.trim(),
        spec.ssh.port(),
        spec.ssh.ssh_user.trim(),
        spec
            .ssh
            .ssh_key
            .as_deref()
            .map(str::trim)
            .unwrap_or(""),
        spec.ssh.ssh_auth,
        spec.ssh.ssh_password.len(),
        spec.ssh
            .ssh_host_key
            .as_deref()
            .map(str::trim)
            .unwrap_or("")
    )
}
