//! SQLite folder discovery: list / group / create / import / delete.
//!
//! Its own test target because the core keeps its state in a process-wide
//! OnceLock, so each test binary gets one initialization.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};

use rust_myadmin_core::api;

fn temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("rma-disc-{}-{}", tag, std::process::id()));
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

fn paths(value: &Value, key: &str) -> Vec<String> {
    value
        .get(key)
        .and_then(|v| v.as_array())
        .map(|items| items.iter().map(|i| str_of(i, "path")).collect::<Vec<_>>())
        .unwrap_or_default()
}

/// Write a valid SQLite database file.
///
/// An empty file is what SQLite expects for a brand-new database; a hand-built
/// header page is rejected by ATTACH as "database disk image is malformed", so
/// the fixture is left empty exactly like the app creates it.
fn make_db(path: &Path) {
    std::fs::write(path, b"").expect("write db");
}

#[tokio::test]
async fn sqlite_folder_discovery_flow() {
    let dir = temp_dir("flow");
    let main = dir.join("main.sqlite");
    make_db(&main);

    let init = api::init_app(dir.to_string_lossy().to_string());
    assert_eq!(init.get("ok"), Some(&Value::Bool(true)), "init: {init}");

    let created = ok(api::connections::create_connection(json!({
        "name": "Discovery",
        "driver": "sqlite",
        "database": main.to_string_lossy(),
        "sqlite_dir": dir.to_string_lossy(),
    })))
    .await;
    let id = str_of(&created["connection"], "id");
    ok(api::connections::connect_connection(id)).await;

    // Only the primary file is listed at first, in one directory group.
    let listed = ok(api::sqlite::sqlite_databases(false)).await;
    assert_eq!(paths(&listed, "databases").len(), 1, "listed: {listed}");
    assert_eq!(paths(&listed, "databases")[0], main.to_string_lossy());
    assert!(listed["primary_exists"].as_bool().unwrap_or(false));
    assert_eq!(
        listed["groups"].as_array().map(|g| g.len()).unwrap_or(0),
        1,
        "listed: {listed}"
    );

    // A file copied into the folder shows up on refresh — nothing is recorded,
    // the folder is the state.
    let extra = dir.join("extra.sqlite");
    make_db(&extra);
    let listed = ok(api::sqlite::sqlite_databases(true)).await;
    assert_eq!(paths(&listed, "databases").len(), 2, "listed: {listed}");

    // A database in a subfolder becomes a second directory group.
    let sub = dir.join("reports");
    std::fs::create_dir_all(&sub).expect("mkdir");
    make_db(&sub.join("q3.sqlite"));
    let listed = ok(api::sqlite::sqlite_databases(true)).await;
    assert_eq!(paths(&listed, "databases").len(), 3, "listed: {listed}");
    assert_eq!(
        listed["groups"].as_array().map(|g| g.len()).unwrap_or(0),
        2,
        "listed: {listed}"
    );

    // A corrupt file in the folder is reported, not listed.
    std::fs::write(dir.join("broken.sqlite"), b"not a database").expect("write broken");
    let listed = ok(api::sqlite::sqlite_databases(true)).await;
    assert_eq!(paths(&listed, "databases").len(), 3, "listed: {listed}");
    assert_eq!(paths(&listed, "unreadable"), vec![dir.join("broken.sqlite").to_string_lossy()]);

    // Creating a database writes a real file into a chosen folder and registers
    // it as a connection.
    let made = ok(api::sqlite::sqlite_create_database(json!({
        "dir": sub.to_string_lossy(),
        "name": "made",
        "content": "CREATE TABLE t (id INTEGER PRIMARY KEY);",
    })))
    .await;
    let made_path = str_of(&made, "path");
    assert!(made_path.ends_with("made.sqlite"), "created: {made}");
    assert!(Path::new(&made_path).exists(), "file not created: {made_path}");
    // The starter script really ran.
    let tables = ok(api::explorer::list_tables("main".to_string())).await;
    let names: Vec<String> = tables["tables"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| str_of(t, "name"))
        .collect();
    assert!(names.iter().any(|n| n == "t"), "starter script missing: {names:?}");

    // A name that already exists is refused instead of overwriting.
    let duplicate = api::sqlite::sqlite_create_database(json!({
        "dir": sub.to_string_lossy(),
        "name": "made",
    }))
    .await;
    assert!(duplicate.is_err(), "duplicate create must fail");

    // A folder that does not exist is a clear error, not a silent no-op.
    let missing = api::sqlite::sqlite_create_database(json!({
        "dir": dir.join("nope").to_string_lossy(),
        "name": "x",
    }))
    .await;
    assert!(missing.is_err(), "missing folder must fail");

    // Importing a folder registers it as a connection.
    let imported = ok(api::sqlite::sqlite_import(json!({
        "paths": [dir.to_string_lossy()],
        "connect": true,
    })))
    .await;
    assert_eq!(
        imported["created"].as_array().map(|c| c.len()).unwrap_or(0),
        1,
        "imported: {imported}"
    );

    // Deleting removes the file from disk; the list follows the disk.
    let before = ok(api::sqlite::sqlite_databases(false)).await;
    assert!(paths(&before, "databases").iter().any(|p| p == &made_path), "listed: {before}");
    ok(api::sqlite::sqlite_delete_file(json!({ "paths": [made_path.clone()] }))).await;
    assert!(!Path::new(&made_path).exists(), "file not deleted: {made_path}");
    let after = ok(api::sqlite::sqlite_databases(false)).await;
    assert!(
        !paths(&after, "databases").iter().any(|p| p == &made_path),
        "deleted database still listed: {after}"
    );

    // The primary file of the *current* connection cannot be deleted through
    // this path (the import above made extra.sqlite the primary one).
    let current = ok(api::sqlite::sqlite_databases(false)).await;
    let current_primary = str_of(&current, "primary");
    assert_eq!(current_primary, extra.to_string_lossy(), "active: {current}");
    let refuse = api::sqlite::sqlite_delete_file(json!({
        "paths": [current_primary],
    }))
    .await;
    assert!(refuse.is_err(), "primary database must not be deletable");
    assert!(extra.exists(), "primary file was removed");

    let _ = api::connections::disconnect().await;
}
