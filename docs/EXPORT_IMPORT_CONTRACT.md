# 数据导入/导出契约（第 50 轮：Excel 导入扩展）

> 读者：导入向导（`lib/src/views/data_import_wizard.dart`）、快速建表向导
> （`lib/src/views/quick_create_table_wizard.dart`）与 Rust 导入引擎的维护者。
> 实现：`desktop/rust/src/importer.rs`、`desktop/rust/src/excel_import.rs`。
> 本轮设计决策见 [IMPORT_EXCEL_ER_DESIGN.md](IMPORT_EXCEL_ER_DESIGN.md) §2。

## 1. 导出格式（不变）

| `format` | 扩展名 | 说明 |
| --- | --- | --- |
| `csv` / `txt` | .csv/.txt | 逗号/制表符分隔文本，NULL 写作 `\N` |
| `json` | .json | JSON 数组（对象记录） |
| `xml` | .xml | `<rows><row><col name=.../></row></rows>` |
| `html` | .html | `<table>`，NULL 单元格带 `class="null"` |
| `xls` | .xls | SpreadsheetML 2003（Excel 2003 XML 工作簿） |
| `md` | .md | Markdown 表格 |
| `sql` | .sql | SQL 脚本 |

## 2. 导入格式识别（内容优先、扩展名兜底）

`import_inspect(path)` 按下面的顺序判断，**先看文件内容再看扩展名**：

1. ZIP 魔数 `PK\x03\x04` → 按内部结构区分：
   - `xl/workbook.bin` → `format="xlsb"`；
   - `xl/workbook.xml` → `format="xlsx"`（含 .xlsm/.xltx）；
   - `opendocument.spreadsheet` → `format="ods"`；
2. OLE2 魔数 `D0 CF 11 E0 A1 B1 1A E1` → `format="xls"`（BIFF8）；
3. 文本含 `mso-application progid="Excel.Sheet"`（或 .xls 扩展名 + XML 内容）
   → `format="excel"`（SpreadsheetML 2003，支持多 `<Worksheet>`）；
4. 其余沿用旧逻辑：json/json_lines/xml/html/markdown/delimited。

| `format` | 扩展名 | `fields.mode` | 工作表 |
| --- | --- | --- | --- |
| `xlsx` | .xlsx/.xlsm | `excel` | 多表 |
| `xls` | .xls | `excel` | 多表（BIFF8） |
| `xlsb` | .xlsb | `excel` | 多表 |
| `ods` | .ods | `excel` | 多表 |
| `excel` | .xls（SpreadsheetML） | `excel` | 多表 |
| `csv` / `tsv` / `txt` | 同名 | `delimited` | 单表 |
| `json_array` / `json_lines` | .json/.jsonl | `json` | 单表 |
| `xml` / `html` / `markdown` | .xml/.html/.md | 同名 | 单表 |

二进制 Excel 文件的 `encoding` 返回 `"binary"`，`head`/`tail` 为空字符串（不展示乱码）；
SpreadsheetML 仍是 UTF-8 文本，`head` 返回 XML 片段。

## 3. `import_inspect` 返回（Excel 新增字段）

```jsonc
{
  "format": "xlsx",                    // xlsx | xls | xlsb | ods | excel(SpreadsheetML)
  "encoding": "binary",
  "sheets": [                          // 仅可见工作表；隐藏表不列出
    { "index": 0, "name": "员工", "rows": 5, "cols": 8 },   // rows 含表头行
    { "index": 1, "name": "订单", "rows": 4, "cols": 3 }
  ],
  "sheet": "员工",                      // 默认选中：第一张可见工作表
  "read":  { "mode": "line", "sheet": "员工", "skip_rows": 0, "...": "..." },
  "fields": { "mode": "excel", "header": true, "...": "..." },
  "streaming": true,                   // 本次识别是否走流式读取（当前所有 Excel 格式均为 true）
  "warnings": ["检测到 2 个工作表：当前导入所选工作表；一次导入多个工作表请用「从文件建表」"]
}
```

