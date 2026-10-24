import 'i18n.dart';
import 'i18n_en/en_admin.dart';
import 'i18n_en/en_backend.dart';
import 'i18n_en/en_builder.dart';
import 'i18n_en/en_common.dart';
import 'i18n_en/en_connections.dart';
import 'i18n_en/en_import.dart';
import 'i18n_en/en_quick_create.dart';
import 'i18n_en/en_relations.dart';
import 'i18n_en/en_settings.dart';
import 'i18n_en/en_tables.dart';
import 'i18n_en/rewrite.dart';
import 'i18n_keys.g.dart';

/// English translations for the desktop-only literal UI strings.
///
/// The generated [enDict] is keyed by semantic key, so everything that goes
/// through `t('...')` is already translated. The desktop views also contain
/// many literals that never reach `t()` — button labels and the short prompts
/// shown in toasts, alerts and confirmation dialogs. Keying all of them by hand
/// would be a large mechanical refactor with little benefit, so this module
/// translates the **rendered string** instead:
///
///  * exact matches use the reverse of the web dictionary ([zhDict] -> [enDict])
///    plus a desktop-only table for strings the web app never had;
///  * a handful of interpolated prompts are recognised by pattern;
///  * anything else (table names, SQL, driver error messages, user input) is
///    returned unchanged, so the translator can never mangle data.
///
/// Every rendered UI string goes through here, including the ones built by the
/// translating `Text` widget (`text.dart`), so the English mode covers the
/// whole desktop UI. Strings that never render through a `Text` widget —
/// `Tooltip.message`, `InputDecoration.hintText`, `Semantics` labels — must be
/// wrapped in [trLiteral] explicitly at the call site.
///
/// Callers should only pass strings that are UI copy, never dynamic content.
String trLiteral(String text) {
  if (I18n.current != AppLang.en || text.isEmpty) return text;
  final exact = _exact[text] ?? _reverseWeb[text];
  if (exact != null) return exact;
  for (final rewrite in _rewrites) {
    final match = rewrite.pattern.firstMatch(text);
    if (match != null) return rewrite.build(match);
  }
  return text;
}

/// Pick the Chinese or English variant of a prompt that needs interpolation.
///
/// Multi-line prompts are awkward to rewrite by pattern; for those, the call
/// site builds both languages and this helper chooses one.
String pickText(String zh, String en) => I18n.current == AppLang.en ? en : zh;

/// Every desktop-authored table, merged with the legacy [_desktop] entries
/// taking precedence (they carry deliberate context fixes such as "应用" being
/// the Apply button).
///
/// Add new copy to the per-area table in the i18n_en directory that matches
/// being translated; keep [_desktop] as the historical compatibility layer.
final Map<String, String> _exact = <String, String>{
  ...enCommon,
  ...enConnections,
  ...enTables,
  ...enImport,
  ...enQuickCreate,
  ...enRelations,
  ...enBuilder,
  ...enAdmin,
  ...enBackend,
  ...enSettings,
  ..._desktop,
};

/// Reverse of the generated web dictionary: Chinese text -> English text.
///
/// Placeholder-bearing entries are skipped because their rendered form contains
/// values that cannot be matched exactly; [trLiteral]'s patterns cover the
/// desktop prompts that need them.
final Map<String, String> _reverseWeb = () {
  final map = <String, String>{};
  for (final entry in enDict.entries) {
    final zh = zhDict[entry.key];
    final en = entry.value;
    if (zh == null || zh.isEmpty || en.isEmpty || zh == en) continue;
    if (zh.contains('{') || en.contains('{')) continue;
    // First key wins; the desktop table below can override a bad context.
    map.putIfAbsent(zh, () => en);
  }
  return map;
}();

