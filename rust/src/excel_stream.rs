//! Excel 逐行流式读取层（第 51 轮：处理「整表载入内存」遗留风险）。
//!
//! 目标：preview / validate / probe / execute 四个阶段都惰性拉行，inspect 也不
//! 再把所有工作表整表读进内存。实现分三类：
//!
//! * xlsx / xlsm：用 zip 直接读 worksheet XML，quick-xml 流式解析 row 元素；
//!   sharedStrings 一次加载（xlsx 的字符串都走它）、styles.xml 解析日期格式、
//!   dimension 提供总行数/列数。工作线程 + 有界 channel 把行送进导入管线，
//!   消费端提前退出（preview 只看几条）时线程会立刻停止。
//! * SpreadsheetML（Excel 2003 XML）：quick-xml 流式扫描多 Worksheet；
//!   保留 ss:Name / ss:Index / ss:Type 语义。
//! * ODS：zip 读 content.xml，流式解析 table:table / table:table-row。
//! * xls（BIFF8）：Record 级流式（OLE2/CFB 流 + BIFF record 遍历，见 xls_stream）；
//! * xlsb：Row 级流式（ZIP entry 流 + BRT record 解析，见 xlsb_stream）。
//!
//! 记录仍然是「一行 = 一个 JSON 数组 Value」：importer 的 ExcelScanner 只负责把
//! 值序列化成文本再交给既有表头/映射/INSERT 管线，这里不重复实现映射逻辑。

use std::fs::File;
use std::io::{BufRead, BufReader, Read};
use std::sync::mpsc::{sync_channel, Receiver};
use std::sync::Arc;
use std::thread::JoinHandle;

use chrono::{Duration as ChronoDuration, NaiveDate, NaiveDateTime, NaiveTime, Timelike};
use quick_xml::events::{BytesStart, BytesText, Event};
use quick_xml::Reader;
use serde_json::{json, Value};
use zip::ZipArchive;

use crate::error::{AppError, AppResult};
use crate::excel_import::{normalize_number, ExcelKind};

/// 工作线程与消费端之间的有界队列长度：行是逐条发送的，256 行足够掩盖
/// XML 解析与 INSERT 的抖动，又不会让提前退出的 preview 白读太多数据。
const CHANNEL_BOUND: usize = 256;
/// inspect 只需要前两行判断表头。
const INSPECT_HEADER_ROWS: usize = 2;
/// 流式读取时先缓冲这么多行来确定列宽（等价于整表 trim 的「末尾全空列裁掉」，
/// 又不会为了知道全局宽度而读完整表）。
const WIDTH_PROBE_ROWS: usize = 128;

// ---------------------------------------------------------------- 公共类型

/// 一个工作表的元信息（inspect.sheets[] 的数据来源）。
#[derive(Clone, Debug)]
pub struct SheetMeta {
    pub index: usize,
    pub name: String,
    /// dimension / 扫描得到的行数（含表头）。未知时为 None。
    pub rows: Option<u64>,
    /// dimension / 扫描得到的列数。未知时为 None。
    pub cols: Option<u64>,
}

impl SheetMeta {
    /// inspect.sheets[] 的 JSON：rows/cols 未知时省略（UI 只显示名字）。
    pub fn to_json(&self) -> Value {
        match (self.rows, self.cols) {
            (Some(rows), Some(cols)) => json!({
                "index": self.index,
                "name": self.name,
                "rows": rows,
                "cols": cols,
            }),
            _ => json!({ "index": self.index, "name": self.name }),
        }
    }
}

/// inspect 的轻量结果：不包含任何整表数据。
pub struct InspectInfo {
    /// 可见工作表（含顺序）。
    pub sheets: Vec<SheetMeta>,
    /// 默认选中的表（第一张可见表）。
    pub sheet: String,
    /// 默认表的前两行（表头启发式与样例用；最多 2 行）。
    pub header_rows: Vec<Vec<Value>>,
    pub hidden_sheets: usize,
    /// 本次 inspect 是否走流式读取（当前所有 Excel 格式均为 true）。
    pub streaming: bool,
    pub warnings: Vec<String>,
}

impl InspectInfo {
    pub fn sheets_json(&self) -> Vec<Value> {
        self.sheets.iter().map(SheetMeta::to_json).collect()
    }
}

/// 逐行拉取一张工作表。
pub trait RowSource: Send {
    fn next_row(&mut self) -> AppResult<Option<Vec<Value>>>;
    /// 已读字节 / 总字节（压缩前 XML 流），用于总行数未知时的进度退化。
    fn bytes_progress(&self) -> Option<(u64, u64)> {
        None
    }
}

/// 打开一张工作表后的结果（ExcelScanner 直接持有它）。
pub struct OpenedSheet {
    pub sheet: String,
    pub sheets: Vec<Value>,
    pub total_rows: Option<u64>,
    pub streaming: bool,
    pub warnings: Vec<String>,
    pub source: Box<dyn RowSource>,
}

/// 统一入口：按格式分派 inspect。
pub fn inspect_workbook(path: &str, kind: ExcelKind) -> AppResult<InspectInfo> {
    match kind {
        ExcelKind::Xlsx => xlsx::inspect(path),
        ExcelKind::SpreadsheetMl => spreadsheetml::inspect(path),
        ExcelKind::Ods => ods::inspect(path),
        ExcelKind::Xls => crate::xls_stream::inspect(path).map(xls_inspect_info),
        ExcelKind::Xlsb => crate::xlsb_stream::inspect_compat(path),
    }
}

/// 统一入口：按格式分派「打开选中工作表」。
pub fn open_sheet(
    path: &str,
    kind: ExcelKind,
    selector: Option<&str>,
    skip_rows: usize,
) -> AppResult<OpenedSheet> {
    match kind {
        ExcelKind::Xlsx => xlsx::open_sheet(path, selector, skip_rows),
        ExcelKind::SpreadsheetMl => spreadsheetml::open_sheet(path, selector, skip_rows),
        ExcelKind::Ods => ods::open_sheet(path, selector, skip_rows),
        ExcelKind::Xls => {
            let opened = crate::xls_stream::open_sheet(path, selector, skip_rows)?;
            Ok(OpenedSheet {
                sheet: opened.sheet,
                sheets: opened
                    .sheets
                    .iter()
                    .map(|(index, name)| json!({ "index": index, "name": name }))
                    .collect(),
                total_rows: opened.total_rows,
                streaming: true,
                warnings: Vec::new(),
                source: Box::new(XlsStreamSource {
                    inner: opened.source,
                }),
            })
        }
        ExcelKind::Xlsb => crate::xlsb_stream::open_sheet_compat(path, selector, skip_rows),
    }
}

// ---------------------------------------------------------------- 接线适配

/// 把 xls_stream 的轻量 inspect 结果转成 excel_stream 的统一结构。
fn xls_inspect_info(result: crate::xls_stream::InspectResult) -> InspectInfo {
    InspectInfo {
        sheets: result
            .sheets
            .into_iter()
            .map(|sheet| SheetMeta {
                index: sheet.index,
                name: sheet.name,
                rows: sheet.rows,
                cols: sheet.cols,
            })
            .collect(),
        sheet: result.sheet,
        header_rows: result.header_rows,
        hidden_sheets: result.hidden_sheets,
        streaming: true,
        warnings: Vec::new(),
    }
}

/// 把 xls_stream 的 RowSource 适配成 excel_stream::RowSource。
struct XlsStreamSource {
    inner: Box<dyn crate::xls_stream::RowSource>,
}

impl RowSource for XlsStreamSource {
    fn next_row(&mut self) -> AppResult<Option<Vec<Value>>> {
        self.inner.next_row()
    }

    fn bytes_progress(&self) -> Option<(u64, u64)> {
        self.inner.bytes_progress()
    }
}

// ---------------------------------------------------------------- 通用工具

/// 取标签的本地名（去掉 ss: / x: / table: 等命名空间前缀）。
fn tag_is(tag: &BytesStart<'_>, name: &str) -> bool {
    let qname = tag.name();
    let raw = qname.as_ref();
    let wanted = name.as_bytes();
    raw == wanted
        || (raw.len() > wanted.len()
            && raw[raw.len() - wanted.len() - 1] == b':'
            && &raw[raw.len() - wanted.len()..] == wanted)
}

/// 读取属性（按本地名匹配，值做 UTF-8 解码 + XML 实体反转义）。
fn attr(tag: &BytesStart<'_>, name: &str) -> Option<String> {
    for attribute in tag.attributes().flatten() {
        let key = attribute.key.as_ref();
        let local = key.rsplit(|&byte| byte == b':').next().unwrap_or(key);
        if local == name.as_bytes() {
            return Some(decode_xml(attribute.value.as_ref()));
        }
    }
    None
}

fn decode_xml(bytes: &[u8]) -> String {
    crate::importer::xml_unescape(&String::from_utf8_lossy(bytes))
}

/// 文本事件 + XML 实体反转义（解析失败时保留替换字符）。
fn text_of(text: &BytesText<'_>) -> String {
    text.unescape()
        .map(|value| value.into_owned())
        .unwrap_or_else(|_| {
            String::from_utf8_lossy(text.borrow().into_inner().as_ref()).into_owned()
        })
}

