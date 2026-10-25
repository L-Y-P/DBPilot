# 第 50 轮设计契约：Excel 导入、快速建表、E-R 关联

> 状态：进行中（用户草图 + 本轮优化后的实现契约）
> 读者：本轮参与实现的 4 个 teammates + 后续接手者
> 相关文件：`desktop/rust/src/importer.rs`、`desktop/lib/src/views/data_import_wizard.dart`、`desktop/lib/src/import_rules.dart`

## 0. 本轮目标（用户原话拆解）

1. **修复导入无法识别 xls**：导入向导的文件选择器把 .xls/.xlsx 等过滤掉了；真实 Excel 文件（Office Open XML .xlsx、BIFF .xls、SpreadsheetML .xls、ODS）也不能作为「多工作表」正确读取。
2. **xls 里有多个表格时，在「读取规则」里让用户选择一个工作表**（常规导入一次导入一张表）。
3. **新建表界面标题位置加「从文件建表」快速建表入口**，复用导入管线（不走 SQL）：多工作表时可选「全部导入」或「自定义选择」；按工作表推断字段类型；创建表 + 导入数据。
4. **字段映射自动推导字段类型**：按前 N 行数据推断 integer/bigint/decimal/float/boolean/date/datetime/time/text，可人工修改。
5. **导入执行后增加「建立关联」步骤（E-R 图，参考 Navicat）**：
   - 用户从当前库添加表（图示里最多 5 张）；
   - 已存在外键自动推导并画出；
   - 拖箭头连线可视化创建外键；
   - 点击箭头设置约束（中文界面用中文表达；英文界面才出现 SQL 关键字）；
   - 同一对表出现多个关系时自动创建中间表（多对多）；
   - 可点击已有关系查看/删除。
6. **用户体验优化**：重命名/隐藏冗余按钮、精简布局（见 §4.3）。

## 1. 硬性协作约定

- **不新增/不修改 FRB 函数签名**（`rust/src/api/**` 的 pub fn 参数与返回类型保持原样），因此**本轮不跑 codegen**、不手改 `rust/src/frb_generated.rs` / `lib/src/rust/**`。所有新能力通过既有 JSON 参数/返回值扩展。
  - 现有入口：`importInspect(path)`、`importPreview(path, params)`、`importValidateStart(params)`、`importExecuteStart(params)`、`importProbe(db, table, params)`、`createTable(db, body, dryRun)`、`alterTable(db, table, body)`、`structure(db, table)`、`builderSchema(db)`、`tables(db)`。
- **Rust 只有 rust-excel 一个人改**；其他人不要跑 `cargo build/test`（会抢 target 锁）。
- 每个 teammate 只写自己名下的文件（见 §7）。需要改别人文件先在群里（send_message 给 lead）说明。
- 新加的中文 UI 文案：桌面端靠 `trLiteral` 对「渲染后的中文」做映射，必须补到对应 `lib/src/i18n_en/en_*.dart`；`pickText(zh, en)` 用于整段提示。新增 en 文件由 Lead 统一接入 `i18n_literals.dart`。
- 各自完成前至少跑：`dart analyze`（0 issue）+ 自己新增/受影响的 `flutter test test/<your>_test.dart`。全量测试由 Lead 串行跑。
- 磁盘只剩 ~5 GB：不要 `cargo clean`、不要 `flutter build`、不要生成 >50 MB 临时文件。

## 2. Rust importer JSON 契约（rust-excel 交付）

### 2.1 `import_inspect(path)` 新增/变化字段

```jsonc
{
  "format": "delimited",          // 新值："xlsx" | "xls" | "xlsb" | "ods"；SpreadsheetML 仍是 "excel"
  "sheets": [                     // 仅 Excel 系格式；其他格式为 null/省略
    { "index": 0, "name": "Sheet1", "rows": 120, "cols": 5 }
  ],
  "sheet": "Sheet1",              // 默认选中的工作表名（第一个可见工作表）
  "read": { "...": "...", "sheet": "Sheet1", "skip_rows": 0 },
  "fields": { "...": "...", "mode": "excel", "header": true },
  "warnings": ["检测到 3 个工作表：当前导入所选工作表；一次导入多个工作表请用「从文件建表」"]
}
```

- 检测顺序（必须按内容优先，扩展名兜底）：
  1. ZIP magic `PK\x03\x04` → 看 `[Content_Types].xml`/内部结构判断 xlsx / xlsb / ods；
  2. OLE2 magic `D0 CF 11 E0 A1 B1 1A E1` → `xls`（BIFF）；
  3. 文本含 `mso-application progid="Excel.Sheet"` 或扩展名 `.xls` 且是 XML → `excel`（SpreadsheetML，本次要支持多 `<Worksheet>`）；
  4. 其余按现有顺序（json/jsonl/xml/html/md/delimited）。