/// Desktop-only UI copy that is not in the generated web dictionary.
///
/// Entries checked before [_reverseWeb]; use this table to fix context problems
/// (for example "应用" is the Apply button, not the app).
const Map<String, String> _desktop = <String, String>{
  // ---- buttons -----------------------------------------------------------
  '改': 'Edit',
  '删': 'Delete',
  '复制': 'Copy',
  '复制内容': 'Copy contents',
  '重跑': 'Re-run',
  '移除': 'Remove',
  '打开': 'Open',
  '打开目录': 'Open folder',
  '全部': 'All',
  '应用': 'Apply',
  '重置': 'Reset',
  '新建模式': 'New schema',
  '新建账号': 'New account',
  '删除模式': 'Delete schema',
  '删除数据库文件': 'Delete database file',
  '查看 DDL': 'View DDL',
  '历史记录': 'History',
  '添加连接': 'Add join',
  '加载示例': 'Load example',
  '添加排序': 'Add sort',
  '生成预览': 'Generate preview',
  '+ 添加作用域': '+ Add scope',
  '选择 SQL 文件': 'Choose SQL file',
  '创建': 'Create',
  '创建中…': 'Creating…',
  '执行中…': 'Running…',
  '保存中…': 'Saving…',
  '刷新': 'Refresh',
  // ---- prompts / toasts --------------------------------------------------
  'SQLite 的数据库就是文件，请用左侧「+」新建数据库文件或导入':
      'A SQLite database is a file. Use "+" on the left to create a database file or import one',
  '当前账号没有建库权限（需要 CREATEDB / 全局 CREATE）':
      'The current account cannot create databases (requires CREATEDB / global CREATE)',
  '请填写数据库名': 'Enter a database name',
  '模式已创建': 'Schema created',
  '模式已删除': 'Schema deleted',
  '数据库文件已删除': 'Database file deleted',
  '该数据库没有对应的文件路径': 'This database has no file path',
  '该连接还没有数据库文件': 'This connection has no database file yet',
  '已断开连接': 'Disconnected',
  '对象已删除': 'Object deleted',
  '单元格已保存': 'Cell saved',
  '进程已终止': 'Process killed',
  '账号已删除': 'Account deleted',
  '没有找到正在执行的查询（可能已结束）':
      'No running query found (it may already have finished)',
  '已中断查询连接，下一次查询会自动重连':
      'Query cancelled by resetting the connection; the next query reconnects automatically',
  '已发送取消请求': 'Cancel request sent',
  '结构一致，无需同步': 'Structures match; nothing to sync',
  '导入完成': 'Import complete',
  '账号已创建': 'Account created',
  '视图已创建': 'View created',
  '对象已创建': 'Object created',
  // ---- alert / info prompts ---------------------------------------------
  '尚未连接数据库：备份需要先打开一个连接。':
      'Not connected: open a connection before using backups.',
  '尚未连接数据库：结构同步需要先打开一个连接。':
      'Not connected: open a connection before comparing structures.',
  '请选择不同的源/目标：同一数据库中的两个模式，或两个数据库中的模式。':
      'Choose different source/target: two schemas in the same database, or schemas in two databases.',
  '结构一致：源库与目标库没有差异。':
      'Structures match: there are no differences between source and target.',
  '只同步字段、主键与索引；外键、触发器和函数不会被创建。':
      'Only columns, primary keys and indexes are synced; foreign keys, triggers and functions are not created.',
  '该表没有主键，行编辑将按整行匹配，可能影响多行。':
      'This table has no primary key; row edits match the whole row and may affect multiple rows.',
  '数据库目录不存在（可能已被移动、删除，或磁盘未挂载）：':
      'The database folder does not exist (it may have been moved, deleted, or the disk is not mounted):',
  // ---- form labels / status ---------------------------------------------
  '设为当前数据库': 'Set as active database',
  '通过 SSH 隧道连接（跳板机）': 'Connect through an SSH tunnel (jump host)',
  '锁定账号': 'Lock account',
  '无权限': 'No permission',
  '删除文件': 'Delete file',
  // ---- data grid / sidebar ---------------------------------------------
  '筛选': 'Filter',
  '隐藏筛选': 'Hide filters',
  '连接中…': 'Connecting…',
  '（无数据库）': '(no databases)',
  '加载模式…': 'Loading schemas…',
  '（无模式）': '(no schemas)',
  '（该目录下没有可用的数据库）':
      '(no usable database files in this folder)',
  '新建 / 导入数据库文件': 'Create / import database file',
  '新建数据库': 'New database',
  // ---- navigation / empty states ----------------------------------------
  '工具 v': 'Tools v',
  '未连接数据库': 'Not connected',
  '当前没有打开的数据库连接。这个页面需要先连接数据库。':
      'No database connection is open. Connect to a database first.',
  '请确认': 'Confirm',
  '确定': 'OK',
};

