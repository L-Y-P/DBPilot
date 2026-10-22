//! SQLite 的账号管理能力（P3 Step 4）。
//!
//! SQLite 没有服务端账号体系：文件就是安全边界。
//!
//! 读接口维持旧契约（改造前 Db 门面的行为）：
//! * `list_users` / `assignable_roles` → 空数组；
//! * `account_model` → `supported:false` 目录（账号页签据此关闭）；
//! 写接口（建/改/删账号、查看授权）返回「SQLite 没有数据库账号」错误。
//! 把读接口也改成 Err 属于 Dart 契约回退，已由
//! tests/sqlite_account_contract.rs 钉死。

use async_trait::async_trait;
use serde_json::Value;

use crate::core::account::AccountAdmin;
use crate::core::connection::ConnectionHandle;
use crate::core::dialect::DatabaseDialect;
use crate::drivers::UserChange;
use crate::error::{AppError, AppResult};

/// 零状态实现。注意：SqliteDriver::account_admin() 返回 None（见
/// drivers::account_admin_for），api 走「不支持」分支，不会调用到这里；
/// 保留实现是为了让能力契约完整、并给未来可能接入的本地账号体系留位。
pub struct SqliteAccountAdmin;

pub static SQLITE_ACCOUNT_ADMIN: SqliteAccountAdmin = SqliteAccountAdmin;

#[async_trait]
impl AccountAdmin for SqliteAccountAdmin {
    fn account_model(&self) -> Value {
        super::account_model()
    }

    /// 旧契约：SQLite 的账号列表是**空数组**而不是错误 —— Dart 侧据此隐藏
    /// 账号页签；改成 Err 会让「正常空结果」变成错误提示。
    async fn list_users(&self, _conn: &ConnectionHandle) -> AppResult<Vec<Value>> {
        Ok(Vec::new())
    }

    async fn user_grants(
        &self,
        _conn: &ConnectionHandle,
        _user: &str,
        _host: &str,
    ) -> AppResult<Value> {
        Err(AppError::bad("SQLite 没有数据库账号"))
    }

    /// 旧契约：可授予角色同样是空数组（SQLite 没有角色）。
    async fn assignable_roles(
        &self,
        _conn: &ConnectionHandle,
        _user: &str,
    ) -> AppResult<Vec<String>> {
        Ok(Vec::new())
    }

    fn create_account_statements(
        &self,
        _user: &str,
        _host: &str,
        _password: &str,
        _change: &UserChange,
    ) -> AppResult<Vec<String>> {
        Err(AppError::bad("SQLite 没有数据库账号"))
    }

    async fn alter_account_statements(
        &self,
        _conn: &ConnectionHandle,
        _user: &str,
        _host: &str,
        _change: &UserChange,
    ) -> AppResult<Vec<String>> {
        Err(AppError::bad("SQLite 没有数据库账号"))
    }

    fn drop_account_statement(&self, _user: &str, _host: &str) -> AppResult<String> {
        Err(AppError::bad("SQLite 没有数据库账号"))
    }

    fn supports_accounts(&self) -> bool {
        false
    }

    fn account_privilege_hint(&self) -> &'static str {
        super::dialect::SQLITE_DIALECT.account_privilege_hint()
    }
}
