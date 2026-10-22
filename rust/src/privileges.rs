//! Effective server privileges of the connected database account.
//!
//! The desktop app is single-user, but the *database* account it connects with
//! is not necessarily privileged: a hosting account often owns one schema and
//! nothing else. Without knowing that, the server page offered account /
//! process / variable tabs that could only fail with MySQL's terse
//! "1142 SELECT command denied to user ...".
//!
//! This module probes what the account can actually do and turns it into a
//! capability list the UI uses to disable (and explain) the actions it cannot
//! perform. The probe is cheap: one SHOW GRANTS plus a couple of catalog reads,
//! and it is re-run whenever the connection changes or the user asks to refresh.

use serde_json::{json, Value};

use crate::core::config::DriverKind;
use crate::core::connection::ConnectionHandle;
use crate::core::driver::DatabaseDriver;
use crate::error::{AppError, AppResult};

/// What the connected account is allowed to do, as far as the UI cares.
#[derive(Clone, Debug, Default)]
pub struct ServerPrivileges {
    /// The account MySQL/PostgreSQL reports as current (user@host / role).
    pub account: String,
    /// Driver family, so the UI can word its explanations correctly.
    pub driver: String,
    /// Global privileges (MySQL) / role attributes (PostgreSQL).
    pub global_privileges: Vec<String>,
    /// True when the account may read other accounts.
    pub can_manage_accounts: bool,
    /// True when the account may create databases (MySQL global CREATE /
    /// PostgreSQL CREATEDB). Used to disable the "new database" action.
    pub can_create_database: bool,
    /// True when the account may read the process list.
    pub can_view_processes: bool,
    /// True when the account may read global status / variables.
    pub can_view_status: bool,
    /// True when the account may kill other sessions.
    pub can_kill_processes: bool,
    /// Databases this account can see.
    pub visible_databases: Vec<String>,
}

impl ServerPrivileges {
    pub fn to_json(&self) -> Value {
        json!({
            "account": self.account,
            "driver": self.driver,
            "global_privileges": self.global_privileges,
            "can_manage_accounts": self.can_manage_accounts,
            "can_create_database": self.can_create_database,
            "can_view_processes": self.can_view_processes,
            "can_view_status": self.can_view_status,
            "can_kill_processes": self.can_kill_processes,
            "visible_databases": self.visible_databases,
            // Anything the account cannot do is reported together with the
            // privilege it would need, so the UI can explain rather than hide.
            "requirements": self.requirements(),
        })
    }

    fn is_postgres(&self) -> bool {
        self.driver == "postgres"
    }

    /// Capability -> missing privilege, for the actions that are unavailable.
    fn requirements(&self) -> Vec<Value> {
        let mut out = Vec::new();
        if !self.can_create_database {
            out.push(json!({
                "capability": "database",
                "label": "新建数据库",
                "privilege": if self.is_postgres() { "CREATEDB 或超级用户" } else { "全局 CREATE 权限" },
            }));
        }
        if !self.can_manage_accounts {
            out.push(json!({
                "capability": "accounts",
                "label": "数据库账号",
                "privilege": if self.is_postgres() { "超级用户或 CREATEROLE" } else { "SELECT ON mysql.user（通常随 SELECT ON *.* 授予）" },
            }));
        }
        if !self.can_view_processes {
            out.push(json!({
                "capability": "processes",
                "label": "进程列表",
                "privilege": if self.is_postgres() { "pg_read_all_stats 角色或超级用户" } else { "PROCESS" },
            }));
        }
        if !self.can_kill_processes {
            out.push(json!({
                "capability": "kill",
                "label": "终止进程",
                "privilege": if self.is_postgres() { "pg_signal_backend 角色" } else { "CONNECTION_ADMIN 或 PROCESS" },
            }));
        }
        out
    }
}

fn has(privs: &[String], name: &str) -> bool {
    privs.iter().any(|p| p.eq_ignore_ascii_case(name))
}

/// Probe the account behind a connection handle. Never fails: an account that
/// cannot even run SHOW GRANTS simply gets an empty capability set.
///
/// P4：探测改为接收 (driver, handle)，api 不再把旧门面 `Db` 传进来。
/// `list_namespaces` 由驱动提供，因此 MySQL 的 GRANT 过滤 / SQLite 的
/// ATTACH 列表等语义与浏览路径完全一致。
pub async fn probe(driver: &dyn DatabaseDriver, conn: &ConnectionHandle) -> ServerPrivileges {
    match conn.driver_kind() {
        DriverKind::Mysql => probe_mysql(driver, conn).await,
        DriverKind::Postgres => probe_postgres(driver, conn).await,
        DriverKind::Sqlite => ServerPrivileges {
            account: "sqlite".to_string(),
            driver: "sqlite".to_string(),
            global_privileges: vec!["ALL".to_string()],
            can_manage_accounts: false,
            can_create_database: false,
            can_view_processes: false,
            can_view_status: true,
            can_kill_processes: false,
            visible_databases: namespace_names(driver, conn).await,
        },
    }
}