/// Interpolated prompts kept from the original desktop translator.
///
/// New patterns belong in the per-area [Rewrite] lists under i18n_en; this list
/// is consulted first so its behaviour cannot regress.
final List<Rewrite> _legacyRewrites = <Rewrite>[
  // Column chooser button, e.g. "列 (3/4)".
  Rewrite(RegExp(r'^列 \((\d+)/(\d+)\)$'), (m) => 'Columns (${m[1]}/${m[2]})'),
  // Toast: "已导入 2 个数据库连接".
  Rewrite(
      RegExp(r'^已导入 (\d+) 个数据库连接$'), (m) => 'Imported ${m[1]} connection(s)'),
  // Toast: "已删除 3 行".
  Rewrite(RegExp(r'^已删除 (\d+) 行$'), (m) => 'Deleted ${m[1]} row(s)'),
  // Toast: "已保存到 /path", "已导出到 /path".
  Rewrite(RegExp(r'^已保存到 (.+)$'), (m) => 'Saved to ${m[1]}'),
  Rewrite(RegExp(r'^已导出到 (.+)$'), (m) => 'Exported to ${m[1]}'),
  // Toast: "无法打开目录：/path" / "...（文件或目录可能已不存在）：/path".
  Rewrite(
      RegExp(r'^无法打开目录（文件或目录可能已不存在）：(.+)$'),
      (m) => 'Cannot open folder (it may no longer exist): ${m[1]}'),
  Rewrite(
      RegExp(r'^无法打开目录：(.+)$'), (m) => 'Cannot open folder: ${m[1]}'),
  // Toast: "当前账号没有连接数据库 db 的权限".
  Rewrite(
      RegExp(r'^当前账号没有连接数据库 (.+) 的权限$'),
      (m) => 'The current account has no permission to connect to database ${m[1]}'),
  // Failed actions keep the backend detail.
  Rewrite(RegExp(r'^保存失败：(.+)$', dotAll: true), (m) => 'Save failed: ${m[1]}'),
  Rewrite(RegExp(r'^删除失败：(.+)$', dotAll: true), (m) => 'Delete failed: ${m[1]}'),
  Rewrite(
      RegExp(r'^执行失败：(.+)$', dotAll: true), (m) => 'Execution failed: ${m[1]}'),
  // Toast: "同步完成 — 12 SQL, 0 failed".
  Rewrite(RegExp(r'^同步完成 — (\d+) SQL, (\d+) failed$'),
      (m) => 'Sync finished — ${m[1]} SQL, ${m[2]} failed'),
  // Result set notice: "3 行受影响，最后插入 ID 5".
  Rewrite(RegExp(r'^(\d+) 行受影响(.*)$', dotAll: true), (m) {
    var rest = m[2]!;
    if (rest.contains('，最后插入 ID ')) {
      rest = rest.replaceFirst('，最后插入 ID ', ', last insert ID ');
      return '${m[1]} row(s) affected$rest';
    }
    return '${m[1]} row(s) affected$rest';
  }),
  // Status pills, e.g. "数据库 rustmyadmin_demo", "3 张表".
  Rewrite(RegExp(r'^数据库 (.+)$'), (m) => 'Database ${m[1]}'),
  Rewrite(RegExp(r'^(\d+) 张表$'), (m) => '${m[1]} tables'),
  // Alert: "当前连接：name (SQLite)".
  Rewrite(RegExp(r'^当前连接：(.+) \((.+)\)$'),
      (m) => 'Current connection: ${m[1]} (${m[2]})'),
  // ---- confirmation dialogs ---------------------------------------------
  Rewrite(RegExp(r'^确定删除连接 (.+) 吗？$'), (m) => 'Delete connection ${m[1]}?'),
  Rewrite(
      RegExp(r'^确定删除数据库文件 (.+) 吗？文件会从磁盘上删除，无法恢复。$'),
      (m) => 'Delete database file ${m[1]}? The file is removed from disk and cannot be recovered.'),
  Rewrite(
      RegExp(r'^确定删除数据库 (.+) 吗？该数据库下的所有模式、表和对象都会被删除，且无法恢复。$'),
      (m) => 'Drop database ${m[1]}? All schemas, tables and objects in it are deleted and cannot be recovered.'),
  Rewrite(
      RegExp(r'^确定删除模式 (.+) 吗？该模式下的所有表、视图和函数都会被删除，且无法恢复。$'),
      (m) => 'Delete schema ${m[1]}? All tables, views and functions in it are deleted and cannot be recovered.'),
  Rewrite(RegExp(r'^确定删除数据库 (.+) 吗？该操作不可恢复。$'),
      (m) => 'Drop database ${m[1]}? This cannot be undone.'),
  Rewrite(RegExp(r'^确定清空表 (.+) 的全部数据吗？$'),
      (m) => 'Truncate all data in table ${m[1]}?'),
  Rewrite(RegExp(r'^确定清空表 (.+) 吗？$'), (m) => 'Truncate table ${m[1]}?'),
  Rewrite(RegExp(r'^确定删除表 (.+) 吗？$'), (m) => 'Drop table ${m[1]}?'),
  Rewrite(RegExp(r'^确定删除 (.+) (.+) 吗？$'),
      (m) => 'Delete ${m[1]} ${m[2]}?'),
  Rewrite(RegExp(r'^确定删除选中的 (\d+) 行吗？$'),
      (m) => 'Delete the ${m[1]} selected row(s)?'),
  Rewrite(RegExp(r'^确定删除该行吗？$'), (_) => 'Delete this row?'),
  Rewrite(RegExp(r'^确定清空全部查询历史吗？$'),
      (_) => 'Clear the entire query history?'),
  Rewrite(RegExp(r'^确定应用以下修改吗？$'), (_) => 'Apply the following changes?'),
  Rewrite(RegExp(r'^确定终止进程 (.+) 吗？$'), (m) => 'Kill process ${m[1]}?'),
  Rewrite(RegExp(r'^确定删除账号 (.+) 吗？$'), (m) => 'Delete account ${m[1]}?'),
];

/// All pattern rewrites, in lookup order.
///
/// The legacy list runs first so the behaviour pinned by the existing tests
/// cannot change; the per-area lists only add prompts the legacy list never
/// covered.
final List<Rewrite> _rewrites = <Rewrite>[
  ..._legacyRewrites,
  ...rewritesCommon,
  ...rewritesConnections,
  ...rewritesTables,
  ...rewritesImport,
  ...rewritesQuickCreate,
  ...rewritesBuilder,
  ...rewritesAdmin,
  ...rewritesBackend,
  ...rewritesSettings,
];
