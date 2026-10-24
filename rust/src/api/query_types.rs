//! Typed result-set DTOs (optimisation layer 1) and streaming console events
//! (layer 3).
//!
//! Why plain structs with a `kind` code instead of Rust enums: FRB 2.13 codegen
//! emits `@freezed` Dart sealed classes for enums with fields, and this Flutter
//! package deliberately has no freezed/build_runner dependency. A struct with a
//! numeric tag generates a normal Dart class.
//!
//! The JSON shape produced by [QueryResponseDto::to_json_value] is byte-for-byte
//! the payload the pre-optimisation `run_query` returned via `serde_json::json!`
//! (`serde_json::Value` serialisation of `ResultSet`), so the Dart side and the
//! ~20 Rust integration tests that treat the response as JSON keep working.

use base64::Engine as _;
use serde_json::{json, Value};

// ------------------------------------------------------------------- cell kinds

/// `CellValue.kind`: SQL NULL.
pub const CELL_KIND_NULL: u8 = 0;
/// `CellValue.kind`: boolean.
pub const CELL_KIND_BOOL: u8 = 1;
/// `CellValue.kind`: signed integer (fits `i64`).
pub const CELL_KIND_INT: u8 = 2;
/// `CellValue.kind`: floating point.
pub const CELL_KIND_FLOAT: u8 = 3;
/// `CellValue.kind`: UTF-8 text (VARCHAR/TEXT/DECIMAL/DATE/JSON/...).
pub const CELL_KIND_TEXT: u8 = 4;
/// `CellValue.kind`: raw bytes (the old `{"__binary__": base64, "len": N}` cell).
pub const CELL_KIND_BYTES: u8 = 5;

// ------------------------------------------------------------------ event kinds

/// [QueryEvent::kind] of a statement start event.
pub const EVENT_KIND_STARTED: u8 = 0;
/// [QueryEvent::kind] of a row-batch event.
pub const EVENT_KIND_BATCH: u8 = 1;
/// [QueryEvent::kind] of a per-statement completion event.
pub const EVENT_KIND_STATEMENT_DONE: u8 = 2;
/// [QueryEvent::kind] of the whole-run completion event.
pub const EVENT_KIND_DONE: u8 = 3;
/// [QueryEvent::kind] of a top-level failure event.
pub const EVENT_KIND_FAILED: u8 = 4;

/// One result cell on the typed boundary.
///
/// Exactly one of the payload fields is meaningful, selected by [kind]:
///
/// | kind | payload |
/// |---|---|
/// | [CELL_KIND_NULL] | none (all payloads are `None`) |
/// | [CELL_KIND_BOOL] | `bool_value` |
/// | [CELL_KIND_INT] | `int_value` |
/// | [CELL_KIND_FLOAT] | `float_value` |
/// | [CELL_KIND_TEXT] | `text_value` |
/// | [CELL_KIND_BYTES] | `bytes_value` |
#[derive(Debug, Clone, PartialEq)]
pub struct CellValue {
    /// See the `CELL_KIND_*` constants.
    pub kind: u8,
    pub bool_value: Option<bool>,
    pub int_value: Option<i64>,
    pub float_value: Option<f64>,
    pub text_value: Option<String>,
    pub bytes_value: Option<Vec<u8>>,
}

impl CellValue {
    fn empty() -> Self {
        Self {
            kind: CELL_KIND_NULL,
            bool_value: None,
            int_value: None,
            float_value: None,
            text_value: None,
            bytes_value: None,
        }
    }

    #[flutter_rust_bridge::frb(ignore)]
    pub fn null() -> Self {
        Self::empty()
    }

    #[flutter_rust_bridge::frb(ignore)]
    pub fn bool(value: bool) -> Self {
        Self {
            kind: CELL_KIND_BOOL,
            bool_value: Some(value),
            ..Self::empty()
        }
    }

    #[flutter_rust_bridge::frb(ignore)]
    pub fn int(value: i64) -> Self {
        Self {
            kind: CELL_KIND_INT,
            int_value: Some(value),
            ..Self::empty()
        }
    }

    #[flutter_rust_bridge::frb(ignore)]
    pub fn float(value: f64) -> Self {
        Self {
            kind: CELL_KIND_FLOAT,
            float_value: Some(value),
            ..Self::empty()
        }
    }

    #[flutter_rust_bridge::frb(ignore)]
    pub fn text(value: String) -> Self {
        Self {
            kind: CELL_KIND_TEXT,
            text_value: Some(value),
            ..Self::empty()
        }
    }

