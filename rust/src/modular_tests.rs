//! 32 轮「core + 驱动扩展点」重构的结构守护测试。
//!
//! 这些测试不连数据库：它们锁定的是**架构约束**，防止后续提交把方言 SQL
//! 或具体驱动依赖又写回 api 层。
//!
//! 允许的临时例外（P2 待办）在 CONCRETE_DRIVER_ALLOWLIST /
//! DIALECT_SQL_ALLOWLIST 里逐条列出；新增例外必须同时更新迁移文档。

use std::sync::Arc;

use serde_json::json;

use crate::core::registry::{driver_options_json, DriverRegistry};
use crate::drivers::{ConnSpec, DriverKind};

fn builtin_registry() -> Arc<DriverRegistry> {
    let registry = Arc::new(DriverRegistry::new());
    crate::core::plugin::activate(&crate::drivers::builtin::builtin_plugins(), &registry)
        .expect("内置插件应能注册");
    registry
}

#[test]
fn builtin_plugins_register_the_three_drivers_in_order() {
    let registry = builtin_registry();
    assert_eq!(registry.ids(), vec!["mysql", "postgres", "sqlite"]);
    assert_eq!(registry.len(), 3);
}

#[test]
fn duplicate_registration_is_rejected() {
    let registry = builtin_registry();
    let mysql = registry.get("mysql").unwrap();
    assert!(registry.register(mysql).is_err(), "重复注册必须报错");
}

#[test]
fn unknown_driver_is_a_user_error_not_a_panic() {
    let registry = builtin_registry();
    let error = registry.get("oracle").unwrap_err();
    assert!(error.to_string().contains("oracle"));
    assert!(error.is_user_error());
}

#[test]
fn driver_options_keep_the_legacy_ffi_shape() {
    let registry = builtin_registry();
    let options = driver_options_json(&registry);
    let array = options.as_array().unwrap();
    assert_eq!(array.len(), 3);
    for item in array {
        let map = item.as_object().unwrap();
        let mut keys: Vec<&String> = map.keys().collect();
        keys.sort();
        assert_eq!(
            keys,
            vec!["default_port", "default_user", "id", "label"],
            "driver_options 的字段必须与重构前一致（Dart 契约）"
        );
    }
}

#[test]
fn each_dialect_owns_its_own_catalog_sql() {
    let registry = builtin_registry();
    let mysql = registry.get("mysql").unwrap();
    let postgres = registry.get("postgres").unwrap();
    let sqlite = registry.get("sqlite").unwrap();

    let mysql_tables = mysql.dialect().list_tables_sql("web").sql;
    assert!(mysql_tables.contains("information_schema.TABLES"));
    assert!(mysql_tables.contains("'web'"));

    let pg_tables = postgres.dialect().list_tables_sql("public").sql;
    assert!(pg_tables.contains("pg_class"));
    assert!(pg_tables.contains("information_schema.tables"));

    let sqlite_tables = sqlite.dialect().list_tables_sql("main").sql;
    assert!(sqlite_tables.contains("sqlite_master"));

    assert!(sqlite
        .dialect()
        .explain_sql("SELECT 1")
        .starts_with("EXPLAIN QUERY PLAN"));
    assert!(postgres
        .dialect()
        .explain_sql("SELECT 1")
        .starts_with("EXPLAIN "));
}

#[test]
fn literal_rendering_follows_the_dialect() {
    let registry = builtin_registry();
    let mysql = registry.get("mysql").unwrap();
    let postgres = registry.get("postgres").unwrap();

    assert_eq!(mysql.dialect().literal(&json!(true)), "1");
    assert_eq!(postgres.dialect().literal(&json!(true)), "TRUE");
    assert_eq!(mysql.dialect().literal(&json!(null)), "NULL");
    assert_eq!(mysql.dialect().literal(&json!("a'b")), "'a''b'");
    // MySQL 需要转义反斜杠；PostgreSQL 保持原样。
    assert_eq!(mysql.dialect().literal(&json!("a\\b")), "'a\\\\b'");
    assert_eq!(postgres.dialect().literal(&json!("a\\b")), "'a\\b'");

    // 反引号用 char 构造，避免源码里出现裸反引号。
    let bt = '\u{60}';
    let mysql_quoted = mysql.dialect().quote_ident(&format!("we{bt}b"));
    assert_eq!(mysql_quoted, format!("{bt}we{bt}{bt}b{bt}"));
    assert_eq!(postgres.dialect().quote_ident("a\"b"), "\"a\"\"b\"");
}

