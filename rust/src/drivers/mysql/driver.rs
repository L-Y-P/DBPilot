//! MySQL 的 `DatabaseDriver` 实现。
//!
//! 方言 SQL 在 `super::dialect`，具体目录/结构查询在 `super`（原 mysql.rs）。
//! 这里只做「能力 → 实现」的绑定。

use async_trait::async_trait;
use serde_json::Value;

use crate::core::connection::{ConnectionConfig, ConnectionHandle};
use crate::core::dialect::DatabaseDialect;
use crate::core::driver::{DatabaseDriver, DriverMetadata, PoolProvider};
use crate::db::ResultSet;
use crate::error::{AppError, AppResult};

use super::dialect::MYSQL_DIALECT;

pub static MYSQL_METADATA: DriverMetadata = DriverMetadata {
    id: "mysql",
    label: "MySQL / MariaDB",
    default_port: Some(3306),
    default_user: "root",
    supports_ssh: true,
    file_based: false,
};

#[derive(Clone, Copy, Debug, Default)]
pub struct MySqlDriver;

#[async_trait]
impl DatabaseDriver for MySqlDriver {
    fn metadata(&self) -> &'static DriverMetadata {
        &MYSQL_METADATA
    }

    fn dialect(&self) -> &dyn DatabaseDialect {
        &MYSQL_DIALECT
    }

    fn account_admin(&self) -> Option<&'static dyn crate::core::account::AccountAdmin> {
        crate::drivers::account_admin_for(crate::drivers::DriverKind::Mysql)
    }

    async fn connect(
        &self,
        provider: &dyn PoolProvider,
        config: &ConnectionConfig,
        database: Option<&str>,
    ) -> AppResult<ConnectionHandle> {
        provider.pooled(config, database).await
    }

    async fn admin_connect(
        &self,
        provider: &dyn PoolProvider,
        config: &ConnectionConfig,
    ) -> AppResult<(ConnectionHandle, Option<String>)> {
        provider.admin_pooled(config).await
    }

    fn resolve_database(
        &self,
        config: &ConnectionConfig,
        requested: Option<&str>,
        active_database: Option<&str>,
    ) -> AppResult<Option<String>> {
        Ok(requested
            .map(str::to_string)
            .or_else(|| active_database.map(str::to_string))
            .or_else(|| config.database().map(str::to_string)))
    }

    async fn list_namespaces(&self, conn: &ConnectionHandle) -> AppResult<Vec<Value>> {
        super::namespaces(conn).await
    }

    async fn list_instance_databases(&self, conn: &ConnectionHandle) -> AppResult<Vec<Value>> {
        super::namespaces(conn).await
    }

    async fn list_tables(
        &self,
        conn: &ConnectionHandle,
        namespace: &str,
    ) -> AppResult<Vec<Value>> {
        super::tables(conn, namespace).await
    }

    async fn table_structure(
        &self,
        conn: &ConnectionHandle,
        namespace: &str,
        table: &str,
    ) -> AppResult<Value> {
        super::structure(conn, namespace, table).await
    }

    async fn current_schema(&self, conn: &ConnectionHandle) -> String {
        conn.query_string("SELECT DATABASE()")
            .await
            .unwrap_or_default()
    }

    async fn server_version(&self, conn: &ConnectionHandle) -> AppResult<String> {
        conn.query_string("SELECT VERSION() AS v").await
    }

    async fn list_all_instance_databases(
        &self,
        conn: &ConnectionHandle,
    ) -> AppResult<Vec<Value>> {
        super::all_namespaces(conn).await
    }

    async fn server_overview(&self, conn: &ConnectionHandle) -> AppResult<Value> {
        super::overview(conn).await
    }

    async fn variables(
        &self,
        conn: &ConnectionHandle,
        filter: Option<&str>,
    ) -> AppResult<Vec<Value>> {
        super::variables(conn, filter).await
    }

    async fn execute(&self, conn: &ConnectionHandle, sql: &str) -> ResultSet {
        conn.execute(sql).await
    }

    async fn execute_limited(
        &self,
        conn: &ConnectionHandle,
        sql: &str,
        max_rows: usize,
    ) -> (ResultSet, bool) {
        conn.execute_limited(sql, max_rows).await
    }

    async fn kill_session(&self, conn: &ConnectionHandle, session_id: i64) -> AppResult<()> {
        let result = conn.execute(&format!("KILL {}", session_id)).await;
        match result.error {
            Some(error) => Err(AppError::bad(error)),
            None => Ok(()),
        }
    }


    // P5：元数据入口 —— 实现仍在 super（方言 SQL 已在其内部走 dialect）。
    async fn object_kind(&self, conn: &ConnectionHandle, ns: &str, table: &str) -> AppResult<Option<String>> {
        super::object_kind(conn, ns, table).await
    }

    async fn builder_schema(&self, conn: &ConnectionHandle, ns: &str) -> AppResult<Value> {
        super::builder_schema(conn, ns).await
    }

    async fn table_ddl(&self, conn: &ConnectionHandle, ns: &str, table: &str) -> AppResult<Option<String>> {
        super::table_ddl(conn, ns, table).await
    }

    async fn objects(&self, conn: &ConnectionHandle, ns: &str) -> AppResult<Value> {
        super::objects(conn, ns).await
    }

    async fn object_definition(&self, conn: &ConnectionHandle, ns: &str, kind: &str, name: &str) -> AppResult<String> {
        super::object_definition(conn, ns, kind, name).await
    }

    async fn meta_options(&self, conn: &ConnectionHandle) -> AppResult<Value> {
        super::meta_options(conn).await
    }

    fn object_drop_sql(&self, ns: &str, kind: &str, name: &str) -> AppResult<String> {
        super::object_drop_sql(ns, kind, name)
    }
}
