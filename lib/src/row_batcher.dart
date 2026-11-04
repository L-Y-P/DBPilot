// Streaming row batching for the SQL console result view (round 85, Plan A).
//
// The console consumes the streaming API: every batch event used to call
// setState immediately, so a 50k-row result (500 rows / batch) rebuilt the
// whole result card ~100 times, and each rebuild re-copied the full row list.
// That synchronous work on the UI thread is what made large results stutter.
//
// [RowBatcher] is the pure part of the fix: it buffers incoming batches per
// statement and decides *when* to hand them to the UI. The widget flushes a
// buffer when it reaches [rowThreshold] rows, or on a timer the widget owns
// (see `_SqlViewState`), or unconditionally at every terminal point (statement
// done / query done / failed / finally / dispose). Keeping the timing source
// outside makes the buffer logic unit-testable without a Flutter binding.


/// Buffered rows for a single statement plus its first-seen column metadata.
class _StatementBuffer {
  final List<List<dynamic>> rows = <List<dynamic>>[];
  List<Map<String, dynamic>>? columns;
  bool truncated = false;
}

/// One flush: the rows and metadata accumulated for [statementIndex] since the
/// previous flush of that statement.
class RowBatchFlush {
  RowBatchFlush({
    required this.statementIndex,
    required this.rows,
    required this.columns,
    required this.truncated,
    required this.firstBatch,
  });

  final int statementIndex;

  /// Rows added since the last flush, in arrival order. Never empty.
  final List<List<dynamic>> rows;

  /// Column metadata, only present on the statement's first flush (the console
  /// stores columns once and keeps them across later flushes).
  final List<Map<String, dynamic>>? columns;

  /// True when any buffered batch for this statement was truncated.
  final bool truncated;

  /// True for the first flush of a statement (used to set `kind = 'rows'`).
  final bool firstBatch;
}

/// Accumulates streaming row batches and groups them into fewer, larger flushes.
///
/// Pure Dart: no timers, no Flutter. The owner calls [add] for every batch and
/// then either drains itself once [dueByThreshold] becomes true or calls
/// [drain] at a terminal point. The 100 ms coalescing window is owned by the widget so
/// this class stays deterministic and unit-testable.
class RowBatcher {
  RowBatcher({this.rowThreshold = 2000}) : assert(rowThreshold > 0);

  /// Flush once the number of buffered rows reaches this value.
  final int rowThreshold;

  final Map<int, _StatementBuffer> _buffers = <int, _StatementBuffer>{};
  final Set<int> _seenFirstBatch = <int>{};
  int _bufferedSinceFlush = 0;

  /// True when nothing is buffered.
  bool get isEmpty => _buffers.isEmpty;

  /// Rows buffered since the last flush (drives the threshold check).
  int get bufferedSinceFlush => _bufferedSinceFlush;

  /// True when the buffered row count has reached [rowThreshold].
  bool get dueByThreshold => _bufferedSinceFlush >= rowThreshold;

  /// Buffer one batch for [statementIndex].
  ///
  /// [rows] are already-converted cell lists (`List<List<dynamic>>`); [columns]
  /// is the batch's column metadata (usually only present on the first batch).
  /// Returns true when the caller should flush now (threshold reached).
  bool add({
    required int statementIndex,
    required List<List<dynamic>> rows,
    List<Map<String, dynamic>>? columns,
    bool truncated = false,
  }) {
    final buffer = _buffers.putIfAbsent(statementIndex, _StatementBuffer.new);
    if (rows.isNotEmpty) buffer.rows.addAll(rows);
    if (columns != null && columns.isNotEmpty) buffer.columns ??= columns;
    if (truncated) buffer.truncated = true;
    _bufferedSinceFlush += rows.length;
    return dueByThreshold;
  }

  /// Remove and return everything buffered, grouped per statement.
  ///
  /// Statements that accumulated no rows *and* no new metadata are skipped, so
  /// a flush is never a no-op list. [firstBatch] is true for the first flush of
  /// a statement index and false thereafter.
  List<RowBatchFlush> drain() {
    if (_buffers.isEmpty) {
      _bufferedSinceFlush = 0;
      return const <RowBatchFlush>[];
    }
    final flushes = <RowBatchFlush>[];
    _buffers.forEach((index, buffer) {
      if (buffer.rows.isEmpty && buffer.columns == null) return;
      final first = _seenFirstBatch.add(index);
      flushes.add(RowBatchFlush(
        statementIndex: index,
        rows: List<List<dynamic>>.unmodifiable(buffer.rows),
        columns: buffer.columns,
        truncated: buffer.truncated,
        firstBatch: first,
      ));
    });
    _buffers.clear();
    _bufferedSinceFlush = 0;
    return flushes;
  }

  /// Apply one [flush] to the mutable JS result map the console stores.
  ///
  /// The console keeps one result map per statement with `rows` (a growing
  /// `List<dynamic>`), `columns` (set once), `kind` and `truncated`. This
  /// mutates that map in place with the flushed rows — the exact merge the
  /// widget performs inside setState — so the semantics (append order, kind
  /// only when there are rows/columns, first-seen columns preserved, truncated
  /// sticky) are unit-testable without a Flutter binding.
  static void applyFlush(Map<String, dynamic> result, RowBatchFlush flush) {
    final rows = result['rows'];
    final target = rows is List ? rows : <dynamic>[];
    if (!identical(rows, target)) result['rows'] = target;
    target.addAll(flush.rows);
    if (flush.columns != null) result['columns'] = flush.columns;
    if (flush.rows.isNotEmpty || (flush.columns?.isNotEmpty ?? false)) {
      result['kind'] = 'rows';
    }
    if (flush.truncated) result['truncated'] = true;
  }

  /// Forget all buffered state and the first-flush bookkeeping (new run).
  void reset() {
    _buffers.clear();
    _seenFirstBatch.clear();
    _bufferedSinceFlush = 0;
  }
}
