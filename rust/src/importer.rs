//! Streaming data-file import engine.
//!
//! The web build only imported SQL scripts. The desktop app also imports data
//! files (CSV / TSV / JSON arrays / JSON Lines / custom wrapped text) into a
//! table, with a guided rule builder. Two properties drive this module:
//!
//! * **Never read a whole file into memory.** Everything is a byte stream with
//!   a bounded record/statement buffer; the same code path validates a 10 KB
//!   sample and a multi-GB data file.
//! * **Every failure names a position.** Records and statements carry the byte
//!   offset, 1-based line and record/statement index so the wizard can point at
//!   the exact line that did not match the configured rule.
//!
//! The module is deliberately UI-free: api::import owns jobs/polling, this
//! module owns parsing, conversion and batched INSERT generation.

use std::fs::File;
use std::fmt::Write as _;
use std::io::{Read, Seek, SeekFrom};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

use crate::drivers::{literal, qi, qualify, DriverKind};
use crate::error::{AppError, AppResult};

/// How many invalid records a validation/import run reports back.
pub const DEFAULT_MAX_ISSUES: usize = 100;
/// Records per multi-row INSERT statement.
pub const DEFAULT_BATCH_SIZE: usize = 500;
pub const MAX_BATCH_SIZE: usize = 5_000;
/// A single generated INSERT statement is capped so one enormous record cannot
/// make sqlx build a gigabyte-sized query string.
pub const MAX_BATCH_SQL_BYTES: usize = 512 * 1024;
/// A per-record cap: a file without the configured separator would otherwise
/// grow the record buffer until the process dies.
pub const DEFAULT_MAX_RECORD_BYTES: usize = 8 * 1024 * 1024;
/// A single SQL statement cap for the streaming SQL-file runner.
pub const MAX_SQL_STATEMENT_BYTES: usize = 16 * 1024 * 1024;
/// Preview reads at most this many records.
pub const MAX_PREVIEW_RECORDS: usize = 20;

fn default_true() -> bool {
    true
}
fn default_quote() -> String {
    "\"".to_string()
}
fn default_record_sep() -> String {
    "\n".to_string()
}
fn default_max_record() -> usize {
    DEFAULT_MAX_RECORD_BYTES
}
fn default_batch() -> usize {
    DEFAULT_BATCH_SIZE
}
fn default_max_issues() -> usize {
    DEFAULT_MAX_ISSUES
}
fn default_mode_line() -> String {
    "line".to_string()
}
fn default_fields_mode() -> String {
    "delimited".to_string()
}
fn default_field_sep() -> String {
    ",".to_string()
}
fn default_on_error() -> String {
    "stop".to_string()
}
fn default_null_tokens() -> Vec<String> {
    vec!["\\N".to_string()]
}

// ---------------------------------------------------------------- rule specs

/// How one complete record is delimited in the file.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ReadSpec {
    /// "line": one record per line (CSV / JSON Lines).
    /// "wrapped": optional file-level wrapper plus a record separator
    /// (JSON array "[ {...}, {...} ]", or BEGIN/END custom blocks).
    #[serde(default = "default_mode_line")]
    pub mode: String,
    /// Bytes expected once before the first record ("[" for a JSON array).
    #[serde(default)]
    pub wrapper_start: String,
    /// Bytes expected once after the last record ("]" for a JSON array).
    #[serde(default)]
    pub wrapper_end: String,
    /// Record separator for line / wrapped modes. A newline is the default.
    #[serde(default = "default_record_sep")]
    pub record_sep: String,
    /// String delimiter used while scanning records (CSV quoted fields, JSON
    /// strings inside a wrapped array). Empty disables quote awareness.
    #[serde(default = "default_quote")]
    pub quote: String,
    /// Wrapped mode only: ignore separators inside braces / brackets / parens.
    #[serde(default = "default_true")]
    pub balance: bool,
    /// Skip blank records instead of reporting them.
    #[serde(default = "default_true")]
    pub skip_blank: bool,
    /// Trim leading/trailing whitespace around each record.
    #[serde(default = "default_true")]
    pub trim: bool,
    #[serde(default = "default_max_record")]
    pub max_record_bytes: usize,
    /// Excel 系格式：要导入的工作表名；也接受 0-based 序号字符串（"0"）。
    /// 空/缺省表示第一张可见工作表。其他格式忽略本字段。
    #[serde(default, deserialize_with = "deserialize_sheet_selector")]
    pub sheet: Option<String>,
    /// Excel 系格式：跳过工作表最前面的 N 行（表头判定在跳过之后）。
    #[serde(default)]
    pub skip_rows: usize,
}

impl Default for ReadSpec {
    fn default() -> Self {
        ReadSpec {
            mode: default_mode_line(),
            wrapper_start: String::new(),
            wrapper_end: String::new(),
            record_sep: default_record_sep(),
            quote: default_quote(),
            balance: true,
            skip_blank: true,
            trim: true,
            max_record_bytes: default_max_record(),
            sheet: None,
            skip_rows: 0,
        }
    }
}

/// read.sheet 允许字符串（工作表名）或数字（0-based 序号），统一成字符串。
fn deserialize_sheet_selector<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<Value>::deserialize(deserializer)?;
    Ok(match value {
        None | Some(Value::Null) => None,
        Some(Value::String(text)) if text.trim().is_empty() => None,
        Some(Value::String(text)) => Some(text),
        Some(Value::Number(number)) => Some(number.to_string()),
        Some(_) => None,
    })
}

/// How the fields of one record are written.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct FieldSpec {
    /// How one record's fields are laid out:
    ///
    ///  * "delimited": CSV-style fields split by field_sep;
    ///  * "json": one JSON value (object = keyed, array = positional);
    ///  * "xml": `<col name="X">value</col>` / `<col name="X" null="true"/>`
    ///    (the XML exporter's own shape);
    ///  * "html": `<td>` cells, `<td class="null">` meaning NULL, `<th>` naming
    ///    the columns;
    ///  * "spreadsheet": SpreadsheetML `<Cell><Data ss:Type="..">v</Data></Cell>`,
    ///    an empty `<Cell/>` meaning NULL (Excel export);
    ///  * "markdown": a `| a | b |` table, header row above a `| --- |` rule.
    #[serde(default = "default_fields_mode")]
    pub mode: String,
    #[serde(default = "default_field_sep")]
    pub field_sep: String,
    #[serde(default = "default_quote")]
    pub quote: String,
    /// Optional escape character inside quotes (a backslash for some CSV flavours).
    #[serde(default)]
    pub escape: String,
    #[serde(default = "default_true")]
    pub trim: bool,
    /// Delimited files only: the first record names the columns.
    #[serde(default)]
    pub header: bool,
}

impl Default for FieldSpec {
    fn default() -> Self {
        FieldSpec {
            mode: default_fields_mode(),
            field_sep: default_field_sep(),
            quote: default_quote(),
            escape: String::new(),
            trim: true,
            header: false,
        }
    }
}

/// One destination column and where its value comes from.
///
/// The source is a JSON string (dictionary key / CSV header name) or a number
/// (0-based field position). Mixing both kinds is rejected.
#[derive(Clone, Debug, Deserialize)]
pub struct ColumnMap {
    pub column: String,
    pub source: Value,
}

#[derive(Clone, Debug, Deserialize)]
pub struct MappingSpec {
    #[serde(default)]
    pub columns: Vec<ColumnMap>,
    /// Keyed records may carry extra keys; ignore them instead of failing.
    #[serde(default = "default_true")]
    pub ignore_unknown: bool,
    /// Empty string means NULL for every column. When false, text/JSON columns
    /// keep the empty string and other columns become NULL.
    #[serde(default)]
    pub empty_as_null: bool,
    #[serde(default = "default_null_tokens")]
    pub null_tokens: Vec<String>,
    /// Trim string values before type conversion.
    #[serde(default = "default_true")]
    pub trim_values: bool,
}

impl Default for MappingSpec {
    fn default() -> Self {
        MappingSpec {
            columns: Vec::new(),
            ignore_unknown: true,
            empty_as_null: false,
            null_tokens: default_null_tokens(),
            trim_values: true,
        }
    }
}

/// Parse request shared by preview / validate / probe / execute.
#[derive(Clone, Debug, Deserialize)]
pub struct ParseSpec {
    pub path: String,
    pub read: ReadSpec,
    pub fields: FieldSpec,
}

