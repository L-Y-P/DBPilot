use futures::StreamExt;
use serde_json::{json, Value};

use sqlx::postgres::{PgPool, PgValueRef};
use sqlx::{Column, Decode, Row, TypeInfo, ValueRef};

pub mod account;
pub mod dialect;
pub mod driver;

use crate::core::connection::ConnectionHandle;
use crate::core::dialect::DatabaseDialect;
use crate::db::{ColumnMeta, ResultBatch, ResultSet, ScanStats};
use crate::drivers::{
    bytes_json, column_json, qi, qualify, quote_str_for, safe_ident, CreateTableSpec, DriverKind,
};
use crate::error::{AppError, AppResult};

fn dec<'r, T>(raw: PgValueRef<'r>) -> Option<T>
where
    T: Decode<'r, sqlx::Postgres>,
{
    T::decode(raw).ok()
}

/// Decode a PostgreSQL NUMERIC/ DECIMAL binary value into its exact decimal string.
fn numeric_to_string(bytes: &[u8]) -> Option<String> {
    if bytes.len() < 8 {
        return None;
    }
    let ndigits = i16::from_be_bytes([bytes[0], bytes[1]]) as usize;
    let weight = i16::from_be_bytes([bytes[2], bytes[3]]);
    let sign = u16::from_be_bytes([bytes[4], bytes[5]]);
    let dscale = i16::from_be_bytes([bytes[6], bytes[7]]);
    if sign == 0xC000 {
        return Some("NaN".to_string());
    }
    let mut digits: Vec<u32> = Vec::with_capacity(ndigits);
    for i in 0..ndigits {
        let off = 8 + i * 2;
        if off + 2 > bytes.len() {
            break;
        }
        digits.push(u16::from_be_bytes([bytes[off], bytes[off + 1]]) as u32);
    }

    let mut int_part = String::new();
    if weight < 0 {
        int_part.push('0');
    } else {
        for i in 0..=weight {
            let d = digits.get(i as usize).copied().unwrap_or(0);
            if i == 0 {
                int_part.push_str(&d.to_string());
            } else {
                int_part.push_str(&format!("{:04}", d));
            }
        }
    }

    let mut frac = String::new();
    let mut e: i16 = -1;
    while (frac.len() as i16) < dscale {
        let idx = weight - e;
        let d = if idx >= 0 {
            digits.get(idx as usize).copied().unwrap_or(0)
        } else {
            0
        };
        frac.push_str(&format!("{:04}", d));
        e -= 1;
        if e < -1000 {
            break;
        }
    }
    if dscale > 0 {
        frac.truncate(dscale as usize);
    }

    let mut out = String::new();
    if sign == 0x4000 {
        out.push('-');
    }
    out.push_str(&int_part);
    if dscale > 0 {
        out.push('.');
        out.push_str(&frac);
    }
    Some(out)
}

pub(crate) fn value_to_json(row: &sqlx::postgres::PgRow, idx: usize) -> Value {
    let raw = match row.try_get_raw(idx) {
        Ok(raw) => raw,
        Err(_) => return Value::Null,
    };
    if raw.is_null() {
        return Value::Null;
    }
    let tname = row.column(idx).type_info().name().to_uppercase();

    match tname.as_str() {
        "BOOL" => {
            if let Some(v) = dec::<bool>(raw.clone()) {
                return json!(v);
            }
        }
        "INT2" | "INT4" | "INT8" | "OID" | "XID" => {
            if let Some(v) = dec::<i64>(raw.clone()) {
                return json!(v);
            }
            if let Some(v) = dec::<i32>(raw.clone()) {
                return json!(v);
            }
        }
        "FLOAT4" => {
            if let Some(v) = dec::<f32>(raw.clone()) {
                return json!(v as f64);
            }
        }
        "FLOAT8" => {
            if let Some(v) = dec::<f64>(raw.clone()) {
                return json!(v);
            }
        }
        "NUMERIC" | "DECIMAL" | "MONEY" => {
            if let Ok(bytes) = raw.as_bytes() {
                if let Some(s) = numeric_to_string(bytes) {
                    return json!(s);
                }
            }
        }
        "DATE" => {
            if let Some(v) = dec::<chrono::NaiveDate>(raw.clone()) {
                return json!(v.to_string());
            }
        }
        "TIME" => {
            if let Some(v) = dec::<chrono::NaiveTime>(raw.clone()) {
                return json!(v.to_string());
            }
        }
        "TIMESTAMP" => {
            if let Some(v) = dec::<chrono::NaiveDateTime>(raw.clone()) {
                return json!(v.format("%Y-%m-%d %H:%M:%S%.f").to_string());
            }
        }
        "TIMESTAMPTZ" => {
            if let Some(v) = dec::<chrono::DateTime<chrono::Utc>>(raw.clone()) {
                return json!(v.format("%Y-%m-%d %H:%M:%S%.f%:z").to_string());
            }
        }
        "JSON" | "JSONB" => {
            if let Some(v) = dec::<sqlx::types::Json<Value>>(raw.clone()) {
                return v.0;
            }
            if let Some(v) = dec::<String>(raw.clone()) {
                return json!(v);
            }
        }
        "UUID" => {
            if let Some(v) = dec::<uuid::Uuid>(raw.clone()) {
                return json!(v.to_string());
            }
        }
        "BYTEA" => {
            if let Some(v) = dec::<Vec<u8>>(raw.clone()) {
                return bytes_json(&v);
            }
        }
        "INTERVAL" => {
            if let Some(v) = dec::<sqlx::postgres::types::PgInterval>(raw.clone()) {
                let secs = v.microseconds as f64 / 1_000_000.0;
                return json!(format!("{} mons {} days {}s", v.months, v.days, secs));
            }
        }
        _ => {}
    }

    if let Some(v) = dec::<String>(raw.clone()) {
        return json!(v);
    }
    if let Some(v) = dec::<Vec<u8>>(raw.clone()) {
        return bytes_json(&v);
    }
    Value::Null
}

pub async fn run_one(pool: &PgPool, stmt: String) -> ResultSet {
    let conn = match pool.acquire().await {
        Ok(conn) => conn,
        Err(e) => return error_set(stmt, e),
    };
    run_one_owned(conn, stmt).await.0
}

/// Execute one statement on an owned connection and hand it back.
///
/// Taking the connection by value (instead of `&mut PgConnection`) keeps the
/// future `Send` without a higher-ranked `Executor` obligation; see
/// `drivers::mysql::exec::run_one_limited_owned` for the full explanation.
pub async fn run_one_owned(
    mut conn: sqlx::pool::PoolConnection<sqlx::Postgres>,
    stmt: String,
) -> (ResultSet, sqlx::pool::PoolConnection<sqlx::Postgres>) {
    let wants_rows = crate::db::returns_rows(&stmt);
    let make = |columns: Vec<ColumnMeta>, rows: Vec<Vec<Value>>, affected: u64| ResultSet {
        columns,
        rows,
        row_count: affected,
        last_insert_id: 0,
        statement: stmt.clone(),
        kind: "rows".to_string(),
        error: None,
        truncated: false,
    };

    if wants_rows {
        let result = match sqlx::query(stmt.as_str()).fetch_all(&mut *conn).await {
            Ok(rows) => {
                let columns = rows
                    .first()
                    .map(|row| crate::drivers::columns_meta(row))
                    .unwrap_or_default();
                let values: Vec<Vec<Value>> = rows
                    .iter()
                    .map(|r| (0..r.len()).map(|i| value_to_json(r, i)).collect())
                    .collect();
                let mut rs = make(columns, values, 0);
                rs.row_count = rs.rows.len() as u64;
                rs
            }
            Err(e) => error_set(stmt, e),
        };
        (result, conn)
    } else {
        let result = match sqlx::query(stmt.as_str()).execute(&mut *conn).await {
            Ok(r) => {
                let mut rs = make(Vec::new(), Vec::new(), r.rows_affected());
                rs.kind = "affected".to_string();
                rs
            }
            Err(e) => error_set(stmt, e),
        };
        (result, conn)
    }
}

