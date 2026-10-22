//! Live import tests against the real MySQL / PostgreSQL servers used by the
//! other live suites.
//!
//!   cargo test --test live_import -- --ignored --test-threads=1
//!
//! They prove that the multi-row INSERT literals, the probe transaction
//! (INSERT + read back + ROLLBACK) and the keyed/positional mappings work on the
//! sqlx MySQL and PostgreSQL backends, not only on SQLite.

use serde_json::{json, Value};

use rust_myadmin_core::api;

mod common;

/// MySQL 连接体：端点来自 DBPILOT_TEST_MYSQL_*。
fn mysql_body(name: &str, database: &str) -> Value {
    let endpoint = common::mysql();
    json!({
        "name": name,
        "driver": "mysql",
        "host": endpoint.host,
        "port": endpoint.port,
        "user": endpoint.user,
        "password": endpoint.password,
        "database": database,
    })
}

/// PostgreSQL 连接体：端点来自 DBPILOT_TEST_PG_*。
fn pg_body(name: &str, database: &str) -> Value {
    let endpoint = common::postgres();
    json!({
        "name": name,
        "driver": "postgres",
        "host": endpoint.host,
        "port": endpoint.port,
        "user": endpoint.user,
        "password": endpoint.password,
        "database": database,
        "ssl_mode": "disable",
    })
}

