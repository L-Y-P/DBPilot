import 'dart:async';

import 'package:flutter/material.dart';

import 'theme.dart';

/// Colours for the SQL console syntax highlighting. They sit next to the theme
/// tokens but are only used by the editor, so they stay in this file.
class SqlSyntaxColors {
  SqlSyntaxColors._();

  static const Color keyword = Color(0xFF1B5FAA);
  static const Color string = Color(0xFF1E7E46);
  static const Color number = Color(0xFF8A5A00);
  static const Color comment = Color(0xFF7A8794);
  static const Color identifier = Color(0xFF7A5BB0);
  static const Color operator = Color(0xFF46566E);
}

/// The class of one highlighted SQL token.
enum SqlTokenKind { plain, keyword, string, number, comment, identifier, operator }

/// One token produced by [sqlTokenize].
class SqlToken {
  const SqlToken(this.kind, this.text);
  final SqlTokenKind kind;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is SqlToken && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => '${kind.name}($text)';
}

/// A TextEditingController that paints SQL keywords/strings/comments/numbers.
///
/// The tokenizer is a single O(n) pass and longer scripts skip highlighting
/// entirely: a 1 MB SQL dump loaded into the console must not re-tokenize on
/// every keystroke.
class SqlHighlightingController extends TextEditingController {
  SqlHighlightingController({super.text});

  /// Text longer than this is rendered in a single plain span.
  static const int maxHighlightChars = 120 * 1024;

  /// Short SQL is tokenised synchronously (tests, small snippets); larger text
  /// is highlighted after a pause so a keystroke never pays the full 20–60 ms
  /// tokenizer cost on the frame.
  static const int syncHighlightChars = 8 * 1024;
  static const Duration debounce = Duration(milliseconds: 120);

  String? _cachedText;
  List<SqlToken>? _cachedTokens;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Test hook: tokenise the current text now instead of waiting for the
  /// debounce timer.
  void flushHighlight() {
    _timer?.cancel();
    final text = value.text;
    if (text.length > maxHighlightChars) {
      _cachedText = text;
      _cachedTokens = null;
    } else {
      _cachedText = text;
      _cachedTokens = sqlTokenize(text);
    }
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // While an IME is composing, defer to the default implementation so the
    // composing underline is rendered correctly for CJK input.
    if (withComposing && !value.composing.isCollapsed) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final base = style ?? kBody;
    final text = value.text;
    if (text.length > maxHighlightChars) {
      _timer?.cancel();
      _cachedText = text;
      _cachedTokens = null;
      return TextSpan(text: text, style: base);
    }
    if (text == _cachedText && _cachedTokens != null) {
      return _span(base, _cachedTokens!);
    }
    if (text.length <= syncHighlightChars) {
      _timer?.cancel();
      final tokens = sqlTokenize(text);
      _cachedText = text;
      _cachedTokens = tokens;
      return _span(base, tokens);
    }
    _schedule(text);
    return TextSpan(text: text, style: base);
  }

  void _schedule(String text) {
    _timer?.cancel();
    _timer = Timer(debounce, () {
      if (value.text != text) return;
      _cachedText = text;
      _cachedTokens = sqlTokenize(text);
      notifyListeners();
    });
  }

  TextSpan _span(TextStyle base, List<SqlToken> tokens) {
    if (tokens.length == 1 && tokens.first.kind == SqlTokenKind.plain) {
      return TextSpan(text: tokens.first.text, style: base);
    }
    return TextSpan(style: base, children: [
      for (final token in tokens)
        if (token.kind == SqlTokenKind.plain)
          TextSpan(text: token.text)
        else
          TextSpan(text: token.text, style: sqlTokenStyle(token.kind)),
    ]);
  }
}

/// The style of one token kind, layered on the monospace editor style.
TextStyle sqlTokenStyle(SqlTokenKind kind) {
  switch (kind) {
    case SqlTokenKind.keyword:
      return const TextStyle(
          color: SqlSyntaxColors.keyword, fontWeight: FontWeight.w600);
    case SqlTokenKind.string:
      return const TextStyle(color: SqlSyntaxColors.string);
    case SqlTokenKind.number:
      return const TextStyle(color: SqlSyntaxColors.number);
    case SqlTokenKind.comment:
      return const TextStyle(
          color: SqlSyntaxColors.comment, fontStyle: FontStyle.italic);
    case SqlTokenKind.identifier:
      return const TextStyle(color: SqlSyntaxColors.identifier);
    case SqlTokenKind.operator:
      return const TextStyle(color: SqlSyntaxColors.operator);
    case SqlTokenKind.plain:
      return const TextStyle();
  }
}

