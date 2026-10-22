//! Table-browsing pagination: keyset cursor + deferred join, end to end.
//!
//! The SQL shapes themselves are unit-tested in `dbpilot_core::paging`; this
//! file drives the FFI surface (`api::explorer::table_data`) against a real
//! SQLite database so the wiring — JSON options in, `next_cursor` /
//! `used_keyset` / `used_deferred` out — is covered too.
//!
//! The core keeps its state in a process-wide `OnceLock`, so everything lives
//! in one sequential test (same convention as `tests/sqlite_flow.rs`).

use serde_json::{json, Value};

use rust_myadmin_core::api;

async fn ok<T>(future: impl std::future::Future<Output = anyhow::Result<T>>) -> T {
    match future.await {
        Ok(value) => value,
        Err(e) => panic!("unexpected error: {e}"),
    }
}

#[tokio::test]
async fn paging_options_are_wired_end_to_end() {
    let dir = std::env::temp_dir().join(format!("rma-paging-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp dir");
    let db_file = dir.join("paging.sqlite");
    // The database file must exist; a missing path is reported, not created.
    std::fs::write(&db_file, b"").expect("create database file");

    let init = api::init_app(dir.to_string_lossy().to_string());
    assert_eq!(init.get("ok"), Some(&Value::Bool(true)), "init: {init}");

    let created = ok(api::connections::create_connection(json!({
        "name": "Paging SQLite",
        "driver": "sqlite",
        "database": db_file.to_string_lossy(),
    })))
    .await;
    let conn_id = created["connection"]["id"].as_str().unwrap_or("").to_string();
    assert!(!conn_id.is_empty(), "connection id: {created}");
    ok(api::connections::connect_connection(conn_id)).await;

    ok(api::query::run_query(json!({
        "sql": "CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT, big TEXT);"
    })))
    .await;
    let mut values = Vec::new();
    for i in 1..=120 {
        values.push(format!("({i}, 'label{i}', '{}')", "x".repeat(300)));
    }
    ok(api::query::run_query(json!({
        "sql": format!("INSERT INTO items (id, label, big) VALUES {};", values.join(",")),
    })))
    .await;

    // ---- page 1: defaults (count on, deferred on, no cursor yet) ----------
    let first = ok(api::explorer::table_data(
        "main".into(),
        "items".into(),
        json!({ "per_page": 10 }),
    ))
    .await;
    assert_eq!(first["total"], json!(120), "first: {first}");
    assert_eq!(first["pages"], json!(12));
    // `used_keyset` 表示「这张表/这种排序支持游标分页」，第一页就为 true，
    // 客户端据此决定是否把 next_cursor 接成链条；`used_cursor` 才表示
    // 「这一页真的用 after 顶掉了 OFFSET」。
    assert_eq!(first["used_keyset"], json!(true));
    assert_eq!(first["used_cursor"], json!(false), "第一页没有游标可用");
    assert_eq!(first["used_deferred"], json!(true), "deferred defaults on");
    assert_eq!(
        first["next_cursor"],
        json!(10),
        "the first page must hand back the cursor for page 2"
    );
    assert!(first["sql"].as_str().unwrap_or_default().contains("JOIN (SELECT"));

    // ---- page 2: cursor in, COUNT skipped ---------------------------------
    let second = ok(api::explorer::table_data(
        "main".into(),
        "items".into(),
        json!({ "per_page": 10, "after": first["next_cursor"].clone(), "count": false }),
    ))
    .await;
    assert_eq!(second["used_keyset"], json!(true), "second: {second}");
    assert_eq!(second["used_cursor"], json!(true), "second: {second}");
    assert_eq!(second["used_deferred"], json!(true));
    assert_eq!(second["total"], Value::Null, "count=false skips COUNT(*)");
    assert_eq!(second["pages"], Value::Null);
    let rows = second["rows"].as_array().expect("rows");
    assert_eq!(rows.len(), 10);
    assert_eq!(rows[0][0], json!(11), "keyset must continue after the cursor");
    assert_eq!(second["next_cursor"], json!(20));

    // ---- the last (short) page reports no cursor, so the UI stops ---------
    let last = ok(api::explorer::table_data(
        "main".into(),
        "items".into(),
        json!({ "per_page": 50, "after": 100 }),
    ))
    .await;
    let last_rows = last["rows"].as_array().expect("rows");
    assert_eq!(last_rows.len(), 20, "last: {last}");
    assert_eq!(
        last["next_cursor"],
        Value::Null,
        "a page shorter than per_page is the last one: {last}"
    );

    // ---- deferred=false falls back to a plain SELECT ----------------------
    let plain = ok(api::explorer::table_data(
        "main".into(),
        "items".into(),
        json!({ "per_page": 5, "deferred": false }),
    ))
    .await;
    assert_eq!(plain["used_deferred"], json!(false));
    assert!(!plain["sql"].as_str().unwrap_or_default().contains("JOIN (SELECT"));

    // ---- a table without a primary key keeps offset paging ----------------
    ok(api::query::run_query(json!({
        "sql": "CREATE TABLE nopk (a INTEGER, b TEXT);"
    })))
    .await;
    ok(api::query::run_query(json!({
        "sql": "INSERT INTO nopk VALUES (1,'x'),(2,'y');"
    })))
    .await;
    let no_pk = ok(api::explorer::table_data(
        "main".into(),
        "nopk".into(),
        json!({ "per_page": 10, "after": 1 }),
    ))
    .await;
    assert_eq!(no_pk["used_keyset"], json!(false));
    assert_eq!(no_pk["used_cursor"], json!(false));
    assert_eq!(no_pk["used_deferred"], json!(false));
    assert_eq!(no_pk["next_cursor"], Value::Null);
    assert_eq!(no_pk["total"], json!(2));

    // ---- a non-scalar cursor is rejected, not silently ignored ------------
    assert!(api::explorer::table_data(
        "main".into(),
        "items".into(),
        json!({ "after": { "nested": 1 } }),
    )
    .await
    .is_err());

    // ---- the filter is still rebuilt by parse_filter and ANDed in ---------
    let filtered = ok(api::explorer::table_data(
        "main".into(),
        "items".into(),
        json!({ "per_page": 10, "where": "id > 50", "after": 60 }),
    ))
    .await;
    assert_eq!(filtered["used_keyset"], json!(true), "filtered: {filtered}");
    let filtered_rows = filtered["rows"].as_array().expect("rows");
    assert_eq!(filtered_rows[0][0], json!(61), "filtered rows: {filtered}");

    // ---- an injected filter is still rejected ----------------------------
    assert!(api::explorer::table_data(
        "main".into(),
        "items".into(),
        json!({ "where": "1=1 OR 1=1", "after": 1 }),
    )
    .await
    .is_err());

    let _ = std::fs::remove_dir_all(&dir);
}