- 真 Excel 文件的 `read`：`mode="line"`（无意义）、`sheet`、`skip_rows`；`fields.mode="excel"`、`header=true`（首行像表头时，沿用现有启发式：首行全文本且与第二行列数一致）。
- SpreadsheetML：解析 `<Worksheet ss:Name="...">` 列表；`ss:Name` 可能带命名空间前缀，取 `Name` 属性即可；无 `ss:Name` 时用 `Sheet1`、`Sheet2`…。一个 Worksheet 的 `<Table>` 内 `<Row>` 为记录，复用现有 `parse_spreadsheet_row` 语义（`<Cell/>` = NULL，`ss:Type` 区分 Number/String/Boolean/DateTime）。

### 2.2 `preview/validate/execute/probe` 规则

- `read.sheet`（string，工作表名；也接受 0-based index）在 Excel 系格式生效；缺省第一张表。**validate/execute 必须与 preview 用同一张表**，Dart 侧会把 `read` 原样透传。
- `read.skip_rows`（usize，默认 0）：跳过工作表最前面的 N 行（用于「第一行是标题、第二行才是表头」这类文件）。header 判定在 skip 之后。
- `fields.mode="excel"`：内部等价于一条 JSON 数组记录（`["a", 1, true, null]`），复用既有 json 解析与 `convert_value`。**preview.records[].text 仍返回可读 JSON**，Dart 直接展示现有「分割结果回显」。
- 表头：`fields.header=true` 时第一条记录作为列名；Excel 分支需要让 header 解析支持 `mode="excel"`（同 `json` 数组规则）。`header=false` 时按位置映射（0,1,2…）。
- 进度：Excel 没有字节偏移，用「已读行 / 表总行数」算 percent；`Progress.message` 给出「工作表 Sheet1 · 第 N/M 行」。取消仍按原 flag 生效。
- `probe_first_row` 也必须支持 sheet（Excel 的试插入）。

### 2.3 `importPreview` 返回新增 `schema`（类型推断，快速建表用）

```jsonc
{
  "sheet_used": "Sheet1",
  "sheets": [ ... ],
  "records": [ ... ],
  "header": ["id", "name", "score"],
  "schema": {
    "sample_count": 500,
    "columns": [
      { "name": "id", "source": 0, "type": "integer", "nullable": false,
        "max_length": 0, "primary_candidate": true, "samples": [1, 2, 3] },
      { "name": "name", "source": 1, "type": "text", "nullable": true, "max_length": 12 },
      { "name": "score", "source": 2, "type": "decimal", "nullable": true }
    ]
  }
}
```

- 推断在 Rust 内做（Excel 有真实单元格类型，比 Dart 猜更准）；扫描最多 1000 条数据记录（header/skip 之后）。
- `type` 取值（跨驱动中性名）：`integer` | `bigint` | `decimal` | `float` | `boolean` | `date` | `datetime` | `time` | `text`。
- 规则：忽略空/NULL（为空的列不能否定类型）；整数列全部在 i32 → integer，否则 bigint；有小数 → decimal（超过 15 位或列名像比率再加 float 也行，简单第一版 decimal）；true/false、是/否、0/1 混合布尔列需 ≥90% 布尔值才判 boolean；字符串按样本模式识别 `YYYY-MM-DD`、`YYYY-MM-DD HH:MM[:SS]`、`HH:MM[:SS]`；数值字符串列若 100% 可解析为数字按数字类型；其余 text（`max_length` 为**建表推荐长度**：样本 ≤127 字符给 255，否则 0 → TEXT，见第 52 轮修订）。
- `name` 用表头名（`header=true`）或 `column_1..N`；**保留中文**，仅把空白/引号/控制字符替换为 `_`，去重（`name`、`name_2`）。（DDL 会 quote 标识符。）
- `primary_candidate` / `primary_candidate_reason`（第 52 轮扩展）：每张表最多一个候选，优先级
  「列名 id」→「最早的样本内唯一整数列（学号/订单号）」→「第一列且样本内唯一的短文本列」；
  同时新增 `unique` 字段。Dart 侧默认勾选；非 id 来源的候选会提示「按样本猜的主键，可改」。
- `preview` 请求参数增加可选 `infer: true`（Dart 快速建表用）；不传时也返回 schema（成本可控，1000 行），但 `limit` 语义不变。旧调用方只多一个字段，兼容。

### 2.4 实现建议（rust-excel 自行决定，但需满足契约）