/// 读一个 ZIP 条目到内存（workbook.xml / rels / styles 这类小文件）。
fn zip_entry_bytes<RS: Read + std::io::Seek>(
    archive: &mut ZipArchive<RS>,
    name: &str,
) -> AppResult<Vec<u8>> {
    let mut entry = archive
        .by_name(name)
        .map_err(|error| AppError::bad(format!("无法读取工作簿内部文件 {name}: {error}")))?;
    let mut bytes = Vec::with_capacity(entry.size().min(16 * 1024 * 1024) as usize);
    entry
        .read_to_end(&mut bytes)
        .map_err(|error| AppError::bad(format!("读取 {name} 失败: {error}")))?;
    Ok(bytes)
}

/// 用 quick-xml 遍历一段内存里的 XML（小文件）。
fn read_events<R: BufRead>(
    reader: &mut Reader<R>,
    mut on_event: impl FnMut(&Event<'_>) -> Result<bool, String>,
) -> Result<(), String> {
    let mut buf = Vec::new();
    loop {
        let event = reader
            .read_event_into(&mut buf)
            .map_err(|error| error.to_string())?;
        let keep_going = on_event(&event)?;
        let eof = matches!(event, Event::Eof);
        buf.clear();
        if eof || !keep_going {
            return Ok(());
        }
    }
}

fn xml_reader<R: BufRead>(reader: R) -> Reader<R> {
    Reader::from_reader(reader)
}

/// 流式行缓冲：先攒 WIDTH_PROBE_ROWS 行确定「有效列宽」，再按宽度补齐输出。
///
/// 这样既保留旧整表实现「末尾全空列裁掉」的语义，又不需要把整张表读进内存；
/// 宽度确定后出现的更宽行会按原样输出（保留数据，由导入管线报字段数错误）。
struct WidthBufferedRows {
    pending: Vec<Vec<Value>>,
    width: Option<usize>,
}

impl WidthBufferedRows {
    fn new() -> Self {
        WidthBufferedRows {
            pending: Vec::new(),
            width: None,
        }
    }

    /// 收一行，返回当前可以输出的行（宽度未确定时通常是空）。
    fn push(&mut self, row: Vec<Value>) -> Vec<Vec<Value>> {
        if let Some(width) = self.width {
            return vec![pad_row(row, width)];
        }
        self.pending.push(row);
        if self.pending.len() >= WIDTH_PROBE_ROWS {
            self.decide();
            return self.flush();
        }
        Vec::new()
    }

    /// 输入结束：把最后不足一批的行也输出。
    fn finish(&mut self) -> Vec<Vec<Value>> {
        if self.width.is_none() {
            self.decide();
        }
        self.flush()
    }

    fn decide(&mut self) {
        let mut width = 0usize;
        for row in &self.pending {
            if let Some(last) = row.iter().rposition(|value| !blank_value(value)) {
                width = width.max(last + 1);
            }
        }
        self.width = Some(width);
    }

    fn flush(&mut self) -> Vec<Vec<Value>> {
        let width = self.width.unwrap_or(0);
        std::mem::take(&mut self.pending)
            .into_iter()
            .map(|row| pad_row(row, width))
            .collect()
    }
}

fn pad_row(mut row: Vec<Value>, width: usize) -> Vec<Value> {
    if row.len() < width {
        row.resize(width, Value::Null);
    }
    row
}

pub(crate) fn blank_value(value: &Value) -> bool {
    match value {
        Value::Null => true,
        Value::String(text) => text.is_empty(),
        _ => false,
    }
}

// ---------------------------------------------------------------- Excel 日期序号

/// Excel 序列号 → 日期/时间字符串（与上一轮 calamine 路径的输出保持一致）。
///
/// Excel 把日期存成「1900 起的浮点天数」；calamine 的换算规则是 1899-12-30
/// 为原点，且 <60 的值 +1 天（1900 闰年 bug）。这里用同样的规则，保证流式与
/// 兜底两条路径对同一文件给出完全相同的字符串。
pub(crate) fn excel_serial_value(value: f64, is_1904: bool) -> Value {
    if !value.is_finite() {
        return Value::Null;
    }
    let shifted = if is_1904 { value + 1462.0 } else { value };
    let shifted = if shifted >= 60.0 {
        shifted
    } else {
        shifted + 1.0
    };
    let milliseconds = (shifted * 86_400_000.0).round();
    if !milliseconds.is_finite() || milliseconds.abs() > i64::MAX as f64 {
        return Value::String(format!("{value}"));
    }
    let epoch = NaiveDate::from_ymd_opt(1899, 12, 30)
        .expect("valid date")
        .and_time(NaiveTime::MIN);
    let Some(datetime) =
        epoch.checked_add_signed(ChronoDuration::milliseconds(milliseconds as i64))
    else {
        return Value::String(format!("{value}"));
    };
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

fn pad2(value: u32) -> String {
    format!("{value:02}")
}

/// 时长（[h]:mm:ss 之类）单元格 → HH:MM:SS（小时可超过 24）。
pub(crate) fn excel_duration_value(value: f64) -> Value {
    if !value.is_finite() {
        return Value::Null;
    }
    let seconds = (value * 86_400.0).round() as i64;
    let sign = if seconds < 0 { "-" } else { "" };
    let seconds = seconds.abs();
    Value::String(format!(
        "{sign}{}:{}:{}",
        seconds / 3600,
        pad2((seconds % 3600 / 60) as u32),
        pad2((seconds % 60) as u32)
    ))
}

/// ISO 8601 日期/时间字符串（xlsx t="d"、ODS date-value）→ 导入侧统一格式。
pub(crate) fn normalize_iso_datetime(text: &str) -> Value {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Value::Null;
    }
    let normalized = trimmed.replace('T', " ");
    let without_zone = normalized
        .split(['Z', '+'])
        .next()
        .unwrap_or(&normalized)
        .trim()
        .to_string();
    for format in [
        "%Y-%m-%d %H:%M:%S%.f",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%Y-%m-%d",
    ] {
        if let Ok(datetime) = NaiveDateTime::parse_from_str(&without_zone, format) {
            if datetime.time() == NaiveTime::MIN {
                return Value::String(datetime.date().to_string());
            }
            return Value::String(datetime.format("%Y-%m-%d %H:%M:%S").to_string());
        }
        if let Ok(date) = NaiveDate::parse_from_str(&without_zone, format) {
            return Value::String(date.to_string());
        }
    }
    Value::String(trimmed.to_string())
}

// ---------------------------------------------------------------- 工作表选择

/// 按工作表名或 0-based 序号选表（三个流式解析器共用）。
fn select_named(sheets: &[SheetMeta], selector: Option<&str>) -> AppResult<usize> {
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

/// 线程 → 消费端的消息：行 / 已读 XML 字节位置 / 错误。
enum StreamMsg {
    Row(Vec<Value>),
    Position(u64),
    Err(String),
}

/// 有界 channel 行源：生产线程负责解析 XML，消费端被 drop（例如 preview 只看
/// 几条就结束）时 send 失败，线程立即退出，不会白读整张表。
struct ChannelSource {
    rx: Option<Receiver<StreamMsg>>,
    handle: Option<JoinHandle<()>>,
    total_bytes: u64,
    last_position: u64,
    done: bool,
}

impl ChannelSource {
    fn new(rx: Receiver<StreamMsg>, total_bytes: u64, handle: JoinHandle<()>) -> Self {
        ChannelSource {
            rx: Some(rx),
            handle: Some(handle),
            total_bytes,
            last_position: 0,
            done: false,
        }
    }
}

impl RowSource for ChannelSource {
    fn next_row(&mut self) -> AppResult<Option<Vec<Value>>> {
        if self.done {
            return Ok(None);
        }
        let Some(rx) = &self.rx else {
            return Ok(None);
        };
        loop {
            match rx.recv() {
                Ok(StreamMsg::Row(row)) => return Ok(Some(row)),
                Ok(StreamMsg::Position(position)) => {
                    self.last_position = position;
                }
                Ok(StreamMsg::Err(message)) => {
                    self.done = true;
                    return Err(AppError::bad(message));
                }
                Err(_) => {
                    self.done = true;
                    return Ok(None);
                }
            }
        }
    }

    fn bytes_progress(&self) -> Option<(u64, u64)> {
        if self.total_bytes == 0 {
            return None;
        }
        Some((self.last_position.min(self.total_bytes), self.total_bytes))
    }
}

impl Drop for ChannelSource {
    fn drop(&mut self) {
        // 先丢掉接收端，让还在 send 的生产线程立刻退出；再 join 等它收尾。
        self.rx = None;
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

/// 生产线程的通用发送封装：消费端消失时返回 false 让线程停止。
fn send_msg(tx: &std::sync::mpsc::SyncSender<StreamMsg>, message: StreamMsg) -> bool {
    tx.send(message).is_ok()
}

fn open_zip(path: &str) -> AppResult<ZipArchive<BufReader<File>>> {
    let file = File::open(path).map_err(|error| AppError::bad(format!("无法打开文件: {error}")))?;
    ZipArchive::new(BufReader::new(file))
        .map_err(|error| AppError::bad(format!("不是有效的 ZIP 工作簿: {error}")))
}

fn entry_size(path: &str, name: &str) -> u64 {
    let Ok(mut archive) = open_zip(path) else {
        return 0;
    };
    archive.by_name(name).map(|entry| entry.size()).unwrap_or(0)
}

// ---------------------------------------------------------------- xlsx / xlsm

mod xlsx {
    use super::*;
    use std::collections::HashMap;

    // ------------------------------------------------ 数字格式 / 日期判定

    #[derive(Clone, Copy, PartialEq, Eq, Debug)]
    enum CellFormat {
        Other,
        DateTime,
        TimeDelta,
    }

    fn builtin_format(id: u32) -> CellFormat {
        match id {
            14..=22 | 45 | 47 => CellFormat::DateTime,
            46 => CellFormat::TimeDelta,
            _ => CellFormat::Other,
        }
    }

    /// 自定义数字格式串是否日期/时长。
    ///
    /// 移植自 calamine 的 detect_custom_number_format（MIT）：引号/转义里的
    /// 字符不算格式；方括号里的 [h]/[m]/[s] 是时长；出现 d/m/h/y/s 是日期。
    fn detect_custom_format(code: &str) -> CellFormat {
        let mut escaped = false;
        let mut in_quote = false;
        let mut brackets = 0u8;
        let mut previous = ' ';
        let mut bracketed_hms = false;
        let mut am_pm = false;
        for current in code.chars() {
            if escaped {
                escaped = false;
                previous = current;
                continue;
            }
            match current {
                '_' | '\\' => {
                    escaped = true;
                    previous = current;
                    continue;
                }
                '"' => {
                    in_quote = !in_quote;
                    previous = current;
                    continue;
                }
                ';' => return CellFormat::Other,
                '[' => {
                    brackets += 1;
                    previous = current;
                    continue;
                }
                ']' => {
                    if brackets == 1 && bracketed_hms {
                        return CellFormat::TimeDelta;
                    }
                    brackets = brackets.saturating_sub(1);
                    previous = current;
                    continue;
                }
                _ => {}
            }
            if in_quote {
                previous = current;
                continue;
            }
            if brackets == 0 {
                if current.eq_ignore_ascii_case(&'a') {
                    am_pm = true;
                } else if am_pm && matches!(current, 'p' | 'm' | '/' | 'P' | 'M') {
                    return CellFormat::DateTime;
                } else if matches!(
                    current,
                    'd' | 'm' | 'h' | 'y' | 's' | 'D' | 'M' | 'H' | 'Y' | 'S'
                ) {
                    return CellFormat::DateTime;
                }
            } else if previous == '[' && matches!(current, 'm' | 'h' | 's' | 'M' | 'H' | 'S') {
                bracketed_hms = true;
            }
            previous = current;
        }
        CellFormat::Other
    }

    #[derive(Default)]
    struct CellStyles {
        formats: Vec<CellFormat>,
    }

    impl CellStyles {
        fn format(&self, style: Option<usize>) -> CellFormat {
            style
                .and_then(|index| self.formats.get(index).copied())
                .unwrap_or(CellFormat::Other)
        }
    }

    fn parse_styles(bytes: &[u8]) -> CellStyles {
        let mut num_fmts: HashMap<u32, CellFormat> = HashMap::new();
        let mut xf_formats: Vec<CellFormat> = Vec::new();
        let mut in_cell_xfs = false;
        let mut reader = xml_reader(bytes);
        let _ = read_events(&mut reader, |event| {
            match event {
                Event::Start(tag) | Event::Empty(tag) => {
                    if tag_is(tag, "numFmt") {
                        let id = attr(tag, "numFmtId").and_then(|value| value.parse::<u32>().ok());
                        let code = attr(tag, "formatCode").unwrap_or_default();
                        if let Some(id) = id {
                            num_fmts.insert(id, detect_custom_format(&code));
                        }
                    } else if tag_is(tag, "cellXfs") {
                        in_cell_xfs = true;
                    } else if tag_is(tag, "xf") && in_cell_xfs {
                        let id = attr(tag, "numFmtId")
                            .and_then(|value| value.parse::<u32>().ok())
                            .unwrap_or(0);
                        let format = num_fmts
                            .get(&id)
                            .copied()
                            .unwrap_or_else(|| builtin_format(id));
                        xf_formats.push(format);
                    }
                }
                Event::End(tag) if tag_end_is(tag, "cellXfs") => {
                    in_cell_xfs = false;
                }
                _ => {}
            }
            Ok(true)
        });
        CellStyles {
            formats: xf_formats,
        }
    }

    // ------------------------------------------------ 工作簿元信息

    struct XlsxSheet {
        index: usize,
        name: String,
        target: String,
        rows: Option<u64>,
        cols: Option<u64>,
    }

    struct XlsxWorkbook {
        sheets: Vec<XlsxSheet>,
        hidden_sheets: usize,
        shared_strings: Arc<Vec<String>>,
        styles: Arc<CellStyles>,
        date1904: bool,
    }

    /// 给工作表 XML 的单元格引用（如 "AB12"）求 0-based 列号。
    fn cell_col(reference: &str) -> Option<usize> {
        let mut column = 0usize;
        let mut letters = 0usize;
        for byte in reference.bytes() {
            if byte.is_ascii_alphabetic() {
                column = column * 26 + (byte.to_ascii_uppercase() - b'A' + 1) as usize;
                letters += 1;
            } else {
                break;
            }
        }
        if letters == 0 {
            None
        } else {
            Some(column - 1)
        }
    }

    /// "A1:H5" → (行数, 列数)；没有 dimension 时返回 None。
    fn dimension_size(reference: &str) -> Option<(u64, u64)> {
        let (start, end) = reference.split_once(':').unwrap_or((reference, reference));
        let digits = |cell: &str| -> Option<u64> {
            let number: String = cell.chars().filter(char::is_ascii_digit).collect();
            number.parse::<u64>().ok()
        };
        let letters = |cell: &str| -> Option<u64> {
            let mut column = 0u64;
            let mut letters = 0u64;
            for byte in cell.bytes() {
                if byte.is_ascii_alphabetic() {
                    column = column * 26 + (byte.to_ascii_uppercase() - b'A' + 1) as u64;
                    letters += 1;
                } else {
                    break;
                }
            }
            if letters == 0 {
                None
            } else {
                Some(column)
            }
        };
        let rows = digits(end)?.max(digits(start)?);
        let cols = letters(end)?.max(letters(start)?);
        Some((rows, cols))
    }

    /// 只读工作表 XML 的头部找 dimension（在 sheetData 之前），不解析任何行。
    fn sheet_dimension(
        archive: &mut ZipArchive<BufReader<File>>,
        target: &str,
    ) -> (Option<u64>, Option<u64>) {
        let Ok(entry) = archive.by_name(target) else {
            return (None, None);
        };
        let mut reader = xml_reader(BufReader::new(entry));
        let mut buf = Vec::new();
        let mut result = (None, None);
        let mut seen_events = 0usize;
        loop {
            let Ok(event) = reader.read_event_into(&mut buf) else {
                break;
            };
            seen_events += 1;
            match &event {
                Event::Start(tag) | Event::Empty(tag) => {
                    if tag_is(tag, "dimension") {
                        if let Some(reference) = attr(tag, "ref") {
                            result = dimension_size(&reference)
                                .map_or((None, None), |(rows, cols)| (Some(rows), Some(cols)));
                        }
                        break;
                    }
                    if tag_is(tag, "sheetData") {
                        // dimension 必须在 sheetData 之前；到这里说明没有 dimension。
                        break;
                    }
                }
                Event::Eof => break,
                _ => {}
            }
            buf.clear();
            if seen_events > 20_000 {
                break;
            }
        }
        result
    }

    /// 解析 xl/sharedStrings.xml（一次性加载；xlsx 的字符串都引用它）。
    fn load_shared_strings(archive: &mut ZipArchive<BufReader<File>>) -> Vec<String> {
        let Ok(entry) = archive.by_name("xl/sharedStrings.xml") else {
            return Vec::new();
        };
        let mut reader = xml_reader(BufReader::new(entry));
        let mut strings: Vec<String> = Vec::new();
        let mut current: Option<String> = None;
        let mut in_text = false;
        let mut buf = Vec::new();
        loop {
            let Ok(event) = reader.read_event_into(&mut buf) else {
                break;
            };
            match &event {
                Event::Start(tag) => {
                    if tag_is(tag, "si") {
                        current = Some(String::new());
                    } else if tag_is(tag, "t") && current.is_some() {
                        in_text = true;
                    }
                }
                Event::Empty(tag) if tag_is(tag, "si") => strings.push(String::new()),
                Event::Text(text) if in_text => {
                    if let Some(value) = current.as_mut() {
                        value.push_str(&text_of(text));
                    }
                }
                Event::CData(text) if in_text => {
                    if let Some(value) = current.as_mut() {
                        value.push_str(&String::from_utf8_lossy(text));
                    }
                }
                Event::End(tag) => {
                    if tag_end_is(tag, "t") {
                        in_text = false;
                    } else if tag_end_is(tag, "si") {
                        if let Some(value) = current.take() {
                            strings.push(value);
                        }
                    }
                }
                Event::Eof => break,
                _ => {}
            }
            buf.clear();
        }
        strings
    }

    /// 解析 xl/workbook.xml：工作表名、r:id、可见性、date1904。
    fn load_workbook_sheets(bytes: &[u8]) -> (Vec<(String, String, bool)>, bool) {
        let mut sheets: Vec<(String, String, bool)> = Vec::new();
        let mut date1904 = false;
        let mut reader = xml_reader(bytes);
        let _ = read_events(&mut reader, |event| {
            if let Event::Start(tag) | Event::Empty(tag) = event {
                if tag_is(tag, "workbookPr") {
                    date1904 = matches!(attr(tag, "date1904").as_deref(), Some("1") | Some("true"));
                } else if tag_is(tag, "sheet") {
                    let name = attr(tag, "name").unwrap_or_default();
                    let rid = attr(tag, "id").unwrap_or_default();
                    let visible = !matches!(
                        attr(tag, "state").as_deref(),
                        Some("hidden") | Some("veryHidden")
                    );
                    if !name.is_empty() && !rid.is_empty() {
                        sheets.push((name, rid, visible));
                    }
                }
            }
            Ok(true)
        });
        (sheets, date1904)
    }

    fn resolve_zip_path(base: &str, target: &str) -> String {
        if target.starts_with('/') {
            return target.trim_start_matches('/').to_string();
        }
        let mut parts: Vec<&str> = base.split('/').filter(|part| !part.is_empty()).collect();
        for segment in target.split('/') {
            match segment {
                "" | "." => {}
                ".." => {
                    parts.pop();
                }
                other => parts.push(other),
            }
        }
        parts.join("/")
    }

    fn load_relationships(bytes: &[u8]) -> HashMap<String, String> {
        let mut map = HashMap::new();
        let mut reader = xml_reader(bytes);
        let _ = read_events(&mut reader, |event| {
            if let Event::Start(tag) | Event::Empty(tag) = event {
                if tag_is(tag, "Relationship") {
                    if let (Some(id), Some(target)) = (attr(tag, "Id"), attr(tag, "Target")) {
                        map.insert(id, target);
                    }
                }
            }
            Ok(true)
        });
        map
    }

    impl XlsxWorkbook {
        fn load(path: &str) -> AppResult<Self> {
            let mut archive = open_zip(path)?;
            let workbook_xml = zip_entry_bytes(&mut archive, "xl/workbook.xml").map_err(|_| {
                AppError::bad(
                    "无法读取工作簿: 缺少 xl/workbook.xml（文件可能被加密、损坏或不是 xlsx）",
                )
            })?;
            let rels_xml = zip_entry_bytes(&mut archive, "xl/_rels/workbook.xml.rels")
                .unwrap_or_else(|_| Vec::new());
            let (raw_sheets, date1904) = load_workbook_sheets(&workbook_xml);
            let relationships = load_relationships(&rels_xml);
            let shared_strings = Arc::new(load_shared_strings(&mut archive));
            let styles_bytes = zip_entry_bytes(&mut archive, "xl/styles.xml").unwrap_or_default();
            let styles = Arc::new(parse_styles(&styles_bytes));
            let mut sheets = Vec::new();
            let mut hidden_sheets = 0usize;
            for (name, rid, visible) in raw_sheets {
                let Some(target) = relationships.get(&rid) else {
                    continue;
                };
                let resolved = resolve_zip_path("xl", target);
                // 图表工作表（chartsheet）不是数据表，忽略。
                if !resolved.contains("/worksheets/") && !resolved.starts_with("worksheets/") {
                    continue;
                }
                if !visible {
                    hidden_sheets += 1;
                    continue;
                }
                let (rows, cols) = sheet_dimension(&mut archive, &resolved);
                sheets.push(XlsxSheet {
                    index: sheets.len(),
                    name,
                    target: resolved,
                    rows,
                    cols,
                });
            }
            Ok(XlsxWorkbook {
                sheets,
                hidden_sheets,
                shared_strings,
                styles,
                date1904,
            })
        }
    }

    // ------------------------------------------------ 单行解析

    enum CellKind {
        Shared,
        Bool,
        Error,
        Number,
        Str,
        Inline,
        IsoDate,
    }

    struct CellState {
        column: usize,
        kind: CellKind,
        style: Option<usize>,
        raw: String,
        inline: String,
        in_value: bool,
        in_inline: bool,
        in_text: bool,
    }

    impl CellState {
        fn new(column: usize, kind: CellKind, style: Option<usize>) -> Self {
            CellState {
                column,
                kind,
                style,
                raw: String::new(),
                inline: String::new(),
                in_value: false,
                in_inline: false,
                in_text: false,
            }
        }

        fn resolve(self, shared: &[String], styles: &CellStyles, date1904: bool) -> Value {
            match self.kind {
                CellKind::Error => Value::Null,
                CellKind::Shared => self
                    .raw
                    .trim()
                    .parse::<usize>()
                    .ok()
                    .and_then(|index| shared.get(index))
                    .map(|text| Value::String(text.clone()))
                    .unwrap_or(Value::Null),
                CellKind::Bool => {
                    Value::Bool(matches!(self.raw.trim(), "1" | "true" | "TRUE" | "True"))
                }
                CellKind::Inline => Value::String(self.inline),
                CellKind::Str => Value::String(self.raw),
                CellKind::IsoDate => normalize_iso_datetime(&self.raw),
                CellKind::Number => {
                    let raw = self.raw.trim();
                    if raw.is_empty() {
                        return Value::Null;
                    }
                    let Ok(number) = raw.parse::<f64>() else {
                        return Value::String(self.raw);
                    };
                    match styles.format(self.style) {
                        CellFormat::DateTime => excel_serial_value(number, date1904),
                        CellFormat::TimeDelta => excel_duration_value(number),
                        CellFormat::Other => normalize_number(number),
                    }
                }
            }
        }
    }

    /// 一行 = 一个 JSON 数组；这里只负责把 worksheet XML 事件拼成行值。
    struct XlsxRowReader {
        shared: Arc<Vec<String>>,
        styles: Arc<CellStyles>,
        date1904: bool,
        skip_rows: usize,
        row: Vec<Value>,
        in_row: bool,
        cell: Option<CellState>,
    }

    impl XlsxRowReader {
        fn new(
            shared: Arc<Vec<String>>,
            styles: Arc<CellStyles>,
            date1904: bool,
            skip_rows: usize,
        ) -> Self {
            XlsxRowReader {
                shared,
                styles,
                date1904,
                skip_rows,
                row: Vec::new(),
                in_row: false,
                cell: None,
            }
        }

        fn place(&mut self, column: usize, value: Value) {
            if self.row.len() <= column {
                self.row.resize(column + 1, Value::Null);
            }
            self.row[column] = value;
        }

        /// 处理一个 XML 事件；凑满一行（且不是空行/被 skip_rows 跳过的行）就返回。
        fn on_event(&mut self, event: &Event<'_>) -> Option<Vec<Value>> {
            match event {
                Event::Start(tag) => {
                    if tag_is(tag, "row") {
                        self.row.clear();
                        self.in_row = true;
                    } else if tag_is(tag, "c") && self.in_row {
                        let column = attr(tag, "r")
                            .and_then(|reference| cell_col(&reference))
                            .unwrap_or(self.row.len());
                        let kind = match attr(tag, "t").as_deref() {
                            Some("s") => CellKind::Shared,
                            Some("b") => CellKind::Bool,
                            Some("e") => CellKind::Error,
                            Some("str") => CellKind::Str,
                            Some("inlineStr") => CellKind::Inline,
                            Some("d") => CellKind::IsoDate,
                            _ => CellKind::Number,
                        };
                        let style = attr(tag, "s").and_then(|value| value.parse::<usize>().ok());
                        self.cell = Some(CellState::new(column, kind, style));
                    } else if let Some(cell) = self.cell.as_mut() {
                        if tag_is(tag, "v") {
                            cell.in_value = true;
                        } else if tag_is(tag, "is") {
                            cell.in_inline = true;
                        } else if tag_is(tag, "t") && cell.in_inline {
                            cell.in_text = true;
                        }
                    }
                }
                Event::Empty(tag) => {
                    if tag_is(tag, "row") {
                        self.in_row = false;
                        self.row.clear();
                    } else if tag_is(tag, "c") && self.in_row {
                        let column = attr(tag, "r")
                            .and_then(|reference| cell_col(&reference))
                            .unwrap_or(self.row.len());
                        self.place(column, Value::Null);
                    }
                }
                Event::Text(text) => {
                    if let Some(cell) = self.cell.as_mut() {
                        if cell.in_value {
                            cell.raw.push_str(&text_of(text));
                        } else if cell.in_text {
                            cell.inline.push_str(&text_of(text));
                        }
                    }
                }
                Event::CData(text) => {
                    if let Some(cell) = self.cell.as_mut() {
                        let value = String::from_utf8_lossy(text).into_owned();
                        if cell.in_value {
                            cell.raw.push_str(&value);
                        } else if cell.in_text {
                            cell.inline.push_str(&value);
                        }
                    }
                }
                Event::End(tag) => {
                    if tag_end_is(tag, "v") {
                        if let Some(cell) = self.cell.as_mut() {
                            cell.in_value = false;
                        }
                    } else if tag_end_is(tag, "t") {
                        if let Some(cell) = self.cell.as_mut() {
                            cell.in_text = false;
                        }
                    } else if tag_end_is(tag, "is") {
                        if let Some(cell) = self.cell.as_mut() {
                            cell.in_inline = false;
                        }
                    } else if tag_end_is(tag, "c") {
                        if let Some(cell) = self.cell.take() {
                            let column = cell.column;
                            let value = cell.resolve(&self.shared, &self.styles, self.date1904);
                            self.place(column, value);
                        }
                    } else if tag_end_is(tag, "row") && self.in_row {
                        self.in_row = false;
                        return self.take_row();
                    }
                }
                _ => {}
            }
            None
        }

        fn take_row(&mut self) -> Option<Vec<Value>> {
            let mut row = std::mem::take(&mut self.row);
            // 只裁掉尾部 NULL；空字符串是真实值（导出/导入往返测试依赖这一点）。
            while matches!(row.last(), Some(Value::Null)) {
                row.pop();
            }
            if row.is_empty() {
                return None;
            }
            if self.skip_rows > 0 {
                self.skip_rows -= 1;
                return None;
            }
            Some(row)
        }
    }

    // ------------------------------------------------ inspect

    fn read_head_rows(
        path: &str,
        target: &str,
        shared: Arc<Vec<String>>,
        styles: Arc<CellStyles>,
        date1904: bool,
        want: usize,
    ) -> AppResult<Vec<Vec<Value>>> {
        let mut archive = open_zip(path)?;
        let entry = archive
            .by_name(target)
            .map_err(|error| AppError::bad(format!("无法读取工作表 {target}: {error}")))?;
        let mut reader = xml_reader(BufReader::new(entry));
        let mut parser = XlsxRowReader::new(shared, styles, date1904, 0);
        let mut rows = Vec::new();
        let mut buf = Vec::new();
        loop {
            let event = reader
                .read_event_into(&mut buf)
                .map_err(|error| AppError::bad(format!("解析工作表 XML 失败: {error}")))?;
            let eof = matches!(event, Event::Eof);
            if let Some(row) = parser.on_event(&event) {
                rows.push(row);
            }
            buf.clear();
            if eof || rows.len() >= want {
                break;
            }
        }
        Ok(rows)
    }

    pub fn inspect(path: &str) -> AppResult<InspectInfo> {
        let workbook = XlsxWorkbook::load(path)?;
        let Some(default) = workbook.sheets.first() else {
            return Err(AppError::bad("工作簿里没有可见的工作表"));
        };
        let header_rows = read_head_rows(
            path,
            &default.target,
            workbook.shared_strings.clone(),
            workbook.styles.clone(),
            workbook.date1904,
            INSPECT_HEADER_ROWS,
        )?;
        let sheets: Vec<SheetMeta> = workbook
            .sheets
            .iter()
            .map(|sheet| SheetMeta {
                index: sheet.index,
                name: sheet.name.clone(),
                rows: sheet.rows,
                cols: sheet.cols,
            })
            .collect();
        Ok(InspectInfo {
            sheets,
            sheet: default.name.clone(),
            header_rows,
            hidden_sheets: workbook.hidden_sheets,
            streaming: true,
            warnings: Vec::new(),
        })
    }

    // ------------------------------------------------ 逐行读取

    struct Producer {
        path: String,
        target: String,
        shared: Arc<Vec<String>>,
        styles: Arc<CellStyles>,
        date1904: bool,
        skip_rows: usize,
        tx: std::sync::mpsc::SyncSender<StreamMsg>,
    }

    impl Producer {
        fn run(self) {
            let result = self.produce();
            if let Err(message) = result {
                let _ = send_msg(&self.tx, StreamMsg::Err(message));
            }
        }

        fn produce(&self) -> Result<(), String> {
            let mut archive = open_zip(&self.path).map_err(|error| error.to_string())?;
            let entry = archive
                .by_name(&self.target)
                .map_err(|error| format!("无法读取工作表 {}: {error}", self.target))?;
            let total = entry.size();
            let mut reader = xml_reader(BufReader::new(entry));
            let mut parser = XlsxRowReader::new(
                self.shared.clone(),
                self.styles.clone(),
                self.date1904,
                self.skip_rows,
            );
            let mut emitter = WidthBufferedRows::new();
            let mut buf = Vec::new();
            let mut rows_seen = 0u64;
            loop {
                let event = reader
                    .read_event_into(&mut buf)
                    .map_err(|error| format!("解析工作表 XML 失败: {error}"))?;
                let eof = matches!(event, Event::Eof);
                if let Some(row) = parser.on_event(&event) {
                    for emitted in emitter.push(row) {
                        if !send_msg(&self.tx, StreamMsg::Row(emitted)) {
                            return Ok(());
                        }
                    }
                    rows_seen += 1;
                    if rows_seen % 128 == 0 {
                        let position = reader.buffer_position() as u64;
                        if !send_msg(&self.tx, StreamMsg::Position(position)) {
                            return Ok(());
                        }
                    }
                }
                buf.clear();
                if eof {
                    break;
                }
            }
            for emitted in emitter.finish() {
                if !send_msg(&self.tx, StreamMsg::Row(emitted)) {
                    return Ok(());
                }
            }
            let _ = send_msg(&self.tx, StreamMsg::Position(total));
            Ok(())
        }
    }

    pub fn open_sheet(
        path: &str,
        selector: Option<&str>,
        skip_rows: usize,
    ) -> AppResult<OpenedSheet> {
        let workbook = XlsxWorkbook::load(path)?;
        if workbook.sheets.is_empty() {
            return Err(AppError::bad("工作簿里没有可见的工作表"));
        }
        let metas: Vec<SheetMeta> = workbook
            .sheets
            .iter()
            .map(|sheet| SheetMeta {
                index: sheet.index,
                name: sheet.name.clone(),
                rows: sheet.rows,
                cols: sheet.cols,
            })
            .collect();
        let selected = select_named(&metas, selector)?;
        let sheet = &workbook.sheets[selected];
        let sheets_json: Vec<Value> = metas
            .iter()
            .map(|meta| json!({ "index": meta.index, "name": meta.name }))
            .collect();
        let total_rows = sheet.rows;
        let target = sheet.target.clone();
        let total_bytes = entry_size(path, &target);
        let (tx, rx) = sync_channel(CHANNEL_BOUND);
        let producer = Producer {
            path: path.to_string(),
            target,
            shared: workbook.shared_strings.clone(),
            styles: workbook.styles.clone(),
            date1904: workbook.date1904,
            skip_rows,
            tx,
        };
        let handle = std::thread::Builder::new()
            .name("dbpilot-xlsx-stream".to_string())
            .spawn(move || producer.run())
            .map_err(|error| AppError::bad(format!("启动流式读取线程失败: {error}")))?;
        Ok(OpenedSheet {
            sheet: sheet.name.clone(),
            sheets: sheets_json,
            total_rows,
            streaming: true,
            warnings: Vec::new(),
            source: Box::new(ChannelSource::new(rx, total_bytes, handle)),
        })
    }
}

/// 取结束标签的本地名。
fn tag_end_is(tag: &quick_xml::events::BytesEnd<'_>, name: &str) -> bool {
    let qname = tag.name();
    let raw = qname.as_ref();
    let wanted = name.as_bytes();
    raw == wanted
        || (raw.len() > wanted.len()
            && raw[raw.len() - wanted.len() - 1] == b':'
            && &raw[raw.len() - wanted.len()..] == wanted)
}

// ------------------------------------------------------------ 占位：后续实现

mod spreadsheetml {
    use super::*;
    use std::collections::VecDeque;
    use std::io::Read;

    /// 在字节切片里找子串。
    fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
        if needle.is_empty() || haystack.len() < needle.len() {
            return None;
        }
        haystack
            .windows(needle.len())
            .position(|window| window == needle)
    }

    fn name_from_tag(tag: &[u8], index: usize) -> String {
        let text = String::from_utf8_lossy(tag);
        for attribute in ["ss:Name=", "Name=", "name="] {
            if let Some(start) = text.find(attribute) {
                let rest = &text[start + attribute.len()..];
                let rest = rest.trim_start_matches(['"', '\'']);
                let quote = if rest.starts_with('"') { "" } else { "" };
                let _ = quote;
                let end = rest.find(['"', '\'']).unwrap_or(rest.len());
                let raw = rest[..end].to_string();
                let decoded = crate::importer::xml_unescape(&raw);
                if !decoded.trim().is_empty() {
                    return decoded;
                }
            }
        }
        format!("Sheet{}", index + 1)
    }

    /// 只扫 Worksheet 开始标签拿表名（逐块读文件，不解析行数据、不整文件载入）。
    pub fn sheet_names(path: &str) -> AppResult<Vec<String>> {
        let mut file =
            File::open(path).map_err(|error| AppError::bad(format!("无法打开文件: {error}")))?;
        let mut names: Vec<String> = Vec::new();
        let mut pending: Vec<u8> = Vec::new();
        let mut chunk = [0u8; 64 * 1024];
        loop {
            let read = file
                .read(&mut chunk)
                .map_err(|error| AppError::bad(format!("读取文件失败: {error}")))?;
            if read == 0 {
                break;
            }
            pending.extend_from_slice(&chunk[..read]);
            let mut cursor = 0usize;
            while let Some(found) = find_bytes(&pending[cursor..], b"<Worksheet") {
                let start = cursor + found;
                let Some(len) = pending[start..].iter().position(|&byte| byte == b'>') else {
                    break; // 标签跨块，留给下一轮
                };
                names.push(name_from_tag(&pending[start..start + len + 1], names.len()));
                cursor = start + len + 1;
            }
            if cursor > 0 {
                pending.drain(..cursor);
            }
            // 防御：标签异常长时不要无限增长（正常 Worksheet 开始标签 < 1 KB）。
            if pending.len() > 256 * 1024 {
                pending.drain(..pending.len() - 8 * 1024);
            }
        }
        Ok(names)
    }

    struct SmlCellState {
        index: Option<usize>,
        kind: String,
        raw: String,
        has_data: bool,
    }

    fn cell_value(kind: &str, raw: &str) -> Value {
        match kind {
            "Number" => raw
                .trim()
                .parse::<f64>()
                .map(normalize_number)
                .unwrap_or_else(|_| Value::String(raw.to_string())),
            "Boolean" => Value::Bool(raw.trim() == "1" || raw.trim().eq_ignore_ascii_case("true")),
            // Excel 2003 XML 的 DateTime 是 ISO 文本；转成导入侧统一格式。
            "DateTime" => normalize_iso_datetime(raw),
            "Error" => Value::Null,
            _ => Value::String(raw.to_string()),
        }
    }

    fn place_cell(row: &mut Vec<Value>, index: Option<usize>, value: Value) {
        if let Some(index) = index {
            while row.len() + 1 < index {
                row.push(Value::Null);
            }
        }
        row.push(value);
    }

    fn finish_row(row: &mut Vec<Value>) -> Option<Vec<Value>> {
        // 只裁掉尾部 NULL；空字符串是真实值。
        while matches!(row.last(), Some(Value::Null)) {
            row.pop();
        }
        if row.is_empty() {
            return None;
        }
        Some(std::mem::take(row))
    }

    /// inspect：单次顺序扫描 XML，只统计每张表的行数/列数 + 第一张表的前两行。
    pub fn inspect(path: &str) -> AppResult<InspectInfo> {
        let file =
            File::open(path).map_err(|error| AppError::bad(format!("无法打开文件: {error}")))?;
        let mut reader = xml_reader(BufReader::new(file));
        let mut names: Vec<String> = Vec::new();
        let mut row_counts: Vec<u64> = Vec::new();
        let mut col_counts: Vec<u64> = Vec::new();
        let mut header_rows: Vec<Vec<Value>> = Vec::new();
        let mut current: Option<usize> = None;
        let mut row: Vec<Value> = Vec::new();
        let mut in_row = false;
        let mut cell: Option<SmlCellState> = None;
        let mut in_data = false;
        let mut buf = Vec::new();
        loop {
            let event = reader
                .read_event_into(&mut buf)
                .map_err(|error| AppError::bad(format!("解析 SpreadsheetML 失败: {error}")))?;
            let eof = matches!(event, Event::Eof);
            match &event {
                Event::Start(tag) => {
                    if tag_is(tag, "Worksheet") {
                        let index = names.len();
                        let name =
                            attr(tag, "Name").unwrap_or_else(|| format!("Sheet{}", index + 1));
                        names.push(name);
                        row_counts.push(0);
                        col_counts.push(0);
                        current = Some(index);
                    } else if tag_is(tag, "Row") {
                        row.clear();
                        in_row = true;
                    } else if tag_is(tag, "Cell") && in_row {
                        let index = attr(tag, "Index")
                            .and_then(|value| value.trim().parse::<usize>().ok())
                            .filter(|value| *value > 0);
                        cell = Some(SmlCellState {
                            index,
                            kind: "String".to_string(),
                            raw: String::new(),
                            has_data: false,
                        });
                    } else if tag_is(tag, "Data") {
                        if let Some(state) = cell.as_mut() {
                            // ss:Type 在 <Data> 上（SpreadsheetML 语义），不在 <Cell> 上。
                            state.kind = attr(tag, "Type").unwrap_or_else(|| "String".to_string());
                            state.has_data = true;
                            in_data = true;
                        }
                    }
                }
                Event::Empty(tag) => {
                    if tag_is(tag, "Row") {
                        in_row = false;
                    } else if tag_is(tag, "Cell") && in_row {
                        let index = attr(tag, "Index")
                            .and_then(|value| value.trim().parse::<usize>().ok())
                            .filter(|value| *value > 0);
                        place_cell(&mut row, index, Value::Null);
                    }
                }
                Event::Text(text) => {
                    if in_data {
                        if let Some(state) = cell.as_mut() {
                            state.raw.push_str(&text_of(text));
                        }
                    }
                }
                Event::CData(text) => {
                    if in_data {
                        if let Some(state) = cell.as_mut() {
                            state.raw.push_str(&String::from_utf8_lossy(text));
                        }
                    }
                }
                Event::End(tag) => {
                    if tag_end_is(tag, "Data") {
                        in_data = false;
                    } else if tag_end_is(tag, "Cell") {
                        if let Some(state) = cell.take() {
                            let value = if state.has_data {
                                cell_value(&state.kind, &state.raw)
                            } else {
                                Value::Null
                            };
                            place_cell(&mut row, state.index, value);
                        }
                    } else if tag_end_is(tag, "Row") && in_row {
                        in_row = false;
                        if let (Some(index), Some(row_value)) = (current, finish_row(&mut row)) {
                            if let Some(count) = row_counts.get_mut(index) {
                                *count += 1;
                            }
                            if let Some(cols) = col_counts.get_mut(index) {
                                *cols = (*cols).max(row_value.len() as u64);
                            }
                            if index == 0 && header_rows.len() < INSPECT_HEADER_ROWS {
                                header_rows.push(row_value);
                            }
                        }
                    } else if tag_end_is(tag, "Worksheet") {
                        current = None;
                    }
                }
                _ => {}
            }
            buf.clear();
            if eof {
                break;
            }
        }
        if names.is_empty() {
            return Err(AppError::bad("SpreadsheetML 文件里没有 <Worksheet> 工作表"));
        }
        let sheets: Vec<SheetMeta> = names
            .iter()
            .enumerate()
            .map(|(index, name)| SheetMeta {
                index,
                name: name.clone(),
                rows: row_counts.get(index).copied(),
                cols: col_counts.get(index).copied(),
            })
            .collect();
        Ok(InspectInfo {
            sheet: names[0].clone(),
            sheets,
            header_rows,
            hidden_sheets: 0,
            streaming: true,
            warnings: Vec::new(),
        })
    }

    /// 流式行源：从文件开头扫到目标 Worksheet，逐行产出，离开目标表即停止。
    struct SpreadsheetMlSource {
        /// next_row 里会 take 出来单独用：XML 事件借用了读缓冲，不能让
        /// handle(&mut self) 与 read_event_into 同时可变借用 self。
        reader: Option<Reader<BufReader<File>>>,
        buf: Vec<u8>,
        file_size: u64,
        target: usize,
        sheet_cursor: usize,
        in_target: bool,
        finished: bool,
        row: Vec<Value>,
        in_row: bool,
        cell: Option<SmlCellState>,
        in_data: bool,
        skip_rows: usize,
        emitter: WidthBufferedRows,
        pending: VecDeque<Vec<Value>>,
    }

    impl SpreadsheetMlSource {
        fn open(path: &str, target: usize, skip_rows: usize) -> AppResult<Self> {
            let metadata = std::fs::metadata(path)
                .map_err(|error| AppError::bad(format!("无法读取文件: {error}")))?;
            let file = File::open(path)
                .map_err(|error| AppError::bad(format!("无法打开文件: {error}")))?;
            Ok(SpreadsheetMlSource {
                reader: Some(xml_reader(BufReader::new(file))),
                buf: Vec::new(),
                file_size: metadata.len(),
                target,
                sheet_cursor: 0,
                in_target: false,
                finished: false,
                row: Vec::new(),
                in_row: false,
                cell: None,
                in_data: false,
                skip_rows,
                emitter: WidthBufferedRows::new(),
                pending: VecDeque::new(),
            })
        }

        fn queue_emitted(&mut self, rows: Vec<Vec<Value>>) {
            for row in rows {
                if self.skip_rows > 0 {
                    self.skip_rows -= 1;
                    continue;
                }
                self.pending.push_back(row);
            }
        }

        fn handle(&mut self, event: &Event<'_>) -> Option<Vec<Value>> {
            match event {
                Event::Start(tag) => {
                    if tag_is(tag, "Worksheet") {
                        if self.in_target {
                            self.finished = true;
                            return None;
                        }
                        if self.sheet_cursor == self.target {
                            self.in_target = true;
                        }
                        self.sheet_cursor += 1;
                    } else if self.in_target {
                        if tag_is(tag, "Row") {
                            self.row.clear();
                            self.in_row = true;
                        } else if tag_is(tag, "Cell") && self.in_row {
                            let index = attr(tag, "Index")
                                .and_then(|value| value.trim().parse::<usize>().ok())
                                .filter(|value| *value > 0);
                            self.cell = Some(SmlCellState {
                                index,
                                kind: "String".to_string(),
                                raw: String::new(),
                                has_data: false,
                            });
                        } else if tag_is(tag, "Data") {
                            if let Some(state) = self.cell.as_mut() {
                                // ss:Type 在 <Data> 上。
                                state.kind =
                                    attr(tag, "Type").unwrap_or_else(|| "String".to_string());
                                state.has_data = true;
                                self.in_data = true;
                            }
                        }
                    }
                }
                Event::Empty(tag) => {
                    if !self.in_target {
                        return None;
                    }
                    if tag_is(tag, "Row") {
                        self.in_row = false;
                    } else if tag_is(tag, "Cell") && self.in_row {
                        let index = attr(tag, "Index")
                            .and_then(|value| value.trim().parse::<usize>().ok())
                            .filter(|value| *value > 0);
                        place_cell(&mut self.row, index, Value::Null);
                    }
                }
                Event::Text(text) => {
                    if self.in_data {
                        if let Some(state) = self.cell.as_mut() {
                            state.raw.push_str(&text_of(text));
                        }
                    }
                }
                Event::CData(text) => {
                    if self.in_data {
                        if let Some(state) = self.cell.as_mut() {
                            state.raw.push_str(&String::from_utf8_lossy(text));
                        }
                    }
                }
                Event::End(tag) => {
                    if tag_end_is(tag, "Data") {
                        self.in_data = false;
                    } else if tag_end_is(tag, "Cell") {
                        if let Some(state) = self.cell.take() {
                            let value = if state.has_data {
                                cell_value(&state.kind, &state.raw)
                            } else {
                                Value::Null
                            };
                            place_cell(&mut self.row, state.index, value);
                        }
                    } else if tag_end_is(tag, "Row") && self.in_row {
                        self.in_row = false;
                        if let Some(row) = finish_row(&mut self.row) {
                            return Some(row);
                        }
                    } else if tag_end_is(tag, "Worksheet") && self.in_target {
                        self.finished = true;
                    }
                }
                _ => {}
            }
            None
        }
    }

    impl RowSource for SpreadsheetMlSource {
        fn next_row(&mut self) -> AppResult<Option<Vec<Value>>> {
            if let Some(row) = self.pending.pop_front() {
                return Ok(Some(row));
            }
            if self.finished {
                let rest = self.emitter.finish();
                if rest.is_empty() {
                    return Ok(None);
                }
                self.queue_emitted(rest);
                return Ok(self.pending.pop_front());
            }
            let mut reader = self.reader.take().expect("reader 只在 next_row 里借出");
            let mut buf = std::mem::take(&mut self.buf);
            let result = loop {
                let event = match reader.read_event_into(&mut buf) {
                    Ok(event) => event,
                    Err(error) => {
                        break Err(AppError::bad(format!("解析 SpreadsheetML 失败: {error}")));
                    }
                };
                let eof = matches!(event, Event::Eof);
                if let Some(row) = self.handle(&event) {
                    for emitted in self.emitter.push(row) {
                        self.queue_emitted(vec![emitted]);
                    }
                }
                let rest = if eof || self.finished {
                    Some(self.emitter.finish())
                } else {
                    None
                };
                buf.clear();
                if let Some(rest) = rest {
                    self.queue_emitted(rest);
                    break Ok(self.pending.pop_front());
                }
                if let Some(row) = self.pending.pop_front() {
                    break Ok(Some(row));
                }
            };
            self.buf = buf;
            self.reader = Some(reader);
            result
        }

        fn bytes_progress(&self) -> Option<(u64, u64)> {
            if self.file_size == 0 {
                return None;
            }
            let position = self
                .reader
                .as_ref()
                .map(|reader| reader.buffer_position())
                .unwrap_or(0);
            Some((position.min(self.file_size as usize) as u64, self.file_size))
        }
    }

    pub fn open_sheet(
        path: &str,
        selector: Option<&str>,
        skip_rows: usize,
    ) -> AppResult<OpenedSheet> {
        let names = sheet_names(path)?;
        if names.is_empty() {
            return Err(AppError::bad("SpreadsheetML 文件里没有 <Worksheet> 工作表"));
        }
        let metas: Vec<SheetMeta> = names
            .iter()
            .enumerate()
            .map(|(index, name)| SheetMeta {
                index,
                name: name.clone(),
                rows: None,
                cols: None,
            })
            .collect();
        let selected = select_named(&metas, selector)?;
        let sheets_json: Vec<Value> = metas
            .iter()
            .map(|meta| json!({ "index": meta.index, "name": meta.name }))
            .collect();
        let source = SpreadsheetMlSource::open(path, selected, skip_rows)?;
        Ok(OpenedSheet {
            sheet: names[selected].clone(),
            sheets: sheets_json,
            total_rows: None,
            streaming: true,
            warnings: Vec::new(),
            source: Box::new(source),
        })
    }
}

mod ods {
    use super::*;

    /// ODS 的工作表名（content.xml 里的 table:table；只解析标签，不解析单元格）。
    fn table_names(path: &str) -> AppResult<Vec<String>> {
        let mut archive = open_zip(path)?;
        let entry = archive
            .by_name("content.xml")
            .map_err(|_| AppError::bad("不是有效的 ODS 文件: 缺少 content.xml"))?;
        let mut reader = xml_reader(BufReader::new(entry));
        let mut names: Vec<String> = Vec::new();
        let mut in_spreadsheet = false;
        let mut inside_table = false;
        let mut buf = Vec::new();
        loop {
            let event = reader
                .read_event_into(&mut buf)
                .map_err(|error| AppError::bad(format!("解析 ODS content.xml 失败: {error}")))?;
            match &event {
                Event::Start(tag) | Event::Empty(tag) => {
                    if tag_is(tag, "spreadsheet") {
                        in_spreadsheet = true;
                    } else if in_spreadsheet && !inside_table && tag_is(tag, "table") {
                        names.push(
                            attr(tag, "name")
                                .unwrap_or_else(|| format!("Sheet{}", names.len() + 1)),
                        );
                        inside_table = true;
                    }
                }
                Event::End(tag) => {
                    if tag_end_is(tag, "table") {
                        inside_table = false;
                    } else if tag_end_is(tag, "spreadsheet") {
                        in_spreadsheet = false;
                    }
                }
                Event::Eof => break,
                _ => {}
            }
            buf.clear();
        }
        Ok(names)
    }

    /// ODS 的 ISO 时长（PT09H30M00S）→ HH:MM:SS。
    fn duration_value(text: &str) -> Value {
        let trimmed = text.trim();
        let mut hours = 0i64;
        let mut minutes = 0i64;
        let mut seconds = 0i64;
        let mut number = String::new();
        for ch in trimmed.chars() {
            if ch.is_ascii_digit() || ch == '.' || ch == '-' {
                number.push(ch);
                continue;
            }
            let value = number.parse::<f64>().unwrap_or(0.0);
            number.clear();
            match ch.to_ascii_uppercase() {
                'H' => hours = value as i64,
                'M' => minutes = value as i64,
                'S' => seconds = value.round() as i64,
                _ => {}
            }
        }
        Value::String(format!(
            "{}:{}:{}",
            hours,
            pad2((minutes.rem_euclid(60)) as u32),
            pad2((seconds.rem_euclid(60)) as u32)
        ))
    }

    struct CellState {
        kind: Option<String>,
        value: Option<String>,
        date_value: Option<String>,
        boolean_value: Option<String>,
        time_value: Option<String>,
        text: String,
        in_text: bool,
        repeat: usize,
    }

    impl CellState {
        fn new(repeat: usize) -> Self {
            CellState {
                kind: None,
                value: None,
                date_value: None,
                boolean_value: None,
                time_value: None,
                text: String::new(),
                in_text: false,
                repeat,
            }
        }

        fn resolve(self) -> Value {
            let repeat = self.repeat.clamp(1, 100_000);
            if repeat > 1 {
                // 重复单元格（样式/合并占位）：只保留一个值，其余由列位置补齐；
                // 这里返回的是「第一个」，调用方循环 repeat 次。
            }
            let _ = repeat;
            match self.kind.as_deref() {
                Some("float") | Some("percentage") | Some("currency") => self
                    .value
                    .as_deref()
                    .and_then(|raw| raw.trim().parse::<f64>().ok())
                    .map(normalize_number)
                    .unwrap_or(Value::Null),
                Some("boolean") => Value::Bool(
                    self.boolean_value
                        .as_deref()
                        .map(|raw| raw.trim().eq_ignore_ascii_case("true"))
                        .unwrap_or(false),
                ),
                Some("date") => self
                    .date_value
                    .as_deref()
                    .map(normalize_iso_datetime)
                    .unwrap_or(Value::Null),
                Some("time") => self
                    .time_value
                    .as_deref()
                    .map(duration_value)
                    .unwrap_or(Value::Null),
                Some("string") => Value::String(self.text),
                _ => {
                    if self.text.is_empty() {
                        Value::Null
                    } else {
                        Value::String(self.text)
                    }
                }
            }
        }
    }

    fn place_cell(row: &mut Vec<Value>, repeat: usize, value: Value) {
        for _ in 0..repeat.clamp(1, 100_000) {
            row.push(value.clone());
        }
    }

    fn finish_row(row: &mut Vec<Value>) -> Option<Vec<Value>> {
        // 只裁掉尾部 NULL；空字符串是真实值。
        while matches!(row.last(), Some(Value::Null)) {
            row.pop();
        }
        if row.is_empty() {
            return None;
        }
        Some(std::mem::take(row))
    }

    fn cell_state(tag: &BytesStart<'_>) -> CellState {
        let repeat = attr(tag, "number-columns-repeated")
            .and_then(|value| value.trim().parse::<usize>().ok())
            .unwrap_or(1);
        let mut cell = CellState::new(repeat);
        cell.kind = attr(tag, "value-type");
        cell.value = attr(tag, "value");
        cell.date_value = attr(tag, "date-value");
        cell.boolean_value = attr(tag, "boolean-value");
        cell.time_value = attr(tag, "time-value");
        cell
    }

    struct OdsParser {
        /// 目标表序号；None = 只做 inspect（统计所有表）。
        target: Option<usize>,
        table_cursor: usize,
        in_target: bool,
        inside_table: bool,
        in_spreadsheet: bool,
        row: Vec<Value>,
        row_repeat: usize,
        in_row: bool,
        cell: Option<CellState>,
        /// inspect 用：所有表的名字与行数/列数。
        names: Vec<String>,
        row_counts: Vec<u64>,
        col_counts: Vec<u64>,
        header_rows: Vec<Vec<Value>>,
        finished: bool,
    }

    impl OdsParser {
        fn new(target: Option<usize>) -> Self {
            OdsParser {
                target,
                table_cursor: 0,
                in_target: false,
                inside_table: false,
                in_spreadsheet: false,
                row: Vec::new(),
                row_repeat: 1,
                in_row: false,
                cell: None,
                names: Vec::new(),
                row_counts: Vec::new(),
                col_counts: Vec::new(),
                header_rows: Vec::new(),
                finished: false,
            }
        }

        fn emit_row(&mut self) -> Vec<Vec<Value>> {
            let Some(row) = finish_row(&mut self.row) else {
                return Vec::new();
            };
            if self.target.is_some() {
                if !self.in_target {
                    return Vec::new();
                }
                let repeat = self.row_repeat.clamp(1, 1000);
                return vec![row; repeat];
            }
            // inspect：行数/列数按「非空行」统计；重复行按 repeat 计。
            if let Some(table) = self.names.len().checked_sub(1) {
                if let Some(count) = self.row_counts.get_mut(table) {
                    *count += self.row_repeat.clamp(1, 100_000) as u64;
                }
                if let Some(cols) = self.col_counts.get_mut(table) {
                    *cols = (*cols).max(row.len() as u64);
                }
                if table == 0 && self.header_rows.len() < INSPECT_HEADER_ROWS {
                    self.header_rows.push(row);
                }
            }
            Vec::new()
        }

        /// 处理一个事件，返回可以输出的行（流式读取用）。
        fn on_event(&mut self, event: &Event<'_>) -> Vec<Vec<Value>> {
            match event {
                Event::Start(tag) => {
                    if tag_is(tag, "spreadsheet") {
                        self.in_spreadsheet = true;
                    } else if self.in_spreadsheet && !self.inside_table && tag_is(tag, "table") {
                        let name = attr(tag, "name")
                            .unwrap_or_else(|| format!("Sheet{}", self.names.len() + 1));
                        if let Some(target) = self.target {
                            if self.table_cursor == target {
                                self.in_target = true;
                            }
                        }
                        self.names.push(name);
                        self.row_counts.push(0);
                        self.col_counts.push(0);
                        self.inside_table = true;
                        self.table_cursor += 1;
                    } else if self.inside_table
                        && self.in_target_or_inspect()
                        && tag_is(tag, "table-row")
                    {
                        self.row.clear();
                        self.in_row = true;
                        self.row_repeat = attr(tag, "number-rows-repeated")
                            .and_then(|value| value.trim().parse::<usize>().ok())
                            .unwrap_or(1);
                    } else if self.in_row && tag_is(tag, "table-cell") {
                        self.cell = Some(cell_state(tag));
                    } else if let Some(cell) = self.cell.as_mut() {
                        if tag_is(tag, "p") {
                            if !cell.text.is_empty() {
                                cell.text.push('\n');
                            }
                            cell.in_text = true;
                        }
                    }
                }
                Event::Empty(tag) => {
                    if self.inside_table && self.in_target_or_inspect() {
                        if tag_is(tag, "table-cell") {
                            // 自闭合单元格也要读属性：数值/布尔/日期通常是
                            // <table:table-cell office:value-type="float" .../>。
                            let cell = cell_state(tag);
                            let repeat = cell.repeat;
                            let value = cell.resolve();
                            place_cell(&mut self.row, repeat, value);
                        } else if tag_is(tag, "table-row") {
                            self.in_row = false;
                        }
                    }
                    if let Some(cell) = self.cell.as_mut() {
                        if tag_is(tag, "s") {
                            let count = attr(tag, "c")
                                .and_then(|value| value.trim().parse::<usize>().ok())
                                .unwrap_or(1);
                            for _ in 0..count.min(1024) {
                                cell.text.push(' ');
                            }
                        } else if tag_is(tag, "tab") {
                            cell.text.push('\t');
                        } else if tag_is(tag, "line-break") {
                            cell.text.push('\n');
                        }
                    }
                }
                Event::Text(text) => {
                    if let Some(cell) = self.cell.as_mut() {
                        if cell.in_text {
                            cell.text.push_str(&text_of(text));
                        }
                    }
                }
                Event::CData(text) => {
                    if let Some(cell) = self.cell.as_mut() {
                        if cell.in_text {
                            cell.text.push_str(&String::from_utf8_lossy(text));
                        }
                    }
                }
                Event::End(tag) => {
                    if tag_end_is(tag, "p") {
                        if let Some(cell) = self.cell.as_mut() {
                            cell.in_text = false;
                        }
                    } else if tag_end_is(tag, "table-cell") {
                        if let Some(cell) = self.cell.take() {
                            let repeat = cell.repeat;
                            let value = cell.resolve();
                            place_cell(&mut self.row, repeat, value);
                        }
                    } else if tag_end_is(tag, "table-row") && self.in_row {
                        self.in_row = false;
                        return self.emit_row();
                    } else if tag_end_is(tag, "table") && self.inside_table {
                        self.inside_table = false;
                        if let Some(target) = self.target {
                            if self.table_cursor - 1 == target {
                                self.finished = true;
                            }
                        }
                    } else if tag_end_is(tag, "spreadsheet") {
                        self.in_spreadsheet = false;
                    }
                }
                _ => {}
            }
            Vec::new()
        }

        fn in_target_or_inspect(&self) -> bool {
            self.target.is_none() || self.in_target
        }
    }

    pub fn inspect(path: &str) -> AppResult<InspectInfo> {
        let mut archive = open_zip(path)?;
        let entry = archive
            .by_name("content.xml")
            .map_err(|_| AppError::bad("不是有效的 ODS 文件: 缺少 content.xml"))?;
        let mut reader = xml_reader(BufReader::new(entry));
        let mut parser = OdsParser::new(None);
        let mut buf = Vec::new();
        loop {
            let event = reader
                .read_event_into(&mut buf)
                .map_err(|error| AppError::bad(format!("解析 ODS content.xml 失败: {error}")))?;
            let eof = matches!(event, Event::Eof);
            let _ = parser.on_event(&event);
            buf.clear();
            if eof {
                break;
            }
        }
        if parser.names.is_empty() {
            return Err(AppError::bad("ODS 文件里没有工作表"));
        }
        let sheets: Vec<SheetMeta> = parser
            .names
            .iter()
            .enumerate()
            .map(|(index, name)| SheetMeta {
                index,
                name: name.clone(),
                rows: parser.row_counts.get(index).copied(),
                cols: parser.col_counts.get(index).copied(),
            })
            .collect();
        Ok(InspectInfo {
            sheet: parser.names[0].clone(),
            sheets,
            header_rows: parser.header_rows,
            hidden_sheets: 0,
            streaming: true,
            warnings: Vec::new(),
        })
    }

    struct OdsProducer {
        path: String,
        target: usize,
        skip_rows: usize,
        tx: std::sync::mpsc::SyncSender<StreamMsg>,
    }

    impl OdsProducer {
        fn run(self) {
            if let Err(message) = self.produce() {
                let _ = send_msg(&self.tx, StreamMsg::Err(message));
            }
        }

        fn produce(&self) -> Result<(), String> {
            let mut archive = open_zip(&self.path).map_err(|error| error.to_string())?;
            let entry = archive
                .by_name("content.xml")
                .map_err(|_| "不是有效的 ODS 文件: 缺少 content.xml".to_string())?;
            let total = entry.size();
            let mut reader = xml_reader(BufReader::new(entry));
            let mut parser = OdsParser::new(Some(self.target));
            let mut emitter = WidthBufferedRows::new();
            let mut skip_rows = self.skip_rows;
            let mut buf = Vec::new();
            let mut rows_seen = 0u64;
            loop {
                let event = reader
                    .read_event_into(&mut buf)
                    .map_err(|error| format!("解析 ODS content.xml 失败: {error}"))?;
                let eof = matches!(event, Event::Eof);
                for row in parser.on_event(&event) {
                    if skip_rows > 0 {
                        skip_rows -= 1;
                        continue;
                    }
                    for emitted in emitter.push(row) {
                        if !send_msg(&self.tx, StreamMsg::Row(emitted)) {
                            return Ok(());
                        }
                    }
                    rows_seen += 1;
                    if rows_seen % 128 == 0 {
                        let position = reader.buffer_position() as u64;
                        if !send_msg(&self.tx, StreamMsg::Position(position)) {
                            return Ok(());
                        }
                    }
                }
                buf.clear();
                if eof || parser.finished {
                    break;
                }
            }
            for emitted in emitter.finish() {
                if !send_msg(&self.tx, StreamMsg::Row(emitted)) {
                    return Ok(());
                }
            }
            let _ = send_msg(&self.tx, StreamMsg::Position(total));
            Ok(())
        }
    }

    pub fn open_sheet(
        path: &str,
        selector: Option<&str>,
        skip_rows: usize,
    ) -> AppResult<OpenedSheet> {
        let names = table_names(path)?;
        if names.is_empty() {
            return Err(AppError::bad("ODS 文件里没有工作表"));
        }
        let metas: Vec<SheetMeta> = names
            .iter()
            .enumerate()
            .map(|(index, name)| SheetMeta {
                index,
                name: name.clone(),
                rows: None,
                cols: None,
            })
            .collect();
        let selected = select_named(&metas, selector)?;
        let sheets_json: Vec<Value> = metas
            .iter()
            .map(|meta| json!({ "index": meta.index, "name": meta.name }))
            .collect();
        let total_bytes = entry_size(path, "content.xml");
        let (tx, rx) = sync_channel(CHANNEL_BOUND);
        let producer = OdsProducer {
            path: path.to_string(),
            target: selected,
            skip_rows,
            tx,
        };
        let handle = std::thread::Builder::new()
            .name("dbpilot-ods-stream".to_string())
            .spawn(move || producer.run())
            .map_err(|error| AppError::bad(format!("启动流式读取线程失败: {error}")))?;
        Ok(OpenedSheet {
            sheet: names[selected].clone(),
            sheets: sheets_json,
            total_rows: None,
            streaming: true,
            warnings: Vec::new(),
            source: Box::new(ChannelSource::new(rx, total_bytes, handle)),
        })
    }
}