/// Streaming counterpart of [run_one_owned] with a hard row cap.
///
/// Returns the result, whether the stream was abandoned (the caller must close
/// the connection instead of reusing it), and the connection.
pub async fn run_one_limited(
    pool: &PgPool,
    stmt: String,
    max_rows: usize,
) -> ResultSet {
    if !crate::db::returns_rows(&stmt) {
        return run_one(pool, stmt).await;
    }
    let conn = match pool.acquire().await {
        Ok(conn) => conn,
        Err(e) => return error_set(stmt, e),
    };
    let (result, truncated, conn) = run_one_limited_owned(conn, stmt, max_rows).await;
    if truncated {
        let _ = conn.close().await;
    }
    result
}

pub async fn run_one_limited_owned(
    mut conn: sqlx::pool::PoolConnection<sqlx::Postgres>,
    stmt: String,
    max_rows: usize,
) -> (ResultSet, bool, sqlx::pool::PoolConnection<sqlx::Postgres>) {
    if !crate::db::returns_rows(&stmt) {
        let (result, conn) = run_one_owned(conn, stmt).await;
        return (result, false, conn);
    }
    let mut rows: Vec<sqlx::postgres::PgRow> = Vec::new();
    let mut truncated = false;
    let mut failure: Option<sqlx::Error> = None;
    {
        let mut stream = sqlx::query(stmt.as_str()).fetch(&mut *conn);
        loop {
            match stream.next().await {
                Some(Ok(row)) => {
                    if rows.len() >= max_rows {
                        truncated = true;
                        break;
                    }
                    rows.push(row);
                }
                Some(Err(e)) => {
                    failure = Some(e);
                    break;
                }
                None => break,
            }
        }
    }
    if let Some(e) = failure {
        return (error_set(stmt, e), false, conn);
    }
    let columns = rows
        .first()
        .map(|row| crate::drivers::columns_meta(row))
        .unwrap_or_default();
    let values: Vec<Vec<Value>> = rows
        .iter()
        .map(|r| (0..r.len()).map(|i| value_to_json(r, i)).collect())
        .collect();
    let result = ResultSet {
        columns,
        row_count: values.len() as u64,
        rows: values,
        last_insert_id: 0,
        statement: stmt,
        kind: "rows".to_string(),
        error: None,
        truncated,
    };
    (result, truncated, conn)
}

/// Streaming variant of [run_one_limited_owned] (optimisation layer 3).
///
/// Same contract as the MySQL implementation in
/// `drivers/mysql/exec.rs::run_one_limited_batched_owned`, which is the
/// reference for the docs below:
///
/// * rows are decoded with [value_to_json] and handed to `on_batch` as soon as
///   `batch_size` of them have been read, so a large SQL-console result never
///   materialises as a whole;
/// * a statement that does not return rows reuses [run_one_limited_owned]
///   verbatim (one `affected` batch);
/// * reading stops at `max_rows`, `truncated` is set and the caller closes the
///   connection (never drain/decode the rest);
/// * `on_batch` returning `false` stops the scan immediately; the caller closes
///   the connection, which also cancels the server-side query.
///
/// The returned [ResultSet] carries metadata only (`rows` is empty — the rows
/// travelled through the callback). The connection is moved in and returned for
/// the same rustc/`Send` reason documented on [run_one_limited_owned].
pub async fn run_one_limited_batched_owned(
    conn: sqlx::pool::PoolConnection<sqlx::Postgres>,
    stmt: String,
    max_rows: usize,
    batch_size: usize,
    on_batch: &mut (dyn FnMut(ResultBatch) -> bool + Send),
) -> (
    ResultSet,
    bool,
    bool,
    sqlx::pool::PoolConnection<sqlx::Postgres>,
) {
    if !crate::db::returns_rows(&stmt) {
        let (result, truncated, conn) = run_one_limited_owned(conn, stmt, max_rows).await;
        return (result, truncated, false, conn);
    }
    let mut conn = conn;
    let batch_size = batch_size.max(1);
    let mut columns: Vec<ColumnMeta> = Vec::new();
    let mut buffered: Vec<Vec<Value>> = Vec::with_capacity(batch_size.min(max_rows.max(1)));
    let mut row_count: usize = 0;
    let mut truncated = false;
    let mut stopped = false;
    let mut failure: Option<sqlx::Error> = None;
    {
        let mut stream = sqlx::query(stmt.as_str()).fetch(&mut *conn);
        loop {
            match stream.next().await {
                Some(Ok(row)) => {
                    if row_count >= max_rows {
                        truncated = true;
                        break;
                    }
                    if columns.is_empty() {
                        columns = crate::drivers::columns_meta(&row);
                    }
                    buffered.push((0..row.len()).map(|i| value_to_json(&row, i)).collect());
                    row_count += 1;
                    if buffered.len() >= batch_size {
                        let batch = ResultBatch {
                            columns: columns.clone(),
                            rows: std::mem::take(&mut buffered),
                            truncated: false,
                        };
                        if !on_batch(batch) {
                            stopped = true;
                            break;
                        }
                    }
                }
                Some(Err(e)) => {
                    failure = Some(e);
                    break;
                }
                None => break,
            }
        }
    }
    if let Some(e) = failure {
        return (error_set(stmt, e), false, false, conn);
    }
    if !stopped {
        if !buffered.is_empty() {
            let batch = ResultBatch {
                columns: columns.clone(),
                rows: std::mem::take(&mut buffered),
                truncated,
            };
            if !on_batch(batch) {
                stopped = true;
            }
        } else if truncated {
            // The cap was reached exactly on a batch boundary: emit a trailing
            // empty batch so the consumer still observes `truncated`.
            let batch = ResultBatch {
                columns: columns.clone(),
                rows: Vec::new(),
                truncated: true,
            };
            if !on_batch(batch) {
                stopped = true;
            }
        }
    }
    let result = ResultSet {
        columns,
        rows: Vec::new(),
        row_count: row_count as u64,
        last_insert_id: 0,
        statement: stmt,
        kind: "rows".to_string(),
        error: None,
        truncated,
    };
    (result, truncated, stopped, conn)
}

/// Execute `statements` inside **one transaction**, one affected result each.
///
/// Transaction control goes through sqlx's transaction manager; the first
/// failing statement rolls the whole batch back. PostgreSQL supports `BEGIN`
/// over the extended protocol too, but going through the same helper as MySQL /
/// SQLite keeps the batched row-edit path driver-agnostic.
///
/// The failing statement's 1-based index is part of the error message.
pub async fn run_transaction(
    pool: &PgPool,
    statements: Vec<String>,
) -> AppResult<Vec<ResultSet>> {
    let mut tx = pool
        .begin()
        .await
        .map_err(|e| AppError::bad(crate::error::database_message(&e)))?;
    let mut results = Vec::with_capacity(statements.len());
    for (index, stmt) in statements.into_iter().enumerate() {
        match sqlx::query(stmt.as_str()).execute(&mut *tx).await {
            Ok(result) => results.push(ResultSet {
                columns: Vec::new(),
                rows: Vec::new(),
                row_count: result.rows_affected(),
                last_insert_id: 0,
                statement: stmt,
                kind: "affected".to_string(),
                error: None,
                truncated: false,
            }),
            Err(e) => {
                let _ = tx.rollback().await;
                return Err(AppError::bad(format!(
                    "第 {} 条改动失败，整批已回滚：{}",
                    index + 1,
                    crate::error::database_message(&e)
                )));
            }
        }
    }
    tx.commit().await.map_err(|e| {
        AppError::bad(format!(
            "提交事务失败：{}",
            crate::error::database_message(&e)
        ))
    })?;
    Ok(results)
}