- 依赖：`calamine = { version = "0.26", features = ["dates"] }`（纯 Rust，支持 xlsx/xls/xlsb/ods）。calamine 用 `worksheet_range` 一次载入整张表；文件很大时在 inspect warnings 里提示「工作表已整体载入内存」。不要自己写 BIFF 解析。
- 数据源抽象：`RecordScanner` 增加 enum 外层（`Text(RecordScanner)` | `Excel(ExcelScanner)`），Excel 每行生成 JSON 数组文本（`serde_json::to_string`），`fields.mode="excel"`；`parse_row/header_of` 的 `"excel"` 分支复用 `"json"`。
- SpreadsheetML 多表：读取文件文本 → 切 `<Worksheet>` → 每张表复用现有 `</Row>` 记录切分 + `parse_spreadsheet_row` → 转成同样的行值结构。
- Excel 值转换：Int→number、Float→number（整数值的 float 输出整数）、String→string、Bool→bool、DateTime→`YYYY-MM-DD HH:MM:SS` 字符串（整点 00:00:00 的日期输出 `YYYY-MM-DD` 以便推断 date）、Error/Empty→null、DateTimeIso/DurationIso 保留字符串。
- 空行、末尾全空列要裁掉；列数按表头/最大列对齐，缺列补 null。
- 测试 fixture：用 DSH 自带 Python 生成**一次**并提交到 `desktop/rust/tests/fixtures/`：
  - `excel_multi.xlsx`、`excel_multi.xls`（2-3 个工作表，含数字/日期/布尔/中文文本/NULL 空单元格）
  - 生成方式示例：openpyxl / xlsxwriter 生成 xlsx；`pip install --target /tmp/xlwt_pkg xlwt` + `PYTHONPATH` 生成 xls（本机已验证可行）。生成脚本放 `desktop/rust/tests/fixtures/gen_fixtures.py` 并在 README 注释中写复现命令。
  - 测试覆盖：inspect 识别 xlsx/xls/多表；sheet 选择（每张表数据不同）；skip_rows；schema 推断；validate/execute 到 SQLite 真库；多表 SpreadsheetML；旧格式（csv/xml/xls SpreadsheetML 单表）不回归；单测保持 163+ 全绿。

## 3. 常规导入向导（import-ux 交付）

### 3.1 文件选择器（立即修复）

`lib/src/sqlite_sources.dart` 的 `dataFileExtensions` 补全：`xls, xlsx, xlsm, xlsb, ods, xml, html, htm, md, markdown`（保留原有 csv/tsv/txt/tab/json/jsonl/ndjson/log/dat/data）。picker 标题/提示文案同步。

### 3.2 步骤结构（5 步）

`_stepTitles = ['选择文件', '读取规则', '字段与映射', '执行导入', '建立关联']`

- Excel 系格式时第 2 步标题动态显示「工作表与表头」，其余格式仍「读取规则」。
- 第 5 步只在 `_executeResult != null`（导入已结束）后可进入；footer 在导入成功后把主按钮改成「下一步：建立关联」，第 5 步主按钮「完成并返回」。
- 后两步骤可点击回退（沿用 step chip）。

### 3.3 Excel 分支 UI（第 2 步）

- 顶部 Card「工作表」：`SelectBox` 列出 `inspect.sheets[].name`（带行数/列数，若 inspect 未给 rows 则只显示名字）；选中变化 → 重新 preview/校验（`_resetValidation`）。多表时显示 `AlertBox`（warn）：「文件含 N 个工作表，本次只导入所选工作表；要一次导入多个工作表请用数据库页的『从文件建表』」。
- 「表头」CheckBox + 「跳过开头 N 行」数字输入（0-20，仅 Excel）。两者变化 → 重新 preview。
- **隐藏**：记录方式/包裹符/记录分隔符/引号/层级/跳过空记录/去除空白 等文本切分控件（Excel 用不到）；字段方式下拉隐藏（固定 Excel）。
- 保留「分割结果回显」（Excel 记录文本是 JSON 数组，现组件可显示）；标题改为「前几行数据预览」。
- 预览按钮命名：「刷新预览」（原「预览第一条」）。校验按钮：「校验整个工作表」（原「校验读取规则」；保留字段校验的「校验整个文件」→ Excel 时「校验整个工作表」）。
- 第 1 步「识别格式」显示新格式标签：xlsx/Excel 工作簿、xls/Excel 97-2003、SpreadsheetML、ODS。
- 第 1 步「导入方式」说明卡：Excel 时改为适合 Excel 的文案（整表载入内存、按批 INSERT、校验前不写数据）。
- 第 2/3 步对 Excel 显示「单元格类型按 Excel 原类型识别（数字/日期/布尔/文本）」小字提示。

### 3.4 第 5 步「建立关联」

- 嵌入 `RelationDesigner`（见 §5 接口）：`database: widget.database, initialTables: [widget.table], height: 440, compact: true`。
- 隐藏底部「完成」以外的流程按钮；提示「关系修改会立即写入数据库；也可以稍后从数据库页关系图入口再配置。」（入口由 quick-create 负责，不要求常规向导添加）。
- 关闭向导时照旧 `onImported` 刷新。

### 3.5 按钮/文案调整（用户点名）

| 现在 | 改为 | 说明 |
| --- | --- | --- |
| 底部「取消」 | 「关闭」 | 它是关闭整个对话框，不是取消当前步骤 |
| 步骤内与底部重复的「开始导入」 | 只保留底部主按钮 | 执行卡片里删掉重复按钮，保留进度/取消导入 |
| 「预览第一条」 | 「刷新预览」 | 实际会重新预览多条 |
| 「校验读取规则」 | 「校验整个文件」/ Excel「校验整个工作表」 | 说明校验范围 |
| 导入完成底部「完成」 | 「完成并返回」 | 明确去向 |
| 「上一步」 | 不变 | |
| 第 1 步「导入方式」长说明 | Excel 时换文案；非 Excel 保留但压缩为 2 行 | 减少首屏噪音 |

