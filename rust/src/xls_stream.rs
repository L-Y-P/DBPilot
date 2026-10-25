//! xls（BIFF8 / Excel 97-2003）Record 级流式读取（第 51 轮）。
//!
//! 目标：把遗留的 .xls 从「calamine 整表载入内存」改成真正的逐行流式读取，
//! 语义与 excel_stream 的 xlsx 路径**完全一致**（同一份 fixture 两条路径必须给出
//! 相同的行值）。
//!
//! 分层：
//!
//! 1. **OLE2 容器**：cfb 0.15 打开复合文档，只 open_stream("Workbook")
//!    （老文件叫 Book），拿到 Read + Seek 的流；绝不 read_to_end 整个流，
//!    所有解析都按记录顺序前进（SST 例外：共享字符串表本身就是随机访问结构，
//!    必须驻留内存，与 xlsx 路径一次加载 sharedStrings 的做法一致）。
//! 2. **BIFF record**：u16 type + u16 len + payload；SST 的 CONTINUE（0x003C）
//!    续接按 [MS-XLS] 处理：字符串跨记录时，续接段首字节重新给出 grbit（只有
//!    fHighByte 有意义），rgRun / ExtRst 则直接跨段跳过。
//! 3. **工作表行**：按记录里的 row/col 组装稀疏行 → 尾部 NULL 裁掉、中间空洞补
//!    NULL、空字符串保留、全空行跳过、skip_rows 按有效行跳过、先缓冲
//!    ≤128 行定列宽（等价于整表「末尾全空列裁掉」）。
//! 4. **流式**：解析在独立线程里跑，sync_channel(256) 送行；消费端 drop 后
//!    send 失败，线程立刻退出；bytes_progress 用 Workbook 流的当前位置/总长。
//!
//! 对外接口（Lead 在 excel_stream.rs 里适配成 OpenedSheet / RowSource）：
//!
//! ```text
//! pub fn inspect(path: &str) -> AppResult<InspectResult>;
//! pub fn open_sheet(path: &str, selector: Option<&str>, skip_rows: usize)
//!     -> AppResult<OpenedSheetLike>;
//! ```
//!
//! 已知边界：
//! * 只支持 BIFF8（Excel 97-2003）；BIFF5/BIFF7（Excel 95 及更早）直接报错。
//! * 加密工作簿（FilePass）不支持，报错。
//! * 共享公式 / 数组公式只取 FORMULA 记录里的**缓存结果**，不重算。
//! * 图表工作表、宏表（dt != 0x00）跳过，不计入可见表。
//! * 低字节（compressed）字符串按 BIFF8 规范解码为 Latin-1（即 UTF-16 的低字节）。

// 接线前（Lead 还没在 excel_stream 里分派 xls）本模块的 pub(crate) 项暂无调用方，
// 先压掉 dead_code 告警；接线完成后可删掉这一行。

use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender};
use std::sync::Arc;
use std::thread::JoinHandle;

use cfb::{CompoundFile, Stream};
use serde_json::Value;

use crate::error::{AppError, AppResult};
use crate::excel_import::normalize_number;
use crate::excel_stream::{blank_value, excel_duration_value, excel_serial_value};

/// 工作线程与消费端之间的有界队列长度（与 excel_stream 保持一致）。
const CHANNEL_BOUND: usize = 256;
/// inspect 只需要前两行判断表头。
const INSPECT_HEADER_ROWS: usize = 2;
/// 流式读取时先缓冲这么多行来确定列宽。
const WIDTH_PROBE_ROWS: usize = 128;

// ---------------------------------------------------------------- BIFF 记录号

const BOF: u16 = 0x0809;
const EOF: u16 = 0x000A;
const CONTINUE: u16 = 0x003C;
const FILEPASS: u16 = 0x002F;
const DATEMODE: u16 = 0x0022;
const BOUNDSHEET: u16 = 0x0085;
const SST: u16 = 0x00FC;
const LABELSST: u16 = 0x00FD;
const LABEL: u16 = 0x0204;
const NUMBER: u16 = 0x0203;
const RK: u16 = 0x027E;
const MULRK: u16 = 0x00BD;
const BOOLERR: u16 = 0x0205;
const FORMULA: u16 = 0x0006;
const STRING: u16 = 0x0207;
const BLANK: u16 = 0x0201;
const MULBLANK: u16 = 0x00BE;
const XF: u16 = 0x00E0;
const FORMAT: u16 = 0x041E;
const DIMENSIONS: u16 = 0x0200;

// ---------------------------------------------------------------- 公共类型

/// 一张可见工作表的轻量元信息（inspect.sheets[] 的数据来源）。
#[derive(Clone, Debug)]
pub struct SheetMetaBrief {
    pub index: usize,
    pub name: String,
    pub rows: Option<u64>,
    pub cols: Option<u64>,
}

/// inspect 的结果：只有元信息 + 默认表前两行，不含整表数据。
pub struct InspectResult {
    pub sheets: Vec<SheetMetaBrief>,
    /// 默认选中的表（第一张可见表）。
    pub sheet: String,
    /// 默认表的前两行（表头启发式与样例用）。
    pub header_rows: Vec<Vec<Value>>,
    pub hidden_sheets: usize,
}

/// 逐行拉取一张工作表（与 excel_stream::RowSource 同形）。
pub trait RowSource: Send {
    fn next_row(&mut self) -> AppResult<Option<Vec<Value>>>;
    /// 已读字节 / 总字节（Workbook 流的位置），用于总行数未知时的进度退化。
    fn bytes_progress(&self) -> Option<(u64, u64)> {
        None
    }
}

/// 打开一张工作表后的结果（Lead 适配成 excel_stream::OpenedSheet）。
pub struct OpenedSheetLike {
    pub sheet: String,
    /// (0-based 可见表序号, 表名)，与 xlsx 路径的 sheets JSON 同源。
    pub sheets: Vec<(usize, String)>,
    pub total_rows: Option<u64>,
    pub source: Box<dyn RowSource>,
}

// ---------------------------------------------------------------- 数字格式

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum CellFormat {
    Other,
    DateTime,
    TimeDelta,
}

/// 内建数字格式号 → 日期/时长（与 excel_stream 的 xlsx 路径同一张表）。
///
/// 27–36、50–58 是 ECMA-376 预留给区域设置的日期/时间内建格式（CJK 版 Excel、
/// LibreOffice 常见）；漏掉会让日期按序列号读成整数。37–44 是会计/数值格式，
/// 不要并进来。
fn builtin_format(id: u16) -> CellFormat {
    match id {
        14..=22 | 27..=36 | 45 | 47 | 50..=58 => CellFormat::DateTime,
        46 => CellFormat::TimeDelta,
        _ => CellFormat::Other,
    }
}

/// 自定义格式串是否日期/时长。
///
/// 移植自 calamine 的 detect_custom_number_format（MIT，见 excel_stream.rs 同名
/// 函数的注释）：引号/转义里的字符不算格式；方括号里的 [h]/[m]/[s] 是时长；
/// 出现 d/m/h/y/s 是日期。两条路径必须用同一套判定，否则同一个 .xls 与 .xlsx
/// 会给出不同的日期字符串。
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

// ---------------------------------------------------------------- 字节工具

fn u16_at(bytes: &[u8], at: usize) -> u16 {
    if at + 2 > bytes.len() {
        return 0;
    }
    u16::from_le_bytes([bytes[at], bytes[at + 1]])
}

fn u32_at(bytes: &[u8], at: usize) -> u32 {
    if at + 4 > bytes.len() {
        return 0;
    }
    u32::from_le_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
}

fn f64_at(bytes: &[u8], at: usize) -> f64 {
    if at + 8 > bytes.len() {
        return 0.0;
    }
    let mut raw = [0u8; 8];
    raw.copy_from_slice(&bytes[at..at + 8]);
    f64::from_le_bytes(raw)
}

/// BIFF8 字符数据：fHighByte=1 是 UTF-16LE 单元，0 是 UTF-16 的低字节（Latin-1）。
fn decode_chars(bytes: &[u8], cch: usize, high_byte: bool) -> String {
    if high_byte {
        let take = cch.min(bytes.len() / 2);
        let units: Vec<u16> = bytes[..take * 2]
            .chunks_exact(2)
            .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
            .collect();
        String::from_utf16_lossy(&units)
    } else {
        let take = cch.min(bytes.len());
        bytes[..take].iter().map(|byte| *byte as char).collect()
    }
}

/// XLUnicodeString（u16 cch + u8 grbit + 字符数据）。
fn decode_xl_unicode_string(bytes: &[u8]) -> String {
    if bytes.len() < 3 {
        return String::new();
    }
    let cch = u16_at(bytes, 0) as usize;
    decode_chars(&bytes[3..], cch, bytes[2] & 0x01 != 0)
}

/// ShortXLUnicodeString（u8 cch + u8 grbit + 字符数据），BOUNDSHEET 表名用。
fn decode_short_string(bytes: &[u8], cch: usize, high_byte: bool) -> String {
    decode_chars(bytes, cch, high_byte)
}

// ---------------------------------------------------------------- OLE2 + record