    #[flutter_rust_bridge::frb(ignore)]
    pub fn bytes(value: Vec<u8>) -> Self {
        Self {
            kind: CELL_KIND_BYTES,
            bytes_value: Some(value),
            ..Self::empty()
        }
    }

    /// Convert one cell of the legacy JSON result set into its typed form.
    ///
    /// The legacy cell shapes are produced by the drivers' `value_to_json`:
    /// `null`, booleans, numbers, strings and the binary marker object
    /// `{"__binary__": <base64>, "len": <n>}`. A plain object/array cell never
    /// occurs in practice; it is kept lossless-ish as JSON text for safety
    /// (this is the only value shape where the compatibility layer cannot round
    /// trip, which is why it does not appear in result sets).
    #[flutter_rust_bridge::frb(ignore)]
    pub fn from_json(value: Value) -> Self {
        match value {
            Value::Null => Self::null(),
            Value::Bool(value) => Self::bool(value),
            Value::Number(number) => {
                if let Some(value) = number.as_i64() {
                    Self::int(value)
                } else if let Some(value) = number.as_u64() {
                    // Only reachable above i64::MAX (as_i64 covers the rest).
                    // MySQL BIGINT UNSIGNED can exceed i64; text keeps every
                    // digit instead of rounding through f64.
                    Self::text(value.to_string())
                } else if let Some(value) = number.as_f64() {
                    Self::float(value)
                } else {
                    Self::text(number.to_string())
                }
            }
            Value::String(value) => Self::text(value),
            Value::Object(map) => match map.get("__binary__").and_then(Value::as_str) {
                Some(encoded) => match base64::engine::general_purpose::STANDARD.decode(encoded) {
                    Ok(bytes) => Self::bytes(bytes),
                    // A malformed binary marker is preserved as text rather than
                    // silently turning into NULL.
                    Err(_) => Self::text(Value::Object(map).to_string()),
                },
                None => Self::text(Value::Object(map).to_string()),
            },
            Value::Array(items) => Self::text(Value::Array(items).to_string()),
        }
    }

    /// Back to the legacy JSON cell shape (used by the `run_query` shim).
    ///
    /// Consumes the cell so text payloads move into the JSON tree instead of
    /// being cloned: the legacy path must not add allocations the old
    /// `json!({...})` response did not have.
    #[flutter_rust_bridge::frb(ignore)]
    pub fn into_json(self) -> Value {
        match self.kind {
            CELL_KIND_BOOL => self.bool_value.map(Value::Bool).unwrap_or(Value::Null),
            CELL_KIND_INT => self
                .int_value
                .map(|value| json!(value))
                .unwrap_or(Value::Null),
            CELL_KIND_FLOAT => self
                .float_value
                .and_then(serde_json::Number::from_f64)
                .map(Value::Number)
                .unwrap_or(Value::Null),
            CELL_KIND_TEXT => self.text_value.map(Value::String).unwrap_or(Value::Null),
            CELL_KIND_BYTES => self
                .bytes_value
                .map(|bytes| {
                    json!({
                        "__binary__": base64::engine::general_purpose::STANDARD.encode(&bytes),
                        "len": bytes.len(),
                    })
                })
                .unwrap_or(Value::Null),
            _ => Value::Null,
        }
    }
}

/// One column of a result set.
#[derive(Debug, Clone, PartialEq)]
pub struct ColumnDto {
    pub name: String,
    pub type_name: String,
}

/// One statement's result set (typed form of a driver result set).
#[derive(Debug, Clone, PartialEq)]
pub struct ResultSetDto {
    pub columns: Vec<ColumnDto>,
    pub rows: Vec<Vec<CellValue>>,
    pub row_count: i64,
    pub last_insert_id: i64,
    pub statement: String,
    /// `rows` | `affected` | `error`.
    pub kind: String,
    pub error: Option<String>,
    pub truncated: bool,
}

impl ResultSetDto {
    /// Legacy JSON shape: exactly what `serde_json` produced for a driver result set.
    ///
    /// Consuming on purpose: the compatibility response is built once and then
    /// dropped, so moving the strings into the JSON tree avoids a full extra
    /// copy of every text cell (what the old `json!(...)` path also avoided).
    #[flutter_rust_bridge::frb(ignore)]
    pub fn to_json_value(self) -> Value {
        let rows: Vec<Value> = self
            .rows
            .into_iter()
            .map(|row| Value::Array(row.into_iter().map(CellValue::into_json).collect()))
            .collect();
        let columns: Vec<Value> = self
            .columns
            .into_iter()
            .map(|column| json!({ "name": column.name, "type_name": column.type_name }))
            .collect();
        json!({
            "columns": columns,
            "rows": rows,
            "row_count": self.row_count,
            "last_insert_id": self.last_insert_id,
            "statement": self.statement,
            "kind": self.kind,
            "error": self.error,
            "truncated": self.truncated,
        })
    }
}

