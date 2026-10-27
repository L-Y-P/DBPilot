//! 用户数据目录的盘点与清空（`src/uninstall.rs`）的集成测试。
//!
//! 这些用例**不经过 FRB 状态**：`wipe_data_dir` 的破坏性语义必须在没有
//! `initApp` 的情况下也成立（卸载流程就是在应用状态之外跑的）。`api::files`
//! 那层只覆盖「确认短语/JSON 字段契约」，且只在单个用例里 `init_app` 一次——
//! 全局 `OnceLock` 一个进程只能初始化一次，多写几个用例会互相抢。

use std::path::{Path, PathBuf};

use rust_myadmin_core::uninstall::{
    data_dir_bytes, data_dir_overview, overview_json, scan_data_dir, wipe_data_dir, DataKind,
    DELETE_TOKEN,
};

/// 每个用例一个独立临时目录，路径深度 >= 2（`/var/folders/.../rma-uninstall-x`），
/// 保证不会撞上 [`wipe_data_dir`] 的浅目录护栏。
fn temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("rma-uninstall-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("create temp dir");
    dir
}

fn write(path: &Path, body: &str) {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).expect("create parent");
    }
    std::fs::write(path, body).expect("write fixture");
}

/// 典型的数据目录：一个敏感文件、一个嵌套备份、一个空目录。
fn populated(tag: &str) -> PathBuf {
    let dir = temp_dir(tag);
    write(&dir.join("connections.json"), "{\"host\":\"127.0.0.1\"}"); // 20 B
    write(&dir.join("settings.json"), "{\"theme\":\"dark\"}"); // 16 B
    write(&dir.join("backups").join("a.sql"), "-- a\n"); // 5 B
    write(&dir.join("backups").join("nested").join("b.sql"), "-- bb\n"); // 6 B
    std::fs::create_dir_all(dir.join("empty")).expect("create empty dir");
    dir
}

#[test]
fn scan_sums_sizes_and_counts_files() {
    let dir = populated("scan");
    let entries = scan_data_dir(&dir);

    let find = |name: &str| {
        entries
            .iter()
            .find(|entry| entry.name == name)
            .unwrap_or_else(|| panic!("missing entry {name}: {entries:?}"))
            .clone()
    };

    let connections = find("connections.json");
    assert_eq!(connections.kind, DataKind::File);
    assert_eq!(connections.bytes, 20);
    assert_eq!(connections.count, 1, "a file counts as one file");

    let backups = find("backups");
    assert_eq!(backups.kind, DataKind::Dir);
    assert_eq!(backups.bytes, 11, "5 + 6 bytes below backups/");
    assert_eq!(backups.count, 2, "two .sql files below backups/");

    let empty = find("empty");
    assert_eq!(empty.kind, DataKind::Dir);
    assert_eq!(empty.bytes, 0);
    assert_eq!(empty.count, 0);

    // 按体积降序：connections.json(20) 在 settings.json(16) 前面。
    let order: Vec<&str> = entries.iter().map(|entry| entry.name.as_str()).collect();
    assert_eq!(
        order.first().copied(),
        Some("connections.json"),
        "largest first: {order:?}"
    );

    let overview = data_dir_overview(&dir);
    assert!(overview.exists);
    assert_eq!(
        overview.total_bytes,
        entries.iter().map(|entry| entry.bytes).sum::<u64>()
    );
    assert_eq!(
        overview.file_count,
        entries.iter().map(|entry| entry.count).sum::<u64>()
    );
    // secret_files 只列真正存在的敏感文件，且带上完整路径。
    assert_eq!(overview.secret_files.len(), 2, "{:?}", overview.secret_files);
    assert!(overview
        .secret_files
        .iter()
        .any(|path| path.ends_with("connections.json")));
}

