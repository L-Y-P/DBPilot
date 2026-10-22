//! Schema compare and sync between two namespaces of the same connection.
//!
//! Ports the web `routes/sync.rs`, but the desktop build is the one that had to
//! become usable: the old default picked `information_schema` (an empty diff),
//! a missing table was created without indexes / comments / auto-increment and
//! with unquoted string defaults, and two indexes with the same name but
//! different columns were considered equal.
//!
//! Both source and target are checked against the connection `only_db` /
//! `hide_db` scope; the web version only checked the source and the target,
//! which this preserves and extends to the write path as well.

use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

use super::{parse, state};
use crate::core::connection::ConnectionHandle;
use crate::core::driver::DatabaseDriver;
use crate::drivers::{
    qi, qualify, quote_str_for, safe_default, safe_ident, AlterColumn, AlterIndex,
    AlterTableSpec, DriverKind,
};
use crate::error::{AppError, AppResult};

#[derive(Deserialize)]
struct DiffRequest {
    /// Schema for PostgreSQL, database for MySQL/SQLite.
    source: String,
    target: String,
    /// Physical PostgreSQL database; omitted = active database.
    #[serde(default)]
    source_database: Option<String>,
    #[serde(default)]
    target_database: Option<String>,
    #[serde(default)]
    table: Option<String>,
    #[serde(default)]
    allow_drop: bool,
    #[serde(default)]
    dry_run: bool,
}

#[derive(Clone)]
struct TableDiff {
    name: String,
    status: String,
    statements: Vec<String>,
    warnings: Vec<String>,
    columns_added: usize,
    columns_changed: usize,
    columns_dropped: usize,
    indexes_added: usize,
    indexes_dropped: usize,
}

fn as_str(v: Option<&Value>) -> String {
    v.and_then(|x| x.as_str()).unwrap_or("").to_string()
}

fn textual(type_name: &str) -> bool {
    let t = type_name.to_ascii_lowercase();
    t.contains("char")
        || t.contains("text")
        || t.contains("enum")
        || t.contains("set")
        || t.contains("json")
        || t.contains("date")
        || t.contains("time")
        || t.contains("year")
        || t.contains("uuid")
        || t.contains("xml")
        || t.contains("clob")
        || t.contains("interval")
        || t.contains("inet")
        || t.contains("cidr")
        || t.contains("macaddr")
        || t.contains("citext")
}

fn numeric(type_name: &str) -> bool {
    let t = type_name.to_ascii_lowercase();
    t.contains("int")
        || t.contains("decimal")
        || t.contains("numeric")
        || t.contains("float")
        || t.contains("double")
        || t.contains("real")
        || t.contains("money")
        || t.starts_with("bit")
        || t == "serial"
        || t == "bigserial"
        || t == "smallserial"
}

/// Turn a structure default into a DDL literal.
///
/// `information_schema.COLUMN_DEFAULT` returns MySQL enum / char defaults
/// **unquoted** (`Engineering`), so pasting it straight into DDL produced
/// `DEFAULT Engineering` — invalid SQL. Numeric defaults stay unquoted, known
/// time expressions stay expressions, everything else is quoted. PostgreSQL
/// defaults are already expressions (`'x'::text`) and only need the same
/// validation the designer uses.
fn default_literal(
    driver: DriverKind,
    type_name: &str,
    raw: Option<&str>,
) -> AppResult<Option<String>> {
    let value = match raw.map(str::trim).filter(|s| !s.is_empty()) {
        Some(v) => v,
        None => return Ok(None),
    };
    if value.eq_ignore_ascii_case("null") {
        return Ok(None);
    }
    if driver == DriverKind::Postgres {
        return Ok(Some(safe_default(value)?));
    }
    let upper = value.to_ascii_uppercase();
    if upper.starts_with("CURRENT_TIMESTAMP")
        || upper.starts_with("CURRENT_DATE")
        || upper.starts_with("CURRENT_TIME")
        || upper.starts_with("NOW(")
        || (upper.starts_with("B'") && value.ends_with('\''))
    {
        return Ok(Some(value.to_string()));
    }
    // MySQL 8 expression defaults (JSON / UUID) are written in parentheses.
    if value.starts_with('(') && value.ends_with(')') {
        return Ok(Some(safe_default(value)?));
    }
    if numeric(type_name)
        && value
            .chars()
            .all(|c| c.is_ascii_digit() || matches!(c, '.' | '-' | '+' | 'e' | 'E'))
    {
        return Ok(Some(value.to_string()));
    }
    if textual(type_name) {
        return Ok(Some(quote_str_for(driver, value)));
    }
    // Unknown type: quote instead of injecting a bare identifier.
    Ok(Some(quote_str_for(driver, value)))
}