/// 一个已打开的 xls 复合文档：Workbook 流 + 必须存活的 CompoundFile。
struct OpenWorkbook {
    reader: RecordReader,
    /// CompoundFile 必须比 Stream 活得久（Stream 只持有 Weak 引用）。
    /// 字段顺序即 drop 顺序：reader（含 Stream）先 drop，再 drop CompoundFile。
    _cfb: CompoundFile<File>,
}

/// BIFF 记录读取器：u16 type + u16 len + payload，记录顺序前进。
struct RecordReader {
    stream: Stream<File>,
    /// 下一条记录的起始偏移（= 已消费字节数）。
    pos: u64,
    /// Workbook 流总长度。
    len: u64,
    /// 被 SST 解析器「看过头」的记录（主循环继续处理它）。
    pushback: Option<(u16, Vec<u8>)>,
    /// 最近一次 next_into 读到的记录类型（供 unread 使用）。
    last: Option<u16>,
}

impl RecordReader {
    fn position(&self) -> u64 {
        self.pos
    }

    fn len(&self) -> u64 {
        self.len
    }

    fn seek_to(&mut self, pos: u64) -> AppResult<()> {
        if pos > self.len {
            return Err(AppError::bad(
                "xls 工作表偏移超出 Workbook 流范围（文件损坏）",
            ));
        }
        self.stream
            .seek(SeekFrom::Start(pos))
            .map_err(|error| AppError::bad(format!("定位 xls 记录失败: {error}")))?;
        self.pos = pos;
        self.pushback = None;
        self.last = None;
        Ok(())
    }

    fn read_exact(&mut self, buf: &mut [u8]) -> AppResult<()> {
        self.stream
            .read_exact(buf)
            .map_err(|error| AppError::bad(format!("读取 xls 数据流失败: {error}")))
    }

    /// 读下一条记录到 buf，返回记录类型；流结束返回 None。
    fn next_into(&mut self, buf: &mut Vec<u8>) -> AppResult<Option<u16>> {
        if let Some((typ, payload)) = self.pushback.take() {
            *buf = payload;
            self.last = Some(typ);
            return Ok(Some(typ));
        }
        if self.pos + 4 > self.len {
            self.last = None;
            return Ok(None);
        }
        let mut header = [0u8; 4];
        self.read_exact(&mut header)?;
        let typ = u16::from_le_bytes([header[0], header[1]]);
        let size = u16::from_le_bytes([header[2], header[3]]) as u64;
        if self.pos + 4 + size > self.len {
            return Err(AppError::bad(format!(
                "xls 记录越界（类型 0x{typ:04X}，长度 {size}）：文件被截断或损坏"
            )));
        }
        buf.clear();
        buf.resize(size as usize, 0);
        self.read_exact(buf)?;
        self.pos += 4 + size;
        self.last = Some(typ);
        Ok(Some(typ))
    }

    /// 把刚读到的记录放回（SST 解析器拉到非 CONTINUE 记录时用）。
    fn unread(&mut self, buf: &mut Vec<u8>) {
        if let Some(typ) = self.last.take() {
            self.pushback = Some((typ, std::mem::take(buf)));
        }
    }
}

/// OLE2 容器里的流（目录项）名字，用来判断这个 CFB 到底装的是什么。
fn cfb_stream_names(cfb: &CompoundFile<File>) -> Vec<String> {
    cfb.walk()
        .filter(|entry| entry.is_stream())
        .map(|entry| entry.name().to_string())
        .collect()
}

fn has_stream(streams: &[String], wanted: &str) -> bool {
    streams
        .iter()
        .any(|name| name.eq_ignore_ascii_case(wanted))
}

fn open_workbook(path: &str) -> AppResult<OpenWorkbook> {
    let mut cfb = cfb::open(path)
        .map_err(|error| AppError::bad(format!("不是有效的 .xls（OLE2 复合文档）: {error}")))?;
    // Office 的「密码保护」会把整个 OOXML 包（xlsx/xlsb）塞进 CFB：目录里是
    // EncryptionInfo / EncryptedPackage，而不是 Workbook 流。以前这种文件会被
    // 当成 xls 报「xls 里没有 Workbook/Book 数据流: No such stream」，
    // 用户看到 xls 字样只会以为自己选错了文件——这里先识别容器内容，给中文指引。
    let streams = cfb_stream_names(&cfb);
    if has_stream(&streams, "EncryptionInfo") || has_stream(&streams, "EncryptedPackage") {
        return Err(AppError::bad(
            "文件已加密或是被 OLE2 容器包装的 Office 文件（请输入密码后另存为未加密的 .xlsx/.xlsb 再导入）",
        ));
    }
    if has_stream(&streams, "WordDocument") {
        return Err(AppError::bad(
            "这不是 Excel 工作簿：文件是 Word 文档（.doc）；请在 Excel 中另存为 .xlsx 后再导入",
        ));
    }
    let mut stream = match cfb.open_stream("Workbook") {
        Ok(stream) => stream,
        Err(workbook_error) => match cfb.open_stream("Book") {
            Ok(stream) => stream,
            Err(book_error) => {
                // 加密的 .xls 也是「CFB 里没有可读的 Workbook/Book 流」；
                // 主文案给中文指引，原始 cfb 细节保留在末尾便于排查。
                let detail = if streams.is_empty() {
                    format!("Workbook: {workbook_error}; Book: {book_error}")
                } else {
                    format!(
                        "Workbook: {workbook_error}; Book: {book_error}；目录项：{}",
                        streams.join("、")
                    )
                };
                return Err(AppError::bad(format!(
                    "xls 文件里没有 Workbook/Book 数据流（文件可能已加密，或是被其它 Office 文档包装）；请输入密码后另存为未加密的 .xlsx/.xls 再导入。原始细节：{detail}"
                )));
            }
        },
    };
    let len = stream.len();
    stream
        .seek(SeekFrom::Start(0))
        .map_err(|error| AppError::bad(format!("读取 xls 数据流失败: {error}")))?;
    Ok(OpenWorkbook {
        reader: RecordReader {
            stream,
            pos: 0,
            len,
            pushback: None,
            last: None,
        },
        _cfb: cfb,
    })
}

// ---------------------------------------------------------------- SST + CONTINUE

/// SST 记录的段游标：当前段（SST 或某个 CONTINUE 的 payload）+ 段内偏移。
///
/// 跨段规则（[MS-XLS] 2.5.293 XLUnicodeRichExtendedString）：
/// * 字符数据跨 CONTINUE 时，续接段首字节重新给出 grbit（只需 fHighByte）；
/// * rgRun / ExtRst 是纯字节块，跨段时不需要任何前缀；
/// * 新字符串可以正好从续接段开头开始，此时 cch/grbit 照常读。
struct SegCursor<'a> {
    reader: &'a mut RecordReader,
    seg: Vec<u8>,
    at: usize,
}

impl<'a> SegCursor<'a> {
    fn new(reader: &'a mut RecordReader, first: Vec<u8>) -> Self {
        SegCursor {
            reader,
            seg: first,
            at: 0,
        }
    }

    fn remaining(&self) -> usize {
        self.seg.len().saturating_sub(self.at)
    }

    /// 当前段耗尽时拉下一条 CONTINUE；返回是否还有数据。
    fn advance(&mut self) -> AppResult<bool> {
        let mut scratch = std::mem::take(&mut self.seg);
        match self.reader.next_into(&mut scratch)? {
            Some(CONTINUE) => {
                self.seg = scratch;
                self.at = 0;
                Ok(true)
            }
            Some(_) => {
                self.reader.unread(&mut scratch);
                self.seg = scratch;
                Ok(false)
            }
            None => {
                self.seg = scratch;
                Ok(false)
            }
        }
    }

    /// 确保当前段有数据（允许新字符串从续接段开头开始）。
    fn ensure(&mut self) -> AppResult<()> {
        if self.remaining() > 0 {
            return Ok(());
        }
        if self.advance()? {
            Ok(())
        } else {
            Err(AppError::bad("SST 记录数据不完整（缺少 CONTINUE 续接）"))
        }
    }

    fn read_u8(&mut self) -> AppResult<u8> {
        self.ensure()?;
        let byte = self.seg[self.at];
        self.at += 1;
        Ok(byte)
    }

    fn read_u16(&mut self) -> AppResult<u16> {
        // 新字符串/新字段可以正好从 CONTINUE 段开头开始。
        if self.remaining() == 0 {
            self.ensure()?;
        }
        if self.remaining() < 2 {
            return Err(AppError::bad("SST 记录被截断（u16 跨记录）"));
        }
        let value = u16::from_le_bytes([self.seg[self.at], self.seg[self.at + 1]]);
        self.at += 2;
        Ok(value)
    }

    fn read_u32(&mut self) -> AppResult<u32> {
        if self.remaining() == 0 {
            self.ensure()?;
        }
        if self.remaining() < 4 {
            return Err(AppError::bad("SST 记录被截断（u32 跨记录）"));
        }
        let value = u32_at(&self.seg, self.at);
        self.at += 4;
        Ok(value)
    }