fn error_set(stmt: String, e: sqlx::Error) -> ResultSet {
    ResultSet {
        columns: Vec::new(),
        rows: Vec::new(),
        row_count: 0,
        last_insert_id: 0,
        statement: stmt,
        kind: "error".to_string(),
        // Same normalisation as AppError: one sentence, no duplicate
        // "Caused by:" tail, permission codes explained.
        error: Some(crate::error::database_message(&e)),
        truncated: false,
    }
}

/// Stream a row-returning statement to a callback (export path).
///
/// See the MySQL implementation in `drivers/mysql/exec.rs`: returning `false` from the
/// callback stops the scan and closes the connection so the server does not
/// keep scanning rows the user will never see.
pub async fn scan_rows<'a>(
    pool: &PgPool,
    stmt: String,
    mut on_row: Box<crate::core::connection::RowFn<'a>>,
) -> AppResult<ScanStats> {
    let mut conn = pool
        .acquire()
        .await
        .map_err(|e| AppError::bad(crate::error::database_message(&e)))?;
    let mut stats = ScanStats::default();
    let mut failure: Option<sqlx::Error> = None;
    let mut stopped = false;
    {
        let mut stream = sqlx::query(stmt.as_str()).fetch(&mut *conn);
        while let Some(item) = stream.next().await {
            match item {
                Ok(row) => {
                    if stats.columns.is_empty() {
                        stats.columns = crate::drivers::columns_meta(&row);
                    }
                    let values: Vec<Value> =
                        (0..row.len()).map(|i| value_to_json(&row, i)).collect();
                    stats.rows += 1;
                    if !on_row(&stats.columns, &values) {
                        stopped = true;
                        break;
                    }
                }
                Err(e) => {
                    failure = Some(e);
                    break;
                }
            }
        }
    }
    if let Some(e) = failure {
        return Err(AppError::bad(crate::error::database_message(&e)));
    }
    stats.stopped_early = stopped;
    if stopped {
        let _ = conn.close().await;
    }
    Ok(stats)
}

pub async fn version(pool: &PgPool) -> AppResult<String> {
    let row = sqlx::query("SELECT version()").fetch_one(pool).await?;
    Ok(row.try_get::<String, _>(0).unwrap_or_default())
}

/// Schemas of the current database that the account may actually use.
///
/// `information_schema.schemata` is not a permission check: PostgreSQL lists a
/// schema there as soon as the role has *any* privilege on it, including
/// `CREATE` without `USAGE`, and it also exposes `pg_temp_N`. Such a schema is
/// then offered in the sidebar / pickers and every click fails with
/// "permission denied for schema". Filtering on `has_schema_privilege(...,
/// 'USAGE')` matches what the server will actually let the role query.
///
/// `information_schema` is always readable metadata and is kept. Temporary
/// schemas are never browsable (their objects are session-scoped), so they are
/// excluded like `pg_catalog` / `pg_toast`.
pub async fn namespaces(conn: &ConnectionHandle) -> AppResult<Vec<Value>> {
    // SQL 文本由方言拥有（drivers/postgres/dialect.rs）。
    conn.fetch_named(dialect::POSTGRES_DIALECT.list_schemas_sql().sql)
        .await
}

/// Every schema in the database, ignoring the account's own privileges.
///
/// Used by the grant editor, which must offer schemas the connecting account
/// does not itself have `USAGE` on.
pub async fn all_namespaces(conn: &ConnectionHandle) -> AppResult<Vec<Value>> {
    conn.fetch_named(
        "SELECT schema_name AS \"name\", NULL AS \"charset\", NULL AS \"collation\" FROM information_schema.schemata WHERE schema_name NOT IN ('pg_catalog', 'information_schema', 'pg_toast') ORDER BY schema_name".to_string(),
    )
    .await
}

/// Physical databases of the instance that the account may actually open.
///
/// `pg_database` lists every database on the server, including ones the role
/// has no `CONNECT` privilege on. Offering those produced the same class of bug
/// as MySQL's `performance_schema`: the tree showed a database whose every
/// click failed (PostgreSQL: "permission denied for database"). They are
/// filtered out here, so the sidebar and every picker only offer browsable
/// databases; `can_connect` is still reported for callers that want it.
pub async fn databases(conn: &ConnectionHandle) -> AppResult<Vec<Value>> {
    conn.fetch_named(dialect::POSTGRES_DIALECT.list_databases_sql().sql)
        .await
}

/// Every physical database, ignoring the account's own privileges.
///
/// Kept for callers that must *name* a database the connecting account cannot
/// open (administrative fallbacks); the browser uses [`databases`].
pub async fn all_databases(conn: &ConnectionHandle) -> AppResult<Vec<Value>> {
    conn.fetch_named(
        "SELECT datname AS \"name\", pg_encoding_to_char(encoding) AS \"charset\", datcollate AS \"collation\", pg_get_userbyid(datdba) AS \"owner\", datallowconn AS \"allow_conn\", has_database_privilege(datname, 'CONNECT') AS \"can_connect\" FROM pg_database WHERE NOT datistemplate ORDER BY datname".to_string(),
    )
    .await
}


/// INSERT one row inside a transaction, read it back and always roll back
/// (import probe / "试插入" step).
pub async fn probe_insert(pool: &PgPool, insert: &str, select: &str) -> AppResult<Value> {
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
            let mut map = serde_json::Map::new();
            for i in 0..row.len() {
                let name = row.column(i).name().to_string();
                map.insert(name, value_to_json(&row, i));
            }
            Value::Object(map)
        }
        _ => Value::Null,
    };
    let _ = tx.rollback().await;
    Ok(json!({ "affected": affected, "row": row }))
}

pub async fn tables(conn: &ConnectionHandle, ns: &str) -> AppResult<Vec<Value>> {
    conn.fetch_named(dialect::POSTGRES_DIALECT.list_tables_sql(ns).sql)
        .await
}

pub async fn object_kind(conn: &ConnectionHandle, ns: &str, table: &str) -> AppResult<Option<String>> {
    let rows = conn
        .fetch_named(dialect::POSTGRES_DIALECT.table_kind_sql(ns, table).sql)
        .await?;
    Ok(rows.first().and_then(|r| r.get("kind")).and_then(|v| v.as_str()).map(|s| s.to_string()))
}

