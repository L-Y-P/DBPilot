//! 门面里「与具体驱动无关」的通用操作（P5）。
//!
//! 这些逻辑原本长在 drivers::Db 门面上，用 match self.driver 分派。P5 把它们
//! 抽成自由函数，参数是 &dyn DatabaseDriver + &ConnectionHandle：
//! * DatabaseDriver 的默认方法只需要一行转调，core 不用知道任何 SQL 细节；
//! * Db 门面保留同名方法做兼容（也转调这里），实现只有一份；
//! * api 直接用驱动 trait，不再接触门面。
//!
//! 分派原则：方言/DDL 文本用 driver.dialect() 或各驱动的纯函数；
//! 执行一律走 conn.execute / conn.run_one。

use serde_json::{json, Map, Value};

use crate::config::DriverKind;
use crate::connection::ConnectionHandle;
use crate::db::{split_statements, ResultSet};
use crate::driver::DatabaseDriver;
use crate::error::{AppError, AppResult};
use crate::paging::{page_plan, DataPage};
use crate::spec::{fk_parts, AlterTableSpec, CreateTableSpec};
use crate::sql::{create_database_sql, safe_type};

fn scalar_i64(rs: &ResultSet) -> i64 {
    rs.rows
        .first()
        .and_then(|r| r.first())
        .and_then(|v| {
            v.as_i64()
                .or_else(|| v.as_u64().map(|u| u as i64))
                .or_else(|| v.as_str().and_then(|s| s.parse::<i64>().ok()))
        })
        .unwrap_or(0)
}

// ------------------------------------------------------------------ DDL 文本

/// CREATE DATABASE / CREATE SCHEMA 预览语句。
pub(crate) fn create_database_statement<D: DatabaseDriver + ?Sized>(
    driver: &D,
    name: &str,
    charset: Option<&str>,
    collation: Option<&str>,
    template: Option<&str>,
    encoding: Option<&str>,
    owner: Option<&str>,
    tablespace: Option<&str>,
) -> AppResult<String> {
    let kind = driver.kind();
    if kind == DriverKind::Sqlite {
        return Err(AppError::bad(
            "SQLite has no CREATE DATABASE; create the file instead",
        ));
    }
    create_database_sql(kind, name, charset, collation, template, encoding, owner, tablespace)
}

/// CREATE SCHEMA（仅 PostgreSQL 有独立 schema 概念）。
pub(crate) fn create_schema_statement<D: DatabaseDriver + ?Sized>(
    driver: &D,
    name: &str,
) -> AppResult<String> {
    if driver.supports(crate::dialect::DialectCapability::CreateSchema) {
        Ok(format!(
            "CREATE SCHEMA IF NOT EXISTS {}",
            driver.dialect().quote_ident(name)
        ))
    } else if driver.kind() == DriverKind::Mysql {
        Err(AppError::bad("MySQL 的 schema 就是数据库；请新建数据库"))
    } else {
        Err(AppError::bad("SQLite 不支持 CREATE SCHEMA"))
    }
}

/// DROP DATABASE（MySQL / PostgreSQL；SQLite 的库是文件）。
pub(crate) fn drop_namespace_sql<D: DatabaseDriver + ?Sized>(driver: &D, name: &str) -> AppResult<String> {
    if driver.is_file_based() {
        return Err(AppError::bad("SQLite has no DROP DATABASE"));
    }
    Ok(format!(
        "DROP DATABASE {}",
        driver.dialect().quote_ident(name)
    ))
}

/// DROP SCHEMA ... CASCADE（仅 PostgreSQL）。
pub(crate) fn drop_schema_sql<D: DatabaseDriver + ?Sized>(driver: &D, name: &str) -> AppResult<String> {
    if driver.supports(crate::dialect::DialectCapability::CreateSchema) {
        Ok(format!(
            "DROP SCHEMA {} CASCADE",
            driver.dialect().quote_ident(name)
        ))
    } else if driver.kind() == DriverKind::Mysql {
        Err(AppError::bad("MySQL 的 schema 就是数据库；请删除数据库"))
    } else {
        Err(AppError::bad("SQLite 不支持 DROP SCHEMA"))
    }
}

// ------------------------------------------------------------- CREATE TABLE

