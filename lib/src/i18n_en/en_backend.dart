import '../i18n_literals.dart';
import 'rewrite.dart';

/// English for the driver/backend error copy surfaced through ApiException.
///
/// The Rust core writes its user-facing errors in Chinese (it is the same text
/// the web build returned). In English mode those messages would otherwise be
/// the last Chinese left in the UI, so the common ones are translated here.
///
/// Keys are the **rendered** Chinese strings; values are the English UI copy.
/// Only user-visible copy belongs here — never identifiers, SQL or user data.
const Map<String, String> enBackend = <String, String>{
  // ---- generic / lifecycle ----------------------------------------------
  '没有找到匹配的数据行': 'No matching row was found',
  '数据库返回了一个错误': 'The database returned an error',
  '应用尚未初始化，请先调用 initApp':
      'The application is not initialized yet; call initApp first',
  // ---- SQL console ------------------------------------------------------
  'SQL 语句不能为空': 'The SQL statement is empty',
  'SQL 不能为空': 'SQL cannot be empty',
  '没有正在执行的查询': 'No query is running',
  '查询取消令牌无效': 'The query cancellation token is invalid',
  '没有可 EXPLAIN 的语句': 'There is no statement to EXPLAIN',
  '查询已取消': 'Query cancelled',
  '查询已取消（执行中的连接已被中断，下一次查询会自动重连）':
      'Query cancelled (the connection running it was interrupted; the next query reconnects automatically)',
  '查询已取消（当前语句已回滚，连接可以继续使用）':
      'Query cancelled (the current statement was rolled back; the connection stays usable)',
  'SQLite 在应用进程内执行查询，无法安全取消；请等待查询完成':
      'SQLite runs queries inside the application process and cannot cancel them safely; wait for the query to finish',
  // ---- USE handling -----------------------------------------------------
  'USE 后面需要数据库名': 'USE requires a database name',
  'PostgreSQL 没有 USE 语句：请使用上方数据库选择器，或用 SET search_path TO <模式> 切换默认模式':
      'PostgreSQL has no USE statement: use the database picker above, or switch the default schema with SET search_path TO <schema>',
  'SQLite 没有 USE 语句：附加数据库由连接决定，不能通过 SQL 切换':
      'SQLite has no USE statement: attached databases are decided by the connection and cannot be switched from SQL',
  // ---- explorer ---------------------------------------------------------
  '数据库名不能为空': 'The database name cannot be empty',
  '请填写模式名': 'Enter a schema name',
  '请填写数据库名': 'Enter a database name',
  '请填写表名': 'Enter a table name',
  '请选择模式': 'Choose a schema',
  '请选择要删除的模式': 'Choose the schema to delete',
  '系统模式不允许修改': 'System schemas cannot be modified',
  '系统模式不允许删除': 'System schemas cannot be deleted',
  'MySQL / SQLite 没有独立的 schema 概念':
      'MySQL / SQLite have no separate schema concept',
  'SQLite 数据库是文件；请删除数据库文件':
      'A SQLite database is a file; delete the database file instead',
  '对象定义必须以 CREATE 或 ALTER 开头':
      'The object definition must start with CREATE or ALTER',
  '对象定义只能包含一条语句，请分次执行':
      'The object definition may contain only one statement; run them one at a time',
  // ---- table design -----------------------------------------------------
  '没有需要应用的修改': 'There are no changes to apply',
  '字段名不能为空': 'The column name cannot be empty',
  '非法的对象名': 'Invalid object name',
  '默认值不能为空': 'The default value cannot be empty',
  '默认值包含非法字符': 'The default value contains invalid characters',
  '外键需要至少一个本表字段': 'A foreign key needs at least one local column',
  '外键需要指定引用表': 'A foreign key must name the referenced table',
  '外键字段不能为空': 'The foreign key columns cannot be empty',
  '外键字段与引用字段数量必须一致':
      'The number of foreign-key and referenced columns must match',
  // ---- accounts ---------------------------------------------------------
  '用户名不能为空': 'The user name cannot be empty',
  '用户名/主机名包含非法字符': 'The user name / host contains invalid characters',
  'SQLite 没有数据库账号': 'SQLite has no database accounts',
  'SQLite 不支持 CREATE SCHEMA': 'SQLite does not support CREATE SCHEMA',
  'SQLite 不支持 DROP SCHEMA': 'SQLite does not support DROP SCHEMA',
  'MySQL 的 schema 就是数据库；请新建数据库':
      'A MySQL schema is a database; create a database instead',
  'MySQL 的 schema 就是数据库；请删除数据库':
      'A MySQL schema is a database; drop the database instead',
  // ---- SQLite file management -------------------------------------------
  '当前连接不是 SQLite 连接': 'The current connection is not a SQLite connection',
  '请选择数据库文件保存目录': 'Choose the folder for the database file',
  '请填写数据库文件名': 'Enter the database file name',
  '文件名不能包含路径分隔符或 ..':
      'The file name must not contain a path separator or ..',
  '该目录里没有可用的 SQLite 数据库文件':
      'This folder has no usable SQLite database files',
  '不是 .sqlite / .sqlite3 / .db / .db3 文件':
      'Not a .sqlite / .sqlite3 / .db / .db3 file',
  '不是有效的 SQLite 数据库文件（可能已损坏）':
      'Not a valid SQLite database file (it may be corrupted)',
  '没有可导入的数据库文件': 'There is no database file to import',
  '这是当前连接的主数据库文件，请改用删除连接或在连接编辑里更换主文件':
      'This is the main database file of the current connection; delete the connection or change the main file in the connection editor instead',
  // ---- SQLite ALTER limits ----------------------------------------------
  'SQLite 不支持修改字段定义，请通过重建表实现':
      'SQLite cannot modify a column definition; rebuild the table instead',
  'SQLite 不支持新增主键': 'SQLite cannot add a primary key',
  'SQLite 不支持存储引擎 / 字符集 / 表空间选项':
      'SQLite does not support storage engine / charset / tablespace options',
  'SQLite 的 WITHOUT ROWID / STRICT 只能在建表时指定':
      'SQLite allows WITHOUT ROWID / STRICT only at table creation',
  'SQLite 不支持用 ALTER 增删外键，请在新建表时指定或重建表':
      'SQLite cannot add or drop foreign keys with ALTER; specify them when creating the table or rebuild it',
  'SQLite 新增字段不支持自增 / 注释':
      'SQLite cannot add an auto-increment column or a column comment',
  '没有可用的修改': 'There are no applicable changes',
  // ---- files / backups / history ----------------------------------------
  '请选择文件': 'Choose a file',
  '选择的路径不是文件': 'The selected path is not a file',
  '文件不是 UTF-8 文本': 'The file is not UTF-8 text',
  '请选择保存位置': 'Choose where to save',
  '备份不存在': 'The backup does not exist',
  '导入内容为空': 'The imported content is empty',
  '导出路径必须是绝对路径': 'The export path must be absolute',
  '导出语句不能为空': 'The export statement cannot be empty',
  '查询结果不支持 SQL 导出：SQL 格式需要表结构，请在表页导出':
      'SQL export needs a table structure and is not available for query results; export from the table page',
  // ---- structure sync ----------------------------------------------------
  '尚未选择源数据库': 'No source database has been chosen',
  '请选择源数据库和目标数据库': 'Choose a source and a target database',
  '源与目标不能是同一个数据库中的同名模式':
      'The source and target cannot be the same schema in the same database',
  // ---- import wizard -----------------------------------------------------
  '缺少目标数据库': 'The target database is missing',
  '缺少目标表': 'The target table is missing',
  '请先设置列映射': 'Set the column mapping first',
  '任务不存在或已结束': 'The task does not exist or has already finished',
  '文件是 UTF-16 编码，暂不支持；请另存为 UTF-8 后重试':
      'The file is UTF-16 encoded, which is not supported yet; save it as UTF-8 and retry',
  '文件不是有效的 UTF-8 文本（可能是 GBK/GB18030），请另存为 UTF-8 后重试':
      'The file is not valid UTF-8 text (it may be GBK/GB18030); save it as UTF-8 and retry',
  '记录分隔符不能为空': 'The record separator cannot be empty',
  '引号未闭合：记录一直读到文件结尾':
      'Unterminated quote: the record was read to the end of the file',
  '记录不是有效的 UTF-8 文本（可能是 GBK/GB18030 编码）':
      'The record is not valid UTF-8 text (it may be GBK/GB18030)',
  // ---- connection --------------------------------------------------------
  '连接不存在': 'The connection does not exist',
  'SSH 隧道需要填写数据库服务器地址（从跳板机视角）':
      'An SSH tunnel needs the database server address (as seen from the jump host)',
  '数据库文件不存在': 'The database file does not exist',
};

