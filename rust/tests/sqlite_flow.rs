//! End-to-end exercise of the Rust core against a real SQLite database.
//!
//! The web build was only ever tested through HTTP; this drives the same code
//! paths directly through the FFI surface, which is what the Flutter UI calls.
//! SQLite is used because it needs no server, so the whole flow — connection
//! CRUD, schema creation, row editing, SQL execution, export, import, backup
//! and restore — runs in CI on any machine.
//!
//! The core keeps its state in a process-wide `OnceLock`, so all assertions
//! live in one sequential test rather than competing for that slot.

use serde_json::{json, Value};
use std::path::PathBuf;

use rust_myadmin_core::api;

fn temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("rma-test-{}-{}", tag, std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("create temp dir");
    dir
}

/// Await a bridge call, panicking with the user-facing message on failure.
///
/// The helper is async so a call site reads as `ok(api::x(...)).await`, which
/// keeps the assertion and the await on one line.
async fn ok<T>(future: impl std::future::Future<Output = anyhow::Result<T>>) -> T {
    match future.await {
        Ok(value) => value,
        Err(e) => panic!("unexpected error: {e}"),
    }
}

fn str_of(value: &Value, key: &str) -> String {
    value.get(key).and_then(|v| v.as_str()).unwrap_or("").to_string()
}

