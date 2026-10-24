//! Zero-copy result buffer: Rust owns the bytes, Dart reads them through a raw
//! pointer (mechanism prototype, layer 4 of the transfer optimisation).
//!
//! The normal FRB result path encodes every cell into a wire format that Dart
//! decodes back into objects (a copy in, a copy out). This module keeps the
//! result in one contiguous little-endian byte buffer owned by Rust:
//!
//! ```text
//! Rust:  Vec<u8> (row-major binary)  --ptr/len-->  Dart: Pointer.fromAddress(ptr).asTypedList(len)
//! ```
//!
//! The FFI call only transfers two integers ([raw_buffer_ptr],
//! [raw_buffer_len]); no serializer, no per-cell encode/decode on the bridge.
//! Dart parses the bytes lazily from the view, so paging through rows costs
//! nothing until a row is actually read.
//!
//! # Safety boundary (must stay documented)
//!
//! The Dart `Uint8List` is a **view of Rust memory**. It is not tracked by the
//! Dart GC and Rust does not know about it:
//!
//! * the view is valid only while the `RawRowBuffer` handle is alive;
//! * call `dispose()` on the generated handle (and on [crate::api::raw_buffer]
//!   wrappers) when done — FRB's opaque `dispose` drops the `Arc`, which frees
//!   the `Vec<u8>`;
//! * never keep the view (or a `Uint8List.sublistView` of it) past dispose;
//!   reading freed memory is undefined behaviour;
//! * the buffer is immutable once handed out, so a view never sees a
//!   reallocation as long as the handle lives.
//!
//! # Binary format (version 1, little-endian)
//!
//! ```text
//! header:  magic u32 ("RAWB") | version u16 | flags u16 (bit0 = truncated)
//!          | col_count u32 | row_count u32
//! columns: col_count x (name_len u32 + utf8 name, type_len u32 + utf8 type)
//! rows:    row_count x col_count x cell
//! cell:    tag u8 + payload
//!          0 null  : no payload
//!          1 bool  : u8 (0/1)
//!          2 int   : i64 LE
//!          3 float : f64 LE (IEEE-754)
//!          4 text  : u32 len + utf8 bytes
//!          5 bytes : u32 len + raw bytes
//! ```
//!
//! Dart mirrors this layout in `lib/src/raw_buffer.dart`; [RAW_BUFFER_MAGIC]
//! and [RAW_BUFFER_VERSION] are checked there so a format drift fails loudly.

use serde_json::Value;

use super::query_types::{
    CellValue, ColumnDto, QueryResponseDto, ResultSetDto, CELL_KIND_BOOL, CELL_KIND_BYTES,
    CELL_KIND_FLOAT, CELL_KIND_INT, CELL_KIND_NULL, CELL_KIND_TEXT,
};

/// `"RAWB"` as a little-endian u32.
pub const RAW_BUFFER_MAGIC: u32 = u32::from_le_bytes(*b"RAWB");
/// Binary layout version. Bump whenever the layout below changes.
pub const RAW_BUFFER_VERSION: u16 = 1;
/// Header flag bit 0: the result was truncated by the console row cap.
const FLAG_TRUNCATED: u16 = 1 << 0;
/// Header size in bytes (magic + version + flags + col_count + row_count).
const HEADER_LEN: usize = 16;
/// Upper bound accepted by [make_demo_raw_buffer], so a test cannot ask for an
/// unbounded allocation.
const DEMO_MAX_ROWS: i64 = 100_000;

