//! How many database files one SQLite connection can actually ATTACH.
//!
//! SQLite documents SQLITE_MAX_ATTACHED (10 by default), but the bundled build
//! may differ; the app caps the attach list with [MAX_ATTACHED], so the cap has
//! to match what the engine accepts.

use serde_json::{json, Value};
use std::path::PathBuf;

use rust_myadmin_core::api;

fn temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("rma-attachlimit-{}-{}", tag, std::process::id()));
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

#[tokio::test]
async fn attach_cap_matches_the_engine() {
    let dir = temp_dir("cap");
    let main = dir.join("main.sqlite");
    std::fs::write(&main, b"").expect("main");
    for i in 0..14 {
        std::fs::write(dir.join(format!("f{i}.sqlite")), b"").expect("extra");
    }
    let init = api::init_app(dir.to_string_lossy().to_string());
    assert_eq!(init.get("ok"), Some(&Value::Bool(true)));

    let created = ok(api::connections::create_connection(json!({
        "name": "cap",
        "driver": "sqlite",
        "database": main.to_string_lossy(),
        "sqlite_dir": dir.to_string_lossy(),
    })))
    .await;
    let id = created["connection"]["id"].as_str().unwrap_or("").to_string();
    ok(api::connections::connect_connection(id)).await;

    let listed = ok(api::sqlite::sqlite_databases(false)).await;
    let attached = listed["databases"].as_array().map(|a| a.len()).unwrap_or(0);
    let unreadable = listed["unreadable"].as_array().map(|a| a.len()).unwrap_or(0);
    println!("ATTACHED={attached} UNOPENED={unreadable} LIMIT={}", listed["attach_limit"]);
    // 15 files, one of which is the primary: the engine must accept every file
    // the cap allows, and the leftovers must be reported, not dropped.
    assert!(attached >= 10, "engine attached only {attached} databases");
    assert!(unreadable >= 1, "leftover files were not reported");
}
