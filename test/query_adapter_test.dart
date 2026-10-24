// Pure Dart tests for the streaming query aggregator (optimisation layers 1+3).
//
// No FFI, no live database: [QueryEvent] sequences are built by hand and folded
// with [aggregateQueryEvents], which is exactly what Api.query does with a real
// bridge stream. The assertions pin the legacy flat JSON contract every
// non-console view still consumes.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/rust/api/query_types.dart';

QuerySummaryDto summary({
  int statementCount = 1,
  int failed = 0,
  int elapsedMs = 12,
  String driver = 'mysql',
  String? searchPath,
  String? database,
  String? useDatabase,
  bool truncated = false,
  int rowLimit = 50000,
}) => QuerySummaryDto(
  statementCount: statementCount,
  failed: failed,
  elapsedMs: elapsedMs,
  driver: driver,
  searchPath: searchPath,
  database: database,
  useDatabase: useDatabase,
  truncated: truncated,
  rowLimit: rowLimit,
);

QueryEvent started(int index, String statement) => QueryEvent(
  kind: queryEventStarted,
  statementIndex: index,
  statement: statement,
  columns: const <ColumnDto>[],
  rows: const <List<CellValue>>[],
  truncated: false,
);

QueryEvent batch(
  int index, {
  List<ColumnDto> columns = const <ColumnDto>[],
  List<List<CellValue>> rows = const <List<CellValue>>[],
  bool truncated = false,
}) => QueryEvent(
  kind: queryEventBatch,
  statementIndex: index,
  columns: columns,
  rows: rows,
  truncated: truncated,
);

QueryEvent statementDone(int index, ResultSetDto result) => QueryEvent(
  kind: queryEventStatementDone,
  statementIndex: index,
  columns: const <ColumnDto>[],
  rows: const <List<CellValue>>[],
  truncated: false,
  result: result,
);

QueryEvent done(QuerySummaryDto value) => QueryEvent(
  kind: queryEventDone,
  statementIndex: 0,
  columns: const <ColumnDto>[],
  rows: const <List<CellValue>>[],
  truncated: false,
  summary: value,
);

QueryEvent failed(String message) => QueryEvent(
  kind: queryEventFailed,
  statementIndex: 0,
  columns: const <ColumnDto>[],
  rows: const <List<CellValue>>[],
  truncated: false,
  message: message,
);

ResultSetDto meta({
  List<ColumnDto> columns = const <ColumnDto>[],
  int rowCount = 0,
  int lastInsertId = 0,
  String statement = '',
  String kind = 'rows',
  String? error,
  bool truncated = false,
}) => ResultSetDto(
  columns: columns,
  rows: const <List<CellValue>>[],
  rowCount: rowCount,
  lastInsertId: lastInsertId,
  statement: statement,
  kind: kind,
  error: error,
  truncated: truncated,
);

