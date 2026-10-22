//! The SQL console must never materialise an unbounded result set (S-08).
//!
//! A plain `SELECT *` over a 1,000,000-row table froze the UI for ~200s and
//! used ~1 GB of RSS; 3,000,000 rows froze it for over 6 minutes and had to be
//! force-killed. `Db::run_sql_limited` streams rows and stops at the cap, so
//! the console can show a bounded result and tell the user it was cut off.

use rust_myadmin_core::api;
use rust_myadmin_core::db;
use rust_myadmin_core::core::connection::ConnectionHandle;
use rust_myadmin_core::drivers::{connect_full, pooled_handle, ConnSpec, DriverKind};
use serde_json::json;

mod common;

fn sqlite_spec(path: &std::path::Path) -> ConnSpec {
    ConnSpec {
        driver: DriverKind::Sqlite,
        database: Some(path.to_string_lossy().into()),
        ..Default::default()
    }
}

async fn connect_sqlite(root: &std::path::Path) -> ConnectionHandle {
    let file = root.join("limit.sqlite");
    std::fs::write(&file, []).unwrap();
    let (pool, _tunnel) = connect_full(&sqlite_spec(&file), None).await.expect("open sqlite");
    pooled_handle(pool, DriverKind::Sqlite, None)
}


/// P7：旧门面的 run_sql_limited 已移除。测试直接用句柄逐条执行并合并截断标记，
/// 语义与原方法一致（任一语句被截断则整批 truncated = true）。
async fn run_limited(db: &ConnectionHandle, sql: &str, max_rows: usize) -> (Vec<db::ResultSet>, bool) {
    let handle = db;
    let mut out = Vec::new();
    let mut truncated = false;
    for stmt in db::split_statements(sql) {
        let (result, cut) = handle.execute_limited(&stmt, max_rows).await;
        truncated |= cut;
        out.push(result);
    }
    (out, truncated)
}

#[tokio::test]
async fn caps_row_results_and_flags_truncation() {
    let root = std::env::temp_dir().join(format!("rma-limit-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&root).unwrap();
    let db = connect_sqlite(&root).await;

    let (created, _) = run_limited(&db, 
            "CREATE TABLE t(x INTEGER); WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 100) INSERT INTO t SELECT x FROM c;",
            10,
        )
        .await;
    assert!(
        created.iter().all(|r| r.error.is_none()),
        "setup failed: {:?}",
        created.iter().map(|r| r.error.clone()).collect::<Vec<_>>()
    );

    // Under the cap: everything is returned, no truncation flag.
    let (results, truncated) = run_limited(&db, "SELECT x FROM t ORDER BY x", 10_000).await;
    assert!(!truncated);
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].rows.len(), 100);
    assert!(!results[0].truncated);

    // Over the cap: exactly N rows, flagged truncated.
    let (results, truncated) = run_limited(&db, "SELECT x FROM t ORDER BY x", 10).await;
    assert!(truncated, "100 rows under a 10-row cap must be truncated");
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].rows.len(), 10);
    assert_eq!(results[0].row_count, 10);
    assert!(results[0].truncated);
    // The rows kept are the first ones, in order, not an arbitrary subset.
    assert_eq!(results[0].rows.first().and_then(|r| r.first()), Some(&json!(1)));
    assert_eq!(results[0].rows.last().and_then(|r| r.first()), Some(&json!(10)));

    // A multi-statement script marks the batch when any statement was cut off,
    // and the statements after it still run.
    let (results, truncated) = run_limited(&db, "SELECT x FROM t ORDER BY x; SELECT 42 AS answer", 10)
        .await;
    assert!(truncated);
    assert_eq!(results.len(), 2);
    assert_eq!(results[1].rows.len(), 1);
    assert!(!results[1].truncated);

    // Non-row statements are untouched by the limited path.
    let (results, truncated) = run_limited(&db, "INSERT INTO t VALUES (101)", 10).await;
    assert!(!truncated);
    assert_eq!(results[0].kind, "affected");
    assert_eq!(results[0].row_count, 1);

    // The pool is still usable after a truncated statement closed a connection.
    let (results, _) = run_limited(&db, "SELECT COUNT(*) AS c FROM t", 10_000)
        .await;
    assert_eq!(results[0].rows.len(), 1);

    std::fs::remove_dir_all(root).unwrap();
}

