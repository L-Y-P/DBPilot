// Pure unit tests for the guided-import rule model and job polling helpers.

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/import_rules.dart';

void main() {
  group('escape helpers', () {
    test('decodeEscapes turns typed escape sequences into characters', () {
      expect(decodeEscapes(r'\n'), '\n');
      expect(decodeEscapes(r'\t'), '\t');
      expect(decodeEscapes(r'\r'), '\r');
      expect(decodeEscapes(r'\\'), r'\');
      expect(decodeEscapes(r'\N'), r'\N');
      expect(decodeEscapes('plain'), 'plain');
      expect(decodeEscapes(r'\n\n'), '\n\n');
    });

    test('encodeEscapes round-trips control characters', () {
      for (final value in <String>['\n', '\t', '\r', '\u0000', ',', '|']) {
        expect(decodeEscapes(encodeEscapes(value)), value);
      }
      expect(encodeEscapes('\n'), r'\n');
    });
  });

  group('rule serialization', () {
    test('read rule survives the JSON round-trip', () {
      final rule = ImportReadRule(
        mode: 'wrapped',
        wrapperStart: '[',
        wrapperEnd: ']',
        recordSep: ',',
        quote: '"',
        balance: false,
        skipBlank: false,
        trim: false,
      );
      final restored =
          ImportReadRule.fromJson(Map<String, dynamic>.from(rule.toJson()));
      expect(restored.mode, 'wrapped');
      expect(restored.wrapperStart, '[');
      expect(restored.wrapperEnd, ']');
      expect(restored.recordSep, ',');
      expect(restored.balance, isFalse);
      expect(restored.skipBlank, isFalse);
      expect(restored.trim, isFalse);
    });

    test('field and mapping rules serialize to the Rust contract keys', () {
      final field = ImportFieldRule(
          mode: 'json', fieldSep: '|', quote: "'", header: true);
      final json = field.toJson();
      expect(json['mode'], 'json');
      expect(json['field_sep'], '|');
      expect(json['quote'], "'");
      expect(json['header'], isTrue);

      final mapping = ImportMappingRule(columns: [
        ImportColumnMap(column: 'id', source: 'id'),
        ImportColumnMap(column: 'age', source: 2),
      ]);
      final mapJson = mapping.toJson();
      expect((mapJson['columns'] as List).length, 2);
      expect((mapJson['columns'] as List).first['source'], 'id');
      expect((mapJson['columns'] as List).last['source'], 2);
      expect(mapJson['null_tokens'], <String>[r'\N']);
    });
  });

  group('auto mapping', () {
    test('keyed mapping matches names case-insensitively in table order', () {
      final mapped = autoMapKeyed(
        <String>['ID', 'Name', 'extra'],
        <String>['name', 'id', 'note'],
      );
      expect(mapped.map((m) => m.column).toList(), <String>['name', 'id']);
      expect(mapped[0].source, 'Name');
      expect(mapped[1].source, 'ID');
      expect(mapped.map((m) => m.source).every((s) => s is String), isTrue);
    });

    test('positional mapping skips auto-increment columns when possible', () {
      final mapped = autoMapPositional(
        2,
        <String>['id', 'name', 'age'],
        autoIncrementColumns: <String>{'id'},
      );
      expect(mapped.map((m) => m.column).toList(), <String>['name', 'age']);
      expect(mapped.map((m) => m.source).toList(), <int>[0, 1]);
    });

    test('positional mapping falls back when there are not enough columns', () {
      final mapped = autoMapPositional(
        3,
        <String>['id', 'name'],
        autoIncrementColumns: <String>{'id'},
      );
      expect(mapped.map((m) => m.column).toList(), <String>['id', 'name']);
    });
  });

  group('position labels', () {
    test('recordPositionLabel formats line, record and byte offset', () {
      expect(recordPositionLabel(12, 1024, 8), '第 12 行（第 9 条，字节 1024）');
      expect(recordPositionLabel(3, 40), '第 3 行（字节 40）');
    });

    test('issuePositionLabel appends the problem message', () {
      expect(
        issuePositionLabel(<String, dynamic>{
          'line': 5,
          'offset': 120,
          'index': 2,
          'message': '字段数不符',
        }),
        '第 5 行（第 3 条，字节 120）：字段数不符',
      );
    });
  });

  test('formatCount groups thousands', () {
    expect(formatCount(0), '0');
    expect(formatCount(999), '999');
    expect(formatCount(50000), '50,000');
    expect(formatCount(1234567), '1,234,567');
  });
}