#[test]
fn database_resolution_keeps_the_legacy_semantics() {
    let registry = builtin_registry();
    let mysql = registry.get("mysql").unwrap();
    let postgres = registry.get("postgres").unwrap();
    let sqlite = registry.get("sqlite").unwrap();

    let mysql_spec = ConnSpec {
        driver: DriverKind::Mysql,
        database: Some("default_db".to_string()),
        ..Default::default()
    };
    // MySQL：参数就是数据库，优先级 requested > active > spec。
    assert_eq!(
        mysql
            .resolve_database(&mysql_spec, Some("web"), Some("other"))
            .unwrap()
            .as_deref(),
        Some("web")
    );
    assert_eq!(
        mysql
            .resolve_database(&mysql_spec, None, Some("other"))
            .unwrap()
            .as_deref(),
        Some("other")
    );
    assert_eq!(
        mysql
            .resolve_database(&mysql_spec, None, None)
            .unwrap()
            .as_deref(),
        Some("default_db")
    );

    // PostgreSQL：参数是 schema，物理库只来自 active_database / spec。
    let pg_spec = ConnSpec {
        driver: DriverKind::Postgres,
        database: Some("postgres".to_string()),
        ..Default::default()
    };
    assert_eq!(
        postgres
            .resolve_database(&pg_spec, Some("public"), Some("app"))
            .unwrap()
            .as_deref(),
        Some("app")
    );
    assert_eq!(
        postgres
            .resolve_database(&pg_spec, Some("public"), None)
            .unwrap()
            .as_deref(),
        Some("postgres")
    );
    assert!(postgres.requires_database());
    let empty = ConnSpec {
        driver: DriverKind::Postgres,
        ..Default::default()
    };
    assert!(postgres
        .resolve_database(&empty, Some("public"), None)
        .is_err());

    // SQLite：一个连接一个池，不选物理库。
    let sqlite_spec = ConnSpec {
        driver: DriverKind::Sqlite,
        database: Some("/tmp/x.sqlite".to_string()),
        ..Default::default()
    };
    assert!(sqlite
        .resolve_database(&sqlite_spec, Some("main"), None)
        .unwrap()
        .is_none());
    assert!(sqlite.is_file_based());
    assert!(!postgres.is_file_based());
}

#[test]
fn namespaces_are_databases_is_a_capability_not_a_match() {
    let registry = builtin_registry();
    assert!(registry.get("mysql").unwrap().namespaces_are_databases());
    assert!(registry.get("sqlite").unwrap().namespaces_are_databases());
    assert!(!registry.get("postgres").unwrap().namespaces_are_databases());
}

// --------------------------------------------------------------- 源码守卫

/// api 里仍允许出现的具体驱动依赖。
///
/// **P2 完成后为空**：api/sqlite.rs 的文件发现已收口到 DatabaseDriver 的
/// 文件能力方法，`grep -r "crate::drivers::{mysql,postgres,sqlite}" src/api`
/// 必须为 0。新增例外必须先更新迁移文档，否则这里就是回归。
const CONCRETE_DRIVER_ALLOWLIST: &[(&str, &[&str])] = &[];

/// api 里仍允许出现的方言 SQL。**P2 完成后为空**：
/// 取消/进程列表/protected schema/权限话术都已搬进方言与驱动。
const DIALECT_SQL_ALLOWLIST: &[(&str, &[&str])] = &[];

fn api_sources() -> Vec<(String, String)> {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/api");
    let mut sources = Vec::new();
    for entry in std::fs::read_dir(&dir).expect("api 目录必须存在") {
        let path = entry.expect("可读目录项").path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("rs") {
            continue;
        }
        let name = path
            .file_name()
            .map(|name| name.to_string_lossy().to_string())
            .unwrap_or_default();
        let text = std::fs::read_to_string(&path).expect("api 源文件必须可读");
        sources.push((name, text));
    }
    sources
}

fn allowed(file: &str, table: &[(&str, &[&str])], needle: &str) -> bool {
    table
        .iter()
        .filter(|(name, _)| *name == file)
        .any(|(_, needles)| needles.iter().any(|entry| *entry == needle))
}