### 3.6 测试

- `test/import_rules_test.dart`：`ImportReadRule` 新增 `sheet`/`skipRows` 的 toJson/fromJson/describe。
- FFI：`test/data_import_ffi_test.dart` 增加 xlsx fixture（复用 rust fixture 或测试内生成 SpreadsheetML 双表文本）→ inspect 出现 sheets、preview 指定 sheet 数据不同、导入指定 sheet 行数正确；旧 CSV 用例不回归。
- 向导 UI：至少覆盖 Excel 分支显示工作表下拉与隐藏分隔符控件（可只测 `DataImportWizardDialog` 在 fake inspect 下的 builder 函数；若难注入，改为 FFI 驱动真实向导 widget）。

## 4. 快速建表向导（quick-create 交付）

### 4.1 入口

- `showCreateTableDialog` 的**标题栏**加按钮「从文件建表」（标题位置 = 新建表对话框 header 右侧、关闭按钮左边）。需要给 `lib/src/widgets.dart` 的 `showModalShell`/`showAppModal` 增加可选 `headerActions: List<Widget>`。
- 点击后：关闭建表设计器 → 打开 `QuickCreateTableWizard`；成功后数据库页刷新表格列表并 notice「已创建 N 张表」。
- 数据库页 PageHead 也加一个次级按钮「从文件建表」便于发现（放「新建表」旁）。
- 新文件 `lib/src/views/quick_create_table_wizard.dart`：

```dart
Future<bool> showQuickCreateTableWizard(
  BuildContext context, {
  required String database,
  required Notice notice,
});
```

### 4.2 四步流程

1. **选择文件**：复用 `pickDataFile` + `Api.importInspect`；显示格式/大小/工作表列表。Excel 多表时单选：
   - 「全部导入（每张工作表建一张表）」；
   - 「自定义选择工作表」（复选）。
   单表/非 Excel 文件固定 1 项（表名默认取文件名去扩展名，可改）。表名实时显示（可编辑放在第 2 步）。
2. **工作表与字段**：每个选中表一张 Card：表名输入、表头 CheckBox、跳过开头行数、字段表格（列：源列名 / 列名（可编辑） / 类型（下拉）/ 主键（单选每表 1 个）/ 允许空 / 示例值），底部「重新推断」（重新 `importPreview(infer:true)`）。类型下拉按驱动给常用类型（复用 `db_options.dart` 的类型列表如果可用），映射见 §4.3。表格超过 12 列时内部滚动/分页（简单纵向滚动即可）。
   - 校验：表名非空且合法（字母/数字/中文/下划线，首字符非数字可选）、全局唯一、至少 1 列、每表最多 1 个主键；不合法禁用下一步并就地标红。
3. **创建并导入**：逐表执行：
   - `Api.instance.createTable(database, body)`（body 见 `CreateTableSpec`：`{name, columns:[{name,type,nullable,primary,auto_increment}], ...}`；`dry_run` 可先取 SQL 展示）；
   - 成功后 `importExecuteStart`（read.sheet + skip_rows + fields.mode=excel + mapping.columns 用表头名或位置；`options.on_error='stop'`），poll job，显示每表进度/行数；
   - 失败即停，已建表保留并明确提示（建议：结果区列出「已创建但未导入」的表 + 重试按钮）。
   - 全部成功 → 底部主按钮「下一步：建立关联」。
4. **建立关联**：嵌入 `RelationDesigner(initialTables: 前 5 张), compact: true`；「完成」返回 true。
- 文案重命名建议：步骤 1 主按钮「分析文件」→「下一步」；步骤 3 主按钮「创建表并导入」；步骤 4「完成」。
- 取消/关闭：导入任务执行中禁用关闭（同常规向导）。

### 4.3 类型映射（Dart 侧，推断 type → 各驱动 SQL 类型）

| 推断 | MySQL | PostgreSQL | SQLite |
| --- | --- | --- | --- |
| integer | INT | INTEGER | INTEGER |
| bigint | BIGINT | BIGINT | INTEGER |
| decimal | DECIMAL(18,2) | NUMERIC(18,2) | NUMERIC |
| float | DOUBLE | DOUBLE PRECISION | REAL |
| boolean | TINYINT(1) | BOOLEAN | INTEGER |
| date | DATE | DATE | TEXT |
| datetime | DATETIME | TIMESTAMP | TEXT |
| time | TIME | TIME | TEXT |
| text | TEXT（max_length>0 且 ≤4000 用 VARCHAR(n)；短文本推荐 255） | TEXT（≤4000 用 VARCHAR(n)） | TEXT |

主键列（第 52 轮修订）：MySQL `BIGINT` / PG `BIGINT` / SQLite `INTEGER`。**AUTO_INCREMENT / IDENTITY /
AUTOINCREMENT 只对「添加自增 id 主键」生成的列或用户在字段页显式勾选「自增」的整数主键打开**；
学号/订单号/工号这类业务编号默认不自增，漏填不会被数据库代填成伪编号。非整数主键：createTable
的 `primary:true` 即可。同表的整数 `*_id`/`*Id` 外键列会同步成主键整数类型（BIGINT/INTEGER），
避免 MySQL 外键 `ERROR 3780`（第 52 轮 P0-1）。

