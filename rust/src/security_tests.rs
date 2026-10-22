//! Regression tests for the security fixes applied during the desktop port.
//!
//! Each test pins one previously exploitable behaviour so it cannot silently
//! regress: the web build interpolated several designer fields straight into
//! DDL, and the object editor executed every statement after a CREATE prefix.

use crate::drivers::{
    create_database_sql, safe_default, safe_ident, safe_type, AlterColumn,
    CreateTableSpec, ColumnDef, DriverKind,
};

fn column(name: &str, ty: &str, default: Option<&str>) -> ColumnDef {
    ColumnDef {
        name: name.to_string(),
        col_type: ty.to_string(),
        nullable: true,
        default: default.map(|s| s.to_string()),
        auto_increment: false,
        primary: false,
        comment: None,
        charset: None,
        collation: None,
    }
}

#[test]
fn safe_default_accepts_real_defaults() {
    for value in ["0", "1.5", "NULL", "CURRENT_TIMESTAMP", "'text'", "'a b'", "(1 + 2)"] {
        assert!(safe_default(value).is_ok(), "rejected {value}");
    }
}

#[test]
fn safe_default_rejects_statement_injection() {
    // Every one of these could terminate the column definition and append SQL.
    for value in [
        "0); DROP TABLE users; --",
        "0; DROP TABLE users",
        "1 -- comment",
        "1 /* comment */",
        "0 # comment",
        "'unterminated",
    ] {
        assert!(safe_default(value).is_err(), "accepted {value}");
    }
}

#[test]
fn safe_default_rejects_empty() {
    assert!(safe_default("   ").is_err());
}

#[test]
fn mysql_create_table_rejects_injected_default() {
    let spec = CreateTableSpec {
        name: "t".to_string(),
        columns: vec![column("c", "INT", Some("0); DROP TABLE users; --"))],
        engine: None,
        charset: None,
        collation: None,
        row_format: None,
        auto_increment: None,
        comment: None,
        unlogged: None,
        tablespace: None,
        without_rowid: None,
        strict: None,
        foreign_keys: Vec::new(),
    };
    let result = crate::drivers::mysql::create_table_sql(DriverKind::Mysql, "db", &spec);
    assert!(result.is_err(), "injected default was accepted: {result:?}");
}

#[test]
fn ddl_builders_reject_default_clause_injection() {
    for value in ["0, evil INT", "0), KEY idx (c", "0 NOT NULL", "(1) UNIQUE", "CURRENT_TIMESTAMP(0) ON UPDATE CURRENT_TIMESTAMP"] {
        let spec: CreateTableSpec = serde_json::from_value(serde_json::json!({
            "name": "t", "columns": [{"name": "c", "type": "INT", "default": value}]
        })).unwrap();
        assert!(crate::drivers::mysql::create_table_sql(DriverKind::Mysql, "db", &spec).is_err(), "MySQL accepted {value}");
        assert!(crate::drivers::postgres::create_table_sql("public", &spec).is_err(), "Postgres accepted {value}");
        assert!(crate::drivers::sqlite::create_table_sql("main", &spec).is_err(), "SQLite accepted {value}");
        let alter: crate::drivers::AlterTableSpec = serde_json::from_value(serde_json::json!({
            "add_columns": [{"name": "c", "type": "INT", "default": value}]
        })).unwrap();
        assert!(crate::drivers::mysql::alter_table_statements(DriverKind::Mysql, "db", "t", &alter).is_err());
        assert!(crate::drivers::postgres::alter_table_statements("public", "t", &alter).is_err());
        assert!(crate::drivers::sqlite::alter_table_statements("main", "t", &alter).is_err());
    }
}

#[test]
fn mysql_alter_rejects_injected_charset_and_engine() {
    let mut spec = crate::drivers::AlterTableSpec::default();
    spec.add_columns.push(AlterColumn {
        name: "c".to_string(),
        col_type: "INT".to_string(),
        nullable: true,
        default: None,
        auto_increment: false,
        comment: None,
        charset: Some("utf8mb4; DROP TABLE users; --".to_string()),
        collation: None,
    });
    assert!(crate::drivers::mysql::alter_table_statements(DriverKind::Mysql, "db", "t", &spec).is_err());

    let mut spec2 = crate::drivers::AlterTableSpec::default();
    spec2.engine = Some("InnoDB; DROP TABLE users".to_string());
    assert!(crate::drivers::mysql::alter_table_statements(DriverKind::Mysql, "db", "t", &spec2).is_err());
}