async fn namespace_names(driver: &dyn DatabaseDriver, conn: &ConnectionHandle) -> Vec<String> {
    driver
        .list_namespaces(conn)
        .await
        .unwrap_or_default()
        .into_iter()
        .filter_map(|n| n.get("name").and_then(|v| v.as_str()).map(str::to_string))
        .collect()
}

async fn probe_mysql(driver: &dyn DatabaseDriver, conn: &ConnectionHandle) -> ServerPrivileges {
    let account = conn
        .fetch_string("SELECT CURRENT_USER()".to_string())
        .await
        .unwrap_or_default();

    let mut privileges: Vec<String> = Vec::new();
    if let Ok(rows) = conn.fetch_named("SHOW GRANTS".to_string()).await {
        for row in rows {
            // SHOW GRANTS returns one unnamed column; take its only value.
            let Some(line) = row
                .as_object()
                .and_then(|o| o.values().next())
                .and_then(|v| v.as_str())
            else {
                continue;
            };
            let upper = line.to_ascii_uppercase();
            if !upper.starts_with("GRANT ") {
                continue;
            }
            let Some(on) = upper.find(" ON ") else { continue };
            // Only the global scope (ON *.*) governs server-level actions.
            if !upper[on + 4..].starts_with("*.*") {
                continue;
            }
            let privs = &upper[6..on];
            for p in privs.split(',') {
                let name = p.trim();
                if !name.is_empty() && name != "USAGE" && !privileges.iter().any(|x| x == name) {
                    privileges.push(name.to_string());
                }
            }
        }
    }
    let all = has(&privileges, "ALL PRIVILEGES");
    let can_create_database = all || has(&privileges, "CREATE");
    let can_view_processes = all || has(&privileges, "PROCESS");
    let can_kill_processes = all
        || has(&privileges, "CONNECTION_ADMIN")
        || has(&privileges, "SUPER")
        || has(&privileges, "PROCESS");

    // Decisive probe: either the account may read the account table or it may not.
    let can_manage_accounts = conn
        .fetch_named("SELECT user FROM mysql.user LIMIT 1".to_string())
        .await
        .is_ok();

    ServerPrivileges {
        account,
        driver: "mysql".to_string(),
        global_privileges: privileges,
        can_manage_accounts,
        can_create_database,
        can_view_processes,
        can_view_status: true,
        can_kill_processes,
        visible_databases: namespace_names(driver, conn).await,
    }
}

async fn probe_postgres(driver: &dyn DatabaseDriver, conn: &ConnectionHandle) -> ServerPrivileges {
    let account = conn
        .fetch_string("SELECT current_user".to_string())
        .await
        .unwrap_or_default();
    let mut privileges: Vec<String> = Vec::new();
    if let Ok(rows) = conn
        .fetch_named(
            "SELECT rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls \
             FROM pg_roles WHERE rolname = current_user"
                .to_string(),
        )
        .await
    {
        if let Some(row) = rows.first() {
            for (key, name) in [
                ("rolsuper", "SUPERUSER"),
                ("rolcreatedb", "CREATEDB"),
                ("rolcreaterole", "CREATEROLE"),
                ("rolreplication", "REPLICATION"),
                ("rolbypassrls", "BYPASSRLS"),
            ] {
                if row.get(key) == Some(&Value::Bool(true)) {
                    privileges.push(name.to_string());
                }
            }
        }
    }
    let superuser = has(&privileges, "SUPERUSER");
    // pg_read_all_stats sees every backend; pg_signal_backend may end them.
    let memberships = conn
        .fetch_named(
            "SELECT r.rolname FROM pg_roles r JOIN pg_auth_members m ON m.roleid = r.oid \
             WHERE m.member = (SELECT oid FROM pg_roles WHERE rolname = current_user)"
                .to_string(),
        )
        .await
        .unwrap_or_default();
    let roles: Vec<String> = memberships
        .iter()
        .filter_map(|r| r.get("rolname").and_then(|v| v.as_str()).map(str::to_string))
        .collect();
    let read_all_stats = roles.iter().any(|r| r == "pg_read_all_stats");
    let signal_backend = roles.iter().any(|r| r == "pg_signal_backend");

    let can_view_processes = superuser || read_all_stats;
    let can_kill_processes = superuser || signal_backend;
    let can_manage_accounts = superuser || has(&privileges, "CREATEROLE");
    let can_create_database = superuser || has(&privileges, "CREATEDB");

    ServerPrivileges {
        account,
        driver: "postgres".to_string(),
        global_privileges: privileges,
        can_manage_accounts,
        can_create_database,
        can_view_processes,
        can_view_status: true,
        can_kill_processes,
        visible_databases: namespace_names(driver, conn).await,
    }
}

/// Reject an action the account cannot perform, naming the privilege it needs.
pub fn require(capability: &str, allowed: bool, privilege: &str) -> AppResult<()> {
    if allowed {
        Ok(())
    } else {
        Err(AppError::Forbidden(format!(
            "当前数据库账号没有执行「{capability}」所需的服务器权限（需要 {privilege}）。请让数据库管理员为该账号授权，或改用有权限的账号连接。"
        )))
    }
}
