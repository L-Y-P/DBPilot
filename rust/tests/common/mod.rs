//! 环境变量驱动的测试端点 helper。
//!
//! 开源仓库里不允许出现任何真实的账号 / 密码 / 数据库地址字面量，所以 live
//! 测试需要的端点全部从环境变量读取，缺省值只是“本地开发常见的默认值”：
//!
//!   MySQL       DBPILOT_TEST_MYSQL_HOST     默认 127.0.0.1
//!               DBPILOT_TEST_MYSQL_PORT     默认 3306
//!               DBPILOT_TEST_MYSQL_USER     默认 root
//!               DBPILOT_TEST_MYSQL_PASSWORD 默认 空
//!               DBPILOT_TEST_MYSQL_DB       默认 rustmyadmin_demo
//!
//!   PostgreSQL  DBPILOT_TEST_PG_HOST        默认 127.0.0.1
//!               DBPILOT_TEST_PG_PORT        默认 5432
//!               DBPILOT_TEST_PG_USER        默认 postgres
//!               DBPILOT_TEST_PG_PASSWORD    默认 空
//!               DBPILOT_TEST_PG_DB          默认 rustmyadmin_demo
//!
//!   TLS fixture（tools/tls_fixture.sh 起的临时实例）
//!               DBPILOT_TLS_MYSQL_HOST / _PORT / _USER / _PASSWORD
//!               DBPILOT_TLS_PG_HOST    / _PORT / _USER / _PASSWORD
//!
//! 本地要跑 live 套件时，先 `source` 一个自己的 .env（或直接 export），例如：
//!
//!   DBPILOT_TEST_MYSQL_PASSWORD=... cargo test --test live_databases -- --ignored
//!
//! 默认密码是空字符串：docker-compose.live.yml 起的 MySQL 用
//! MYSQL_ALLOW_EMPTY_PASSWORD、PostgreSQL 用 trust 认证，因此“刚起的库 + 空密码”
//! 开箱即可跑，仓库里也就不需要任何密码常量。
//!
//! 注意：`tests/common/mod.rs` 放在子目录里，cargo 不会把它当成独立的测试目标，
//! 各测试用 `mod common;` 引入即可。

#![allow(dead_code)]

/// 读环境变量，未设置时用默认值。
pub fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

/// 读环境变量，未设置时用默认值（数字版）。
pub fn env_u16(key: &str, default: u16) -> u16 {
    std::env::var(key)
        .ok()
        .and_then(|value| value.trim().parse().ok())
        .unwrap_or(default)
}

/// 读密码类环境变量：未设置或为空都当空密码处理（很多本地实例就是空密码）。
pub fn env_secret(key: &str) -> String {
    std::env::var(key).unwrap_or_default()
}

/// MySQL 端点。
pub struct MysqlEndpoint {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub database: String,
}

/// 从 DBPILOT_TEST_MYSQL_* 读取 MySQL 端点。
pub fn mysql() -> MysqlEndpoint {
    MysqlEndpoint {
        host: env_or("DBPILOT_TEST_MYSQL_HOST", "127.0.0.1"),
        port: env_u16("DBPILOT_TEST_MYSQL_PORT", 3306),
        user: env_or("DBPILOT_TEST_MYSQL_USER", "root"),
        password: env_secret("DBPILOT_TEST_MYSQL_PASSWORD"),
        database: env_or("DBPILOT_TEST_MYSQL_DB", "rustmyadmin_demo"),
    }
}

/// PostgreSQL 端点。
pub struct PgEndpoint {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub database: String,
}

/// 从 DBPILOT_TEST_PG_* 读取 PostgreSQL 端点。
pub fn postgres() -> PgEndpoint {
    PgEndpoint {
        host: env_or("DBPILOT_TEST_PG_HOST", "127.0.0.1"),
        port: env_u16("DBPILOT_TEST_PG_PORT", 5432),
        user: env_or("DBPILOT_TEST_PG_USER", "postgres"),
        password: env_secret("DBPILOT_TEST_PG_PASSWORD"),
        database: env_or("DBPILOT_TEST_PG_DB", "rustmyadmin_demo"),
    }
}

