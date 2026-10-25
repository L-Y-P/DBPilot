// Pure mapping from staged grid edits to the Rust `apply_row_changes` payload.
//
// Keeping this layer free of Flutter/Rust makes the interesting rules (one
// UPDATE per row, primary-key vs all-column keys, NULL edits) unit-testable.

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/row_changes.dart';

List<Map<String, dynamic>> columns() => <Map<String, dynamic>>[
      <String, dynamic>{'name': 'id', 'type_name': 'INTEGER'},
      <String, dynamic>{'name': 'name', 'type_name': 'TEXT'},
      <String, dynamic>{'name': 'qty', 'type_name': 'INTEGER'},
    ];

List<List<dynamic>> rows() => <List<dynamic>>[
      <dynamic>[1, 'one', 1],
      <dynamic>[2, 'two', 2],
    ];

void main() {
  test('groups dirty cells by row into one UPDATE per touched row', () {
    final changes = buildRowChanges(
      columns: columns(),
      rows: rows(),
      primaryKey: <String>['id'],
      edits: const <DirtyCell>[
        DirtyCell(rowIndex: 0, column: 'name', value: 'ONE'),
        DirtyCell(rowIndex: 0, column: 'qty', value: 10),
        DirtyCell(rowIndex: 1, column: 'qty', value: 20),
      ],
    );
    expect(changes, hasLength(2));
    expect(changes[0], <String, dynamic>{
      'action': 'update',
      'keys': <String, dynamic>{'id': 1},
      'values': <String, dynamic>{'name': 'ONE', 'qty': 10},
      'limit_one': false,
    });
    expect(changes[1], <String, dynamic>{
      'action': 'update',
      'keys': <String, dynamic>{'id': 2},
      'values': <String, dynamic>{'qty': 20},
      'limit_one': false,
    });
  });

  test('a table without a primary key keys the row by every column', () {
    final changes = buildRowChanges(
      columns: columns(),
      rows: rows(),
      primaryKey: const <String>[],
      edits: const <DirtyCell>[
        DirtyCell(rowIndex: 1, column: 'name', value: 'TWO'),
      ],
    );
    expect(changes, hasLength(1));
    expect(changes.single['keys'], <String, dynamic>{
      'id': 2,
      'name': 'two',
      'qty': 2,
    });
    // Matching by every column may hit several physical rows, so the backend
    // must narrow to one (the same rule change_row uses).
    expect(changes.single['limit_one'], isTrue);
  });

  test('a NULL edit is sent explicitly instead of being dropped', () {
    final changes = buildRowChanges(
      columns: columns(),
      rows: rows(),
      primaryKey: <String>['id'],
      edits: const <DirtyCell>[
        DirtyCell(rowIndex: 0, column: 'name', isNull: true),
      ],
    );
    expect(changes.single['values'], <String, dynamic>{'name': null});
  });

  test('the last edit for the same cell wins', () {
    final changes = buildRowChanges(
      columns: columns(),
      rows: rows(),
      primaryKey: <String>['id'],
      edits: const <DirtyCell>[
        DirtyCell(rowIndex: 0, column: 'name', value: 'first'),
        DirtyCell(rowIndex: 0, column: 'name', value: 'second'),
      ],
    );
    expect(changes, hasLength(1));
    expect(changes.single['values'], <String, dynamic>{'name': 'second'});
  });

  test('an empty edit list produces no changes', () {
    expect(
      buildRowChanges(
        columns: columns(),
        rows: rows(),
        primaryKey: <String>['id'],
        edits: const <DirtyCell>[],
      ),
      isEmpty,
    );
  });

  test('rejects a stale row index instead of writing to the wrong row', () {
    expect(
      () => buildRowChanges(
        columns: columns(),
        rows: rows(),
        primaryKey: <String>['id'],
        edits: const <DirtyCell>[
          DirtyCell(rowIndex: 5, column: 'name', value: 'x'),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('rejects an unknown column from a stale grid view', () {
    expect(
      () => buildRowChanges(
        columns: columns(),
        rows: rows(),
        primaryKey: <String>['id'],
        edits: const <DirtyCell>[
          DirtyCell(rowIndex: 0, column: 'gone', value: 'x'),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('DirtyCell payloadValue distinguishes NULL from a value', () {
    expect(const DirtyCell(rowIndex: 0, column: 'x', isNull: true).payloadValue,
        isNull);
    expect(
        const DirtyCell(rowIndex: 0, column: 'x', value: 0).payloadValue, 0);
  });

  // =====================================================================
  // 第 59 轮：行键捕获 + 跨页批量保存
  // =====================================================================

  group('row keys', () {
    test('primary-key table captures just the key columns', () {
      expect(
        rowChangeKeys(
          columns: columns(),
          row: <dynamic>[1, 'one', 1],
          primaryKey: <String>['id'],
        ),
        <String, dynamic>{'id': 1},
      );
    });

    test('table without a primary key captures the whole row', () {
      expect(
        rowChangeKeys(
          columns: columns(),
          row: <dynamic>[2, 'two', 2],
          primaryKey: const <String>[],
        ),
        <String, dynamic>{'id': 2, 'name': 'two', 'qty': 2},
      );
    });

    test('key string is order-independent and type-sensitive', () {
      expect(
        rowChangeKeyFor(<String, Object?>{'id': 1, 'name': 'a'}),
        rowChangeKeyFor(<String, Object?>{'name': 'a', 'id': 1}),
      );
      expect(
        rowChangeKeyFor(<String, Object?>{'id': 1}),
        isNot(rowChangeKeyFor(<String, Object?>{'id': '1'})),
      );
      expect(rowChangeKeyFor(<String, Object?>{}), '');
      expect(rowChangeKeyFor(null), '');
    });

    test('rowChangeKey uses the same capture rule', () {
      expect(
        rowChangeKey(
          columns: columns(),
          row: <dynamic>[1, 'one', 1],
          primaryKey: <String>['id'],
        ),
        rowChangeKeyFor(<String, Object?>{'id': 1}),
      );
    });
  });

  group('buildRowChangesFromKeys（跨页批量保存）', () {
    List<DirtyCell> edits() => <DirtyCell>[
          DirtyCell(
            rowIndex: 0,
            column: 'name',
            value: 'ONE',
            keys: <String, Object?>{'id': 1},
          ),
          DirtyCell(
            rowIndex: 0,
            column: 'qty',
            value: 10,
            keys: <String, Object?>{'id': 1},
          ),
          // Same table, different page: rowIndex restarts at 0 on page 2, but the
          // captured keys still identify row 2.
          DirtyCell(
            rowIndex: 0,
            column: 'name',
            value: 'TWO',
            keys: <String, Object?>{'id': 2},
          ),
        ];

    test('groups by captured keys, not by page index', () {
      final changes = buildRowChangesFromKeys(
        columns: columns(),
        primaryKey: <String>['id'],
        edits: edits(),
      );
      expect(changes, hasLength(2));
      expect(changes[0]['keys'], <String, dynamic>{'id': 1});
      expect(changes[0]['values'], <String, dynamic>{'name': 'ONE', 'qty': 10});
      expect(changes[0]['limit_one'], isFalse);
      expect(changes[1]['keys'], <String, dynamic>{'id': 2});
      expect(changes[1]['values'], <String, dynamic>{'name': 'TWO'});
    });

    test('no primary key → whole-row keys and limit_one', () {
      final changes = buildRowChangesFromKeys(
        columns: columns(),
        primaryKey: const <String>[],
        edits: <DirtyCell>[
          DirtyCell(
            rowIndex: 3,
            column: 'name',
            value: 'X',
            keys: <String, Object?>{'id': 3, 'name': 'three', 'qty': 3},
          ),
        ],
      );
      expect(changes.single['limit_one'], isTrue);
      expect(changes.single['keys'], <String, dynamic>{
        'id': 3,
        'name': 'three',
        'qty': 3,
      });
    });

    test('a NULL edit is sent explicitly', () {
      final changes = buildRowChangesFromKeys(
        columns: columns(),
        primaryKey: <String>['id'],
        edits: <DirtyCell>[
          DirtyCell(
            rowIndex: 0,
            column: 'name',
            isNull: true,
            keys: <String, Object?>{'id': 1},
          ),
        ],
      );
      expect(changes.single['values'], <String, dynamic>{'name': null});
    });

    test('empty edits → no changes', () {
      expect(
        buildRowChangesFromKeys(
          columns: columns(),
          primaryKey: <String>['id'],
          edits: const <DirtyCell>[],
        ),
        isEmpty,
      );
    });

    test('rejects missing / empty row keys', () {
      expect(
        () => buildRowChangesFromKeys(
          columns: columns(),
          primaryKey: <String>['id'],
          edits: const <DirtyCell>[
            DirtyCell(rowIndex: 0, column: 'name', value: 'x'),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => buildRowChangesFromKeys(
          columns: columns(),
          primaryKey: <String>['id'],
          edits: const <DirtyCell>[
            DirtyCell(
              rowIndex: 0,
              column: 'name',
              value: 'x',
              keys: <String, Object?>{},
            ),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('rejects unknown columns and missing key columns', () {
      expect(
        () => buildRowChangesFromKeys(
          columns: columns(),
          primaryKey: <String>['id'],
          edits: <DirtyCell>[
            DirtyCell(
              rowIndex: 0,
              column: 'gone',
              value: 'x',
              keys: <String, Object?>{'id': 1},
            ),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => buildRowChangesFromKeys(
          columns: columns(),
          primaryKey: <String>['id'],
          edits: <DirtyCell>[
            DirtyCell(
              rowIndex: 0,
              column: 'name',
              value: 'x',
              keys: <String, Object?>{'name': 'one'},
            ),
          ],
        ),
        throwsArgumentError,
        reason: '主键列 id 不在 keys 里',
      );
      expect(
        () => buildRowChangesFromKeys(
          columns: columns(),
          primaryKey: <String>['id'],
          edits: <DirtyCell>[
            DirtyCell(
              rowIndex: 0,
              column: 'name',
              value: 'x',
              keys: <String, Object?>{'id': 1, 'gone': 2},
            ),
          ],
        ),
        throwsArgumentError,
        reason: 'keys 里有未知列',
      );
    });
  });
}
