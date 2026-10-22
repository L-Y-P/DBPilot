//! Server administration: status, variables, processes, database accounts.
//!
//! Ports the web `routes/admin.rs`. Those handlers required the site admin
//! role; the desktop app has no roles, so the checks are removed. Everything
//! else — including the system-account guard in `drivers` — is unchanged.

use serde::Deserialize;
use serde_json::{json, Value};

use super::{parse, state};
use crate::core::account::AccountAdmin;
use crate::core::connection::ConnectionHandle;
use crate::core::dialect::DialectCapability;
use crate::core::driver::DatabaseDriver;
use crate::drivers::{PrivilegeGrant, RoleAttributes, UserChange};
use crate::error::AppError;
use crate::privileges::{self, ServerPrivileges};

/// What the connected database account may do on the server.
///
/// The UI calls this on connect and on refresh so it can disable the panels the
/// account has no privilege for and name the GRANT that is missing, instead of
/// showing a tab that can only fail with "1142 SELECT command denied".
pub async fn server_privileges() -> anyhow::Result<Value> {
    let state = state()?;
    let skill = state.driver_for_active().await?;
    let conn = state.connection_for(None).await?;
    let probed = privileges::probe(skill.as_ref(), &conn).await;
    Ok(probed.to_json())
}

/// Probe the account's capabilities once, for the handlers below.
async fn probe(driver: &dyn DatabaseDriver, conn: &ConnectionHandle) -> ServerPrivileges {
    privileges::probe(driver, conn).await
}

/// The active driver's account capability.
///
/// 只有「驱动完全没登记账号实现」时才报错；SQLite 登记了实现但
/// `supports_accounts() == false`，它的读接口（用户列表 / 能力目录）必须照旧
/// 返回空列表与 `supported:false`，写接口由实现自己返回
/// 「SQLite 没有数据库账号」。早期版本在这里按 supports_accounts() 一并拒绝，
/// 会把两个读接口从「正常空结果」变成报错，属 Dart 契约回退。
fn account_admin(driver: &dyn DatabaseDriver) -> anyhow::Result<&'static dyn AccountAdmin> {
    driver
        .account_admin()
        .ok_or_else(|| AppError::bad(format!("{} 没有数据库账号", driver.label())).into())
}

/// Server version, uptime, counters and the full status variable map.
pub async fn status() -> anyhow::Result<Value> {
    let state = state()?;
    let skill = state.driver_for_active().await?;
    let conn = state.connection_for(None).await?;
    // SQLite has no server to inspect; the overview is local metadata and is
    // always allowed. The two network drivers need PROCESS / SHOW DATABASES for
    // the full status variable map.
    if skill.dialect().supports_server_admin() {
        let caps = probe(skill.as_ref(), &conn).await;
        privileges::require(
            "服务器状态",
            caps.can_view_status,
            skill.dialect().status_privilege_hint(),
        )?;
    }
    // P4：概览也走驱动方法，api/server.rs 不再持有旧门面 Db。
    skill
        .server_overview(&conn)
        .await
        .map_err(anyhow::Error::from)
}

#[derive(Deserialize)]
struct VariableQuery {
    #[serde(default)]
    filter: Option<String>,
}

/// Server variables, optionally filtered by a substring.
pub async fn variables(params: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let query: VariableQuery = parse("params", params)?;
    let skill = state.driver_for_active().await?;
    let conn = state.connection_for(None).await?;
    let variables = skill.variables(&conn, query.filter.as_deref()).await?;
    Ok(json!({ "variables": variables }))
}

/// Open sessions on the server.
pub async fn processes() -> anyhow::Result<Value> {
    let state = state()?;
    let skill = state.driver_for_active().await?;
    let handle = state.connection_for(None).await?;
    if skill.dialect().supports_server_admin() {
        let caps = probe(skill.as_ref(), &handle).await;
        privileges::require(
            "进程列表",
            caps.can_view_processes,
            skill.dialect().process_privilege_hint(),
        )?;
    }
    // P2-4：进程列表由驱动给出（MySQL SHOW FULL PROCESSLIST /
    // PostgreSQL pg_stat_activity），api 不再直接执行方言 SQL。
    let processes = skill.show_processlist(&handle).await?;
    Ok(json!({ "processes": processes }))
}

