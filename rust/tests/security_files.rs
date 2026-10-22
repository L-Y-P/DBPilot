use rust_myadmin_core::api;
use serde_json::json;

#[test]
fn import_read_enforces_size_and_utf8() {
    let dir = std::env::temp_dir().join(format!("rma-read-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&dir).unwrap();
    let path = dir.join("large.sql");
    let file = std::fs::File::create(&path).unwrap();
    file.set_len(64 * 1024 * 1024 + 1).unwrap();
    let result = api::files::read_text_file(path.to_string_lossy().into());
    assert!(result.is_err(), "oversized imports must be rejected before allocation");
    std::fs::write(&path, "SELECT '中文';").unwrap();
    assert_eq!(api::files::read_text_file(path.to_string_lossy().into()).unwrap(), "SELECT '中文';");
    std::fs::write(&path, [0xff]).unwrap();
    assert!(api::files::read_text_file(path.to_string_lossy().into()).is_err());
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn sqlite_delete_stays_inside_connection_folder_and_preflights_batch() {
    let root = std::env::temp_dir().join(format!("rma-delete-{}", uuid::Uuid::new_v4()));
    let folder = root.join("allowed");
    std::fs::create_dir_all(&folder).unwrap();
    let primary = folder.join("main.sqlite");
    std::fs::write(&primary, []).unwrap();
    api::init_app(root.join("app").to_string_lossy().into());
    let made = api::connections::create_connection(json!({"name":"Synthetic", "driver":"sqlite", "database":primary, "sqlite_dir":folder})).await.unwrap();
    api::connections::connect_connection(made["connection"]["id"].as_str().unwrap().into()).await.unwrap();
    let outside = root.join("outside.sqlite");
    std::fs::write(&outside, []).unwrap();
    let victim = folder.join("victim.sqlite");
    std::fs::write(&victim, []).unwrap();
    let result = api::sqlite::sqlite_delete_file(json!({"paths":[victim, outside]})).await;
    assert!(result.is_err(), "outside-folder deletion must fail");
    assert!(victim.exists(), "validate the whole batch before deleting any file");
    assert!(outside.exists());
    for target in [primary.clone(), folder.join("../outside.sqlite")] {
        assert!(api::sqlite::sqlite_delete_file(json!({"paths":[target]})).await.is_err());
    }
    #[cfg(unix)] {
        let escape = folder.join("escape");
        std::os::unix::fs::symlink(&root, &escape).unwrap();
        assert!(api::sqlite::sqlite_delete_file(json!({"paths":[escape.join("outside.sqlite")]})).await.is_err());
        let link = folder.join("link.sqlite");
        std::os::unix::fs::symlink(&outside, &link).unwrap();
        assert!(api::sqlite::sqlite_delete_file(json!({"paths":[link]})).await.is_err());
    }
    let text = folder.join("notes.txt");
    std::fs::write(&text, "keep").unwrap();
    assert!(api::sqlite::sqlite_delete_file(json!({"paths":[text]})).await.is_err());
    api::sqlite::sqlite_delete_file(json!({"paths":[victim]})).await.unwrap();
    assert!(!victim.exists());
    assert!(primary.exists() && outside.exists());
    api::connections::disconnect().await.unwrap();
    std::fs::remove_dir_all(root).unwrap();
}
