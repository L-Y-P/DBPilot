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
  // ---- about / updates ----------------------------------------------------
  '应用版本': 'App version',
  '核心版本': 'Core version',
  '未知': 'Unknown',
  '检查更新': 'Check for updates',
  '已是最新版本': 'You are up to date',
  '项目地址': 'Project URL',
  '仅检查仓库是否有新版本，不会自动下载或安装。':
      'Checks the repository for a newer release only; nothing is downloaded or installed automatically.',
  '无法打开浏览器，请手动复制链接。':
      'Could not open the browser; please copy the link manually.',
  '发现新版本：': 'Update available:',
  '更新说明': 'Release notes',
  '下载地址': 'Download',
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
];
