//! Optional tests that run against a real database server on this machine.
//!
//! These are marked `#[ignore]` so the default `cargo test` stays hermetic;
//! run them explicitly once a server is available:
//!
//!   cargo test --test live_databases -- --ignored --nocapture
//!
//! They exist because SQLite exercises a different sqlx backend than MySQL /
//! PostgreSQL, and the desktop app must work against all three.

use serde_json::{json, Value};

use rust_myadmin_core::api;

mod common;

/// PostgreSQL 连接体：host/port/user/password 全部来自 DBPILOT_TEST_PG_*，
/// 仓库里不保留任何真实账号密码字面量。
fn pg_body(name: Option<&str>, database: Option<&str>) -> Value {
    let endpoint = common::postgres();
    let mut body = json!({
        "driver": "postgres",
        "host": endpoint.host,
        "port": endpoint.port,
        "user": endpoint.user,
        "password": endpoint.password,
        "ssl_mode": "disable",
    });
    if let Some(name) = name {
        body["name"] = json!(name);
    }
    if let Some(database) = database {
        body["database"] = json!(database);
    }
    body
}

/// MySQL 连接体：host/port/user/password 全部来自 DBPILOT_TEST_MYSQL_*。
fn mysql_body(name: Option<&str>, database: Option<&str>) -> Value {
    let endpoint = common::mysql();
    let mut body = json!({
        "driver": "mysql",
        "host": endpoint.host,
        "port": endpoint.port,
        "user": endpoint.user,
        "password": endpoint.password,
    });
    if let Some(name) = name {
        body["name"] = json!(name);
    }
    if let Some(database) = database {
        body["database"] = json!(database);
    }
    body
}

/// 受限角色 rma_limited 的密码：测试运行时临时生成，仓库里不留任何字面量。
///
/// 这里用进程号而不是固定串，只是为了每次运行各不相同；PostgreSQL 用 trust
/// 认证时密码本身不参与校验，角色权限才是被测对象。
fn restricted_role_password() -> String {
    format!("rma-limited-{}", std::process::id())
}

async fn ok<T>(future: impl std::future::Future<Output = anyhow::Result<T>>) -> T {
    match future.await {
        Ok(value) => value,
        Err(e) => panic!("unexpected error: {e}"),
    }
}

fn str_of(value: &Value, key: &str) -> String {
    value.get(key).and_then(|v| v.as_str()).unwrap_or("").to_string()
}

async fn connect(body: Value) -> String {
    let created = ok(api::connections::create_connection(body)).await;
    let id = str_of(&created["connection"], "id");
    assert!(!id.is_empty(), "connection not created: {created}");
    ok(api::connections::connect_connection(id.clone())).await;
    id
}

