// Live 测试用的数据库端点 helper。
//
// 开源仓库里不允许出现任何真实的账号 / 密码 / 数据库地址字面量，所以这些
// live 测试（默认会在数据库不可达时 markTestSkipped）需要的端点全部从环境变量
// 读取。缺省值只是“本地开发常见的默认值”，密码一律为空：
//
//   MySQL       DBPILOT_TEST_MYSQL_HOST     默认 127.0.0.1
//               DBPILOT_TEST_MYSQL_PORT     默认 3306
//               DBPILOT_TEST_MYSQL_USER     默认 root
//               DBPILOT_TEST_MYSQL_PASSWORD 默认 空
//               DBPILOT_TEST_MYSQL_DB       默认 rustmyadmin_demo
//
//   PostgreSQL  DBPILOT_TEST_PG_HOST        默认 127.0.0.1
//               DBPILOT_TEST_PG_PORT        默认 5432
//               DBPILOT_TEST_PG_USER        默认 postgres
//               DBPILOT_TEST_PG_PASSWORD    默认 空
//               DBPILOT_TEST_PG_DB          默认 rustmyadmin_demo
//
// 受限 / 低权限账号（这些测试用它验证权限提示）同样由环境变量提供：
//
//   DBPILOT_TEST_MYSQL_LIMITED_USER      默认 web
//   DBPILOT_TEST_MYSQL_LIMITED_PASSWORD  默认 空
//   DBPILOT_TEST_MYSQL_LIMITED_DB        默认 web
//   DBPILOT_TEST_MYSQL_RESTRICTED_USER   默认 rma_limited
//   DBPILOT_TEST_MYSQL_RESTRICTED_PASSWORD 默认 空
//   DBPILOT_TEST_MYSQL_RESTRICTED_DB     默认 sakila
//   DBPILOT_TEST_PG_LIMITED_USER         默认 rma_limited
//   DBPILOT_TEST_PG_LIMITED_PASSWORD     默认 空
//   DBPILOT_TEST_PG_LIVE_DB              默认 pagila
//
// 本地跑这些测试前先 export 自己的值（或 source 一个不提交的 .env），例如：
//
//   DBPILOT_TEST_MYSQL_PASSWORD=... flutter test test/mysql_visibility_test.dart

import 'dart:io';

/// 一个数据库端点。
class LiveDbEndpoint {
  const LiveDbEndpoint({
    required this.host,
    required this.port,
    required this.user,
    required this.password,
    required this.database,
  });

  final String host;
  final int port;
  final String user;
  final String password;
  final String database;

  /// 连到指定数据库（数据库名为空时用端点默认库）。
  LiveDbEndpoint withDatabase(String database) => LiveDbEndpoint(
        host: host,
        port: port,
        user: user,
        password: password,
        database: database,
      );

  /// 换成另一个账号（受限账号等）。
  LiveDbEndpoint withAccount(String user, String password) => LiveDbEndpoint(
        host: host,
        port: port,
        user: user,
        password: password,
        database: database,
      );
}

String _env(String key, String fallback) {
  final value = Platform.environment[key];
  if (value == null) return fallback;
  return value;
}

int _envPort(String key, int fallback) {
  final value = Platform.environment[key];
  if (value == null) return fallback;
  return int.tryParse(value.trim()) ?? fallback;
}

/// MySQL 端点（DBPILOT_TEST_MYSQL_*）。
LiveDbEndpoint mysqlEndpoint({String? database}) => LiveDbEndpoint(
      host: _env('DBPILOT_TEST_MYSQL_HOST', '127.0.0.1'),
      port: _envPort('DBPILOT_TEST_MYSQL_PORT', 3306),
      user: _env('DBPILOT_TEST_MYSQL_USER', 'root'),
      password: _env('DBPILOT_TEST_MYSQL_PASSWORD', ''),
      database: database ?? _env('DBPILOT_TEST_MYSQL_DB', 'rustmyadmin_demo'),
    );

/// PostgreSQL 端点（DBPILOT_TEST_PG_*）。
LiveDbEndpoint pgEndpoint({String? database}) => LiveDbEndpoint(
      host: _env('DBPILOT_TEST_PG_HOST', '127.0.0.1'),
      port: _envPort('DBPILOT_TEST_PG_PORT', 5432),
      user: _env('DBPILOT_TEST_PG_USER', 'postgres'),
      password: _env('DBPILOT_TEST_PG_PASSWORD', ''),
      database: database ?? _env('DBPILOT_TEST_PG_DB', 'rustmyadmin_demo'),
    );

/// 只持有单个库权限的低权限 MySQL 账号（默认 web）。
LiveDbEndpoint mysqlLimitedEndpoint() => mysqlEndpoint().withAccount(
      _env('DBPILOT_TEST_MYSQL_LIMITED_USER', 'web'),
      _env('DBPILOT_TEST_MYSQL_LIMITED_PASSWORD', ''),
    ).withDatabase(_env('DBPILOT_TEST_MYSQL_LIMITED_DB', 'web'));

/// 权限更窄的 MySQL 账号（默认 rma_limited，只读 sakila 两张表）。
LiveDbEndpoint mysqlRestrictedEndpoint() => mysqlEndpoint().withAccount(
      _env('DBPILOT_TEST_MYSQL_RESTRICTED_USER', 'rma_limited'),
      _env('DBPILOT_TEST_MYSQL_RESTRICTED_PASSWORD', ''),
    ).withDatabase(_env('DBPILOT_TEST_MYSQL_RESTRICTED_DB', 'sakila'));

/// PG 受限角色（这些测试验证 schema/database 可见性），默认 rma_limited。
LiveDbEndpoint pgLimitedEndpoint() => pgEndpoint().withAccount(
      _env('DBPILOT_TEST_PG_LIMITED_USER', 'rma_limited'),
      _env('DBPILOT_TEST_PG_LIMITED_PASSWORD', ''),
    );

/// PG live 用例用的库（默认 pagila）。
String pgLiveDatabase() => _env('DBPILOT_TEST_PG_LIVE_DB', 'pagila');

/// 拼一个 createConnection 用的 map。
Map<String, dynamic> connectionPayload(
  String driver,
  LiveDbEndpoint endpoint, {
  String name = 'live',
}) =>
    <String, dynamic>{
      'name': name,
      'driver': driver,
      'host': endpoint.host,
      'port': endpoint.port,
      'user': endpoint.user,
      'password': endpoint.password,
      'database': endpoint.database,
    };
