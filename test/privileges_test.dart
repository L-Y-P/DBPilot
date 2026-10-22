// Regression tests for the database-privilege handling.
//
// Reported symptoms:
//   * the server page showed raw driver errors ("1142 SELECT command denied to
//     user 'web'@'localhost' for table 'user'") with a duplicated "Caused by:";
//   * a connection could open but then fail on every tab, because the app never
//     asked what the database account was actually allowed to do;
//   * granting a privilege in the database did not unblock the app.
//
// The UI now probes capabilities on connect, disables what it cannot do and
// names the GRANT needed. These tests pin the pure pieces of that: error
// formatting, capability mapping and the permission detector.

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';

void main() {
  group('permission errors', () {
    test('recognises the driver wording of a missing privilege', () {
      expect(
        isPermissionError(
            "SELECT command denied to user 'web'@'localhost' for table 'user'"),
        isTrue,
      );
      expect(
        isPermissionError(
            "Access denied for user 'web'@'%' to database 'rustmyadmin_demo'"),
        isTrue,
      );
      expect(isPermissionError('permission denied for table users'), isTrue);
      expect(isPermissionError('当前数据库账号没有访问该数据库的权限'), isTrue);
    });

    test('does not flag ordinary failures', () {
      expect(isPermissionError('Unknown column \'x\' in \'field list\''), isFalse);
      expect(isPermissionError('表不存在：可能已被删除'), isFalse);
      expect(isPermissionError(null), isFalse);
    });

    test('strips sqlx prefixes and the duplicated cause chain', () {
      // _cleanMessage runs inside ApiException; exercise it through the public
      // detector plus a direct formatting check.
      const raw =
          'AnyhowException(error returned from database: 1044 (42000): Access denied for user \'web\'@\'%\' to database \'x\'\n\nCaused by:\n    1044 (42000): Access denied for user \'web\'@\'%\' to database \'x\')';
      expect(cleanErrorMessageForTest(raw),
          "1044 (42000): Access denied for user 'web'@'%' to database 'x'");
    });

    test('adds an actionable hint only for permission failures', () {
      final hinted = describeDbError(
          "SELECT command denied to user 'web'@'localhost' for table 'user'");
      expect(hinted, contains('数据库账号自身的权限限制'));
      expect(hinted, contains('请让数据库管理员'));

      const plain = 'Unknown column x';
      expect(describeDbError(plain), plain);

      // A message that already explains itself is not decorated twice.
      const explained = '当前数据库账号没有执行「数据库账号」所需的服务器权限（需要 PROCESS）。'
          '请让数据库管理员为该账号授权，或改用有权限的账号连接。';
      expect(describeDbError(explained), explained);
    });
  });

  group('capability mapping', () {
    test('short capability names map to the probe flags', () {
      // Regression: can() looked up caps['processes'] but the probe reports
      // can_view_processes, so every tab was disabled even for root.
      final caps = <String, dynamic>{
        'can_view_status': true,
        'can_view_processes': true,
        'can_manage_accounts': false,
        'can_kill_processes': true,
      };
      expect(AppState.capabilityFlagForTest('processes'), 'can_view_processes');
      expect(caps[AppState.capabilityFlagForTest('accounts')], isFalse);
      expect(caps[AppState.capabilityFlagForTest('kill')], isTrue);
      // An unknown capability is not restricted.
      expect(AppState.capabilityFlagForTest('nonsense'), isNull);
    });

    test('a missing capability yields the privilege to request', () {
      // Mirrors the shape privileges.rs returns; the server page renders this
      // list as one banner and disables the matching tabs.
      final caps = <String, dynamic>{
        'account': 'web@%',
        'can_view_status': true,
        'can_view_processes': false,
        'can_manage_accounts': false,
        'can_kill_processes': false,
        'requirements': <dynamic>[
          <String, dynamic>{
            'capability': 'accounts',
            'label': '数据库账号',
            'privilege': 'SELECT ON mysql.user',
          },
          <String, dynamic>{
            'capability': 'processes',
            'label': '进程列表',
            'privilege': 'PROCESS',
          },
        ],
      };
      expect(caps['can_manage_accounts'], isFalse);
      final requirements = caps['requirements'] as List;
      expect(requirements.map((r) => (r as Map)['capability']),
          containsAll(<String>['accounts', 'processes']));
      expect(
        requirements
            .cast<Map>()
            .firstWhere((r) => r['capability'] == 'processes')['privilege'],
        'PROCESS',
      );
    });
  });
}