/// Patterns for the interpolated backend errors of this area.
final List<Rewrite> rewritesBackend = <Rewrite>[
  // "无法打开数据库 X：…" — the per-database permission wording. The inner
  // message is translated recursively: the driver layer may already have
  // replaced it with its own Chinese explanation.
  Rewrite(RegExp(r'^无法打开数据库 (.+?)：(.+)$', dotAll: true),
      (m) => 'Cannot open database ${m[1]}: ${trLiteral(m[2]!)}'),
  // Driver error suffixes.
  Rewrite(RegExp(r'^(.+)（错误码 ([A-Za-z0-9]+)）$', dotAll: true),
      (m) => '${trLiteral(m[1]!)} (error code ${m[2]})'),
  Rewrite(RegExp(r'^数据库原始信息：(.+)$', dotAll: true),
      (m) => 'Original database message: ${m[1]}'),
  // Filesystem messages.
  Rewrite(RegExp(r'^无法读取文件: (.+)$', dotAll: true),
      (m) => 'Cannot read the file: ${m[1]}'),
  Rewrite(RegExp(r'^无法打开文件: (.+)$', dotAll: true),
      (m) => 'Cannot open the file: ${m[1]}'),
  Rewrite(RegExp(r'^读取文件失败: (.+)$', dotAll: true),
      (m) => 'Reading the file failed: ${m[1]}'),
  Rewrite(RegExp(r'^无法写入文件: (.+)$', dotAll: true),
      (m) => 'Cannot write the file: ${m[1]}'),
  Rewrite(RegExp(r'^无法创建目录: (.+)$', dotAll: true),
      (m) => 'Cannot create the folder: ${m[1]}'),
  Rewrite(RegExp(r'^无法创建导出文件 (.+?)：(.+)$', dotAll: true),
      (m) => 'Cannot create the export file ${m[1]}: ${m[2]}'),
  Rewrite(RegExp(r'^无法保存连接：(.+)$', dotAll: true),
      (m) => 'Cannot save the connection: ${m[1]}'),
  Rewrite(RegExp(r'^无法保存备份索引: (.+)$', dotAll: true),
      (m) => 'Cannot save the backup index: ${m[1]}'),
  Rewrite(RegExp(r'^无法写入备份文件: (.+)$', dotAll: true),
      (m) => 'Cannot write the backup file: ${m[1]}'),
  Rewrite(RegExp(r'^无法读取备份文件: (.+)$', dotAll: true),
      (m) => 'Cannot read the backup file: ${m[1]}'),
  Rewrite(RegExp(r'^无法保存查询历史: (.+)$', dotAll: true),
      (m) => 'Cannot save the query history: ${m[1]}'),
  Rewrite(RegExp(r'^无法保存设置: (.+)$', dotAll: true),
      (m) => 'Cannot save the settings: ${m[1]}'),
  Rewrite(RegExp(r'^无法创建数据目录: (.+)$', dotAll: true),
      (m) => 'Cannot create the data folder: ${m[1]}'),
  Rewrite(RegExp(r'^无法创建备份目录: (.+)$', dotAll: true),
      (m) => 'Cannot create the backup folder: ${m[1]}'),
  Rewrite(RegExp(r'^目录不存在：(.+)$', dotAll: true),
      (m) => 'The folder does not exist: ${m[1]}'),
  Rewrite(RegExp(r'^文件已存在：(.+)$', dotAll: true),
      (m) => 'The file already exists: ${m[1]}'),
  Rewrite(RegExp(r'^无法在 (.+?) 创建数据库文件：(.+)$', dotAll: true),
      (m) => 'Cannot create the database file in ${m[1]}: ${m[2]}'),
  Rewrite(RegExp(r'^删除数据库文件失败 (.+?)：(.+)$', dotAll: true),
      (m) => 'Deleting the database file failed ${m[1]}: ${m[2]}'),
  Rewrite(RegExp(r'^无法读取：(.+)$', dotAll: true),
      (m) => 'Cannot read: ${m[1]}'),
  // Object helpers.
  Rewrite(RegExp(r"^对象 '(.+)' 不存在$", dotAll: true),
      (m) => "Object '${m[1]}' does not exist"),
  Rewrite(RegExp(r"^未知对象类型 '(.+)'$", dotAll: true),
      (m) => "Unknown object type '${m[1]}'"),
  Rewrite(RegExp(r"^SQLite 不支持查看对象类型 '(.+)'$", dotAll: true),
      (m) => "SQLite cannot inspect object type '${m[1]}'"),
  Rewrite(RegExp(r"^SQLite 不支持删除对象类型 '(.+)'$", dotAll: true),
      (m) => "SQLite cannot drop object type '${m[1]}'"),
  Rewrite(RegExp(r"^不支持的字段类型 '(.+)'$", dotAll: true),
      (m) => "Unsupported column type '${m[1]}'"),
  // Round34 P2-02: a MySQL connection charset the client cannot put in the
  // handshake. The Rust layer rejects it before sqlx's own English
  // "unsupported MySQL charset" message can reach the UI.
  Rewrite(RegExp(r"^不支持的 MySQL 字符集 '(.+)'：(.+)$", dotAll: true),
      (m) => "Unsupported MySQL charset '${m[1]}': use a charset the server "
          "supports (e.g. utf8mb4, utf8, latin1)"),
  Rewrite(RegExp(r'^不支持的导出格式 (.+)$', dotAll: true),
      (m) => 'Unsupported export format ${m[1]}'),
  Rewrite(RegExp(r"^不支持的引用动作 '(.+)'$", dotAll: true),
      (m) => "Unsupported referential action '${m[1]}'"),
  Rewrite(RegExp(r"^非法外键名 '(.+)'$", dotAll: true),
      (m) => "Invalid foreign-key name '${m[1]}'"),
  Rewrite(RegExp(r"^非法排序规则 '(.+)'$", dotAll: true),
      (m) => "Invalid collation '${m[1]}'"),
  Rewrite(RegExp(r"^默认值包含非法字符 '(.+)'$", dotAll: true),
      (m) => "The default value contains the invalid character '${m[1]}'"),
  Rewrite(RegExp(r'^默认值包含多余内容：(.+)$', dotAll: true),
      (m) => 'The default value has trailing content: ${m[1]}'),
  Rewrite(RegExp(r'^默认值不是合法表达式：(.+)$', dotAll: true),
      (m) => 'The default value is not a valid expression: ${m[1]}'),
  Rewrite(RegExp(r'^参数 (.+?) 无效: (.+)$', dotAll: true),
      (m) => 'Parameter ${m[1]} is invalid: ${m[2]}'),
  // Import engine positions.
  Rewrite(RegExp(r'^单条记录超过上限 (\d+) 字节，可能记录分隔符配置不正确$'),
      (m) => 'One record exceeds the ${m[1]}-byte limit; the record separator may be misconfigured'),
  Rewrite(RegExp(r'^导入内容过大（(\d+) 字节，上限 (\d+) 字节）$'),
      (m) => 'The imported content is too large (${m[1]} bytes; the limit is ${m[2]} bytes)'),
  Rewrite(RegExp(r'^文件过大：(\d+) 字节，导入上限为 (\d+) MiB$'),
      (m) => 'The file is too large: ${m[1]} bytes; the import limit is ${m[2]} MiB'),
  Rewrite(RegExp(r'^已切换到数据库：(.+)$', dotAll: true),
      (m) => 'Switched to database: ${m[1]}'),
  // Structure sync warnings.
  Rewrite(RegExp(r'^目标多出字段 (.+)（未勾选允许删除，已跳过）$', dotAll: true),
      (m) => 'Target has the extra column ${m[1]} (dropping is not enabled, skipped)'),
  Rewrite(RegExp(r'^目标多出索引 (.+)（未勾选允许删除，已跳过）$', dotAll: true),
      (m) => 'Target has the extra index ${m[1]} (dropping is not enabled, skipped)'),
  Rewrite(RegExp(r'^目标库多出的表 (.+)（结构同步不会删除它）$', dotAll: true),
      (m) => 'Target has the extra table ${m[1]} (structure sync never drops it)'),
  Rewrite(RegExp(r'^索引 (.+) 定义不同（未勾选允许删除，已跳过）$', dotAll: true),
      (m) => 'Index ${m[1]} is defined differently (dropping is not enabled, skipped)'),
  // ---- permission hints (the Rust layer's actionable sentences) ----------
  Rewrite(RegExp(r'^用户名或密码不正确，或该账号不允许从当前主机登录。$', dotAll: true),
      (_) => 'The user name or password is incorrect, or the account is not allowed to log in from this host.'),
  Rewrite(RegExp(r'^当前数据库账号没有访问该数据库的权限。请让管理员执行 GRANT \.\.\. ON 该库\.\* TO 该账号，或改用有权限的账号连接。$', dotAll: true),
      (_) => 'The current database account cannot access this database. Ask the administrator for GRANT ... ON that database.* TO the account, or connect with an account that has it.'),
  Rewrite(RegExp(r'^当前数据库账号缺少该操作所需的表级权限。请让数据库管理员补授对应的 SELECT / INSERT / UPDATE / DELETE 等权限。$', dotAll: true),
      (_) => 'The current database account lacks the table-level privilege for this operation. Ask the database administrator for the matching SELECT / INSERT / UPDATE / DELETE privilege.'),
  Rewrite(RegExp(r'^当前数据库角色权限不足。请让管理员补授相应的 GRANT，或改用有权限的角色连接。$', dotAll: true),
      (_) => 'The current database role lacks privileges. Ask the administrator for the matching GRANT, or connect with a role that has it.'),
  Rewrite(RegExp(r'^当前数据库账号缺少执行该语句所需的服务器级权限。$', dotAll: true),
      (_) => 'The current database account lacks the server-level privilege needed for this statement.'),
  Rewrite(RegExp(r'^当前数据库账号缺少该列的操作权限。$', dotAll: true),
      (_) => 'The current database account lacks the privilege for this column.'),
  Rewrite(RegExp(r'^当前数据库账号缺少服务器级权限（需要 SUPER、SYSTEM_VARIABLES_ADMIN、SESSION_VARIABLES_ADMIN 之一）。$', dotAll: true),
      (_) => 'The current database account lacks a server-level privilege (one of SUPER, SYSTEM_VARIABLES_ADMIN, SESSION_VARIABLES_ADMIN is required).'),
  Rewrite(RegExp(r'^表不存在：可能已被删除，或当前库选择错误。$', dotAll: true),
      (_) => 'The table does not exist: it may have been dropped, or the wrong database is selected.'),
  Rewrite(RegExp(r'^数据库不存在：可能已被删除，或名称拼写错误。$', dotAll: true),
      (_) => 'The database does not exist: it may have been dropped, or the name is misspelled.'),
  Rewrite(RegExp(r'^数据库不存在或当前角色无权连接该数据库。$', dotAll: true),
      (_) => 'The database does not exist or the current role cannot connect to it.'),
  Rewrite(RegExp(r'^数据库文件只读，当前无法写入。$', dotAll: true),
      (_) => 'The database file is read-only and cannot be written.'),
];
