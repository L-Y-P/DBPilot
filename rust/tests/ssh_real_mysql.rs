//! Real end-to-end: SSH tunnel to the local MySQL server.
//!
//! The jump host is a real russh server started in-process; the database is a
//! real MySQL server whose endpoint comes from DBPILOT_TEST_MYSQL_* (see
//! tests/common/mod.rs), so no credential is stored in this repository. This
//! proves the tunnel carries a real database protocol — handshake,
//! authentication and query results — not just a synthetic echo.

use std::sync::Arc;
use std::time::Duration;

use russh::keys::key::KeyPair;
use russh::server::{Auth, Msg, Server as _, Session};
use russh::Channel;
use rust_myadmin_core::drivers::{connect, ConnSpec, DriverKind};
use rust_myadmin_core::ssh::{self, SshAuth, SshSpec};
use tokio::net::{TcpListener, TcpStream};

mod common;

#[derive(Clone)]
struct Srv {
    password: String,
}
impl russh::server::Server for Srv {
    type Handler = Sess;
    fn new_client(&mut self, _: Option<std::net::SocketAddr>) -> Sess {
        Sess {
            password: self.password.clone(),
        }
    }
}
struct Sess {
    password: String,
}
#[async_trait::async_trait]
impl russh::server::Handler for Sess {
    type Error = anyhow::Error;
    async fn auth_password(&mut self, _u: &str, password: &str) -> Result<Auth, Self::Error> {
        if password == self.password {
            Ok(Auth::Accept)
        } else {
            Ok(Auth::Reject {
                proceed_with_methods: None,
            })
        }
    }
    async fn channel_open_direct_tcpip(
        &mut self,
        channel: Channel<Msg>,
        host: &str,
        port: u32,
        _oa: &str,
        _op: u32,
        _s: &mut Session,
    ) -> Result<bool, Self::Error> {
        let host = host.to_string();
        tokio::spawn(async move {
            let Ok(mut upstream) = TcpStream::connect((host.as_str(), port as u16)).await else {
                return;
            };
            let mut stream = channel.into_stream();
            let _ = tokio::io::copy_bidirectional(&mut upstream, &mut stream).await;
        });
        Ok(true)
    }
}

async fn start_server() -> (u16, String) {
    let key = Arc::new(KeyPair::generate_ed25519().expect("keypair"));
    // 跳板密码每次运行随机生成：仓库里不留任何密码字面量。
    let password = format!("tunnel-pass-{}", uuid::Uuid::new_v4());
    let mut server = Srv {
        password: password.clone(),
    };
    let config = Arc::new(russh::server::Config {
        inactivity_timeout: Some(Duration::from_secs(60)),
        auth_rejection_time: Duration::from_millis(10),
        keys: vec![(*key).clone()],
        ..Default::default()
    });
    let (tx, rx) = tokio::sync::oneshot::channel();
    tokio::spawn(async move {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.expect("bind");
        let port = listener.local_addr().expect("addr").port();
        let _ = tx.send(port);
        let _ = server.run_on_socket(config, &listener).await;
    });
    (rx.await.expect("port"), password)
}

/// 被隧道转发的数据库端点：host/port/user/password 来自 DBPILOT_TEST_MYSQL_*。
fn mysql_endpoint() -> common::MysqlEndpoint {
    common::mysql()
}


/// P7：旧门面的 run_sql 已移除；测试走驱动 trait + 会话句柄。
async fn run_sql(
    db: &rust_myadmin_core::core::connection::ConnectionHandle,
    sql: &str,
) -> Vec<rust_myadmin_core::db::ResultSet> {
    rust_myadmin_core::drivers::builtin::driver_for(db.driver_kind())
        .run_sql(db, sql)
        .await
}

#[tokio::test]
async fn mysql_is_reachable_through_the_ssh_tunnel() {
    let endpoint = mysql_endpoint();
    // 必须真正登录成功才跑（只看端口会在“有库但密码不对”的机器上 panic）。
    if !common::mysql_usable().await {
        eprintln!("SKIP: DBPILOT_TEST_MYSQL_* does not authenticate");
        return;
    }
    let (ssh_port, password) = start_server().await;
    let spec = SshSpec {
        ssh_host: "127.0.0.1".to_string(),
        ssh_port: Some(ssh_port),
        ssh_user: "tester".to_string(),
        ssh_auth: SshAuth::Password,
        ssh_password: password,
        ..Default::default()
    };
    let tunnel = ssh::open(&spec, &endpoint.host, endpoint.port, Duration::from_secs(10))
        .await
        .expect("tunnel opens");
    // Dial MySQL through the forwarded port and read the server greeting.
    let mut socket = TcpStream::connect(tunnel.local_addr).await.expect("dial");
    let mut greeting = [0u8; 5];
    tokio::time::timeout(Duration::from_secs(10), tokio::io::AsyncReadExt::read_exact(&mut socket, &mut greeting))
        .await
        .expect("MySQL greeting timed out through the tunnel")
        .expect("read greeting");
    // Protocol version 10 is the first payload byte of an initial handshake.
    assert_eq!(greeting[4], 10, "expected a MySQL protocol-10 handshake");
}

#[tokio::test]
async fn wrong_password_is_rejected() {
    let (ssh_port, _password) = start_server().await;
    let spec = SshSpec {
        ssh_host: "127.0.0.1".to_string(),
        ssh_port: Some(ssh_port),
        ssh_user: "tester".to_string(),
        ssh_auth: SshAuth::Password,
        ssh_password: "nope".to_string(),
        ..Default::default()
    };
    let endpoint = mysql_endpoint();
    let error = ssh::open(&spec, &endpoint.host, endpoint.port, Duration::from_secs(10))
        .await
        .err()
        .expect("must reject");
    assert!(error.to_string().contains("SSH 认证失败"));
}

