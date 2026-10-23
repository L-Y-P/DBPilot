use serde_json::{json, Map, Value};

use sqlx::mysql::{MySqlConnectOptions, MySqlPool, MySqlSslMode};

pub mod account;
pub mod dialect;
pub mod driver;
pub mod exec;
pub mod row;

use crate::core::connection::ConnectionHandle;
use crate::core::dialect::DatabaseDialect;
use crate::drivers::{qi, qualify, quote_str_for, safe_ident, ColumnDef, ConnSpec, CreateTableSpec, DriverKind};
use crate::error::{AppError, AppResult};

/// TLS mode for MySQL.
///
/// `require` encrypts but accepts any certificate; `verify-ca` validates the
/// chain; `verify-full` also matches the host name. Anything else disables TLS.
pub fn ssl_mode_for(spec: &ConnSpec) -> MySqlSslMode {
    if !matches!(spec.ssl_mode(), "require" | "prefer") {
        return MySqlSslMode::Disabled;
    }
    match spec.ssl_verify().as_str() {
        "verify-full" => MySqlSslMode::VerifyIdentity,
        "verify-ca" => MySqlSslMode::VerifyCa,
        _ => MySqlSslMode::Required,
    }
}

/// Character sets sqlx's MySQL client accepts in the handshake.
///
/// Mirrors `CharSet::from_str` in sqlx-mysql. MySQL's own
/// `information_schema.CHARACTER_SETS` is wider than this list: MySQL 8.x still
/// advertises `utf8mb3`, but the client has no entry for that spelling and
/// fails the connection with `unsupported MySQL charset: utf8mb3` (round34
/// P2-02), so the alias is rewritten below instead.
const MYSQL_CLIENT_CHARSETS: &[&str] = &[
    "armscii8", "ascii", "big5", "binary", "cp1250", "cp1251", "cp1256", "cp1257", "cp850",
    "cp852", "cp866", "cp932", "dec8", "eucjpms", "euckr", "gb18030", "gb2312", "gbk", "geostd8",
    "greek", "hebrew", "hp8", "keybcs2", "koi8r", "koi8u", "latin1", "latin2", "latin5", "latin7",
    "macce", "macroman", "sjis", "swe7", "tis620", "ucs2", "ujis", "utf16", "utf16le", "utf32",
    "utf8", "utf8mb4",
];

/// Character set name to put in the MySQL handshake.
///
/// Empty / missing keeps the driver default (`utf8mb4`). `utf8mb3` is MySQL
/// 8.x's spelling of the 3-byte UTF-8 encoding the client calls `utf8`; mapping
/// it lets a connection already saved with `utf8mb3` open instead of dying on
/// the client's own allow-list. Anything else the client cannot encode is
/// rejected here, in Chinese copy that the UI translates (en_backend), rather
/// than surfacing sqlx's English `unsupported MySQL charset` string.
pub fn connection_charset(raw: Option<&str>) -> AppResult<String> {
    let trimmed = raw.unwrap_or("").trim();
    if trimmed.is_empty() {
        return Ok("utf8mb4".to_string());
    }
    let lower = trimmed.to_ascii_lowercase();
    let mapped = if lower == "utf8mb3" { "utf8" } else { lower.as_str() };
    if MYSQL_CLIENT_CHARSETS.contains(&mapped) {
        return Ok(mapped.to_string());
    }
    Err(AppError::bad(format!(
        "不支持的 MySQL 字符集 '{}'：请改用服务端支持的名称（如 utf8mb4、utf8、latin1）",
        trimmed
    )))
}

/// Connection options built field by field.
///
/// The URL form cannot express ssl-mode / CA files safely (and used to hard-code
/// `ssl-mode=DISABLED`, so "require" silently connected in plaintext). The URL
/// is still parsed so the percent-encoding rules for user / password / charset
/// stay in one place, then the TLS settings are applied on top.
pub fn connect_options(spec: &ConnSpec, database: Option<&str>) -> AppResult<MySqlConnectOptions> {
    // The charset goes through the client's capability list first: an unknown
    // name (including MySQL 8.x's `utf8mb3` spelling) is rejected here with a
    // translatable message instead of at handshake time with sqlx's English
    // "unsupported MySQL charset".
    let charset = connection_charset(spec.charset.as_deref())?;
    let mut opts = MySqlConnectOptions::new()
        .host(spec.host.trim())
        .port(spec.port())
        .username(&spec.user)
        .charset(&charset)
        .ssl_mode(ssl_mode_for(spec));
    // 空密码时**不要**调 .password("")：sqlx 会把 Some("") 当成「带密码」处理，
    // 在 caching_sha2_password + 非 TLS（本应用默认 ssl_mode=disable）下会走
    // scramble 而非 cleartext 分支，服务端收到非空认证响应后报
    // “Access denied ... (using password: YES)”，连空密码账号也连不上。
    // 不设置密码时 sqlx 发送 0 长度响应，服务端才按「无密码」校验。
    if !spec.password.is_empty() {
        opts = opts.password(&spec.password);
    }
    if let Some(db) = database.or_else(|| spec.database()) {
        opts = opts.database(db);
    }
    if let Some(ca) = spec.ssl_ca() {
        opts = opts.ssl_ca(ca);
    }
    if let Some(cert) = spec.ssl_cert() {
        opts = opts.ssl_client_cert(cert);
    }
    if let Some(key) = spec.ssl_key() {
        opts = opts.ssl_client_key(key);
    }
    Ok(opts)
}

// NOTE: this module used to build a `mysql://` URL string with
// `&ssl-mode=DISABLED` baked in, plus a `connect_pool` that used it. Both are
// gone: the URL form cannot carry CA / client certificates and is exactly how
// the "require" setting silently ran in plaintext. Use `connect_options()`
// through `drivers::connect` instead.

pub async fn run_one(pool: &MySqlPool, stmt: String) -> crate::db::ResultSet {
    exec::run_one(pool, stmt).await
}

pub async fn version(pool: &MySqlPool) -> AppResult<String> {
    let rs = exec::run_one(pool, "SELECT VERSION() AS v".to_string()).await;
    if let Some(e) = rs.error {
        return Err(AppError::bad(e));
    }
    Ok(rs
        .rows
        .first()
        .and_then(|r| r.first())
        .map(|v| match v {
            Value::String(s) => s.clone(),
            other => other.to_string(),
        })
        .unwrap_or_default())
}

/// Databases this account can browse, with their charset / collation.
///
/// `information_schema.SCHEMATA` lists `performance_schema` for every account
/// (and on 8.0 also any database the account may not open), so filtering the
/// tree by that list alone still offered databases whose every click failed
/// with MySQL 1044. The list is narrowed to schemas the account holds a grant
/// on; a global grant (`*.*`, which `ALL PRIVILEGES` implies) sees everything.
pub async fn namespaces(conn: &ConnectionHandle) -> AppResult<Vec<Value>> {
    let all = all_namespaces(conn).await?;
    let Some(granted) = granted_schema_filter(conn).await else {
        // No grant filter available (SHOW GRANTS failed) or a global grant:
        // list everything and let the server reject what it must.
        return Ok(all);
    };
    Ok(filter_namespaces(all, &granted))
}

/// Every schema the server lists, regardless of grants.
///
/// Used where grants are being *edited*: an administrator must be able to pick
/// a database the connecting account itself does not own.
pub async fn all_namespaces(conn: &ConnectionHandle) -> AppResult<Vec<Value>> {
    // SQL 文本由方言拥有（drivers/mysql/dialect.rs），这里只负责执行。
    conn.fetch_named(dialect::MYSQL_DIALECT.list_databases_sql().sql)
        .await
}