void main() {
  test('aggregateQueryEvents keeps the exact flat legacy shape', () {
    const statement = 'SELECT id, name FROM users';
    final json = aggregateQueryEvents(<QueryEvent>[
      started(0, statement),
      batch(
        0,
        columns: const <ColumnDto>[
          ColumnDto(name: 'id', typeName: 'BIGINT'),
          ColumnDto(name: 'name', typeName: 'VARCHAR'),
        ],
        rows: <List<CellValue>>[
          <CellValue>[
            const CellValue(kind: cellKindInt, intValue: 7),
            const CellValue(kind: cellKindText, textValue: 'alice'),
          ],
          <CellValue>[
            const CellValue(kind: cellKindNull),
            const CellValue(kind: cellKindNull),
          ],
        ],
      ),
      statementDone(
        0,
        meta(columns: const <ColumnDto>[], rowCount: 2, statement: statement),
      ),
      done(summary()),
    ]);

    expect(json.keys.toSet(), <String>{
      'results',
      'statement_count',
      'failed',
      'elapsed_ms',
      'driver',
      'search_path',
      'database',
      'use_database',
      'truncated',
      'row_limit',
    });
    expect(json['statement_count'], 1);
    expect(json['failed'], 0);
    expect(json['elapsed_ms'], 12);
    expect(json['driver'], 'mysql');
    expect(json['search_path'], isNull);
    expect(json['database'], isNull);
    expect(json['use_database'], isNull);
    expect(json['truncated'], isFalse);
    expect(json['row_limit'], 50000);

    final results = json['results'] as List<dynamic>;
    expect(results, hasLength(1));
    final first = results.first as Map<String, dynamic>;
    expect(first.keys.toSet(), <String>{
      'columns',
      'rows',
      'row_count',
      'last_insert_id',
      'statement',
      'kind',
      'error',
      'truncated',
    });
    expect(first['columns'], <dynamic>[
      <String, dynamic>{'name': 'id', 'type_name': 'BIGINT'},
      <String, dynamic>{'name': 'name', 'type_name': 'VARCHAR'},
    ]);
    expect(first['rows'], <dynamic>[
      <dynamic>[7, 'alice'],
      <dynamic>[null, null],
    ]);
    expect(first['row_count'], 2);
    expect(first['last_insert_id'], 0);
    expect(first['statement'], statement);
    expect(first['kind'], 'rows');
    expect(first['error'], isNull);
    expect(first['truncated'], isFalse);
  });

  test('any batch cell kind is converted to the legacy JSON cell', () {
    final bytes = Uint8List.fromList(<int>[0, 1, 254, 255]);
    final json = aggregateQueryEvents(<QueryEvent>[
      started(0, 'SELECT b, i, f, t, x FROM t'),
      batch(
        0,
        columns: const <ColumnDto>[ColumnDto(name: 'v', typeName: 'TEXT')],
        rows: <List<CellValue>>[
          <CellValue>[
            const CellValue(kind: cellKindNull),
            const CellValue(kind: cellKindBool, boolValue: true),
            const CellValue(kind: cellKindInt, intValue: -42),
            const CellValue(kind: cellKindFloat, floatValue: 1.5),
            const CellValue(kind: cellKindText, textValue: 'text'),
            CellValue(kind: cellKindBytes, bytesValue: bytes),
          ],
        ],
      ),
      done(summary()),
    ]);

    final row =
        ((json['results'] as List<dynamic>).first
                as Map<String, dynamic>)['rows']
            as List<dynamic>;
    expect(row, hasLength(1));
    final cells = row.first as List<dynamic>;
    expect(cells, <dynamic>[
      null,
      true,
      -42,
      1.5,
      'text',
      <String, dynamic>{'__binary__': base64Encode(bytes), 'len': bytes.length},
    ]);
    // The binary marker keeps the shape the grids already understand.
    expect(isBinaryCell(cells.last), isTrue);
    expect(displayCell(cells.last), '[BLOB 4 bytes]');
  });

  test('a zero-row SELECT gets its columns back from statement_done', () {
    final json = aggregateQueryEvents(<QueryEvent>[
      started(0, 'SELECT id FROM t WHERE 1 = 0'),
      statementDone(
        0,
        meta(
          columns: const <ColumnDto>[ColumnDto(name: 'id', typeName: 'INT')],
          statement: 'SELECT id FROM t WHERE 1 = 0',
          rowCount: 0,
        ),
      ),
      done(summary()),
    ]);

    final first =
        (json['results'] as List<dynamic>).first as Map<String, dynamic>;
    expect(first['rows'], isEmpty);
    expect(first['columns'], <dynamic>[
      <String, dynamic>{'name': 'id', 'type_name': 'INT'},
    ]);
    expect(first['kind'], 'rows');
  });

  test('multi-statement indexes stay aligned and keep affected metadata', () {
    final json = aggregateQueryEvents(<QueryEvent>[
      started(0, 'INSERT INTO t VALUES (1)'),
      statementDone(
        0,
        meta(
          rowCount: 1,
          lastInsertId: 42,
          statement: 'INSERT INTO t VALUES (1)',
          kind: 'affected',
        ),
      ),
      started(1, 'SELECT id FROM t'),
      batch(
        1,
        columns: const <ColumnDto>[ColumnDto(name: 'id', typeName: 'INT')],
        rows: <List<CellValue>>[
          <CellValue>[const CellValue(kind: cellKindInt, intValue: 1)],
        ],
        truncated: true,
      ),
      statementDone(
        1,
        meta(
          columns: const <ColumnDto>[ColumnDto(name: 'id', typeName: 'INT')],
          rowCount: 1,
          statement: 'SELECT id FROM t',
          truncated: true,
        ),
      ),
      done(summary(statementCount: 2, elapsedMs: 99, truncated: true)),
    ]);

    expect(json['statement_count'], 2);
    expect(json['elapsed_ms'], 99);
    expect(json['truncated'], isTrue);
    final results = json['results'] as List<dynamic>;
    expect(results, hasLength(2));
    final affected = results[0] as Map<String, dynamic>;
    expect(affected['statement'], 'INSERT INTO t VALUES (1)');
    expect(affected['kind'], 'affected');
    expect(affected['row_count'], 1);
    expect(affected['last_insert_id'], 42);
    expect(affected['rows'], isEmpty);
    final rows = results[1] as Map<String, dynamic>;
    expect(rows['statement'], 'SELECT id FROM t');
    expect(rows['kind'], 'rows');
    expect(rows['truncated'], isTrue);
    expect(rows['rows'], <dynamic>[
      <dynamic>[1],
    ]);
  });

  test('a skipped statement index still leaves a placeholder slot', () {
    final json = aggregateQueryEvents(<QueryEvent>[
      started(0, 'SELECT 1'),
      started(2, 'SELECT 3'),
      done(summary(statementCount: 3)),
    ]);
    final results = json['results'] as List<dynamic>;
    expect(results, hasLength(3));
    expect((results[0] as Map)['statement'], 'SELECT 1');
    expect((results[1] as Map)['statement'], '');
    expect((results[2] as Map)['statement'], 'SELECT 3');
  });

  test('summary optional fields are flattened onto the top level', () {
    final json = aggregateQueryEvents(<QueryEvent>[
      done(
        summary(
          statementCount: 2,
          failed: 1,
          elapsedMs: 3,
          driver: 'postgres',
          searchPath: 'public',
          database: 'app',
          useDatabase: 'other',
          truncated: false,
          rowLimit: 50000,
        ),
      ),
    ]);

    expect(json['results'], isEmpty);
    expect(json['statement_count'], 2);
    expect(json['failed'], 1);
    expect(json['driver'], 'postgres');
    expect(json['search_path'], 'public');
    expect(json['database'], 'app');
    expect(json['use_database'], 'other');
    expect(json['row_limit'], 50000);
  });

  test('a failed event throws the cleaned message, like the old run_query', () {
    expect(
      () => aggregateQueryEvents(<QueryEvent>[
        started(0, 'SELECT * FROM missing'),
        failed('error returned from database: boom'),
      ]),
      throwsA(
        isA<ApiException>().having((error) => error.message, 'message', 'boom'),
      ),
    );
    expect(
      () => aggregateQueryEvents(<QueryEvent>[
        failed('AnyhowException(SQL 语句不能为空)'),
      ]),
      throwsA(
        isA<ApiException>().having(
          (error) => error.message,
          'message',
          'SQL 语句不能为空',
        ),
      ),
    );
  });

  test('CellValue.when covers every kind and throws on an unknown one', () {
    String describe(CellValue cell) => cell.when<String>(
          null_: () => 'null',
          bool_: (value) => 'bool:$value',
          int_: (value) => 'int:$value',
          float_: (value) => 'float:$value',
          text_: (value) => 'text:$value',
          bytes_: (value) => 'bytes:${value.length}',
        );

    expect(describe(const CellValue(kind: cellKindNull)), 'null');
    expect(
      describe(const CellValue(kind: cellKindBool, boolValue: true)),
      'bool:true',
    );
    expect(
      describe(const CellValue(kind: cellKindInt, intValue: 7)),
      'int:7',
    );
    expect(
      describe(const CellValue(kind: cellKindFloat, floatValue: 1.5)),
      'float:1.5',
    );
    expect(
      describe(const CellValue(kind: cellKindText, textValue: 'hi')),
      'text:hi',
    );
    expect(
      describe(CellValue(kind: cellKindBytes, bytesValue: Uint8List(3))),
      'bytes:3',
    );

    // A kind that Rust/Dart disagree on must fail loudly, not fall through.
    expect(
      () => describe(const CellValue(kind: 99)),
      throwsA(isA<StateError>().having(
        (error) => error.message.toString(),
        'message',
        contains('99'),
      )),
    );
  });
}