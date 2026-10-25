//! Excel 格式识别 + 建表类型推断（xlsx / xls / xlsb / ods / SpreadsheetML 2003）。
//!
//! 设计契约见 desktop/docs/IMPORT_EXCEL_ER_DESIGN.md §2。读取本身已经全部搬到
//! excel_stream（逐行流式）：xlsx/xlsm、SpreadsheetML、ODS、xls(BIFF8)、xlsb
//! 分别由 excel_stream 内的模块与 xls_stream / xlsb_stream 实现。这一层只留：
//!
//! 1. 内容优先、扩展名兜底的格式识别（inspect 用）；
//! 2. preview 的列类型推断（infer_schema），供「从文件建表」向导直接建表。
//!
//! 记录切分、表头/映射/INSERT 全在 importer.rs 里复用既有管线：Excel 的一行
//! 在扫描器里就序列化成一段 JSON 数组文本（fields.mode = "excel"），因此
//! preview / validate / execute / probe 四条路径不需要各写一套 Excel 逻辑。

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use chrono::{NaiveDate, NaiveDateTime, NaiveTime};
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
        // OLE2 是复合文档容器；真正的解析交给 xls_stream（BIFF8 record 级流式）。
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

/// 空单元格判定：NULL 或空字符串（类型推断要把「空」和「0 / 空串」分开）。
fn blank_cell(value: &Value) -> bool {
    match value {
        Value::Null => true,
        Value::String(text) => text.is_empty(),
        _ => false,
    }
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

/// 文本列的「推荐长度」：给文员后续录入留余量。
///
/// 样本最大长度只是这一批数据的宽度，直接顶满会让用户第二天录入长一点的姓名、
/// 班级或邮箱就撞上 MySQL STRICT 模式的 ERROR 1406 Data too long。规则：
/// 样本最大长度 <= 127 时给 255（满足「至少 2 倍、且不小于 32」的余量）；超过
/// 127 时返回 0，由建表向导落成 TEXT，避免把超长文本截断。
fn recommended_text_length(sample_max_length: usize) -> usize {
    if sample_max_length <= 127 {
        255
    } else {
        0
    }
}

/// 「样本内唯一」的统一口径：无重复非空值、无空值、且至少有一个非空样本。
fn column_unique(evidence: &ColumnEvidence) -> bool {
    evidence.unique && evidence.empty == 0 && evidence.non_empty > 0
}

/// 每张表最多选一个主键候选，优先级：id 列名 > 最早的唯一整数列 > 唯一的短文本首列。
///
/// 只影响「建议」，不改类型推断本身。返回与列一一对应的 reason，非候选为 ""。
/// 规则 b/c 要求列在样本内唯一且无空值；规则 a 保持旧行为（只要列名叫 id 就提示），
/// 以免同一个文件在新旧版本给出不同的主键建议。
fn primary_candidate_reasons(
    names: &[String],
    evidences: &[ColumnEvidence],
    types: &[&'static str],
) -> Vec<&'static str> {
    let mut reasons = vec![""; names.len()];
    // a) 显式 id 列（忽略大小写）。
    if let Some(index) = names
        .iter()
        .position(|name| name.eq_ignore_ascii_case("id"))
    {
        reasons[index] = "id";
        return reasons;
    }
    // b) 最早的唯一整数列：学号/订单号/工号这类自然键，不该逼用户再加自增 id。
    if let Some(index) = (0..names.len()).find(|&index| {
        column_unique(&evidences[index]) && matches!(types[index], "integer" | "bigint")
    }) {
        reasons[index] = "unique_integer";
        return reasons;
    }
    // c) 唯一的短文本首列（邮箱/名称/编号）；64 字符上限避免把长文本备注当主键。
    if !names.is_empty()
        && types[0] == "text"
        && column_unique(&evidences[0])
        && evidences[0].max_length <= 64
    {
        reasons[0] = "first_column";
    }
    reasons
}

fn column_schema(
    index: usize,
    name: &str,
    evidence: &ColumnEvidence,
    data_type: &'static str,
    primary_reason: &'static str,
) -> Value {
    let max_length = if data_type == "text" {
        recommended_text_length(evidence.max_length)
    } else {
        0
    };
    json!({
        "name": name,
        "source": index,
        "type": data_type,
        "nullable": evidence.empty > 0,
        "max_length": max_length,
        "unique": column_unique(evidence),
        "primary_candidate": !primary_reason.is_empty(),
        "primary_candidate_reason": primary_reason,
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
    // 每列只扫一遍样本；主键候选要跨列比较，所以先算完证据再统一选。
    let evidences: Vec<ColumnEvidence> = (0..names.len())
        .map(|index| {
            let mut evidence = ColumnEvidence::new();
            for row in rows {
                evidence.observe(row.get(index).unwrap_or(&Value::Null));
            }
            evidence
        })
        .collect();
    let types: Vec<&'static str> = evidences
        .iter()
        .map(ColumnEvidence::inferred_type)
        .collect();
    let reasons = primary_candidate_reasons(&names, &evidences, &types);
    let columns: Vec<Value> = names
        .iter()
        .enumerate()
        .map(|(index, name)| {
            column_schema(index, name, &evidences[index], types[index], reasons[index])
        })
        .collect();
    json!({ "sample_count": rows.len(), "columns": columns })
}