/// Whole-run metadata (diagnostics, tree highlighting, history).
#[derive(Debug, Clone, PartialEq)]
pub struct QuerySummaryDto {
    pub statement_count: i64,
    pub failed: i64,
    pub elapsed_ms: i64,
    pub driver: String,
    pub search_path: Option<String>,
    pub database: Option<String>,
    pub use_database: Option<String>,
    pub truncated: bool,
    pub row_limit: i64,
}

/// Typed `run_query` response: per-statement results plus the run summary.
#[derive(Debug, Clone, PartialEq)]
pub struct QueryResponseDto {
    pub results: Vec<ResultSetDto>,
    pub summary: QuerySummaryDto,
}

impl QueryResponseDto {
    /// Legacy JSON payload, identical to the pre-typed `run_query` response.
    #[flutter_rust_bridge::frb(ignore)]
    pub fn to_json_value(self) -> Value {
        let results: Vec<Value> = self
            .results
            .into_iter()
            .map(ResultSetDto::to_json_value)
            .collect();
        let summary = self.summary;
        json!({
            "results": results,
            "statement_count": summary.statement_count,
            "failed": summary.failed,
            "elapsed_ms": summary.elapsed_ms,
            "driver": summary.driver,
            "search_path": summary.search_path,
            "database": summary.database,
            "use_database": summary.use_database,
            "truncated": summary.truncated,
            "row_limit": summary.row_limit,
        })
    }
}

/// One event of the streaming console run.
///
/// Exactly one payload field is meaningful, selected by [kind]:
///
/// | kind | payload |
/// |---|---|
/// | [EVENT_KIND_STARTED] | `statement_index`, `statement` |
/// | [EVENT_KIND_BATCH] | `statement_index`, `columns` (first batch only), `rows`, `truncated` |
/// | [EVENT_KIND_STATEMENT_DONE] | `statement_index`, `result` (rows empty, meta only) |
/// | [EVENT_KIND_DONE] | `summary` |
/// | [EVENT_KIND_FAILED] | `message` |
#[derive(Debug, Clone, PartialEq)]
pub struct QueryEvent {
    /// See the `EVENT_KIND_*` constants.
    pub kind: u8,
    pub statement_index: i64,
    pub statement: Option<String>,
    pub columns: Vec<ColumnDto>,
    pub rows: Vec<Vec<CellValue>>,
    pub truncated: bool,
    pub result: Option<ResultSetDto>,
    pub summary: Option<QuerySummaryDto>,
    pub message: Option<String>,
}

impl QueryEvent {
    /// All-payload-empty event; constructors override the meaningful fields.
    fn empty() -> Self {
        Self {
            kind: EVENT_KIND_STARTED,
            statement_index: 0,
            statement: None,
            columns: Vec::new(),
            rows: Vec::new(),
            truncated: false,
            result: None,
            summary: None,
            message: None,
        }
    }

    pub(crate) fn started(statement_index: i64, statement: String) -> Self {
        Self {
            kind: EVENT_KIND_STARTED,
            statement_index,
            statement: Some(statement),
            ..Self::empty()
        }
    }

    pub(crate) fn batch(
        statement_index: i64,
        columns: Vec<ColumnDto>,
        rows: Vec<Vec<CellValue>>,
        truncated: bool,
    ) -> Self {
        Self {
            kind: EVENT_KIND_BATCH,
            statement_index,
            columns,
            rows,
            truncated,
            ..Self::empty()
        }
    }

    pub(crate) fn statement_done(statement_index: i64, result: ResultSetDto) -> Self {
        Self {
            kind: EVENT_KIND_STATEMENT_DONE,
            statement_index,
            result: Some(result),
            ..Self::empty()
        }
    }

    pub(crate) fn done(summary: QuerySummaryDto) -> Self {
        Self {
            kind: EVENT_KIND_DONE,
            summary: Some(summary),
            ..Self::empty()
        }
    }

