import 'rewrite.dart';

/// English for the data import wizard, rule summaries and the SQL console / file
/// runner.
///
/// Keys are the **rendered** Chinese strings; values are the English UI copy.
/// Only user-visible copy belongs here — never identifiers, SQL or user data.
const Map<String, String> enImport = <String, String>{
  '选择要导入的数据文件': 'Choose the data file to import',
  '读取规则': 'Read rules',
  '字段与映射': 'Fields and mapping',
  '执行导入': 'Run import',
  '请先设置至少一列映射': 'Set at least one column mapping first',
  '校验任务启动失败': 'Could not start the validation task',
  '导入任务启动失败': 'Could not start the import task',
  '数据导入向导': 'Data import wizard',
  '上一步': 'Back',
  '下一步': 'Next',
  '完成': 'Done',
  '先选择一个数据文件；大文件会流式读取，不会一次载入内存。': 'Choose a data file first; large files are streamed and never loaded into memory at once.',
  '确认格式无误后进入下一步设置读取规则。':
      'Once the format looks right, continue to set the read rules.',
  '读取规则校验通过，可以继续。': 'The read rules validated; you can continue.',
  '设置一条完整数据如何切分，预览后校验整个文件；校验通过才能继续。': 'Define how one record is split, preview it, then validate the whole file; you can continue once validation passes.',
  '试插入与整文件校验都通过，可以开始导入。': 'The trial insert and whole-file validation both passed; you can start importing.',
  '设置字段识别与列映射，先“试插入”，再校验整个文件；两项都通过才能继续。': 'Set field detection and column mapping, run the trial insert, then validate the whole file; both must pass to continue.',
  '导入按批次写入，可随时取消；出错时按选择的策略处理。': 'Rows are written in batches and the import can be cancelled at any time; errors follow the chosen policy.',
  '导入已结束，点击完成返回表页。':
      'The import has finished; press Done to return to the table page.',
  '数据文件': 'Data file',
  '支持 CSV / TSV / 分隔文本 / JSON 数组 / JSON Lines / 自定义包裹与分隔的文本。': 'Supports CSV / TSV / delimited text / JSON arrays / JSON Lines / custom wrappers and separators.',
  '导入前会逐步校验读取规则与字段规则，并试插入一条数据验证列映射。': 'Before importing, the read and field rules are validated step by step and one row is trial-inserted to verify the column mapping.',
  '识别格式': 'Detected format',
  '文件开头预览': 'Beginning of the file',
  '导入方式': 'How the import works',
  '大文件按 64 KiB 分块流式读取，内存占用与文件大小无关；': 'Large files are streamed in 64 KiB chunks, so memory use does not grow with the file;',
  '数据按批次生成多行 INSERT 写入，避免逐行写入造成卡死；': 'rows are written with multi-row INSERT batches instead of one statement per row;',
  '读取规则和字段规则在校验通过前不会写入任何数据。':
      'no data is written until the read and field rules validate.',
  '一条完整数据怎么切分': 'How one record is split',
  '预览第一条': 'Preview the first record',
  '记录方式': 'Record mode',
  '每行一条记录（CSV / JSON Lines）': 'One record per line (CSV / JSON Lines)',
  '自定义包裹 / 记录分隔符（JSON 数组等）':
      'Custom wrapper / record separator (JSON arrays, ...)',
  '包裹开头': 'Wrapper start',
  '例如 [）': 'for example [)',
  '包裹结尾': 'Wrapper end',
  '例如 ]': 'for example ]',
  '记录分隔符': 'Record separator',
  '引号字符': 'Quote character',
  'CSV/JSON 引号': 'CSV/JSON quote',
  '跳过空记录': 'Skip blank records',
  '去除首尾空白': 'Trim surrounding whitespace',
  '按括号层级识别': 'Split by bracket depth',
  '校验读取规则': 'Validate read rules',
  '整个文件都能按当前读取规则切分。': 'The whole file splits with the current read rules.',
  '分割结果回显（给用户参考）': 'Split result (for reference)',
  '表头：': 'Header:',
  '还没有可显示的记录，请检查文件或调整读取规则。':
      'No record to show yet; check the file or adjust the read rules.',
  '每条数据怎么识别字段': 'How fields are detected in each record',
  '字段方式': 'Field mode',
  '分隔文本（逗号/制表符等）': 'Delimited text (comma/tab, ...)',
  'JSON（对象=列名，数组=按位置）': 'JSON (object = column names, array = by position)',
  '字段分隔符': 'Field separator',
  '转义字符': 'Escape character',
  '可留空，例如': 'Optional, for example ',
  '首行是列名': 'First row holds column names',
  '去除字段首尾空白': 'Trim field whitespace',
  '当前识别为“有列名”的数据：每一列按列名映射到目标表列，列名来自表头或 JSON 键。': 'Records are read as named data: each column maps to a target column by name, taken from the header or the JSON keys.',
  '试插入一条（写入后立即回滚）': 'Trial insert one row (rolled back immediately)',
  '读取第一条数据、按映射转换类型并实际插入目标表，然后回滚事务；': 'Reads the first record, converts it with the mapping, inserts it into the target table, then rolls the transaction back;',
  '用于确认列映射与目标表完全匹配，不会留下数据。': 'it confirms the mapping matches the target table and leaves no data behind.',
  '试插入': 'Trial insert',
  '校验整个文件（含字段与类型转换）': 'Validate the whole file (fields and type conversion)',
  '整个文件都能按当前字段规则与列映射解析并转换。': 'The whole file parses and converts with the current field rules and mapping.',
  '自动映射': 'Auto map',
  '添加映射': 'Add mapping',
  '尚未设置列映射。点击“自动映射”按列名或顺序生成，或手动添加。': 'No column mapping yet. Press Auto map to build it from names or position, or add entries manually.',
  '目标列': 'Target column',
  '来源': 'Source',
  '移除这条映射': 'Remove this mapping',
  '空字符串视为 NULL': 'Treat empty strings as NULL',
  '忽略未映射的多余字段': 'Ignore extra unmapped fields',
  'NULL 标记（逗号分隔）': 'NULL tokens (comma separated)',
  '试插入成功：影响 1 行，事务已回滚，目标表没有写入任何数据。': 'Trial insert succeeded: 1 row affected, the transaction was rolled back and nothing was written.',
  '转换后的列值': 'Converted column values',
  '事务内读回的样例行': 'Sample row read back in the transaction',
  '校验中…': 'Validating…',
  '开始校验': 'Start validation',
  '通过': 'Passed',
  '取消校验': 'Cancel validation',
  '请根据下面的位置提示调整规则后重新校验。':
      'Adjust the rules according to the positions below, then validate again.',
  '导入确认': 'Import confirmation',
  '字段规则': 'Field rules',
  '列映射': 'Column mapping',
  '目标表': 'Target table',
  '文件较大：导入会逐块读取并分批插入，界面保持响应，可随时取消。': 'Large file: the import reads in chunks and inserts in batches, the UI stays responsive and it can be cancelled at any time.',
  '导入选项': 'Import options',
  '每批插入行数': 'Rows per batch',
  '500（默认）': '500 (default)',
  '出错处理': 'On error',
  '停止导入并报告位置': 'Stop and report the position',
  '跳过出错行继续导入': 'Skip bad rows and continue',
  '导入结果': 'Import result',
  '导入会按批次写入目标表。过程中可以取消，已写入的批次不会回滚。': 'Rows are written to the target table in batches. The import can be cancelled; batches already written are not rolled back.',
  '取消导入': 'Cancel import',
  '分隔文本（CSV / TSV / 自定义分隔符）': 'Delimited text (CSV / TSV / custom separator)',
  'JSON 数组': 'JSON array',
  // The four structural formats the exporter writes (round 38).
  'XML（<rows> / <row> / <col>）': 'XML (<rows> / <row> / <col>)',
  'HTML 表格（<table>）': 'HTML table (<table>)',
  'Excel（SpreadsheetML .xls）': 'Excel (SpreadsheetML .xls)',
  'XML（<col name="列">值</col>）': 'XML (<col name="col">value</col>)',
  'HTML 表格（<td> 单元格）': 'HTML table (<td> cells)',
  'Excel（SpreadsheetML 单元格）': 'Excel (SpreadsheetML cells)',
  'JSON Lines（每行一个 JSON）': 'JSON Lines (one JSON per line)',
  '未知': 'Unknown',
  '导入 SQL 文件': 'Import SQL file',
  '文件较大：已载入前 128 KB 供查看，直接执行可用「执行 SQL 文件」': 'Large file: the first 128 KB are loaded for review; use Run SQL file to execute it directly',
  '文件较大': 'Large file',
  '可以只载入前 128 KB 查看/编辑，或直接让数据库流式执行整个文件': 'Load only the first 128 KB for review/editing, or let the database stream the whole file',
  '（逐条读取，不占内存，执行过程可在页面上取消）。': ' (executed statement by statement, no full-file memory use, cancellable from the page).',
  '载入前 128 KB': 'Load first 128 KB',
  '直接执行文件': 'Run the file directly',
  '不会载入编辑器；执行过程可取消。': 'The editor is not loaded; the run can be cancelled.',
  'SQL 文件执行': 'SQL file execution',
  '关闭结果': 'Close result',
  '输入 SQL，多条语句用分号分隔（Cmd/Ctrl+Enter 执行）':
      'Enter SQL; separate statements with semicolons (Cmd/Ctrl+Enter runs it)',
  '当前没有正在执行的查询': 'No query is running',
  '中断执行查询的连接（KILL CONNECTION），下次查询自动重连': 'Kill the connection running the query (KILL CONNECTION); the next query reconnects automatically',
  '取消正在执行的查询（pg_cancel_backend）':
      'Cancel the running query (pg_cancel_backend)',
  'SQLite 在应用进程内执行，无法安全取消；点击查看说明': 'SQLite runs inside the application process and cannot be cancelled safely; click for details',
  '小文件载入编辑器；大文件可预览前 128 KB 或直接流式执行': 'Small files load into the editor; large files can be previewed (first 128 KB) or streamed directly',
  '选择 .sql 文件并从磁盘流式执行（不载入编辑器）':
      'Choose a .sql file and stream it from disk (without loading the editor)',
  '执行 SQL 文件到': 'Run SQL file on ',
  // ---- Round 50: worksheet import (Excel / ODS workbooks) -----------------
  '工作表与表头': 'Worksheet and header',
  '建立关联': 'Build relations',
  '下一步：建立关联': 'Next: build relations',
  '完成并返回': 'Done and go back',
  '工作表': 'Worksheet',
  '默认工作表': 'Default worksheet',
  '首行为列名': 'First row holds column names',
  '跳过开头行数': 'Rows to skip at the top',
  '刷新预览': 'Refresh preview',
  '前几行数据预览': 'Preview of the first rows',
  '校验整个文件': 'Validate the whole file',
  '校验整个工作表': 'Validate the whole worksheet',
  '校验整个工作表（含字段与类型转换）':
      'Validate the whole worksheet (fields and type conversion)',
  '整个工作表都能按当前读取规则切分。':
      'The whole worksheet splits with the current read rules.',
  '整个工作表都能按当前字段规则与列映射解析并转换。': 'The whole worksheet parses and converts with the current field rules and mapping.',
  '单元格类型按 Excel 原类型识别（数字 / 日期 / 布尔 / 文本）。':
      'Cell types are read as Excel types (number / date / boolean / text).',
  '字段方式固定为 Excel 单元格：数字 / 日期 / 布尔 / 文本按原单元格类型识别；'
          '分隔符、引号等文本拆分设置不适用于工作簿。':
      'Field mode is fixed to Excel cells: numbers, dates, booleans and text keep their '
      'cell type; delimiter and quote settings do not apply to workbooks.',
  '工作簿是二进制/压缩格式，不显示文件开头预览；下一步可选择要导入的工作表。':
      'A workbook is a binary/compressed container, so there is no text preview of its '
      'beginning; the next step lets you choose a worksheet.',
  '关系修改会立即写入数据库；也可以稍后从数据库页的关系图入口再配置。':
      'Relation changes are written to the database immediately; you can also configure '
      'them later from the relation designer on the database page.',
  '工作表读取规则校验通过，可以继续。': 'The worksheet read rules validated; you can continue.',
  '选择工作表与表头、设置跳过开头的行数，然后校验整个工作表；校验通过才能继续。':
      'Choose the worksheet and header, set how many leading rows to skip, then validate '
      'the whole worksheet; you can continue once it passes.',
  '确认列映射，先“试插入”，再校验整个工作表；两项都通过才能继续。':
      'Confirm the column mapping, run the trial insert, then validate the whole '
      'worksheet; both must pass to continue.',
  '导入已结束：下一步可以建立表间关联，也可以直接关闭。': 'The import has finished: the next step builds table relations, or you can close now.',
  '添加表并连接字段建立外键；关系修改会立即写入数据库。':
      'Add tables and connect fields to create foreign keys; relation changes are written '
      'to the database immediately.',
  '工作表按行流式读取、按批 INSERT 写入（共享字符串表仍需一次加载）；':
      'Worksheets are streamed row by row and written with INSERT batches (the shared '
      'string table is still loaded once);',
  '数字 / 日期 / 布尔 / 文本按原单元格类型识别；校验通过前不会写入任何数据。':
      'Numbers, dates, booleans and text are read as their cell types; nothing is '
      'written until validation passes.',
  '数据按批次生成多行 INSERT 写入；读取规则和字段规则在校验通过前不会写入任何数据。':
      'Rows are written with multi-row INSERT batches; no data is written until the '
      'read and field rules validate.',
  '工作簿较大：按行流式读取并分批插入，内存占用与行数无关（共享字符串表仍需一次加载）；界面保持响应，可随时取消。':
      'Large workbook: rows are streamed and inserted in batches, so memory use does not '
      'grow with rows (the shared string table is still loaded once); the UI stays '
      'responsive and the import can be cancelled.',
  'xlsx / Excel 工作簿': 'xlsx / Excel workbook',
  'xls / Excel 97-2003 工作簿': 'xls / Excel 97-2003 workbook',
  'xlsb / Excel 二进制工作簿': 'xlsb / Excel binary workbook',
  'ods / OpenDocument 表格': 'ods / OpenDocument spreadsheet',
  // The Excel rule summaries (ImportFieldRule.describe) are static copy.
  'Excel 单元格 · 首行为列名': 'Excel cells · first row holds column names',
  'Excel 单元格 · 无列名（按位置）': 'Excel cells · no names (by position)',
};

