//! N-01 / N-11: the SSH jump-host fingerprint must actually be reported,
//! persisted and enforced.
//!
//! The connection probe used to open a *second* temporary tunnel just to look up
//! a fingerprint, which never found one — so the form never backfilled
//! `ssh_host_key`, TOFU pinning never happened, and `strict` could not be used
//! from the UI. This test drives the real API against an in-process SSH server
//! and a real MySQL server; the database endpoint comes from
//! DBPILOT_TEST_MYSQL_* (see tests/common/mod.rs), so no credential is stored
//! in this repository.

use std::sync::Arc;
use std::time::Duration;

use russh::keys::key::KeyPair;
use russh::server::{Auth, Msg, Server as _, Session};
use russh::Channel;
use rust_myadmin_core::api;
use serde_json::{json, Value};
use tokio::net::TcpStream;

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
    // 跳板密码每次运行随机生成：仓库里不留任何密码字面量，也不影响被测逻辑。
    let password = format!("fingerprint-pass-{}", uuid::Uuid::new_v4());
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
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind");
        let port = listener.local_addr().expect("addr").port();
        let _ = tx.send(port);
        let _ = server.run_on_socket(config, &listener).await;
    });
    (rx.await.expect("port"), password)
}

/// 数据库端点（host/port/user/password）来自 DBPILOT_TEST_MYSQL_*；
/// SSH 跳板是测试进程内起的 russh 服务，密码由 start_server() 随机生成。
fn db_fields(ssh_port: u16, password: &str) -> Value {
    let endpoint = common::mysql();
    json!({
        "driver": "mysql",
        "host": endpoint.host,
        "port": endpoint.port,
        "user": endpoint.user,
        "password": endpoint.password,
        "ssh_host": "127.0.0.1",
        "ssh_port": ssh_port,
        "ssh_user": "tester",
        "ssh_auth": "password",
        "ssh_password": password,
    })
}

fn connection_payload(name: &str, ssh_port: u16, password: &str) -> Value {
    let mut body = db_fields(ssh_port, password);
    body["name"] = json!(name);
    body["ssh_host_key_policy"] = json!("accept-new");
    body
}

#[tokio::test]
async fn fingerprint_is_reported_pinned_and_enforced() {
    // 必须真正登录成功才跑：只看端口的话，本机跑着一个密码不同的 MySQL 时
    // 测试会真的去连然后 panic，开源仓库在别人机器上就红了。
    if !common::mysql_usable().await {
        eprintln!("SKIP: DBPILOT_TEST_MYSQL_* does not authenticate");
        return;
    }
    let (ssh_port, password) = start_server().await;
    let root = std::env::temp_dir().join(format!("rma-ssh-fp-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&root).unwrap();
    let initialized = api::init_app(root.join("app").to_string_lossy().into());
    assert_eq!(initialized["ok"], json!(true), "{initialized}");
    let connections_file = initialized["connections_file"].as_str().unwrap().to_string();

    // 1. The probe reports the fingerprint instead of an empty string (N-01).
    let probe = api::connections::test_connection(db_fields(ssh_port, &password))
        .await
        .expect("test connection through the tunnel");
    assert_eq!(probe["ok"], json!(true), "{probe}");
    assert_eq!(probe["tunnelled"], json!(true), "{probe}");
    let fingerprint = probe["ssh_host_key_fingerprint"]
        .as_str()
        .expect("probe must return a fingerprint");
    assert!(
        fingerprint.starts_with("SHA256:"),
        "unexpected fingerprint format: {fingerprint}"
    );
    assert!(
        probe["dial_port"].as_u64().unwrap_or(0) > 0,
        "tunnel port missing: {probe}"
    );

    // 2. Saving the form persists the fingerprint (what the UI does after a
    //    successful probe).
    let mut saved_body = connection_payload("SSH strict", ssh_port, &password);
    saved_body["ssh_host_key"] = json!(fingerprint);
    saved_body["ssh_host_key_policy"] = json!("strict");
    let created = api::connections::create_connection(saved_body)
        .await
        .expect("save connection");
    let strict_id = created["connection"]["id"].as_str().unwrap().to_string();
    let listed = api::connections::list_connections().await.unwrap();
    let stored = listed["connections"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == json!(strict_id))
        .expect("saved connection listed");
    assert_eq!(stored["ssh_host_key"], json!(fingerprint));
    assert_eq!(stored["ssh_host_key_policy"], json!("strict"));

    // 3. strict + matching fingerprint connects.
    let probe_stored =
        api::connections::test_connection(json!({"connection_id": strict_id}))
            .await
            .expect("strict probe with the saved fingerprint");
    assert_eq!(probe_stored["ok"], json!(true), "{probe_stored}");
    assert_eq!(
        probe_stored["ssh_host_key_changed"],
        json!(false),
        "the stored pin must match: {probe_stored}"
    );

    // 4. strict + wrong fingerprint is rejected before any database traffic.
    let mut wrong_body = connection_payload("SSH strict wrong", ssh_port, &password);
    wrong_body["ssh_host_key"] =
        json!("SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    wrong_body["ssh_host_key_policy"] = json!("strict");
    let wrong = api::connections::create_connection(wrong_body)
        .await
        .expect("save wrong-pin connection");
    let wrong_id = wrong["connection"]["id"].as_str().unwrap().to_string();
    let rejected = api::connections::test_connection(json!({"connection_id": wrong_id})).await;
    assert!(
        rejected.is_err(),
        "a strict connection with a mismatched host key must be refused"
    );

    // 5. accept-new pins the key on first real connect, without a prior probe
    //    (the UI promise "first connection trusts and remembers").
    let pinless = api::connections::create_connection(connection_payload(
        "SSH tofu",
        ssh_port,
        &password,
    ))
    .await
    .expect("save pinless connection");
    let pinless_id = pinless["connection"]["id"].as_str().unwrap().to_string();
    api::connections::connect_connection(pinless_id.clone())
        .await
        .expect("connect through accept-new tunnel");
    let listed = api::connections::list_connections().await.unwrap();
    let pinned = listed["connections"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == json!(pinless_id))
        .expect("connect connection listed");
    assert_eq!(
        pinned["ssh_host_key"],
        json!(fingerprint),
        "accept-new must remember the jump host key on first connect"
    );
    // 6. ... and the pin is actually written to disk, not only memory.
    let on_disk: Vec<Value> =
        serde_json::from_str(&std::fs::read_to_string(&connections_file).unwrap()).unwrap();
    let disk_entry = on_disk
        .iter()
        .find(|c| c["id"] == json!(pinless_id))
        .expect("connection persisted");
    assert_eq!(disk_entry["ssh_host_key"], json!(fingerprint));

    // 7. The same pin is enforced on the next connection: connecting again with
    //    the stored key succeeds.
    api::connections::disconnect().await.unwrap();
    api::connections::connect_connection(pinless_id.clone())
        .await
        .expect("reconnect using the persisted pin");

    api::connections::disconnect().await.unwrap();
    std::fs::remove_dir_all(&root).unwrap();
}