#[test]
fn overview_json_keeps_the_dart_contract() {
    let dir = populated("json");
    let value = overview_json(&dir);
    assert_eq!(value["exists"], serde_json::json!(true));
    assert_eq!(value["contains_secrets"], serde_json::json!(true));
    assert!(
        value["total_bytes"].as_u64().unwrap_or(0) >= 42,
        "total: {value}"
    );
    let files = value["files"].as_array().expect("files array");
    assert!(files.iter().all(|file| {
        file.get("name").and_then(|v| v.as_str()).is_some()
            && file.get("path").and_then(|v| v.as_str()).is_some()
            && file.get("bytes").and_then(|v| v.as_u64()).is_some()
            && file.get("count").and_then(|v| v.as_u64()).is_some()
            && matches!(file.get("kind").and_then(|v| v.as_str()), Some("file" | "dir"))
    }));

    // 目录不存在时结构不变，只是数字为零 / exists=false。
    let missing = overview_json(&dir.join("definitely-missing"));
    assert_eq!(missing["exists"], serde_json::json!(false));
    assert_eq!(missing["contains_secrets"], serde_json::json!(false));
    assert_eq!(missing["files"], serde_json::json!([]));
    assert_eq!(missing["total_bytes"], serde_json::json!(0));
}

#[test]
fn symlinks_are_skipped_not_followed() {
    let dir = temp_dir("symlink");
    let outside = temp_dir("symlink-outside");
    write(&outside.join("important.txt"), "do not delete me");
    write(&dir.join("real.txt"), "real");
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(&outside, dir.join("link")).expect("symlink");
        let overview = data_dir_overview(&dir);
        assert_eq!(
            overview.total_bytes, 4,
            "symlink target must not be counted: {overview:?}"
        );
        assert!(
            !overview.entries.iter().any(|e| e.name == "link"),
            "symlinks are not listed: {overview:?}"
        );
        // 清空只删链接本身，链接指向的真实数据必须还在。
        wipe_data_dir(&dir, DELETE_TOKEN, DELETE_TOKEN).expect("wipe");
        assert!(outside.join("important.txt").exists(), "target survived");
    }
    #[cfg(not(unix))]
    let _ = &outside;
}

#[test]
fn guards_reject_empty_root_and_shallow_paths() {
    // 空路径
    let empty = Path::new("");
    assert!(wipe_data_dir(empty, DELETE_TOKEN, DELETE_TOKEN).is_err());

    // 根目录
    let root = Path::new("/");
    let error = wipe_data_dir(root, DELETE_TOKEN, DELETE_TOKEN).expect_err("root must be refused");
    assert!(error.contains("根目录"), "unexpected error: {error}");

    // 盘符根（Windows 形态的字符串在 macOS 上也会被同一套护栏拦下）
    for drive in ["C:", "C:\\", "D:/"] {
        let error = wipe_data_dir(Path::new(drive), DELETE_TOKEN, DELETE_TOKEN)
            .expect_err("drive root must be refused");
        assert!(
            error.contains("盘符") || error.contains("过浅"),
            "unexpected error for {drive}: {error}"
        );
    }

    // 深度 < 2 的目录：/tmp 这类一级目录，即使真实存在也必须拒绝。
    let shallow = Path::new("/tmp");
    let error = wipe_data_dir(shallow, DELETE_TOKEN, DELETE_TOKEN).expect_err("shallow refused");
    assert!(error.contains("过浅"), "unexpected error: {error}");
    assert!(shallow.exists(), "the guard must not touch /tmp");
}

#[test]
fn wrong_confirmation_leaves_everything_alone() {
    let dir = populated("confirm");
    let before = data_dir_bytes(&dir);
    assert!(before > 0);

    for wrong in ["", "delete-all-x", "DELETE", "delete all"] {
        let error = wipe_data_dir(&dir, wrong, DELETE_TOKEN)
            .expect_err("`{wrong}` must be refused");
        assert!(
            error.contains("确认短语"),
            "unexpected error for `{wrong}`: {error}"
        );
    }
    // 大小写不敏感且容忍首尾空白，但必须完整相等。
    assert!(
        wipe_data_dir(&dir, "  delete-All  ", "DELETE-ALL-x".to_string().as_str()).is_err(),
        "prefix is not a confirmation"
    );

    assert_eq!(data_dir_bytes(&dir), before, "nothing may be deleted");
    assert!(dir.join("connections.json").exists());
    assert!(dir.join("backups").join("nested").join("b.sql").exists());

    // 调用方没给期望值时不能无条件放行。
    assert!(wipe_data_dir(&dir, "", "").is_err());
}

