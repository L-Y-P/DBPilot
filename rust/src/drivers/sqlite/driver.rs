//! SQLite 的 `DatabaseDriver` 实现。

use async_trait::async_trait;
use serde_json::Value;

use crate::core::connection::{ConnectionConfig, ConnectionHandle};
use crate::core::dialect::DatabaseDialect;
use crate::core::driver::{DatabaseDriver, DriverMetadata};
use crate::error::{AppError, AppResult};

use super::dialect::SQLITE_DIALECT;

pub static SQLITE_METADATA: DriverMetadata = DriverMetadata {
    id: "sqlite",
    label: "SQLite",
    default_port: None,
    default_user: "",
    supports_ssh: false,
    file_based: true,
};

#[derive(Clone, Copy, Debug, Default)]
pub struct SqliteDriver;

#[async_trait]
impl DatabaseDriver for SqliteDriver {
    fn metadata(&self) -> &'static DriverMetadata {
        &SQLITE_METADATA
    }

    fn dialect(&self) -> &dyn DatabaseDialect {
        &SQLITE_DIALECT
    }

    /// SQLite 没有账号体系：api 拿不到实现，统一返回「不支持」文案。
    fn account_admin(&self) -> Option<&'static dyn crate::core::account::AccountAdmin> {
        crate::drivers::account_admin_for(crate::drivers::DriverKind::Sqlite)
    }

    /// SQLite 的 `database` 参数是文件路径/附件别名，不选物理库池。
    fn resolve_database(
        &self,
        _config: &ConnectionConfig,
        _requested: Option<&str>,
        _active_database: Option<&str>,
    ) -> AppResult<Option<String>> {
        Ok(None)
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

    async fn current_schema(&self, _conn: &ConnectionHandle) -> String {
        "main".to_string()
    }

    async fn server_version(&self, _conn: &ConnectionHandle) -> AppResult<String> {
        Ok("SQLite (embedded)".to_string())
    }

    async fn list_all_instance_databases(
        &self,
        conn: &ConnectionHandle,
    ) -> AppResult<Vec<Value>> {
        super::namespaces(conn).await
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

    async fn kill_session(&self, _conn: &ConnectionHandle, _session_id: i64) -> AppResult<()> {
        Err(AppError::bad(
            "SQLite 在应用进程内执行查询，没有服务端会话可终止".to_string(),
        ))
    }

    fn list_database_files(&self, folder: &str, max_files: usize, max_depth: usize) -> Vec<String> {
        super::scan_folder(std::path::Path::new(folder), max_files, max_depth)
            .into_iter()
            .map(|path| path.to_string_lossy().to_string())
            .collect()
    }

    fn is_database_file(&self, path: &str) -> bool {
        super::is_sqlite_file(std::path::Path::new(path))
    }

    fn is_readable_database(&self, path: &str) -> bool {
        super::is_readable(std::path::Path::new(path))
    }

    fn same_database_path(&self, a: &str, b: &str) -> bool {
        super::same_path(a, b)
    }

    fn connection_name_for_path(&self, path: &str) -> String {
        super::connection_name(std::path::Path::new(path))
    }

    fn max_attached_databases(&self) -> usize {
        super::MAX_ATTACHED
    }

    fn discover_database(&self, folder: &str) -> Option<String> {
        super::scan_folder(std::path::Path::new(folder), 500, 6)
            .into_iter()
            .find(|file| super::is_readable(file))
            .map(|file| file.to_string_lossy().to_string())
    }

    fn suggest_connection_name(&self, database: &str) -> Option<String> {
        Some(super::connection_name(std::path::Path::new(database)))
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
