import 'i18n_literals.dart';

/// The corrupt-file backup named in [error], or null when the backend could not
/// preserve the original file (in that case it refuses to overwrite it).
///
/// The backend writes the copy next to the live file, so the directory is
/// recovered from the parenthesised live-file path: the user needs the folder,
/// not just the name, to restore it.
String? connectionsStoreBackupPath(String error) {
  final name = RegExp(r'connections\.json\.corrupt-[^\s；;，,]+')
      .firstMatch(error)
      ?.group(0);
  if (name == null) return null;
  final live = RegExp(r'（([^）]*connections\.json)）')
      .firstMatch(error)
      ?.group(1);
  final cut = live?.lastIndexOf('/') ?? -1;
  return cut < 0 ? name : '${live!.substring(0, cut)}/$name';
}

/// The backend's parse diagnostic (e.g. serde's "expected value at line 1"),
/// extracted from the wrapping sentence so the English banner keeps the useful
/// detail without repeating the Chinese user-facing copy.
String _storeErrorDetail(String error) {
  final match = RegExp(r'）：(.+?)(?:；|$)').firstMatch(error);
  return (match?.group(1) ?? '').trim();
}

/// Build the dismissible startup banner explaining a corrupt connections.json.
///
/// Returns null when the store loaded normally, so the view can simply skip
/// rendering the alert. The copy is chosen with [pickText] because the UI has a
/// real English mode; the actual backup path (and serde's line/column reason)
/// are interpolated so the user knows which file to restore.
String? connectionsStoreNotice(String? error) {
  final text = error?.trim();
  if (text == null || text.isEmpty) return null;
  final backup = connectionsStoreBackupPath(text);
  final zh = backup == null
      ? '连接配置文件 connections.json 解析失败，且原文件备份失败；'
            '应用本次以空/种子连接列表启动，且没有覆盖该文件。'
            '历史连接可能未显示，请先检查该文件再保存新连接。'
      : '连接配置文件 connections.json 解析失败，原文件已原样备份为 $backup。'
            '应用本次以空/种子连接列表启动，历史连接可能未显示；'
            '建议检查该文件，必要时从备份恢复连接后重启应用。';
  final en = backup == null
      ? 'The connections.json file could not be parsed and the original could '
            'not be backed up. The app started with an empty/seed connection list '
            'and has not overwritten the file. Your saved connections may be '
            'missing, so inspect the file before saving new ones.'
      : 'The connections.json file could not be parsed; the original file was '
            'backed up as $backup. The app started with an empty/seed connection '
            'list, so your saved connections may be missing. Check the file and, if '
            'needed, restore your connections from the backup and restart the app.';
  final detail = _storeErrorDetail(text);
  final notice = pickText(zh, en);
  if (detail.isEmpty) return notice;
  return '$notice\n${pickText('详情：', 'Details: ')}$detail';
}