/// The strongest end-to-end check: a real SQL round trip through the tunnel.
///
/// This drives the same connect + query path the app uses, with the SSH spec
/// attached, so a broken tunnel, a wrong forwarded port or a pool that lost the
/// tunnel would fail here.
#[tokio::test]
async fn runs_a_real_query_through_the_tunnel() {
    let endpoint = mysql_endpoint();
    // 必须真正登录成功才跑（只看端口会在“有库但密码不对”的机器上 panic）。
    if !common::mysql_usable().await {
        eprintln!("SKIP: DBPILOT_TEST_MYSQL_* does not authenticate");
        return;
    }
    let (ssh_port, password) = start_server().await;
    let spec = ConnSpec {
        driver: DriverKind::Mysql,
        host: endpoint.host.clone(),
        port: Some(endpoint.port),
        user: endpoint.user.clone(),
        password: endpoint.password.clone(),
        ssh: SshSpec {
            ssh_host: "127.0.0.1".to_string(),
            ssh_port: Some(ssh_port),
            ssh_user: "tester".to_string(),
            ssh_auth: SshAuth::Password,
            ssh_password: password,
            ..Default::default()
        },
        ..Default::default()
    };
    let pool = connect(&spec, None).await.expect("connect through tunnel");
    let db = rust_myadmin_core::drivers::pooled_handle(pool, DriverKind::Mysql, None);
    let results = run_sql(&db, "SELECT 42 AS answer").await;
    let first = results.first().expect("one result");
    assert!(first.error.is_none(), "query error: {:?}", first.error);
    let cell = first
        .rows
        .first()
        .and_then(|r| r.first())
        .map(|v| v.to_string());
    assert_eq!(cell.as_deref(), Some("42"), "unexpected rows: {:?}", first.rows);
}
/// 取消 + 进程列表**经 SSH 隧道**的端到端验证（补上 P2 报告的缺口）。
///
/// 与 live_cancel_processlist.rs 的直连版本相比，这里证明：
/// * 隧道后的连接同样出现在服务器 PROCESSLIST 里；
/// * cancel_query() 通过隧道连接定位并 KILL 掉正在 SLEEP 的连接；
/// * 取消后隧道/池重建，控制台仍可用（隧道生命周期没有被取消逻辑搞坏）。
#[tokio::test]
async fn cancel_and_process_list_through_the_tunnel() {
    use serde_json::json;
    use rust_myadmin_core::api;

    let endpoint = mysql_endpoint();
    // 必须真正登录成功才跑（只看端口会在“有库但密码不对”的机器上 panic）。
    if !common::mysql_usable().await {
        eprintln!("SKIP: DBPILOT_TEST_MYSQL_* does not authenticate");
        return;
    }
    let (ssh_port, password) = start_server().await;

    let dir = std::env::temp_dir().join(format!("rma-ssh-cancel-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    let init = api::init_app(dir.to_string_lossy().to_string());
    assert_eq!(init.get("ok"), Some(&serde_json::Value::Bool(true)), "init: {init}");

    let created = api::connections::create_connection(json!({
        "name": "tunnel cancel mysql",
        "driver": "mysql",
        "host": endpoint.host,
        "port": endpoint.port,
        "user": endpoint.user,
        "password": endpoint.password,
        "database": "mysql",
        "ssl_mode": "disable",
        "ssh_host": "127.0.0.1",
        "ssh_port": ssh_port,
        "ssh_user": "tester",
        "ssh_auth": "password",
        "ssh_password": password,
    }))
    .await
    .expect("create connection");
    let id = created["connection"]["id"].as_str().expect("id").to_string();
    api::connections::connect_connection(id)
        .await
        .expect("connect through tunnel");

    // 1) 隧道后的会话必须出现在进程列表里。
    let own = api::query::run_query(json!({ "sql": "SELECT CONNECTION_ID() AS id", "database": "mysql" }))
        .await
        .expect("own id");
    let own_id = own["results"][0]["rows"][0][0].as_i64().expect("CONNECTION_ID()");
    let processes = api::server::processes().await.expect("processes");
    assert!(
        processes["processes"]
            .as_array()
            .expect("array")
            .iter()
            .any(|row| row.get("Id").and_then(|v| v.as_i64()) == Some(own_id)),
        "tunneled session {own_id} missing from process list: {processes}"
    );

    // 2) 取消必须能打断隧道上正在执行的语句。
    let running = tokio::spawn(async {
        api::query::run_query(json!({ "sql": "SELECT SLEEP(30)", "database": "mysql" })).await
    });
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let cancel = api::query::cancel_query().await.expect("cancel");
    assert!(
        cancel["cancelled"].as_u64().unwrap_or(0) >= 1,
        "no tunneled connection was killed: {cancel}"
    );
    let payload = tokio::time::timeout(Duration::from_secs(20), running)
        .await
        .expect("cancelled query never returned")
        .expect("task panicked")
        .expect("run_query failed");
    let error = payload["results"][0]["error"].as_str().unwrap_or("");
    assert!(error.contains("查询已取消"), "cancel not surfaced: {payload}");

    // 3) 隧道仍然可用（池重建后能重新建隧道并查询）。
    let after = api::query::run_query(json!({ "sql": "SELECT 1 AS ok", "database": "mysql" }))
        .await
        .expect("after");
    assert!(after["results"][0]["error"].is_null(), "console broken after tunnel cancel: {after}");
}
