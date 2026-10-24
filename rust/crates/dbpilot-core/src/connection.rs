//! 与 sqlx 解耦的连接句柄和统一结果类型。
//!
//! 目标：api 只看到 [`ConnectionHandle`] / [`crate::db::ResultSet`]，
//! 看不到 `MySqlPool`/`PgPool`/`SqlitePool`（具体池类型只出现在
//! `drivers::Pool` 内部和 `pools.rs` 的缓存里）。
//!
//! P2-2 起驱动实现只通过本句柄的公开方法执行 SQL 与取方言，
//! **不再有 downcast**（`typed()` / `as_any()` 已删除）：`Db` 门面只是
//! `SqlSession` 的一个实现，驱动内部函数统一接收 `&ConnectionHandle`。

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::Value;

use crate::db::ResultSet;
use crate::error::{AppError, AppResult};

use super::dialect::DatabaseDialect;

/// 连接配置：P2-1 起结构体（ConnSpec）与池身份计算都在 `core::config`，
/// 这里只做别名，让 api 用 ConnectionConfig / ConnSpec 两个名字都能编译。
pub use crate::config::{ConnectionConfig, ConnSpec};
pub use crate::config::DriverKind;

/// SSH 隧道的落点信息（复用现有类型，避免出现两套）。
///
/// 33 轮拆 crate 时从 drivers/mod.rs 搬进契约层：SqlSession::tunnel() 的
/// 返回类型属于连接契约，core 不能反向依赖 drivers。
#[derive(Clone, Debug)]
pub struct TunnelInfo {
    /// Local forwarded address the driver connected to (127.0.0.1:port).
    pub host: String,
    pub port: u16,
    /// SHA256 fingerprint of the jump host key used for this tunnel.
    pub fingerprint: String,
}

/// 流式回调的规范类型（P6.1）：显式 HRTB + Send。
///
/// 写成类型别名是为了让 trait 方法、Db 实现和三个驱动函数用同一个类型；
/// 直接写 dyn FnMut(&[..], &[..]) 时，async_trait 会把两个引用的生命周期提升成
/// 早绑定参数，和驱动侧的 for<'a,'b> 对不上（one type is more general）。
pub type RowFn<'a> =
    dyn for<'r, 'c> FnMut(&'r [crate::db::ColumnMeta], &'c [serde_json::Value]) -> bool + Send + 'a;

/// 一个「可执行 SQL 的会话」。
///
/// 实现者是 `drivers::Db`（内部包 sqlx 池）。接口刻意只暴露
/// 「执行 + 查询 + 方言」，不暴露池类型，因此驱动实现无法也不需要
/// downcast（P2-2 已删除 `as_any`）。
#[async_trait]
pub trait SqlSession: Send + Sync {
    fn driver_id(&self) -> &'static str;

    fn dialect(&self) -> &dyn DatabaseDialect;

    /// 执行一条语句（含 DDL / 会话指令）。
    async fn execute(&self, sql: &str) -> ResultSet;

    /// 执行一条语句并限制返回行数（SQL 控制台用）。
    async fn execute_limited(&self, sql: &str, max_rows: usize) -> (ResultSet, bool);

    /// 用**文本协议**执行（不 prepare）：
    ///
    /// MySQL 的存储过程/触发器/事件与账号 DDL 走 prepared 会被拒（错误 1295），
    /// 旧门面的 `Db::run_raw` 就是为此存在。默认实现退回普通执行（PostgreSQL /
    /// SQLite 的普通路径本来就不 prepare 这些语句）。
    async fn execute_raw(&self, sql: &str) -> ResultSet {
        self.execute(sql).await
    }

    /// 执行查询并返回按列名索引的对象行。
    async fn query_rows(&self, sql: &str) -> AppResult<Vec<Value>> {
        let result = self.execute(sql).await;
        if let Some(error) = result.error {
            return Err(AppError::bad(error));
        }
        Ok(rows_to_named(&result))
    }

