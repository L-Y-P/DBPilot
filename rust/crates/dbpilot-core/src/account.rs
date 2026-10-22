//! 账号能力契约（P3 Step 4）。
//!
//! 旧 drivers::Db 门面把「数据库账号（用户/角色）」的读写和 SQL 执行混在一起；
//! 这里把它拆成 api 唯一认识的账号接口：api 只通过
//! core::driver::DatabaseDriver::account_admin 拿到实现，不再按驱动分派，
//! 也不再直接调用门面方法。
//!
//! 约定与 DatabaseDriver 相同：
//! * 实现必须是零状态：drivers/<id>/account.rs 用 unit struct + static；
//! * 所有方法 &self，连接状态在 ConnectionHandle 里；
//! * 没有账号体系的驱动（SQLite）用 supports_accounts() 表达，
//!   或者干脆不提供实现（account_admin() 返回 None）。

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::AppResult;

use super::connection::ConnectionHandle;


/// 一个驱动对「数据库账号」的读写能力。
///
/// SQL 文本仍归各驱动的自由函数（drivers/<id>.rs）所有；实现只是把那些
/// 函数从 &Db 迁到 ConnectionHandle 后按接口重新暴露。
#[async_trait]
pub trait AccountAdmin: Send + Sync {
    /// 客户端控件目录：账号编辑器该渲染哪些字段 / 权限。
    fn account_model(&self) -> Value;

    /// 账号列表（MySQL mysql.user / PostgreSQL pg_roles）。
    async fn list_users(&self, conn: &ConnectionHandle) -> AppResult<Vec<Value>>;

    /// 一个账号的结构化权限 / 角色成员 + 原始行。
    async fn user_grants(
        &self,
        conn: &ConnectionHandle,
        user: &str,
        host: &str,
    ) -> AppResult<Value>;

    /// 可以授予该账号的角色（PostgreSQL 成员关系 / MySQL 角色）。
    async fn assignable_roles(
        &self,
        conn: &ConnectionHandle,
        user: &str,
    ) -> AppResult<Vec<String>>;

    /// CREATE + 初始权限，返回语句列表（dry-run 友好）。纯函数，不需要连接。
    fn create_account_statements(
        &self,
        user: &str,
        host: &str,
        password: &str,
        change: &UserChange,
    ) -> AppResult<Vec<String>>;

    /// ALTER / RENAME / 权限差异，返回最小语句列表。
    /// 需要当前状态（SHOW GRANTS / pg_auth_members）时要读连接。
    async fn alter_account_statements(
        &self,
        conn: &ConnectionHandle,
        user: &str,
        host: &str,
        change: &UserChange,
    ) -> AppResult<Vec<String>>;

    /// DROP 一个账号。纯函数，不需要连接（系统账号守卫在内）。
    fn drop_account_statement(&self, user: &str, host: &str) -> AppResult<String>;

    /// 没有账号体系的驱动返回 false（SQLite）；api 用它替代 DriverKind 判断。
    fn supports_accounts(&self) -> bool {
        true
    }

    /// 缺少账号管理权限时要补的 GRANT（用户可见文案）。
    fn account_privilege_hint(&self) -> &'static str {
        "相应的账号管理权限"
    }
}

// ------------------------------------------------------- 账号编辑请求 DTO
//
// 33 轮拆 crate 时从 drivers/mod.rs 搬进契约层：AccountAdmin 的签名需要
// UserChange，core 不能反向依赖 drivers。drivers 仍 re-export 旧路径。

/// One row of the graphical privilege matrix: a scope (global, database or
/// table) plus the privileges granted on it.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq, Hash)]
pub struct PrivilegeGrant {
    /// `*` for the global scope, otherwise a database / schema name.
    pub scope: String,
    /// MySQL only: a single table inside `scope`. `None` means the whole scope.
    #[serde(default)]
    pub table: Option<String>,
    #[serde(default)]
    pub privileges: Vec<String>,
}

/// Desired state of a database account, as sent by the account editor.
/// Every field is optional so a single request can change just one thing.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct UserChange {
    #[serde(default)]
    pub new_user: Option<String>,
    #[serde(default)]
    pub new_host: Option<String>,
    #[serde(default)]
    pub password: Option<String>,
    #[serde(default)]
    pub account_locked: Option<bool>,
    /// MySQL: full privilege matrix. `None` leaves the privileges untouched.
    #[serde(default)]
    pub grants: Option<Vec<PrivilegeGrant>>,
    /// PostgreSQL: role membership. `None` leaves the memberships untouched.
    #[serde(default)]
    pub roles: Option<Vec<String>>,
    /// PostgreSQL: role attributes.
    #[serde(default)]
    pub attributes: Option<RoleAttributes>,
    /// Advanced escape hatch: raw statements appended after the generated ones.
    #[serde(default)]
    pub extra_sql: Vec<String>,
}

/// PostgreSQL role attributes, mirroring `pg_roles` boolean columns.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct RoleAttributes {
    #[serde(default)]
    pub login: Option<bool>,
    #[serde(default)]
    pub superuser: Option<bool>,
    #[serde(default)]
    pub createdb: Option<bool>,
    #[serde(default)]
    pub createrole: Option<bool>,
    #[serde(default)]
    pub replication: Option<bool>,
    #[serde(default)]
    pub bypassrls: Option<bool>,
    #[serde(default)]
    pub connection_limit: Option<i64>,
    #[serde(default)]
    pub valid_until: Option<String>,
}