const Set<String> _sqlKeywords = <String>{
  'ADD', 'ALL', 'ALTER', 'ANALYZE', 'AND', 'AS', 'ASC', 'AUTO_INCREMENT',
  'BEGIN', 'BETWEEN', 'BIGINT', 'BINARY', 'BLOB', 'BOOL', 'BOOLEAN', 'BY',
  'CALL', 'CASCADE', 'CASE', 'CHANGE', 'CHAR', 'CHARACTER', 'CHECK', 'COLLATE',
  'COLUMN', 'COMMENT', 'COMMIT', 'CONSTRAINT', 'CREATE', 'CROSS', 'CURRENT_DATE',
  'CURRENT_TIMESTAMP', 'CURRENT_USER', 'DATABASE', 'DATABASES', 'DATE',
  'DATETIME', 'DECIMAL', 'DEFAULT', 'DELETE', 'DELIMITER', 'DESC', 'DESCRIBE',
  'DISTINCT', 'DOUBLE', 'DROP', 'ELSE', 'END', 'ENGINE', 'EVENT', 'EXISTS',
  'EXPLAIN', 'FALSE', 'FLOAT', 'FOR', 'FOREIGN', 'FROM', 'FULL', 'FUNCTION',
  'GRANT', 'GROUP', 'HAVING', 'IF', 'IN', 'INDEX', 'INNER', 'INSERT', 'INT',
  'INTEGER', 'INTERVAL', 'INTO', 'IS', 'JOIN', 'JSON', 'KEY', 'LEFT', 'LIKE',
  'LIMIT', 'LOCK', 'LONGTEXT', 'MATCH', 'MEDIUMINT', 'MODIFY', 'NATURAL',
  'NOT', 'NULL', 'NUMERIC', 'OFFSET', 'ON', 'OPTIMIZE', 'OR', 'ORDER', 'OUTER',
  'PRIMARY', 'PROCEDURE', 'READ', 'REAL', 'RECURSIVE', 'REFERENCES', 'RENAME',
  'REPLACE', 'RESTRICT', 'RETURNING', 'REVOKE', 'RIGHT', 'ROLLBACK', 'SCHEMA',
  'SELECT', 'SERIAL', 'SESSION', 'SET', 'SHOW', 'SMALLINT', 'START', 'TABLE',
  'TABLES', 'TEMPORARY', 'TEXT', 'THEN', 'TIME', 'TIMESTAMP', 'TINYINT', 'TO',
  'TRANSACTION', 'TRIGGER', 'TRUE', 'TRUNCATE', 'UNION', 'UNIQUE', 'UNSIGNED',
  'UPDATE', 'USE', 'USING', 'VALUE', 'VALUES', 'VARBINARY', 'VARCHAR', 'VIEW',
  'WHEN', 'WHERE', 'WITH', 'WRITE', 'YEAR',
};