    async fn query_i64(&self, sql: &str) -> AppResult<i64> {
        let result = self.execute(sql).await;
        if let Some(error) = result.error {
            return Err(AppError::bad(error));
        }
        Ok(scalar_i64(&result).unwrap_or(0))
    }

    async fn query_string(&self, sql: &str) -> AppResult<String> {
        let result = self.execute(sql).await;
        if let Some(error) = result.error {
            return Err(AppError::bad(error));
        }
        Ok(result
            .rows
            .first()
            .and_then(|row| row.first())
            .map(|value| match value {
                Value::String(text) => text.clone(),
                other => other.to_string(),
            })
            .unwrap_or_default())
    }

    async fn close(&self);

    /// 流式扫描（导出/备份）。P6.1：回调装箱并带显式生命周期，避开
    /// BQ&mut dyn FnMutBQ 在 obj-safe trait 上的 HRTB/Send 冲突。
    async fn scan_rows_boxed<'a>(
        &'a self,
        _sql: &'a str,
        _on_row: Box<RowFn<'a>>,
    ) -> AppResult<crate::db::ScanStats> {
        Err(AppError::Internal("该会话不支持流式扫描".to_string()))
    }

    /// 在一个事务里试插一行、读回、立刻回滚（导入向导的「试插入」）。
    async fn probe_insert(&self, _insert: &str, _select: &str) -> AppResult<serde_json::Value> {
        Err(AppError::Internal("该会话不支持事务试插".to_string()))
    }

    /// 在一个事务里依次执行多条语句，返回每条语句的结果。
    ///
    /// 全部成功才提交；任一条失败则整批回滚并返回错误（错误里带失败序号）。
    /// 用来实现行批量保存（`api::explorer::apply_row_changes`）这类
    /// "多行必须一起成功" 的写入。默认实现报告不支持，池化会话按驱动实现。
    ///
    /// 注意：事务控制由驱动用 sqlx 的 transaction API 发出，不要在这个方法里
    /// 执行 `BEGIN`：MySQL 的 prepared-statement 协议拒绝 `BEGIN`（错误 1295），
    /// 而 `sqlx::query("BEGIN")` 恰好走 prepared 路径。
    async fn execute_transaction(&self, _statements: Vec<String>) -> AppResult<Vec<ResultSet>> {
        Err(AppError::Internal("该会话不支持事务批量执行".to_string()))
    }

    /// 这条会话背后的 SSH 隧道（无隧道为 None）。
    ///
    /// TOFU 固定主机密钥（N-01）需要连接后读指纹；api 通过句柄拿，不碰门面字段。
    fn tunnel(&self) -> Option<TunnelInfo> {
        None
    }
}

/// 句柄：api / state 只持有它，不关心底下是哪种池。
#[derive(Clone)]
pub struct ConnectionHandle {
    inner: Arc<dyn SqlSession>,
}

impl std::fmt::Debug for ConnectionHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConnectionHandle")
            .field("driver", &self.inner.driver_id())
            .finish()
    }
}

impl ConnectionHandle {
    pub fn new(inner: Arc<dyn SqlSession>) -> Self {
        ConnectionHandle { inner }
    }

