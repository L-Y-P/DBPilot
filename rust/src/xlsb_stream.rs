//! xlsb（ZIP 容器 + BRT 二进制记录）Row 级流式读取（第 51 轮）。
//!
//! xlsb 是 Excel 2007+ 的二进制工作簿：外层是 ZIP，内部用 BRT（Binary Record Table）
//! 记录替代 XML。与 xlsx 路径一样，这里只把「工作表」这一条 entry 当流处理：
//!
//! * xl/workbook.bin（工作表清单/顺序/隐藏位/1904 日期系统）、
//!   xl/_rels/workbook.bin.rels（rId → 工作表路径）、xl/sharedStrings.bin、
//!   xl/styles.bin 都是小文件，一次读入；
//! * xl/worksheets/sheetN.bin 用 zip::ZipArchive::by_name 拿到 ZipFile（实现 Read），
//!   边解压边按 BRT 记录解析，**不 read_to_end**；
//! * 解析线程 + 有界 channel(256) 把行送进导入管线，消费端提前退出（preview 只看
//!   几条）时线程立刻停止。
//!
//! BRT 记录（MS-XLSB 2.1.4）：record id（1-2 字节 varint）+ record size（1-4 字节
//! varint）+ payload。两段都是「低 7 位是数据、最高位表示后面还有字节」。
//!
//! 单元格（MS-XLSB 2.5.9 Cell）= column(4) + iStyleRef(3) + fPhShow/保留(1) 共 8 字节
//! 头，其后是值：Blank 无值（8）、Rk(4)（12）、Real(8)（16）、Isst(4)（12）、
//! St = XLWideString（12+2N）、Bool/Error 各 1 字节（9）。读取端同时容忍「7 字节头」
//! 的非规范写入器（见 fixed_value_offset）；测试里的最小写入器按规范写 8 字节头，
//! 并用 calamine 作为独立实现交叉验证（见 fixture_reads_with_calamine）。
//!
//! 行语义与 xlsx/xls 完全一致：数值整数值→i64、布尔→Bool、空/错误→Null、文本→String、
//! 日期格式数值→excel_serial_value、时长→excel_duration_value、行按列号补齐并裁掉
//! 尾部 NULL、全空行跳过、skip_rows 按有效行计、先缓冲 ≤128 行确定列宽。

use std::collections::HashMap;
use std::fs::File;
use std::io::{self, BufReader, Read, Seek};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender};
use std::sync::Arc;
use std::thread::JoinHandle;

use quick_xml::events::Event;
use quick_xml::Reader as XmlReader;
use serde_json::{json, Value};
use zip::ZipArchive;

use crate::error::{AppError, AppResult};
use crate::excel_import::normalize_number;
use crate::excel_stream::{blank_value, excel_duration_value, excel_serial_value};

/// 工作线程与消费端之间的有界队列长度（与 xlsx/xls 路径一致）。
const CHANNEL_BOUND: usize = 256;
/// inspect 只需要前两行判断表头。
const INSPECT_HEADER_ROWS: usize = 2;
/// 流式读取时先缓冲这么多行来确定列宽（WidthBufferedRows 语义）。
const WIDTH_PROBE_ROWS: usize = 128;
/// 单条 BRT 记录的上限：xlsb 的记录远小于此，超过即视为文件损坏（防 OOM）。
const MAX_RECORD_BYTES: usize = 16 * 1024 * 1024;
/// Excel 工作表最大列数（越界视为损坏，避免按恶意列号扩容）。
const MAX_COLS: usize = 16_384;
/// Excel 工作表最大行号（0-based）。
const MAX_ROW_INDEX: u32 = 1_048_575;

// ---------------------------------------------------------------- BRT 记录号

/// BRT 记录号（MS-XLSB 2.4 节）。只列出本模块会用到的。
mod brt {
    pub const ROW_HDR: u32 = 0x0000;
    pub const CELL_BLANK: u32 = 0x0001;
    pub const CELL_RK: u32 = 0x0002;
    pub const CELL_ERROR: u32 = 0x0003;
    pub const CELL_BOOL: u32 = 0x0004;
    pub const CELL_REAL: u32 = 0x0005;
    pub const CELL_ST: u32 = 0x0006;
    pub const CELL_ISST: u32 = 0x0007;
    /// 公式单元格的缓存值（与同类型常量单元格布局相同，值后面才是公式字节）。
    pub const FMLA_STRING: u32 = 0x0008;
    pub const FMLA_NUM: u32 = 0x0009;
    pub const FMLA_BOOL: u32 = 0x000A;
    pub const FMLA_ERROR: u32 = 0x000B;

    pub const END_BUNDLE_SHS: u32 = 0x0090;
    pub const BEGIN_SHEET_DATA: u32 = 0x0091;
    pub const END_SHEET_DATA: u32 = 0x0092;
    pub const WS_DIM: u32 = 0x0094;
    pub const WB_PROP: u32 = 0x0099;
    pub const BUNDLE_SH: u32 = 0x009C;
    #[allow(dead_code)]
    pub const BEGIN_SST: u32 = 0x009F;
    pub const END_SST: u32 = 0x00A0;
    pub const SST_ITEM: u32 = 0x0013;

    pub const FMT: u32 = 0x002C;
    pub const XF: u32 = 0x002F;
    #[allow(dead_code)]
    pub const BEGIN_FMTS: u32 = 0x0267;
    #[allow(dead_code)]
    pub const END_FMTS: u32 = 0x0268;
    pub const BEGIN_CELL_XFS: u32 = 0x0269;
    pub const END_CELL_XFS: u32 = 0x026A;
}

// ---------------------------------------------------------------- 公共类型

/// 一个工作表的元信息（inspect.sheets[] 的数据来源）。
#[derive(Clone, Debug)]
pub struct SheetMetaBrief {
    pub index: usize,
    pub name: String,
    /// BrtWsDim 的 rwLast+1（含表头）；未知时为 None。
    pub rows: Option<u64>,
    /// BrtWsDim 的 colLast+1；未知时为 None。
    pub cols: Option<u64>,
}

/// inspect 的轻量结果：不包含任何整表数据。
#[derive(Debug)]
pub struct InspectResult {
    pub sheets: Vec<SheetMetaBrief>,
    /// 默认选中的表（第一张可见表）。
    pub sheet: String,
    /// 默认表的前两行（表头启发式与样例用）。
    pub header_rows: Vec<Vec<Value>>,
    pub hidden_sheets: usize,
}

/// 逐行拉取一张工作表。
pub trait RowSource: Send {
    fn next_row(&mut self) -> AppResult<Option<Vec<Value>>>;
    /// 已读字节 / 总字节（解压后的 BRT 流），用于总行数未知时的进度退化。
    fn bytes_progress(&self) -> Option<(u64, u64)> {
        None
    }
}

/// 打开一张工作表后的结果（Lead 适配进 excel_stream::OpenedSheet）。
pub struct OpenedSheetLike {
    pub sheet: String,
    /// (0-based 可见表序号, 表名)，顺序与工作簿一致。
    pub sheets: Vec<(usize, String)>,
    pub total_rows: Option<u64>,
    pub source: Box<dyn RowSource>,
}

// ---------------------------------------------------------------- 变长整数

/// 读一个「低 7 位数据 + 最高位续接」的变长整数（最多 max_bytes 字节）。
///
/// 从字节流里按需读，不预读整条记录；Ok(None) 表示干净 EOF（记录边界处）。
fn read_varint<R: Read>(reader: &mut R, max_bytes: usize) -> io::Result<Option<u64>> {
    let mut value = 0u64;
    for index in 0..max_bytes {
        let mut byte = [0u8; 1];
        let read = loop {
            match reader.read(&mut byte) {
                Ok(read) => break read,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        };
        if read == 0 {
            if index == 0 {
                return Ok(None);
            }
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "BRT 变长整数在记录中间结束",
            ));
        }
        value |= ((byte[0] & 0x7F) as u64) << (7 * index);
        if byte[0] & 0x80 == 0 {
            return Ok(Some(value));
        }
    }
    Err(io::Error::new(
        io::ErrorKind::InvalidData,
        "BRT 变长整数超过 4 字节",
    ))
}

/// 顺序读 BRT 记录：record id（1-2 字节 varint）+ record size（1-4 字节 varint）+ payload。
///
/// payload 复用调用方给的缓冲区，避免大表逐记录分配。
struct RecordReader<R> {
    inner: R,
}

impl<R: Read> RecordReader<R> {
    fn new(inner: R) -> Self {
        RecordReader { inner }
    }

    /// 读下一条记录到 payload；Ok(None) = 干净 EOF。
    fn next_into(&mut self, payload: &mut Vec<u8>) -> io::Result<Option<u32>> {
        payload.clear();
        let Some(id) = read_varint(&mut self.inner, 4)? else {
            return Ok(None);
        };
        let Some(length) = read_varint(&mut self.inner, 4)? else {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "BRT 记录头缺少长度字段",
            ));
        };
        let length = length as usize;
        if length > MAX_RECORD_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("BRT 记录长度 {length} 超出上限"),
            ));
        }
        payload.resize(length, 0);
        self.inner.read_exact(payload)?;
        Ok(Some(id as u32))
    }
}

// ---------------------------------------------------------------- 字符串 / 单元格布局

/// 读 XLWideString（4 字节字符数 + UTF-16LE），返回 (文本, 结束偏移)。
///
/// 长度非法（越界/超出 payload）时返回 None，由调用方决定是容错还是报错。
fn wide_string_at(payload: &[u8], offset: usize) -> Option<(String, usize)> {
    let length_end = offset.checked_add(4)?;
    if payload.len() < length_end {
        return None;
    }
    let units = u32::from_le_bytes([
        payload[offset],
        payload[offset + 1],
        payload[offset + 2],
        payload[offset + 3],
    ]) as usize;
    // 0xFFFFFFFF 表示「没有这个字符串」（BrtBundleSh 的 strRelID 可为空）。
    if units == u32::MAX as usize {
        return None;
    }
    let end = length_end.checked_add(units.checked_mul(2)?)?;
    if payload.len() < end {
        return None;
    }
    let mut text = String::with_capacity(units.min(1024));
    let mut index = length_end;
    while index < end {
        let unit = u16::from_le_bytes([payload[index], payload[index + 1]]);
        index += 2;
        match char::decode_utf16(std::iter::once(unit)).next() {
            Some(Ok(character)) => text.push(character),
            // 落单的代理项：用替换字符，别让一条坏字符串毁掉整表。
            _ => text.push('\u{FFFD}'),
        }
    }
    Some((text, end))
}

/// 定长值（Rk/Real/Isst/Bool/Error）在 payload 里的偏移。
///
/// 规范是 8 字节 Cell 头（column 4 + iStyleRef 3 + fPhShow/保留 1），但历史上存在按
/// 7 字节头（column 4 + iStyleRef 3）写的非规范文件；用记录长度反推值偏移，两种都能读：
/// 常量单元格的记录长度 = 头长度 + 值长度，所以 len - size 恰好是 7 或 8。
/// 公式单元格（值后面还有公式字节）长度更长，固定按规范从 8 开始。
fn fixed_value_offset(payload_len: usize, value_size: usize) -> Result<usize, String> {
    let Some(candidate) = payload_len.checked_sub(value_size) else {
        return Err(format!(
            "单元格记录长度 {payload_len} 小于值长度 {value_size}"
        ));
    };
    if candidate == 7 || candidate == 8 {
        return Ok(candidate);
    }
    if payload_len >= 8 + value_size {
        return Ok(8);
    }
    if payload_len >= 7 + value_size {
        return Ok(7);
    }
    Err(format!(
        "单元格记录长度 {payload_len} 与值长度 {value_size} 不匹配"
    ))
}

/// 单元格头的 iStyleRef（3 字节，位于 payload[4..7]）。
fn cell_style_ref(payload: &[u8]) -> u32 {
    if payload.len() < 7 {
        return 0;
    }
    (payload[4] as u32) | ((payload[5] as u32) << 8) | ((payload[6] as u32) << 16)
}

/// 单元格头的列号（payload[0..4]）。
fn cell_column(payload: &[u8]) -> Option<u32> {
    if payload.len() < 4 {
        return None;
    }
    Some(u32::from_le_bytes([
        payload[0], payload[1], payload[2], payload[3],
    ]))
}

// ---------------------------------------------------------------- 数字格式 / 日期判定

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum CellFormat {
    Other,
    DateTime,
    TimeDelta,
}

