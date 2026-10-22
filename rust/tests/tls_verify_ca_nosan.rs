//! P7 (round 30) regression: MySQL ssl_verify = "verify-ca" must validate the
//! CA chain but must NOT validate the server hostname.
//!
//! The regular TLS fixture (tools/tls_fixture.sh, port 3307) issues a server
//! certificate with subjectAltName DNS:localhost,IP:127.0.0.1, so it can never
//! catch this bug: the hostname always matches there. This test instead targets
//! a throwaway MySQL instance whose server certificate has NO subjectAltName:
//!
//!   * the mysql CLI with --ssl-mode=VERIFY_CA connects successfully;
//!   * sqlx 0.8.6 + rustls 0.23.46 used to fail with
//!     "certificate not valid for name "127.0.0.1"; not valid for any names"
//!     because NoHostnameTlsVerifier only matched the old
//!     CertificateError::NotValidForName variant (see
//!     vendor/sqlx-core/src/net/tls/tls_rustls.rs).
//!
//! Fixture setup / teardown: create a throwaway MySQL instance on
//! DBPILOT_TLS_NOSAN_PORT (default 3308) whose server certificate has no SAN.
//! Env overrides: DBPILOT_TLS_NOSAN_PORT, DBPILOT_TLS_NOSAN_CA,
//! DBPILOT_TLS_NOSAN_USER, DBPILOT_TLS_NOSAN_PASSWORD (no credential is stored
//! in this repository). Without a running fixture the tests print SKIP and pass,
//! like the other TLS tests.

use rust_myadmin_core::core::connection::ConnectionHandle;
use rust_myadmin_core::drivers::{connect, pooled_handle, ConnSpec, DriverKind};

mod common;

/// 无 SAN fixture 的端口；判断依据是 common::tls_nosan_ready()（密码已生成 +
/// CA 存在 + 端口可连），而不是“端口开着就真跑”——凭据不对时真跑会 panic。
fn nosan_port() -> Option<u16> {
    common::tls_nosan_ready().then(|| common::tls_mysql_nosan().port)
}

fn nosan_ca() -> Option<String> {
    let path = std::env::var("DBPILOT_TLS_NOSAN_CA").unwrap_or_else(|_| {
        std::env::temp_dir()
            .join("rma-tls-nosan")
            .join("certs")
            .join("ca.pem")
            .to_string_lossy()
            .to_string()
    });
    std::path::Path::new(&path).exists().then_some(path)
}

fn fixture() -> Option<(u16, String)> {
    let port = nosan_port()?;
    let ca = nosan_ca()?;
    Some((port, ca))
}

fn spec(port: u16, verify: &str, ca: Option<&str>) -> ConnSpec {
    let endpoint = common::tls_mysql_nosan();
    ConnSpec {
        driver: DriverKind::Mysql,
        // 127.0.0.1 deliberately does not match the certificate CN (localhost)
        // and the certificate has no SAN at all.
        host: endpoint.host,
        port: Some(port),
        user: endpoint.user,
        password: endpoint.password,
        ssl_mode: Some("require".to_string()),
        ssl_verify: Some(verify.to_string()),
        ssl_ca: ca.map(str::to_string),
        ..Default::default()
    }
}

async fn query_one(spec: &ConnSpec) -> anyhow::Result<()> {
    let pool = connect(spec, None).await?;
    let db = pooled_handle(pool, DriverKind::Mysql, None);
    let results = run_sql(&db, "SELECT 1 AS ok").await;
    let first = results.first().ok_or_else(|| anyhow::anyhow!("no result"))?;
    if let Some(error) = &first.error {
        anyhow::bail!("{error}");
    }
    Ok(())
}

/// The regression from round 29 (T-01): before the sqlx-core patch this failed
/// with "certificate not valid for name 127.0.0.1".

/// P7：旧门面的 run_sql 已移除；测试走驱动 trait + 会话句柄。
async fn run_sql(db: &ConnectionHandle, sql: &str) -> Vec<rust_myadmin_core::db::ResultSet> {
    rust_myadmin_core::drivers::builtin::driver_for(db.driver_kind())
        .run_sql(db, sql)
        .await
}

#[tokio::test]
async fn verify_ca_ignores_hostname_for_a_cert_without_san() {
    let Some((port, ca)) = fixture() else {
        eprintln!("SKIP: no no-SAN TLS MySQL fixture (see this file's header)");
        return;
    };
    let ok = query_one(&spec(port, "verify-ca", Some(&ca))).await;
    assert!(
        ok.is_ok(),
        "verify-ca must accept a chain-valid certificate even when the host name does not match: {ok:?}"
    );
}

/// verify-full must keep checking the host name, otherwise the patch would have
/// silently disabled hostname verification for every TLS mode.
#[tokio::test]
async fn verify_full_still_checks_the_hostname() {
    let Some((port, ca)) = fixture() else {
        eprintln!("SKIP: no no-SAN TLS MySQL fixture (see this file's header)");
        return;
    };
    let result = query_one(&spec(port, "verify-full", Some(&ca))).await;
    assert!(
        result.is_err(),
        "verify-full must reject a certificate that is not valid for 127.0.0.1: {result:?}"
    );
}

/// The hostname must be the only thing verify-ca skips: the chain is still
/// validated, so an unknown CA is refused.
#[tokio::test]
async fn verify_ca_still_requires_a_trusted_chain() {
    let Some((port, _ca)) = fixture() else {
        eprintln!("SKIP: no no-SAN TLS MySQL fixture (see this file's header)");
        return;
    };
    let result = query_one(&spec(port, "verify-ca", None)).await;
    assert!(
        result.is_err(),
        "verify-ca without the CA must not accept an untrusted chain: {result:?}"
    );
}