#[test]
fn wipe_is_idempotent_and_keeps_the_directory() {
    let dir = populated("wipe");
    assert!(data_dir_bytes(&dir) > 0);

    // 小写也接受（大小写不敏感）。
    wipe_data_dir(&dir, "delete-all", DELETE_TOKEN).expect("first wipe");

    assert!(dir.is_dir(), "the data directory itself must survive");
    assert_eq!(
        std::fs::read_dir(&dir).expect("read dir").count(),
        0,
        "no children may remain"
    );
    let overview = data_dir_overview(&dir);
    assert!(overview.exists);
    assert_eq!(overview.total_bytes, 0);
    assert_eq!(overview.file_count, 0);
    assert!(overview.secret_files.is_empty());

    // 第二次清空：目录已空，仍然 Ok（幂等）。
    wipe_data_dir(&dir, DELETE_TOKEN, DELETE_TOKEN).expect("second wipe is a no-op");

    // 目录本身被删掉后再点一次也必须是 Ok，并且不留半截状态。
    std::fs::remove_dir_all(&dir).expect("remove dir");
    wipe_data_dir(&dir, DELETE_TOKEN, DELETE_TOKEN).expect("missing dir is a no-op");

    // 失败路径不留副作用：确认短语错误时目录保持原样。
    write(&dir.join("settings.json"), "{}");
    assert!(wipe_data_dir(&dir, "nope", DELETE_TOKEN).is_err());
    assert!(dir.join("settings.json").exists());
}

#[test]
fn api_wipe_user_data_rejects_a_bad_confirmation() {
    // 只在这里初始化一次全局状态：`STATE` 是进程级 OnceLock。
    let dir = temp_dir("api");
    write(&dir.join("connections.json"), "{}");
    let init = rust_myadmin_core::api::init_app(dir.to_string_lossy().to_string());
    assert_eq!(
        init.get("ok").and_then(|v| v.as_bool()),
        Some(true),
        "init: {init}"
    );

    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("runtime");

    // 先看盘点契约。
    let summary = rust_myadmin_core::api::files::data_dir_summary().expect("summary");
    assert_eq!(summary["exists"], serde_json::json!(true));
    assert_eq!(summary["contains_secrets"], serde_json::json!(true));
    assert!(summary["files"].as_array().is_some_and(|files| !files.is_empty()));

    // 确认短语错误：必须报错，且文件仍在。
    let error = runtime
        .block_on(rust_myadmin_core::api::files::wipe_user_data(
            "DELETE-USER-DATAX".to_string(),
        ))
        .expect_err("bad confirmation must fail");
    assert!(
        error.to_string().contains("确认短语"),
        "unexpected error: {error}"
    );
    assert!(dir.join("connections.json").exists());

    // 正确短语：返回 ok 与释放字节数（删除前统计，含 init_app 自己写出的
    // settings.json），目录保留。
    let expected_bytes = data_dir_bytes(&dir);
    assert!(expected_bytes > 2, "fixture should hold data: {expected_bytes}");
    let removed = runtime
        .block_on(rust_myadmin_core::api::files::wipe_user_data(
            "delete-user-data".to_string(),
        ))
        .expect("wipe");
    assert_eq!(removed["ok"], serde_json::json!(true));
    assert_eq!(removed["removed_bytes"], serde_json::json!(expected_bytes));
    assert!(dir.is_dir());
    assert!(!dir.join("connections.json").exists());
}
