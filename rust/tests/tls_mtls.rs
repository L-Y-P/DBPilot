//! Real mutual-TLS verification against the throwaway TLS fixtures.
//!
//! The handover listed mTLS as the remaining TLS gap: the client certificate
//! fields were plumbed through to sqlx, but no server ever required a client
//! certificate. tools/tls_fixture.sh now creates a client cert (CN=mtlstest)
//! and enforces it:
//!   * MySQL  user mtlstest with REQUIRE X509
//!   * PG     role mtlstest with cert clientcert=verify-full
//!
//! Without the fixture the tests SKIP, so a plain `cargo test` stays green for
//! developers who have not started it. The fixture accounts and their passwords
//! come from the environment (DBPILOT_TLS_*; tools/tls_fixture.sh writes them to
//! <fixture dir>/credentials.env), so the repository stores no credential.

use rust_myadmin_core::core::connection::ConnectionHandle;
use rust_myadmin_core::drivers::{connect, pooled_handle, ConnSpec, DriverKind};

mod common;

/// fixture 是否就绪：判断依据是 common::tls_*_ready()（密码已生成 + CA 存在 +
/// 端口可连），而不是“端口开着就真跑”——凭据不对时真跑会 panic。
///
/// 同时兼容显式设置的 DBPILOT_TLS_*_PORT（使用者自己起 fixture 时）。
fn fixture_port(name: &str, default: u16, ready: bool) -> Option<u16> {
    let port = std::env::var(name)
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(default);
    ready.then_some(port)
}

/// MySQL client certificate material from the fixture.
fn mysql_certs() -> Option<(String, String, String)> {
    let base = std::env::var("DBPILOT_TLS_MYSQL_DIR").unwrap_or_else(|_| {
        std::env::temp_dir()
            .join("rma-tls-mysql")
            .join("certs")
            .to_string_lossy()
            .to_string()
    });
    let ca = format!("{base}/ca.pem");
    let cert = format!("{base}/client-cert.pem");
    let key = format!("{base}/client-key.pem");
    [ca.clone(), cert.clone(), key.clone()]
        .iter()
        .all(|path| std::path::Path::new(path).exists())
        .then_some((ca, cert, key))
}

fn pg_certs() -> Option<(String, String, String)> {
    let base = std::env::var("DBPILOT_TLS_PG_DIR").unwrap_or_else(|_| {
        std::env::temp_dir()
            .join("rma-tls-pg")
            .join("certs")
            .to_string_lossy()
            .to_string()
    });
    let ca = format!("{base}/ca.pem");
    let cert = format!("{base}/client-cert.pem");
    let key = format!("{base}/client-key.pem");
    [ca.clone(), cert.clone(), key.clone()]
        .iter()
        .all(|path| std::path::Path::new(path).exists())
        .then_some((ca, cert, key))
}

fn mysql_spec(port: u16, certs: Option<&(String, String, String)>) -> ConnSpec {
    let endpoint = common::tls_mysql_mtls();
    ConnSpec {
        driver: DriverKind::Mysql,
        host: endpoint.host,
        port: Some(port),
        user: endpoint.user,
        password: endpoint.password,
        ssl_mode: Some("require".to_string()),
        ssl_verify: Some("verify-ca".to_string()),
        ssl_ca: certs.map(|c| c.0.clone()),
        ssl_cert: certs.map(|c| c.1.clone()),
        ssl_key: certs.map(|c| c.2.clone()),
        ..Default::default()
    }
}

fn pg_spec(port: u16, certs: Option<&(String, String, String)>) -> ConnSpec {
    let endpoint = common::tls_postgres_mtls();
    ConnSpec {
        driver: DriverKind::Postgres,
        host: endpoint.host,
        port: Some(port),
        user: endpoint.user,
        password: endpoint.password,
        // The fixture role has no database of the same name: connect to the
        // maintenance database so auth, not a missing DB, decides the outcome.
        database: Some("postgres".to_string()),
        ssl_mode: Some("require".to_string()),
        ssl_verify: Some("verify-ca".to_string()),
        ssl_ca: certs.map(|c| c.0.clone()),
        ssl_cert: certs.map(|c| c.1.clone()),
        ssl_key: certs.map(|c| c.2.clone()),
        ..Default::default()
    }
}