/// Keep only the schemas the account may open.
///
/// `information_schema` is metadata every account can read regardless of
/// grants, so it survives the filter. Everything else must be named by an
/// actual grant; otherwise the tree offers a database whose every click fails
/// with MySQL 1044 (the reported bug: a `web` account owning only `web` was
/// still shown `performance_schema`, which `SHOW DATABASES` reports for every
/// account).
fn filter_namespaces(all: Vec<Value>, granted: &[String]) -> Vec<Value> {
    all.into_iter()
        .filter(|row| match row.get("name").and_then(|v| v.as_str()) {
            Some("information_schema") => true,
            Some(name) => granted.iter().any(|g| g == name),
            None => false,
        })
        .collect()
}

/// Privileges that imply access to the schema they are granted on.
///
/// A *global* grant of one of these (`SELECT ON *.*`, `ALL PRIVILEGES ON *.*`)
/// reaches every database. Server-level privileges such as `PROCESS` or
/// `SHOW DATABASES` do **not**: an account may inspect the server while still
/// being unable to `USE` another account's schema, which is exactly the
/// situation that made the sidebar offer `performance_schema` and then fail.
const SCHEMA_PRIVILEGES: &[&str] = &[
    "ALL PRIVILEGES",
    "SELECT",
    "INSERT",
    "UPDATE",
    "DELETE",
    "CREATE",
    "DROP",
    "ALTER",
    "INDEX",
    "REFERENCES",
    "CREATE VIEW",
    "SHOW VIEW",
    "TRIGGER",
    "EXECUTE",
    "CREATE ROUTINE",
    "ALTER ROUTINE",
    "EVENT",
    "LOCK TABLES",
    "CREATE TEMPORARY TABLES",
];

/// Schemas mentioned by `SHOW GRANTS`, or `None` when every schema is allowed.
///
/// `None` means "do not filter": the grants could not be read, or a *global
/// schema privilege* is held. Table- and column-level grants imply access to
/// their schema, and MySQL 8 expands role privileges into their own lines, so
/// role members need no role-catalog query (which differs between 5.7 and 8.x).
///
/// `GRANT USAGE ON *.*` is the no-op line every account has and is skipped:
/// USAGE means "no privileges here", so treating it as a global grant would
/// disable the filter for every account (which is the bug this function fixes).
fn visible_schema_scopes(lines: &[String]) -> Option<Vec<String>> {
    let mut scopes: Vec<String> = Vec::new();
    for line in lines {
        let upper = line.to_ascii_uppercase();
        if !upper.starts_with("GRANT ") {
            continue;
        }
        // Role grants have no ON clause; their privileges appear on their own
        // expanded lines in MySQL 8.
        let Some(on) = upper.find(" ON ") else { continue };
        let privileges: Vec<&str> = upper[6..on]
            .split(',')
            .map(str::trim)
            .filter(|p| !p.is_empty() && *p != "USAGE")
            .collect();
        if privileges.is_empty() {
            continue;
        }
        let rest = &line[on + 4..];
        let rest_upper = rest.to_ascii_uppercase();
        let Some(to) = rest_upper.find(" TO ") else { continue };
        let Some(schema) = split_scope(rest[..to].trim()).first().cloned() else {
            continue;
        };
        if schema == "*" {
            // A global *schema* privilege reaches every database; a global
            // server privilege (PROCESS, RELOAD, SHOW DATABASES, …) does not.
            if privileges
                .iter()
                .any(|p| SCHEMA_PRIVILEGES.contains(p))
            {
                return None;
            }
            continue;
        }
        if !schema.is_empty() && !scopes.iter().any(|s| *s == schema) {
            scopes.push(schema);
        }
    }
    Some(scopes)
}

/// Read the account's grants and derive the schemas it can browse.
async fn granted_schema_filter(conn: &ConnectionHandle) -> Option<Vec<String>> {
    let rows = conn.fetch_named("SHOW GRANTS".to_string()).await.ok()?;
    let lines: Vec<String> = rows
        .iter()
        .filter_map(|row| {
            row.as_object()
                .and_then(|object| object.values().next())
                .and_then(|value| value.as_str())
                .map(str::to_string)
        })
        .collect();
    visible_schema_scopes(&lines)
}


/// INSERT one row inside a transaction, read it back with a null-safe
/// predicate and always roll back. Used by the import probe ("试插入") so the
/// user can see the effect without committing anything.
pub async fn probe_insert(pool: &MySqlPool, insert: &str, select: &str) -> AppResult<Value> {
    let mut tx = pool
        .begin()
        .await
        .map_err(|e| AppError::bad(crate::error::database_message(&e)))?;
    let affected = match sqlx::query(insert).execute(&mut *tx).await {
        Ok(result) => result.rows_affected(),
        Err(e) => {
            let _ = tx.rollback().await;
            return Err(AppError::bad(crate::error::database_message(&e)));
        }
    };
    let row = match sqlx::query(select).fetch_optional(&mut *tx).await {
        Ok(Some(row)) => {
            let columns = row::columns_meta(&row);
            let values = row::row_values(&row);
            let mut map = Map::new();
            for (i, column) in columns.iter().enumerate() {
                map.insert(
                    column.name.clone(),
                    values.get(i).cloned().unwrap_or(Value::Null),
                );
            }
            Value::Object(map)
        }
        _ => Value::Null,
    };
    let _ = tx.rollback().await;
    Ok(json!({ "affected": affected, "row": row }))
}

pub async fn tables(conn: &ConnectionHandle, ns: &str) -> AppResult<Vec<Value>> {
    conn.fetch_named(dialect::MYSQL_DIALECT.list_tables_sql(ns).sql)
        .await
}