fn default_of(v: Option<&Value>) -> Option<String> {
    match v {
        Some(Value::String(s)) if !s.is_empty() => Some(s.clone()),
        Some(Value::Null) | None => None,
        Some(other) => {
            let text = other.to_string();
            if text.is_empty() {
                None
            } else if text == "null" {
                None
            } else {
                Some(text)
            }
        }
    }
}

fn column_payload(c: &Value, with_charset: bool, with_collation: bool) -> AlterColumn {
    let auto_increment = as_str(c.get("EXTRA")).contains("auto_increment");
    AlterColumn {
        name: as_str(c.get("name")),
        col_type: as_str(c.get("type_name")),
        nullable: c.get("IS_NULLABLE").and_then(|v| v.as_str()) == Some("YES"),
        // PostgreSQL reports an identity column's sequence as the default;
        // emitting both DEFAULT nextval(...) and GENERATED ... IDENTITY is
        // invalid DDL. The identity clause is the one to keep.
        default: if auto_increment {
            None
        } else {
            default_of(c.get("COLUMN_DEFAULT"))
        },
        auto_increment,
        comment: c
            .get("COLUMN_COMMENT")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string()),
        charset: if with_charset {
            c.get("CHARACTER_SET_NAME")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string())
        } else {
            None
        },
        collation: if with_collation {
            c.get("COLLATION_NAME")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string())
        } else {
            None
        },
    }
}

fn same_column(a: &AlterColumn, b: &AlterColumn) -> bool {
    a.col_type.eq_ignore_ascii_case(&b.col_type)
        && a.nullable == b.nullable
        && a.default == b.default
        && a.auto_increment == b.auto_increment
        && a.charset == b.charset
        && a.collation == b.collation
        && a.comment == b.comment
}

fn index_list(structure: &Value) -> Vec<AlterIndex> {
    let mut order: Vec<String> = Vec::new();
    let mut map: HashMap<String, AlterIndex> = HashMap::new();
    for x in structure
        .get("indexes")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
    {
        let name = as_str(x.get("INDEX_NAME"));
        let is_primary = x.get("IS_PRIMARY").and_then(|v| v.as_bool()) == Some(true);
        let is_auto = x.get("IS_AUTO").and_then(|v| v.as_bool()) == Some(true);
        // MySQL names its primary key "PRIMARY"; PostgreSQL marks it explicitly
        // (`orders_pkey`); SQLite autoindex names are reserved and cannot be
        // created by hand. Recreating the primary key as an index fails because
        // CREATE TABLE already created it, which the live PG round-trip caught.
        if name.is_empty()
            || name.eq_ignore_ascii_case("PRIMARY")
            || is_primary
            || is_auto
            || name.starts_with("sqlite_autoindex")
        {
            continue;
        }
        let unique = x.get("NON_UNIQUE").and_then(|v| v.as_i64()) == Some(0);
        let column = as_str(x.get("COLUMN_NAME"));
        if !map.contains_key(&name) {
            order.push(name.clone());
            map.insert(
                name.clone(),
                AlterIndex {
                    name: name.clone(),
                    unique,
                    columns: Vec::new(),
                },
            );
        }
        if !column.is_empty() {
            if let Some(entry) = map.get_mut(&name) {
                entry.columns.push(column);
            }
        }
    }
    order.into_iter().filter_map(|n| map.remove(&n)).collect()
}

fn same_index(a: &AlterIndex, b: &AlterIndex) -> bool {
    a.unique == b.unique && a.columns == b.columns
}

