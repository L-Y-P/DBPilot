//! Export and import.
//!
//! Ports the web `routes/export.rs`. The web version streamed an HTTP
//! `Response` with a `Content-Disposition` header; a desktop app has no HTTP,
//! so these return `{ filename, content_type, content }` and the Dart layer
//! writes the file wherever the user chose in the save dialog.

use std::io::Write;

use serde::Deserialize;
use serde_json::{json, Value};

use super::{parse, state};
use crate::drivers::{literal, qi, qualify};
use crate::error::AppError;
use crate::exporters::{export_meta, ExportResult, ExportStream, Sink};

/// Preview mode caps the rendered document at this many bytes.
///
/// The UI only shows a preview; rendering a whole million-row table just to
/// throw most of it away was the other half of the export memory problem.
const MAX_PREVIEW_BYTES: usize = 256 * 1024;

/// SQL previews stop after this many data rows (structure is always complete).
const PREVIEW_SQL_ROWS: u64 = 200;

/// Table DDL: the driver native statement when available, otherwise a
/// CREATE TABLE synthesised from the normalized structure.
pub(crate) async fn ddl_for(
    driver: &dyn crate::core::driver::DatabaseDriver,
    conn: &crate::core::connection::ConnectionHandle,
    ns: &str,
    table: &str,
) -> anyhow::Result<String> {
    if let Some(ddl) = driver.table_ddl(conn, ns, table).await? {
        return Ok(ddl);
    }
    let structure = driver.table_structure(conn, ns, table).await?;
    let columns = structure
        .get("columns")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let primary_key = structure
        .get("primary_key")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let mut defs: Vec<String> = Vec::new();
    for c in &columns {
        let name = c.get("name").and_then(|v| v.as_str()).unwrap_or_default();
        let type_name = c.get("type_name").and_then(|v| v.as_str()).unwrap_or_default();
        if name.is_empty() || type_name.is_empty() {
            continue;
        }
        let mut def = format!("{} {}", qi(driver.kind(), name), type_name);
        if c.get("IS_NULLABLE").and_then(|v| v.as_str()) != Some("YES") {
            def.push_str(" NOT NULL");
        }
        if let Some(default) = c.get("COLUMN_DEFAULT").and_then(|v| v.as_str()) {
            if !default.is_empty() {
                def.push_str(&format!(" DEFAULT {}", default));
            }
        }
        defs.push(def);
    }
    if !primary_key.is_empty() {
        let names: Vec<String> = primary_key
            .iter()
            .filter_map(|v| v.as_str())
            .map(|s| qi(driver.kind(), s))
            .collect();
        if !names.is_empty() {
            defs.push(format!("PRIMARY KEY ({})", names.join(", ")));
        }
    }
    Ok(format!(
        "CREATE TABLE {} (\n  {}\n)",
        qualify(driver.kind(), ns, table),
        defs.join(",\n  ")
    ))
}




/// SQL dump of one table (structure and/or data).
pub(crate) async fn table_sql(
    driver: &dyn crate::core::driver::DatabaseDriver,
    conn: &crate::core::connection::ConnectionHandle,
    ns: &str,
    table: &str,
    with_structure: bool,
    with_data: bool,
    with_drop: bool,
) -> anyhow::Result<String> {
    let mut out = String::new();
    if with_structure {
        out.push_str(&format!("--\n-- Table structure for table {}\n--\n\n", table));
        if with_drop {
            out.push_str(&format!("DROP TABLE IF EXISTS {};\n", qualify(driver.kind(), ns, table)));
        }
        out.push_str(&format!("{};\n\n", ddl_for(driver, conn, ns, table).await?));
    }
    if with_data {
        out.push_str(&format!("--\n-- Dumping data for table {}\n--\n\n", table));
        let result = conn
            .run_one(format!("SELECT * FROM {}", qualify(driver.kind(), ns, table)))
            .await;
        if let Some(err) = result.error {
            return Err(AppError::bad(err).into());
        }
        if !result.rows.is_empty() {
            let cols: Vec<String> = result
                .columns
                .iter()
                .map(|c| qi(driver.kind(), &c.name))
                .collect();
            out.push_str(&format!(
                "INSERT INTO {} ({}) VALUES\n",
                qualify(driver.kind(), ns, table),
                cols.join(", ")
            ));
            let tuples: Vec<String> = result
                .rows
                .iter()
                .map(|row| {
                    let values: Vec<String> = row.iter().map(|v| literal(driver.kind(), v)).collect();
                    format!("({})", values.join(", "))
                })
                .collect();
            out.push_str(&tuples.join(",\n"));
            out.push_str(";\n\n");
        }
    }
    Ok(out)
}

