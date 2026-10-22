// Smoke tests for the desktop port.
//
// These deliberately avoid a live database: they cover the pure helpers and
// the i18n dictionary, which are the parts most likely to drift from the web
// app during a refactor. End-to-end behaviour is verified against real
// databases by the Rust integration tests and the manual checklist.

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';
import 'package:rust_myadmin_desktop/src/i18n_keys.g.dart';
import 'package:rust_myadmin_desktop/src/nav.dart';
import 'package:rust_myadmin_desktop/src/views/result_table.dart';

void main() {
  group('i18n', () {
    test('ships both languages for every key', () {
      expect(zhDict.length, greaterThan(400));
      expect(enDict.length, zhDict.length);
      for (final key in zhDict.keys) {
        expect(enDict.containsKey(key), isTrue, reason: 'missing en for $key');
      }
    });

    test('falls back to the key itself when missing', () {
      expect(t('definitely_not_a_key'), 'definitely_not_a_key');
    });

    test('switches language', () {
      I18n.setLang(AppLang.en);
      expect(t('save'), 'Save');
      I18n.setLang(AppLang.zh);
      expect(t('save'), '保存');
    });
  });

  group('displayCell', () {
    test('renders null as empty', () {
      expect(displayCell(null), '');
    });

    test('renders a binary marker as a blob chip', () {
      expect(displayCell({'__binary__': 'AAAA', 'len': 3}), '[BLOB 3 bytes]');
    });

    test('renders objects as JSON', () {
      expect(displayCell({'a': 1}), contains('"a"'));
    });

    test('renders scalars verbatim', () {
      expect(displayCell(42), '42');
      expect(displayCell('x'), 'x');
    });
  });

  group('formatBytes', () {
    test('humanises sizes like the web helper', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1024), '1.00 KB');
      expect(formatBytes(1024 * 1024), '1.00 MB');
      expect(formatBytes(null), '—');
    });
  });

  group('inferSingleTable', () {
    const columns = [
      {'name': 'id', 'type_name': 'INT'},
    ];

    test('accepts a plain single-table select', () {
      expect(inferSingleTable('SELECT * FROM users', columns), 'users');
      expect(inferSingleTable('SELECT * FROM `db`.`users`', columns), 'users');
    });

    test('rejects joins and unions', () {
      expect(inferSingleTable('SELECT * FROM a JOIN b ON a.id = b.id', columns),
          isNull);
      expect(inferSingleTable('SELECT 1 UNION SELECT 2', columns), isNull);
    });

    test('rejects non-selects', () {
      expect(inferSingleTable('UPDATE users SET a = 1', columns), isNull);
    });
  });

  group('AppRoute', () {
    test('marks connection-dependent sections', () {
      expect(AppRoute.sql.needsConnection, isTrue);
      expect(AppRoute.backups.needsConnection, isTrue);
      expect(AppRoute.connections.needsConnection, isFalse);
      expect(AppRoute.history.needsConnection, isFalse);
      expect(AppRoute.database('x').needsConnection, isTrue);
    });

    test('compares by value so navigation can skip redundant rebuilds', () {
      expect(AppRoute.database('a'), AppRoute.database('a'));
      expect(AppRoute.database('a'), isNot(AppRoute.database('b')));
    });
  });
}
