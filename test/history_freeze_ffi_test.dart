// End-to-end regression for the query-history freeze.
//
// A multi-megabyte script used to be copied into query_history.json verbatim.
// Opening 查询历史 then froze: every visible row handed the full statement to
// TextPainter/Tooltip, and history_list() shipped all of it over FFI.
//
// This test loads a synthetic 20 MB history through the real Rust library and
// checks the three layers of the fix:
//   1. the store caps each SQL at 32 K characters and flags it;
//   2. startup compacts the oversized file and keeps query_history.json.bak;
//   3. the history page renders with bounded EllipsisText inputs.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/history_preview.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/history_view.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('rma-history-freeze-');
    // ~700 KB per entry x 30 = ~21 MB, the shape that used to make the page
    // unresponsive and query_history.json tens of megabytes.
    final huge = 'SELECT 1;\n' * 70000;
    final entries = <Map<String, dynamic>>[
      for (var i = 0; i < 30; i++)
        <String, dynamic>{
          'id': 'h-$i',
          'user': 'local',
          'sql': huge,
          'database': 'db',
          'at': '2026-10-21T00:00:${i.toString().padLeft(2, '0')}+00:00',
          'ok': true,
          'statements': 1,
          'failed': 0,
          'elapsed_ms': 1,
        },
    ];
    File('${dir.path}/query_history.json').writeAsStringSync(jsonEncode(entries));

    await RustLib.init(
        externalLibrary:
            ExternalLibrary.open('rust/target/debug/librust_myadmin_core.dylib'));
    await Api.init(dir.path);
  });

  tearDownAll(() async {
    await dir.delete(recursive: true);
  });

  testWidgets('huge history is capped, compacted and rendered bounded',
      (tester) async {
    final payload = await tester.runAsync(() => Api.instance.history(200)) ?? <Json>[];
    expect(payload.length, 30);
    expect(
      payload.every((entry) => (entry['sql'] as String).length <= 32768),
      isTrue,
      reason: 'history_list must not ship multi-megabyte SQL over FFI',
    );
    expect(payload.first['sql_truncated'], isTrue);
    expect(payload.first['sql_chars'], greaterThan(600000));

    // Pagination is done in Rust: a page asks for only its own rows, and the
    // payload reports the total so the pager can show "page N / M".
    final page2 = await tester.runAsync(
            () => Api.instance.historyPage(limit: 10, offset: 10)) ??
        <String, dynamic>{};
    expect(page2['total'], 30);
    expect((page2['history'] as List).length, 10);

    // Startup migration: compacted file + original bytes preserved as .bak.
    final compacted = File('${dir.path}/query_history.json').lengthSync();
    expect(compacted, lessThan(3 * 1024 * 1024),
        reason: 'oversized query_history.json was not compacted');
    final backup = File('${dir.path}/query_history.json.bak');
    expect(backup.existsSync(), isTrue, reason: 'original history was not preserved');

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: HistoryView(notice: Notice())),
    ));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(tester.takeException(), isNull);
    final texts = tester
        .widgetList<EllipsisText>(find.byType(EllipsisText))
        .map((widget) => widget.text)
        .toList();
    expect(texts, isNotEmpty);
    expect(
      texts.every((text) => text.length <= historyPreviewChars + 1),
      isTrue,
      reason: 'row previews must not receive the whole statement: '
          '${texts.map((text) => text.length).toList()}',
    );
  });
}