pub async fn object_kind(conn: &ConnectionHandle, ns: &str, table: &str) -> AppResult<Option<String>> {
    let rows = conn
        .fetch_named(dialect::MYSQL_DIALECT.table_kind_sql(ns, table).sql)
        .await?;
    Ok(rows
        .first()
        .and_then(|r| r.get("kind"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string()))
}

fn column_meta_value(
    name: &str,
    data_type: &str,
    column_type: &str,
    nullable: &str,
    default: Value,
    key: &str,
    extra: &str,
    comment: &str,
    charset: Value,
    collation: Value,
    position: i64,
    precision: Value,
    scale: Value,
) -> Value {
    json!({
        "name": name,
        "type_name": column_type,
        "COLUMN_NAME": name,
        "DATA_TYPE": data_type,
        "COLUMN_TYPE": column_type,
        "IS_NULLABLE": nullable,
        "COLUMN_DEFAULT": default,
        "COLUMN_KEY": key,
        "EXTRA": extra,
        "COLUMN_COMMENT": comment,
        "CHARACTER_SET_NAME": charset,
        "COLLATION_NAME": collation,
        "ORDINAL_POSITION": position,
        "NUMERIC_PRECISION": precision,
        "NUMERIC_SCALE": scale,
    })
}

pub async fn structure(conn: &ConnectionHandle, ns: &str, table: &str) -> AppResult<Value> {
    let info_rows = conn
        .fetch_named(format!(
            "SELECT TABLE_TYPE, ENGINE, TABLE_ROWS, DATA_LENGTH, INDEX_LENGTH, TABLE_COLLATION, TABLE_COMMENT, CREATE_TIME, UPDATE_TIME, AUTO_INCREMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA = {} AND TABLE_NAME = {}",
            quote_str_for(conn.driver_kind(), ns),
            quote_str_for(conn.driver_kind(), table)
        ))
        .await?;
    let info = info_rows
        .into_iter()
        .next()
        .ok_or_else(|| AppError::not_found(format!("table '{}' does not exist", table)))?;

    let raw_columns = conn
        .fetch_named(dialect::MYSQL_DIALECT.list_columns_sql(ns, table).sql)
        .await?;

    let mut columns = Vec::new();
    for c in raw_columns {
        let get = |k: &str| c.get(k).cloned().unwrap_or(Value::Null);
        let s = |k: &str| get(k).as_str().unwrap_or_default().to_string();
        columns.push(column_meta_value(
            &s("COLUMN_NAME"),
            &s("DATA_TYPE"),
            &s("COLUMN_TYPE"),
            &s("IS_NULLABLE"),
            get("COLUMN_DEFAULT"),
            &s("COLUMN_KEY"),
            &s("EXTRA"),
            &s("COLUMN_COMMENT"),
            get("CHARACTER_SET_NAME"),
            get("COLLATION_NAME"),
            get("ORDINAL_POSITION").as_i64().unwrap_or(0),
            get("NUMERIC_PRECISION"),
            get("NUMERIC_SCALE"),
        ));
    }

    let indexes = conn
        .fetch_named(format!(
            "SELECT INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME, COLLATION, CARDINALITY, INDEX_TYPE FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = {} AND TABLE_NAME = {} ORDER BY INDEX_NAME, SEQ_IN_INDEX",
            quote_str_for(conn.driver_kind(), ns),
            quote_str_for(conn.driver_kind(), table)
        ))
        .await?;

    let pk_rows = conn
        .fetch_named(format!(
            "SELECT COLUMN_NAME FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = {} AND TABLE_NAME = {} AND INDEX_NAME = 'PRIMARY' ORDER BY SEQ_IN_INDEX",
            quote_str_for(conn.driver_kind(), ns),
            quote_str_for(conn.driver_kind(), table)
        ))
        .await?;
    let primary_key: Vec<Value> = pk_rows
        .iter()
        .filter_map(|r| r.get("COLUMN_NAME").cloned())
        .collect();

    let foreign_keys = conn
        .fetch_named(format!(
            "SELECT kcu.CONSTRAINT_NAME, kcu.COLUMN_NAME, kcu.REFERENCED_TABLE_NAME, kcu.REFERENCED_COLUMN_NAME, rc.DELETE_RULE, rc.UPDATE_RULE FROM information_schema.KEY_COLUMN_USAGE kcu JOIN information_schema.REFERENTIAL_CONSTRAINTS rc ON rc.CONSTRAINT_SCHEMA = kcu.CONSTRAINT_SCHEMA AND rc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME WHERE kcu.TABLE_SCHEMA = {} AND kcu.TABLE_NAME = {} AND kcu.REFERENCED_TABLE_NAME IS NOT NULL ORDER BY kcu.CONSTRAINT_NAME, kcu.ORDINAL_POSITION",
            quote_str_for(conn.driver_kind(), ns),
            quote_str_for(conn.driver_kind(), table)
        ))
        .await
        .unwrap_or_default();

    Ok(json!({
        "database": ns,
        "table": table,
        "info": info,
        "columns": columns,
        "indexes": indexes,
        "primary_key": primary_key,
        "foreign_keys": foreign_keys,
    }))
}

pub async fn overview(conn: &ConnectionHandle) -> AppResult<Value> {
    let version = version_of(conn).await;
    let comment = conn
        .fetch_string("SELECT @@version_comment".to_string())
        .await
        .unwrap_or_default();
    let status_rows = conn.fetch_named("SHOW GLOBAL STATUS".to_string()).await?;
    let mut map = Map::new();
    for row in &status_rows {
        let k = row.get("Variable_name").and_then(|v| v.as_str()).unwrap_or_default();
        let v = row.get("Value").cloned().unwrap_or(Value::Null);
        if !k.is_empty() {
            map.insert(k.to_string(), v);
        }
    }
    let all = Value::Object(map);
    let get = |key: &str| all.get(key).cloned().unwrap_or(Value::Null);
    let database_count = conn
        .fetch_i64("SELECT COUNT(*) FROM information_schema.SCHEMATA".to_string())
        .await
        .unwrap_or(0);
    let table_count = conn
        .fetch_i64("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')".to_string())
        .await
        .unwrap_or(0);
    Ok(json!({
        "version": version,
        "version_comment": comment,
        "uptime": get("Uptime"),
        "threads_connected": get("Threads_connected"),
        "threads_running": get("Threads_running"),
        "queries": get("Queries"),
        "questions": get("Questions"),
        "slow_queries": get("Slow_queries"),
        "connections": get("Connections"),
        "bytes_received": get("Bytes_received"),
        "bytes_sent": get("Bytes_sent"),
        "aborted_connects": get("Aborted_connects"),
        "database_count": database_count,
        "table_count": table_count,
        "status": all,
    }))
}

async fn version_of(conn: &ConnectionHandle) -> String {
    // P4：不再借用具体池，直接用句柄查询（与 mysql::version 同一条 SQL）。
    conn.query_string("SELECT VERSION() AS v").await.unwrap_or_default()
}

pub async fn variables(conn: &ConnectionHandle, filter: Option<&str>) -> AppResult<Vec<Value>> {
    let mut rows = conn.fetch_named("SHOW GLOBAL VARIABLES".to_string()).await?;
    if let Some(f) = filter {
        let needle = f.to_lowercase();
        rows.retain(|v| {
            v.get("Variable_name")
                .and_then(|x| x.as_str())
                .map(|s| s.to_lowercase().contains(&needle))
                .unwrap_or(false)
        });
    }
    Ok(rows)
}

pub async fn processes(conn: &ConnectionHandle) -> AppResult<Vec<Value>> {
    // P2-4：SQL 的唯一归属在方言；这里是旧门面的兼容入口。
    match dialect::MYSQL_DIALECT.list_processes_sql() {
        Some(query) => conn.fetch_named(query.sql).await,
        None => Ok(Vec::new()),
    }
}

pub async fn users(conn: &ConnectionHandle) -> AppResult<Vec<Value>> {
    match conn.fetch_named("SELECT user, host, plugin, account_locked FROM mysql.user ORDER BY user, host".to_string()).await {
        Ok(rows) => Ok(rows),
        Err(_) => conn.fetch_named("SELECT user, host, plugin FROM mysql.user ORDER BY user, host".to_string()).await,
    }
}

pub async fn builder_schema(conn: &ConnectionHandle, ns: &str) -> AppResult<Value> {
    let columns = conn
        .fetch_named(format!(
            "SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE AS data_type, IS_NULLABLE, COLUMN_KEY FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = {} ORDER BY TABLE_NAME, ORDINAL_POSITION",
            quote_str_for(conn.driver_kind(), ns)
        ))
        .await?;
    let fks = conn
        .fetch_named(format!(
            "SELECT TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA = {} AND REFERENCED_TABLE_NAME IS NOT NULL",
            quote_str_for(conn.driver_kind(), ns)
        ))
        .await
        .unwrap_or_default();

    let mut tables: Vec<(String, Vec<Value>, Vec<Value>)> = Vec::new();
    for row in columns {
        let tname = row.get("TABLE_NAME").and_then(|v| v.as_str()).unwrap_or_default().to_string();
        let col = json!({
            "name": row.get("COLUMN_NAME").cloned().unwrap_or(Value::Null),
            "type": row.get("data_type").cloned().unwrap_or(Value::Null),
            "nullable": row.get("IS_NULLABLE").and_then(|v| v.as_str()).map(|s| s == "YES").unwrap_or(true),
            "key": row.get("COLUMN_KEY").cloned().unwrap_or(Value::Null),
        });
        match tables.iter_mut().find(|(n, _, _)| *n == tname) {
            Some((_, cols, _)) => cols.push(col),
            None => tables.push((tname, vec![col], Vec::new())),
        }
    }
    for row in fks {
        let tname = row.get("TABLE_NAME").and_then(|v| v.as_str()).unwrap_or_default().to_string();
        let fk = json!({
            "column": row.get("COLUMN_NAME").cloned().unwrap_or(Value::Null),
            "ref_table": row.get("REFERENCED_TABLE_NAME").cloned().unwrap_or(Value::Null),
            "ref_column": row.get("REFERENCED_COLUMN_NAME").cloned().unwrap_or(Value::Null),
        });
        if let Some((_, _, list)) = tables.iter_mut().find(|(n, _, _)| *n == tname) {
            list.push(fk);
        }
    }

    let tables: Vec<Value> = tables
        .into_iter()
        .map(|(name, columns, foreign_keys)| json!({ "name": name, "columns": columns, "foreign_keys": foreign_keys }))
        .collect();
    Ok(json!({ "schema": ns, "tables": tables }))
}

pub async fn table_ddl(conn: &ConnectionHandle, ns: &str, table: &str) -> AppResult<Option<String>> {
    let rs = conn
        .run_one(format!("SHOW CREATE TABLE {}", qualify(conn.driver_kind(), ns, table)))
        .await;
    if let Some(e) = rs.error {
        return Err(AppError::bad(e));
    }
    Ok(rs
        .rows
        .first()
        .and_then(|r| r.get(1).cloned())
        .and_then(|v| v.as_str().map(|s| s.to_string())))
}

pub fn create_table_sql(driver: crate::drivers::DriverKind, ns: &str, spec: &CreateTableSpec) -> AppResult<String> {
    let mut defs: Vec<String> = Vec::new();
    let mut primary: Vec<String> = Vec::new();
    for column in &spec.columns {
        let name = column.name.trim();
        let mut def = format!("{} {}", qi(driver, name), column.col_type.trim());
        if let Some(charset) = column.charset.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            def.push_str(&format!(" CHARACTER SET {}", safe_ident(charset)?));
        }
        if let Some(collation) = column.collation.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            def.push_str(&format!(" COLLATE {}", safe_ident(collation)?));
        }
        def.push_str(if column.nullable { " NULL" } else { " NOT NULL" });
        if let Some(value) = column.default.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            def.push_str(&format!(" DEFAULT {}", crate::drivers::safe_default(value)?));
        }
        if column.auto_increment {
            def.push_str(" AUTO_INCREMENT");
        }
        if let Some(comment) = column.comment.as_deref().filter(|s| !s.is_empty()) {
            def.push_str(&format!(" COMMENT {}", quote_str_for(driver, comment)));
        }
        if column.primary {
            primary.push(qi(driver, name));
        }
        defs.push(def);
    }
    if !primary.is_empty() {
        defs.push(format!("PRIMARY KEY ({})", primary.join(", ")));
    }
    for fk in &spec.foreign_keys {
        defs.push(crate::drivers::fk_constraint_sql(driver, &spec.name, fk)?);
    }
    let mut sql = format!("CREATE TABLE {} (\n  {}\n)", qualify(driver, ns, &spec.name), defs.join(",\n  "));
    if let Some(engine) = spec.engine.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        sql.push_str(&format!(" ENGINE={}", safe_ident(engine)?));
    }
    if let Some(charset) = spec.charset.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        sql.push_str(&format!(" DEFAULT CHARSET={}", safe_ident(charset)?));
    }
    if let Some(collation) = spec.collation.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        sql.push_str(&format!(" COLLATE={}", safe_ident(collation)?));
    }
    if let Some(row_format) = spec.row_format.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        sql.push_str(&format!(" ROW_FORMAT={}", safe_ident(row_format)?));
    }
    if let Some(auto_increment) = spec.auto_increment {
        sql.push_str(&format!(" AUTO_INCREMENT={}", auto_increment));
    }
    if let Some(comment) = spec.comment.as_deref().filter(|s| !s.is_empty()) {
        sql.push_str(&format!(" COMMENT={}", quote_str_for(driver, comment)));
    }
    Ok(sql)
}