    /// 读 cch 个字符，跨 CONTINUE 时按续接段首字节重读 grbit。
    fn read_chars(&mut self, cch: usize, mut high_byte: bool, out: &mut String) -> AppResult<()> {
        let mut left = cch;
        while left > 0 {
            if self.remaining() == 0 {
                if !self.advance()? {
                    return Err(AppError::bad("SST 字符串跨 CONTINUE 时数据不完整"));
                }
                // 续接段首字节重新给出 grbit：只有 fHighByte 影响解码。
                let flags = self.seg[self.at];
                self.at += 1;
                high_byte = flags & 0x01 != 0;
            }
            let width = if high_byte { 2 } else { 1 };
            let available = self.remaining() / width;
            if available == 0 {
                return Err(AppError::bad("SST 字符串的 UTF-16 单元被记录边界截断"));
            }
            let take = available.min(left);
            let bytes = &self.seg[self.at..self.at + take * width];
            if high_byte {
                let units: Vec<u16> = bytes
                    .chunks_exact(2)
                    .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
                    .collect();
                out.push_str(&String::from_utf16_lossy(&units));
            } else {
                for byte in bytes {
                    out.push(*byte as char);
                }
            }
            self.at += take * width;
            left -= take;
        }
        Ok(())
    }

    /// 跳过 n 个字节（rgRun / ExtRst），可以跨 CONTINUE（不读 grbit）。
    fn skip(&mut self, mut count: usize) -> AppResult<()> {
        while count > 0 {
            if self.remaining() == 0 && !self.advance()? {
                return Err(AppError::bad("SST 记录数据不完整（跳过富文本/扩展块时）"));
            }
            let take = self.remaining().min(count);
            self.at += take;
            count -= take;
        }
        Ok(())
    }
}

/// 解析 SST（0x00FC）及其后续 CONTINUE 记录，返回共享字符串表。
fn parse_sst(reader: &mut RecordReader, first: Vec<u8>) -> AppResult<Vec<String>> {
    let mut cursor = SegCursor::new(reader, first);
    let _cst_total = cursor.read_u32()?;
    let cst_unique = cursor.read_u32()? as usize;
    // 防御损坏文件：cstUnique 不可能超过记录总字节数，先按一个合理上界预留。
    let mut strings = Vec::with_capacity(cst_unique.min(1 << 20));
    for _ in 0..cst_unique {
        let cch = cursor.read_u16()? as usize;
        let flags = cursor.read_u8()?;
        let high_byte = flags & 0x01 != 0;
        let rich = flags & 0x08 != 0;
        let extended = flags & 0x04 != 0;
        let mut c_run = 0usize;
        let mut cb_ext_rst = 0usize;
        if rich {
            c_run = cursor.read_u16()? as usize;
        }
        if extended {
            let raw = cursor.read_u32()? as i32;
            cb_ext_rst = raw.max(0) as usize;
        }
        let mut text = String::with_capacity(cch);
        cursor.read_chars(cch, high_byte, &mut text)?;
        cursor.skip(c_run.saturating_mul(4))?;
        cursor.skip(cb_ext_rst)?;
        strings.push(text);
    }
    Ok(strings)
}

// ---------------------------------------------------------------- 工作簿元信息

struct SheetInfo {
    index: usize,
    name: String,
    /// 工作表子流在 Workbook 流里的绝对偏移（BOUNDSHEET 的 lbPlyPos）。
    offset: u64,
    rows: Option<u64>,
    cols: Option<u64>,
}

struct WorkbookInfo {
    sheets: Vec<SheetInfo>,
    hidden_sheets: usize,
    sst: Arc<Vec<String>>,
    /// 已按 XF 索引解析好的单元格格式（XF 顺序即 ixfe）。
    xf_formats: Arc<Vec<CellFormat>>,
    is_1904: bool,
}

/// BOUNDSHEET（0x0085）：工作表名 + 子流偏移 + 可见性 + 表类型。
fn parse_boundsheet(payload: &[u8], index: usize, hidden: &mut usize) -> Option<SheetInfo> {
    if payload.len() < 8 {
        return None;
    }
    let offset = u32_at(payload, 0) as u64;
    let state = payload[4] & 0x03;
    let kind = payload[5];
    let cch = payload[6] as usize;
    let high_byte = payload[7] & 0x01 != 0;
    // 只保留普通工作表：图表表（0x02）、宏表（0x01）、VBA 模块（0x06）都跳过。
    if kind != 0x00 {
        return None;
    }
    let name = decode_short_string(&payload[8..], cch, high_byte);
    if name.is_empty() {
        return None;
    }
    if state != 0x00 {
        *hidden += 1;
        return None;
    }
    Some(SheetInfo {
        index,
        name,
        offset,
        rows: None,
        cols: None,
    })
}

/// FORMAT（0x041E）：ifmt + 自定义格式串。
fn parse_format_record(payload: &[u8]) -> Option<(u16, String)> {
    if payload.len() < 5 {
        return None;
    }
    let ifmt = u16_at(payload, 0);
    let cch = u16_at(payload, 2) as usize;
    let high_byte = payload[4] & 0x01 != 0;
    Some((ifmt, decode_chars(&payload[5..], cch, high_byte)))
}

/// DIMENSIONS（0x0200）：BIFF8 是 14 字节（u32 行 / u16 列），旧版是 10 字节。
fn parse_dimensions(payload: &[u8]) -> (Option<u64>, Option<u64>) {
    if payload.len() >= 14 {
        let first_row = u32_at(payload, 0) as u64;
        let last_row = u32_at(payload, 4) as u64;
        let first_col = u16_at(payload, 8) as u64;
        let last_col = u16_at(payload, 10) as u64;
        (
            Some(last_row.saturating_sub(first_row)),
            Some(last_col.saturating_sub(first_col)),
        )
    } else if payload.len() >= 10 {
        let first_row = u16_at(payload, 0) as u64;
        let last_row = u16_at(payload, 2) as u64;
        let first_col = u16_at(payload, 4) as u64;
        let last_col = u16_at(payload, 6) as u64;
        (
            Some(last_row.saturating_sub(first_row)),
            Some(last_col.saturating_sub(first_col)),
        )
    } else {
        (None, None)
    }
}

/// 扫描 Workbook 全局子流（第一个 BOF..EOF）：BOUNDSHEET / SST / XF / FORMAT /
/// DATEMODE。只读记录头，不碰任何工作表行。
fn scan_globals(reader: &mut RecordReader) -> AppResult<WorkbookInfo> {
    let mut payload: Vec<u8> = Vec::new();
    let mut sheets: Vec<SheetInfo> = Vec::new();
    let mut hidden_sheets = 0usize;
    let mut sst: Vec<String> = Vec::new();
    let mut xf_ifmt: Vec<u16> = Vec::new();
    let mut custom_formats: HashMap<u16, String> = HashMap::new();
    let mut is_1904 = false;
    let mut seen_bof = false;
    loop {
        let Some(typ) = reader.next_into(&mut payload)? else {
            break;
        };
        match typ {
            BOF => {
                if payload.len() < 4 {
                    return Err(AppError::bad("xls 的 BOF 记录被截断"));
                }
                let version = u16_at(&payload, 0);
                let substream = u16_at(&payload, 2);
                // 0x0600 = BIFF8；个别生成器写 0，用子流类型兜底判断。
                let is_biff8 = version == 0x0600 || (version == 0 && substream != 0x1000);
                if !is_biff8 {
                    return Err(AppError::bad(format!(
                        "BIFF5/BIFF7（Excel 95 及更早，BOF 版本 0x{version:04X}）的 .xls 暂不支持流式读取；请另存为 .xlsx 后再导入"
                    )));
                }
                seen_bof = true;
            }
            EOF => break,
            FILEPASS => {
                if payload.len() >= 2 && u16_at(&payload, 0) != 0 {
                    return Err(AppError::bad("加密的 .xls 暂不支持导入（请先取消密码）"));
                }
            }
            DATEMODE => {
                if u16_at(&payload, 0) == 1 {
                    is_1904 = true;
                }
            }
            XF => {
                if payload.len() >= 4 {
                    xf_ifmt.push(u16_at(&payload, 2));
                }
            }
            FORMAT => {
                if let Some((ifmt, code)) = parse_format_record(&payload) {
                    custom_formats.insert(ifmt, code);
                }
            }
            BOUNDSHEET => {
                if let Some(sheet) = parse_boundsheet(&payload, sheets.len(), &mut hidden_sheets) {
                    sheets.push(sheet);
                }
            }
            SST => {
                let first = std::mem::take(&mut payload);
                sst = parse_sst(reader, first)?;
            }
            _ => {}
        }
    }
    if !seen_bof {
        return Err(AppError::bad("不是有效的 .xls 工作簿（缺少 BOF 记录）"));
    }
    // XF 索引 → 单元格格式：自定义格式串优先，否则按内建格式号判定。
    let xf_formats = xf_ifmt
        .into_iter()
        .map(|ifmt| match custom_formats.get(&ifmt) {
            Some(code) => detect_custom_format(code),
            None => builtin_format(ifmt),
        })
        .collect();
    Ok(WorkbookInfo {
        sheets,
        hidden_sheets,
        sst: Arc::new(sst),
        xf_formats: Arc::new(xf_formats),
        is_1904,
    })
}