/// Kill one server session by id.
pub async fn kill_process(id: i64) -> anyhow::Result<Value> {
    let state = state()?;
    let skill = state.driver_for_active().await?;
    let handle = state.connection_for(None).await?;
    if skill.dialect().supports_server_admin() {
        let caps = probe(skill.as_ref(), &handle).await;
        privileges::require(
            "终止进程",
            caps.can_kill_processes,
            skill.dialect().kill_privilege_hint(),
        )?;
    }
    skill.kill_session(&handle, id).await?;
    Ok(json!({ "ok": true, "killed": id }))
}

/// Database accounts (MySQL users / PostgreSQL roles).
pub async fn list_db_users() -> anyhow::Result<Value> {
    let state = state()?;
    // Accounts are instance-level; use the admin connection even when the
    // browsed database is a different one.
    let skill = state.driver_for_active().await?;
    let admin = account_admin(skill.as_ref())?;
    // P4：管理句柄一次拿到，probe 也吃句柄 —— 不再需要 &Db，也就没有
    // 「先 admin_db 再 admin_connection」的重复取池。
    let (conn, _admin_database) = state.admin_connection().await?;
    if skill.dialect().supports_server_admin() {
        let caps = probe(skill.as_ref(), &conn).await;
        privileges::require(
            "数据库账号",
            caps.can_manage_accounts,
            skill.dialect().account_privilege_hint(),
        )?;
    }
    let users = admin.list_users(&conn).await?;
    Ok(json!({ "users": users, "driver": skill.id() }))
}

#[derive(Deserialize)]
struct RoleQuery {
    #[serde(default)]
    user: Option<String>,
}

/// Which controls the account editor should render for the active driver.
pub async fn user_privileges(params: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let query: RoleQuery = parse("params", params)?;
    let active = state.active().await?;
    let skill = state.driver_for_active().await?;
    let admin = account_admin(skill.as_ref())?;
    let (conn, _admin_database) = state.admin_connection().await?;
    let mut catalog = admin.account_model();
    let Some(object) = catalog.as_object_mut() else {
        return Ok(catalog);
    };
    object.insert("driver".into(), json!(skill.id()));

    // MySQL edits privileges per scope, so the editor needs the database list.
    // This is the administrative surface: it must offer every database on the
    // server, not only the ones the connecting account itself holds a grant on,
    // or an operator could never grant on a database it does not own.
    // MySQL 按「库」授范围权限；PostgreSQL 是角色、SQLite 无账号体系，
    // 都不进这个分支（能力位，不要用 namespaces_are_databases：SQLite 也是 true）。
    if skill.supports(DialectCapability::GrantScopes) {
        let mut scopes = vec![json!({ "value": "*", "label": "*.* （全局）" })];
        // 管理面：授范围权限时要能看到服务器上所有库（不受连接账号自身授权
        // 过滤），所以用驱动的 list_all_instance_databases ——
        // list_instance_databases 是按 GRANT 过滤过的浏览用列表，会藏掉
        // 管理员不拥有的库。
        let namespaces = skill
            .list_all_instance_databases(&conn)
            .await
            .unwrap_or_default();
        for ns in namespaces {
            if let Some(name) = ns.get("name").and_then(|v| v.as_str()) {
                if active.visible(name) {
                    scopes.push(json!({ "value": name, "label": format!("{}.*", name) }));
                }
            }
        }
        object.insert("scopes".into(), json!(scopes));
    }

    // PostgreSQL membership editing needs the list of roles to pick from.
    if let Some(user) = query.user.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        let roles = admin.assignable_roles(&conn, user).await.unwrap_or_default();
        object.insert("roles".into(), json!(roles));
    }
    Ok(catalog)
}

#[derive(Deserialize)]
struct CreateUserRequest {
    user: String,
    #[serde(default = "default_host")]
    host: String,
    #[serde(default)]
    password: String,
    #[serde(default)]
    account_locked: Option<bool>,
    #[serde(default)]
    grants: Option<Vec<PrivilegeGrant>>,
    #[serde(default)]
    roles: Option<Vec<String>>,
    #[serde(default)]
    attributes: Option<RoleAttributes>,
    #[serde(default)]
    extra_sql: Vec<String>,
}

fn default_host() -> String {
    "%".to_string()
}