pub async fn meta_options(conn: &ConnectionHandle) -> AppResult<Value> {
    let charsets = conn
        .fetch_named(
            "SELECT CHARACTER_SET_NAME AS charset, DEFAULT_COLLATE_NAME AS default_collation, MAXLEN AS maxlen, DESCRIPTION AS description FROM information_schema.CHARACTER_SETS ORDER BY CHARACTER_SET_NAME".to_string(),
        )
        .await
        .unwrap_or_default();
    let collations = conn
        .fetch_named(
            "SELECT COLLATION_NAME AS collation, CHARACTER_SET_NAME AS charset, IS_DEFAULT AS is_default FROM information_schema.COLLATIONS ORDER BY CHARACTER_SET_NAME, COLLATION_NAME".to_string(),
        )
        .await
        .unwrap_or_default();
    let engines = conn
        .fetch_named(
            "SELECT ENGINE AS engine, SUPPORT AS support, COMMENT AS comment FROM information_schema.ENGINES ORDER BY ENGINE".to_string(),
        )
        .await
        .unwrap_or_default();
    let default_charset = conn
        .fetch_string("SELECT @@character_set_server".to_string())
        .await
        .unwrap_or_else(|_| "utf8mb4".to_string());
    let default_collation = conn
        .fetch_string("SELECT @@collation_server".to_string())
        .await
        .unwrap_or_default();
    let default_row_format = conn
        .fetch_string("SELECT @@innodb_default_row_format".to_string())
        .await
        .map(|s| s.to_ascii_uppercase())
        .unwrap_or_else(|_| "DYNAMIC".to_string());
    Ok(json!({
        "charsets": charsets,
        "collations": collations,
        "engines": engines,
        "row_formats": ["DYNAMIC", "COMPACT", "COMPRESSED", "REDUNDANT"],
        "tablespaces": [],
        "default_row_format": default_row_format,
        "default_charset": default_charset,
        "default_collation": default_collation,
        "features": {
            "charset": true,
            "table_charset": true,
            "collation": true,
            "engine": true,
            "row_format": true,
            "auto_increment": true,
            "comment": true,
            "unlogged": false,
            "tablespace": false,
            "without_rowid": false,
            "strict": false,
        },
    }))
}

pub fn _unused(_: &ColumnDef) {}

/// Render one ADD / MODIFY COLUMN clause.
///
/// Returns a Result because every interpolated piece is validated. The web
/// build pasted charset, collation and default straight into the DDL, which
/// let a crafted designer request inject SQL.
fn column_clause(driver: DriverKind, c: &crate::drivers::AlterColumn) -> AppResult<String> {
    let mut def = format!("{} {}", qi(driver, c.name.trim()), c.col_type.trim());
    if let Some(charset) = c.charset.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        def.push_str(&format!(" CHARACTER SET {}", safe_ident(charset)?));
    }
    if let Some(collation) = c.collation.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        def.push_str(&format!(" COLLATE {}", safe_ident(collation)?));
    }
    def.push_str(if c.nullable { " NULL" } else { " NOT NULL" });
    if let Some(value) = c.default.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        def.push_str(&format!(" DEFAULT {}", crate::drivers::safe_default(value)?));
    }
    if c.auto_increment {
        def.push_str(" AUTO_INCREMENT");
    }
    if let Some(comment) = c.comment.as_deref().filter(|s| !s.is_empty()) {
        def.push_str(&format!(" COMMENT {}", quote_str_for(driver, comment)));
    }
    Ok(def)
}

