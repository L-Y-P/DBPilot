// Batched row edits: staged dirty cells -> applyRowChanges payload.
//
// The table page (and the SQL console result grid) let the user stage several
// cell edits and save them in **one transaction** through the Rust
// api::explorer::apply_row_changes handler. This file owns the pure mapping
// from the grid's dirty cells to that handler's JSON shape, so it can be
// unit-tested without Flutter or the Rust bridge.

import 'dart:convert';

/// One staged cell edit.
///
/// [rowIndex] is an index into the exact `rows` list the grid rendered; callers
/// that show a page (SQL console result view) must map it back to their own row
/// list before building the payload. For cross-page batches use [keys] with
/// [buildRowChangesFromKeys] instead: the row index only makes sense for the
/// page the edit was staged on.
class DirtyCell {
  const DirtyCell({
    required this.rowIndex,
    required this.column,
    this.value,
    this.isNull = false,
    this.keys,
  });

  final int rowIndex;
  final String column;
  final Object? value;
  final bool isNull;

  /// Original row keys captured when the edit was staged（第 59 轮）.
  ///
  /// Primary-key columns when known, otherwise the whole row. They are captured
  /// **before** the edit is applied (and kept when the edited cell is itself a
  /// key column), so a cross-page batch still targets the row the user started
  /// from. Null for edits created without key capture (old call sites/tests).
  final Map<String, Object?>? keys;

  /// Value sent to the backend: an explicit `null` when the user ticked NULL.
  Object? get payloadValue => isNull ? null : value;

  @override
  bool operator ==(Object other) =>
      other is DirtyCell &&
      other.rowIndex == rowIndex &&
      other.column == column &&
      other.isNull == isNull &&
      other.value == value &&
      rowChangeKeyFor(other.keys) == rowChangeKeyFor(keys);

  @override
  int get hashCode =>
      Object.hash(rowIndex, column, value, isNull, rowChangeKeyFor(keys));

  @override
  String toString() => 'DirtyCell(row: $rowIndex, column: $column, '
      'value: ${isNull ? 'NULL' : value})';
}

/// Canonical string for a row-key map, usable as a Map key.
///
/// Entries are sorted by column name and each value is JSON-encoded so a numeric
/// `1` and a string `'1'` do not collide. Null/empty keys return the empty
/// string.
String rowChangeKeyFor(Map<String, Object?>? keys) {
  if (keys == null || keys.isEmpty) return '';
  final entries = keys.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return entries
      .map((entry) => '${entry.key}\u0000${jsonEncode(entry.value)}')
      .join('\u0001');
}

/// Capture the row keys for [row]: the primary key when known, otherwise every
/// column (the same rule single-cell edits have always used).
Map<String, Object?> rowChangeKeys({
  required List<Map<String, dynamic>> columns,
  required List<dynamic> row,
  required List<String> primaryKey,
}) =>
    _rowKeys(columns, row, primaryKey);

/// Canonical identity of [row] inside one page (see [rowChangeKeyFor]).
String rowChangeKey({
  required List<Map<String, dynamic>> columns,
  required List<dynamic> row,
  required List<String> primaryKey,
}) =>
    rowChangeKeyFor(rowChangeKeys(
      columns: columns,
      row: row,
      primaryKey: primaryKey,
    ));