/// 建表所需的全部语句（PostgreSQL 的注释要单独发）。
pub(crate) fn create_table_statements<D: DatabaseDriver + ?Sized>(
    driver: &D,
    ns: &str,
    spec: &CreateTableSpec,
) -> AppResult<Vec<String>> {
    if spec.columns.is_empty() {
        return Err(AppError::bad("at least one column is required"));
    }
    for c in &spec.columns {
        if c.name.trim().is_empty() {
            return Err(AppError::bad("column name is required"));
        }
        if !safe_type(&c.col_type) {
            return Err(AppError::bad(format!(
                "unsupported column type '{}'",
                c.col_type
            )));
        }
    }
    for fk in &spec.foreign_keys {
        fk_parts(fk)?;
    }
    let dialect = driver.dialect();
    // 33 轮拆 crate：建表 DDL 通过方言 trait 回到驱动实现，
    // core 不再调用 drivers::mysql/postgres/sqlite 的具体函数。
    let mut out = vec![dialect.create_table_sql(ns, spec)?];
    if driver.kind() == DriverKind::Postgres {
        if let Some(comment) = spec.comment.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            out.push(format!(
                "COMMENT ON TABLE {} IS {}",
                dialect.qualify(ns, &spec.name),
                dialect.quote_string(comment)
            ));
        }
        // PostgreSQL 没有行内列注释语法：设计器的每列备注要单独发 COMMENT ON COLUMN。
        for column in &spec.columns {
            if let Some(comment) = column
                .comment
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                out.push(format!(
                    "COMMENT ON COLUMN {}.{} IS {}",
                    dialect.qualify(ns, &spec.name),
                    dialect.quote_ident(column.name.trim()),
                    dialect.quote_string(comment)
                ));
            }
        }
    }
    Ok(out)
}

/// ALTER TABLE 批次（设计器）。
pub(crate) fn alter_table_statements<D: DatabaseDriver + ?Sized>(
    driver: &D,
    ns: &str,
    table: &str,
    spec: &AlterTableSpec,
) -> AppResult<Vec<String>> {
    if spec.is_empty() {
        return Err(AppError::bad("没有需要应用的修改"));
    }
    for c in spec.add_columns.iter().chain(spec.modify_columns.iter()) {
        if c.name.trim().is_empty() {
            return Err(AppError::bad("字段名不能为空"));
        }
        if !c.col_type.is_empty() && !safe_type(&c.col_type) {
            return Err(AppError::bad(format!("不支持的字段类型 '{}'", c.col_type)));
        }
    }
    // 同上：ALTER 批次语句由方言提供（PostgreSQL 的注释语句仍在这里组装）。
    driver.dialect().alter_table_statements(ns, table, spec)
}

// ------------------------------------------------------------------- 执行类

pub(crate) async fn create_table<D: DatabaseDriver + ?Sized>(
    driver: &D,
    conn: &ConnectionHandle,
    ns: &str,
    spec: &CreateTableSpec,
) -> AppResult<()> {
    for sql in create_table_statements(driver, ns, spec)? {
        conn.exec(&sql).await?;
    }
    Ok(())
}

pub(crate) async fn create_schema<D: DatabaseDriver + ?Sized>(
    driver: &D,
    conn: &ConnectionHandle,
    name: &str,
) -> AppResult<()> {
    let sql = create_schema_statement(driver, name)?;
    conn.exec(&sql).await
}

pub(crate) async fn drop_schema<D: DatabaseDriver + ?Sized>(
    driver: &D,
    conn: &ConnectionHandle,
    name: &str,
) -> AppResult<()> {
    let sql = drop_schema_sql(driver, name)?;
    conn.exec(&sql).await
}

pub(crate) async fn drop_namespace<D: DatabaseDriver + ?Sized>(
    driver: &D,
    conn: &ConnectionHandle,
    name: &str,
) -> AppResult<()> {
    let sql = drop_namespace_sql(driver, name)?;
    conn.exec(&sql).await
}

/// DROP TABLE / DROP VIEW（先确认对象类型）。
pub(crate) async fn drop_table<D: DatabaseDriver + ?Sized>(
    driver: &D,
    conn: &ConnectionHandle,
    ns: &str,
    table: &str,
) -> AppResult<()> {
    let kind = driver
        .object_kind(conn, ns, table)
        .await?
        .ok_or_else(|| AppError::not_found(format!("'{}' does not exist", table)))?;
    let keyword = if kind.eq_ignore_ascii_case("VIEW") {
        "VIEW"
    } else {
        "TABLE"
    };
    let sql = format!("DROP {} {}", keyword, driver.dialect().qualify(ns, table));
    conn.exec(&sql).await
}