pub fn alter_table_statements(
    driver: DriverKind,
    ns: &str,
    table: &str,
    spec: &crate::drivers::AlterTableSpec,
) -> AppResult<Vec<String>> {
    let target = qualify(driver, ns, table);
    let mut clauses: Vec<String> = Vec::new();
    for c in &spec.add_columns {
        clauses.push(format!("ADD COLUMN {}", column_clause(driver, c)?));
    }
    for c in &spec.modify_columns {
        clauses.push(format!("MODIFY COLUMN {}", column_clause(driver, c)?));
    }
    for name in &spec.drop_columns {
        clauses.push(format!("DROP COLUMN {}", qi(driver, name)));
    }
    for r in &spec.rename_columns {
        clauses.push(format!(
            "RENAME COLUMN {} TO {}",
            qi(driver, &r.from),
            qi(driver, &r.to)
        ));
    }
    if let Some(cols) = &spec.set_primary_key {
        if !cols.is_empty() {
            let names: Vec<String> = cols.iter().map(|c| qi(driver, c)).collect();
            clauses.push(format!("ADD PRIMARY KEY ({})", names.join(", ")));
        }
    }
    // Drop before add: a replaced index keeps its name, and the other order
    // would add the new definition and then drop it again.
    for name in &spec.drop_indexes {
        clauses.push(format!("DROP INDEX {}", qi(driver, name)));
    }
    for idx in &spec.add_indexes {
        if idx.name.trim().is_empty() || idx.columns.is_empty() {
            continue;
        }
        let kind = if idx.unique { "UNIQUE INDEX" } else { "INDEX" };
        let cols: Vec<String> = idx.columns.iter().map(|c| qi(driver, c)).collect();
        clauses.push(format!(
            "ADD {} {} ({})",
            kind,
            qi(driver, idx.name.trim()),
            cols.join(", ")
        ));
    }
    for fk in &spec.add_foreign_keys {
        clauses.push(format!("ADD {}", crate::drivers::fk_constraint_sql(driver, table, fk)?));
    }
    for name in &spec.drop_foreign_keys {
        clauses.push(format!("DROP FOREIGN KEY {}", qi(driver, name)));
    }
    if let Some(engine) = spec.engine.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        clauses.push(format!("ENGINE={}", safe_ident(engine)?));
    }
    if let Some(row_format) = spec.row_format.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        clauses.push(format!("ROW_FORMAT={}", safe_ident(row_format)?));
    }
    if let Some(auto_increment) = spec.auto_increment {
        clauses.push(format!("AUTO_INCREMENT={}", auto_increment));
    }
    if let Some(charset) = spec.charset.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        let mut clause = format!("CONVERT TO CHARACTER SET {}", safe_ident(charset)?);
        if let Some(collation) = spec.collation.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            clause.push_str(&format!(" COLLATE {}", safe_ident(collation)?));
        }
        clauses.push(clause);
    }
    if let Some(comment) = &spec.comment {
        clauses.push(format!("COMMENT={}", quote_str_for(driver, comment)));
    }

    let mut statements = Vec::new();
    if !clauses.is_empty() {
        statements.push(format!("ALTER TABLE {} {}", target, clauses.join(", ")));
    }
    if let Some(new_name) = spec.rename_to.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        statements.push(format!("RENAME TABLE {} TO {}", target, qi(driver, new_name)));
    }
    Ok(statements)
}

pub async fn objects(conn: &ConnectionHandle, ns: &str) -> AppResult<Value> {
    let lit = quote_str_for(conn.driver_kind(), ns);
    let views = conn
        .fetch_named(format!(
            "SELECT TABLE_NAME AS name, 'view' AS kind, 'VIEW' AS type, DEFINER AS definer, CHECK_OPTION AS check_option, IS_UPDATABLE AS updatable FROM information_schema.VIEWS WHERE TABLE_SCHEMA = {} ORDER BY TABLE_NAME",
            lit
        ))
        .await
        .unwrap_or_default();
    let routines = conn
        .fetch_named(format!(
            "SELECT ROUTINE_NAME AS name, LOWER(ROUTINE_TYPE) AS kind, ROUTINE_TYPE AS type, DEFINER AS definer, DATA_TYPE AS returns, SECURITY_TYPE AS security, CREATED AS created FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = {} ORDER BY ROUTINE_TYPE, ROUTINE_NAME",
            lit
        ))
        .await
        .unwrap_or_default();
    let triggers = conn
        .fetch_named(format!(
            "SELECT TRIGGER_NAME AS name, 'trigger' AS kind, 'TRIGGER' AS type, EVENT_OBJECT_TABLE AS tbl, ACTION_TIMING AS timing, EVENT_MANIPULATION AS event FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = {} ORDER BY TRIGGER_NAME",
            lit
        ))
        .await
        .unwrap_or_default();
    let events = conn
        .fetch_named(format!(
            "SELECT EVENT_NAME AS name, 'event' AS kind, STATUS AS type, EVENT_TYPE AS schedule, INTERVAL_VALUE AS interval_value, INTERVAL_FIELD AS interval_field, STARTS AS starts, ENDS AS ends, DEFINER AS definer FROM information_schema.EVENTS WHERE EVENT_SCHEMA = {} ORDER BY EVENT_NAME",
            lit
        ))
        .await
        .unwrap_or_default();
    Ok(json!({ "views": views, "routines": routines, "triggers": triggers, "events": events }))
}

/// CREATE ... statement for one existing object, for the definition viewer.
pub async fn object_definition(conn: &ConnectionHandle, ns: &str, kind: &str, name: &str) -> AppResult<String> {
    let target = qualify(conn.driver_kind(), ns, name);
    let sql = match kind {
        "view" => format!("SHOW CREATE VIEW {}", target),
        "procedure" => format!("SHOW CREATE PROCEDURE {}", target),
        "function" => format!("SHOW CREATE FUNCTION {}", target),
        "trigger" => format!("SHOW CREATE TRIGGER {}", target),
        "event" => format!("SHOW CREATE EVENT {}", target),
        other => return Err(AppError::bad(format!("未知对象类型 '{}'", other))),
    };
    let rs = conn.run_one(sql).await;
    if let Some(err) = rs.error {
        return Err(AppError::bad(err));
    }
    let row = rs
        .rows
        .first()
        .ok_or_else(|| AppError::not_found(format!("对象 '{}' 不存在", name)))?;
    let idx = rs
        .columns
        .iter()
        .position(|c| c.name.starts_with("Create "))
        .unwrap_or(if row.len() > 1 { 1 } else { 0 });
    Ok(row
        .get(idx)
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string())
}

/// DROP statement for one object (identifier-quoted and kind-checked).
pub fn object_drop_sql(ns: &str, kind: &str, name: &str) -> AppResult<String> {
    let d = DriverKind::Mysql;
    let target = qualify(d, ns, name);
    let head = match kind {
        "view" => "DROP VIEW",
        "procedure" => "DROP PROCEDURE",
        "function" => "DROP FUNCTION",
        "trigger" => "DROP TRIGGER",
        "event" => "DROP EVENT",
        other => return Err(AppError::bad(format!("未知对象类型 '{}'", other))),
    };
    Ok(format!("{} {}", head, target))
}

// ------------------------------------------------------------ database accounts
//
// The account editor is a graphical front end for CREATE USER / ALTER USER /
// GRANT / REVOKE. It never rewrites what it cannot understand: `SHOW GRANTS`
// lines that do not match the simple `GRANT <privs> ON <scope> TO <account>`
// shape (role grants, PROXY grants, …) are reported verbatim and left alone.
// Privileges outside `MYSQL_PRIVILEGES` are likewise never revoked, so opening
// the editor and saving cannot silently strip privileges the UI cannot show.

/// Privileges offered by the editor. `true` marks the ones MySQL only accepts
/// at the `*.*` scope.
pub const MYSQL_PRIVILEGES: &[(&str, bool)] = &[
    ("SELECT", false),
    ("INSERT", false),
    ("UPDATE", false),
    ("DELETE", false),
    ("CREATE", false),
    ("DROP", false),
    ("ALTER", false),
    ("INDEX", false),
    ("REFERENCES", false),
    ("CREATE VIEW", false),
    ("SHOW VIEW", false),
    ("TRIGGER", false),
    ("EXECUTE", false),
    ("CREATE ROUTINE", false),
    ("ALTER ROUTINE", false),
    ("EVENT", false),
    ("LOCK TABLES", false),
    ("CREATE TEMPORARY TABLES", false),
    ("GRANT OPTION", false),
    ("CREATE USER", true),
    ("PROCESS", true),
    ("RELOAD", true),
    ("SHOW DATABASES", true),
    ("REPLICATION CLIENT", true),
    ("REPLICATION SLAVE", true),
    ("FILE", true),
    ("SHUTDOWN", true),
];