#[derive(Deserialize)]
struct ExportQuery {
    #[serde(default)]
    format: Option<String>,
    #[serde(default)]
    structure: Option<bool>,
    #[serde(default)]
    data: Option<bool>,
    #[serde(default)]
    drop: Option<bool>,
    /// When set, the export is streamed straight to this absolute path instead
    /// of being returned as a String. The desktop save dialog picks the path
    /// first, then Rust writes it row by row (P1: 1M-row export used ~1 GB RSS).
    #[serde(default)]
    path: Option<String>,
}

fn payload(filename: String, content_type: &str, content: String) -> Value {
    json!({
        "filename": filename,
        "content_type": content_type,
        "content": content,
    })
}

/// Write a SQL dump of one table, streaming the row data into `writer`.
///
/// Data rows are emitted as multi-row INSERT statements in batches of 500, so
/// the process never holds more than one batch in memory. `max_data_rows` = 0
/// means "every row" (file export); a positive value stops the scan early and
/// reports truncation (preview).
async fn table_sql_stream<W: Write + Send>(
    driver: &dyn crate::core::driver::DatabaseDriver,
    conn: &crate::core::connection::ConnectionHandle,
    ns: &str,
    table: &str,
    with_structure: bool,
    with_data: bool,
    with_drop: bool,
    writer: &mut W,
    max_data_rows: u64,
) -> anyhow::Result<(u64, bool)> {
    if with_structure {
        writeln!(writer, "--\n-- Table structure for table {table}\n--\n")?;
        if with_drop {
            writeln!(
                writer,
                "DROP TABLE IF EXISTS {};",
                qualify(driver.kind(), ns, table)
            )?;
        }
        writeln!(writer, "{};\n", ddl_for(driver, conn, ns, table).await?)?;
    }
    if !with_data {
        return Ok((0, false));
    }
    writeln!(writer, "--\n-- Dumping data for table {table}\n--\n")?;
    let select = format!("SELECT * FROM {}", qualify(driver.kind(), ns, table));
    let mut rows: u64 = 0;
    let mut batch: u64 = 0;
    let mut io_error: Option<std::io::Error> = None;
    let mut truncated = false;
    const BATCH: u64 = 500;
    let stats = conn
        .scan_rows(&select, |columns, row| {
            let outcome: std::io::Result<()> = (|| {
                if batch == 0 {
                    let names: Vec<String> = columns
                        .iter()
                        .map(|c| qi(driver.kind(), &c.name))
                        .collect();
                    write!(
                        writer,
                        "INSERT INTO {} ({}) VALUES\n",
                        qualify(driver.kind(), ns, table),
                        names.join(", ")
                    )?;
                } else {
                    write!(writer, ",\n")?;
                }
                let values: Vec<String> =
                    row.iter().map(|v| literal(driver.kind(), v)).collect();
                write!(writer, "({})", values.join(", "))
            })();
            if let Err(e) = outcome {
                io_error = Some(e);
                return false;
            }
            rows += 1;
            batch += 1;
            if batch >= BATCH {
                if let Err(e) = writeln!(writer, ";") {
                    io_error = Some(e);
                    return false;
                }
                batch = 0;
            }
            if max_data_rows > 0 && rows >= max_data_rows {
                truncated = true;
                return false;
            }
            true
        })
        .await?;
    if let Some(e) = io_error {
        return Err(e.into());
    }
    if batch > 0 {
        writeln!(writer, ";")?;
    }
    writeln!(writer)?;
    // The scan stops early only for a preview cap; a real export consumes all
    // rows, so stopped_early implies the dump was cut off.
    let _ = stats;
    Ok((rows, truncated))
}