- 表头启发式与 CSV 一致：首行**全是非空文本**且后面还有数据行时 `fields.header=true`。
- **inspect 不再整表载入**（第 51 轮）：
  - `xlsx/xlsm`：只读 `xl/workbook.xml` + `xl/_rels/workbook.xml.rels` + 每张表的
    `<dimension>`（表头判定只解析默认表的前两行）；`sharedStrings.xml` 一次性加载
    （xlsx 的字符串都引用它，这是唯一按字符串总量占内存的部分）。
  - `SpreadsheetML / ODS`：单次顺序扫描 XML，只统计表名 / 行数 / 列数 + 默认表前两行，
    不保存单元格；文件再大也只会占一个固定大小的读缓冲。
  - `xls(BIFF8)`：OLE2(CFB) 的 Workbook 流 + BIFF record 顺序遍历，只读 BOUNDSHEET 与
    每张表的 DIMENSIONS + 默认表前两行（不读单元格）；SST（共享字符串表）一次性加载。
  - `xlsb`：ZIP 里只读 workbook.bin / rels / 每表 BrtWsDim + 默认表前两行；sharedStrings.bin
    与 styles.bin 一次性加载。
- `sheets[].rows/cols` 是「已知才给」：xlsx 来自 dimension，SpreadsheetML/ODS 来自扫描；
  xls/xlsb 的非默认表、以及没有 dimension 的 xlsx 会省略这两个字段，
  UI 按「无 rows 只显示名字」处理即可。

## 4. 读规则新增参数（preview / validate / execute / probe 通用）

| 参数 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `read.sheet` | string \| number | 第一张可见表 | 工作表名或 **0-based 序号**（`"1"` 与 `1` 都接受）。名称不存在时报「找不到工作表」并列出可选表名。Dart 侧把 `read` 原样透传到 preview/validate/execute，保证四个阶段读同一张表。 |
| `read.skip_rows` | number | 0 | 跳过工作表最前面的 N 行（例如首行是标题、第二行才是表头）。**表头判定在跳过之后**。 |

非 Excel 格式忽略这两个字段，行为与旧版本一致。

## 5. `fields.mode = "excel"`

Excel 的一行在引擎里就是一段 JSON 数组文本（`["a", 1, true, null]`），因此：

- 解析复用 JSON 数组规则；`preview.records[].text` 是这段 JSON 文本，Dart 的
  「分割结果回显」组件可以直接展示；
- `fields.header=true` 时第一条记录是表头（空表头单元格自动补 `column_N`，
  其余规则同 CSV；`header=false` 时按位置 0,1,2… 映射）；
- 单元格保持 Excel 原类型：数字→整数/小数、布尔→bool、空单元格/公式错误→NULL、
  日期→`YYYY-MM-DD`、日期时间→`YYYY-MM-DD HH:MM:SS`、纯时间/时长→`HH:MM:SS`；
- 映射、类型转换、批量 INSERT、取消/进度复用既有管线；
- Excel 进度按行且保持流式：总行数来自 dimension / 扫描，
  `percent = 已读行 / 表总行数`，`message = "工作表 <名> · 第 N/M 行"`；
  总行数未知时（无 dimension 的 xlsx、SpreadsheetML、ODS）退化为
  `percent = XML 字节进度`、`message = "工作表 <名> · 第 N 行"`，读完强制 100%。
  `bytes/total_bytes` 按同一进度等比缩放（Dart 侧显示不会一直是 0）。

## 6. `importPreview` 新增 `schema`（类型推断，快速建表用）

```jsonc
{
  "sheet_used": "员工",              // Excel 才有
  "sheets": [ { "index": 0, "name": "员工" } ],
  "records": [ "..." ],
  "header": ["id", "姓名"],
  "schema": {
    "sample_count": 500,             // 实际扫描的数据行数（表头之后，最多 1000）
    "columns": [
      { "name": "id", "source": 0, "type": "integer", "nullable": false,
        "max_length": 0, "unique": true, "primary_candidate": true,
        "primary_candidate_reason": "id", "samples": [1, 2, 3] },
      { "name": "姓名", "source": 1, "type": "text", "nullable": true, "max_length": 255 },
      { "name": "评分", "source": 4, "type": "decimal", "nullable": false }
    ]
  }
}
```