/// 一个 TLS fixture 端点（tools/tls_fixture.sh 起的临时实例）。
///
/// fixture 脚本把随机生成的密码写进 <fixture 目录>/credentials.env，测试从
/// 环境变量读取；fixture 没起时这些变量为空，测试按 SKIP 处理。
pub struct TlsEndpoint {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
}

/// TLS fixture 的 MySQL 端点（普通 TLS 账号，默认 tlstest）。
pub fn tls_mysql() -> TlsEndpoint {
    TlsEndpoint {
        host: env_or("DBPILOT_TLS_MYSQL_HOST", "127.0.0.1"),
        port: env_u16("DBPILOT_TLS_MYSQL_PORT", 3307),
        user: env_or("DBPILOT_TLS_MYSQL_USER", "tlstest"),
        password: env_secret("DBPILOT_TLS_MYSQL_PASSWORD"),
    }
}

/// TLS fixture 的 MySQL mTLS 账号（REQUIRE X509，默认 mtlstest）。
pub fn tls_mysql_mtls() -> TlsEndpoint {
    TlsEndpoint {
        user: env_or("DBPILOT_TLS_MYSQL_MTLS_USER", "mtlstest"),
        password: env_secret("DBPILOT_TLS_MYSQL_MTLS_PASSWORD"),
        ..tls_mysql()
    }
}

/// TLS fixture 的“无 SAN”MySQL 账号（verify-ca 回归用，默认 nosantest）。
pub fn tls_mysql_nosan() -> TlsEndpoint {
    TlsEndpoint {
        port: env_u16("DBPILOT_TLS_NOSAN_PORT", 3308),
        user: env_or("DBPILOT_TLS_NOSAN_USER", "nosantest"),
        password: env_secret("DBPILOT_TLS_NOSAN_PASSWORD"),
        ..tls_mysql()
    }
}

/// TLS fixture 的 PostgreSQL 端点（默认 postgres 角色）。
pub fn tls_postgres() -> TlsEndpoint {
    TlsEndpoint {
        host: env_or("DBPILOT_TLS_PG_HOST", "127.0.0.1"),
        port: env_u16("DBPILOT_TLS_PG_PORT", 5434),
        user: env_or("DBPILOT_TLS_PG_USER", "postgres"),
        password: env_secret("DBPILOT_TLS_PG_PASSWORD"),
    }
}

/// TLS fixture 的 PostgreSQL mTLS 角色（cert 认证，默认 mtlstest）。
pub fn tls_postgres_mtls() -> TlsEndpoint {
    TlsEndpoint {
        user: env_or("DBPILOT_TLS_PG_MTLS_USER", "mtlstest"),
        password: env_secret("DBPILOT_TLS_PG_MTLS_PASSWORD"),
        ..tls_postgres()
    }
}

/// 探测某个 host:port 是否可连（live 测试用它决定 SKIP 还是真跑）。
pub fn port_open(host: &str, port: u16) -> bool {
    use std::net::{TcpStream, ToSocketAddrs};
    use std::time::Duration;
    let Ok(mut addrs) = (host, port).to_socket_addrs() else {
        return false;
    };
    match addrs.next() {
        Some(addr) => TcpStream::connect_timeout(&addr, Duration::from_millis(800)).is_ok(),
        None => false,
    }
}

/// MySQL 是否在跑（只看端口，不做认证；适合纯网络类判断）。
pub fn mysql_available() -> bool {
    let endpoint = mysql();
    port_open(&endpoint.host, endpoint.port)
}

/// PostgreSQL 是否在跑（只看端口，不做认证）。
pub fn postgres_available() -> bool {
    let endpoint = postgres();
    port_open(&endpoint.host, endpoint.port)
}

/// 把 user / password 里的特殊字符转义成 URL 可以接受的 userinfo。
///
/// 只保留 RFC 3986 的 unreserved 字符（字母数字与 - . _ ~），其余一律百分号编码，
/// 这样密码里出现 @ : / # ? 之类也不会把连接串拆坏。
fn encode_userinfo(value: &str) -> String {
    const USERINFO: &percent_encoding::AsciiSet = &percent_encoding::NON_ALPHANUMERIC
        .remove(b'-')
        .remove(b'.')
        .remove(b'_')
        .remove(b'~');
    percent_encoding::utf8_percent_encode(value, USERINFO).to_string()
}

