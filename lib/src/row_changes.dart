// Batched row edits: staged dirty cells -> applyRowChanges payload.
//
// The table page (and the SQL console result grid) let the user stage several
// cell edits and save them in **one transaction** through the Rust
// api::explorer::apply_row_changes handler. This file owns the pure mapping
// from the grid's dirty cells to that handler's JSON shape, so it can be
// unit-tested without Flutter or the Rust bridge.

/// One staged cell edit.
///
/// [rowIndex] is an index into the exact `rows` list the grid rendered; callers
/// that show a page (SQL console result view) must map it back to their own row
/// list before building the payload.
class DirtyCell {
  const DirtyCell({
    required this.rowIndex,
    required this.column,
    this.value,
    this.isNull = false,
  });

  final int rowIndex;
  final String column;
  final Object? value;
  final bool isNull;

  /// Value sent to the backend: an explicit `null` when the user ticked NULL.
  Object? get payloadValue => isNull ? null : value;

  @override
  bool operator ==(Object other) =>
      other is DirtyCell &&
      other.rowIndex == rowIndex &&
      other.column == column &&
      other.isNull == isNull &&
      other.value == value;

  @override
  int get hashCode => Object.hash(rowIndex, column, value, isNull);

  @override
  String toString() => 'DirtyCell(row: $rowIndex, column: $column, '
      'value: ${isNull ? 'NULL' : value})';
}

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
