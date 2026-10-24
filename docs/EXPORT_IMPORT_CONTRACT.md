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
  "warnings": ["检测到 2 个工作表：当前导入所选工作表；一次导入多个工作表请用「从文件建表」"]
}
```

- 表头启发式与 CSV 一致：首行**全是非空文本**且后面还有数据行时 `fields.header=true`。
- 工作表整体载入内存；当总单元格数 > 10 万或文件 > 20 MB 时 `warnings` 会提示内存占用。
- **大文件轻量识别**：文件 > 8 MB（`INSPECT_LIGHT_EXCEL_BYTES`）时，inspect 只解析第一张
  可见工作表（默认 read/fields 与表头判定需要它），`sheets[]` 里其余工作表只返回
  `{index, name}`（不带 `rows`/`cols`，选中该表后 preview 再加载），并在 `warnings` 里说明
  「文件较大…」。UI 侧按契约「无 rows 只显示名字」处理即可。

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
- Excel 没有字节偏移，进度按行：`percent = 已读行 / 表总行数`，
  `message = "工作表 <名> · 第 N/M 行"`，`bytes/total_bytes` 按行数等比缩放。

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
        "max_length": 0, "primary_candidate": true, "samples": [1, 2, 3] },
      { "name": "姓名", "source": 1, "type": "text", "nullable": true, "max_length": 2 },
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
  （`max_length` 为最大字符数）。
- `name`：表头名（保留中文），空白/引号/控制字符替换为 `_`，重复加 `_2`，空表头为
  `column_N`；DDL 侧负责 quote 标识符。
- `primary_candidate`：列名 `id`（忽略大小写）或表头第一列且非空唯一。
- `samples`：最多 3 个去重后的样本值（`1.0` 这类整数值会规范成 `1`）。
- 非 Excel 格式同样返回 schema（CSV 数字列也能直接建表）。

## 7. 已知边界

- **整表载入内存**：calamine 的 `worksheet_range` 一次读入所选工作表；超大工作簿
  （百万行级）会占用较多内存，inspect 会给 warning。CSV 的「永不整文件读入」约束
  不适用于 Excel 二进制格式。inspect 对 > 8 MB 的文件只加载第一张表（见 §3），
  preview/validate/execute 仍会整表加载所选工作表。
- 只读：不支持写回 xlsx/xls/xlsb/ods；导出 Excel 仍是 SpreadsheetML 2003（.xls）。
- 加密/损坏的工作簿在 inspect/preview 阶段返回中文错误（「无法读取 ... 文件可能已损坏、被密码保护」）。
- 公式单元格读取 Excel 缓存的计算结果；没有缓存时为 NULL。
- 隐藏工作表不参与选择；默认选第一张可见表。
- SpreadsheetML 仅支持 UTF-8 文本（Excel 2003 XML 的常见编码）。
- 一次常规导入只导入一张工作表；需要一次建多张表请用「从文件建表」向导。
- Excel 的时间单元格是「一天内的比例」，calamine 会落在 1899-12-31，读取层据此输出
  `HH:MM:SS`；跨天时长（`[h]:mm:ss`）也输出 `HH:MM:SS`（小时可超过 24）。

## 8. 测试与 fixtures

- fixtures：`desktop/rust/tests/fixtures/excel_multi.xlsx`、`excel_multi.xls`
  （3 个可见表 + 隐藏表；数字/日期/时间/布尔/中文/NULL）。生成脚本与复现命令见
  [fixtures/README.md](../rust/tests/fixtures/README.md)。
- Rust 单测：`cd desktop/rust && cargo test --offline --lib`，Excel 用例在
  `importer.rs` 的 `excel_tests`（inspect 识别、选表、skip_rows、原生类型预览、
  schema 推断、SpreadsheetML 多表、validate/probe、SQLite 真库 execute + 按行进度）。
- 集成用例：`cargo test --offline --test data_import --test export_import_round_trip`。
