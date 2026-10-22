//! Live verification of the P2-4 paths against real servers.
//!
//!   cargo test --offline --test live_cancel_processlist -- --ignored --test-threads=1 --nocapture
//!
//! Needs a MySQL and a PostgreSQL server; the endpoint, account and password come
//! from the environment (DBPILOT_TEST_MYSQL_* / DBPILOT_TEST_PG_*, see
//! tests/common/mod.rs), so no credential is stored in this repository.
//!
//! What it proves at runtime (not just "the SQL compiles"):
//! 1. server::processes() really returns the live session list: the test reads its
//!    own connection id / backend pid through a query and finds it in the list;
//! 2. query::cancel_query() really interrupts a running statement: a SLEEP /
//!    pg_sleep is started in the background, cancel_query() is called, and the
//!    in-flight result comes back rewritten to the user-facing "查询已取消"
//!    (the N-07 path), with cancelled >= 1.

use serde_json::{json, Value};

use rust_myadmin_core::api;

mod common;

fn init(tag: &str) {
    let dir = std::env::temp_dir().join(format!("rma-live-{tag}-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    let result = api::init_app(dir.to_string_lossy().to_string());
    assert_eq!(result.get("ok"), Some(&Value::Bool(true)), "init: {result}");
}

async fn connect(body: Value) -> String {
    let created = api::connections::create_connection(body).await.unwrap();
    let id = created["connection"]["id"].as_str().unwrap().to_string();
    api::connections::connect_connection(id.clone()).await.unwrap();
    id
}

async fn run_in(database: &str, sql: &str) -> Value {
    api::query::run_query(json!({ "sql": sql, "database": database }))
        .await
        .expect("run_query failed")
}

fn first_cell(value: &Value) -> Value {
    value["results"][0]["rows"][0][0].clone()
}

fn process_ids(processes: &Value) -> Vec<i64> {
    processes["processes"]
        .as_array()
        .expect("processes array")
        .iter()
        .filter_map(|row| row.get("Id").and_then(Value::as_i64))
        .collect()
}

/// Start a long statement in the background and cancel it from the main task.
async fn cancel_a_running_query(database: &str, sleep_sql: &str) -> (Value, Value) {
    let sql = sleep_sql.to_string();
    let database = database.to_string();
    let running = tokio::spawn(async move { run_in(&database, &sql).await });

    // Give the statement time to reach the server and be recorded as active.
    tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
    let cancelled = api::query::cancel_query().await.expect("cancel_query failed");

    let result = tokio::time::timeout(std::time::Duration::from_secs(20), running)
        .await
        .expect("the cancelled query never returned")
        .expect("run_query task panicked");
    (cancelled, result)
}

#[tokio::test]
#[ignore = "requires MySQL; endpoint from DBPILOT_TEST_MYSQL_* (see tests/common/mod.rs)"]
async fn mysql_process_list_and_cancel() {
    init("cancel-mysql");
    let endpoint = common::mysql();
    let _id = connect(json!({
        "name": "live cancel mysql",
        "driver": "mysql",
        "host": endpoint.host,
        "port": endpoint.port,
        "user": endpoint.user,
        "password": endpoint.password,
        "database": "mysql",
    }))
    .await;

    // 1) The process list must contain this very session.
    let own = run_in("mysql", "SELECT CONNECTION_ID() AS id").await;
    let own_id = first_cell(&own).as_i64().expect("CONNECTION_ID()");
    let processes = api::server::processes().await.expect("processes failed");
    let ids = process_ids(&processes);
    assert!(
        ids.contains(&own_id),
        "own connection {own_id} missing from process list {ids:?}"
    );

    // 2) A running statement must be cancellable and reported as cancelled.
    let (cancelled, result) = cancel_a_running_query("mysql", "SELECT SLEEP(30) AS slept").await;
    assert_eq!(cancelled["ok"], Value::Bool(true), "cancel: {cancelled}");
    // P4：响应载荷的 driver 字段现在来自 driver.id()（而不是硬编码字面量）。
    assert_eq!(
        cancelled["driver"],
        Value::String("mysql".into()),
        "cancel payload: {cancelled}"
    );
    assert!(
        cancelled["cancelled"].as_u64().unwrap_or(0) >= 1,
        "no MySQL connection was killed: {cancelled}"
    );
    let error = result["results"][0]["error"].as_str().unwrap_or("");
    assert!(
        error.contains("查询已取消"),
        "cancel was not surfaced to the user: {result}"
    );

    // 3) The console still works afterwards (reconnect / pool invalidation).
    let after = run_in("mysql", "SELECT 1 AS ok").await;
    assert!(
        after["results"][0]["error"].is_null(),
        "console broken after cancel: {after}"
    );
}

#[tokio::test]
#[ignore = "requires PostgreSQL; endpoint from DBPILOT_TEST_PG_* (see tests/common/mod.rs)"]
async fn postgres_process_list_and_cancel() {
    init("cancel-postgres");
    let endpoint = common::postgres();
    let _id = connect(json!({
        "name": "live cancel postgres",
        "driver": "postgres",
        "host": endpoint.host,
        "port": endpoint.port,
        "user": endpoint.user,
        "password": endpoint.password,
        "database": "postgres",
        "ssl_mode": "disable",
    }))
    .await;

    // 1) The process list must contain this very backend.
    let own = run_in("postgres", "SELECT pg_backend_pid() AS pid").await;
    let own_id = first_cell(&own).as_i64().expect("pg_backend_pid()");
    let processes = api::server::processes().await.expect("processes failed");
    let ids = process_ids(&processes);
    assert!(
        ids.contains(&own_id),
        "own backend {own_id} missing from process list {ids:?}"
    );

    // 2) A running statement must be cancellable and reported as cancelled.
    let (cancelled, result) = cancel_a_running_query("postgres", "SELECT pg_sleep(30)").await;
    assert_eq!(cancelled["ok"], Value::Bool(true), "cancel: {cancelled}");
    assert_eq!(
        cancelled["driver"],
        Value::String("postgres".into()),
        "cancel payload: {cancelled}"
    );
    assert!(
        cancelled["cancelled"].as_u64().unwrap_or(0) >= 1,
        "no PostgreSQL backend was cancelled: {cancelled}"
    );
    let error = result["results"][0]["error"].as_str().unwrap_or("");
    assert!(
        error.contains("查询已取消"),
        "cancel was not surfaced to the user: {result}"
    );

    // 3) The connection stays usable after pg_cancel_backend.
    let after = run_in("postgres", "SELECT 1 AS ok").await;
    assert!(
        after["results"][0]["error"].is_null(),
        "session broken after cancel: {after}"
    );
}
// ---------------------------------------------------------------- kill session
//
// api::server::kill_process() 现在走 DatabaseDriver::kill_session；这里在驱动层
// 直接验证：杀掉目标会话后，服务器的进程列表里不再有它。
//
// 注意：不能断言「受害者池的下一条查询失败」——池里可能还有别的连接，sqlx 会
// 换一条继续服务，那是池的正确行为，不是 kill 失败。

use std::time::Duration;

use rust_myadmin_core::core::connection::ConnectionHandle;
use rust_myadmin_core::core::driver::DatabaseDriver;
use rust_myadmin_core::drivers::mysql::driver::MySqlDriver;
use rust_myadmin_core::drivers::postgres::driver::PostgresDriver;
use rust_myadmin_core::drivers::{connect_full, pooled_handle, ConnSpec, DriverKind};

fn mysql_spec() -> ConnSpec {
    let endpoint = common::mysql();
    ConnSpec {
        driver: DriverKind::Mysql,
        host: endpoint.host,
        port: Some(endpoint.port),
        user: endpoint.user,
        password: endpoint.password,
        database: Some("mysql".to_string()),
        ssl_mode: Some("disable".to_string()),
        ..Default::default()
    }
}

fn postgres_spec() -> ConnSpec {
    let endpoint = common::postgres();
    ConnSpec {
        driver: DriverKind::Postgres,
        host: endpoint.host,
        port: Some(endpoint.port),
        user: endpoint.user,
        password: endpoint.password,
        database: Some("postgres".to_string()),
        ssl_mode: Some("disable".to_string()),
        ..Default::default()
    }
}

/// Poll the server's own process list until the victim disappears.
///
/// KILL is asynchronous on the server side (MySQL reports the packet before the
/// thread is fully gone), so a short bounded poll is the reliable check.
async fn wait_until_session_gone(
    driver: &dyn DatabaseDriver,
    conn: &ConnectionHandle,
    victim: i64,
) -> bool {
    for _ in 0..20 {
        let rows = driver.show_processlist(conn).await.unwrap_or_default();
        let present = rows
            .iter()
            .any(|row| row.get("Id").and_then(Value::as_i64) == Some(victim));
        if !present {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    false
}

#[tokio::test]
#[ignore = "requires MySQL; endpoint from DBPILOT_TEST_MYSQL_* (see tests/common/mod.rs)"]
async fn mysql_kill_session_closes_the_victim() {
    let spec = mysql_spec();
    let (victim_pool, _) = connect_full(&spec, Some("mysql")).await.expect("victim pool");
    let victim_handle = pooled_handle(victim_pool, DriverKind::Mysql, None);
    let victim_id = victim_handle
        .query_i64("SELECT CONNECTION_ID() AS id")
        .await
        .expect("CONNECTION_ID()");

    let (killer_pool, _) = connect_full(&spec, Some("mysql")).await.expect("killer pool");
    let killer = pooled_handle(killer_pool, DriverKind::Mysql, None);
    MySqlDriver
        .kill_session(&killer, victim_id)
        .await
        .expect("KILL CONNECTION");

    assert!(
        wait_until_session_gone(&MySqlDriver, &killer, victim_id).await,
        "session {victim_id} is still in the process list after KILL"
    );
}

#[tokio::test]
#[ignore = "requires PostgreSQL; endpoint from DBPILOT_TEST_PG_* (see tests/common/mod.rs)"]
async fn postgres_kill_session_closes_the_victim() {
    let spec = postgres_spec();
    let (victim_pool, _) = connect_full(&spec, Some("postgres")).await.expect("victim pool");
    let victim_handle = pooled_handle(victim_pool, DriverKind::Postgres, None);
    let victim_id = victim_handle
        .query_i64("SELECT pg_backend_pid() AS pid")
        .await
        .expect("pg_backend_pid()");

    let (killer_pool, _) = connect_full(&spec, Some("postgres")).await.expect("killer pool");
    let killer = pooled_handle(killer_pool, DriverKind::Postgres, None);
    PostgresDriver
        .kill_session(&killer, victim_id)
        .await
        .expect("pg_terminate_backend");

    assert!(
        wait_until_session_gone(&PostgresDriver, &killer, victim_id).await,
        "backend {victim_id} is still in pg_stat_activity after terminate"
    );
}