### 4.4 测试 `test/quick_create_table_test.dart`

- 纯逻辑：类型映射、表名/列名清洗、去重。
- FFI（SQLite + CSV 双列文件）：走完 1 个文件 → 建表 + 导入行数正确、类型按推断；多工作表 SpreadsheetML/xlsx fixture → 全部导入建 2 张表；自定义只选 1 张。
- 入口：打开 create-table 对话框能看到 header 按钮（widget 测试）。

## 5. E-R 关联设计器（er-designer 交付）

### 5.1 接口（T2/T4 依赖，先建文件）

```dart
// lib/src/views/relation_designer.dart
class RelationDesigner extends StatefulWidget {
  const RelationDesigner({
    super.key,
    required this.database,
    this.initialTables = const <String>[],
    this.onChanged,
    this.maxTables = 5,
    this.height = 460,
    this.compact = false,
  });
  final String database;
  final List<String> initialTables;   // 预置加入的表（导入的表）
  final Future<void> Function()? onChanged;
  final int maxTables;
  final double height;
  final bool compact;                 // 向导内嵌：更小的工具栏/间距
}

Future<void> showRelationDesigner(
  BuildContext context, {
  required String database,
  List<String> initialTables = const <String>[],
  Future<void> Function()? onChanged,
  Notice? notice,
});
```

- 数据加载：`Api.instance.builderSchema(database)`（表、列、已有外键：`foreign_keys[]{column,ref_table,ref_column}`）；对已加入的表再 `Api.instance.structure(database, table)` 拿真实约束名/引用动作（MySQL: `CONSTRAINT_NAME/DELETE_RULE/UPDATE_RULE`；PG 同；SQLite: `CONSTRAINT_NAME` 为 null、用 `SEQ`）。
- 关系模型与纯逻辑放 `lib/src/views/er_model.dart`（可在无 FFI 的纯 Dart 单测里测）：节点/边、默认约束名、FK payload 生成、junction 定义、箭头命中检测、自动布局。

### 5.2 画布与交互

- 顶部工具栏：[`+ 添加表`]（弹表选择器：搜索 + 复选，已达 5 张/已加入禁用，底部「加入」）；右侧 `已加入 2/5` Pill；空画布有引导文案「添加表后，从字段连接点拖到另一张表的字段即可创建外键」。
- 表卡片：标题（表名 + 移除按钮）；字段行（字段名、类型、PK 标记、FK 标记）；每行右侧一个小圆点连接点（hover 高亮），从连接点按下拖动 → 出现到光标的临时连线 → 松开在另一张表字段行上 → 打开「新建外键关系」对话框。
- 已有外键在加入表时自动画成箭头（只画两端都已加入的）；箭头带小标签（约束名或 `a.id → b.a_id`）；点击箭头命中区域（距线 ≤8 px）打开「外键关系」对话框：显示两端/约束名/引用动作；按钮「删除关系」；新创建的关系同样可删（`alter_table` `drop_foreign_keys:[name]`）。SQLite 不支持 ALTER 增删外键：连接点提示禁用并显示原因，但已有外键仍自动显示（只读）。
- 新外键对话框（中文 UI）：
  - 本表字段、引用表（固定）、引用字段（默认引用表 PK 列，可换）；
  - 删除时 / 更新时：`级联删除 CASCADE`… 用中文选项：「级联（一并删除/更新子行）」「置空（SET NULL，仅可空字段）」「限制（有子行时拒绝）」「不操作」。**中文界面不显示 SQL 关键字**；英文界面显示 `ON DELETE CASCADE` 等（`pickText` / en 映射）。
  - 约束名（默认 `fk_<table>_<column>`，可改）；
  - 底部：「取消」「创建外键」。
- 创建实现：`Api.instance.alterTable(database, localTable, {add_foreign_keys:[{name,columns:[localCol],ref_table,ref_columns:[refCol],on_delete:'CASCADE',on_update:''}]})`；成功后重载该表 structure / 重建边。MySQL 引用列必须是 PK/唯一索引：默认选 PK；用户选了非唯一列时若数据库报错，把错误展示在对话框内。
- 删除实现：`alter_table(database, localTable, {drop_foreign_keys:[name]})`（SQLite 禁用）。
- 中间表（多对多）：当用户在同一对表之间创建**第二条**关系时，弹提示：「两表之间已存在关系。为避免多条外键并存，将自动创建中间表（多对多）；仍要直接添加第二个外键可切换为『直接添加』」。
  - 默认「创建中间表」：生成 `<表1>_<表2>`（去重加 `_rel`/`_2`；用户名可改），列：`id` 主键自增 + `<表1>_id` + `<表2>_id`，两个 FK 指向两端 PK（引用列类型从目标 schema 列类型取，保证 MySQL 类型匹配）；`createTable` 一次事务提交；成功后中间表加入画布。
  - 选「直接添加」→ 走普通外键创建。
  - 判断「已存在关系」= 两端表之间已有一条边（任一方向）；junction 创建后两条边换成 junction 加两条 FK。