/// TRUNCATE（SQLite 用 DELETE FROM）。
pub(crate) async fn truncate<D: DatabaseDriver + ?Sized>(
    driver: &D,
    conn: &ConnectionHandle,
    ns: &str,
    table: &str,
) -> AppResult<()> {
    let kind = driver
        .object_kind(conn, ns, table)
        .await?
        .ok_or_else(|| AppError::not_found(format!("'{}' does not exist", table)))?;
    if kind.eq_ignore_ascii_case("VIEW") {
        return Err(AppError::bad("cannot truncate a view"));
    }
    let target = driver.dialect().qualify(ns, table);
    let sql = if driver.is_file_based() {
        format!("DELETE FROM {}", target)
    } else {
        format!("TRUNCATE TABLE {}", target)
    };
    conn.exec(&sql).await
}

/// 执行对象 DROP（SQL 文本由驱动提供）。
pub(crate) async fn drop_object<D: DatabaseDriver + ?Sized>(
    driver: &D,
    conn: &ConnectionHandle,
    ns: &str,
    kind: &str,
    name: &str,
) -> AppResult<()> {
    let sql = driver.object_drop_sql(ns, kind, name)?;
    conn.exec(&sql).await
}

/// 整段脚本（不含行数上限；控制台用 SessionHandle 的 run_limited）。
pub(crate) async fn run_sql<D: DatabaseDriver + ?Sized>(
    _driver: &D,
    conn: &ConnectionHandle,
    sql: &str,
) -> Vec<ResultSet> {
    let mut out = Vec::new();
    for stmt in split_statements(sql) {
        out.push(conn.run_one(stmt).await);
    }
    out
}

// ------------------------------------------------------------- 数据浏览/编辑

