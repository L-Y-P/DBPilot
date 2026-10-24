import '../i18n_literals.dart';
import 'rewrite.dart';

/// English for the shell, shared widgets, app bootstrap and connection-independent
/// chrome (dialogs, SQLite file actions, import rule summaries, data grids).
///
/// Keys are the **rendered** Chinese strings; values are the English UI copy.
/// Only user-visible copy belongs here — never identifiers, SQL or user data.
const Map<String, String> enCommon = <String, String>{
  // ---- shell / navigation ------------------------------------------------
  '中文': 'Chinese',
  '备份': 'Backup',
  '模式名': 'Schema name',
  '切换到中文界面': 'Switch to Chinese',
  '切换到英文界面': 'Switch to English',
  // ---- shared widgets ----------------------------------------------------
  '关闭提示': 'Dismiss',
  '完整内容请双击查看或复制': 'Double-click to view or copy the full content',
  // ---- app state ---------------------------------------------------------
  '初始化失败': 'Initialization failed',
  '未连接': 'Not connected',
  '模式': 'Schema',
  '模式（schema）': 'Schema',
  '数据库': 'Database',
  // ---- api / permission copy --------------------------------------------
  '返回值格式无效': 'Invalid response format',
  '请让数据库管理员': 'Ask the database administrator',
  '请让管理员': 'Ask the administrator',
  '提示：这是数据库账号自身的权限限制，不是应用出错。':
      'Note: this is a permission limit of the database account itself, not an application error.',
  '请让数据库管理员为该账号授权，或在连接管理里改用有权限的账号。':
      'Ask the database administrator to grant the privilege, or switch to an account that has it in the connection manager.',
  '权限不足': 'Insufficient privileges',
  // ---- dialogs -----------------------------------------------------------
  '高级选项': 'Advanced options',
  '模板': 'Template',
  '默认 template1；改编码/排序规则时通常选 template0':
      'Defaults to template1; choose template0 when changing encoding or collation',
  '编码': 'Encoding',
  '留空 = 服务端默认；例如 UTF8': 'Blank = server default; for example UTF8',
  '留空 = 服务端默认；例如 en_US.UTF-8': 'Blank = server default; for example en_US.UTF-8',
  '属主': 'Owner',
  '留空 = 当前用户': 'Blank = current user',
  '留空 = pg_default': 'Blank = pg_default',
  '编码/排序规则与模板不兼容时 PostgreSQL 会拒绝创建；此时请把模板改为 template0。':
      'PostgreSQL refuses to create the database when the encoding or collation is incompatible with the template; in that case set the template to template0.',
  '（默认）': '(default)',
  '将创建 PostgreSQL 数据库（CREATE DATABASE）。库中的模式请在数据库页用「新建模式」创建。':
      'Creates a PostgreSQL database (CREATE DATABASE). Create its schemas from the database page with "New schema".',
  // ---- SQLite actions ----------------------------------------------------
  'SQLite 的数据库就是一个文件。选择要执行的操作：':
      'A SQLite database is a file. Choose what to do:',
  '新建数据库文件': 'New database file',
  '输入文件名，选择保存目录，创建后立即打开。':
      'Enter a file name, choose a folder, and the file opens right after it is created.',
  '导入数据库文件': 'Import database file',
  '选择一个或多个已有的 .sqlite / .db 文件，分别作为连接打开。':
      'Pick one or more existing .sqlite / .db files and open each as a connection.',
  '导入数据库目录': 'Import database folder',
  '选择一个目录，递归找出其中的所有数据库文件。':
      'Pick a folder; every database file inside it is found recursively.',
  '选择数据库文件的保存目录': 'Choose the folder for the database file',
  '无法打开文件夹选择器': 'Cannot open the folder picker',
  '文件名': 'File name',
  '保存目录': 'Folder',
  '初始化 SQL（可选）': 'Initialization SQL (optional)',
  '文件会直接创建在所选目录里；目录不可写或没有权限时，系统会返回具体错误。':
      'The file is created directly in the chosen folder; the system reports the exact error when the folder is not writable.',
  '无法打开文件选择器': 'Cannot open the file picker',
  '选择包含 SQLite 数据库的文件夹': 'Choose the folder containing SQLite databases',
  '导入失败': 'Import failed',
  '部分文件未导入': 'Some files were not imported',
  // ---- SQLite pickers (native dialog titles) -----------------------------
  '选择 SQLite 数据库文件（可多选）': 'Choose SQLite database files (multiple allowed)',
  '选择包含 SQLite 数据库的文件夹（会递归查找）':
      'Choose the folder containing SQLite databases (searched recursively)',
  '选择文件夹': 'Choose folder',
  '保存文件': 'Save file',
  '选择要导入的数据文件': 'Choose the data file to import',
  '选择 SQLite 数据库文件': 'Choose a SQLite database file',
  '选择文件': 'Choose file',
  // ---- import rules ------------------------------------------------------
  '无包裹符': 'No wrapper',
  '字典/JSON 记录': 'Dictionary / JSON records',
  '首行为列名': 'First row holds column names',
  '无列名（按位置）': 'No column names (by position)',
  // ---- data grid ---------------------------------------------------------
  '无结果': 'No results',
  '保存会把该值写回数据库。': 'Saving writes this value back to the database.',
  'CSV 已复制到剪贴板': 'CSV copied to clipboard',
  'JSON 已复制到剪贴板': 'JSON copied to clipboard',
  // ---- generic -----------------------------------------------------------
  '保存': 'Save',
  '取消': 'Cancel',
  '删除': 'Delete',
  '关闭': 'Close',
  '刷新': 'Refresh',
  '确定': 'OK',
  '未知': 'Unknown',
  '未选择': 'Not selected',
  '（无）': '(none)',
  '（全部）': '(all)',
  '当前数据库': 'Current database',
  '（可选）': '(optional)',
  // ---- leftovers found by the coverage audit ---------------------------
  'DBPilot 启动失败': 'DBPilot failed to start',
  '没有': 'no',
  '所需': 'required',
  '或到「表」页使用导出。': 'or use Export on the table page.',
  '或到「表」页使用导出获取完整数据。': 'or use Export on the table page for the complete data.',
  '\\n请让数据库管理员为该账号授权，或改用有权限的账号连接；':
      '\\nAsk the database administrator to grant it to the account, or connect with an account that has it;',
  '确定应用以下修改吗？': 'Apply the following changes?',
  '\\n…（预览已截断）': '\\n… (preview truncated)',
  '通过向导逐步设置一条数据怎么切分、列怎么识别，先试插入一条并校验整个文件，通过后再分批写入。':
      'Step through the wizard to define how one record is split and how columns are detected; one row is trial-inserted and the whole file validated before batching.',
  '选择 UTF-8 的 .sql 脚本（支持 DELIMITER 指令），从磁盘流式读取并逐条执行；':
      'Choose a UTF-8 .sql script (DELIMITER supported); it is streamed from disk and executed statement by statement;',
  '大文件不会整个载入内存，执行过程中可取消。':
      'large files are never loaded into memory and the run can be cancelled.',
  '例如 total_amount': 'for example total_amount',
  // Delimiter / escape examples in the import wizard.
  '例如 [）': 'for example [)',
  '例如 ]': 'for example ]',
  'CSV/JSON 引号': 'CSV/JSON quote',
  '例如 \\n 或 ,': 'for example \\n or ,',
  '例如 , 或 \\t': 'for example , or \\t',
  '可留空，例如 \\\\': 'Optional, for example \\\\',
  '例如 \\N': 'for example \\N',
  '按括号层级识别记录：包裹在 [] / {} 内部的记录分隔符不会被切开（JSON 推荐）':
      'Split by bracket depth: record separators inside [] / {} are not split (recommended for JSON)',
  // Whole-string prompts that are concatenated at the call site are built with
  // pickText() instead; only strings that render on their own belong here.
  '\n请让数据库管理员为该账号授权，或改用有权限的账号连接；':
      '\nAsk the database administrator to grant it to the account, or connect with an account that has it;',
  '\n…（预览已截断）': '\n… (preview truncated)',
  '请填写表名': 'Enter a table name',
  '请至少填写一个字段名': 'Enter at least one column name',
};