#[test]
fn api_does_not_import_concrete_driver_modules() {
    for (file, text) in api_sources() {
        // 同时匹配 crate::drivers::mysql 与 crate::drivers::{mysql, ...} 两种
        // 写法（2026-10-21 独立验证发现的盲区：花括号形式曾绕过守卫）。
        for needle in [
            "crate::drivers::mysql",
            "crate::drivers::postgres",
            "crate::drivers::sqlite",
            "crate::drivers::{mysql",
            "crate::drivers::{postgres",
            "crate::drivers::{sqlite",
        ] {
            if text.contains(needle) && !allowed(&file, CONCRETE_DRIVER_ALLOWLIST, needle) {
                panic!("api/{file} 直接依赖了具体驱动：{needle}");
            }
        }
        // 允许 api 通过 core 的类型别名使用连接配置/驱动 id 类型。
        assert!(!text.contains("drivers::Pool"), "api/{file} 不应接触具体池类型");
    }
}

/// 去掉行注释后的源码：注释里提到方言 SQL（解释历史原因）不应触发守卫。
fn without_line_comments(text: &str) -> String {
    text.lines()
        .map(|line| match line.find("//") {
            Some(index) => &line[..index],
            None => line,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[test]
fn api_does_not_carry_dialect_sql() {
    for (file, text) in api_sources() {
        let text = without_line_comments(&text);
        for needle in [
            "SHOW TABLES",
            "SHOW DATABASES",
            "sqlite_master",
            "pg_catalog",
            "pg_database",
            "information_schema.PROCESSLIST",
        ] {
            if text.contains(needle) && !allowed(&file, DIALECT_SQL_ALLOWLIST, needle) {
                panic!("api/{file} 出现了方言 SQL：{needle}");
            }
        }
    }
}

// ------------------------------------------------------------ P3 结构守卫
//
// 这些守卫锁定 P3 的成果；如果后续提交把 api 又拉回 Db 门面 / ScriptSession，
// 或把 sqlx 的 MySQL 类型放回 db.rs，测试会失败。

fn source(relative: &str) -> String {
    std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(relative))
        .unwrap_or_else(|e| panic!("读不到 {relative}: {e}"))
}

#[test]
fn p3_session_abstraction_is_wired() {
    // api 只认 core trait，不再点名具体会话类型（注释里解释历史不算）。
    let query = without_line_comments(&source("src/api/query.rs"));
    assert!(
        !query.contains("script_session"),
        "api/query.rs 又出现了 Db::script_session"
    );
    assert!(
        query.contains("SessionHandle"),
        "api/query.rs 应通过 core::SessionHandle 开会话"
    );
    assert!(
        query.contains("open_session"),
        "api/query.rs 应通过 AppState::open_session 开会话"
    );
    // 旧门面上的 pub 构造入口必须保持删除状态。
    let facade = source("src/drivers/mod.rs");
    assert!(
        !facade.contains("pub async fn script_session"),
        "Db::script_session 又被加回来了"
    );
    // core 必须提供 trait 与驱动 / 池两端的接线。
    assert!(source("crates/dbpilot-core/src/session.rs").contains("pub trait SessionHandle"));
    assert!(source("crates/dbpilot-core/src/driver.rs").contains("async fn session("));
}

#[test]
fn p3_account_admin_is_the_only_account_surface() {
    let server = source("src/api/server.rs");
    for forbidden in [
        "conn.users()",
        "conn.user_grants(",
        "conn.account_model()",
        "conn.create_account_statements(",
        "conn.alter_account_statements(",
        "conn.drop_account_statement(",
    ] {
        assert!(
            !server.contains(forbidden),
            "api/server.rs 仍直接调用 Db 账号方法：{forbidden}"
        );
    }
    assert!(
        server.contains("account_admin"),
        "api/server.rs 应通过 DatabaseDriver::account_admin 访问账号能力"
    );
    assert!(source("crates/dbpilot-core/src/account.rs").contains("pub trait AccountAdmin"));
}

#[test]
fn p4_api_does_not_call_db_raw_execution() {
    // P4：api 的文本协议执行（run_raw）改走 ConnectionHandle，server.rs 不再
    // 需要旧门面 Db。
    let server = source("src/api/server.rs");
    assert!(
        !server.contains("admin_db()"),
        "api/server.rs 又用回了 Db 管理连接（应使用 admin_connection()）"
    );
    assert!(
        !server.contains("db_for("),
        "api/server.rs 又用回了 Db 句柄（应使用 connection_for()）"
    );
    assert!(source("crates/dbpilot-core/src/connection.rs").contains("pub async fn run_raw"));
}

#[test]
fn p3_mysql_row_and_exec_live_in_the_mysql_driver() {
    let db = source("crates/dbpilot-core/src/db.rs");
    assert!(!db.contains("MySqlRow"), "db.rs 又出现了 MySqlRow（MySQL 解码应留在 drivers/mysql/row.rs）");
    assert!(!db.contains("MySqlPool"), "db.rs 又出现了 MySqlPool（执行应留在 drivers/mysql/exec.rs）");
    assert!(std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("src/drivers/mysql/exec.rs")
        .exists());
    assert!(std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("src/drivers/mysql/row.rs")
        .exists());
}

#[test]
fn p4_db_rs_is_dialect_neutral_and_has_no_open_todos() {
    // P4 收尾：db.rs 的两条 TODO(P3) 都已兑现——
    // ① 语句切分接上方言能力位（split_statements_for）；② returns_rows 的关键字
    // 表按「跨方言并集」定稿，不再标记为待办。这里防止 TODO 又长回来，也防止
    // 方言化入口被删掉。
    let source = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("crates/dbpilot-core/src/db.rs"),
    )
    .expect("db.rs 必须可读");
    assert!(
        !source.contains("TODO(P3)"),
        "db.rs 又出现了 TODO(P3)：P4 已完成，新的方言差异请通过 DatabaseDialect 表达"
    );
    assert!(
        source.contains("pub fn split_statements_for("),
        "方言化的语句切分入口 split_statements_for 被删掉了"
    );
}

// ------------------------------------------------------ P5/P6.2 结构守卫

#[test]
fn p5_p62_api_files_stop_using_the_legacy_facade() {
    // P5/P5.1/P6/P6.1：这些文件已全部走 ConnectionHandle + DatabaseDriver，
    // 不应再出现旧门面的取值入口或类型名（注释里解释历史不算）。
    for file in [
        "server.rs",
        "query.rs",
        "mod.rs",
        "connections.rs",
        "sqlite.rs",
        "explorer.rs",
        "data_import.rs",
        "sync.rs",
        "backup.rs",
        "export.rs",
    ] {
        let text = without_line_comments(&source(&format!("src/api/{file}")));
        for needle in ["db_for(", "db_for_database(", "admin_db()", "drivers::Db"] {
            assert!(
                !text.contains(needle),
                "api/{file} 仍在用旧门面：{needle}（P5 要求走 connection_for / driver trait）"
            );
        }
    }

    // P6.2：门面的方言分派必须清零，业务方法（DDL/分页/账号/元数据）不得再长回来。
    let facade = without_line_comments(&source("src/drivers/mod.rs"));
    assert!(
        !facade.contains("match self.driver"),
        "Db 门面又出现方言分派：业务逻辑应放在 drivers/ops.rs 或驱动实现里"
    );
    for gone in [
        "pub async fn data(",
        "pub async fn tables(",
        "pub async fn structure(",
        "pub async fn users(",
        "pub async fn objects(",
        "pub fn create_table_statements(",
        "pub async fn drop_object(",
        "pub async fn drop_namespace(",
    ] {
        assert!(
            !facade.contains(gone),
            "门面业务方法又长回来了：{gone}（应放在 DatabaseDriver / ops.rs）"
        );
    }
    // 33 轮：Db 门面已删除，只剩内部的 PoolSession（SqlSession 实现）。
    // 下面这些断言锁定「池类型不外泄 + 只有句柄进入公开签名」。
    assert!(
        !facade.contains("pub struct Db"),
        "Db 门面又被加回来了（应使用 ConnectionHandle + 内部 PoolSession）"
    );
    for kept in [
        "pub(crate) struct PoolSession",
        "impl crate::core::connection::SqlSession for PoolSession",
        "pub fn pooled_handle(",
    ] {
        assert!(facade.contains(kept), "内部会话实现缺少：{kept}");
    }
    // PoolRegistry / state 的公开入口必须直接给句柄，不再包一层 Db。
    let pools = source("src/pools.rs");
    assert!(
        pools.contains("-> AppResult<ConnectionHandle>"),
        "PoolRegistry 应直接返回 ConnectionHandle"
    );
    assert!(
        !pools.contains("-> AppResult<Db>"),
        "PoolRegistry 不应再返回 Db 门面"
    );
    for moved in [
        "pub async fn scan_rows",
        "pub async fn run_sql(",
        "pub async fn run_sql_limited(",
    ] {
        assert!(
            !facade.contains(moved),
            "流式/脚本能力应留在 ConnectionHandle，不应回到门面：{moved}"
        );
    }
    // 34 轮：data 的入参从一长串位置参数改成 paging::DataPage 结构体，
    // 签名里不再有 page/per_page/sorts/filter 四个裸参数。
    let ops = source("crates/dbpilot-core/src/ops.rs");
    assert!(
        ops.contains("pub(crate) async fn data"),
        "drivers/ops.rs 的通用实现被删掉了"
    );
    assert!(
        ops.contains("query: &DataPage<'_>"),
        "ops::data 应接收 paging::DataPage（分页形态收口到纯函数）"
    );
    assert!(
        !ops.contains("SELECT * FROM {}{}{} LIMIT {} OFFSET {}"),
        "分页 SQL 必须由 paging 模块生成，不能又写回 ops.rs"
    );
    assert!(
        source("crates/dbpilot-core/src/paging.rs").contains("pub fn page_plan("),
        "分页纯函数 page_plan 被删掉了（keyset / 延迟关联的唯一实现）"
    );
}

#[test]
fn p7_contract_crate_is_textually_independent_from_drivers() {
    // 33 轮拆 crate 的硬约束：契约层（dbpilot-core）的**代码**里不能再出现
    // crate::drivers / crate::api。注释里解释历史不算（用去注释后的文本判断）。
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("crates/dbpilot-core/src");
    let mut checked = 0usize;
    for entry in std::fs::read_dir(&dir).expect("契约层目录必须存在") {
        let path = entry.expect("可读目录项").path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("rs") {
            continue;
        }
        let text = without_line_comments(
            &std::fs::read_to_string(&path).expect("契约层源文件必须可读"),
        );
        for forbidden in ["crate::drivers", "crate::api", "crate::state", "crate::pools"] {
            assert!(
                !text.contains(forbidden),
                "{} 仍依赖上层模块：{forbidden}（core 只能被依赖，不能反向依赖）",
                path.display()
            );
        }
        checked += 1;
    }
    assert!(checked >= 15, "契约层源文件数量异常：{checked}");

    // 依赖方向由 Cargo 固定：主 crate 必须声明路径依赖，契约层不能依赖主 crate。
    let manifest = source("Cargo.toml");
    assert!(
        manifest.contains("dbpilot-core = { path = \"crates/dbpilot-core\" }"),
        "主 crate 的 Cargo.toml 缺少 dbpilot-core 路径依赖"
    );
    let core_manifest = source("crates/dbpilot-core/Cargo.toml");
    assert!(
        !core_manifest.contains("rust_myadmin"),
        "契约层不能依赖主 crate（依赖方向必须是 api/state/drivers -> core）"
    );
    assert!(
        !core_manifest.contains("mysql") && !core_manifest.contains("postgres"),
        "契约层不能依赖具体驱动"
    );
}

#[test]
fn p7_ops_lives_in_the_contract_crate() {
    // 33 轮：drivers/ops.rs 搬进契约层，core 的默认方法不再引用 drivers。
    assert!(
        !std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("src/drivers/ops.rs")
            .exists(),
        "drivers/ops.rs 又被加回来了（应在 crates/dbpilot-core/src/ops.rs）"
    );
    let ops = source("crates/dbpilot-core/src/ops.rs");
    assert!(ops.contains("pub(crate) async fn data"), "契约层的通用编排被删掉了");
    assert!(
        !ops.contains("super::mysql") && !ops.contains("super::postgres"),
        "ops.rs 又直接调用具体驱动（应通过 DatabaseDialect trait）"
    );
    // 方言 trait 提供建表/改表 SQL 的入口，驱动侧实现。
    let dialect = source("crates/dbpilot-core/src/dialect.rs");
    assert!(dialect.contains("fn create_table_sql("));
    assert!(dialect.contains("fn alter_table_statements("));
}

#[test]
fn state_still_routes_visibility_through_ensure_visible() {
    let source = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/state.rs"),
    )
    .expect("state.rs 必须可读");
    assert!(source.contains("ensure_visible"), "授权边界必须还在 state.rs");
    // explorer 是「按名字打开库/表」的主要入口，必须直接调用边界；sync 的
    // 结构同步也自己命名库。只数全局次数的话，删掉其中一处仍会通过
    // （2026-10-21 独立验证指出守卫过弱）。
    for (file, minimum) in [("explorer.rs", 4usize), ("sync.rs", 1usize), ("mod.rs", 1usize)] {
        let text = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("src/api")
                .join(file),
        )
        .unwrap();
        let calls = text.matches("ensure_visible(").count();
        assert!(
            calls >= minimum,
            "api/{file} 的 ensure_visible 调用点从 {minimum} 掉到 {calls}，授权闸门可能被绕过"
        );
    }
}
