//! Excel 数据文件读取（xlsx / xls / xlsb / ods / SpreadsheetML 2003）。
//!
//! 设计契约见 desktop/docs/IMPORT_EXCEL_ER_DESIGN.md §2。这一层只做两件事：
//!
//! 1. 把一个工作簿读成行值（Vec<Vec<serde_json::Value>>），并保留工作表列表，
//!    供 importer::inspect 展示、RecordScanner 逐行扫描；
//! 2. 按列的数据形状推断类型（infer_schema），供「从文件建表」向导直接建表。
//!
//! 记录切分、表头/映射/INSERT 全在 importer.rs 里复用既有管线：Excel 的一行
//! 在扫描器里就序列化成一段 JSON 数组文本（fields.mode = "excel"），因此
//! preview / validate / execute / probe 四条路径不需要各写一套 Excel 逻辑。
//!
//! 已知边界：calamine 的 worksheet_range 会把整张表载入内存，超大的工作簿会
//! 占用较多内存（inspect 会在 warnings 里提示）。CSV 那套「保证不整文件读入」
//! 的流式约束不适用于 Excel 二进制格式。

use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom};
use std::path::Path;

use calamine::{
    open_workbook, Data, ExcelDateTime, Ods, Reader, SheetType, SheetVisible, Sheets, Xls, Xlsb,
    Xlsx,
};
use chrono::{NaiveDate, NaiveDateTime, NaiveTime, Timelike};
use serde_json::{json, Number, Value};

use crate::error::{AppError, AppResult};

/// ZIP 文件头（xlsx / xlsb / ods 都是 ZIP 容器）。
const ZIP_MAGIC: [u8; 4] = [0x50, 0x4B, 0x03, 0x04];
/// OLE2 复合文档头（BIFF8 .xls）。
const OLE2_MAGIC: [u8; 8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
/// SpreadsheetML 2003 的 processing instruction。
const SPREADSHEETML_MARKER: &str = "mso-application progid=\"Excel.Sheet\"";
/// 类型推断最多扫描的数据行数（表头之后）。
pub const SCHEMA_SAMPLE_ROWS: usize = 1000;

// ---------------------------------------------------------------- 格式识别

/// Excel 系文件的真实格式（由文件内容判断，扩展名只是兜底）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExcelKind {
    Xlsx,
    Xls,
    Xlsb,
    Ods,
    /// SpreadsheetML 2003：Excel 2003 XML 表格，扩展名通常是 .xls。
    SpreadsheetMl,
}

impl ExcelKind {
    /// import_inspect 的 format 新值；SpreadsheetML 沿用历史的 "excel"。
    pub fn format(self) -> &'static str {
        match self {
            ExcelKind::Xlsx => "xlsx",
            ExcelKind::Xls => "xls",
            ExcelKind::Xlsb => "xlsb",
            ExcelKind::Ods => "ods",
            ExcelKind::SpreadsheetMl => "excel",
        }
    }

    /// 面向错误/警告的中文格式名。
    pub fn label(self) -> &'static str {
        match self {
            ExcelKind::Xlsx => "Excel 工作簿（.xlsx）",
            ExcelKind::Xls => "Excel 97-2003 工作簿（.xls）",
            ExcelKind::Xlsb => "Excel 二进制工作簿（.xlsb）",
            ExcelKind::Ods => "OpenDocument 电子表格（.ods）",
            ExcelKind::SpreadsheetMl => "SpreadsheetML 2003 表格（Excel XML）",
        }
    }

    /// 二进制格式（编码显示为 binary；SpreadsheetML 仍是 UTF-8 文本）。
    pub fn is_binary(self) -> bool {
        !matches!(self, ExcelKind::SpreadsheetMl)
    }
}

