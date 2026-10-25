//! Database / table explorer: namespaces, tables, structure, rows, DDL.
//!
//! Ports the read paths of `routes/database.rs`, `routes/table.rs` and
//! `routes/design.rs`. Permission checks collapsed to
//! `ActiveConnection::ensure_visible`, which is enforced inside
//! `AppState::db_for` for every namespace-taking call.

use serde::Deserialize;
use serde_json::{json, Value};

use super::{parse, state};
use crate::core::dialect::DialectCapability;
use crate::drivers::CreateTableSpec;
use crate::error::AppError;

/// Namespaces visible inside the active database.
///
/// PostgreSQL returns schemas (`public`, `app`, ...); MySQL returns the
/// databases themselves. The instance tree uses [`instance_databases`] for the
/// physical database list and [`list_schemas`] for a specific database.
pub async fn list_databases() -> anyhow::Result<Value> {
    let state = state()?;
    let active = state.active().await?;
    // 新路径：注册表取驱动 → 池化句柄 → 驱动返回元数据。
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(None).await?;
    let rows = driver.list_namespaces(&conn).await?;
    // PostgreSQL 的 only_db / hide_db 管的是物理数据库（实例树里由 db_for
    // 校验）；schema 列表本身不是授权边界。MySQL / SQLite 的命名空间就是
    // 数据库，仍然在这里按连接规则过滤。
    let databases = if driver.namespaces_are_databases() {
        active.keep_visible_rows(rows)
    } else {
        rows
    };
    Ok(json!({
        "databases": databases,
        "driver": driver.id(),
        "driver_label": driver.label(),
    }))
}


/// Physical databases visible to the active account.
///
/// This is the list behind the sidebar tree. PostgreSQL requires an
/// instance-level connection (admin pool, with a fallback when the account
/// cannot open postgres); MySQL can use a server-level connection.
pub async fn instance_databases() -> anyhow::Result<Value> {
    let state = state()?;
    let active = state.active().await?;
    let driver = state.driver(&active.driver_id)?;
    let (conn, admin_database) = state.admin_connection().await?;
    let rows = driver.list_instance_databases(&conn).await?;
    let databases = active.keep_visible_rows(rows);
    Ok(json!({
        "databases": databases,
        "active_database": state.active_database().await,
        "admin_database": admin_database,
        "driver": driver.id(),
        "driver_label": driver.label(),
    }))
}

/// Switch the explorer to one physical database.
///
/// The pool is opened (and pinged) before the state changes, so a database the
/// account cannot reach is reported and the previous selection stays active.
/// PostgreSQL also returns the schemas of the new database plus the session
/// search_path; MySQL returns an empty schema list because its databases are
/// the namespaces.
pub async fn select_database(database: String) -> anyhow::Result<Value> {
    let state = state()?;
    let active = state.active().await?;
    let database = database.trim().to_string();
    if database.is_empty() {
        return Err(AppError::bad("数据库名不能为空").into());
    }
    active.ensure_visible(&database)?;
    // Report a per-database rejection as such: route it through for_database so
    // it cannot read as "the connection failed" (the account may be connected
    // and simply lack the GRANT on this one database).
    let driver = state.driver(&active.driver_id)?;
    let conn = state
        .connection_for_database(&database)
        .await
        .map_err(|error| error.for_database(&database))?;
    driver
        .ping(&conn)
        .await
        .map_err(|error| error.for_database(&database))?;
    let schemas = if driver.supports(DialectCapability::Schemas) {
        driver.list_namespaces(&conn).await?
    } else {
        Vec::new()
    };
    let search_path = driver.current_schema(&conn).await;
    state.set_active_database(Some(database.clone())).await;
    Ok(json!({
        "database": database,
        "schemas": schemas,
        "search_path": search_path,
        "driver": driver.id(),
    }))
}

