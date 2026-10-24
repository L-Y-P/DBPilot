import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'rust/api/files.dart' as rfiles;

/// Local, privacy-preserving SQL results statistics.
///
/// The 50k console cap decision needs the real row-count distribution, not a
/// guess: this recorder appends one JSON line per run to
/// `data_dir/query_metrics.jsonl` (bounded/rotated). It never stores SQL text —
/// only the first 16 hex chars of its SHA-256.
///
/// Disable with `DBPILOT_QUERY_METRICS=0`. Write failures are swallowed:
/// metrics must never break a query.
class QueryMetrics {
  QueryMetrics._();
  static final QueryMetrics instance = QueryMetrics._();

  static const String fileName = 'query_metrics.jsonl';
  static const int _maxBytes = 2 * 1024 * 1024;
  static const int _keepLines = 2000;

  bool _enabled = Platform.environment['DBPILOT_QUERY_METRICS'] != '0';
  bool _started = false;
  Future<void> _initFuture = Future<void>.value();
  Future<void> _chain = Future<void>.value();
  String? _path;
  int _nextRunId = 1;
  final Map<int, _RunMeta> _runs = <int, _RunMeta>{};

  bool get enabled => _enabled;

  /// Await the pending writes (tests only).
  @visibleForTesting
  Future<void> get pending => _chain;

  /// Point the recorder at a test file without touching the real data dir.
  @visibleForTesting
  void debugConfigure({required String path, bool enabled = true}) {
    _enabled = enabled;
    _path = path;
    _started = true;
    _initFuture = Future<void>.value();
  }

  /// Start one run; returns an id used by [finishRun] / [markPaged].
  int beginRun({required String sql, required String source}) {
    final runId = _nextRunId++;
    if (!_enabled) return runId;
    _runs[runId] = _RunMeta(
      hash: hashOf(sql),
      statementType: statementTypeOf(sql),
      source: source,
    );
    _ensureStarted();
    return runId;
  }

  /// Finish one run. Safe to call exactly once per id.
  void finishRun({
    required int runId,
    required int resultRows,
    required bool truncated,
    required int rustElapsedMs,
    required int wallMs,
    required int statementCount,
    bool failed = false,
  }) {
    if (!_enabled) return;
    final meta = _runs.remove(runId);
    if (meta == null) return;
    _enqueue(<String, Object?>{
      'ts': DateTime.now().toUtc().toIso8601String(),
      'event': 'run',
      'run_id': runId,
      'source': meta.source,
      'query_hash': meta.hash,
      'stmt_type': meta.statementType,
      'result_rows': resultRows,
      'truncated': truncated,
      'elapsed_ms_rust': rustElapsedMs,
      'wall_ms': wallMs,
      'statement_count': statementCount,
      'failed': failed,
    });
  }

  /// Record that the user paged/scroll-viewed the result of [runId].
  void markPaged({required int runId}) {
    if (!_enabled) return;
    _enqueue(<String, Object?>{
      'ts': DateTime.now().toUtc().toIso8601String(),
      'event': 'paged',
      'run_id': runId,
    });
  }

  /// First 16 hex chars of SHA-256(sql) — stable, but not reversible.
  static String hashOf(String sql) =>
      sha256.convert(utf8.encode(sql)).toString().substring(0, 16);

  /// Coarse statement class; the first token after leading comments.
  static String statementTypeOf(String sql) {
    var text = sql.trim();
    while (text.isNotEmpty) {
      if (text.startsWith('--')) {
        final end = text.indexOf('\n');
        if (end < 0) return 'other';
        text = text.substring(end + 1).trim();
      } else if (text.startsWith('/*')) {
        final end = text.indexOf('*/');
        if (end < 0) return 'other';
        text = text.substring(end + 2).trim();
      } else {
        break;
      }
    }
    if (text.isEmpty) return 'other';
    final token = text.split(RegExp(r'[\s(;]')).first.toUpperCase();
    switch (token) {
      case 'SELECT':
      case 'WITH':
      case 'TABLE':
      case 'VALUES':
        return 'select';
      case 'SHOW':
        return 'show';
      case 'EXPLAIN':
      case 'DESCRIBE':
      case 'DESC':
        return 'explain';
      case 'CREATE':
      case 'ALTER':
      case 'DROP':
      case 'TRUNCATE':
      case 'RENAME':
        return 'ddl';
      case 'USE':
        return 'use';
      default:
        return 'other';
    }
  }

  void _ensureStarted() {
    if (_started) return;
    _started = true;
    _initFuture = _initialize();
  }

  Future<void> _initialize() async {
    try {
      final response = await rfiles.dataDir();
      final map = response is Map ? response : null;
      final directory = map?['data_dir']?.toString() ?? '';
      if (directory.isEmpty) {
        _enabled = false;
        return;
      }
      final file = File('$directory/$fileName');
      await _rotate(file);
      _path = file.path;
    } catch (_) {
      _enabled = false;
    }
  }

  Future<void> _rotate(File file) async {
    try {
      if (!await file.exists() || await file.length() <= _maxBytes) return;
      final lines = await file.readAsLines();
      final kept = lines.length > _keepLines
          ? lines.sublist(lines.length - _keepLines)
          : lines;
      final buffer = StringBuffer();
      for (final line in kept) {
        buffer.writeln(line);
      }
      await file.writeAsString(buffer.toString());
    } catch (_) {
      // Rotation is best-effort; the append below still works.
    }
  }

  void _enqueue(Map<String, Object?> record) {
    if (!_enabled) return;
    _chain = _chain.then((_) async {
      await _initFuture;
      final path = _path;
      if (path == null) return;
      await File(path).writeAsString(
        '${jsonEncode(record)}\n',
        mode: FileMode.append,
        flush: false,
      );
    }).catchError((Object _) {
      // Metrics must never surface as query errors.
    });
  }
}

class _RunMeta {
  const _RunMeta({
    required this.hash,
    required this.statementType,
    required this.source,
  });

  final String hash;
  final String statementType;
  final String source;
}