- 布局：初始自动布局（网格/环形，卡片宽 ~230，间距 48），节点可拖动（相对 canvas 坐标，保存到 _positions）；画布固定高度 `height`，内容超出时画布内部滚动（只滚动背景/节点整体，交互仍可用）；`compact=true` 时卡片更紧凑。

### 5.3 测试

- 纯 Dart：`test/er_model_test.dart` — 约束名、FK payload、junction 定义（类型/命名/去重）、箭头命中、自动布局、已存在边检测。
- FFI SQLite：`test/er_designer_test.dart` — 建 2-3 张带外键的表 → 打开 RelationDesigner → 自动显示已有关系、添加表上限 5、移除；SQLite 下「创建外键」禁用并给提示；SQLite 下 junction 表通过 createTable 创建成功（FK 内联建表 SQLite 支持）。
- English：新 en 文件 `lib/src/i18n_en/en_relations.dart`（Lead 接入），覆盖画布/对话框/动作选项文案。

## 6. 验收（Lead 负责）

- `cd desktop/rust && cargo test --offline --lib`：旧 163 + 新增全绿；`cargo test --offline --workspace` exit 0。
- `cd desktop && make debug-dylib` 后 `.flutter-sdk/bin/flutter test`：旧 454 + 新增全绿；`dart analyze` 0 issue；`python3 tools/check_api_surface.py` OK。
- 手工/自动化走查：MySQL 与 SQLite 各跑一次「Excel 导入 → 建立关联」；快速建表从建表对话框入口建 2 张表并导入；英文模式无中文残留。
- 新增 `HANDOVER_ROUND50.md` + 更新 `docs/EXPORT_IMPORT_CONTRACT.md`（格式表补 xlsx/xls/ods、工作表选择、类型推断）。

## 7. 文件归属（write scopes）