#[test]
fn sqlite_create_table_rejects_injected_default() {
    let spec = CreateTableSpec {
        name: "t".to_string(),
        columns: vec![column("c", "TEXT", Some("x'); DROP TABLE users; --"))],
        engine: None,
        charset: None,
        collation: None,
        row_format: None,
        auto_increment: None,
        comment: None,
        unlogged: None,
        tablespace: None,
        without_rowid: None,
        strict: None,
        foreign_keys: Vec::new(),
    };
    assert!(crate::drivers::sqlite::create_table_sql("db", &spec).is_err());
}

#[test]
fn postgres_create_table_rejects_injected_default() {
    let spec = CreateTableSpec {
        name: "t".to_string(),
        columns: vec![column("c", "INT", Some("0); DROP TABLE users; --"))],
        engine: None,
        charset: None,
        collation: None,
        row_format: None,
        auto_increment: None,
        comment: None,
        unlogged: None,
        tablespace: None,
        without_rowid: None,
        strict: None,
        foreign_keys: Vec::new(),
    };
    assert!(crate::drivers::postgres::create_table_sql("db", &spec).is_err());
}

#[test]
fn safe_ident_still_rejects_quotes() {
    assert!(safe_ident("utf8mb4").is_ok());
    assert!(safe_ident("utf8mb4; DROP").is_err());
    assert!(safe_ident("a`b").is_err());
}

#[test]
fn safe_type_allows_parameterised_types_only() {
    assert!(safe_type("VARCHAR(255)"));
    assert!(safe_type("DECIMAL(10, 2)"));
    // Types the app itself offers. ENUM used to be rejected, so the designer
    // and structure sync could not create any table that had one.
    assert!(safe_type("ENUM('a','b')"));
    assert!(safe_type("int[]"));
    assert!(safe_type("character varying(255)"));
    assert!(safe_type("timestamp with time zone"));
    assert!(!safe_type("INT; DROP TABLE t"));
    assert!(!safe_type("INT) --"));
    assert!(!safe_type("INT) DROP TABLE t"));
    assert!(!safe_type("ENUM('a'"));
    assert!(!safe_type(""));
}

#[test]
fn create_database_options_are_quoted() {
    let sql = create_database_sql(
        DriverKind::Postgres,
        "app",
        None,
        Some("en_US.UTF-8"),
        Some("template1"),
        Some("UTF8"),
        Some("app_role"),
        Some("fast_disk"),
    )
    .expect("valid create database");
    assert!(sql.starts_with("CREATE DATABASE \"app\" WITH "));
    assert!(sql.contains("TEMPLATE \"template1\""));
    assert!(sql.contains("ENCODING 'UTF8'"));
    assert!(sql.contains("LC_COLLATE 'en_US.UTF-8'"));
    assert!(sql.contains("OWNER \"app_role\""));
    assert!(sql.contains("TABLESPACE \"fast_disk\""));

    // Encoding is a string literal: a quote is escaped, not a second statement.
    let escaped = create_database_sql(
        DriverKind::Postgres,
        "app",
        None,
        None,
        None,
        Some("UTF8'; DROP DATABASE postgres; --"),
        None,
        None,
    )
    .expect("encoding is quoted");
    assert!(escaped.contains("ENCODING 'UTF8''; DROP DATABASE postgres; --'"));

    // Identifier-valued options are quoted: special characters and Unicode are
    // legal role/table-space/database names, while a semicolon stays inside the
    // quoted identifier instead of starting a second statement.
    let special = create_database_sql(
        DriverKind::Postgres,
        "app",
        None,
        None,
        Some("template1; DROP DATABASE postgres"),
        None,
        Some("app-role"),
        Some("fast disk"),
    )
    .expect("identifiers are quoted");
    assert!(special.contains("TEMPLATE \"template1; DROP DATABASE postgres\""));
    assert!(special.contains("OWNER \"app-role\""));
    assert!(special.contains("TABLESPACE \"fast disk\""));
    assert_eq!(special.matches("CREATE DATABASE").count(), 1);

    let unicode = create_database_sql(
        DriverKind::Postgres,
        "应用库",
        None,
        None,
        Some("模板库"),
        None,
        Some("应用-属主"),
        None,
    )
    .expect("Unicode identifiers are quoted");
    assert!(unicode.starts_with("CREATE DATABASE \"应用库\""));
    assert!(unicode.contains("OWNER \"应用-属主\""));
}

#[test]
fn statement_splitter_handles_quotes_and_delimiters() {
    let statements = crate::db::split_statements("SELECT 1; SELECT 'a;b';");
    assert_eq!(statements.len(), 2);
    assert_eq!(statements[1], "SELECT 'a;b'");

    let delimited = crate::db::split_statements("DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; END//\n");
    assert_eq!(delimited.len(), 1);
    assert!(delimited[0].contains("CREATE PROCEDURE"));
}