/// One query result held in Rust memory as a row-major binary buffer.
///
/// Opaque to Dart: the generated `RawRowBuffer` class is a handle, and the only
/// way to reach the bytes is [raw_buffer_ptr] + [raw_buffer_len]. Use
/// [raw_buffer_meta] for the column names / row count without parsing.
///
/// The fields are private on purpose — Dart must not depend on Rust struct
/// layout, only on the documented binary format.
#[flutter_rust_bridge::frb(opaque)]
pub struct RawRowBuffer {
    /// Encoded rows, header included (see the module docs).
    data: Vec<u8>,
    /// Column metadata (also encoded in `data`; kept here so
    /// [raw_buffer_meta] needs no parsing).
    columns: Vec<ColumnDto>,
    /// Number of rows actually encoded (authoritative over the driver's
    /// reported count when the two disagree).
    row_count: i64,
    /// Whether the console row cap truncated the result.
    truncated: bool,
}

/// Metadata of a [RawRowBuffer], returned without touching the byte buffer.
///
/// This is the safe convenience path: it copies only column names/types, not
/// row data.
#[derive(Debug, Clone)]
pub struct RawBufferMeta {
    pub columns: Vec<ColumnDto>,
    pub row_count: i64,
    pub truncated: bool,
    /// Length of the binary buffer in bytes (same as [raw_buffer_len]).
    pub byte_len: i64,
}

impl RawRowBuffer {
    fn new(data: Vec<u8>, columns: Vec<ColumnDto>, row_count: i64, truncated: bool) -> Self {
        Self {
            data,
            columns,
            row_count,
            truncated,
        }
    }
}

/// Execute one console query and return its first row-returning result set as a
/// zero-copy [RawRowBuffer].
///
/// This is a mechanism prototype, not the console's new path: the query runs
/// through the existing typed engine (`run_query_typed`) and the resulting rows
/// are then encoded once into the binary buffer. It therefore still materialises
/// the typed rows in Rust; a production version would encode straight from the
/// driver's `RawCell` iterator in the query observer (see
/// `analysis/OPAQUE_REPORT.md`).
///
/// Multi-statement scripts follow the console: a leading `USE db` is applied as
/// a database switch, and the first result set with `kind == "rows"` is
/// encoded. A statement-level error aborts the call instead of returning a
/// partial buffer.
pub async fn make_raw_buffer_from_query(body: Value) -> anyhow::Result<RawRowBuffer> {
    let response = crate::query_engine::run_typed(body).await?;
    let (columns, rows, truncated) = select_rows_result(response)?;
    let row_count = rows.len() as i64;
    let data = encode_raw_buffer(&columns, &rows, truncated)?;
    Ok(RawRowBuffer::new(data, columns, row_count, truncated))
}

/// Build a deterministic demo buffer without a database connection.
///
/// Every cell kind of the format is exercised by the six demo columns:
/// `id` (int), `name` (text), `score` (float), `active` (bool),
/// `payload` (bytes) and `note` (text, NULL on every fifth row). This is what
/// the Dart unit tests use so the format can be verified without MySQL.
///
/// `rows` is clamped to `0..=100000`.
#[flutter_rust_bridge::frb(sync)]
pub fn make_demo_raw_buffer(rows: i64) -> RawRowBuffer {
    let rows = rows.clamp(0, DEMO_MAX_ROWS) as usize;
    let columns = demo_columns();
    let mut data_rows: Vec<Vec<CellValue>> = Vec::with_capacity(rows);
    for index in 0..rows {
        data_rows.push(vec![
            CellValue::int(index as i64),
            CellValue::text(format!("row-{index}")),
            CellValue::float(index as f64 * 0.5),
            CellValue::bool(index % 2 == 0),
            CellValue::bytes(vec![(index & 0xFF) as u8, 0, 255]),
            if index % 5 == 0 {
                CellValue::null()
            } else {
                CellValue::text(format!("note-{index}"))
            },
        ]);
    }
    // The demo rows are built by the module itself, so encoding cannot fail
    // unless the cell constructors themselves are inconsistent.
    let data = encode_raw_buffer(&columns, &data_rows, false)
        .expect("demo raw buffer encoding is infallible");
    RawRowBuffer::new(data, columns, rows as i64, false)
}

