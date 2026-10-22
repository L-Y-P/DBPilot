//! 驱动契约：连接、执行、元数据。
//!
//! `DatabaseDriver` 是 api 唯一认识的能力接口。默认实现直接基于
//! [`ConnectionHandle`] + [`DatabaseDialect`]，驱动只在「方言确实不同」
//! 的地方覆盖（例如 MySQL 要按 GRANT 过滤可浏览库、SQLite 要从
//! `PRAGMA database_list` 拼文件路径）。
//!
//! 连接池与 SSH 隧道**不在驱动里**：驱动只向 [`PoolProvider`] 要一个
//! 池化句柄，生命周期仍由 `pools::PoolRegistry` + `ssh` 管理
//! （对应硬性要求 5）。

use std::fmt;

use async_trait::async_trait;
use serde_json::Value;

use crate::db::ResultSet;
use crate::error::{AppError, AppResult};

use super::account::AccountAdmin;
use super::connection::{ConnectionConfig, ConnectionHandle};
use super::dialect::{DatabaseDialect, DialectCapability};

/// 驱动的静态元信息：给连接表单和 `driver_options` 用。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DriverMetadata {
    pub id: &'static str,
    pub label: &'static str,
    pub default_port: Option<u16>,
    pub default_user: &'static str,
    /// 是否支持 SSH 跳板（SQLite 文件连接不支持）。
    pub supports_ssh: bool,
    /// 是否是本地文件型数据库（SQLite）。
    pub file_based: bool,
}

impl DriverMetadata {
    /// FFI 兼容形态：与重构前 `driver_options()` 的四个字段逐字一致。
    /// **不要**在这里加字段 —— Dart 侧契约不变是硬性要求 2。
    pub fn to_json(self) -> Value {
        serde_json::json!({
            "id": self.id,
            "label": self.label,
            "default_port": self.default_port,
            "default_user": self.default_user,
        })
    }

    /// 内部/诊断用：额外带能力位。
    pub fn to_json_full(self) -> Value {
        serde_json::json!({
            "id": self.id,
            "label": self.label,
            "default_port": self.default_port,
            "default_user": self.default_user,
            "supports_ssh": self.supports_ssh,
            "file_based": self.file_based,
        })
    }
}

/// 连接池供给方：由 `PoolRegistry` 实现。
///
/// 驱动只提交「连接配置 + 物理库名」，拿到一个池化句柄；缓存/LRU/隧道
/// 都由实现方负责，驱动不持有池的生命周期。
#[async_trait]
pub trait PoolProvider: Send + Sync {
    async fn pooled(
        &self,
        config: &ConnectionConfig,
        database: Option<&str>,
    ) -> AppResult<ConnectionHandle>;

    async fn admin_pooled(
        &self,
        config: &ConnectionConfig,
    ) -> AppResult<(ConnectionHandle, Option<String>)>;

    /// 打开一条**被固定**的会话（P3 Step 1）：SQL 控制台整段脚本共用它，
    /// 会话级状态才不会丢。默认没有会话概念的实现可以返回不支持。
    async fn session(
        &self,
        _config: &ConnectionConfig,
        _database: Option<&str>,
    ) -> AppResult<Box<dyn crate::session::SessionHandle>> {
        Err(AppError::Internal(
            "该连接池不支持固定会话".to_string(),
        ))
    }
}

/// 驱动契约。
///
/// * `Send + Sync + Debug`：注册表以 `Arc<dyn DatabaseDriver>` 跨线程共享；
/// * 所有方法都 `&self`：驱动必须是零状态/只读状态，连接状态在句柄里。
#[async_trait]
pub trait DatabaseDriver: Send + Sync + fmt::Debug {
    fn metadata(&self) -> &'static DriverMetadata;

