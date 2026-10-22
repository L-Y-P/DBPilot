//! Real TLS verification against a PostgreSQL server that requires TLS.
//!
//! Fixture: a throwaway PostgreSQL instance (DBPILOT_TLS_PG_PORT, default 5434)
//! with `ssl=on` and a pg_hba rule that rejects non-TLS connections, started by
//! tools/tls_fixture.sh. The account and password come from the environment
//! (DBPILOT_TLS_PG_*), so the repository stores no credential. The tests skip
//! when the fixture is absent.

use rust_myadmin_core::core::connection::ConnectionHandle;
use rust_myadmin_core::drivers::{connect, pooled_handle, ConnSpec, DriverKind};

mod common;

/// fixture 端口；判断依据是 common::tls_postgres_ready()（密码已生成 + CA 存在 +
/// 端口可连），而不是“端口开着就真跑”。
fn tls_pg_port() -> Option<u16> {
    common::tls_postgres_ready().then(|| common::tls_postgres().port)
}

fn ca_path() -> Option<String> {
    // `temp_dir()` is `/tmp` on Unix and `%TEMP%` on Windows, so the fixture's
    // default location resolves on both without a hardcoded `/tmp`.
    let path = std::env::var("DBPILOT_TLS_PG_CA").unwrap_or_else(|_| {
        std::env::temp_dir()
            .join("rma-tls-pg")
            .join("certs")
            .join("ca.pem")
            .to_string_lossy()
            .to_string()
    });
    std::path::Path::new(&path).exists().then_some(path)
}

fn spec(port: u16, mode: &str, verify: &str, ca: Option<&str>, host: &str) -> ConnSpec {
    let endpoint = common::tls_postgres();
    ConnSpec {
        driver: DriverKind::Postgres,
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

async fn query_one(spec: &ConnSpec) -> anyhow::Result<i64> {
    let pool = connect(spec, None).await?;
    let db = pooled_handle(pool, DriverKind::Postgres, None);
    let results = run_sql(&db, "SELECT CASE WHEN ssl THEN 1 ELSE 0 END AS encrypted FROM pg_stat_ssl WHERE pid = pg_backend_pid()")
        .await;
    let first = results.first().ok_or_else(|| anyhow::anyhow!("no result"))?;
    if let Some(error) = &first.error {
        anyhow::bail!("{error}");
    }
    let cell = first
        .rows
        .first()
        .and_then(|r| r.first())
        .ok_or_else(|| anyhow::anyhow!("no row"))?;
    Ok(cell.as_i64().unwrap_or(0))
}


/// P7：旧门面的 run_sql 已移除；测试走驱动 trait + 会话句柄。
async fn run_sql(db: &ConnectionHandle, sql: &str) -> Vec<rust_myadmin_core::db::ResultSet> {
    rust_myadmin_core::drivers::builtin::driver_for(db.driver_kind())
        .run_sql(db, sql)
        .await
}

#[tokio::test]
async fn verify_ca_connects_and_reports_an_encrypted_session() {
    let (Some(port), Some(ca)) = (tls_pg_port(), ca_path()) else {
        eprintln!("SKIP: no TLS PostgreSQL fixture (start tools/tls_fixture.sh up)");
        return;
    };
    let encrypted = query_one(&spec(port, "require", "verify-ca", Some(&ca), "localhost"))
        .await
        .expect("verify-ca should succeed");
    assert_eq!(encrypted, 1, "session was not encrypted");
}

#[tokio::test]
async fn verify_full_connects_to_a_matching_host_and_rejects_a_wrong_ca() {
    let (Some(port), Some(ca)) = (tls_pg_port(), ca_path()) else {
        eprintln!("SKIP: no TLS PostgreSQL fixture");
        return;
    };
    let encrypted = query_one(&spec(port, "require", "verify-full", Some(&ca), "localhost"))
        .await
        .expect("verify-full against a matching host should succeed");
    assert_eq!(encrypted, 1, "session was not encrypted");

    // Another CA must not be accepted: this is what makes verification real.
    let wrong = query_one(&spec(
        port,
        "require",
        "verify-full",
        // The MySQL fixture's CA is a different CA: verification must reject it.
        Some(
            &std::env::temp_dir()
                .join("rma-tls-mysql")
                .join("certs")
                .join("ca.pem")
                .to_string_lossy(),
        ),
        "localhost",
    ))
    .await;
    assert!(wrong.is_err(), "verify-full accepted the wrong CA: {wrong:?}");
}

#[tokio::test]
async fn plaintext_is_rejected_by_the_tls_only_server() {
    let Some(port) = tls_pg_port() else {
        eprintln!("SKIP: no TLS PostgreSQL fixture");
        return;
    };
    let result = query_one(&spec(port, "disable", "require", None, "127.0.0.1")).await;
    assert!(result.is_err(), "plaintext reached a TLS-only server: {result:?}");
}