/// Address of the buffer's first byte, as an integer for
/// `ffi.Pointer<ffi.Uint8>.fromAddress()`.
///
/// Borrows the handle (`&RawRowBuffer`), so the Dart side keeps ownership and
/// the handle is not consumed by the call.
#[flutter_rust_bridge::frb(sync)]
pub fn raw_buffer_ptr(buffer: &RawRowBuffer) -> u64 {
    buffer.data.as_ptr() as usize as u64
}

/// Length of the encoded buffer in bytes (header included).
#[flutter_rust_bridge::frb(sync)]
pub fn raw_buffer_len(buffer: &RawRowBuffer) -> u64 {
    buffer.data.len() as u64
}

/// Copy the column metadata (and row count / truncation) of a buffer.
///
/// Cheap: it never touches the row payload.
#[flutter_rust_bridge::frb(sync)]
pub fn raw_buffer_meta(buffer: &RawRowBuffer) -> RawBufferMeta {
    RawBufferMeta {
        columns: buffer.columns.clone(),
        row_count: buffer.row_count,
        truncated: buffer.truncated,
        byte_len: buffer.data.len() as i64,
    }
}

// ---------------------------------------------------------------- internals

/// Pick the result set the buffer represents.
///
/// The console can run several statements; the buffer encodes the first
/// row-returning one. A statement error is propagated because silently encoding
/// an empty buffer would hide it.
fn select_rows_result(
    response: QueryResponseDto,
) -> anyhow::Result<(Vec<ColumnDto>, Vec<Vec<CellValue>>, bool)> {
    let mut chosen: Option<ResultSetDto> = None;
    for result in response.results {
        if let Some(error) = result.error.as_ref() {
            if result.kind != "rows" {
                anyhow::bail!("{error}");
            }
        }
        if chosen.is_none() && result.kind == "rows" {
            chosen = Some(result);
        }
    }
    let result = chosen.ok_or_else(|| {
        anyhow::anyhow!("该查询没有返回结果集（raw buffer 只支持 SELECT/SHOW 等行结果）")
    })?;
    Ok((result.columns, result.rows, result.truncated))
}

fn demo_columns() -> Vec<ColumnDto> {
    fn column(name: &str, type_name: &str) -> ColumnDto {
        ColumnDto {
            name: name.to_string(),
            type_name: type_name.to_string(),
        }
    }
    vec![
        column("id", "BIGINT"),
        column("name", "VARCHAR"),
        column("score", "DOUBLE"),
        column("active", "BOOLEAN"),
        column("payload", "VARBINARY"),
        column("note", "TEXT"),
    ]
}

/// Encode a fully materialised result set into the binary format.
///
/// Two passes: the first computes the exact size (one allocation, no growth),
/// the second writes the bytes. Cell text is copied exactly once, into the
/// buffer Dart will read.
fn encode_raw_buffer(
    columns: &[ColumnDto],
    rows: &[Vec<CellValue>],
    truncated: bool,
) -> anyhow::Result<Vec<u8>> {
    let column_count = u32::try_from(columns.len())
        .map_err(|_| anyhow::anyhow!("列数超过 u32 上限: {}", columns.len()))?;
    let row_count = u32::try_from(rows.len())
        .map_err(|_| anyhow::anyhow!("行数超过 u32 上限: {}", rows.len()))?;

    let mut size = HEADER_LEN;
    for column in columns {
        size += 4 + column.name.len() + 4 + column.type_name.len();
    }
    for row in rows {
        if row.len() != columns.len() {
            anyhow::bail!(
                "行宽不一致: 期望 {} 列, 实际 {} 列",
                columns.len(),
                row.len()
            );
        }
        for cell in row {
            size += encoded_cell_len(cell)?;
        }
    }

    let mut data = Vec::with_capacity(size);
    data.extend_from_slice(&RAW_BUFFER_MAGIC.to_le_bytes());
    data.extend_from_slice(&RAW_BUFFER_VERSION.to_le_bytes());
    let flags = if truncated { FLAG_TRUNCATED } else { 0 };
    data.extend_from_slice(&flags.to_le_bytes());
    data.extend_from_slice(&column_count.to_le_bytes());
    data.extend_from_slice(&row_count.to_le_bytes());
    for column in columns {
        write_sized_str(&mut data, &column.name)?;
        write_sized_str(&mut data, &column.type_name)?;
    }
    for row in rows {
        for cell in row {
            write_cell(&mut data, cell)?;
        }
    }
    debug_assert_eq!(data.len(), size, "raw buffer size accounting drifted");
    Ok(data)
}