/// 真正做一次 MySQL 登录探测：用 DBPILOT_TEST_MYSQL_* 建一个单连接池。
///
/// 端口不通、账号不存在、密码不对、TLS 握手失败等都返回 false —— 测试据此 SKIP。
/// 只做认证探测、不指定默认库，因此“库不存在”不会让本函数误判为不可用。
///
/// 这是“任意机器上 cargo test 都必须绿”的关键：仅看端口是不够的，本机可能
/// 跑着一个密码不同的 MySQL，那样测试会真的去连然后 panic。
pub async fn mysql_usable() -> bool {
    use sqlx::mysql::MySqlPoolOptions;
    use std::time::Duration;

    let endpoint = mysql();
    let url = format!(
        "mysql://{}:{}@{}:{}/",
        encode_userinfo(&endpoint.user),
        encode_userinfo(&endpoint.password),
        endpoint.host,
        endpoint.port
    );
    let Ok(pool) = MySqlPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(Duration::from_secs(5))
        .connect(&url)
        .await
    else {
        return false;
    };
    // connect() 会立即开至少一条连接（认证在此发生）；再取一次连接是双保险。
    if pool.acquire().await.is_err() {
        let _ = pool.close().await;
        return false;
    }
    let _ = pool.close().await;
    true
}

/// 真正做一次 PostgreSQL 登录探测（连到维护库 postgres）。
///
/// 与 mysql_usable 同理：认证/网络任一步失败都返回 false，测试据此 SKIP。
pub async fn postgres_usable() -> bool {
    use sqlx::postgres::PgPoolOptions;
    use std::time::Duration;

    let endpoint = postgres();
    let url = format!(
        "postgres://{}:{}@{}:{}/postgres",
        encode_userinfo(&endpoint.user),
        encode_userinfo(&endpoint.password),
        endpoint.host,
        endpoint.port
    );
    let Ok(pool) = PgPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(Duration::from_secs(5))
        .connect(&url)
        .await
    else {
        return false;
    };
    if pool.acquire().await.is_err() {
        let _ = pool.close().await;
        return false;
    }
    let _ = pool.close().await;
    true
}

/// TLS fixture 是否由 tools/tls_fixture.sh 准备好。
///
/// 脚本每次 up 都会生成非空随机密码并写进 credentials.env，所以
/// “密码变量已设置 + CA 文件存在 + 端口可连”就是 fixture 就绪的可靠信号；
/// 此时再去连不会因为凭据不对而 panic（凭据就是我们自己刚生成的）。
pub fn tls_mysql_ready() -> bool {
    let endpoint = tls_mysql();
    let ca = std::env::var("DBPILOT_TLS_MYSQL_CA").unwrap_or_else(|_| {
        std::env::temp_dir()
            .join("rma-tls-mysql")
            .join("certs")
            .join("ca.pem")
            .to_string_lossy()
            .to_string()
    });
    !endpoint.password.is_empty()
        && std::path::Path::new(&ca).exists()
        && port_open(&endpoint.host, endpoint.port)
}

/// TLS PostgreSQL fixture 是否就绪（判断依据同 tls_mysql_ready）。
pub fn tls_postgres_ready() -> bool {
    let endpoint = tls_postgres();
    let ca = std::env::var("DBPILOT_TLS_PG_CA").unwrap_or_else(|_| {
        std::env::temp_dir()
            .join("rma-tls-pg")
            .join("certs")
            .join("ca.pem")
            .to_string_lossy()
            .to_string()
    });
    !endpoint.password.is_empty()
        && std::path::Path::new(&ca).exists()
        && port_open(&endpoint.host, endpoint.port)
}

/// 无 SAN 证书 fixture 是否就绪（判断依据同 tls_mysql_ready）。
pub fn tls_nosan_ready() -> bool {
    let endpoint = tls_mysql_nosan();
    let ca = std::env::var("DBPILOT_TLS_NOSAN_CA").unwrap_or_else(|_| {
        std::env::temp_dir()
            .join("rma-tls-nosan")
            .join("certs")
            .join("ca.pem")
            .to_string_lossy()
            .to_string()
    });
    !endpoint.password.is_empty()
        && std::path::Path::new(&ca).exists()
        && port_open(&endpoint.host, endpoint.port)
}