/// 内建数字格式 id（与 xlsx 路径的 builtin_format 一致）。
fn builtin_format(id: u32) -> CellFormat {
    match id {
        14..=22 | 45 | 47 => CellFormat::DateTime,
        46 => CellFormat::TimeDelta,
        _ => CellFormat::Other,
    }
}

/// 自定义数字格式串是否日期/时长（与 excel_stream 里 xlsx 的启发式等价）。
///
/// 移植自 calamine 的 detect_custom_number_format（MIT）：引号/转义里的字符不算格式；
/// 方括号里的 [h]/[m]/[s] 是时长；出现 d/m/h/y/s 是日期。
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

/// cellXfs 下标 → 日期/时长判定。
#[derive(Default)]
struct CellStyles {
    formats: Vec<CellFormat>,
}

impl CellStyles {
    fn format(&self, style: u32) -> CellFormat {
        self.formats
            .get(style as usize)
            .copied()
            .unwrap_or(CellFormat::Other)
    }
}

/// 解析 xl/styles.bin：BrtBeginFmts/BrtFmt（自定义格式串）+ BrtBeginCellXFs/BrtXF（ifmt）。
fn parse_styles(bytes: &[u8]) -> CellStyles {
    let mut number_formats: HashMap<u16, CellFormat> = HashMap::new();
    let mut formats: Vec<CellFormat> = Vec::new();
    let mut in_cell_xfs = false;
    let mut records = RecordReader::new(bytes);
    let mut payload = Vec::new();
    loop {
        match records.next_into(&mut payload) {
            Ok(Some(id)) => match id {
                brt::FMT => {
                    if payload.len() >= 2 {
                        let ifmt = u16::from_le_bytes([payload[0], payload[1]]);
                        if let Some((code, _)) = wide_string_at(&payload, 2) {
                            number_formats.insert(ifmt, detect_custom_format(&code));
                        }
                    }
                }
                brt::BEGIN_CELL_XFS => in_cell_xfs = true,
                brt::XF if in_cell_xfs => {
                    let ifmt = if payload.len() >= 4 {
                        u16::from_le_bytes([payload[2], payload[3]]) as u32
                    } else {
                        0
                    };
                    let format = match builtin_format(ifmt) {
                        CellFormat::Other => number_formats
                            .get(&(ifmt as u16))
                            .copied()
                            .unwrap_or(CellFormat::Other),
                        other => other,
                    };
                    formats.push(format);
                }
                brt::END_CELL_XFS => break,
                _ => {}
            },
            // 样式文件损坏不该让整张表读不出来：按「无日期格式」继续。
            Ok(None) | Err(_) => break,
        }
    }
    CellStyles { formats }
}

// ---------------------------------------------------------------- 工作簿元信息

struct BundleSheet {
    name: String,
    rel_id: String,
    hidden: bool,
}

struct SheetEntry {
    index: usize,
    name: String,
    target: String,
}

struct WorkbookData {
    sheets: Vec<SheetEntry>,
    hidden_sheets: usize,
    date1904: bool,
    shared: Arc<Vec<String>>,
    styles: Arc<CellStyles>,
}

fn open_zip(path: &str) -> AppResult<ZipArchive<BufReader<File>>> {
    let file = File::open(path).map_err(|error| AppError::bad(format!("无法打开文件: {error}")))?;
    ZipArchive::new(BufReader::new(file))
        .map_err(|error| AppError::bad(format!("不是有效的 ZIP 工作簿: {error}")))
}

/// 读一个小 entry（workbook.bin / rels / sharedStrings.bin / styles.bin）。
fn entry_bytes<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
    name: &str,
) -> AppResult<Option<Vec<u8>>> {
    match archive.by_name(name) {
        Ok(mut entry) => {
            let mut bytes = Vec::with_capacity(entry.size().min(8 * 1024 * 1024) as usize);
            entry
                .read_to_end(&mut bytes)
                .map_err(|error| AppError::bad(format!("读取 {name} 失败: {error}")))?;
            Ok(Some(bytes))
        }
        Err(zip::result::ZipError::FileNotFound) => Ok(None),
        Err(error) => Err(AppError::bad(format!(
            "无法读取工作簿内部文件 {name}: {error}"
        ))),
    }
}

/// 解析 xl/workbook.bin：工作表清单（BrtBundleSh）、隐藏位、1904 日期系统（BrtWbProp）。
fn parse_workbook_bin(bytes: &[u8]) -> AppResult<(Vec<BundleSheet>, bool)> {
    let mut sheets = Vec::new();
    let mut date1904 = false;
    let mut records = RecordReader::new(bytes);
    let mut payload = Vec::new();
    loop {
        let id = records
            .next_into(&mut payload)
            .map_err(|error| AppError::bad(format!("解析 xl/workbook.bin 失败: {error}")))?;
        let Some(id) = id else { break };
        match id {
            brt::WB_PROP => {
                // BrtWbProp: flags(4) + dwThemeVersion(4) + strName；bit0 = f1904。
                if !payload.is_empty() {
                    date1904 = payload[0] & 0x01 != 0;
                }
            }
            brt::BUNDLE_SH => {
                // BrtBundleSh: hsState(4) + iTabID(4) + strRelID(XLWideString) + strName(XLWideString)
                if payload.len() < 12 {
                    continue;
                }
                let state = u32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]);
                let (rel_id, name_offset) = match wide_string_at(&payload, 8) {
                    Some((rel_id, end)) => (rel_id, end),
                    // 没有关系 id 时 strRelID 只剩 4 字节长度字段。
                    None => (String::new(), 12),
                };
                let name = wide_string_at(&payload, name_offset)
                    .map(|(name, _)| name)
                    .unwrap_or_default();
                if name.is_empty() {
                    continue;
                }
                sheets.push(BundleSheet {
                    name,
                    rel_id,
                    hidden: state & 0x3 != 0,
                });
            }
            brt::END_BUNDLE_SHS => break,
            _ => {}
        }
    }
    Ok((sheets, date1904))
}

/// 解析 xl/_rels/workbook.bin.rels：rId → 目标路径（相对 xl/）。
fn parse_rels(bytes: &[u8]) -> HashMap<String, String> {
    let mut map = HashMap::new();
    let mut reader = XmlReader::from_reader(bytes);
    let mut buffer = Vec::new();
    loop {
        match reader.read_event_into(&mut buffer) {
            Ok(Event::Start(tag)) | Ok(Event::Empty(tag)) => {
                if tag.name().as_ref().rsplit(|&byte| byte == b':').next() == Some(b"Relationship")
                {
                    let mut id = None;
                    let mut target = None;
                    for attribute in tag.attributes().flatten() {
                        let key = attribute.key.as_ref();
                        let local = key.rsplit(|&byte| byte == b':').next().unwrap_or(key);
                        let value = String::from_utf8_lossy(attribute.value.as_ref()).into_owned();
                        match local {
                            b"Id" => id = Some(value),
                            b"Target" => target = Some(value),
                            _ => {}
                        }
                    }
                    if let (Some(id), Some(target)) = (id, target) {
                        map.insert(id, target);
                    }
                }
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
        buffer.clear();
    }
    map
}

/// 把 rels 里的相对 Target 解析成 ZIP 内部绝对路径。
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

/// 解析 xl/sharedStrings.bin：BrtSstItem 的 XLWideString（富文本/扩展信息忽略）。
fn load_shared_strings<R: Read + Seek>(archive: &mut ZipArchive<R>) -> AppResult<Vec<String>> {
    let Some(bytes) = entry_bytes(archive, "xl/sharedStrings.bin")? else {
        return Ok(Vec::new());
    };
    let mut strings = Vec::new();
    let mut records = RecordReader::new(bytes.as_slice());
    let mut payload = Vec::new();
    loop {
        let id = records
            .next_into(&mut payload)
            .map_err(|error| AppError::bad(format!("解析 xl/sharedStrings.bin 失败: {error}")))?;
        match id {
            Some(brt::SST_ITEM) => {
                // BrtSstItem: flags(1) + str(XLWideString) + [富文本/扩展信息]
                if let Some((text, _)) = wide_string_at(&payload, 1) {
                    strings.push(text);
                }
            }
            Some(brt::END_SST) | None => break,
            _ => {}
        }
    }
    Ok(strings)
}

fn load_workbook(path: &str) -> AppResult<WorkbookData> {
    let mut archive = open_zip(path)?;
    let workbook_bytes = entry_bytes(&mut archive, "xl/workbook.bin")?.ok_or_else(|| {
        AppError::bad("无法读取工作簿: 缺少 xl/workbook.bin（文件可能被加密、损坏或不是 xlsb）")
    })?;
    let (raw_sheets, date1904) = parse_workbook_bin(&workbook_bytes)?;
    let rels = entry_bytes(&mut archive, "xl/_rels/workbook.bin.rels")?
        .map(|bytes| parse_rels(&bytes))
        .unwrap_or_default();
    let shared = Arc::new(load_shared_strings(&mut archive)?);
    let styles = Arc::new(match entry_bytes(&mut archive, "xl/styles.bin")? {
        Some(bytes) => parse_styles(&bytes),
        None => CellStyles::default(),
    });

    let mut sheets = Vec::new();
    let mut hidden_sheets = 0usize;
    for (position, bundle) in raw_sheets.iter().enumerate() {
        let target = rels
            .get(&bundle.rel_id)
            .map(|target| resolve_zip_path("xl", target))
            // rels 缺失/损坏时退回按顺序命名的工作表 entry。
            .unwrap_or_else(|| format!("xl/worksheets/sheet{}.bin", position + 1));
        // 图表工作表（chartsheets）/对话框表不是数据表，直接忽略（与 xlsx 路径一致）。
        if !target.contains("worksheets/") {
            continue;
        }
        if bundle.hidden {
            hidden_sheets += 1;
            continue;
        }
        sheets.push(SheetEntry {
            index: sheets.len(),
            name: bundle.name.clone(),
            target,
        });
    }

    Ok(WorkbookData {
        sheets,
        hidden_sheets,
        date1904,
        shared,
        styles,
    })
}

/// 只扫工作表 entry 的头部找 BrtWsDim（在 BrtBeginSheetData 之前），不解析任何行。
fn read_sheet_dim<R: Read + Seek>(
    archive: &mut ZipArchive<R>,
    target: &str,
) -> (Option<u64>, Option<u64>) {
    let Ok(entry) = archive.by_name(target) else {
        return (None, None);
    };
    let mut records = RecordReader::new(entry);
    let mut payload = Vec::new();
    let mut scanned = 0usize;
    loop {
        match records.next_into(&mut payload) {
            Ok(Some(id)) => match id {
                // BrtWsDim: rwFirst(4) + rwLast(4) + colFirst(4) + colLast(4)
                brt::WS_DIM => {
                    if payload.len() >= 16 {
                        let rw_last =
                            u32::from_le_bytes([payload[4], payload[5], payload[6], payload[7]]);
                        let col_last = u32::from_le_bytes([
                            payload[12], payload[13], payload[14], payload[15],
                        ]);
                        return (Some(rw_last as u64 + 1), Some(col_last as u64 + 1));
                    }
                    return (None, None);
                }
                // 已经进入行数据区，说明没有可用的 dimension。
                brt::BEGIN_SHEET_DATA => return (None, None),
                _ => {}
            },
            Ok(None) | Err(_) => return (None, None),
        }
        scanned += 1;
        if scanned > 4096 {
            return (None, None);
        }
    }
}

// ---------------------------------------------------------------- 行解析

/// 行缓冲：先攒 WIDTH_PROBE_ROWS 行确定「有效列宽」，再按宽度补齐输出。
///
/// 保留旧整表实现「末尾全空列裁掉」的语义，又不需要把整张表读进内存；宽度确定后
/// 出现的更宽行按原样输出（保留数据，由导入管线报字段数错误）。
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

/// 把 BRT 记录流拼成「一行 = 一个 JSON 数组」。
struct SheetParser {
    shared: Arc<Vec<String>>,
    styles: Arc<CellStyles>,
    date1904: bool,
    skip_rows: usize,
    row: Vec<Value>,
    current_row: Option<u32>,
    in_sheet_data: bool,
    ended: bool,
}

impl SheetParser {
    fn new(
        shared: Arc<Vec<String>>,
        styles: Arc<CellStyles>,
        date1904: bool,
        skip_rows: usize,
    ) -> Self {
        SheetParser {
            shared,
            styles,
            date1904,
            skip_rows,
            row: Vec::new(),
            current_row: None,
            in_sheet_data: false,
            ended: false,
        }
    }

    fn place(&mut self, column: usize, value: Value) {
        if column >= MAX_COLS {
            return;
        }
        if self.row.len() <= column {
            self.row.resize(column + 1, Value::Null);
        }
        self.row[column] = value;
    }

    /// 处理一条记录；凑满一行（且不是空行/被 skip_rows 跳过的行）就返回。
    fn on_record(&mut self, id: u32, payload: &[u8]) -> Result<Option<Vec<Value>>, String> {
        match id {
            brt::BEGIN_SHEET_DATA => {
                self.in_sheet_data = true;
                Ok(None)
            }
            brt::END_SHEET_DATA => {
                self.ended = true;
                Ok(self.take_row())
            }
            brt::ROW_HDR => {
                // 上一条行结束（BrtRowHdr 之后才是本行的单元格）。
                let previous = self.take_row();
                if payload.len() < 4 {
                    return Err("BrtRowHdr 记录过短".to_string());
                }
                let row = u32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]);
                if row > MAX_ROW_INDEX {
                    return Err(format!("行号 {row} 超出 Excel 上限"));
                }
                self.current_row = Some(row);
                Ok(previous)
            }
            _ if self.in_sheet_data
                && self.current_row.is_some()
                && matches!(id, 0x0001..=0x000B) =>
            {
                let Some(column) = cell_column(payload) else {
                    return Err(format!("单元格记录 0x{id:04X} 过短"));
                };
                let value = self.cell_value(id, payload)?;
                self.place(column as usize, value);
                Ok(None)
            }
            _ => Ok(None),
        }
    }

    /// 一条单元格记录 → JSON 值（日期/时长/整数语义与 xlsx 路径一致）。
    fn cell_value(&self, id: u32, payload: &[u8]) -> Result<Value, String> {
        if payload.len() < 7 {
            return Err(format!(
                "单元格记录 0x{id:04X} 长度 {} 不足 7 字节",
                payload.len()
            ));
        }
        let format = self.styles.format(cell_style_ref(payload));
        match id {
            brt::CELL_BLANK => Ok(Value::Null),
            // 错误单元格与空单元格一样输出 NULL（导入侧不区分 #DIV/0! 与空）。
            brt::CELL_ERROR | brt::FMLA_ERROR => Ok(Value::Null),
            brt::CELL_BOOL | brt::FMLA_BOOL => {
                let offset = fixed_value_offset(payload.len(), 1)?;
                Ok(Value::Bool(payload[offset] != 0))
            }
            brt::CELL_RK => {
                let offset = fixed_value_offset(payload.len(), 4)?;
                let raw = u32::from_le_bytes([
                    payload[offset],
                    payload[offset + 1],
                    payload[offset + 2],
                    payload[offset + 3],
                ]);
                Ok(number_value(rk_number(raw), format, self.date1904))
            }
            brt::CELL_REAL | brt::FMLA_NUM => {
                let offset = fixed_value_offset(payload.len(), 8)?;
                let mut bytes = [0u8; 8];
                bytes.copy_from_slice(&payload[offset..offset + 8]);
                Ok(number_value(
                    f64::from_le_bytes(bytes),
                    format,
                    self.date1904,
                ))
            }
            brt::CELL_ISST => {
                let offset = fixed_value_offset(payload.len(), 4)?;
                let index = u32::from_le_bytes([
                    payload[offset],
                    payload[offset + 1],
                    payload[offset + 2],
                    payload[offset + 3],
                ]);
                Ok(self
                    .shared
                    .get(index as usize)
                    .map(|text| Value::String(text.clone()))
                    .unwrap_or(Value::Null))
            }
            brt::CELL_ST | brt::FMLA_STRING => {
                // 规范是 8 字节头；非规范的 7 字节头用「字符串长度是否正好落到记录尾」区分。
                let text = wide_string_at(payload, 8)
                    .or_else(|| wide_string_at(payload, 7))
                    .map(|(text, _)| text)
                    .unwrap_or_default();
                Ok(Value::String(text))
            }
            _ => Ok(Value::Null),
        }
    }

    fn take_row(&mut self) -> Option<Vec<Value>> {
        self.current_row = None;
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

/// RkNumber（MS-XLSB 2.5.122）→ f64。
///
/// bit0 = fX100（值 /100），bit1 = fInt（30 位有符号整数），否则 30 位是 f64 的高 30 位。
fn rk_number(raw: u32) -> f64 {
    let divide_by_100 = raw & 0x01 != 0;
    let is_integer = raw & 0x02 != 0;
    let value = if is_integer {
        ((raw & 0xFFFF_FFFC) as i32 >> 2) as f64
    } else {
        let mut bytes = [0u8; 8];
        bytes[4..].copy_from_slice(&(raw & 0xFFFF_FFFC).to_le_bytes());
        f64::from_le_bytes(bytes)
    };
    if divide_by_100 {
        value / 100.0
    } else {
        value
    }
}

/// 数值单元格 → JSON（日期/时长/整数语义与 xlsx 路径一致）。
fn number_value(value: f64, format: CellFormat, date1904: bool) -> Value {
    match format {
        CellFormat::DateTime => excel_serial_value(value, date1904),
        CellFormat::TimeDelta => excel_duration_value(value),
        CellFormat::Other => normalize_number(value),
    }
}

// ---------------------------------------------------------------- 流式线程

/// 线程 → 消费端的消息：行 / 已读字节位置 / 错误。
enum StreamMsg {
    Row(Vec<Value>),
    Position(u64),
    Err(String),
}

/// 有界 channel 行源：生产线程解析 BRT，消费端被 drop（例如 preview 只看几条就结束）
/// 时 send 失败，线程立即退出，不会白读整张表。
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
                Ok(StreamMsg::Position(position)) => self.last_position = position,
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

/// 给 ZIP entry 套一层计数 Read：bytes_progress = 已解压字节 / entry.size()。
struct CountingReader<R> {
    inner: R,
    read: Arc<AtomicU64>,
}

impl<R: Read> Read for CountingReader<R> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let read = self.inner.read(buffer)?;
        if read > 0 {
            self.read.fetch_add(read as u64, Ordering::Relaxed);
        }
        Ok(read)
    }
}