#[test]
fn statement_splitter_keeps_postgres_dollar_quoted_bodies_whole() {
    // P1 (round 29): a pg_dump-style function body must not be split on the
    // semicolons inside `$$ ... $$`.
    let sql = "CREATE FUNCTION f() RETURNS void AS $$ BEGIN PERFORM 1; PERFORM 2; END $$ LANGUAGE plpgsql; SELECT 1;";
    let statements = crate::db::split_statements(sql);
    assert_eq!(statements.len(), 2, "{statements:?}");
    assert!(statements[0].contains("PERFORM 2;"), "{}", statements[0]);
    assert!(statements[0].ends_with("LANGUAGE plpgsql"), "{}", statements[0]);
    assert_eq!(statements[1], "SELECT 1");

    // Named tags with quotes inside stay whole too.
    let tagged =
        "CREATE FUNCTION g() RETURNS text AS $body$ SELECT 'a;b'; $body$ LANGUAGE sql;";
    let statements = crate::db::split_statements(tagged);
    assert_eq!(statements.len(), 1, "{statements:?}");
    assert!(statements[0].contains("SELECT 'a;b';"), "{}", statements[0]);

    // A positional parameter is not a dollar quote.
    let parameters = "UPDATE t SET a=$1, b=$2 WHERE id=$3;";
    let statements = crate::db::split_statements(parameters);
    assert_eq!(statements.len(), 1, "{statements:?}");
    assert!(statements[0].contains("$1"));
}

#[test]
fn statement_splitter_keeps_mysql_executable_comments_as_code() {
    // P4 (round 29): mysqldump wraps objects in `/*!NNNNN ... */`; those are
    // statements, not comments.
    let sql = "/*!50001 CREATE VIEW v AS SELECT 1 */;\n/*!40101 SET @a=1 */;\nSELECT 2;";
    let statements = crate::db::split_statements(sql);
    assert_eq!(statements.len(), 3, "{statements:?}");
    assert!(statements[0].starts_with("/*!50001 CREATE VIEW"), "{}", statements[0]);
    assert!(statements[1].starts_with("/*!40101 SET"), "{}", statements[1]);
    assert_eq!(statements[2], "SELECT 2");

    // A mysqldump trigger block uses DELIMITER + executable comments + a body
    // containing semicolons; the block must survive as one statement.
    let trigger = "DELIMITER ;;\n/*!50003 CREATE*/ /*!50017 DEFINER=`root`@`localhost`*/ /*!50003 TRIGGER tr BEFORE INSERT ON t FOR EACH ROW BEGIN SET @x=1; SET @y=2; END */;;\nDELIMITER ;\n";
    let statements = crate::db::split_statements(trigger);
    assert_eq!(statements.len(), 1, "{statements:?}");
    assert!(statements[0].contains("SET @x=1; SET @y=2;"), "{}", statements[0]);
}

#[test]
fn statement_splitter_does_not_mistake_identifiers_for_delimiter_directive() {
    let statements = crate::db::split_statements("SELECT delimiter_count FROM t;");
    assert_eq!(statements.len(), 1, "{statements:?}");
    assert!(statements[0].contains("delimiter_count"));
}

#[test]
fn returns_rows_detects_read_statements() {
    assert!(crate::db::returns_rows("SELECT 1"));
    assert!(crate::db::returns_rows("-- comment\nSHOW TABLES"));
    assert!(!crate::db::returns_rows("INSERT INTO t VALUES (1)"));
}

#[test]
fn name_visible_enforces_only_and_hide_rules() {
    use crate::config::name_visible;
    // No rules means everything is visible.
    assert!(name_visible(None, None, "anything"));
    // only_db restricts to the listed names, with wildcards.
    assert!(name_visible(Some("app%"), None, "app_db"));
    assert!(!name_visible(Some("app%"), None, "other"));
    // hide_db removes matches even when only_db would allow them.
    assert!(!name_visible(Some("app%"), Some("app_secret"), "app_secret"));
    assert!(name_visible(None, Some("tmp%"), "prod"));
    assert!(!name_visible(None, Some("tmp%"), "tmp_x"));
}

#[test]
fn quote_helpers_escape_embedded_quotes() {
    assert_eq!(crate::db::quote_ident("a`b"), "`a``b`");
    assert_eq!(crate::drivers::qi(DriverKind::Postgres, "a\"b"), "\"a\"\"b\"");
    assert_eq!(crate::db::quote_str("a'b"), "'a''b'");
}

#[test]
fn literal_escapes_strings_per_dialect() {
    use serde_json::json;
    assert_eq!(crate::drivers::literal(DriverKind::Mysql, &json!("a'b")), "'a''b'");
    assert_eq!(crate::drivers::literal(DriverKind::Postgres, &json!(true)), "TRUE");
    assert_eq!(crate::drivers::literal(DriverKind::Mysql, &json!(null)), "NULL");
}

