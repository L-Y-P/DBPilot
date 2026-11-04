//! 四连接性能基准：perf-mysql / PostgreSQL / SQLite / SSH 隧道 MySQL。
//!
//! 通过 DBPILOT_PERF=1 开启。每种连接测：连接建立耗时、list_databases、
//! list_tables、简单查询延迟(多次取中位数)、中等结果集查询。
//!
//! 连接参数全部来自环境变量，缺省按本机默认：
//!   MySQL      DBPILOT_TEST_MYSQL_HOST/PORT/USER/PASSWORD  (+ FCONN_MYSQL_DB 默认 dbpilot_perf)
//!   PostgreSQL DBPILOT_TEST_PG_HOST/PORT/USER/PASSWORD      (+ FCONN_PG_DB 默认 dbpilot_perf)
//!   SQLite     FCONN_SQLITE_FILE (默认 C圈盘, 见下)
//!   SSH        FCONN_SSH_HOST/USER/PASSWORD/REMOTE_HOST/REMOTE_PORT/DB
//!
//! 输出每项一行，直接打印到 stdout。

use std::time::Instant;
use rust_myadmin_core::api;
use serde_json::{json, Value};

fn enabled() -> bool { std::env::var("DBPILOT_PERF").map(|v| v == "1").unwrap_or(false) }

fn ev(k: &str) -> Option<String> { std::env::var(k).ok().filter(|s| !s.is_empty()) }
fn evd(k: &str, d: &str) -> String { ev(k).unwrap_or_else(|| d.to_string()) }

fn init_state() {
    let dir = std::env::temp_dir().join("dbpilot-fconn-state");
    let _ = std::fs::create_dir_all(&dir);
    let r = api::init_app(dir.to_string_lossy().to_string());
    assert_eq!(r.get("ok"), Some(&Value::Bool(true)), "init_app: {r}");
}

async fn connect(body: Value) -> Value {
    let _ = api::connections::disconnect().await;
    let created = api::connections::create_connection(body).await.expect("create_connection");
    let id = created["connection"]["id"].as_str().expect("id").to_string();
    api::connections::connect_connection(id).await.expect("connect_connection");
    created
}

fn ms(d: std::time::Duration) -> f64 { d.as_secs_f64() * 1000.0 }

async fn timed_query(sql: &str) -> (f64, usize, usize) {
    let t = Instant::now();
    let res = api::query::run_query(json!({ "sql": sql })).await.expect("run_query");
    let e = ms(t.elapsed());
    let rows = res["results"].as_array().and_then(|a| a.first())
        .and_then(|r| r["row_count"].as_u64()).unwrap_or(0) as usize;
    (e, rows, res.to_string().len())
}