fn send_msg(tx: &SyncSender<StreamMsg>, message: StreamMsg) -> bool {
    tx.send(message).is_ok()
}

struct Producer {
    path: String,
    target: String,
    shared: Arc<Vec<String>>,
    styles: Arc<CellStyles>,
    date1904: bool,
    skip_rows: usize,
    tx: SyncSender<StreamMsg>,
}

impl Producer {
    fn run(self) {
        if let Err(message) = self.produce() {
            let _ = send_msg(&self.tx, StreamMsg::Err(message));
        }
    }

    fn produce(&self) -> Result<(), String> {
        let mut archive = open_zip(&self.path).map_err(|error| error.to_string())?;
        let entry = archive
            .by_name(&self.target)
            .map_err(|error| format!("无法读取工作表 {}: {error}", self.target))?;
        let total_bytes = entry.size();
        let counter = Arc::new(AtomicU64::new(0));
        let reader = BufReader::with_capacity(
            64 * 1024,
            CountingReader {
                inner: entry,
                read: counter.clone(),
            },
        );
        let mut records = RecordReader::new(reader);
        let mut parser = SheetParser::new(
            self.shared.clone(),
            self.styles.clone(),
            self.date1904,
            self.skip_rows,
        );
        let mut emitter = WidthBufferedRows::new();
        let mut payload = Vec::new();
        let mut rows_seen = 0u64;
        loop {
            let id = records
                .next_into(&mut payload)
                .map_err(|error| format!("解析工作表 BRT 记录失败: {error}"))?;
            let Some(id) = id else { break };
            if let Some(row) = parser.on_record(id, &payload)? {
                for emitted in emitter.push(row) {
                    if !send_msg(&self.tx, StreamMsg::Row(emitted)) {
                        return Ok(());
                    }
                }
                rows_seen += 1;
                if rows_seen % 128 == 0 {
                    let position = counter.load(Ordering::Relaxed);
                    if !send_msg(&self.tx, StreamMsg::Position(position)) {
                        return Ok(());
                    }
                }
            }
            if parser.ended {
                break;
            }
        }
        for emitted in emitter.finish() {
            if !send_msg(&self.tx, StreamMsg::Row(emitted)) {
                return Ok(());
            }
        }
        let _ = send_msg(&self.tx, StreamMsg::Position(total_bytes));
        Ok(())
    }
}

// ---------------------------------------------------------------- 选表

/// 按工作表名或 0-based 序号选表（与 xlsx/xls 路径的语义一致）。
fn select_named(sheets: &[SheetEntry], selector: Option<&str>) -> AppResult<usize> {
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

// ---------------------------------------------------------------- 对外入口

/// 读默认表的前 want 个有效行（表头启发式用，最多读几行就停）。
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
    let mut records = RecordReader::new(BufReader::with_capacity(32 * 1024, entry));
    let mut parser = SheetParser::new(shared, styles, date1904, 0);
    let mut rows = Vec::new();
    let mut payload = Vec::new();
    loop {
        let id = records
            .next_into(&mut payload)
            .map_err(|error| AppError::bad(format!("解析工作表 BRT 记录失败: {error}")))?;
        let Some(id) = id else { break };
        if let Some(row) = parser.on_record(id, &payload).map_err(AppError::bad)? {
            rows.push(row);
            if rows.len() >= want {
                break;
            }
        }
        if parser.ended {
            break;
        }
    }
    Ok(rows)
}

/// inspect：只读 workbook.bin + 每表 BrtWsDim + 默认表前两行，不碰任何整表数据。
pub fn inspect(path: &str) -> AppResult<InspectResult> {
    let workbook = load_workbook(path)?;
    if workbook.sheets.is_empty() {
        return Err(AppError::bad("工作簿里没有可见的工作表"));
    }
    let mut archive = open_zip(path)?;
    let mut sheets = Vec::with_capacity(workbook.sheets.len());
    for sheet in &workbook.sheets {
        let (rows, cols) = read_sheet_dim(&mut archive, &sheet.target);
        sheets.push(SheetMetaBrief {
            index: sheet.index,
            name: sheet.name.clone(),
            rows,
            cols,
        });
    }
    drop(archive);

    let default = &workbook.sheets[0];
    let header_rows = read_head_rows(
        path,
        &default.target,
        workbook.shared.clone(),
        workbook.styles.clone(),
        workbook.date1904,
        INSPECT_HEADER_ROWS,
    )?;
    Ok(InspectResult {
        sheets,
        sheet: default.name.clone(),
        header_rows,
        hidden_sheets: workbook.hidden_sheets,
    })
}

/// 打开一张工作表，返回逐行拉取的 RowSource（解析在工作线程里做）。
pub fn open_sheet(path: &str, selector: Option<&str>, skip_rows: usize) -> AppResult<OpenedSheetLike> {
    let workbook = load_workbook(path)?;
    let selected = select_named(&workbook.sheets, selector)?;
    let sheet = &workbook.sheets[selected];
    let target = sheet.target.clone();
    let (total_rows, total_bytes) = {
        let mut archive = open_zip(path)?;
        let (rows, _) = read_sheet_dim(&mut archive, &target);
        let bytes = archive
            .by_name(&target)
            .map(|entry| entry.size())
            .unwrap_or(0);
        (rows, bytes)
    };
    let (tx, rx) = sync_channel(CHANNEL_BOUND);
    let producer = Producer {
        path: path.to_string(),
        target,
        shared: workbook.shared.clone(),
        styles: workbook.styles.clone(),
        date1904: workbook.date1904,
        skip_rows,
        tx,
    };
    let handle = std::thread::Builder::new()
        .name("dbpilot-xlsb-stream".to_string())
        .spawn(move || producer.run())
        .map_err(|error| AppError::bad(format!("启动流式读取线程失败: {error}")))?;
    Ok(OpenedSheetLike {
        sheet: sheet.name.clone(),
        sheets: workbook
            .sheets
            .iter()
            .map(|sheet| (sheet.index, sheet.name.clone()))
            .collect(),
        total_rows,
        source: Box::new(ChannelSource::new(rx, total_bytes, handle)),
    })
}

// ---------------------------------------------------------------- Lead 接线适配