#[test]
fn repair_defaults_cannot_append_column_or_alter_clauses() {
    use crate::drivers::{AlterTableSpec, mysql, postgres, sqlite};
    for value in ["0, evil INT", "0), KEY idx (c", "0), CONSTRAINT x FOREIGN KEY (c) REFERENCES t (id", "0 NOT NULL", "(1) NOT NULL", "CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP", "'x' COLLATE evil"] {
        let spec: CreateTableSpec = serde_json::from_value(serde_json::json!({
            "name":"t", "columns":[{"name":"c", "type":"INT", "nullable":true,"default":value}]
        })).unwrap();
        for result in [mysql::create_table_sql(DriverKind::Mysql, "db", &spec), postgres::create_table_sql("db", &spec), sqlite::create_table_sql("main", &spec)] {
            assert!(result.is_err(), "accepted DDL default {value}");
        }
        let mut alter = AlterTableSpec::default();
        alter.add_columns.push(AlterColumn { name:"c".into(), col_type:"INT".into(), nullable:true, default:Some(value.into()), auto_increment:false, comment:None, charset:None, collation:None });
        for result in [mysql::alter_table_statements(DriverKind::Mysql,"db","t",&alter), postgres::alter_table_statements("db","t",&alter), sqlite::alter_table_statements("main","t",&alter)] {
            assert!(result.is_err(), "accepted ALTER default {value}");
        }
    }
}

#[test]
fn repair_defaults_preserve_scalar_expressions() {
    for value in ["-1.2e+3", "CURRENT_TIMESTAMP(6)", "'a,b)'", "'O''Brien'", "(1 + (2 * 3))", "nextval('seq'::regclass)", "'text'::character varying", "(json_object('k', 1))"] {
        assert!(safe_default(value).is_ok(), "rejected {value}");
    }
}

#[test]
fn repair_ssl_disable_wins_over_verification() {
    for driver in [DriverKind::Mysql, DriverKind::Postgres] {
        for verify in ["require", "verify-ca", "verify-full"] {
            let spec = crate::drivers::ConnSpec { driver, ssl_mode:Some("disable".into()), ssl_verify:Some(verify.into()), ..Default::default() };
            assert_eq!(spec.ssl_mode(), "disable");
            if driver == DriverKind::Mysql {
                assert!(matches!(crate::drivers::mysql::ssl_mode_for(&spec), sqlx::mysql::MySqlSslMode::Disabled));
            }
        }
    }
}

// ---------------------------------------------------------------- db errors
//
// The server page used to show sqlx's raw display string, which repeats the
// driver message once as the error and once under "Caused by:". These pin the
// normalisation that the UI relies on.

#[test]
fn strip_caused_by_drops_the_duplicated_tail() {
    let raw = "error returned from database: 1044 (42000): Access denied for user 'web'@'%' to database 'x'\n\nCaused by:\n    1044 (42000): Access denied for user 'web'@'%' to database 'x'";
    let cleaned = crate::error::strip_caused_by(raw);
    assert_eq!(
        cleaned,
        "1044 (42000): Access denied for user 'web'@'%' to database 'x'"
    );
}

#[test]
fn strip_caused_by_keeps_a_plain_message() {
    assert_eq!(crate::error::strip_caused_by("  请先选择一个数据库连接  "), "请先选择一个数据库连接");
    assert_eq!(crate::error::strip_caused_by(""), "数据库返回了一个错误");
}

#[test]
fn permission_hints_cover_the_common_failures() {
    // 1044: the account cannot open the database at all.
    let hint = crate::error::permission_hint_for_test("1044").expect("1044 hint");
    assert!(hint.contains("没有访问该数据库的权限"), "{hint}");
    // 1142: table-level denial, the one in the account tab.
    let hint = crate::error::permission_hint_for_test("1142").expect("1142 hint");
    assert!(hint.contains("表级权限"), "{hint}");
    // Unknown codes stay unexplained rather than inventing advice.
    assert!(crate::error::permission_hint_for_test("9999").is_none());
}

#[test]
fn permission_hints_fall_back_to_the_message_text() {
    // sqlx drops MySQL's numeric prefix from message(), leaving only SQLSTATE,
    // so the wording has to be enough on its own.
    let hint = crate::error::permission_hint_from_message_test(
        "SELECT command denied to user 'web'@'localhost' for table 'user'",
    )
    .expect("message hint");
    assert!(hint.contains("表级权限"), "{hint}");
    assert!(crate::error::permission_hint_from_message_test("Unknown column 'x'").is_none());
}