pub async fn structure(conn: &ConnectionHandle, ns: &str, table: &str) -> AppResult<Value> {
    let info_rows = conn
        .fetch_named(format!(
            "SELECT t.table_type AS \"TABLE_TYPE\", NULL AS \"ENGINE\", COALESCE(s.n_live_tup, 0) AS \"TABLE_ROWS\", pg_total_relation_size(c.oid) AS \"DATA_LENGTH\", 0 AS \"INDEX_LENGTH\", NULL AS \"TABLE_COLLATION\", COALESCE(obj_description(c.oid, 'pg_class'), '') AS \"TABLE_COMMENT\", NULL AS \"CREATE_TIME\", NULL AS \"UPDATE_TIME\", NULL AS \"AUTO_INCREMENT\", COALESCE(ts.spcname, (SELECT spcname FROM pg_tablespace WHERE oid = (SELECT dattablespace FROM pg_database WHERE datname = current_database()))) AS \"TABLESPACE\", CASE WHEN c.relpersistence = 'u' THEN 'YES' ELSE 'NO' END AS \"UNLOGGED\" FROM information_schema.tables t JOIN pg_class c ON c.relname = t.table_name JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = t.table_schema LEFT JOIN pg_tablespace ts ON ts.oid = c.reltablespace LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid WHERE t.table_schema = {} AND t.table_name = {}",
            quote_str_for(conn.driver_kind(), ns),
            quote_str_for(conn.driver_kind(), table)
        ))
        .await?;
    let info = info_rows
        .into_iter()
        .next()
        .ok_or_else(|| AppError::not_found(format!("table '{}' does not exist", table)))?;

    // Primary key from the catalogues, not from information_schema (P2-04):
    // see `primary_key_sql`.
    let pk_rows = conn.fetch_named(primary_key_sql(ns, table)).await?;
    let primary_key: Vec<Value> = pk_rows.iter().filter_map(|r| r.get("COLUMN_NAME").cloned()).collect();
    let pk_names: Vec<String> = primary_key
        .iter()
        .filter_map(|v| v.as_str().map(|s| s.to_string()))
        .collect();

    let raw_columns = conn
        .fetch_named(dialect::POSTGRES_DIALECT.list_columns_sql(ns, table).sql)
        .await?;

    let mut columns = Vec::new();
    for c in raw_columns {
        let get = |k: &str| c.get(k).cloned().unwrap_or(Value::Null);
        let s = |k: &str| get(k).as_str().unwrap_or_default().to_string();
        let name = s("COLUMN_NAME");
        let key = if pk_names.contains(&name) { "PRI" } else { "" };
        // Identity columns (GENERATED … AS IDENTITY) have no column_default;
        // they are identified by is_identity. Missing this made structure sync
        // recreate the column as a plain integer and silently drop the identity.
        let is_identity = s("IS_IDENTITY") == "YES";
        let extra = if is_identity
            || get("COLUMN_DEFAULT")
                .as_str()
                .map(|d| d.contains("nextval("))
                .unwrap_or(false)
        {
            "auto_increment"
        } else {
            ""
        };
        columns.push(column_json(
            &name,
            &s("DATA_TYPE"),
            &s("COLUMN_TYPE"),
            &s("IS_NULLABLE"),
            get("COLUMN_DEFAULT"),
            key,
            extra,
            // PostgreSQL stores column comments outside the table definition;
            // without this the structure tab and structure sync both thought
            // every column had no comment.
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
            "SELECT i.relname AS \"INDEX_NAME\", CASE WHEN ix.indisunique THEN 0 ELSE 1 END AS \"NON_UNIQUE\", ix.indisprimary AS \"IS_PRIMARY\", a.attname AS \"COLUMN_NAME\", k.ord AS \"SEQ_IN_INDEX\", NULL AS \"CARDINALITY\", am.amname AS \"INDEX_TYPE\" FROM pg_index ix JOIN pg_class i ON i.oid = ix.indexrelid JOIN pg_class t ON t.oid = ix.indrelid JOIN pg_namespace n ON n.oid = t.relnamespace JOIN pg_am am ON am.oid = i.relam JOIN LATERAL unnest(ix.indkey) WITH ORDINALITY AS k(attnum, ord) ON true JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum WHERE n.nspname = {} AND t.relname = {} ORDER BY i.relname, k.ord",
            quote_str_for(conn.driver_kind(), ns),
            quote_str_for(conn.driver_kind(), table)
        ))
        .await?;

    let fk_rows = conn
        .fetch_named(format!(
            "SELECT tc.constraint_name AS \"CONSTRAINT_NAME\", kcu.column_name AS \"COLUMN_NAME\", ccu.table_name AS \"REFERENCED_TABLE_NAME\", ccu.column_name AS \"REFERENCED_COLUMN_NAME\", rc.delete_rule AS \"DELETE_RULE\", rc.update_rule AS \"UPDATE_RULE\" FROM information_schema.table_constraints tc JOIN information_schema.key_column_usage kcu ON kcu.constraint_name = tc.constraint_name AND kcu.table_schema = tc.table_schema JOIN information_schema.constraint_column_usage ccu ON ccu.constraint_name = tc.constraint_name AND ccu.table_schema = tc.table_schema JOIN information_schema.referential_constraints rc ON rc.constraint_name = tc.constraint_name AND rc.constraint_schema = tc.table_schema WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_schema = {} AND tc.table_name = {} ORDER BY tc.constraint_name",
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
        "foreign_keys": fk_rows,
    }))
}

pub async fn overview(conn: &ConnectionHandle) -> AppResult<Value> {
    let version = conn.fetch_string("SELECT version()".to_string()).await.unwrap_or_default();
    let uptime = conn
        .fetch_i64("SELECT EXTRACT(EPOCH FROM (now() - pg_postmaster_start_time()))::bigint".to_string())
        .await
        .unwrap_or(0);
    let threads_connected = conn.fetch_i64("SELECT count(*) FROM pg_stat_activity".to_string()).await.unwrap_or(0);
    let threads_running = conn
        .fetch_i64("SELECT count(*) FROM pg_stat_activity WHERE state = 'active'".to_string())
        .await
        .unwrap_or(0);
    let queries = conn
        .fetch_i64("SELECT COALESCE(sum(xact_commit + xact_rollback), 0)::bigint FROM pg_stat_database".to_string())
        .await
        .unwrap_or(0);
    let connections = conn
        .fetch_i64("SELECT COALESCE(sum(numbackends), 0)::bigint FROM pg_stat_database".to_string())
        .await
        .unwrap_or(0);
    let database_count = conn
        .fetch_i64("SELECT count(*) FROM pg_database WHERE NOT datistemplate".to_string())
        .await
        .unwrap_or(0);
    let table_count = conn
        .fetch_i64("SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog', 'information_schema')".to_string())
        .await
        .unwrap_or(0);

    let settings = conn
        .fetch_named("SELECT name AS \"Variable_name\", setting AS \"Value\" FROM pg_settings ORDER BY name".to_string())
        .await
        .unwrap_or_default();
    let mut map = serde_json::Map::new();
    for row in &settings {
        if let Some(k) = row.get("Variable_name").and_then(|v| v.as_str()) {
            map.insert(k.to_string(), row.get("Value").cloned().unwrap_or(Value::Null));
        }
    }
    let all = Value::Object(map);
    Ok(json!({
        "version": version,
        "version_comment": "PostgreSQL",
        "uptime": uptime,
        "threads_connected": threads_connected,
        "threads_running": threads_running,
        "queries": queries,
        "questions": queries,
        "slow_queries": Value::Null,
        "connections": connections,
        "bytes_received": Value::Null,
        "bytes_sent": Value::Null,
        "aborted_connects": Value::Null,
        "database_count": database_count,
        "table_count": table_count,
        "status": all,
    }))
}

pub async fn variables(conn: &ConnectionHandle, filter: Option<&str>) -> AppResult<Vec<Value>> {
    let mut rows = conn
        .fetch_named("SELECT name AS \"Variable_name\", setting AS \"Value\" FROM pg_settings ORDER BY name".to_string())
        .await?;
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
    match dialect::POSTGRES_DIALECT.list_processes_sql() {
        Some(query) => conn.fetch_named(query.sql).await,
        None => Ok(Vec::new()),
    }
}

pub async fn users(conn: &ConnectionHandle) -> AppResult<Vec<Value>> {
    Ok(conn
        .fetch_named(
            "SELECT rolname AS \"user\", 'local' AS \"host\", CASE WHEN rolsuper THEN 'superuser' WHEN rolcanlogin THEN 'login' ELSE 'group' END AS \"plugin\", CASE WHEN rolcanlogin THEN 'N' ELSE 'Y' END AS \"account_locked\" FROM pg_roles ORDER BY rolname".to_string(),
        )
        .await?
        .into_iter()
        .collect())
}

