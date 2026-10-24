import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/query_metrics.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('rma-metrics-');
    file = File('${dir.path}/query_metrics.jsonl');
    QueryMetrics.instance.debugConfigure(path: file.path);
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('query hash is a stable 16-char SHA-256 prefix, never SQL text', () {
    const sql = 'SELECT * FROM secret_table WHERE token = 123';
    final first = QueryMetrics.hashOf(sql);
    final second = QueryMetrics.hashOf(sql);
    expect(first, hasLength(16));
    expect(first, second);
    expect(first, isNot(contains('secret')));
    expect(QueryMetrics.hashOf('SELECT 1'), isNot(first));
  });

  test('statement type is classified from the first token', () {
    expect(QueryMetrics.statementTypeOf('SELECT 1'), 'select');
    expect(QueryMetrics.statementTypeOf('  -- note\n  show tables'), 'show');
    expect(QueryMetrics.statementTypeOf('/* c */ EXPLAIN SELECT 1'), 'explain');
    expect(QueryMetrics.statementTypeOf('CREATE TABLE t (id INT)'), 'ddl');
    expect(QueryMetrics.statementTypeOf('USE app'), 'use');
    expect(QueryMetrics.statementTypeOf(''), 'other');
  });

  test('finishRun appends one line with the agreed fields', () async {
    final runId = QueryMetrics.instance.beginRun(
      sql: 'SELECT * FROM narrow_10m LIMIT 50000',
      source: 'console',
    );
    QueryMetrics.instance.finishRun(
      runId: runId,
      resultRows: 50000,
      truncated: true,
      rustElapsedMs: 87,
      wallMs: 89,
      statementCount: 1,
    );
    await QueryMetrics.instance.pending;

    final lines = await file.readAsLines();
    expect(lines, hasLength(1));
    final record = jsonDecode(lines.single) as Map<String, dynamic>;
    expect(record['event'], 'run');
    expect(record['source'], 'console');
    expect(record['stmt_type'], 'select');
    expect(record['result_rows'], 50000);
    expect(record['truncated'], isTrue);
    expect(record['elapsed_ms_rust'], 87);
    expect(record['wall_ms'], 89);
    expect(record['statement_count'], 1);
    expect(record['failed'], isFalse);
    expect((record['query_hash'] as String), hasLength(16));
    expect(lines.single, isNot(contains('narrow_10m')));
  });

  test('markPaged emits a follow-up event keyed by run id', () async {
    final runId = QueryMetrics.instance.beginRun(sql: 'SELECT 1', source: 'console');
    QueryMetrics.instance.finishRun(
      runId: runId,
      resultRows: 1,
      truncated: false,
      rustElapsedMs: 1,
      wallMs: 2,
      statementCount: 1,
    );
    QueryMetrics.instance.markPaged(runId: runId);
    await QueryMetrics.instance.pending;

    final lines = await file.readAsLines();
    final paged = jsonDecode(lines.last) as Map<String, dynamic>;
    expect(paged['event'], 'paged');
    expect(paged['run_id'], runId);
  });

  test('a failed run is still recorded without breaking the caller', () async {
    final runId = QueryMetrics.instance.beginRun(sql: 'SELECT bad', source: 'api');
    QueryMetrics.instance.finishRun(
      runId: runId,
      resultRows: 0,
      truncated: false,
      rustElapsedMs: 0,
      wallMs: 3,
      statementCount: 0,
      failed: true,
    );
    await QueryMetrics.instance.pending;
    final record =
        jsonDecode((await file.readAsLines()).single) as Map<String, dynamic>;
    expect(record['failed'], isTrue);
    expect(record['result_rows'], 0);
  });

  test('disabled recorder writes nothing', () async {
    QueryMetrics.instance.debugConfigure(path: file.path, enabled: false);
    final runId = QueryMetrics.instance.beginRun(sql: 'SELECT 1', source: 'api');
    QueryMetrics.instance.finishRun(
      runId: runId,
      resultRows: 1,
      truncated: false,
      rustElapsedMs: 1,
      wallMs: 1,
      statementCount: 1,
    );
    await QueryMetrics.instance.pending;
    expect(await file.exists(), isFalse);
  });
}