    pub fn from_session<S: SqlSession + 'static>(session: S) -> Self {
        ConnectionHandle {
            inner: Arc::new(session),
        }
    }

    pub fn driver_id(&self) -> &'static str {
        self.inner.driver_id()
    }

    pub fn dialect(&self) -> &dyn DatabaseDialect {
        self.inner.dialect()
    }

    pub async fn execute(&self, sql: &str) -> ResultSet {
        self.inner.execute(sql).await
    }

    pub async fn exec(&self, sql: &str) -> AppResult<()> {
        let result = self.inner.execute(sql).await;
        match result.error {
            Some(error) => Err(AppError::bad(error)),
            None => Ok(()),
        }
    }

    /// 旧门面方法名的兼容包装（P2-2 迁移驱动内部实现时按名替换即可）。
    ///
    /// 这些包装让 `mysql::tables(db: &Db)` 这类函数可以只改参数类型，
    /// 函数体里的 `db.fetch_named(...)` 保持同名调用。
    pub async fn fetch_named(&self, sql: String) -> AppResult<Vec<Value>> {
        self.inner.query_rows(&sql).await
    }

    pub async fn fetch_i64(&self, sql: String) -> AppResult<i64> {
        self.inner.query_i64(&sql).await
    }

    pub async fn fetch_string(&self, sql: String) -> AppResult<String> {
        self.inner.query_string(&sql).await
    }

    pub async fn run_one(&self, sql: String) -> ResultSet {
        self.inner.execute(&sql).await
    }

    /// 文本协议执行（P4）：账号 DDL 等不接受 prepared 的语句走这里。
    pub async fn run_raw(&self, sql: &str) -> ResultSet {
        self.inner.execute_raw(sql).await
    }

    pub async fn run_one_limited(&self, sql: String, max_rows: usize) -> (ResultSet, bool) {
        self.inner.execute_limited(&sql, max_rows).await
    }

    /// 驱动自身标识（供 `qualify_*` 一类方言 helper 使用）。
    pub fn driver_kind(&self) -> crate::config::DriverKind {
        match self.driver_id() {
            "mysql" => crate::config::DriverKind::Mysql,
            "postgres" => crate::config::DriverKind::Postgres,
            _ => crate::config::DriverKind::Sqlite,
        }
    }

    pub async fn execute_limited(&self, sql: &str, max_rows: usize) -> (ResultSet, bool) {
        self.inner.execute_limited(sql, max_rows).await
    }

    pub async fn query_rows(&self, sql: &str) -> AppResult<Vec<Value>> {
        self.inner.query_rows(sql).await
    }

    pub async fn query_i64(&self, sql: &str) -> AppResult<i64> {
        self.inner.query_i64(sql).await
    }

    pub async fn query_string(&self, sql: &str) -> AppResult<String> {
        self.inner.query_string(sql).await
    }

    pub async fn close(&self) {
        self.inner.close().await
    }

    /// SSH 隧道落点信息（无隧道为 None）。
    pub fn tunnel(&self) -> Option<TunnelInfo> {
        self.inner.tunnel()
    }

    /// 事务内试插一行并回滚（导入向导）。
    pub async fn probe_insert(&self, insert: &str, select: &str) -> AppResult<serde_json::Value> {
        self.inner.probe_insert(insert, select).await
    }

    /// 一个事务内执行多条语句（全部成功才提交，否则整批回滚）。
    pub async fn execute_transaction(
        &self,
        statements: Vec<String>,
    ) -> AppResult<Vec<ResultSet>> {
        self.inner.execute_transaction(statements).await
    }

    /// 流式扫描（导出/备份）：逐行回调、不整表载入内存。
    pub async fn scan_rows<'a, F>(&'a self, sql: &'a str, on_row: F) -> AppResult<crate::db::ScanStats>
    where
        F: for<'r, 'c> FnMut(&'r [crate::db::ColumnMeta], &'c [serde_json::Value]) -> bool + Send + 'a,
    {
        self.inner.scan_rows_boxed(sql, Box::new(on_row)).await
    }
}

/// 结果集 → 按列名索引的对象行。
///
/// 与 `drivers::named_from` 保持同一份实现（后者已委托到这里），
/// 避免两份逻辑在迁移期漂移。
pub fn rows_to_named(result: &ResultSet) -> Vec<Value> {
    result
        .rows
        .iter()
        .map(|row| {
            let mut map = serde_json::Map::new();
            for (index, column) in result.columns.iter().enumerate() {
                map.insert(
                    column.name.clone(),
                    row.get(index).cloned().unwrap_or(Value::Null),
                );
            }
            Value::Object(map)
        })
        .collect()
}

fn scalar_i64(result: &ResultSet) -> Option<i64> {
    result
        .rows
        .first()
        .and_then(|row| row.first())
        .and_then(|value| {
            value
                .as_i64()
                .or_else(|| value.as_u64().map(|v| v as i64))
                .or_else(|| value.as_str().and_then(|text| text.parse::<i64>().ok()))
        })
}