pub async fn builder_schema(conn: &ConnectionHandle, ns: &str) -> AppResult<Value> {
    let columns = conn
        .fetch_named(format!(
            "SELECT c.table_name AS \"TABLE_NAME\", c.column_name AS \"COLUMN_NAME\", c.data_type AS \"data_type\", c.is_nullable AS \"IS_NULLABLE\", CASE WHEN pk.column_name IS NULL THEN '' ELSE 'PRI' END AS \"COLUMN_KEY\" FROM information_schema.columns c LEFT JOIN (SELECT kcu.table_schema, kcu.table_name, kcu.column_name FROM information_schema.table_constraints tc JOIN information_schema.key_column_usage kcu ON kcu.constraint_name = tc.constraint_name AND kcu.table_schema = tc.table_schema AND kcu.table_name = tc.table_name WHERE tc.constraint_type = 'PRIMARY KEY') pk ON pk.table_schema = c.table_schema AND pk.table_name = c.table_name AND pk.column_name = c.column_name WHERE c.table_schema = {} ORDER BY c.table_name, c.ordinal_position",
            quote_str_for(conn.driver_kind(), ns)
        ))
        .await?;
    let fks = conn
        .fetch_named(format!(
            "SELECT kcu.table_name AS \"TABLE_NAME\", kcu.column_name AS \"COLUMN_NAME\", ccu.table_name AS \"REFERENCED_TABLE_NAME\", ccu.column_name AS \"REFERENCED_COLUMN_NAME\" FROM information_schema.table_constraints tc JOIN information_schema.key_column_usage kcu ON kcu.constraint_name = tc.constraint_name AND kcu.table_schema = tc.table_schema JOIN information_schema.constraint_column_usage ccu ON ccu.constraint_name = tc.constraint_name AND ccu.table_schema = tc.table_schema WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_schema = {}",
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
            "key": row.get("COLUMN_KEY").and_then(|v| v.as_str()).unwrap_or_default(),
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

pub async fn table_ddl(_conn: &ConnectionHandle, _ns: &str, _table: &str) -> AppResult<Option<String>> {
    Ok(None)
}

pub fn create_table_sql(ns: &str, spec: &CreateTableSpec) -> AppResult<String> {
    let mut defs: Vec<String> = Vec::new();
    let mut primary: Vec<String> = Vec::new();
    for column in &spec.columns {
        let name = column.name.trim();
        let mut def = format!("{} {}", qi(DriverKind::Postgres, name), column.col_type.trim());
        if let Some(collation) = column.collation.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            def.push_str(&format!(" COLLATE {}", qi(DriverKind::Postgres, collation)));
        }
        if column.auto_increment {
            def.push_str(" GENERATED BY DEFAULT AS IDENTITY");
        } else if let Some(value) = column.default.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            def.push_str(&format!(" DEFAULT {}", crate::drivers::safe_default(value)?));
        }
        if !column.nullable {
            def.push_str(" NOT NULL");
        }
        if column.primary {
            primary.push(qi(DriverKind::Postgres, name));
        }
        defs.push(def);
    }
    if !primary.is_empty() {
        defs.push(format!("PRIMARY KEY ({})", primary.join(", ")));
    }
    for fk in &spec.foreign_keys {
        defs.push(crate::drivers::fk_constraint_sql(DriverKind::Postgres, &spec.name, fk)?);
    }
    let _ = safe_ident;
    let mut sql = format!(
        "CREATE {}{} {} (\n  {}\n)",
        if spec.unlogged == Some(true) { "UNLOGGED " } else { "" },
        "TABLE",
        qualify(DriverKind::Postgres, ns, &spec.name),
        defs.join(",\n  ")
    );
    if let Some(ts) = spec.tablespace.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        sql.push_str(&format!(" TABLESPACE {}", qi(DriverKind::Postgres, ts)));
    }
    Ok(sql)
}

pub fn alter_table_statements(
    ns: &str,
    table: &str,
    spec: &crate::drivers::AlterTableSpec,
) -> AppResult<Vec<String>> {
    let d = DriverKind::Postgres;
    let target = qualify(d, ns, table);
    let mut out: Vec<String> = Vec::new();
    for c in &spec.add_columns {
        let col = qi(d, c.name.trim());
        let mut s = format!("ALTER TABLE {} ADD COLUMN {} {}", target, col, c.col_type.trim());
        if let Some(collation) = c.collation.as_deref().map(str::trim).filter(|v| !v.is_empty()) {
            s.push_str(&format!(" COLLATE {}", qi(d, collation)));
        }
        if let Some(value) = c.default.as_deref().map(str::trim).filter(|v| !v.is_empty()) {
            s.push_str(&format!(" DEFAULT {}", crate::drivers::safe_default(value)?));
        }
        if !c.nullable {
            s.push_str(" NOT NULL");
        }
        if c.auto_increment {
            s.push_str(" GENERATED BY DEFAULT AS IDENTITY");
        }
        out.push(s);
        if let Some(comment) = c.comment.as_deref().filter(|v| !v.is_empty()) {
            out.push(format!("COMMENT ON COLUMN {}.{} IS {}", target, col, quote_str_for(d, comment)));
        }
    }
    for c in &spec.modify_columns {
        let col = qi(d, c.name.trim());
        if !c.col_type.trim().is_empty() {
            match c.collation.as_deref().map(str::trim).filter(|v| !v.is_empty()) {
                Some(collation) => out.push(format!(
                    "ALTER TABLE {} ALTER COLUMN {} TYPE {} COLLATE {}",
                    target,
                    col,
                    c.col_type.trim(),
                    qi(d, collation)
                )),
                None => out.push(format!("ALTER TABLE {} ALTER COLUMN {} TYPE {}", target, col, c.col_type.trim())),
            }
        }
        out.push(format!(
            "ALTER TABLE {} ALTER COLUMN {} {}",
            target,
            col,
            if c.nullable { "DROP NOT NULL" } else { "SET NOT NULL" }
        ));
        match c.default.as_deref().map(str::trim).filter(|v| !v.is_empty()) {
            Some(value) => out.push(format!(
                "ALTER TABLE {} ALTER COLUMN {} SET DEFAULT {}",
                target,
                col,
                crate::drivers::safe_default(value)?
            )),
            None => out.push(format!("ALTER TABLE {} ALTER COLUMN {} DROP DEFAULT", target, col)),
        }
        if let Some(comment) = c.comment.as_deref().filter(|v| !v.is_empty()) {
            out.push(format!("COMMENT ON COLUMN {}.{} IS {}", target, col, quote_str_for(d, comment)));
        }
    }
    for name in &spec.drop_columns {
        out.push(format!("ALTER TABLE {} DROP COLUMN {}", target, qi(d, name)));
    }
    for r in &spec.rename_columns {
        out.push(format!(
            "ALTER TABLE {} RENAME COLUMN {} TO {}",
            target,
            qi(d, &r.from),
            qi(d, &r.to)
        ));
    }
    if let Some(cols) = &spec.set_primary_key {
        if !cols.is_empty() {
            let names: Vec<String> = cols.iter().map(|c| qi(d, c)).collect();
            out.push(format!("ALTER TABLE {} ADD PRIMARY KEY ({})", target, names.join(", ")));
        }
    }
    // Drop before add: a replaced index keeps its name, and the other order
    // would create the new definition and then drop it again.
    for name in &spec.drop_indexes {
        out.push(format!("DROP INDEX {}", qi(d, name)));
    }
    for idx in &spec.add_indexes {
        if idx.name.trim().is_empty() || idx.columns.is_empty() {
            continue;
        }
        let cols: Vec<String> = idx.columns.iter().map(|c| qi(d, c)).collect();
        out.push(format!(
            "CREATE {}INDEX {} ON {} ({})",
            if idx.unique { "UNIQUE " } else { "" },
            qi(d, idx.name.trim()),
            target,
            cols.join(", ")
        ));
    }
    for fk in &spec.add_foreign_keys {
        out.push(format!("ALTER TABLE {} ADD {}", target, crate::drivers::fk_constraint_sql(d, table, fk)?));
    }
    for name in &spec.drop_foreign_keys {
        out.push(format!("ALTER TABLE {} DROP CONSTRAINT {}", target, qi(d, name)));
    }
    if let Some(unlogged) = spec.unlogged {
        out.push(format!(
            "ALTER TABLE {} SET {}",
            target,
            if unlogged { "UNLOGGED" } else { "LOGGED" }
        ));
    }
    if let Some(ts) = spec.tablespace.as_deref().map(str::trim).filter(|v| !v.is_empty()) {
        out.push(format!("ALTER TABLE {} SET TABLESPACE {}", target, qi(d, ts)));
    }
    if let Some(comment) = &spec.comment {
        out.push(format!("COMMENT ON TABLE {} IS {}", target, quote_str_for(d, comment)));
    }
    if let Some(new_name) = spec.rename_to.as_deref().map(str::trim).filter(|v| !v.is_empty()) {
        out.push(format!("ALTER TABLE {} RENAME TO {}", target, qi(d, new_name)));
    }
    Ok(out)
}

