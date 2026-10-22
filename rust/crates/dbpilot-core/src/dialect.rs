//! 数据库方言：只生成 SQL，不执行。
//!
//! 设计要点：
//! * 返回值是 [`SqlQuery`]（SQL 文本 + 可选绑定参数），**不返回**
//!   `MySqlQuery` / `PgQuery` 之类具体类型；
//! * 标识符/字符串/字面量引用规则也在这里（`quote_ident` / `quote_string` /
//!   `literal`），api 层不再自己拼接 `SHOW TABLES` 或 `sqlite_master`；
//! * 能力位 [`DialectCapability`] 用来替掉 api 中的 `DriverKind::Postgres`
//!   分支（例如「有没有独立 schema 概念」「能不能 EXPLAIN」）。

use serde_json::Value;

use crate::error::{AppError, AppResult};
use crate::spec::{AlterTableSpec, CreateTableSpec};

/// 一个绑定参数。P1 阶段生成 SQL 仍以字面量为主，参数化是给后续
/// prepared statement 预留的形态，避免以后改 trait 签名。
#[derive(Clone, Debug, PartialEq)]
pub enum SqlParam {
    Null,
    Int(i64),
    Text(String),
    Bool(bool),
}

/// 一条生成好的语句。`params` 为空时按字面量直接执行。
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SqlQuery {
    pub sql: String,
    pub params: Vec<SqlParam>,
}

impl SqlQuery {
    pub fn new(sql: impl Into<String>) -> Self {
        SqlQuery {
            sql: sql.into(),
            params: Vec::new(),
        }
    }

    pub fn with_param(mut self, param: SqlParam) -> Self {
        self.params.push(param);
        self
    }
}

/// 方言能力位：api 用它替代 `match driver { ... }`。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DialectCapability {
    /// 实例级数据库列表（MySQL SCHEMATA / PG pg_database）。
    Databases,
    /// 独立的 schema 概念（仅 PostgreSQL）。
    Schemas,
    CreateDatabase,
    DropDatabase,
    CreateSchema,
    Explain,
    ProcessList,
    KillSession,
    UserManagement,
    /// 一个连接里可 ATTACH 多个库文件（SQLite）。
    AttachDatabase,
    /// 支持 `USE <db>` 指令（仅 MySQL）。
    UseStatement,
    /// 支持 `SHOW CREATE TABLE`。
    ShowCreateTable,
    /// 权限按「库」授范围（仅 MySQL）：账号编辑器的 scope 选择器要用服务器上
    /// 的全部库。PostgreSQL 是角色、SQLite 无账号体系，都不进这个分支。
    GrantScopes,
}

/// 方言契约。实现必须零状态（`Copy`），因为每个驱动持有一个 `'static` 实例。
pub trait DatabaseDialect: Send + Sync + std::fmt::Debug {
    /// 驱动的稳定 id，与 `DatabaseDriver::id()` 一致。
    fn driver_id(&self) -> &'static str;

    /// 标识符引用（MySQL 反引号 / PostgreSQL·SQLite 双引号）。
    fn quote_ident(&self, name: &str) -> String;

    /// 字符串字面量引用（MySQL 需转义反斜杠）。
    fn quote_string(&self, value: &str) -> String;

    fn qualify(&self, namespace: &str, table: &str) -> String {
        format!(
            "{}.{}",
            self.quote_ident(namespace),
            self.quote_ident(table)
        )
    }