/// Schemas of a database without switching the active database.
///
/// The sidebar needs this to expand a database node; it lazily opens a pool for
/// that database (the registry caps the number of open pools).
pub async fn list_schemas(database: String) -> anyhow::Result<Value> {
    let state = state()?;
    let active = state.active().await?;
    let database = database.trim().to_string();
    if database.is_empty() {
        return Err(AppError::bad("数据库名不能为空").into());
    }
    active.ensure_visible(&database)?;
    let conn = state
        .connection_for_database(&database)
        .await
        .map_err(|error| error.for_database(&database))?;
    let driver = state.driver(&active.driver_id)?;
    let schemas = if driver.supports(DialectCapability::Schemas) {
        driver.list_namespaces(&conn).await?
    } else {
        Vec::new()
    };
    let search_path = if driver.supports(DialectCapability::Schemas) {
        driver.current_schema(&conn).await
    } else {
        database.clone()
    };
    Ok(json!({
        "database": database,
        "schemas": schemas,
        "search_path": search_path,
        "driver": driver.id(),
    }))
}

// P2-5：受保护 schema 名单由方言提供（pg_catalog / information_schema / …），
// api 不再硬编码 PostgreSQL 系统 schema。
fn protected_schema(dialect: &dyn crate::core::dialect::DatabaseDialect, name: &str) -> bool {
    dialect.is_protected_schema(name)
}

/// CREATE SCHEMA inside the active PostgreSQL database.
pub async fn create_schema(name: String) -> anyhow::Result<Value> {
    let state = state()?;
    let active = state.active().await?;
    let driver = state.driver(&active.driver_id)?;
    if !driver.supports(DialectCapability::CreateSchema) {
        return Err(AppError::bad("MySQL / SQLite 没有独立的 schema 概念").into());
    }
    let name = name.trim().to_string();
    if name.is_empty() {
        return Err(AppError::bad("请填写模式名").into());
    }
    if protected_schema(driver.dialect(), &name) {
        return Err(AppError::bad("系统模式不允许修改").into());
    }
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(None).await?;
    let sql = driver.create_schema_statement(&name)?;
    driver.create_schema(&conn, &name).await?;
    Ok(json!({ "ok": true, "schema": name, "sql": sql }))
}

/// DROP SCHEMA ... CASCADE inside the active PostgreSQL database.
pub async fn drop_schema(schema: String) -> anyhow::Result<Value> {
    let state = state()?;
    let active = state.active().await?;
    let driver = state.driver(&active.driver_id)?;
    if !driver.supports(DialectCapability::CreateSchema) {
        return Err(AppError::bad("MySQL / SQLite 没有独立的 schema 概念").into());
    }
    let schema = schema.trim().to_string();
    if schema.is_empty() {
        return Err(AppError::bad("请选择要删除的模式").into());
    }
    if protected_schema(driver.dialect(), &schema) {
        return Err(AppError::bad("系统模式不允许删除").into());
    }
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(None).await?;
    driver.drop_schema(&conn, &schema).await?;
    Ok(json!({ "ok": true, "dropped": schema }))
}

/// Character sets / collations / engines / row formats for the designers.
pub async fn meta_options() -> anyhow::Result<Value> {
    let state = state()?;
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(None).await?;
    driver.meta_options(&conn).await.map_err(anyhow::Error::from)
}

#[derive(Deserialize)]
struct CreateDatabaseRequest {
    name: String,
    #[serde(default)]
    charset: Option<String>,
    #[serde(default)]
    collation: Option<String>,
    /// PostgreSQL advanced options; blank means server default.
    #[serde(default)]
    template: Option<String>,
    #[serde(default)]
    encoding: Option<String>,
    #[serde(default)]
    owner: Option<String>,
    #[serde(default)]
    tablespace: Option<String>,
}