/// Rebuild a table that is missing from the target.
///
/// The old version created columns + primary key only: no secondary indexes,
/// no charset / collation, no column comments, no AUTO_INCREMENT and no
/// PostgreSQL identity. A "synced" table therefore differed from the source in
/// exactly the ways the diff screen does not show.
fn create_statements(
    kind: DriverKind,
    target: &str,
    table: &str,
    structure: &Value,
) -> AppResult<Vec<String>> {
    let d = kind;
    let empty = Vec::new();
    let columns = structure
        .get("columns")
        .and_then(|v| v.as_array())
        .unwrap_or(&empty)
        .clone();
    let mut defs: Vec<String> = Vec::new();
    let mut comments: Vec<String> = Vec::new();
    for c in &columns {
        let name = as_str(c.get("name"));
        let ty = as_str(c.get("type_name"));
        if name.is_empty() || ty.is_empty() {
            continue;
        }
        // The type comes from server metadata, but it is still interpolated
        // into DDL: reject statement terminators / comment openers here too.
        if !crate::drivers::safe_type(&ty) {
            return Err(AppError::bad(format!("不支持的字段类型 '{}'", ty)));
        }
        let mut def = format!("{} {}", qi(d, &name), ty);
        if d == DriverKind::Mysql && textual(&ty) {
            if let Some(charset) = c
                .get("CHARACTER_SET_NAME")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
            {
                def.push_str(&format!(" CHARACTER SET {}", safe_ident(charset)?));
            }
            if let Some(collation) = c
                .get("COLLATION_NAME")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
            {
                def.push_str(&format!(" COLLATE {}", safe_ident(collation)?));
            }
        }
        let auto = as_str(c.get("EXTRA")).contains("auto_increment");
        if d == DriverKind::Postgres && auto {
            def.push_str(" GENERATED BY DEFAULT AS IDENTITY");
        } else {
            let default = default_of(c.get("COLUMN_DEFAULT"));
            if let Some(lit) = default_literal(d, &ty, default.as_deref())? {
                def.push_str(&format!(" DEFAULT {}", lit));
            }
            if d == DriverKind::Mysql && auto {
                def.push_str(" AUTO_INCREMENT");
            }
        }
        if c.get("IS_NULLABLE").and_then(|v| v.as_str()) != Some("YES") {
            def.push_str(" NOT NULL");
        }
        if d == DriverKind::Mysql {
            if let Some(comment) = c
                .get("COLUMN_COMMENT")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
            {
                def.push_str(&format!(" COMMENT {}", quote_str_for(d, comment)));
            }
        } else if d == DriverKind::Postgres {
            if let Some(comment) = c
                .get("COLUMN_COMMENT")
                .and_then(|v| v.as_str())
                .filter(|s| !s.is_empty())
            {
                comments.push(format!(
                    "COMMENT ON COLUMN {}.{} IS {}",
                    qualify(d, target, table),
                    qi(d, &name),
                    quote_str_for(d, comment)
                ));
            }
        }
        defs.push(def);
    }

    let pk: Vec<String> = structure
        .get("primary_key")
        .and_then(|v| v.as_array())
        .map(|list| {
            list.iter()
                .filter_map(|v| v.as_str())
                .map(|s| qi(d, s))
                .collect()
        })
        .unwrap_or_default();
    if !pk.is_empty() {
        defs.push(format!("PRIMARY KEY ({})", pk.join(", ")));
    }

    let indexes = index_list(structure);
    // MySQL requires an AUTO_INCREMENT column to be indexed at CREATE time, so
    // its secondary indexes go inside the CREATE TABLE statement. PostgreSQL /
    // SQLite use separate CREATE INDEX statements below.
    if d == DriverKind::Mysql {
        for idx in &indexes {
            if idx.columns.is_empty() {
                continue;
            }
            let cols: Vec<String> = idx.columns.iter().map(|c| qi(d, c)).collect();
            let kind = if idx.unique { "UNIQUE KEY" } else { "KEY" };
            defs.push(format!(
                "{} {} ({})",
                kind,
                qi(d, &idx.name),
                cols.join(", ")
            ));
        }
    }

    let info = structure.get("info").cloned().unwrap_or(Value::Null);
    let mut create = format!(
        "CREATE TABLE {} (\n  {}\n)",
        qualify(d, target, table),
        defs.join(",\n  ")
    );
    if d == DriverKind::Mysql {
        if let Some(engine) = info
            .get("ENGINE")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
        {
            if safe_ident(engine).is_ok() {
                create.push_str(&format!(" ENGINE={}", engine));
            }
        }
        if let Some(collation) = info
            .get("TABLE_COLLATION")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
        {
            if safe_ident(collation).is_ok() {
                create.push_str(&format!(" COLLATE={}", collation));
            }
        }
        if let Some(comment) = info
            .get("TABLE_COMMENT")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
        {
            create.push_str(&format!(" COMMENT={}", quote_str_for(d, comment)));
        }
    }

    let mut out = vec![create];
    if d == DriverKind::Postgres {
        if let Some(comment) = info
            .get("TABLE_COMMENT")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
        {
            out.push(format!(
                "COMMENT ON TABLE {} IS {}",
                qualify(d, target, table),
                quote_str_for(d, comment)
            ));
        }
        out.extend(comments);
    }
    if d != DriverKind::Mysql {
        for idx in &indexes {
            if idx.columns.is_empty() {
                continue;
            }
            let cols: Vec<String> = idx.columns.iter().map(|c| qi(d, c)).collect();
            let kind = if idx.unique { "UNIQUE INDEX" } else { "INDEX" };
            out.push(format!(
                "CREATE {} {} ON {} ({})",
                kind,
                qi(d, &idx.name),
                qualify(d, target, table),
                cols.join(", ")
            ));
        }
    }
    Ok(out)
}

