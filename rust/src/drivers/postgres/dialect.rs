//! PostgreSQL 方言。
//!
//! 集中 `pg_database` / `pg_namespace` / `information_schema` 查询与
//! 双引号标识符规则；`TRUE/FALSE`、`decode(hex, 'hex')` 等字面量差异也在
//! 这里覆盖。

use crate::core::dialect::{DatabaseDialect, DialectCapability, SqlQuery};
use crate::drivers::{qi, quote_str_for, AlterTableSpec, CreateTableSpec, DriverKind};
use crate::error::AppResult;

pub static POSTGRES_DIALECT: PostgresDialect = PostgresDialect;

#[derive(Clone, Copy, Debug, Default)]
pub struct PostgresDialect;

impl DatabaseDialect for PostgresDialect {
    fn driver_id(&self) -> &'static str {
        "postgres"
    }

    fn quote_ident(&self, name: &str) -> String {
        qi(DriverKind::Postgres, name)
    }

    fn quote_string(&self, value: &str) -> String {
        quote_str_for(DriverKind::Postgres, value)
    }

    fn bool_literal(&self, value: bool) -> &'static str {
        if value {
            "TRUE"
        } else {
            "FALSE"
        }
    }

    fn binary_literal(&self, hex: &str) -> String {
        format!("decode('{}', 'hex')", hex)
    }

    fn list_databases_sql(&self) -> SqlQuery {
        SqlQuery::new(
            "SELECT datname AS \"name\", pg_encoding_to_char(encoding) AS \"charset\", \
             datcollate AS \"collation\", pg_get_userbyid(datdba) AS \"owner\", \
             datallowconn AS \"allow_conn\", true AS \"can_connect\" \
             FROM pg_database WHERE NOT datistemplate \
             AND has_database_privilege(datname, 'CONNECT') ORDER BY datname",
        )
    }

    fn list_schemas_sql(&self) -> SqlQuery {
        SqlQuery::new(
            "SELECT n.nspname AS \"name\", NULL AS \"charset\", NULL AS \"collation\" \
             FROM pg_namespace n \
             WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast') \
               AND n.nspname NOT LIKE 'pg_temp_%' \
               AND n.nspname NOT LIKE 'pg_toast_temp_%' \
               AND (n.nspname = 'information_schema' OR has_schema_privilege(n.oid, 'USAGE')) \
             ORDER BY n.nspname",
        )
    }

    fn list_tables_sql(&self, namespace: &str) -> SqlQuery {
        SqlQuery::new(format!(
            "SELECT t.table_name AS \"name\", CASE t.table_type WHEN 'VIEW' THEN 'VIEW' \
             ELSE 'BASE TABLE' END AS \"type\", NULL AS \"engine\", \
             COALESCE(s.n_live_tup, 0) AS \"row_count\", \
             pg_total_relation_size(c.oid) AS \"data_length\", 0 AS \"index_length\", \
             NULL AS \"collation\", COALESCE(obj_description(c.oid, 'pg_class'), '') AS \"comment\", \
             NULL AS \"created\", NULL AS \"updated\", \
             COALESCE(ts.spcname, (SELECT spcname FROM pg_tablespace WHERE oid = \
               (SELECT dattablespace FROM pg_database WHERE datname = current_database()))) AS \"tablespace\", \
             CASE WHEN c.relpersistence = 'u' THEN 'YES' ELSE 'NO' END AS \"unlogged\" \
             FROM information_schema.tables t \
             JOIN pg_class c ON c.relname = t.table_name \
             JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = t.table_schema \
             LEFT JOIN pg_tablespace ts ON ts.oid = c.reltablespace \
             LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid \
             WHERE t.table_schema = {} ORDER BY t.table_name",
            self.quote_string(namespace)
        ))
    }

    fn list_columns_sql(&self, namespace: &str, table: &str) -> SqlQuery {
        SqlQuery::new(format!(
            "SELECT c.column_name AS \"COLUMN_NAME\", c.data_type AS \"DATA_TYPE\", \
             CASE WHEN c.character_maximum_length IS NOT NULL \
                  THEN c.data_type || '(' || c.character_maximum_length || ')' \
                  WHEN c.data_type = 'numeric' AND c.numeric_precision IS NOT NULL \
                  THEN c.data_type || '(' || c.numeric_precision || ',' || COALESCE(c.numeric_scale, 0) || ')' \
                  ELSE c.data_type END AS \"COLUMN_TYPE\", \
             c.is_nullable AS \"IS_NULLABLE\", c.column_default AS \"COLUMN_DEFAULT\", \
             c.character_set_name AS \"CHARACTER_SET_NAME\", \
             COALESCE(c.collation_name, CASE WHEN c.data_type IN \
               ('character varying', 'character', 'text', 'name') \
               THEN (SELECT datcollate FROM pg_database WHERE datname = current_database()) END) AS \"COLLATION_NAME\", \
             c.ordinal_position AS \"ORDINAL_POSITION\", c.numeric_precision AS \"NUMERIC_PRECISION\", \
             c.numeric_scale AS \"NUMERIC_SCALE\", \
             COALESCE((SELECT col_description(pc.oid, c.ordinal_position) FROM pg_class pc \
               JOIN pg_namespace pn ON pn.oid = pc.relnamespace \
               WHERE pn.nspname = c.table_schema AND pc.relname = c.table_name), '') AS \"COLUMN_COMMENT\", \
             c.is_identity AS \"IS_IDENTITY\" \
             FROM information_schema.columns c WHERE c.table_schema = {} AND c.table_name = {} \
             ORDER BY c.ordinal_position",
            self.quote_string(namespace),
            self.quote_string(table)
        ))
    }

    fn table_kind_sql(&self, namespace: &str, table: &str) -> SqlQuery {
        SqlQuery::new(format!(
            "SELECT table_type AS \"kind\" FROM information_schema.tables \
             WHERE table_schema = {} AND table_name = {}",
            self.quote_string(namespace),
            self.quote_string(table)
        ))
    }

    fn current_schema_sql(&self) -> Option<&'static str> {
        Some("SHOW search_path")
    }

    fn protected_databases(&self) -> &'static [&'static str] {
        &[
            "pg_catalog",
            "pg_toast",
            "template0",
            "template1",
            "postgres",
        ]
    }

    fn protected_schemas(&self) -> &'static [&'static str] {
        &["information_schema", "pg_catalog", "pg_toast"]
    }

    fn protected_database_prefixes(&self) -> &'static [&'static str] {
        &["pg_temp_", "pg_toast_temp_"]
    }

    fn protected_schema_prefixes(&self) -> &'static [&'static str] {
        &["pg_temp_", "pg_toast_temp_"]
    }

    fn status_privilege_hint(&self) -> &'static str {
        "pg_read_all_stats 角色"
    }

    fn process_privilege_hint(&self) -> &'static str {
        "pg_read_all_stats 角色或超级用户"
    }

    fn kill_privilege_hint(&self) -> &'static str {
        "pg_signal_backend 角色"
    }

    fn account_privilege_hint(&self) -> &'static str {
        "超级用户或 CREATEROLE"
    }

    fn supports_delimiter_directive(&self) -> bool {
        true
    }

    fn supports(&self, capability: DialectCapability) -> bool {
        matches!(
            capability,
            DialectCapability::Databases
                | DialectCapability::Schemas
                | DialectCapability::CreateDatabase
                | DialectCapability::DropDatabase
                | DialectCapability::CreateSchema
                | DialectCapability::Explain
                | DialectCapability::ProcessList
                | DialectCapability::KillSession
                | DialectCapability::UserManagement
        )
    }

    fn list_processes_sql(&self) -> Option<SqlQuery> {
        Some(SqlQuery::new(
            "SELECT pid AS \"Id\", usename AS \"User\", COALESCE(client_addr::text, 'local') AS \"Host\", \
             datname AS \"db\", COALESCE(state, '') AS \"Command\", \
             COALESCE(EXTRACT(EPOCH FROM (now() - query_start))::int, 0) AS \"Time\", \
             COALESCE(wait_event_type, '') AS \"State\", LEFT(COALESCE(query, ''), 200) AS \"Info\" \
             FROM pg_stat_activity ORDER BY pid",
        ))
    }

    /// P2-4：按 SQL 注释里的取消令牌定位 active backend 并取消它。
    fn cancel_backend_sql(&self, pattern: &str) -> Option<SqlQuery> {
        Some(SqlQuery::new(format!(
            "SELECT pg_cancel_backend(pid) AS cancelled FROM pg_stat_activity \
             WHERE pid <> pg_backend_pid() AND state = 'active' AND query LIKE {}",
            self.quote_string(pattern)
        )))
    }

    fn cancel_message(&self) -> &'static str {
        "查询已取消（当前语句已回滚，连接可以继续使用）"
    }

    fn database_ddl_keywords(&self) -> &'static [&'static str] {
        // PostgreSQL 的 DROP SCHEMA 是库内 schema，不能触发库级池失效。
        &["DATABASE"]
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

    fn use_statement_hint(&self) -> &'static str {
        "PostgreSQL 没有 USE 语句：请使用上方数据库选择器，或用 SET search_path TO <模式> 切换默认模式"
    }
}