fn extension_of(path: &str) -> String {
    Path::new(path)
        .extension()
        .map(|value| value.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default()
}

fn read_head(path: &str, max: usize) -> AppResult<Vec<u8>> {
    let mut file = File::open(path).map_err(|e| AppError::bad(format!("无法打开文件: {e}")))?;
    let mut buf = vec![0u8; max];
    let read = file
        .read(&mut buf)
        .map_err(|e| AppError::bad(format!("读取文件失败: {e}")))?;
    buf.truncate(read);
    Ok(buf)
}

fn read_tail(path: &str, max: usize) -> AppResult<Vec<u8>> {
    let mut file = File::open(path).map_err(|e| AppError::bad(format!("无法打开文件: {e}")))?;
    let size = file
        .seek(SeekFrom::End(0))
        .map_err(|e| AppError::bad(format!("读取文件失败: {e}")))?;
    let take = (max as u64).min(size) as usize;
    file.seek(SeekFrom::Start(size - take as u64))
        .map_err(|e| AppError::bad(format!("读取文件失败: {e}")))?;
    let mut buf = vec![0u8; take];
    let read = file
        .read(&mut buf)
        .map_err(|e| AppError::bad(format!("读取文件失败: {e}")))?;
    buf.truncate(read);
    Ok(buf)
}

fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() || haystack.len() < needle.len() {
        return false;
    }
    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

/// 按 ZIP 内部结构区分 xlsx / xlsb / ods（文件名在 ZIP 的本地/中央目录里是明文）。
fn zip_kind(head: &[u8], tail: &[u8], ext: &str) -> Option<ExcelKind> {
    let has = |needle: &[u8]| contains_bytes(head, needle) || contains_bytes(tail, needle);
    if has(b"xl/workbook.bin") {
        return Some(ExcelKind::Xlsb);
    }
    if has(b"xl/workbook.xml") || has(b"xl/workbook") {
        return Some(ExcelKind::Xlsx);
    }
    if has(b"opendocument.spreadsheet") || has(b"application/vnd.oasis.opendocument") {
        return Some(ExcelKind::Ods);
    }
    // 结构没认出来时用扩展名兜底（例如只含流式数据的特殊 ZIP 写入器）。
    match ext {
        "xlsx" | "xlsm" | "xlam" | "xltx" | "xltm" => Some(ExcelKind::Xlsx),
        "xlsb" => Some(ExcelKind::Xlsb),
        "ods" => Some(ExcelKind::Ods),
        _ => None,
    }
}

/// 纯内容识别（head 至少 16 KiB；ZIP 需要 tail 覆盖中央目录）。
///
/// 检测顺序是契约规定的「内容优先、扩展名兜底」：
/// ZIP → xlsx/xlsb/ods；OLE2 → xls；文本 SpreadsheetML → excel。
pub fn sniff(head: &[u8], tail: &[u8], ext: &str) -> Option<ExcelKind> {
    if head.starts_with(&ZIP_MAGIC) {
        return zip_kind(head, tail, ext);
    }
    if head.starts_with(&OLE2_MAGIC) {
        // OLE2 是复合文档容器；真正的解析交给 calamine，打不开时由读取层报错。
        return Some(ExcelKind::Xls);
    }
    let text = String::from_utf8_lossy(head);
    if text.contains(SPREADSHEETML_MARKER) {
        return Some(ExcelKind::SpreadsheetMl);
    }
    let trimmed = text.trim_start_matches(['\u{feff}', ' ', '\t', '\r', '\n']);
    if ext == "xls" && trimmed.starts_with('<') {
        return Some(ExcelKind::SpreadsheetMl);
    }
    None
}

/// 从磁盘识别 Excel 系格式；不是 Excel 系返回 None。
pub fn detect(path: &str) -> AppResult<Option<ExcelKind>> {
    let head = read_head(path, 16 * 1024)?;
    let ext = extension_of(path);
    let needs_tail = head.starts_with(&ZIP_MAGIC);
    let tail = if needs_tail {
        read_tail(path, 256 * 1024)?
    } else {
        Vec::new()
    };
    Ok(sniff(&head, &tail, &ext))
}

// ---------------------------------------------------------------- 行数据模型

/// 一个工作表：行已裁掉末尾全空列、过滤全空行。
#[derive(Clone, Debug)]
pub struct ExcelSheet {
    pub name: String,
    /// 单元格值：空单元格是 Value::Null，日期/时间是格式化后的字符串。
    pub rows: Vec<Vec<Value>>,
    /// 有效列数（所有行已补齐到这个宽度）。
    pub cols: usize,
}

/// 工作表目录（不含数据），用于「选表」与错误提示。
#[derive(Clone, Debug)]
pub struct SheetBrief {
    pub index: usize,
    pub name: String,
}

/// 扫描器需要的「单张表 + 表目录」。
pub struct SelectedSheet {
    pub sheet: ExcelSheet,
    pub sheets: Vec<SheetBrief>,
    /// 被忽略的隐藏/图表工作表数量（inspect 警告用）。
    pub hidden_sheets: usize,
}

// ---------------------------------------------------------------- 读取工作簿

fn open_error(kind: ExcelKind, error: impl std::fmt::Display) -> AppError {
    AppError::bad(format!(
        "无法读取{}: {error}（文件可能已损坏、被密码保护或不是真正的 Excel 文件）",
        kind.label()
    ))
}

type Book = Sheets<BufReader<File>>;

fn open_book(path: &str, kind: ExcelKind) -> AppResult<Book> {
    let opened: Result<Book, String> = match kind {
        ExcelKind::Xlsx => open_workbook::<Xlsx<BufReader<File>>, _>(path)
            .map(Sheets::Xlsx)
            .map_err(|e| e.to_string()),
        ExcelKind::Xls => open_workbook::<Xls<BufReader<File>>, _>(path)
            .map(Sheets::Xls)
            .map_err(|e| e.to_string()),
        ExcelKind::Xlsb => open_workbook::<Xlsb<BufReader<File>>, _>(path)
            .map(Sheets::Xlsb)
            .map_err(|e| e.to_string()),
        ExcelKind::Ods => open_workbook::<Ods<BufReader<File>>, _>(path)
            .map(Sheets::Ods)
            .map_err(|e| e.to_string()),
        ExcelKind::SpreadsheetMl => unreachable!("SpreadsheetML 不是二进制工作簿"),
    };
    opened.map_err(|error| open_error(kind, error))
}

/// 工作簿里所有普通工作表的元数据（隐藏表也占 workbook 序号）。
struct SheetMeta {
    raw_index: usize,
    name: String,
    visible: bool,
}

fn sheet_metadata(book: &Book) -> Vec<SheetMeta> {
    book.sheets_metadata()
        .iter()
        .enumerate()
        .filter(|(_, sheet)| matches!(sheet.typ, SheetType::WorkSheet))
        .map(|(raw_index, sheet)| SheetMeta {
            raw_index,
            name: sheet.name.clone(),
            visible: matches!(sheet.visible, SheetVisible::Visible),
        })
        .collect()
}

/// 可见工作表列表（inspect.sheets 的数据源，也是「第 N 张表」的序号来源）。
fn visible_meta(meta: &[SheetMeta]) -> Vec<&SheetMeta> {
    meta.iter().filter(|sheet| sheet.visible).collect()
}

/// 选表：默认第一张可见表；支持「工作表名」或 0-based 序号字符串。
fn select_sheet(sheets: &[SheetBrief], selector: Option<&str>) -> AppResult<usize> {
    if sheets.is_empty() {
        return Err(AppError::bad("工作簿里没有可见的工作表"));
    }
    let Some(raw) = selector.map(str::trim).filter(|value| !value.is_empty()) else {
        return Ok(0);
    };
    if let Some(position) = sheets.iter().position(|sheet| sheet.name == raw) {
        return Ok(position);
    }
    if let Ok(index) = raw.parse::<usize>() {
        if index < sheets.len() {
            return Ok(index);
        }
        return Err(AppError::bad(format!(
            "工作表序号 {index} 超出范围（共 {} 个工作表，从 0 开始）",
            sheets.len()
        )));
    }
    let names = sheets
        .iter()
        .map(|sheet| sheet.name.as_str())
        .collect::<Vec<_>>()
        .join("、");
    Err(AppError::bad(format!(
        "找不到工作表 '{raw}'；可选工作表：{names}"
    )))
}

fn sheets_from_meta(meta: &[&SheetMeta]) -> Vec<SheetBrief> {
    meta.iter()
        .enumerate()
        .map(|(index, sheet)| SheetBrief {
            index,
            name: sheet.name.clone(),
        })
        .collect()
}

/// 读取指定工作表（缺省第一张可见表）；前 skip_rows 行会被跳过。
pub fn read_selected(
    path: &str,
    kind: ExcelKind,
    selector: Option<&str>,
    skip_rows: usize,
) -> AppResult<SelectedSheet> {
    if kind == ExcelKind::SpreadsheetMl {
        // SpreadsheetML 已由 excel_stream 流式读取；这里只服务 xls/xlsb 兜底。
        return Err(AppError::bad(
            "SpreadsheetML 请使用流式读取路径（excel_stream）",
        ));
    }
    let mut book = open_book(path, kind)?;
    let meta = sheet_metadata(&book);
    let visible = visible_meta(&meta);
    let briefs = sheets_from_meta(&visible);
    let selected = select_sheet(&briefs, selector)?;
    let target = visible[selected];
    let range = book
        .worksheet_range_at(target.raw_index)
        .ok_or_else(|| AppError::bad(format!("无法定位工作表「{}」", target.name)))?
        .map_err(|error| open_error(kind, error))?;
    let mut rows = trim_rows(range_to_rows(range));
    if skip_rows > 0 && skip_rows < rows.len() {
        rows.drain(..skip_rows);
    } else if skip_rows >= rows.len() {
        rows.clear();
    }
    let cols = rows.iter().map(Vec::len).max().unwrap_or(0);
    let sheet = ExcelSheet {
        name: target.name.clone(),
        rows,
        cols,
    };
    Ok(SelectedSheet {
        sheet,
        sheets: briefs,
        hidden_sheets: meta.len().saturating_sub(visible.len()),
    })
}

// ---------------------------------------------------------------- 单元格转换

/// 把 f64 规范成 JSON 数字：整数值输出整数（Excel 的数字单元格统一是浮点，
/// 92 不应变成 92.0），非整数/超范围保留浮点。
pub(crate) fn normalize_number(value: f64) -> Value {
    if !value.is_finite() {
        return Value::Null;
    }
    if value.fract() == 0.0 && value.abs() <= 9_007_199_254_740_992.0 {
        return json!(value as i64);
    }
    Number::from_f64(value)
        .map(Value::Number)
        .unwrap_or(Value::Null)
}

/// JSON 数字的整数值（含 1.0 这类「整数值的浮点」）。
///
/// SpreadsheetML 解析器历史上把 Number 单元格存成 f64，serde_json 的
/// as_i64() 对 1.0 返回 None；类型推断必须把这类值当整数，否则 id 列会被
/// 误判成 decimal（第 50 轮用户真实文件发现的 bug）。
fn integral_number(number: &Number) -> Option<i128> {
    if let Some(value) = number.as_i64() {
        return Some(value as i128);
    }
    if let Some(value) = number.as_u64() {
        return Some(value as i128);
    }
    let value = number.as_f64()?;
    if value.is_finite() && value.fract() == 0.0 && value.abs() <= 9_007_199_254_740_992.0 {
        Some(value as i128)
    } else {
        None
    }
}

/// 推断样本里展示规范化的整数（1.0 → 1）。
fn integral_sample(number: &Number) -> Option<Value> {
    if let Some(value) = number.as_i64() {
        return Some(json!(value));
    }
    if let Some(value) = number.as_u64() {
        return Some(json!(value));
    }
    let value = number.as_f64()?;
    if value.is_finite() && value.fract() == 0.0 && value.abs() <= 9_007_199_254_740_992.0 {
        Some(json!(value as i64))
    } else {
        None
    }
}

fn pad2(value: u32) -> String {
    format!("{value:02}")
}

/// Excel 日期/时间单元格 → 导入用的字符串。
///
/// * 纯日期（00:00:00）输出 YYYY-MM-DD，这样类型推断能认成 date；
/// * 纯时间（一天内的比例，calamine 会落在 1899-12-31）输出 HH:MM:SS；
/// * 其余输出 YYYY-MM-DD HH:MM:SS；时长（[h]:mm:ss）也输出 HH:MM:SS。
fn excel_datetime_value(value: &ExcelDateTime) -> Value {
    if value.is_duration() {
        if let Some(duration) = value.as_duration() {
            let seconds = duration.num_seconds();
            let sign = if seconds < 0 { "-" } else { "" };
            let seconds = seconds.abs();
            return Value::String(format!(
                "{sign}{}:{}:{}",
                seconds / 3600,
                pad2((seconds % 3600 / 60) as u32),
                pad2((seconds % 60) as u32)
            ));
        }
    }
    match value.as_datetime() {
        Some(datetime) => {
            let time_only_date = NaiveDate::from_ymd_opt(1899, 12, 31).expect("valid date");
            if datetime.date() == time_only_date {
                Value::String(format!(
                    "{}:{}:{}",
                    pad2(datetime.hour()),
                    pad2(datetime.minute()),
                    pad2(datetime.second())
                ))
            } else if datetime.time() == NaiveTime::MIN {
                Value::String(datetime.date().to_string())
            } else {
                Value::String(datetime.format("%Y-%m-%d %H:%M:%S").to_string())
            }
        }
        // 年份超出 chrono 范围等极端情况：保留 calamine 的原始数值文本。
        None => Value::String(value.to_string()),
    }
}

fn data_to_value(cell: &Data) -> Value {
    match cell {
        Data::Int(value) => json!(value),
        Data::Float(value) => normalize_number(*value),
        Data::String(value) => Value::String(value.clone()),
        Data::Bool(value) => Value::Bool(*value),
        Data::DateTime(value) => excel_datetime_value(value),
        // ISO 日期/时长本身就适合当字符串导入；类型推断会按字符串模式识别。
        Data::DateTimeIso(value) | Data::DurationIso(value) => Value::String(value.clone()),
        // 公式错误（#DIV/0! 等）与空单元格都按 NULL 导入。
        Data::Error(_) | Data::Empty => Value::Null,
    }
}

fn range_to_rows(range: calamine::Range<Data>) -> Vec<Vec<Value>> {
    range
        .rows()
        .map(|row| row.iter().map(data_to_value).collect())
        .collect()
}

/// 空单元格判定：NULL 或空字符串。
fn blank_cell(value: &Value) -> bool {
    match value {
        Value::Null => true,
        Value::String(text) => text.is_empty(),
        _ => false,
    }
}

/// 裁掉全空行与末尾全空列，并把每行补齐到同一宽度。
pub fn trim_rows(mut rows: Vec<Vec<Value>>) -> Vec<Vec<Value>> {
    let mut width = 0usize;
    for row in &rows {
        if let Some(last) = row.iter().rposition(|value| !blank_cell(value)) {
            width = width.max(last + 1);
        }
    }
    if width == 0 {
        return Vec::new();
    }
    rows.retain(|row| row.iter().any(|value| !blank_cell(value)));
    for row in &mut rows {
        row.resize(width, Value::Null);
    }
    rows
}

// ---------------------------------------------------------------- 类型推断

fn normalize_identifier(raw: &str, fallback: &str) -> String {
    let mut out = String::new();
    let mut pending_underscore = false;
    for ch in raw.trim().chars() {
        let replaced = ch.is_whitespace()
            || ch.is_control()
            || matches!(ch, '"' | '\'' | '`' | '[' | ']' | '\\');
        if replaced {
            if !out.is_empty() {
                pending_underscore = true;
            }
        } else {
            if pending_underscore {
                out.push('_');
                pending_underscore = false;
            }
            out.push(ch);
        }
    }
    if out.is_empty() {
        fallback.to_string()
    } else {
        out
    }
}

fn is_date_text(text: &str) -> bool {
    NaiveDate::parse_from_str(text, "%Y-%m-%d").is_ok()
        || NaiveDate::parse_from_str(text, "%Y/%m/%d").is_ok()
}

fn is_datetime_text(text: &str) -> bool {
    for format in [
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%Y/%m/%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%S",
    ] {
        if NaiveDateTime::parse_from_str(text, format).is_ok() {
            return true;
        }
    }
    false
}

fn is_time_text(text: &str) -> bool {
    NaiveTime::parse_from_str(text, "%H:%M:%S").is_ok()
        || NaiveTime::parse_from_str(text, "%H:%M").is_ok()
}

fn is_boolean_text(text: &str) -> bool {
    matches!(
        text.to_ascii_lowercase().as_str(),
        "true" | "false" | "yes" | "no"
    ) || text == "是"
        || text == "否"
}

/// 一列的类型证据。忽略了 NULL/空字符串，所以空单元格不会否定一列的类型。
#[derive(Default)]
struct ColumnEvidence {
    non_empty: usize,
    empty: usize,
    bool_like: usize,
    zero_one: usize,
    int_ok: usize,
    num_ok: usize,
    date_ok: usize,
    datetime_ok: usize,
    time_ok: usize,
    min_int: i128,
    max_int: i128,
    max_length: usize,
    has_int: bool,
    samples: Vec<Value>,
    distinct: Vec<String>,
    unique: bool,
}

impl ColumnEvidence {
    fn new() -> Self {
        ColumnEvidence {
            unique: true,
            min_int: i128::MAX,
            max_int: i128::MIN,
            ..Default::default()
        }
    }

    fn observe(&mut self, value: &Value) {
        if blank_cell(value) {
            self.empty += 1;
            return;
        }
        self.non_empty += 1;
        let key = value.to_string();
        if !self.distinct.iter().any(|existing| existing == &key) {
            self.distinct.push(key);
        } else {
            self.unique = false;
        }
        let sample = match value {
            Value::Number(number) => integral_sample(number).unwrap_or_else(|| value.clone()),
            _ => value.clone(),
        };
        if self.samples.len() < 3 && !self.samples.iter().any(|existing| existing == &sample) {
            self.samples.push(sample);
        }
        self.max_length = self.max_length.max(match value {
            Value::String(text) => text.chars().count(),
            other => other.to_string().chars().count(),
        });
        match value {
            Value::Bool(_) => {
                self.bool_like += 1;
            }
            Value::Number(number) => {
                self.num_ok += 1;
                // 整数值的浮点（SpreadsheetML 的 1.0、部分驱动返回的 NUMBER）
                // 必须按整数归类，否则 id 类列会被推断成 decimal。
                if let Some(integer) = integral_number(number) {
                    self.int_ok += 1;
                    self.has_int = true;
                    self.min_int = self.min_int.min(integer);
                    self.max_int = self.max_int.max(integer);
                }
                if number
                    .as_f64()
                    .is_some_and(|value| value == 0.0 || value == 1.0)
                {
                    self.zero_one += 1;
                }
            }
            Value::String(text) => {
                let trimmed = text.trim();
                if is_boolean_text(trimmed) {
                    self.bool_like += 1;
                }
                if let Ok(integer) = trimmed.parse::<i128>() {
                    self.int_ok += 1;
                    self.num_ok += 1;
                    self.has_int = true;
                    self.min_int = self.min_int.min(integer);
                    self.max_int = self.max_int.max(integer);
                } else if trimmed.parse::<f64>().is_ok() {
                    self.num_ok += 1;
                }
                if trimmed == "0" || trimmed == "1" {
                    self.zero_one += 1;
                }
                if is_datetime_text(trimmed) {
                    self.datetime_ok += 1;
                } else if is_date_text(trimmed) {
                    self.date_ok += 1;
                } else if is_time_text(trimmed) {
                    self.time_ok += 1;
                }
            }
            _ => {}
        }
    }

    fn inferred_type(&self) -> &'static str {
        let typed = self.non_empty;
        if typed == 0 {
            return "text";
        }
        // 布尔：真实布尔值/是/否 占 ≥90%；0/1 只在列里也有布尔证据时才并入
        // （纯 0/1 整数列仍然判 integer，避免把编号列误判成布尔）。
        if self.bool_like > 0 {
            let booleanish = (self.bool_like + self.zero_one) as f64 / typed as f64;
            if booleanish >= 0.9 {
                return "boolean";
            }
        }
        if self.num_ok == typed && self.has_int {
            if self.int_ok == typed {
                let fits_i32 = self.min_int >= i32::MIN as i128 && self.max_int <= i32::MAX as i128;
                return if fits_i32 { "integer" } else { "bigint" };
            }
            return "decimal";
        }
        if self.num_ok == typed {
            return "decimal";
        }
        if self.datetime_ok > 0 && self.date_ok + self.datetime_ok == typed {
            return "datetime";
        }
        if self.date_ok == typed {
            return "date";
        }
        if self.time_ok == typed {
            return "time";
        }
        "text"
    }
}