    /// 布尔字面量（PostgreSQL 用 TRUE/FALSE，其余 1/0）。
    fn bool_literal(&self, value: bool) -> &'static str {
        if value {
            "1"
        } else {
            "0"
        }
    }

    /// 二进制字面量（PostgreSQL 用 decode(hex)，其余 X'..'）。
    fn binary_literal(&self, hex: &str) -> String {
        format!("X'{}'", hex)
    }

    /// JSON 值 → SQL 字面量。默认实现覆盖三种方言的公共部分。
    fn literal(&self, value: &Value) -> String {
        match value {
            Value::Null => "NULL".to_string(),
            Value::Bool(flag) => self.bool_literal(*flag).to_string(),
            Value::Number(number) => number.to_string(),
            Value::String(text) => self.quote_string(text),
            Value::Object(map) => match map.get("__binary__").and_then(Value::as_str) {
                Some(encoded) => {
                    let bytes = {
                        use base64::Engine as _;
                        base64::engine::general_purpose::STANDARD
                            .decode(encoded)
                            .unwrap_or_default()
                    };
                    self.binary_literal(&hex::encode(bytes))
                }
                None => self.quote_string(&Value::Object(map.clone()).to_string()),
            },
            other => self.quote_string(&other.to_string()),
        }
    }

    // ------------------------------------------------------------ 元数据 SQL

    /// 实例级数据库列表。
    fn list_databases_sql(&self) -> SqlQuery;

    /// 当前数据库内的 schema/命名空间列表。
    fn list_schemas_sql(&self) -> SqlQuery;

    /// 一个命名空间里的表/视图。
    fn list_tables_sql(&self, namespace: &str) -> SqlQuery;

    /// 一个表的列信息。
    fn list_columns_sql(&self, namespace: &str, table: &str) -> SqlQuery;

    /// 对象的类型（TABLE / VIEW ...）。
    fn table_kind_sql(&self, namespace: &str, table: &str) -> SqlQuery;

    /// `SHOW CREATE TABLE` 等价物；不支持的方言返回明确错误。
    fn show_create_table_sql(&self, _namespace: &str, _table: &str) -> AppResult<SqlQuery> {
        Err(AppError::bad(format!(
            "{} 不支持 SHOW CREATE TABLE",
            self.driver_id()
        )))
    }

    /// 读取当前默认 schema/数据库的语句（用于 search_path 展示）。
    fn current_schema_sql(&self) -> Option<&'static str> {
        None
    }

    /// EXPLAIN 前缀；SQLite 需要 `EXPLAIN QUERY PLAN`。
    fn explain_sql(&self, statement: &str) -> String {
        format!("EXPLAIN {}", statement.trim())
    }

    // ------------------------------------------------- 服务器会话 / 取消（P2-4）

    /// 服务器会话列表；没有服务器概念的驱动返回 None。
    fn list_processes_sql(&self) -> Option<SqlQuery> {
        None
    }

    /// 按取消令牌模式串找出会话 id（MySQL 的 information_schema.PROCESSLIST）。
    fn find_session_ids_sql(&self, _pattern: &str) -> Option<SqlQuery> {
        None
    }

    /// 终止一个会话（MySQL 的 KILL CONNECTION {id}）。
    fn kill_session_sql(&self, _session_id: i64) -> Option<SqlQuery> {
        None
    }

    /// 按令牌模式串直接取消后端（PostgreSQL 的 pg_cancel_backend 批处理），
    /// 结果集里应包含布尔列 cancelled。
    fn cancel_backend_sql(&self, _pattern: &str) -> Option<SqlQuery> {
        None
    }

    /// 取消之后是否需要重建连接（MySQL 的 KILL 会杀掉整条连接）。
    fn reconnect_after_cancel(&self) -> bool {
        false
    }

    /// 用户可见的「已取消」文案。
    fn cancel_message(&self) -> &'static str {
        "查询已取消"
    }

    /// CREATE/DROP 后跟的关键字（MySQL 认 DATABASE 与 SCHEMA，PostgreSQL 只认
    /// DATABASE，SQLite 没有实例级库）。
    fn database_ddl_keywords(&self) -> &'static [&'static str] {
        &[]
    }

    /// 系统库/系统 schema，用于首次连接挑选初始库。
    ///
    /// P2-5 起默认取 protected_databases()，驱动只需要实现后者。
    fn system_databases(&self) -> &'static [&'static str] {
        self.protected_databases()
    }

    /// 受保护、不允许 DROP/RENAME 的数据库名单（P2-5）。
    fn protected_databases(&self) -> &'static [&'static str] {
        &[]
    }

    /// 受保护、不允许 CREATE/DROP 的 schema 名单（P2-5）。
    fn protected_schemas(&self) -> &'static [&'static str] {
        &[]
    }

    /// 临时对象前缀（PostgreSQL 的 pg_temp_* / pg_toast_temp_*）。
    fn protected_database_prefixes(&self) -> &'static [&'static str] {
        &[]
    }

    fn protected_schema_prefixes(&self) -> &'static [&'static str] {
        &[]
    }

    fn is_protected_database(&self, name: &str) -> bool {
        self.protected_databases().iter().any(|known| *known == name)
            || self
                .protected_database_prefixes()
                .iter()
                .any(|prefix| name.starts_with(prefix))
    }

    fn is_protected_schema(&self, name: &str) -> bool {
        self.protected_schemas().iter().any(|known| *known == name)
            || self
                .protected_schema_prefixes()
                .iter()
                .any(|prefix| name.starts_with(prefix))
    }

    /// SQLite 等无服务器概念的驱动返回 false：server 管理页据此跳过权限探测。
    fn supports_server_admin(&self) -> bool {
        true
    }

    // ------------------------------------------------- 服务器权限话术（P2-6）

    /// 缺少「查看服务器状态」权限时要补的 GRANT（用户可见文案）。
    fn status_privilege_hint(&self) -> &'static str {
        "相应的服务器权限"
    }

    /// 缺少「查看进程列表」权限时要补的 GRANT。
    fn process_privilege_hint(&self) -> &'static str {
        self.status_privilege_hint()
    }

    /// 缺少「终止会话」权限时要补的 GRANT。
    fn kill_privilege_hint(&self) -> &'static str {
        self.status_privilege_hint()
    }

    /// 缺少「管理数据库账号」权限时要补的 GRANT。
    fn account_privilege_hint(&self) -> &'static str {
        "相应的账号管理权限"
    }

    fn max_identifier_len(&self) -> usize {
        64
    }

    /// MySQL / SQLite 的「命名空间就是数据库」；PostgreSQL 不是。
    fn namespaces_are_databases(&self) -> bool {
        false
    }

    /// 是否支持 `USE <db>`。
    fn supports_use_statement(&self) -> bool {
        self.supports(DialectCapability::UseStatement)
    }

    /// 不支持 USE 时给用户的话术（各驱动写法不同，放在方言里）。
    fn use_statement_hint(&self) -> &'static str {
        "该数据库不支持 USE 语句"
    }

    /// 是否支持 DELIMITER / $$ 这类客户端脚本分隔符（MySQL / PG）。
    fn supports_delimiter_directive(&self) -> bool {
        false
    }

    /// 语句分隔符；SQLite 仍是分号，保留钩子给未来方言。
    fn statement_separator(&self) -> &'static str {
        ";"
    }

    fn supports(&self, capability: DialectCapability) -> bool;

    // --------------------------------------------------------------- DDL 文本
    //
    // 33 轮拆 crate 时新增：建表/改表的 SQL 文本由方言提供，drivers::ops 只做
    // 与驱动无关的校验和 PostgreSQL 注释语句的组装。默认实现报「不支持」，
    // 三个内置驱动都在各自的 dialect.rs 覆盖。

    /// 建表 DDL（单条 CREATE TABLE）。
    fn create_table_sql(&self, _namespace: &str, _spec: &CreateTableSpec) -> AppResult<String> {
        Err(AppError::bad(format!(
            "{} 不支持生成建表语句",
            self.driver_id()
        )))
    }

    /// ALTER TABLE 批次语句。
    fn alter_table_statements(
        &self,
        _namespace: &str,
        _table: &str,
        _spec: &AlterTableSpec,
    ) -> AppResult<Vec<String>> {
        Err(AppError::bad(format!(
            "{} 不支持修改表结构",
            self.driver_id()
        )))
    }
}