/// 某类连接：连接耗时、库列表、表清单、简单查询 x5 中位数、中等结果集。
async fn bench(label: &str, body: Value, db_for_tables: &str, simple_sql: &str, mid_sql: &str) {
    println!("\n########## {label} ##########");
    let t = Instant::now();
    let conn = connect(body).await;
    let connect_ms = ms(t.elapsed());
    println!("{:<34} {:>10.1} ms", "连接建立", connect_ms);

    let t = Instant::now();
    let dbs = api::explorer::list_databases().await.expect("list_databases");
    let dbs_n = dbs.get("databases").and_then(|v| v.as_array()).map(|a| a.len()).unwrap_or(0);
    println!("{:<34} {:>10.1} ms   dbs={dbs_n}", "list_databases", ms(t.elapsed()));

    let t = Instant::now();
    match api::explorer::list_tables(db_for_tables.to_string()).await {
        Ok(v) => {
            let n = v.get("tables").and_then(|x| x.as_array()).map(|a| a.len()).unwrap_or(0);
            println!("{:<34} {:>10.1} ms   tables={n}", "list_tables", ms(t.elapsed()));
        }
        Err(e) => println!("{:<34} {:>10.1} ms   ERR={e}", "list_tables", ms(t.elapsed())),
    }

    // 简单查询 x5 取中位数
    let mut ts = Vec::new();
    for _ in 0..5 {
        let (e, rows, _) = timed_query(simple_sql).await;
        ts.push(e);
        let _ = rows;
    }
    ts.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!("{:<34} {:>10.1} ms   (median of 5)", "简单查询", ts[ts.len()/2]);

    let (e, rows, bytes) = timed_query(mid_sql).await;
    println!("{:<34} {:>10.1} ms   rows={rows} json={}KB", "中等结果集查询", e, bytes/1024);

    let _ = conn;
    println!("-- {label} 结束 --");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn perf_four_connections() {
    if !enabled() {
        eprintln!("skip: 设 DBPILOT_PERF=1 才跑");
        return;
    }
    init_state();

    // 1) MySQL 本地 (perf-mysql / r68-remote-mysql-ssh 指向同一实例)
    let my_host = evd("DBPILOT_TEST_MYSQL_HOST", "127.0.0.1");
    let my_port: u16 = evd("DBPILOT_TEST_MYSQL_PORT", "3306").parse().unwrap_or(3306);
    let my_user = evd("DBPILOT_TEST_MYSQL_USER", "root");
    let my_pass = evd("DBPILOT_TEST_MYSQL_PASSWORD", "123456");
    let my_db = evd("FCONN_MYSQL_DB", "dbpilot_perf");
    bench(
        "perf-mysql (MySQL 127.0.0.1:3306)",
        json!({"driver":"mysql","host":my_host,"port":my_port,"user":my_user,"password":my_pass,"database":my_db,"ssl_mode":"disable"}),
        &my_db,
        "SELECT 1",
        "SELECT * FROM narrow_10m LIMIT 50000",
    ).await;

    // 2) PostgreSQL
    if let Some(_) = ev("DBPILOT_TEST_PG_HOST").or(Some("127.0.0.1".into())) {
        let pg_host = evd("DBPILOT_TEST_PG_HOST", "127.0.0.1");
        let pg_port: u16 = evd("DBPILOT_TEST_PG_PORT", "5432").parse().unwrap_or(5432);
        let pg_user = evd("DBPILOT_TEST_PG_USER", "postgres");
        let pg_pass = evd("DBPILOT_TEST_PG_PASSWORD", "123456");
        let pg_db = evd("FCONN_PG_DB", "dbpilot_perf");
        bench(
            "PostgreSQL@127.0.0.1 (PG 5432)",
            json!({"driver":"postgres","host":pg_host,"port":pg_port,"user":pg_user,"password":pg_pass,"database":pg_db,"ssl_mode":"disable"}),
            &pg_db,
            "SELECT 1",
            "SELECT * FROM narrow_1m LIMIT 50000",
        ).await;
    }

    // 3) SQLite
    if let Some(sqlite_file) = ev("FCONN_SQLITE_FILE") {
        bench(
            "r68-sqlite-demo (SQLite 文件)",
            json!({"driver":"sqlite","database":sqlite_file}),
            "",
            "SELECT 1",
            "SELECT * FROM demo LIMIT 50000",
        ).await;
    }

    // 4) SSH 隧道 MySQL（跳板 192.168.1.45）
    if let Some(ssh_host) = ev("FCONN_SSH_HOST") {
        let ssh_user = evd("FCONN_SSH_USER", "ssh");
        let ssh_pass = evd("FCONN_SSH_PASSWORD", "123456");
        let remote_host = evd("FCONN_REMOTE_HOST", "127.0.0.1");
        let remote_port: u16 = evd("FCONN_REMOTE_PORT", "3306").parse().unwrap_or(3306);
        let db = evd("FCONN_SSH_DB", "dbpilot_perf");
        bench(
            "r68-remote-mysql-ssh (SSH 隧道)",
            json!({"driver":"mysql","host":remote_host,"port":remote_port,"user":"root","password":"123456","database":db,"ssl_mode":"disable",
                   "ssh_host":ssh_host,"ssh_port":22,"ssh_user":ssh_user,"ssh_auth":"password","ssh_password":ssh_pass}),
            &db,
            "SELECT 1",
            "SELECT * FROM narrow_10m LIMIT 50000",
        ).await;
    }
}
