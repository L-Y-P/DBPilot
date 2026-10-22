// Regression tests for the P12 permission-UI behaviour and the P10 server-page
// wording.
//
// The UI cannot know in advance whether an account may CREATE TABLE / DROP
// DATABASE / TRUNCATE in a given schema: the server capability probe only
// reports instance-level flags. So a permission failure is learned, remembered
// per connection+database+action, and the matching button is greyed out. These
// tests pin that pure logic plus the timeout / permission / generic wording of
// the per-panel server errors, without needing a database.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/views/server_view.dart';

void main() {
  final state = AppState.instance;
  Map<String, dynamic>? previousConnection;
  String? previousDatabase;
  String previousSearchPath = '';
  Map<String, dynamic>? previousPrivileges;

  setUp(() {
    previousConnection = state.connection;
    previousDatabase = state.activeDatabase;
    previousSearchPath = state.searchPath;
    previousPrivileges = state.serverPrivileges;
    state.connection = <String, dynamic>{'id': 'conn-a', 'driver': 'mysql'};
    state.clearDeniedActions();
  });

  tearDown(() {
    state.clearDeniedActions();
    state.connection = previousConnection;
    state.activeDatabase = previousDatabase;
    state.searchPath = previousSearchPath;
    state.serverPrivileges = previousPrivileges;
  });

  group('learned action denials (P12)', () {
    test('a denial is scoped to connection + database + action', () {
      expect(state.isActionDenied('sakila', 'drop_database'), isFalse);

      expect(
        state.markActionDenied(
            'sakila', 'drop_database', "1142 DROP command denied to user 'x'"),
        isTrue,
      );
      expect(state.isActionDenied('sakila', 'drop_database'), isTrue);
      // A different database or action is not affected.
      expect(state.isActionDenied('other_db', 'drop_database'), isFalse);
      expect(state.isActionDenied('sakila', 'truncate_table'), isFalse);
      expect(state.deniedActionReason('sakila', 'drop_database'),
          contains('1142'));

      // Marking again returns false (already denied) but refreshes the reason.
      expect(
        state.markActionDenied('sakila', 'drop_database', 'other message'),
        isFalse,
      );
      expect(state.isActionDenied('sakila', 'drop_database'), isTrue);
      expect(state.deniedActionReason('sakila', 'drop_database'),
          contains('other message'));
    });

    test('denials do not leak into a new connection', () {
      state.markActionDenied('sakila', 'create_table', 'denied');
      expect(state.isActionDenied('sakila', 'create_table'), isTrue);

      state.connection = <String, dynamic>{'id': 'conn-b', 'driver': 'mysql'};
      // Same database name, different connection: a GRANT on the new account
      // may allow it, so the old denial must not carry over.
      expect(state.isActionDenied('sakila', 'create_table'), isFalse);
    });

    test('clearDeniedActions forgets every learned denial', () {
      state.markActionDenied('sakila', 'create_table', 'denied');
      state.markActionDenied('sakila', 'truncate_table', 'denied');
      expect(state.deniedActions, isNotEmpty);

      state.clearDeniedActions();
      expect(state.deniedActions, isEmpty);
      expect(state.deniedActionReasons, isEmpty);
      expect(state.isActionDenied('sakila', 'create_table'), isFalse);
    });

    test('empty database or action is ignored', () {
      expect(state.markActionDenied('', 'create_table', 'denied'), isFalse);
      expect(state.markActionDenied('sakila', '', 'denied'), isFalse);
      expect(state.deniedActions, isEmpty);
    });
  });

  group('server panel failure wording (P10)', () {
    test('a timeout becomes a per-panel explanation, not a blank page', () {
      final text = serverPanelFailureText(
        label: '服务器状态',
        error: TimeoutException('too slow after 8s'),
        privilege: 'PROCESS 或 SHOW DATABASES',
        account: 'rma_limited@%',
      );
      expect(text, contains('服务器状态'));
      expect(text, contains('加载超时'));
      expect(text, contains('其余页签仍可正常使用'));
      expect(text, contains('刷新'));
    });

    test('a permission failure names the account, panel and GRANT', () {
      final text = serverPanelFailureText(
        label: '进程列表',
        error: "1142 SELECT command denied to user 'rma_limited'@'%'",
        privilege: 'PROCESS',
        account: 'rma_limited@%',
      );
      expect(text, contains('rma_limited@%'));
      expect(text, contains('进程列表'));
      expect(text, contains('需要：PROCESS。'));
      expect(text, contains('无法绕过数据库权限'));
      // The raw driver dump must not be the only thing shown.
      expect(text, isNot(contains('Caused by')));
    });

    test('an ordinary failure keeps the cleaned database message', () {
      final text = serverPanelFailureText(
        label: '服务器变量',
        error: '表不存在：可能已被删除',
      );
      expect(text, contains('服务器变量'));
      expect(text, contains('加载失败'));
      expect(text, contains('表不存在'));
    });

    test('a permission failure without a known GRANT still explains', () {
      final text = serverPanelFailureText(
        label: '服务器状态',
        error: 'permission denied',
      );
      expect(text, contains('服务器状态'));
      expect(text, contains('没有读取'));
      expect(text, isNot(contains('需要：。')));
    });
  });

  // Helper import kept close to its use so the test file stays self-contained.
  group('permission detector sanity', () {
    test('the learned path only triggers for real permission failures', () {
      expect(
          isPermissionError("1142 SELECT command denied to user 'x'@'%'"),
          isTrue);
      expect(isPermissionError('Unknown column x'), isFalse);
      expect(isPermissionError('表不存在'), isFalse);
    });
  });
}