pub async fn meta_options(conn: &ConnectionHandle) -> AppResult<Value> {
    let charsets = conn
        .fetch_named(
            "SELECT DISTINCT pg_encoding_to_char(encoding) AS \"charset\", '' AS \"default_collation\", 0 AS \"maxlen\", 'PostgreSQL 服务端编码' AS \"description\" FROM pg_database ORDER BY 1".to_string(),
        )
        .await
        .unwrap_or_default();
    let collations = conn
        .fetch_named(
            "SELECT collname AS \"collation\", '' AS \"charset\", CASE WHEN collname = 'default' THEN 'Yes' ELSE '' END AS \"is_default\" FROM pg_collation ORDER BY collname".to_string(),
        )
        .await
        .unwrap_or_default();
    let default_charset = conn
        .fetch_string("SHOW server_encoding".to_string())
        .await
        .unwrap_or_else(|_| "UTF8".to_string());
    let default_collation = conn
        .fetch_string("SELECT datcollate FROM pg_database WHERE datname = current_database()".to_string())
        .await
        .unwrap_or_default();
    let tablespaces = conn
        .fetch_named(
            "SELECT spcname AS \"tablespace\", CASE WHEN spcname = 'pg_default' THEN 'Yes' ELSE '' END AS \"is_default\" FROM pg_tablespace ORDER BY spcname".to_string(),
        )
        .await
        .unwrap_or_default();
    let engines: Vec<Value> = Vec::new();
    let row_formats: Vec<Value> = Vec::new();
    Ok(json!({
        "charsets": charsets,
        "collations": collations,
        "engines": engines,
        "row_formats": row_formats,
        "tablespaces": tablespaces,
        "default_charset": default_charset,
        "default_collation": default_collation,
        "features": {
            "charset": false,
            "table_charset": false,
            "collation": true,
            "engine": false,
            "row_format": false,
            "auto_increment": true,
            "comment": true,
            "unlogged": true,
            "tablespace": true,
            "without_rowid": false,
            "strict": false,
        },
    }))
}

/// Whether one catalogue row may be listed for the current role.
///
/// `is_owner` is `pg_has_role(owner, 'USAGE')` (the owner, or a member of the
/// owning role); `has_explicit_grant` is the privilege check that ignores the
/// grant PostgreSQL makes to PUBLIC by default.
pub fn pg_object_visible(is_owner: bool, has_explicit_grant: bool) -> bool {
    is_owner || has_explicit_grant
}

/// Keep the rows whose `visible` flag is true, and count the rest.
///
/// A missing flag counts as hidden: the privilege decision must fail closed, so
/// a query that stops computing it cannot silently turn into a metadata leak.
pub fn split_visible_rows(rows: Vec<Value>) -> (Vec<Value>, usize) {
    let mut visible = Vec::with_capacity(rows.len());
    let mut hidden = 0usize;
    for row in rows {
        if row.get("visible").and_then(Value::as_bool).unwrap_or(false) {
            visible.push(row);
        } else {
            hidden += 1;
        }
    }
    (visible, hidden)
}

/// Catalogue query behind the object panel's routine list.
///
/// `visible` is computed in SQL so the privilege rule lives in one place, is
/// asserted by the unit tests through [`pg_object_visible`], and lets the caller
/// count what it hid without a second query.
pub fn routine_list_sql(ns: &str) -> String {
    format!(
        "SELECT p.proname AS \"name\", CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END AS \"kind\", CASE p.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END AS \"type\", pg_get_function_result(p.oid) AS \"returns\", pg_get_userbyid(p.proowner) AS \"definer\", CASE p.prosecdef WHEN true THEN 'DEFINER' ELSE 'INVOKER' END AS \"security\", (pg_has_role(p.proowner, 'USAGE') OR (p.proacl IS NOT NULL AND has_function_privilege(p.oid, 'EXECUTE'))) AS \"visible\" FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = {} AND p.prokind IN ('f','p') ORDER BY p.prokind, p.proname",
        quote_str_for(DriverKind::Postgres, ns)
    )
}

/// Catalogue query behind the object panel's trigger list.
///
/// A trigger is only as visible as the table it fires on: the predicate matches
/// the table tree (owner, or any table privilege).
pub fn trigger_list_sql(ns: &str) -> String {
    format!(
        "SELECT t.tgname AS \"name\", 'trigger' AS \"kind\", 'TRIGGER' AS \"type\", c.relname AS \"tbl\", CASE WHEN t.tgtype::int & 2 = 2 THEN 'BEFORE' WHEN t.tgtype::int & 64 = 64 THEN 'INSTEAD' ELSE 'AFTER' END AS \"timing\", pg_get_triggerdef(t.oid) AS \"definition\", (pg_has_role(c.relowner, 'USAGE') OR has_table_privilege(c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')) AS \"visible\" FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = {} AND NOT t.tgisinternal ORDER BY t.tgname",
        quote_str_for(DriverKind::Postgres, ns)
    )
}

/// Primary-key columns of one table, straight from the catalogues.
///
/// `information_schema.table_constraints` / `key_column_usage` only describe
/// constraints to a role that owns the table or holds a privilege *other than*
/// SELECT, so a SELECT-only role saw no primary key and row edits degraded to
/// whole-row matching (round34 P2-04). pg_index and pg_attribute are readable by
/// every account.
pub fn primary_key_sql(ns: &str, table: &str) -> String {
    format!(
        "SELECT a.attname AS \"COLUMN_NAME\" FROM pg_index ix JOIN pg_class t ON t.oid = ix.indrelid JOIN pg_namespace n ON n.oid = t.relnamespace JOIN LATERAL unnest(ix.indkey) WITH ORDINALITY AS k(attnum, ord) ON true JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum WHERE ix.indisprimary AND n.nspname = {} AND t.relname = {} ORDER BY k.ord",
        quote_str_for(DriverKind::Postgres, ns),
        quote_str_for(DriverKind::Postgres, table)
    )
}

