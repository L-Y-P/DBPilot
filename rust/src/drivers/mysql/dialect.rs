//! MySQL / MariaDB 方言。
//!
//! 这里集中了 MySQL 特有的 SQL：`information_schema.*`、`SHOW CREATE TABLE`、
//! 反引号标识符、反斜杠转义的字符串字面量。api 层不再出现这些文本。

use crate::core::dialect::{DatabaseDialect, DialectCapability, SqlQuery};
use crate::db::quote_ident;
use crate::drivers::{quote_str_for, AlterTableSpec, CreateTableSpec, DriverKind};
use crate::error::AppResult;

pub static MYSQL_DIALECT: MySqlDialect = MySqlDialect;

#[derive(Clone, Copy, Debug, Default)]
pub struct MySqlDialect;

impl DatabaseDialect for MySqlDialect {
    fn driver_id(&self) -> &'static str {
        "mysql"
    }

    fn quote_ident(&self, name: &str) -> String {
        quote_ident(name)
    }

    fn quote_string(&self, value: &str) -> String {
        // MySQL 默认把反斜杠当转义符，这里的实现与连接池的
        // NO_BACKSLASH_ESCAPES 清理保持一致（见 drivers::connect_via）。
        quote_str_for(DriverKind::Mysql, value)
    }

    fn list_databases_sql(&self) -> SqlQuery {
        SqlQuery::new(
            "SELECT SCHEMA_NAME AS name, DEFAULT_CHARACTER_SET_NAME AS charset, \
             DEFAULT_COLLATION_NAME AS collation FROM information_schema.SCHEMATA \
             ORDER BY SCHEMA_NAME",
        )
    }

    fn list_schemas_sql(&self) -> SqlQuery {
        // MySQL 的 schema 就是 database。
        self.list_databases_sql()
    }

    fn list_tables_sql(&self, namespace: &str) -> SqlQuery {
        SqlQuery::new(format!(
            "SELECT TABLE_NAME AS name, TABLE_TYPE AS type, ENGINE AS engine, \
             TABLE_ROWS AS row_count, DATA_LENGTH AS data_length, \
             INDEX_LENGTH AS index_length, TABLE_COLLATION AS collation, \
             TABLE_COMMENT AS comment, CREATE_TIME AS created, UPDATE_TIME AS updated \
             FROM information_schema.TABLES WHERE TABLE_SCHEMA = {} ORDER BY TABLE_NAME",
            self.quote_string(namespace)
        ))
    }

    fn list_columns_sql(&self, namespace: &str, table: &str) -> SqlQuery {
        SqlQuery::new(format!(
            "SELECT COLUMN_NAME, COLUMN_TYPE, DATA_TYPE, IS_NULLABLE, COLUMN_DEFAULT, \
             COLUMN_KEY, EXTRA, COLUMN_COMMENT, CHARACTER_SET_NAME, COLLATION_NAME, \
             ORDINAL_POSITION, NUMERIC_PRECISION, NUMERIC_SCALE \
             FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = {} AND TABLE_NAME = {} \
             ORDER BY ORDINAL_POSITION",
            self.quote_string(namespace),
            self.quote_string(table)
        ))
    }

    fn table_kind_sql(&self, namespace: &str, table: &str) -> SqlQuery {
        SqlQuery::new(format!(
            "SELECT TABLE_TYPE AS kind FROM information_schema.TABLES \
             WHERE TABLE_SCHEMA = {} AND TABLE_NAME = {}",
            self.quote_string(namespace),
            self.quote_string(table)
        ))
    }

    fn show_create_table_sql(&self, namespace: &str, table: &str) -> AppResult<SqlQuery> {
        Ok(SqlQuery::new(format!(
            "SHOW CREATE TABLE {}",
            self.qualify(namespace, table)
        )))
    }

    fn current_schema_sql(&self) -> Option<&'static str> {
        Some("SELECT DATABASE()")
    }

    fn list_processes_sql(&self) -> Option<SqlQuery> {
        Some(SqlQuery::new("SHOW FULL PROCESSLIST"))
    }

    /// P2-4：按取消令牌（SQL 注释里的 /*rma_cancel:<token>*/）定位连接。
    fn find_session_ids_sql(&self, pattern: &str) -> Option<SqlQuery> {
        Some(SqlQuery::new(format!(
            "SELECT ID AS id FROM information_schema.PROCESSLIST \
             WHERE ID <> CONNECTION_ID() AND INFO LIKE {}",
            self.quote_string(pattern)
        )))
    }

    fn kill_session_sql(&self, session_id: i64) -> Option<SqlQuery> {
        Some(SqlQuery::new(format!("KILL CONNECTION {session_id}")))
    }

    /// MySQL 的 KILL 会杀掉整条连接：取消后必须重建连接。
    fn reconnect_after_cancel(&self) -> bool {
        true
    }

    fn cancel_message(&self) -> &'static str {
        "查询已取消（执行中的连接已被中断，下一次查询会自动重连）"
    }

    fn database_ddl_keywords(&self) -> &'static [&'static str] {
        // MySQL 同时接受 DATABASE 和 SCHEMA。
        &["DATABASE", "SCHEMA"]
    }

    fn protected_databases(&self) -> &'static [&'static str] {
        &["information_schema", "performance_schema", "mysql", "sys"]
    }

    fn status_privilege_hint(&self) -> &'static str {
        "PROCESS 或 SHOW DATABASES"
    }

    fn process_privilege_hint(&self) -> &'static str {
        "PROCESS"
    }

    fn kill_privilege_hint(&self) -> &'static str {
        "CONNECTION_ADMIN 或 PROCESS"
    }

    fn account_privilege_hint(&self) -> &'static str {
        "SELECT ON mysql.user（通常随 SELECT ON *.* 授予）"
    }

    fn supports_delimiter_directive(&self) -> bool {
        true
    }

    fn namespaces_are_databases(&self) -> bool {
        true
    }

    // ------------------------------------------------ DDL 文本（33 轮拆 crate）
    //
    // 建表/改表 SQL 由驱动拥有；drivers::ops 通过方言 trait 回调到这里，
    // 契约层（dbpilot_core）不再认识具体驱动模块。
    fn create_table_sql(&self, ns: &str, spec: &CreateTableSpec) -> AppResult<String> {
        super::create_table_sql(DriverKind::Mysql, ns, spec)
    }

    fn alter_table_statements(
        &self,
        ns: &str,
        table: &str,
        spec: &AlterTableSpec,
    ) -> AppResult<Vec<String>> {
        super::alter_table_statements(DriverKind::Mysql, ns, table, spec)
    }

    fn supports(&self, capability: DialectCapability) -> bool {
        matches!(
            capability,
            DialectCapability::Databases
                | DialectCapability::CreateDatabase
                | DialectCapability::DropDatabase
                | DialectCapability::Explain
                | DialectCapability::ProcessList
                | DialectCapability::KillSession
                | DialectCapability::UserManagement
                | DialectCapability::UseStatement
                | DialectCapability::ShowCreateTable
                | DialectCapability::GrantScopes
        )
    }
}