/// Stream a table's rows through one of the exchange-format renderers.
///
/// The renderer is created lazily on the first row (that is when the column
/// metadata becomes known), so an empty table still produces a valid empty
/// document. Returns the render result plus whether the output was truncated.
async fn table_rows_stream(
    driver: &dyn crate::core::driver::DatabaseDriver,
    conn: &crate::core::connection::ConnectionHandle,
    ns: &str,
    table: &str,
    format: &str,
    max_bytes: Option<usize>,
    sink: Sink,
) -> anyhow::Result<(ExportResult, bool)> {
    let select = format!("SELECT * FROM {}", qualify(driver.kind(), ns, table));
    let mut sink = Some(sink);
    let mut stream: Option<ExportStream> = None;
    let mut io_error: Option<std::io::Error> = None;
    let mut format_error: Option<String> = None;
    let stats = conn
        .scan_rows(&select, |columns, row| {
            if stream.is_none() {
                let pending = sink.take().expect("sink is consumed once");
                match ExportStream::new(format, table, columns, pending, max_bytes) {
                    Ok(Some(created)) => stream = Some(created),
                    Ok(None) => {
                        format_error = Some(format!("不支持的导出格式 {format}"));
                        return false;
                    }
                    Err(e) => {
                        io_error = Some(e);
                        return false;
                    }
                }
            }
            match stream.as_mut().expect("created above").write_row(row) {
                Ok(true) => true,
                Ok(false) => false,
                Err(e) => {
                    io_error = Some(e);
                    false
                }
            }
        })
        .await?;
    if let Some(e) = io_error {
        return Err(e.into());
    }
    if let Some(message) = format_error {
        return Err(AppError::bad(message).into());
    }
    let finished = match stream {
        Some(created) => created.finish()?,
        None => {
            // No row meant the lazy renderer was never created: emit an empty
            // document so the file is still well-formed for its format.
            let pending = sink.take().expect("sink is consumed once");
            match ExportStream::new(format, table, &[], pending, max_bytes) {
                Ok(Some(empty)) => empty.finish()?,
                Ok(None) => {
                    return Err(AppError::bad(format!("不支持的导出格式 {format}")).into())
                }
                Err(e) => return Err(e.into()),
            }
        }
    };
    Ok((finished, stats.stopped_early))
}

/// Export one table in any supported format.
///
/// Two modes:
///  * `params.path` set → stream the document straight into that file and
///    return `{written: true, rows, bytes...}` (large-table export).
///  * no path → render a bounded preview into the response (the SQL console's
///    export preview and the table page preview both use this).
pub async fn export_table(database: String, table: String, params: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let query: ExportQuery = parse("params", params)?;
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(Some(&database)).await?;
    let format = query.format.unwrap_or_else(|| "sql".to_string()).to_lowercase();
    let with_structure = query.structure.unwrap_or(true);
    let with_data = query.data.unwrap_or(true);
    let with_drop = query.drop.unwrap_or(false);
    let (content_type, filename) = export_meta(&format, &table)
        .ok_or_else(|| AppError::bad(format!("不支持的导出格式 {format}")))?;
    let path = query
        .path
        .as_deref()
        .map(str::trim)
        .filter(|p| !p.is_empty());

    if let Some(path) = path {
        if !std::path::Path::new(path).is_absolute() {
            return Err(AppError::bad("导出路径必须是绝对路径").into());
        }
        let file = std::fs::File::create(path).map_err(|e| {
            AppError::BadRequest(format!("无法创建导出文件 {path}：{e}"))
        })?;
        let mut writer = std::io::BufWriter::new(file);
        let rows = if format == "sql" {
            let (rows, _) = table_sql_stream(
                driver.as_ref(),
                &conn,
                &database,
                &table,
                with_structure,
                with_data,
                with_drop,
                &mut writer,
                0,
            )
            .await?;
            writer.flush()?;
            rows
        } else {
            let (result, _) = table_rows_stream(
                driver.as_ref(),
                &conn,
                &database,
                &table,
                &format,
                None,
                Sink::File(Box::new(writer)),
            )
            .await?;
            result.rows
        };
        return Ok(json!({
            "filename": filename,
            "content_type": content_type,
            "content": "",
            "written": true,
            "rows": rows,
            "path": path,
        }));
    }

    let (content, truncated, rows) = if format == "sql" {
        let mut buffer: Vec<u8> = Vec::new();
        let (rows, truncated) = table_sql_stream(
            driver.as_ref(),
            &conn,
            &database,
            &table,
            with_structure,
            with_data,
            with_drop,
            &mut buffer,
            PREVIEW_SQL_ROWS,
        )
        .await?;
        (String::from_utf8_lossy(&buffer).into_owned(), truncated, rows)
    } else {
        let (result, truncated) = table_rows_stream(
            driver.as_ref(),
            &conn,
            &database,
            &table,
            &format,
            Some(MAX_PREVIEW_BYTES),
            Sink::Memory(Vec::new()),
        )
        .await?;
        (result.content.unwrap_or_default(), truncated, result.rows)
    };
    Ok(json!({
        "filename": filename,
        "content_type": content_type,
        "content": content,
        "truncated": truncated,
        "rows": rows,
    }))
}

