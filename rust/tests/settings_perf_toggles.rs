//! The performance toggles the settings dialog offers, through the FFI surface.
//!
//! `config.rs` unit-tests the serde/sanitize path; this file checks what the
//! Dart side actually sees: `get_settings` must return both keys (so AppState
//! can read them) and an older `settings.json` without them must still load
//! with both switched on.
//!
//! App state is a process-wide `OnceLock`, so everything is one test.

use serde_json::{json, Value};
use std::path::PathBuf;

use rust_myadmin_core::api;

fn temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("rma-settings-{tag}-{}", std::process::id()));
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
async fn performance_toggles_are_visible_to_the_ui() {
    let dir = temp_dir("perf");
    // A settings file written by an older build: no performance keys at all.
    std::fs::write(
        dir.join("settings.json"),
        r#"{"theme":"dark","language":"en","page_size":25}"#,
    )
    .expect("write old settings");

    let init = api::init_app(dir.to_string_lossy().to_string());
    assert_eq!(init.get("ok"), Some(&Value::Bool(true)), "init: {init}");

    // ------------------------------------------- old file -> defaults are on
    let settings = ok(api::get_settings()).await;
    assert_eq!(settings["theme"], json!("dark"), "old keys still load");
    assert_eq!(
        settings["auto_column_width"],
        json!(true),
        "旧 settings.json 的自动列宽必须默认为开: {settings}"
    );
    assert_eq!(
        settings["lazy_big_fields"],
        json!(true),
        "旧 settings.json 的大字段延迟加载必须默认为开: {settings}"
    );

    // ------------------------------------------------- switching them off works
    let saved = ok(api::save_settings(json!({
        "theme": "dark",
        "language": "en",
        "auto_column_width": false,
        "lazy_big_fields": false,
    })))
    .await;
    assert_eq!(saved["auto_column_width"], json!(false), "saved: {saved}");
    assert_eq!(saved["lazy_big_fields"], json!(false), "saved: {saved}");

    // ...and is persisted to disk, so the next launch keeps the choice.
    let on_disk: Value = serde_json::from_str(
        &std::fs::read_to_string(dir.join("settings.json")).expect("settings.json must exist"),
    )
    .expect("settings.json must be valid JSON");
    assert_eq!(on_disk["auto_column_width"], json!(false), "disk: {on_disk}");
    assert_eq!(on_disk["lazy_big_fields"], json!(false), "disk: {on_disk}");

    // The read-back path agrees with what was written.
    let reread = ok(api::get_settings()).await;
    assert_eq!(reread["auto_column_width"], json!(false));
    assert_eq!(reread["lazy_big_fields"], json!(false));

    // Omitting the keys keeps the previously saved values (serde defaults are
    // for a *missing* file field, and save_settings replaces the whole struct,
    // so a partial payload falls back to the defaults rather than crashing).
    let partial = ok(api::save_settings(json!({ "theme": "light" }))).await;
    assert_eq!(partial["auto_column_width"], json!(true), "partial: {partial}");

    let _ = std::fs::remove_dir_all(&dir);
}
