//! Attached SQLite databases.
//!
//! Its own test target on purpose: the Rust core keeps state in a process-wide
//! OnceLock, so each test binary initializes once and tests inside one file
//! cannot each have their own data directory.

use serde_json::{json, Value};
use std::path::PathBuf;

use rust_myadmin_core::api;

fn temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("rma-attach-{}-{}", tag, std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("create temp dir");
    dir
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

/// Every other database file in the connection folder is ATTACHed, so one
/// connection browses a whole folder. Their tables have to be reachable, not
/// merely listed.
#[tokio::test]
async fn sqlite_attached_databases_are_browsable() {
    let dir = temp_dir("attach");
    let main = dir.join("main.sqlite");
    // A space in the file name on purpose: the alias has to be sanitised while
    // the ATTACH statement still points at the real path.
    let second = dir.join("second db.sqlite");
    std::fs::write(&main, b"").expect("write main");
    std::fs::write(&second, b"").expect("write second");

    let init = api::init_app(dir.to_string_lossy().to_string());
    assert_eq!(init.get("ok"), Some(&Value::Bool(true)), "init: {init}");

    let created = ok(api::connections::create_connection(json!({
        "name": "Attach probe",
        "driver": "sqlite",
        "database": main.to_string_lossy(),
        "sqlite_dir": dir.to_string_lossy(),
    })))
    .await;
    let id = str_of(&created["connection"], "id");
    ok(api::connections::connect_connection(id)).await;

    // Create the table inside the *attached* schema; if the ATTACH did not run
    // this fails with "no such database".
    let created_table = ok(api::query::run_query(json!({
        "sql": "CREATE TABLE second_db.items (id INTEGER PRIMARY KEY, note TEXT);"
    })))
    .await;
    let failed = created_table["failed"].as_i64().unwrap_or(-1);
    assert_eq!(failed, 0, "attached DDL failed: {created_table}");

    let dbs = ok(api::explorer::list_databases()).await;
    let names: Vec<String> = dbs["databases"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| str_of(d, "name"))
        .collect();
    assert!(names.iter().any(|n| n == "main"), "main missing: {names:?}");
    assert!(
        names.iter().any(|n| n == "second_db"),
        "attached alias missing: {names:?}"
    );

    // The attached schema must be browsable, not merely listed.
    let tables = ok(api::explorer::list_tables("second_db".to_string())).await;
    let table_names: Vec<String> = tables["tables"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| str_of(t, "name"))
        .collect();
    assert!(
        table_names.iter().any(|n| n == "items"),
        "attached table missing: {table_names:?}"
    );

    // Same-named files in different folders must not share an alias.
    let a = rust_myadmin_core::drivers::sqlite::alias_for("/a/x.sqlite", 0);
    let b = rust_myadmin_core::drivers::sqlite::alias_for("/b/x.sqlite", 1);
    assert_ne!(a, b, "alias sanitation must keep same-named files apart");
}