/// SQL dump of every base table in a database.
pub async fn export_database(database: String) -> anyhow::Result<Value> {
    let state = state()?;
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(Some(&database)).await?;
    let mut out = format!(
        "-- DBPilot SQL dump\n-- Driver: {}\n-- Database: {}\n\n",
        driver.label(),
        database
    );
    let tables = driver.list_tables(&conn, &database).await?;
    for t in &tables {
        if t.get("type").and_then(|v| v.as_str()) != Some("BASE TABLE") {
            continue;
        }
        let name = t.get("name").and_then(|v| v.as_str()).unwrap_or_default();
        if name.is_empty() {
            continue;
        }
        out.push_str(&table_sql(driver.as_ref(), &conn, &database, name, true, true, true).await?);
    }
    Ok(payload(
        format!("{}.sql", database),
        "application/sql; charset=utf-8",
        out,
    ))
}

/// Upper bound for one import. The web build buffered the whole request body
/// with no limit, so a multi-GB script was a trivial out-of-memory. 64 MiB is
/// far beyond a normal SQL dump while still bounded.
const MAX_IMPORT_BYTES: usize = 64 * 1024 * 1024;

/// Run a SQL script supplied as raw text.
pub async fn import_sql(database: String, sql: String) -> anyhow::Result<Value> {
    let state = state()?;
    if sql.trim().is_empty() {
        return Err(AppError::bad("导入内容为空").into());
    }
    if sql.len() > MAX_IMPORT_BYTES {
        return Err(AppError::bad(format!(
            "导入内容过大（{} 字节，上限 {} 字节）",
            sql.len(),
            MAX_IMPORT_BYTES
        )).into());
    }
    let mut current_database = database;
    let mut conn = state.connection_for(Some(&current_database)).await?;
    let mut results: Vec<crate::db::ResultSet> = Vec::new();
    let mut last_use: Option<String> = None;
    // P4：按方言切分（与 SQL 控制台同一条路径）。
    let splitter = state.driver_for_active().await?;
    for statement in crate::db::split_statements_for(splitter.dialect(), &sql) {
        // USE is treated as a validated database switch (see run_query); raw
        // USE must not reach a pooled connection or it could bypass the
        // connection's only_db / hide_db visibility rules.
        if let Some(target) = super::use_statement_target(&statement) {
            match super::switch_database_for_use(&state, &target).await {
                Ok(()) => match state.connection_for(Some(&target)).await {
                    Ok(updated) => {
                        conn = updated;
                        last_use = Some(target.clone());
                        current_database = target.clone();
                        results.push(super::session_result(
                            &statement,
                            &format!("已切换到数据库：{}", target),
                        ));
                    }
                    Err(e) => {
                        results.push(super::session_error_result(&statement, &e.to_string()));
                        break;
                    }
                },
                Err(e) => {
                    results.push(super::session_error_result(&statement, &e.to_string()));
                    break;
                }
            }
            continue;
        }
        results.push(conn.run_one(statement).await);
    }
    let statements = results.len();
    let failed = results.iter().filter(|r| r.error.is_some()).count();
    let errors: Vec<Value> = results
        .iter()
        .filter_map(|r| {
            r.error
                .as_ref()
                .map(|e| json!({ "statement": r.statement, "error": e }))
        })
        .collect();
    Ok(json!({
        "statements": statements,
        "succeeded": statements.saturating_sub(failed),
        "failed": failed,
        "errors": errors,
        "results": results,
        "database": current_database,
        "use_database": last_use,
    }))
}