pub fn account_model() -> Value {
    json!({
        "supported": true,
        "model": "mysql",
        "host_required": true,
        "privileges": MYSQL_PRIVILEGES
            .iter()
            .map(|(name, global_only)| json!({ "name": name, "global_only": global_only }))
            .collect::<Vec<Value>>(),
        "note": "MySQL 权限以「作用域 × 权限」矩阵表示。表级授权与角色授权不在矩阵内，会在查看窗口原样列出并保持不变。",
    })
}

fn known_privilege(name: &str) -> bool {
    MYSQL_PRIVILEGES.iter().any(|(p, _)| *p == name)
}

/// Split `text` on `.` while ignoring dots inside backticks, unquoting as it goes.
fn split_scope(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut in_quote = false;
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '`' {
            if in_quote && chars.peek() == Some(&'`') {
                cur.push('`');
                chars.next();
                continue;
            }
            in_quote = !in_quote;
            continue;
        }
        if c == '.' && !in_quote {
            out.push(cur.trim().to_string());
            cur.clear();
            continue;
        }
        cur.push(c);
    }
    out.push(cur.trim().to_string());
    out
}

/// Parse `*.*`, `` `db`.* `` or `` `db`.`tbl` `` into (scope, table).
fn parse_scope(text: &str) -> Option<(String, Option<String>)> {
    let parts = split_scope(text.trim());
    match parts.len() {
        2 => {
            let scope = parts[0].clone();
            if scope.is_empty() {
                return None;
            }
            if parts[1] == "*" {
                Some((scope, None))
            } else if parts[1].is_empty() {
                None
            } else {
                Some((scope, Some(parts[1].clone())))
            }
        }
        1 => {
            if parts[0] == "*" {
                Some(("*".to_string(), None))
            } else if parts[0].is_empty() {
                None
            } else {
                Some((parts[0].clone(), None))
            }
        }
        _ => None,
    }
}

fn scope_target(scope: &str, table: Option<&str>) -> String {
    let d = DriverKind::Mysql;
    if scope == "*" {
        "*.*".to_string()
    } else if let Some(t) = table {
        format!("{}.{}", qi(d, scope), qi(d, t))
    } else {
        format!("{}.*", qi(d, scope))
    }
}

struct ParsedGrant {
    scope: String,
    table: Option<String>,
    privileges: Vec<String>,
}

fn parse_grant_line(line: &str) -> Option<ParsedGrant> {
    let trimmed = line.trim();
    let upper = trimmed.to_ascii_uppercase();
    if !upper.starts_with("GRANT ") {
        return None;
    }
    let body = &trimmed[6..];
    let body_upper = body.to_ascii_uppercase();
    // Role grants (`GRANT `r`@`%` TO `u`@`h``) have no ON clause and are kept as-is.
    let on_idx = body_upper.find(" ON ")?;
    let privileges_part = &body[..on_idx];
    let rest = &body[on_idx + 4..];
    let rest_upper = rest.to_ascii_uppercase();
    let to_idx = rest_upper.find(" TO ")?;
    let (scope, table) = parse_scope(rest[..to_idx].trim())?;
    let tail_upper = rest[to_idx + 4..].to_ascii_uppercase();

    let mut privileges: Vec<String> = privileges_part
        .split(',')
        .map(|p| p.trim().to_ascii_uppercase())
        .filter(|p| !p.is_empty() && p != "USAGE")
        .collect();
    if tail_upper.contains("WITH GRANT OPTION") {
        privileges.push("GRANT OPTION".to_string());
    }
    Some(ParsedGrant { scope, table, privileges })
}

/// Read one account's privileges as a structured matrix plus the raw lines.
pub async fn user_grants(conn: &ConnectionHandle, user: &str, host: &str) -> AppResult<Value> {
    let sql = format!(
        "SHOW GRANTS FOR {}@{}",
        quote_str_for(conn.driver_kind(), user),
        quote_str_for(conn.driver_kind(), host)
    );
    let rs = conn.run_one(sql).await;
    if let Some(err) = rs.error {
        return Err(AppError::bad(err));
    }
    let raw: Vec<String> = rs
        .rows
        .iter()
        .filter_map(|r| r.first().and_then(|v| v.as_str()).map(|s| s.to_string()))
        .collect();

    let mut matrix: Vec<Value> = Vec::new();
    let mut other: Vec<String> = Vec::new();
    for line in &raw {
        match parse_grant_line(line) {
            Some(parsed) => matrix.push(json!({
                "scope": parsed.scope,
                "table": parsed.table,
                "privileges": parsed.privileges,
            })),
            None => other.push(line.clone()),
        }
    }
    // Merge rows that share a scope so the UI shows one row per scope.
    let mut merged: Vec<(String, Option<String>, Vec<String>)> = Vec::new();
    for row in matrix {
        let scope = row.get("scope").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let table = row.get("table").and_then(|v| v.as_str()).map(|s| s.to_string());
        let privs: Vec<String> = row
            .get("privileges")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().filter_map(|v| v.as_str()).map(|s| s.to_string()).collect())
            .unwrap_or_default();
        match merged.iter_mut().find(|(s, t, _)| *s == scope && *t == table) {
            Some(entry) => {
                for p in privs {
                    if !entry.2.contains(&p) {
                        entry.2.push(p);
                    }
                }
            }
            None => merged.push((scope, table, privs)),
        }
    }
    let grants: Vec<Value> = merged
        .into_iter()
        .filter(|(_, _, privs)| !privs.is_empty())
        .map(|(scope, table, privileges)| {
            json!({ "scope": scope, "table": table, "privileges": privileges })
        })
        .collect();

    Ok(json!({
        "supported": true,
        "model": "mysql",
        "raw": raw,
        "grants": grants,
        "roles": Vec::<String>::new(),
        "other": other,
    }))
}

/// Current privileges as (scope, table, privilege) triples.
async fn current_privileges(
    conn: &ConnectionHandle,
    user: &str,
    host: &str,
) -> AppResult<Vec<(String, Option<String>, String)>> {
    let value = user_grants(conn, user, host).await?;
    let mut out = Vec::new();
    for row in value.get("grants").and_then(|v| v.as_array()).cloned().unwrap_or_default() {
        let scope = row.get("scope").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let table = row.get("table").and_then(|v| v.as_str()).map(|s| s.to_string());
        for p in row.get("privileges").and_then(|v| v.as_array()).cloned().unwrap_or_default() {
            if let Some(name) = p.as_str() {
                out.push((scope.clone(), table.clone(), name.to_string()));
            }
        }
    }
    Ok(out)
}

/// MySQL has no assignable-role model we can edit reliably across versions, so
/// role grants stay in the read-only `other` list.
pub async fn assignable_roles(_conn: &ConnectionHandle, _user: &str) -> AppResult<Vec<String>> {
    Ok(Vec::new())
}

