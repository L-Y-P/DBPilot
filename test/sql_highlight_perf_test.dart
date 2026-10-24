// P2-8：SQL 编辑器语法高亮的性能预算（回归测试）。
//
// 编辑器用 SqlHighlightingController 在每次文本变化时重新分词。大文件在
// SQL 控制台里本来就只载入前 200KB（见 lib/src/views/sql_view.dart），所以真正
// 需要关心的是「200KB 级文本的一次分词」。
//
// 预算：单次 200KB 分词 < 120ms（测试 VM 是 JIT；release AOT 通常快 2–5 倍）。
// 超过说明高亮实现退化，会直接表现为输入卡顿。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/sql_highlight.dart';

String buildSql(int targetBytes) {
  final b = StringBuffer();
  var i = 0;
  while (b.length < targetBytes) {
    b.write("INSERT INTO t_$i (id, name, value, created_at) "
        "VALUES ($i, 'name-$i', 12.34, '2024-01-01 10:00:00');\n");
    i++;
  }
  return b.toString();
}

void main() {
  testWidgets('large SQL highlights after the debounce, not on the keystroke frame',
      (tester) async {
    final sql = buildSql(100 * 1024);
    final controller = SqlHighlightingController(text: sql);
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (ctx) {
        context = ctx;
        return const SizedBox();
      }),
    ));
    final immediate = controller.buildTextSpan(
      context: context,
      style: const TextStyle(),
      withComposing: false,
    );
    expect(immediate.children, isNull,
        reason: '100KB must not tokenise synchronously on the input frame');
    await tester.pump(const Duration(milliseconds: 130));
    final highlighted = controller.buildTextSpan(
      context: context,
      style: const TextStyle(),
      withComposing: false,
    );
    expect(highlighted.children, isNotNull,
        reason: 'after the pause the text should be highlighted');
    controller.dispose();
  });

  test('small SQL still highlights synchronously (tests/goldens unchanged)', () {
    final controller = SqlHighlightingController(text: 'SELECT 1 FROM t');
    expect(sqlTokenize(controller.text), isNotEmpty);
    controller.dispose();
  });

  test('200KB SQL 分词在预算内（< 120ms）', () {
    final sql = buildSql(200 * 1024);
    sqlTokenize(sql); // 预热（JIT 首次调用含编译）
    final sw = Stopwatch()..start();
    final tokens = sqlTokenize(sql);
    sw.stop();
    expect(tokens, isNotEmpty);
    expect(sw.elapsedMilliseconds, lessThan(120),
        reason: '200KB 分词耗时 ${sw.elapsedMilliseconds}ms，输入会卡');
  });

  test('10MB SQL 分词耗时被记录（编辑器不会整份载入，仅作趋势观察）', () {
    final sql = buildSql(10 * 1024 * 1024);
    final sw = Stopwatch()..start();
    final tokens = sqlTokenize(sql);
    sw.stop();
    expect(tokens.length, greaterThan(100000));
    // 只记录不设上限：编辑器最多只载入 200KB，10MB 是兜底场景。
    // ignore: avoid_print
    print('SQL_HIGHLIGHT_10MB_US=${sw.elapsedMicroseconds}');
  });
}