/// CREATE DATABASE. `dry_run` returns the SQL without executing it.
///
/// Runs on the instance-level (admin) connection: PostgreSQL's `postgres`
/// maintenance database may be used even when the account browses a different
/// database, and MySQL can create a database from any selected one. Schemas are
/// created separately with [`create_schema`].
pub async fn create_database(body: Value, dry_run: bool) -> anyhow::Result<Value> {
    let state = state()?;
    let req: CreateDatabaseRequest = parse("database", body)?;
    let name = req.name.trim().to_string();
    if name.is_empty() {
        return Err(AppError::bad("请填写数据库名").into());
    }
    // The new database must fall inside the connection's allowed scope.
    state.active().await?.ensure_visible(&name)?;
    let driver = state.driver_for_active().await?;
    let (conn, _) = state.admin_connection().await?;
    let sql = driver.create_database_statement(
        &name,
        req.charset.as_deref(),
        req.collation.as_deref(),
        req.template.as_deref(),
        req.encoding.as_deref(),
        req.owner.as_deref(),
        req.tablespace.as_deref(),
    )?;
    if dry_run {
        return Ok(json!({ "dry_run": true, "sql": sql }));
    }
    let outcome = conn.run_one(sql.clone()).await;
    if let Some(error) = outcome.error {
        return Err(AppError::bad(error).into());
    }
    Ok(json!({ "ok": true, "database": name, "sql": sql }))
}

pub async fn drop_database(database: String) -> anyhow::Result<Value> {
    let state = state()?;
    let active = state.active().await?;
    active.ensure_visible(&database)?;
    let driver = state.driver(&active.driver_id)?;
    if driver.is_file_based() {
        return Err(AppError::bad("SQLite 数据库是文件；请删除数据库文件").into());
    }

    // Connect through a pool that is not the database being dropped. PostgreSQL
    // refuses DROP DATABASE while any session (including this app's admin pool)
    // is connected to it, so the configured database is cleared before the
    // admin fallback chooses another maintenance database.
    let mut drop_spec = active.spec.clone();
    if drop_spec.database() == Some(database.as_str()) {
        drop_spec.database = None;
    }
    let driver = state.driver(&active.driver_id)?;
    let (conn, admin_database) = state.admin_connection_for(&drop_spec).await?;
    if admin_database.as_deref() == Some(database.as_str()) {
        return Err(AppError::bad(
            "无法连接到其他数据库来执行删除；请先改为可连接其他库的账号，或使用只连接目标库以外的管理连接",
        )
        .into());
    }

    // Dropping the active database is allowed: move the explorer to another
    // accessible database first so the next page has a valid pool.
    if state.active_database().await.as_deref() == Some(database.as_str()) {
        let rows = driver.list_instance_databases(&conn).await.unwrap_or_default();
        let mut next: Option<String> = None;
        for row in rows {
            let Some(name) = row.get("name").and_then(|v| v.as_str()) else {
                continue;
            };
            if name == database || !active.visible(name) {
                continue;
            }
            if state.pools.get(&active.spec, Some(name)).await.is_ok() {
                next = Some(name.to_string());
                break;
            }
        }
        state.set_active_database(next).await;
    }

    // Close the cached pool first: PostgreSQL refuses to drop a database while
    // any connection to it is open.
    state.pools.evict_database(&active.spec, &database).await;
    driver.drop_namespace(&conn, &database).await?;
    Ok(json!({ "ok": true, "dropped": database }))
}

pub async fn list_tables(database: String) -> anyhow::Result<Value> {
    let state = state()?;
    // connection_for 内部仍走 db_for：ensure_visible 照旧执行。
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(Some(&database)).await?;
    let tables = driver.list_tables(&conn, &database).await?;
    Ok(json!({ "database": database, "tables": tables }))
}

/// List tables in one explicit database/schema without changing the active one.
///
/// Used by the structure-sync table picker when the source/target is not the
/// database currently selected in the tree. PostgreSQL receives the physical
/// database plus a schema; MySQL/SQLite use the namespace as both.
pub async fn list_tables_in(database: String, schema: Option<String>) -> anyhow::Result<Value> {
    let state = state()?;
    let active = state.active().await?;
    let database = database.trim().to_string();
    if database.is_empty() {
        return Err(AppError::bad("数据库名不能为空").into());
    }
    active.ensure_visible(&database)?;
    let driver = state.driver(&active.driver_id)?;
    let conn = state.connection_for_database(&database).await?;
    // PostgreSQL 的参数是 schema；MySQL / SQLite 的命名空间就是数据库。
    let namespace = if driver.namespaces_are_databases() {
        database.clone()
    } else {
        schema
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| AppError::bad("请选择模式"))?
            .to_string()
    };
    let tables = driver.list_tables(&conn, &namespace).await?;
    Ok(json!({
        "database": database,
        "schema": namespace,
        "tables": tables,
    }))
}