/// 只读某张工作表子流头部的 DIMENSIONS（不解析任何单元格）。
fn scan_dimensions(reader: &mut RecordReader) -> AppResult<(Option<u64>, Option<u64>)> {
    let mut payload: Vec<u8> = Vec::new();
    loop {
        let Some(typ) = reader.next_into(&mut payload)? else {
            return Ok((None, None));
        };
        match typ {
            DIMENSIONS => return Ok(parse_dimensions(&payload)),
            EOF => return Ok((None, None)),
            // 有的生成器不写 DIMENSIONS，遇到第一格数据就放弃。
            LABELSST | LABEL | NUMBER | RK | MULRK | BOOLERR | FORMULA | BLANK | MULBLANK => {
                return Ok((None, None))
            }
            _ => {}
        }
    }
}

/// 打开文件 → 全局子流 → 每张可见表的 DIMENSIONS。
fn load_workbook(path: &str) -> AppResult<(WorkbookInfo, OpenWorkbook)> {
    let mut opened = open_workbook(path)?;
    let mut info = scan_globals(&mut opened.reader)?;
    for sheet in &mut info.sheets {
        opened.reader.seek_to(sheet.offset)?;
        let (rows, cols) = scan_dimensions(&mut opened.reader)?;
        sheet.rows = rows;
        sheet.cols = cols;
    }
    Ok((info, opened))
}