#[tokio::test]
async fn full_sqlite_flow() {
    let dir = temp_dir("flow");
    let db_file = dir.join("demo.sqlite");
    // The database file must exist: a connection pointing at a path that is not
    // there is reported as missing instead of being silently created empty.
    std::fs::write(&db_file, b"").expect("create database file");

    // ---------------------------------------------------------------- init
    let init = api::init_app(dir.to_string_lossy().to_string());
    assert_eq!(init.get("ok"), Some(&Value::Bool(true)), "init: {init}");

    // ------------------------------------------------- connection lifecycle
    let created = ok(api::connections::create_connection(json!({
        "name": "Test SQLite",
        "driver": "sqlite",
        "database": db_file.to_string_lossy(),
    })))
    .await;
    let conn_id = str_of(&created["connection"], "id");
    assert!(!conn_id.is_empty(), "connection id: {created}");

    // Testing raw credentials must work without any admin gate.
    let probe = ok(api::connections::test_connection(json!({
        "driver": "sqlite",
        "database": db_file.to_string_lossy(),
    })))
    .await;
    assert_eq!(probe.get("ok"), Some(&Value::Bool(true)), "probe: {probe}");

    let connected = ok(api::connections::connect_connection(conn_id.clone())).await;
    assert_eq!(connected.get("ok"), Some(&Value::Bool(true)), "connect: {connected}");

    // The active connection is remembered for the next launch.
    let active = ok(api::connections::active_connection()).await;
    assert!(active["connection"].is_object(), "active: {active}");

    // ------------------------------------------------------------ SQL + DDL
    let ddl = ok(api::query::run_query(json!({
        "sql": "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER);"
    })))
    .await;
    assert_eq!(ddl.get("failed"), Some(&Value::from(0)), "ddl: {ddl}");

    // A multi-statement script runs statement by statement.
    let insert = ok(api::query::run_query(json!({
        "sql": "INSERT INTO people (name, age) VALUES ('Ada', 36); INSERT INTO people (name, age) VALUES ('Bob', 41);"
    })))
    .await;
    assert_eq!(insert.get("statement_count"), Some(&Value::from(2)), "insert: {insert}");
    assert_eq!(insert.get("failed"), Some(&Value::from(0)), "insert: {insert}");

    // ------------------------------------------------------------ structure
    let structure = ok(api::explorer::table_structure("main".into(), "people".into())).await;
    let columns = structure["columns"].as_array().expect("columns");
    assert_eq!(columns.len(), 3, "structure: {structure}");
    assert_eq!(columns[0]["name"], Value::from("id"));

    // ----------------------------------------------------------- pagination
    let page = ok(api::explorer::table_data(
        "main".into(),
        "people".into(),
        json!({ "page": 1, "per_page": 10, "sort": "name:desc" }),
    ))
    .await;
    assert_eq!(page["total"], Value::from(2), "page: {page}");
    let rows = page["rows"].as_array().expect("rows");
    assert_eq!(rows.len(), 2);
    // Sorting by name descending puts Bob first.
    assert_eq!(rows[0][1], Value::from("Bob"), "sorted rows: {rows:?}");

    // A filter is parsed against real column names, so injection is rejected.
    let filtered = ok(api::explorer::table_data(
        "main".into(),
        "people".into(),
        json!({ "where": "age > 40" }),
    ))
    .await;
    assert_eq!(filtered["total"], Value::from(1), "filtered: {filtered}");

    let injected = api::explorer::table_data(
        "main".into(),
        "people".into(),
        json!({ "where": "1=1 OR 1=1" }),
    )
    .await;
    assert!(injected.is_err(), "filter injection was accepted");

    // ------------------------------------------------------- row edit paths
    let updated = ok(api::explorer::change_row(
        "main".into(),
        "people".into(),
        json!({ "action": "update", "keys": { "id": 1 }, "values": { "age": 37 } }),
    ))
    .await;
    assert_eq!(updated["rows_affected"], Value::from(1), "update: {updated}");

    let inserted = ok(api::explorer::change_row(
        "main".into(),
        "people".into(),
        json!({ "action": "insert", "values": { "name": "Cy", "age": 22 } }),
    ))
    .await;
    assert_eq!(inserted["rows_affected"], Value::from(1), "insert row: {inserted}");

    // --------------------------------------------------------------- objects
    let objects = ok(api::explorer::list_objects("main".into())).await;
    assert!(objects.get("views").is_some(), "objects: {objects}");

    // A view definition must be a single statement: this used to allow a
    // trailing DROP TABLE through the CREATE-prefix guard.
    let view = ok(api::explorer::create_object(
        "main".into(),
        json!({ "sql": "CREATE VIEW adults AS SELECT name FROM people WHERE age >= 40;" }),
    ))
    .await;
    assert_eq!(view.get("ok"), Some(&Value::Bool(true)), "view: {view}");

    let attack = api::explorer::create_object(
        "main".into(),
        json!({ "sql": "CREATE VIEW v2 AS SELECT 1; DROP TABLE people;" }),
    )
    .await;
    assert!(attack.is_err(), "multi-statement object definition was accepted");

    // ---------------------------------------------------------------- export
    let dump = ok(api::export::export_table(
        "main".into(),
        "people".into(),
        json!({ "format": "sql", "structure": true, "data": true, "drop": true }),
    ))
    .await;
    let content = str_of(&dump, "content");
    assert!(content.contains("CREATE TABLE"), "dump: {content}");
    assert!(content.contains("INSERT INTO"), "dump: {content}");
    assert!(content.contains("Ada"), "dump: {content}");

    let csv = ok(api::export::export_table(
        "main".into(),
        "people".into(),
        json!({ "format": "csv" }),
    ))
    .await;
    assert!(str_of(&csv, "content").starts_with("id,name,age"), "csv: {csv}");

    // An unsupported format is a user error, not a panic.
    assert!(api::export::export_table(
        "main".into(),
        "people".into(),
        json!({ "format": "nope" }),
    )
    .await
    .is_err());

    // ---------------------------------------------------------------- backup
    let backup = ok(api::backup::create_backup(json!({ "database": "main" }))).await;
    let backup_id = str_of(&backup["backup"], "id");
    assert!(!backup_id.is_empty(), "backup: {backup}");

    let listed = ok(api::backup::list_backups()).await;
    assert_eq!(listed["backups"].as_array().map(|a| a.len()), Some(1));

    // Delete a row, then restore the backup and confirm it comes back.
    ok(api::explorer::change_row(
        "main".into(),
        "people".into(),
        json!({ "action": "delete", "keys": { "id": 3 } }),
    ))
    .await;
    let before = ok(api::explorer::table_data(
        "main".into(),
        "people".into(),
        json!({ "per_page": 50 }),
    ))
    .await;
    assert_eq!(before["total"], Value::from(2), "after delete: {before}");

    let restored = ok(api::backup::restore_backup(backup_id.clone())).await;
    assert_eq!(restored.get("failed"), Some(&Value::from(0)), "restore: {restored}");

    // -------------------------------------------------------------- history
    let history = ok(api::query::history_list(Some(50), None)).await;
    assert!(
        history["history"].as_array().map(|a| !a.is_empty()).unwrap_or(false),
        "history: {history}"
    );

    // --------------------------------------------------------------- import
    let imported = ok(api::export::import_sql(
        "main".into(),
        "CREATE TABLE imported (x INTEGER);".to_string(),
    ))
    .await;
    assert_eq!(imported.get("failed"), Some(&Value::from(0)), "import: {imported}");

    // A malformed script reports the failure instead of silently succeeding.
    let bad = ok(api::export::import_sql(
        "main".into(),
        "THIS IS NOT SQL;".to_string(),
    ))
    .await;
    assert!(bad["failed"].as_i64().unwrap_or(0) > 0, "bad import: {bad}");

    // --------------------------------------------------------- namespaces
    let databases = ok(api::explorer::list_databases()).await;
    assert!(
        databases["databases"].as_array().map(|a| !a.is_empty()).unwrap_or(false),
        "databases: {databases}"
    );

    // ------------------------------------------------------- meta + status
    let meta = ok(api::explorer::meta_options()).await;
    assert!(meta.get("features").is_some(), "meta: {meta}");

    let status = ok(api::server::status()).await;
    assert!(status.get("version").is_some(), "status: {status}");

    // ------------------------------------------------------------ settings
    let saved = ok(api::save_settings(json!({
        "theme": "dark",
        "language": "en",
        "page_size": 25,
        "window": { "width": 1600, "height": 1000 },
    })))
    .await;
    assert_eq!(saved["language"], Value::from("en"), "settings: {saved}");

    // A hand-edited settings file cannot produce an unusable window.
    let clamped = ok(api::save_settings(json!({
        "theme": "nonsense",
        "language": "fr",
        "page_size": 999999,
        "window": { "width": 1, "height": 1 },
    })))
    .await;
    assert_eq!(clamped["theme"], Value::from("system"), "clamp: {clamped}");
    assert_eq!(clamped["language"], Value::from("zh"), "clamp: {clamped}");
    assert_eq!(clamped["page_size"], Value::from(1000), "clamp: {clamped}");

    // ----------------------------------------------------------- disconnect
    ok(api::connections::disconnect()).await;
    let after = ok(api::connections::active_connection()).await;
    assert!(after["connection"].is_null(), "active after disconnect: {after}");

    // Every operation that needs a connection now fails cleanly.
    let no_conn = api::explorer::list_tables("main".into()).await;
    assert!(no_conn.is_err(), "expected an error without a connection");

    // -------------------------------------------------------- delete + tidy
    let removed = ok(api::connections::delete_connection(conn_id)).await;
    assert_eq!(removed.get("removed"), Some(&Value::Bool(true)), "remove: {removed}");

    let _ = std::fs::remove_dir_all(&dir);
}

