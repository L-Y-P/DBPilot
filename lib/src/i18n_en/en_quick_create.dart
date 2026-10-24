import 'rewrite.dart';

/// English for the round-50 quick-create wizard (from-file table creation).
///
/// Keys are the **rendered** Chinese strings; values are the English UI copy.
/// Only user-visible copy belongs here; SQL types, table names and backend
/// errors are never listed.
///
/// Lead: wire this file into lib/src/i18n_literals.dart —
///
///   import 'i18n_en/en_quick_create.dart';
///   ...enQuickCreate,            // inside the _exact map literal
///   ...rewritesQuickCreate,      // inside the _rewrites list literal
const Map<String, String> enQuickCreate = <String, String>{
  // ---- wizard chrome / footer buttons -----------------------------------
  '从文件建表': 'Create tables from file',
  '选择文件': 'Choose file',
  '重新选择文件': 'Choose another file',
  '工作表与字段': 'Worksheets and columns',
  '创建并导入': 'Create and import',
  '建立关联': 'Connect tables',
  '下一步': 'Next',
  '上一步': 'Back',
  '完成': 'Done',
  '关闭': 'Close',
  '创建表并导入': 'Create tables and import',
  '创建并导入…': 'Creating and importing…',
  '下一步：建立关联': 'Next: connect tables',
  '重试失败的表': 'Retry failed tables',
  '取消导入': 'Cancel import',
  '重新推断': 'Re-infer',
  '未知': 'Unknown',
  // ---- step 1: file and worksheets --------------------------------------
  '数据文件': 'Data file',
  '文件名': 'File name',
  '格式': 'Format',
  '大小': 'Size',
  '路径': 'Path',
  '选择要用于建表的数据文件': 'Choose a data file to create tables from',
  '选择 CSV / Excel / JSON 等数据文件，直接建表并导入数据（不经过 SQL）。':
      'Choose a CSV / Excel / JSON data file to create tables and import the data directly (no SQL involved).',
  '该格式没有工作表概念：整个文件创建 1 张表，表名默认取文件名。':
      'This format has no worksheets: one table is created from the whole file, named after the file.',
  '文件含 1 个工作表，将创建 1 张表（表名默认取文件名）。':
      'The file has 1 worksheet; one table will be created (named after the file).',
  '全部导入（每张工作表建一张表）':
      'Import all (one table per worksheet)',
  // ---- detected format labels (mirror the importer's format list) ------
  '分隔文本（CSV / TSV / 自定义分隔符）':
      'Delimited text (CSV / TSV / custom separator)',
  'JSON 数组': 'JSON array',
  'JSON Lines（每行一个 JSON）': 'JSON Lines (one JSON per line)',
  'XML（<rows> / <row> / <col>）': 'XML (<rows> / <row> / <col>)',
  'HTML 表格（<table>）': 'HTML table (<table>)',
  'Excel（SpreadsheetML .xls）': 'Excel (SpreadsheetML .xls)',
  'Excel 工作簿（.xlsx）': 'Excel workbook (.xlsx)',
  'Excel 97-2003（.xls）': 'Excel 97-2003 (.xls)',
  'Excel 二进制工作簿（.xlsb）': 'Excel binary workbook (.xlsb)',
  'OpenDocument 表格（.ods）': 'OpenDocument spreadsheet (.ods)',
  'Markdown 表格（| a | b |）': 'Markdown table (| a | b |)',
  // ---- step 2: per-table columns ---------------------------------------
  '确认每张表的表名与字段。类型由文件内容自动推断（可改），整数主键建表时自动自增。':
      'Review each table name and its columns. Types are inferred from the data (editable); integer primary keys become auto-increment.',
  '表名': 'Table name',
  '跳过开头行数': 'Skip leading rows',
  '首行是列名': 'First row is the header',
  '修改「首行是列名 / 跳过行数」后会自动重新推断；也可以点「重新推断」按当前设置刷新。':
      'Changing the header / skipped rows re-infers the columns automatically; press Re-infer to refresh with the current settings.',
  '源列名': 'Source column',
  '列名': 'Column name',
  '类型': 'Type',
  '主键': 'Primary key',
  '允许空': 'Allow NULL',
  '示例值': 'Sample values',
  '文件里没有可导入的列': 'The file has no importable columns',
  '主键：每张表最多 1 个；整数主键建表时自动自增。字段可空：主键列强制非空。':
      'Primary key: at most one per table; integer keys become auto-increment. Nullable is forced off for the key column.',
  // ---- step 3: run status ----------------------------------------------
  '逐表执行：先 CREATE TABLE，再按前一步的映射导入数据。失败会停下，已创建的表保留，可以重试。':
      'Each table is created first, then its rows are imported with the mapping from the previous step. On failure the run stops, created tables are kept and you can retry.',
  '执行计划': 'Execution plan',
  '正在执行…': 'Running…',
  '待创建': 'Pending',
  '建表中': 'Creating',
  '导入中': 'Importing',
  '失败': 'Failed',
  // ---- step 4: relations ------------------------------------------------
  '关系修改会立即写入数据库；也可以稍后从数据库页的「关系图」入口再配置。':
      'Relationship changes are written to the database immediately; you can also configure them later from the database page (Relationships).',
  '没有已创建的表可以建立关联。': 'There is no created table to connect.',
  // ---- footer hints -----------------------------------------------------
  '选择数据文件后点击「下一步」分析格式与工作表。':
      'Choose a data file, then continue to analyze its format and worksheets.',
  '先确认每张表的表名与字段，再创建表并导入。':
      'Review the table names and columns before creating and importing.',
  '全部完成。可以继续建立表之间的关联。':
      'Everything is done. Continue to connect the tables.',
  '创建与导入是逐表执行的，失败会停下并保留已创建的表。':
      'Tables are created and imported one by one; on failure the run stops and keeps what was created.',
  '点击「完成」返回数据库页。': 'Press Done to return to the database page.',
  '正在分析文件…': 'Analyzing the file…',
  '正在推断字段类型…': 'Inferring column types…',
  // ---- entry points (database page + create-table designer header) ------
  '选择 CSV / Excel 等数据文件，按工作表快速建表并导入数据':
      'Choose a CSV / Excel data file to quickly create tables (one per worksheet) and import the data',
  '选择一个数据文件，按工作表批量建表并导入数据':
      'Choose a data file to create tables from its worksheets and import the data',
  '关系图': 'Relationships',
  '查看并编辑表之间的外键关系':
      'View and edit foreign-key relationships between tables',
};

/// Interpolated prompts of the quick-create wizard.
final List<Rewrite> rewritesQuickCreate = <Rewrite>[
  // Card title: 表 1 · sales.xlsx / 表 2 · Sheet1.
  Rewrite(RegExp(r'^表 (\d+) · (.+)$'), (m) => 'Table ${m[1]} · ${m[2]}'),
  // Card action: 工作表：Sheet1.
  Rewrite(RegExp(r'^工作表：(.+)$'), (m) => 'Worksheet: ${m[1]}'),
];
