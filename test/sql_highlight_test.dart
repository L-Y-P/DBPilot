// SQL console syntax highlighting: tokenizer classification and controller
// span building (the console must keep long scripts cheap to render).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/sql_highlight.dart';

String kindOf(List<SqlToken> tokens, String text) {
  for (final token in tokens) {
    if (token.text == text) return token.kind.name;
  }
  return 'missing';
}

void main() {
  test('tokenizer classifies keywords, strings, numbers and comments', () {
    final tokens = sqlTokenize(
      "SELECT COUNT(*) FROM users WHERE id = 42 AND name = 'Ada' -- note\n"
      '/* block */ UPDATE t SET x = 1.5e3, y = 0xFF;',
    );
    expect(kindOf(tokens, 'SELECT'), 'keyword');
    expect(kindOf(tokens, 'FROM'), 'keyword');
    expect(kindOf(tokens, 'WHERE'), 'keyword');
    expect(kindOf(tokens, "'Ada'"), 'string');
    expect(kindOf(tokens, '42'), 'number');
    expect(kindOf(tokens, '1.5e3'), 'number');
    expect(kindOf(tokens, '0xFF'), 'number');
    expect(kindOf(tokens, '-- note'), 'comment');
    expect(kindOf(tokens, '/* block */'), 'comment');
    expect(
        tokens.any((t) => t.kind == SqlTokenKind.plain && t.text.contains('COUNT')),
        isTrue);
  });

  test('tokenizer handles quoted identifiers and doubled quotes', () {
    final tokens = sqlTokenize(
      'SELECT `weird name`, "quoted id" FROM t;',
    );
    expect(kindOf(tokens, '`weird name`'), 'identifier');
    expect(kindOf(tokens, '"quoted id"'), 'identifier');
  });

  test('tokenizer keeps the whole text across token boundaries', () {
    const sql = "SELECT * FROM t WHERE name = 'a''b' AND n = 12;";
    final rebuilt = sqlTokenize(sql).map((t) => t.text).join();
    expect(rebuilt, sql);
  });

  testWidgets('controller renders coloured spans for SQL keywords',
      (tester) async {
    final controller =
        SqlHighlightingController(text: 'SELECT * FROM t WHERE id = 1 -- c');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TextField(controller: controller)),
    ));
    final context = tester.element(find.byType(TextField));
    final span = controller.buildTextSpan(
      context: context,
      style: const TextStyle(color: Colors.black),
      withComposing: false,
    );
    final children = span.children ?? const <InlineSpan>[];
    expect(children, isNotEmpty);
    final keyword = children.whereType<TextSpan>().where(
        (s) => s.style?.color == SqlSyntaxColors.keyword);
    expect(keyword.map((s) => s.text).toList(),
        containsAll(<String>['SELECT', 'FROM', 'WHERE']));
    final comment = children.whereType<TextSpan>().where(
        (s) => s.style?.color == SqlSyntaxColors.comment);
    expect(comment.map((s) => s.text).toList(), contains('-- c'));
  });

  testWidgets('very long scripts render as one plain span', (tester) async {
    final long = 'SELECT 1;\n' * 13000;
    expect(long.length,
        greaterThan(SqlHighlightingController.maxHighlightChars));
    final controller = SqlHighlightingController(text: long);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TextField(controller: controller, maxLines: 2)),
    ));
    final context = tester.element(find.byType(TextField));
    final span = controller.buildTextSpan(
      context: context,
      style: const TextStyle(color: Colors.black),
      withComposing: false,
    );
    expect(span.text, long);
    expect(span.children, isNull);
  });
}
