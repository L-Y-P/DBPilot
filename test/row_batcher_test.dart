// Round 85 / Plan A: the streaming row batcher that merges 500-row batches into
// few setState flushes. Pure Dart — no Flutter binding, no timers.

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/row_batcher.dart';

List<List<dynamic>> rowsRange(int from, int count) => <List<dynamic>>[
      for (var i = from; i < from + count; i++) <dynamic>[i],
    ];

void main() {
  test('a fresh batcher is empty and not due', () {
    final batcher = RowBatcher(rowThreshold: 2000);
    expect(batcher.isEmpty, isTrue);
    expect(batcher.dueByThreshold, isFalse);
    expect(batcher.drain(), isEmpty);
  });

  test('add returns true only once the buffered rows reach the threshold', () {
    final batcher = RowBatcher(rowThreshold: 1000);
    // 500 + 499 stays below; the 500th row of the next batch crosses it.
    expect(batcher.add(statementIndex: 0, rows: rowsRange(0, 500)), isFalse);
    expect(batcher.add(statementIndex: 0, rows: rowsRange(500, 499)), isFalse);
    expect(batcher.dueByThreshold, isFalse);
    expect(batcher.add(statementIndex: 0, rows: rowsRange(999, 1)), isTrue);
    expect(batcher.dueByThreshold, isTrue);
  });

  test('drain returns all buffered rows for a statement and resets counters',
      () {
    final batcher = RowBatcher(rowThreshold: 2000);
    batcher.add(statementIndex: 0, rows: rowsRange(0, 3));
    batcher.add(statementIndex: 0, rows: rowsRange(3, 2));
    final flushes = batcher.drain();
    expect(flushes, hasLength(1));
    final flush = flushes.single;
    expect(flush.statementIndex, 0);
    expect(flush.rows, hasLength(5));
    expect(flush.rows.first.first, 0);
    expect(flush.rows.last.first, 4);
    expect(flush.firstBatch, isTrue);
    expect(batcher.isEmpty, isTrue);
    expect(batcher.bufferedSinceFlush, 0);
  });

  test('firstBatch is true only on the first flush of a statement', () {
    final batcher = RowBatcher(rowThreshold: 1);
    batcher.add(statementIndex: 7, rows: rowsRange(0, 1));
    final first = batcher.drain().single;
    expect(first.firstBatch, isTrue);
    batcher.add(statementIndex: 7, rows: rowsRange(1, 1));
    final second = batcher.drain().single;
    expect(second.firstBatch, isFalse);
  });

  test('drain groups rows per statement index in one flush', () {
    final batcher = RowBatcher(rowThreshold: 100);
    batcher.add(statementIndex: 0, rows: rowsRange(0, 2));
    batcher.add(statementIndex: 1, rows: rowsRange(10, 3));
    final flushes = batcher.drain();
    expect(flushes, hasLength(2));
    final byIndex = {for (final f in flushes) f.statementIndex: f};
    expect(byIndex[0]!.rows, hasLength(2));
    expect(byIndex[1]!.rows, hasLength(3));
    expect(byIndex[1]!.rows.first.first, 10);
  });

  test('columns and truncated ride on the statement flush', () {
    final batcher = RowBatcher(rowThreshold: 2000);
    final columns = <Map<String, dynamic>>[
      <String, dynamic>{'name': 'n', 'type_name': 'INT'},
    ];
    batcher.add(statementIndex: 0, rows: rowsRange(0, 2), columns: columns);
    batcher.add(statementIndex: 0, rows: rowsRange(2, 1), truncated: true);
    final flush = batcher.drain().single;
    expect(flush.columns, isNotNull);
    expect(flush.columns!.single['name'], 'n');
    expect(flush.truncated, isTrue);
  });

  test('a statement with metadata only (no rows) still flushes once', () {
    final batcher = RowBatcher(rowThreshold: 2000);
    batcher.add(
      statementIndex: 2,
      rows: const <List<dynamic>>[],
      columns: <Map<String, dynamic>>[
        <String, dynamic>{'name': 'x'},
      ],
    );
    final flush = batcher.drain().single;
    expect(flush.statementIndex, 2);
    expect(flush.rows, isEmpty);
    expect(flush.firstBatch, isTrue);
  });

  test('applyFlush appends rows, sets columns once, marks kind, sticks trunc',
      () {
    final result = <String, dynamic>{
      'kind': '',
      'columns': <dynamic>[],
      'rows': <dynamic>[],
      'truncated': false,
    };
    final first = RowBatchFlush(
      statementIndex: 0,
      rows: <List<dynamic>>[
        <dynamic>[1],
        <dynamic>[2],
      ],
      columns: <Map<String, dynamic>>[
        <String, dynamic>{'name': 'n'},
      ],
      truncated: false,
      firstBatch: true,
    );
    RowBatcher.applyFlush(result, first);
    final rows = result['rows'] as List<dynamic>;
    expect(rows, hasLength(2));
    expect(rows.first, <dynamic>[1]);
    expect(result['kind'], 'rows');
    expect((result['columns'] as List).single['name'], 'n');

    // A later flush adds rows without a columns payload; columns are preserved.
    final later = RowBatchFlush(
      statementIndex: 0,
      rows: <List<dynamic>>[
        <dynamic>[3],
      ],
      columns: null,
      truncated: true,
      firstBatch: false,
    );
    RowBatcher.applyFlush(result, later);
    expect((result['rows'] as List).length, 3);
    expect((result['columns'] as List).single['name'], 'n');
    expect(result['truncated'], isTrue);
  });

  test('applyFlush does not mark kind for an empty metadata-free flush', () {
    final result = <String, dynamic>{
      'kind': '',
      'columns': <dynamic>[],
      'rows': <dynamic>[],
    };
    RowBatcher.applyFlush(
      result,
      RowBatchFlush(
        statementIndex: 0,
        rows: const <List<dynamic>>[],
        columns: null,
        truncated: false,
        firstBatch: true,
      ),
    );
    expect(result['kind'], '');
    expect((result['rows'] as List), isEmpty);
  });

  test('reset forgets buffered rows and the first-flush bookkeeping', () {
    final batcher = RowBatcher(rowThreshold: 2000);
    batcher.add(statementIndex: 0, rows: rowsRange(0, 2));
    batcher.reset();
    expect(batcher.isEmpty, isTrue);
    batcher.add(statementIndex: 0, rows: rowsRange(0, 1));
    expect(batcher.drain().single.firstBatch, isTrue);
  });
}