pub(crate) async fn data<D: DatabaseDriver + ?Sized>(
    driver: &D,
    conn: &ConnectionHandle,
    ns: &str,
    table: &str,
    query: &DataPage<'_>,
) -> AppResult<Value> {
    let structure = driver.table_structure(conn, ns, table).await?;
    let columns = structure
        .get("columns")
        .and_then(|c| c.as_array())
        .cloned()
        .unwrap_or_default();
    let primary_key_json = structure
        .get("primary_key")
        .cloned()
        .unwrap_or_else(|| json!([]));

    let (page, per_page) = query.normalized();
    let dialect = driver.dialect();

    // 排序按真实列名校验：未知列在这里就报错，绝不把调用方的字符串拼进 SQL。
    let mut sorts: Vec<(String, String)> = Vec::new();
    for (column, direction) in query.sorts {
        let column = column.trim();
        if column.is_empty() {
            continue;
        }
        let known = columns
            .iter()
            .any(|c| c.get("name").and_then(|v| v.as_str()) == Some(column));
        if !known {
            return Err(AppError::bad(format!("unknown column '{}'", column)));
        }
        sorts.push((column.to_string(), direction.to_string()));
    }
    let primary_key: Vec<String> = primary_key_json
        .as_array()
        .map(|names| {
            names
                .iter()
                .filter_map(|name| name.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();

    // 过滤文本永不直接拼接：按真实列名重新解析，只放行简单比较。
    let safe_filter = match query.filter.map(str::trim).filter(|s| !s.is_empty()) {
        Some(filter) => {
            let column_names: Vec<String> = columns
                .iter()
                .filter_map(|c| c.get("name").and_then(|v| v.as_str()).map(|s| s.to_string()))
                .collect();
            Some(crate::filter::parse_filter(filter, &column_names, driver.kind())?)
        }
        None => None,
    };

    // 游标只接受标量：对象/数组无法安全地变成 SQL 字面量比较。
    if let Some(after) = query.after {
        if !after.is_string() && !after.is_number() && !after.is_boolean() {
            return Err(AppError::bad("after 游标必须是字符串或数字"));
        }
    }

    let target = dialect.qualify(ns, table);
    let plan = page_plan(
        dialect,
        &target,
        &primary_key,
        &sorts,
        safe_filter.as_deref(),
        per_page,
        query.offset(),
        query.after,
        query.count,
        query.deferred,
    );

    // count=false 时跳过整表计数（宽表上 COUNT(*) 往往比取一页还贵）。
    let total = match plan.count_sql {
        Some(sql) => {
            let count = conn.run_one(sql).await;
            if let Some(err) = count.error {
                return Err(AppError::bad(err));
            }
            Some(scalar_i64(&count))
        }
        None => None,
    };

    let result = conn.run_one(plan.sql.clone()).await;
    if let Some(err) = result.error {
        return Err(AppError::bad(err));
    }

    let pages = total.map(|total| {
        if total <= 0 {
            1
        } else {
            ((total as u64) + per_page - 1) / per_page
        }
    });
    // 游标只在本页「装满」时给出：最后一页不满 per_page 说明后面没有行了，
    // 再返回一个游标会让 UI 多翻一页空白。这个判据对 keyset 与 OFFSET 都成立
    // （keyset 下本页同样从游标起连续取 per_page 行）。
    let next_cursor = if (result.rows.len() as u64) < per_page {
        None
    } else {
        plan.cursor_column
            .as_deref()
            .and_then(|column| crate::paging::next_cursor(&result.columns, &result.rows, column))
    };
    // `used_keyset` 的含义是「本次查询的游标分页生效」而不是「这一页真的收到了
    // after」：第一页没有游标，但客户端要据此决定能否把 next_cursor 接成链条
    // （table_view 在 used_keyset=false 时会退回 OFFSET 并丢弃游标栈）。
    let keyset_in_effect = plan.cursor_column.is_some();
    Ok(json!({
        "database": ns,
        "table": table,
        "columns": result.columns,
        "rows": result.rows,
        // count=false 时 total / pages 为 null（字段仍然存在，Dart 契约不变）。
        "total": total,
        "page": page,
        "per_page": per_page,
        "pages": pages,
        "primary_key": primary_key_json,
        "next_cursor": next_cursor,
        // 游标分页是否生效（形态允许 keyset）；第一页即 true，便于 UI 接链条。
        "used_keyset": keyset_in_effect,
        // 这一页是否真的用 after 代替了 OFFSET（第一页没有游标，故为 false）。
        "used_cursor": plan.used_keyset,
        "used_deferred": plan.used_deferred,
        // 实际执行的 SQL，便于测试与排查执行计划。
        "sql": plan.sql,
    }))
}

pub(crate) async fn change_row<D: DatabaseDriver + ?Sized>(
    driver: &D,
    conn: &ConnectionHandle,
    ns: &str,
    table: &str,
    action: &str,
    keys: &Map<String, Value>,
    values: &Map<String, Value>,
    limit_one: bool,
) -> AppResult<Value> {
    let dialect = driver.dialect();
    let target = dialect.qualify(ns, table);
    let wheres = keys
        .iter()
        .map(|(c, v)| {
            if v.is_null() {
                format!("{} IS NULL", dialect.quote_ident(c))
            } else {
                format!("{} = {}", dialect.quote_ident(c), dialect.literal(v))
            }
        })
        .collect::<Vec<_>>()
        .join(" AND ");
    // 用全部列匹配可能命中多行，所以收窄到一行。
    let (cond, tail) = if limit_one {
        match driver.kind() {
            DriverKind::Postgres => (
                format!("ctid = (SELECT ctid FROM {} WHERE {} LIMIT 1)", target, wheres),
                "",
            ),
            DriverKind::Sqlite => (
                format!("rowid = (SELECT rowid FROM {} WHERE {} LIMIT 1)", target, wheres),
                "",
            ),
            DriverKind::Mysql => (wheres.clone(), " LIMIT 1"),
        }
    } else {
        (wheres.clone(), "")
    };
    let sql = match action {
        "insert" => {
            if values.is_empty() {
                return Err(AppError::bad("insert requires at least one column"));
            }
            let cols: Vec<String> = values.keys().map(|c| dialect.quote_ident(c)).collect();
            let vals: Vec<String> = values.values().map(|v| dialect.literal(v)).collect();
            format!(
                "INSERT INTO {} ({}) VALUES ({})",
                target,
                cols.join(", "),
                vals.join(", ")
            )
        }
        "update" => {
            if values.is_empty() {
                return Err(AppError::bad("update requires at least one column"));
            }
            if keys.is_empty() {
                return Err(AppError::bad("update requires a row key"));
            }
            let sets: Vec<String> = values
                .iter()
                .map(|(c, v)| format!("{} = {}", dialect.quote_ident(c), dialect.literal(v)))
                .collect();
            format!(
                "UPDATE {} SET {} WHERE {}{}",
                target,
                sets.join(", "),
                cond,
                tail
            )
        }
        "delete" => {
            if keys.is_empty() {
                return Err(AppError::bad("delete requires a row key"));
            }
            format!("DELETE FROM {} WHERE {}{}", target, cond, tail)
        }
        other => return Err(AppError::bad(format!("unknown row action '{}'", other))),
    };

    let result = conn.run_one(sql).await;
    if let Some(err) = result.error {
        return Err(AppError::bad(err));
    }
    Ok(json!({
        "ok": true,
        "action": action,
        "rows_affected": result.row_count,
        "last_insert_id": result.last_insert_id,
    }))
}