/// Export the rows of an arbitrary SELECT (the query builder's result).
///
/// The builder's generated SELECT may span several databases, so it is run as
/// one statement against [database] and its rows are streamed through the same
/// exchange-format renderers the table page uses (SQL / CSV / JSON / XML / HTML
/// / TXT / Excel / Markdown). This keeps the builder's export identical to the
/// table page's export instead of maintaining a second, weaker CSV writer.
///
/// Like [export_table] there are two modes:
///  * `params.path` set → stream straight into that file (no big String crosses
///    the FFI boundary);
///  * no path → render a bounded preview into the response.
pub async fn export_query(database: String, sql: String, params: Value) -> anyhow::Result<Value> {
    let state = state()?;
    let query: ExportQuery = parse("params", params)?;
    let statement = sql.trim();
    if statement.is_empty() {
        return Err(AppError::bad("导出语句不能为空").into());
    }
    let driver = state.driver_for_active().await?;
    let conn = state.connection_for(Some(&database)).await?;
    let format = query.format.unwrap_or_else(|| "csv".to_string()).to_lowercase();
    // The SQL format dumps table structure, which a free SELECT has none of.
    if format == "sql" {
        return Err(AppError::bad(
            "查询结果不支持 SQL 导出：SQL 格式需要表结构，请在表页导出",
        )
        .into());
    }
    let (content_type, filename) = export_meta(&format, "query_result")
        .ok_or_else(|| AppError::bad(format!("不支持的导出格式 {format}")))?;
    let path = query
        .path
        .as_deref()
        .map(str::trim)
        .filter(|p| !p.is_empty());

    if let Some(path) = path {
        if !std::path::Path::new(path).is_absolute() {
            return Err(AppError::bad("导出路径必须是绝对路径").into());
        }
        let file = std::fs::File::create(path).map_err(|e| {
            AppError::BadRequest(format!("无法创建导出文件 {path}：{e}"))
        })?;
        let writer = std::io::BufWriter::new(file);
        let (result, _) = query_rows_stream(driver.as_ref(), &conn, statement, &format, None, Sink::File(Box::new(writer)))
            .await?;
        return Ok(json!({
            "filename": filename,
            "content_type": content_type,
            "content": "",
            "written": true,
            "rows": result.rows,
            "bytes": result.bytes,
            "path": path,
        }));
    }

    let (result, truncated) = query_rows_stream(
        driver.as_ref(),
        &conn,
        statement,
        &format,
        Some(MAX_PREVIEW_BYTES),
        Sink::Memory(Vec::new()),
    )
    .await?;
    Ok(json!({
        "filename": filename,
        "content_type": content_type,
        "content": result.content.unwrap_or_default(),
        "truncated": truncated,
        "rows": result.rows,
    }))
}

/// Stream an arbitrary SELECT through one of the exchange-format renderers.
///
/// Mirrors [table_rows_stream] but takes the statement instead of building a
/// `SELECT * FROM table`, so the builder can export a JOIN / aggregate result.
async fn query_rows_stream(
    _driver: &dyn crate::core::driver::DatabaseDriver,
    conn: &crate::core::connection::ConnectionHandle,
    statement: &str,
    format: &str,
    max_bytes: Option<usize>,
    sink: Sink,
) -> anyhow::Result<(ExportResult, bool)> {
    let mut sink = Some(sink);
    let mut stream: Option<ExportStream> = None;
    let mut io_error: Option<std::io::Error> = None;
    let mut format_error: Option<String> = None;
    let stats = conn
        .scan_rows(statement, |columns, row| {
            if stream.is_none() {
                let pending = sink.take().expect("sink is consumed once");
                match ExportStream::new(format, "query_result", columns, pending, max_bytes) {
                    Ok(Some(created)) => stream = Some(created),
                    Ok(None) => {
                        format_error = Some(format!("不支持的导出格式 {format}"));
                        return false;
                    }
                    Err(e) => {
                        io_error = Some(e);
                        return false;
                    }
                }
            }
            match stream.as_mut().expect("created above").write_row(row) {
                Ok(true) => true,
                Ok(false) => false,
                Err(e) => {
                    io_error = Some(e);
                    false
                }
            }
        })
        .await?;
    if let Some(e) = io_error {
        return Err(e.into());
    }
    if let Some(message) = format_error {
        return Err(AppError::bad(message).into());
    }
    let finished = match stream {
        Some(created) => created.finish()?,
        None => {
            let pending = sink.take().expect("sink is consumed once");
            match ExportStream::new(format, "query_result", &[], pending, max_bytes) {
                Ok(Some(empty)) => empty.finish()?,
                Ok(None) => {
                    return Err(AppError::bad(format!("不支持的导出格式 {format}")).into())
                }
                Err(e) => return Err(e.into()),
            }
        }
    };
    Ok((finished, stats.stopped_early))
}

/// Supported export formats, for the UI dropdown.
#[flutter_rust_bridge::frb(sync)]
pub fn export_formats() -> Value {
    crate::exporters::formats()
}