/// Tokenize SQL for highlighting. Never throws; unknown characters stay plain.
List<SqlToken> sqlTokenize(String text) {
  final tokens = <SqlToken>[];
  final n = text.length;
  var i = 0;
  var plainStart = 0;

  void flushPlain(int end) {
    if (end > plainStart) {
      tokens.add(SqlToken(SqlTokenKind.plain, text.substring(plainStart, end)));
    }
  }

  void emit(SqlTokenKind kind, int start, int end) {
    flushPlain(start);
    tokens.add(SqlToken(kind, text.substring(start, end)));
    plainStart = end;
  }

  while (i < n) {
    final c = text.codeUnitAt(i);
    // Line comments: -- ... and MySQL # ...
    if ((c == 0x2D && i + 1 < n && text.codeUnitAt(i + 1) == 0x2D) || c == 0x23) {
      final end = _until(text, i, '\n', includeStop: false);
      emit(SqlTokenKind.comment, i, end);
      i = end;
      continue;
    }
    // Block comment: /* ... */
    if (c == 0x2F && i + 1 < n && text.codeUnitAt(i + 1) == 0x2A) {
      var end = i + 2;
      while (end < n) {
        if (text.codeUnitAt(end) == 0x2A &&
            end + 1 < n &&
            text.codeUnitAt(end + 1) == 0x2F) {
          end += 2;
          break;
        }
        end++;
      }
      emit(SqlTokenKind.comment, i, end);
      i = end;
      continue;
    }
    // Strings: single quotes, with '' and backslash escapes.
    if (c == 0x27 || c == 0x22) {
      final quote = c;
      var end = i + 1;
      while (end < n) {
        final cu = text.codeUnitAt(end);
        if (cu == 0x5C) {
          end += 2;
          continue;
        }
        if (cu == quote) {
          if (end + 1 < n && text.codeUnitAt(end + 1) == quote) {
            end += 2;
            continue;
          }
          end++;
          break;
        }
        end++;
      }
      if (end > n) end = n;
      emit(c == 0x22 ? SqlTokenKind.identifier : SqlTokenKind.string, i, end);
      i = end;
      continue;
    }
    // Quoted identifiers: backticks.
    if (c == 0x60) {
      var end = i + 1;
      while (end < n) {
        if (text.codeUnitAt(end) == 0x60) {
          if (end + 1 < n && text.codeUnitAt(end + 1) == 0x60) {
            end += 2;
            continue;
          }
          end++;
          break;
        }
        end++;
      }
      emit(SqlTokenKind.identifier, i, end);
      i = end;
      continue;
    }
    // Numbers: 123, 1.5, .5, 1e10, 0xFF.
    if (_isDigit(c) || (c == 0x2E && i + 1 < n && _isDigit(text.codeUnitAt(i + 1)))) {
      var end = i;
      var seenDot = false;
      var seenExp = false;
      while (end < n) {
        final cu = text.codeUnitAt(end);
        if (_isDigit(cu)) {
          end++;
        } else if (cu == 0x2E && !seenDot && !seenExp) {
          seenDot = true;
          end++;
        } else if ((cu == 0x65 || cu == 0x45) && !seenExp) {
          seenExp = true;
          end++;
          if (end < n &&
              (text.codeUnitAt(end) == 0x2B || text.codeUnitAt(end) == 0x2D)) {
            end++;
          }
        } else if (cu == 0x78 || cu == 0x58) {
          // hex prefix: 0xFF
          end++;
          while (end < n && _isHexDigit(text.codeUnitAt(end))) {
            end++;
          }
          break;
        } else {
          break;
        }
      }
      emit(SqlTokenKind.number, i, end);
      i = end;
      continue;
    }
    // Words: keywords or plain identifiers.
    if (_isWordStart(c) || c > 0x7F) {
      var end = i;
      while (end < n) {
        final cu = text.codeUnitAt(end);
        if (_isWordChar(cu) || cu > 0x7F) {
          end++;
        } else {
          break;
        }
      }
      final word = text.substring(i, end);
      if (_sqlKeywords.contains(word.toUpperCase())) {
        emit(SqlTokenKind.keyword, i, end);
      }
      // Plain identifiers keep the base colour; don't split the span.
      i = end;
      continue;
    }
    // Operators / punctuation.
    if (_isOperatorChar(c)) {
      var end = i + 1;
      while (end < n && _isOperatorChar(text.codeUnitAt(end))) {
        end++;
      }
      emit(SqlTokenKind.operator, i, end);
      i = end;
      continue;
    }
    i++;
  }
  flushPlain(n);
  return tokens;
}

int _until(String text, int start, String stop, {required bool includeStop}) {
  final index = text.indexOf(stop, start + 1);
  if (index < 0) return text.length;
  return includeStop ? index + stop.length : index;
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
bool _isHexDigit(int c) =>
    _isDigit(c) ||
    (c >= 0x61 && c <= 0x66) ||
    (c >= 0x41 && c <= 0x46);
bool _isWordStart(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F;
bool _isWordChar(int c) => _isWordStart(c) || _isDigit(c) || c == 0x24;
bool _isOperatorChar(int c) {
  const chars = '=<>!+-*/%|&^~:(),.;[]{}@?';
  return chars.codeUnits.contains(c);
}