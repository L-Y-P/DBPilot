//! MySQL 的账号管理能力（P3 Step 4）。
//!
//! 只是把 `super`（drivers/mysql.rs）里已有的账号函数按 [`AccountAdmin`]
//! 重新暴露 —— SQL 与解析逻辑仍只有一份，签名已从 `&Db` 迁到
//! [`ConnectionHandle`]（P2-2 同款迁移：没有 downcast）。

use async_trait::async_trait;
use serde_json::Value;

use crate::core::account::AccountAdmin;
use crate::core::connection::ConnectionHandle;
use crate::core::dialect::DatabaseDialect;
use crate::drivers::UserChange;
use crate::error::AppResult;

/// 零状态实现：注册表/驱动以 `&'static` 共享，见 drivers::account_admin_for。
pub struct MySqlAccountAdmin;

pub static MYSQL_ACCOUNT_ADMIN: MySqlAccountAdmin = MySqlAccountAdmin;

#[async_trait]
impl AccountAdmin for MySqlAccountAdmin {
    fn account_model(&self) -> Value {
        super::account_model()
    }

    async fn list_users(&self, conn: &ConnectionHandle) -> AppResult<Vec<Value>> {
        super::users(conn).await
    }

    async fn user_grants(
        &self,
        conn: &ConnectionHandle,
        user: &str,
        host: &str,
    ) -> AppResult<Value> {
        super::user_grants(conn, user, host).await
    }

    async fn assignable_roles(
        &self,
        conn: &ConnectionHandle,
        user: &str,
    ) -> AppResult<Vec<String>> {
        super::assignable_roles(conn, user).await
    }

    fn create_account_statements(
        &self,
        user: &str,
        host: &str,
        password: &str,
        change: &UserChange,
    ) -> AppResult<Vec<String>> {
        super::create_account_statements(user, host, password, change)
    }

    async fn alter_account_statements(
        &self,
        conn: &ConnectionHandle,
        user: &str,
        host: &str,
        change: &UserChange,
    ) -> AppResult<Vec<String>> {
        super::alter_account_statements(conn, user, host, change).await
    }

    fn drop_account_statement(&self, user: &str, host: &str) -> AppResult<String> {
        super::drop_account_statement(user, host)
    }

    fn account_privilege_hint(&self) -> &'static str {
        super::dialect::MYSQL_DIALECT.account_privilege_hint()
    }
}
