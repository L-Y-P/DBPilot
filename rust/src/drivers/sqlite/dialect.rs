//! SQLite 方言。
//!
//! 集中 `sqlite_master` / `PRAGMA` 查询，以及 ATTACH 命名空间的限定规则。
//! SQLite 的「数据库」是文件，命名空间是 `main` / 附件别名。

use crate::core::dialect::{DatabaseDialect, DialectCapability, SqlQuery};
use crate::drivers::{qi, quote_str_for, AlterTableSpec, CreateTableSpec, DriverKind};
use crate::error::{AppError, AppResult};

use super::{master_of, pragma};

pub static SQLITE_DIALECT: SqliteDialect = SqliteDialect;

#[derive(Clone, Copy, Debug, Default)]
pub struct SqliteDialect;

impl DatabaseDialect for SqliteDialect {
    fn driver_id(&self) -> &'static str {
        "sqlite"
    }

    fn quote_ident(&self, name: &str) -> String {
        qi(DriverKind::Sqlite, name)
    }

    fn quote_string(&self, value: &str) -> String {
        quote_str_for(DriverKind::Sqlite, value)
    }

    fn list_databases_sql(&self) -> SqlQuery {
        // 文件列表在驱动层再补 file 字段（PRAGMA 返回的是路径）。
        SqlQuery::new("PRAGMA database_list")
    }

    fn list_schemas_sql(&self) -> SqlQuery {
        self.list_databases_sql()
    }

    fn list_tables_sql(&self, namespace: &str) -> SqlQuery {
        SqlQuery::new(format!(
            "SELECT name AS \"name\", CASE type WHEN 'view' THEN 'VIEW' ELSE 'BASE TABLE' END AS \"type\", \
             NULL AS \"engine\", NULL AS \"row_count\", NULL AS \"data_length\", NULL AS \"index_length\", \
             NULL AS \"collation\", '' AS \"comment\", NULL AS \"created\", NULL AS \"updated\" \
             FROM {} WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name",
            master_of(namespace)
        ))
    }

    fn list_columns_sql(&self, namespace: &str, table: &str) -> SqlQuery {
        SqlQuery::new(pragma(
            namespace,
            "table_info",
            &self.quote_string(table),
        ))
    }

    fn table_kind_sql(&self, namespace: &str, table: &str) -> SqlQuery {
        SqlQuery::new(format!(
            "SELECT type AS kind FROM {} WHERE name = {}",
            master_of(namespace),
            self.quote_string(table)
        ))
    }

    fn show_create_table_sql(&self, namespace: &str, table: &str) -> AppResult<SqlQuery> {
        Ok(SqlQuery::new(format!(
            "SELECT sql AS ddl FROM {} WHERE type IN ('table', 'view') AND name = {}",
            master_of(namespace),
            self.quote_string(table)
        )))
    }

    fn explain_sql(&self, statement: &str) -> String {
        format!("EXPLAIN QUERY PLAN {}", statement.trim())
    }

    fn namespaces_are_databases(&self) -> bool {
        true
    }

    /// SQLite 没有服务器/账号概念：server 管理页跳过权限探测。
    fn supports_server_admin(&self) -> bool {
        false
    }

    fn status_privilege_hint(&self) -> &'static str {
        "SQLite 无服务器权限概念"
    }

    fn process_privilege_hint(&self) -> &'static str {
        "SQLite 无进程列表"
    }

    fn kill_privilege_hint(&self) -> &'static str {
        "SQLite 无服务端会话"
    }

    fn account_privilege_hint(&self) -> &'static str {
        "SQLite 无数据库账号"
    }

    fn max_identifier_len(&self) -> usize {
        255
    }

    // ------------------------------------------------ DDL 文本（33 轮拆 crate）
    fn create_table_sql(&self, ns: &str, spec: &CreateTableSpec) -> AppResult<String> {
        super::create_table_sql(ns, spec)
    }

    fn alter_table_statements(
        &self,
        ns: &str,
        table: &str,
        spec: &AlterTableSpec,
    ) -> AppResult<Vec<String>> {
        super::alter_table_statements(ns, table, spec)
    }

    fn supports(&self, capability: DialectCapability) -> bool {
        matches!(
            capability,
            DialectCapability::Databases
                | DialectCapability::AttachDatabase
                | DialectCapability::Explain
        )
    }

    fn use_statement_hint(&self) -> &'static str {
        "SQLite 没有 USE 语句：附加数据库由连接决定，不能通过 SQL 切换"
    }
}

/// 供驱动实现抛出的统一「SQLite 没有这个对象类型」错误。
pub fn unsupported(message: &str) -> AppError {
    AppError::bad(message.to_string())
}
