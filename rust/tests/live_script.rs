//! Live regression tests for the round-29 script-execution fixes (P1..P5).
//!
//!   cargo test --offline --test live_script -- --ignored --test-threads=1
//!
//! They need the local MySQL and PostgreSQL servers the other live suites use.
//! The endpoint, account and password come from the environment
//! (DBPILOT_TEST_MYSQL_* / DBPILOT_TEST_PG_*, see tests/common/mod.rs), so this
//! repository never stores a real account or password. The MySQL sakila test
//! recreates the local `sakila` database from the official dump and is
//! therefore destructive on purpose; it is skipped when the dump file is absent.

use serde_json::{json, Value};

use rust_myadmin_core::api;

mod common;

fn init() {
    let dir = std::env::temp_dir().join(format!("rma-live-script-{}", std::process::id()));
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

async fn mysql_connect(database: &str) -> String {
    let endpoint = common::mysql();
    connect(json!({
        "name": "live script mysql",
        "driver": "mysql",
        "host": endpoint.host,
        "port": endpoint.port,
        "user": endpoint.user,
        "password": endpoint.password,
        "database": database,
    }))
    .await
}

async fn postgres_connect(database: &str) -> String {
    let endpoint = common::postgres();
    connect(json!({
        "name": "live script postgres",
        "driver": "postgres",
        "host": endpoint.host,
        "port": endpoint.port,
        "user": endpoint.user,
        "password": endpoint.password,
        "database": database,
        "ssl_mode": "disable",
    }))
    .await
}

/// Run one console request and return the raw response.
async fn run_in(database: &str, sql: &str) -> Value {
    api::query::run_query(json!({ "sql": sql, "database": database }))
        .await
        .expect("run_query failed")
}


/// Drop the pools before the test process moves on: the next test runs on a
/// fresh tokio runtime, and a pool created on a closed runtime would hand out
/// connections whose driver tasks are gone (acquire then times out).
async fn cleanup() {
    let _ = api::connections::disconnect().await;
}

async fn run(sql: &str) -> Value {
    api::query::run_query(json!({ "sql": sql }))
        .await
        .expect("run_query failed")
}

fn errors_of(response: &Value) -> Vec<String> {
    response["results"]
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item["error"].as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

fn first_cell(response: &Value) -> Value {
    response["results"][0]["rows"][0][0].clone()
}

#[tokio::test]
#[ignore = "requires PostgreSQL; endpoint from DBPILOT_TEST_PG_* (see tests/common/mod.rs)"]
async fn postgres_dump_script_keeps_functions_and_triggers() {
    init();
    let _id = postgres_connect("postgres").await;

    // Fresh database so object counts are unambiguous.
    run("DROP DATABASE IF EXISTS rma_round30_pg").await;
    run("CREATE DATABASE rma_round30_pg").await;
    api::explorer::select_database("rma_round30_pg".to_string())
        .await
        .unwrap();

    // P1: a dollar-quoted body with semicolons must survive both splitting
    // passes. Before the fix the statement was cut at the inner semicolon.
    let response = run_in(
        "rma_round30_pg",
        "CREATE FUNCTION rma_round30_add(a integer) RETURNS integer AS $$ SELECT a + 1; $$ LANGUAGE sql; \
         SELECT rma_round30_add(41) AS answer;",
    )
    .await;
    assert!(
        errors_of(&response).is_empty(),
        "dollar-quoted function failed: {response}"
    );
    assert_eq!(
        response["results"][1]["rows"][0][0],
        json!(42),
        "function body/call broken: {response}"
    );

    // P1: the real pg_dump-style combined script (functions, triggers, views,
    // data). 533 statements; before the fix the second split silently dropped
    // 7 functions and 14 triggers.
    //
    // 夹具路径只能由 DBPILOT_TEST_PAGILA_SCRIPT 给出：发布仓库里不带任何开发机
    // 私有文件，缺失时按 SKIP 处理（与 sakila 用例一致）。
    let Ok(path) = std::env::var("DBPILOT_TEST_PAGILA_SCRIPT") else {
        println!("SKIP: DBPILOT_TEST_PAGILA_SCRIPT not set (pg_dump-style fixture)");
        cleanup().await;
        let _id = postgres_connect("postgres").await;
        run("DROP DATABASE IF EXISTS rma_round30_pg").await;
        cleanup().await;
        return;
    };
    let Ok(script) = std::fs::read_to_string(&path) else {
        println!("SKIP: pagila combined script not found at {path}");
        cleanup().await;
        let _id = postgres_connect("postgres").await;
        run("DROP DATABASE IF EXISTS rma_round30_pg").await;
        cleanup().await;
        return;
    };
    let response = run_in("rma_round30_pg", &script).await;
    let errors = errors_of(&response);
    assert!(
        errors.is_empty(),
        "{} statement(s) failed, first: {:?}",
        errors.len(),
        errors.first()
    );
    assert!(
        response["statement_count"].as_u64().unwrap_or(0) > 400,
        "unexpected statement count: {}",
        response["statement_count"]
    );

    let functions = first_cell(
        &run_in(
            "rma_round30_pg",
            "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace \
             WHERE n.nspname = 'public' AND p.prokind = 'f'",
        )
        .await,
    )
    .as_i64()
    .unwrap_or(0);
    assert!(functions >= 7, "expected >=7 functions, got {functions}");
    let triggers = first_cell(
        &run_in(
            "rma_round30_pg",
            "SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal",
        )
        .await,
    )
    .as_i64()
    .unwrap_or(0);
    assert!(triggers >= 14, "expected >=14 triggers, got {triggers}");
    let tables = first_cell(
        &run_in(
            "rma_round30_pg",
            "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace \
             WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')",
        )
        .await,
    )
    .as_i64()
    .unwrap_or(0);
    assert!(tables >= 22, "expected >=22 tables, got {tables}");

    // Leave no test database behind. Drop all pools first (the script opened
    // connections to the new database), then reconnect to postgres to DROP it:
    // PostgreSQL refuses while any session, including our own pool, is connected.
    cleanup().await;
    let _id = postgres_connect("postgres").await;
    run("DROP DATABASE IF EXISTS rma_round30_pg").await;
    cleanup().await;
}

#[tokio::test]
#[ignore = "requires PostgreSQL; endpoint from DBPILOT_TEST_PG_* (see tests/common/mod.rs)"]
async fn postgres_session_state_survives_statements() {
    init();
    let _id = postgres_connect("postgres").await;
    api::explorer::select_database("postgres".to_string())
        .await
        .unwrap();

    let response = run_in(
        "postgres",
        "SET statement_timeout TO 1234; \
         SET search_path TO public; \
         SELECT current_setting('statement_timeout') AS timeout, \
                current_setting('search_path') AS path",
    )
    .await;
    assert!(errors_of(&response).is_empty(), "{response}");
    let last = response["results"].as_array().unwrap().last().unwrap();
    let row = last["rows"][0].as_array().unwrap();
    assert!(
        row[0].as_str().unwrap_or("").starts_with("1234"),
        "statement_timeout not preserved: {response}"
    );
    assert_eq!(row[1], json!("public"), "search_path not preserved: {response}");
    cleanup().await;
}

#[tokio::test]
#[ignore = "requires MySQL; endpoint from DBPILOT_TEST_MYSQL_* (see tests/common/mod.rs)"]
async fn mysql_session_state_and_recreated_database() {
    init();
    let _id = mysql_connect("mysql").await;

    // P3/P5: session state set by one statement must reach the later ones;
    // P4/P5: executable comments, routines and LOCK TABLES must not fail;
    // P2: a DROP+CREATE DATABASE script must leave usable pools.
    let script = "DROP DATABASE IF EXISTS rma_round30_my;
CREATE DATABASE rma_round30_my;
USE rma_round30_my;
SET FOREIGN_KEY_CHECKS=0;
CREATE TABLE child (id INT PRIMARY KEY, parent_id INT,
  CONSTRAINT fk_parent FOREIGN KEY (parent_id) REFERENCES parent(id));
CREATE TABLE parent (id INT PRIMARY KEY);
SET @rma_answer := 42;
/*!40101 SET @rma_version_comment := 7 */;
CREATE TABLE locked (id INT PRIMARY KEY);
LOCK TABLES locked WRITE;
INSERT INTO locked VALUES (1);
UNLOCK TABLES;
/*!50001 CREATE VIEW v_child AS SELECT id FROM child */;
DELIMITER //
CREATE PROCEDURE p_child() BEGIN SELECT COUNT(*) FROM child; END//
DELIMITER ;
CREATE TRIGGER tr_child BEFORE INSERT ON child FOR EACH ROW SET NEW.parent_id = COALESCE(NEW.parent_id, 0);
SET FOREIGN_KEY_CHECKS=1;
SELECT @rma_answer AS answer, @@FOREIGN_KEY_CHECKS AS fk;";
    let response = run_in("mysql", script).await;
    let errors = errors_of(&response);
    assert!(errors.is_empty(), "{} failure(s): {errors:?}", errors.len());
    let last = response["results"].as_array().unwrap().last().unwrap();
    assert_eq!(last["rows"][0][0], json!(42), "user variable lost: {response}");
    assert_eq!(last["rows"][0][1], json!(1), "FOREIGN_KEY_CHECKS not restored");

    // P2: the next script starts on a re-created database. Before the pool was
    // invalidated this failed with "No database selected" because the cached
    // pool still held the pre-DROP connection.
    let response = run_in(
        "mysql",
        "USE rma_round30_my; \
         CREATE TABLE after_recreate (id INT PRIMARY KEY); \
         INSERT INTO after_recreate VALUES (1); \
         SELECT COUNT(*) AS rows_now FROM after_recreate;",
    )
    .await;
    assert!(errors_of(&response).is_empty(), "{response}");
    let last = response["results"].as_array().unwrap().last().unwrap();
    assert_eq!(last["rows"][0][0], json!(1), "{response}");

    // Objects created through version comments / raw fallback exist.
    let response = run_in(
        "rma_round30_my",
        "SELECT \
           (SELECT COUNT(*) FROM information_schema.VIEWS WHERE TABLE_SCHEMA='rma_round30_my') AS views, \
           (SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='rma_round30_my') AS triggers, \
           (SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='rma_round30_my') AS routines, \
           (SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='rma_round30_my' AND TABLE_TYPE='BASE TABLE') AS tables",
    )
    .await;
    let row = response["results"][0]["rows"][0].as_array().unwrap();
    assert!(row[0].as_i64().unwrap_or(0) >= 1, "view missing: {response}");
    assert!(row[1].as_i64().unwrap_or(0) >= 1, "trigger missing: {response}");
    assert!(row[2].as_i64().unwrap_or(0) >= 1, "routine missing: {response}");
    assert!(row[3].as_i64().unwrap_or(0) >= 4, "tables missing: {response}");

    run("DROP DATABASE IF EXISTS rma_round30_my").await;
    cleanup().await;
}

#[tokio::test]
#[ignore = "requires MySQL (DBPILOT_TEST_MYSQL_*) and a sakila dump at RMA_SAKILA_DUMP"]
async fn mysql_official_sakila_dump_imports_views_triggers_and_routines() {
    init();
    // 官方 sakila dump 需要使用者自己下载；仓库里不带，缺失即 SKIP。
    let Ok(path) = std::env::var("RMA_SAKILA_DUMP") else {
        println!("SKIP: RMA_SAKILA_DUMP not set (official sakila dump)");
        return;
    };
    let Ok(script) = std::fs::read_to_string(&path) else {
        println!("SKIP: sakila dump not found at {path}");
        return;
    };
    let _id = mysql_connect("mysql").await;
    let response = run_in("mysql", &script).await;
    let errors = errors_of(&response);
    if !errors.is_empty() {
        for item in response["results"].as_array().unwrap() {
            if !item["error"].is_null() {
                eprintln!("FAILED STMT: {}", item["statement"]);
                eprintln!("  ERROR: {}", item["error"]);
            }
        }
    }
    assert!(
        errors.is_empty(),
        "{} statement(s) failed, first: {:?}",
        errors.len(),
        errors.first()
    );

    let response = run_in(
        "sakila",
        "SELECT \
           (SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='sakila' AND TABLE_TYPE='BASE TABLE') AS tables, \
           (SELECT COUNT(*) FROM information_schema.VIEWS WHERE TABLE_SCHEMA='sakila') AS views, \
           (SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='sakila') AS triggers, \
           (SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='sakila') AS routines, \
           (SELECT COUNT(*) FROM sakila.film) AS films",
    )
    .await;
    let row = response["results"][0]["rows"][0].as_array().unwrap();
    assert!(row[0].as_i64().unwrap_or(0) >= 16, "tables: {response}");
    assert!(row[1].as_i64().unwrap_or(0) >= 7, "views: {response}");
    assert!(row[2].as_i64().unwrap_or(0) >= 3, "triggers: {response}");
    assert!(row[3].as_i64().unwrap_or(0) >= 6, "routines: {response}");
    assert_eq!(row[4].as_i64(), Some(1000), "film rows: {response}");
    cleanup().await;
}