    fn id(&self) -> &'static str {
        self.metadata().id
    }

    fn label(&self) -> &'static str {
        self.metadata().label
    }

    fn default_port(&self) -> Option<u16> {
        self.metadata().default_port
    }

    fn dialect(&self) -> &dyn DatabaseDialect;

    /// 账号管理能力（P3 Step 4）。
    ///
    /// 没有账号体系的驱动（SQLite）返回 None，api 据此给出「不支持」文案，
    /// 不再自己 match DriverKind。驱动是零状态的，实现用 static unit struct，
    /// 所以这里给 `&'static dyn AccountAdmin` 而不是 `Arc`：既不分配，
    /// 也不延长驱动实例的生命周期。
    fn account_admin(&self) -> Option<&'static dyn AccountAdmin> {
        None
    }

    // -------------------------------------------------------------- 能力位

    fn namespaces_are_databases(&self) -> bool {
        self.dialect().namespaces_are_databases()
    }

    fn is_file_based(&self) -> bool {
        self.metadata().file_based
    }

    fn supports(&self, capability: DialectCapability) -> bool {
        self.dialect().supports(capability)
    }

    /// PostgreSQL 连接必须知道物理库（实例级连接没有默认库）。
    fn requires_database(&self) -> bool {
        false
    }

    /// 把「调用方给的命名空间参数 + 当前选中库」解析成一个物理数据库名。
    ///
    /// 这里是 PostgreSQL 与 MySQL 的语义差异所在：PG 的参数是 schema，
    /// 物理库取自 `active_database`；MySQL 的参数就是数据库。
    /// **授权校验仍由 `ActiveConnection::ensure_visible` 在 state 层做**，
    /// 驱动只解析、不授权。
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

    // -------------------------------------------------------------- 连接

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

    /// 打开一条固定会话（P3 Step 1）。默认交给池供给方；驱动可在 P4 覆盖成
    /// 自己更高效的实现（例如直接持有原生连接不动）。
    async fn open_session(
        &self,
        provider: &dyn PoolProvider,
        config: &ConnectionConfig,
        database: Option<&str>,
    ) -> AppResult<Box<dyn crate::session::SessionHandle>> {
        provider.session(config, database).await
    }

    // -------------------------------------------------------------- 执行

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

    async fn query_rows(&self, conn: &ConnectionHandle, sql: &str) -> AppResult<Vec<Value>> {
        conn.query_rows(sql).await
    }

    async fn ping(&self, conn: &ConnectionHandle) -> AppResult<()> {
        let result = conn.execute("SELECT 1").await;
        match result.error {
            Some(error) => Err(AppError::bad(error)),
            None => Ok(()),
        }
    }

    // -------------------------------------------------------------- 元数据

    /// 浏览器左侧「数据库」列表：MySQL 是数据库，PG 是当前库的 schema，
    /// SQLite 是 ATTACH 的文件。
    async fn list_namespaces(&self, conn: &ConnectionHandle) -> AppResult<Vec<Value>> {
        conn.query_rows(&self.dialect().list_databases_sql().sql)
            .await
    }

    /// 实例级物理数据库列表（PG 的 pg_database / MySQL 的 SCHEMATA）。
    async fn list_instance_databases(&self, conn: &ConnectionHandle) -> AppResult<Vec<Value>> {
        conn.query_rows(&self.dialect().list_databases_sql().sql)
            .await
    }

    async fn list_tables(
        &self,
        conn: &ConnectionHandle,
        namespace: &str,
    ) -> AppResult<Vec<Value>> {
        conn.query_rows(&self.dialect().list_tables_sql(namespace).sql)
            .await
    }

    async fn table_structure(
        &self,
        conn: &ConnectionHandle,
        namespace: &str,
        table: &str,
    ) -> AppResult<Value>;

    async fn show_create_table(
        &self,
        conn: &ConnectionHandle,
        namespace: &str,
        table: &str,
    ) -> AppResult<Option<String>> {
        let query = self.dialect().show_create_table_sql(namespace, table)?;
        let result = conn.execute(&query.sql).await;
        if let Some(error) = result.error {
            return Err(AppError::bad(error));
        }
        Ok(result
            .rows
            .first()
            .and_then(|row| row.get(1))
            .and_then(Value::as_str)
            .map(str::to_string))
    }

    /// 当前会话的默认 schema / 数据库。
    async fn current_schema(&self, conn: &ConnectionHandle) -> String {
        match self.dialect().current_schema_sql() {
            Some(sql) => conn.query_string(sql).await.unwrap_or_default(),
            None => String::new(),
        }
    }

    async fn server_version(&self, conn: &ConnectionHandle) -> AppResult<String>;

    /// 实例级**全部**数据库，不做授权过滤。
    ///
    /// 只给管理面用：账号编辑器的 scope 选择器必须能选到连接账号自己不拥有的库；
    /// 浏览用的列表是 list_instance_databases（按 GRANT 过滤）。
    async fn list_all_instance_databases(
        &self,
        conn: &ConnectionHandle,
    ) -> AppResult<Vec<Value>> {
        self.list_instance_databases(conn).await
    }

    /// 服务器状态概览（status 页）。
    async fn server_overview(&self, _conn: &ConnectionHandle) -> AppResult<Value> {
        Err(AppError::bad(format!("{} 没有服务器状态页", self.label())))
    }

    /// 服务器 / 会话变量（variables 页），可按子串过滤。
    async fn variables(
        &self,
        _conn: &ConnectionHandle,
        _filter: Option<&str>,
    ) -> AppResult<Vec<Value>> {
        Err(AppError::bad(format!("{} 没有变量列表", self.label())))
    }

    /// 终止一个会话；不支持的驱动返回明确的用户错误。
    async fn kill_session(&self, _conn: &ConnectionHandle, _session_id: i64) -> AppResult<()> {
        Err(AppError::bad(format!(
            "{} 不支持终止会话",
            self.label()
        )))
    }

    /// 服务器会话列表（P2-4）：SQL 由方言提供，驱动只执行。
    async fn show_processlist(&self, conn: &ConnectionHandle) -> AppResult<Vec<Value>> {
        match self.dialect().list_processes_sql() {
            Some(query) => conn.query_rows(&query.sql).await,
            None => Err(AppError::bad(format!(
                "{} 没有服务器会话列表",
                self.label()
            ))),
        }
    }

    /// 取消当前控制台查询：按令牌模式串找到会话并中断（P2-4）。
    ///
    /// 令牌仍由 api 注入到 SQL 注释里（PostgreSQL 靠它定位 backend，MySQL 靠它
    /// 定位连接），驱动只负责「怎么找、怎么杀」——即方言 SQL 的归属。
    /// 返回被中断的会话数。
    async fn cancel_session_by_token(
        &self,
        conn: &ConnectionHandle,
        pattern: &str,
    ) -> AppResult<usize> {
        let dialect = self.dialect();
        if let Some(query) = dialect.cancel_backend_sql(pattern) {
            let rows = conn.query_rows(&query.sql).await?;
            return Ok(rows
                .iter()
                .filter(|row| row.get("cancelled").and_then(Value::as_bool) == Some(true))
                .count());
        }
        if let Some(find) = dialect.find_session_ids_sql(pattern) {
            let rows = conn.query_rows(&find.sql).await.unwrap_or_default();
            let ids: Vec<i64> = rows
                .iter()
                .filter_map(|row| row.get("id").and_then(Value::as_i64))
                .collect();
            let mut cancelled = 0usize;
            for id in ids {
                if let Some(sql) = dialect.kill_session_sql(id) {
                    let outcome = conn.execute(&sql.sql).await;
                    if outcome.error.is_none() {
                        cancelled += 1;
                    }
                }
            }
            return Ok(cancelled);
        }
        Err(AppError::bad(format!(
            "{} 不支持取消查询",
            self.label()
        )))
    }

    // -------------------------------------------------------------- 文件型驱动

    /// 列出一个目录下的数据库文件（含子目录，带扫描边界）。
    ///
    /// P2-3：api/sqlite.rs 原本直接调用 `drivers::sqlite::scan_folder` 等自由
    /// 函数；收口成文件型驱动的能力方法后，api 不再 import 具体驱动模块。
    fn list_database_files(
        &self,
        _folder: &str,
        _max_files: usize,
        _max_depth: usize,
    ) -> Vec<String> {
        Vec::new()
    }

    /// 路径扩展名看起来像本驱动的数据库文件。
    fn is_database_file(&self, _path: &str) -> bool {
        false
    }

    /// 文件内容是本驱动的有效数据库（SQLite 检查 16 字节 header）。
    fn is_readable_database(&self, _path: &str) -> bool {
        false
    }

    /// 两个路径是否指向同一个文件（解析符号链接 / macOS 的 /private 前缀）。
    fn same_database_path(&self, a: &str, b: &str) -> bool {
        a == b
    }

    /// 文件型数据库的显示名（去掉扩展名）。
    fn connection_name_for_path(&self, path: &str) -> String {
        path.to_string()
    }

    /// 一个连接最多能附加多少个数据库文件。
    fn max_attached_databases(&self) -> usize {
        0
    }

    /// SQLite：在一个目录里找第一个可读数据库文件。
    fn discover_database(&self, _folder: &str) -> Option<String> {
        None
    }

    /// SQLite：给连接起一个默认名字（文件名去掉扩展名）。
    fn suggest_connection_name(&self, _database: &str) -> Option<String> {
        None
    }

    // ------------------------------------------------ 驱动族（P5：门面通用操作）

    /// 驱动族（core::config::DriverKind）。只用于 filter 解析等仍以 DriverKind
    /// 为参数的既有 API；新代码优先用能力位。
    fn kind(&self) -> crate::config::DriverKind {
        match self.id() {
            "mysql" => crate::config::DriverKind::Mysql,
            "postgres" => crate::config::DriverKind::Postgres,
            _ => crate::config::DriverKind::Sqlite,
        }
    }

    // ---------------------------------------------------------------- 元数据

    /// 对象类型（TABLE / VIEW ...）；各驱动用自己的目录查询。
    async fn object_kind(
        &self,
        _conn: &ConnectionHandle,
        _namespace: &str,
        _table: &str,
    ) -> AppResult<Option<String>> {
        Err(AppError::bad(format!("{} 没有对象类型查询", self.label())))
    }

    /// 图形查询构建器需要的表 + 列 + 外键结构。
    async fn builder_schema(
        &self,
        _conn: &ConnectionHandle,
        _namespace: &str,
    ) -> AppResult<Value> {
        Err(AppError::bad(format!("{} 没有查询构建器元数据", self.label())))
    }

    /// 建表 DDL（原生 SHOW CREATE 或等价物）。
    async fn table_ddl(
        &self,
        _conn: &ConnectionHandle,
        _namespace: &str,
        _table: &str,
    ) -> AppResult<Option<String>> {
        Err(AppError::bad(format!("{} 没有建表 DDL", self.label())))
    }

    /// 视图 / 存储过程 / 触发器 / 事件列表。
    async fn objects(&self, _conn: &ConnectionHandle, _namespace: &str) -> AppResult<Value> {
        Err(AppError::bad(format!("{} 没有对象列表", self.label())))
    }

    /// 一个对象的 CREATE 语句（定义查看器）。
    async fn object_definition(
        &self,
        _conn: &ConnectionHandle,
        _namespace: &str,
        _kind: &str,
        _name: &str,
    ) -> AppResult<String> {
        Err(AppError::bad(format!("{} 不支持查看对象定义", self.label())))
    }

    /// 字符集 / 排序规则 / 存储引擎 / 行格式（设计器下拉）。
    async fn meta_options(&self, _conn: &ConnectionHandle) -> AppResult<Value> {
        Err(AppError::bad(format!("{} 没有设计器选项", self.label())))
    }

    /// 对象 DROP 语句（纯文本，各驱动校验 kind 与引用规则）。
    fn object_drop_sql(&self, _namespace: &str, _kind: &str, _name: &str) -> AppResult<String> {
        Err(AppError::bad(format!("{} 不支持删除对象", self.label())))
    }

    // ------------------------------------------------------------- DDL 生成

    /// CREATE DATABASE（含 PostgreSQL 的可选子句）。
    #[allow(clippy::too_many_arguments)]
    fn create_database_statement(
        &self,
        name: &str,
        charset: Option<&str>,
        collation: Option<&str>,
        template: Option<&str>,
        encoding: Option<&str>,
        owner: Option<&str>,
        tablespace: Option<&str>,
    ) -> AppResult<String> {
        crate::ops::create_database_statement(
            self, name, charset, collation, template, encoding, owner, tablespace,
        )
    }

    /// CREATE SCHEMA（仅 PostgreSQL 有独立 schema）。
    fn create_schema_statement(&self, name: &str) -> AppResult<String> {
        crate::ops::create_schema_statement(self, name)
    }

    /// 建表所需的全部语句。
    fn create_table_statements(
        &self,
        namespace: &str,
        spec: &crate::spec::CreateTableSpec,
    ) -> AppResult<Vec<String>> {
        crate::ops::create_table_statements(self, namespace, spec)
    }

    /// CREATE TABLE 语句（多条用方言分隔符连接，设计器预览用）。
    ///
    /// P7：statement_separator() 的第一个真实消费者 —— 三种方言当前都返回 ";"，
    /// 输出与硬编码 ";\n" 逐字一致；未来若某方言需要别的分隔符，只改 dialect。
    fn create_table_statement(
        &self,
        namespace: &str,
        spec: &crate::spec::CreateTableSpec,
    ) -> AppResult<String> {
        let separator = format!("{}\n", self.dialect().statement_separator());
        Ok(self
            .create_table_statements(namespace, spec)?
            .join(&separator))
    }

    /// ALTER TABLE 批次语句。
    fn alter_table_statements(
        &self,
        namespace: &str,
        table: &str,
        spec: &crate::spec::AlterTableSpec,
    ) -> AppResult<Vec<String>> {
        crate::ops::alter_table_statements(self, namespace, table, spec)
    }

    // ---------------------------------------------------------------- 执行类

    async fn create_table(
        &self,
        conn: &ConnectionHandle,
        namespace: &str,
        spec: &crate::spec::CreateTableSpec,
    ) -> AppResult<()> {
        crate::ops::create_table(self, conn, namespace, spec).await
    }

    async fn create_schema(&self, conn: &ConnectionHandle, name: &str) -> AppResult<()> {
        crate::ops::create_schema(self, conn, name).await
    }

    async fn drop_schema(&self, conn: &ConnectionHandle, name: &str) -> AppResult<()> {
        crate::ops::drop_schema(self, conn, name).await
    }

    async fn drop_namespace(&self, conn: &ConnectionHandle, name: &str) -> AppResult<()> {
        crate::ops::drop_namespace(self, conn, name).await
    }

    async fn drop_table(
        &self,
        conn: &ConnectionHandle,
        namespace: &str,
        table: &str,
    ) -> AppResult<()> {
        crate::ops::drop_table(self, conn, namespace, table).await
    }

    async fn truncate(
        &self,
        conn: &ConnectionHandle,
        namespace: &str,
        table: &str,
    ) -> AppResult<()> {
        crate::ops::truncate(self, conn, namespace, table).await
    }

    async fn drop_object(
        &self,
        conn: &ConnectionHandle,
        namespace: &str,
        kind: &str,
        name: &str,
    ) -> AppResult<()> {
        crate::ops::drop_object(self, conn, namespace, kind, name).await
    }

    /// 整段脚本执行（无行数上限；控制台走 SessionHandle）。
    async fn run_sql(&self, conn: &ConnectionHandle, sql: &str) -> Vec<ResultSet> {
        crate::ops::run_sql(self, conn, sql).await
    }

    /// 一页表数据（keyset 游标 + 延迟关联；见 `crate::paging`）。
    ///
    /// 入参是 [`DataPage`] 结构体而不是一长串位置参数：`after` / `count` /
    /// `deferred` 都是可选项，位置参数会变成一串看不懂的 `None, true, true`。
    async fn data(
        &self,
        conn: &ConnectionHandle,
        namespace: &str,
        table: &str,
        query: &crate::paging::DataPage<'_>,
    ) -> AppResult<Value> {
        crate::ops::data(self, conn, namespace, table, query).await
    }

    /// 行级 INSERT / UPDATE / DELETE。
    #[allow(clippy::too_many_arguments)]
    async fn change_row(
        &self,
        conn: &ConnectionHandle,
        namespace: &str,
        table: &str,
        action: &str,
        keys: &serde_json::Map<String, Value>,
        values: &serde_json::Map<String, Value>,
        limit_one: bool,
    ) -> AppResult<Value> {
        crate::ops::change_row(
            self, conn, namespace, table, action, keys, values, limit_one,
        )
        .await
    }
}