/// GRANT / REVOKE statements that turn `current` into `desired`.
/// Only privileges known to the editor are ever revoked.
fn diff_statements(
    account: &str,
    desired: &[crate::drivers::PrivilegeGrant],
    current: &[(String, Option<String>, String)],
) -> Vec<String> {
    let mut out = Vec::new();
    let mut desired_set: Vec<(String, Option<String>, String)> = Vec::new();
    for grant in desired {
        let scope = grant.scope.trim().to_string();
        if scope.is_empty() {
            continue;
        }
        let table = grant.table.as_ref().map(|t| t.trim().to_string()).filter(|t| !t.is_empty());
        for p in &grant.privileges {
            let name = p.trim().to_ascii_uppercase();
            if name.is_empty() || !known_privilege(&name) {
                continue;
            }
            let entry = (scope.clone(), table.clone(), name);
            if !desired_set.contains(&entry) {
                desired_set.push(entry);
            }
        }
    }

    // additions, grouped per scope
    let mut added: Vec<(String, Option<String>, Vec<String>)> = Vec::new();
    for entry in &desired_set {
        if current.contains(entry) {
            continue;
        }
        match added
            .iter_mut()
            .find(|(s, t, _)| *s == entry.0 && *t == entry.1)
        {
            Some(group) => group.2.push(entry.2.clone()),
            None => added.push((entry.0.clone(), entry.1.clone(), vec![entry.2.clone()])),
        }
    }
    for (scope, table, privileges) in added {
        let target = scope_target(&scope, table.as_deref());
        let normal: Vec<String> = privileges.iter().filter(|p| *p != "GRANT OPTION").cloned().collect();
        let grant_option = privileges.iter().any(|p| p == "GRANT OPTION");
        if !normal.is_empty() {
            let mut stmt = format!("GRANT {} ON {} TO {}", normal.join(", "), target, account);
            if grant_option {
                stmt.push_str(" WITH GRANT OPTION");
            }
            out.push(stmt);
        } else if grant_option {
            out.push(format!("GRANT USAGE ON {} TO {} WITH GRANT OPTION", target, account));
        }
    }

    // removals, grouped per scope. Privileges the editor does not know about
    // (e.g. CREATE ROLE, dynamic privileges) are never revoked, so saving the
    // form cannot silently strip them.
    let mut removed: Vec<(String, Option<String>, Vec<String>)> = Vec::new();
    for entry in current {
        if desired_set.contains(entry) || !known_privilege(&entry.2) {
            continue;
        }
        match removed
            .iter_mut()
            .find(|(s, t, _)| *s == entry.0 && *t == entry.1)
        {
            Some(group) => group.2.push(entry.2.clone()),
            None => removed.push((entry.0.clone(), entry.1.clone(), vec![entry.2.clone()])),
        }
    }
    for (scope, table, privileges) in removed {
        let target = scope_target(&scope, table.as_deref());
        let normal: Vec<String> = privileges.iter().filter(|p| *p != "GRANT OPTION").cloned().collect();
        if !normal.is_empty() {
            out.push(format!("REVOKE {} ON {} FROM {}", normal.join(", "), target, account));
        }
        if privileges.iter().any(|p| p == "GRANT OPTION") {
            out.push(format!("REVOKE GRANT OPTION ON {} FROM {}", target, account));
        }
    }
    out
}

pub fn create_account_statements(
    user: &str,
    host: &str,
    password: &str,
    change: &crate::drivers::UserChange,
) -> AppResult<Vec<String>> {
    crate::drivers::check_account_name(user, host)?;
    let d = DriverKind::Mysql;
    let account = format!(
        "{}@{}",
        quote_str_for(d, user),
        quote_str_for(d, host)
    );
    let mut out = vec![format!(
        "CREATE USER IF NOT EXISTS {} IDENTIFIED BY {}",
        account,
        quote_str_for(d, password)
    )];
    if change.account_locked == Some(true) {
        out.push(format!("ALTER USER {} ACCOUNT LOCK", account));
    }
    if let Some(grants) = &change.grants {
        out.extend(diff_statements(&account, grants, &[]));
    }
    out.extend(
        change
            .extra_sql
            .iter()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty()),
    );
    Ok(out)
}

/// DROP 一个账号（纯函数；系统账号守卫与引用规则只有这一份）。
pub fn drop_account_statement(user: &str, host: &str) -> AppResult<String> {
    crate::drivers::guard_system_account(user)?;
    Ok(format!(
        "DROP USER {}",
        crate::drivers::mysql_account(DriverKind::Mysql, user, host)
    ))
}

pub async fn alter_account_statements(
    conn: &ConnectionHandle,
    user: &str,
    host: &str,
    change: &crate::drivers::UserChange,
) -> AppResult<Vec<String>> {
    crate::drivers::check_account_name(user, host)?;
    let d = DriverKind::Mysql;
    let account = format!("{}@{}", quote_str_for(d, user), quote_str_for(d, host));
    let mut out = Vec::new();

    if let Some(password) = change.password.as_deref().filter(|p| !p.is_empty()) {
        out.push(format!(
            "ALTER USER {} IDENTIFIED BY {}",
            account,
            quote_str_for(d, password)
        ));
    }
    if let Some(locked) = change.account_locked {
        out.push(format!(
            "ALTER USER {} ACCOUNT {}",
            account,
            if locked { "LOCK" } else { "UNLOCK" }
        ));
    }
    if let Some(grants) = &change.grants {
        let current = current_privileges(conn, user, host).await?;
        out.extend(diff_statements(&account, grants, &current));
    }
    // Rename last: the statements above still address the old account name.
    if let Some(new_user) = change.new_user.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        crate::drivers::guard_system_account(user)?;
        let new_host = change
            .new_host
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or(host);
        out.push(format!(
            "RENAME USER {} TO {}@{}",
            account,
            quote_str_for(d, new_user),
            quote_str_for(d, new_host)
        ));
    }
    out.extend(
        change
            .extra_sql
            .iter()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty()),
    );
    Ok(out)
}


#[cfg(test)]
mod account_tests {
    use super::*;
    use crate::drivers::PrivilegeGrant;

    fn grant(scope: &str, privileges: &[&str]) -> PrivilegeGrant {
        PrivilegeGrant {
            scope: scope.to_string(),
            table: None,
            privileges: privileges.iter().map(|p| p.to_string()).collect(),
        }
    }

    fn current(scope: &str, privilege: &str) -> (String, Option<String>, String) {
        (scope.to_string(), None, privilege.to_string())
    }

    #[test]
    fn parses_scope_forms() {
        assert_eq!(parse_scope("*.*"), Some(("*".to_string(), None)));
        assert_eq!(
            parse_scope("`rustmyadmin_demo`.*"),
            Some(("rustmyadmin_demo".to_string(), None))
        );
        assert_eq!(
            parse_scope("`db`.`tbl`"),
            Some(("db".to_string(), Some("tbl".to_string())))
        );
    }

    #[test]
    fn parses_show_grants_lines() {
        let parsed = parse_grant_line("GRANT SELECT, INSERT ON `db`.* TO `u`@`h`").unwrap();
        assert_eq!(parsed.scope, "db");
        assert_eq!(parsed.privileges, vec!["SELECT", "INSERT"]);

        // USAGE means "no privileges" and must not become a checkbox.
        let usage = parse_grant_line("GRANT USAGE ON *.* TO `u`@`h`").unwrap();
        assert!(usage.privileges.is_empty());

        let option = parse_grant_line("GRANT SELECT ON `db`.* TO `u`@`h` WITH GRANT OPTION").unwrap();
        assert!(option.privileges.contains(&"GRANT OPTION".to_string()));

        let table = parse_grant_line("GRANT SELECT ON `db`.`tbl` TO `u`@`h`").unwrap();
        assert_eq!(table.table.as_deref(), Some("tbl"));

        // Role grants have no ON clause and stay in the read-only list.
        assert!(parse_grant_line("GRANT `role`@`%` TO `u`@`h`").is_none());
    }

