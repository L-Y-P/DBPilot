//! Application error type shared by every module.
//!
//! The web build turned these into HTTP status codes. A desktop build has no
//! transport, so only the human-readable message crosses the FFI boundary; the
//! status mapping is kept because the SQL layer still classifies user errors
//! (BadRequest) apart from genuine faults (Internal).
//!
//! Database errors get special treatment: sqlx's Display reads
//! 'error returned from database: 1142 (42000): SELECT command denied ...' and
//! its source() repeats the same sentence, which surfaced in the UI as
//! 'error returned from database: ... / Caused by: ...'. clean_database_error
//! turns that into one short sentence, and maps the common permission codes to
//! an explanation of which privilege is missing.

use serde_json::json;

#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("{0}")]
    Unauthorized(String),
    #[error("{0}")]
    BadRequest(String),
    #[error("{0}")]
    NotFound(String),
    #[error("{0}")]
    Forbidden(String),
    /// The database rejected the statement. The payload is already a
    /// user-facing sentence (see clean_database_error), never a raw sqlx
    /// display string.
    #[error("{0}")]
    Database(String),
    #[error("{0}")]
    Internal(String),
}

impl AppError {
    /// Coarse classification, mirroring the HTTP status the web build used.
    pub fn kind(&self) -> &'static str {
        match self {
            AppError::Unauthorized(_) => "unauthorized",
            AppError::BadRequest(_) => "bad_request",
            AppError::NotFound(_) => "not_found",
            AppError::Forbidden(_) => "forbidden",
            AppError::Database(_) => "bad_request",
            AppError::Internal(_) => "internal",
        }
    }

    /// True for errors the user can fix by changing their input.
    pub fn is_user_error(&self) -> bool {
        matches!(self.kind(), "bad_request" | "not_found" | "forbidden" | "unauthorized")
    }

    pub fn bad<T: Into<String>>(msg: T) -> Self {
        AppError::BadRequest(msg.into())
    }
    pub fn not_found<T: Into<String>>(msg: T) -> Self {
        AppError::NotFound(msg.into())
    }
}

impl From<sqlx::Error> for AppError {
    fn from(e: sqlx::Error) -> Self {
        match e {
            sqlx::Error::Database(db) => AppError::Database(clean_database_error(db.as_ref())),
            sqlx::Error::RowNotFound => AppError::not_found("没有找到匹配的数据行"),
            other => AppError::Internal(strip_caused_by(&other.to_string())),
        }
    }
}

impl From<anyhow::Error> for AppError {
    fn from(e: anyhow::Error) -> Self {
        AppError::Internal(strip_caused_by(&format!("{:#}", e)))
    }
}

impl AppError {
    /// Reword a failure as "无法打开数据库 X：…".
    ///
    /// Opening a pool for one database can fail because that database rejects
    /// the account (MySQL 1044). Reporting it as "MySQL 连接失败" made a
    /// per-database permission problem look like the whole connection had
    /// dropped, which is how a limited account's error read in the sidebar.
    pub fn for_database(self, database: &str) -> Self {
        // The driver layer may already have named the database (1044 is mapped
        // there so the connect path is covered too); never stack the prefix.
        if self.to_string().starts_with("无法打开数据库 ") {
            return self;
        }
        let message = format!("无法打开数据库 {database}：{}", self);
        match self {
            AppError::Unauthorized(_) => AppError::Unauthorized(message),
            AppError::BadRequest(_) => AppError::BadRequest(message),
            AppError::NotFound(_) => AppError::NotFound(message),
            AppError::Forbidden(_) => AppError::Forbidden(message),
            AppError::Database(_) => AppError::Database(message),
            AppError::Internal(_) => AppError::Internal(message),
        }
    }

    /// Serialize as the {"error": ..., "kind": ...} shape the web API returned,
    /// so the ported UI code can keep reading 'error'.
    pub fn to_json(&self) -> serde_json::Value {
        json!({ "error": self.to_string(), "kind": self.kind() })
    }
}

pub type AppResult<T> = Result<T, AppError>;

/// Drop anyhow's 'Caused by:' chain and sqlx's generic prefix.
///
/// sqlx errors are transparent over the driver error, so anyhow printed the
/// same sentence twice (once as the error, once as its cause). Nothing in this
/// app benefits from the duplicated tail.
pub fn strip_caused_by(message: &str) -> String {
    let mut out = message.trim();
    for marker in ["\n\nCaused by:", "\nCaused by:"] {
        if let Some(index) = out.find(marker) {
            out = &out[..index];
        }
    }
    let cleaned = out
        .trim()
        .trim_start_matches("error returned from database: ")
        .trim()
        .to_string();
    if cleaned.is_empty() {
        "数据库返回了一个错误".to_string()
    } else {
        cleaned
    }
}

