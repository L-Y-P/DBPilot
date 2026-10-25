//! excel_multi.xlsb 的生成脚本（复现用，不是 cargo 测试目标）。
//!
//! 本文件放在 tests/fixtures/ 下，**不会被 cargo 编译**（cargo 只把 tests/*.rs 顶层
//! 文件当集成测试目标），它的作用是留下「这个二进制 fixture 是怎么来的」的可执行说明。
//!
//! ## 为什么不用现成的 xlsb 写入库
//!
//! rxlsb 之类的写入器把 BrtCellBool 写成 9 字节 payload（column 4 + iStyleRef 3 +
//! 值 1 + 多 1 字节），不符合 MS-XLSB 2.5.9 的 Cell 布局（8 字节头 + 1 字节值 = 9，
//! 而它们写 10）。用这种文件当 fixture 会把「读取器能读错文件」当成正确性证据。
//! 因此 fixture 由 xlsb_stream 模块内的最小 BRT 写入器生成，并用 calamine（独立实现）
//! 反向校验（见 src/xlsb_stream.rs 的 fixture_reads_with_calamine 测试）。
//!
//! ## 复现命令
//!
//! ```sh
//! cd desktop/rust
//! export PATH=$HOME/.cargo/bin:$PATH
//! CARGO_INCREMENTAL=0 cargo test --offline --lib \
//!   xlsb_stream::tests::write_excel_multi_fixture -- --ignored --nocapture
//! ```
//!
//! 产物：`desktop/rust/tests/fixtures/excel_multi.xlsb`（约 2.7 KB）。
//!
//! ## 内容（与 excel_multi.xlsx / excel_multi.xls 对齐）
//!
//! | 工作表 | 可见 | 内容 |
//! | --- | --- | --- |
//! | 员工 | 是（默认选中） | id / 姓名 / 入职日期 / 活跃 / 评分 / 备注 / 登录时间 / 打卡时间 |
//! | 订单 | 是 | 订单号 / 客户 / 金额 |
//! | 配置 | 是 | 键 / 值 |
//! | 隐藏数据 | 否 | 只用来断言 hidden_sheets 计数 |
//!
//! 「员工」覆盖：整数（BrtCellRk）、中文文本（BrtCellIsst + sharedStrings）、
//! 日期（ifmt 14）、日期时间（ifmt 22）、纯时间（ifmt 21）、布尔（BrtCellBool）、
//! NULL（BrtCellBlank）、小数（BrtCellReal）。
//!
//! ## 文件结构
//!
//! ```
//! [Content_Types].xml
//! _rels/.rels
//! xl/_rels/workbook.bin.rels   rId1..N → worksheets/sheetN.bin
//! xl/workbook.bin              BrtWbProp / BrtBundleSh × 4
//! xl/sharedStrings.bin         BrtBeginSst / BrtSstItem × 28
//! xl/styles.bin                BrtFmt × 2 + BrtBeginCellXFs / BrtXF × 5
//! xl/worksheets/sheet1..4.bin  BrtWsDim / BrtBeginSheetData / BrtRowHdr + Cell / BrtEndSheetData
//! ```
//!
//! 生成逻辑（写入器本体）在 `src/xlsb_stream.rs` 的 `mod tests` 里：
//! `BrtWriter` / `Cell` / `SheetSpec` / `workbook_bytes` / `excel_multi_spec`。
//! 它们必须留在单元测试里（复用 `push_varint` / `wide` / `cell_header` 这些同样被
//! 布局断言覆盖的辅助函数），所以这里只留说明与指针。
//!
//! ## 校验
//!
//! ```sh
//! CARGO_INCREMENTAL=0 cargo test --offline --lib xlsb_stream
//! ```
//!
//! 其中 `fixture_reads_with_calamine` 用 calamine 0.26 读同一个文件，断言
//! 单元格类型/值/日期序列号与我们的流式读取完全一致 —— 这一步专门用来兜住
//! 「单元格头 8 字节 / Bool 9 字节」这类布局错误。

/// 重新生成 fixture 的入口说明（真正的生成逻辑见 src/xlsb_stream.rs 的单元测试）。
pub const REGENERATE: &str = "CARGO_INCREMENTAL=0 cargo test --offline --lib \
    xlsb_stream::tests::write_excel_multi_fixture -- --ignored --nocapture";
