import 'api.dart';

/// Maximum characters rendered in one history row preview (and its tooltip).
///
/// The store already caps a stored entry at 32 K characters, but a row preview
/// must be far shorter: laying out a multi-kilobyte string in every visible row
/// is what made the history page freeze after a large script was imported.
const int historyPreviewChars = 400;

/// Maximum characters the "full SQL" dialog renders at once.
///
/// The Rust store caps at 32 K; older files are compacted on load, so this is a
/// defensive bound for payloads that bypass the store.
const int historyDialogRenderChars = 32 * 1024;

/// The SQL text carried by a history entry (bounded by the Rust store).
String historySqlText(Json entry) => (entry['sql'] ?? '').toString();

/// True when the stored SQL is only a prefix of the executed script.
bool historySqlTruncated(Json entry) => entry['sql_truncated'] == true;

/// Original length of the executed SQL in characters.
int historySqlChars(Json entry) {
  final value = (entry['sql_chars'] as num?)?.toInt();
  if (value != null && value > 0) return value;
  return historySqlText(entry).length;
}

/// One-line preview used by the table row and its hover tooltip.
String historySqlPreview(Json entry, {int maxChars = historyPreviewChars}) {
  final sql = historySqlText(entry);
  if (sql.length <= maxChars) return sql;
  return '${sql.substring(0, maxChars)}…';
}

/// Text the full-SQL dialog can safely render (never the whole multi-MB script).
String historySqlDisplay(Json entry, {int maxChars = historyDialogRenderChars}) {
  final sql = historySqlText(entry);
  if (sql.length <= maxChars) return sql;
  return sql.substring(0, maxChars);
}