    #[test]
    fn diff_grants_and_revokes() {
        let desired = vec![grant("db", &["SELECT", "UPDATE"]), grant("*", &["PROCESS"])];
        let existing = vec![current("db", "SELECT"), current("db", "INSERT")];
        let out = diff_statements("'u'@'h'", &desired, &existing);
        assert!(out.contains(&"GRANT UPDATE ON `db`.* TO 'u'@'h'".to_string()), "{:?}", out);
        assert!(out.contains(&"GRANT PROCESS ON *.* TO 'u'@'h'".to_string()), "{:?}", out);
        assert!(out.contains(&"REVOKE INSERT ON `db`.* FROM 'u'@'h'".to_string()), "{:?}", out);
        // SELECT is already granted, so no statement is emitted for it.
        assert!(!out.iter().any(|s| s == "GRANT SELECT ON `db`.* TO 'u'@'h'"), "{:?}", out);
    }

    #[test]
    fn diff_never_revokes_unknown_privileges() {
        let desired = vec![grant("db", &["SELECT"])];
        let existing = vec![current("db", "SELECT"), current("*", "CREATE ROLE")];
        let out = diff_statements("'u'@'h'", &desired, &existing);
        assert!(out.is_empty(), "unexpected statements: {:?}", out);
    }

    #[test]
    fn grant_option_is_rendered_explicitly() {
        let desired = vec![grant("db", &["SELECT", "GRANT OPTION"])];
        let out = diff_statements("'u'@'h'", &desired, &[]);
        assert_eq!(out, vec!["GRANT SELECT ON `db`.* TO 'u'@'h' WITH GRANT OPTION"]);
    }
}

#[cfg(test)]
mod visibility_tests {
    use super::*;

    fn line(text: &str) -> String {
        text.to_string()
    }

    #[test]
    fn usage_only_account_sees_nothing_extra() {
        // The exact SHOW GRANTS of the reported web account: USAGE ON *.* plus
        // one schema. USAGE must not be read as a global grant.
        let scopes = visible_schema_scopes(&[
            line("GRANT USAGE ON *.* TO `web`@`%`"),
            line("GRANT ALL PRIVILEGES ON `web`.* TO `web`@`%` WITH GRANT OPTION"),
        ])
        .expect("a schema list");
        assert_eq!(scopes, vec!["web".to_string()]);
    }

    #[test]
    fn server_level_global_privileges_do_not_unlock_every_schema() {
        // PROCESS / SHOW DATABASES let the account inspect the server, but it
        // still cannot USE another schema, so the tree must stay filtered.
        let scopes = visible_schema_scopes(&[
            line("GRANT PROCESS ON *.* TO `u`@`%`"),
            line("GRANT SHOW DATABASES ON *.* TO `u`@`%`"),
            line("GRANT SELECT ON `app`.* TO `u`@`%`"),
        ])
        .expect("a schema list");
        assert_eq!(scopes, vec!["app".to_string()]);
    }

    #[test]
    fn global_schema_privileges_unlock_everything() {
        for grant in [
            "GRANT SELECT ON *.* TO `u`@`%`",
            "GRANT ALL PRIVILEGES ON *.* TO `u`@`%`",
            "GRANT INSERT ON *.* TO `u`@`%`",
        ] {
            assert_eq!(visible_schema_scopes(&[line(grant)]), None, "{grant}");
        }
    }

    #[test]
    fn table_and_column_grants_name_their_schema() {
        let scopes = visible_schema_scopes(&[
            line("GRANT USAGE ON *.* TO `u`@`%`"),
            line("GRANT SELECT ON `shop`.`orders` TO `u`@`%`"),
            line("GRANT SELECT (`name`) ON `crm`.`users` TO `u`@`%`"),
        ])
        .expect("a schema list");
        assert_eq!(scopes, vec!["shop".to_string(), "crm".to_string()]);
    }

    #[test]
    fn role_grants_without_on_clause_are_ignored() {
        // MySQL 8 expands a role's privileges into their own lines; the role
        // grant itself must not be parsed as a schema.
        let scopes = visible_schema_scopes(&[
            line("GRANT USAGE ON *.* TO `u`@`%`"),
            line("GRANT `rma_reader`@`%` TO `u`@`%`"),
            line("GRANT SELECT ON `rustmyadmin_demo`.* TO `u`@`%`"),
        ])
        .expect("a schema list");
        assert_eq!(scopes, vec!["rustmyadmin_demo".to_string()]);
    }

    #[test]
    fn unreadable_grants_disable_the_filter() {
        // When SHOW GRANTS itself fails the caller falls back to the server's
        // list instead of hiding everything.
        assert_eq!(visible_schema_scopes(&[]), Some(Vec::new()));
    }

    #[test]
    fn information_schema_always_survives_the_filter() {
        use serde_json::json;
        let rows = vec![
            json!({ "name": "information_schema" }),
            json!({ "name": "performance_schema" }),
            json!({ "name": "web" }),
        ];
        let kept = filter_namespaces(rows, &["web".to_string()]);
        let names: Vec<&str> = kept
            .iter()
            .filter_map(|row| row.get("name").and_then(|v| v.as_str()))
            .collect();
        assert_eq!(names, vec!["information_schema", "web"]);
    }
}

#[cfg(test)]
mod charset_tests {
    use super::*;

    #[test]
    fn empty_or_missing_keeps_the_driver_default() {
        assert_eq!(connection_charset(None).unwrap(), "utf8mb4");
        assert_eq!(connection_charset(Some("")).unwrap(), "utf8mb4");
        assert_eq!(connection_charset(Some("   ")).unwrap(), "utf8mb4");
    }

    /// The round34 P2-02 symptom: MySQL 8.x lists `utf8mb3` in
    /// `information_schema.CHARACTER_SETS`, but sqlx's client has no such entry
    /// and fails the handshake with "unsupported MySQL charset: utf8mb3". The
    /// 3-byte encoding is the one the client calls `utf8`, so a connection saved
    /// with the MySQL spelling must still open.
    #[test]
    fn utf8mb3_is_mapped_to_the_client_spelling() {
        assert_eq!(connection_charset(Some("utf8mb3")).unwrap(), "utf8");
        assert_eq!(connection_charset(Some("UTF8MB3")).unwrap(), "utf8");
        assert_eq!(connection_charset(Some(" utf8mb3 ")).unwrap(), "utf8");
    }

    #[test]
    fn known_names_are_lower_cased_and_passed_through() {
        assert_eq!(connection_charset(Some("utf8mb4")).unwrap(), "utf8mb4");
        assert_eq!(connection_charset(Some("UTF8")).unwrap(), "utf8");
        assert_eq!(connection_charset(Some("Latin1")).unwrap(), "latin1");
        assert_eq!(connection_charset(Some("gb18030")).unwrap(), "gb18030");
        assert_eq!(connection_charset(Some("binary")).unwrap(), "binary");
    }

    /// Everything the client cannot put in the handshake fails here, in the
    /// Chinese copy the UI translates (en_backend); sqlx's English message never
    /// reaches the user.
    #[test]
    fn unknown_names_are_rejected_with_translatable_copy() {
        for bad in ["utf9", "utf8mb4; DROP TABLE t; --", "utf8mb5"] {
            let err = connection_charset(Some(bad)).unwrap_err().to_string();
            assert!(
                err.contains("不支持的 MySQL 字符集") && err.contains(bad),
                "unexpected message for {bad}: {err}"
            );
            assert!(
                !err.contains("unsupported MySQL charset"),
                "sqlx's raw English message leaked: {err}"
            );
        }
    }

    /// The capability list must stay in sync with the client: every name it
    /// accepts is offered to the connection editor.
    #[test]
    fn capability_list_has_no_mysql_only_spelling() {
        assert!(!MYSQL_CLIENT_CHARSETS.contains(&"utf8mb3"));
        assert!(MYSQL_CLIENT_CHARSETS.contains(&"utf8"));
        assert!(MYSQL_CLIENT_CHARSETS.contains(&"utf8mb4"));
    }
}
