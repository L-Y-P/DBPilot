//! PostgreSQL 的 `DatabaseDriver` 实现。

use async_trait::async_trait;
use serde_json::Value;

use crate::core::connection::{ConnectionConfig, ConnectionHandle};
use crate::core::dialect::DatabaseDialect;
use crate::core::driver::{DatabaseDriver, DriverMetadata};
use crate::error::{AppError, AppResult};

use super::dialect::POSTGRES_DIALECT;

pub static POSTGRES_METADATA: DriverMetadata = DriverMetadata {
    id: "postgres",
    label: "PostgreSQL",
    default_port: Some(5432),
    default_user: "postgres",
    supports_ssh: true,
    file_based: false,
};

#[derive(Clone, Copy, Debug, Default)]
pub struct PostgresDriver;

#[async_trait]
impl DatabaseDriver for PostgresDriver {
    fn metadata(&self) -> &'static DriverMetadata {
        &POSTGRES_METADATA
    }

    fn dialect(&self) -> &dyn DatabaseDialect {
        &POSTGRES_DIALECT
    }

    fn account_admin(&self) -> Option<&'static dyn crate::core::account::AccountAdmin> {
        crate::drivers::account_admin_for(crate::drivers::DriverKind::Postgres)
    }

    fn requires_database(&self) -> bool {
        true
    }

    /// PostgreSQL 实例级连接没有默认库，必须先从 `active_database` 取；
    /// 调用方给的参数是 schema，不参与选择物理库。
    fn resolve_database(
        &self,
        config: &ConnectionConfig,
        _requested: Option<&str>,
        active_database: Option<&str>,
    ) -> AppResult<Option<String>> {
        active_database
            .map(str::to_string)
            .or_else(|| config.database().map(str::to_string))
            .map(Some)
            .ok_or_else(|| AppError::bad("尚未选择数据库"))
    }

    async fn list_namespaces(&self, conn: &ConnectionHandle) -> AppResult<Vec<Value>> {
        super::namespaces(conn).await
    }

    async fn list_instance_databases(&self, conn: &ConnectionHandle) -> AppResult<Vec<Value>> {
        super::databases(conn).await
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
        conn.query_string("SHOW search_path").await.unwrap_or_default()
    }

    async fn server_version(&self, conn: &ConnectionHandle) -> AppResult<String> {
        conn.query_string("SELECT version()").await
    }

    async fn list_all_instance_databases(
        &self,
        conn: &ConnectionHandle,
    ) -> AppResult<Vec<Value>> {
        super::all_databases(conn).await
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

    async fn kill_session(&self, conn: &ConnectionHandle, session_id: i64) -> AppResult<()> {
        let result = conn
            .execute(&format!("SELECT pg_terminate_backend({})", session_id))
            .await;
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