/// Turn a driver error into one short, actionable sentence.
///
/// Permission failures are the common case here (a connection whose database
/// account only owns one schema), so they get a Chinese explanation naming the
/// privilege that is missing instead of MySQL's terse English text.
pub fn clean_database_error(db: &dyn sqlx::error::DatabaseError) -> String {
    // sqlx exposes the SQLSTATE (e.g. "42000"), but MySQL prefixes its message
    // with the driver error number ("1142 (42000): ..."), and that number is
    // what distinguishes "table denied" from "database denied". Prefer it.
    let sqlstate = db.code().unwrap_or_default().to_string();
    let raw = strip_caused_by(db.message());
    // MySQL reports "No database selected" with SQLSTATE 3D000, which is also
    // PostgreSQL's invalid_catalog_name code. Matching the code alone produced
    // the misleading "数据库不存在或当前角色无权连接该数据库" (the database
    // exists; the session simply has no default database).
    if raw.to_ascii_lowercase().contains("no database selected") {
        return "未选择数据库：当前连接没有默认数据库，请先执行 USE <数据库> 再执行该语句。"
            .to_string();
    }
    let (number, message) = split_driver_code(&raw);
    let code = if number.is_empty() { sqlstate } else { number };
    // sqlx's DatabaseError::message() has already dropped MySQL's numeric
    // prefix ("1142 (42000): ") and only code() carries the SQLSTATE, so the
    // numeric path above only helps for drivers that keep it. Fall back to the
    // message text, which is unambiguous for permission failures.
    let hint = permission_hint(&code).or_else(|| permission_hint_from_message(&message));
    match hint {
        Some(hint) => format!("{hint}\n数据库原始信息：{message}（错误码 {code}）"),
        None if code.is_empty() => message,
        None => format!("{message}（错误码 {code}）"),
    }
}

/// Recognise the permission failures from the driver's own wording.
fn permission_hint_from_message(message: &str) -> Option<&'static str> {
    let lower = message.to_ascii_lowercase();
    let hint = if lower.contains("access denied for user")
        && (lower.contains("to database") || lower.contains("using password"))
    {
        if lower.contains("using password") {
            "用户名或密码不正确，或该账号不允许从当前主机登录。"
        } else {
            "当前数据库账号没有访问该数据库的权限。请让管理员执行 GRANT ... ON 该库.* TO 该账号，或改用有权限的账号连接。"
        }
    } else if lower.contains("command denied") {
        "当前数据库账号缺少该操作所需的表级权限。请让数据库管理员补授对应的 SELECT / INSERT / UPDATE / DELETE 等权限。"
    } else if lower.contains("permission denied") || lower.contains("insufficient privilege") {
        "当前数据库角色权限不足。请让管理员补授相应的 GRANT，或改用有权限的角色连接。"
    } else if lower.contains("must have") && lower.contains("privilege") {
        "当前数据库账号缺少执行该语句所需的服务器级权限。"
    } else {
        return None;
    };
    Some(hint)
}

/// Split a leading "1142 (42000): " / "42501: " driver prefix off a message.
fn split_driver_code(message: &str) -> (String, String) {
    let head = message.split(':').next().unwrap_or("").trim();
    let number = head
        .split_whitespace()
        .next()
        .unwrap_or("")
        .trim_matches(|c: char| !c.is_ascii_alphanumeric())
        .to_string();
    let looks_like_code = !number.is_empty()
        && number.len() <= 5
        && number.chars().any(|c| c.is_ascii_digit())
        && number.chars().all(|c| c.is_ascii_alphanumeric());
    if !looks_like_code {
        return (String::new(), message.to_string());
    }
    let rest = message
        .split_once(':')
        .map(|(_, tail)| tail.trim().to_string())
        .unwrap_or_else(|| message.to_string());
    (number, if rest.is_empty() { message.to_string() } else { rest })
}

/// Message for a statement that failed, used by the ResultSet error field.
pub fn database_message(error: &sqlx::Error) -> String {
    match error {
        sqlx::Error::Database(db) => clean_database_error(db.as_ref()),
        other => strip_caused_by(&other.to_string()),
    }
}

/// Test hook: the code-based permission explanation.
pub fn permission_hint_for_test(code: &str) -> Option<&'static str> {
    permission_hint(code)
}

/// Test hook: the message-based permission explanation.
pub fn permission_hint_from_message_test(message: &str) -> Option<&'static str> {
    permission_hint_from_message(message)
}

/// Explain the permission-related error codes of the three drivers.
fn permission_hint(code: &str) -> Option<&'static str> {
    let hint = match code {
        // MySQL / MariaDB
        "1044" => "当前数据库账号没有访问该数据库的权限。请让管理员执行 GRANT ... ON 该库.* TO 该账号，或改用有权限的账号连接。",
        "1142" => "当前数据库账号缺少该操作所需的表级权限。请让管理员补授对应的 SELECT / INSERT / UPDATE / DELETE 等权限。",
        "1143" => "当前数据库账号缺少该列的操作权限。",
        "1227" => "当前数据库账号缺少服务器级权限（需要 SUPER、SYSTEM_VARIABLES_ADMIN、SESSION_VARIABLES_ADMIN 之一）。",
        "1045" => "用户名或密码不正确，或该账号不允许从当前主机登录。",
        "1146" => "表不存在：可能已被删除，或当前库选择错误。",
        "1049" => "数据库不存在：可能已被删除，或名称拼写错误。",
        // PostgreSQL
        "42501" => "当前数据库角色权限不足。请让管理员补授相应的 GRANT，或改用有权限的角色连接。",
        "3D000" => "数据库不存在或当前角色无权连接该数据库。",
        "28P01" => "用户名或密码不正确。",
        // SQLite
        "8" => "数据库文件只读，当前无法写入。",
        _ => return None,
    };
    Some(hint)
}
