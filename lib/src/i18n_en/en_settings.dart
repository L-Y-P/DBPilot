import 'rewrite.dart';

/// English for the settings dialog and the update checker.
///
/// Keys are the **rendered** Chinese strings (the desktop UI writes Chinese and
/// [trLiteral] rewrites it), values are the English UI copy. Only user-visible
/// copy belongs here — a path, a version number or a release note is data and is
/// rendered untouched.
const Map<String, String> enSettings = <String, String>{
  // ---- dialog chrome ------------------------------------------------------
  '设置': 'Settings',
  '语言': 'Language',
  // A language switcher names each language in that language, so 中文 stays
  // 中文 in English mode (overriding en_common's '中文' -> 'Chinese' entry for
  // this dialog; english_ui_test's whitelist documents the same rule).
  '中文': '中文',
  '个性化': 'Personalization',
  '备份': 'Backups',
  '关于': 'About',
  // ---- appearance ---------------------------------------------------------
  '主题': 'Theme',
  '跟随系统': 'Follow system',
  '浅色': 'Light',
  '深色': 'Dark',
  '主题色': 'Accent color',
  // Theme preset names (kThemePresets).
  '默认': 'Default',
  '靛蓝': 'Indigo',
  '青绿': 'Teal',
  '森林': 'Forest',
  '玫瑰': 'Rose',
  '紫罗兰': 'Violet',
  // ---- performance --------------------------------------------------------
  '性能': 'Performance',
  '自动调整列宽': 'Auto-fit column widths',
  '大字段延迟加载': 'Lazy-load large fields',
  '关闭自动列宽后所有列使用固定宽度，宽表首帧更快；大字段延迟加载只渲染长值的前 120 个字符，双击单元格仍可查看完整内容。':
      'With auto-fit off, every column uses a fixed width and wide tables paint faster; '
          'lazy loading renders only the first 120 characters of a long value, and '
          'double-clicking a cell still shows the whole content.',
  // ---- backups ------------------------------------------------------------
  '备份目录': 'Backup folder',
  '未设置': 'Not set',
  '更改': 'Change',
  '恢复默认': 'Restore default',
  '选择备份保存目录': 'Choose a folder for backups',
  '备份文件默认保存在数据目录的 backups 子目录，可另选一个位置。':
      'Backups are stored in the backups folder inside the data directory by default; pick a different location here.',
  // ---- data & uninstall ---------------------------------------------------
  '数据与卸载': 'Data & uninstall',
  '数据目录': 'Data folder',
  '打开数据目录': 'Open data folder',
  '执行清空…': 'Erase user data…',
  '刷新': 'Refresh',
  '占用空间': 'Space used',
  '内容': 'Contents',
  '尚未创建': 'Not created yet',
  '空目录（0 B）': 'Empty (0 B)',
  '占用未知': 'Space used unknown',
  '数据目录不可用': 'Data folder unavailable',
  '正在读取数据目录…': 'Reading the data folder…',
  '正在统计占用…': 'Measuring disk usage…',
  '确定清空用户数据吗？': 'Erase all user data?',
  '将删除 {path} 里的全部文件（连接配置、查询历史、设置与备份），此操作不可撤销。':
      'Everything inside {path} will be deleted (connections, query history, settings and backups). This cannot be undone.',
  '清空': 'Erase',
  '卸载应用不会自动删除这个目录：卸载前请在这里清空，或卸载后手动删除该路径。Windows 安装包在卸载时会询问是否删除用户数据。':
      'Uninstalling the app does not delete this folder. Erase it here before uninstalling, '
          'or delete the folder manually afterwards. On Windows the uninstaller asks whether '
          'to remove the user data.',
  // ---- about / updates ----------------------------------------------------
  '应用版本': 'App version',
  '未知': 'Unknown',
  '检查更新': 'Check for updates',
  '已是最新版本': 'You are up to date',
  '项目地址': 'Project URL',
  '发现新版本后自动下载并安装（Windows 会请求管理员权限），完成后应用将重启。':
      'A newer release is downloaded and installed automatically (Windows asks for administrator rights); the app restarts when it finishes.',
  '重试自动更新': 'Retry update',
  '已取消更新': 'Update cancelled',
  '更新下载地址无效': 'The update download URL is not valid',
  '更新包文件名无效': 'The update package file name is not valid',
  '下载超时，请稍后重试':
      'The download timed out; please try again later',
  '无法打开浏览器，请手动复制链接。':
      'Could not open the browser; please copy the link manually.',
  '发现新版本：': 'Update available:',
  '更新说明': 'Release notes',
  '下载地址': 'Download',
  // ---- Microsoft Store (MSIX) builds -------------------------------------
  // A Store build cannot update itself (Windows forbids a packaged app from
  // running the NSIS installer, and the Store re-signs every release), so the
  // about section swaps the GitHub wording for the Store one. The sentence is
  // shared with update_apply.dart's UpdateApplyException (kMsixUpdateGuidance).
  '当前为 Microsoft Store 版本，应用内自动更新已停用，请从 Microsoft Store 更新。':
      'This is the Microsoft Store version: in-app updates are disabled. '
          'Please update from the Microsoft Store.',
  '更新方式：Microsoft Store': 'Updates: Microsoft Store',
  // ---- update check failures ---------------------------------------------
  '未配置更新源': 'No update source configured',
  '更新检查失败：更新地址无效':
      'Update check failed: the update URL is not valid',
  '更新检查失败：更新清单不是合法的 JSON':
      'Update check failed: the update manifest is not valid JSON',
  '更新检查失败：更新清单缺少 version 字段':
      'Update check failed: the update manifest has no version field',
  '检查更新超时，请稍后重试':
      'The update check timed out; please try again later',
};

/// Interpolated update-check failures (they embed the HTTP status or the
/// underlying I/O error).
final List<Rewrite> rewritesSettings = <Rewrite>[
  // The DataGrid's lazy-load badge: "… 1536 字符" -> "… 1536 chars".
  Rewrite(RegExp(r'^… (\d+) 字符$'), (m) => '… ${m[1]} chars'),
  Rewrite(RegExp(r'^更新检查失败：HTTP (\d+)$'),
      (m) => 'Update check failed: HTTP ${m[1]}'),
  // Backup page subtitle (P3-10). It names the database the picker points at,
  // so it is interpolated copy rather than a fixed sentence; the PostgreSQL
  // variant must be tried first because `(.+)` would otherwise swallow its
  // extra clause and translate the sentence as a plain MySQL one.
  Rewrite(
      RegExp(r'^备份作用于当前数据库 (.+) 中的模式；恢复时会切换回备份记录的数据库。$'),
      (m) =>
          'Backups apply to the schemas of the current database ${m[1]}; a restore switches back to the database recorded in the backup.'),
  Rewrite(RegExp(r'^备份作用于当前数据库 (.+)。$'),
      (m) => 'Backups apply to the current database ${m[1]}.'),
  Rewrite(RegExp(r'^更新检查失败：(.+)$', dotAll: true),
      (m) => 'Update check failed: ${m[1]}'),
  Rewrite(RegExp(r'^下载失败：(.+)$', dotAll: true),
      (m) => 'Download failed: ${m[1]}'),
  Rewrite(RegExp(r'^下载不完整：收到 (\d+) 字节，应为 (\d+) 字节$'),
      (m) => 'Incomplete download: received ${m[1]} of ${m[2]} bytes'),
  Rewrite(RegExp(r'^更新失败：(.+)$', dotAll: true),
      (m) => 'Update failed: ${m[1]}'),
];
