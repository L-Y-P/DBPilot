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
}