- 请求参数可带 `infer: true`（快速建表）；**不传也会返回 schema**，旧调用方只是多一个字段。
- `type`（跨驱动中性名）：`integer` | `bigint` | `decimal` | `float` | `boolean` |
  `date` | `datetime` | `time` | `text`。第一版不产出 `float`（有小数统一 `decimal`）。
- 规则：忽略 NULL/空字符串（空值不否定类型，只置 `nullable=true`）；整数全在 i32 →
  `integer`，否则 `bigint`；有小数 → `decimal`；布尔（bool/true/false/是/否，含 0/1
  混合且 ≥90%）→ `boolean`；100% 匹配日期/日期时间/时间格式的字符串 → `date`/
  `datetime`/`time`；100% 可解析为数字的字符串列按数字类型；其余 `text`
  （`max_length` 是**建表推荐长度**，不是样本最大字符数：样本 ≤127 字符时给 255
  （至少 2 倍余量，避免文员之后录入稍长的姓名/班级就触发严格模式 1406 错误）；
  超过 127 字符给 0，Dart 侧落 TEXT。非文本列为 0。）
- `name`：表头名（保留中文），空白/引号/控制字符替换为 `_`，重复加 `_2`，空表头为
  `column_N`；DDL 侧负责 quote 标识符。
- `unique`：该列在样本内无重复非空值、无空值且至少一个非空值（第 52 轮新增）。
- `primary_candidate` / `primary_candidate_reason`：每张表最多一个候选，按优先级
  选一个（第 52 轮扩展；只影响建表建议，不改类型推断本身）：
  1. 列名 `id`（忽略大小写）→ `id`；
  2. 最早的样本内唯一整数列（学号/订单号/工号这类自然键）→ `unique_integer`；
  3. 第一列且样本内唯一的短文本列（≤64 字符）→ `first_column`；
  4. 没有候选时 `primary_candidate=false`，reason 为空串。
  `unique_integer` / `first_column` 是「按样本猜的」，Dart 侧默认选中并提示用户可改。
- `samples`：最多 3 个去重后的样本值（`1.0` 这类整数值会规范成 `1`）。
- 非 Excel 格式同样返回 schema（CSV 数字列也能直接建表）。

## 7. 流式读取矩阵（第 51 轮）

| 格式 | inspect | preview / validate / probe / execute | 说明 |
| --- | --- | --- | --- |
| `xlsx` / `xlsm` | 流式（workbook+rels+dimension+前两行） | **流式**（zip + quick-xml 逐 `<row>`） | sharedStrings 一次性加载；styles.xml 判日期格式；支持 inlineStr/s/b/e/n/d/公式缓存值；XML 在工作线程解析、有界 channel 送行，preview 只看几条时线程立即停止 |
| `SpreadsheetML`（.xls XML） | 流式（单次扫描统计） | **流式**（quick-xml 逐 Worksheet/Row/Cell） | 多 Worksheet、ss:Index、ss:Type 语义不变 |
| `ods` | 流式（content.xml 单次扫描） | **流式**（zip + quick-xml 逐 table-row/table-cell） | P1；支持 float/percentage/currency/boolean/date/time/string 与重复行列 |
| `xls`（BIFF8） | 流式（BOUNDSHEET + 每表 DIMENSIONS + 默认表前两行） | **流式（Record 级）**：cfb 的 Workbook 流 + BIFF record 顺序遍历（SST/CONTINUE、LABELSST/LABEL/NUMBER/RK/MULRK/BOOLERR/FORMULA 缓存值、XF+FORMAT 判日期、DATEMODE 1904） | 不整表载入 Workbook 流；SST 一次性加载（与 xlsx 的 sharedStrings 同理）；BIFF5/7 与加密工作簿报错 |
| `xlsb` | 流式（workbook.bin + 每表 BrtWsDim + 默认表前两行） | **流式（Row 级）**：zip 的 ZipFile(Read) 边解压边解析 BRT（varint id + varsize、BrtRowHdr/BrtCell*/公式缓存值、sharedStrings/styles） | 工作表 entry 级流式，无 read_to_end；SST/styles 一次性加载；加密 xlsb 报错 |