/// Quote / normalise the defaults of columns added by an ALTER.
///
/// The driver's column clause validates defaults with `safe_default`, which
/// expects the caller to have produced a DDL literal already.
fn alter_spec_for_ddl(driver: DriverKind, spec: &AlterTableSpec) -> AppResult<AlterTableSpec> {
    let mut out = spec.clone();
    for c in out
        .add_columns
        .iter_mut()
        .chain(out.modify_columns.iter_mut())
    {
        if let Some(raw) = c
            .default
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
        {
            c.default = default_literal(driver, &c.col_type, Some(&raw))?;
        }
    }
    Ok(out)
}

async fn diff_table(
    driver: &dyn DatabaseDriver,
    target_conn: &ConnectionHandle,
    req: &DiffRequest,
    name: &str,
    source_structure: &Value,
) -> AppResult<TableDiff> {
    // The target side (tables, structure, DDL) runs on the target database's
    // pool; the source structure was already read from the source pool.
    let target_tables = driver.list_tables(&target_conn, &req.target).await?;
    let exists = target_tables
        .iter()
        .any(|t| t.get("name").and_then(|v| v.as_str()) == Some(name));
    if !exists {
        return Ok(TableDiff {
            name: name.to_string(),
            status: "missing".to_string(),
            statements: create_statements(driver.kind(), &req.target, name, source_structure)?,
            warnings: Vec::new(),
            columns_added: 0,
            columns_changed: 0,
            columns_dropped: 0,
            indexes_added: 0,
            indexes_dropped: 0,
        });
    }

    let target_structure = driver.table_structure(target_conn, &req.target, name).await?;
    let with_charset = driver.kind() == DriverKind::Mysql;
    let with_collation = true;
    let source_columns: Vec<AlterColumn> = source_structure
        .get("columns")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
        .iter()
        .map(|c| column_payload(c, with_charset, with_collation))
        .collect();
    let target_columns: Vec<AlterColumn> = target_structure
        .get("columns")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
        .iter()
        .map(|c| column_payload(c, with_charset, with_collation))
        .collect();

    let mut spec = AlterTableSpec::default();
    let mut warnings: Vec<String> = Vec::new();
    for c in &source_columns {
        match target_columns.iter().find(|t| t.name == c.name) {
            None => spec.add_columns.push(c.clone()),
            Some(t) => {
                if !same_column(c, t) {
                    spec.modify_columns.push(c.clone());
                }
            }
        }
    }
    for t in &target_columns {
        if !source_columns.iter().any(|c| c.name == t.name) {
            if req.allow_drop {
                spec.drop_columns.push(t.name.clone());
            } else {
                warnings.push(format!("目标多出字段 {}（未勾选允许删除，已跳过）", t.name));
            }
        }
    }

    let source_indexes = index_list(source_structure);
    let target_indexes = index_list(&target_structure);
    for i in &source_indexes {
        match target_indexes.iter().find(|t| t.name == i.name) {
            None => spec.add_indexes.push(i.clone()),
            Some(t) if !same_index(i, t) => {
                if req.allow_drop {
                    // Same name, different definition: drop then recreate. The
                    // per-driver ALTER builders emit drops before adds.
                    spec.drop_indexes.push(i.name.clone());
                    spec.add_indexes.push(i.clone());
                } else {
                    warnings.push(format!(
                        "索引 {} 定义不同（未勾选允许删除，已跳过）",
                        i.name
                    ));
                }
            }
            Some(_) => {}
        }
    }
    for i in &target_indexes {
        if !source_indexes.iter().any(|s| s.name == i.name) {
            if req.allow_drop {
                spec.drop_indexes.push(i.name.clone());
            } else {
                warnings.push(format!("目标多出索引 {}（未勾选允许删除，已跳过）", i.name));
            }
        }
    }

    let statements = if spec.is_empty() {
        Vec::new()
    } else {
        let ddl_spec = alter_spec_for_ddl(driver.kind(), &spec)?;
        driver.alter_table_statements(&req.target, name, &ddl_spec)?
    };
    let status = if statements.is_empty() { "same" } else { "differs" }.to_string();
    Ok(TableDiff {
        name: name.to_string(),
        status,
        statements,
        warnings,
        columns_added: spec.add_columns.len(),
        columns_changed: spec.modify_columns.len(),
        columns_dropped: spec.drop_columns.len(),
        indexes_added: spec.add_indexes.len(),
        indexes_dropped: spec.drop_indexes.len(),
    })
}

