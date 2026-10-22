//! P1: large table exports must stream to the destination file.
//!
//! The export used to `fetch_all` the whole table, render it into one String
//! and send that through the FFI bridge — on a 1,000,000-row table the test
//! report measured ~1 GB RSS (ST-06 / §6.3 P1). The fix writes row by row into
//! the destination file, so the response carries no content at all and the
//! preview is byte-capped.

use rust_myadmin_core::api;
use serde_json::json;

fn sqlite_path(root: &std::path::Path) -> std::path::PathBuf {
    let dir = root.join("db");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("main.sqlite");
    std::fs::write(&file, []).unwrap();
    file
}

async fn settle_setup() {
    // No-op helper kept so the setup code mirrors the other integration tests.
}

#[tokio::test]
async fn csv_and_sql_exports_stream_to_file_and_preview_is_bounded() {
    let root = std::env::temp_dir().join(format!("rma-export-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&root).unwrap();
    let db_file = sqlite_path(&root);
    let initialized = api::init_app(root.join("app").to_string_lossy().into());
    assert_eq!(initialized["ok"], json!(true), "{initialized}");
    settle_setup().await;
    let made = api::connections::create_connection(json!({
        "name": "Export streaming",
        "driver": "sqlite",
        "database": db_file,
    }))
    .await
    .unwrap();
    api::connections::connect_connection(made["connection"]["id"].as_str().unwrap().into())
        .await
        .unwrap();

    // 100,000 rows: enough for a preview to hit its byte cap.
    let setup = api::query::run_query(json!({
        "sql": "CREATE TABLE big(x INTEGER); \
                WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 100000) \
                INSERT INTO big SELECT x FROM c;"
    }))
    .await
    .unwrap();
    assert!(
        setup["results"].as_array().unwrap().iter().all(|r| r["error"].is_null()),
        "setup: {setup}"
    );

    // ---- 1. CSV straight to file: no content through the FFI bridge ----
    let csv_path = root.join("big.csv");
    let result = api::export::export_table(
        "main".into(),
        "big".into(),
        json!({"format": "csv", "path": csv_path.to_string_lossy()}),
    )
    .await
    .expect("csv export");
    assert_eq!(result["written"], json!(true), "{result}");
    assert_eq!(result["rows"], json!(100_000));
    assert_eq!(result["content"], json!(""), "the file export must not return a String copy");
    let csv = std::fs::read_to_string(&csv_path).unwrap();
    let lines: Vec<&str> = csv.lines().collect();
    assert_eq!(lines.len(), 100_001, "header + one line per row");
    assert_eq!(lines[0], "x");
    assert_eq!(lines[1], "1");
    assert_eq!(lines.last(), Some(&"100000"));

    // ---- 2. SQL dump straight to file: structure + streamed INSERT batches ----
    let sql_path = root.join("big.sql");
    let result = api::export::export_table(
        "main".into(),
        "big".into(),
        json!({"format": "sql", "path": sql_path.to_string_lossy(), "structure": true, "data": true}),
    )
    .await
    .expect("sql export");
    assert_eq!(result["rows"], json!(100_000), "{result}");
    let dump = std::fs::read_to_string(&sql_path).unwrap();
    assert!(dump.contains("CREATE TABLE"), "missing structure: {}", &dump[..200.min(dump.len())]);
    assert!(dump.contains("INSERT INTO"), "missing data");
    assert!(dump.contains("(100000)"), "last row missing from the dump");
    // Batched INSERTs: 100k rows / 500 per statement = 200 statements.
    assert_eq!(dump.matches("INSERT INTO").count(), 200);
    assert!(!dump.contains("(100001)"), "must not invent rows");

    // ---- 3. CSV preview is byte-capped and flagged ----
    let preview = api::export::export_table(
        "main".into(),
        "big".into(),
        json!({"format": "csv"}),
    )
    .await
    .expect("csv preview");
    assert_eq!(preview["truncated"], json!(true), "{preview:?}");
    let content = preview["content"].as_str().unwrap();
    assert!(
        content.len() <= 256 * 1024,
        "preview must be capped, got {} bytes",
        content.len()
    );
    let preview_rows = preview["rows"].as_u64().unwrap();
    assert!(preview_rows > 0 && preview_rows < 100_000);
    assert_eq!(
        content.lines().count() as u64,
        preview_rows + 1,
        "each previewed row must be complete"
    );

    // ---- 4. SQL preview stops after the row cap ----
    let preview = api::export::export_table(
        "main".into(),
        "big".into(),
        json!({"format": "sql"}),
    )
    .await
    .expect("sql preview");
    assert_eq!(preview["truncated"], json!(true));
    assert_eq!(preview["rows"], json!(200));
    let content = preview["content"].as_str().unwrap();
    assert!(content.contains("CREATE TABLE"));
    assert!(content.contains("(200)"));
    assert!(!content.contains("(201)"));

    // ---- 5. Unsupported format is rejected before writing anything ----
    let error = api::export::export_table(
        "main".into(),
        "big".into(),
        json!({"format": "parquet", "path": root.join("x.parquet").to_string_lossy()}),
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("不支持的导出格式"), "{error}");
    assert!(!root.join("x.parquet").exists());

    // ---- 6. Relative destination paths are refused ----
    let error = api::export::export_table(
        "main".into(),
        "big".into(),
        json!({"format": "csv", "path": "relative.csv"}),
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("绝对路径"), "{error}");

    api::connections::disconnect().await.unwrap();
    std::fs::remove_dir_all(&root).unwrap();
}