- CSV/JSON/XML/HTML/Markdown 等文本格式本来就走流式字节读取，本轮不变。
- 大文件护栏（第 51 轮）：单文件超过 **5 GB** 时，能流式读取的格式只在 warnings 里提醒
  （「文件约 X GB（超过 5 GB）：会逐行流式读取，耗时与磁盘 IO 会明显增加」）；
  如果有读取路径需要整表载入内存，则超过 5 GB 直接拒绝并在错误里说明格式与拆分建议。
  当前 xlsx/xls/xlsb/ODS/SpreadsheetML/CSV/JSON 等全部流式，所以实际行为是「提醒不拒绝」。
- 内存边界：xlsx / xls / xlsb 的峰值 ≈ 共享字符串表（sharedStrings/SST，字符串总长度）
  + 读缓冲 + 首个 128 行宽度探测缓冲；SpreadsheetML/ODS 只占固定读缓冲。
  行数据本身都是逐行产出，不随文件行数增长（每个解析器都有 5 万行流式单测）。
- 流式读取会先缓冲最多 128 行确定有效列宽（等价于旧实现「裁掉末尾全空列」的语义）；
  之后更宽的行按原样输出（保留数据，由列映射报字段数错误）。

## 8. 已知边界

- 只读：不支持写回 xlsx/xls/xlsb/ods；导出 Excel 仍是 SpreadsheetML 2003（.xls）。
- 单文件 > 5 GB：流式格式会给 warning；若将来出现必须整表载入的读取路径，会直接拒绝（见 §7 大文件护栏）。
- 加密/损坏的工作簿在 inspect/preview 阶段返回中文错误（「无法读取 ... 文件可能已损坏、被密码保护」）。
- 公式单元格读取 Excel 缓存的计算结果；没有缓存时为 NULL。
- 隐藏工作表不参与选择；默认选第一张可见表。
- SpreadsheetML 仅支持 UTF-8 文本（Excel 2003 XML 的常见编码）。
- 一次常规导入只导入一张工作表；需要一次建多张表请用「从文件建表」向导。
- Excel 的时间单元格是「一天内的比例」，calamine 会落在 1899-12-31，读取层据此输出
  `HH:MM:SS`；跨天时长（`[h]:mm:ss`）也输出 `HH:MM:SS`（小时可超过 24）。

## 9. 测试与 fixtures

- fixtures：`desktop/rust/tests/fixtures/excel_multi.xlsx`、`excel_multi.xls`
  （3 个可见表 + 隐藏表；数字/日期/时间/布尔/中文/NULL），以及 Lead 的多表
  `relational_multi.xlsx`（users/categories/products/orders/order_items）。
  生成脚本与复现命令见 [fixtures/README.md](../rust/tests/fixtures/README.md)。
- Rust 单测：`cd desktop/rust && cargo test --offline --lib`，Excel 用例在
  `importer.rs` 的 `excel_tests`：
  - 旧版：inspect 识别、选表、skip_rows、原生类型预览、schema 推断、SpreadsheetML
    多表、validate/probe、SQLite 真库 execute + 按行进度；
  - 第 51 轮流式：测试内用 zip writer 合成 2 万行 xlsx（inspect/preview/validate
    行数与进度、sheet 选择、schema）+ execute 2000 行到 SQLite；合成 ODS 预览/选表；
    SpreadsheetML 大文件（8 MB+）单次扫描统计；无 dimension 的 xlsx 进度退化；
        xls(BIFF8) / xlsb 流式（真实 fixture 三表、日期/时间/布尔/NULL、5 万行合成表）；
    streaming 全为 true，不再有「暂未流式」warning。
- 集成用例：`cargo test --offline --test data_import --test export_import_round_trip`。
- 手工验证（本轮）：用户真实 `student_course.xls`（SpreadsheetML，8 行数据）与
  `relational_multi.xlsx`（5 表）inspect/preview/validate 均为流式且行数/类型正确。