/// Resolve the source and target pools.
///
/// PostgreSQL: source/target are schemas; source_database/target_database choose
/// the physical databases, defaulting to the active one. MySQL: source/target
/// are databases (the fields are accepted but optional). SQLite keeps one pool.
async fn sync_connections(
    state: &crate::state::AppState,
    req: &DiffRequest,
) -> AppResult<(
    std::sync::Arc<dyn DatabaseDriver>,
    ConnectionHandle,
    ConnectionHandle,
    bool,
    Option<String>,
    Option<String>,
)> {
    let active = state.active().await?;
    let active_database = state.active_database().await;
    let driver = state.driver_for_active().await?;
    let requested = |value: &Option<String>| -> Option<String> {
        value
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
    };
    let source_db = requested(&req.source_database);
    let target_db = requested(&req.target_database);
    match active.spec.driver {
        DriverKind::Postgres => {
            let source_database = source_db
                .or(active_database)
                .or_else(|| active.spec.database().map(str::to_string))
                .ok_or_else(|| AppError::bad("尚未选择源数据库"))?;
            let target_database = target_db
                .clone()
                .unwrap_or_else(|| source_database.clone());
            active.ensure_visible(&source_database)?;
            active.ensure_visible(&target_database)?;
            let source_conn = state.connection_for_database(&source_database).await?;
            let target_conn = state.connection_for_database(&target_database).await?;
            let same = source_database == target_database;
            Ok((
                driver,
                source_conn,
                target_conn,
                same,
                Some(source_database),
                Some(target_database),
            ))
        }
        DriverKind::Mysql => {
            active.ensure_visible(&req.source)?;
            active.ensure_visible(&req.target)?;
            let source_conn = state.connection_for(Some(&req.source)).await?;
            let target_conn = state.connection_for(Some(&req.target)).await?;
            let same = req.source == req.target;
            Ok((driver, source_conn, target_conn, same, None, None))
        }
        DriverKind::Sqlite => {
            active.ensure_visible(&req.source)?;
            active.ensure_visible(&req.target)?;
            let source_conn = state.connection_for(Some(&req.source)).await?;
            let target_conn = state.connection_for(Some(&req.target)).await?;
            let same = req.source == req.target;
            Ok((driver, source_conn, target_conn, same, None, None))
        }
    }
}