fn db(pool: rust_myadmin_core::drivers::Pool, driver: DriverKind) -> ConnectionHandle {
    pooled_handle(pool, driver, None)
}

async fn query_rows(spec: &ConnSpec, sql: &str) -> anyhow::Result<Vec<Vec<serde_json::Value>>> {
    let pool = connect(spec, None).await?;
    let database = db(pool, spec.driver);
    let results = run_sql(&database, sql).await;
    let first = results.first().ok_or_else(|| anyhow::anyhow!("no result"))?;
    if let Some(error) = &first.error {
        anyhow::bail!("{error}");
    }
    Ok(first.rows.clone())
}


/// P7：旧门面的 run_sql 已移除；测试走驱动 trait + 会话句柄。
async fn run_sql(db: &ConnectionHandle, sql: &str) -> Vec<rust_myadmin_core::db::ResultSet> {
    rust_myadmin_core::drivers::builtin::driver_for(db.driver_kind())
        .run_sql(db, sql)
        .await
}

#[tokio::test]
async fn mysql_requires_a_client_certificate() {
    let Some(port) = fixture_port(
        "DBPILOT_TLS_MYSQL_PORT",
        3307,
        common::tls_mysql_ready(),
    ) else {
        eprintln!("SKIP: no TLS MySQL fixture (start tools/tls_fixture.sh up)");
        return;
    };
    let Some(certs) = mysql_certs() else {
        eprintln!("SKIP: fixture client certificate not found");
        return;
    };

    // Positive: server has REQUIRE X509, so this only succeeds when the client
    // certificate was actually presented and accepted.
    let rows = query_rows(&mysql_spec(port, Some(&certs)), "SELECT 1 AS ok")
        .await
        .expect("mTLS connection with a client certificate must succeed");
    assert_eq!(rows.first().and_then(|r| r.first()), Some(&serde_json::json!(1)));

    // Negative: same credentials, no client certificate -> rejected.
    let without = query_rows(&mysql_spec(port, None), "SELECT 1 AS ok").await;
    assert!(
        without.is_err(),
        "MySQL accepted a connection without the required client certificate: {without:?}"
    );
}

#[tokio::test]
async fn postgres_requires_a_client_certificate_and_reports_its_dn() {
    let Some(port) = fixture_port(
        "DBPILOT_TLS_PG_PORT",
        5434,
        common::tls_postgres_ready(),
    ) else {
        eprintln!("SKIP: no TLS PostgreSQL fixture (start tools/tls_fixture.sh up)");
        return;
    };
    let Some(certs) = pg_certs() else {
        eprintln!("SKIP: fixture client certificate not found");
        return;
    };

    // Positive: cert auth with clientcert=verify-full. pg_stat_ssl tells us the
    // server really saw the certificate, not just a TLS session.
    let rows = query_rows(
        &pg_spec(port, Some(&certs)),
        "SELECT ssl, client_dn FROM pg_stat_ssl WHERE pid = pg_backend_pid()",
    )
    .await
    .expect("mTLS connection with a client certificate must succeed");
    let row = rows.first().expect("one row");
    assert_eq!(row.first(), Some(&serde_json::json!(true)), "session must be TLS");
    let dn = row.get(1).and_then(|v| v.as_str()).unwrap_or_default();
    assert!(
        dn.contains("CN=mtlstest"),
        "server did not report the client certificate DN: {dn:?}"
    );

    // Negative: no client certificate -> pg_hba cert rule rejects us.
    let without = query_rows(
        &pg_spec(port, None),
        "SELECT 1 AS ok",
    )
    .await;
    assert!(
        without.is_err(),
        "PostgreSQL accepted a connection without the required client certificate: {without:?}"
    );
}