/// 把本模块的 RowSource 适配成 excel_stream::RowSource。
struct AdaptedSource(Box<dyn RowSource>);

impl crate::excel_stream::RowSource for AdaptedSource {
    fn next_row(&mut self) -> AppResult<Option<Vec<Value>>> {
        self.0.next_row()
    }

    fn bytes_progress(&self) -> Option<(u64, u64)> {
        self.0.bytes_progress()
    }
}

/// InspectResult → excel_stream::InspectInfo（Lead 接线用，streaming 恒为 true）。
pub fn into_inspect_info(result: InspectResult) -> crate::excel_stream::InspectInfo {
    crate::excel_stream::InspectInfo {
        sheets: result
            .sheets
            .into_iter()
            .map(|sheet| crate::excel_stream::SheetMeta {
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

/// OpenedSheetLike → excel_stream::OpenedSheet（Lead 接线用）。
pub fn into_opened_sheet(opened: OpenedSheetLike) -> crate::excel_stream::OpenedSheet {
    crate::excel_stream::OpenedSheet {
        sheet: opened.sheet,
        sheets: opened
            .sheets
            .into_iter()
            .map(|(index, name)| json!({ "index": index, "name": name }))
            .collect(),
        total_rows: opened.total_rows,
        streaming: true,
        warnings: Vec::new(),
        source: Box::new(AdaptedSource(opened.source)),
    }
}

/// 一步到位的接线入口：excel_stream::inspect_workbook 里 ExcelKind::Xlsb 分支直接调用。
pub fn inspect_compat(path: &str) -> AppResult<crate::excel_stream::InspectInfo> {
    inspect(path).map(into_inspect_info)
}

/// 一步到位的接线入口：excel_stream::open_sheet 里 ExcelKind::Xlsb 分支直接调用。
pub fn open_sheet_compat(
    path: &str,
    selector: Option<&str>,
    skip_rows: usize,
) -> AppResult<crate::excel_stream::OpenedSheet> {
    open_sheet(path, selector, skip_rows).map(into_opened_sheet)
}

// ---------------------------------------------------------------- 单元测试

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    use std::path::PathBuf;

    // ============================================================ 最小 BRT 写入器
    //
    // 测试辅助：按 MS-XLSB 写一个「够小、够真」的 xlsb（ZIP + BRT）。故意不依赖任何
    // xlsb 写入库（rxlsb 的 BrtCellBool 布局与规范不符），这样写入器本身就是规范的一份
    // 可执行说明；产物还用 calamine（独立实现）反向验证（见 fixture_reads_with_calamine）。
    //
    // 规范单元格布局（MS-XLSB 2.5.9 Cell）：
    //   column(4) + iStyleRef(3) + fPhShow/保留(1) = 8 字节头
    //   BrtCellBlank = 8，BrtCellRk = 12，BrtCellReal = 16，BrtCellIsst = 12，
    //   BrtCellSt = 8 + 4 + 2N，BrtCellBool = 9，BrtCellError = 9。

    fn push_varint(out: &mut Vec<u8>, mut value: u64) {
        loop {
            let mut byte = (value & 0x7F) as u8;
            value >>= 7;
            if value != 0 {
                byte |= 0x80;
            }
            out.push(byte);
            if value == 0 {
                return;
            }
        }
    }

    fn wide(text: &str) -> Vec<u8> {
        let units: Vec<u16> = text.encode_utf16().collect();
        let mut out = Vec::with_capacity(4 + units.len() * 2);
        out.extend_from_slice(&(units.len() as u32).to_le_bytes());
        for unit in units {
            out.extend_from_slice(&unit.to_le_bytes());
        }
        out
    }

    struct BrtWriter {
        out: Vec<u8>,
    }

    impl BrtWriter {
        fn new() -> Self {
            BrtWriter { out: Vec::new() }
        }

        fn record(&mut self, id: u32, payload: &[u8]) {
            push_varint(&mut self.out, id as u64);
            push_varint(&mut self.out, payload.len() as u64);
            self.out.extend_from_slice(payload);
        }

        fn empty(&mut self, id: u32) {
            self.record(id, &[]);
        }

        fn into_inner(self) -> Vec<u8> {
            self.out
        }
    }

    /// 规范 Cell 头：column(4) + iStyleRef(3) + fPhShow/保留(1)。
    fn cell_header(col: u32, style: u32) -> Vec<u8> {
        let mut out = Vec::with_capacity(8);
        out.extend_from_slice(&col.to_le_bytes());
        out.extend_from_slice(&style.to_le_bytes()[..3]);
        out.push(0);
        out
    }

    #[derive(Clone, Debug)]
    enum Cell {
        Blank { col: u32, style: u32 },
        Int { col: u32, style: u32, value: i64 },
        Real { col: u32, style: u32, value: f64 },
        Bool { col: u32, style: u32, value: bool },
        Error { col: u32, style: u32, code: u8 },
        Text { col: u32, style: u32, text: String },
        Shared { col: u32, style: u32, index: u32 },
    }

    impl Cell {
        fn column(&self) -> u32 {
            match self {
                Cell::Blank { col, .. }
                | Cell::Int { col, .. }
                | Cell::Real { col, .. }
                | Cell::Bool { col, .. }
                | Cell::Error { col, .. }
                | Cell::Text { col, .. }
                | Cell::Shared { col, .. } => *col,
            }
        }

        /// 写入一条单元格记录，返回 payload 长度（用于断言规范布局）。
        fn write(&self, writer: &mut BrtWriter) -> usize {
            let (id, payload) = match self {
                Cell::Blank { col, style } => (brt::CELL_BLANK, cell_header(*col, *style)),
                Cell::Int { col, style, value } => {
                    // RkNumber fInt：bit1=1，bit0=0（不除 100），高 30 位是有符号整数。
                    let raw = (((*value as i32) << 2) | 0b10) as u32;
                    let mut payload = cell_header(*col, *style);
                    payload.extend_from_slice(&raw.to_le_bytes());
                    (brt::CELL_RK, payload)
                }
                Cell::Real { col, style, value } => {
                    let mut payload = cell_header(*col, *style);
                    payload.extend_from_slice(&value.to_le_bytes());
                    (brt::CELL_REAL, payload)
                }
                Cell::Bool { col, style, value } => {
                    let mut payload = cell_header(*col, *style);
                    payload.push(u8::from(*value));
                    (brt::CELL_BOOL, payload)
                }
                Cell::Error { col, style, code } => {
                    let mut payload = cell_header(*col, *style);
                    payload.push(*code);
                    (brt::CELL_ERROR, payload)
                }
                Cell::Text { col, style, text } => {
                    let mut payload = cell_header(*col, *style);
                    payload.extend_from_slice(&wide(text));
                    (brt::CELL_ST, payload)
                }
                Cell::Shared { col, style, index } => {
                    let mut payload = cell_header(*col, *style);
                    payload.extend_from_slice(&index.to_le_bytes());
                    (brt::CELL_ISST, payload)
                }
            };
            let len = payload.len();
            writer.record(id, &payload);
            len
        }
    }

    fn int(col: u32, value: i64) -> Cell {
        Cell::Int {
            col,
            style: 0,
            value,
        }
    }

    fn real(col: u32, value: f64) -> Cell {
        Cell::Real {
            col,
            style: 0,
            value,
        }
    }

    fn real_styled(col: u32, style: u32, value: f64) -> Cell {
        Cell::Real {
            col,
            style,
            value,
        }
    }

    fn boolean(col: u32, value: bool) -> Cell {
        Cell::Bool {
            col,
            style: 0,
            value,
        }
    }

    fn blank(col: u32) -> Cell {
        Cell::Blank { col, style: 0 }
    }

    fn shared(col: u32, index: u32) -> Cell {
        Cell::Shared {
            col,
            style: 0,
            index,
        }
    }

    fn text(col: u32, value: &str) -> Cell {
        Cell::Text {
            col,
            style: 0,
            text: value.to_string(),
        }
    }

    struct SheetSpec {
        name: String,
        hidden: bool,
        rows: Vec<Vec<Cell>>,
    }

    struct WorkbookSpec {
        sheets: Vec<SheetSpec>,
        shared: Vec<String>,
    }

    /// 工作表 entry：BrtBeginSheet / BrtWsDim / BrtBeginSheetData / 行 / BrtEndSheetData。
    fn write_sheet_bin(rows: &[Vec<Cell>]) -> Vec<u8> {
        let mut writer = BrtWriter::new();
        writer.empty(0x0081); // BrtBeginSheet

        let mut last_row = 0u32;
        let mut last_col = 0u32;
        for (index, row) in rows.iter().enumerate() {
            for cell in row {
                last_row = last_row.max(index as u32);
                last_col = last_col.max(cell.column());
            }
        }
        // BrtWsDim: rwFirst(4) + rwLast(4) + colFirst(4) + colLast(4)
        let mut dim = Vec::with_capacity(16);
        dim.extend_from_slice(&0u32.to_le_bytes());
        dim.extend_from_slice(&last_row.to_le_bytes());
        dim.extend_from_slice(&0u32.to_le_bytes());
        dim.extend_from_slice(&last_col.to_le_bytes());
        writer.record(brt::WS_DIM, &dim);

        writer.empty(brt::BEGIN_SHEET_DATA);
        for (index, row) in rows.iter().enumerate() {
            // BrtRowHdr: rw(4) + ixfe(4) + miyRw(2) + flags(1) + reserved(1) + ccolspan(2)
            let mut header = Vec::with_capacity(14);
            header.extend_from_slice(&(index as u32).to_le_bytes());
            header.extend_from_slice(&0u32.to_le_bytes());
            header.extend_from_slice(&300u16.to_le_bytes());
            header.push(0);
            header.push(0);
            header.extend_from_slice(&0u16.to_le_bytes());
            writer.record(brt::ROW_HDR, &header);
            for cell in row {
                cell.write(&mut writer);
            }
        }
        writer.empty(brt::END_SHEET_DATA);
        writer.empty(0x0082); // BrtEndSheet
        writer.into_inner()
    }

    fn write_workbook_bin(sheets: &[SheetSpec], date1904: bool) -> Vec<u8> {
        let mut writer = BrtWriter::new();
        writer.empty(0x0083); // BrtBeginBook
        // BrtWbProp: flags(4) + dwThemeVersion(4) + strName；bit0 = f1904。
        let mut prop = Vec::new();
        prop.extend_from_slice(&u32::from(date1904).to_le_bytes());
        prop.extend_from_slice(&0u32.to_le_bytes());
        prop.extend_from_slice(&wide(""));
        writer.record(brt::WB_PROP, &prop);
        writer.empty(0x008F); // BrtBeginBundleShs
        for (index, sheet) in sheets.iter().enumerate() {
            // BrtBundleSh: hsState(4) + iTabID(4) + strRelID + strName
            let mut payload = Vec::new();
            payload.extend_from_slice(&u32::from(sheet.hidden).to_le_bytes());
            payload.extend_from_slice(&(index as u32 + 1).to_le_bytes());
            payload.extend_from_slice(&wide(&format!("rId{}", index + 1)));
            payload.extend_from_slice(&wide(&sheet.name));
            writer.record(brt::BUNDLE_SH, &payload);
        }
        writer.empty(brt::END_BUNDLE_SHS);
        writer.empty(0x0084); // BrtEndBook
        writer.into_inner()
    }

    fn write_shared_strings_bin(strings: &[String]) -> Vec<u8> {
        let mut writer = BrtWriter::new();
        // BrtBeginSst: cstTotal(4) + cstUnique(4)
        let mut begin = Vec::new();
        begin.extend_from_slice(&(strings.len() as u32).to_le_bytes());
        begin.extend_from_slice(&(strings.len() as u32).to_le_bytes());
        writer.record(brt::BEGIN_SST, &begin);
        for text in strings {
            // BrtSstItem: flags(1) + str(XLWideString)
            let mut payload = vec![0u8];
            payload.extend_from_slice(&wide(text));
            writer.record(brt::SST_ITEM, &payload);
        }
        writer.empty(brt::END_SST);
        writer.into_inner()
    }

    /// 固定样式表：cellXfs = [General, ifmt 14, ifmt 22, ifmt 21, ifmt 165(自定义时长)]。
    ///
    /// 同时写两条 BrtFmt（自定义格式串），让 styles.bin 的自定义格式分支也有覆盖：
    /// 164 "0.00"（非日期）、165 "[h]:mm:ss"（时长）。
    fn write_styles_bin() -> Vec<u8> {
        let mut writer = BrtWriter::new();
        writer.empty(0x0116); // BrtBeginStyleSheet
        let custom: [(u16, &str); 2] = [(164, "0.00"), (165, "[h]:mm:ss")];
        writer.record(0x0267, &(custom.len() as u32).to_le_bytes()); // BrtBeginFmts
        for (ifmt, code) in custom {
            let mut payload = Vec::new();
            payload.extend_from_slice(&ifmt.to_le_bytes());
            payload.extend_from_slice(&wide(code));
            writer.record(brt::FMT, &payload);
        }
        writer.empty(0x0268); // BrtEndFmts
        // 下标 4 用自定义格式 165（"[h]:mm:ss"）验证自定义格式分支。
        let xfs: [u16; 5] = [0, 14, 22, 21, 165];
        writer.record(brt::BEGIN_CELL_XFS, &(xfs.len() as u32).to_le_bytes());
        for ifmt in xfs {
            // BrtXF: ixfeParent(2) + ifmt(2) + 对齐/保护位
            let mut payload = Vec::new();
            payload.extend_from_slice(&0xFFFFu16.to_le_bytes());
            payload.extend_from_slice(&ifmt.to_le_bytes());
            payload.extend_from_slice(&[0u8; 8]);
            writer.record(brt::XF, &payload);
        }
        writer.empty(brt::END_CELL_XFS);
        writer.empty(0x0117); // BrtEndStyleSheet
        writer.into_inner()
    }

    const CONTENT_TYPES: &str = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="bin" ContentType="application/vnd.ms-excel.sheet.binary.macroEnabled.main"/>
</Types>"#;

    const ROOT_RELS: &str = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.bin"/>
</Relationships>"#;

    fn workbook_rels(sheet_count: usize) -> String {
        let mut xml = String::from(
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n\
             <Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n",
        );
        for index in 1..=sheet_count {
            xml.push_str(&format!(
                "<Relationship Id=\"rId{index}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet{index}.bin\"/>\n"
            ));
        }
        xml.push_str(&format!(
            "<Relationship Id=\"rId{}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.bin\"/>\n",
            sheet_count + 1
        ));
        xml.push_str(&format!(
            "<Relationship Id=\"rId{}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.bin\"/>\n",
            sheet_count + 2
        ));
        xml.push_str("</Relationships>");
        xml
    }

    fn zip_entry(
        zip: &mut zip::ZipWriter<&mut Cursor<Vec<u8>>>,
        name: &str,
        bytes: &[u8],
        options: zip::write::SimpleFileOptions,
    ) {
        use std::io::Write as _;
        zip.start_file(name, options).expect("start zip entry");
        zip.write_all(bytes).expect("write zip entry");
    }

    /// 把 WorkbookSpec 写成 .xlsb 的字节（ZIP + [Content_Types].xml + rels + BRT）。
    fn workbook_bytes(spec: &WorkbookSpec) -> Vec<u8> {
        let mut cursor = Cursor::new(Vec::new());
        {
            let mut zip = zip::ZipWriter::new(&mut cursor);
            let options = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            zip_entry(&mut zip, "[Content_Types].xml", CONTENT_TYPES.as_bytes(), options);
            zip_entry(&mut zip, "_rels/.rels", ROOT_RELS.as_bytes(), options);
            let rels = workbook_rels(spec.sheets.len());
            zip_entry(
                &mut zip,
                "xl/_rels/workbook.bin.rels",
                rels.as_bytes(),
                options,
            );
            zip_entry(
                &mut zip,
                "xl/workbook.bin",
                &write_workbook_bin(&spec.sheets, false),
                options,
            );
            zip_entry(
                &mut zip,
                "xl/sharedStrings.bin",
                &write_shared_strings_bin(&spec.shared),
                options,
            );
            zip_entry(&mut zip, "xl/styles.bin", &write_styles_bin(), options);
            for (index, sheet) in spec.sheets.iter().enumerate() {
                zip_entry(
                    &mut zip,
                    &format!("xl/worksheets/sheet{}.bin", index + 1),
                    &write_sheet_bin(&sheet.rows),
                    options,
                );
            }
            zip.finish().expect("finish zip");
        }
        cursor.into_inner()
    }

    fn temp_path(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "rma-xlsb-stream-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&dir).expect("create temp dir");
        dir.join(name)
    }

    fn write_temp_workbook(spec: &WorkbookSpec, name: &str) -> PathBuf {
        let path = temp_path(name);
        std::fs::write(&path, workbook_bytes(spec)).expect("write workbook");
        path
    }

    fn fixture_path() -> String {
        format!("{}/tests/fixtures/excel_multi.xlsb", env!("CARGO_MANIFEST_DIR"))
    }

    // ------------------------------------------------------------ fixture 内容
    //
    // 与 tests/fixtures/excel_multi.xlsx 完全对齐（员工 / 订单 / 配置 + 隐藏数据）：
    // 数字、中文、日期、日期时间、纯时间、布尔、NULL、小数。
    //
    // 样式表下标：0 = General，1 = ifmt 14（日期），2 = ifmt 22（日期时间），
    // 3 = ifmt 21（纯时间）。Excel 序列号按 1900 日期系统：2021-03-05 = 44260。

    const DATE_STYLE: u32 = 1;
    const DATETIME_STYLE: u32 = 2;
    const TIME_STYLE: u32 = 3;

    const SERIAL_2021_03_05: f64 = 44_260.0;
    const SERIAL_2022_07_18: f64 = 44_760.0;
    const SERIAL_2023_01_02: f64 = 44_928.0;
    const SERIAL_2023_11_30: f64 = 45_260.0;

    fn day_fraction(hours: u32, minutes: u32, seconds: u32) -> f64 {
        (hours * 3600 + minutes * 60 + seconds) as f64 / 86_400.0
    }

    fn excel_multi_spec() -> WorkbookSpec {
        let shared_strings: Vec<String> = [
            "id", "姓名", "入职日期", "活跃", "评分", "备注", "登录时间", "打卡时间", "张伟", "李娜",
            "王强", "赵敏", "优秀", "试用", "订单号", "客户", "金额", "甲公司", "乙公司", "丙公司",
            "键", "值", "version", "1.0", "env", "prod", "secret", "不应出现在工作表列表",
        ]
        .iter()
        .map(|text| text.to_string())
        .collect();
        let index = |text: &str| -> u32 {
            shared_strings
                .iter()
                .position(|candidate| candidate == text)
                .expect("shared string") as u32
        };

        let employees = vec![
            vec![
                shared(0, index("id")),
                shared(1, index("姓名")),
                shared(2, index("入职日期")),
                shared(3, index("活跃")),
                shared(4, index("评分")),
                shared(5, index("备注")),
                shared(6, index("登录时间")),
                shared(7, index("打卡时间")),
            ],
            vec![
                int(0, 1),
                shared(1, index("张伟")),
                real_styled(2, DATE_STYLE, SERIAL_2021_03_05),
                boolean(3, true),
                real(4, 88.5),
                blank(5),
                real_styled(6, DATETIME_STYLE, SERIAL_2021_03_05 + day_fraction(9, 30, 0)),
                real_styled(7, TIME_STYLE, day_fraction(9, 30, 0)),
            ],
            vec![
                int(0, 2),
                shared(1, index("李娜")),
                real_styled(2, DATE_STYLE, SERIAL_2022_07_18),
                boolean(3, false),
                int(4, 92),
                shared(5, index("优秀")),
                real_styled(6, DATETIME_STYLE, SERIAL_2022_07_18 + day_fraction(14, 5, 30)),
                real_styled(7, TIME_STYLE, day_fraction(9, 5, 30)),
            ],
            vec![
                int(0, 3),
                shared(1, index("王强")),
                real_styled(2, DATE_STYLE, SERIAL_2023_01_02),
                boolean(3, true),
                real(4, 76.25),
                blank(5),
                real_styled(6, DATETIME_STYLE, SERIAL_2023_01_02 + day_fraction(8, 0, 0)),
                real_styled(7, TIME_STYLE, day_fraction(8, 45, 0)),
            ],
            vec![
                int(0, 4),
                shared(1, index("赵敏")),
                real_styled(2, DATE_STYLE, SERIAL_2023_11_30),
                boolean(3, true),
                int(4, 66),
                shared(5, index("试用")),
                real_styled(6, DATETIME_STYLE, SERIAL_2023_11_30 + day_fraction(18, 20, 0)),
                real_styled(7, TIME_STYLE, day_fraction(10, 15, 0)),
            ],
        ];

        let orders = vec![
            vec![
                shared(0, index("订单号")),
                shared(1, index("客户")),
                shared(2, index("金额")),
            ],
            vec![
                int(0, 1001),
                shared(1, index("甲公司")),
                real(2, 299.5),
            ],
            vec![
                int(0, 1002),
                shared(1, index("乙公司")),
                real(2, 1280.0),
            ],
            vec![
                int(0, 1003),
                shared(1, index("丙公司")),
                real(2, 58.75),
            ],
        ];

        let config = vec![
            vec![shared(0, index("键")), shared(1, index("值"))],
            vec![shared(0, index("version")), shared(1, index("1.0"))],
            vec![shared(0, index("env")), shared(1, index("prod"))],
        ];

        let hidden = vec![
            vec![shared(0, index("secret"))],
            vec![shared(0, index("不应出现在工作表列表"))],
        ];

        WorkbookSpec {
            sheets: vec![
                SheetSpec {
                    name: "员工".to_string(),
                    hidden: false,
                    rows: employees,
                },
                SheetSpec {
                    name: "订单".to_string(),
                    hidden: false,
                    rows: orders,
                },
                SheetSpec {
                    name: "配置".to_string(),
                    hidden: false,
                    rows: config,
                },
                SheetSpec {
                    name: "隐藏数据".to_string(),
                    hidden: true,
                    rows: hidden,
                },
            ],
            shared: shared_strings,
        }
    }

    /// 重新生成提交到 git 的二进制 fixture（tests/fixtures/excel_multi.xlsb）。
    ///
    /// 复现命令：
    ///   CARGO_INCREMENTAL=0 cargo test --offline --lib \
    ///     xlsb_stream::tests::write_excel_multi_fixture -- --ignored --nocapture
    #[test]
    #[ignore = "只在重新生成二进制 fixture 时跑"]
    fn write_excel_multi_fixture() {
        let bytes = workbook_bytes(&excel_multi_spec());
        let path = fixture_path();
        std::fs::write(&path, &bytes).expect("write fixture");
        println!("wrote {path} ({} bytes)", bytes.len());
    }

    // ============================================================ 变长编码

    #[test]
    fn varint_roundtrip_covers_one_to_four_bytes() {
        // (值, 期望字节数)：0x7F 是 1 字节上限，0x80 需要 2 字节，依此类推。
        let cases: [(u64, usize); 8] = [
            (0, 1),
            (0x7F, 1),
            (0x80, 2),
            (0x3FFF, 2),
            (0x4000, 3),
            (0x1F_FFFF, 3),
            (0x20_0000, 4),
            (0x0FFF_FFFF, 4),
        ];
        for (value, expected_len) in cases {
            let mut encoded = Vec::new();
            push_varint(&mut encoded, value);
            assert_eq!(
                encoded.len(),
                expected_len,
                "值 {value:#X} 应编码成 {expected_len} 字节，实际 {encoded:?}"
            );
            let mut reader = encoded.as_slice();
            let decoded = read_varint(&mut reader, 4).expect("decode").expect("value");
            assert_eq!(decoded, value, "值 {value:#X} 往返不一致");
            assert!(reader.is_empty(), "值 {value:#X} 有多余字节");
        }
    }

    #[test]
    fn varint_rejects_more_than_four_bytes_and_reports_eof() {
        // 4 个续接字节 + 1 个结束字节 → 超过 4 字节上限。
        let mut reader = [0x80u8, 0x80, 0x80, 0x80, 0x01].as_slice();
        let error = read_varint(&mut reader, 4).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);

        // 记录边界处的 EOF → Ok(None)。
        let mut empty = [].as_slice();
        assert!(read_varint(&mut empty, 4).unwrap().is_none());

        // 记录中间 EOF → UnexpectedEof。
        let mut truncated = [0x80u8].as_slice();
        let error = read_varint(&mut truncated, 4).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::UnexpectedEof);
    }

    #[test]
    fn record_reader_parses_id_and_size_varints() {
        // 1 字节 id（0x0000 BrtRowHdr）+ 1 字节长度 0。
        let mut bytes = Vec::new();
        let mut writer = BrtWriter::new();
        writer.record(0x0000, &[]);
        // 2 字节 id（0x009C BrtBundleSh）+ 2 字节长度（300）。
        writer.record(0x009C, &vec![0xABu8; 300]);
        // 2 字节 id + 3 字节长度（20_000）。
        writer.record(0x0269, &vec![0xCDu8; 20_000]);
        bytes.extend_from_slice(&writer.into_inner());

        let mut records = RecordReader::new(bytes.as_slice());
        let mut payload = Vec::new();
        assert_eq!(records.next_into(&mut payload).unwrap(), Some(0x0000));
        assert!(payload.is_empty());
        assert_eq!(records.next_into(&mut payload).unwrap(), Some(0x009C));
        assert_eq!(payload.len(), 300);
        assert!(payload.iter().all(|byte| *byte == 0xAB));
        assert_eq!(records.next_into(&mut payload).unwrap(), Some(0x0269));
        assert_eq!(payload.len(), 20_000);
        assert!(payload.iter().all(|byte| *byte == 0xCD));
        assert_eq!(records.next_into(&mut payload).unwrap(), None);
    }

    #[test]
    fn record_id_beyond_two_bytes_still_decodes() {
        // MS-XLSB 的记录号最多 2 字节，但读端按 4 字节 varint 解，不会把长记录号读错位。
        let mut writer = BrtWriter::new();
        writer.record(0x1_0000, &[1, 2, 3]);
        writer.record(0x0000, &[]);
        let bytes = writer.into_inner();
        let mut records = RecordReader::new(bytes.as_slice());
        let mut payload = Vec::new();
        assert_eq!(records.next_into(&mut payload).unwrap(), Some(0x1_0000));
        assert_eq!(payload, vec![1, 2, 3]);
        assert_eq!(records.next_into(&mut payload).unwrap(), Some(0x0000));
    }

    // ============================================================ 单元格布局

    #[test]
    fn writer_uses_ms_xlsb_cell_layout() {
        // 规范长度：Blank 8 / Rk 12 / Real 16 / Isst 12 / Bool 9 / St 8+4+2N。
        let cases: [(Cell, usize); 6] = [
            (blank(0), 8),
            (int(0, 42), 12),
            (real(0, 1.5), 16),
            (shared(0, 3), 12),
            (boolean(0, true), 9),
            (text(0, "中文"), 8 + 4 + 4),
        ];
        for (cell, expected) in cases {
            let mut writer = BrtWriter::new();
            let len = cell.write(&mut writer);
            assert_eq!(len, expected, "单元格 {cell:?} 的 payload 长度不符");
        }
        // 1 字节中文 = 2 个 UTF-16 单元（"中文" 是 2 个字符 = 4 字节）。
        let mut writer = BrtWriter::new();
        assert_eq!(text(0, "中").write(&mut writer), 8 + 4 + 2);
    }

    #[test]
    fn fixed_value_offset_accepts_spec_and_legacy_headers() {
        // 规范 8 字节头。
        assert_eq!(fixed_value_offset(8 + 1, 1).unwrap(), 8);
        assert_eq!(fixed_value_offset(8 + 4, 4).unwrap(), 8);
        assert_eq!(fixed_value_offset(8 + 8, 8).unwrap(), 8);
        // 非规范的 7 字节头（column 4 + iStyleRef 3）也读得出来。
        assert_eq!(fixed_value_offset(7 + 1, 1).unwrap(), 7);
        assert_eq!(fixed_value_offset(7 + 4, 4).unwrap(), 7);
        // 公式记录（值后面还有公式字节）按规范从 8 开始。
        assert_eq!(fixed_value_offset(8 + 8 + 6, 8).unwrap(), 8);
        // 明显对不上的长度报错而不是 panic。
        assert!(fixed_value_offset(3, 8).is_err());
    }

    #[test]
    fn rk_number_decodes_integer_fraction_and_hundredths() {
        // 整数 42：0b10 | (42 << 2)
        assert_eq!(rk_number((42u32 << 2) | 0b10), 42.0);
        assert_eq!(rk_number((0u32 << 2) | 0b10), 0.0);
        assert_eq!(rk_number(((-7i32 as u32) << 2) | 0b10), -7.0);
        // fX100：42 / 100 = 0.42
        assert_eq!(rk_number((42u32 << 2) | 0b11), 0.42);
        // 浮点：只保留 f64 的高 30 位（1.5 = 0x3FF8000000000000 → 高 32 位 0x3FF80000）。
        let mut bytes = [0u8; 8];
        bytes[4..].copy_from_slice(&1.5f64.to_le_bytes()[4..]);
        let raw = u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]) & 0xFFFF_FFFC;
        assert_eq!(rk_number(raw), 1.5);
    }

    #[test]
    fn detect_custom_format_matches_xlsx_heuristics() {
        assert_eq!(detect_custom_format("yyyy-mm-dd"), CellFormat::DateTime);
        assert_eq!(detect_custom_format("h:mm:ss"), CellFormat::DateTime);
        assert_eq!(detect_custom_format("[h]:mm:ss"), CellFormat::TimeDelta);
        assert_eq!(detect_custom_format("[mm]:ss"), CellFormat::TimeDelta);
        assert_eq!(detect_custom_format("0.00"), CellFormat::Other);
        // 引号里的 m/d 不算日期格式。
        assert_eq!(detect_custom_format("\"m/d\"0"), CellFormat::Other);
        // 内建格式。
        assert_eq!(builtin_format(14), CellFormat::DateTime);
        assert_eq!(builtin_format(22), CellFormat::DateTime);
        assert_eq!(builtin_format(21), CellFormat::DateTime);
        assert_eq!(builtin_format(46), CellFormat::TimeDelta);
        assert_eq!(builtin_format(0), CellFormat::Other);
    }

    // ============================================================ 行解析（合成记录）

    fn parser_for(shared: Vec<String>, styles: Vec<CellFormat>, skip_rows: usize) -> SheetParser {
        SheetParser::new(
            Arc::new(shared),
            Arc::new(CellStyles { formats: styles }),
             false,
            skip_rows,
        )
    }

    /// 用 BrtWriter 拼一段 sheetData，交给 SheetParser 解析出所有行。
    fn parse_rows(parser: &mut SheetParser, bytes: &[u8]) -> Vec<Vec<Value>> {
        let mut records = RecordReader::new(bytes);
        let mut payload = Vec::new();
        let mut rows = Vec::new();
        while let Some(id) = records.next_into(&mut payload).expect("record") {
            if let Some(row) = parser.on_record(id, &payload).expect("parse") {
                rows.push(row);
            }
            if parser.ended {
                break;
            }
        }
        rows
    }

    fn sheet_data_bytes(rows: &[Vec<Cell>]) -> Vec<u8> {
        let mut writer = BrtWriter::new();
        writer.empty(brt::BEGIN_SHEET_DATA);
        for (index, row) in rows.iter().enumerate() {
            let mut header = Vec::with_capacity(14);
            header.extend_from_slice(&(index as u32).to_le_bytes());
            header.extend_from_slice(&0u32.to_le_bytes());
            header.extend_from_slice(&300u16.to_le_bytes());
            header.push(0);
            header.push(0);
            header.extend_from_slice(&0u16.to_le_bytes());
            writer.record(brt::ROW_HDR, &header);
            for cell in row {
                cell.write(&mut writer);
            }
        }
        writer.empty(brt::END_SHEET_DATA);
        writer.into_inner()
    }

    #[test]
    fn parser_reads_every_supported_cell_kind() {
        let strings = vec!["甲".to_string(), "乙".to_string()];
        let styles = vec![
            CellFormat::Other,
            CellFormat::DateTime,
            CellFormat::TimeDelta,
            CellFormat::Other,
        ];
        let mut parser = parser_for(strings, styles, 0);
        let rows = vec![
            vec![
                blank(0),
                int(1, 7),
                real(2, 2.5),
                boolean(3, true),
                boolean(4, false),
                shared(5, 0),
                shared(6, 1),
                text(7, "内联"),
                Cell::Error {
                    col: 8,
                    style: 0,
                    code: 0x07,
                },
            ],
            vec![
                real_styled(0, 1, 44_260.0),
                real_styled(1, 2, 1.5),
                real_styled(2, 3, 12.0),
                int(3, 0),
            ],
        ];
        let parsed = parse_rows(&mut parser, &sheet_data_bytes(&rows));
        assert_eq!(parsed.len(), 2, "{parsed:?}");
        // 末尾的 Null（错误单元格）按「裁掉尾部 NULL」语义去掉。
        assert_eq!(
            parsed[0],
            vec![
                Value::Null,
                json!(7),
                json!(2.5),
                json!(true),
                json!(false),
                json!("甲"),
                json!("乙"),
                json!("内联"),
            ]
        );
        // 日期 / 时长 / 普通数值三种格式判定。
        assert_eq!(
            parsed[1],
            vec![json!("2021-03-05"), json!("36:00:00"), json!(12), json!(0)]
        );
    }

    #[test]
    fn parser_tolerates_legacy_seven_byte_cell_header() {
        // 有些非规范写入器（以及历史版本的读取器）按 7 字节头写值：column(4)+style(3)。
        // 读端用「记录长度 - 值长度」反推偏移，7/8 两种都读得出同样的值。
        let mut writer = BrtWriter::new();
        writer.empty(brt::BEGIN_SHEET_DATA);
        let mut row_header = Vec::new();
        row_header.extend_from_slice(&0u32.to_le_bytes());
        row_header.extend_from_slice(&0u32.to_le_bytes());
        row_header.extend_from_slice(&300u16.to_le_bytes());
        row_header.push(0);
        row_header.push(0);
        row_header.extend_from_slice(&0u16.to_le_bytes());
        writer.record(brt::ROW_HDR, &row_header);

        let header = |col: u32| -> Vec<u8> {
            let mut out = Vec::new();
            out.extend_from_slice(&col.to_le_bytes());
            out.extend_from_slice(&0u32.to_le_bytes()[..3]);
            out
        };
        // Bool(7 字节头 + 1 = 8 字节总长)
        let mut bool_payload = header(0);
        bool_payload.push(1);
        writer.record(brt::CELL_BOOL, &bool_payload);
        // Rk 整数 9（7 字节头 + 4 = 11）
        let mut rk_payload = header(1);
        rk_payload.extend_from_slice(&(((9i32 << 2) | 0b10) as u32).to_le_bytes());
        writer.record(brt::CELL_RK, &rk_payload);
        // Real 1.25（7 字节头 + 8 = 15）
        let mut real_payload = header(2);
        real_payload.extend_from_slice(&1.25f64.to_le_bytes());
        writer.record(brt::CELL_REAL, &real_payload);
        // St（7 字节头 + 4 + 2N）
        let mut st_payload = header(3);
        st_payload.extend_from_slice(&wide("七字节"));
        writer.record(brt::CELL_ST, &st_payload);
        // Isst 索引 1
        let mut isst_payload = header(4);
        isst_payload.extend_from_slice(&1u32.to_le_bytes());
        writer.record(brt::CELL_ISST, &isst_payload);
        writer.empty(brt::END_SHEET_DATA);
        let bytes = writer.into_inner();

        let mut parser = parser_for(vec!["零".to_string(), "一".to_string()], Vec::new(), 0);
        let rows = parse_rows(&mut parser, &bytes);
        assert_eq!(
            rows,
            vec![vec![
                json!(true),
                json!(9),
                json!(1.25),
                json!("七字节"),
                json!("一"),
            ]]
        );
    }

    #[test]
    fn parser_pads_by_column_trims_trailing_nulls_and_skips_blank_rows() {
        let mut parser = parser_for(Vec::new(), Vec::new(), 0);
        let rows = vec![
            vec![int(0, 1), int(2, 3)],   // 第 1 列空 → 补 NULL
            vec![],                       // 全空行 → 跳过
            vec![blank(0), blank(1)],     // 只有空单元格 → 跳过
            vec![int(1, 9)],              // 前面补 NULL，尾部 NULL 裁掉
        ];
        let parsed = parse_rows(&mut parser, &sheet_data_bytes(&rows));
        assert_eq!(
            parsed,
            vec![vec![json!(1), Value::Null, json!(3)], vec![Value::Null, json!(9)]]
        );
    }

    #[test]
    fn parser_applies_skip_rows_to_effective_rows_only() {
        let rows = vec![
            vec![int(0, 1)],
            vec![],          // 全空行不算有效行，也不消耗 skip_rows
            vec![int(0, 2)],
            vec![int(0, 3)],
        ];
        let mut parser = parser_for(Vec::new(), Vec::new(), 1);
        let parsed = parse_rows(&mut parser, &sheet_data_bytes(&rows));
        assert_eq!(parsed, vec![vec![json!(2)], vec![json!(3)]]);
    }

    #[test]
    fn parser_ignores_cells_outside_sheet_data_and_huge_columns() {
        // 行数据区之外出现的 0x0005 记录（例如 BrtWsProp 的邻居）不能被当成单元格。
        let mut writer = BrtWriter::new();
        writer.record(brt::CELL_REAL, &{
            let mut payload = cell_header(0, 0);
            payload.extend_from_slice(&1.0f64.to_le_bytes());
            payload
        });
        writer.empty(brt::BEGIN_SHEET_DATA);
        let mut header = Vec::new();
        header.extend_from_slice(&0u32.to_le_bytes());
        header.extend_from_slice(&0u32.to_le_bytes());
        header.extend_from_slice(&300u16.to_le_bytes());
        header.push(0);
        header.push(0);
        header.extend_from_slice(&0u16.to_le_bytes());
        writer.record(brt::ROW_HDR, &header);
        // 超出 Excel 列上限的列号被忽略，不会按恶意列号扩容。
        let mut payload = cell_header(1_000_000, 0);
        payload.extend_from_slice(&1.0f64.to_le_bytes());
        writer.record(brt::CELL_REAL, &payload);
        writer.record(brt::CELL_REAL, &{
            let mut payload = cell_header(1, 0);
            payload.extend_from_slice(&2.0f64.to_le_bytes());
            payload
        });
        writer.empty(brt::END_SHEET_DATA);
        let bytes = writer.into_inner();

        let mut parser = parser_for(Vec::new(), Vec::new(), 0);
        let rows = parse_rows(&mut parser, &bytes);
        assert_eq!(rows, vec![vec![Value::Null, json!(2)]]);
    }

    // ============================================================ fixture（3 表）

    #[test]
    fn inspect_lists_visible_sheets_and_header_rows() {
        let info = inspect(&fixture_path()).expect("inspect");
        let names: Vec<&str> = info.sheets.iter().map(|sheet| sheet.name.as_str()).collect();
        assert_eq!(names, vec!["员工", "订单", "配置"]);
        assert_eq!(info.sheet, "员工");
        assert_eq!(info.hidden_sheets, 1, "隐藏数据表要计入 hidden_sheets");
        // 员工表：表头 + 4 行数据 = 5 行，8 列。
        assert_eq!(info.sheets[0].rows, Some(5));
        assert_eq!(info.sheets[0].cols, Some(8));
        assert_eq!(info.sheets[0].index, 0);
        assert_eq!(info.sheets[1].rows, Some(4));
        assert_eq!(info.sheets[1].cols, Some(3));
        // 默认表前两行：表头 + 第一条数据。
        assert_eq!(info.header_rows.len(), 2);
        assert_eq!(
            info.header_rows[0],
            vec![
                json!("id"),
                json!("姓名"),
                json!("入职日期"),
                json!("活跃"),
                json!("评分"),
                json!("备注"),
                json!("登录时间"),
                json!("打卡时间"),
            ]
        );
        assert_eq!(
            info.header_rows[1],
            vec![
                json!(1),
                json!("张伟"),
                json!("2021-03-05"),
                json!(true),
                json!(88.5),
                Value::Null,
                json!("2021-03-05 09:30:00"),
                json!("09:30:00"),
            ]
        );
    }

    #[test]
    fn inspect_keeps_hidden_sheet_out_of_the_sheet_list() {
        let info = inspect(&fixture_path()).expect("inspect");
        assert!(
            !info.sheets.iter().any(|sheet| sheet.name == "隐藏数据"),
            "隐藏表不应出现在 sheets[]：{:?}",
            info.sheets
        );
        assert_eq!(info.sheets.len(), 3);
    }

    fn read_all(path: &str, selector: Option<&str>, skip_rows: usize) -> Vec<Vec<Value>> {
        let mut opened = open_sheet(path, selector, skip_rows).expect("open_sheet");
        let mut rows = Vec::new();
        while let Some(row) = opened.source.next_row().expect("next_row") {
            rows.push(row);
        }
        rows
    }

    #[test]
    fn open_sheet_reads_employee_cells_with_native_types() {
        let path = fixture_path();
        let rows = read_all(&path, None, 0);
        assert_eq!(rows.len(), 5, "表头 + 4 行数据：{rows:?}");
        assert_eq!(
            rows[0],
            vec![
                json!("id"),
                json!("姓名"),
                json!("入职日期"),
                json!("活跃"),
                json!("评分"),
                json!("备注"),
                json!("登录时间"),
                json!("打卡时间"),
            ]
        );
        // 数字 / 中文 / 日期 / 布尔 / 小数 / NULL / 日期时间 / 纯时间。
        assert_eq!(
            rows[1],
            vec![
                json!(1),
                json!("张伟"),
                json!("2021-03-05"),
                json!(true),
                json!(88.5),
                Value::Null,
                json!("2021-03-05 09:30:00"),
                json!("09:30:00"),
            ]
        );
        assert_eq!(rows[2][1], json!("李娜"));
        assert_eq!(rows[2][3], json!(false));
        assert_eq!(rows[2][5], json!("优秀"));
        assert_eq!(rows[2][6], json!("2022-07-18 14:05:30"));
        assert_eq!(rows[2][7], json!("09:05:30"));
        assert_eq!(rows[3][5], Value::Null);
        assert_eq!(rows[4][4], json!(66), "整数值的浮点要收成 i64");
        assert_eq!(rows[4][2], json!("2023-11-30"));
        assert_eq!(rows[4][7], json!("10:15:00"));
    }

    #[test]
    fn open_sheet_switches_sheet_by_name_and_index() {
        let path = fixture_path();
        let by_name = read_all(&path, Some("订单"), 0);
        assert_eq!(
            by_name[0],
            vec![json!("订单号"), json!("客户"), json!("金额")]
        );
        assert_eq!(by_name[1], vec![json!(1001), json!("甲公司"), json!(299.5)]);
        assert_eq!(by_name[2], vec![json!(1002), json!("乙公司"), json!(1280)]);
        assert_eq!(by_name[3], vec![json!(1003), json!("丙公司"), json!(58.75)]);

        let by_index = read_all(&path, Some("1"), 0);
        assert_eq!(by_index, by_name);

        let config = read_all(&path, Some("配置"), 0);
        assert_eq!(
            config,
            vec![
                vec![json!("键"), json!("值")],
                vec![json!("version"), json!("1.0")],
                vec![json!("env"), json!("prod")],
            ]
        );
    }

    #[test]
    fn open_sheet_reports_sheet_list_and_dimension() {
        let opened = open_sheet(&fixture_path(), Some("订单"), 0).expect("open_sheet");
        assert_eq!(opened.sheet, "订单");
        assert_eq!(
            opened.sheets,
            vec![
                (0, "员工".to_string()),
                (1, "订单".to_string()),
                (2, "配置".to_string()),
            ]
        );
        assert_eq!(opened.total_rows, Some(4), "BrtWsDim 的行数含表头");
    }

    #[test]
    fn open_sheet_applies_skip_rows() {
        let path = fixture_path();
        let rows = read_all(&path, None, 1);
        assert_eq!(rows.len(), 4);
        assert_eq!(rows[0][1], json!("张伟"), "跳 1 行后首行是原数据第 1 行");
        let rows = read_all(&path, None, 2);
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0][1], json!("李娜"));
        // 跳过超过总行数时返回空。
        assert!(read_all(&path, None, 99).is_empty());
    }

    #[test]
    fn open_sheet_rejects_unknown_sheet() {
        let error = open_sheet(&fixture_path(), Some("不存在"), 0)
            .map(|_| ())
            .unwrap_err();
        let message = error.to_string();
        assert!(message.contains("找不到工作表"), "{message}");
        assert!(message.contains("员工"), "{message}");
        // 序号越界也给可读错误。
        let error = open_sheet(&fixture_path(), Some("9"), 0)
            .map(|_| ())
            .unwrap_err();
        assert!(error.to_string().contains("超出范围"), "{error}");
    }

    #[test]
    fn open_sheet_rejects_non_xlsb_file() {
        let error = inspect("no-such-file.xlsb").unwrap_err();
        assert!(error.to_string().contains("无法打开文件"), "{error}");
        // 一个不是 ZIP 的文件。
        let path = temp_path("not-a-zip.xlsb");
        std::fs::write(&path, b"not a zip at all").unwrap();
        let error = inspect(path.to_str().unwrap()).unwrap_err();
        assert!(error.to_string().contains("不是有效的 ZIP 工作簿"), "{error}");
    }

    /// 独立实现交叉验证：用 calamine 读同一个 fixture，确认写入器产出的文件符合规范。
    ///
    /// 这一步专门用来兜住「单元格头 8 字节 / Bool 9 字节」这类布局错误：calamine 是
    /// 独立的 xlsb 实现，两边对同一文件给出同样的值，才说明布局没写歪。
    #[test]
    fn fixture_reads_with_calamine() {
        use calamine::{Data, Reader, Xlsb};

        let path = fixture_path();
        let mut workbook: Xlsb<_> = calamine::open_workbook(&path).expect("calamine open");
        let range = workbook.worksheet_range("员工").expect("calamine sheet");
        let cell = |row: u32, col: u32| range.get_value((row, col)).cloned();

        assert_eq!(cell(0, 0), Some(Data::String("id".to_string())));
        assert_eq!(cell(1, 0), Some(Data::Int(1)));
        assert_eq!(cell(1, 1), Some(Data::String("张伟".to_string())));
        assert_eq!(cell(1, 3), Some(Data::Bool(true)));
        assert_eq!(cell(1, 4), Some(Data::Float(88.5)));
        assert_eq!(cell(2, 3), Some(Data::Bool(false)));
        assert_eq!(cell(2, 4), Some(Data::Int(92)));
        assert_eq!(cell(2, 5), Some(Data::String("优秀".to_string())));
        assert_eq!(cell(3, 5), Some(Data::Empty));

        // 日期单元格：calamine 看到 DateTime，序列号再走我们的 excel_serial_value
        // 必须得到与流式读取一致的字符串。
        let mut dates = Vec::new();
        for (row, col) in [(1u32, 2u32), (2, 2), (3, 2), (4, 2)] {
            match cell(row, col) {
                Some(Data::DateTime(value)) => {
                    dates.push(excel_serial_value(value.as_f64(), false))
                }
                other => panic!("第 {row} 行日期列应为 DateTime，实际 {other:?}"),
            }
        }
        assert_eq!(
            dates,
            vec![
                json!("2021-03-05"),
                json!("2022-07-18"),
                json!("2023-01-02"),
                json!("2023-11-30"),
            ]
        );
        // 日期时间 / 纯时间列。
        match cell(1, 6) {
            Some(Data::DateTime(value)) => assert_eq!(
                excel_serial_value(value.as_f64(), false),
                json!("2021-03-05 09:30:00")
            ),
            other => panic!("登录时间应为 DateTime，实际 {other:?}"),
        }
        match cell(1, 7) {
            Some(Data::DateTime(value)) => {
                assert_eq!(excel_serial_value(value.as_f64(), false), json!("09:30:00"))
            }
            other => panic!("打卡时间应为 DateTime，实际 {other:?}"),
        }
    }

    // ============================================================ 50,000 行流式

    fn big_spec(rows: usize) -> WorkbookSpec {
        let mut sheet_rows = Vec::with_capacity(rows + 1);
        sheet_rows.push(vec![
            text(0, "id"),
            text(1, "名称"),
            text(2, "数值"),
        ]);
        for index in 1..=rows {
            sheet_rows.push(vec![
                int(0, index as i64),
                text(1, &format!("name-{index}")),
                real(2, index as f64 * 1.25 + 0.25),
            ]);
        }
        WorkbookSpec {
            sheets: vec![SheetSpec {
                name: "大表".to_string(),
                hidden: false,
                rows: sheet_rows,
            }],
            shared: Vec::new(),
        }
    }

    #[test]
    fn streams_fifty_thousand_rows_without_buffering_the_sheet() {
        const ROWS: usize = 50_000;
        let path = write_temp_workbook(&big_spec(ROWS), "big.xlsb");
        let path = path.to_str().expect("utf-8 path").to_string();

        let info = inspect(&path).expect("inspect");
        assert_eq!(info.sheets[0].rows, Some(ROWS as u64 + 1));
        assert_eq!(info.sheets[0].cols, Some(3));

        let mut opened = open_sheet(&path, None, 0).expect("open_sheet");
        let mut count = 0usize;
        let mut first = None;
        let mut last = None;
        let mut progress = None;
        while let Some(row) = opened.source.next_row().expect("next_row") {
            assert_eq!(row.len(), 3, "每行固定 3 列（宽度由前 128 行确定）");
            if count == 0 {
                first = Some(row.clone());
            }
            last = Some(row);
            count += 1;
            if count == 300 {
                progress = opened.source.bytes_progress();
            }
        }
        assert_eq!(count, ROWS + 1, "表头 + {ROWS} 行");
        assert_eq!(
            first.expect("first row"),
            vec![json!("id"), json!("名称"), json!("数值")]
        );
        assert_eq!(
            last.expect("last row"),
            vec![json!(ROWS), json!(format!("name-{ROWS}")), json!(62_500.25)]
        );
        // 读到 300 行时进度必须远小于总量：证明是「边解压边解析」，不是先整表载入。
        let (read, total) = progress.expect("bytes_progress");
        assert!(total > 100_000, "大表 entry 应该远大于 100 KB：{total}");
        assert!(
            read < total / 2,
            "读到 300 行时只应消耗少量字节：{read}/{total}"
        );
    }

    #[test]
    fn dropping_the_source_early_stops_the_producer_thread() {
        const ROWS: usize = 50_000;
        let path = write_temp_workbook(&big_spec(ROWS), "early-drop.xlsb");
        let path = path.to_str().expect("utf-8 path").to_string();
        let mut opened = open_sheet(&path, None, 0).expect("open_sheet");
        let mut rows = 0usize;
        while rows < 200 {
            match opened.source.next_row().expect("next_row") {
                Some(_) => rows += 1,
                None => break,
            }
        }
        let (read, total) = opened.source.bytes_progress().expect("progress");
        assert!(read < total, "提前退出时不应读完整表：{read}/{total}");
        // drop 会 join 生产线程；线程若卡在 send 上（消费端已 drop）这里会挂住。
        drop(opened);
    }

    // ============================================================ 自定义格式端到端

    #[test]
    fn custom_time_delta_format_produces_duration_string() {
        // ifmt 165 = "[h]:mm:ss"（写进 styles.bin 的 BrtFmt），1.5 天 → 36:00:00。
        let mut spec = big_spec(1);
        spec.sheets[0].rows[1][2] = Cell::Real {
            col: 2,
            style: 4,
            value: 1.5,
        };
        // 在样式表里追加一条 TimeDelta XF（下标 4）。
        let path = write_temp_workbook(&spec, "duration.xlsb");
        let rows = read_all(path.to_str().unwrap(), None, 0);
        assert_eq!(rows[1][2], json!("36:00:00"), "{rows:?}");
    }

    #[test]
    fn worksheet_without_dimension_still_streams() {
        // 没有 BrtWsDim 的文件（某些导出器会省略）：inspect 的 rows/cols 为 None，
        // 但行仍然逐条读得出来。
        let mut sheet = Vec::new();
        let mut writer = BrtWriter::new();
        writer.empty(0x0081);
        writer.empty(brt::BEGIN_SHEET_DATA);
        let mut header = Vec::new();
        header.extend_from_slice(&0u32.to_le_bytes());
        header.extend_from_slice(&0u32.to_le_bytes());
        header.extend_from_slice(&300u16.to_le_bytes());
        header.push(0);
        header.push(0);
        header.extend_from_slice(&0u16.to_le_bytes());
        writer.record(brt::ROW_HDR, &header);
        let mut payload = cell_header(0, 0);
        payload.extend_from_slice(&7.0f64.to_le_bytes());
        writer.record(brt::CELL_REAL, &payload);
        writer.empty(brt::END_SHEET_DATA);
        writer.empty(0x0082);
        sheet.extend_from_slice(&writer.into_inner());

        let spec = WorkbookSpec {
            sheets: vec![SheetSpec {
                name: "无维度".to_string(),
                hidden: false,
                rows: Vec::new(),
            }],
            shared: Vec::new(),
        };
        // 复用 workbook_bytes 的 ZIP 结构，但替换 sheet1.bin 的内容。
        let path = temp_path("no-dim.xlsb");
        let mut cursor = Cursor::new(Vec::new());
        {
            let mut zip = zip::ZipWriter::new(&mut cursor);
            let options = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            zip_entry(&mut zip, "[Content_Types].xml", CONTENT_TYPES.as_bytes(), options);
            zip_entry(&mut zip, "_rels/.rels", ROOT_RELS.as_bytes(), options);
            let rels = workbook_rels(1);
            zip_entry(&mut zip, "xl/_rels/workbook.bin.rels", rels.as_bytes(), options);
            zip_entry(
                &mut zip,
                "xl/workbook.bin",
                &write_workbook_bin(&spec.sheets, false),
                options,
            );
            zip_entry(&mut zip, "xl/styles.bin", &write_styles_bin(), options);
            zip_entry(&mut zip, "xl/worksheets/sheet1.bin", &sheet, options);
            zip.finish().expect("finish zip");
        }
        std::fs::write(&path, cursor.into_inner()).expect("write workbook");

        let path = path.to_str().expect("utf-8 path").to_string();
        let info = inspect(&path).expect("inspect");
        assert_eq!(info.sheets[0].rows, None);
        assert_eq!(info.sheets[0].cols, None);
        let rows = read_all(&path, None, 0);
        assert_eq!(rows, vec![vec![json!(7)]]);
        let opened = open_sheet(&path, None, 0).expect("open_sheet");
        assert_eq!(opened.total_rows, None);
    }

    #[test]
    fn workbooks_without_shared_strings_or_styles_still_read() {
        // sharedStrings.bin / styles.bin 缺失（全内联字符串、无日期格式）也要能读。
        let spec = WorkbookSpec {
            sheets: vec![SheetSpec {
                name: "最小".to_string(),
                hidden: false,
                rows: vec![vec![text(0, "a"), int(1, 2)]],
            }],
            shared: Vec::new(),
        };
        let path = temp_path("minimal.xlsb");
        let mut cursor = Cursor::new(Vec::new());
        {
            let mut zip = zip::ZipWriter::new(&mut cursor);
            let options = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            zip_entry(&mut zip, "[Content_Types].xml", CONTENT_TYPES.as_bytes(), options);
            zip_entry(&mut zip, "_rels/.rels", ROOT_RELS.as_bytes(), options);
            let rels = workbook_rels(1);
            zip_entry(&mut zip, "xl/_rels/workbook.bin.rels", rels.as_bytes(), options);
            zip_entry(
                &mut zip,
                "xl/workbook.bin",
                &write_workbook_bin(&spec.sheets, false),
                options,
            );
            zip_entry(
                &mut zip,
                "xl/worksheets/sheet1.bin",
                &write_sheet_bin(&spec.sheets[0].rows),
                options,
            );
            zip.finish().expect("finish zip");
        }
        std::fs::write(&path, cursor.into_inner()).expect("write workbook");
        let rows = read_all(path.to_str().unwrap(), None, 0);
        assert_eq!(rows, vec![vec![json!("a"), json!(2)]]);
    }

    #[test]
    fn date_1904_workbook_uses_the_1904_epoch() {
        // BrtWbProp bit0 = f1904：同一个序列号在 1904 系统下要往后挪 1462 天。
        let spec = WorkbookSpec {
            sheets: vec![SheetSpec {
                name: "1904".to_string(),
                hidden: false,
                rows: vec![vec![real_styled(0, 1, 100.0)]],
            }],
            shared: Vec::new(),
        };
        let path = temp_path("1904.xlsb");
        let mut cursor = Cursor::new(Vec::new());
        {
            let mut zip = zip::ZipWriter::new(&mut cursor);
            let options = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            zip_entry(&mut zip, "[Content_Types].xml", CONTENT_TYPES.as_bytes(), options);
            zip_entry(&mut zip, "_rels/.rels", ROOT_RELS.as_bytes(), options);
            let rels = workbook_rels(1);
            zip_entry(&mut zip, "xl/_rels/workbook.bin.rels", rels.as_bytes(), options);
            zip_entry(
                &mut zip,
                "xl/workbook.bin",
                &write_workbook_bin(&spec.sheets, true),
                options,
            );
            zip_entry(&mut zip, "xl/styles.bin", &write_styles_bin(), options);
            zip_entry(
                &mut zip,
                "xl/worksheets/sheet1.bin",
                &write_sheet_bin(&spec.sheets[0].rows),
                options,
            );
            zip.finish().expect("finish zip");
        }
        std::fs::write(&path, cursor.into_inner()).expect("write workbook");
        let rows = read_all(path.to_str().unwrap(), None, 0);
        // 1904 系统里序列号 0 = 1904-01-01，第 100 天 = 1904-04-10。
        assert_eq!(rows, vec![vec![json!("1904-04-10")]]);
    }

    #[test]
    fn compat_wrappers_adapt_into_excel_stream_types() {
        let info = inspect_compat(&fixture_path()).expect("inspect_compat");
        assert!(info.streaming);
        assert_eq!(info.sheet, "员工");
        assert_eq!(info.sheets.len(), 3);
        assert_eq!(info.header_rows.len(), 2);
        assert!(info.warnings.is_empty());

        let mut opened = open_sheet_compat(&fixture_path(), Some("配置"), 0).expect("compat");
        assert!(opened.streaming);
        assert_eq!(opened.sheet, "配置");
        assert_eq!(opened.sheets.len(), 3);
        assert_eq!(opened.sheets[0]["name"], json!("员工"));
        let mut rows = Vec::new();
        while let Some(row) = opened.source.next_row().expect("row") {
            rows.push(row);
        }
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[2], vec![json!("env"), json!("prod")]);
        // 适配层的 bytes_progress 也要透传（否则导入进度条会退化成不确定态）：
        // 读完整个 sheet 后进度应到 100%。
        let (read, total) = opened
            .source
            .bytes_progress()
            .expect("适配层要透传 bytes_progress");
        assert_eq!(read, total, "读完后进度应到 100%");
    }

    /// 与 excel_multi.xlsx 对齐：同一个逻辑工作簿的 xlsx / xlsb 两条流式路径必须
    /// 逐行逐值给出完全相同的 JSON（导入管线对格式无感知的前提）。
    #[test]
    fn xlsb_fixture_matches_xlsx_fixture_row_by_row() {
        use crate::excel_import::ExcelKind;

        let xlsx = format!(
            "{}/tests/fixtures/excel_multi.xlsx",
            env!("CARGO_MANIFEST_DIR")
        );
        let xlsb = fixture_path();
        // xlsx 侧直接走既有的 excel_stream 流式实现（与导入管线用的同一条路径）。
        let read_xlsx = |selector: Option<&str>, skip: usize| -> Vec<Vec<Value>> {
            let mut opened =
                crate::excel_stream::open_sheet(&xlsx, ExcelKind::Xlsx, selector, skip)
                    .expect("open xlsx");
            let mut rows = Vec::new();
            while let Some(row) = opened.source.next_row().expect("xlsx row") {
                rows.push(row);
            }
            rows
        };
        for (selector, expected_rows) in [(None, 5usize), (Some("订单"), 4), (Some("配置"), 3)] {
            let xlsx_rows = read_xlsx(selector, 0);
            let xlsb_rows = read_all(&xlsb, selector, 0);
            assert_eq!(xlsx_rows.len(), expected_rows, "xlsx {selector:?}");
            assert_eq!(xlsb_rows.len(), expected_rows, "xlsb {selector:?}");
            assert_eq!(xlsx_rows, xlsb_rows, "表 {selector:?} 的 xlsx/xlsb 行不一致");
        }
        // skip_rows 语义也要一致。
        for skip in [1usize, 2, 5] {
            assert_eq!(
                read_xlsx(None, skip),
                read_all(&xlsb, None, skip),
                "skip_rows={skip} 时两条路径不一致"
            );
        }
    }
}

