// Regression tests for the query-history preview bounds.
//
// Symptom: after a multi-megabyte script was executed, opening 查询历史 froze
// the app: every visible row handed the whole statement to TextPainter/Tooltip,
// and history_list() shipped all of it over FFI. The helpers below bound both the
// row preview and the full-SQL dialog.

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/history_preview.dart';

Map<String, dynamic> entry({
  required String sql,
  bool truncated = false,
  int? chars,
}) =>
    <String, dynamic>{
      'sql': sql,
      'sql_truncated': truncated,
      'sql_chars': chars ?? sql.length,
    };

void main() {
  test('preview is bounded and ellipsized for very long SQL', () {
    final huge = 'SELECT 1;' * 100000;
    final preview = historySqlPreview(entry(sql: huge, truncated: true, chars: huge.length));
    expect(preview.length, lessThanOrEqualTo(historyPreviewChars + 1));
    expect(preview.endsWith('…'), isTrue);
    // The tooltip/preview path never receives the multi-megabyte text.
    expect(preview.length, lessThan(huge.length));
  });

  test('short SQL is shown unchanged', () {
    const sql = 'SELECT * FROM film LIMIT 10';
    expect(historySqlPreview(entry(sql: sql)), sql);
    expect(historySqlDisplay(entry(sql: sql)), sql);
  });

  test('truncated flag and original length survive the payload', () {
    final payload = entry(sql: 'X' * 100, truncated: true, chars: 1234567);
    expect(historySqlTruncated(payload), isTrue);
    expect(historySqlChars(payload), 1234567);
  });

  test('display is capped even for an untruncated oversized payload', () {
    final huge = 'Y' * (historyDialogRenderChars + 5000);
    final shown = historySqlDisplay(entry(sql: huge));
    expect(shown.length, historyDialogRenderChars);
  });

  test('missing metadata falls back to the stored SQL length', () {
    final legacy = <String, dynamic>{'sql': 'SELECT 1'};
    expect(historySqlTruncated(legacy), isFalse);
    expect(historySqlChars(legacy), 8);
    expect(historySqlPreview(legacy), 'SELECT 1');
  });
}