/// CREATE TABLE from the visual designer.
pub async fn create_table(database: String, body: Value, dry_run: bool) -> anyhow::Result<Value> {
    let state = state()?;
    let mut spec: CreateTableSpec = parse("table", body)?;
    // Trim once, up front: the web build echoed a trimmed name while the DDL
    // used the raw one, so a stray space became part of the table name.
    spec.name = spec.name.trim().to_string();
    if spec.name.is_empty() {
        return Err(AppError::bad("请填写表名").into());
    }
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(Some(&database)).await?;
    let name = spec.name.clone();
    let sql = driver.create_table_statement(&database, &spec)?;
    if dry_run {
        return Ok(json!({ "dry_run": true, "sql": sql }));
    }
    driver.create_table(&conn, &database, &spec).await?;
    Ok(json!({ "ok": true, "table": name, "sql": sql }))
}

pub async fn drop_table(database: String, table: String) -> anyhow::Result<Value> {
    let state = state()?;
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(Some(&database)).await?;
    driver.drop_table(&conn, &database, &table).await?;
    Ok(json!({ "ok": true, "dropped": table }))
}

pub async fn truncate_table(database: String, table: String) -> anyhow::Result<Value> {
    let state = state()?;
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(Some(&database)).await?;
    driver.truncate(&conn, &database, &table).await?;
    Ok(json!({ "ok": true, "truncated": table }))
}

pub async fn table_structure(database: String, table: String) -> anyhow::Result<Value> {
    let state = state()?;
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(Some(&database)).await?;
    driver.table_structure(&conn, &database, &table).await.map_err(anyhow::Error::from)
}

#[derive(Deserialize)]
struct DataQuery {
    #[serde(default)]
    page: Option<u64>,
    #[serde(default)]
    per_page: Option<u64>,
    /// Comma separated `column:direction` pairs, e.g. `name:asc,salary:desc`.
    #[serde(default)]
    sort: Option<String>,
    #[serde(default, rename = "where")]
    filter: Option<String>,
    /// Keyset cursor: the primary-key value of the previous page's last row.
    ///
    /// Anything that is not a JSON scalar is rejected in `table_data` rather
    /// than silently ignored, so a UI bug does not quietly fall back to OFFSET.
    #[serde(default)]
    after: Option<Value>,
    /// Whether to run `COUNT(*)`. Defaults to true (the old behaviour).
    #[serde(default)]
    count: Option<bool>,
    /// Whether to use a deferred join (primary keys first, then fetch rows).
    /// Defaults to true; tables without a primary key fall back automatically.
    #[serde(default)]
    deferred: Option<bool>,
}

