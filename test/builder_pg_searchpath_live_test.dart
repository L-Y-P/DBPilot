// Live regression for ROUND68 P1-01: a PostgreSQL query-builder statement must
// keep working after a previous console script leaves the pooled session's
// search_path empty. pg_dump emits
//   SELECT pg_catalog.set_config('search_path', '', false);
// and the SQL console pins one pooled connection for the whole script, so the
// connection goes back to the pool with an empty search_path; the builder used
// to send unqualified table names and died with 42P01.
//
// The test is live: PostgreSQL and the pagila database come from
// DBPILOT_TEST_PG_* (test/live_db_env.dart) and it SKIPs when unreachable.
// It proves both halves of the bug:
//   * the qualified builder SQL built by buildBuilderSql(..., defaultNamespace:
//     'public') runs with an empty search_path;
//   * the historical unqualified form still fails with 42P01, so the assertion
//     would catch a regression that drops the namespace again.
//
// Paths are assembled with explicit concatenation to keep the one-liners
// readable, matching the other live tests.
// ignore_for_file: prefer_interpolation_to_compose_strings
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/builder/query_model.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';

import 'live_db_env.dart';

const String _taint =
    "SELECT pg_catalog.set_config('search_path', '', false); ";

/// First error of any statement in a multi-statement response (the taint
/// statement comes first and always succeeds, so looking at results[0] alone
/// would hide the SELECT's 42P01).
String _errorOf(Object? response) {
  final results = (response as Map)['results'];
  if (results is! List) return '';
  for (final result in results) {
    final error = ((result as Map)['error'] ?? '').toString();
    if (error.isNotEmpty) return error;
  }
  return '';
}

void main() {
  late Directory dir;

  setUpAll(() async {
    final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
    if (!dylib.existsSync()) {
      fail('Run cargo build --lib in rust/ first: ' + dylib.path + ' is missing');
    }
    await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
    dir = await Directory.systemTemp.createTemp('rma-builder-searchpath-');
    final init = await Api.init(dir.path);
    expect(init['ok'], isTrue, reason: 'init_app failed: ' + init.toString());
    await AppState.instance.bootstrap(dir.path);
  });

  tearDownAll(() async {
    try {
      await AppState.instance.disconnect();
    } catch (_) {}
    await dir.delete(recursive: true);
  });

  test('PG builder SQL survives an emptied search_path', () async {
    final liveDb = pgLiveDatabase();
    final endpoint = pgEndpoint(database: liveDb);
    var connected = false;
    try {
      final created = await Api.instance.createConnection(
        connectionPayload('postgres', endpoint, name: 'builder-p1-live'),
      );
      final id = (created['connection'] as Map)['id'].toString();
      await AppState.instance.connect(id);
      connected = true;
    } catch (_) {
      connected = false;
    }
    if (!connected) {
      markTestSkipped(
          'PostgreSQL (DBPILOT_TEST_PG_*) + ' + liveDb + ' not available');
      return;
    }

    final raw = await Api.instance.builderSchema('public');
    final tables = builderTablesFromSchema(raw);
    expect(tables, isNotEmpty,
        reason: liveDb + '.public exposes no tables; rebuild the fixture');
    final primary = tables.first.name;
    final quote = AppState.instance.quoteIdent;

    final qualified = buildBuilderSql(
      BuilderQuery()..primaryTable = primary,
      tables,
      quote: quote,
      dialect: builderDialectOf('postgres'),
      defaultNamespace: 'public',
    );
    expect(qualified.executable, contains('"public"."' + primary + '"'));

    final qualifiedResponse = await Api.instance.query(_taint + qualified.executable);
    expect(_errorOf(qualifiedResponse), isEmpty,
        reason: 'qualified builder SQL failed: ' + qualified.executable);

    // The old rendering must still fail on the same session state; otherwise
    // this test could pass even if the namespace never reached the SQL.
    final unqualified = buildBuilderSql(
      BuilderQuery()..primaryTable = primary,
      tables,
      quote: quote,
      dialect: builderDialectOf('postgres'),
    );
    final unqualifiedResponse =
        await Api.instance.query(_taint + unqualified.executable);
    expect(_errorOf(unqualifiedResponse), contains('42P01'),
        reason: 'unqualified SQL unexpectedly passed: ' + unqualified.executable);
  });
}