/// Execute generated statements one by one, stopping at the first failure.
///
/// P4：改成接收 ConnectionHandle；文本协议路径由
/// `SqlSession::execute_raw` / `ConnectionHandle::run_raw` 提供
/// （MySQL 账号 DDL 不接受 prepared，错误 1295）。
async fn run_statements(conn: &ConnectionHandle, statements: &[String]) -> (Vec<Value>, usize) {
    let mut results: Vec<Value> = Vec::new();
    let mut failed = 0usize;
    for statement in statements {
        let outcome = conn.run_raw(statement).await;
        if outcome.error.is_some() {
            failed += 1;
        }
        results.push(json!({
            "statement": statement,
            "error": outcome.error,
            "rows_affected": outcome.row_count,
        }));
        if failed > 0 {
            break;
        }
    }
    (results, failed)
}

/// Create a database account. `dry_run` returns the statements without running them.
pub async fn create_db_user(body: Value, dry_run: bool) -> anyhow::Result<Value> {
    let state = state()?;
    let req: CreateUserRequest = parse("user", body)?;
    let skill = state.driver_for_active().await?;
    let admin = account_admin(skill.as_ref())?;
    let (conn, _admin_database) = state.admin_connection().await?;
    let change = UserChange {
        account_locked: req.account_locked,
        grants: req.grants,
        roles: req.roles,
        attributes: req.attributes,
        extra_sql: req.extra_sql,
        ..Default::default()
    };
    let statements = admin.create_account_statements(&req.user, &req.host, &req.password, &change)?;
    if dry_run {
        return Ok(json!({ "dry_run": true, "statements": statements, "failed": 0, "results": [] }));
    }
    let (results, failed) = run_statements(&conn, &statements).await;
    Ok(json!({
        "ok": failed == 0,
        "user": req.user,
        "host": req.host,
        "statements": statements,
        "results": results,
        "failed": failed,
    }))
}

/// Rename / password / lock / privileges / roles of one existing account.
pub async fn update_db_user(user: String, host: String, body: Value, dry_run: bool) -> anyhow::Result<Value> {
    let state = state()?;
    let change: UserChange = parse("user", body)?;
    let skill = state.driver_for_active().await?;
    let admin = account_admin(skill.as_ref())?;
    let (conn, _admin_database) = state.admin_connection().await?;
    let statements = admin.alter_account_statements(&conn, &user, &host, &change).await?;
    if dry_run {
        return Ok(json!({ "dry_run": true, "statements": statements, "failed": 0, "results": [] }));
    }
    if statements.is_empty() {
        return Ok(json!({ "ok": true, "statements": [], "results": [], "failed": 0, "unchanged": true }));
    }
    // 语句执行走句柄的 text protocol 路径（MySQL 账号 DDL 不接受 prepared）。
    let (results, failed) = run_statements(&conn, &statements).await;
    Ok(json!({
        "ok": failed == 0,
        "statements": statements,
        "results": results,
        "failed": failed,
    }))
}

/// Drop one database account. The system-account guard lives in `drivers`.
pub async fn drop_db_user(user: String, host: String) -> anyhow::Result<Value> {
    let state = state()?;
    let skill = state.driver_for_active().await?;
    let admin = account_admin(skill.as_ref())?;
    let sql = admin.drop_account_statement(&user, &host)?;
    let (conn, _admin_database) = state.admin_connection().await?;
    let outcome = conn.run_raw(&sql).await;
    if let Some(err) = outcome.error {
        return Err(AppError::bad(err).into());
    }
    Ok(json!({ "ok": true, "statement": sql }))
}

/// Structured privileges of one account, for the "view" dialog.
pub async fn db_user_grants(user: String, host: String) -> anyhow::Result<Value> {
    let state = state()?;
    let skill = state.driver_for_active().await?;
    let admin = account_admin(skill.as_ref())?;
    let (conn, _admin_database) = state.admin_connection().await?;
    let mut value = admin.user_grants(&conn, &user, &host).await?;
    let assignable = admin.assignable_roles(&conn, &user).await.unwrap_or_default();
    if let Some(object) = value.as_object_mut() {
        object.insert("user".into(), json!(user));
        object.insert("host".into(), json!(host));
        object.insert("driver".into(), json!(skill.id()));
        object.insert("assignable_roles".into(), json!(assignable));
    }
    Ok(value)
}