/// Build the `changes` array for `Api.applyRowChanges`.
///
/// * one UPDATE per touched row (several dirty cells on the same row are merged
///   into one statement, so "save all" is one round trip per row, not per cell),
/// * the row key is [primaryKey] when known; a table without a primary key uses
///   every column and sets `limit_one: true`, which is exactly
///   `change_row`'s "match at most one physical row" contract,
/// * a NULL edit is sent as an explicit `null`, never dropped (dropping it
///   would be the same as "do not change this column").
///
/// Throws [ArgumentError] for a row index outside [rows], or for a column name
/// that is not in [columns] (a stale grid view), instead of sending a silently
/// wrong UPDATE.
List<Map<String, dynamic>> buildRowChanges({
  required List<Map<String, dynamic>> columns,
  required List<List<dynamic>> rows,
  required List<String> primaryKey,
  required List<DirtyCell> edits,
}) {
  final columnIndex = <String, int>{
    for (var i = 0; i < columns.length; i++) columns[i]['name'].toString(): i,
  };
  final byRow = <int, Map<String, Object?>>{};
  for (final edit in edits) {
    if (edit.rowIndex < 0 || edit.rowIndex >= rows.length) {
      throw ArgumentError.value(
          edit.rowIndex, 'edits', 'row index outside the rendered rows');
    }
    if (!columnIndex.containsKey(edit.column)) {
      throw ArgumentError.value(edit.column, 'edits', 'unknown column');
    }
    (byRow[edit.rowIndex] ??= <String, Object?>{})[edit.column] =
        edit.payloadValue;
  }
  final changes = <Map<String, dynamic>>[];
  for (final entry in byRow.entries) {
    final row = rows[entry.key];
    changes.add(<String, dynamic>{
      'action': 'update',
      'keys': _rowKeys(columns, row, primaryKey),
      'values': entry.value,
      'limit_one': primaryKey.isEmpty,
    });
  }
  return changes;
}

/// Build the `changes` array for [Api.applyRowChanges] from edits that carry
/// their own row keys（第 59 轮：跨页批量保存）。
///
/// Unlike [buildRowChanges] this does not need the rendered `rows` at all, so
/// edits staged on different pages can be combined in one transaction: every
/// edit targets the row identified by [DirtyCell.keys] captured when it was
/// staged. Several dirty cells on the same row key are merged into one UPDATE.
///
/// * the key is the captured row key (primary key when known, otherwise the
///   whole row) — see [rowChangeKeys];
/// * `limit_one` is true when [primaryKey] is empty (same contract as
///   [buildRowChanges]);
/// * a NULL edit is sent as an explicit `null`, never dropped.
///
/// Throws [ArgumentError] for an unknown column, for a missing/empty [DirtyCell.keys],
/// for a key column that is not in [columns], or when [primaryKey] requests a key
/// column that the edit did not capture — instead of sending a wrong UPDATE.
List<Map<String, dynamic>> buildRowChangesFromKeys({
  required List<Map<String, dynamic>> columns,
  required List<String> primaryKey,
  required List<DirtyCell> edits,
}) {
  final columnNames = <String>{
    for (final column in columns) column['name'].toString(),
  };
  final keyColumns = primaryKey.isEmpty ? columnNames : primaryKey.toSet();
  final valuesByKey = <String, Map<String, Object?>>{};
  final keysByKey = <String, Map<String, Object?>>{};
  for (final edit in edits) {
    if (!columnNames.contains(edit.column)) {
      throw ArgumentError.value(edit.column, 'edits', 'unknown column');
    }
    final keys = edit.keys;
    if (keys == null || keys.isEmpty) {
      throw ArgumentError.value(edit, 'edits', 'row keys are required');
    }
    for (final name in keys.keys) {
      if (!columnNames.contains(name)) {
        throw ArgumentError.value(name, 'keys', 'unknown key column');
      }
    }
    for (final name in keyColumns) {
      if (!keys.containsKey(name)) {
        throw ArgumentError.value(name, 'keys', 'missing key column');
      }
    }
    final key = rowChangeKeyFor(keys);
    (valuesByKey[key] ??= <String, Object?>{})[edit.column] =
        edit.payloadValue;
    keysByKey[key] = keys;
  }
  return <Map<String, dynamic>>[
    for (final entry in valuesByKey.entries)
      <String, dynamic>{
        'action': 'update',
        'keys': keysByKey[entry.key],
        'values': entry.value,
        'limit_one': primaryKey.isEmpty,
      },
  ];
}

/// Key columns identifying [row]: the primary key when known, otherwise every
/// column (same rule the table page has always used for single-cell edits).
Map<String, Object?> _rowKeys(
  List<Map<String, dynamic>> columns,
  List<dynamic> row,
  List<String> primaryKey,
) {
  final target = primaryKey.isEmpty
      ? <String>{for (final column in columns) column['name'].toString()}
      : primaryKey.toSet();
  final keys = <String, Object?>{};
  for (var i = 0; i < columns.length; i++) {
    final name = columns[i]['name'].toString();
    if (!target.contains(name)) continue;
    keys[name] = i < row.length ? row[i] : null;
  }
  return keys;
}