fn encoded_cell_len(cell: &CellValue) -> anyhow::Result<usize> {
    Ok(match cell.kind {
        CELL_KIND_NULL => 1,
        CELL_KIND_BOOL => 2,
        CELL_KIND_INT => 9,
        CELL_KIND_FLOAT => 9,
        CELL_KIND_TEXT => 1 + 4 + text_bytes(cell)?.len(),
        CELL_KIND_BYTES => 1 + 4 + bytes_bytes(cell)?.len(),
        other => anyhow::bail!("未知 cell kind: {other}"),
    })
}

fn text_bytes(cell: &CellValue) -> anyhow::Result<&[u8]> {
    cell.text_value
        .as_deref()
        .map(str::as_bytes)
        .ok_or_else(|| anyhow::anyhow!("TEXT cell 缺少 text_value"))
}

fn bytes_bytes(cell: &CellValue) -> anyhow::Result<&[u8]> {
    cell.bytes_value
        .as_deref()
        .ok_or_else(|| anyhow::anyhow!("BYTES cell 缺少 bytes_value"))
}

fn write_cell(data: &mut Vec<u8>, cell: &CellValue) -> anyhow::Result<()> {
    match cell.kind {
        CELL_KIND_NULL => data.push(CELL_KIND_NULL),
        CELL_KIND_BOOL => {
            data.push(CELL_KIND_BOOL);
            data.push(u8::from(cell.bool_value.unwrap_or(false)));
        }
        CELL_KIND_INT => {
            data.push(CELL_KIND_INT);
            data.extend_from_slice(&cell.int_value.unwrap_or_default().to_le_bytes());
        }
        CELL_KIND_FLOAT => {
            data.push(CELL_KIND_FLOAT);
            data.extend_from_slice(&cell.float_value.unwrap_or_default().to_le_bytes());
        }
        CELL_KIND_TEXT => {
            data.push(CELL_KIND_TEXT);
            write_sized_bytes(data, text_bytes(cell)?)?;
        }
        CELL_KIND_BYTES => {
            data.push(CELL_KIND_BYTES);
            write_sized_bytes(data, bytes_bytes(cell)?)?;
        }
        other => anyhow::bail!("未知 cell kind: {other}"),
    }
    Ok(())
}

fn write_sized_str(data: &mut Vec<u8>, value: &str) -> anyhow::Result<()> {
    write_sized_bytes(data, value.as_bytes())
}