/// Views / routines / triggers / events of a namespace.
///
/// Views come from `information_schema.views`, which PostgreSQL already limits
/// to what the role may touch. `pg_proc` and `pg_trigger` are plain catalogues
/// every account can read, so without the privilege predicate below the object
/// panel listed the routines and triggers of tables the role cannot even open
/// (round34 P2-03: a SELECT-only role saw 9 functions and 15 triggers of a
/// schema where it could read exactly one table).
pub async fn objects(conn: &ConnectionHandle, ns: &str) -> AppResult<Value> {
    let lit = quote_str_for(conn.driver_kind(), ns);
    let views = conn
        .fetch_named(format!(
            "SELECT v.table_name AS \"name\", 'view' AS \"kind\", 'VIEW' AS \"type\", v.check_option AS \"check_option\", v.is_updatable AS \"updatable\", pg_get_userbyid(c.relowner) AS \"definer\" FROM information_schema.views v JOIN pg_class c ON c.relname = v.table_name JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = v.table_schema WHERE v.table_schema = {} ORDER BY v.table_name",
            lit
        ))
        .await
        .unwrap_or_default();
    // A routine is listed for its owner (or a member of the owning role) and
    // for a role that was granted EXECUTE explicitly. The `proacl IS NOT NULL`
    // guard matters: PostgreSQL grants EXECUTE to PUBLIC by default, so
    // has_function_privilege() alone is true for every account and would leak
    // every function name again.
    let routine_rows = conn
        .fetch_named(routine_list_sql(ns))
        .await
        .unwrap_or_default();
    // A trigger belongs to a table, so it follows that table's visibility: the
    // same rule the table tree uses (owner, or any table privilege at all).
    let trigger_rows = conn
        .fetch_named(trigger_list_sql(ns))
        .await
        .unwrap_or_default();
    let (routines, hidden_routines) = split_visible_rows(routine_rows);
    let (triggers, hidden_triggers) = split_visible_rows(trigger_rows);
    let events: Vec<Value> = Vec::new();
    Ok(json!({
        "views": views,
        "routines": routines,
        "triggers": triggers,
        "events": events,
        // How many objects the privilege filter removed, so the panel can say
        // so instead of showing a bare 0 that looks like "none exist".
        "hidden": { "routines": hidden_routines, "triggers": hidden_triggers },
    }))
}