fn init() {
    let dir = std::env::temp_dir().join(format!("rma-live-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    let result = api::init_app(dir.to_string_lossy().to_string());
    assert_eq!(result.get("ok"), Some(&Value::Bool(true)), "init: {result}");
}


/// PostgreSQL: connect to the instance, switch databases lazily, manage schemas
/// and databases through the admin fallback.
#[tokio::test]
#[ignore = "requires PostgreSQL; endpoint from DBPILOT_TEST_PG_* (see tests/common/mod.rs)"]
async fn postgres_instance_tree() {
    init();

    let probe = ok(api::connections::test_connection(pg_body(
        None,
        Some("rma_missing_database"),
    )))
    .await;
    assert_eq!(probe.get("ok"), Some(&Value::Bool(true)), "probe: {probe}");
    let fallback = str_of(&probe, "database");
    assert_ne!(fallback, "rma_missing_database", "fallback: {probe}");

    let created = ok(api::connections::create_connection(pg_body(
        Some("Live PostgreSQL tree"),
        None,
    )))
    .await;
    let id = str_of(&created["connection"], "id");
    let connected = ok(api::connections::connect_connection(id.clone())).await;
    let active = connected["connection"]["active_database"]
        .as_str()
        .unwrap_or("")
        .to_string();
    assert!(!active.is_empty(), "no initial database: {connected}");

    let instance = ok(api::explorer::instance_databases()).await;
    let names: Vec<String> = instance["databases"]
        .as_array()
        .expect("databases array")
        .iter()
        .filter_map(|d| d.get("name").and_then(|v| v.as_str()).map(str::to_string))
        .collect();
    assert!(names.iter().any(|n| n == "rustmyadmin_demo"), "databases: {names:?}");
    assert!(names.len() > 1, "expected multiple databases: {names:?}");

    let selected = ok(api::explorer::select_database("rustmyadmin_demo".into())).await;
    assert_eq!(str_of(&selected, "database"), "rustmyadmin_demo");
    let schema_names: Vec<String> = selected["schemas"]
        .as_array()
        .expect("schemas array")
        .iter()
        .filter_map(|s| s.get("name").and_then(|v| v.as_str()).map(str::to_string))
        .collect();
    assert!(schema_names.iter().any(|s| s == "public"), "schemas: {schema_names:?}");
    assert!(!str_of(&selected, "search_path").is_empty(), "search_path: {selected}");

    // Reading another database's schemas is lazy and must not switch the
    // active database.
    let postgres = ok(api::explorer::list_schemas("postgres".into())).await;
    assert!(
        postgres["schemas"]
            .as_array()
            .map(|a| a.iter().any(|s| s.get("name") == Some(&Value::from("public"))))
            .unwrap_or(false),
        "postgres schemas: {postgres}"
    );
    let after = ok(api::explorer::instance_databases()).await;
    assert_eq!(after["active_database"], Value::from("rustmyadmin_demo"));

    // Schema DDL runs on the active database pool.
    let schema = "rma_tree_selftest";
    let _ = ok(api::query::run_query(json!({
        "sql": format!("DROP SCHEMA IF EXISTS {schema} CASCADE"),
    })))
    .await;
    ok(api::explorer::create_schema(schema.into())).await;
    ok(api::query::run_query(json!({
        "sql": format!("CREATE TABLE {schema}.t (id int PRIMARY KEY, name text)"),
    })))
    .await;
    let tables = ok(api::explorer::list_tables(schema.into())).await;
    assert!(
        tables["tables"]
            .as_array()
            .map(|a| a.iter().any(|t| t.get("name") == Some(&Value::from("t"))))
            .unwrap_or(false),
        "tables: {tables}"
    );

    // Instance-level create/drop database through the admin connection.
    let scratch_db = "rma_instance_selftest";
    let _ = api::explorer::drop_database(scratch_db.into()).await;
    ok(api::explorer::create_database(json!({ "name": scratch_db }), false)).await;
    let instance = ok(api::explorer::instance_databases()).await;
    assert!(
        instance["databases"]
            .as_array()
            .map(|a| a.iter().any(|d| d.get("name") == Some(&Value::from(scratch_db))))
            .unwrap_or(false),
        "created database missing: {instance}"
    );
    ok(api::explorer::drop_database(scratch_db.into())).await;
    let instance = ok(api::explorer::instance_databases()).await;
    assert!(
        !instance["databases"]
            .as_array()
            .map(|a| a.iter().any(|d| d.get("name") == Some(&Value::from(scratch_db))))
            .unwrap_or(false),
        "dropped database still listed: {instance}"
    );

    ok(api::explorer::drop_schema(schema.into())).await;
    ok(api::connections::disconnect()).await;
    ok(api::connections::delete_connection(id)).await;
}


/// PostgreSQL: a long query can be cancelled from the SQL console.
#[tokio::test]
#[ignore = "requires PostgreSQL; endpoint from DBPILOT_TEST_PG_* (see tests/common/mod.rs)"]
async fn postgres_cancel_query() {
    init();
    connect(pg_body(Some("Live cancel"), Some("rustmyadmin_demo"))).await;

    let handle = tokio::spawn(async {
        api::query::run_query(json!({ "sql": "SELECT pg_sleep(30)" })).await
    });
    tokio::time::sleep(std::time::Duration::from_millis(800)).await;
    let cancel = ok(api::query::cancel_query()).await;
    assert!(
        cancel.get("cancelled").and_then(|v| v.as_u64()).unwrap_or(0) > 0,
        "cancel did not find the backend: {cancel}"
    );
    let payload = match handle.await.expect("query task") {
        Ok(value) => value,
        Err(error) => panic!("query error: {error}"),
    };
    assert_eq!(payload["failed"], Value::from(1), "cancel result: {payload}");
    let error = payload["results"][0]["error"].as_str().unwrap_or("");
    // The user-facing message is localised ("查询已取消…"); accept either the
    // Chinese wording or an English "cancel" from older payloads.
    assert!(
        error.contains("取消") || error.to_ascii_lowercase().contains("cancel"),
        "expected cancellation error: {error}"
    );
    ok(api::connections::disconnect()).await;
}


/// PostgreSQL: a role with access to one business database only.
///
/// The role cannot open postgres/template1; a blank connection should fail with
/// the "fill in a default database" hint, while connecting with the business
/// database must work and the tree must grey out databases without CONNECT.
/// Management actions must be disabled by the capability probe.
#[tokio::test]
#[ignore = "requires PostgreSQL; endpoint from DBPILOT_TEST_PG_* (see tests/common/mod.rs)"]
async fn postgres_restricted_role() {
    init();
    let super_id = connect(pg_body(Some("Live restricted super"), Some("postgres"))).await;

    // Set up a login role that can reach only rustmyadmin_demo. PUBLIC CONNECT
    // on postgres/template1 is revoked for the duration of the test.
    let limited_pw = restricted_role_password();
    let setup = [
        "DROP ROLE IF EXISTS rma_limited".to_string(),
        format!(
            "CREATE ROLE rma_limited LOGIN PASSWORD '{limited_pw}' NOSUPERUSER NOCREATEDB NOCREATEROLE"
        ),
        "REVOKE CONNECT ON DATABASE postgres FROM PUBLIC".to_string(),
        "REVOKE CONNECT ON DATABASE template1 FROM PUBLIC".to_string(),
        "GRANT CONNECT ON DATABASE rustmyadmin_demo TO rma_limited".to_string(),
        "GRANT USAGE ON SCHEMA public TO rma_limited".to_string(),
    ];
    for sql in setup {
        ok(api::query::run_query(json!({ "sql": sql }))).await;
    }
    ok(api::connections::disconnect()).await;

    // Blank database: no management DB can be reached; the error must tell the
    // user to fill a default database instead of only saying "connection failed".
    let mut restricted = pg_body(None, None);
    restricted["user"] = json!("rma_limited");
    restricted["password"] = json!(limited_pw.clone());
    let error = api::connections::test_connection(restricted)
        .await
        .expect_err("restricted role should not find an admin database");
    assert!(
        error.to_string().contains("默认数据库"),
        "missing fallback hint: {error}"
    );

    let mut limited = pg_body(Some("Live restricted"), Some("rustmyadmin_demo"));
    limited["user"] = json!("rma_limited");
    limited["password"] = json!(limited_pw.clone());
    let limited_id = connect(limited).await;

    let instance = ok(api::explorer::instance_databases()).await;
    let databases = instance["databases"].as_array().cloned().unwrap_or_default();
    let can_connect = |name: &str| {
        databases
            .iter()
            .find(|d| d.get("name") == Some(&Value::from(name)))
            .and_then(|d| d.get("can_connect"))
            .and_then(|v| v.as_bool())
    };
    assert_eq!(can_connect("rustmyadmin_demo"), Some(true), "instance: {instance}");
    // Databases without CONNECT are filtered out of the list (round 20 fix), so
    // "postgres" may be absent rather than present with can_connect=false.
    assert_ne!(can_connect("postgres"), Some(true), "instance: {instance}");
    assert!(
        api::explorer::select_database("postgres".into()).await.is_err(),
        "restricted role selected postgres"
    );

    let caps = ok(api::server::server_privileges()).await;
    assert_eq!(caps["can_manage_accounts"], Value::Bool(false), "caps: {caps}");
    assert_eq!(caps["can_create_database"], Value::Bool(false), "caps: {caps}");
    assert!(
        api::server::list_db_users().await.is_err(),
        "restricted role listed accounts"
    );

    // Restore the cluster state for other tests.
    ok(api::connections::disconnect()).await;
    let super_id_again = connect(pg_body(Some("Live restricted super 2"), Some("postgres"))).await;
    for sql in [
        "GRANT CONNECT ON DATABASE postgres TO PUBLIC",
        "GRANT CONNECT ON DATABASE template1 TO PUBLIC",
        "REVOKE ALL ON DATABASE rustmyadmin_demo FROM rma_limited",
        "REVOKE ALL ON SCHEMA public FROM rma_limited",
        "DROP ROLE IF EXISTS rma_limited",
    ] {
        let _ = api::query::run_query(json!({ "sql": sql })).await;
    }
    let _ = ok(api::connections::disconnect()).await;
    let _ = api::connections::delete_connection(super_id).await;
    let _ = api::connections::delete_connection(limited_id).await;
    let _ = api::connections::delete_connection(super_id_again).await;
}


/// MySQL: cancel a long query by killing its connection and reconnecting.
#[tokio::test]
#[ignore = "requires MySQL; endpoint from DBPILOT_TEST_MYSQL_* (see tests/common/mod.rs)"]
async fn mysql_cancel_query() {
    init();
    connect(mysql_body(Some("Live MySQL cancel"), Some("rustmyadmin_demo"))).await;

    let handle = tokio::spawn(async {
        api::query::run_query(json!({ "sql": "SELECT SLEEP(30)" })).await
    });
    tokio::time::sleep(std::time::Duration::from_millis(800)).await;
    let cancel = ok(api::query::cancel_query()).await;
    assert!(
        cancel.get("cancelled").and_then(|v| v.as_u64()).unwrap_or(0) > 0,
        "cancel did not find the MySQL connection: {cancel}"
    );
    assert_eq!(cancel.get("reconnected"), Some(&Value::Bool(true)));
    let payload = match handle.await.expect("query task") {
        Ok(value) => value,
        Err(error) => panic!("query error: {error}"),
    };
    assert_eq!(payload["failed"], Value::from(1), "cancel result: {payload}");

    // The killed pool entry was forgotten; this must transparently reconnect.
    let after = ok(api::query::run_query(json!({ "sql": "SELECT 1" }))).await;
    assert_eq!(after.get("failed"), Some(&Value::from(0)), "reconnect: {after}");
    ok(api::connections::disconnect()).await;
}

/// Connect to the local MySQL, list databases, read a table and run SQL.
#[tokio::test]
#[ignore = "requires MySQL; endpoint from DBPILOT_TEST_MYSQL_* (see tests/common/mod.rs)"]
async fn mysql_round_trip() {
    init();

    let probe = ok(api::connections::test_connection(mysql_body(None, None))).await;
    assert_eq!(probe.get("ok"), Some(&Value::Bool(true)), "probe: {probe}");
    assert!(
        probe.get("version").and_then(|v| v.as_str()).map(|v| !v.is_empty()).unwrap_or(false),
        "probe version: {probe}"
    );
    println!("mysql version: {}", str_of(&probe, "version"));

    let created = ok(api::connections::create_connection(mysql_body(Some("Live MySQL"), None))).await;
    let id = str_of(&created["connection"], "id");
    ok(api::connections::connect_connection(id.clone())).await;

    // Namespaces come back through the visibility filter.
    let databases = ok(api::explorer::list_databases()).await;
    let names: Vec<String> = databases["databases"]
        .as_array()
        .expect("databases array")
        .iter()
        .filter_map(|d| d.get("name").and_then(|v| v.as_str()).map(|s| s.to_string()))
        .collect();
    println!("mysql databases: {names:?}");
    assert!(!names.is_empty(), "no databases visible");

    // A scratch schema keeps the test independent of pre-existing data.
    let scratch = "rma_desktop_selftest";
    let _ = ok(api::query::run_query(json!({
        "sql": format!("DROP DATABASE IF EXISTS `{scratch}`"),
    })))
    .await;
    ok(api::explorer::create_database(json!({ "name": scratch }), false)).await;

    let ddl = ok(api::query::run_query(json!({
        "sql": format!(
            "CREATE TABLE `{scratch}`.`t` (id INT PRIMARY KEY, name VARCHAR(64));"
        ),
        "database": scratch,
    })))
    .await;
    assert_eq!(ddl.get("failed"), Some(&Value::from(0)), "ddl: {ddl}");

    ok(api::query::run_query(json!({
        "sql": format!("INSERT INTO `{scratch}`.`t` VALUES (1, 'Ada'), (2, 'Bob');"),
        "database": scratch,
    })))
    .await;

    // Structure, pagination and the filter parser all run against MySQL here.
    let structure = ok(api::explorer::table_structure(scratch.into(), "t".into())).await;
    assert_eq!(structure["columns"].as_array().map(|a| a.len()), Some(2));

    let page = ok(api::explorer::table_data(
        scratch.into(),
        "t".into(),
        json!({ "page": 1, "per_page": 10, "sort": "name:desc" }),
    ))
    .await;
    assert_eq!(page["total"], Value::from(2), "page: {page}");
    assert_eq!(page["rows"][0][1], Value::from("Bob"), "sorted: {page}");

    let filtered = ok(api::explorer::table_data(
        scratch.into(),
        "t".into(),
        json!({ "where": "name LIKE 'A%'" }),
    ))
    .await;
    assert_eq!(filtered["total"], Value::from(1), "filtered: {filtered}");

    // The DDL default validator must reject an injected default on MySQL too.
    let injected = api::explorer::create_table(
        scratch.into(),
        json!({
            "name": "evil",
            "columns": [{
                "name": "c",
                "type": "INT",
                "nullable": true,
                "default": "0); DROP TABLE t; --",
                "auto_increment": false,
                "primary": false,
                "comment": null,
                "charset": null,
                "collation": null,
            }],
            "foreign_keys": [],
        }),
        false,
    )
    .await;
    assert!(injected.is_err(), "injected default was accepted by MySQL builder");

    // Export, then drop the scratch schema so the server is left clean.
    let dump = ok(api::export::export_table(
        scratch.into(),
        "t".into(),
        json!({ "format": "sql" }),
    ))
    .await;
    assert!(str_of(&dump, "content").contains("Ada"), "dump: {dump}");

    ok(api::query::run_query(json!({
        "sql": format!("DROP DATABASE `{scratch}`"),
    })))
    .await;

    ok(api::connections::disconnect()).await;
    ok(api::connections::delete_connection(id)).await;
}