fn write_sized_bytes(data: &mut Vec<u8>, value: &[u8]) -> anyhow::Result<()> {
    let len = u32::try_from(value.len())
        .map_err(|_| anyhow::anyhow!("cell/列名长度超过 u32 上限: {}", value.len()))?;
    data.extend_from_slice(&len.to_le_bytes());
    data.extend_from_slice(value);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read_u32(data: &[u8], offset: usize) -> u32 {
        u32::from_le_bytes(data[offset..offset + 4].try_into().unwrap())
    }

    fn read_u16(data: &[u8], offset: usize) -> u16 {
        u16::from_le_bytes(data[offset..offset + 2].try_into().unwrap())
    }

    #[test]
    fn header_and_columns_are_encoded() {
        let buffer = make_demo_raw_buffer(3);
        let data = &buffer.data;
        assert_eq!(read_u32(data, 0), RAW_BUFFER_MAGIC);
        assert_eq!(read_u16(data, 4), RAW_BUFFER_VERSION);
        assert_eq!(read_u16(data, 6), 0);
        assert_eq!(read_u32(data, 8), 6);
        assert_eq!(read_u32(data, 12), 3);
        // The metadata copy and the encoded header must agree.
        assert_eq!(buffer.row_count, 3);
        assert_eq!(buffer.columns.len(), 6);
        let meta = raw_buffer_meta(&buffer);
        assert_eq!(meta.byte_len as usize, data.len());
        assert_eq!(meta.columns[1].name, "name");
        assert_eq!(meta.columns[4].type_name, "VARBINARY");
    }

    #[test]
    fn truncation_flag_round_trips() {
        let columns = demo_columns();
        let data = encode_raw_buffer(&columns, &[], true).unwrap();
        assert_eq!(read_u16(&data, 6), FLAG_TRUNCATED);
        let buffer = RawRowBuffer::new(data, columns, 0, true);
        assert!(raw_buffer_meta(&buffer).truncated);
        assert_eq!(raw_buffer_meta(&buffer).row_count, 0);
        assert_eq!(
            raw_buffer_len(&buffer) as usize,
            raw_buffer_meta(&buffer).byte_len as usize
        );
    }

    #[test]
    fn pointer_matches_vector_start() {
        let buffer = make_demo_raw_buffer(1);
        assert_eq!(
            raw_buffer_ptr(&buffer),
            buffer.data.as_ptr() as usize as u64
        );
        assert!(!buffer.data.is_empty());
    }

    #[test]
    fn demo_buffer_covers_every_cell_kind() {
        let buffer = make_demo_raw_buffer(6);
        let data = &buffer.data;
        // Skip header + columns, then walk the first row's six cells.
        let mut offset = HEADER_LEN;
        for _ in 0..6 {
            let name_len = read_u32(data, offset) as usize;
            offset += 4 + name_len;
            let type_len = read_u32(data, offset) as usize;
            offset += 4 + type_len;
        }
        let expected_tags = [
            CELL_KIND_INT,
            CELL_KIND_TEXT,
            CELL_KIND_FLOAT,
            CELL_KIND_BOOL,
            CELL_KIND_BYTES,
            CELL_KIND_NULL,
        ];
        for expected in expected_tags {
            assert_eq!(data[offset], expected, "tag at offset {offset}");
            offset += match expected {
                CELL_KIND_INT | CELL_KIND_FLOAT => 1 + 8,
                CELL_KIND_BOOL => 2,
                CELL_KIND_TEXT | CELL_KIND_BYTES => {
                    let len = read_u32(data, offset + 1) as usize;
                    1 + 4 + len
                }
                _ => 1,
            };
        }
    }

    #[test]
    fn unknown_cell_kind_is_rejected() {
        let mut cell = CellValue::null();
        cell.kind = 99;
        let mut row: Vec<CellValue> = (0..demo_columns().len())
            .map(|_| CellValue::null())
            .collect();
        row[2] = cell;
        let error = encode_raw_buffer(&demo_columns(), &[row], false).unwrap_err();
        assert!(error.to_string().contains("未知 cell kind"), "{error}");
    }

    #[test]
    fn row_width_mismatch_is_rejected() {
        let rows = vec![vec![CellValue::int(1)]];
        let error = encode_raw_buffer(&demo_columns(), &rows, false).unwrap_err();
        assert!(error.to_string().contains("行宽不一致"), "{error}");
    }

    #[test]
    fn demo_rows_are_clamped() {
        assert_eq!(make_demo_raw_buffer(-5).row_count, 0);
        assert_eq!(make_demo_raw_buffer(0).row_count, 0);
        // 100_001 clamps to 100_000 without allocating beyond the cap.
        let buffer = make_demo_raw_buffer(DEMO_MAX_ROWS + 1);
        assert_eq!(buffer.row_count, DEMO_MAX_ROWS);
    }
}
