// Regression tests for the database-privilege handling.
//
// Reported symptoms:
//   * the server page showed raw driver errors with a duplicated "Caused by:";
//   * a connection opened fine but then every panel failed, because the app
//     never asked what the database account was allowed to do;
//   * granting a privilege in the database did not unblock the app.
//
// The banner wording, capability mapping and error formatting are pure and are
// pinned here; the probe itself is exercised against the real Rust core (and a
// real low-privilege MySQL account when one is available).
//
// 端点与账号来自环境变量（DBPILOT_TEST_MYSQL_* / DBPILOT_TEST_MYSQL_LIMITED_*，
// 见 test/live_db_env.dart），仓库里不留任何账号密码字面量。

import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/views/server_view.dart';

import 'live_db_env.dart';

Future<bool> connectAs(LiveDbEndpoint endpoint, {String name = 'regress3'}) async {
  final created = await Api.instance.createConnection(
    connectionPayload('mysql', endpoint, name: name),
  );
  final id = (created['connection'] as Map)['id'].toString();
  try {
    await AppState.instance.connect(id);
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run cargo build --lib in rust/ first: the dylib is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    final dir = await Directory.systemTemp.createTemp('rma-regress3-');
    final init = await Api.init(dir.path);
    expect(init['ok'], isTrue, reason: 'init_app failed');
    await AppState.instance.bootstrap(dir.path);
  });

  test('banner names the missing GRANTs and how to apply them', () {
    final message = privilegeBannerMessage(<String, dynamic>{
      'account': 'web@%',
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
    });
    expect(message, contains('web@%'));
    expect(message, contains('数据库账号：需要 SELECT ON mysql.user'));
    expect(message, contains('进程列表：需要 PROCESS'));
    expect(message, contains('刷新'));
    // The app must be explicit that it cannot bypass the database.
    expect(message, contains('无法绕过数据库权限'));
    // A fully privileged account gets no banner at all.
    expect(privilegeBannerMessage(<String, dynamic>{'requirements': <dynamic>[]}), isEmpty);
    expect(privilegeBannerMessage(null), isEmpty);
  });

  test('a privileged account reports every capability', () async {
    if (!await connectAs(mysqlEndpoint(), name: 'regress3-privileged')) {
      markTestSkipped('MySQL (DBPILOT_TEST_MYSQL_*) not reachable');
      return;
    }
    final caps = AppState.instance.serverPrivileges!;
    expect(caps['account'], contains('root'));
    expect(AppState.instance.can('accounts'), isTrue);
    expect(AppState.instance.can('processes'), isTrue);
    expect(AppState.instance.can('status'), isTrue);
    expect(AppState.instance.can('kill'), isTrue);
    expect(AppState.instance.requiredPrivilege('accounts'), isNull);
    await AppState.instance.disconnect();
  });

  test('a restricted account reports what it cannot do', () async {
    if (!await connectAs(mysqlLimitedEndpoint(), name: 'regress3-limited')) {
      markTestSkipped('limited MySQL account (DBPILOT_TEST_MYSQL_LIMITED_*) not available');
      return;
    }
    // This account owns one schema and nothing else.
    expect(AppState.instance.can('accounts'), isFalse);
    expect(AppState.instance.can('processes'), isFalse);
    expect(AppState.instance.can('kill'), isFalse);
    expect(AppState.instance.can('status'), isTrue,
        reason: 'the page must still render its status panel');
    expect(AppState.instance.requiredPrivilege('processes'), contains('PROCESS'));

    final banner =
        privilegeBannerMessage(AppState.instance.serverPrivileges);
    expect(banner, contains('没有以下服务器权限'));
    expect(banner, contains('PROCESS'));
    expect(banner, contains('SELECT ON mysql.user'));
    expect(banner, isNot(contains('Caused by')));
    expect(banner, isNot(contains('error returned from database')));
    await AppState.instance.disconnect();
  });

  test('a denied statement explains the missing privilege', () async {
    final limited = mysqlLimitedEndpoint();
    if (!await connectAs(limited, name: 'regress3-denied')) {
      markTestSkipped('limited MySQL account (DBPILOT_TEST_MYSQL_LIMITED_*) not available');
      return;
    }
    final res = await Api.instance.query('SELECT * FROM mysql.user', limited.database);
    final first = (res['results'] as List).first as Map;
    final error = (first['error'] ?? '').toString();
    expect(error, isNotEmpty);
    expect(error, contains('表级权限'));
    expect(error, isNot(contains('Caused by')));
    expect(error, isNot(contains('error returned from database')));
    await AppState.instance.disconnect();
  });

  test('opening a database without rights names the GRANT', () async {
    // 1044: the account may log in but cannot open this database. This is the
    // second screenshot in the report. connectAs() swallows the error, so this
    // drives connect() directly to keep the message.
    // 受限账号去开一个它没有权限的库（默认 demo 库）。
    final created = await Api.instance.createConnection(
      connectionPayload(
        'mysql',
        mysqlLimitedEndpoint().withDatabase(mysqlEndpoint().database),
        name: 'regress3-1044',
      ),
    );
    final id = (created['connection'] as Map)['id'].toString();
    Object? failure;
    try {
      await AppState.instance.connect(id);
    } catch (e) {
      failure = e;
    }
    if (failure == null) {
      await AppState.instance.disconnect();
      markTestSkipped('web already has access to rustmyadmin_demo');
      return;
    }
    final message = failure.toString();
    // 只有「能登录但打不开这个库」(1044) 才是本用例要覆盖的路径。受限账号
    // 本身没配置好（密码不对 / 账号不存在）时是登录失败 (1045)，此时应当
    // SKIP 而不是把一条认证错误当成 1044 断言 —— 否则任何没准备该账号的
    // 机器（含 CI）上 flutter test 都会红。
    if (message.contains('用户名或密码不正确') ||
        message.contains('Access denied for user') ||
        message.contains('1045')) {
      markTestSkipped(
          'limited MySQL account (DBPILOT_TEST_MYSQL_LIMITED_*) cannot log in');
      return;
    }
    expect(message, contains('没有访问该数据库的权限'));
    expect(message, contains('GRANT'));
    expect(message, isNot(contains('Caused by')));
    expect(message, isNot(contains('error returned from database')));
  });
}