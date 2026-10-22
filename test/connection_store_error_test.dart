//! Regression tests for the P6 startup banner (connections.json corruption).
//!
//! These are pure Dart tests: the Rust store side is covered by
//! `cargo test --lib` (connections::tests + api::connections::tests). Here we
//! pin the two halves the UI owns:
//!
//!  * the `listConnections` payload -> "is there a startup error to show?";
//!  * that error -> the dismissible banner copy, in both UI languages.
//!
//! No FFI library is loaded and no global Rust state is initialized.

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/connection_store_notice.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';

const _dir =
    '/Users/me/Library/Application Support/com.rustmyadmin.rustMyadminDesktop';
const _livePath = '$_dir/connections.json';
const _backupName = 'connections.json.corrupt-20261021T022049Z.json';
const _backupPath = '$_dir/$_backupName';

/// Mirrors the message ConnectionStore::load() produces when it preserved the
/// corrupt file as `connections.json.corrupt-<UTC stamp>.json`.
String _corruptError({String detail = 'expected value at line 1 column 2'}) =>
    '连接配置文件无法解析（$_livePath）：$detail；原文件已原样保留为 $_backupPath';

/// Mirrors the message when preserving the corrupt file itself failed: the
/// store then refuses to overwrite the only copy.
String _unpreservedError({
  String detail = 'expected value at line 1 column 2',
}) => '连接配置文件无法解析（$_livePath）：$detail；且原文件备份失败，本次不会覆盖该文件';

void main() {
  tearDown(() => I18n.setLang(AppLang.zh));

  group('connectionsStoreErrorFromPayload', () {
    test('normal payloads mean "show no banner"', () {
      expect(connectionsStoreErrorFromPayload(null), isNull);
      expect(connectionsStoreErrorFromPayload('not a map'), isNull);
      expect(connectionsStoreErrorFromPayload(<String, dynamic>{}), isNull);
      expect(
        connectionsStoreErrorFromPayload(<String, dynamic>{
          'connections': <Object>[],
          'store_error': null,
        }),
        isNull,
        reason: 'a healthy store reports store_error: null',
      );
      expect(
        connectionsStoreErrorFromPayload(<String, dynamic>{
          'store_error': '  ',
        }),
        isNull,
      );
      // The view composes "payload -> error -> banner"; a normal payload must
      // therefore never reach AlertBox.
      expect(
        connectionsStoreNotice(
          connectionsStoreErrorFromPayload(<String, dynamic>{
            'connections': <Object>[],
            'store_error': null,
          }),
        ),
        isNull,
      );
    });

    test('a corrupt-file error is surfaced from the payload', () {
      final payload = <String, dynamic>{
        'connections': <Object>[],
        'store_error': _corruptError(),
      };
      final error = connectionsStoreErrorFromPayload(payload);
      expect(error, _corruptError());
      expect(connectionsStoreNotice(error), isNotNull);
    });
  });

  group('connectionsStoreNotice', () {
    test('Chinese banner names the backup, the seed fallback and the fix', () {
      I18n.setLang(AppLang.zh);
      final notice = connectionsStoreNotice(_corruptError())!;
      expect(notice, contains('connections.json 解析失败'));
      expect(notice, contains('原文件已原样备份为 $_backupPath'));
      expect(notice, contains(_backupName));
      expect(notice, contains('空/种子'));
      expect(notice, contains('建议检查该文件'));
      expect(notice, contains('详情：'));
      expect(notice, contains('expected value at line 1 column 2'));
    });

    test(
      'English banner is fully English apart from the diagnostic detail',
      () {
        I18n.setLang(AppLang.en);
        final notice = connectionsStoreNotice(_corruptError())!;
        expect(
          notice,
          contains('The connections.json file could not be parsed'),
        );
        expect(notice, contains('backed up as $_backupPath'));
        expect(notice, contains('empty/seed'));
        expect(notice, contains('restore your connections from the backup'));
        expect(notice, contains('Details: expected value at line 1 column 2'));
        // The user-facing copy must not leak the Chinese wrapper sentence.
        expect(notice, isNot(contains('解析失败')));
        expect(notice, isNot(contains('原文件已原样备份')));
      },
    );

    test('failed backup warns that the file was not overwritten', () {
      I18n.setLang(AppLang.zh);
      final notice = connectionsStoreNotice(_unpreservedError())!;
      expect(notice, contains('备份失败'));
      expect(notice, contains('没有覆盖该文件'));
      expect(notice, isNot(contains('corrupt-')));
    });

    test('failed backup is explained in English too', () {
      I18n.setLang(AppLang.en);
      final notice = connectionsStoreNotice(_unpreservedError())!;
      expect(notice, contains('could not be backed up'));
      expect(notice, contains('has not overwritten the file'));
      expect(notice, contains('Details: expected value at line 1 column 2'));
    });

    test('empty error never renders', () {
      expect(connectionsStoreNotice(null), isNull);
      expect(connectionsStoreNotice(''), isNull);
      expect(connectionsStoreNotice('   '), isNull);
    });
  });
}
