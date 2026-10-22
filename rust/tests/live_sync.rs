//! Live structure-sync checks against a real MySQL / PostgreSQL server.
//!
//! Both are ignored by default because they need real servers. They exist
//! because sync is the feature that was easiest to get subtly wrong: a missing
//! table used to be recreated without indexes, comments or quoted enum
//! defaults, and "compare again" is the only honest way to prove the generated
//! DDL is complete.
//!
//!   cargo test --test live_sync -- --ignored --nocapture

use serde_json::{json, Value};

use rust_myadmin_core::api;

mod common;

async fn ok<T>(future: impl std::future::Future<Output = anyhow::Result<T>>) -> T {
    match future.await {
        Ok(value) => value,
        Err(e) => panic!("unexpected error: {e}"),
    }
}

fn init() {
    let dir = std::env::temp_dir().join(format!("rma-live-sync-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    let result = api::init_app(dir.to_string_lossy().to_string());
    assert_eq!(result.get("ok"), Some(&Value::Bool(true)), "init: {result}");
}

fn str_of(value: &Value, key: &str) -> String {
    value.get(key).and_then(|v| v.as_str()).unwrap_or("").to_string()
}

async fn connect(body: Value) -> String {
    let created = ok(api::connections::create_connection(body)).await;
    let id = str_of(&created["connection"], "id");
    assert!(!id.is_empty(), "connection not created: {created}");
    let active = ok(api::connections::connect_connection(id.clone())).await;
    assert_eq!(active.get("connection").and_then(|c| c.get("driver")).is_some(), true);
    id
}

async fn diff(source: &str, target: &str, allow_drop: bool) -> Value {
    ok(api::sync::schema_diff(json!({
        "source": source,
        "target": target,
        "allow_drop": allow_drop,
        "dry_run": true,
    })))
    .await
}

async fn sync(source: &str, target: &str) -> Value {
    ok(api::sync::schema_sync(json!({
        "source": source,
        "target": target,
        "allow_drop": false,
        "dry_run": false,
    })))
    .await
}

/// MySQL: rebuild the demo database into a scratch schema, then compare again.
#[tokio::test]
#[ignore = "requires MySQL; endpoint from DBPILOT_TEST_MYSQL_* (see tests/common/mod.rs)"]
async fn mysql_sync_round_trip() {
    init();
    let scratch = "rma_sync_selftest";

    let endpoint = common::mysql();
    connect(json!({
        "name": "Live sync MySQL",
        "driver": "mysql",
        "host": endpoint.host,
        "port": endpoint.port,
        "user": endpoint.user,
        "password": endpoint.password,
    }))
    .await;

    // DDL needs an active connection on the Rust side.
    let _ = ok(api::query::run_query(json!({
        "sql": format!("DROP DATABASE IF EXISTS `{scratch}`"),
    })))
    .await;
    ok(api::explorer::create_database(json!({ "name": scratch }), false)).await;

    let before = diff("rustmyadmin_demo", scratch, false).await;
    assert!(
        before.get("changed").and_then(|v| v.as_i64()).unwrap_or(0) > 5,
        "expected missing tables: {before}"
    );

    let applied = sync("rustmyadmin_demo", scratch).await;
    assert_eq!(applied.get("failed"), Some(&Value::from(0)), "sync failed: {applied}");

    let after = diff("rustmyadmin_demo", scratch, false).await;
    assert_eq!(
        after.get("changed"),
        Some(&Value::from(0)),
        "second compare should be clean: {after}"
    );

    // The enum default used to be emitted unquoted (DEFAULT Engineering), so a
    // successful CREATE with this column proves the quoting fix.
    let rows = ok(api::query::run_query(json!({
        "sql": format!(
            "SELECT COLUMN_DEFAULT, COLUMN_TYPE FROM information_schema.COLUMNS              WHERE TABLE_SCHEMA = '{}' AND TABLE_NAME = 'employees' AND COLUMN_NAME = 'department'",
            scratch
        ),
    })))
    .await;
    // run_query returns { results: [ { rows: [[...]] } ] }, and the enum
    // default arrives as the first cell of the first row.
    let cell = rows["results"][0]["rows"][0][0].as_str().unwrap_or("");
    assert!(
        cell.to_ascii_lowercase().contains("engineering"),
        "enum default not recreated: {rows}"
    );

    let _ = ok(api::query::run_query(json!({
        "sql": format!("DROP DATABASE IF EXISTS `{scratch}`"),
    })))
    .await;
}


/// PostgreSQL: diff/sync two schemas that live in different databases.
///
/// This exercises the cross-database path: source metadata comes from database
/// A's pool, target metadata/DDL from database B's pool, and the generated SQL
/// executes on B. Also checks that target-only tables are reported instead of
/// being silently ignored.
#[tokio::test]
#[ignore = "requires PostgreSQL; endpoint from DBPILOT_TEST_PG_* (see tests/common/mod.rs)"]
async fn postgres_cross_database_sync() {
    init();
    let target_db = "rma_crossdb_selftest";
    let endpoint = common::postgres();
    connect(json!({
        "name": "Live cross database",
        "driver": "postgres",
        "host": endpoint.host,
        "port": endpoint.port,
        "user": endpoint.user,
        "password": endpoint.password,
        "database": "rustmyadmin_demo",
        "ssl_mode": "disable",
    }))
    .await;

    // Remove a previous run and recreate the target database (it has public).
    let _ = api::explorer::drop_database(target_db.into()).await;
    ok(api::explorer::create_database(json!({ "name": target_db }), false)).await;

    let body = json!({
        "source": "public",
        "target": "public",
        "source_database": "rustmyadmin_demo",
        "target_database": target_db,
        "allow_drop": false,
        "dry_run": true,
    });
    let before = ok(api::sync::schema_diff(body.clone())).await;
    assert!(
        before.get("changed").and_then(|v| v.as_i64()).unwrap_or(0) > 0,
        "expected missing tables: {before}"
    );
    assert_eq!(before["source_database"], "rustmyadmin_demo");
    assert_eq!(before["target_database"], target_db);

    let applied = ok(api::sync::schema_sync(json!({
        "source": "public",
        "target": "public",
        "source_database": "rustmyadmin_demo",
        "target_database": target_db,
        "allow_drop": false,
        "dry_run": false,
    })))
    .await;
    assert_eq!(applied.get("failed"), Some(&Value::from(0)), "sync failed: {applied}");

    let after = ok(api::sync::schema_diff(body)).await;
    assert_eq!(after.get("changed"), Some(&Value::from(0)), "second compare: {after}");

    // Switch to the target database and prove the table landed there.
    ok(api::explorer::select_database(target_db.into())).await;
    let structure = ok(api::explorer::table_structure("public".into(), "people".into())).await;
    assert_eq!(structure["columns"].as_array().map(|a| a.len()), Some(4));

    // A table only in the target must be reported as target_only, not dropped.
    ok(api::query::run_query(json!({
        "sql": "CREATE TABLE public.target_only_marker (id int PRIMARY KEY)",
    })))
    .await;
    let reverse = ok(api::sync::schema_diff(json!({
        "source": "public",
        "target": "public",
        "source_database": "rustmyadmin_demo",
        "target_database": target_db,
        "allow_drop": true,
        "dry_run": true,
    })))
    .await;
    let marker = reverse["tables"]
        .as_array()
        .and_then(|tables| {
            tables.iter().find(|t| t.get("name") == Some(&Value::from("target_only_marker")))
        })
        .cloned()
        .unwrap_or(Value::Null);
    assert_eq!(marker["status"], "target_only", "reverse: {reverse}");
    assert!(marker["statements"].as_array().map(|a| a.is_empty()).unwrap_or(false));

    // Clean up: switch back to the source database before dropping the target.
    ok(api::explorer::select_database("rustmyadmin_demo".into())).await;
    ok(api::explorer::drop_database(target_db.into())).await;
    // Free every cached pool/connection: these live tests share one process, and
    // the next test should not inherit half-open PostgreSQL sessions.
    ok(api::connections::disconnect()).await;
}

/// PostgreSQL: rebuild public into a fresh schema, including comments, indexes
/// and the identity column, then compare again.
#[tokio::test]
#[ignore = "requires PostgreSQL; endpoint from DBPILOT_TEST_PG_* (see tests/common/mod.rs)"]
async fn postgres_sync_round_trip() {
    init();
    let endpoint = common::postgres();
    connect(json!({
        "name": "Live sync PostgreSQL",
        "driver": "postgres",
        "host": endpoint.host,
        "port": endpoint.port,
        "user": endpoint.user,
        "password": endpoint.password,
        "database": "rustmyadmin_demo",
        "ssl_mode": "disable",
    }))
    .await;

    let _ = ok(api::query::run_query(json!({
        "sql": "DROP SCHEMA IF EXISTS rma_sync_selftest CASCADE;",
    })))
    .await;
    let _ = ok(api::query::run_query(json!({
        "sql": "CREATE SCHEMA rma_sync_selftest;",
    })))
    .await;

    let before = diff("public", "rma_sync_selftest", false).await;
    assert!(
        before.get("changed").and_then(|v| v.as_i64()).unwrap_or(0) > 0,
        "expected missing tables: {before}"
    );

    let applied = sync("public", "rma_sync_selftest").await;
    assert_eq!(applied.get("failed"), Some(&Value::from(0)), "sync failed: {applied}");

    let after = diff("public", "rma_sync_selftest", false).await;
    assert_eq!(
        after.get("changed"),
        Some(&Value::from(0)),
        "second compare should be clean: {after}"
    );

    let structure = ok(api::explorer::table_structure(
        "rma_sync_selftest".to_string(),
        "people".to_string(),
    ))
    .await;
    let columns = structure["columns"].as_array().cloned().unwrap_or_default();
    assert_eq!(columns.len(), 4, "people columns: {structure}");

    // Identity is not a DEFAULT: information_schema reports it via is_identity.
    let identity = ok(api::query::run_query(json!({
        "sql": "SELECT is_identity FROM information_schema.columns \
                WHERE table_schema = 'rma_sync_selftest' AND table_name = 'people' AND column_name = 'id';",
    })))
    .await;
    assert_eq!(
        identity["results"][0]["rows"][0][0].as_str(),
        Some("YES"),
        "identity not recreated: {identity}"
    );

    let indexes = ok(api::query::run_query(json!({
        "sql": "SELECT indexname FROM pg_indexes \
                WHERE schemaname = 'rma_sync_selftest' AND tablename = 'people' AND indexname = 'people_name_idx';",
    })))
    .await;
    assert_eq!(
        indexes["results"][0]["rows"][0][0].as_str(),
        Some("people_name_idx"),
        "secondary index not recreated: {indexes}"
    );

    let comments = ok(api::query::run_query(json!({
        "sql": "SELECT col_description('rma_sync_selftest.people'::regclass, 2) AS c;",
    })))
    .await;
    let comment = comments["results"][0]["rows"][0][0].as_str().unwrap_or("");
    assert_eq!(comment, "姓名", "column comment not recreated: {comments}");

    let _ = ok(api::query::run_query(json!({
        "sql": "DROP SCHEMA rma_sync_selftest CASCADE;",
    })))
    .await;
}
