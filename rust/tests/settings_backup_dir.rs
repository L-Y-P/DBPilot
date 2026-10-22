//! Settings-driven backup directory, exercised through the FFI surface.
//!
//! The app state lives in a process-wide `OnceLock`, so this file contains a
//! single test: the point is that one settings save redirects the backup store,
//! and a second `init_app` in the same process would be ignored anyway.

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
async fn settings_drive_app_config_and_the_backup_directory() {
    let dir = temp_dir("backupdir");
    let custom = dir.join("dumps");

    let init = api::init_app(dir.to_string_lossy().to_string());
    assert_eq!(init.get("ok"), Some(&Value::Bool(true)), "init: {init}");

    // -------------------------------------------------------------- defaults
    let config = api::app_config().expect("app_config");
    assert_eq!(config["title"], Value::from("DBPilot"));
    assert_eq!(config["theme"], Value::from("system"));
    assert_eq!(config["theme_color"], Value::from("default"));
    assert_eq!(config["language"], Value::from("zh"));
    assert_eq!(config["update_url"], Value::from(""));
    let default_backup_dir = dir.join("backups");
    assert_eq!(
        config["backup_dir"],
        Value::from(default_backup_dir.to_string_lossy().to_string()),
        "app_config: {config}"
    );

    // A custom directory holds an existing backup: its index is what the store
    // must load once the setting changes.
    std::fs::create_dir_all(&custom).expect("create dump dir");
    let file = "20240101-000000-sqlite-main.sql";
    std::fs::write(custom.join(file), "-- dump\nSELECT 1;").expect("write dump");
    let id = "bk-settings-test";
    std::fs::write(
        custom.join("index.json"),
        json!([{
            "id": id,
            "file": file,
            "driver": "sqlite",
            "database": "main",
            "created_at": "2024-01-01T00:00:00+00:00",
            "size": 18
        }])
        .to_string(),
    )
    .expect("write index");

    // Nothing is listed while the default (empty) directory is in force.
    let before = ok(api::backup::list_backups()).await;
    assert_eq!(
        before["backups"].as_array().map(Vec::len),
        Some(0),
        "before: {before}"
    );

    // --------------------------------------------------------- save settings
    let saved = ok(api::save_settings(json!({
        "theme": "dark",
        "theme_color": "teal",
        "language": "en",
        "page_size": 25,
        "backup_dir": custom.to_string_lossy(),
        "update_url": "https://example.com/dbpilot/latest.json",
        "window": { "width": 1600, "height": 1000 },
    })))
    .await;
    assert_eq!(saved["theme_color"], Value::from("teal"), "saved: {saved}");
    assert_eq!(
        saved["backup_dir"],
        Value::from(custom.to_string_lossy().to_string()),
        "saved: {saved}"
    );

    // The effective directory is reported everywhere the UI reads it...
    let config = api::app_config().expect("app_config after save");
    assert_eq!(
        config["backup_dir"],
        Value::from(custom.to_string_lossy().to_string()),
        "config: {config}"
    );
    assert_eq!(config["theme"], Value::from("dark"));
    assert_eq!(config["theme_color"], Value::from("teal"));
    assert_eq!(config["language"], Value::from("en"));
    assert_eq!(
        config["update_url"],
        Value::from("https://example.com/dbpilot/latest.json")
    );

    let files = api::files::data_dir().expect("data_dir");
    assert_eq!(
        files["backup_dir"],
        Value::from(custom.to_string_lossy().to_string()),
        "files: {files}"
    );

    // ...and the store reloaded that directory's index.
    let after = ok(api::backup::list_backups()).await;
    let listed = after["backups"].as_array().cloned().unwrap_or_default();
    assert_eq!(listed.len(), 1, "after: {after}");
    assert_eq!(listed[0]["id"], Value::from(id));

    // Reading goes through the same current directory.
    let read = ok(api::backup::read_backup(id.to_string())).await;
    assert_eq!(read["content"], Value::from("-- dump\nSELECT 1;"));

    let path = ok(api::files::backup_path(id.to_string())).await;
    assert_eq!(
        path["path"],
        Value::from(custom.join(file).to_string_lossy().to_string()),
        "backup_path: {path}"
    );

    // ------------------------------------------------ invalid values dropped
    let clamped = ok(api::save_settings(json!({
        "theme": "dark",
        "theme_color": "neon",
        "language": "en",
        "backup_dir": "relative/dumps",
        "update_url": "ftp://example.com/latest.json",
    })))
    .await;
    assert_eq!(clamped["backup_dir"], Value::Null, "clamp: {clamped}");
    assert_eq!(
        clamped["theme_color"],
        Value::from("default"),
        "clamp: {clamped}"
    );
    assert_eq!(clamped["update_url"], Value::from(""), "clamp: {clamped}");
    // Rejecting the directory falls back to the default one, so the store is
    // switched back and the custom directory's backup is no longer listed...
    assert_eq!(
        api::app_config().expect("app_config")["backup_dir"],
        Value::from(default_backup_dir.to_string_lossy().to_string())
    );
    let after_clamp = ok(api::backup::list_backups()).await;
    assert_eq!(
        after_clamp["backups"].as_array().map(Vec::len),
        Some(0),
        "after clamp: {after_clamp}"
    );
    // ...but its files are left alone.
    assert!(custom.join(file).exists(), "the custom dump must not be deleted");

    let _ = std::fs::remove_dir_all(&dir);
}