async fn compute(state: &crate::state::AppState, req: &DiffRequest) -> AppResult<Vec<TableDiff>> {
    if req.source.trim().is_empty() || req.target.trim().is_empty() {
        return Err(AppError::bad("请选择源数据库和目标数据库").into());
    }
    let (driver, source_conn, target_conn, same_database, _, _) =
        sync_connections(state, req).await?;
    if req.source == req.target && same_database {
        return Err(AppError::bad("源与目标不能是同一个数据库中的同名模式").into());
    }
    let filter = req.table.as_deref().map(str::trim).filter(|s| !s.is_empty());

    let mut out: Vec<TableDiff> = Vec::new();
    let mut source_names: HashSet<String> = HashSet::new();
    let tables = driver.list_tables(&source_conn, &req.source).await?;
    for t in tables {
        if t.get("type").and_then(|v| v.as_str()) != Some("BASE TABLE") {
            continue;
        }
        let name = as_str(t.get("name"));
        if name.is_empty() {
            continue;
        }
        if let Some(f) = filter {
            if f != name {
                continue;
            }
        }
        source_names.insert(name.clone());
        let structure = driver
            .table_structure(&source_conn, &req.source, &name)
            .await?;
        out.push(diff_table(driver.as_ref(), &target_conn, req, &name, &structure).await?);
    }

    // Tables that exist only in the target are reported instead of silently
    // ignored (important for a cross-database diff). They are never dropped
    // automatically; DROP TABLE is destructive and needs an explicit action.
    let target_tables = driver.list_tables(&target_conn, &req.target).await?;
    for t in target_tables {
        if t.get("type").and_then(|v| v.as_str()) != Some("BASE TABLE") {
            continue;
        }
        let name = as_str(t.get("name"));
        if name.is_empty() || source_names.contains(&name) {
            continue;
        }
        if let Some(f) = filter {
            if f != name {
                continue;
            }
        }
        out.push(TableDiff {
            name: name.clone(),
            status: "target_only".to_string(),
            statements: Vec::new(),
            warnings: vec![format!("目标库多出的表 {}（结构同步不会删除它）", name)],
            columns_added: 0,
            columns_changed: 0,
            columns_dropped: 0,
            indexes_added: 0,
            indexes_dropped: 0,
        });
    }
    Ok(out)
}

fn to_json(
    diffs: &[TableDiff],
    source: &str,
    target: &str,
    source_database: Option<&str>,
    target_database: Option<&str>,
    dry_run: bool,
) -> Value {
    let tables: Vec<Value> = diffs
        .iter()
        .map(|d| {
            json!({
                "name": d.name,
                "status": d.status,
                "statements": d.statements,
                "warnings": d.warnings,
                "columns_added": d.columns_added,
                "columns_changed": d.columns_changed,
                "columns_dropped": d.columns_dropped,
                "indexes_added": d.indexes_added,
                "indexes_dropped": d.indexes_dropped,
            })
        })
        .collect();
    json!({
        "source": source,
        "target": target,
        "source_database": source_database,
        "target_database": target_database,
        "dry_run": dry_run,
        "tables": tables,
        "changed": diffs.iter().filter(|d| d.status != "same").count(),
    })
}

/// Compare source and target. Always a dry run, matching the web endpoint.
pub async fn schema_diff(body: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let mut req: DiffRequest = parse("diff", body)?;
    req.dry_run = true;
    let (_driver, _source_conn, _target_conn, _same, source_database, target_database) =
        sync_connections(&state, &req).await?;
    let diffs = compute(&state, &req).await?;
    Ok(to_json(
        &diffs,
        &req.source,
        &req.target,
        source_database.as_deref(),
        target_database.as_deref(),
        true,
    ))
}

/// Compare and (unless `dry_run`) apply the statements to the target.
pub async fn schema_sync(body: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let req: DiffRequest = parse("sync", body)?;
    let (_driver, _source_conn, target_conn, _same, source_database, target_database) =
        sync_connections(&state, &req).await?;
    let diffs = compute(&state, &req).await?;
    if req.dry_run {
        return Ok(to_json(
            &diffs,
            &req.source,
            &req.target,
            source_database.as_deref(),
            target_database.as_deref(),
            true,
        ));
    }
    let mut results: Vec<Value> = Vec::new();
    let mut failed = 0usize;
    for d in &diffs {
        for statement in &d.statements {
            let outcome = target_conn.run_one(statement.clone()).await;
            if outcome.error.is_some() {
                failed += 1;
            }
            results.push(json!({
                "table": d.name,
                "statement": statement,
                "error": outcome.error,
            }));
            if failed > 0 {
                break;
            }
        }
        if failed > 0 {
            break;
        }
    }
    let payload = to_json(
        &diffs,
        &req.source,
        &req.target,
        source_database.as_deref(),
        target_database.as_deref(),
        false,
    );
    Ok(json!({
        "summary": payload,
        "results": results,
        "failed": failed,
        "executed": results.len(),
    }))
}