/// Parse the `sort` string into (column, direction) pairs.
fn parse_sorts(raw: Option<&str>) -> Vec<(String, String)> {
    raw.map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|raw| {
            raw.split(',')
                .filter_map(|part| {
                    let mut it = part.splitn(2, ':');
                    let column = it.next().unwrap_or("").trim().to_string();
                    if column.is_empty() {
                        return None;
                    }
                    let dir = it.next().unwrap_or("asc").trim().to_string();
                    Some((column, dir))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// One page of table rows.
///
/// Paging is index-range based when possible: pass `after` (the primary-key
/// value of the previous page's last row, returned as `next_cursor`) to replace
/// `OFFSET` with a range scan. `count: false` skips `COUNT(*)` (`total` and
/// `pages` come back null), and `deferred: true` (the default) fetches primary
/// keys first and joins back for the full rows. Every option defaults to the
/// pre-optimisation behaviour, so an old caller sees the same response plus the
/// new informational fields.
pub async fn table_data(database: String, table: String, params: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let query: DataQuery = parse("params", params)?;
    if let Some(after) = query.after.as_ref() {
        // A JSON object/array cannot be compared with a column: reject it here
        // instead of producing SQL that always fails.
        if !after.is_string() && !after.is_number() && !after.is_boolean() {
            return Err(AppError::bad("after 游标必须是字符串或数字").into());
        }
    }
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(Some(&database)).await?;
    let sorts = parse_sorts(query.sort.as_deref());
    let page = crate::core::paging::DataPage {
        page: query.page.unwrap_or(1),
        per_page: query.per_page.unwrap_or(25),
        sorts: &sorts,
        filter: query.filter.as_deref(),
        after: query.after.as_ref(),
        count: query.count.unwrap_or(true),
        deferred: query.deferred.unwrap_or(true),
    };
    driver.data(&conn, &database, &table, &page)
        .await
        .map_err(anyhow::Error::from)
}

#[derive(Deserialize)]
struct RowChange {
    action: String,
    #[serde(default)]
    values: Option<serde_json::Map<String, Value>>,
    #[serde(default)]
    keys: Option<serde_json::Map<String, Value>>,
    /// Match at most one physical row; used when the key is every column.
    #[serde(default)]
    limit_one: bool,
}

/// INSERT / UPDATE / DELETE one row.
pub async fn change_row(database: String, table: String, body: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let req: RowChange = parse("row", body)?;
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(Some(&database)).await?;
    let keys = req.keys.unwrap_or_default();
    let values = req.values.unwrap_or_default();
    driver.change_row(&conn, &database, &table, &req.action, &keys, &values, req.limit_one)
        .await
        .map_err(anyhow::Error::from)
}

/// Parse the batch-change payload: a JSON array of row changes, or an object
/// `{"changes": [...]}` (the shape the Dart page sends).
fn parse_row_changes(changes: Value) -> anyhow::Result<Vec<RowChange>> {
    let items = match changes {
        Value::Array(items) => items,
        Value::Object(mut object) => match object.remove("changes") {
            Some(Value::Array(items)) => items,
            _ => {
                return Err(AppError::bad("changes 必须是数组，或包含 changes 数组的对象").into());
            }
        },
        _ => return Err(AppError::bad("changes 必须是数组，或包含 changes 数组的对象").into()),
    };
    items
        .into_iter()
        .enumerate()
        .map(|(index, item)| {
            serde_json::from_value::<RowChange>(item).map_err(|error| {
                AppError::bad(format!("第 {} 条改动格式无效：{error}", index + 1)).into()
            })
        })
        .collect()
}

/// One row change after SQL validation/rendering: everything the response needs
/// to report a zero-row match without re-parsing the request.
struct PlannedChange {
    index: usize,
    action: String,
    sql: String,
    keys: serde_json::Map<String, Value>,
}

/// UPDATE / DELETE items whose driver affected-row count is 0.
///
/// Diagnostics only: the batch is not a failure, the transaction commits and
/// ok / rows_affected keep their meaning. MySQL counts only rows whose values
/// actually changed, so a same-value UPDATE also reports 0 there — the list
/// means "the key matched no row, or the row's values did not change" (the Dart
/// page words it that way). INSERT is excluded because 0 rows affected is its
/// normal count.
fn zero_row_results(changes: &[PlannedChange], row_counts: &[u64]) -> Vec<Value> {
    changes
        .iter()
        .zip(row_counts)
        .filter(|(change, count)| {
            **count == 0
                && matches!(
                    change.action.to_ascii_lowercase().as_str(),
                    "update" | "delete"
                )
        })
        .map(|(change, _)| {
            json!({
                "index": change.index,
                "action": change.action,
                "keys": Value::Object(change.keys.clone()),
            })
        })
        .collect()
}

/// Apply several row changes (INSERT / UPDATE / DELETE) in **one transaction**.
///
/// The semantic of every item is exactly [change_row]'s: the same key/value
/// quoting, the same `limit_one` narrowing (ctid / rowid / LIMIT 1) and the
/// same validation — the SQL is produced by the shared
/// `DatabaseDriver::change_row_sql`, only execution differs.
///
/// Every statement is validated and built **before** the transaction starts, so
/// a bad item (unknown action, update without keys, ...) cannot leave a
/// half-applied write behind. The batch then runs through
/// `ConnectionHandle::execute_transaction` (one sqlx transaction, driver-issued
/// `BEGIN`/`COMMIT`); the first server error rolls the whole batch back and
/// the error names the failing item.
///
/// Returns per-item results plus the total affected rows, so the table page can
/// show "已保存 N 行" and flag the item that matched no row. Matching no row is
/// **not** a failure: the batch still commits and ok/rows_affected keep their
/// meaning. [zero_row_results] (added in round 60) lists the UPDATE / DELETE
/// items whose driver row count was 0; since MySQL counts only rows whose values
/// changed, that means "the key matched nothing, or the value did not change".
///
pub async fn apply_row_changes(
    database: String,
    table: String,
    changes: Value,
) -> anyhow::Result<Value> {
    let state = state()?;
    let driver = state.driver_for_active().await?;
    let parsed = parse_row_changes(changes)?;
    // Build first: validation errors must fail before BEGIN (no rollback needed).
    let mut planned: Vec<PlannedChange> = Vec::with_capacity(parsed.len());
    for (index, change) in parsed.iter().enumerate() {
        let keys = change.keys.clone().unwrap_or_default();
        let values = change.values.clone().unwrap_or_default();
        let sql = driver
            .change_row_sql(&database, &table, &change.action, &keys, &values, change.limit_one)
            .map_err(anyhow::Error::from)?;
        planned.push(PlannedChange {
            index,
            action: change.action.clone(),
            sql,
            keys,
        });
    }
    if planned.is_empty() {
        return Ok(json!({
            "ok": true,
            "database": database,
            "table": table,
            "results": [],
            "rows_affected": 0,
            "zero_row_results": [],
        }));
    }
    // One transaction on one pooled connection. The driver issues BEGIN/COMMIT
    // through sqlx's transaction manager (a prepared `BEGIN` is rejected by
    // MySQL, error 1295) and rolls the whole batch back when a statement fails.
    let conn = state.connection_for(Some(&database)).await?;
    let sqls: Vec<String> = planned.iter().map(|change| change.sql.clone()).collect();
    let executed = conn
        .execute_transaction(sqls)
        .await
        .map_err(anyhow::Error::from)?;
    let mut results: Vec<Value> = Vec::with_capacity(executed.len());
    let mut rows_affected = 0u64;
    for (change, result) in planned.iter().zip(executed.iter()) {
        rows_affected += result.row_count;
        results.push(json!({
            "ok": true,
            "index": change.index,
            "action": change.action,
            "rows_affected": result.row_count,
            "last_insert_id": result.last_insert_id,
        }));
    }
    // Additive diagnostics only: which UPDATE / DELETE matched no row (or, on
    // MySQL, changed no value). Never changes ok or the transaction outcome.
    // Passing only the row counts keeps ResultSet out of the FRB-facing module.
    let row_counts: Vec<u64> = executed.iter().map(|result| result.row_count).collect();
    let zero_rows = zero_row_results(&planned, &row_counts);
    Ok(json!({
        "ok": true,
        "database": database,
        "table": table,
        "results": results,
        "rows_affected": rows_affected,
        "zero_row_results": zero_rows,
    }))
}

/// Table metadata for the graphical query builder.
pub async fn builder_schema(database: String) -> anyhow::Result<Value> {
    let state = state()?;
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(Some(&database)).await?;
    driver.builder_schema(&conn, &database).await.map_err(anyhow::Error::from)
}

/// Table metadata for the graphical query builder, across several namespaces.
///
/// Advanced (cross-database) queries can join tables from more than one
/// database. Each requested namespace is loaded separately and its tables are
/// returned with their namespace attached, so the builder can qualify them.
/// Namespaces the account may not open are reported in `denied` instead of
/// failing the whole call: the picker keeps working with the rest and tells the
/// user which database was skipped.
pub async fn builder_schema_multi(databases: Vec<String>) -> anyhow::Result<Value> {
    let state = state()?;
    let active = state.active().await?;
    let driver = state.driver(&active.driver_id)?;
    let mut schemas: Vec<Value> = Vec::new();
    let mut denied: Vec<Value> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for raw in databases {
        let database = raw.trim().to_string();
        if database.is_empty() || seen.contains(&database) {
            continue;
        }
        seen.push(database.clone());
        // MySQL namespaces are physical databases (visibility + pool per
        // database); PostgreSQL namespaces are schemas inside the active
        // database, so the schema list itself is the authorization boundary
        // and no per-namespace pool is opened.
        let schemas_only = !driver.namespaces_are_databases();
        if !schemas_only {
            if let Err(e) = active.ensure_visible(&database) {
                denied.push(json!({ "database": database, "error": e.to_string() }));
                continue;
            }
        }
        let conn_result = if schemas_only {
            state.connection_for(None).await
        } else {
            state.connection_for_database(&database).await
        };
        let conn = match conn_result {
            Ok(conn) => conn,
            Err(e) => {
                denied.push(json!({ "database": database, "error": e.to_string() }));
                continue;
            }
        };
        match driver.builder_schema(&conn, &database).await {
            Ok(mut schema) => {
                if let Some(map) = schema.as_object_mut() {
                    map.insert("database".to_string(), json!(database));
                }
                schemas.push(schema);
            }
            Err(e) => {
                denied.push(json!({ "database": database, "error": e.to_string() }));
            }
        }
    }
    Ok(json!({ "schemas": schemas, "denied": denied }))
}

/// Views / routines / triggers / events of a namespace.
pub async fn list_objects(database: String) -> anyhow::Result<Value> {
    let state = state()?;
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(Some(&database)).await?;
    driver.objects(&conn, &database).await.map_err(anyhow::Error::from)
}

#[derive(Deserialize)]
struct ObjectRequest {
    sql: String,
}

/// True when the text holds a compound body whose internal semicolons must not
/// be treated as statement separators.
fn has_compound_body(sql: &str) -> bool {
    if sql.contains('$') {
        return true;
    }
    let upper = sql.to_ascii_uppercase();
    upper.contains(" BEGIN") && upper.contains(" END")
}

/// Run a CREATE/ALTER typed in the object editor.
pub async fn create_object(database: String, body: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let req: ObjectRequest = parse("object", body)?;
    let sql = req.sql.trim();
    if sql.is_empty() {
        return Err(AppError::bad("SQL 不能为空").into());
    }
    let conn = state.connection_for(Some(&database)).await?;
    let upper = sql.to_ascii_uppercase();
    if !upper.starts_with("CREATE ") && !upper.starts_with("ALTER ") {
        return Err(AppError::bad("对象定义必须以 CREATE 或 ALTER 开头").into());
    }
    // Compound bodies (MySQL BEGIN..END, PostgreSQL dollar-quoted blocks) must
    // run as one statement. Everything here goes through the unprepared path
    // because MySQL rejects routines/triggers/events when prepared (error 1295).
    // The web build only checked that the whole payload *started* with CREATE or
    // ALTER, then ran every split statement. A payload such as
    //   CREATE VIEW v AS SELECT 1; DROP TABLE users;
    // therefore passed the guard and dropped the table. Reject a multi-statement
    // object definition outright: the editor only ever needs one statement.
    let statements = if has_compound_body(sql) {
        vec![sql.to_string()]
    } else {
        let skill = state.driver_for_active().await?;
        let split = crate::db::split_statements_for(skill.dialect(), sql);
        if split.len() > 1 {
            return Err(AppError::bad("对象定义只能包含一条语句，请分次执行").into());
        }
        split
    };
    let mut results: Vec<Value> = Vec::new();
    let mut failed = 0usize;
    for statement in statements {
        let outcome = conn.run_raw(&statement).await;
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
    Ok(json!({ "ok": failed == 0, "failed": failed, "results": results }))
}

/// CREATE statement of one existing object.
pub async fn object_definition(database: String, kind: String, name: String) -> anyhow::Result<Value> {
    let state = state()?;
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(Some(&database)).await?;
    let ddl = driver.object_definition(&conn, &database, &kind, &name).await?;
    Ok(json!({ "ddl": ddl, "kind": kind, "name": name, "driver": driver.id() }))
}

pub async fn drop_object(database: String, kind: String, name: String) -> anyhow::Result<Value> {
    let state = state()?;
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(Some(&database)).await?;
    let sql = driver.object_drop_sql(&database, &kind, &name)?;
    let outcome = conn.run_raw(&sql).await;
    if let Some(err) = outcome.error {
        return Err(AppError::bad(err).into());
    }
    Ok(json!({ "ok": true, "statement": sql }))
}

/// Native or synthesised CREATE TABLE, for the DDL tab.
pub async fn table_ddl(database: String, table: String) -> anyhow::Result<Value> {
    let state = state()?;
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(Some(&database)).await?;
    let ddl = super::export::ddl_for(driver.as_ref(), &conn, &database, &table).await?;
    Ok(json!({ "ddl": ddl, "driver": driver.id() }))
}

#[derive(Deserialize)]
struct AlterRequest {
    #[serde(default)]
    dry_run: bool,
    #[serde(flatten)]
    spec: crate::drivers::AlterTableSpec,
}

/// Apply (or preview) a batch of table-designer changes.
pub async fn alter_table(database: String, table: String, body: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let req: AlterRequest = parse("alter", body)?;
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(Some(&database)).await?;
    let statements = driver.alter_table_statements(&database, &table, &req.spec)?;
    if req.dry_run {
        return Ok(json!({
            "dry_run": true,
            "statements": statements,
            "failed": 0,
            "results": [],
        }));
    }
    let mut results: Vec<Value> = Vec::new();
    let mut failed = 0usize;
    for statement in &statements {
        let outcome = conn.run_one(statement.clone()).await;
        let error = outcome.error.clone();
        if error.is_some() {
            failed += 1;
        }
        results.push(json!({
            "statement": statement,
            "error": error,
            "rows_affected": outcome.row_count,
        }));
        if failed > 0 {
            break;
        }
    }
    Ok(json!({
        "dry_run": false,
        "statements": statements,
        "results": results,
        "failed": failed,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn change(index: usize, action: &str, keys: Value) -> PlannedChange {
        let Value::Object(keys) = keys else {
            panic!("keys must be an object");
        };
        PlannedChange {
            index,
            action: action.to_string(),
            sql: String::new(),
            keys,
        }
    }

    #[test]
    fn zero_row_results_flag_only_zero_row_update_and_delete() {
        let changes = vec![
            change(0, "update", json!({ "id": 1 })),
            change(1, "update", json!({ "id": 2 })),
            change(2, "delete", json!({ "id": 3 })),
            change(3, "insert", json!({})),
            change(4, "delete", json!({ "id": 4 })),
        ];
        let row_counts = vec![
            0u64, // update matched nothing
            1,    // update hit one row
            0,    // delete matched nothing
            1,    // insert is never reported
            2,    // delete hit two rows, not zero
        ];
        assert_eq!(
            zero_row_results(&changes, &row_counts),
            vec![
                json!({ "index": 0, "action": "update", "keys": { "id": 1 } }),
                json!({ "index": 2, "action": "delete", "keys": { "id": 3 } }),
            ]
        );
    }

    #[test]
    fn zero_row_results_are_empty_when_everything_matched() {
        let changes = vec![
            change(0, "update", json!({ "id": 1 })),
            change(1, "delete", json!({ "id": 2 })),
        ];
        let row_counts = vec![1u64, 1];
        assert!(zero_row_results(&changes, &row_counts).is_empty());
    }

    #[test]
    fn zero_row_results_keep_the_incoming_change_index() {
        // The reported index must line up with the incoming changes array, not
        // with the position inside the filtered diagnostics list.
        let changes = vec![
            change(0, "insert", json!({})),
            change(1, "update", json!({ "id": 9 })),
            change(2, "update", json!({ "id": 8 })),
        ];
        let row_counts = vec![1u64, 0, 0];
        let zero = zero_row_results(&changes, &row_counts);
        assert_eq!(zero.len(), 2);
        assert_eq!(zero[0]["index"], json!(1));
        assert_eq!(zero[1]["index"], json!(2));
        assert_eq!(zero[0]["keys"], json!({ "id": 9 }));
    }
}