| 成员 | 文件 |
| --- | --- |
| rust-excel | `desktop/rust/**`（Cargo.toml/lock、src/importer.rs、src/excel*.rs、src/lib.rs、tests/**、tests/fixtures/**）、`desktop/docs/EXPORT_IMPORT_CONTRACT.md` |
| import-ux | `desktop/lib/src/views/data_import_wizard.dart`、`desktop/lib/src/import_rules.dart`、`desktop/lib/src/sqlite_sources.dart`、`desktop/lib/src/i18n_en/en_import.dart`、`desktop/test/import_rules_test.dart`、`desktop/test/data_import_ffi_test.dart` |
| quick-create | `desktop/lib/src/views/quick_create_table_wizard.dart`(新)、`desktop/lib/src/views/create_table_dialog.dart`、`desktop/lib/src/widgets.dart`、`desktop/lib/src/views/database_view.dart`、`desktop/lib/src/i18n_en/en_quick_create.dart`(新)、`desktop/test/quick_create_table_test.dart`(新)、`desktop/test/create_table_dialog_test.dart` |
| er-designer | `desktop/lib/src/views/relation_designer.dart`(新)、`desktop/lib/src/views/er_model.dart`(新)、`desktop/lib/src/i18n_en/en_relations.dart`(新)、`desktop/test/er_model_test.dart`(新)、`desktop/test/er_designer_test.dart`(新) |
| Lead | 本文件、`i18n_literals.dart` 接线、集成冲突协调、全量验证、`HANDOVER_ROUND50.md`、提交 |

> 交叉依赖：import-ux 的第 5 步与 quick-create 的第 4 步都 import `relation_designer.dart`；er-designer 第一件事先把 §5.1 接口骨架提交（可以函数体 TODO），并在完成后通知 Lead。

## 8. 第 50 轮收尾补充（用户第二轮反馈，2026-10-24 晚）

用户原话：
> 处理遗留风险，所以导入使用流式，验证是流式读取验证。关系图中，导入一个表自动推导并导入与他关联的表，同时优化多对多的推导，同时连线没有箭头无法直观看到关系，同时给我一个多表Excel进行测试。

### 8.1 Excel 流式（task-5 / rust-excel）

- **preview / validate / probe / execute 全部流式拉行**：xlsx/xlsm 用 `zip` + `quick-xml` 逐行解析 sheet XML（sharedStrings 一次加载但不再物化单元格矩阵）；SpreadsheetML 流式 XML 扫描；ODS 流式（P1）；`xlsb` 暂留 calamine 兜底 + warning，**旧版 BIFF8 `.xls` 优先流式、否则明确标注兜底**。
- **inspect 不再整表载入**：xlsx 读 `workbook.xml` + rels + 每表 `dimension`（表头只读前两行）；SpreadsheetML 单次扫描取表名/行数；`sheets[]/sheet/read.sheet/skip_rows/schema/fields.mode` 契约不变，可新增 `streaming: true|false` 与兜底 warning。
- 进度保持按行（total 来自 dimension/扫描；未知时给已读行数）。
- 验收：合成 2–5 万行 xlsx 的 preview/validate 行数与选表正确；旧 fixtures 全绿；`docs/EXPORT_IMPORT_CONTRACT.md` 增流式矩阵与兜底说明。

### 8.2 E-R 图（task-6 / er-designer）

1. **箭头**：所有关系边（已有/新建/建议）在目标端画清晰箭头（按贝塞尔切线方向），hover/选中高亮，命中逻辑不变。
2. **自动带入关联表**：加入一张表（含导入第 4 步 seed）时，自动把已有外键的父/子表加入画布到 10 张上限；顶部提示「已自动加入关联表：…」+「撤销自动加入」；避免循环、用户移除后不立即加回。
3. **多对多推导**：
   - 中间表识别（恰好 2 个单列外键指向 2 张不同表）→ 节点徽标「中间表（多对多）」，并在两端实体表间画「多对多 · <中间表>」关系线（可折叠中间表节点）。
   - 新建外键对话框增加「关系类型：多对一（默认）/ 多对多（自动建中间表）」，后者走既有 junction `createTable`。
   - 再次在两表间建关系：已有中间表则提示不要重复；双方连接列都不唯一时默认建议中间表（保留直接添加）。
   - 对画布内的表按列名推导「建议关系」：`<x>_id`/`<x>Id` → 表 `x`/`xs`/`xes` 单列主键；只跳过
     「该本地列已有外键 / 与已有外键相同目标」，所以应用 1 条后其余建议仍保留（第 52 轮 P2-7），
     可以逐步补齐；虚线建议边 + 工具栏「建立建议外键 (N)」批量应用。应用走 `alterTableChecked`，
     失败会逐条显示中文原因，不再静默（第 52 轮 P0-1）。
4. 测试文件：`desktop/rust/tests/fixtures/relational_multi.xlsx`（5 个工作表；画布上限 10）：
   - `users` / `categories` / `products(category_id)` / `orders(user_id)` / `order_items(order_id, product_id)`；
   - 预期建议：products.category_id→categories、orders.user_id→users、order_items.order_id→orders、order_items.product_id→products；
   - `order_items` 恰好两个单列外键 → 识别为中间表，orders↔products 显示多对多。
   - 生成脚本 `gen_relational_multi.py`；用户可直接用 `~/Downloads/DBPilot_多表测试.xlsx`。
5. 英文文案进 `en_relations.dart`；保持 `RelationDesigner`/`showRelationDesigner` 公开接口不变。


## 9. 第 53 轮修订（复测小问题 + 遗留项）

> 来源：`test-report/round52/RETEST_REPORT.md` §4 与 ROUND51 报告 P2-3 / P2-6 / P2-8 / P2-9 / P2-11 / P3。
> 本轮改动均有单测/widget 测试覆盖；全量 Flutter 679 passed / 14 skipped、Rust lib 256 passed / 2 ignored。

### 9.1 导入后端

- **5 GiB 护栏（P2-3）**：`ensure_streamable_with_limit` 只做 file_info + 轻量格式识别（`ExcelKind::is_streaming()` 常量），不再为判定而 `inspect_workbook`（旧实现会在 preview/probe/validate/execute 各完整解析一遍超大文件，xls 甚至会加载整个 SST）。阈值文案统一 GiB（「文件约 5.0 GiB（超过 5 GiB，即 5×1024³ 字节）」）并追加共享字符串表内存峰值风险提示。
- **隐藏工作表（P2-11）**：ODS 支持 `table:display="false"` / `table:visibility="collapse"` / style 继承；SpreadsheetML 支持 `ss:Visibility=Hidden/VeryHidden`；与 xlsx/xls/xlsb 一样排除、计数并给「已忽略 N 个隐藏工作表」。全部工作表都隐藏时给中文提示。
- **错误文案（P3）**：Office 加密的 xlsx/xlsb（OLE2/CFB 包装 EncryptionInfo/EncryptedPackage）→ 中文「已加密，请另存为未加密文件」；CFB 无 Workbook/Book 流 → 中文 + 原始细节；扩展名是 Excel 但内容是 HTML/非 SpreadsheetML XML → 中文「可能是 HTML/文本文件改了扩展名」；路径不存在/无权限 → 中文主文案 + OS 原文。合法 SpreadsheetML（含无 mso-application PI 的 Workbook/Worksheet）不误伤。
- **测试隔离 flake**：`drivers/sqlite` 的临时库文件名改用 `static AtomicUsize` 序号（原 tag+pid+SystemTime::as_nanos() 并行时会撞名），`batch_stream_tests` 并行连跑 5/5 绿。

### 9.2 快速建表向导

- **主键类型显示 == DDL（复测小问题 1）**：新增 `normalizePrimaryColumnTypes()`，在列推断/重新推断/补自增主键后把「整数主键」在计划层就设成驱动主键类型（MySQL/PG BIGINT、SQLite INTEGER）；字段页、类型下拉、tooltip 与最终 DDL 不再出现「显示整数、建表 BIGINT」的割裂。
- **失败重试不再重复预检（复测小问题 2）**：`_retry()` 保留用户已确认的外键预检签名；只有外键集合变化（重新读取/删外键/返回关系步骤）才清空。
- **删外键走 checked（复测小问题 3）**：`_dropForeignKeyAndRetry` 改用 `alterTableChecked`，失败给中文前缀 + 原始细节并保留失败面板。
- **关闭确认（P2-9）**：已建表但未全部导入成功时，关闭改三选一：取消 / 保留已建表并关闭 / 删除本次已建表并关闭（反序删表，失败留在向导并可「清理并重试」）；全部导入成功时仍直接关闭。
- **术语说明（P3）**：标题栏新增「术语说明」入口，打开 `lib/src/glossary.dart` 的术语表（主键/外键/唯一/约束/索引/中间表/多对多/事务/自增/空值，中英双语 + 白话解释）。

### 9.3 E-R 关系图

- **多对多标签避让（P2-6）**：标签锚点由「连线中点」改为沿法线偏移（`m2mLabelAnchorFor`，默认 18px、固定偏上、夹取到画布内），折叠中间表后橙色连线中段保持可见。
- **自动带入提示（P2-8）**：库里没有外键、或候选表到达 10 张上限时，工具栏下方给可关闭提示（`autoIncludeNotice`），并明确「自动带入=已有外键，建议关系=列名推导」是两套机制。
- **删除外键确认（P2-9）**：`confirmDeleteForeignKeyDialog` 二次确认，说明只解除引用约束、不删数据、之后可重建。
- **批量建议确认 + 进度（P3）**：批量（>1 条）先确认「N 条会立即写入数据库、不能一键全部撤销」，执行中显示「正在建立 X/N 条…」；单条点击不确认。
- **术语说明（P3）**：工具栏新增术语表入口。


## 10. 第 54 轮修订（关系列表侧栏 / 删除生成列 / 测试增强）

> 来源：HANDOVER_ROUND53 §5「下一轮候选」。本轮把 P2-5「关系列表」补上，并收尾「生成自增 id 列无法删除」与三处测试增强。

### 10.1 E-R「关系列表」侧栏（P2-5）

- 工具栏新增「关系列表」开关（key er-relation-list-toggle）。打开后面板与画布并排（常规 260px、紧凑/向导内 220px），包含：
  标题「关系列表（N 条）」+ 关闭、搜索框（按表名/列名/展示文本/中间表名，大小写不敏感）、空状态。
- 列表项分三类，徽标区分：**外键**（a.b → c.d）、**建议关系**、**多对多 · 中间表**。点击行为复用画布：
  外键 → 打开现有关系详情（可改约束/删除）；建议 → 单条建立；多对多 → 折叠/展开中间表。
  真实外键行（MySQL/PG 且解析到约束名）右侧提供删除图标，走既有二次确认。
- 纯模型 `relationListItems(...)` 在 er_model，排序稳定（外键 → 建议 → 多对多，再按本表/本列/引用表/引用列），便于单测。
- 列表随图版本号刷新；紧凑模式 440 宽有 widget 测试确认无溢出。

### 10.2 删除自动生成的主键列（P2-9 收尾）

- 字段表格新增第 8 列「操作」：仅 `generated`（「添加自增 id 主键」生成）列显示删除图标；点击后移除该列、重建控制器、重跑类型对齐/规范化，并在 notice 里提示「需要主键时可重新点『添加自增 id 主键』」。
- 纯函数 `removeGeneratedColumn()` 只删 generated 且无源列的同名列（源文件同名普通列不会被误删），删除后表回到无主键状态（不自动挑别的主键），「未设置主键」提示与添加按钮重新出现；再次添加会生成新的 id（重名 id_2）。

### 10.3 测试增强

- **MySQL live**（test/quick_create_fk_live_test.dart）：在 4 条建议外键建立后，真实执行一次 `ALTER TABLE ... DROP FOREIGN KEY`（checked）→ 断言库中剩 3 条、对应建议重新出现 → 再建立一次 → 回到 4 条；覆盖真实 ALTER 成功/删除两条路径。
- **Rust 端到端**（importer.rs cfg(test)）：5 个走公开 `import_inspect` 的用例——PermissionDenied 中文错误（chmod 000 + guard 恢复，root 环境显式跳过）、ODS / SpreadsheetML 隐藏表端到端 warning 与选表、HTML 伪装 .xls、加密 CFB 的 inspect 中文错误。
- **E-R 标签几何**：补充标签矩形与连线的关系断言。注意 axis-aligned 210×18 文本盒在垂直/斜线场景必然与连线横向相交（第 53 轮 18px 法线偏移只保证水平连线不被盖住）；测试对水平场景验证矩形与线段不相交/9px 净空，对垂直/斜线验证锚点在中点法线上且净空 18>半高 9。若要求垂直/斜线也完全不遮挡，需要改标签尺寸/旋转/布局策略（UX 决策，未做）。

