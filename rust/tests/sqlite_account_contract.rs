//! SQLite 契约回归（P3 Step 4 + P4 收尾）。
//!
//! 背景：把账号能力搬进 core::AccountAdmin 时，如果 SQLite 直接返回「没有实现」，
//! list_db_users / user_privileges 会从「正常空结果」变成报错；Dart 侧
//! desktop/lib/src/views/server_view.dart:779 用
//! if (_accountModel['supported'] != true) 隐藏账号页签 —— 一旦这里报错，
//! 页面会走 _error 分支弹错，而不是显示「SQLite 没有账号体系」的说明。
//! 本测试把这些 JSON 形态钉死，并覆盖 P2-3/P4 改动过的另外两个 SQLite 出口。
//!
//! SQLite 不需要服务器，因此是 hermetic 用例（不标 #[ignore]）。

use serde_json::{json, Value};

use rust_myadmin_core::api;

fn keys(value: &Value) -> Vec<String> {
    let mut out: Vec<String> = value
        .as_object()
        .map(|o| o.keys().cloned().collect())
        .unwrap_or_default();
    out.sort();
    out
}

#[tokio::test]
async fn sqlite_contracts_are_stable() {
    let dir = std::env::temp_dir().join(format!("rma-account-contract-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp dir");
    let db_file = dir.join("demo.sqlite");
    std::fs::write(&db_file, b"").expect("create db file");

    let init = api::init_app(dir.to_string_lossy().to_string());
    assert_eq!(init.get("ok"), Some(&Value::Bool(true)), "init: {init}");

    let created = api::connections::create_connection(json!({
        "name": "account contract sqlite",
        "driver": "sqlite",
        "database": db_file.to_string_lossy(),
    }))
    .await
    .expect("create connection");
    let id = created["connection"]["id"].as_str().expect("id").to_string();
    api::connections::connect_connection(id)
        .await
        .expect("connect sqlite");

    // ---------------------------------------------------------- 账号：读接口
    // 1) 账号列表 → 空数组 + driver，而不是错误。
    let users = api::server::list_db_users()
        .await
        .expect("list_db_users 对 SQLite 必须是正常空结果");
    assert_eq!(users["users"], json!([]), "users payload: {users}");
    assert_eq!(users["driver"], json!("sqlite"), "users payload: {users}");
    assert_eq!(keys(&users), vec!["driver", "users"], "users keys changed: {users}");

    // 2) 账号能力目录 → supported:false，而不是错误。
    let catalog = api::server::user_privileges(json!({}))
        .await
        .expect("user_privileges 对 SQLite 必须返回 supported:false 目录");
    assert_eq!(catalog["supported"], json!(false), "catalog: {catalog}");
    assert_eq!(catalog["model"], json!("sqlite"), "catalog: {catalog}");
    assert_eq!(catalog["driver"], json!("sqlite"), "catalog: {catalog}");
    assert_eq!(catalog["host_required"], json!(false), "catalog: {catalog}");
    assert!(
        catalog["note"].as_str().map(|n| !n.is_empty()).unwrap_or(false),
        "note 是 UI 的说明文案，不能为空: {catalog}"
    );
    // UI 用 supported 做门禁；额外键可以有，但不能少。
    for required in ["supported", "model", "host_required", "note", "driver"] {
        assert!(
            keys(&catalog).contains(&required.to_string()),
            "catalog 缺少字段 {required}: {catalog}"
        );
    }

    // 3) 服务器能力探测（Dart app_state.can() 读的就是这组 can_* 标志）。
    let caps = api::server::server_privileges()
        .await
        .expect("server_privileges 对 SQLite 必须成功");
    assert_eq!(caps["driver"], json!("sqlite"), "caps: {caps}");
    assert_eq!(caps["account"], json!("sqlite"), "caps: {caps}");
    assert_eq!(caps["can_view_status"], json!(true), "caps: {caps}");
    for flag in [
        "can_manage_accounts",
        "can_create_database",
        "can_view_processes",
        "can_kill_processes",
    ] {
        assert_eq!(caps[flag], json!(false), "SQLite 的 {flag} 必须是 false: {caps}");
    }
    assert!(
        caps["visible_databases"].is_array(),
        "visible_databases 必须是数组: {caps}"
    );

    // ---------------------------------------------------------- 账号：写接口
    // 保持原有用户错误文案（不是 500 / internal）。
    let create = api::server::create_db_user(json!({ "user": "someone" }), true).await;
    assert!(
        create
            .expect_err("SQLite 建账号必须报错")
            .to_string()
            .contains("SQLite 没有数据库账号")
    );
    let update = api::server::update_db_user(
        "someone".to_string(),
        "%".to_string(),
        json!({ "password": "x" }),
        true,
    )
    .await;
    assert!(
        update
            .expect_err("SQLite 改账号必须报错")
            .to_string()
            .contains("SQLite 没有数据库账号")
    );
    let drop = api::server::drop_db_user("someone".to_string(), "%".to_string()).await;
    assert!(
        drop.expect_err("SQLite 删账号必须报错")
            .to_string()
            .contains("SQLite 没有数据库账号")
    );
    let grants = api::server::db_user_grants("someone".to_string(), "%".to_string()).await;
    assert!(
        grants
            .expect_err("SQLite 查看授权必须报错")
            .to_string()
            .contains("SQLite 没有数据库账号")
    );

    // ------------------------------------------- driver_options（P2 搬迁的载荷）
    // 这组键原来硬编码在 api/mod.rs，现在由 core DriverMetadata::to_json 产出；
    // Dart 连接表单直接读它，所以必须在运行时验证形态（而不只是单测）。
    let options = api::driver_options();
    let list = options.as_array().expect("driver_options 必须是数组");
    assert_eq!(list.len(), 3, "driver_options: {options}");
    let ids: Vec<&str> = list
        .iter()
        .filter_map(|d| d.get("id").and_then(|v| v.as_str()))
        .collect();
    assert_eq!(ids, vec!["mysql", "postgres", "sqlite"], "顺序即表单顺序: {options}");
    for item in list {
        assert_eq!(
            keys(item),
            vec!["default_port", "default_user", "id", "label"],
            "driver_options 的字段集必须与重构前一致: {item}"
        );
    }

    // ------------------------------------------------- 文件列表（P2-3 改动面）
    let databases = api::sqlite::sqlite_databases(false)
        .await
        .expect("sqlite_databases");
    for required in [
        "folder",
        "folder_name",
        "folder_exists",
        "primary",
        "primary_exists",
        "databases",
        "groups",
        "unreadable",
        "scanned",
        "attach_limit",
    ] {
        assert!(
            keys(&databases).contains(&required.to_string()),
            "sqlite_databases 缺少字段 {required}: {databases}"
        );
    }
    assert_eq!(
        databases["attach_limit"],
        json!(10),
        "attach_limit 由驱动能力给出（SQLITE_MAX_ATTACHED 约定为 10）"
    );
    assert!(
        databases["scanned"].as_u64().unwrap_or(0) >= 1,
        "应该扫描到 demo.sqlite: {databases}"
    );
    let first = &databases["databases"][0];
    for required in ["name", "path", "file", "title", "dir", "primary", "exists"] {
        assert!(
            keys(first).contains(&required.to_string()),
            "database 条目缺少字段 {required}: {first}"
        );
    }
    assert_eq!(first["title"], json!("demo"), "标题应是去掉扩展名的文件名: {first}");

    // 状态页对 SQLite 是本地元数据（不受账号改动影响）。
    let status = api::server::status().await.expect("status sqlite");
    assert!(status.get("version").is_some(), "status: {status}");

    // ------------------------------------- 新建库 + 起始脚本（P4 切分路径）
    // 正常脚本必须能被 split_statements_for(sqlite) 正确切开并执行。
    let created_db = api::sqlite::sqlite_create_database(json!({
        "dir": dir.to_string_lossy(),
        "name": "starter",
        "content": "CREATE TABLE t (a INTEGER); INSERT INTO t VALUES (1); INSERT INTO t VALUES (2);",
    }))
    .await
    .expect("create sqlite database with starter script");
    assert_eq!(created_db["ok"], json!(true), "create payload: {created_db}");

    let count = api::query::run_query(json!({ "sql": "SELECT COUNT(*) FROM t" }))
        .await
        .expect("count rows in starter table");
    assert_eq!(count["failed"], json!(0), "starter script failed: {count}");
    assert_eq!(
        count["results"][0]["rows"][0][0],
        json!(2),
        "starter script 的语句没有被完整执行: {count}"
    );
}