/// Patterns for the interpolated prompts of this area, matched against the
/// rendered string (see [Rewrite]).
final List<Rewrite> rewritesCommon = <Rewrite>[
  // Data grid column chooser and selection counters.
  Rewrite(RegExp(r'^列 \((\d+)/(\d+)\)$'),
      (m) => 'Columns (${m[1]}/${m[2]})'),
  Rewrite(RegExp(r'^已选 (\d+)$'), (m) => '${m[1]} selected'),
  Rewrite(RegExp(r'^本页 (\d+) 行$'), (m) => '${m[1]} rows on this page'),
  // Shell: connect privilege and SQLite attach overflow.
  Rewrite(RegExp(r'^当前账号没有连接数据库 (.+) 的权限$'),
      (m) => 'The current account has no permission to connect to database ${m[1]}'),
  Rewrite(RegExp(r'^(.+)（无连接权限）$'),
      (m) => '${m[1]} (no connect privilege)'),
  Rewrite(RegExp(r'^另有 (\d+) 个数据库未打开$'),
      (m) => '${m[1]} more databases are not opened'),
  Rewrite(RegExp(r'^（最多同时附加 (\d+) 个）$'),
      (m) => ' (at most ${m[1]} attached at once)'),
  // SQLite bulk import toasts.
  Rewrite(RegExp(r'^已导入 (\d+) 个数据库连接$'),
      (m) => 'Imported ${m[1]} connection(s)'),
  Rewrite(RegExp(r'^无法打开文件夹选择器：(.+)$'),
      (m) => 'Cannot open the folder picker: ${m[1]}'),
  // Dialog titles assembled from a database/schema noun.
  Rewrite(RegExp(r'^新建(数据库|模式)$'),
      (m) => m[1] == '数据库' ? 'New database' : 'New schema'),
  Rewrite(RegExp(r'^(数据库|模式)已创建$'),
      (m) => m[1] == '数据库' ? 'Database created' : 'Schema created'),
  // Import rule summaries (see import_rules.dart).
  Rewrite(RegExp(r'^包裹符 \[(.+) … (.+)\]$'),
      (m) => 'Wrapper [${m[1]} … ${m[2]}]'),
  Rewrite(RegExp(r'^自定义包裹 · (.+) · 记录分隔符 "(.*)"$'),
      (m) =>
          'Custom wrapper · ${trLiteral(m[1]!)} · record separator "${m[2]}"'),
  Rewrite(RegExp(r'^每行一条 · 记录分隔符 "(.*)"$'),
      (m) => 'One record per line · record separator "${m[1]}"'),
  Rewrite(RegExp(r'^分隔符 "(.*)" · (.+)$'),
      (m) => 'Separator "${m[1]}" · ${trLiteral(m[2]!)}'),
  Rewrite(RegExp(r'^第 (\d+) 条，$'), (m) => 'record ${m[1]}, '),
  Rewrite(RegExp(r'^第 (\d+) 行（第 (\d+) 条，字节 (\d+)）$'),
      (m) => 'Line ${m[1]} (record ${m[2]}, byte ${m[3]})'),
  Rewrite(RegExp(r'^第 (\d+) 行（字节 (\d+)）$'),
      (m) => 'Line ${m[1]} (byte ${m[2]})'),
  // Import issue label: position plus the backend's reason.
  Rewrite(RegExp(r'^第 (\d+) 行（第 (\d+) 条，字节 (\d+)）：(.*)$', dotAll: true),
      (m) => 'Line ${m[1]} (record ${m[2]}, byte ${m[3]}): ${trLiteral(m[4]!)}'),
  Rewrite(RegExp(r'^第 (\d+) 行（字节 (\d+)）：(.*)$', dotAll: true),
      (m) => 'Line ${m[1]} (byte ${m[2]}): ${trLiteral(m[3]!)}'),
  // Snippet prefix inside an import issue row.
  Rewrite(RegExp(r'^内容：(.*)$', dotAll: true), (m) => 'Content: ${m[1]}'),
  // Pagination on the table browser and result grids. The single-page form is
  // rendered while the row count is still loading (pages == null), and an
  // untranslated 「第 N 页」 there made the English UI test flake under load.
  Rewrite(RegExp(r'^第 (\d+) 页$'), (m) => 'Page ${m[1]}'),
  Rewrite(RegExp(r'^第 (\d+) / (\d+) 页$'),
      (m) => 'Page ${m[1]} / ${m[2]}'),
  Rewrite(RegExp(r'^显示 (\d+) / (\d+) 行$'),
      (m) => 'Showing ${m[1]} / ${m[2]} rows'),
  Rewrite(RegExp(r'^行数：(\d+)$'), (m) => 'Rows: ${m[1]}'),
  Rewrite(RegExp(r'^显示 (\d+) / (\d+) 项$'),
      (m) => 'Showing ${m[1]} / ${m[2]} items'),

  // Tooltip text clamped by tooltipText().
  Rewrite(RegExp(r'^(.+)…（其余 (\d+) 个字符未显示；(.*)）$'),
      (m) => '${m[1]}… (${m[2]} more characters not shown; ${m[3]})'),
];