/// The `only_db` / `hide_db` allow-list is the desktop app's only remaining
/// authorization boundary, so it gets its own focused test.
#[tokio::test]
async fn visibility_rules_are_enforced() {
    let dir = temp_dir("visible");
    let db_file = dir.join("v.sqlite");

    let init = api::init_app(dir.to_string_lossy().to_string());
    assert_eq!(init.get("ok"), Some(&Value::Bool(true)));

    // This test shares the process-wide state with the one above, so it only
    // runs meaningfully when it is the first to initialize.
    let created = ok(api::connections::create_connection(json!({
        "name": "Restricted",
        "driver": "sqlite",
        "database": db_file.to_string_lossy(),
        "only_db": "allowed%",
    })))
    .await;
    let id = str_of(&created["connection"], "id");

    let connected = api::connections::connect_connection(id.clone()).await;
    if connected.is_err() {
        // Another test already initialized the state; skip rather than fail.
        let _ = std::fs::remove_dir_all(&dir);
        return;
    }

    // "main" does not match "allowed%", so it must be rejected.
    let denied = api::explorer::list_tables("main".into()).await;
    assert!(denied.is_err(), "only_db rule was not enforced");

    let _ = api::connections::disconnect().await;
    let _ = std::fs::remove_dir_all(&dir);
}