#[derive(Clone, Debug, Deserialize)]
pub struct ValidateSpec {
    #[serde(flatten)]
    pub parse: ParseSpec,
    #[serde(default)]
    pub mapping: Option<MappingSpec>,
    #[serde(default)]
    pub database: Option<String>,
    #[serde(default)]
    pub table: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct ExecuteOptions {
    #[serde(default = "default_batch")]
    pub batch_size: usize,
    /// "stop" aborts at the first invalid row; "skip" keeps going.
    #[serde(default = "default_on_error")]
    pub on_error: String,
    #[serde(default = "default_max_issues")]
    pub max_issues: usize,
    /// How many autocommit batches to wrap into one transaction (P1).
    ///
    /// 1 (the default) keeps the historical behaviour: every batch is its own
    /// autocommit statement, so a later failure keeps earlier batches.  Higher
    /// values reduce commit round trips for the delimited fast path; on failure
    /// the group is rolled back and replayed batch by batch so the observable
    /// partial-import semantics stay the same.  Ignored by the generic path and
    /// when on_error = "skip" (per-row diagnostics need per-batch isolation).
    #[serde(default = "default_transaction_batches")]
    pub transaction_batches: usize,
}

fn default_transaction_batches() -> usize {
    1
}

impl Default for ExecuteOptions {
    fn default() -> Self {
        ExecuteOptions {
            batch_size: default_batch(),
            on_error: default_on_error(),
            max_issues: default_max_issues(),
            transaction_batches: default_transaction_batches(),
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
pub struct ExecuteSpec {
    #[serde(flatten)]
    pub validate: ValidateSpec,
    #[serde(default)]
    pub options: ExecuteOptions,
}

// ---------------------------------------------------------------- diagnostics

#[derive(Clone, Debug, Default, Serialize)]
pub struct Progress {
    pub phase: String,
    pub bytes: u64,
    pub total_bytes: u64,
    pub records: u64,
    pub rows: u64,
    pub failed: u64,
    pub percent: f64,
    pub elapsed_ms: u64,
    pub message: String,
}

impl Progress {
    fn refresh(&mut self, started: Instant) {
        self.elapsed_ms = started.elapsed().as_millis() as u64;
        self.percent = if self.total_bytes > 0 {
            (self.bytes as f64 / self.total_bytes as f64 * 100.0).clamp(0.0, 100.0)
        } else {
            0.0
        };
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct RowIssue {
    /// 0-based record index (header records are not counted).
    pub index: u64,
    pub line: u64,
    pub offset: u64,
    pub message: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub snippet: String,
}

pub fn snippet(text: &str, max_chars: usize) -> String {
    let mut out: String = text.chars().take(max_chars).collect();
    if text.chars().count() > max_chars {
        out.push('…');
    }
    out.replace('\n', "\\n").replace('\r', "\\r")
}

#[derive(Clone, Debug)]
struct RawRecord {
    index: u64,
    offset: u64,
    line: u64,
    text: String,
}

#[derive(Clone, Debug)]
struct ReadProblem {
    message: String,
    offset: u64,
    line: u64,
    /// Fatal structural problems stop the scan (the rule can no longer be
    /// applied); recoverable ones (invalid UTF-8, blank record) let it continue.
    fatal: bool,
}

enum ScanItem {
    Record(RawRecord),
    Problem(ReadProblem),
}

/// Result of the unquoted-record fast path in [RecordScanner::next_line].
enum FastRecord {
    Bytes(Vec<u8>),
    Eof,
    Fallback,
}

// ---------------------------------------------------------------- byte stream

/// Buffered byte stream with absolute offset + line tracking.
///
/// All reads are bounded: the internal buffer is refilled in 64 KiB chunks and
/// compacted after consumption, so memory stays flat no matter the file size.
struct ByteStream {
    file: File,
    buf: Vec<u8>,
    pos: usize,
    eof: bool,
    /// Absolute offset of the next unread byte.
    abs: u64,
    /// 1-based line of the next unread byte.
    line: u64,
}

impl ByteStream {
    fn open(path: &str) -> AppResult<Self> {
        let mut file = File::open(path).map_err(|e| AppError::bad(format!("无法打开文件: {e}")))?;
        // Detect a byte-order mark; UTF-16 is reported as unsupported rather
        // than silently decoded as garbage.
        let mut head = [0u8; 4];
        let n = file.read(&mut head).unwrap_or(0);
        let (skip, encoding) = detect_bom(&head[..n]);
        if encoding == "utf-16le" || encoding == "utf-16be" {
            return Err(AppError::bad(
                "文件是 UTF-16 编码，暂不支持；请另存为 UTF-8 后重试".to_string(),
            ));
        }
        // Always rewind to the first content byte: the BOM probe above consumed
        // up to four bytes even when there is no BOM.
        file.seek(SeekFrom::Start(skip as u64))
            .map_err(|e| AppError::bad(format!("无法读取文件: {e}")))?;
        Ok(ByteStream {
            file,
            buf: Vec::with_capacity(64 * 1024),
            pos: 0,
            eof: false,
            abs: skip as u64,
            line: 1,
        })
    }

    fn ensure(&mut self, n: usize) -> AppResult<()> {
        while self.buf.len().saturating_sub(self.pos) < n && !self.eof {
            if self.pos > 0 {
                self.buf.drain(..self.pos);
                self.pos = 0;
            }
            let mut chunk = [0u8; 64 * 1024];
            let read = self
                .file
                .read(&mut chunk)
                .map_err(|e| AppError::bad(format!("读取文件失败: {e}")))?;
            if read == 0 {
                self.eof = true;
                break;
            }
            self.buf.extend_from_slice(&chunk[..read]);
        }
        Ok(())
    }

    fn remaining(&self) -> usize {
        self.buf.len().saturating_sub(self.pos)
    }

    fn at_eof(&mut self) -> AppResult<bool> {
        self.ensure(1)?;
        Ok(self.remaining() == 0)
    }

    fn peek(&mut self) -> AppResult<Option<u8>> {
        self.ensure(1)?;
        Ok(self.buf.get(self.pos).copied())
    }

    /// Look n bytes ahead without consuming (None past EOF).
    fn peek_at(&mut self, n: usize) -> AppResult<Option<u8>> {
        self.ensure(n + 1)?;
        Ok(self.buf.get(self.pos + n).copied())
    }

    fn starts_with(&mut self, pat: &[u8]) -> AppResult<bool> {
        if pat.is_empty() {
            return Ok(true);
        }
        self.ensure(pat.len())?;
        Ok(self.remaining() >= pat.len() && self.buf[self.pos..self.pos + pat.len()] == *pat)
    }

    fn starts_with_ascii_ci(&mut self, pat: &str) -> AppResult<bool> {
        let bytes = pat.as_bytes();
        self.ensure(bytes.len())?;
        if self.remaining() < bytes.len() {
            return Ok(false);
        }
        Ok(self.buf[self.pos..self.pos + bytes.len()]
            .iter()
            .zip(bytes.iter())
            .all(|(a, b)| a.to_ascii_lowercase() == b.to_ascii_lowercase()))
    }

    fn next_byte(&mut self) -> AppResult<Option<u8>> {
        let byte = self.peek()?;
        if let Some(b) = byte {
            self.pos += 1;
            self.abs += 1;
            if b == b'\n' {
                self.line += 1;
            }
        }
        Ok(byte)
    }

    /// Consume n bytes (they must already be buffered; callers peeked).
    fn advance(&mut self, n: usize) {
        for _ in 0..n {
            if let Some(b) = self.buf.get(self.pos).copied() {
                self.pos += 1;
                self.abs += 1;
                if b == b'\n' {
                    self.line += 1;
                }
            }
        }
    }

    fn position(&self) -> (u64, u64) {
        (self.abs, self.line)
    }

    /// Read one more chunk into the buffer, compacting consumed bytes first.
    /// Returns false at EOF. Same 64 KiB bound as [ByteStream::ensure].
    fn fill_more(&mut self) -> AppResult<bool> {
        if self.eof {
            return Ok(false);
        }
        if self.pos > 0 {
            self.buf.drain(..self.pos);
            self.pos = 0;
        }
        let mut chunk = [0u8; 64 * 1024];
        let read = self
            .file
            .read(&mut chunk)
            .map_err(|e| AppError::bad(format!("读取文件失败: {e}")))?;
        if read == 0 {
            self.eof = true;
            return Ok(false);
        }
        self.buf.extend_from_slice(&chunk[..read]);
        Ok(true)
    }

    /// Consume buffered bytes up to buffer index `end` (exclusive), keeping the
    /// absolute offset and 1-based line in sync. Unlike [ByteStream::advance]
    /// this is used by the fast record scanner, which can skip whole records.
    fn consume_through(&mut self, end: usize) {
        let end = end.min(self.buf.len());
        let consumed = end.saturating_sub(self.pos);
        if consumed > 0 {
            self.line += self.buf[self.pos..end]
                .iter()
                .filter(|&&byte| byte == b'\n')
                .count() as u64;
            self.abs += consumed as u64;
            self.pos = end;
        }
    }
}

/// Byte-order mark detection. Returns (bytes to skip, encoding label).
pub fn detect_bom(head: &[u8]) -> (usize, &'static str) {
    if head.starts_with(&[0xEF, 0xBB, 0xBF]) {
        (3, "utf-8")
    } else if head.starts_with(&[0xFF, 0xFE]) {
        (2, "utf-16le")
    } else if head.starts_with(&[0xFE, 0xFF]) {
        (2, "utf-16be")
    } else {
        (0, "utf-8")
    }
}

// ---------------------------------------------------------------- record scan

/// One record's text plus where it was found in the file.
struct TextScanner {
    stream: ByteStream,
    read: ReadSpec,
    fields: FieldSpec,
    /// Wrapped mode: the opening wrapper has been consumed.
    started: bool,
    /// Next record index (0-based, header included).
    next_index: u64,
    done: bool,
    explicit_end: bool,
}

impl TextScanner {
    fn open(spec: &ParseSpec) -> AppResult<TextScanner> {
        std::fs::metadata(&spec.path)
            .map_err(|e| AppError::bad(format!("无法读取文件: {e}")))?;
        Ok(TextScanner {
            stream: ByteStream::open(&spec.path)?,
            read: normalize_read(&spec.read),
            fields: spec.fields.clone(),
            started: false,
            next_index: 0,
            done: false,
            explicit_end: false,
        })
    }

    fn next(&mut self) -> AppResult<Option<ScanItem>> {
        if self.done {
            return Ok(None);
        }
        loop {
            let item = match self.read.mode.as_str() {
                "wrapped" => self.next_wrapped(),
                _ => self.next_line(),
            }?;
            // The Markdown separator row (`| --- | --- |`) is table syntax, not
            // a record: keeping it would show up as a bogus one-column row.
            if self.fields.mode == "markdown" {
                if let Some(ScanItem::Record(record)) = &item {
                    if is_markdown_rule(&record.text) {
                        continue;
                    }
                }
            }
            return Ok(item);
        }
    }

    /// One record per line (CSV quoted fields may contain newlines).
    fn next_line(&mut self) -> AppResult<Option<ScanItem>> {
        let sep = self.read.record_sep.as_bytes().to_vec();
        if sep.is_empty() {
            self.done = true;
            return Ok(Some(ScanItem::Problem(ReadProblem {
                message: "记录分隔符不能为空".to_string(),
                offset: self.stream.abs,
                line: self.stream.line,
                fatal: true,
            })));
        }
        // CSV rule: a quote only opens at the start of a field, so embedded
        // quotes in unquoted text do not swallow the rest of the file.
        let quote_on = self.fields.mode == "delimited" && !self.read.quote.is_empty();
        let quote = self.read.quote.as_bytes().first().copied();
        let field_sep = self.fields.field_sep.as_bytes().to_vec();

        loop {
            if self.stream.at_eof()? {
                self.done = true;
                return Ok(None);
            }
            let (start_offset, start_line) = self.stream.position();
            let mut text: Vec<u8> = match self.read_fast_record(&sep, quote_on, quote)? {
                FastRecord::Bytes(bytes) => bytes,
                FastRecord::Eof => {
                    self.done = true;
                    return Ok(None);
                }
                FastRecord::Fallback => {
                    let mut text: Vec<u8> = Vec::new();
                    let mut in_quote = false;
                    let mut at_field_start = true;
                    loop {
                    if self.stream.at_eof()? {
                        if in_quote {
                            self.done = true;
                            return Ok(Some(ScanItem::Problem(ReadProblem {
                                message: "引号未闭合：记录一直读到文件结尾".to_string(),
                                offset: start_offset,
                                line: start_line,
                                fatal: true,
                            })));
                        }
                        break;
                    }
                    if !in_quote && self.stream.starts_with(&sep)? {
                        self.stream.advance(sep.len());
                        break;
                    }
                    if quote_on
                        && !in_quote
                        && !field_sep.is_empty()
                        && self.stream.starts_with(&field_sep)?
                    {
                        self.stream.advance(field_sep.len());
                        text.extend_from_slice(&field_sep);
                        at_field_start = true;
                        continue;
                    }
                    let byte = match self.stream.next_byte()? {
                        Some(b) => b,
                        None => break,
                    };
                    if quote_on {
                        if in_quote {
                            if Some(byte) == quote {
                                // Doubled quote escapes itself inside a quoted field.
                                if Some(byte) == self.stream.peek()? {
                                    self.stream.advance(1);
                                    text.push(byte);
                                    text.push(byte);
                                } else {
                                    in_quote = false;
                                    text.push(byte);
                                }
                            } else {
                                text.push(byte);
                            }
                            continue;
                        }
                        if Some(byte) == quote && at_field_start {
                            in_quote = true;
                            at_field_start = false;
                            text.push(byte);
                            continue;
                        }
                    }
                    at_field_start = false;
                    text.push(byte);
                    if text.len() > self.read.max_record_bytes {
                        self.done = true;
                        return Ok(Some(ScanItem::Problem(ReadProblem {
                            message: format!(
                                "单条记录超过上限 {} 字节，可能记录分隔符配置不正确",
                                self.read.max_record_bytes
                            ),
                            offset: start_offset,
                            line: start_line,
                            fatal: true,
                        })));
                    }
                    }
                    text
                }
            };
            // A record terminated by CRLF keeps a trailing CR when the separator
            // is a bare newline; strip it like a text editor would.
            if sep.ends_with(b"\n") && text.last() == Some(&b'\r') {
                text.pop();
            }
            let index = self.next_index;
            self.next_index += 1;
            let raw = match String::from_utf8(text) {
                Ok(text) => text,
                Err(_) => {
                    return Ok(Some(ScanItem::Problem(ReadProblem {
                        message: "记录不是有效的 UTF-8 文本（可能是 GBK/GB18030 编码）"
                            .to_string(),
                        offset: start_offset,
                        line: start_line,
                        fatal: false,
                    })))
                }
            };
            // Record-level trimming would eat a trailing field separator, which is
            // exactly how a row ending in an empty (or NULL) last column looks.
            // Delimited and Markdown rows trim their FIELDS instead (split_fields
            // does that), so the empty cell survives.
            let trim_record = self.read.trim
                && !matches!(self.fields.mode.as_str(), "delimited" | "markdown");
            let text = if trim_record { raw.trim().to_string() } else { raw };
            if text.is_empty() {
                if self.read.skip_blank {
                    continue;
                }
                return Ok(Some(ScanItem::Problem(ReadProblem {
                    message: "空记录（跳过空行可避免）".to_string(),
                    offset: start_offset,
                    line: start_line,
                    fatal: false,
                })));
            }
            return Ok(Some(ScanItem::Record(RawRecord {
                index,
                offset: start_offset,
                line: start_line,
                text,
            })));
        }
    }

    /// Fast path for the common exported-CSV shape: a single-byte record
    /// separator, a single-byte quote character and rows whose cells are not
    /// quoted. Scans the 64 KiB buffer for the separator instead of walking it
    /// byte by byte through `at_eof`/`starts_with`/`next_byte` (the old inner
    /// loop cost several function calls per input byte).
    ///
    /// Any record that contains the quote character falls back to the general
    /// state machine, so quoted cells, doubled quotes and embedded newlines keep
    /// the exact previous semantics.
    fn read_fast_record(
        &mut self,
        sep: &[u8],
        quote_on: bool,
        quote: Option<u8>,
    ) -> AppResult<FastRecord> {
        if sep.len() != 1 {
            return Ok(FastRecord::Fallback);
        }
        let sep_byte = sep[0];
        let quote_byte = if quote_on {
            match quote {
                Some(byte) if byte != b'\n' && byte != sep_byte => Some(byte),
                _ => return Ok(FastRecord::Fallback),
            }
        } else {
            None
        };
        loop {
            if self.stream.remaining() == 0 {
                if !self.stream.fill_more()? {
                    return Ok(FastRecord::Eof);
                }
            }
            let start = self.stream.pos;
            let buf = &self.stream.buf;
            match buf[start..].iter().position(|&byte| byte == sep_byte) {
                Some(relative) => {
                    let end = start + relative;
                    if end - start > self.read.max_record_bytes {
                        // Let the byte-wise path report the configured size limit.
                        return Ok(FastRecord::Fallback);
                    }
                    if let Some(quote_byte) = quote_byte {
                        if buf[start..end].contains(&quote_byte) {
                            return Ok(FastRecord::Fallback);
                        }
                    }
                    let bytes = buf[start..end].to_vec();
                    self.stream.consume_through(end + sep.len());
                    return Ok(FastRecord::Bytes(bytes));
                }
                None => {
                    if self.stream.eof || self.stream.remaining() > self.read.max_record_bytes {
                        // Final record without a trailing separator, or a record
                        // that exceeds the configured limit: the byte-wise path
                        // produces the exact same bytes / diagnostics.
                        return Ok(FastRecord::Fallback);
                    }
                    self.stream.fill_more()?;
                }
            }
        }
    }

    /// Records separated by record_sep, optionally inside one file-level
    /// wrapper. Bracket depth and JSON strings are honoured so a comma inside a
    /// JSON object never ends the record.
    fn next_wrapped(&mut self) -> AppResult<Option<ScanItem>> {
        let sep = self.read.record_sep.as_bytes().to_vec();
        let open = self.read.wrapper_start.as_bytes().to_vec();
        let close = self.read.wrapper_end.as_bytes().to_vec();
        let quote = self.read.quote.as_bytes().first().copied();
        if sep.is_empty() {
            self.done = true;
            return Ok(Some(ScanItem::Problem(ReadProblem {
                message: "记录分隔符不能为空".to_string(),
                offset: self.stream.abs,
                line: self.stream.line,
                fatal: true,
            })));
        }

        if !self.started {
            self.started = true;
            self.skip_spaces()?;
            if !open.is_empty() {
                if !self.stream.starts_with(&open)? {
                    self.done = true;
                    return Ok(Some(ScanItem::Problem(ReadProblem {
                        message: format!(
                            "文件开头缺少记录包裹符 '{}'",
                            self.read.wrapper_start
                        ),
                        offset: self.stream.abs,
                        line: self.stream.line,
                        fatal: true,
                    })));
                }
                self.stream.advance(open.len());
            }
        }

        loop {
            self.skip_spaces()?;
            if self.stream.at_eof()? {
                self.done = true;
                if !close.is_empty() && !self.explicit_end {
                    return Ok(Some(ScanItem::Problem(ReadProblem {
                        message: format!("文件结尾缺少记录包裹符 '{}'", self.read.wrapper_end),
                        offset: self.stream.abs,
                        line: self.stream.line,
                        fatal: true,
                    })));
                }
                return Ok(None);
            }
            if self.explicit_end {
                let (offset, line) = self.stream.position();
                self.done = true;
                return Ok(Some(ScanItem::Problem(ReadProblem {
                    message: format!(
                        "记录包裹符 '{}' 之后还有内容",
                        self.read.wrapper_end
                    ),
                    offset,
                    line,
                    fatal: true,
                })));
            }
            if !close.is_empty() && self.stream.starts_with(&close)? {
                self.stream.advance(close.len());
                self.explicit_end = true;
                continue;
            }
            // Blank lines / duplicated separators between records.
            if self.stream.starts_with(&sep)? {
                let (offset, line) = self.stream.position();
                self.stream.advance(sep.len());
                if self.read.skip_blank {
                    continue;
                }
                return Ok(Some(ScanItem::Problem(ReadProblem {
                    message: "空记录（跳过空记录可避免）".to_string(),
                    offset,
                    line,
                    fatal: false,
                })));
            }

            let (start_offset, start_line) = self.stream.position();
            let mut text: Vec<u8> = Vec::new();
            let mut in_string = false;
            let mut escaped = false;
            let mut depth: i64 = 0;
            let mut terminated = false;
            loop {
                if self.stream.at_eof()? {
                    break;
                }
                // The closing wrapper at top level ends the last record.
                if !in_string
                    && depth == 0
                    && !close.is_empty()
                    && !text.is_empty()
                    && self.stream.starts_with(&close)?
                {
                    break;
                }
                if !in_string
                    && depth == 0
                    && !text.is_empty()
                    && self.stream.starts_with(&sep)?
                {
                    self.stream.advance(sep.len());
                    terminated = true;
                    break;
                }
                let byte = match self.stream.next_byte()? {
                    Some(b) => b,
                    None => break,
                };
                if in_string {
                    if escaped {
                        escaped = false;
                    } else if Some(byte) == quote {
                        in_string = false;
                    } else if byte == b'\\' {
                        escaped = true;
                    }
                } else if Some(byte) == quote {
                    in_string = true;
                } else if self.read.balance {
                    match byte {
                        b'{' | b'[' | b'(' => depth += 1,
                        b'}' | b']' | b')' => {
                            depth -= 1;
                            if depth < 0 {
                                depth = 0;
                            }
                        }
                        _ => {}
                    }
                }
                text.push(byte);
                if text.len() > self.read.max_record_bytes {
                    self.done = true;
                    return Ok(Some(ScanItem::Problem(ReadProblem {
                        message: format!(
                            "单条记录超过上限 {} 字节，可能记录分隔符/包裹符配置不正确",
                            self.read.max_record_bytes
                        ),
                        offset: start_offset,
                        line: start_line,
                        fatal: true,
                    })));
                }
            }
            let index = self.next_index;
            self.next_index += 1;
            let raw = match String::from_utf8(text) {
                Ok(text) => text,
                Err(_) => {
                    return Ok(Some(ScanItem::Problem(ReadProblem {
                        message: "记录不是有效的 UTF-8 文本（可能是 GBK/GB18030 编码）"
                            .to_string(),
                        offset: start_offset,
                        line: start_line,
                        fatal: false,
                    })))
                }
            };
            let text = if self.read.trim { raw.trim().to_string() } else { raw };
            if text.is_empty() {
                if self.read.skip_blank {
                    continue;
                }
                return Ok(Some(ScanItem::Problem(ReadProblem {
                    message: "空记录（跳过空记录可避免）".to_string(),
                    offset: start_offset,
                    line: start_line,
                    fatal: false,
                })));
            }
            if !terminated && close.is_empty() {
                // No wrapper and no separator: the rest of the file is one
                // record; scanning ends after it.
                self.done = true;
            }
            return Ok(Some(ScanItem::Record(RawRecord {
                index,
                offset: start_offset,
                line: start_line,
                text,
            })));
        }
    }

    fn skip_spaces(&mut self) -> AppResult<()> {
        loop {
            match self.stream.peek()? {
                Some(b' ') | Some(b'\t') | Some(b'\r') | Some(b'\n') => {
                    self.stream.advance(1);
                }
                _ => return Ok(()),
            }
        }
    }
}

// ---------------------------------------------------------------- record scan

/// Record scanner used by preview / validate / probe / execute.
///
/// Text formats keep the streaming byte reader (never loads the file). Excel
/// formats use the streaming row layer (excel_stream): xlsx/ODS/SpreadsheetML
/// parse incrementally (xlsx/xlsb/xls/ODS/SpreadsheetML). Rows are handed to
/// the shared header/mapping/INSERT pipeline as JSON-array record text.
enum RecordScanner {
    Text(TextScanner),
    Excel(ExcelScanner),
}

/// Excel 类型的进度：按行（总行数未知时退化为 XML 字节进度）。
struct ExcelProgress {
    sheet: String,
    done: u64,
    total: Option<u64>,
    finished: bool,
    bytes: Option<(u64, u64)>,
}

/// 工作簿的表目录 + 当前选中的表（preview 回显用）。
struct ExcelMeta {
    sheet: String,
    sheets: Vec<Value>,
    streaming: bool,
    warnings: Vec<String>,
}

/// Excel 行扫描器：从流式行源惰性拉行，绝不物化整张表。
struct ExcelScanner {
    opened: crate::excel_stream::OpenedSheet,
    meta: ExcelMeta,
    /// 当前行号（skip_rows 之后的物理位置）。
    first_line: u64,
    next_index: u64,
    finished: bool,
}

impl ExcelScanner {
    fn open(spec: &ParseSpec) -> AppResult<ExcelScanner> {
        let kind = crate::excel_import::detect(&spec.path)?.ok_or_else(|| {
            AppError::bad("无法识别为 Excel 文件（支持 xlsx/xls/xlsb/ods/SpreadsheetML）")
        })?;
        let opened = crate::excel_stream::open_sheet(
            &spec.path,
            kind,
            spec.read.sheet.as_deref(),
            spec.read.skip_rows,
        )?;
        let meta = ExcelMeta {
            sheet: opened.sheet.clone(),
            sheets: opened.sheets.clone(),
            streaming: opened.streaming,
            warnings: opened.warnings.clone(),
        };
        Ok(ExcelScanner {
            opened,
            meta,
            first_line: spec.read.skip_rows as u64 + 1,
            next_index: 0,
            finished: false,
        })
    }

    fn next(&mut self) -> AppResult<Option<ScanItem>> {
        match self.opened.source.next_row()? {
            None => {
                self.finished = true;
                Ok(None)
            }
            Some(values) => {
                let index = self.next_index;
                self.next_index += 1;
                let text = serde_json::to_string(&values).unwrap_or_else(|_| "[]".to_string());
                Ok(Some(ScanItem::Record(RawRecord {
                    index,
                    // Excel 没有字节偏移：offset 恒为 0，行号按工作表实际行号报告。
                    offset: 0,
                    line: self.first_line + index,
                    text,
                })))
            }
        }
    }
}

impl RecordScanner {
    fn open(spec: &ParseSpec) -> AppResult<RecordScanner> {
        if spec.fields.mode == "excel" {
            Ok(RecordScanner::Excel(ExcelScanner::open(spec)?))
        } else {
            Ok(RecordScanner::Text(TextScanner::open(spec)?))
        }
    }

    fn next(&mut self) -> AppResult<Option<ScanItem>> {
        match self {
            RecordScanner::Text(scanner) => scanner.next(),
            RecordScanner::Excel(scanner) => scanner.next(),
        }
    }

    /// Excel 的按行进度；文本格式返回 None（继续用字节进度）。
    fn excel_progress(&self) -> Option<ExcelProgress> {
        match self {
            RecordScanner::Excel(scanner) => Some(ExcelProgress {
                sheet: scanner.opened.sheet.clone(),
                done: scanner.next_index,
                total: scanner.opened.total_rows,
                finished: scanner.finished,
                bytes: scanner.opened.source.bytes_progress(),
            }),
            RecordScanner::Text(_) => None,
        }
    }

    /// 当前工作表/表目录（preview 回显）；文本格式返回 None。
    fn excel_meta(&self) -> Option<&ExcelMeta> {
        match self {
            RecordScanner::Excel(scanner) => Some(&scanner.meta),
            RecordScanner::Text(_) => None,
        }
    }
}

/// Excel 进度按行：percent = 已读行/总行数；总行数未知时用 XML 字节进度退化。
/// 读完时强制 100%（dimension 可能比实际数据行多一点）。
fn apply_excel_progress(
    state: &mut Progress,
    progress: &ExcelProgress,
    total_bytes: u64,
    started: Instant,
) {
    let fraction = if progress.finished {
        1.0
    } else if let Some(total) = progress.total.filter(|total| *total > 0) {
        (progress.done.min(total) as f64 / total as f64).clamp(0.0, 1.0)
    } else if let Some((position, total)) = progress.bytes.filter(|(_, total)| *total > 0) {
        (position.min(total) as f64 / total as f64).clamp(0.0, 1.0)
    } else {
        0.0
    };
    if total_bytes > 0 {
        state.bytes = (total_bytes as f64 * fraction) as u64;
    }
    state.refresh(started);
    state.percent = fraction * 100.0;
    state.message = match progress.total {
        Some(total) if !progress.finished && total > 0 => format!(
            "工作表 {} · 第 {}/{} 行",
            progress.sheet,
            progress.done.min(total),
            total
        ),
        _ => format!("工作表 {} · 第 {} 行", progress.sheet, progress.done),
    };
}


fn normalize_read(read: &ReadSpec) -> ReadSpec {
    let mut read = read.clone();
    read.mode = match read.mode.as_str() {
        "wrapped" => "wrapped".to_string(),
        _ => "line".to_string(),
    };
    read
}

// ------------------------------------------------- fast delimited record scan
//
// The delimited execute path needs the record text AND its field boundaries
// without allocating a `String` per record or per field.  `next_record_into`
// reuses a caller-owned byte buffer and returns borrowed slices of it; the
// caller must finish using the slice before the next call.  Semantics (quoted
// fields, doubled quotes, embedded newlines, CRLF stripping, blank records,
// UTF-8 diagnostics, size limits) are exactly `next_line`'s.

#[derive(Clone, Copy, Debug)]
struct RecordMeta {
    index: u64,
    offset: u64,
    line: u64,
}

enum NextRecord {
    /// The record bytes are in the caller's buffer and are valid UTF-8.
    Record(RecordMeta),
    Problem(ReadProblem),
    End,
}

enum FastRecordFill {
    Written,
    Eof,
    Fallback,
}

impl TextScanner {
    /// Fill `out` with the next record and return its metadata plus a borrowed
    /// `&str` view.  Only used by the delimited fast execute path, where
    /// `read.trim` is false (delimited rows trim their fields instead).
    fn next_record_into(&mut self, out: &mut Vec<u8>) -> AppResult<NextRecord> {
        if self.done {
            return Ok(NextRecord::End);
        }
        let sep = self.read.record_sep.as_bytes().to_vec();
        if sep.is_empty() {
            self.done = true;
            return Ok(NextRecord::Problem(ReadProblem {
                message: "记录分隔符不能为空".to_string(),
                offset: self.stream.abs,
                line: self.stream.line,
                fatal: true,
            }));
        }
        let quote_on = self.fields.mode == "delimited" && !self.read.quote.is_empty();
        let quote = self.read.quote.as_bytes().first().copied();
        let field_sep = self.fields.field_sep.as_bytes().to_vec();
        loop {
            if self.stream.at_eof()? {
                self.done = true;
                return Ok(NextRecord::End);
            }
            let (start_offset, start_line) = self.stream.position();
            out.clear();
            match self.read_fast_record_into(&sep, quote_on, quote, out)? {
                FastRecordFill::Written => {}
                FastRecordFill::Eof => {
                    self.done = true;
                    return Ok(NextRecord::End);
                }
                FastRecordFill::Fallback => {
                    // Same state machine as `next_line`, but it appends bytes to
                    // the reusable buffer instead of allocating a fresh Vec.
                    let mut in_quote = false;
                    let mut at_field_start = true;
                    loop {
                        if self.stream.at_eof()? {
                            if in_quote {
                                self.done = true;
                                return Ok(NextRecord::Problem(ReadProblem {
                                    message: "引号未闭合：记录一直读到文件结尾".to_string(),
                                    offset: start_offset,
                                    line: start_line,
                                    fatal: true,
                                }));
                            }
                            break;
                        }
                        if !in_quote && self.stream.starts_with(&sep)? {
                            self.stream.advance(sep.len());
                            break;
                        }
                        if quote_on
                            && !in_quote
                            && !field_sep.is_empty()
                            && self.stream.starts_with(&field_sep)?
                        {
                            self.stream.advance(field_sep.len());
                            out.extend_from_slice(&field_sep);
                            at_field_start = true;
                            continue;
                        }
                        let byte = match self.stream.next_byte()? {
                            Some(byte) => byte,
                            None => break,
                        };
                        if quote_on {
                            if in_quote {
                                if Some(byte) == quote {
                                    if Some(byte) == self.stream.peek()? {
                                        self.stream.advance(1);
                                        out.push(byte);
                                        out.push(byte);
                                    } else {
                                        in_quote = false;
                                        out.push(byte);
                                    }
                                } else {
                                    out.push(byte);
                                }
                                continue;
                            }
                            if Some(byte) == quote && at_field_start {
                                in_quote = true;
                                at_field_start = false;
                                out.push(byte);
                                continue;
                            }
                        }
                        at_field_start = false;
                        out.push(byte);
                        if out.len() > self.read.max_record_bytes {
                            self.done = true;
                            return Ok(NextRecord::Problem(ReadProblem {
                                message: format!(
                                    "单条记录超过上限 {} 字节，可能记录分隔符配置不正确",
                                    self.read.max_record_bytes
                                ),
                                offset: start_offset,
                                line: start_line,
                                fatal: true,
                            }));
                        }
                    }
                }
            }
            // A record terminated by CRLF keeps a trailing CR when the separator
            // is a bare newline; strip it like a text editor would.
            if sep.ends_with(b"\n") && out.last() == Some(&b'\r') {
                out.pop();
            }
            let index = self.next_index;
            self.next_index += 1;
            if std::str::from_utf8(out).is_err() {
                return Ok(NextRecord::Problem(ReadProblem {
                    message: "记录不是有效的 UTF-8 文本（可能是 GBK/GB18030 编码）".to_string(),
                    offset: start_offset,
                    line: start_line,
                    fatal: false,
                }));
            }
            let text = std::str::from_utf8(out).expect("UTF-8 validated above");
            debug_assert!(
                !(self.read.trim
                    && !matches!(self.fields.mode.as_str(), "delimited" | "markdown")),
                "next_record_into is only used for delimited records"
            );
            if text.is_empty() {
                if self.read.skip_blank {
                    continue;
                }
                return Ok(NextRecord::Problem(ReadProblem {
                    message: "空记录（跳过空行可避免）".to_string(),
                    offset: start_offset,
                    line: start_line,
                    fatal: false,
                }));
            }
            return Ok(NextRecord::Record(RecordMeta {
                index,
                offset: start_offset,
                line: start_line,
            }));
        }
    }

    /// Copy the next unquoted record into `out`.  Leaves the stream untouched
    /// when it returns `Fallback` so the byte-wise state machine can take over.
    fn read_fast_record_into(
        &mut self,
        sep: &[u8],
        quote_on: bool,
        quote: Option<u8>,
        out: &mut Vec<u8>,
    ) -> AppResult<FastRecordFill> {
        if sep.len() != 1 {
            return Ok(FastRecordFill::Fallback);
        }
        let sep_byte = sep[0];
        let quote_byte = if quote_on {
            match quote {
                Some(byte) if byte != b'\n' && byte != sep_byte => Some(byte),
                _ => return Ok(FastRecordFill::Fallback),
            }
        } else {
            None
        };
        loop {
            if self.stream.remaining() == 0 {
                if !self.stream.fill_more()? {
                    return Ok(FastRecordFill::Eof);
                }
            }
            let start = self.stream.pos;
            let buf = &self.stream.buf;
            match buf[start..].iter().position(|&byte| byte == sep_byte) {
                Some(relative) => {
                    let end = start + relative;
                    if end - start > self.read.max_record_bytes {
                        return Ok(FastRecordFill::Fallback);
                    }
                    if let Some(quote_byte) = quote_byte {
                        if buf[start..end].contains(&quote_byte) {
                            return Ok(FastRecordFill::Fallback);
                        }
                    }
                    out.extend_from_slice(&buf[start..end]);
                    self.stream.consume_through(end + sep.len());
                    return Ok(FastRecordFill::Written);
                }
                None => {
                    if self.stream.eof || self.stream.remaining() > self.read.max_record_bytes {
                        return Ok(FastRecordFill::Fallback);
                    }
                    self.stream.fill_more()?;
                }
            }
        }
    }
}

// ---------------------------------------------------------------- field parse

#[derive(Clone, Debug)]
pub enum ParsedRow {
    Keyed(Map<String, Value>),
    Positional(Vec<Value>),
}

/// Split one delimited record into fields, honouring quotes.
pub fn split_fields(
    text: &str,
    sep: &str,
    quote: &str,
    escape: &str,
    trim: bool,
) -> Result<Vec<String>, String> {
    if sep.is_empty() {
        return Err("字段分隔符不能为空".to_string());
    }
    let quote_char = quote.chars().next();
    let escape_char = escape.chars().next();
    // Fast path: when the quoting character does not occur in the record, the
    // general state machine degenerates to "split on the separator, then trim".
    // Exported CSV data takes this path; quoted/doubled-quote cells stay on the
    // byte-at-a-time implementation below.
    if quote_char.is_none_or(|quote| !text.contains(quote)) {
        return Ok(text
            .split(sep)
            .map(|part| {
                if trim {
                    part.trim().to_string()
                } else {
                    part.to_string()
                }
            })
            .collect());
    }
    let mut fields: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut in_quote = false;
    let mut field_started = false;
    let bytes = text.as_bytes();
    let mut i = 0usize;
    while i < text.len() {
        let ch = text[i..].chars().next().unwrap();
        let clen = ch.len_utf8();
        if in_quote {
            if Some(ch) == escape_char {
                cur.push(ch);
                i += clen;
                if i < text.len() {
                    let next = text[i..].chars().next().unwrap();
                    cur.push(next);
                    i += next.len_utf8();
                }
                continue;
            }
            if Some(ch) == quote_char {
                if text[i + clen..].starts_with(quote) {
                    cur.push(ch);
                    i += clen * 2;
                    continue;
                }
                in_quote = false;
                i += clen;
                continue;
            }
            cur.push(ch);
            i += clen;
            continue;
        }
        if bytes[i..].starts_with(sep.as_bytes()) {
            fields.push(finish_field(std::mem::take(&mut cur), trim));
            field_started = false;
            i += sep.len();
            continue;
        }
        if Some(ch) == quote_char && (!field_started || cur.trim().is_empty()) {
            cur.clear();
            in_quote = true;
            field_started = true;
            i += clen;
            continue;
        }
        cur.push(ch);
        field_started = true;
        i += clen;
    }
    if in_quote {
        return Err("引号未闭合".to_string());
    }
    fields.push(finish_field(cur, trim));
    Ok(fields)
}

fn finish_field(mut field: String, trim: bool) -> String {
    if trim {
        let trimmed = field.trim();
        if trimmed.len() != field.len() {
            // Only pay for a second allocation when whitespace is actually
            // present (the old code always reallocated the field).
            field = trimmed.to_string();
        }
    }
    field
}

/// Field boundaries (byte ranges into `text`) for a record that contains no
/// quote character.  This is the unquoted CSV fast path: no per-field String,
/// no escaping work — the semantics are exactly `split_fields`'s fast path
/// (`text.split(sep)`, then `trim` every field).
fn split_fields_ranges(
    text: &str,
    sep: &str,
    trim: bool,
    out: &mut Vec<(usize, usize)>,
) -> Result<(), String> {
    if sep.is_empty() {
        return Err("字段分隔符不能为空".to_string());
    }
    out.clear();
    let mut start = 0usize;
    loop {
        let end = match text[start..].find(sep) {
            Some(relative) => start + relative,
            None => text.len(),
        };
        let (field_start, field_end) = if trim {
            let part = &text[start..end];
            let trimmed = part.trim();
            let offset = trimmed.as_ptr() as usize - text.as_ptr() as usize;
            (offset, offset + trimmed.len())
        } else {
            (start, end)
        };
        out.push((field_start, field_end));
        if end == text.len() {
            break;
        }
        start = end + sep.len();
    }
    Ok(())
}

/// Parse one record according to the field rule.
pub fn parse_row(text: &str, spec: &FieldSpec) -> Result<ParsedRow, String> {
    match spec.mode.as_str() {
        "xml" => return parse_xml_row(text),
        "html" => return parse_html_row(text),
        "spreadsheet" => return parse_spreadsheet_row(text),
        "markdown" => return parse_markdown_row(text),
        // "excel" 是 Excel 扫描器序列化出来的一行（JSON 数组文本），
        // 与 JSON 数组共用同一套解析/NULL 语义（契约 §2.2）。
        "json" | "excel" => match serde_json::from_str::<Value>(text) {
            Ok(Value::Object(map)) => Ok(ParsedRow::Keyed(map)),
            Ok(Value::Array(values)) => Ok(ParsedRow::Positional(values)),
            Ok(other) => Err(format!(
                "记录是 JSON {}，需要 JSON 对象（列名:值）或数组（按位置）",
                json_kind(&other)
            )),
            Err(e) => Err(format!("JSON 解析失败: {e}")),
        },
        _ => {
            if spec.field_sep.is_empty() {
                return Err("字段分隔符不能为空".to_string());
            }
            let fields = split_fields(
                text,
                &spec.field_sep,
                &spec.quote,
                &spec.escape,
                spec.trim,
            )?;
            Ok(ParsedRow::Positional(
                fields.into_iter().map(Value::String).collect(),
            ))
        }
    }
}

// ------------------------------------------------- structural record parsers
//
// The exporter writes seven non-SQL formats; the importer used to understand
// only delimited text and JSON, so an exported XML/HTML/Excel/Markdown file
// could not be read back. Each parser below mirrors exactly what
// exporters::render emits for that format, including the NULL markers:
//
//   XML        <col name="x" null="true"/>   vs <col name="x"></col>
//   HTML       <td class="null"></td>        vs <td></td>
//   Excel      <Cell/>                       vs <Cell><Data>..</Data></Cell>
//   Markdown   \N                            vs (empty)
//   CSV/TXT    \N                            vs (empty)

/// Unescape the five XML entities the exporter writes.
pub(crate) fn xml_unescape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(amp) = rest.find('&') {
        out.push_str(&rest[..amp]);
        rest = &rest[amp..];
        let end = match rest.find(';') {
            Some(end) => end,
            None => break,
        };
        let entity = &rest[1..end];
        let decoded = match entity {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            _ => None,
        };
        match decoded {
            Some(c) => {
                out.push(c);
                rest = &rest[end + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// Text between the first `<tag ...>` and its matching `</tag>`.
fn inner_of<'a>(text: &'a str, tag: &str) -> Option<&'a str> {
    let open = text.find(&format!("<{tag}"))?;
    let after_open = text[open..].find('>')? + open + 1;
    let close = text[after_open..].find(&format!("</{tag}>"))? + after_open;
    Some(&text[after_open..close])
}

/// Value of `name="..."` inside the first tag of `text`.
pub(crate) fn attr_value<'a>(text: &'a str, name: &str) -> Option<&'a str> {
    let needle = format!("{name}=\"");
    let start = text.find(&needle)? + needle.len();
    let end = text[start..].find('"')? + start;
    Some(&text[start..end])
}

/// Parse one `<row>` of the XML export.
///
/// A `<col ... null="true"/>` element is NULL; a `<col name="x"></col>`
/// element is the empty string. Keeping them apart is what makes the round
/// trip lossless.
fn parse_xml_row(text: &str) -> Result<ParsedRow, String> {
    let mut map = Map::new();
    let mut rest = text;
    let mut seen = 0usize;
    while let Some(start) = rest.find("<col") {
        rest = &rest[start..];
        let tag_end = match rest.find('>') {
            Some(end) => end,
            None => break,
        };
        let tag = &rest[..=tag_end];
        let name = attr_value(tag, "name")
            .ok_or_else(|| "XML 列缺少 name 属性".to_string())?
            .to_string();
        if tag.ends_with("/>") {
            let is_null = attr_value(tag, "null").is_some_and(|v| v == "true");
            map.insert(
                name,
                if is_null {
                    Value::Null
                } else {
                    Value::String(String::new())
                },
            );
            seen += 1;
            rest = &rest[tag_end + 1..];
            continue;
        }
        let body = inner_of(rest, "col").unwrap_or("");
        map.insert(name, Value::String(xml_unescape(body)));
        seen += 1;
        rest = &rest[tag_end + 1..];
    }
    if seen == 0 {
        return Err("XML 记录里没有 <col> 元素".to_string());
    }
    Ok(ParsedRow::Keyed(map))
}

/// Parse one `<tr>` of the HTML export into positional cells.
///
/// `<td class="null"></td>` is NULL; `<td></td>` is the empty string.
fn parse_html_row(text: &str) -> Result<ParsedRow, String> {
    let mut values = Vec::new();
    let mut rest = text;
    while let Some(start) = rest.find("<td") {
        rest = &rest[start..];
        let tag_end = match rest.find('>') {
            Some(end) => end,
            None => break,
        };
        let tag = &rest[..=tag_end];
        let is_null = attr_value(tag, "class").is_some_and(|v| v == "null");
        let body = inner_of(rest, "td").unwrap_or("");
        values.push(if is_null {
            Value::Null
        } else {
            Value::String(xml_unescape(body))
        });
        rest = &rest[tag_end + 1..];
    }
    if values.is_empty() {
        return Err("HTML 记录里没有 <td> 元素".to_string());
    }
    Ok(ParsedRow::Positional(values))
}

/// Parse one `<Row>` of the SpreadsheetML (Excel) export.
///
/// `<Cell/>` is NULL; `ss:Index` (which Excel writes for sparse rows) skips
/// positions so the values stay aligned with the header.
pub(crate) fn parse_spreadsheet_row(text: &str) -> Result<ParsedRow, String> {
    let mut values: Vec<Value> = Vec::new();
    let mut rest = text;
    while let Some(start) = rest.find("<Cell") {
        rest = &rest[start..];
        let tag_end = match rest.find('>') {
            Some(end) => end,
            None => break,
        };
        let tag = &rest[..=tag_end];
        if let Some(index) = attr_value(tag, "ss:Index").and_then(|v| v.parse::<usize>().ok()) {
            // SpreadsheetML indices are 1-based and may skip positions.
            while values.len() + 1 < index {
                values.push(Value::Null);
            }
        }
        if tag.ends_with("/>") {
            values.push(Value::Null);
            rest = &rest[tag_end + 1..];
            continue;
        }
        let body = inner_of(rest, "Cell").unwrap_or("");
        match inner_of(body, "Data") {
            Some(data) => {
                let kind = body
                    .find("<Data")
                    .and_then(|i| attr_value(&body[i..], "ss:Type"))
                    .unwrap_or("String");
                let raw = xml_unescape(data);
                values.push(match kind {
                    // 整数值输出成 JSON 整数（1.0 → 1）：记录文本/样本与类型推断
                    // 都不再需要区分「Excel 数字是浮点」这件事。
                    "Number" => raw
                        .parse::<f64>()
                        .map(crate::excel_import::normalize_number)
                        .unwrap_or(Value::String(raw)),
                    "Boolean" => Value::Bool(raw == "1" || raw.eq_ignore_ascii_case("true")),
                    _ => Value::String(raw),
                });
            }
            // A <Cell> with no <Data> child is an empty cell.
            None => values.push(Value::Null),
        }
        rest = &rest[tag_end + 1..];
    }
    if values.is_empty() {
        return Err("Excel 记录里没有 <Cell> 元素".to_string());
    }
    Ok(ParsedRow::Positional(values))
}

/// Parse one Markdown table row into positional cells.
///
/// The separator row (`| --- |`) is skipped by the caller. `\|` is an escaped
/// pipe inside a cell.
fn parse_markdown_row(text: &str) -> Result<ParsedRow, String> {
    let trimmed = text.trim();
    let body = trimmed.strip_prefix('|').unwrap_or(trimmed);
    let body = body.strip_suffix('|').unwrap_or(body);
    let mut values = Vec::new();
    let mut cur = String::new();
    let mut chars = body.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' && chars.peek() == Some(&'|') {
            chars.next();
            cur.push('|');
        } else if c == '|' {
            values.push(Value::String(cur.trim().to_string()));
            cur.clear();
        } else {
            cur.push(c);
        }
    }
    values.push(Value::String(cur.trim().to_string()));
    Ok(ParsedRow::Positional(values))
}

/// Is this Markdown line the `| --- | --- |` separator?
fn is_markdown_rule(text: &str) -> bool {
    let trimmed = text.trim();
    trimmed.starts_with('|')
        && trimmed.contains('-')
        && trimmed
            .chars()
            .all(|c| matches!(c, '|' | '-' | ':' | ' '))
}
fn json_kind(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "布尔值",
        Value::Number(_) => "数字",
        Value::String(_) => "字符串",
        Value::Array(_) => "数组",
        Value::Object(_) => "对象",
    }
}

fn header_of(text: &str, spec: &FieldSpec) -> Result<Vec<String>, String> {
    // The structural formats name their columns in their own way: XML carries
    // the name in each <col>, HTML in the <th> row, Excel in the first <Row>
    // (which has no ss:Type distinction).
    let fields: Vec<String> = match spec.mode.as_str() {
        "xml" => {
            let mut names = Vec::new();
            let mut rest = text;
            while let Some(start) = rest.find("<col") {
                rest = &rest[start..];
                let tag_end = match rest.find('>') {
                    Some(end) => end,
                    None => break,
                };
                match attr_value(&rest[..=tag_end], "name") {
                    Some(name) => names.push(name.to_string()),
                    None => return Err("XML 列缺少 name 属性".to_string()),
                }
                rest = &rest[tag_end + 1..];
            }
            names
        }
        "html" => {
            let mut names = Vec::new();
            let mut rest = text;
            while let Some(start) = rest.find("<th") {
                rest = &rest[start..];
                let tag_end = match rest.find('>') {
                    Some(end) => end,
                    None => break,
                };
                let body = inner_of(rest, "th").unwrap_or("");
                names.push(xml_unescape(body));
                rest = &rest[tag_end + 1..];
            }
            names
        }
        "spreadsheet" => match parse_spreadsheet_row(text)? {
            ParsedRow::Positional(values) => values
                .into_iter()
                .map(|v| match v {
                    Value::String(s) => s,
                    other => other.to_string(),
                })
                .collect(),
            ParsedRow::Keyed(map) => map.keys().cloned().collect(),
        },
        "markdown" => match parse_markdown_row(text)? {
            ParsedRow::Positional(values) => values
                .into_iter()
                .map(|v| match v {
                    Value::String(s) => s,
                    other => other.to_string(),
                })
                .collect(),
            ParsedRow::Keyed(map) => map.keys().cloned().collect(),
        },
        // Excel 的一行是 JSON 数组文本（见 excel_import）；表头按数组规则取列名。
        "excel" => match serde_json::from_str::<Value>(text) {
            Ok(Value::Array(values)) => values
                .into_iter()
                .map(|value| match value {
                    Value::String(s) => s,
                    Value::Null => String::new(),
                    other => other.to_string(),
                })
                .collect(),
            Ok(Value::Object(map)) => map.keys().cloned().collect(),
            Ok(_) => return Err("Excel 记录不是 JSON 数组".to_string()),
            Err(e) => return Err(format!("JSON 解析失败: {e}")),
        },
        _ => split_fields(text, &spec.field_sep, &spec.quote, &spec.escape, true)?,
    };
    if fields.is_empty() {
        return Err("表头为空".to_string());
    }
    let mut names: Vec<String> = Vec::new();
    for (i, name) in fields.iter().enumerate() {
        let name = name.trim().to_string();
        if name.is_empty() {
            // Excel 表头允许留空单元格：按位置补列名，映射/建表都能继续。
            if spec.mode == "excel" {
                names.push(format!("column_{}", i + 1));
                continue;
            }
            return Err(format!("表头第 {} 列为空", i + 1));
        }
        if names.iter().any(|n| n == &name) {
            return Err(format!("表头列名重复: '{}'", name));
        }
        names.push(name);
    }
    Ok(names)
}

/// 哪些字段方式会消费「第一条记录 = 表头」（Excel 的 excel 模式同 CSV 数组规则）。
fn is_header_mode(mode: &str) -> bool {
    matches!(
        mode,
        "delimited" | "xml" | "html" | "spreadsheet" | "markdown" | "excel"
    )
}

// ---------------------------------------------------------------- table types

#[derive(Clone, Debug)]
pub struct TableColumn {
    pub name: String,
    pub data_type: String,
    pub type_name: String,
    pub nullable: bool,
    pub auto_increment: bool,
}

impl TableColumn {
    fn kind(&self) -> ColumnKind {
        let raw = if self.data_type.trim().is_empty() {
            &self.type_name
        } else {
            &self.data_type
        };
        column_kind(raw)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ColumnKind {
    Int,
    Float,
    Bool,
    Json,
    Date,
    Binary,
    Text,
}

pub fn column_kind(data_type: &str) -> ColumnKind {
    let mut norm = data_type.trim().to_ascii_lowercase();
    if let Some(pos) = norm.find('(') {
        norm.truncate(pos);
    }
    let norm = norm.trim().to_string();
    if norm.contains("json") {
        return ColumnKind::Json;
    }
    if norm == "bool" || norm == "boolean" || norm == "bit" {
        return ColumnKind::Bool;
    }
    if (norm.contains("int")
        && !norm.contains("interval")
        && !norm.contains("point")
        && !norm.contains("print"))
        || norm == "serial"
        || norm == "bigserial"
        || norm == "smallserial"
    {
        return ColumnKind::Int;
    }
    if norm.contains("numeric")
        || norm.contains("decimal")
        || norm.contains("float")
        || norm.contains("double")
        || norm.contains("real")
        || norm.contains("money")
    {
        return ColumnKind::Float;
    }
    if norm.contains("date") || norm.contains("time") || norm == "year" {
        return ColumnKind::Date;
    }
    if norm.contains("blob") || norm.contains("binary") || norm == "bytea" {
        return ColumnKind::Binary;
    }
    if norm.contains("char") || norm.contains("text") || norm.contains("clob") {
        return ColumnKind::Text;
    }
    ColumnKind::Text
}

/// Extract the destination columns from a structure response.
pub fn columns_from_structure(structure: &Value) -> Vec<TableColumn> {
    let mut out = Vec::new();
    let Some(columns) = structure.get("columns").and_then(|c| c.as_array()) else {
        return out;
    };
    for column in columns {
        let name = column
            .get("name")
            .or_else(|| column.get("COLUMN_NAME"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if name.is_empty() {
            continue;
        }
        out.push(TableColumn {
            name,
            data_type: column
                .get("DATA_TYPE")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            type_name: column
                .get("type_name")
                .or_else(|| column.get("COLUMN_TYPE"))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            nullable: column
                .get("IS_NULLABLE")
                .and_then(|v| v.as_str())
                .map(|v| !v.eq_ignore_ascii_case("NO"))
                .unwrap_or(true),
            auto_increment: column
                .get("EXTRA")
                .and_then(|v| v.as_str())
                .map(|v| v.to_ascii_lowercase().contains("auto_increment"))
                .unwrap_or(false),
        });
    }
    out
}

/// Resolved column mapping: destination metadata plus ordered sources.
#[derive(Clone, Debug)]
pub struct ResolvedMapping {
    pub columns: Vec<TableColumn>,
    pub sources: Vec<Value>,
    pub keyed: bool,
}

/// Validate a mapping against the real table before any row is read.
pub fn resolve_mapping(
    mapping: &MappingSpec,
    table_columns: &[TableColumn],
) -> AppResult<ResolvedMapping> {
    if mapping.columns.is_empty() {
        return Err(AppError::bad("请先设置列映射（至少映射一列）"));
    }
    let mut keyed: Option<bool> = None;
    let mut columns = Vec::new();
    let mut sources = Vec::new();
    let mut seen_columns: Vec<String> = Vec::new();
    for entry in &mapping.columns {
        let column = entry.column.trim().to_string();
        if column.is_empty() {
            return Err(AppError::bad("列映射包含空的目标列名"));
        }
        if seen_columns.iter().any(|c| c == &column) {
            return Err(AppError::bad(format!("列 '{}' 被映射了多次", column)));
        }
        let Some(meta) = table_columns.iter().find(|c| c.name == column) else {
            return Err(AppError::bad(format!(
                "目标表不存在列 '{}'，请重新选择映射",
                column
            )));
        };
        let this_keyed = match &entry.source {
            Value::String(_) => true,
            Value::Number(n) => {
                if n.as_u64().is_none() {
                    return Err(AppError::bad(format!(
                        "列 '{}' 的位置序号必须是非负整数",
                        column
                    )));
                }
                false
            }
            _ => {
                return Err(AppError::bad(format!(
                    "列 '{}' 的来源必须是列名（字典）或位置序号（无列名）",
                    column
                )))
            }
        };
        match keyed {
            None => keyed = Some(this_keyed),
            Some(k) if k != this_keyed => {
                return Err(AppError::bad(
                    "列映射不能混用“按列名”和“按位置”两种来源".to_string(),
                ))
            }
            _ => {}
        }
        seen_columns.push(column);
        columns.push(meta.clone());
        sources.push(entry.source.clone());
    }
    Ok(ResolvedMapping {
        columns,
        sources,
        keyed: keyed.unwrap_or(true),
    })
}

/// Turn the configured NULL token into a real `null` for the preview echo.
///
/// The final conversion happens in [convert_value] during validate/execute, but
/// the wizard's "here is how your rule reads the file" panel has to show NULL
/// where the file means NULL - otherwise the marker looks like literal text and
/// the user cannot tell whether the rule is right.
fn mark_null_token(value: Value) -> Value {
    match value {
        Value::String(s) if s == "\\N" => Value::Null,
        other => other,
    }
}

fn mark_null_tokens(values: Vec<Value>) -> Vec<Value> {
    values.into_iter().map(mark_null_token).collect()
}

fn convert_value(raw: Value, column: &TableColumn, mapping: &MappingSpec) -> Result<Value, String> {
    if raw.is_null() {
        return Ok(Value::Null);
    }
    let kind = column.kind();
    if let Value::String(mut text) = raw {
        if mapping.trim_values {
            let trimmed = text.trim();
            if trimmed.len() != text.len() {
                // Only allocate when the field actually carries whitespace.
                text = trimmed.to_string();
            }
        }
        if mapping.null_tokens.iter().any(|token| token == &text) {
            return Ok(Value::Null);
        }
        if text.is_empty() {
            // Empty is NULL for every non-text column. JSON goes here too: an
            // empty string is not a valid JSON document, so keeping it would
            // only fail later at INSERT time.
            return if mapping.empty_as_null || !matches!(kind, ColumnKind::Text) {
                Ok(Value::Null)
            } else {
                Ok(Value::String(String::new()))
            };
        }
        return match kind {
            // The common CSV case: move the parsed String into the INSERT values
            // instead of cloning it (the old code cloned it twice: trim + match).
            ColumnKind::Text => Ok(Value::String(text)),
            ColumnKind::Int => {
                let cleaned = cleaned_numeric(&text);
                if let Ok(value) = cleaned.parse::<i64>() {
                    Ok(json!(value))
                } else if let Ok(value) = cleaned.parse::<u64>() {
                    Ok(json!(value))
                } else {
                    Err(format!(
                        "列 '{}' 需要整数，但值是 '{}'",
                        column.name,
                        snippet(&text, 40)
                    ))
                }
            }
            ColumnKind::Float => {
                let cleaned = cleaned_numeric(&text);
                if cleaned.parse::<f64>().is_err() {
                    return Err(format!(
                        "列 '{}' 需要数字，但值是 '{}'",
                        column.name,
                        snippet(&text, 40)
                    ));
                }
                // Keep the original text: the database parses decimals without
                // the precision loss of an f64 round-trip.
                Ok(Value::String(cleaned.into_owned()))
            }
            ColumnKind::Bool => {
                let value = if text.eq_ignore_ascii_case("1")
                    || text.eq_ignore_ascii_case("t")
                    || text.eq_ignore_ascii_case("true")
                    || text.eq_ignore_ascii_case("y")
                    || text.eq_ignore_ascii_case("yes")
                    || text.eq_ignore_ascii_case("on")
                {
                    Some(true)
                } else if text.eq_ignore_ascii_case("0")
                    || text.eq_ignore_ascii_case("f")
                    || text.eq_ignore_ascii_case("false")
                    || text.eq_ignore_ascii_case("n")
                    || text.eq_ignore_ascii_case("no")
                    || text.eq_ignore_ascii_case("off")
                {
                    Some(false)
                } else {
                    None
                };
                match value {
                    Some(value) => Ok(Value::Bool(value)),
                    None => {
                        let lowered = text.to_ascii_lowercase();
                        Err(format!(
                            "列 '{}' 需要布尔值（true/false/1/0），但值是 '{}'",
                            column.name,
                            snippet(&lowered, 40)
                        ))
                    }
                }
            }
            ColumnKind::Date => Ok(Value::String(text)),
            ColumnKind::Json => {
                if serde_json::from_str::<Value>(&text).is_err() {
                    return Err(format!(
                        "列 '{}' 是 JSON 类型，但值是 '{}'，不是合法的 JSON 文本",
                        column.name,
                        snippet(&text, 40)
                    ));
                }
                Ok(Value::String(text))
            }
            ColumnKind::Binary => Err(format!(
                "列 '{}' 是二进制/BLOB 类型，暂不支持从文本文件导入",
                column.name
            )),
        };
    }
    // Non-string raw values only arrive from structured formats (JSON arrays /
    // JSON lines / spreadsheets).
    match kind {
        ColumnKind::Int => match raw {
            Value::Number(number) if number.is_i64() || number.is_u64() => {
                Ok(Value::Number(number))
            }
            Value::Number(_) => Err(format!("列 '{}' 需要整数，但值是小数", column.name)),
            Value::Bool(value) => Ok(if value { json!(1) } else { json!(0) }),
            _ => Err(format!("列 '{}' 需要整数", column.name)),
        },
        ColumnKind::Float => match raw {
            Value::Number(number) => Ok(Value::Number(number)),
            Value::Bool(value) => Ok(if value { json!(1) } else { json!(0) }),
            _ => Err(format!("列 '{}' 需要数字", column.name)),
        },
        // Structured formats (JSON / Excel cells) deliver real booleans and
        // 0/1 numbers instead of text. This branch used to reject them outright,
        // which made a PostgreSQL BOOLEAN target unimportable from a workbook
        // even though the cell *was* a boolean.
        ColumnKind::Bool => match raw {
            Value::Bool(value) => Ok(Value::Bool(value)),
            Value::Number(number) => match number.as_i64() {
                Some(0) => Ok(Value::Bool(false)),
                Some(1) => Ok(Value::Bool(true)),
                _ => Err(format!(
                    "列 '{}' 需要布尔值（true/false/1/0），但值是 '{}'",
                    column.name, number
                )),
            },
            other => Err(format!(
                "列 '{}' 需要布尔值（true/false/1/0），但值是 '{}'",
                column.name,
                snippet(&other.to_string(), 40)
            )),
        },
        ColumnKind::Date => Err(format!(
            "列 '{}' 是日期时间类型，请使用文本格式（如 2024-01-02 03:04:05）",
            column.name
        )),
        ColumnKind::Json => match raw {
            Value::Object(_) | Value::Array(_) => Ok(raw),
            other => Ok(Value::String(other.to_string())),
        },
        ColumnKind::Binary => Err(format!(
            "列 '{}' 是二进制/BLOB 类型，暂不支持从文本文件导入",
            column.name
        )),
        ColumnKind::Text => Ok(Value::String(raw.to_string())),
    }
}

/// Convert one parsed record into the ordered values for the INSERT.
fn map_record(
    row: &ParsedRow,
    resolved: &ResolvedMapping,
    mapping: &MappingSpec,
) -> Result<Vec<Value>, String> {
    match row {
        ParsedRow::Keyed(map) => {
            if !resolved.keyed {
                return Err("文件记录是字典格式（带列名），但列映射使用的是位置序号".to_string());
            }
            let mut values = Vec::with_capacity(resolved.sources.len());
            for (i, source) in resolved.sources.iter().enumerate() {
                let Some(key) = source.as_str() else {
                    return Err("列映射来源类型错误".to_string());
                };
                let column = &resolved.columns[i];
                match map.get(key) {
                    Some(raw) => values.push(convert_value(raw.clone(), column, mapping)?),
                    None if column.nullable || column.auto_increment => {
                        values.push(Value::Null)
                    }
                    None => {
                        return Err(format!(
                            "缺少字段 '{}'（目标列 '{}' 不允许 NULL）",
                            key, column.name
                        ))
                    }
                }
            }
            if !mapping.ignore_unknown {
                for key in map.keys() {
                    if !resolved.sources.iter().any(|s| s.as_str() == Some(key)) {
                        return Err(format!("记录多出未映射的字段 '{}'", key));
                    }
                }
            }
            Ok(values)
        }
        ParsedRow::Positional(fields) => {
            if resolved.keyed {
                return Err("文件记录没有列名（数组/分隔文本），但列映射使用的是列名".to_string());
            }
            // A SHORT record is not an error: an export may legitimately omit
            // trailing columns (older exporters did exactly that), so missing
            // positions are read as NULL. Only EXTRA fields are reported - they
            // mean the rule split the record differently than the mapping
            // expects, and silently dropping them would lose data.
            if fields.len() > resolved.sources.len() {
                return Err(format!(
                    "记录有 {} 个字段，但列映射只有 {} 列（字段数多于列映射）",
                    fields.len(),
                    resolved.sources.len()
                ));
            }
            let mut values = Vec::with_capacity(resolved.sources.len());
            for (i, source) in resolved.sources.iter().enumerate() {
                let Some(index) = source.as_u64() else {
                    return Err("列映射来源类型错误".to_string());
                };
                let index = index as usize;
                // Positions past the end of a short record are NULL (see above).
                let raw = fields.get(index).cloned().unwrap_or(Value::Null);
                values.push(convert_value(raw, &resolved.columns[i], mapping)?);
            }
            Ok(values)
        }
    }
}

/// Mapping sources repeated for two target columns cannot take ownership of a
/// cell (the second column would read an empty slot), so the execute path only
/// uses the moving conversion when every source appears once.
fn sources_are_unique(resolved: &ResolvedMapping) -> bool {
    for i in 0..resolved.sources.len() {
        for j in (i + 1)..resolved.sources.len() {
            if resolved.sources[i] == resolved.sources[j] {
                return false;
            }
        }
    }
    true
}

/// [`map_record`] that consumes the parsed row.
///
/// The INSERT path only needs the values once, so moving the parsed strings into
/// the converted values avoids the clone-per-cell the borrowed version needs.
fn map_record_owned(
    row: ParsedRow,
    resolved: &ResolvedMapping,
    mapping: &MappingSpec,
) -> Result<Vec<Value>, String> {
    match row {
        ParsedRow::Keyed(mut map) => {
            if !resolved.keyed {
                return Err("文件记录是字典格式（带列名），但列映射使用的是位置序号".to_string());
            }
            let mut values = Vec::with_capacity(resolved.sources.len());
            for (i, source) in resolved.sources.iter().enumerate() {
                let Some(key) = source.as_str() else {
                    return Err("列映射来源类型错误".to_string());
                };
                let column = &resolved.columns[i];
                match map.remove(key) {
                    Some(raw) => values.push(convert_value(raw, column, mapping)?),
                    None if column.nullable || column.auto_increment => {
                        values.push(Value::Null)
                    }
                    None => {
                        return Err(format!(
                            "缺少字段 '{}'（目标列 '{}' 不允许 NULL）",
                            key, column.name
                        ))
                    }
                }
            }
            if !mapping.ignore_unknown {
                for key in map.keys() {
                    if !resolved.sources.iter().any(|s| s.as_str() == Some(key)) {
                        return Err(format!("记录多出未映射的字段 '{}'", key));
                    }
                }
            }
            Ok(values)
        }
        ParsedRow::Positional(mut fields) => {
            if resolved.keyed {
                return Err("文件记录没有列名（数组/分隔文本），但列映射使用的是列名".to_string());
            }
            if fields.len() > resolved.sources.len() {
                return Err(format!(
                    "记录有 {} 个字段，但列映射只有 {} 列（字段数多于列映射）",
                    fields.len(),
                    resolved.sources.len()
                ));
            }
            let mut values = Vec::with_capacity(resolved.sources.len());
            for (i, source) in resolved.sources.iter().enumerate() {
                let Some(index) = source.as_u64() else {
                    return Err("列映射来源类型错误".to_string());
                };
                let index = index as usize;
                let raw = if index < fields.len() {
                    std::mem::take(&mut fields[index])
                } else {
                    Value::Null
                };
                values.push(convert_value(raw, &resolved.columns[i], mapping)?);
            }
            Ok(values)
        }
    }
}

/// Move-or-clone dispatch used by the execute loop.
fn map_parsed_owned(
    row: ParsedRow,
    resolved: &ResolvedMapping,
    mapping: &MappingSpec,
    sources_unique: bool,
) -> Result<Vec<Value>, String> {
    if sources_unique {
        map_record_owned(row, resolved, mapping)
    } else {
        map_record(&row, resolved, mapping)
    }
}

/// Header→position translation computed once per import.
///
/// A delimited file with a header and a name-based mapping used to rebuild a
/// `Map<String, Value>` (with cloned header keys and cloned cell values) for
/// every row, then look the mapped names up by hash. The header is constant, so
/// the positions are computed once and the row path stays positional.
struct HeaderPlan {
    /// For every mapped target column: index into the positional record fields,
    /// or `None` when the mapped source name does not occur in the header.
    positions: Vec<Option<usize>>,
    /// First header column that is not mapped, when `ignore_unknown = false`.
    extra_field: Option<String>,
    header_len: usize,
}

impl HeaderPlan {
    fn new(header: &[String], resolved: &ResolvedMapping, mapping: &MappingSpec) -> Self {
        let positions = resolved
            .sources
            .iter()
            .map(|source| {
                source
                    .as_str()
                    .and_then(|name| header.iter().position(|column| column == name))
            })
            .collect();
        let extra_field = if mapping.ignore_unknown {
            None
        } else {
            header
                .iter()
                .find(|name| {
                    !resolved
                        .sources
                        .iter()
                        .any(|source| source.as_str() == Some(name.as_str()))
                })
                .cloned()
        };
        Self {
            positions,
            extra_field,
            header_len: header.len(),
        }
    }
}

/// Convert one positional record using the pre-computed header plan.
fn map_header_record(
    mut fields: Vec<Value>,
    plan: &HeaderPlan,
    resolved: &ResolvedMapping,
    mapping: &MappingSpec,
) -> Result<Vec<Value>, String> {
    if fields.len() > plan.header_len {
        return Err(format!(
            "记录有 {} 个字段，表头只有 {} 列",
            fields.len(),
            plan.header_len
        ));
    }
    let mut values = Vec::with_capacity(resolved.sources.len());
    for (i, position) in plan.positions.iter().enumerate() {
        let column = &resolved.columns[i];
        match position {
            Some(index) => {
                let raw = if *index < fields.len() {
                    std::mem::take(&mut fields[*index])
                } else {
                    Value::Null
                };
                values.push(convert_value(raw, column, mapping)?);
            }
            None => {
                let key = resolved.sources[i].as_str().unwrap_or("");
                if column.nullable || column.auto_increment {
                    values.push(Value::Null);
                } else {
                    return Err(format!(
                        "缺少字段 '{}'（目标列 '{}' 不允许 NULL）",
                        key, column.name
                    ));
                }
            }
        }
    }
    if let Some(name) = &plan.extra_field {
        return Err(format!("记录多出未映射的字段 '{}'", name));
    }
    Ok(values)
}

/// Build the column list for INSERT from a resolved mapping.
pub fn mapping_column_names(resolved: &ResolvedMapping) -> Vec<String> {
    resolved.columns.iter().map(|c| c.name.clone()).collect()
}

/// Render one multi-row INSERT statement.
pub fn build_insert_sql(
    driver: DriverKind,
    database: &str,
    table: &str,
    columns: &[String],
    rows: &[Vec<Value>],
) -> String {
    let mut sql = String::with_capacity(rows.len() * 48 + columns.len() * 8 + 32);
    push_insert_header(&mut sql, driver, database, table, columns);
    push_insert_rows(&mut sql, driver, rows.iter().map(|row| row.as_slice()));
    sql
}

/// Full INSERT of one row, used by the probe ("试插入") dialog.
pub fn build_single_insert_sql(
    driver: DriverKind,
    database: &str,
    table: &str,
    columns: &[String],
    values: &[Value],
) -> String {
    let mut sql = String::with_capacity(columns.len() * 8 + 64);
    push_insert_header(&mut sql, driver, database, table, columns);
    push_insert_rows(&mut sql, driver, std::iter::once(values));
    sql
}

/// Write the shared `INSERT INTO <target> (<columns>) VALUES ` head.
///
/// The importer renders this once and appends every batch to it; the old code
/// rebuilt the target/column list for every statement.
fn push_insert_header(
    out: &mut String,
    driver: DriverKind,
    database: &str,
    table: &str,
    columns: &[String],
) {
    out.push_str("INSERT INTO ");
    out.push_str(&qualify(driver, database, table));
    out.push_str(" (");
    for (index, column) in columns.iter().enumerate() {
        if index > 0 {
            out.push_str(", ");
        }
        out.push_str(&qi(driver, column));
    }
    out.push_str(") VALUES ");
}

/// Append `(v1,v2),(v3,v4),...` for already-converted rows.
fn push_insert_rows<'a>(
    out: &mut String,
    driver: DriverKind,
    rows: impl IntoIterator<Item = &'a [Value]>,
) {
    let mut first = true;
    for row in rows {
        if !first {
            out.push(',');
        }
        first = false;
        out.push('(');
        for (index, value) in row.iter().enumerate() {
            if index > 0 {
                out.push(',');
            }
            push_literal(out, driver, value);
        }
        out.push(')');
    }
}

/// Upper bound of the SQL text [`literal`] renders for `value`.
///
/// Used only for the `MAX_BATCH_SQL_BYTES` cap. The old implementation called
/// `literal()` for every cell just to measure its length — ~10 M extra String
/// allocations for a 100 MB import. A type-based bound is enough here.
fn estimate_literal_len(value: &Value) -> usize {
    match value {
        Value::Null => 4,
        Value::Bool(_) => 5,
        Value::Number(_) => 32,
        // MySQL doubles backslashes as well as quotes, so `* 2 + 2` is a safe
        // upper bound for every dialect.
        Value::String(text) => text.len().saturating_mul(2) + 2,
        // Binary markers / JSON objects are rare on this path.
        other => other.to_string().len() + 2,
    }
}

/// [`literal`] without the per-cell `String` allocation.
///
/// The importer renders millions of cells; `literal()` returning a fresh String
/// per cell was a measurable part of the insert phase. Byte-for-byte identical
/// to `dbpilot_core::sql::literal` for the shapes the importer can produce
/// (a unit test pins the equivalence).
fn push_literal(out: &mut String, driver: DriverKind, value: &Value) {
    match value {
        Value::Null => out.push_str("NULL"),
        Value::Bool(true) => out.push_str(if matches!(driver, DriverKind::Postgres) {
            "TRUE"
        } else {
            "1"
        }),
        Value::Bool(false) => out.push_str(if matches!(driver, DriverKind::Postgres) {
            "FALSE"
        } else {
            "0"
        }),
        Value::Number(number) => {
            // `write!` renders exactly like `Number::to_string()` but reuses the
            // caller's buffer instead of allocating per cell.
            let _ = write!(out, "{number}");
        }
        Value::String(text) => push_quoted(out, driver, text),
        other => {
            // Objects (binary markers / JSON payloads) are rare here and need
            // the shared implementation; everything else stringifies first.
            out.push_str(&literal(driver, other));
        }
    }
}

/// Quote a string literal, mirroring `dbpilot_core::sql::quote_str_for`.
fn push_quoted(out: &mut String, driver: DriverKind, text: &str) {
    let mysql = driver.is_mysql();
    let needs_escape = text
        .as_bytes()
        .iter()
        .any(|&byte| byte == b'\'' || (mysql && byte == b'\\'));
    out.push('\'');
    if !needs_escape {
        // Nothing to double: UTF-8 can be copied verbatim.
        out.push_str(text);
    } else if mysql {
        for ch in text.chars() {
            match ch {
                '\\' => out.push_str("\\\\"),
                '\'' => out.push_str("''"),
                other => out.push(other),
            }
        }
    } else {
        for ch in text.chars() {
            if ch == '\'' {
                out.push('\'');
            }
            out.push(ch);
        }
    }
    out.push('\'');
}

// ---------------------------------------------------------------- inspection

#[derive(Clone, Debug)]
pub struct FileInfo {
    pub size: u64,
    pub name: String,
}

/// 无法流式读取的格式的大小上限：5 GiB（5×1024³ 字节）。
///
/// 能流式读的格式（CSV/JSON/Excel 全格式）只按行处理，大小不受这个限制；
/// 只有「必须整表载入内存」的读取路径才受它约束——超过 5 GiB 直接拒绝，
/// 避免把一台机器的内存吃光。提醒文案同时会出现在 inspect 的 warnings 里。
pub const MAX_NON_STREAMING_BYTES: u64 = 5 * 1024 * 1024 * 1024;

/// 字节数 → 普通文件大小显示（1 位小数，1024 进制）。
pub fn format_size(bytes: u64) -> String {
    const KB: f64 = 1024.0;
    let value = bytes as f64;
    if value >= KB * KB * KB {
        format!("{:.1} GB", value / (KB * KB * KB))
    } else if value >= KB * KB {
        format!("{:.1} MB", value / (KB * KB))
    } else if value >= KB {
        format!("{:.1} KB", value / KB)
    } else {
        format!("{bytes} B")
    }
}

/// 字节数 → GiB（1 位小数）。5 GiB 护栏的文案统一用这个单位，
/// 避免同一句话里「5.0 GB」与「超过 5 GB」互相矛盾。
pub fn format_gib(bytes: u64) -> String {
    const GIB: f64 = 1024.0 * 1024.0 * 1024.0;
    format!("{:.1} GiB", bytes as f64 / GIB)
}

/// 单文件过大时的提醒（可流式读取也要提醒耗时与内存）。
fn large_file_warning(size: u64) -> Option<String> {
    if size <= MAX_NON_STREAMING_BYTES {
        return None;
    }
    Some(format!(
        "文件约 {}（超过 5 GiB，即 5×1024³ 字节）：会逐行流式读取，耗时与磁盘 IO 会明显增加；建议分批导入或先压缩无关列。超大工作簿的共享字符串表（SST）本身可能很大，内存峰值会明显上升；若是 .xls，建议先另存为 .xlsx 或拆分文件后再导入。",
        format_gib(size)
    ))
}

/// 超过 5 GiB 且该格式无法流式读取时的拒绝文案。
pub fn non_streaming_size_error(size: u64, format: &str) -> String {
    format!(
        "文件约 {}，超过 5 GiB（5×1024³ 字节）；{} 目前无法流式读取（需要整表载入内存），已拒绝导入。请拆分文件，或转换为 xlsx / CSV 后再试。",
        format_gib(size),
        format
    )
}

/// 大文件护栏：只对「超过 5 GiB 且必须整表载入」的文件报错。
///
/// 正常文件（≤ 5 GiB）零开销直接返回；超过 5 GiB 时也只用 file_info +
/// 格式识别这种轻量判定：格式是否流式是 ExcelKind 的**常量属性**，绝不能
/// 为了判断而解析工作簿（xls 会解析整个 SST、xlsx/xlsb 会整读
/// sharedStrings、ODS/SpreadsheetML 会全量扫描；preview/validate/execute
/// 各调用一次就等于把超大文件多读好几遍）。
pub fn ensure_large_file_streamable(path: &str) -> AppResult<()> {
    ensure_streamable_with_limit(path, MAX_NON_STREAMING_BYTES)
}

fn ensure_streamable_with_limit(path: &str, limit: u64) -> AppResult<()> {
    let info = file_info(path)?;
    if info.size <= limit {
        return Ok(());
    }
    if let Some(kind) = crate::excel_import::detect(path)? {
        // 当前所有 Excel 格式都返回 true，因此这条拒绝分支实际不可达；
        // 保留它是给将来的非流式格式留口，判断依据仍然是常量而非内容解析。
        if !kind.is_streaming() {
            return Err(AppError::bad(non_streaming_size_error(
                info.size,
                kind.format(),
            )));
        }
    }
    Ok(())
}

pub fn file_info(path: &str) -> AppResult<FileInfo> {
    let path = path.trim();
    if path.is_empty() {
        return Err(AppError::bad("请选择文件"));
    }
    // 路径错误（不存在 / 没权限）是最常见的失败之一：主文案用中文说清下一步，
    // 括号里保留 OS 原文（英文）方便排查，而不是把 std::io 的错误直接抛给用户。
    let meta = std::fs::metadata(path).map_err(|error| {
        let detail = error.to_string();
        match error.kind() {
            std::io::ErrorKind::NotFound => AppError::bad(format!(
                "文件不存在或无法访问：{path}（{detail}）"
            )),
            std::io::ErrorKind::PermissionDenied => AppError::bad(format!(
                "没有权限读取文件：{path}（{detail}）"
            )),
            _ => AppError::bad(format!("无法读取文件：{path}（{detail}）")),
        }
    })?;
    if !meta.is_file() {
        return Err(AppError::bad("选择的路径不是文件"));
    }
    let name = std::path::Path::new(path)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| path.to_string());
    Ok(FileInfo {
        size: meta.len(),
        name,
    })
}

pub fn read_prefix(path: &str, max: usize) -> AppResult<Vec<u8>> {
    let mut file = File::open(path).map_err(|e| AppError::bad(format!("无法打开文件: {e}")))?;
    let mut buf = vec![0u8; max.min(16 * 1024 * 1024)];
    let n = file
        .read(&mut buf)
        .map_err(|e| AppError::bad(format!("读取文件失败: {e}")))?;
    buf.truncate(n);
    Ok(buf)
}

pub fn read_suffix(path: &str, max: usize) -> AppResult<Vec<u8>> {
    let mut file = File::open(path).map_err(|e| AppError::bad(format!("无法打开文件: {e}")))?;
    let size = file
        .seek(SeekFrom::End(0))
        .map_err(|e| AppError::bad(format!("读取文件失败: {e}")))?;
    let take = (max as u64).min(size) as usize;
    file.seek(SeekFrom::Start(size - take as u64))
        .map_err(|e| AppError::bad(format!("读取文件失败: {e}")))?;
    let mut buf = vec![0u8; take];
    let n = file
        .read(&mut buf)
        .map_err(|e| AppError::bad(format!("读取文件失败: {e}")))?;
    buf.truncate(n);
    Ok(buf)
}

/// Inspect a data file and suggest a read/field rule.
///
/// Excel 系格式先按文件内容识别（ZIP/OLE2 魔数优先于扩展名），再走工作簿分支：
/// 返回 sheets / sheet / read.sheet / read.skip_rows / fields.mode = "excel"；
/// 其余文本格式保持原来的检测顺序。
pub fn inspect(path: &str) -> AppResult<Value> {
    let info = file_info(path)?;
    let head = read_prefix(path, 16 * 1024)?;
    let tail = read_suffix(path, 8 * 1024)?;
    let (bom, encoding) = detect_bom(&head);
    let mut warnings: Vec<String> = Vec::new();
    if let Some(warning) = large_file_warning(info.size) {
        warnings.push(warning);
    }

    // 内容优先：xlsx/xls/xlsb/ods/SpreadsheetML 都是工作簿，走上表分支。
    if let Some(kind) = crate::excel_import::detect(path)? {
        return inspect_excel(path, &info, kind, &head, &tail, bom, encoding, warnings);
    }

    if encoding == "utf-16le" || encoding == "utf-16be" {
        warnings.push("文件是 UTF-16 编码，暂不支持；请另存为 UTF-8".to_string());
    }
    let body = &head[bom.min(head.len())..];
    let head_str = String::from_utf8_lossy(body).to_string();
    let tail_str = String::from_utf8_lossy(&tail).to_string();
    if !body.is_empty() && std::str::from_utf8(body).is_err() {
        warnings.push(
            "文件开头不是 UTF-8 文本（可能是 GBK/GB18030），请在编辑器中另存为 UTF-8 后导入"
                .to_string(),
        );
    }

    let ext = std::path::Path::new(path)
        .extension()
        .map(|e| e.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();
    let trimmed = head_str
        .trim_start_matches('﻿')
        .trim_start()
        .to_string();
    let tail_trimmed = tail_str.trim_end().to_string();

    let mut read = ReadSpec::default();
    let mut fields = FieldSpec::default();
    let format: String;
    // The structural formats the exporter writes. Each one is recognised by
    // its extension OR by its own opening marker, because a file renamed to
    // .txt still has to import.
    // Excel (SpreadsheetML) is handled by excel_import above (content-first).
    if ext == "xml" || trimmed.starts_with("<?xml") || trimmed.starts_with("<rows") {
        format = "xml".to_string();
        fields.mode = "xml".to_string();
        read.mode = "wrapped".to_string();
        // The document opens with an <?xml?> prolog, so a literal wrapper PREFIX
        // cannot match, but </rows> is still needed as the terminator: without it
        // the closing tag would be read as one more record.
        read.wrapper_start = String::new();
        read.wrapper_end = "</rows>".to_string();
        read.record_sep = "</row>".to_string();
        // Quotes are irrelevant here; disabling them keeps <col name="x"> from
        // being mistaken for an unterminated string.
        read.quote = String::new();
        if !trimmed.contains("<rows") {
            warnings.push("文件里没有 <rows> 根元素，可能不是本应用导出的 XML".to_string());
        }
    } else if ext == "html" || ext == "htm" || trimmed.starts_with("<!doctype") || trimmed.starts_with("<table") {
        format = "html".to_string();
        fields.mode = "html".to_string();
        fields.header = true;
        read.mode = "wrapped".to_string();
        // The document opens with <!doctype html>, so the wrapper PREFIX cannot
        // match, but </tbody> terminates the row list.
        read.wrapper_start = String::new();
        read.wrapper_end = "</tbody>".to_string();
        read.record_sep = "</tr>".to_string();
        read.quote = String::new();
    } else if ext == "md" || ext == "markdown" || looks_like_markdown(&trimmed) {
        format = "markdown".to_string();
        fields.mode = "markdown".to_string();
        fields.header = true;
        read.mode = "line".to_string();
        read.quote = String::new();
    } else if matches!(ext.as_str(), "jsonl" | "ndjson" | "jsonlines") {
        format = "json_lines".to_string();
        fields.mode = "json".to_string();
    } else if ext == "csv" || ext == "tsv" || ext == "tab" || ext == "txt" || ext.is_empty() {
        format = "delimited".to_string();
        detect_delimited(&trimmed, &ext, &mut fields);
    } else if ext == "json" || trimmed.starts_with('[') || trimmed.starts_with('{') {
        if trimmed.starts_with('[') {
            format = "json_array".to_string();
            read.mode = "wrapped".to_string();
            read.wrapper_start = "[".to_string();
            read.wrapper_end = "]".to_string();
            read.record_sep = ",".to_string();
            fields.mode = "json".to_string();
            if !tail_trimmed.ends_with(']') {
                warnings.push("文件结尾不是 ']'，JSON 数组可能不完整".to_string());
            }
        } else if ext == "json" || trimmed.starts_with('{') {
            format = "json_lines".to_string();
            fields.mode = "json".to_string();
            warnings.push(
                "每行一个 JSON 记录才能按行导入；若整个文件是一个多行 JSON 对象，请改用其他工具"
                    .to_string(),
            );
        } else {
            format = "delimited".to_string();
            detect_delimited(&trimmed, &ext, &mut fields);
        }
    } else {
        format = "delimited".to_string();
        detect_delimited(&trimmed, &ext, &mut fields);
    }

    Ok(json!({
        "path": path,
        "name": info.name,
        "size": info.size,
        "encoding": encoding,
        "format": format,
        "read": read,
        "fields": fields,
        "head": snippet_keep(&head_str, 4000),
        "tail": snippet_keep(&tail_str, 2000),
        "warnings": warnings,
    }))
}

/// Excel 系文件的 inspect：用流式元数据读取列出工作表、给出默认 read/fields。
///
/// 不再整表载入：xlsx 只读 workbook.xml + rels + 每表 dimension + 默认表前两行；
/// SpreadsheetML / ODS 单次顺序扫描统计表名/行数/列数（不保存单元格）；
/// xls（BIFF8）走 Record 级流式、xlsb 走 Row 级流式（见 excel_stream::inspect_workbook）。
fn inspect_excel(
    path: &str,
    info: &FileInfo,
    kind: crate::excel_import::ExcelKind,
    head: &[u8],
    tail: &[u8],
    bom: usize,
    encoding: &'static str,
    mut warnings: Vec<String>,
) -> AppResult<Value> {
    let mut inspected = crate::excel_stream::inspect_workbook(path, kind)?;
    if !inspected.streaming && info.size > MAX_NON_STREAMING_BYTES {
        return Err(AppError::bad(non_streaming_size_error(
            info.size,
            kind.format(),
        )));
    }
    warnings.append(&mut inspected.warnings);
    if inspected.sheets.len() > 1 {
        warnings.push(format!(
            "检测到 {} 个工作表：当前导入所选工作表；一次导入多个工作表请用「从文件建表」",
            inspected.sheets.len()
        ));
    }
    if inspected.hidden_sheets > 0 {
        warnings.push(format!("已忽略 {} 个隐藏工作表", inspected.hidden_sheets));
    }

    // 表头启发式与 CSV 一致：首行全是非空文本且至少还有一行数据。
    let header = inspected.header_rows.len() > 1
        && inspected.header_rows[0]
            .iter()
            .all(|value| matches!(value, Value::String(text) if !text.trim().is_empty()));

    let mut read = ReadSpec::default();
    read.mode = "line".to_string();
    read.sheet = Some(inspected.sheet.clone());
    read.skip_rows = 0;
    let mut fields = FieldSpec::default();
    fields.mode = "excel".to_string();
    fields.header = header;

    // 二进制工作簿没有可读文本预览；SpreadsheetML 仍是 XML 文本。
    let (head_text, tail_text, encoding) = if kind.is_binary() {
        (String::new(), String::new(), "binary")
    } else {
        (
            snippet_keep(&String::from_utf8_lossy(&head[bom.min(head.len())..]), 4000),
            snippet_keep(&String::from_utf8_lossy(tail), 2000),
            encoding,
        )
    };

    Ok(json!({
        "path": path,
        "name": info.name,
        "size": info.size,
        "encoding": encoding,
        "format": kind.format(),
        "read": read,
        "fields": fields,
        "sheets": inspected.sheets_json(),
        "sheet": inspected.sheet,
        "streaming": inspected.streaming,
        "head": head_text,
        "tail": tail_text,
        "warnings": warnings,
    }))
}


/// First line starts with `|` and the second is a `| --- |` rule.
fn looks_like_markdown(text: &str) -> bool {
    let mut lines = text.lines().filter(|l| !l.trim().is_empty());
    let first = lines.next().unwrap_or("");
    let second = lines.next().unwrap_or("");
    first.trim_start().starts_with('|') && is_markdown_rule(second)
}

fn detect_delimited(text: &str, ext: &str, fields: &mut FieldSpec) {
    fields.mode = "delimited".to_string();
    let first = text.lines().next().unwrap_or("");
    let tabs = first.matches('\t').count();
    let commas = first.matches(',').count();
    let semis = first.matches(';').count();
    let pipes = first.matches('|').count();
    let sep = if ext == "tsv" || ext == "tab" || (tabs > 0 && tabs >= commas) {
        "\t"
    } else if commas > 0 {
        ","
    } else if semis > commas {
        ";"
    } else if pipes > commas {
        "|"
    } else {
        ","
    };
    fields.field_sep = sep.to_string();
    fields.quote = "\"".to_string();
    fields.trim = true;
    // Header heuristic: the first record has the same field count as the
    // second and consists of non-numeric labels.
    if let Some(second) = text.lines().nth(1) {
        let first_fields = split_fields(first, sep, "\"", "", true).unwrap_or_default();
        let second_fields = split_fields(second, sep, "\"", "", true).unwrap_or_default();
        let first_all_text = first_fields
            .iter()
            .all(|v| v.parse::<f64>().is_err());
        fields.header = !first_fields.is_empty()
            && first_fields.len() == second_fields.len()
            && first_all_text;
    }
}

fn snippet_keep(text: &str, max_chars: usize) -> String {
    let mut out: String = text.chars().take(max_chars).collect();
    if text.chars().count() > max_chars {
        out.push('…');
    }
    out
}

// ---------------------------------------------------------------- preview

/// Collect one parsed data row for the schema inference sample.
///
/// Keyed records (XML / JSON) have no header record in the wizard's sense, so
/// the key order of the first row becomes the column order; when a header was
/// parsed, the row is reordered to that header so values stay aligned.
fn push_schema_row(
    keys: &mut Option<Vec<String>>,
    rows: &mut Vec<Vec<Value>>,
    header: Option<&[String]>,
    row: ParsedRow,
) {
    match row {
        ParsedRow::Positional(values) => rows.push(mark_null_tokens(values)),
        ParsedRow::Keyed(map) => {
            if let Some(header) = header {
                rows.push(
                    header
                        .iter()
                        .map(|key| mark_null_token(map.get(key).cloned().unwrap_or(Value::Null)))
                        .collect(),
                );
                return;
            }
            if keys.is_none() {
                *keys = Some(map.keys().cloned().collect());
            }
            let ordered = keys.as_ref().expect("keys set above");
            rows.push(
                ordered
                    .iter()
                    .map(|key| mark_null_token(map.get(key).cloned().unwrap_or(Value::Null)))
                    .collect(),
            );
        }
    }
}

/// Read a few records and parse them so the wizard can echo back exactly how
/// the current rule splits the file.
///
/// Besides the echoed records this samples up to SCHEMA_SAMPLE_ROWS data rows
/// (header excluded) and returns the inferred schema used by the "create tables
/// from file" wizard. The echo itself is still capped by the limit argument.
pub fn preview(spec: &ParseSpec, limit: usize) -> AppResult<Value> {
    ensure_large_file_streamable(&spec.path)?;
    let info = file_info(&spec.path)?;
    let limit = limit.clamp(1, MAX_PREVIEW_RECORDS);
    let mut scanner = RecordScanner::open(spec)?;
    let mut records: Vec<Value> = Vec::new();
    let mut issues: Vec<Value> = Vec::new();
    let mut header: Option<Vec<String>> = None;
    let mut header_done = !spec.fields.header || !is_header_mode(&spec.fields.mode);
    let mut read_bytes = 0u64;
    // 类型推断样本与回显分开：回显只看前 limit 条，schema 最多扫 1000 行。
    let mut schema_rows: Vec<Vec<Value>> = Vec::new();
    let mut schema_keys: Option<Vec<String>> = None;
    while records.len() < limit {
        match scanner.next()? {
            None => break,
            Some(ScanItem::Problem(problem)) => {
                issues.push(issue_json(
                    records.len() as u64,
                    problem.line,
                    problem.offset,
                    &problem.message,
                    "",
                ));
                if problem.fatal {
                    break;
                }
            }
            Some(ScanItem::Record(record)) => {
                read_bytes = record.offset;
                let mut item = json!({
                    "index": record.index,
                    "line": record.line,
                    "offset": record.offset,
                    "text": snippet_keep(&record.text, 4000),
                    "text_truncated": record.text.chars().count() > 4000,
                });
                if !header_done {
                    header_done = true;
                    match header_of(&record.text, &spec.fields) {
                        Ok(names) => {
                            item["header"] = json!(true);
                            item["values"] = json!(names.clone());
                            item["field_count"] = json!(names.len());
                            header = Some(names);
                            records.push(item);
                            continue;
                        }
                        Err(message) => {
                            item["error"] = json!(message.clone());
                            issues.push(issue_json(
                                record.index,
                                record.line,
                                record.offset,
                                &format!("表头解析失败: {message}"),
                                &record.text,
                            ));
                            records.push(item);
                            continue;
                        }
                    }
                }
                match parse_row(&record.text, &spec.fields) {
                    Ok(ParsedRow::Keyed(map)) => {
                        let keys: Vec<String> = map.keys().cloned().collect();
                        item["kind"] = json!("object");
                        item["field_count"] = json!(map.len());
                        item["keys"] = json!(keys);
                        let mut marked = Map::new();
                        for (k, v) in map {
                            marked.insert(k, mark_null_token(v));
                        }
                        item["values"] = json!(marked.clone());
                        push_schema_row(
                            &mut schema_keys,
                            &mut schema_rows,
                            header.as_deref(),
                            ParsedRow::Keyed(marked),
                        );
                    }
                    Ok(ParsedRow::Positional(values)) => {
                        item["kind"] = json!("array");
                        item["field_count"] = json!(values.len());
                        let marked = mark_null_tokens(values);
                        item["values"] = json!(marked.clone());
                        schema_rows.push(marked);
                    }
                    Err(message) => {
                        item["error"] = json!(message.clone());
                        let mut with_snippet = issue_json(
                            record.index,
                            record.line,
                            record.offset,
                            &message,
                            &record.text,
                        );
                        with_snippet["snippet"] = json!(snippet(&record.text, 120));
                        issues.push(with_snippet);
                    }
                }
                records.push(item);
            }
        }
    }
    // 继续扫到 1000 行数据，只用于 schema，不进入回显。
    while schema_rows.len() < crate::excel_import::SCHEMA_SAMPLE_ROWS {
        match scanner.next()? {
            None => break,
            Some(ScanItem::Problem(problem)) => {
                if issues.len() < DEFAULT_MAX_ISSUES {
                    issues.push(issue_json(
                        records.len() as u64,
                        problem.line,
                        problem.offset,
                        &problem.message,
                        "",
                    ));
                }
                if problem.fatal {
                    break;
                }
            }
            Some(ScanItem::Record(record)) => match parse_row(&record.text, &spec.fields) {
                Ok(row) => push_schema_row(
                    &mut schema_keys,
                    &mut schema_rows,
                    header.as_deref(),
                    row,
                ),
                Err(message) => {
                    if issues.len() < DEFAULT_MAX_ISSUES {
                        issues.push(issue_json(
                            record.index,
                            record.line,
                            record.offset,
                            &message,
                            &record.text,
                        ));
                    }
                }
            },
        }
    }
    let schema_header = header.clone().or(schema_keys);
    let schema = crate::excel_import::infer_schema(
        schema_header.as_deref(),
        &schema_rows,
        crate::excel_import::SCHEMA_SAMPLE_ROWS,
    );
    let (sheet_used, sheets, streaming, stream_warnings) = match scanner.excel_meta() {
        Some(meta) => (
            json!(meta.sheet),
            json!(meta.sheets),
            meta.streaming,
            meta.warnings.clone(),
        ),
        None => (Value::Null, Value::Null, true, Vec::new()),
    };
    Ok(json!({
        "path": spec.path,
        "size": info.size,
        "records": records,
        "header": header,
        "issues": issues,
        "read_bytes": read_bytes,
        "sheet_used": sheet_used,
        "sheets": sheets,
        "streaming": streaming,
        "warnings": stream_warnings,
        "schema": schema,
    }))
}

fn issue_json(index: u64, line: u64, offset: u64, message: &str, text: &str) -> Value {
    json!({
        "index": index,
        "line": line,
        "offset": offset,
        "message": message,
        "snippet": snippet(text, 120),
    })
}

/// Parse the first data record and convert it with the configured mapping.
///
/// Used by the "试插入" step: the returned values are inserted inside a rolled
/// back transaction so the UI can show the exact effect without modifying data.
pub fn probe_first_row(spec: &ValidateSpec, table_columns: &[TableColumn]) -> AppResult<Value> {
    ensure_large_file_streamable(&spec.parse.path)?;
    let mapping = spec
        .mapping
        .as_ref()
        .ok_or_else(|| AppError::bad("请先设置列映射"))?;
    let resolved = resolve_mapping(mapping, table_columns)?;
    let mut scanner = RecordScanner::open(&spec.parse)?;
    let mut header: Option<Vec<String>> = None;
    let mut header_pending = spec.parse.fields.header && is_header_mode(&spec.parse.fields.mode);
    loop {
        match scanner.next()? {
            None => return Err(AppError::bad("文件中没有可导入的数据记录")),
            Some(ScanItem::Problem(problem)) => {
                return Err(AppError::bad(format!(
                    "第 {} 行（字节 {}）: {}",
                    problem.line, problem.offset, problem.message
                )))
            }
            Some(ScanItem::Record(record)) => {
                let parsed = if header_pending {
                    header_pending = false;
                    match header_of(&record.text, &spec.parse.fields) {
                        Ok(names) => {
                            header = Some(names);
                            continue;
                        }
                        Err(message) => return Err(AppError::bad(
                            format!("第 {} 行表头解析失败: {}", record.line, message)
                        )),
                    }
                } else {
                    parse_row(&record.text, &spec.parse.fields)
                };
                let row = match parsed {
                    Err(message) => {
                        return Err(AppError::bad(format!(
                            "第 {} 行记录解析失败: {}",
                            record.line, message
                        )))
                    }
                    Ok(row) => row,
                };
                let row = if let Some(header) = &header {
                    match row {
                        ParsedRow::Positional(values) => {
                            // Short rows pad with NULL; only extra fields are an
                            // error (see resolve_mapping for the reasoning).
                            if values.len() > header.len() {
                                return Err(AppError::bad(format!(
                                    "第 {} 行有 {} 个字段，表头只有 {} 列",
                                    record.line,
                                    values.len(),
                                    header.len()
                                )));
                            }
                            let mut map = Map::new();
                            for (i, name) in header.iter().enumerate() {
                                map.insert(
                                    name.clone(),
                                    values.get(i).cloned().unwrap_or(Value::Null),
                                );
                            }
                            ParsedRow::Keyed(map)
                        }
                        keyed => keyed,
                    }
                } else {
                    row
                };
                let values = map_record(&row, &resolved, mapping)
                    .map_err(|e| AppError::bad(format!("第 {} 行: {}", record.line, e)))?;
                return Ok(json!({
                    "record": {
                        "index": record.index,
                        "line": record.line,
                        "offset": record.offset,
                        "text": snippet(&record.text, 200),
                    },
                    "header": header,
                    "preview": match row {
                        ParsedRow::Keyed(map) => json!({"kind": "object", "values": map}),
                        ParsedRow::Positional(values) => json!({"kind": "array", "values": values}),
                    },
                    "columns": mapping_column_names(&resolved),
                    "values": values,
                }));
            }
        }
    }
}

// ---------------------------------------------------------------- validation

/// Validate the whole file against the read/field rules (and, when a mapping is
/// supplied, the mapping + type conversion).
///
/// Returns immediately on a fatal structural problem; per-record failures are
/// counted and the first max_issues are returned with their position.
pub fn validate(
    spec: &ValidateSpec,
    table_columns: Option<&[TableColumn]>,
    max_issues: usize,
    total_bytes: u64,
    progress: &(dyn Fn(&Progress) + Sync),
    cancel: &AtomicBool,
) -> AppResult<Value> {
    let started = Instant::now();
    ensure_large_file_streamable(&spec.parse.path)?;
    let max_issues = max_issues.clamp(1, 1_000);
    let mut resolved = None;
    if let Some(mapping) = &spec.mapping {
        let columns = table_columns.ok_or_else(|| AppError::bad("校验列映射需要目标表结构"))?;
        resolved = Some(resolve_mapping(mapping, columns)?);
    }
    let mut scanner = RecordScanner::open(&spec.parse)?;
    let mut issues: Vec<Value> = Vec::new();
    let mut progress_state = Progress {
        phase: "validating".to_string(),
        total_bytes,
        ..Default::default()
    };
    let mut bytes_read = 0u64;
    let mut records = 0u64;
    let mut data_records = 0u64;
    let mut valid = 0u64;
    let mut invalid = 0u64;
    let mut fatal = false;
    let mut header: Option<Vec<String>> = None;
    let mut header_pending = spec.parse.fields.header && is_header_mode(&spec.parse.fields.mode);
    let mut cancelled = false;

    loop {
        if cancel.load(Ordering::Relaxed) {
            cancelled = true;
            break;
        }
        let item = match scanner.next()? {
            None => break,
            Some(item) => item,
        };
        match item {
            ScanItem::Problem(problem) => {
                if issues.len() < max_issues {
                    issues.push(issue_json(
                        records,
                        problem.line,
                        problem.offset,
                        &problem.message,
                        "",
                    ));
                }
                if problem.fatal {
                    fatal = true;
                    break;
                }
                invalid += 1;
            }
            ScanItem::Record(record) => {
                records += 1;
                bytes_read = record.offset.max(bytes_read);
                let parsed = if header_pending {
                    header_pending = false;
                    match header_of(&record.text, &spec.parse.fields) {
                        Ok(names) => {
                            header = Some(names);
                            progress_state.records = records;
                            progress_state.bytes = bytes_read;
                            progress_state.refresh(started);
                            if let Some(excel) = scanner.excel_progress() {
                                apply_excel_progress(
                                    &mut progress_state,
                                    &excel,
                                    total_bytes,
                                    started,
                                );
                            }
                            progress(&progress_state);
                            continue;
                        }
                        Err(message) => Err(format!("表头解析失败: {}", message)),
                    }
                } else {
                    parse_row(&record.text, &spec.parse.fields)
                };
                let result: Result<(), String> = match parsed {
                    Err(message) => Err(message),
                    Ok(row) => {
                        let row = if let Some(header) = &header {
                            match row {
                                ParsedRow::Positional(values) => {
                                    if values.len() > header.len() {
                                        Err(format!(
                                            "记录有 {} 个字段，表头只有 {} 列",
                                            values.len(),
                                            header.len()
                                        ))
                                    } else {
                                        let mut map = Map::new();
                                        for (i, name) in header.iter().enumerate() {
                                            map.insert(
                                                name.clone(),
                                                values.get(i).cloned().unwrap_or(Value::Null),
                                            );
                                        }
                                        Ok(ParsedRow::Keyed(map))
                                    }
                                }
                                keyed => Ok(keyed),
                            }
                        } else {
                            Ok(row)
                        };
                        match row {
                            Ok(row) => match (&resolved, &spec.mapping) {
                                (Some(resolved), Some(mapping)) => {
                                    map_record(&row, resolved, mapping).map(|_| ())
                                }
                                _ => Ok(()),
                            },
                            Err(message) => Err(message),
                        }
                    }
                };
                match result {
                    Ok(()) => valid += 1,
                    Err(message) => {
                        invalid += 1;
                        if issues.len() < max_issues {
                            let mut issue = issue_json(
                                record.index,
                                record.line,
                                record.offset,
                                &message,
                                &record.text,
                            );
                            issue["snippet"] = json!(snippet(&record.text, 120));
                            issues.push(issue);
                        }
                    }
                }
                data_records += 1;
            }
        }
        progress_state.bytes = bytes_read;
        progress_state.records = records;
        progress_state.rows = data_records;
        progress_state.failed = invalid;
        progress_state.refresh(started);
        if let Some(excel) = scanner.excel_progress() {
            apply_excel_progress(&mut progress_state, &excel, total_bytes, started);
        }
        progress(&progress_state);
    }
    if !fatal && !cancelled && bytes_read < total_bytes {
        bytes_read = total_bytes;
    }
    progress_state.bytes = bytes_read;
    progress_state.phase = "done".to_string();
    progress_state.records = records;
    progress_state.rows = data_records;
    progress_state.failed = invalid;
    progress_state.refresh(started);
    if let Some(excel) = scanner.excel_progress() {
        apply_excel_progress(&mut progress_state, &excel, total_bytes, started);
    }
    progress(&progress_state);

    Ok(json!({
        "ok": !fatal && invalid == 0,
        "cancelled": cancelled,
        "fatal": fatal,
        "bytes": bytes_read,
        "total_bytes": total_bytes,
        "records": records,
        "data_records": data_records,
        "valid": valid,
        "invalid": invalid,
        "issues": issues,
        "header": header,
        "elapsed_ms": started.elapsed().as_millis() as u64,
    }))
}

// ------------------------------------------------ fast delimited CSV execute
//
// P0 (round 65): the generic execute loop materialises one `String` per record,
// one `String` per field, and a `Vec<Value>` per row before rendering the SQL.
// For the common delimited/CSV shape we instead stream records into a reusable
// byte buffer, split unquoted records into byte ranges, convert each field
// straight into the reusable INSERT buffer, and keep only a byte span per row
// (needed for the rare skip-errors single-row retry).  Quoted records keep the
// existing `split_fields` implementation so all quoting/escaping semantics stay
// byte-for-byte identical; other formats stay on the generic path.

/// Allocate a cleaned numeric string only when the raw field actually contains
/// thousands separators.  The old code always ran `str::replace`, creating one
/// temporary String per numeric cell even for the common "1234.56" case.
fn cleaned_numeric(text: &str) -> std::borrow::Cow<'_, str> {
    if text.as_bytes().iter().any(|byte| *byte == b',' || *byte == b'_') {
        std::borrow::Cow::Owned(text.replace([',', '_'], ""))
    } else {
        std::borrow::Cow::Borrowed(text)
    }
}

fn push_bool_literal(out: &mut String, driver: DriverKind, value: bool) {
    if matches!(driver, DriverKind::Postgres) {
        out.push_str(if value { "TRUE" } else { "FALSE" });
    } else {
        out.push_str(if value { "1" } else { "0" });
    }
}

/// Convert one raw text field exactly like `convert_value(Value::String) +
/// push_literal`, appending the SQL literal directly to `out`.
fn append_field_sql(
    out: &mut String,
    driver: DriverKind,
    raw: Option<&str>,
    column: &TableColumn,
    mapping: &MappingSpec,
) -> Result<(), String> {
    let Some(raw) = raw else {
        out.push_str("NULL");
        return Ok(());
    };
    let kind = column.kind();
    let text = if mapping.trim_values { raw.trim() } else { raw };
    if mapping
        .null_tokens
        .iter()
        .any(|token| token.as_str() == text)
    {
        out.push_str("NULL");
        return Ok(());
    }
    if text.is_empty() {
        if mapping.empty_as_null || !matches!(kind, ColumnKind::Text) {
            out.push_str("NULL");
        } else {
            push_quoted(out, driver, "");
        }
        return Ok(());
    }
    match kind {
        ColumnKind::Text => {
            push_quoted(out, driver, text);
            Ok(())
        }
        ColumnKind::Int => {
            let cleaned = cleaned_numeric(text);
            if let Ok(value) = cleaned.parse::<i64>() {
                let _ = write!(out, "{value}");
                return Ok(());
            }
            if let Ok(value) = cleaned.parse::<u64>() {
                let _ = write!(out, "{value}");
                return Ok(());
            }
            Err(format!(
                "列 '{}' 需要整数，但值是 '{}'",
                column.name,
                snippet(text, 40)
            ))
        }
        ColumnKind::Float => {
            let cleaned = cleaned_numeric(text);
            if cleaned.parse::<f64>().is_err() {
                return Err(format!(
                    "列 '{}' 需要数字，但值是 '{}'",
                    column.name,
                    snippet(text, 40)
                ));
            }
            // Keep the textual representation (the database parses decimals
            // without an f64 round-trip), quoted exactly like the old path.
            push_quoted(out, driver, &cleaned);
            Ok(())
        }
        ColumnKind::Bool => {
            let value = if text.eq_ignore_ascii_case("1")
                || text.eq_ignore_ascii_case("t")
                || text.eq_ignore_ascii_case("true")
                || text.eq_ignore_ascii_case("y")
                || text.eq_ignore_ascii_case("yes")
                || text.eq_ignore_ascii_case("on")
            {
                Some(true)
            } else if text.eq_ignore_ascii_case("0")
                || text.eq_ignore_ascii_case("f")
                || text.eq_ignore_ascii_case("false")
                || text.eq_ignore_ascii_case("n")
                || text.eq_ignore_ascii_case("no")
                || text.eq_ignore_ascii_case("off")
            {
                Some(false)
            } else {
                None
            };
            match value {
                Some(value) => {
                    push_bool_literal(out, driver, value);
                    Ok(())
                }
                None => {
                    // The error message historically shows the lower-cased value;
                    // only pay for that allocation on the error path.
                    let lowered = text.to_ascii_lowercase();
                    Err(format!(
                        "列 '{}' 需要布尔值（true/false/1/0），但值是 '{}'",
                        column.name,
                        snippet(&lowered, 40)
                    ))
                }
            }
        }
        ColumnKind::Date => {
            push_quoted(out, driver, text);
            Ok(())
        }
        ColumnKind::Json => {
            if serde_json::from_str::<Value>(text).is_err() {
                return Err(format!(
                    "列 '{}' 是 JSON 类型，但值是 '{}'，不是合法的 JSON 文本",
                    column.name,
                    snippet(text, 40)
                ));
            }
            push_quoted(out, driver, text);
            Ok(())
        }
        ColumnKind::Binary => Err(format!(
            "列 '{}' 是二进制/BLOB 类型，暂不支持从文本文件导入",
            column.name
        )),
    }
}

/// Field list for one delimited record: borrowed byte ranges (unquoted fast
/// path) or owned Strings (records containing the quote character).
enum RowFields<'a> {
    Ranges(&'a [(usize, usize)]),
    Owned(&'a [String]),
}

impl RowFields<'_> {
    fn len(&self) -> usize {
        match self {
            RowFields::Ranges(ranges) => ranges.len(),
            RowFields::Owned(fields) => fields.len(),
        }
    }

    fn get<'a>(&'a self, text: &'a str, index: usize) -> Option<&'a str> {
        match self {
            RowFields::Ranges(ranges) => ranges
                .get(index)
                .map(|(start, end)| &text[*start..*end]),
            RowFields::Owned(fields) => fields.get(index).map(|field| field.as_str()),
        }
    }
}

/// Prepared positional layout for one delimited import.
enum FastRowPlan {
    /// Header present + name-based mapping (the normal CSV-with-header case).
    Header(HeaderPlan),
    /// No header + positional mapping.
    Positional(Vec<usize>),
}

fn fast_delimited_eligible(spec: &ExecuteSpec, resolved: &ResolvedMapping) -> bool {
    let parse = &spec.validate.parse;
    std::env::var_os("DBPILOT_IMPORT_LEGACY").is_none()
        && parse.fields.mode == "delimited"
        && parse.read.mode != "wrapped"
        && parse.fields.header == resolved.keyed
        && !parse.fields.field_sep.is_empty()
        && (resolved.keyed || resolved.sources.iter().all(|source| source.as_u64().is_some()))
}

/// Convert one delimited record into the current INSERT row, appending the SQL
/// literal directly to `out`.  Returns the same errors as the generic
/// parse_row/map/convert pipeline.
fn fast_process_row(
    text: &str,
    fields: &RowFields<'_>,
    plan: &FastRowPlan,
    columns: &[TableColumn],
    resolved: &ResolvedMapping,
    mapping: &MappingSpec,
    driver: DriverKind,
    out: &mut String,
) -> Result<(), String> {
    match plan {
        FastRowPlan::Header(header_plan) => {
            if fields.len() > header_plan.header_len {
                return Err(format!(
                    "记录有 {} 个字段，表头只有 {} 列",
                    fields.len(),
                    header_plan.header_len
                ));
            }
            for (index, position) in header_plan.positions.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                let column = &columns[index];
                match position {
                    Some(field_index) => append_field_sql(
                        out,
                        driver,
                        fields.get(text, *field_index),
                        column,
                        mapping,
                    )?,
                    None => {
                        if column.nullable || column.auto_increment {
                            append_field_sql(out, driver, None, column, mapping)?;
                        } else {
                            let key = resolved.sources[index].as_str().unwrap_or("");
                            return Err(format!(
                                "缺少字段 '{}'（目标列 '{}' 不允许 NULL）",
                                key, column.name
                            ));
                        }
                    }
                }
            }
            if let Some(name) = &header_plan.extra_field {
                return Err(format!("记录多出未映射的字段 '{}'", name));
            }
            Ok(())
        }
        FastRowPlan::Positional(sources) => {
            if fields.len() > sources.len() {
                return Err(format!(
                    "记录有 {} 个字段，但列映射只有 {} 列（字段数多于列映射）",
                    fields.len(),
                    sources.len()
                ));
            }
            for (index, source) in sources.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                append_field_sql(
                    out,
                    driver,
                    fields.get(text, *source),
                    &columns[index],
                    mapping,
                )?;
            }
            Ok(())
        }
    }
}

struct FastBatchRow {
    span: std::ops::Range<usize>,
    index: u64,
    line: u64,
    offset: u64,
}

/// One complete batch queued for a grouped transaction (P1).
struct FastPendingBatch {
    sql: String,
    rows: Vec<FastBatchRow>,
}

#[allow(unused_assignments)]
async fn execute_delimited_fast(
    driver: &dyn crate::core::driver::DatabaseDriver,
    conn: &crate::core::connection::ConnectionHandle,
    spec: &ExecuteSpec,
    table_columns: &[TableColumn],
    total_bytes: u64,
    progress: &(dyn Fn(&Progress) + Sync),
    cancel: &AtomicBool,
) -> AppResult<Value> {
    let started = Instant::now();
    let mut db_ns: u128 = 0;
    let mut sql_bytes: u64 = 0;
    ensure_large_file_streamable(&spec.validate.parse.path)?;
    let mapping = spec
        .validate
        .mapping
        .as_ref()
        .ok_or_else(|| AppError::bad("请先设置列映射"))?;
    let resolved = resolve_mapping(mapping, table_columns)?;
    let columns = mapping_column_names(&resolved);
    let database = spec
        .validate
        .database
        .as_deref()
        .ok_or_else(|| AppError::bad("缺少目标数据库"))?;
    let table = spec
        .validate
        .table
        .as_deref()
        .ok_or_else(|| AppError::bad("缺少目标表"))?;
    let parse = &spec.validate.parse;
    let options = &spec.options;
    let batch_size = options.batch_size.clamp(1, MAX_BATCH_SIZE);
    let max_issues = options.max_issues.clamp(1, 1_000);
    let skip_errors = options.on_error == "skip";
    // P1: transaction grouping is opt-in and only used when per-batch isolation
    // is not required for diagnostics (on_error = "skip" keeps batch = 1).
    let transaction_batches = options.transaction_batches.clamp(1, 16);
    let group_enabled = transaction_batches > 1 && !skip_errors;
    let mut pending: Vec<FastPendingBatch> = Vec::new();

    let mut scanner = TextScanner::open(parse)?;
    let mut record_bytes: Vec<u8> = Vec::with_capacity(64 * 1024);
    let mut ranges: Vec<(usize, usize)> = Vec::with_capacity(64);

    let mut insert_prefix = String::new();
    push_insert_header(&mut insert_prefix, driver.kind(), database, table, &columns);
    let mut batch_sql = String::with_capacity(insert_prefix.len() + 256 * 1024);
    batch_sql.push_str(&insert_prefix);
    let mut batch_rows: Vec<FastBatchRow> = Vec::with_capacity(batch_size.min(4_096));
    let mut batch_bytes: usize = 0;

    let mut progress_state = Progress {
        phase: "importing".to_string(),
        total_bytes,
        ..Default::default()
    };
    let mut bytes_read = 0u64;
    let mut records = 0u64;
    let mut data_records = 0u64;
    let mut rows_inserted = 0u64;
    let mut rows_failed = 0u64;
    let mut batches = 0u64;
    let mut issues: Vec<Value> = Vec::new();
    let mut cancelled = false;
    let mut stopped = false;
    let mut stop_message = String::new();
    let mut last_progress = Instant::now();
    const PROGRESS_INTERVAL: std::time::Duration = std::time::Duration::from_millis(100);

    macro_rules! report_issue {
        ($index:expr, $line:expr, $offset:expr, $message:expr, $text:expr) => {{
            rows_failed += 1;
            if issues.len() < max_issues {
                let mut issue = issue_json($index, $line, $offset, $message, "");
                issue["snippet"] = json!(snippet($text, 120));
                issues.push(issue);
            }
        }};
    }

    // P1: optionally group several autocommit batches into one transaction.
    // The group is sent through `execute_transaction`; if it fails, it has been
    // rolled back as a unit, and the batches are replayed one by one so the
    // historical partial-import semantics (earlier batches stay, the failing
    // batch reports its own error) are preserved.
    macro_rules! flush_group {
        () => {{
            if !pending.is_empty() {
                let group_len = pending.len() as u64;
                let sqls: Vec<String> =
                    pending.iter().map(|batch| batch.sql.clone()).collect();
                let db_started = Instant::now();
                let result = conn.execute_transaction(sqls).await;
                db_ns += db_started.elapsed().as_nanos();
                batches += group_len;
                match result {
                    Ok(_) => {
                        for batch in &pending {
                            rows_inserted += batch.rows.len() as u64;
                        }
                    }
                    Err(_) => {
                        // Replay batch by batch: the failed transaction left
                        // nothing behind, and earlier batches must still commit
                        // exactly like the old autocommit path.
                        for batch in &pending {
                            sql_bytes += batch.sql.len() as u64;
                            let replay_started = Instant::now();
                            let replayed = conn.run_raw(&batch.sql).await;
                            db_ns += replay_started.elapsed().as_nanos();
                            match replayed.error {
                                Some(error) => {
                                    stopped = true;
                                    stop_message = format!("批量插入失败: {}", error);
                                    if issues.len() < max_issues {
                                        let row = &batch.rows[0];
                                        let mut issue = issue_json(
                                            row.index,
                                            row.line,
                                            row.offset,
                                            &stop_message,
                                            "",
                                        );
                                        issue["snippet"] = json!("");
                                        issues.push(issue);
                                    }
                                    break;
                                }
                                None => rows_inserted += batch.rows.len() as u64,
                            }
                        }
                    }
                }
                pending.clear();
            }
        }};
    }

    macro_rules! flush_batch {
        () => {{
            if !batch_rows.is_empty() {
                if group_enabled {
                    sql_bytes += batch_sql.len() as u64;
                    pending.push(FastPendingBatch {
                        sql: std::mem::take(&mut batch_sql),
                        rows: std::mem::take(&mut batch_rows),
                    });
                    batch_bytes = 0;
                    batch_sql.push_str(&insert_prefix);
                    if pending.len() >= transaction_batches {
                        flush_group!();
                    }
                } else {
                    batches += 1;
                    sql_bytes += batch_sql.len() as u64;
                    let db_started = Instant::now();
                    let result = conn.run_raw(&batch_sql).await;
                    db_ns += db_started.elapsed().as_nanos();
                    if let Some(error) = result.error {
                        if skip_errors {
                            // The batch rolled back as a unit (autocommit):
                            // replay it row by row to keep the historical
                            // per-row diagnostics.
                            for row in &batch_rows {
                                let mut single =
                                    String::with_capacity(insert_prefix.len() + row.span.len());
                                single.push_str(&insert_prefix);
                                single.push_str(&batch_sql[row.span.clone()]);
                                sql_bytes += single.len() as u64;
                                let single_started = Instant::now();
                                let single_result = conn.run_raw(&single).await;
                                db_ns += single_started.elapsed().as_nanos();
                                match single_result.error {
                                    Some(error) => {
                                        report_issue!(
                                            row.index,
                                            row.line,
                                            row.offset,
                                            &format!("插入失败: {}", error),
                                            ""
                                        );
                                    }
                                    None => rows_inserted += 1,
                                }
                            }
                        } else {
                            stopped = true;
                            stop_message = format!("批量插入失败: {}", error);
                            if issues.len() < max_issues {
                                let row = &batch_rows[0];
                                let mut issue = issue_json(
                                    row.index,
                                    row.line,
                                    row.offset,
                                    &stop_message,
                                    "",
                                );
                                issue["snippet"] = json!("");
                                issues.push(issue);
                            }
                        }
                    } else {
                        rows_inserted += batch_rows.len() as u64;
                    }
                    batch_rows.clear();
                    batch_bytes = 0;
                    batch_sql.clear();
                    batch_sql.push_str(&insert_prefix);
                }
            }
        }};
    }

    let mut header_pending = parse.fields.header;
    let mut header_failed = false;
    let mut plan: Option<FastRowPlan> = if header_pending {
        None
    } else if resolved.keyed {
        None
    } else {
        Some(FastRowPlan::Positional(
            resolved
                .sources
                .iter()
                .map(|source| source.as_u64().unwrap_or(0) as usize)
                .collect(),
        ))
    };

    loop {
        if cancel.load(Ordering::Relaxed) {
            cancelled = true;
            break;
        }
        let item = scanner.next_record_into(&mut record_bytes)?;
        match item {
            NextRecord::End => break,
            NextRecord::Problem(problem) => {
                if problem.fatal {
                    stopped = true;
                    stop_message = problem.message.clone();
                    report_issue!(
                        records,
                        problem.line,
                        problem.offset,
                        &problem.message,
                        ""
                    );
                    break;
                }
                report_issue!(
                    records,
                    problem.line,
                    problem.offset,
                    &problem.message,
                    ""
                );
                continue;
            }
            NextRecord::Record(meta) => {
                let text = match std::str::from_utf8(&record_bytes) {
                    Ok(text) => text,
                    Err(_) => {
                        return Err(AppError::Internal(
                            "record buffer is not valid UTF-8".to_string(),
                        ))
                    }
                };
                records += 1;
                bytes_read = meta.offset.max(bytes_read);
                if header_pending {
                    header_pending = false;
                    match header_of(text, &parse.fields) {
                        Ok(names) => {
                            if resolved.keyed {
                                plan = Some(FastRowPlan::Header(HeaderPlan::new(
                                    &names,
                                    &resolved,
                                    mapping,
                                )));
                            }
                            progress_state.records = records;
                            progress_state.bytes = bytes_read;
                            progress_state.refresh(started);
                            progress(&progress_state);
                            continue;
                        }
                        Err(message) => {
                            header_failed = true;
                            let message = format!("表头解析失败: {}", message);
                            report_issue!(meta.index, meta.line, meta.offset, &message, text);
                            if !skip_errors {
                                stopped = true;
                                stop_message = message;
                                break;
                            }
                            continue;
                        }
                    }
                }

                // Row delimiters live in the shared batch buffer; the per-row
                // span covers "(...)" only, so the skip-errors retry can send
                // the INSERT prefix followed by exactly that span.
                let segment_start = batch_sql.len();
                if !batch_rows.is_empty() {
                    batch_sql.push(',');
                }
                let row_start = batch_sql.len();
                batch_sql.push('(');
                let quote_char = parse.fields.quote.chars().next();
                let contains_quote = quote_char.map_or(false, |quote| text.contains(quote));
                let row_result: Result<(), String> = if let Some(plan) = plan.as_ref() {
                    if contains_quote {
                        match split_fields(
                            text,
                            &parse.fields.field_sep,
                            &parse.fields.quote,
                            &parse.fields.escape,
                            parse.fields.trim,
                        ) {
                            Ok(fields) => {
                                let row_fields = RowFields::Owned(&fields);
                                fast_process_row(
                                    text,
                                    &row_fields,
                                    plan,
                                    &resolved.columns,
                                    &resolved,
                                    mapping,
                                    driver.kind(),
                                    &mut batch_sql,
                                )
                            }
                            Err(message) => Err(message),
                        }
                    } else {
                        match split_fields_ranges(
                            text,
                            &parse.fields.field_sep,
                            parse.fields.trim,
                            &mut ranges,
                        ) {
                            Ok(()) => {
                                let row_fields = RowFields::Ranges(&ranges);
                                fast_process_row(
                                    text,
                                    &row_fields,
                                    plan,
                                    &resolved.columns,
                                    &resolved,
                                    mapping,
                                    driver.kind(),
                                    &mut batch_sql,
                                )
                            }
                            Err(message) => Err(message),
                        }
                    }
                } else {
                    debug_assert!(header_failed);
                    // The header failed, so the generic path kept `header = None`
                    // and every later positional row fails mapping as "keyed
                    // mapping vs positional record". Surface a parse error first
                    // when the row itself is malformed, like the generic path.
                    if contains_quote {
                        match split_fields(
                            text,
                            &parse.fields.field_sep,
                            &parse.fields.quote,
                            &parse.fields.escape,
                            parse.fields.trim,
                        ) {
                            Ok(_) => Err(
                                "文件记录没有列名（数组/分隔文本），但列映射使用的是列名"
                                    .to_string(),
                            ),
                            Err(message) => Err(message),
                        }
                    } else {
                        match split_fields_ranges(
                            text,
                            &parse.fields.field_sep,
                            parse.fields.trim,
                            &mut ranges,
                        ) {
                            Ok(()) => Err(
                                "文件记录没有列名（数组/分隔文本），但列映射使用的是列名"
                                    .to_string(),
                            ),
                            Err(message) => Err(message),
                        }
                    }
                };
                match row_result {
                    Err(message) => {
                        batch_sql.truncate(segment_start);
                        report_issue!(meta.index, meta.line, meta.offset, &message, text);
                        if !skip_errors {
                            stopped = true;
                            stop_message = message;
                            break;
                        }
                    }
                    Ok(()) => {
                        batch_sql.push(')');
                        data_records += 1;
                        let span = row_start..batch_sql.len();
                        batch_bytes += span.len();
                        batch_rows.push(FastBatchRow {
                            span,
                            index: meta.index,
                            line: meta.line,
                            offset: meta.offset,
                        });
                        if batch_rows.len() >= batch_size || batch_bytes >= MAX_BATCH_SQL_BYTES {
                            flush_batch!();
                            if stopped {
                                break;
                            }
                        }
                    }
                }
            }
        }
        if last_progress.elapsed() >= PROGRESS_INTERVAL {
            last_progress = Instant::now();
            progress_state.bytes = bytes_read;
            progress_state.records = records;
            progress_state.rows = rows_inserted;
            progress_state.failed = rows_failed;
            progress_state.refresh(started);
            progress(&progress_state);
        }
    }

    if !stopped && !cancelled {
        flush_batch!();
    }
    // Complete batches already queued for a grouped transaction must still be
    // committed when the run stops/cancels, matching the old per-batch commits.
    // (The current partially filled batch is intentionally not flushed, exactly
    // like the autocommit path.)
    flush_group!();
    if !cancelled && bytes_read < total_bytes {
        bytes_read = total_bytes;
    }
    progress_state.bytes = bytes_read;
    progress_state.phase = if cancelled {
        "cancelled".to_string()
    } else {
        "done".to_string()
    };
    progress_state.records = records;
    progress_state.rows = rows_inserted;
    progress_state.failed = rows_failed;
    progress_state.refresh(started);
    progress(&progress_state);

    Ok(json!({
        "ok": rows_failed == 0 && !stopped && !cancelled,
        "cancelled": cancelled,
        "stopped": stopped,
        "message": stop_message,
        "bytes": bytes_read,
        "total_bytes": total_bytes,
        "records": records,
        "data_records": data_records,
        "rows_inserted": rows_inserted,
        "rows_failed": rows_failed,
        "batches": batches,
        "issues": issues,
        "elapsed_ms": started.elapsed().as_millis() as u64,
        "timings": {
            "total_ms": started.elapsed().as_millis() as u64,
            "db_ms": (db_ns / 1_000_000) as u64,
            "non_db_ms": ((started.elapsed().as_nanos().saturating_sub(db_ns)) / 1_000_000) as u64,
            "sql_bytes": sql_bytes,
            "batches": batches,
            "batch_size": batch_size,
            "transaction_batches": transaction_batches,
        },
    }))
}

// ---------------------------------------------------------------- execution

/// Stream the file and INSERT it in batches.
///
/// Reading stays incremental and inserts are multi-row statements; rows that
/// fail conversion are reported with their position and either abort the run
/// (on_error = stop) or are skipped (skip). A failed batch is retried row by row
/// in skip mode so one bad row does not hide the rest.
#[allow(unused_assignments)]
pub async fn execute(
    driver: &dyn crate::core::driver::DatabaseDriver,
    conn: &crate::core::connection::ConnectionHandle,
    spec: &ExecuteSpec,
    table_columns: &[TableColumn],
    total_bytes: u64,
    progress: &(dyn Fn(&Progress) + Sync),
    cancel: &AtomicBool,
) -> AppResult<Value> {
    // P0 fast path: the common delimited/CSV shape avoids the per-record /
    // per-field / per-row intermediate allocations.  Every other format (and
    // any mapping/layout this path cannot prove equivalent) stays on the
    // original generic implementation below.  DBPILOT_IMPORT_LEGACY=1 forces the
    // generic path for differential testing/benchmarks.
    if let Some(mapping) = spec.validate.mapping.as_ref() {
        if let Ok(resolved) = resolve_mapping(mapping, table_columns) {
            if fast_delimited_eligible(spec, &resolved) {
                return execute_delimited_fast(
                    driver,
                    conn,
                    spec,
                    table_columns,
                    total_bytes,
                    progress,
                    cancel,
                )
                .await;
            }
        }
    }
    execute_generic(
        driver,
        conn,
        spec,
        table_columns,
        total_bytes,
        progress,
        cancel,
    )
    .await
}

#[allow(unused_assignments)]
async fn execute_generic(
    driver: &dyn crate::core::driver::DatabaseDriver,
    conn: &crate::core::connection::ConnectionHandle,
    spec: &ExecuteSpec,
    table_columns: &[TableColumn],
    total_bytes: u64,
    progress: &(dyn Fn(&Progress) + Sync),
    cancel: &AtomicBool,
) -> AppResult<Value> {
    let started = Instant::now();
    // Benchmark-only counters (exposed as additive `timings` in the result):
    // time spent inside database round trips vs everything else (read/parse/
    // convert/render/progress). No behavioural impact.
    let mut db_ns: u128 = 0;
    let mut sql_bytes: u64 = 0;
    ensure_large_file_streamable(&spec.validate.parse.path)?;
    let mapping = spec
        .validate
        .mapping
        .as_ref()
        .ok_or_else(|| AppError::bad("请先设置列映射"))?;
    let resolved = resolve_mapping(mapping, table_columns)?;
    let columns = mapping_column_names(&resolved);
    let database = spec
        .validate
        .database
        .as_deref()
        .ok_or_else(|| AppError::bad("缺少目标数据库"))?;
    let table = spec
        .validate
        .table
        .as_deref()
        .ok_or_else(|| AppError::bad("缺少目标表"))?;
    let options = &spec.options;
    let batch_size = options.batch_size.clamp(1, MAX_BATCH_SIZE);
    let max_issues = options.max_issues.clamp(1, 1_000);
    let skip_errors = options.on_error == "skip";
    // Two target columns may read the same source; the moving conversion cannot
    // hand the same cell to both, so those rare mappings keep the cloning path.
    let sources_unique = sources_are_unique(&resolved);

    let mut scanner = RecordScanner::open(&spec.validate.parse)?;
    let mut progress_state = Progress {
        phase: "importing".to_string(),
        total_bytes,
        ..Default::default()
    };
    let mut bytes_read = 0u64;
    let mut records = 0u64;
    let mut data_records = 0u64;
    let mut rows_inserted = 0u64;
    let mut rows_failed = 0u64;
    let mut batches = 0u64;
    let mut issues: Vec<Value> = Vec::new();
    let mut header: Option<Vec<String>> = None;
    let mut header_plan: Option<HeaderPlan> = None;
    // execute 一直只给 delimited 跳过表头；"excel" 的记录同样是「首条 = 表头」，
    // 因此必须一起处理，否则表头行会被当成数据插进去。
    let mut header_pending = spec.validate.parse.fields.header
        && matches!(spec.validate.parse.fields.mode.as_str(), "delimited" | "excel");
    let mut cancelled = false;
    let mut stopped = false;
    let mut stop_message = String::new();
    // Progress is throttled: the callback clones `Progress` and takes the job
    // mutex, which dominated small-row imports when done per record.
    let mut last_progress = Instant::now();
    const PROGRESS_INTERVAL: std::time::Duration = std::time::Duration::from_millis(100);

    type Row = (u64, u64, u64, Vec<Value>);
    let mut batch: Vec<Row> = Vec::with_capacity(batch_size.min(4_096));
    let mut batch_bytes: usize = 0;
    // The target table and column list are identical for every batch, so render
    // the INSERT head once instead of rebuilding it per statement.
    let mut insert_prefix = String::new();
    push_insert_header(&mut insert_prefix, driver.kind(), database, table, &columns);

    macro_rules! report_issue {
        ($index:expr, $line:expr, $offset:expr, $message:expr, $text:expr) => {{
            rows_failed += 1;
            if issues.len() < max_issues {
                let mut issue = issue_json($index, $line, $offset, $message, "");
                issue["snippet"] = json!(snippet($text, 120));
                issues.push(issue);
            }
        }};
    }

    macro_rules! flush_batch {
        () => {{
            if !batch.is_empty() {
                // Borrow the queued rows: the old code cloned the whole batch
                // (`batch.iter().map(|r| r.3.clone())`) just to hand a
                // `&[Vec<Value>]` to the SQL builder.
                let mut sql = String::with_capacity(insert_prefix.len() + batch_bytes + 16);
                sql.push_str(&insert_prefix);
                push_insert_rows(&mut sql, driver.kind(), batch.iter().map(|row| row.3.as_slice()));
                sql_bytes += sql.len() as u64;
                // Text protocol: the SQL text is unique per batch, so a prepared
                // statement would be a prepare+execute+close round trip each time.
                let db_started = Instant::now();
                let result = conn.run_raw(&sql).await;
                db_ns += db_started.elapsed().as_nanos();
                batches += 1;
                if let Some(error) = result.error {
                    if skip_errors {
                        // Retry one row at a time to find the exact offenders.
                        for (index, line, offset, values) in batch.iter() {
                            let mut single = String::with_capacity(insert_prefix.len() + 128);
                            single.push_str(&insert_prefix);
                            push_insert_rows(&mut single, driver.kind(), std::iter::once(values.as_slice()));
                            sql_bytes += single.len() as u64;
                            let single_started = Instant::now();
                            let result = conn.run_raw(&single).await;
                            db_ns += single_started.elapsed().as_nanos();
                            match result.error {
                                Some(error) => {
                                    report_issue!(
                                        *index,
                                        *line,
                                        *offset,
                                        &format!("插入失败: {}", error),
                                        ""
                                    );
                                }
                                None => rows_inserted += 1,
                            }
                        }
                    } else {
                        stopped = true;
                        stop_message = format!("批量插入失败: {}", error);
                        if issues.len() < max_issues {
                            let (index, line, offset, _) = &batch[0];
                            let mut issue = issue_json(
                                *index,
                                *line,
                                *offset,
                                &stop_message,
                                "",
                            );
                            issue["snippet"] = json!("");
                            issues.push(issue);
                        }
                    }
                } else {
                    rows_inserted += batch.len() as u64;
                }
                batch.clear();
                batch_bytes = 0;
            }
        }};
    }

    loop {
        if cancel.load(Ordering::Relaxed) {
            cancelled = true;
            break;
        }
        let item = match scanner.next()? {
            None => break,
            Some(item) => item,
        };
        match item {
            ScanItem::Problem(problem) => {
                if problem.fatal {
                    stopped = true;
                    stop_message = problem.message.clone();
                    report_issue!(
                        records,
                        problem.line,
                        problem.offset,
                        &problem.message,
                        ""
                    );
                    break;
                }
                report_issue!(
                    records,
                    problem.line,
                    problem.offset,
                    &problem.message,
                    ""
                );
            }
            ScanItem::Record(record) => {
                records += 1;
                bytes_read = record.offset.max(bytes_read);
                let parsed = if header_pending {
                    header_pending = false;
                    match header_of(&record.text, &spec.validate.parse.fields) {
                        Ok(names) => {
                            if resolved.keyed && sources_unique {
                                header_plan = Some(HeaderPlan::new(&names, &resolved, mapping));
                            }
                            header = Some(names);
                            progress_state.records = records;
                            progress_state.bytes = bytes_read;
                            progress_state.refresh(started);
                            if let Some(excel) = scanner.excel_progress() {
                                apply_excel_progress(
                                    &mut progress_state,
                                    &excel,
                                    total_bytes,
                                    started,
                                );
                            }
                            progress(&progress_state);
                            continue;
                        }
                        Err(message) => Err(format!("表头解析失败: {}", message)),
                    }
                } else {
                    parse_row(&record.text, &spec.validate.parse.fields)
                };
                let converted: Result<Vec<Value>, String> = match parsed {
                    Err(message) => Err(message),
                    Ok(ParsedRow::Positional(fields)) if header_plan.is_some() => {
                        // Fast path: constant header + name-based mapping. Avoids
                        // rebuilding a Map (cloned keys + cloned cells) per row.
                        map_header_record(
                            fields,
                            header_plan.as_ref().expect("checked by pattern"),
                            &resolved,
                            mapping,
                        )
                    }
                    Ok(parsed) => {
                        let row = if let Some(header) = &header {
                            match parsed {
                                ParsedRow::Positional(values) => {
                                    if values.len() > header.len() {
                                        Err(format!(
                                            "记录有 {} 个字段，表头只有 {} 列",
                                            values.len(),
                                            header.len()
                                        ))
                                    } else {
                                        let mut map = Map::new();
                                        for (i, name) in header.iter().enumerate() {
                                            map.insert(
                                                name.clone(),
                                                values.get(i).cloned().unwrap_or(Value::Null),
                                            );
                                        }
                                        Ok(ParsedRow::Keyed(map))
                                    }
                                }
                                keyed => Ok(keyed),
                            }
                        } else {
                            Ok(parsed)
                        };
                        match row {
                            Ok(row) => map_parsed_owned(row, &resolved, mapping, sources_unique),
                            Err(message) => Err(message),
                        }
                    }
                };
                match converted {
                    Err(message) => {
                        report_issue!(
                            record.index,
                            record.line,
                            record.offset,
                            &message,
                            &record.text
                        );
                        if !skip_errors {
                            stopped = true;
                            stop_message = message;
                            break;
                        }
                    }
                    Ok(values) => {
                        data_records += 1;
                        batch_bytes += values.iter().map(estimate_literal_len).sum::<usize>();
                        batch.push((record.index, record.line, record.offset, values));
                        if batch.len() >= batch_size || batch_bytes >= MAX_BATCH_SQL_BYTES {
                            flush_batch!();
                            if stopped {
                                break;
                            }
                        }
                    }
                }
            }
        }
        if last_progress.elapsed() >= PROGRESS_INTERVAL {
            last_progress = Instant::now();
            progress_state.bytes = bytes_read;
            progress_state.records = records;
            progress_state.rows = rows_inserted;
            progress_state.failed = rows_failed;
            progress_state.refresh(started);
            if let Some(excel) = scanner.excel_progress() {
                apply_excel_progress(&mut progress_state, &excel, total_bytes, started);
            }
            progress(&progress_state);
        }
        if stopped {
            break;
        }
    }
    if !stopped && !cancelled {
        flush_batch!();
    }
    if !cancelled && bytes_read < total_bytes {
        bytes_read = total_bytes;
    }
    progress_state.bytes = bytes_read;
    progress_state.phase = if cancelled {
        "cancelled".to_string()
    } else {
        "done".to_string()
    };
    progress_state.records = records;
    progress_state.rows = rows_inserted;
    progress_state.failed = rows_failed;
    progress_state.refresh(started);
    if let Some(excel) = scanner.excel_progress() {
        apply_excel_progress(&mut progress_state, &excel, total_bytes, started);
    }
    progress(&progress_state);

    Ok(json!({
        "ok": rows_failed == 0 && !stopped && !cancelled,
        "cancelled": cancelled,
        "stopped": stopped,
        "message": stop_message,
        "bytes": bytes_read,
        "total_bytes": total_bytes,
        "records": records,
        "data_records": data_records,
        "rows_inserted": rows_inserted,
        "rows_failed": rows_failed,
        "batches": batches,
        "issues": issues,
        "elapsed_ms": started.elapsed().as_millis() as u64,
        "timings": {
            "total_ms": started.elapsed().as_millis() as u64,
            "db_ms": (db_ns / 1_000_000) as u64,
            "non_db_ms": ((started.elapsed().as_nanos().saturating_sub(db_ns)) / 1_000_000) as u64,
            "sql_bytes": sql_bytes,
            "batches": batches,
            "batch_size": batch_size,
        },
    }))
}

// ---------------------------------------------------------------- SQL scripts

/// One statement found by the streaming SQL-file reader.
#[derive(Clone, Debug)]
pub struct SqlStatement {
    pub sql: String,
    pub offset: u64,
    pub line: u64,
}

#[derive(Clone, Debug)]
pub struct ScriptProblem {
    pub message: String,
    pub offset: u64,
    pub line: u64,
    pub fatal: bool,
}

pub enum ScriptItem {
    Statement(SqlStatement),
    Problem(ScriptProblem),
}

enum CharOutcome {
    Char(char),
    Eof,
    Invalid,
}

/// Streaming equivalent of db::split_statements for files.
///
/// It keeps the same semantics (quotes, line/block comments, DELIMITER
/// directives) but reads the file in 64 KiB chunks, so importing a multi-GB dump
/// never loads it into memory. One statement is buffered at a time, capped by
/// MAX_SQL_STATEMENT_BYTES.
pub struct SqlScriptReader {
    stream: ByteStream,
    state: u8,
    cur: String,
    has_code: bool,
    delimiter: Vec<u8>,
    /// PostgreSQL dollar-quote tag currently open (state 6), e.g. `$$`.
    dollar_tag: Vec<u8>,
    stmt_offset: u64,
    stmt_line: u64,
    done: bool,
}

impl SqlScriptReader {
    pub fn open(path: &str) -> AppResult<Self> {
        Ok(SqlScriptReader {
            stream: ByteStream::open(path)?,
            state: 0,
            cur: String::new(),
            has_code: false,
            delimiter: b";".to_vec(),
            dollar_tag: Vec::new(),
            stmt_offset: 0,
            stmt_line: 1,
            done: false,
        })
    }

    pub fn bytes_read(&self) -> u64 {
        self.stream.abs
    }

    pub fn next_statement(&mut self) -> AppResult<Option<ScriptItem>> {
        if self.done {
            return Ok(None);
        }
        loop {
            if self.stream.at_eof()? {
                self.done = true;
                if self.has_code {
                    return Ok(self.take_statement().map(|s| s));
                }
                return Ok(None);
            }
            if let Some(problem) = self.maybe_delimiter()? {
                self.done = true;
                return Ok(Some(ScriptItem::Problem(problem)));
            }
            // PostgreSQL dollar-quoted body: copy bytes verbatim until the exact
            // closing tag appears, so embedded semicolons never split it.
            if self.state == 6 {
                if !self.dollar_tag.is_empty() && self.stream.starts_with(&self.dollar_tag.clone())? {
                    let tag = String::from_utf8_lossy(&self.dollar_tag).to_string();
                    let len = self.dollar_tag.len();
                    self.stream.advance(len);
                    self.cur.push_str(&tag);
                    self.state = 0;
                    self.dollar_tag.clear();
                    continue;
                }
                let (pos, line) = self.stream.position();
                let ch = match self.next_char()? {
                    CharOutcome::Char(c) => c,
                    CharOutcome::Eof => continue,
                    CharOutcome::Invalid => {
                        self.done = true;
                        return Ok(Some(ScriptItem::Problem(ScriptProblem {
                            message: "文件不是有效的 UTF-8 文本（可能是 GBK/GB18030 编码）"
                                .to_string(),
                            offset: pos,
                            line,
                            fatal: true,
                        })));
                    }
                };
                self.cur.push(ch);
                continue;
            }
            // A dollar-quote opener starts a body; `$1` is a parameter, not a quote.
            if self.state == 0 && self.stream.peek()? == Some(b'$') {
                let (pos, line) = self.stream.position();
                if let Some(tag) = self.peek_dollar_tag()? {
                    let text = String::from_utf8_lossy(&tag).to_string();
                    self.stream.advance(tag.len());
                    self.cur.push_str(&text);
                    self.dollar_tag = tag;
                    self.mark_code(pos, line);
                    self.state = 6;
                    continue;
                }
            }
            if self.state == 0 && self.stream.starts_with(&self.delimiter.clone())? {
                let len = self.delimiter.len();
                self.stream.advance(len);
                if self.has_code {
                    return Ok(self.take_statement());
                }
                self.cur.clear();
                self.has_code = false;
                continue;
            }
            // Comment openers are detected before consuming so the two
            // characters stay together.
            if self.state == 0 && self.stream.starts_with(b"--")? {
                self.stream.advance(2);
                self.cur.push_str("--");
                self.state = 4;
                continue;
            }
            if self.state == 0 && self.stream.starts_with(b"/*")? {
                let (pos, line) = self.stream.position();
                if self.stream.peek_at(2)? == Some(b'!') {
                    // MySQL executable comment (`/*!NNNNN ... */`): keep it as
                    // code so the server can execute it, instead of dropping the
                    // whole statement as a comment.
                    self.mark_code(pos, line);
                    self.stream.advance(2);
                    self.cur.push_str("/*");
                    self.state = 0;
                    continue;
                }
                self.stream.advance(2);
                self.cur.push_str("/*");
                self.state = 5;
                continue;
            }
            if self.state == 0 && self.stream.starts_with(b"#")? {
                self.stream.advance(1);
                self.cur.push('#');
                self.state = 4;
                continue;
            }
            let (pos, line) = self.stream.position();
            let ch = match self.next_char()? {
                CharOutcome::Char(c) => c,
                CharOutcome::Eof => continue,
                CharOutcome::Invalid => {
                    self.done = true;
                    return Ok(Some(ScriptItem::Problem(ScriptProblem {
                        message: "文件不是有效的 UTF-8 文本（可能是 GBK/GB18030 编码）"
                            .to_string(),
                        offset: pos,
                        line,
                        fatal: true,
                    })));
                }
            };
            match self.state {
                0 => match ch {
                    '\'' => {
                        self.mark_code(pos, line);
                        self.state = 1;
                        self.cur.push(ch);
                    }
                    '"' => {
                        self.mark_code(pos, line);
                        self.state = 2;
                        self.cur.push(ch);
                    }
                    BT_CHAR => {
                        self.mark_code(pos, line);
                        self.state = 3;
                        self.cur.push(ch);
                    }
                    _ => {
                        if !ch.is_whitespace() {
                            self.mark_code(pos, line);
                        }
                        self.cur.push(ch);
                    }
                },
                1 => {
                    if ch == '\\' {
                        self.cur.push(ch);
                        if let CharOutcome::Char(next) = self.next_char()? {
                            self.cur.push(next);
                        }
                    } else {
                        if ch == '\'' {
                            self.state = 0;
                        }
                        self.cur.push(ch);
                    }
                }
                2 => {
                    if ch == '\\' {
                        self.cur.push(ch);
                        if let CharOutcome::Char(next) = self.next_char()? {
                            self.cur.push(next);
                        }
                    } else {
                        if ch == '"' {
                            self.state = 0;
                        }
                        self.cur.push(ch);
                    }
                }
                3 => {
                    if ch == BT_CHAR {
                        self.state = 0;
                    }
                    self.cur.push(ch);
                }
                4 => {
                    self.cur.push(ch);
                    if ch == '\n' {
                        self.state = 0;
                    }
                }
                5 => {
                    self.cur.push(ch);
                    if ch == '*' && self.stream.starts_with(b"/")? {
                        self.stream.advance(1);
                        self.cur.push('/');
                        self.state = 0;
                    }
                }
                _ => {}
            }
            if self.cur.len() > MAX_SQL_STATEMENT_BYTES {
                self.done = true;
                return Ok(Some(ScriptItem::Problem(ScriptProblem {
                    message: format!(
                        "单条 SQL 语句超过 {} 字节，请拆分后导入",
                        MAX_SQL_STATEMENT_BYTES
                    ),
                    offset: self.stmt_offset,
                    line: self.stmt_line,
                    fatal: true,
                })));
            }
        }
    }

    fn mark_code(&mut self, offset: u64, line: u64) {
        if !self.has_code {
            self.stmt_offset = offset;
            self.stmt_line = line;
            self.has_code = true;
        }
    }

    fn take_statement(&mut self) -> Option<ScriptItem> {
        let sql = self.cur.trim().to_string();
        let offset = self.stmt_offset;
        let line = self.stmt_line;
        self.cur.clear();
        self.has_code = false;
        if sql.is_empty() {
            return None;
        }
        Some(ScriptItem::Statement(SqlStatement { sql, offset, line }))
    }

    /// DELIMITER xxx directive: recognised at the start of a statement, like
    /// the synchronous splitter does.
    fn maybe_delimiter(&mut self) -> AppResult<Option<ScriptProblem>> {
        if self.state != 0 || self.has_code {
            return Ok(None);
        }
        if !self.stream.starts_with_ascii_ci("delimiter")? {
            return Ok(None);
        }
        // The keyword must be followed by whitespace (otherwise it is a plain
        // identifier such as delimiter_count).
        let after = self.stream.peek_at(9)?;
        if !matches!(after, Some(b' ') | Some(b'\t') | Some(b'\r') | Some(b'\n')) {
            return Ok(None);
        }
        let (offset, line) = self.stream.position();
        let mut i = 0usize;
        let mut bytes: Vec<u8> = Vec::new();
        loop {
            match self.stream.peek_at(i)? {
                None | Some(b'\n') => break,
                Some(b) => {
                    bytes.push(b);
                    i += 1;
                    if i > 1024 {
                        return Ok(Some(ScriptProblem {
                            message: "DELIMITER 指令行过长".to_string(),
                            offset,
                            line,
                            fatal: true,
                        }));
                    }
                }
            }
        }
        let text = String::from_utf8_lossy(&bytes).to_string();
        let token = text.get(9..).unwrap_or("").trim().to_string();
        self.stream.advance(i);
        if matches!(self.stream.peek()?, Some(b'\n')) {
            self.stream.advance(1);
        }
        if !token.is_empty() {
            self.delimiter = token.as_bytes().to_vec();
        }
        Ok(None)
    }

    /// Recognise a PostgreSQL dollar-quote opener at the current position.
    ///
    /// The caller has already checked that the current byte is `$`. Returns the
    /// full tag (`$$` or `$name$`) or None when this is an ordinary dollar
    /// (e.g. the `$1` positional parameter, which may not open a body).
    fn peek_dollar_tag(&mut self) -> AppResult<Option<Vec<u8>>> {
        if self.stream.peek_at(1)? == Some(b'$') {
            return Ok(Some(b"$$".to_vec()));
        }
        let mut name: Vec<u8> = Vec::new();
        let mut i = 1usize;
        loop {
            match self.stream.peek_at(i)? {
                None => return Ok(None),
                Some(b'$') => {
                    if name.is_empty() {
                        return Ok(None);
                    }
                    let mut tag = Vec::with_capacity(name.len() + 2);
                    tag.push(b'$');
                    tag.extend_from_slice(&name);
                    tag.push(b'$');
                    return Ok(Some(tag));
                }
                Some(b) if b.is_ascii_alphanumeric() || b == b'_' => {
                    if name.is_empty() && b.is_ascii_digit() {
                        return Ok(None);
                    }
                    name.push(b);
                    i += 1;
                    if i > 130 {
                        return Ok(None);
                    }
                }
                Some(_) => return Ok(None),
            }
        }
    }

    fn next_char(&mut self) -> AppResult<CharOutcome> {
        self.stream.ensure(4)?;
        if self.stream.remaining() == 0 {
            return Ok(CharOutcome::Eof);
        }
        let first = match self.stream.peek()? {
            Some(b) => b,
            None => return Ok(CharOutcome::Eof),
        };
        let len = match first {
            0x00..=0x7F => 1,
            0xC0..=0xDF => 2,
            0xE0..=0xEF => 3,
            0xF0..=0xF7 => 4,
            _ => return Ok(CharOutcome::Invalid),
        };
        self.stream.ensure(len)?;
        if self.stream.remaining() < len {
            return Ok(CharOutcome::Invalid);
        }
        let mut bytes = [0u8; 4];
        for (i, slot) in bytes.iter_mut().enumerate().take(len) {
            *slot = self.stream.peek_at(i)?.unwrap_or(0);
        }
        match std::str::from_utf8(&bytes[..len]) {
            Ok(s) => {
                let ch = s.chars().next().unwrap_or('\u{fffd}');
                self.stream.advance(len);
                Ok(CharOutcome::Char(ch))
            }
            Err(_) => Ok(CharOutcome::Invalid),
        }
    }
}

/// Backtick, spelled without a literal backtick so this file stays easy to
/// embed in tooling that treats that character specially.
const BT_CHAR: char = '\u{60}';

// ------------------------------------------------------------------- tests

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn temp_file(name: &str, content: &str) -> String {
        let dir = std::env::temp_dir().join(format!("rma-import-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(name);
        let mut file = File::create(&path).unwrap();
        file.write_all(content.as_bytes()).unwrap();
        path.to_string_lossy().to_string()
    }

    fn parse_spec(path: &str, read: ReadSpec, fields: FieldSpec) -> ParseSpec {
        ParseSpec {
            path: path.to_string(),
            read,
            fields,
        }
    }

    fn csv_fields(header: bool, sep: &str) -> FieldSpec {
        FieldSpec {
            mode: "delimited".to_string(),
            field_sep: sep.to_string(),
            quote: "\"".to_string(),
            escape: String::new(),
            trim: true,
            header,
        }
    }

    fn int_column(name: &str) -> TableColumn {
        TableColumn {
            name: name.to_string(),
            data_type: "int".to_string(),
            type_name: "int".to_string(),
            nullable: false,
            auto_increment: false,
        }
    }

    fn text_column(name: &str) -> TableColumn {
        TableColumn {
            name: name.to_string(),
            data_type: "varchar".to_string(),
            type_name: "varchar(20)".to_string(),
            nullable: true,
            auto_increment: false,
        }
    }

    #[test]
    fn split_fields_handles_quotes_and_commas() {
        let fields =
            split_fields("1,\"a,b\",\"say \"\"hi\"\"\",x", ",", "\"", "", true).unwrap();
        assert_eq!(fields, vec!["1", "a,b", "say \"hi\"", "x"]);
    }

    #[test]
    fn line_reader_reports_csv_rows() {
        let path = temp_file("a.csv", "id,name\n1,Ada\n2,\"Bob, Jr\"\n");
        let spec = parse_spec(&path, ReadSpec::default(), csv_fields(true, ","));
        let preview = preview(&spec, 10).unwrap();
        let records = preview["records"].as_array().unwrap();
        assert_eq!(records.len(), 3, "{}", preview);
        assert_eq!(preview["header"], json!(["id", "name"]));
        assert_eq!(records[2]["kind"], json!("array"));
        assert_eq!(records[2]["values"], json!(["2", "Bob, Jr"]));
    }

    #[test]
    fn quoted_newline_stays_in_one_record() {
        let path = temp_file("b.csv", "a,b\n1,\"line1\nline2\"\n2,x\n");
        let spec = parse_spec(&path, ReadSpec::default(), csv_fields(false, ","));
        let preview = preview(&spec, 10).unwrap();
        let records = preview["records"].as_array().unwrap();
        assert_eq!(records.len(), 3, "{}", preview);
        assert_eq!(records[1]["field_count"], json!(2));
        assert_eq!(records[1]["values"][1], json!("line1\nline2"));
    }

    #[test]
    fn wrapped_json_array_splits_at_depth_zero() {
        let path = temp_file(
            "c.json",
            "[\n {\"id\":1,\"tags\":[1,2]},\n {\"id\":2,\"tags\":[]}\n]\n",
        );
        let mut read = ReadSpec::default();
        read.mode = "wrapped".to_string();
        read.wrapper_start = "[".to_string();
        read.wrapper_end = "]".to_string();
        read.record_sep = ",".to_string();
        let fields = FieldSpec {
            mode: "json".to_string(),
            ..Default::default()
        };
        let spec = parse_spec(&path, read, fields);
        let preview = preview(&spec, 10).unwrap();
        let records = preview["records"].as_array().unwrap();
        assert_eq!(records.len(), 2, "{}", preview);
        assert_eq!(records[0]["kind"], json!("object"));
        assert_eq!(records[0]["values"]["id"], json!(1));
        assert_eq!(records[1]["values"]["tags"], json!([]));
    }

    #[test]
    fn preview_reports_missing_wrapper_position() {
        let path = temp_file("d.txt", "{\"id\":1}\n");
        let mut read = ReadSpec::default();
        read.mode = "wrapped".to_string();
        read.wrapper_start = "[".to_string();
        read.wrapper_end = "]".to_string();
        read.record_sep = ",".to_string();
        let fields = FieldSpec {
            mode: "json".to_string(),
            ..Default::default()
        };
        let spec = parse_spec(&path, read, fields);
        let preview = preview(&spec, 10).unwrap();
        let issues = preview["issues"].as_array().unwrap();
        assert!(!issues.is_empty(), "{}", preview);
        assert!(issues[0]["message"].as_str().unwrap().contains("包裹符"));
    }

    #[test]
    fn validate_reports_bad_rows_with_positions() {
        let path = temp_file("e.csv", "id,name\n1,Ada\nx,Bob\n3,Cy\n");
        let spec = parse_spec(&path, ReadSpec::default(), csv_fields(true, ","));
        let columns = vec![int_column("id"), text_column("name")];
        let mapping = MappingSpec {
            columns: vec![
                ColumnMap {
                    column: "id".to_string(),
                    source: json!("id"),
                },
                ColumnMap {
                    column: "name".to_string(),
                    source: json!("name"),
                },
            ],
            ..Default::default()
        };
        let validate_spec = ValidateSpec {
            parse: spec,
            mapping: Some(mapping),
            database: Some("main".to_string()),
            table: Some("t".to_string()),
        };
        let result = validate(
            &validate_spec,
            Some(&columns),
            100,
            0,
            &(|_| {}),
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(result["invalid"], json!(1), "{}", result);
        let issues = result["issues"].as_array().unwrap();
        assert!(
            issues[0]["message"].as_str().unwrap().contains("整数"),
            "{}",
            result
        );
        assert_eq!(issues[0]["line"], json!(3));
    }

    #[test]
    fn type_conversion_rejects_text_in_number_column() {
        let column = int_column("id");
        let mapping = MappingSpec::default();
        assert!(convert_value(json!("12"), &column, &mapping).is_ok());
        assert!(convert_value(json!("12.5"), &column, &mapping).is_err());
        assert!(convert_value(json!("abc"), &column, &mapping).is_err());
    }

    #[test]
    fn push_literal_matches_the_shared_literal_implementation() {
        let values = vec![
            Value::Null,
            json!(true),
            json!(false),
            json!(0),
            json!(-42),
            json!(i64::MAX),
            json!(1.5),
            json!(""),
            json!("plain"),
            json!("it's"),
            json!("back\\slash"),
            json!("line\nbreak"),
            json!("a, b"),
            json!("日本語"),
            json!({ "__binary__": "AAEC/w==", "len": 4 }),
            json!([1, 2]),
            json!({ "a": 1 }),
        ];
        for driver in [DriverKind::Mysql, DriverKind::Postgres, DriverKind::Sqlite] {
            for value in &values {
                let mut out = String::new();
                push_literal(&mut out, driver, value);
                assert_eq!(out, literal(driver, value), "{driver:?} {value}");
                assert!(
                    estimate_literal_len(value) >= literal(driver, value).len(),
                    "{driver:?} {value}: estimate must be an upper bound"
                );
            }
        }
    }

    #[test]
    fn insert_sql_builders_render_identical_statements() {
        let columns = vec!["id".to_string(), "name".to_string()];
        let row = vec![json!(1), json!("it's")];
        let single = build_single_insert_sql(DriverKind::Mysql, "db", "t", &columns, &row);
        let multi = build_insert_sql(
            DriverKind::Mysql,
            "db",
            "t",
            &columns,
            std::slice::from_ref(&row),
        );
        assert_eq!(single, multi);
        let expected = format!(
            "INSERT INTO {} ({}, {}) VALUES (1,'it''s')",
            qualify(DriverKind::Mysql, "db", "t"),
            qi(DriverKind::Mysql, "id"),
            qi(DriverKind::Mysql, "name"),
        );
        assert_eq!(single, expected);
        let two = build_insert_sql(
            DriverKind::Mysql,
            "db",
            "t",
            &columns,
            &[row, vec![json!(2), Value::Null]],
        );
        let expected = format!(
            "INSERT INTO {} ({}, {}) VALUES (1,'it''s'),(2,NULL)",
            qualify(DriverKind::Mysql, "db", "t"),
            qi(DriverKind::Mysql, "id"),
            qi(DriverKind::Mysql, "name"),
        );
        assert_eq!(two, expected);
    }

    #[test]
    fn header_plan_matches_the_map_based_conversion() {
        let resolved = ResolvedMapping {
            columns: vec![int_column("id"), text_column("name"), text_column("note")],
            sources: vec![json!("id"), json!("name"), json!("note")],
            keyed: true,
        };
        let mapping = MappingSpec::default();
        let header: Vec<String> = ["id", "name", "note"]
            .iter()
            .map(|name| name.to_string())
            .collect();
        let plan = HeaderPlan::new(&header, &resolved, &mapping);

        // What the old execute path did: positional row -> Map -> keyed map_record.
        let legacy = |fields: Vec<Value>| -> Result<Vec<Value>, String> {
            let mut map = Map::new();
            for (index, name) in header.iter().enumerate() {
                map.insert(
                    name.clone(),
                    fields.get(index).cloned().unwrap_or(Value::Null),
                );
            }
            map_record(&ParsedRow::Keyed(map), &resolved, &mapping)
        };
        for fields in [
            vec![json!("1"), json!("Ada"), json!("x")],
            vec![json!("2"), json!(" Bob "), json!("")],
            vec![json!("3")],
        ] {
            let expected = legacy(fields.clone());
            let actual = map_header_record(fields.clone(), &plan, &resolved, &mapping);
            match (&actual, &expected) {
                (Ok(a), Ok(b)) => assert_eq!(a, b, "fields {fields:?}"),
                (Err(a), Err(b)) => assert_eq!(a, b, "fields {fields:?}"),
                _ => panic!("fast path differs: {actual:?} vs {expected:?}"),
            }
        }

        // An unmapped header column has to fail exactly like the map path did.
        let mut strict = MappingSpec::default();
        strict.ignore_unknown = false;
        let mut wide_header = header.clone();
        wide_header.push("extra".to_string());
        let plan = HeaderPlan::new(&wide_header, &resolved, &strict);
        let fields = vec![json!("1"), json!("Ada"), json!("x")];
        let mut map = Map::new();
        for (index, name) in wide_header.iter().enumerate() {
            map.insert(
                name.clone(),
                fields.get(index).cloned().unwrap_or(Value::Null),
            );
        }
        let expected = map_record(&ParsedRow::Keyed(map), &resolved, &strict).unwrap_err();
        let actual = map_header_record(fields, &plan, &resolved, &strict).unwrap_err();
        assert_eq!(actual, expected);
    }

    #[test]
    fn owned_and_borrowed_mapping_produce_the_same_values() {
        let mapping = MappingSpec::default();
        let keyed = ResolvedMapping {
            columns: vec![int_column("id"), text_column("name")],
            sources: vec![json!("id"), json!("name")],
            keyed: true,
        };
        let mut row = Map::new();
        row.insert("id".to_string(), json!("7"));
        row.insert("name".to_string(), json!("Ada"));
        let borrowed = map_record(&ParsedRow::Keyed(row.clone()), &keyed, &mapping).unwrap();
        let owned = map_record_owned(ParsedRow::Keyed(row), &keyed, &mapping).unwrap();
        assert_eq!(borrowed, owned);

        let positional = ResolvedMapping {
            columns: vec![int_column("id"), text_column("name")],
            sources: vec![json!(0), json!(1)],
            keyed: false,
        };
        let fields = vec![json!("9"), json!("Bob")];
        let borrowed =
            map_record(&ParsedRow::Positional(fields.clone()), &positional, &mapping).unwrap();
        let owned =
            map_record_owned(ParsedRow::Positional(fields), &positional, &mapping).unwrap();
        assert_eq!(borrowed, owned);
    }

    #[test]
    fn sql_reader_splits_statements_and_honours_delimiter() {
        let path = temp_file(
            "f.sql",
            "-- comment\nCREATE TABLE t(x INT);\nINSERT INTO t VALUES (1);\n\
             DELIMITER //\nCREATE PROCEDURE p() BEGIN SELECT 1; END//\nDELIMITER ;\n",
        );
        let mut reader = SqlScriptReader::open(&path).unwrap();
        let mut statements = Vec::new();
        while let Some(item) = reader.next_statement().unwrap() {
            match item {
                ScriptItem::Statement(stmt) => statements.push(stmt.sql),
                ScriptItem::Problem(problem) => panic!("unexpected problem: {:?}", problem),
            }
        }
        assert_eq!(statements.len(), 3, "{:?}", statements);
        assert!(statements[0].contains("CREATE TABLE"));
        assert!(statements[1].contains("INSERT INTO"));
        assert!(statements[2].contains("CREATE PROCEDURE"));
        assert!(statements[2].contains("SELECT 1; END"));
    }

    #[test]
    fn sql_reader_keeps_dollar_quoted_and_executable_comment_statements() {
        let path = temp_file(
            "dollar.sql",
            "CREATE FUNCTION f() RETURNS void AS $$ BEGIN PERFORM 1; PERFORM 2; END $$ LANGUAGE plpgsql;\n             /*!50001 CREATE VIEW v AS SELECT 1 */;\n             SELECT 3;\n",
        );
        let mut reader = SqlScriptReader::open(&path).unwrap();
        let mut statements = Vec::new();
        while let Some(item) = reader.next_statement().unwrap() {
            match item {
                ScriptItem::Statement(stmt) => statements.push(stmt.sql),
                ScriptItem::Problem(problem) => panic!("unexpected problem: {:?}", problem),
            }
        }
        assert_eq!(statements.len(), 3, "{:?}", statements);
        assert!(statements[0].contains("PERFORM 2;"), "{}", statements[0]);
        assert!(statements[0].ends_with("LANGUAGE plpgsql"), "{}", statements[0]);
        assert!(statements[1].starts_with("/*!50001 CREATE VIEW"), "{}", statements[1]);
        assert_eq!(statements[2], "SELECT 3");
    }

    #[test]
    fn sql_reader_does_not_treat_dollar_parameters_as_quotes() {
        let path = temp_file("params.sql", "UPDATE t SET a=$1, b=$2 WHERE id=$3;\n");
        let mut reader = SqlScriptReader::open(&path).unwrap();
        let mut statements = Vec::new();
        while let Some(item) = reader.next_statement().unwrap() {
            if let ScriptItem::Statement(stmt) = item {
                statements.push(stmt.sql);
            }
        }
        assert_eq!(statements.len(), 1, "{:?}", statements);
        assert!(statements[0].contains("$1"));
    }

    #[test]
    fn inspect_detects_json_array_and_csv() {
        let json_path = temp_file("g.json", "[{\"a\":1},{\"a\":2}]");
        let info = inspect(&json_path).unwrap();
        assert_eq!(info["format"], json!("json_array"));
        assert_eq!(info["read"]["wrapper_start"], json!("["));
        assert_eq!(info["read"]["record_sep"], json!(","));

        let csv_path = temp_file("h.csv", "id,name\n1,Ada\n2,Bob\n");
        let info = inspect(&csv_path).unwrap();
        assert_eq!(info["format"], json!("delimited"));
        assert_eq!(info["fields"]["header"], json!(true));
        assert_eq!(info["fields"]["field_sep"], json!(","));
    }

    #[test]
    fn wrapped_custom_text_with_begin_end_and_newline_separator() {
        let path = temp_file(
            "i.txt",
            "BEGIN\n1|Ada\n2|Bob\nEND\n",
        );
        let mut read = ReadSpec::default();
        read.mode = "wrapped".to_string();
        read.wrapper_start = "BEGIN".to_string();
        read.wrapper_end = "END".to_string();
        read.record_sep = "\n".to_string();
        let fields = FieldSpec {
            mode: "delimited".to_string(),
            field_sep: "|".to_string(),
            ..Default::default()
        };
        let spec = parse_spec(&path, read, fields);
        let preview = preview(&spec, 10).unwrap();
        let records = preview["records"].as_array().unwrap();
        assert_eq!(records.len(), 2, "{}", preview);
        assert_eq!(records[0]["values"], json!(["1", "Ada"]));
        assert_eq!(records[1]["values"], json!(["2", "Bob"]));
    }

    #[test]
    fn wrapped_custom_text_reports_the_line_of_a_bad_record() {
        let path = temp_file(
            "j.txt",
            "BEGIN\n1|Ada\n2|Bob\ntoo|many|fields\nEND\n",
        );
        let mut read = ReadSpec::default();
        read.mode = "wrapped".to_string();
        read.wrapper_start = "BEGIN".to_string();
        read.wrapper_end = "END".to_string();
        read.record_sep = "\n".to_string();
        let fields = FieldSpec {
            mode: "delimited".to_string(),
            field_sep: "|".to_string(),
            ..Default::default()
        };
        let mapping = MappingSpec {
            columns: vec![
                ColumnMap {
                    column: "id".to_string(),
                    source: json!(0),
                },
                ColumnMap {
                    column: "name".to_string(),
                    source: json!(1),
                },
            ],
            ..Default::default()
        };
        let validate_spec = ValidateSpec {
            parse: parse_spec(&path, read, fields),
            mapping: Some(mapping),
            database: Some("main".to_string()),
            table: Some("t".to_string()),
        };
        let columns = vec![int_column("id"), text_column("name")];
        let result = validate(
            &validate_spec,
            Some(&columns),
            100,
            0,
            &(|_| {}),
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(result["invalid"], json!(1), "{}", result);
        let issue = &result["issues"][0];
        assert_eq!(issue["line"], json!(4), "{}", result);
        assert!(
            issue["message"].as_str().unwrap().contains("字段数"),
            "{}",
            result
        );
    }

    #[test]
    fn sql_reader_streams_across_chunk_boundaries() {
        let mut script = String::new();
        for i in 0..4000 {
            script.push_str(&format!("INSERT INTO t VALUES ({});\n", i));
        }
        assert!(script.len() > 64 * 1024, "must cross the 64 KiB read chunk");
        let path = temp_file("k.sql", &script);
        let mut reader = SqlScriptReader::open(&path).unwrap();
        let mut count = 0usize;
        let mut last = String::new();
        while let Some(item) = reader.next_statement().unwrap() {
            match item {
                ScriptItem::Statement(stmt) => {
                    count += 1;
                    last = stmt.sql;
                }
                ScriptItem::Problem(problem) => panic!("unexpected problem: {:?}", problem),
            }
        }
        assert_eq!(count, 4000);
        assert_eq!(last, "INSERT INTO t VALUES (3999)");
    }
}

#[cfg(test)]
mod round_trip_tests {
    use super::*;
    use crate::db::ColumnMeta;
    use crate::exporters;
    use serde_json::json;

    /// Columns and rows that exercise every awkward case: a NULL, an empty
    /// string, a comma inside a value, an XML-significant character, and a row
    /// SHORTER than the column list.
    fn sample() -> (Vec<ColumnMeta>, Vec<Vec<Value>>) {
        let cols = vec![
            ColumnMeta { name: "id".into(), type_name: "INTEGER".into() },
            ColumnMeta { name: "name".into(), type_name: "TEXT".into() },
            ColumnMeta { name: "note".into(), type_name: "TEXT".into() },
        ];
        let rows = vec![
            vec![json!(1), json!("alice"), Value::Null],
            vec![json!(2), Value::Null, json!("has,comma")],
            vec![json!(3), json!("bob"), json!("")],
            vec![json!(4), json!("a & b < c"), json!("x | y")],
        ];
        (cols, rows)
    }

    fn write_export(dir: &std::path::Path, format: &str) -> String {
        let (cols, rows) = sample();
        let (body, _, filename) =
            exporters::render(format, "t", &cols, &rows).expect("format supported");
        let path = dir.join(filename);
        std::fs::write(&path, body).unwrap();
        path.to_string_lossy().into_owned()
    }

    fn temp_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("rma-rt-{tag}-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn inspect_recognises_every_exporter_format() {
        let dir = temp_dir("inspect");
        // SQL is a script, not a record format; it is covered by the SQL reader tests.
        for (format, expected) in [
            ("csv", "delimited"),
            ("txt", "delimited"),
            ("json", "json_array"),
            ("xml", "xml"),
            ("html", "html"),
            ("xls", "excel"),
            ("md", "markdown"),
        ] {
            let path = write_export(&dir, format);
            let info = inspect(&path).unwrap();
            assert_eq!(
                info["format"].as_str().unwrap(),
                expected,
                "{format} must be recognised as {expected}"
            );
        }
    }

    #[test]
    fn every_format_previews_with_the_right_cell_count_and_null_placement() {
        let dir = temp_dir("preview");
        for format in ["csv", "txt", "json", "xml", "html", "xls", "md"] {
            let path = write_export(&dir, format);
            let info = inspect(&path).unwrap();
            let spec = ParseSpec {
                path: path.clone(),
                read: serde_json::from_value(info["read"].clone()).unwrap(),
                fields: serde_json::from_value(info["fields"].clone()).unwrap(),
            };
            let preview = preview(&spec, 10).unwrap();
            let records = preview["records"].as_array().unwrap();
            // The header is one of the records for delimited/xml/html/xls/md.
            let data: Vec<&Value> = records
                .iter()
                .filter(|r| r["header"] != json!(true))
                .collect();
            assert_eq!(data.len(), 4, "{format}: four data records");
            for record in &data {
                assert_eq!(
                    record["field_count"].as_u64().unwrap(),
                    3,
                    "{format}: every record must have 3 cells: {record}"
                );
            }
            // Row 0 has a NULL note; row 2 has an EMPTY note.
            let values = |i: usize| -> &Value { &data[i]["values"] };
            let note_of = |i: usize| -> Value {
                let v = values(i);
                match v {
                    Value::Object(map) => map.get("note").cloned().unwrap_or(Value::Null),
                    Value::Array(items) => items.get(2).cloned().unwrap_or(Value::Null),
                    other => other.clone(),
                }
            };
            assert!(note_of(0).is_null(), "{format}: row 0 note must be NULL, got {}", note_of(0));
            assert_eq!(
                note_of(2),
                json!(""),
                "{format}: row 2 note must be the empty string"
            );
        }
    }

    #[test]
    fn xml_and_html_escape_sequences_round_trip() {
        let dir = temp_dir("escape");
        for format in ["xml", "html", "xls"] {
            let path = write_export(&dir, format);
            let info = inspect(&path).unwrap();
            let spec = ParseSpec {
                path: path.clone(),
                read: serde_json::from_value(info["read"].clone()).unwrap(),
                fields: serde_json::from_value(info["fields"].clone()).unwrap(),
            };
            let preview = preview(&spec, 10).unwrap();
            let text = preview["records"].to_string();
            assert!(
                text.contains("a & b < c"),
                "{format}: entities must be decoded again: {text}"
            );
        }
    }
}

#[cfg(test)]
mod excel_tests {
    use super::*;
    use crate::drivers::{ConnSpec, DriverKind};
    use std::io::Write;
    use std::sync::Mutex;

    fn fixture(name: &str) -> String {
        format!("{}/tests/fixtures/{}", env!("CARGO_MANIFEST_DIR"), name)
    }

    #[test]
    fn format_size_is_human_readable() {
        assert_eq!(format_size(512), "512 B");
        assert_eq!(format_size(2048), "2.0 KB");
        assert_eq!(format_size(5 * 1024 * 1024), "5.0 MB");
        assert_eq!(format_size(MAX_NON_STREAMING_BYTES), "5.0 GB");
        assert_eq!(format_size(MAX_NON_STREAMING_BYTES * 2), "10.0 GB");
    }

    #[test]
    fn format_gib_uses_1024_based_units() {
        assert_eq!(format_gib(0), "0.0 GiB");
        assert_eq!(format_gib(MAX_NON_STREAMING_BYTES), "5.0 GiB");
        assert_eq!(format_gib(MAX_NON_STREAMING_BYTES + 1), "5.0 GiB");
        assert_eq!(format_gib(MAX_NON_STREAMING_BYTES * 2), "10.0 GiB");
    }

    #[test]
    fn non_streaming_size_error_names_format_and_limit_in_gib() {
        let message = non_streaming_size_error(MAX_NON_STREAMING_BYTES + 1, "xls");
        assert!(message.contains("5.0 GiB"), "{message}");
        assert!(message.contains("5×1024³ 字节"), "{message}");
        // 不再出现「5.0 GB（超过 5 GB）」这种自相矛盾的说法。
        assert!(!message.contains("5.0 GB"), "{message}");
        assert!(message.contains("xls"), "{message}");
        assert!(message.contains("无法流式读取"), "{message}");
    }

    #[test]
    fn large_file_warning_starts_above_five_gibibytes() {
        assert!(large_file_warning(MAX_NON_STREAMING_BYTES).is_none());
        // 5.2e9 字节 = 4.84 GiB：不到 5 GiB，不提示（十进制 GB 不是这里的阈值）。
        assert!(large_file_warning(5_200_000_000).is_none());

        let warning = large_file_warning(MAX_NON_STREAMING_BYTES + 1).expect("warning");
        assert!(warning.contains("5.0 GiB"), "{warning}");
        assert!(warning.contains("超过 5 GiB"), "{warning}");
        assert!(warning.contains("5×1024³ 字节"), "{warning}");
        assert!(!warning.contains("5.0 GB（超过 5 GB）"), "{warning}");
        // 超 5 GiB 的流式文件也要提示共享字符串表的内存风险（xls 建议另存/拆分）。
        assert!(warning.contains("SST"), "{warning}");
        assert!(warning.contains("内存峰值"), "{warning}");
        assert!(warning.contains(".xls"), "{warning}");
    }

    #[test]
    fn streamable_formats_ignore_the_five_gigabyte_limit() {
        // 所有 Excel 格式现在都是流式：把阈值压到 1 字节也不该拒绝。
        for fixture_name in [XLSX, XLS] {
            let path = fixture(fixture_name);
            ensure_streamable_with_limit(&path, 1).expect(fixture_name);
        }
    }

    #[test]
    fn large_file_guard_never_parses_the_workbook_to_decide() {
        // 「看起来像 xlsx」但 ZIP 结构损坏的小文件：detect 只读文件头就能认成
        // xlsx；旧实现随后 inspect_workbook 会因不是有效 ZIP 而失败，新实现用
        // ExcelKind::is_streaming() 常量判断，直接 Ok。limit=0 让所有非空文件
        // 都越过阈值，正好覆盖「要判定」的分支。
        let path = temp_path("broken.xlsx");
        let mut body = vec![0x50, 0x4B, 0x03, 0x04];
        body.extend_from_slice(b"xl/workbook.xml but this is not a real zip archive");
        std::fs::write(&path, &body).unwrap();
        ensure_streamable_with_limit(&path, 0)
            .expect("格式是流式的：判定不能为了格式而解析工作簿内容");

        // 所有当前格式的流式属性都是常量 true（拒绝分支只为将来的非流式格式保留）。
        for kind in [
            crate::excel_import::ExcelKind::Xlsx,
            crate::excel_import::ExcelKind::Xls,
            crate::excel_import::ExcelKind::Xlsb,
            crate::excel_import::ExcelKind::Ods,
            crate::excel_import::ExcelKind::SpreadsheetMl,
        ] {
            assert!(kind.is_streaming(), "{kind:?}");
        }
    }


    fn temp_file(name: &str, content: &str) -> String {
        let dir = std::env::temp_dir().join(format!("rma-excel-import-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(name);
        let mut file = File::create(&path).unwrap();
        file.write_all(content.as_bytes()).unwrap();
        path.to_string_lossy().to_string()
    }

    fn parse_spec(path: &str, read: ReadSpec, fields: FieldSpec) -> ParseSpec {
        ParseSpec {
            path: path.to_string(),
            read,
            fields,
        }
    }

    fn csv_fields(header: bool, sep: &str) -> FieldSpec {
        FieldSpec {
            mode: "delimited".to_string(),
            field_sep: sep.to_string(),
            quote: "\"".to_string(),
            escape: String::new(),
            trim: true,
            header,
        }
    }

    fn spec_from_inspect(path: &str) -> (Value, ParseSpec) {
        let info = inspect(path).expect("inspect");
        let spec = ParseSpec {
            path: path.to_string(),
            read: serde_json::from_value(info["read"].clone()).expect("read spec"),
            fields: serde_json::from_value(info["fields"].clone()).expect("fields spec"),
        };
        (info, spec)
    }

    fn sheet_spec(path: &str, sheet: Option<&str>, skip_rows: usize, header: bool) -> ParseSpec {
        let (_, mut spec) = spec_from_inspect(path);
        spec.read.sheet = sheet.map(str::to_string);
        spec.read.skip_rows = skip_rows;
        spec.fields.header = header;
        spec
    }

    fn column(name: &str, data_type: &str, nullable: bool) -> TableColumn {
        TableColumn {
            name: name.to_string(),
            data_type: data_type.to_string(),
            type_name: data_type.to_string(),
            nullable,
            auto_increment: false,
        }
    }

    fn named_mapping(columns: &[(&str, &str)]) -> MappingSpec {
        MappingSpec {
            columns: columns
                .iter()
                .map(|(column, source)| ColumnMap {
                    column: column.to_string(),
                    source: json!(source),
                })
                .collect(),
            ..Default::default()
        }
    }

    fn schema_column(schema: &Value, index: usize) -> &Value {
        &schema["columns"][index]
    }

    const XLSX: &str = "excel_multi.xlsx";
    const XLS: &str = "excel_multi.xls";

    #[test]
    fn inspect_detects_xlsx_and_lists_visible_sheets() {
        let path = fixture(XLSX);
        let info = inspect(&path).unwrap();
        assert_eq!(info["format"], json!("xlsx"), "{info}");
        assert_eq!(info["encoding"], json!("binary"));
        assert_eq!(info["fields"]["mode"], json!("excel"));
        assert_eq!(info["fields"]["header"], json!(true));
        assert_eq!(info["streaming"], json!(true), "{info}");
        assert_eq!(info["read"]["sheet"], json!("员工"));
        assert_eq!(info["read"]["skip_rows"], json!(0));
        assert_eq!(info["sheet"], json!("员工"));
        let sheets = info["sheets"].as_array().expect("sheets");
        let names: Vec<&str> = sheets
            .iter()
            .map(|sheet| sheet["name"].as_str().unwrap())
            .collect();
        assert_eq!(names, vec!["员工", "订单", "配置"], "{info}");
        assert_eq!(sheets[0]["index"], json!(0));
        assert_eq!(sheets[0]["rows"], json!(5)); // 表头 + 4 行数据
        assert_eq!(sheets[0]["cols"], json!(8));
        let warnings = info["warnings"].to_string();
        assert!(warnings.contains("3 个工作表"), "{warnings}");
        assert!(warnings.contains("隐藏工作表"), "{warnings}");
        assert_eq!(info["head"], json!(""), "binary workbook has no text preview");
    }

    #[test]
    fn inspect_detects_xls_biff_workbook() {
        let path = fixture(XLS);
        let info = inspect(&path).unwrap();
        assert_eq!(info["format"], json!("xls"), "{info}");
        assert_eq!(info["sheet"], json!("员工"));
        let sheets = info["sheets"].as_array().expect("sheets");
        assert_eq!(sheets.len(), 3, "{info}");
        assert_eq!(info["fields"]["mode"], json!("excel"));
        // BIFF8 走 Record 级流式：streaming=true，且不再有「暂未流式」提示。
        assert_eq!(info["streaming"], json!(true), "{info}");
        assert!(
            !info["warnings"].to_string().contains("暂未流式"),
            "{info}"
        );
    }

    #[test]
    fn preview_reads_excel_cells_with_their_native_types() {
        for fixture_name in [XLSX, XLS] {
            let path = fixture(fixture_name);
            let (_, spec) = spec_from_inspect(&path);
            let preview = preview(&spec, 10).unwrap();
            assert_eq!(preview["sheet_used"], json!("员工"), "{fixture_name}");
            assert_eq!(
                preview["streaming"],
                json!(true),
                "{fixture_name}: {}",
                preview["streaming"]
            );
            assert_eq!(
                preview["header"],
                json!([
                    "id",
                    "姓名",
                    "入职日期",
                    "活跃",
                    "评分",
                    "备注",
                    "登录时间",
                    "打卡时间"
                ]),
                "{fixture_name}: {}",
                preview["header"]
            );
            let records = preview["records"].as_array().unwrap();
            // 1 条表头 + 4 条数据。
            assert_eq!(records.len(), 5, "{fixture_name}: {preview}");
            assert_eq!(records[0]["header"], json!(true));
            // records[..].text 是 JSON 数组文本（Dart 侧「分割结果回显」直接展示）。
            assert!(
                records[1]["text"].as_str().unwrap().starts_with('['),
                "{fixture_name}"
            );
            // 数字/布尔/日期/时间/NULL 都保留 Excel 原类型。
            assert_eq!(
                records[1]["values"],
                json!([1, "张伟", "2021-03-05", true, 88.5, null, "2021-03-05 09:30:00", "09:30:00"]),
                "{fixture_name}: {}",
                records[1]["values"]
            );
            assert_eq!(records[2]["values"][5], json!("优秀"), "{fixture_name}");
            assert_eq!(records[3]["values"][5], Value::Null, "{fixture_name}");
            assert_eq!(records[2]["values"][3], json!(false), "{fixture_name}");
        }
    }

    #[test]
    fn preview_switches_worksheet_by_name_or_index() {
        let path = fixture(XLSX);
        // 名字选表。
        let by_name = preview(&sheet_spec(&path, Some("订单"), 0, true), 10).unwrap();
        assert_eq!(by_name["sheet_used"], json!("订单"));
        assert_eq!(by_name["header"], json!(["订单号", "客户", "金额"]));
        assert_eq!(
            by_name["records"][1]["values"],
            json!([1001, "甲公司", 299.5])
        );
        // 字符串形式的 0-based 序号（契约：read.sheet 也接受序号）。
        let by_index = preview(&sheet_spec(&path, Some("1"), 0, true), 10).unwrap();
        assert_eq!(by_index["sheet_used"], json!("订单"));
        assert_eq!(by_index["header"], json!(["订单号", "客户", "金额"]));
        // 第二张表数据与第一张不同。
        let employees = preview(&sheet_spec(&path, None, 0, true), 10).unwrap();
        assert_eq!(employees["sheet_used"], json!("员工"));

        // JSON 数字形式的工作表序号也要能反序列化（Dart 可能直接传 int）。
        let read: ReadSpec = serde_json::from_value(json!({ "sheet": 2 })).unwrap();
        assert_eq!(read.sheet.as_deref(), Some("2"));
        let read: ReadSpec = serde_json::from_value(json!({ "sheet": "配置" })).unwrap();
        assert_eq!(read.sheet.as_deref(), Some("配置"));
    }

    #[test]
    fn preview_reports_a_missing_worksheet_by_name() {
        let path = fixture(XLSX);
        let error = preview(&sheet_spec(&path, Some("不存在"), 0, true), 10).unwrap_err();
        let message = error.to_string();
        assert!(message.contains("找不到工作表"), "{message}");
        assert!(message.contains("员工"), "{message}");
    }

    #[test]
    fn skip_rows_moves_the_first_data_row_down() {
        let path = fixture(XLSX);
        // 跳过表头行后，第一条记录就是原来的第 1 行数据。
        let spec = sheet_spec(&path, None, 1, false);
        let first = preview(&spec, 10).unwrap();
        let records = first["records"].as_array().unwrap();
        assert_eq!(records.len(), 4, "{first}");
        assert_eq!(
            records[0]["values"],
            json!([1, "张伟", "2021-03-05", true, 88.5, null, "2021-03-05 09:30:00", "09:30:00"])
        );
        // skip_rows 在表头判定之前生效：跳 1 行后首行（原数据第 1 行）按表头解析。
        let spec = sheet_spec(&path, None, 1, true);
        let shifted = preview(&spec, 10).unwrap();
        assert_eq!(shifted["header"][1], json!("张伟"), "{}", shifted["header"]);
        assert_eq!(
            shifted["records"][1]["values"][1],
            json!("李娜"),
            "{}",
            shifted
        );
    }

    #[test]
    fn schema_infers_employee_column_types() {
        for fixture_name in [XLSX, XLS] {
            let path = fixture(fixture_name);
            let (_, spec) = spec_from_inspect(&path);
            let preview = preview(&spec, 5).unwrap();
            let schema = &preview["schema"];
            assert_eq!(schema["sample_count"], json!(4), "{fixture_name}: {schema}");
            let columns = schema["columns"].as_array().unwrap();
            assert_eq!(columns.len(), 8, "{fixture_name}: {schema}");

            assert_eq!(columns[0]["name"], json!("id"));
            assert_eq!(columns[0]["source"], json!(0));
            assert_eq!(columns[0]["type"], json!("integer"));
            assert_eq!(columns[0]["nullable"], json!(false));
            assert_eq!(columns[0]["primary_candidate"], json!(true));
            assert_eq!(columns[0]["samples"], json!([1, 2, 3]));

            assert_eq!(columns[1]["name"], json!("姓名"));
            assert_eq!(columns[1]["type"], json!("text"));
            // 文本列给余量：样本 2 字符 → 推荐 255，而不是零余量的 VARCHAR(2)。
            assert_eq!(columns[1]["max_length"], json!(255));
            assert_eq!(columns[1]["nullable"], json!(false));

            assert_eq!(columns[2]["name"], json!("入职日期"));
            assert_eq!(columns[2]["type"], json!("date"), "{fixture_name}: {schema}");

            assert_eq!(columns[3]["name"], json!("活跃"));
            assert_eq!(columns[3]["type"], json!("boolean"));

            assert_eq!(columns[4]["name"], json!("评分"));
            assert_eq!(columns[4]["type"], json!("decimal"));

            assert_eq!(columns[5]["name"], json!("备注"));
            assert_eq!(columns[5]["type"], json!("text"));
            assert_eq!(columns[5]["nullable"], json!(true));

            assert_eq!(columns[6]["name"], json!("登录时间"));
            assert_eq!(columns[6]["type"], json!("datetime"));

            assert_eq!(columns[7]["name"], json!("打卡时间"));
            assert_eq!(columns[7]["type"], json!("time"), "{fixture_name}: {schema}");
        }
    }

    #[test]
    fn schema_infers_order_sheet_types() {
        let path = fixture(XLSX);
        let preview = preview(&sheet_spec(&path, Some("订单"), 0, true), 10).unwrap();
        let columns = preview["schema"]["columns"].as_array().unwrap();
        assert_eq!(columns[0]["name"], json!("订单号"));
        assert_eq!(columns[0]["type"], json!("integer"));
        assert_eq!(columns[1]["name"], json!("客户"));
        assert_eq!(columns[1]["type"], json!("text"));
        assert_eq!(columns[1]["max_length"], json!(255));
        assert_eq!(columns[2]["name"], json!("金额"));
        assert_eq!(columns[2]["type"], json!("decimal"));
    }

    #[test]
    fn schema_handles_bigint_identifier_cleanup_and_dedup() {
        let header = vec![
            "id".to_string(),
            "大 数字".to_string(),
            "".to_string(),
            "dup".to_string(),
            "dup".to_string(),
        ];
        let rows = vec![
            vec![json!(1), json!(3_000_000_000_i64), json!("x"), json!("a"), json!(true)],
            vec![json!(2), json!(4_000_000_000_i64), json!("y"), json!("b"), json!(false)],
        ];
        let schema = crate::excel_import::infer_schema(Some(&header), &rows, 1000);
        let columns = schema["columns"].as_array().unwrap();
        assert_eq!(columns[0]["type"], json!("integer"));
        assert_eq!(columns[1]["name"], json!("大_数字"));
        assert_eq!(columns[1]["type"], json!("bigint"));
        assert_eq!(columns[2]["name"], json!("column_3"));
        assert_eq!(columns[3]["name"], json!("dup"));
        assert_eq!(columns[4]["name"], json!("dup_2"));
        assert_eq!(columns[4]["type"], json!("boolean"));
        assert_eq!(schema["sample_count"], json!(2));
    }

    #[test]
    fn schema_text_length_headroom_avoids_zero_margin_columns() {
        // 短文本给 255 的推荐长度（样本只有 2 字符也不再生成 VARCHAR(2)）；
        // 超过 127 字符的长文本返回 0，由向导落成 TEXT；非文本列不带长度。
        let long_text = "长".repeat(128);
        let boundary_text = "界".repeat(127);
        let header = vec![
            "姓名".to_string(),
            "长备注".to_string(),
            "边界".to_string(),
            "id".to_string(),
        ];
        let rows = vec![
            vec![
                json!("张三"),
                json!(long_text.clone()),
                json!(boundary_text.clone()),
                json!(1),
            ],
            vec![json!("李四"), json!(long_text), json!(boundary_text), json!(2)],
        ];
        let schema = crate::excel_import::infer_schema(Some(&header), &rows, 1000);
        let columns = schema["columns"].as_array().unwrap();
        assert_eq!(columns[0]["type"], json!("text"));
        assert_eq!(columns[0]["max_length"], json!(255), "{schema}");
        assert_eq!(columns[1]["type"], json!("text"));
        assert_eq!(columns[1]["max_length"], json!(0), "{schema}");
        assert_eq!(columns[2]["type"], json!("text"));
        assert_eq!(columns[2]["max_length"], json!(255), "{schema}");
        assert_eq!(columns[3]["type"], json!("integer"));
        assert_eq!(columns[3]["max_length"], json!(0), "{schema}");
    }

    #[test]
    fn schema_suggests_unique_integer_natural_key_instead_of_demanding_an_id() {
        // 学生名单：首列姓名（文本），学号是唯一整数自然键；应提议 学号 而不是逼用户加自增 id。
        let header = vec!["姓名".to_string(), "学号".to_string(), "班级".to_string()];
        let rows = vec![
            vec![json!("张三"), json!(20260101), json!("高一(1)班")],
            vec![json!("李四"), json!(20260102), json!("高一(1)班")],
            vec![json!("王五"), json!(20260103), json!("高一(2)班")],
        ];
        let schema = crate::excel_import::infer_schema(Some(&header), &rows, 1000);
        let columns = schema["columns"].as_array().unwrap();
        // 姓名单看也是唯一文本，但优先级低于唯一的整数自然键。
        assert_eq!(columns[0]["unique"], json!(true), "{schema}");
        assert_eq!(columns[0]["primary_candidate"], json!(false), "{schema}");
        assert_eq!(columns[1]["type"], json!("integer"), "{schema}");
        assert_eq!(columns[1]["unique"], json!(true), "{schema}");
        assert_eq!(columns[1]["primary_candidate"], json!(true), "{schema}");
        assert_eq!(
            columns[1]["primary_candidate_reason"],
            json!("unique_integer"),
            "{schema}"
        );
        assert_eq!(columns[2]["unique"], json!(false), "班级有重复: {schema}");
        assert_eq!(columns[2]["primary_candidate"], json!(false), "{schema}");
        let candidates = columns
            .iter()
            .filter(|column| column["primary_candidate"] == json!(true))
            .count();
        assert_eq!(candidates, 1, "每张表最多一个主键候选: {schema}");
    }

    #[test]
    fn schema_keeps_named_id_as_the_single_primary_candidate() {
        // orders(id, user_id, status)：仍选 id；重复的 user_id / status 不成为候选。
        let header = vec![
            "id".to_string(),
            "user_id".to_string(),
            "status".to_string(),
            "note".to_string(),
        ];
        let rows = vec![
            vec![json!(1), json!(7), json!("paid"), json!("a")],
            vec![json!(2), json!(7), json!("paid"), Value::Null],
            vec![json!(3), json!(9), json!("new"), json!("b")],
        ];
        let schema = crate::excel_import::infer_schema(Some(&header), &rows, 1000);
        let columns = schema["columns"].as_array().unwrap();
        assert_eq!(columns[0]["primary_candidate"], json!(true), "{schema}");
        assert_eq!(
            columns[0]["primary_candidate_reason"],
            json!("id"),
            "{schema}"
        );
        assert_eq!(columns[0]["unique"], json!(true), "{schema}");
        assert_eq!(columns[1]["unique"], json!(false), "{schema}");
        assert_eq!(columns[1]["primary_candidate"], json!(false), "{schema}");
        assert_eq!(columns[2]["unique"], json!(false), "{schema}");
        // 有空值的列不算唯一（unique 要求无空值、非空样本 > 0）。
        assert_eq!(columns[3]["unique"], json!(false), "{schema}");
        assert_eq!(
            columns[3]["primary_candidate_reason"],
            json!(""),
            "{schema}"
        );
    }

    #[test]
    fn schema_primary_candidate_falls_back_to_unique_first_column_only() {
        // 首列唯一短文本 → 候选（邮箱/名称这类自然键）。
        let header = vec!["邮箱".to_string(), "备注".to_string()];
        let rows = vec![
            vec![json!("a@example.com"), json!("甲")],
            vec![json!("b@example.com"), Value::Null],
        ];
        let schema = crate::excel_import::infer_schema(Some(&header), &rows, 1000);
        let columns = schema["columns"].as_array().unwrap();
        assert_eq!(
            columns[0]["primary_candidate_reason"],
            json!("first_column"),
            "{schema}"
        );
        assert_eq!(columns[0]["primary_candidate"], json!(true), "{schema}");
        assert_eq!(columns[1]["unique"], json!(false), "{schema}");

        // 首列文本超过 64 字符、或没有唯一列 → 没有候选（reason 空串）。
        let long_text = "长".repeat(65);
        let header = vec!["长描述".to_string(), "状态".to_string(), "备注".to_string()];
        let rows = vec![
            vec![json!(long_text), json!("paid"), json!("x")],
            vec![json!("另一段"), json!("paid"), json!("y")],
        ];
        let schema = crate::excel_import::infer_schema(Some(&header), &rows, 1000);
        let columns = schema["columns"].as_array().unwrap();
        for column in columns {
            assert_eq!(column["primary_candidate"], json!(false), "{schema}");
            assert_eq!(
                column["primary_candidate_reason"],
                json!(""),
                "{schema}"
            );
        }
    }

    #[test]
    fn schema_falls_back_to_numeric_positional_columns() {
        // header=false 的 Excel：列名是 column_1..N。
        let path = fixture(XLSX);
        let preview = preview(&sheet_spec(&path, None, 1, false), 10).unwrap();
        let columns = preview["schema"]["columns"].as_array().unwrap();
        assert_eq!(columns[0]["name"], json!("column_1"));
        assert_eq!(columns[0]["type"], json!("integer"));
    }

    #[test]
    fn schema_is_returned_for_text_formats_too() {
        let path = temp_file(
            "schema.csv",
            "id,score,when,label\n1,2.5,2024-01-01,x\n2,3.5,2024-01-02,y\n",
        );
        let spec = parse_spec(&path, ReadSpec::default(), csv_fields(true, ","));
        let preview_json = preview(&spec, 5).unwrap();
        let columns = preview_json["schema"]["columns"].as_array().unwrap();
        assert_eq!(
            columns[0]["type"],
            json!("integer"),
            "{}",
            preview_json["schema"]
        );
        assert_eq!(columns[1]["type"], json!("decimal"));
        assert_eq!(columns[2]["type"], json!("date"));
        assert_eq!(columns[3]["type"], json!("text"));
        assert_eq!(preview_json["sheet_used"], Value::Null);
    }

    fn multi_sheet_spreadsheetml() -> String {
        [
            "<?xml version=\"1.0\"?>",
            "<?mso-application progid=\"Excel.Sheet\"?>",
            "<Workbook xmlns:ss=\"urn:schemas-microsoft-com:office:spreadsheet\">",
            "<Worksheet ss:Name=\"第一表\"><Table>",
            "<Row><Cell><Data ss:Type=\"String\">id</Data></Cell><Cell><Data ss:Type=\"String\">名称</Data></Cell></Row>",
            "<Row><Cell><Data ss:Type=\"Number\">1</Data></Cell><Cell><Data ss:Type=\"String\">甲</Data></Cell></Row>",
            "<Row><Cell><Data ss:Type=\"Number\">2</Data></Cell><Cell><Data ss:Type=\"String\">乙</Data></Cell></Row>",
            "</Table></Worksheet>",
            "<Worksheet ss:Name=\"第二表\"><Table>",
            "<Row><Cell><Data ss:Type=\"String\">code</Data></Cell><Cell><Data ss:Type=\"String\">金额</Data></Cell></Row>",
            "<Row><Cell><Data ss:Type=\"String\">A</Data></Cell><Cell><Data ss:Type=\"Number\">9.5</Data></Cell></Row>",
            "</Table></Worksheet>",
            "</Workbook>",
        ]
        .join("\n")
    }

    #[test]
    fn spreadsheetml_supports_multiple_worksheets() {
        let path = temp_file("multi.xls", &multi_sheet_spreadsheetml());
        let info = inspect(&path).unwrap();
        assert_eq!(info["format"], json!("excel"), "{info}");
        let sheets = info["sheets"].as_array().unwrap();
        assert_eq!(sheets.len(), 2, "{info}");
        assert_eq!(sheets[0]["name"], json!("第一表"));
        assert_eq!(sheets[1]["name"], json!("第二表"));
        assert_eq!(info["sheet"], json!("第一表"));
        assert_eq!(info["fields"]["header"], json!(true));
        assert_eq!(info["streaming"], json!(true), "{info}");

        let (_, mut spec) = spec_from_inspect(&path);
        let first = preview(&spec, 10).unwrap();
        assert_eq!(first["streaming"], json!(true), "{first}");
        assert_eq!(first["header"], json!(["id", "名称"]));
        assert_eq!(first["records"][1]["values"], json!([1, "甲"]));
        // SpreadsheetML 的 Number 历史上是 f64（1.0），必须规范成整数并推断为 integer。
        let schema = &first["schema"];
        assert_eq!(schema["columns"][0]["type"], json!("integer"), "{schema}");
        assert_eq!(schema["columns"][0]["samples"], json!([1, 2]), "{schema}");

        spec.read.sheet = Some("第二表".to_string());
        let second = preview(&spec, 10).unwrap();
        assert_eq!(second["header"], json!(["code", "金额"]));
        assert_eq!(second["records"][1]["values"], json!(["A", 9.5]));
        // 多表时第二张表按序号也能选到。
        spec.read.sheet = Some("1".to_string());
        let by_index = preview(&spec, 10).unwrap();
        assert_eq!(by_index["sheet_used"], json!("第二表"));
    }

    #[test]
    fn sniff_detects_zip_ole2_and_spreadsheetml_by_content() {
        use crate::excel_import::{sniff, ExcelKind};
        let mut zip = vec![0x50, 0x4B, 0x03, 0x04];
        zip.extend_from_slice(b"...xl/workbook.xml...");
        assert_eq!(sniff(&zip, &[], "bin"), Some(ExcelKind::Xlsx));

        let mut xlsb = vec![0x50, 0x4B, 0x03, 0x04];
        xlsb.extend_from_slice(b"...xl/workbook.bin...");
        assert_eq!(sniff(&xlsb, &[], "bin"), Some(ExcelKind::Xlsb));

        let mut ods = vec![0x50, 0x4B, 0x03, 0x04];
        ods.extend_from_slice(b"...application/vnd.oasis.opendocument.spreadsheet...");
        assert_eq!(sniff(&ods, &[], "zip"), Some(ExcelKind::Ods));

        let mut ole2 = vec![0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
        ole2.extend_from_slice(b"whatever");
        assert_eq!(sniff(&ole2, &[], "doc"), Some(ExcelKind::Xls));

        let xml = b"<?xml version=\"1.0\"?>\n<?mso-application progid=\"Excel.Sheet\"?>\n<Workbook/>";
        assert_eq!(sniff(xml, &[], "xml"), Some(ExcelKind::SpreadsheetMl));
        assert_eq!(sniff(b"id,name\n1,Ada\n", &[], "csv"), None);
    }

    #[test]
    fn validate_converts_excel_cells_against_table_columns() {
        let path = fixture(XLSX);
        let (_, spec) = spec_from_inspect(&path);
        let columns = vec![
            column("id", "int", false),
            column("姓名", "varchar", true),
            column("入职日期", "date", true),
            column("活跃", "tinyint", true),
            column("评分", "decimal", true),
        ];
        let mapping = named_mapping(&[
            ("id", "id"),
            ("姓名", "姓名"),
            ("入职日期", "入职日期"),
            ("活跃", "活跃"),
            ("评分", "评分"),
        ]);
        let validate_spec = ValidateSpec {
            parse: spec,
            mapping: Some(mapping),
            database: Some("main".to_string()),
            table: Some("emp".to_string()),
        };
        let result = validate(
            &validate_spec,
            Some(&columns),
            100,
            std::fs::metadata(&path).unwrap().len(),
            &(|_| {}),
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(result["valid"], json!(4), "{result}");
        assert_eq!(result["invalid"], json!(0), "{result}");
        assert_eq!(
            result["header"],
            json!(["id", "姓名", "入职日期", "活跃", "评分", "备注", "登录时间", "打卡时间"]),
            "{result}"
        );
    }

    #[test]
    fn validate_reports_a_text_value_in_an_integer_column() {
        let path = fixture(XLSX);
        let (_, spec) = spec_from_inspect(&path);
        let columns = vec![column("id", "int", false), column("姓名", "varchar", true)];
        // 把「姓名」映射到整数列 id：4 行都应该失败。
        let mapping = named_mapping(&[("id", "姓名"), ("姓名", "id")]);
        let validate_spec = ValidateSpec {
            parse: spec,
            mapping: Some(mapping),
            database: Some("main".to_string()),
            table: Some("emp".to_string()),
        };
        let result = validate(
            &validate_spec,
            Some(&columns),
            100,
            0,
            &(|_| {}),
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(result["invalid"], json!(4), "{result}");
        assert!(
            result["issues"][0]["message"]
                .as_str()
                .unwrap()
                .contains("整数"),
            "{result}"
        );
    }

    #[test]
    fn probe_first_row_reads_the_selected_sheet() {
        let path = fixture(XLSX);
        let (_, spec) = spec_from_inspect(&path);
        let columns = vec![column("id", "int", false), column("姓名", "varchar", true)];
        let mapping = named_mapping(&[("id", "id"), ("姓名", "姓名")]);
        let mut validate_spec = ValidateSpec {
            parse: spec,
            mapping: Some(mapping),
            database: Some("main".to_string()),
            table: Some("emp".to_string()),
        };
        let probe = probe_first_row(&validate_spec, &columns).unwrap();
        assert_eq!(probe["values"], json!([1, "张伟"]), "{probe}");
        assert_eq!(probe["header"], json!(["id", "姓名", "入职日期", "活跃", "评分", "备注", "登录时间", "打卡时间"]));

        // 换一张表后试插的第一行也跟着换。
        validate_spec.parse.read.sheet = Some("订单".to_string());
        validate_spec.mapping = Some(named_mapping(&[("id", "订单号")]));
        let probe = probe_first_row(&validate_spec, &columns[..1]).unwrap();
        assert_eq!(probe["values"], json!([1001]), "{probe}");
        assert_eq!(probe["header"], json!(["订单号", "客户", "金额"]));
    }

    #[test]
    fn inspect_large_spreadsheetml_is_metadata_only() {
        // 用一个巨大的 XML 注释把文件撑过 8 MB：inspect 现在是单次流式扫描，
        // 只统计表名/行数/列数，不保存任何单元格，也不再有「大文件轻量分支」。
        let mut xml = String::from(
            "<?xml version=\"1.0\"?>\n<?mso-application progid=\"Excel.Sheet\"?>\n<Workbook xmlns:ss=\"urn:schemas-microsoft-com:office:spreadsheet\">\n<!--",
        );
        while xml.len() < 8 * 1024 * 1024 + 1024 {
            xml.push('x');
        }
        xml.push_str("-->\n");
        xml.push_str(
            "<Worksheet ss:Name=\"大表\"><Table><Row><Cell><Data ss:Type=\"String\">id</Data></Cell></Row><Row><Cell><Data ss:Type=\"Number\">1</Data></Cell></Row></Table></Worksheet>",
        );
        xml.push_str(
            "<Worksheet ss:Name=\"第二表\"><Table><Row><Cell><Data ss:Type=\"String\">code</Data></Cell></Row><Row><Cell><Data ss:Type=\"String\">A</Data></Cell></Row></Table></Worksheet>",
        );
        xml.push_str("</Workbook>");
        let path = temp_file("large.xls", &xml);
        let info = inspect(&path).unwrap();
        assert_eq!(info["format"], json!("excel"), "{info}");
        assert_eq!(info["sheet"], json!("大表"));
        assert_eq!(info["streaming"], json!(true));
        let sheets = info["sheets"].as_array().unwrap();
        assert_eq!(sheets.len(), 2, "{info}");
        // 流式扫描后每张表都有行数/列数（不再为了行数整表载入）。
        assert_eq!(sheets[0]["rows"], json!(2), "{info}");
        assert_eq!(sheets[1]["rows"], json!(2), "{info}");
        assert_eq!(sheets[1]["cols"], json!(1), "{info}");
        assert!(!info["warnings"].to_string().contains("文件较大"), "{info}");
        assert_eq!(info["fields"]["header"], json!(true));

        // 选其他工作表时同样能正常 preview（此时才逐行解析该表）。
        let mut read: ReadSpec = serde_json::from_value(info["read"].clone()).unwrap();
        read.sheet = Some("第二表".to_string());
        let fields: FieldSpec = serde_json::from_value(info["fields"].clone()).unwrap();
        let spec = parse_spec(&path, read, fields);
        let preview = preview(&spec, 10).unwrap();
        assert_eq!(preview["sheet_used"], json!("第二表"));
        assert_eq!(preview["header"], json!(["code"]));
        assert_eq!(preview["streaming"], json!(true));
    }

    #[tokio::test]
    async fn execute_imports_excel_rows_into_a_real_sqlite_table() {
        let path = fixture(XLSX);
        let dir = std::env::temp_dir().join(format!("rma-excel-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let db_path = dir.join("main.sqlite");
        std::fs::write(&db_path, []).unwrap();
        let conn_spec = ConnSpec {
            driver: DriverKind::Sqlite,
            database: Some(db_path.to_string_lossy().into_owned()),
            ..Default::default()
        };
        let pool = crate::drivers::connect(&conn_spec, None).await.unwrap();
        let conn = crate::drivers::pooled_handle(pool, DriverKind::Sqlite, None);
        let setup = conn
            .run_raw(
                "CREATE TABLE emp (id INTEGER PRIMARY KEY, name TEXT, hired TEXT, active INTEGER, score REAL, note TEXT, login_at TEXT, clock TEXT)",
            )
            .await;
        assert!(setup.error.is_none(), "{:?}", setup.error);

        let (_, spec) = spec_from_inspect(&path);
        let columns = vec![
            column("id", "INTEGER", false),
            column("name", "TEXT", true),
            column("hired", "TEXT", true),
            column("active", "INTEGER", true),
            column("score", "REAL", true),
            column("note", "TEXT", true),
            column("login_at", "TEXT", true),
            column("clock", "TEXT", true),
        ];
        let mapping = named_mapping(&[
            ("id", "id"),
            ("name", "姓名"),
            ("hired", "入职日期"),
            ("active", "活跃"),
            ("score", "评分"),
            ("note", "备注"),
            ("login_at", "登录时间"),
            ("clock", "打卡时间"),
        ]);
        let execute_spec = ExecuteSpec {
            validate: ValidateSpec {
                parse: spec,
                mapping: Some(mapping),
                database: Some("main".to_string()),
                table: Some("emp".to_string()),
            },
            options: ExecuteOptions::default(),
        };
        let progress: Mutex<Vec<Progress>> = Mutex::new(Vec::new());
        let report = |value: &Progress| {
            if let Ok(mut guard) = progress.lock() {
                guard.push(value.clone());
            }
        };
        let total_bytes = std::fs::metadata(&path).unwrap().len();
        let driver = crate::drivers::sqlite::driver::SqliteDriver;
        let result = execute(
            &driver,
            &conn,
            &execute_spec,
            &columns,
            total_bytes,
            &report,
            &AtomicBool::new(false),
        )
        .await
        .unwrap();
        assert_eq!(result["rows_inserted"], json!(4), "{result}");
        assert_eq!(result["rows_failed"], json!(0), "{result}");
        assert_eq!(conn.fetch_i64("SELECT COUNT(*) FROM emp".to_string()).await.unwrap(), 4);
        let row = conn
            .fetch_named(
                "SELECT id, name, hired, active, score, note, login_at, clock FROM emp WHERE id = 2"
                    .to_string(),
            )
            .await
            .unwrap();
        assert_eq!(row.len(), 1);
        assert_eq!(row[0]["name"], json!("李娜"));
        assert_eq!(row[0]["score"].as_f64(), Some(92.0), "{:?}", row[0]);
        assert_eq!(row[0]["clock"], json!("09:05:30"));

        // Excel 的进度必须按行数走，并在 message 里说明工作表。
        let last = progress.lock().unwrap().last().cloned().expect("progress");
        assert_eq!(last.percent, 100.0, "{last:?}");
        assert!(last.message.contains("工作表 员工"), "{last:?}");
        assert!(last.records >= 5, "header + 4 data rows: {last:?}");
    }

    #[test]
    fn structured_boolean_values_convert_for_boolean_columns() {
        // Excel cells / JSON booleans arrive as Value::Bool (or 0/1), not as the
        // text that the CSV path sees. A PostgreSQL BOOLEAN column imports from
        // a workbook only if this path converts them.
        let flag = column("active", "boolean", true);
        let mapping = MappingSpec::default();
        assert_eq!(
            convert_value(Value::Bool(true), &flag, &mapping).unwrap(),
            Value::Bool(true)
        );
        assert_eq!(
            convert_value(Value::Bool(false), &flag, &mapping).unwrap(),
            Value::Bool(false)
        );
        assert_eq!(
            convert_value(json!(1), &flag, &mapping).unwrap(),
            Value::Bool(true)
        );
        assert_eq!(
            convert_value(json!(0), &flag, &mapping).unwrap(),
            Value::Bool(false)
        );
        assert!(convert_value(json!(2), &flag, &mapping).is_err());
        // Text still goes through the string branch above.
        assert_eq!(
            convert_value(json!("YES"), &flag, &mapping).unwrap(),
            Value::Bool(true)
        );
        // NULL stays NULL.
        assert_eq!(convert_value(Value::Null, &flag, &mapping).unwrap(), Value::Null);
    }

    // ------------------------------------------------ 流式读取（第 51 轮）

    /// 用 zip writer 在测试内合成一个最小 xlsx：不依赖外部 fixture / Python。
    fn synthetic_xlsx(path: &str, big_rows: usize) {
        let workbook = [
            "<?xml version=\"1.0\"?><workbook xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>",
            "<sheet name=\"Big\" sheetId=\"1\" r:id=\"rId1\"/>",
            "<sheet name=\"Small\" sheetId=\"2\" r:id=\"rId2\"/>",
            "<sheet name=\"Hidden\" sheetId=\"3\" state=\"hidden\" r:id=\"rId3\"/>",
            "</sheets></workbook>",
        ]
        .join("");
        let rels = [
            "<?xml version=\"1.0\"?><Relationships>",
            "<Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\"/>",
            "<Relationship Id=\"rId2\" Target=\"worksheets/sheet2.xml\"/>",
            "<Relationship Id=\"rId3\" Target=\"worksheets/sheet3.xml\"/>",
            "</Relationships>",
        ]
        .join("");
        let mut big = String::from("<?xml version=\"1.0\"?><worksheet>");
        big.push_str(&format!("<dimension ref=\"A1:C{}\"/>", big_rows + 1));
        big.push_str("<sheetData>");
        big.push_str("<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>id</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>name</t></is></c><c r=\"C1\" t=\"inlineStr\"><is><t>flag</t></is></c></row>");
        for row in 1..=big_rows {
            big.push_str(&format!(
                "<row r=\"{0}\"><c r=\"A{0}\"><v>{1}</v></c><c r=\"B{0}\" t=\"inlineStr\"><is><t>名称{1}</t></is></c><c r=\"C{0}\" t=\"b\"><v>{2}</v></c></row>",
                row + 1,
                row,
                if row % 2 == 0 { 1 } else { 0 }
            ));
        }
        big.push_str("</sheetData></worksheet>");
        let small = concat!(
            "<?xml version=\"1.0\"?><worksheet><dimension ref=\"A1:B4\"/><sheetData>",
            "<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>name</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>score</t></is></c></row>",
            "<row r=\"2\"><c r=\"A2\" t=\"inlineStr\"><is><t>a</t></is></c><c r=\"B2\"><v>1.5</v></c></row>",
            "<row r=\"3\"><c r=\"A3\" t=\"inlineStr\"><is><t>b</t></is></c><c r=\"B3\"><v>2</v></c></row>",
            "<row r=\"4\"><c r=\"A4\" t=\"inlineStr\"><is><t>c</t></is></c><c r=\"B4\"><v>3.5</v></c></row>",
            "</sheetData></worksheet>",
        );
        let hidden = "<?xml version=\"1.0\"?><worksheet><dimension ref=\"A1:A2\"/><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>secret</t></is></c></row></sheetData></worksheet>";
        let entries: Vec<(&str, String, bool)> = vec![
            ("xl/workbook.xml", workbook, false),
            ("xl/_rels/workbook.xml.rels", rels, false),
            ("xl/worksheets/sheet1.xml", big, false),
            ("xl/worksheets/sheet2.xml", small.to_string(), false),
            ("xl/worksheets/sheet3.xml", hidden.to_string(), false),
        ];
        let file = File::create(path).unwrap();
        let mut writer = zip::ZipWriter::new(file);
        for (name, content, stored) in entries {
            let options = zip::write::SimpleFileOptions::default()
                .compression_method(if stored {
                    zip::CompressionMethod::Stored
                } else {
                    zip::CompressionMethod::Deflated
                });
            writer.start_file(name, options).unwrap();
            writer.write_all(content.as_bytes()).unwrap();
        }
        writer.finish().unwrap();
    }

    fn temp_path(name: &str) -> String {
        let dir = std::env::temp_dir().join(format!("rma-stream-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join(name).to_string_lossy().to_string()
    }

    #[test]
    fn streaming_xlsx_large_sheet_preview_validate_and_schema() {
        let path = temp_path("large.xlsx");
        let big_rows = 20_000usize;
        synthetic_xlsx(&path, big_rows);

        // inspect 只读 workbook/rels/dimension + 前两行，不解析 2 万行数据。
        let (info, spec) = spec_from_inspect(&path);
        assert_eq!(info["format"], json!("xlsx"), "{info}");
        assert_eq!(info["streaming"], json!(true), "{info}");
        assert_eq!(info["sheet"], json!("Big"));
        let sheets = info["sheets"].as_array().unwrap();
        assert_eq!(sheets.len(), 2, "hidden sheet 不列出: {info}");
        assert_eq!(sheets[0]["name"], json!("Big"));
        assert_eq!(sheets[0]["rows"], json!((big_rows + 1) as u64));
        assert_eq!(sheets[0]["cols"], json!(3));
        assert!(
            info["warnings"].to_string().contains("隐藏工作表"),
            "{info}"
        );
        assert_eq!(info["fields"]["header"], json!(true));

        // 默认表 preview 只回显 limit 条，但 schema 仍扫 1000 行。
        let big_preview = preview(&spec, 5).unwrap();
        assert_eq!(big_preview["sheet_used"], json!("Big"));
        assert_eq!(big_preview["streaming"], json!(true));
        assert_eq!(big_preview["header"], json!(["id", "name", "flag"]));
        assert_eq!(big_preview["records"].as_array().unwrap().len(), 5);
        assert_eq!(big_preview["records"][1]["values"], json!([1, "名称1", false]));
        assert_eq!(big_preview["records"][2]["values"], json!([2, "名称2", true]));
        let columns = big_preview["schema"]["columns"].as_array().unwrap();
        assert_eq!(columns[0]["type"], json!("integer"), "{big_preview}");
        assert_eq!(columns[1]["type"], json!("text"));
        assert_eq!(columns[2]["type"], json!("boolean"));
        assert_eq!(big_preview["schema"]["sample_count"], json!(1000));

        // 按名字选第二张表；表头/数据完全不同。
        let mut small_spec = spec.clone();
        small_spec.read.sheet = Some("Small".to_string());
        let small = preview(&small_spec, 5).unwrap();
        assert_eq!(small["sheet_used"], json!("Small"));
        assert_eq!(small["header"], json!(["name", "score"]));
        assert_eq!(small["records"][1]["values"], json!(["a", 1.5]));

        // validate 仍然逐行解析全部 2 万行（不物化）。
        let validate_spec = ValidateSpec {
            parse: spec.clone(),
            mapping: None,
            database: None,
            table: None,
        };
        let progress: Mutex<Vec<Progress>> = Mutex::new(Vec::new());
        let report = |value: &Progress| {
            if let Ok(mut guard) = progress.lock() {
                guard.push(value.clone());
            }
        };
        let result = validate(
            &validate_spec,
            None,
            100,
            std::fs::metadata(&path).unwrap().len(),
            &report,
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(result["ok"], json!(true), "{result}");
        assert_eq!(result["data_records"], json!(big_rows as u64), "{result}");
        assert_eq!(result["valid"], json!(big_rows as u64), "{result}");
        assert_eq!(
            result["header"],
            json!(["id", "name", "flag"]),
            "{result}"
        );
        let last = progress.lock().unwrap().last().cloned().expect("progress");
        assert_eq!(last.percent, 100.0, "{last:?}");
        assert!(last.message.contains("工作表 Big"), "{last:?}");
    }

    #[tokio::test]
    async fn streaming_xlsx_execute_inserts_large_sheet_rows() {
        let path = temp_path("execute.xlsx");
        let rows = 2_000usize;
        synthetic_xlsx(&path, rows);

        let dir = std::env::temp_dir().join(format!("rma-stream-db-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let db_path = dir.join("main.sqlite");
        std::fs::write(&db_path, []).unwrap();
        let conn_spec = ConnSpec {
            driver: DriverKind::Sqlite,
            database: Some(db_path.to_string_lossy().into_owned()),
            ..Default::default()
        };
        let pool = crate::drivers::connect(&conn_spec, None).await.unwrap();
        let conn = crate::drivers::pooled_handle(pool, DriverKind::Sqlite, None);
        let setup = conn
            .run_raw(
                "CREATE TABLE big (id INTEGER PRIMARY KEY, name TEXT, flag INTEGER)",
            )
            .await;
        assert!(setup.error.is_none(), "{:?}", setup.error);

        let (_, spec) = spec_from_inspect(&path);
        let columns = vec![
            column("id", "INTEGER", false),
            column("name", "TEXT", true),
            column("flag", "INTEGER", true),
        ];
        let mapping = named_mapping(&[("id", "id"), ("name", "name"), ("flag", "flag")]);
        let execute_spec = ExecuteSpec {
            validate: ValidateSpec {
                parse: spec,
                mapping: Some(mapping),
                database: Some("main".to_string()),
                table: Some("big".to_string()),
            },
            options: ExecuteOptions::default(),
        };
        let progress: Mutex<Vec<Progress>> = Mutex::new(Vec::new());
        let report = |value: &Progress| {
            if let Ok(mut guard) = progress.lock() {
                guard.push(value.clone());
            }
        };
        let driver = crate::drivers::sqlite::driver::SqliteDriver;
        let result = execute(
            &driver,
            &conn,
            &execute_spec,
            &columns,
            std::fs::metadata(&path).unwrap().len(),
            &report,
            &AtomicBool::new(false),
        )
        .await
        .unwrap();
        assert_eq!(result["rows_inserted"], json!(rows as u64), "{result}");
        assert_eq!(result["rows_failed"], json!(0), "{result}");
        assert_eq!(
            conn.fetch_i64("SELECT COUNT(*) FROM big".to_string())
                .await
                .unwrap(),
            rows as i64
        );
        let last = progress.lock().unwrap().last().cloned().expect("progress");
        assert_eq!(last.percent, 100.0, "{last:?}");
        assert!(last.message.contains("工作表 Big"), "{last:?}");
    }

    #[test]
    fn streaming_spreadsheetml_validate_reports_row_progress() {
        let path = temp_file("stream_sml.xls", &multi_sheet_spreadsheetml());
        let (info, spec) = spec_from_inspect(&path);
        assert_eq!(info["streaming"], json!(true), "{info}");
        let progress: Mutex<Vec<Progress>> = Mutex::new(Vec::new());
        let report = |value: &Progress| {
            if let Ok(mut guard) = progress.lock() {
                guard.push(value.clone());
            }
        };
        let validate_spec = ValidateSpec {
            parse: spec,
            mapping: None,
            database: None,
            table: None,
        };
        let result = validate(
            &validate_spec,
            None,
            100,
            std::fs::metadata(&path).unwrap().len(),
            &report,
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(result["data_records"], json!(2), "{result}");
        assert_eq!(result["valid"], json!(2), "{result}");
        let last = progress.lock().unwrap().last().cloned().expect("progress");
        assert_eq!(last.percent, 100.0, "unknown total must still finish 100%: {last:?}");
        assert!(
            last.message.contains("工作表 第一表") && last.message.contains("行"),
            "{last:?}"
        );
    }

    #[test]
    fn xls_streaming_report_has_no_fallback_warning() {
        let path = fixture(XLS);
        let (info, spec) = spec_from_inspect(&path);
        assert_eq!(info["streaming"], json!(true), "{info}");
        assert!(
            !info["warnings"].to_string().contains("暂未流式"),
            "{info}"
        );
        let preview = preview(&spec, 5).unwrap();
        assert_eq!(preview["streaming"], json!(true), "{preview}");
        assert!(
            !preview["warnings"].to_string().contains("暂未流式"),
            "{preview}"
        );
    }

    #[test]
    fn streaming_ods_preview_and_sheet_selection() {
        let path = temp_path("stream.ods");
        let mimetype = "application/vnd.oasis.opendocument.spreadsheet".to_string();
        let content = concat!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" ",
            "xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" ",
            "xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\">",
            "<office:body><office:spreadsheet>",
            "<table:table table:name=\"员工\">",
            "<table:table-row>",
            "<table:table-cell office:value-type=\"string\"><text:p>id</text:p></table:table-cell>",
            "<table:table-cell office:value-type=\"string\"><text:p>姓名</text:p></table:table-cell>",
            "<table:table-cell office:value-type=\"string\"><text:p>活跃</text:p></table:table-cell>",
            "</table:table-row>",
            "<table:table-row>",
            "<table:table-cell office:value-type=\"float\" office:value=\"1\"/>",
            "<table:table-cell office:value-type=\"string\"><text:p>张伟</text:p></table:table-cell>",
            "<table:table-cell office:value-type=\"boolean\" office:boolean-value=\"true\"/>",
            "</table:table-row>",
            "<table:table-row>",
            "<table:table-cell office:value-type=\"float\" office:value=\"2\"/>",
            "<table:table-cell office:value-type=\"string\"><text:p>李娜</text:p></table:table-cell>",
            "<table:table-cell office:value-type=\"boolean\" office:boolean-value=\"false\"/>",
            "</table:table-row>",
            "</table:table>",
            "<table:table table:name=\"第二表\">",
            "<table:table-row>",
            "<table:table-cell office:value-type=\"string\"><text:p>code</text:p></table:table-cell>",
            "<table:table-cell office:value-type=\"string\"><text:p>金额</text:p></table:table-cell>",
            "</table:table-row>",
            "<table:table-row>",
            "<table:table-cell office:value-type=\"string\"><text:p>A</text:p></table:table-cell>",
            "<table:table-cell office:value-type=\"float\" office:value=\"9.5\"/>",
            "</table:table-row>",
            "</table:table>",
            "</office:spreadsheet></office:body></office:document-content>",
        )
        .to_string();
        let entries: Vec<(&str, String, bool)> = vec![
            ("mimetype", mimetype, true),
            ("content.xml", content, false),
        ];
        let file = File::create(&path).unwrap();
        let mut writer = zip::ZipWriter::new(file);
        for (name, content, stored) in entries {
            let options = zip::write::SimpleFileOptions::default()
                .compression_method(if stored {
                    zip::CompressionMethod::Stored
                } else {
                    zip::CompressionMethod::Deflated
                });
            writer.start_file(name, options).unwrap();
            writer.write_all(content.as_bytes()).unwrap();
        }
        writer.finish().unwrap();

        let (info, spec) = spec_from_inspect(&path);
        assert_eq!(info["format"], json!("ods"), "{info}");
        assert_eq!(info["streaming"], json!(true), "{info}");
        assert_eq!(info["sheet"], json!("员工"));
        let sheets = info["sheets"].as_array().unwrap();
        assert_eq!(sheets.len(), 2, "{info}");
        assert_eq!(sheets[0]["rows"], json!(3), "{info}");
        assert_eq!(sheets[0]["cols"], json!(3), "{info}");

        let employees = preview(&spec, 5).unwrap();
        assert_eq!(employees["sheet_used"], json!("员工"));
        assert_eq!(employees["header"], json!(["id", "姓名", "活跃"]));
        assert_eq!(employees["records"][1]["values"], json!([1, "张伟", true]));
        assert_eq!(employees["records"][2]["values"], json!([2, "李娜", false]));

        let mut second = spec.clone();
        second.read.sheet = Some("第二表".to_string());
        let preview = preview(&second, 5).unwrap();
        assert_eq!(preview["header"], json!(["code", "金额"]));
        assert_eq!(preview["records"][1]["values"], json!(["A", 9.5]));
    }


    #[test]
    fn streaming_xlsx_without_dimension_degrades_progress_gracefully() {
        // 有些生成器不写 <dimension>：此时总行数未知，进度必须退化成
        // 「工作表 X · 第 N 行」并在读完时到达 100%。
        let path = temp_path("no_dimension.xlsx");
        let workbook = "<?xml version=\"1.0\"?><workbook><sheets><sheet name=\"NoDim\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>";
        let rels = "<?xml version=\"1.0\"?><Relationships><Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\"/></Relationships>";
        let mut sheet = String::from("<?xml version=\"1.0\"?><worksheet><sheetData>");
        sheet.push_str("<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>id</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>name</t></is></c></row>");
        for row in 1..=500 {
            sheet.push_str(&format!(
                "<row r=\"{}\"><c r=\"A{}\"><v>{}</v></c><c r=\"B{}\" t=\"inlineStr\"><is><t>行{}</t></is></c></row>",
                row + 1,
                row + 1,
                row,
                row + 1,
                row
            ));
        }
        sheet.push_str("</sheetData></worksheet>");
        let file = File::create(&path).unwrap();
        let mut writer = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        for (name, content) in [
            ("xl/workbook.xml", workbook),
            ("xl/_rels/workbook.xml.rels", rels),
            ("xl/worksheets/sheet1.xml", sheet.as_str()),
        ] {
            writer.start_file(name, options).unwrap();
            writer.write_all(content.as_bytes()).unwrap();
        }
        writer.finish().unwrap();

        let (info, spec) = spec_from_inspect(&path);
        assert_eq!(info["streaming"], json!(true), "{info}");
        // 没有 dimension：inspect 的 sheets[] 省略 rows/cols。
        assert!(
            info["sheets"][0].get("rows").is_none(),
            "{}",
            info["sheets"][0]
        );
        let preview = preview(&spec, 3).unwrap();
        assert_eq!(preview["header"], json!(["id", "name"]));
        assert_eq!(preview["records"][1]["values"], json!([1, "行1"]));

        let progress: Mutex<Vec<Progress>> = Mutex::new(Vec::new());
        let report = |value: &Progress| {
            if let Ok(mut guard) = progress.lock() {
                guard.push(value.clone());
            }
        };
        let result = validate(
            &ValidateSpec {
                parse: spec,
                mapping: None,
                database: None,
                table: None,
            },
            None,
            100,
            std::fs::metadata(&path).unwrap().len(),
            &report,
            &AtomicBool::new(false),
        )
        .unwrap();
        assert_eq!(result["data_records"], json!(500), "{result}");
        let last = progress.lock().unwrap().last().cloned().expect("progress");
        assert_eq!(last.percent, 100.0, "{last:?}");
        // 总行数未知：只报「第 N 行」（N 含表头行），不带 /M。
        assert!(
            last.message.contains("工作表 NoDim") && last.message.contains("行"),
            "{last:?}"
        );
        assert!(!last.message.contains('/'), "{last:?}");
    }

    // ------------------------------------------------ P2-11 隐藏工作表（第 53 轮）

    /// 用 zip writer 在测试内合成 ODS；content.xml 由调用方提供。
    fn synthetic_ods(path: &str, content: &str) {
        let file = File::create(path).unwrap();
        let mut writer = zip::ZipWriter::new(file);
        writer
            .start_file(
                "mimetype",
                zip::write::SimpleFileOptions::default()
                    .compression_method(zip::CompressionMethod::Stored),
            )
            .unwrap();
        writer
            .write_all(b"application/vnd.oasis.opendocument.spreadsheet")
            .unwrap();
        writer
            .start_file(
                "content.xml",
                zip::write::SimpleFileOptions::default()
                    .compression_method(zip::CompressionMethod::Deflated),
            )
            .unwrap();
        writer.write_all(content.as_bytes()).unwrap();
        writer.finish().unwrap();
    }

    /// 2 张可见表 + 3 张隐藏表（display / visibility / style 继承各一种）。
    const ODS_WITH_HIDDEN_SHEETS: &str = concat!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
        "<office:document-content ",
        "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" ",
        "xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" ",
        "xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" ",
        "xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\">",
        "<office:automatic-styles>",
        "<style:style style:name=\"ta_hidden\" style:family=\"table\">",
        "<style:table-properties table:display=\"false\"/>",
        "</style:style>",
        "</office:automatic-styles>",
        "<office:body><office:spreadsheet>",
        "<table:table table:name=\"员工\">",
        "<table:table-row>",
        "<table:table-cell office:value-type=\"string\"><text:p>id</text:p></table:table-cell>",
        "<table:table-cell office:value-type=\"string\"><text:p>姓名</text:p></table:table-cell>",
        "</table:table-row>",
        "<table:table-row>",
        "<table:table-cell office:value-type=\"float\" office:value=\"1\"/>",
        "<table:table-cell office:value-type=\"string\"><text:p>张伟</text:p></table:table-cell>",
        "</table:table-row>",
        "<table:table-row>",
        "<table:table-cell office:value-type=\"float\" office:value=\"2\"/>",
        "<table:table-cell office:value-type=\"string\"><text:p>李娜</text:p></table:table-cell>",
        "</table:table-row>",
        "</table:table>",
        "<table:table table:name=\"隐藏A\" table:display=\"false\">",
        "<table:table-row><table:table-cell office:value-type=\"string\"><text:p>secret-a</text:p></table:table-cell></table:table-row>",
        "</table:table>",
        "<table:table table:name=\"隐藏B\" table:visibility=\"collapse\">",
        "<table:table-row><table:table-cell office:value-type=\"string\"><text:p>secret-b</text:p></table:table-cell></table:table-row>",
        "</table:table>",
        "<table:table table:name=\"隐藏C\" table:style-name=\"ta_hidden\">",
        "<table:table-row><table:table-cell office:value-type=\"string\"><text:p>secret-c</text:p></table:table-cell></table:table-row>",
        "</table:table>",
        "<table:table table:name=\"第二表\">",
        "<table:table-row>",
        "<table:table-cell office:value-type=\"string\"><text:p>code</text:p></table:table-cell>",
        "</table:table-row>",
        "<table:table-row>",
        "<table:table-cell office:value-type=\"string\"><text:p>A</text:p></table:table-cell>",
        "</table:table-row>",
        "</table:table>",
        "</office:spreadsheet></office:body></office:document-content>",
    );

    #[test]
    fn ods_hidden_sheets_are_excluded_counted_and_unselectable() {
        let path = temp_path("hidden.ods");
        synthetic_ods(&path, ODS_WITH_HIDDEN_SHEETS);
        let (info, mut spec) = spec_from_inspect(&path);
        assert_eq!(info["format"], json!("ods"), "{info}");
        assert_eq!(info["sheet"], json!("员工"), "{info}");
        let sheets = info["sheets"].as_array().unwrap();
        assert_eq!(sheets.len(), 2, "隐藏表必须从 sheets 里排除: {info}");
        assert_eq!(sheets[0]["name"], json!("员工"));
        assert_eq!(sheets[1]["name"], json!("第二表"));
        // 隐藏表的行不计入任何可见表。
        assert_eq!(sheets[0]["rows"], json!(3), "{info}");
        assert!(
            info["warnings"]
                .to_string()
                .contains("已忽略 3 个隐藏工作表"),
            "{info}"
        );
        // InspectInfo.hidden_sheets 是 warning 的来源，直接断言它。
        let inspected = crate::excel_stream::inspect_workbook(
            &path,
            crate::excel_import::ExcelKind::Ods,
        )
        .unwrap();
        assert_eq!(inspected.hidden_sheets, 3, "ODS 三种隐藏写法都要计入");

        // 隐藏表名选不到；可选列表里也不能出现隐藏表。
        spec.read.sheet = Some("隐藏A".to_string());
        let error = preview(&spec, 5).unwrap_err().to_string();
        assert!(error.contains("找不到工作表 '隐藏A'"), "{error}");
        assert!(!error.contains("隐藏C"), "隐藏表不该出现在可选列表: {error}");
        spec.read.sheet = Some("隐藏C".to_string());
        assert!(preview(&spec, 5).is_err(), "样式继承隐藏的表也要选不到");

        // 可见表序号不含隐藏表：1 = 第二表。
        spec.read.sheet = Some("1".to_string());
        let second = preview(&spec, 5).unwrap();
        assert_eq!(second["sheet_used"], json!("第二表"), "{second}");
        assert_eq!(second["header"], json!(["code"]), "{second}");

        spec.read.sheet = Some("员工".to_string());
        let first = preview(&spec, 5).unwrap();
        assert_eq!(first["header"], json!(["id", "姓名"]), "{first}");
        assert_eq!(first["records"][1]["values"], json!([1, "张伟"]));
    }

    /// 2 张可见表 + 1 张 ss:Visibility="Hidden" 的 SpreadsheetML。
    const SML_WITH_HIDDEN_SHEETS: &str = concat!(
        "<?xml version=\"1.0\"?>",
        "<?mso-application progid=\"Excel.Sheet\"?>",
        "<Workbook xmlns:ss=\"urn:schemas-microsoft-com:office:spreadsheet\">",
        "<Worksheet ss:Name=\"员工\"><Table>",
        "<Row><Cell><Data ss:Type=\"String\">id</Data></Cell><Cell><Data ss:Type=\"String\">姓名</Data></Cell></Row>",
        "<Row><Cell><Data ss:Type=\"Number\">1</Data></Cell><Cell><Data ss:Type=\"String\">张伟</Data></Cell></Row>",
        "<Row><Cell><Data ss:Type=\"Number\">2</Data></Cell><Cell><Data ss:Type=\"String\">李娜</Data></Cell></Row>",
        "</Table></Worksheet>",
        "<Worksheet ss:Name=\"隐藏页\" ss:Visibility=\"Hidden\"><Table>",
        "<Row><Cell><Data ss:Type=\"String\">secret</Data></Cell></Row>",
        "</Table></Worksheet>",
        "<Worksheet ss:Name=\"第二表\"><Table>",
        "<Row><Cell><Data ss:Type=\"String\">code</Data></Cell></Row>",
        "<Row><Cell><Data ss:Type=\"String\">A</Data></Cell></Row>",
        "</Table></Worksheet>",
        "</Workbook>",
    );

    #[test]
    fn spreadsheetml_hidden_sheets_are_excluded_counted_and_unselectable() {
        let path = temp_file("hidden_sml.xls", SML_WITH_HIDDEN_SHEETS);
        let (info, mut spec) = spec_from_inspect(&path);
        assert_eq!(info["format"], json!("excel"), "{info}");
        let sheets = info["sheets"].as_array().unwrap();
        assert_eq!(sheets.len(), 2, "隐藏表必须从 sheets 里排除: {info}");
        assert_eq!(sheets[0]["name"], json!("员工"));
        assert_eq!(sheets[1]["name"], json!("第二表"));
        assert!(
            info["warnings"]
                .to_string()
                .contains("已忽略 1 个隐藏工作表"),
            "{info}"
        );
        let inspected = crate::excel_stream::inspect_workbook(
            &path,
            crate::excel_import::ExcelKind::SpreadsheetMl,
        )
        .unwrap();
        assert_eq!(inspected.hidden_sheets, 1);

        spec.read.sheet = Some("隐藏页".to_string());
        let error = preview(&spec, 5).unwrap_err().to_string();
        assert!(error.contains("找不到工作表 '隐藏页'"), "{error}");

        // 可见表序号不含隐藏表：1 = 第二表（行源也要跳过隐藏表）。
        spec.read.sheet = Some("1".to_string());
        let second = preview(&spec, 5).unwrap();
        assert_eq!(second["sheet_used"], json!("第二表"), "{second}");
        assert_eq!(second["header"], json!(["code"]), "{second}");
        assert_eq!(second["records"][1]["values"], json!(["A"]), "{second}");

        spec.read.sheet = Some("员工".to_string());
        let first = preview(&spec, 5).unwrap();
        assert_eq!(first["header"], json!(["id", "姓名"]), "{first}");
        assert_eq!(first["records"][1]["values"], json!([1, "张伟"]), "{first}");
    }

    // ------------------------------------------------ P3 错误文案（第 53 轮）

    /// 造一个只含指定流名的 OLE2/CFB（模拟加密的 xlsx/xlsb 或被包装的 Office 文件）。
    fn synthetic_cfb(path: &str, streams: &[&str]) {
        let mut cfb = cfb::create(path).expect("create cfb");
        for name in streams {
            let mut stream = cfb.create_stream(*name).expect("create stream");
            std::io::Write::write_all(&mut stream, b"not a real stream payload").expect("write");
        }
        cfb.flush().expect("flush cfb");
    }

    #[test]
    fn encrypted_ooxml_in_a_cfb_container_reports_a_chinese_password_hint() {
        // Office 的「密码保护」会把整个 xlsx/xlsb 包塞进 CFB（EncryptionInfo /
        // EncryptedPackage）。以前会被当成 xls，报
        // 「xls 里没有 Workbook/Book 数据流: No such stream」。
        let path = temp_path("encrypted.xlsx");
        synthetic_cfb(&path, &["EncryptionInfo", "EncryptedPackage"]);
        assert_eq!(
            crate::excel_import::detect(&path).unwrap(),
            Some(crate::excel_import::ExcelKind::Xls),
            "OLE2 内容仍然先按 xls 分派，由 xls_stream 识别加密容器"
        );
        let error = inspect(&path).unwrap_err().to_string();
        assert!(
            error.contains("文件已加密或是被 OLE2 容器包装的 Office 文件"),
            "{error}"
        );
        assert!(error.contains("密码"), "{error}");
        assert!(error.contains(".xlsx/.xlsb"), "{error}");
        assert!(!error.contains("No such stream"), "{error}");
    }

    #[test]
    fn cfb_without_a_workbook_stream_reports_chinese_with_raw_detail() {
        // 加密的 .xls（或其它 Office 文档）同样没有 Workbook/Book 流：主文案中文，
        // 原始 cfb 细节保留在末尾便于排查。
        let path = temp_path("no_workbook.xls");
        synthetic_cfb(&path, &["SomethingElse"]);
        let error = inspect(&path).unwrap_err().to_string();
        assert!(error.contains("没有 Workbook/Book 数据流"), "{error}");
        assert!(error.contains("密码"), "{error}");
        assert!(error.contains("原始细节"), "{error}");
        assert!(
            error.contains("No such stream") || error.contains("not found"),
            "原始细节要保留: {error}"
        );
        assert!(
            !error.starts_with("xls 里没有 Workbook/Book 数据流:"),
            "英文主文案不该再出现在开头: {error}"
        );
    }

    #[test]
    fn html_disguised_as_an_excel_file_reports_a_chinese_hint() {
        let html = b"<!doctype html><html><head><meta charset=\"utf-8\"></head><body><table><tr><td>1</td></tr></table></body></html>";
        for ext in ["xls", "xlsx", "xlsb"] {
            let path = temp_path(&format!("fake.{ext}"));
            std::fs::write(&path, html).unwrap();
            let error = inspect(&path).unwrap_err().to_string();
            assert!(error.contains("扩展名是 Excel"), "{ext}: {error}");
            assert!(error.contains("不是 Excel 二进制格式"), "{ext}: {error}");
            assert!(
                error.contains("另存为 .xlsx/.xls 或用 CSV 导入"),
                "{ext}: {error}"
            );
            assert!(!error.contains("Expecting"), "不该泄漏 XML 解析器英文: {ext}: {error}");
        }

        // 普通 XML（不是 SpreadsheetML）同样给提示，而不是去解析它。
        let path = temp_path("fake_xml.xls");
        std::fs::write(&path, b"<?xml version=\"1.0\"?><root><item>1</item></root>").unwrap();
        let error = inspect(&path).unwrap_err().to_string();
        assert!(error.contains("扩展名是 Excel"), "{error}");
    }

    #[test]
    fn legitimate_spreadsheetml_xls_is_not_reported_as_a_fake_excel_file() {
        // 合法的 SpreadsheetML .xls 同样以 <?xml 开头：有 mso-application PI 的
        // 导出文件不能被误伤。
        let path = temp_file("legit.xls", &multi_sheet_spreadsheetml());
        let info = inspect(&path).expect("合法的 SpreadsheetML 必须照常识别");
        assert_eq!(info["format"], json!("excel"), "{info}");

        // 没有 PI、但根元素是 Workbook/Worksheet 的文件同样合法。
        let no_pi = concat!(
            "<?xml version=\"1.0\"?>",
            "<Workbook xmlns:ss=\"urn:schemas-microsoft-com:office:spreadsheet\">",
            "<Worksheet ss:Name=\"表1\"><Table>",
            "<Row><Cell><Data ss:Type=\"String\">id</Data></Cell></Row>",
            "<Row><Cell><Data ss:Type=\"Number\">1</Data></Cell></Row>",
            "</Table></Worksheet></Workbook>",
        );
        let path = temp_file("no_pi.xls", no_pi);
        let info = inspect(&path).expect("缺 PI 的 SpreadsheetML 也必须照常识别");
        assert_eq!(info["format"], json!("excel"), "{info}");
        assert_eq!(info["sheets"][0]["name"], json!("表1"), "{info}");
    }

    #[test]
    fn missing_and_unreadable_paths_report_chinese_messages() {
        let missing = std::env::temp_dir().join(format!(
            "rma-missing-{}.csv",
            uuid::Uuid::new_v4()
        ));
        let shown = missing.to_string_lossy().to_string();
        let error = file_info(&shown).unwrap_err().to_string();
        assert!(error.contains("文件不存在或无法访问："), "{error}");
        assert!(error.contains(&shown), "路径要保留: {error}");
        // OS 原文放在括号里，主文案保持中文。
        assert!(error.contains('（') && error.contains('）'), "{error}");

        // 目录不是文件：沿用既有中文提示。
        let directory = std::env::temp_dir();
        let error = file_info(&directory.to_string_lossy()).unwrap_err().to_string();
        assert!(error.contains("选择的路径不是文件"), "{error}");
    }

    // ------------------------------ 第 54 轮：公开 API 端到端（import_inspect）

    /// 端到端入口：走 FFI 层实际调用的 api::data_import::import_inspect
    /// （内部就是 importer::inspect，第一步就会 file_info），不再直接调内部函数，
    /// 保证「用户在应用里看到的错误/警告」就是这里断言的。
    async fn inspect_via_api(path: &str) -> anyhow::Result<Value> {
        crate::api::data_import::import_inspect(path.to_string()).await
    }

    /// chmod 000 的父目录：Drop 时恢复权限并删除，保证断言失败也不会留下坏权限目录。
    #[cfg(unix)]
    struct LockedDirGuard {
        locked: std::path::PathBuf,
        root: std::path::PathBuf,
    }

    #[cfg(unix)]
    impl LockedDirGuard {
        /// 建 root/locked/data.csv，再把 locked 的权限改成 000（不可搜索 ⇒ EACCES）。
        fn new() -> (Self, String) {
            use std::os::unix::fs::PermissionsExt;
            let root = std::env::temp_dir().join(format!("rma-perm-{}", uuid::Uuid::new_v4()));
            let locked = root.join("locked");
            std::fs::create_dir_all(&locked).unwrap();
            let file = locked.join("data.csv");
            std::fs::write(&file, "id,name\n1,Ada\n").unwrap();
            std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o000)).unwrap();
            let guard = LockedDirGuard { locked, root };
            (guard, file.to_string_lossy().to_string())
        }
    }

    #[cfg(unix)]
    impl Drop for LockedDirGuard {
        fn drop(&mut self) {
            use std::os::unix::fs::PermissionsExt;
            // finally 语义：无论断言/panic 与否，先恢复 700 再删除。
            let _ = std::fs::set_permissions(&self.locked, std::fs::Permissions::from_mode(0o700));
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn inspect_api_reports_permission_denied_in_chinese() {
        let (guard, path) = LockedDirGuard::new();

        // 以 root 运行时 chmod 000 仍可访问：明确跳过（并说明原因），
        // 而不是把「没测到」伪装成通过。
        match std::fs::metadata(&path) {
            Ok(_) => {
                eprintln!(
                    "跳过 PermissionDenied 用例：当前进程可能是 root（chmod 000 的目录仍可读取）"
                );
                return;
            }
            Err(error) => assert_eq!(
                error.kind(),
                std::io::ErrorKind::PermissionDenied,
                "chmod 000 的父目录必须产生 EACCES: {error}"
            ),
        }

        let error = inspect_via_api(&path).await.unwrap_err().to_string();
        assert!(error.contains("没有权限读取文件"), "{error}");
        assert!(error.contains(&path), "路径要保留: {error}");
        // 括号里保留 OS 原文（英文），便于排查；不同平台措辞不同，只认特征。
        assert!(
            error.contains("os error 13")
                || error.contains("Permission denied")
                || error.contains("Operation not permitted"),
            "OS 原文要保留: {error}"
        );

        drop(guard);
        // guard 必须恢复权限并删除目录（finally 语义）。
        assert!(
            !std::path::Path::new(&path).exists(),
            "chmod 恢复后临时目录应被清理"
        );
    }

    /// 1 张可见 + 1 张隐藏（table:display="false"）的最小 ODS。
    const ODS_WITH_ONE_HIDDEN_SHEET: &str = concat!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
        "<office:document-content ",
        "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" ",
        "xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" ",
        "xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\">",
        "<office:body><office:spreadsheet>",
        "<table:table table:name=\"可见页\">",
        "<table:table-row>",
        "<table:table-cell office:value-type=\"string\"><text:p>id</text:p></table:table-cell>",
        "<table:table-cell office:value-type=\"string\"><text:p>姓名</text:p></table:table-cell>",
        "</table:table-row>",
        "<table:table-row>",
        "<table:table-cell office:value-type=\"float\" office:value=\"1\"/>",
        "<table:table-cell office:value-type=\"string\"><text:p>张伟</text:p></table:table-cell>",
        "</table:table-row>",
        "</table:table>",
        "<table:table table:name=\"隐藏页\" table:display=\"false\">",
        "<table:table-row><table:table-cell office:value-type=\"string\"><text:p>secret</text:p></table:table-cell></table:table-row>",
        "</table:table>",
        "</office:spreadsheet></office:body></office:document-content>",
    );

    #[tokio::test]
    async fn inspect_api_excludes_one_hidden_ods_sheet_end_to_end() {
        let path = temp_path("api_hidden.ods");
        synthetic_ods(&path, ODS_WITH_ONE_HIDDEN_SHEET);
        let info = inspect_via_api(&path).await.expect("ODS inspect 应成功");

        assert_eq!(info["format"], json!("ods"), "{info}");
        assert!(
            info["warnings"]
                .to_string()
                .contains("已忽略 1 个隐藏工作表"),
            "{info}"
        );
        let sheets = info["sheets"].as_array().unwrap();
        assert_eq!(sheets.len(), 1, "隐藏表不能出现在 sheets: {info}");
        assert_eq!(sheets[0]["name"], json!("可见页"), "{info}");
        assert_eq!(info["sheet"], json!("可见页"), "{info}");
        assert!(
            !info.to_string().contains("隐藏页"),
            "隐藏表名不能出现在 inspect 结果（sheets/sheet）: {info}"
        );
    }

    #[tokio::test]
    async fn inspect_api_excludes_one_hidden_spreadsheetml_sheet_end_to_end() {
        let path = temp_file("api_hidden_sml.xls", SML_WITH_HIDDEN_SHEETS);
        let info = inspect_via_api(&path)
            .await
            .expect("SpreadsheetML inspect 应成功");

        assert_eq!(info["format"], json!("excel"), "{info}");
        assert!(
            info["warnings"]
                .to_string()
                .contains("已忽略 1 个隐藏工作表"),
            "{info}"
        );
        let sheets = info["sheets"].as_array().unwrap();
        assert_eq!(sheets.len(), 2, "隐藏表不能出现在 sheets: {info}");
        let names: Vec<&str> = sheets
            .iter()
            .filter_map(|sheet| sheet["name"].as_str())
            .collect();
        assert_eq!(names, ["员工", "第二表"], "{info}");
        assert!(!names.contains(&"隐藏页"), "{info}");
    }

    #[tokio::test]
    async fn inspect_api_reports_html_disguised_as_xls_in_chinese() {
        let path = temp_path("api_fake.xls");
        std::fs::write(
            &path,
            b"<html><body><table><tr><td>1</td></tr></table></body></html>",
        )
        .unwrap();
        let error = inspect_via_api(&path).await.unwrap_err().to_string();
        assert!(error.contains("扩展名是 Excel"), "{error}");
        assert!(error.contains("不是 Excel 二进制格式"), "{error}");
        assert!(error.contains("HTML"), "文案要点明可能是 HTML: {error}");
    }

    #[tokio::test]
    async fn inspect_api_reports_encrypted_cfb_in_chinese() {
        let path = temp_path("api_encrypted.xlsx");
        synthetic_cfb(&path, &["EncryptionInfo", "EncryptedPackage"]);
        let error = inspect_via_api(&path).await.unwrap_err().to_string();
        assert!(error.contains("已加密"), "{error}");
        assert!(error.contains("密码"), "{error}");
        assert!(error.contains("另存为未加密的 .xlsx/.xlsb"), "{error}");
    }

    // ------------------------------ 第 55 轮：5 GiB 护栏稀疏文件端到端

    /// 稀疏大文件目录：Drop 时删除文件与目录。
    ///
    /// 断言失败 / panic / 提前 return 都不会留下 5 GiB 逻辑大小的临时文件
    /// （APFS、ext4、xfs 上它是 0 物理占用，删除也是瞬间的）。
    struct SparseCsvGuard {
        path: std::path::PathBuf,
        dir: std::path::PathBuf,
    }

    impl SparseCsvGuard {
        /// 创建「逻辑大小 = bytes、几乎不占物理磁盘」的稀疏 CSV。
        ///
        /// 返回 None 表示当前平台/文件系统不支持稀疏文件（或物理占用与逻辑大小
        /// 相当，继续跑会真的写满磁盘）：调用方打印说明后跳过，绝不硬写 5 GiB。
        fn create(bytes: u64) -> Option<(Self, String)> {
            let dir = std::env::temp_dir().join(format!("rma-sparse-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir_all(&dir).ok()?;
            let path = dir.join("big.csv");
            let guard = SparseCsvGuard {
                path: path.clone(),
                dir,
            };
            let file = std::fs::File::create(&path).ok()?;
            file.set_len(bytes).ok()?;
            drop(file);
            let meta = std::fs::metadata(&path).ok()?;
            if meta.len() != bytes {
                return None;
            }
            // 物理占用必须远小于逻辑大小，否则说明文件系统真的分配了 5 GiB。
            #[cfg(unix)]
            {
                use std::os::unix::fs::MetadataExt;
                let allocated = meta.blocks().saturating_mul(512);
                if allocated.saturating_mul(2) > bytes {
                    return None;
                }
            }
            let shown = path.to_string_lossy().to_string();
            Some((guard, shown))
        }
    }

    impl Drop for SparseCsvGuard {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.path);
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    #[tokio::test]
    async fn sparse_csv_over_five_gib_warns_without_reading_the_whole_file() {
        let Some((_guard, path)) = SparseCsvGuard::create(MAX_NON_STREAMING_BYTES + 1) else {
            eprintln!(
                "跳过 5 GiB 稀疏文件用例：当前平台/文件系统不支持 set_len 稀疏文件（本机 APFS 支持）"
            );
            return;
        };

        let started = std::time::Instant::now();
        let info = inspect_via_api(&path)
            .await
            .expect("超过 5 GiB 的 CSV 是流式格式：护栏必须放行，且不得为了判定而预解析");
        let elapsed = started.elapsed();

        assert_eq!(info["format"], json!("delimited"), "{info}");
        assert_eq!(info["size"], json!(MAX_NON_STREAMING_BYTES + 1), "{info}");

        let warnings = info["warnings"].to_string();
        assert!(warnings.contains("超过 5 GiB"), "{warnings}");
        assert!(warnings.contains("5.0 GiB"), "{warnings}");
        assert!(warnings.contains("GiB"), "护栏文案要统一 GiB 口径: {warnings}");
        // 旧文案的自相矛盾说法不能回来。
        assert!(!warnings.contains("5.0 GB（超过 5 GB）"), "{warnings}");

        // 稀疏文件只读 16 KiB 头 + 8 KiB 尾就瞬间 EOF；若护栏（或 inspect）去预解析/
        // 整表读取，5 GiB 至少是秒级甚至几十秒。10 秒是宽松上界，专门抓「把整个文件
        // 读一遍」这种跑偏，不是性能基准。
        assert!(
            elapsed < std::time::Duration::from_secs(10),
            "inspect 用了 {elapsed:?}，说明护栏可能在读取整个文件"
        );
    }

    #[tokio::test]
    async fn sparse_csv_at_exactly_five_gib_has_no_large_file_warning() {
        let Some((_guard, path)) = SparseCsvGuard::create(MAX_NON_STREAMING_BYTES) else {
            eprintln!(
                "跳过 5 GiB 稀疏文件用例：当前平台/文件系统不支持 set_len 稀疏文件（本机 APFS 支持）"
            );
            return;
        };

        let info = inspect_via_api(&path)
            .await
            .expect("恰好 5 GiB 的 CSV 必须正常 Ok");
        assert_eq!(info["format"], json!("delimited"), "{info}");
        assert_eq!(info["size"], json!(MAX_NON_STREAMING_BYTES), "{info}");

        // 阈值是「超过」5 GiB（MAX_NON_STREAMING_BYTES 本身不提示）。
        let warnings = info["warnings"].to_string();
        assert!(
            !warnings.contains("超过 5 GiB"),
            "恰好 5 GiB 不该有大文件 warning: {warnings}"
        );
        assert!(
            !warnings.contains("GiB"),
            "恰好 5 GiB 不该出现 GiB 口径的大文件 warning: {warnings}"
        );
    }
}


#[cfg(test)]
mod fast_path_equivalence_tests {
    use super::*;

    fn column(data_type: &str) -> TableColumn {
        TableColumn {
            name: "c".to_string(),
            data_type: data_type.to_string(),
            type_name: String::new(),
            nullable: true,
            auto_increment: false,
        }
    }

    #[test]
    fn split_fields_ranges_matches_split_fields_on_unquoted_records() {
        let cases = [
            "",
            "a",
            "a,b,c",
            "a,,c",
            ",",
            "a,",
            ",a",
            " a , b ",
            "中文,值,🙂",
            "a;b",
            "a\tb",
        ];
        for trim in [true, false] {
            for sep in [",", ";", "\t"] {
                for text in cases {
                    let mut ranges = Vec::new();
                    split_fields_ranges(text, sep, trim, &mut ranges).unwrap();
                    let ours: Vec<&str> =
                        ranges.iter().map(|(start, end)| &text[*start..*end]).collect();
                    let old = split_fields(text, sep, "\"", "", trim).unwrap();
                    let old_refs: Vec<&str> = old.iter().map(|field| field.as_str()).collect();
                    assert_eq!(ours, old_refs, "text={text:?} sep={sep:?} trim={trim}");
                }
            }
        }
    }

    #[test]
    fn fast_field_rendering_matches_legacy_conversion() {
        let mapping = MappingSpec::default();
        let mapping_empty_null = MappingSpec {
            empty_as_null: true,
            ..Default::default()
        };
        let mapping_no_trim = MappingSpec {
            trim_values: false,
            ..Default::default()
        };
        let cases: &[(&str, &[&str])] = &[
            (
                "varchar(32)",
                &[
                    "hello",
                    "中文",
                    "a'b",
                    "a\\b",
                    "  spaced  ",
                    "",
                    "\\N",
                    "line\nbreak",
                    "🙂",
                ],
            ),
            (
                "bigint",
                &[
                    "0",
                    "-1",
                    "1,234",
                    "1_234",
                    "-1_000,5",
                    " 42 ",
                    "abc",
                    "1.5",
                    "18446744073709551615",
                ],
            ),
            (
                "decimal(12,2)",
                &[
                    "0",
                    "-0.5",
                    "1.25",
                    "1,234.50",
                    "1_234.50",
                    "1e3",
                    "NaN",
                    "abc",
                    " 3.5 ",
                ],
            ),
            (
                "bool",
                &[
                    "1", "0", "true", "FALSE", "yes", "no", "on", "off", "t", "f", "2", "abc",
                ],
            ),
            (
                "datetime",
                &["2024-01-02 03:04:05", "2024-01-02", "abc"],
            ),
            ("json", &["{\"a\":1}", "[1,2]", "not-json", ""]),
            ("blob", &["x"]),
        ];
        for driver in [DriverKind::Mysql, DriverKind::Postgres, DriverKind::Sqlite] {
            for (data_type, values) in cases {
                let col = column(data_type);
                for raw in *values {
                    for mp in [&mapping, &mapping_empty_null, &mapping_no_trim] {
                        let mut ours = String::new();
                        let ours_result = append_field_sql(&mut ours, driver, Some(raw), &col, mp);
                        let legacy_result =
                            convert_value(Value::String((*raw).to_string()), &col, mp).map(
                                |value| {
                                    let mut out = String::new();
                                    push_literal(&mut out, driver, &value);
                                    out
                                },
                            );
                        match (ours_result, legacy_result) {
                            (Ok(()), Ok(expected)) => assert_eq!(
                                ours, expected,
                                "driver={driver:?} type={data_type} raw={raw:?}"
                            ),
                            (Err(ours_error), Err(legacy_error)) => assert_eq!(
                                ours_error, legacy_error,
                                "driver={driver:?} type={data_type} raw={raw:?}"
                            ),
                            (ours_result, legacy_result) => panic!(
                                "mismatch driver={driver:?} type={data_type} raw={raw:?}: \
                                 ours={ours_result:?} legacy={legacy_result:?}"
                            ),
                        }
                    }
                    // Missing field -> NULL, exactly like convert_value(Null).
                    let mut ours = String::new();
                    append_field_sql(&mut ours, driver, None, &col, &mapping).unwrap();
                    let mut expected = String::new();
                    push_literal(
                        &mut expected,
                        driver,
                        &convert_value(Value::Null, &col, &mapping).unwrap(),
                    );
                    assert_eq!(ours, expected);
                }
            }
        }
    }
}

