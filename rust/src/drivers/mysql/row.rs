//! MySQL 行的解码与 JSON 化（P3 Step 5 从 db.rs 迁入）。
//!
//! 只被 MySQL 驱动使用：把 `MySqlRow` 单元格转成保持 DECIMAL 精度、标注二进制
//! 数据的 JSON，并据此生成 SQL 字面量。

use base64::Engine as _;
use serde_json::{json, Value};
use sqlx::mysql::{MySqlRow, MySqlValueRef};
use sqlx::{Column, Decode, Row, TypeInfo, ValueRef};

use crate::db::{quote_str, ColumnMeta};

pub fn columns_meta(row: &MySqlRow) -> Vec<ColumnMeta> {
    row.columns()
        .iter()
        .map(|c| ColumnMeta {
            name: c.name().to_string(),
            type_name: c.type_info().name().to_string(),
        })
        .collect()
}

fn binary_json(bytes: &[u8]) -> Value {
    json!({
        "__binary__": base64::engine::general_purpose::STANDARD.encode(bytes),
        "len": bytes.len(),
    })
}

/// Decode a raw MySQL cell as T directly, bypassing sqlx's strict compatibility
/// check. This is what allows reading DECIMAL, JSON, TIMESTAMP and BINARY-flagged
/// text columns (such as information_schema metadata) instead of losing them.
fn decode<'r, T>(raw: MySqlValueRef<'r>) -> Option<T>
where
    T: Decode<'r, sqlx::MySql>,
{
    T::decode(raw).ok()
}

fn bytes_to_json(raw: MySqlValueRef<'_>) -> Value {
    match decode::<Vec<u8>>(raw) {
        Some(bytes) => binary_json(&bytes),
        None => Value::Null,
    }
}

/// True when a decoded string holds control characters, i.e. it is really binary data.
fn looks_binary(value: &str) -> bool {
    value
        .chars()
        .any(|c| (c as u32) < 0x20 && c != '\t' && c != '\n' && c != '\r')
}

/// Convert one MySQL cell to JSON, keeping DECIMAL precise and marking binary data.
pub fn value_to_json(row: &MySqlRow, idx: usize) -> Value {
    let raw = match row.try_get_raw(idx) {
        Ok(raw) => raw,
        Err(_) => return Value::Null,
    };
    if raw.is_null() {
        return Value::Null;
    }
    let tname = row.column(idx).type_info().name().to_uppercase();

    if tname.contains("INT") || matches!(tname.as_str(), "YEAR" | "BIT" | "BOOLEAN" | "SERIAL") {
        if tname == "BOOLEAN" {
            if let Some(v) = decode::<bool>(raw.clone()) {
                return json!(v);
            }
        }
        if tname.contains("UNSIGNED") || tname == "BIT" {
            if let Some(v) = decode::<u64>(raw.clone()) {
                return json!(v);
            }
        }
        if let Some(v) = decode::<i64>(raw.clone()) {
            return json!(v);
        }
        if let Some(v) = decode::<u64>(raw.clone()) {
            return json!(v);
        }
        return bytes_to_json(raw);
    }

    if tname == "FLOAT" || tname == "DOUBLE" {
        if let Some(v) = decode::<f64>(raw.clone()) {
            return json!(v);
        }
        return bytes_to_json(raw);
    }

    if tname == "DECIMAL" || tname == "NEWDECIMAL" {
        if let Some(v) = decode::<String>(raw.clone()) {
            return json!(v);
        }
        return bytes_to_json(raw);
    }

    if tname == "DATE" {
        if let Some(v) = decode::<chrono::NaiveDate>(raw.clone()) {
            return json!(v.to_string());
        }
        return bytes_to_json(raw);
    }

    if tname == "DATETIME" || tname == "TIMESTAMP" {
        if let Some(v) = decode::<chrono::NaiveDateTime>(raw.clone()) {
            return json!(v.format("%Y-%m-%d %H:%M:%S%.f").to_string());
        }
        return bytes_to_json(raw);
    }

    if tname == "TIME" {
        if let Some(v) = decode::<chrono::NaiveTime>(raw.clone()) {
            return json!(v.to_string());
        }
        if let Some(v) = decode::<chrono::TimeDelta>(raw.clone()) {
            let total = v.num_seconds();
            let sign = if total < 0 { "-" } else { "" };
            let abs = total.abs();
            return json!(format!("{}{:02}:{:02}:{:02}", sign, abs / 3600, (abs % 3600) / 60, abs % 60));
        }
        return bytes_to_json(raw);
    }

    if tname == "JSON" {
        if let Some(v) = decode::<String>(raw.clone()) {
            return json!(v);
        }
        return bytes_to_json(raw);
    }

    // Everything else (VARCHAR, CHAR, TEXT, ENUM, SET, BLOB, BINARY, ...):
    // prefer readable UTF-8, otherwise return base64-marked bytes.
    if let Some(v) = decode::<String>(raw.clone()) {
        if !looks_binary(&v) {
            return json!(v);
        }
    }
    bytes_to_json(raw)
}

pub fn row_values(row: &MySqlRow) -> Vec<Value> {
    (0..row.len()).map(|i| value_to_json(row, i)).collect()
}

/// Serialize rows as objects keyed by column name (for metadata queries).
pub fn rows_to_named(rows: &[MySqlRow]) -> Vec<Value> {
    rows.iter()
        .map(|r| {
            let mut map = serde_json::Map::new();
            for i in 0..r.len() {
                map.insert(r.column(i).name().to_string(), value_to_json(r, i));
            }
            Value::Object(map)
        })
        .collect()
}

/// Read a text column without sqlx's strict compatibility check. Some
/// information_schema text columns are flagged BINARY, which makes try_get reject them.
pub fn cell_string(row: &MySqlRow, idx: usize) -> Option<String> {
    let raw = row.try_get_raw(idx).ok()?;
    if raw.is_null() {
        return None;
    }
    decode::<String>(raw)
}

/// Produce a SQL literal for a cell, using X'..' for binary data.
pub fn sql_literal(row: &MySqlRow, idx: usize) -> String {
    match value_to_json(row, idx) {
        Value::Null => "NULL".to_string(),
        Value::Bool(b) => {
            if b {
                "1".to_string()
            } else {
                "0".to_string()
            }
        }
        Value::Number(n) => n.to_string(),
        Value::String(s) => quote_str(&s),
        Value::Object(o) => match o.get("__binary__").and_then(|v| v.as_str()) {
            Some(b64) => {
                // A malformed payload must not silently become an empty blob,
                // which would corrupt data on a round-trip. Emit NULL and a
                // comment so the failure is visible in the generated SQL.
                match base64::engine::general_purpose::STANDARD.decode(b64) {
                    Ok(bytes) => format!("X'{}'", hex::encode(bytes)),
                    Err(_) => "NULL /* invalid binary payload */".to_string(),
                }
            }
            None => quote_str(&Value::Object(o).to_string()),
        },
        other => quote_str(&other.to_string()),
    }
}