/// End-to-end through the console API: the response must expose the cap and a
/// truncation flag so the UI can render the "result was cut off" banner.
#[tokio::test]
async fn console_response_reports_row_limit_and_truncation() {
    let root = std::env::temp_dir().join(format!("rma-limit-api-{}", uuid::Uuid::new_v4()));
    let sqlite_dir = root.join("db");
    std::fs::create_dir_all(&sqlite_dir).unwrap();
    let file = sqlite_dir.join("main.sqlite");
    std::fs::write(&file, []).unwrap();
    api::init_app(root.join("app").to_string_lossy().into());
    let made = api::connections::create_connection(json!({
        "name": "LimitTest",
        "driver": "sqlite",
        "database": file,
        "sqlite_dir": sqlite_dir,
    }))
    .await
    .unwrap();
    let id = made["connection"]["id"].as_str().unwrap().to_string();
    api::connections::connect_connection(id).await.unwrap();

    // Create > cap rows: 50,005 so the last 5 must be cut off.
    let total = api::query::MAX_CONSOLE_ROWS + 5;
    let setup = api::query::run_query(json!({
        "sql": format!(
            "CREATE TABLE big(x INTEGER); WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < {total}) INSERT INTO big SELECT x FROM c;"
        )
    }))
    .await
    .unwrap();
    assert!(setup["results"][0]["error"].is_null(), "setup: {setup}");

    let response = api::query::run_query(json!({"sql": "SELECT x FROM big ORDER BY x"}))
        .await
        .unwrap();
    assert_eq!(response["truncated"], json!(true));
    assert_eq!(response["row_limit"], json!(api::query::MAX_CONSOLE_ROWS));
    let first = &response["results"][0];
    assert_eq!(first["kind"], json!("rows"));
    assert_eq!(first["truncated"], json!(true));
    let rows = first["rows"].as_array().unwrap();
    assert_eq!(rows.len(), api::query::MAX_CONSOLE_ROWS);
    assert_eq!(rows.first(), Some(&json!([1])));
    assert_eq!(rows.last(), Some(&json!([api::query::MAX_CONSOLE_ROWS])));

    // A normal small query is not affected.
    let small = api::query::run_query(json!({"sql": "SELECT 1 AS one"}))
        .await
        .unwrap();
    assert_eq!(small["truncated"], json!(false));
    assert_eq!(small["results"][0]["rows"], json!([[1]]));

    api::connections::disconnect().await.unwrap();
    std::fs::remove_dir_all(root).unwrap();
}

/// The MySQL streaming path is different from SQLite: when the cap is reached
/// the connection is closed mid-result-set, which must (a) stop the server-side
/// query and (b) leave the pool usable for the next query. A cross join over
/// information_schema gives a result set far larger than the cap without
/// creating any table.
///
/// 端点来自 DBPILOT_TEST_MYSQL_*（见 tests/common/mod.rs），仓库里不留账号密码。
#[tokio::test]
async fn mysql_cap_closes_stream_and_pool_recovers() {
    // 必须真正登录成功才跑（只看端口会在“有库但密码不对”的机器上 panic）。
    if !common::mysql_usable().await {
        eprintln!("SKIP: DBPILOT_TEST_MYSQL_* does not authenticate");
        return;
    }
    let endpoint = common::mysql();
    let spec = ConnSpec {
        driver: DriverKind::Mysql,
        host: endpoint.host.clone(),
        port: Some(endpoint.port),
        user: endpoint.user.clone(),
        password: endpoint.password.clone(),
        ..Default::default()
    };
    let (pool, _tunnel) = match connect_full(&spec, None).await {
        Ok(connection) => connection,
        Err(error) => {
            eprintln!("SKIP: cannot connect to MySQL from DBPILOT_TEST_MYSQL_*: {error}");
            return;
        }
    };
    let db = pooled_handle(pool, DriverKind::Mysql, None);

    let cap = 10_000usize;
    let (results, truncated) = run_limited(&db, 
            "SELECT a.TABLE_NAME, b.COLUMN_NAME FROM information_schema.COLUMNS a \
             CROSS JOIN information_schema.COLUMNS b",
            cap,
        )
        .await;
    assert!(truncated, "a cross join over information_schema must exceed {cap} rows");
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].rows.len(), cap);
    assert!(results[0].truncated);
    assert!(results[0].error.is_none(), "unexpected error: {:?}", results[0].error);

    // The closed connection must not poison the pool: the next query opens a
    // fresh connection and returns normally.
    let (results, truncated) = run_limited(&db, "SELECT 42 AS answer", 10).await;
    assert!(!truncated);
    assert!(results[0].error.is_none(), "pool did not recover: {:?}", results[0].error);
    assert_eq!(results[0].rows.first().and_then(|r| r.first()), Some(&json!(42)));
}