fn column_schema(index: usize, name: &str, rows: &[Vec<Value>]) -> Value {
    let mut evidence = ColumnEvidence::new();
    for row in rows {
        evidence.observe(row.get(index).unwrap_or(&Value::Null));
    }
    let data_type = evidence.inferred_type();
    let primary_candidate = name.eq_ignore_ascii_case("id")
        || (index == 0 && evidence.unique && evidence.empty == 0 && evidence.non_empty > 0);
    let max_length = if data_type == "text" {
        evidence.max_length
    } else {
        0
    };
    json!({
        "name": name,
        "source": index,
        "type": data_type,
        "nullable": evidence.empty > 0,
        "max_length": max_length,
        "primary_candidate": primary_candidate,
        "samples": evidence.samples,
    })
}

/// 按样本行推断建表用的列定义（契约 §2.3）。
///
/// header 是表头名（header=true 时），rows 是表头之后的数据行（按位置）。
/// 扫描行数由调用方裁剪，这里最多再看 SCHEMA_SAMPLE_ROWS 行。
pub fn infer_schema(header: Option<&[String]>, rows: &[Vec<Value>], max_rows: usize) -> Value {
    let limit = rows.len().min(max_rows.min(SCHEMA_SAMPLE_ROWS));
    let rows = &rows[..limit];
    let mut width = header.map(|header| header.len()).unwrap_or(0);
    for row in rows {
        width = width.max(row.len());
    }
    let mut used: Vec<String> = Vec::with_capacity(width);
    let mut names: Vec<String> = Vec::with_capacity(width);
    for index in 0..width {
        let fallback = format!("column_{}", index + 1);
        let raw = header
            .and_then(|header| header.get(index))
            .map(String::as_str)
            .unwrap_or("");
        let mut name = normalize_identifier(raw, &fallback);
        if used.iter().any(|existing| existing == &name) {
            let base = name.clone();
            let mut suffix = 2;
            loop {
                let candidate = format!("{base}_{suffix}");
                if !used.iter().any(|existing| existing == &candidate) {
                    name = candidate;
                    break;
                }
                suffix += 1;
            }
        }
        used.push(name.clone());
        names.push(name);
    }
    let columns: Vec<Value> = names
        .iter()
        .enumerate()
        .map(|(index, name)| column_schema(index, name, rows))
        .collect();
    json!({ "sample_count": rows.len(), "columns": columns })
}