fn init() {
    let dir = std::env::temp_dir().join(format!("rma-live-import-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    let result = api::init_app(dir.to_string_lossy().to_string());
    assert_eq!(result.get("ok"), Some(&Value::Bool(true)), "init: {result}");
}

fn write_csv(name: &str, content: &str) -> String {
    let dir = std::env::temp_dir().join(format!("rma-live-import-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join(name);
    std::fs::write(&path, content).unwrap();
    path.to_string_lossy().to_string()
}

async fn wait_job(job_id: &str) -> Value {
    for _ in 0..800 {
        let status = api::data_import::import_job_status(job_id.to_string()).unwrap();
        if status["done"].as_bool().unwrap_or(false) {
            return status;
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
    panic!("job {job_id} did not finish");
}

async fn run(sql: &str) -> Value {
    api::query::run_query(json!({ "sql": sql })).await.unwrap()
}

fn mapping_keyed(columns: &[&str]) -> Value {
    let columns: Vec<Value> = columns
        .iter()
        .map(|c| json!({ "column": c, "source": c }))
        .collect();
    json!({ "columns": columns, "null_tokens": ["\\N", "NULL"] })
}

#[tokio::test]
#[ignore = "requires MySQL; endpoint from DBPILOT_TEST_MYSQL_* (see tests/common/mod.rs)"]
async fn mysql_import_and_probe() {
    init();
    let created =
        api::connections::create_connection(mysql_body("Live MySQL import", "rustmyadmin_demo"))
            .await
            .unwrap();
    let id = created["connection"]["id"].as_str().unwrap().to_string();
    api::connections::connect_connection(id).await.unwrap();

    run("DROP TABLE IF EXISTS rma_import_live").await;
    run("CREATE TABLE rma_import_live (id INT PRIMARY KEY, name VARCHAR(50), note TEXT, payload JSON NULL)")
        .await;

    // Keyed CSV with quotes/commas and a NULL token.
    let csv = write_csv(
        "mysql.csv",
        "id,name,note,payload\n\
         1,Ada,\"hello, world\",\"{\"\"a\"\": 1}\"\n\
         2,Bob,\\N,NULL\n\
         3,小明,你好,NULL\n",
    );
    let info = api::data_import::import_inspect(csv.clone()).await.unwrap();
    assert_eq!(info["format"], json!("delimited"), "{}", info);
    let mapping = mapping_keyed(&["id", "name", "note", "payload"]);
    let params = json!({
        "path": csv,
        "read": info["read"],
        "fields": info["fields"],
        "mapping": mapping,
    });

    // Probe: inserts and rolls back on MySQL (uses <=> to read the row back).
    let probe = api::data_import::import_probe("rustmyadmin_demo".into(), "rma_import_live".into(), params.clone())
        .await
        .unwrap();
    assert_eq!(probe["affected"], json!(1), "{}", probe);
    assert_eq!(probe["row"]["name"], json!("Ada"), "{}", probe);
    let count = run("SELECT COUNT(*) AS c FROM rma_import_live").await;
    assert_eq!(count["results"][0]["rows"][0][0], json!(0), "probe must roll back");

    // Real import.
    let start = api::data_import::import_execute_start(json!({
        "path": params["path"],
        "read": params["read"],
        "fields": params["fields"],
        "mapping": params["mapping"],
        "database": "rustmyadmin_demo",
        "table": "rma_import_live",
        "options": { "batch_size": 2, "on_error": "stop" },
    }))
    .await
    .unwrap();
    let job = wait_job(start["job_id"].as_str().unwrap()).await;
    assert_eq!(job["state"], json!("done"), "{}", job);
    assert_eq!(job["result"]["rows_inserted"], json!(3), "{}", job);
    let rows = run("SELECT id, name, note FROM rma_import_live ORDER BY id").await;
    let rows = rows["results"][0]["rows"].as_array().unwrap();
    assert_eq!(rows[0][1], json!("Ada"));
    assert_eq!(rows[0][2], json!("hello, world"));
    assert_eq!(rows[1][1], json!("Bob"));
    assert_eq!(rows[1][2], Value::Null);
    assert_eq!(rows[2][1], json!("小明"));

    // Positional CSV (no header) exercises the number-source mapping.
    let positional = write_csv("mysql_pos.csv", "10,Tom\n11,Jerry\n");
    let info = api::data_import::import_inspect(positional.clone()).await.unwrap();
    let start = api::data_import::import_execute_start(json!({
        "path": positional,
        "read": info["read"],
        "fields": info["fields"],
        "mapping": { "columns": [
            { "column": "id", "source": 0 },
            { "column": "name", "source": 1 },
        ]},
        "database": "rustmyadmin_demo",
        "table": "rma_import_live",
        "options": { "batch_size": 100, "on_error": "stop" },
    }))
    .await
    .unwrap();
    let job = wait_job(start["job_id"].as_str().unwrap()).await;
    assert_eq!(job["result"]["rows_inserted"], json!(2), "{}", job);
    let count = run("SELECT COUNT(*) AS c FROM rma_import_live").await;
    assert_eq!(count["results"][0]["rows"][0][0], json!(5));

    // USE is handled as a validated database switch, not raw SQL.
    let switched = api::query::run_query(json!({
        "sql": "USE mysql; SELECT DATABASE() AS db",
    }))
    .await
    .unwrap();
    let results = switched["results"].as_array().unwrap();
    assert_eq!(results.len(), 2, "{}", switched);
    assert!(results[0]["error"].is_null(), "{}", switched);
    assert_eq!(
        results[0]["rows"][0][0],
        json!("已切换到数据库：mysql"),
        "{}",
        switched
    );
    assert_eq!(results[1]["rows"][0][0], json!("mysql"), "{}", switched);
    assert_eq!(switched["use_database"], json!("mysql"), "{}", switched);

    let switched = api::query::run_query(json!({
        "sql": "USE rustmyadmin_demo; SELECT DATABASE() AS db",
    }))
    .await
    .unwrap();
    assert_eq!(
        switched["results"][1]["rows"][0][0],
        json!("rustmyadmin_demo"),
        "{}",
        switched
    );

    // EXPLAIN skips the USE prelude and explains the real statement.
    let explained = api::query::explain(json!({
        "sql": "USE rustmyadmin_demo; SELECT DATABASE()",
    }))
    .await
    .unwrap();
    assert_eq!(explained["results"][0]["error"], Value::Null, "{}", explained);

    // A SQL file may start with USE: it is applied as a session switch, so the
    // following statements target the switched database.
    let use_file = write_csv(
        "use.sql",
        "USE rustmyadmin_demo;
         CREATE TABLE rma_use_file(x INT);
         INSERT INTO rma_use_file VALUES (7);
",
    );
    let start = api::data_import::sql_file_execute_start(
        "mysql".into(),
        use_file,
        json!({ "on_error": "stop" }),
    )
    .await
    .unwrap();
    let job = wait_job(start["job_id"].as_str().unwrap()).await;
    assert_eq!(job["result"]["ok"], json!(true), "{}", job);
    assert_eq!(job["result"]["use_database"], json!("rustmyadmin_demo"), "{}", job);
    let rows = run("SELECT x FROM rustmyadmin_demo.rma_use_file").await;
    assert_eq!(rows["results"][0]["rows"][0][0], json!(7), "{}", rows);
    run("DROP TABLE rustmyadmin_demo.rma_use_file").await;

    // S-03 regression: USE must still respect the connection's only_db /
    // hide_db visibility boundary (the old behaviour rejected USE; the new
    // behaviour applies it only after the same check the database picker uses).
    let mut restricted_body = mysql_body("Live restricted USE", "rustmyadmin_demo");
    restricted_body["only_db"] = json!("rustmyadmin_demo");
    let restricted = api::connections::create_connection(restricted_body)
        .await
        .unwrap();
    let restricted_id = restricted["connection"]["id"].as_str().unwrap().to_string();
    api::connections::connect_connection(restricted_id).await.unwrap();
    let denied = api::query::run_query(json!({
        "sql": "USE mysql; SELECT 1",
    }))
    .await
    .unwrap();
    let denied_results = denied["results"].as_array().unwrap();
    assert_eq!(denied_results.len(), 1, "{}", denied);
    assert!(
        denied_results[0]["error"]
            .as_str()
            .unwrap()
            .contains("没有访问数据库"),
        "{}",
        denied
    );
    let allowed = api::query::run_query(json!({
        "sql": "USE rustmyadmin_demo; SELECT 1",
    }))
    .await
    .unwrap();
    assert_eq!(allowed["results"][1]["error"], Value::Null, "{}", allowed);

    run("DROP TABLE rma_import_live").await;
    api::connections::disconnect().await.unwrap();

    // ---------------------------------------------------------- PostgreSQL ---
    let created =
        api::connections::create_connection(pg_body("Live PG import", "rustmyadmin_demo"))
            .await
            .unwrap();
    let id = created["connection"]["id"].as_str().unwrap().to_string();
    api::connections::connect_connection(id).await.unwrap();

    run("DROP TABLE IF EXISTS public.rma_import_live").await;
    run("CREATE TABLE public.rma_import_live (id INT PRIMARY KEY, name TEXT, note TEXT, payload JSONB NULL)")
        .await;

    let csv = write_csv(
        "pg.csv",
        "id,name,note,payload\n\
         1,Ada,\"hello, world\",\"{\"\"a\"\": 1}\"\n\
         2,Bob,\\N,NULL\n\
         3,小明,你好,NULL\n",
    );
    let info = api::data_import::import_inspect(csv.clone()).await.unwrap();
    let mapping = mapping_keyed(&["id", "name", "note", "payload"]);
    let params = json!({
        "path": csv,
        "read": info["read"],
        "fields": info["fields"],
        "mapping": mapping,
    });
    let probe = api::data_import::import_probe("public".into(), "rma_import_live".into(), params.clone())
        .await
        .unwrap();
    assert_eq!(probe["affected"], json!(1), "{}", probe);
    assert_eq!(probe["row"]["name"], json!("Ada"), "{}", probe);
    let count = run("SELECT COUNT(*) AS c FROM public.rma_import_live").await;
    assert_eq!(count["results"][0]["rows"][0][0], json!(0));

    let start = api::data_import::import_execute_start(json!({
        "path": params["path"],
        "read": params["read"],
        "fields": params["fields"],
        "mapping": params["mapping"],
        "database": "public",
        "table": "rma_import_live",
        "options": { "batch_size": 2, "on_error": "stop" },
    }))
    .await
    .unwrap();
    let job = wait_job(start["job_id"].as_str().unwrap()).await;
    assert_eq!(job["state"], json!("done"), "{}", job);
    assert_eq!(job["result"]["rows_inserted"], json!(3), "{}", job);
    let rows = run("SELECT id, name, note, payload::text FROM public.rma_import_live ORDER BY id").await;
    let rows = rows["results"][0]["rows"].as_array().unwrap();
    assert_eq!(rows[0][1], json!("Ada"));
    assert_eq!(rows[0][2], json!("hello, world"));
    assert!(rows[0][3].as_str().unwrap().contains("\"a\""), "{rows:?}");
    assert_eq!(rows[1][2], Value::Null);
    assert_eq!(rows[2][1], json!("小明"));

    // Positional mapping.
    let positional = write_csv("pg_pos.csv", "10,Tom\n11,Jerry\n");
    let info = api::data_import::import_inspect(positional.clone()).await.unwrap();
    let start = api::data_import::import_execute_start(json!({
        "path": positional,
        "read": info["read"],
        "fields": info["fields"],
        "mapping": { "columns": [
            { "column": "id", "source": 0 },
            { "column": "name", "source": 1 },
        ]},
        "database": "public",
        "table": "rma_import_live",
        "options": { "batch_size": 100, "on_error": "stop" },
    }))
    .await
    .unwrap();
    let job = wait_job(start["job_id"].as_str().unwrap()).await;
    assert_eq!(job["result"]["rows_inserted"], json!(2), "{}", job);
    let count = run("SELECT COUNT(*) AS c FROM public.rma_import_live").await;
    assert_eq!(count["results"][0]["rows"][0][0], json!(5));

    // EXPLAIN skips a SET search_path prelude (the table page opens with it).
    let explained = api::query::explain(json!({
        "sql": "SET search_path TO public; SELECT 1",
        "database": "public",
    }))
    .await
    .unwrap();
    assert_eq!(explained["results"][0]["error"], Value::Null, "{}", explained);

    // PostgreSQL has no USE statement: the console reports a hint instead of
    // forwarding the raw SQL.
    let attempt = api::query::run_query(json!({
        "sql": "USE public; SELECT 1",
        "database": "public",
    }))
    .await
    .unwrap();
    let results = attempt["results"].as_array().unwrap();
    assert_eq!(results.len(), 1, "{}", attempt);
    assert!(
        results[0]["error"]
            .as_str()
            .unwrap()
            .contains("PostgreSQL 没有 USE"),
        "{}",
        attempt
    );

    run("DROP TABLE public.rma_import_live").await;
    api::connections::disconnect().await.unwrap();
}
