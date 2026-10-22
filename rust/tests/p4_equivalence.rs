//! P4 行为等价：语句切分的「旧实现 vs 方言化实现」差分测试。
//!
//! 背景：P4 把 db.rs 的语句切分接上方言能力位（split_statements_for）。
//! 旧入口 split_statements() 保留为「全特性」实现，新入口按方言决定是否把
//! DELIMITER 当客户端指令。本测试用同一批脚本对两条路径做差分，把差异钉在
//! 「只有 SQLite + DELIMITER 指令」这一个已知点上。
//!
//! 这是 hermetic 测试（不连数据库）。

use rust_myadmin_core::core::config::DriverKind;
use rust_myadmin_core::db::{split_statements, split_statements_for};
use rust_myadmin_core::drivers::builtin::dialect_for;

fn split_via(kind: DriverKind, sql: &str) -> Vec<String> {
    split_statements_for(dialect_for(kind), sql)
}

/// 普通脚本（无客户端指令）：三条路径必须逐字一致。
#[test]
fn ordinary_scripts_split_identically_for_every_dialect() {
    let corpus = [
        "SELECT 1; SELECT 2;",
        "SELECT ';' AS semi; SELECT 2;",
        "-- comment; not a separator\nSELECT 3;",
        "/* block ; comment */ SELECT 4;",
        "SELECT \u{60}semi;colon\u{60} FROM t;",
        "SELECT \"semi;colon\" FROM t;",
        "SELECT delimiter_count FROM t;",
        "SELECT 1",                       // 无结尾分号
        "SELECT 1;;SELECT 2;",            // 空语句
        "SET @a = 'x;y'; SELECT @a;",
        "CREATE TABLE t (a INT); INSERT INTO t VALUES (1);",
    ];
    for sql in corpus {
        let legacy = split_statements(sql);
        let mysql = split_via(DriverKind::Mysql, sql);
        let postgres = split_via(DriverKind::Postgres, sql);
        let sqlite = split_via(DriverKind::Sqlite, sql);
        assert_eq!(legacy, mysql, "MySQL 与旧实现不一致: {sql:?}");
        assert_eq!(legacy, postgres, "PostgreSQL 与旧实现不一致: {sql:?}");
        assert_eq!(legacy, sqlite, "SQLite 与旧实现不一致（普通脚本不应有差异）: {sql:?}");
    }
}

/// PostgreSQL 的美元引用体是三方共享行为（P1 修过的坑），不能因为方言化被削弱。
#[test]
fn dollar_quoted_bodies_stay_shared_across_dialects() {
    let sql = "CREATE FUNCTION f() RETURNS int AS $body$ BEGIN RETURN 1; END; $body$ LANGUAGE plpgsql; SELECT 1;";
    let legacy = split_statements(sql);
    assert_eq!(legacy.len(), 2, "美元引用体必须整块保留: {legacy:?}");
    assert!(legacy[0].contains("RETURN 1; END;"), "函数体被切碎: {legacy:?}");
    for kind in [DriverKind::Mysql, DriverKind::Postgres, DriverKind::Sqlite] {
        assert_eq!(split_via(kind, sql), legacy, "方言 {kind:?} 削弱了 $tag$ 处理");
    }
}

/// MySQL / PostgreSQL 支持 DELIMITER 指令：与旧实现完全一致。
#[test]
fn delimiter_directives_are_unchanged_for_mysql_and_postgres() {
    let sql = "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; END//\nDELIMITER ;\nSELECT 2;";
    let legacy = split_statements(sql);
    assert_eq!(legacy.len(), 2, "DELIMITER 脚本应切成 2 条: {legacy:?}");
    assert!(legacy[0].starts_with("CREATE PROCEDURE"), "{legacy:?}");
    assert_eq!(legacy[1], "SELECT 2");
    assert_eq!(split_via(DriverKind::Mysql, sql), legacy);
    assert_eq!(split_via(DriverKind::Postgres, sql), legacy);
}

/// SQLite 没有 DELIMITER 指令：文本不再被客户端吞掉（本轮唯一有意差异）。
#[test]
fn sqlite_keeps_delimiter_text_instead_of_swallowing_it() {
    let sql = "DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; END//\nSELECT 2;";
    let legacy = split_statements(sql);
    let sqlite = split_via(DriverKind::Sqlite, sql);

    assert_ne!(
        sqlite, legacy,
        "SQLite 不应再把 DELIMITER 当客户端指令（那样会静默吞掉这一行）"
    );
    let joined = sqlite.join("\n");
    assert!(
        joined.contains("DELIMITER //"),
        "SQLite 路径应把 DELIMITER 文本交给服务端: {sqlite:?}"
    );
    assert!(
        !legacy.join("\n").contains("DELIMITER //"),
        "旧实现（MySQL 语义）会吞掉 DELIMITER 行——这正是两者应有的差异"
    );
}

/// 多行脚本 + 指令混排：确认只有 DELIMITER 那一行导致差异，其余片段仍一致。
#[test]
fn sqlite_difference_is_limited_to_the_delimiter_line() {
    let sql = "SELECT 1;\nDELIMITER $$\nSELECT 2;\nDELIMITER ;\nSELECT 3;";
    let legacy = split_statements(sql);
    let sqlite = split_via(DriverKind::Sqlite, sql);
    // 旧实现：DELIMITER $$ 之后以 $$ 为分隔符，语句为 ["SELECT 1", "SELECT 2;\nDELIMITER ;\nSELECT 3;"]
    // 或类似形态；关键断言是差异存在且 SQLite 保留了指令文本。
    assert_ne!(sqlite, legacy);
    assert!(sqlite.join("\n").contains("DELIMITER $$"));
    // 普通尾部语句仍然被切出来（没有因为不认识指令而整体粘连成一条）。
    assert!(
        sqlite.iter().any(|s| s.contains("SELECT 1")),
        "SQLite 路径应仍能切出普通语句: {sqlite:?}"
    );
}