/// CREATE ... statement for one existing object, for the definition viewer.
pub async fn object_definition(conn: &ConnectionHandle, ns: &str, kind: &str, name: &str) -> AppResult<String> {
    let lit_ns = quote_str_for(conn.driver_kind(), ns);
    let lit_name = quote_str_for(conn.driver_kind(), name);
    let sql = match kind {
        "view" => format!(
            "SELECT 'CREATE OR REPLACE VIEW ' || {} || ' AS ' || pg_get_viewdef(c.oid) AS ddl FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = {} AND c.relname = {} AND c.relkind = 'v'",
            quote_str_for(conn.driver_kind(), &qualify(conn.driver_kind(), ns, name)),
            lit_ns,
            lit_name
        ),
        "function" | "procedure" => format!(
            "SELECT pg_get_functiondef(p.oid) AS ddl FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = {} AND p.proname = {} LIMIT 1",
            lit_ns, lit_name
        ),
        "trigger" => format!(
            "SELECT pg_get_triggerdef(t.oid) AS ddl FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = {} AND t.tgname = {} AND NOT t.tgisinternal",
            lit_ns, lit_name
        ),
        other => return Err(AppError::bad(format!("未知对象类型 '{}'", other))),
    };
    let rows = conn.fetch_named(sql).await?;
    rows.first()
        .and_then(|r| r.get("ddl"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| AppError::not_found(format!("对象 '{}' 不存在", name)))
}

/// DROP statement for one object (identifier-quoted and kind-checked).
pub fn object_drop_sql(ns: &str, kind: &str, name: &str) -> AppResult<String> {
    let d = DriverKind::Postgres;
    let target = qualify(d, ns, name);
    let head = match kind {
        "view" => "DROP VIEW",
        "procedure" => "DROP PROCEDURE",
        "function" => "DROP FUNCTION",
        "trigger" => "DROP TRIGGER",
        other => return Err(AppError::bad(format!("未知对象类型 '{}'", other))),
    };
    Ok(format!("{} {}", head, target))
}

// ------------------------------------------------------------ database accounts
//
// PostgreSQL models an account as a *role*: its capabilities come from role
// attributes (LOGIN / SUPERUSER / CREATEDB / …) plus membership in other roles.
// That is exactly what the graphical editor edits. Object-level GRANTs live in
// the ACL of each object and are deliberately left to the SQL console.

pub fn account_model() -> Value {
    json!({
        "supported": true,
        "model": "postgres",
        "host_required": false,
        "attributes": ["LOGIN", "SUPERUSER", "CREATEDB", "CREATEROLE", "REPLICATION", "BYPASSRLS"],
        "note": "PostgreSQL 以「角色属性 + 角色成员」表示账号；对象级授权（GRANT … ON TABLE …）请使用 SQL 控制台。",
    })
}

pub async fn user_grants(conn: &ConnectionHandle, user: &str, host: &str) -> AppResult<Value> {
    let _ = host;
    let rows = conn
        .fetch_named(format!(
            "SELECT rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolconnlimit, rolvaliduntil::text AS valid_until FROM pg_roles WHERE rolname = {}",
            quote_str_for(conn.driver_kind(), user)
        ))
        .await?;
    let row = rows.first().cloned().unwrap_or_else(|| json!({}));
    let flag = |key: &str| row.get(key).and_then(|v| v.as_bool()).unwrap_or(false);

    let memberships = conn
        .fetch_named(format!(
            "SELECT r.rolname AS name FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid JOIN pg_roles u ON u.oid = m.member WHERE u.rolname = {} ORDER BY r.rolname",
            quote_str_for(conn.driver_kind(), user)
        ))
        .await
        .unwrap_or_default();
    let roles: Vec<String> = memberships
        .iter()
        .filter_map(|r| r.get("name").and_then(|v| v.as_str()).map(|s| s.to_string()))
        .collect();

    let valid_until = row.get("valid_until").cloned().unwrap_or(Value::Null);
    let raw: Vec<String> = if rows.is_empty() {
        Vec::new()
    } else {
        vec![format!(
            "-- 角色属性：LOGIN={} SUPERUSER={} CREATEDB={} CREATEROLE={} REPLICATION={} BYPASSRLS={} CONNECTION LIMIT={} VALID UNTIL={}",
            flag("rolcanlogin"),
            flag("rolsuper"),
            flag("rolcreatedb"),
            flag("rolcreaterole"),
            flag("rolreplication"),
            flag("rolbypassrls"),
            row.get("rolconnlimit").and_then(|v| v.as_i64()).unwrap_or(-1),
            valid_until.as_str().unwrap_or("infinity"),
        )]
    };

    Ok(json!({
        "supported": true,
        "model": "postgres",
        "attributes": {
            "login": flag("rolcanlogin"),
            "superuser": flag("rolsuper"),
            "createdb": flag("rolcreatedb"),
            "createrole": flag("rolcreaterole"),
            "replication": flag("rolreplication"),
            "bypassrls": flag("rolbypassrls"),
            "connection_limit": row.get("rolconnlimit").and_then(|v| v.as_i64()).unwrap_or(-1),
            "valid_until": valid_until,
        },
        "grants": [],
        "roles": roles,
        "other": [],
        "raw": raw,
    }))
}

/// Roles that may be granted to this account (system roles excluded).
pub async fn assignable_roles(conn: &ConnectionHandle, user: &str) -> AppResult<Vec<String>> {
    let rows = conn
        .fetch_named(format!(
            "SELECT rolname AS name FROM pg_roles WHERE rolname <> {} AND rolname NOT LIKE 'pg\\_%' ORDER BY rolname",
            quote_str_for(conn.driver_kind(), user)
        ))
        .await?;
    Ok(rows
        .iter()
        .filter_map(|r| r.get("name").and_then(|v| v.as_str()).map(|s| s.to_string()))
        .collect())
}

async fn current_memberships(conn: &ConnectionHandle, user: &str) -> AppResult<Vec<String>> {
    let rows = conn
        .fetch_named(format!(
            "SELECT r.rolname AS name FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid JOIN pg_roles u ON u.oid = m.member WHERE u.rolname = {} ORDER BY r.rolname",
            quote_str_for(conn.driver_kind(), user)
        ))
        .await?;
    Ok(rows
        .iter()
        .filter_map(|r| r.get("name").and_then(|v| v.as_str()).map(|s| s.to_string()))
        .collect())
}

fn attribute_statements(user: &str, attrs: &crate::drivers::RoleAttributes) -> Vec<String> {
    let d = DriverKind::Postgres;
    let role = qi(d, user);
    let mut out = Vec::new();
    let mut with: Vec<&str> = Vec::new();
    if let Some(v) = attrs.login {
        with.push(if v { "LOGIN" } else { "NOLOGIN" });
    }
    if let Some(v) = attrs.superuser {
        with.push(if v { "SUPERUSER" } else { "NOSUPERUSER" });
    }
    if let Some(v) = attrs.createdb {
        with.push(if v { "CREATEDB" } else { "NOCREATEDB" });
    }
    if let Some(v) = attrs.createrole {
        with.push(if v { "CREATEROLE" } else { "NOCREATEROLE" });
    }
    if let Some(v) = attrs.replication {
        with.push(if v { "REPLICATION" } else { "NOREPLICATION" });
    }
    if let Some(v) = attrs.bypassrls {
        with.push(if v { "BYPASSRLS" } else { "NOBYPASSRLS" });
    }
    if !with.is_empty() {
        out.push(format!("ALTER ROLE {} WITH {}", role, with.join(" ")));
    }
    if let Some(limit) = attrs.connection_limit {
        out.push(format!("ALTER ROLE {} CONNECTION LIMIT {}", role, limit));
    }
    if let Some(until) = attrs.valid_until.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        let literal = if until.eq_ignore_ascii_case("infinity") {
            "infinity".to_string()
        } else {
            quote_str_for(d, until)
        };
        out.push(format!("ALTER ROLE {} VALID UNTIL {}", role, literal));
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
    let d = DriverKind::Postgres;
    let mut out = vec![format!(
        "CREATE ROLE {} LOGIN PASSWORD {}",
        qi(d, user),
        quote_str_for(d, password)
    )];
    if let Some(attributes) = &change.attributes {
        out.extend(attribute_statements(user, attributes));
    }
    if let Some(roles) = &change.roles {
        for role in roles.iter().map(|r| r.trim()).filter(|r| !r.is_empty()) {
            out.push(format!("GRANT {} TO {}", qi(d, role), qi(d, user)));
        }
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

/// DROP 一个账号（纯函数；系统账号守卫只有这一份）。
pub fn drop_account_statement(user: &str, _host: &str) -> AppResult<String> {
    crate::drivers::guard_system_account(user)?;
    Ok(format!("DROP ROLE {}", qi(DriverKind::Postgres, user)))
}

pub async fn alter_account_statements(
    conn: &ConnectionHandle,
    user: &str,
    host: &str,
    change: &crate::drivers::UserChange,
) -> AppResult<Vec<String>> {
    crate::drivers::check_account_name(user, host)?;
    let d = DriverKind::Postgres;
    let role = qi(d, user);
    let mut out = Vec::new();

    if let Some(password) = change.password.as_deref().filter(|p| !p.is_empty()) {
        out.push(format!(
            "ALTER ROLE {} WITH PASSWORD {}",
            role,
            quote_str_for(d, password)
        ));
    }
    if let Some(locked) = change.account_locked {
        out.push(format!(
            "ALTER ROLE {} WITH {}",
            role,
            if locked { "NOLOGIN" } else { "LOGIN" }
        ));
    }
    if let Some(attributes) = &change.attributes {
        out.extend(attribute_statements(user, attributes));
    }
    if let Some(roles) = &change.roles {
        let current = current_memberships(conn, user).await?;
        let desired: Vec<String> = roles
            .iter()
            .map(|r| r.trim().to_string())
            .filter(|r| !r.is_empty())
            .collect();
        for role_name in &desired {
            if !current.contains(role_name) {
                out.push(format!("GRANT {} TO {}", qi(d, role_name), role));
            }
        }
        for role_name in &current {
            if !desired.contains(role_name) {
                out.push(format!("REVOKE {} FROM {}", qi(d, role_name), role));
            }
        }
    }
    // Rename last: the statements above still address the old role name.
    if let Some(new_user) = change.new_user.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        crate::drivers::guard_system_account(user)?;
        out.push(format!("ALTER ROLE {} RENAME TO {}", role, qi(d, new_user)));
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
mod object_visibility_tests {
    use super::*;

    #[test]
    fn owner_sees_its_own_objects() {
        assert!(pg_object_visible(true, false));
        assert!(pg_object_visible(true, true));
    }

    #[test]
    fn an_explicit_execute_grant_is_visible() {
        assert!(pg_object_visible(false, true));
    }

    /// PostgreSQL grants EXECUTE to PUBLIC by default, so
    /// has_function_privilege() is true for every account; the caller only
    /// reports an *explicit* grant (proacl IS NOT NULL), which keeps a plain
    /// non-owner hidden (round34 P2-03).
    #[test]
    fn public_default_grants_do_not_leak() {
        assert!(!pg_object_visible(false, false));
    }

    #[test]
    fn split_visible_rows_fails_closed() {
        let rows = vec![
            json!({ "name": "visible_one", "visible": true }),
            json!({ "name": "hidden_one", "visible": false }),
            json!({ "name": "no_flag" }),
            json!({ "name": "null_flag", "visible": Value::Null }),
            json!({ "name": "string_flag", "visible": "true" }),
        ];
        let (visible, hidden) = split_visible_rows(rows);
        assert_eq!(visible.len(), 1);
        assert_eq!(hidden, 4, "a missing/bogus flag must count as hidden");
        assert_eq!(
            visible[0].get("name").and_then(|v| v.as_str()),
            Some("visible_one")
        );
    }

    #[test]
    fn routine_sql_gates_on_owner_or_explicit_grant() {
        let sql = routine_list_sql("public");
        assert!(sql.contains("pg_has_role(p.proowner, 'USAGE')"), "{sql}");
        assert!(sql.contains("p.proacl IS NOT NULL"), "{sql}");
        assert!(sql.contains("has_function_privilege(p.oid, 'EXECUTE')"), "{sql}");
        assert!(sql.contains("'public'"), "{sql}");
    }

    #[test]
    fn trigger_sql_follows_its_table() {
        let sql = trigger_list_sql("public");
        assert!(sql.contains("pg_has_role(c.relowner, 'USAGE')"), "{sql}");
        assert!(sql.contains("has_table_privilege(c.oid,"), "{sql}");
    }

    /// P2-04: the constraint views in information_schema are invisible to a
    /// SELECT-only role, so the key has to come from the catalogues.
    #[test]
    fn primary_key_sql_uses_the_catalogues() {
        let sql = primary_key_sql("public", "actor");
        assert!(sql.contains("pg_index"), "{sql}");
        assert!(sql.contains("ix.indisprimary"), "{sql}");
        assert!(sql.contains("pg_attribute"), "{sql}");
        assert!(!sql.contains("information_schema"), "{sql}");
        assert!(sql.contains("'public'") && sql.contains("'actor'"), "{sql}");
    }
}
