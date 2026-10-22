// Pure-function coverage for the round34 fixes that have no UI harness:
// enum/set insert validation (P3-01), SQLite size labels (P3-03), hidden-object
// counts (P2-03) and the MySQL connection charset list (P2-02).

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/db_options.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';
import 'package:rust_myadmin_desktop/src/views/database_view.dart';
import 'package:rust_myadmin_desktop/src/views/table_view.dart';

void main() {
  setUp(() => I18n.setLang(AppLang.zh));
  tearDown(() => I18n.setLang(AppLang.zh));

  group('enum / set insert validation (P3-01)', () {
    const rating = "enum('G','PG','PG-13','R','NC-17')";

    test('the declared values are parsed out of COLUMN_TYPE', () {
      expect(enumColumnOptions(rating), <String>['G', 'PG', 'PG-13', 'R', 'NC-17']);
      expect(setColumnOptions("set('a','b')"), <String>['a', 'b']);
      expect(enumColumnOptions('varchar(10)'), isNull);
      expect(enumColumnOptions(null), isNull);
      expect(enumColumnOptions('ENUM(\'x\')'), <String>['x']);
    });

    test("a doubled quote inside a value stays one apostrophe", () {
      expect(enumColumnOptions("enum('it''s','ok')"), <String>["it's", 'ok']);
    });

    test('an out-of-range enum value is rejected before the server sees it', () {
      final error = typedValueError('rating', rating, '19.99');
      expect(error, isNotNull);
      expect(error, contains('rating'));
      expect(error, contains('PG-13'));
      expect(typedValueError('rating', rating, 'PG-13'), isNull);
      // Values are case sensitive: the column definition is the source.
      expect(typedValueError('rating', rating, 'pg-13'), isNotNull);
    });

    test('a set accepts several declared values and rejects unknown ones', () {
      expect(typedValueError('tags', "set('a','b')", 'a,b'), isNull);
      expect(typedValueError('tags', "set('a','b')", ' a , b '), isNull);
      expect(typedValueError('tags', "set('a','b')", 'a,c'), isNotNull);
      // Non enum/set columns are left to the driver's own coercion.
      expect(typedValueError('name', 'varchar(10)', 'anything'), isNull);
    });

    test("MySQL's truncation error is mapped back to its column", () {
      expect(
          truncatedColumnName(
              'Data truncated for column \'rating\' at row 1 (1265)'),
          'rating');
      expect(truncatedColumnName('some other failure'), isNull);
      expect(truncatedColumnName(null), isNull);
    });
  });

  group('SQLite size labelling (P3-03)', () {
    test('a measured table shows its data plus index bytes', () {
      expect(
          tableSizeLabel(<String, dynamic>{
            'data_length': 1024,
            'index_length': 1024,
          }),
          '2.00 KB');
    });

    test('a file-level fallback says so instead of showing a dash', () {
      final label = tableSizeLabel(<String, dynamic>{
        'size_scope': 'file',
        'file_size': 4096,
      });
      expect(label, contains('文件级'));
      expect(label, contains('4.00 KB'));
    });

    test('a view with neither number keeps the dash', () {
      expect(tableSizeLabel(<String, dynamic>{'name': 'v'}), '—');
      expect(tableSizeLabel(<String, dynamic>{'size_scope': 'none'}), '—');
    });
  });

  group('hidden object counts (P2-03)', () {
    test('the driver-reported hidden counts are summed', () {
      expect(
          hiddenObjectCount(<String, dynamic>{
            'hidden': <String, dynamic>{'routines': 9, 'triggers': 15},
          }),
          24);
    });

    test('a driver without the metadata reports nothing hidden', () {
      expect(hiddenObjectCount(<String, dynamic>{}), 0);
      expect(hiddenObjectCount(<String, dynamic>{'hidden': 'nope'}), 0);
    });
  });

  group('MySQL connection charsets (P2-02)', () {
    test('utf8mb3 is not offered, utf8 is', () {
      final list = connectionCharsetsFor('mysql');
      expect(list, contains('utf8mb4'));
      expect(list, contains('utf8'));
      expect(list, isNot(contains('utf8mb3')));
    });

    test("the server's list narrows but never re-introduces utf8mb3", () {
      final list = connectionCharsetsFor('mysql', meta: <String, dynamic>{
        'charsets': <dynamic>[
          <String, dynamic>{'charset': 'utf8mb3'},
          <String, dynamic>{'charset': 'utf8mb4'},
          <String, dynamic>{'charset': 'latin1'},
        ],
      });
      expect(list, <String>['utf8mb4', 'latin1']);
    });

    test('unknown server names fall back to the driver list', () {
      final list = connectionCharsetsFor('mysql', meta: <String, dynamic>{
        'charsets': <dynamic>[
          <String, dynamic>{'charset': 'weird1'},
        ],
      });
      expect(list, mysqlConnectionCharsets);
    });

    test('other drivers have no connection charset', () {
      expect(connectionCharsetsFor('postgres'), isEmpty);
      expect(connectionCharsetsFor('sqlite'), isEmpty);
    });
  });
}
