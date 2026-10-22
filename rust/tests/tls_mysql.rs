//! Real TLS verification against a MySQL server that requires TLS.
//!
//! A throwaway MySQL instance (DBPILOT_TLS_MYSQL_PORT, default 3307,
//! `require_secure_transport=ON`) is started by tools/tls_fixture.sh with its
//! own CA and server certificate. These tests close the "TLS was never tested
//! against a server that actually requires it" gap.
//!
//! The fixture endpoint, account and password come from the environment
//! (DBPILOT_TLS_MYSQL_*; tools/tls_fixture.sh writes them to
//! <fixture dir>/credentials.env). Without a running fixture the tests skip, so
//! a developer without it still gets a green run.

use rust_myadmin_core::core::connection::ConnectionHandle;
use rust_myadmin_core::drivers::{connect, pooled_handle, ConnSpec, DriverKind};

mod common;

/// TLS fixture 的 MySQL 端口；fixture 没起时返回 None，测试 SKIP。
///
/// 判断依据是 common::tls_mysql_ready()（密码已生成 + CA 存在 + 端口可连），
/// 而不是“端口开着就真跑”：3307 被别的 MySQL 占着时凭据一定不对，真跑会 panic。
fn tls_mysql_port() -> Option<u16> {
    common::tls_mysql_ready().then(|| common::tls_mysql().port)
}

fn ca_path() -> Option<String> {
    // `temp_dir()` is `/tmp` on Unix and `%TEMP%` on Windows; the fixture
    // script writes there, so no hardcoded `/tmp` (which does not exist on
    // Windows) is needed.
    let path = std::env::var("DBPILOT_TLS_MYSQL_CA").unwrap_or_else(|_| {
        std::env::temp_dir()
            .join("rma-tls-mysql")
            .join("certs")
            .join("ca.pem")
            .to_string_lossy()
            .to_string()
    });
    std::path::Path::new(&path).exists().then_some(path)
}

fn spec(port: u16, mode: &str, verify: &str, ca: Option<&str>, host: &str) -> ConnSpec {
    // 账号密码来自 fixture 脚本随机生成后写进环境变量，仓库里没有字面量。
    let endpoint = common::tls_mysql();
    ConnSpec {
        driver: DriverKind::Mysql,
        host: host.to_string(),
        port: Some(port),
        user: endpoint.user,
        password: endpoint.password,
        ssl_mode: Some(mode.to_string()),
        ssl_verify: Some(verify.to_string()),
        ssl_ca: ca.map(str::to_string),
        ..Default::default()
    }
}

async fn query_one(spec: &ConnSpec) -> anyhow::Result<String> {
    let pool = connect(spec, None).await?;
    let db = pooled_handle(pool, DriverKind::Mysql, None);
    let results = run_sql(&db, "SELECT 1 AS ok").await;
    let first = results.first().ok_or_else(|| anyhow::anyhow!("no result"))?;
    if let Some(error) = &first.error {
        anyhow::bail!("{error}");
    }
    Ok("ok".to_string())
}


/// P7：旧门面的 run_sql 已移除；测试走驱动 trait + 会话句柄。
async fn run_sql(db: &ConnectionHandle, sql: &str) -> Vec<rust_myadmin_core::db::ResultSet> {
    rust_myadmin_core::drivers::builtin::driver_for(db.driver_kind())
        .run_sql(db, sql)
        .await
}

#[tokio::test]
async fn verified_tls_connection_succeeds_with_a_custom_ca() {
    let Some(port) = tls_mysql_port() else {
        eprintln!("SKIP: no TLS MySQL fixture (start tools/tls_fixture.sh up)");
        return;
    };
    let Some(ca) = ca_path() else {
        eprintln!("SKIP: fixture CA not found");
        return;
    };
    // verify-ca: chain validated, host name not checked.
    let ok = query_one(&spec(port, "require", "verify-ca", Some(&ca), "127.0.0.1")).await;
    assert!(ok.is_ok(), "verify-ca should succeed: {ok:?}");

    // verify-full with the fixture host name: the certificate has a SAN for
    // localhost and 127.0.0.1, so a matching host must pass.
    let ok = query_one(&spec(port, "require", "verify-full", Some(&ca), "localhost")).await;
    assert!(ok.is_ok(), "verify-full against localhost should succeed: {ok:?}");
}

#[tokio::test]
async fn verification_fails_without_the_right_ca() {
    let Some(port) = tls_mysql_port() else {
        eprintln!("SKIP: no TLS MySQL fixture");
        return;
    };
    // No CA: the self-signed fixture chain is untrusted, so strict modes must
    // refuse. This is the behaviour that makes TLS meaningful.
    let result = query_one(&spec(port, "require", "verify-full", None, "localhost")).await;
    assert!(
        result.is_err(),
        "verify-full without a CA must not silently succeed: {result:?}"
    );
}

#[tokio::test]
async fn plaintext_is_refused_by_a_tls_only_server() {
    let Some(port) = tls_mysql_port() else {
        eprintln!("SKIP: no TLS MySQL fixture");
        return;
    };
    // ssl_mode=disable against require_secure_transport=ON must fail: this
    // proves the fixture really enforces TLS and the client cannot fall back.
    let result = query_one(&spec(port, "disable", "require", None, "127.0.0.1")).await;
    assert!(
        result.is_err(),
        "plaintext reached a TLS-only server: {result:?}"
    );
}

#[allow(dead_code)]
fn _unused(_: &str) {}