/// 按工作表名或 0-based 序号选表（与 excel_stream::select_named 同语义）。
fn select_sheet(sheets: &[SheetInfo], selector: Option<&str>) -> AppResult<usize> {
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

// ---------------------------------------------------------------- 单元格 → JSON

/// RK 记录里的 32 位编码 → f64（bit0 = /100，bit1 = 整数，其余 30 位是值）。
fn rk_value(raw: u32) -> f64 {
    let divide_by_100 = raw & 0x01 != 0;
    let is_integer = raw & 0x02 != 0;
    let mut value = if is_integer {
        ((raw as i32) >> 2) as f64
    } else {
        f64::from_bits(((raw as u64) & 0xFFFF_FFFC) << 32)
    };
    if divide_by_100 {
        value /= 100.0;
    }
    value
}

/// 数值单元格 → JSON：日期/时间格式走 excel_serial_value，时长走
/// excel_duration_value，其余按 normalize_number（整数值输出 i64）。
fn number_value(value: f64, xf: usize, xf_formats: &[CellFormat], is_1904: bool) -> Value {
    if !value.is_finite() {
        return Value::Null;
    }
    match xf_formats.get(xf).copied().unwrap_or(CellFormat::Other) {
        CellFormat::DateTime => excel_serial_value(value, is_1904),
        CellFormat::TimeDelta => excel_duration_value(value),
        CellFormat::Other => normalize_number(value),
    }
}

/// 往稀疏行里放值：按列号补齐中间的 NULL。
fn place(row: &mut Vec<Value>, column: usize, value: Value) {
    if row.len() <= column {
        row.resize(column + 1, Value::Null);
    }
    row[column] = value;
}

/// 单元格记录的行号（没有行号的记录返回 None）。
fn cell_row(typ: u16, payload: &[u8]) -> Option<u32> {
    match typ {
        LABELSST | LABEL | NUMBER | RK | MULRK | BOOLERR | FORMULA | BLANK | MULBLANK => {
            if payload.len() >= 4 {
                Some(u16_at(payload, 0) as u32)
            } else {
                None
            }
        }
        _ => None,
    }
}

/// FORMULA 的缓存结果是「字符串」时，返回该单元格的列号（值在随后的 STRING 记录里）。
fn formula_string_column(payload: &[u8]) -> Option<usize> {
    if payload.len() < 14 {
        return None;
    }
    let result = &payload[6..14];
    if result[6] == 0xFF && result[7] == 0xFF && result[0] == 0x00 {
        Some(u16_at(payload, 2) as usize)
    } else {
        None
    }
}

/// 把一条单元格记录的值写进行缓冲区。
fn apply_cell(
    typ: u16,
    payload: &[u8],
    row: &mut Vec<Value>,
    xf_formats: &[CellFormat],
    sst: &[String],
    is_1904: bool,
) {
    match typ {
        LABELSST => {
            if payload.len() < 10 {
                return;
            }
            let column = u16_at(payload, 2) as usize;
            let index = u32_at(payload, 6) as usize;
            // 空字符串是真实值（导出/导入往返依赖这一点），与 xlsx 路径一致。
            let value = match sst.get(index) {
                Some(text) => Value::String(text.clone()),
                None => Value::Null,
            };
            place(row, column, value);
        }
        LABEL => {
            if payload.len() < 9 {
                return;
            }
            let column = u16_at(payload, 2) as usize;
            let value = decode_xl_unicode_string(&payload[6..]);
            place(row, column, Value::String(value));
        }
        NUMBER => {
            if payload.len() < 14 {
                return;
            }
            let column = u16_at(payload, 2) as usize;
            let xf = u16_at(payload, 4) as usize;
            let value = number_value(f64_at(payload, 6), xf, xf_formats, is_1904);
            place(row, column, value);
        }
        RK => {
            if payload.len() < 10 {
                return;
            }
            let column = u16_at(payload, 2) as usize;
            let xf = u16_at(payload, 4) as usize;
            let value = number_value(rk_value(u32_at(payload, 6)), xf, xf_formats, is_1904);
            place(row, column, value);
        }
        MULRK => {
            // row u16 + colFirst u16 + (xf u16 + rk u32)* + colLast u16
            if payload.len() < 12 {
                return;
            }
            let column_first = u16_at(payload, 2) as usize;
            let body = &payload[4..payload.len() - 2];
            for (offset, chunk) in body.chunks_exact(6).enumerate() {
                let xf = u16_at(chunk, 0) as usize;
                let value = number_value(rk_value(u32_at(chunk, 2)), xf, xf_formats, is_1904);
                place(row, column_first + offset, value);
            }
        }
        BOOLERR => {
            if payload.len() < 8 {
                return;
            }
            let column = u16_at(payload, 2) as usize;
            let raw = payload[6];
            let is_error = payload[7] != 0;
            // 错误值 → Null（与 xlsx 的 t="e" 一致）。
            let value = if is_error {
                Value::Null
            } else {
                Value::Bool(raw != 0)
            };
            place(row, column, value);
        }
        FORMULA => {
            if payload.len() < 14 {
                return;
            }
            let column = u16_at(payload, 2) as usize;
            let xf = u16_at(payload, 4) as usize;
            let result = &payload[6..14];
            // 特殊值编码：byte0 = 类型，byte6..8 = 0xFFFF；普通数字按 f64 解释。
            let special = result[6] == 0xFF && result[7] == 0xFF && result[0] <= 0x03;
            let value = if special {
                match result[0] {
                    // 0x00 = 字符串，值在随后的 STRING 记录里（先占位 NULL）
                    0x00 => Value::Null,
                    // 0x01 = 布尔
                    0x01 => Value::Bool(result[2] != 0),
                    // 0x02 = 错误
                    0x02 => Value::Null,
                    // 0x03 = 空字符串
                    0x03 => Value::String(String::new()),
                    _ => Value::Null,
                }
            } else {
                number_value(f64_at(result, 0), xf, xf_formats, is_1904)
            };
            place(row, column, value);
        }
        BLANK => {
            if payload.len() >= 6 {
                place(row, u16_at(payload, 2) as usize, Value::Null);
            }
        }
        MULBLANK => {
            if payload.len() < 6 {
                return;
            }
            let column_first = u16_at(payload, 2) as usize;
            let body = &payload[4..payload.len() - 2];
            for (offset, _) in body.chunks_exact(2).enumerate() {
                place(row, column_first + offset, Value::Null);
            }
        }
        _ => {}
    }
}

// ---------------------------------------------------------------- 逐行解析

/// 一张工作表子流的行解析器：按记录顺序前进，凑满一行就返回（空行跳过）。
struct SheetParser {
    /// 拥有整个 Workbook 流：字段顺序保证 Stream 先于 CompoundFile drop。
    wb: OpenWorkbook,
    payload: Vec<u8>,
    xf_formats: Arc<Vec<CellFormat>>,
    sst: Arc<Vec<String>>,
    is_1904: bool,
    row: Vec<Value>,
    current_row: Option<u32>,
    /// FORMULA 的字符串结果：等紧随其后的 STRING 记录填进来。
    pending_string_column: Option<usize>,
    finished: bool,
}

impl SheetParser {
    fn new(
        wb: OpenWorkbook,
        xf_formats: Arc<Vec<CellFormat>>,
        sst: Arc<Vec<String>>,
        is_1904: bool,
    ) -> Self {
        SheetParser {
            wb,
            payload: Vec::new(),
            xf_formats,
            sst,
            is_1904,
            row: Vec::new(),
            current_row: None,
            pending_string_column: None,
            finished: false,
        }
    }

    fn position(&self) -> u64 {
        self.wb.reader.position()
    }

    /// 取走当前行：只裁尾部 NULL（空字符串是真实值），全空行返回 None。
    fn take_row(&mut self) -> Option<Vec<Value>> {
        let mut row = std::mem::take(&mut self.row);
        while matches!(row.last(), Some(Value::Null)) {
            row.pop();
        }
        if row.is_empty() {
            return None;
        }
        Some(row)
    }

    fn next_row(&mut self) -> AppResult<Option<Vec<Value>>> {
        if self.finished {
            return Ok(None);
        }
        loop {
            let Some(typ) = self.wb.reader.next_into(&mut self.payload)? else {
                self.finished = true;
                return Ok(self.take_row());
            };
            match typ {
                EOF => {
                    self.finished = true;
                    return Ok(self.take_row());
                }
                DIMENSIONS => continue,
                STRING => {
                    if let Some(column) = self.pending_string_column.take() {
                        let text = decode_xl_unicode_string(&self.payload);
                        place(&mut self.row, column, Value::String(text));
                    }
                    continue;
                }
                _ => {}
            }
            let Some(row_number) = cell_row(typ, &self.payload) else {
                continue;
            };
            let finished_row = if self.current_row != Some(row_number) {
                let finished = self.take_row();
                self.current_row = Some(row_number);
                self.pending_string_column = None;
                finished
            } else {
                None
            };
            if typ == FORMULA {
                self.pending_string_column = formula_string_column(&self.payload);
            }
            apply_cell(
                typ,
                &self.payload,
                &mut self.row,
                &self.xf_formats,
                &self.sst,
                self.is_1904,
            );
            if finished_row.is_some() {
                return Ok(finished_row);
            }
        }
    }
}

// ---------------------------------------------------------------- 行宽缓冲

/// 流式行缓冲：先攒 WIDTH_PROBE_ROWS 行确定「有效列宽」，再按宽度补齐输出。
///
/// 与 excel_stream::WidthBufferedRows 语义完全相同（那边是私有类型，这里实现
/// 等价逻辑）：既保留旧整表实现「末尾全空列裁掉」的语义，又不需要整表驻留内存。
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

// ---------------------------------------------------------------- 流式线程

/// 线程 → 消费端的消息：行 / 已读字节位置 / 错误。
enum StreamMsg {
    Row(Vec<Value>),
    Position(u64),
    Err(String),
}

/// 有界 channel 行源：消费端被 drop（preview 只看几条）时 send 失败，线程立即退出。
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

struct Producer {
    path: String,
    offset: u64,
    sst: Arc<Vec<String>>,
    xf_formats: Arc<Vec<CellFormat>>,
    is_1904: bool,
    skip_rows: usize,
    tx: SyncSender<StreamMsg>,
}

impl Producer {
    fn run(self) {
        let result = self.produce();
        if let Err(message) = result {
            let _ = self.tx.send(StreamMsg::Err(message.to_string()));
        }
    }

    fn produce(&self) -> AppResult<()> {
        // cfb::Stream 不是 Send，解析线程里自己打开文件（cfb 的目录解析很快；
        // SST 已在 open_sheet 里同步解析好，通过 Arc 共享，不重复解析）。
        let mut opened = open_workbook(&self.path)?;
        opened.reader.seek_to(self.offset)?;
        let total = opened.reader.len();
        let mut parser = SheetParser::new(
            opened,
            self.xf_formats.clone(),
            self.sst.clone(),
            self.is_1904,
        );
        let mut emitter = WidthBufferedRows::new();
        let mut skip_rows = self.skip_rows;
        let mut rows_seen = 0u64;
        loop {
            let Some(row) = parser.next_row()? else {
                break;
            };
            if skip_rows > 0 {
                skip_rows -= 1;
                continue;
            }
            for emitted in emitter.push(row) {
                if self.tx.send(StreamMsg::Row(emitted)).is_err() {
                    return Ok(());
                }
            }
            rows_seen += 1;
            if rows_seen % 128 == 0
                && self
                    .tx
                    .send(StreamMsg::Position(parser.position()))
                    .is_err()
            {
                return Ok(());
            }
        }
        for emitted in emitter.finish() {
            if self.tx.send(StreamMsg::Row(emitted)).is_err() {
                return Ok(());
            }
        }
        let _ = self.tx.send(StreamMsg::Position(total));
        Ok(())
    }
}

// ---------------------------------------------------------------- 公共入口

/// inspect：只读 BOUNDSHEET + 每表 DIMENSIONS + 默认表前两行（不读单元格）。
pub fn inspect(path: &str) -> AppResult<InspectResult> {
    let (info, mut opened) = load_workbook(path)?;
    let Some(default) = info.sheets.first() else {
        return Err(AppError::bad("工作簿里没有可见的工作表"));
    };
    opened.reader.seek_to(default.offset)?;
    let mut parser = SheetParser::new(
        opened,
        info.xf_formats.clone(),
        info.sst.clone(),
        info.is_1904,
    );
    let mut header_rows = Vec::new();
    while header_rows.len() < INSPECT_HEADER_ROWS {
        match parser.next_row()? {
            Some(row) => header_rows.push(row),
            None => break,
        }
    }
    let sheets = info
        .sheets
        .iter()
        .map(|sheet| SheetMetaBrief {
            index: sheet.index,
            name: sheet.name.clone(),
            rows: sheet.rows,
            cols: sheet.cols,
        })
        .collect();
    Ok(InspectResult {
        sheets,
        sheet: default.name.clone(),
        header_rows,
        hidden_sheets: info.hidden_sheets,
    })
}

/// 打开一张工作表：全局元信息同步扫描，行数据在独立线程里流式解析。
pub fn open_sheet(
    path: &str,
    selector: Option<&str>,
    skip_rows: usize,
) -> AppResult<OpenedSheetLike> {
    let (info, opened) = load_workbook(path)?;
    let selected = select_sheet(&info.sheets, selector)?;
    let sheet = &info.sheets[selected];
    let sheets: Vec<(usize, String)> = info
        .sheets
        .iter()
        .map(|sheet| (sheet.index, sheet.name.clone()))
        .collect();
    let total_rows = sheet.rows;
    let total_bytes = opened.reader.len();
    drop(opened);
    let (tx, rx) = sync_channel(CHANNEL_BOUND);
    let producer = Producer {
        path: path.to_string(),
        offset: sheet.offset,
        sst: info.sst.clone(),
        xf_formats: info.xf_formats.clone(),
        is_1904: info.is_1904,
        skip_rows,
        tx,
    };
    let handle = std::thread::Builder::new()
        .name("dbpilot-xls-stream".to_string())
        .spawn(move || producer.run())
        .map_err(|error| AppError::bad(format!("启动 xls 流式读取线程失败: {error}")))?;
    Ok(OpenedSheetLike {
        sheet: sheet.name.clone(),
        sheets,
        total_rows,
        source: Box::new(ChannelSource::new(rx, total_bytes, handle)),
    })
}

// ---------------------------------------------------------------- 测试

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> String {
        format!("{}/tests/fixtures/{}", env!("CARGO_MANIFEST_DIR"), name)
    }

    /// 读完整张表，每行包成 JSON 数组（方便直接和 json! 比较）。
    fn read_all(sheet: &mut OpenedSheetLike) -> Vec<Value> {
        let mut rows = Vec::new();
        while let Some(row) = sheet.source.next_row().expect("stream row") {
            rows.push(Value::Array(row));
        }
        rows
    }

    fn read_head(sheet: &mut OpenedSheetLike, limit: usize) -> Vec<Value> {
        let mut rows = Vec::new();
        while rows.len() < limit {
            match sheet.source.next_row().expect("stream row") {
                Some(row) => rows.push(Value::Array(row)),
                None => break,
            }
        }
        rows
    }

    // ------------------------------------------------ 真实 xlwt fixture

    #[test]
    fn inspect_lists_visible_sheets_in_order() {
        let info = inspect(&fixture("excel_multi.xls")).expect("inspect");
        let names: Vec<&str> = info.sheets.iter().map(|s| s.name.as_str()).collect();
        assert_eq!(names, vec!["员工", "订单", "配置"]);
        assert_eq!(info.sheet, "员工");
        assert_eq!(info.hidden_sheets, 0);
        // DIMENSIONS：员工 5 行（表头 + 4 数据）× 8 列。
        assert_eq!(info.sheets[0].index, 0);
        assert_eq!(info.sheets[0].rows, Some(5));
        assert_eq!(info.sheets[0].cols, Some(8));
        assert_eq!(info.sheets[1].rows, Some(4));
        assert_eq!(info.sheets[1].cols, Some(3));
        assert_eq!(info.header_rows.len(), 2);
        assert_eq!(
            Value::Array(info.header_rows[0].clone()),
            serde_json::json!([
                "id",
                "姓名",
                "入职日期",
                "活跃",
                "评分",
                "备注",
                "登录时间",
                "打卡时间"
            ])
        );
        assert_eq!(
            Value::Array(info.header_rows[1].clone()),
            serde_json::json!([
                1,
                "张伟",
                "2021-03-05",
                true,
                88.5,
                null,
                "2021-03-05 09:30:00",
                "09:30:00"
            ])
        );
    }

    #[test]
    fn reads_employee_sheet_with_native_types() {
        let mut sheet = open_sheet(&fixture("excel_multi.xls"), Some("员工"), 0).expect("open");
        assert_eq!(sheet.sheet, "员工");
        assert_eq!(sheet.sheets.len(), 3);
        assert_eq!(sheet.total_rows, Some(5));
        let rows = read_all(&mut sheet);
        assert_eq!(rows.len(), 5, "表头 + 4 行数据：{rows:?}");
        assert_eq!(
            rows[1],
            serde_json::json!([
                1,
                "张伟",
                "2021-03-05",
                true,
                88.5,
                null,
                "2021-03-05 09:30:00",
                "09:30:00"
            ])
        );
        assert_eq!(
            rows[2],
            serde_json::json!([
                2,
                "李娜",
                "2022-07-18",
                false,
                92,
                "优秀",
                "2022-07-18 14:05:30",
                "09:05:30"
            ])
        );
        // 布尔 false、NULL 备注、中文文本都按原类型保留。
        assert_eq!(rows[3][3], Value::Bool(true));
        assert_eq!(rows[1][5], Value::Null, "张伟 的备注是 NULL");
        assert_eq!(rows[3][5], Value::Null, "王强 的备注是 NULL");
        assert_eq!(rows[2][5], Value::String("优秀".to_string()));
        assert_eq!(rows[4][5], Value::String("试用".to_string()));
    }

    #[test]
    fn selects_sheet_by_name_and_index() {
        let mut by_name = open_sheet(&fixture("excel_multi.xls"), Some("订单"), 0).expect("open");
        assert_eq!(by_name.sheet, "订单");
        assert_eq!(by_name.sheets[1], (1, "订单".to_string()));
        let rows = read_all(&mut by_name);
        assert_eq!(rows[0], serde_json::json!(["订单号", "客户", "金额"]));
        assert_eq!(rows[1], serde_json::json!([1001, "甲公司", 299.5]));
        assert_eq!(rows[3], serde_json::json!([1003, "丙公司", 58.75]));

        // 字符串形式的 0-based 序号也接受（契约：read.sheet 支持序号）。
        let mut by_index = open_sheet(&fixture("excel_multi.xls"), Some("1"), 0).expect("open");
        assert_eq!(by_index.sheet, "订单");
        assert_eq!(
            read_head(&mut by_index, 2)[1],
            serde_json::json!([1001, "甲公司", 299.5])
        );
    }

    #[test]
    fn skip_rows_drops_leading_valid_rows() {
        let mut sheet = open_sheet(&fixture("excel_multi.xls"), None, 1).expect("open");
        let rows = read_all(&mut sheet);
        assert_eq!(rows.len(), 4, "跳过表头后只剩 4 行：{rows:?}");
        assert_eq!(
            rows[0],
            serde_json::json!([
                1,
                "张伟",
                "2021-03-05",
                true,
                88.5,
                null,
                "2021-03-05 09:30:00",
                "09:30:00"
            ])
        );
        assert_eq!(rows[1][1], Value::String("李娜".to_string()));
    }

    #[test]
    fn unknown_sheet_lists_candidates() {
        let error = open_sheet(&fixture("excel_multi.xls"), Some("不存在"), 0)
            .err()
            .expect("unknown sheet must fail");
        let message = error.to_string();
        assert!(message.contains("找不到工作表"), "{message}");
        assert!(message.contains("员工"), "{message}");
        assert!(message.contains("订单"), "{message}");
    }

    #[test]
    fn early_drop_stops_the_producer() {
        let mut sheet = open_sheet(&fixture("excel_multi.xls"), None, 0).expect("open");
        let first = sheet.source.next_row().expect("first row");
        assert!(first.is_some());
        // drop 后线程必须立即退出（send 失败），不能挂住。
        drop(sheet);
    }

    #[test]
    fn reports_byte_progress() {
        let mut sheet = open_sheet(&fixture("excel_multi.xls"), None, 0).expect("open");
        let _ = read_all(&mut sheet);
        let (done, total) = sheet.source.bytes_progress().expect("progress");
        assert!(total > 0);
        assert!(done <= total);
    }

    // ------------------------------------------------ 测试内最小 BIFF8 写入器

    /// 一条原始记录：u16 type + u16 len + payload。
    fn rec(typ: u16, payload: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(4 + payload.len());
        out.extend_from_slice(&typ.to_le_bytes());
        out.extend_from_slice(&(payload.len() as u16).to_le_bytes());
        out.extend_from_slice(payload);
        out
    }

    fn bof(substream: u16) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&0x0600u16.to_le_bytes()); // BIFF8
        payload.extend_from_slice(&substream.to_le_bytes()); // 0x0005 globals / 0x0010 sheet
        payload.extend_from_slice(&0x0Dbbu16.to_le_bytes());
        payload.extend_from_slice(&0x07CCu16.to_le_bytes());
        payload.extend_from_slice(&0u32.to_le_bytes());
        payload.extend_from_slice(&0x0006u16.to_le_bytes());
        payload.extend_from_slice(&0u16.to_le_bytes());
        rec(BOF, &payload)
    }

    fn dimensions(first_row: u32, last_row: u32, first_col: u16, last_col: u16) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&first_row.to_le_bytes());
        payload.extend_from_slice(&last_row.to_le_bytes());
        payload.extend_from_slice(&first_col.to_le_bytes());
        payload.extend_from_slice(&last_col.to_le_bytes());
        payload.extend_from_slice(&0u16.to_le_bytes());
        rec(DIMENSIONS, &payload)
    }

    fn boundsheet(name: &str, offset: u32, hidden: bool) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&offset.to_le_bytes());
        payload.push(if hidden { 1u8 } else { 0u8 });
        payload.push(0u8); // dt = worksheet
        let units: Vec<u16> = name.encode_utf16().collect();
        payload.push(units.len() as u8);
        payload.push(0x01); // fHighByte
        for unit in units {
            payload.extend_from_slice(&unit.to_le_bytes());
        }
        rec(BOUNDSHEET, &payload)
    }

    /// XLUnicodeRichExtendedString（只置 fHighByte，无富文本/扩展块）。
    fn xl_unicode_string(text: &str) -> Vec<u8> {
        let mut out = Vec::new();
        let ascii = text.is_ascii();
        let units: Vec<u16> = text.encode_utf16().collect();
        out.extend_from_slice(&(units.len() as u16).to_le_bytes());
        out.push(if ascii { 0 } else { 1 });
        for unit in &units {
            if ascii {
                out.push(*unit as u8);
            } else {
                out.extend_from_slice(&unit.to_le_bytes());
            }
        }
        out
    }

    fn sst_payload(strings: &[&str]) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&(strings.len() as u32).to_le_bytes());
        payload.extend_from_slice(&(strings.len() as u32).to_le_bytes());
        for text in strings {
            payload.extend_from_slice(&xl_unicode_string(text));
        }
        payload
    }

    fn number_cell(row: u16, col: u16, xf: u16, value: f64) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&row.to_le_bytes());
        payload.extend_from_slice(&col.to_le_bytes());
        payload.extend_from_slice(&xf.to_le_bytes());
        payload.extend_from_slice(&value.to_le_bytes());
        rec(NUMBER, &payload)
    }

    fn label_sst_cell(row: u16, col: u16, xf: u16, index: u32) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&row.to_le_bytes());
        payload.extend_from_slice(&col.to_le_bytes());
        payload.extend_from_slice(&xf.to_le_bytes());
        payload.extend_from_slice(&index.to_le_bytes());
        rec(LABELSST, &payload)
    }

    /// 一张工作表：表名 + 是否隐藏 + 记录 + DIMENSIONS 参数。
    struct TestSheet {
        name: &'static str,
        hidden: bool,
        records: Vec<Vec<u8>>,
        dims: (u32, u32, u16, u16),
    }

    /// 组装一个完整的 BIFF8 Workbook 流。
    ///
    /// * prefix：全局子流 BOF 之后立即插入的记录（DATEMODE / XF / FORMAT …）；
    /// * sst / sst_extra：SST payload 与紧随其后的 CONTINUE 记录；
    /// * BOUNDSHEET 偏移由本函数算出，调用方不用关心。
    fn build(
        prefix: Vec<Vec<u8>>,
        sheets: Vec<TestSheet>,
        sst: Option<Vec<u8>>,
        sst_extra: Vec<Vec<u8>>,
    ) -> Vec<u8> {
        let mut sheet_streams: Vec<Vec<u8>> = Vec::new();
        for sheet in &sheets {
            let mut stream = bof(0x0010);
            stream.extend_from_slice(&dimensions(
                sheet.dims.0,
                sheet.dims.1,
                sheet.dims.2,
                sheet.dims.3,
            ));
            for record in &sheet.records {
                stream.extend_from_slice(record);
            }
            stream.extend_from_slice(&rec(EOF, &[]));
            sheet_streams.push(stream);
        }
        let mut globals_len = bof(0x0005).len();
        for record in &prefix {
            globals_len += record.len();
        }
        for sheet in &sheets {
            globals_len += boundsheet(sheet.name, 0, false).len();
        }
        if let Some(payload) = &sst {
            globals_len += rec(SST, payload).len();
        }
        for extra in &sst_extra {
            globals_len += extra.len();
        }
        globals_len += rec(EOF, &[]).len();

        let mut globals = bof(0x0005);
        for record in prefix {
            globals.extend_from_slice(&record);
        }
        let mut offset = globals_len as u32;
        for (sheet, stream) in sheets.iter().zip(&sheet_streams) {
            globals.extend_from_slice(&boundsheet(sheet.name, offset, sheet.hidden));
            offset += stream.len() as u32;
        }
        if let Some(payload) = sst {
            globals.extend_from_slice(&rec(SST, &payload));
        }
        for extra in sst_extra {
            globals.extend_from_slice(&extra);
        }
        globals.extend_from_slice(&rec(EOF, &[]));

        let mut workbook = globals;
        for stream in sheet_streams {
            workbook.extend_from_slice(&stream);
        }
        workbook
    }

    fn write_xls(workbook: &[u8]) -> String {
        let dir = std::env::temp_dir().join(format!("rma-xls-stream-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("synthetic.xls");
        {
            let mut cfb = cfb::create(&path).expect("create cfb");
            {
                let mut stream = cfb.create_stream("Workbook").expect("create stream");
                std::io::Write::write_all(&mut stream, workbook).expect("write stream");
            }
            cfb.flush().expect("flush cfb");
        }
        path.to_string_lossy().into_owned()
    }

    fn date_xf(ifmt: u16) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&0u16.to_le_bytes()); // ifnt
        payload.extend_from_slice(&ifmt.to_le_bytes());
        payload.extend_from_slice(&[0u8; 16]);
        rec(XF, &payload)
    }

    // ------------------------------------------------ 合成文件：流式 50,000 行

    #[test]
    fn streams_fifty_thousand_rows() {
        const ROWS: u32 = 50_000;
        let mut records: Vec<Vec<u8>> = Vec::with_capacity(ROWS as usize + 1);
        records.push(label_sst_cell(0, 0, 0, 0));
        for row in 0..ROWS {
            records.push(number_cell((row + 1) as u16, 0, 0, row as f64));
        }
        let path = write_xls(&build(
            Vec::new(),
            vec![TestSheet {
                name: "大表",
                hidden: false,
                records,
                dims: (0, ROWS + 1, 0, 1),
            }],
            Some(sst_payload(&["序号"])),
            Vec::new(),
        ));

        let info = inspect(&path).expect("inspect synthetic");
        assert_eq!(info.sheets[0].name, "大表");
        assert_eq!(info.sheets[0].rows, Some(ROWS as u64 + 1));
        assert_eq!(info.sheets[0].cols, Some(1));

        let mut sheet = open_sheet(&path, None, 0).expect("open synthetic");
        let mut count = 0u64;
        let mut first_data: Option<Value> = None;
        let mut last: Option<Value> = None;
        while let Some(row) = sheet.source.next_row().expect("stream row") {
            let row = Value::Array(row);
            if count == 0 {
                assert_eq!(row, serde_json::json!(["序号"]));
            } else if count == 1 {
                first_data = Some(row.clone());
            }
            last = Some(row);
            count += 1;
        }
        assert_eq!(count, ROWS as u64 + 1, "表头 + {ROWS} 行数据");
        assert_eq!(first_data.expect("first data row"), serde_json::json!([0]));
        assert_eq!(
            last.expect("last row"),
            serde_json::json!([ROWS as i64 - 1])
        );
        let _ = std::fs::remove_file(&path);
    }

    // ------------------------------------------------ 合成文件：其余单元格记录

    #[test]
    fn supports_remaining_cell_records() {
        // 一行覆盖 MULRK / MULBLANK / BLANK / BOOLERR（布尔 + 错误）/
        // FORMULA（数字、字符串 + STRING 记录、布尔）。
        let mut mulrk = Vec::new();
        mulrk.extend_from_slice(&1u16.to_le_bytes()); // row
        mulrk.extend_from_slice(&0u16.to_le_bytes()); // colFirst
        for value in [1i32, 2, 3] {
            mulrk.extend_from_slice(&0u16.to_le_bytes()); // xf
            mulrk.extend_from_slice(&(((value << 2) | 0x02) as u32).to_le_bytes());
        }
        mulrk.extend_from_slice(&2u16.to_le_bytes()); // colLast

        let mut mulblank = Vec::new();
        mulblank.extend_from_slice(&1u16.to_le_bytes());
        mulblank.extend_from_slice(&3u16.to_le_bytes());
        mulblank.extend_from_slice(&[0u8; 4]); // 2 个 xf
        mulblank.extend_from_slice(&4u16.to_le_bytes());

        let mut blank = Vec::new();
        blank.extend_from_slice(&1u16.to_le_bytes());
        blank.extend_from_slice(&5u16.to_le_bytes());
        blank.extend_from_slice(&0u16.to_le_bytes());

        let mut bool_cell = Vec::new();
        bool_cell.extend_from_slice(&1u16.to_le_bytes());
        bool_cell.extend_from_slice(&6u16.to_le_bytes());
        bool_cell.extend_from_slice(&0u16.to_le_bytes());
        bool_cell.push(1);
        bool_cell.push(0);

        let mut err_cell = bool_cell.clone();
        // 列号在 payload[2..4]（payload[4..6] 是 xf）。
        err_cell[2..4].copy_from_slice(&7u16.to_le_bytes());
        err_cell[6] = 0x07; // #DIV/0!
        err_cell[7] = 1;

        let mut formula_num = Vec::new();
        formula_num.extend_from_slice(&1u16.to_le_bytes());
        formula_num.extend_from_slice(&8u16.to_le_bytes());
        formula_num.extend_from_slice(&0u16.to_le_bytes());
        formula_num.extend_from_slice(&12.5f64.to_le_bytes());
        formula_num.extend_from_slice(&[0u8; 6]); // grbit + chn
        formula_num.extend_from_slice(&0u16.to_le_bytes()); // cce

        let mut formula_str = Vec::new();
        formula_str.extend_from_slice(&1u16.to_le_bytes());
        formula_str.extend_from_slice(&9u16.to_le_bytes());
        formula_str.extend_from_slice(&0u16.to_le_bytes());
        formula_str.extend_from_slice(&[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF]);
        formula_str.extend_from_slice(&[0u8; 6]);
        formula_str.extend_from_slice(&0u16.to_le_bytes());

        let mut formula_bool = Vec::new();
        formula_bool.extend_from_slice(&1u16.to_le_bytes());
        formula_bool.extend_from_slice(&10u16.to_le_bytes());
        formula_bool.extend_from_slice(&0u16.to_le_bytes());
        formula_bool.extend_from_slice(&[0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0xFF, 0xFF]);
        formula_bool.extend_from_slice(&[0u8; 6]);
        formula_bool.extend_from_slice(&0u16.to_le_bytes());

        let records = vec![
            rec(MULRK, &mulrk),
            rec(MULBLANK, &mulblank),
            rec(BLANK, &blank),
            rec(BOOLERR, &bool_cell),
            rec(BOOLERR, &err_cell),
            rec(FORMULA, &formula_num),
            rec(FORMULA, &formula_str),
            rec(STRING, &xl_unicode_string("公式文本")),
            rec(FORMULA, &formula_bool),
        ];
        let path = write_xls(&build(
            Vec::new(),
            vec![TestSheet {
                name: "记录",
                hidden: false,
                records,
                dims: (0, 2, 0, 11),
            }],
            Some(sst_payload(&["未使用"])),
            Vec::new(),
        ));

        let mut sheet = open_sheet(&path, None, 0).expect("open");
        let rows = read_all(&mut sheet);
        assert_eq!(rows.len(), 1, "{rows:?}");
        let row = &rows[0];
        assert_eq!(row[0], serde_json::json!(1));
        assert_eq!(row[1], serde_json::json!(2));
        assert_eq!(row[2], serde_json::json!(3));
        // MULBLANK / BLANK 都是 Null（中间的 NULL 保留，末尾才裁掉）。
        assert_eq!(row[3], Value::Null);
        assert_eq!(row[4], Value::Null);
        assert_eq!(row[5], Value::Null);
        assert_eq!(row[6], Value::Bool(true));
        assert_eq!(row[7], Value::Null, "错误值 → Null");
        assert_eq!(row[8], serde_json::json!(12.5));
        assert_eq!(row[9], Value::String("公式文本".to_string()));
        assert_eq!(row[10], Value::Bool(true));
        let _ = std::fs::remove_file(&path);
    }

    // ------------------------------------------------ 合成文件：SST 跨 CONTINUE

    #[test]
    fn sst_string_spanning_continue_rereads_grbit() {
        // "AB中C"：前 2 个字符 compressed，跨 CONTINUE 后切到 UTF-16。
        let mut sst = Vec::new();
        sst.extend_from_slice(&1u32.to_le_bytes()); // cstTotal
        sst.extend_from_slice(&1u32.to_le_bytes()); // cstUnique
        sst.extend_from_slice(&4u16.to_le_bytes()); // cch
        sst.push(0x00); // 起始段 compressed
        sst.extend_from_slice(b"AB");
        let mut cont = Vec::new();
        cont.push(0x01); // 续接段重新给出 grbit：UTF-16
        for unit in "中C".encode_utf16() {
            cont.extend_from_slice(&unit.to_le_bytes());
        }
        let path = write_xls(&build(
            Vec::new(),
            vec![TestSheet {
                name: "跨段",
                hidden: false,
                records: vec![label_sst_cell(0, 0, 0, 0), number_cell(1, 0, 0, 1.0)],
                dims: (0, 2, 0, 1),
            }],
            Some(sst),
            vec![rec(CONTINUE, &cont)],
        ));
        let mut sheet = open_sheet(&path, None, 0).expect("open");
        let rows = read_all(&mut sheet);
        assert_eq!(rows[0], serde_json::json!(["AB中C"]), "{rows:?}");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn sst_string_starting_on_continue_is_read() {
        // 第一条字符串在 SST 段内，第二条整条落在 CONTINUE 段里。
        let mut sst = Vec::new();
        sst.extend_from_slice(&2u32.to_le_bytes());
        sst.extend_from_slice(&2u32.to_le_bytes());
        sst.extend_from_slice(&xl_unicode_string("一"));
        let mut cont = Vec::new();
        cont.extend_from_slice(&xl_unicode_string("二"));
        let path = write_xls(&build(
            Vec::new(),
            vec![TestSheet {
                name: "续接",
                hidden: false,
                records: vec![label_sst_cell(0, 0, 0, 0), label_sst_cell(0, 1, 0, 1)],
                dims: (0, 1, 0, 2),
            }],
            Some(sst),
            vec![rec(CONTINUE, &cont)],
        ));
        let mut sheet = open_sheet(&path, None, 0).expect("open");
        let rows = read_all(&mut sheet);
        assert_eq!(rows[0], serde_json::json!(["一", "二"]), "{rows:?}");
        let _ = std::fs::remove_file(&path);
    }

    // ------------------------------------------------ 合成文件：隐藏表 / 1904 / 错误

    #[test]
    fn hidden_sheets_are_excluded_and_counted() {
        let path = write_xls(&build(
            Vec::new(),
            vec![
                TestSheet {
                    name: "可见",
                    hidden: false,
                    records: vec![label_sst_cell(0, 0, 0, 0), number_cell(1, 0, 0, 7.0)],
                    dims: (0, 2, 0, 1),
                },
                TestSheet {
                    name: "隐藏",
                    hidden: true,
                    records: vec![number_cell(0, 0, 0, 99.0)],
                    dims: (0, 1, 0, 1),
                },
            ],
            Some(sst_payload(&["值"])),
            Vec::new(),
        ));
        let info = inspect(&path).expect("inspect");
        assert_eq!(info.hidden_sheets, 1);
        assert_eq!(info.sheets.len(), 1);
        assert_eq!(info.sheets[0].name, "可见");
        // hidden_sheets 必须穿过 excel_stream 的统一 InspectInfo（xls_inspect_info），
        // importer::inspect_excel 才会追加「已忽略 N 个隐藏工作表」warning；
        // 与 xlsx / xlsb 两条路径对齐。
        // 注：仓库里的 excel_multi.xls fixture 只有 3 张可见表、没有隐藏表，
        // 所以隐藏表场景只能用这里合成的 BIFF8 工作簿覆盖。
        let unified =
            crate::excel_stream::inspect_workbook(&path, crate::excel_import::ExcelKind::Xls)
                .expect("inspect_workbook");
        assert_eq!(unified.hidden_sheets, 1);
        assert_eq!(unified.sheets.len(), 1);
        assert_eq!(unified.sheet, "可见");
        let mut sheet = open_sheet(&path, None, 0).expect("open");
        assert_eq!(read_all(&mut sheet).len(), 2);
        // 隐藏表按名字选不到。
        assert!(open_sheet(&path, Some("隐藏"), 0).is_err());
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn honours_1904_date_mode() {
        // DATEMODE=1：序列号 0 = 1904-01-01（excel_serial_value 的 1462 偏移）。
        // XF #0 指向内建日期格式 14。
        let path = write_xls(&build(
            vec![rec(DATEMODE, &1u16.to_le_bytes()), date_xf(14)],
            vec![TestSheet {
                name: "日期",
                hidden: false,
                records: vec![number_cell(0, 0, 0, 0.0)],
                dims: (0, 1, 0, 1),
            }],
            None,
            Vec::new(),
        ));
        let mut sheet = open_sheet(&path, None, 0).expect("open");
        let rows = read_all(&mut sheet);
        assert_eq!(rows[0], serde_json::json!(["1904-01-01"]), "{rows:?}");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn custom_date_format_from_format_record_is_honoured() {
        // 自定义 ifmt=0xA4 + FORMAT 记录 "YYYY-MM-DD"：1900 日期模式下
        // 44260 = 2021-03-05。
        let mut format_payload = Vec::new();
        format_payload.extend_from_slice(&0xA4u16.to_le_bytes());
        format_payload.extend_from_slice(&10u16.to_le_bytes());
        format_payload.push(0x00); // compressed
        format_payload.extend_from_slice(b"YYYY-MM-DD");
        let path = write_xls(&build(
            vec![rec(FORMAT, &format_payload), date_xf(0xA4)],
            vec![TestSheet {
                name: "自定义",
                hidden: false,
                records: vec![number_cell(0, 0, 0, 44260.0)],
                dims: (0, 1, 0, 1),
            }],
            None,
            Vec::new(),
        ));
        let mut sheet = open_sheet(&path, None, 0).expect("open");
        let rows = read_all(&mut sheet);
        assert_eq!(rows[0], serde_json::json!(["2021-03-05"]), "{rows:?}");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn duration_format_uses_duration_value() {
        // ifmt=46（[h]:mm:ss）→ 时长；1.5 天 = 36:00:00。
        let path = write_xls(&build(
            vec![date_xf(46)],
            vec![TestSheet {
                name: "时长",
                hidden: false,
                records: vec![number_cell(0, 0, 0, 1.5)],
                dims: (0, 1, 0, 1),
            }],
            None,
            Vec::new(),
        ));
        let mut sheet = open_sheet(&path, None, 0).expect("open");
        let rows = read_all(&mut sheet);
        assert_eq!(rows[0], serde_json::json!(["36:00:00"]), "{rows:?}");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn east_asian_builtin_formats_resolve_serial_to_date() {
        // 27–36 / 50–58 是 CJK 等区域设置的日期时间内建格式；37–44 是会计/数值格式。
        for id in [14u16, 22, 27, 28, 31, 36, 50, 55, 58] {
            assert_eq!(builtin_format(id), CellFormat::DateTime, "ifmt={id}");
        }
        for id in [0u16, 37, 38, 39, 40, 41, 42, 43, 44, 49, 59] {
            assert_eq!(builtin_format(id), CellFormat::Other, "ifmt={id}");
        }
        assert_eq!(builtin_format(46), CellFormat::TimeDelta);

        // 45000 = 2023-03-15（1900 日期系统）；fmt 27/31/55 必须给出日期串而不是整数。
        for ifmt in [27u16, 31, 55] {
            let path = write_xls(&build(
                vec![date_xf(ifmt)],
                vec![TestSheet {
                    name: "日期",
                    hidden: false,
                    records: vec![number_cell(0, 0, 0, 45_000.0)],
                    dims: (0, 1, 0, 1),
                }],
                None,
                Vec::new(),
            ));
            let mut sheet = open_sheet(&path, None, 0).expect("open");
            let rows = read_all(&mut sheet);
            assert_eq!(
                rows[0],
                serde_json::json!(["2023-03-15"]),
                "ifmt={ifmt}: {rows:?}"
            );
            let _ = std::fs::remove_file(&path);
        }
    }

    #[test]
    fn blank_rows_are_skipped_and_rows_padded_to_width() {
        // 第 0 行只有 B 列（A 列空洞），第 1 行只有 A 列 → 输出宽度按缓冲定宽补齐。
        let path = write_xls(&build(
            Vec::new(),
            vec![TestSheet {
                name: "补齐",
                hidden: false,
                records: vec![number_cell(0, 2, 0, 1.0), number_cell(1, 0, 0, 2.0)],
                dims: (0, 2, 0, 3),
            }],
            None,
            Vec::new(),
        ));
        let mut sheet = open_sheet(&path, None, 0).expect("open");
        let rows = read_all(&mut sheet);
        assert_eq!(
            rows,
            vec![
                serde_json::json!([null, null, 1]),
                serde_json::json!([2, null, null]),
            ]
        );
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn rejects_non_ole2_files() {
        let dir = std::env::temp_dir().join(format!("rma-xls-bad-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("not.xls");
        std::fs::write(&path, b"not an ole2 file").expect("write");
        let message = inspect(&path.to_string_lossy())
            .err()
            .expect("must fail")
            .to_string();
        assert!(message.contains("OLE2"), "{message}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