/// Patterns for the interpolated prompts of this area, matched against the
/// rendered string (see [Rewrite]).
final List<Rewrite> rewritesImport = <Rewrite>[
  // ImportReadRule.describe() for a worksheet: Excel 工作表 "Sheet1" · 跳过开头 2 行
  Rewrite(
    RegExp(r'^Excel 工作表 "(.+)" · 跳过开头 (\d+) 行$'),
    (m) => 'Excel worksheet "${m[1]}" · skip first ${m[2]} row(s)',
  ),
  Rewrite(RegExp(r'^Excel 工作表 "(.+)"$'), (m) => 'Excel worksheet "${m[1]}"'),
  // Import progress for a worksheet, reported by the Rust importer:
  // "工作表 Sheet1 · 第 120/500 行".
  Rewrite(
    RegExp(r'^工作表 (.+) · 第 (\d+)/(\d+) 行(.*)$'),
    (m) => 'Worksheet ${m[1]} · row ${m[2]}/${m[3]}${m[4]}',
  ),
  // inspect() warnings for a workbook (rendered on the first wizard step).
  Rewrite(
    RegExp(r'^检测到 (\d+) 个工作表：当前导入所选工作表；一次导入多个工作表请用「从文件建表」$'),
    (m) =>
        'Detected ${m[1]} worksheets: this import reads the selected one; to import '
        'several at once use "Create tables from file"',
  ),
  Rewrite(
    RegExp(r'^已忽略 (\d+) 个隐藏工作表$'),
    (m) => 'Ignored ${m[1]} hidden worksheet(s)',
  ),
  Rewrite(
    RegExp(r'^工作表已整体载入内存（当前表 (\d+) 行 × (\d+) 列）：超大工作簿会占用较多内存$'),
    (m) =>
        'The worksheet is loaded into memory (${m[1]} rows × ${m[2]} cols): very '
        'large workbooks use a lot of memory',
  ),
];