    pub(crate) fn failed(message: String) -> Self {
        Self {
            kind: EVENT_KIND_FAILED,
            message: Some(message),
            ..Self::empty()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn binary_cell(bytes: &[u8]) -> Value {
        json!({
            "__binary__": base64::engine::general_purpose::STANDARD.encode(bytes),
            "len": bytes.len(),
        })
    }

    #[test]
    fn cell_value_covers_every_console_cell_shape() {
        assert_eq!(CellValue::from_json(Value::Null), CellValue::null());
        assert_eq!(CellValue::from_json(json!(true)), CellValue::bool(true));
        assert_eq!(CellValue::from_json(json!(-42)), CellValue::int(-42));
        assert_eq!(CellValue::from_json(json!(1.5)), CellValue::float(1.5));
        // DECIMAL / DATE / DATETIME / JSON arrive as strings: keep them verbatim.
        assert_eq!(
            CellValue::from_json(json!("12345678901234567890.1234")),
            CellValue::text("12345678901234567890.1234".to_string())
        );
        assert_eq!(
            CellValue::from_json(binary_cell(&[0, 1, 254, 255])),
            CellValue::bytes(vec![0, 1, 254, 255])
        );
        // A value above i64::MAX cannot be an Int; text keeps all digits.
        assert_eq!(
            CellValue::from_json(json!(u64::MAX)),
            CellValue::text(u64::MAX.to_string())
        );
        // i64::MAX stays an integer.
        assert_eq!(
            CellValue::from_json(json!(i64::MAX)),
            CellValue::int(i64::MAX)
        );
    }

    #[test]
    fn cell_value_round_trips_into_legacy_json() {
        for value in [
            Value::Null,
            json!(true),
            json!(false),
            json!(-7),
            json!(42),
            json!(1.25),
            json!("text"),
            json!(""),
            binary_cell(&[9, 8, 7]),
            binary_cell(&[]),
        ] {
            let cell = CellValue::from_json(value.clone());
            assert_eq!(cell.into_json(), value, "round trip failed for {value}");
        }
    }

    #[test]
    fn object_cells_degrade_to_json_text() {
        let cell = CellValue::from_json(json!({ "a": 1 }));
        assert_eq!(cell.kind, CELL_KIND_TEXT);
        assert_eq!(cell.text_value.as_deref(), Some("{\"a\":1}"));
        let cell = CellValue::from_json(json!([1, 2]));
        assert_eq!(cell.kind, CELL_KIND_TEXT);
        assert_eq!(cell.text_value.as_deref(), Some("[1,2]"));
    }

    #[test]
    fn event_kind_codes_select_the_documented_payload() {
        let started = QueryEvent::started(3, "SELECT 1".to_string());
        assert_eq!(started.kind, EVENT_KIND_STARTED);
        assert_eq!(started.statement_index, 3);
        assert_eq!(started.statement.as_deref(), Some("SELECT 1"));
        assert!(started.result.is_none() && started.summary.is_none());

        let batch = QueryEvent::batch(
            0,
            vec![ColumnDto {
                name: "id".to_string(),
                type_name: "BIGINT".to_string(),
            }],
            vec![vec![CellValue::int(1)]],
            false,
        );
        assert_eq!(batch.kind, EVENT_KIND_BATCH);
        assert_eq!(batch.columns.len(), 1);
        assert_eq!(batch.rows, vec![vec![CellValue::int(1)]]);
        assert!(!batch.truncated);

        let done = QueryEvent::statement_done(0, empty_result_set());
        assert_eq!(done.kind, EVENT_KIND_STATEMENT_DONE);
        assert!(done.result.is_some());

        let summary = QueryEvent::done(empty_summary());
        assert_eq!(summary.kind, EVENT_KIND_DONE);
        assert!(summary.summary.is_some());

        let failed = QueryEvent::failed("boom".to_string());
        assert_eq!(failed.kind, EVENT_KIND_FAILED);
        assert_eq!(failed.message.as_deref(), Some("boom"));
    }
}

#[cfg(test)]
fn empty_result_set() -> ResultSetDto {
    ResultSetDto {
        columns: Vec::new(),
        rows: Vec::new(),
        row_count: 0,
        last_insert_id: 0,
        statement: String::new(),
        kind: String::new(),
        error: None,
        truncated: false,
    }
}

#[cfg(test)]
fn empty_summary() -> QuerySummaryDto {
    QuerySummaryDto {
        statement_count: 0,
        failed: 0,
        elapsed_ms: 0,
        driver: String::new(),
        search_path: None,
        database: None,
        use_database: None,
        truncated: false,
        row_limit: 0,
    }
}
