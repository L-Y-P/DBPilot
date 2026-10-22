import 'dart:async';

import 'api.dart';

/// Cast a bridge value that should be a JSON object into a Map.
Json asJsonMap(Object? value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  return <String, dynamic>{};
}

/// Rules for the guided data-file import.
///
/// These classes mirror the JSON contract of the Rust importer (see
/// desktop/rust/src/importer.rs). Keeping them as plain Dart objects makes the
/// wizard state easy to serialize, copy and unit-test; the Rust side is the
/// authority for parsing semantics.

/// How one complete record is delimited in the file.
class ImportReadRule {
  ImportReadRule({
    this.mode = 'line',
    this.wrapperStart = '',
    this.wrapperEnd = '',
    this.recordSep = '\n',
    this.quote = '"',
    this.balance = true,
    this.skipBlank = true,
    this.trim = true,
    this.maxRecordBytes = 8 * 1024 * 1024,
  });

  /// line: one record per line; wrapped: file-level wrapper + separator.
  String mode;
  String wrapperStart;
  String wrapperEnd;
  String recordSep;
  String quote;
  bool balance;
  bool skipBlank;
  bool trim;
  int maxRecordBytes;

  bool get isWrapped => mode == 'wrapped';

  ImportReadRule copyWith({
    String? mode,
    String? wrapperStart,
    String? wrapperEnd,
    String? recordSep,
    String? quote,
    bool? balance,
    bool? skipBlank,
    bool? trim,
  }) {
    return ImportReadRule(
      mode: mode ?? this.mode,
      wrapperStart: wrapperStart ?? this.wrapperStart,
      wrapperEnd: wrapperEnd ?? this.wrapperEnd,
      recordSep: recordSep ?? this.recordSep,
      quote: quote ?? this.quote,
      balance: balance ?? this.balance,
      skipBlank: skipBlank ?? this.skipBlank,
      trim: trim ?? this.trim,
      maxRecordBytes: maxRecordBytes,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mode': mode,
        'wrapper_start': wrapperStart,
        'wrapper_end': wrapperEnd,
        'record_sep': recordSep,
        'quote': quote,
        'balance': balance,
        'skip_blank': skipBlank,
        'trim': trim,
        'max_record_bytes': maxRecordBytes,
      };

  factory ImportReadRule.fromJson(Json json) => ImportReadRule(
        mode: (json['mode'] ?? 'line').toString(),
        wrapperStart: (json['wrapper_start'] ?? '').toString(),
        wrapperEnd: (json['wrapper_end'] ?? '').toString(),
        recordSep: (json['record_sep'] ?? '\n').toString(),
        quote: (json['quote'] ?? '"').toString(),
        balance: json['balance'] != false,
        skipBlank: json['skip_blank'] != false,
        trim: json['trim'] != false,
        maxRecordBytes:
            (json['max_record_bytes'] as num?)?.toInt() ?? 8 * 1024 * 1024,
      );

  /// Human-readable one-line description used in the wizard summary.
  String describe() {
    if (isWrapped) {
      final open = encodeEscapes(wrapperStart);
      final close = encodeEscapes(wrapperEnd);
      final sep = encodeEscapes(recordSep);
      final wrapper = open.isEmpty && close.isEmpty
          ? '无包裹符'
          : '包裹符 [$open … $close]';
      return '自定义包裹 · $wrapper · 记录分隔符 "$sep"';
    }
    return '每行一条 · 记录分隔符 "${encodeEscapes(recordSep)}"';
  }
}

/// How the fields of one record are written.
class ImportFieldRule {
  ImportFieldRule({
    this.mode = 'delimited',
    this.fieldSep = ',',
    this.quote = '"',
    this.escape = '',
    this.trim = true,
    this.header = false,
  });

  /// delimited: CSV-style; json: one JSON value per record.
  String mode;
  String fieldSep;
  String quote;
  String escape;
  bool trim;
  bool header;

  bool get isJson => mode == 'json';

  ImportFieldRule copyWith({
    String? mode,
    String? fieldSep,
    String? quote,
    String? escape,
    bool? trim,
    bool? header,
  }) {
    return ImportFieldRule(
      mode: mode ?? this.mode,
      fieldSep: fieldSep ?? this.fieldSep,
      quote: quote ?? this.quote,
      escape: escape ?? this.escape,
      trim: trim ?? this.trim,
      header: header ?? this.header,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mode': mode,
        'field_sep': fieldSep,
        'quote': quote,
        'escape': escape,
        'trim': trim,
        'header': header,
      };

  factory ImportFieldRule.fromJson(Json json) => ImportFieldRule(
        mode: (json['mode'] ?? 'delimited').toString(),
        fieldSep: (json['field_sep'] ?? ',').toString(),
        quote: (json['quote'] ?? '"').toString(),
        escape: (json['escape'] ?? '').toString(),
        trim: json['trim'] != false,
        header: json['header'] == true,
      );

  String describe() {
    if (isJson) return '字典/JSON 记录';
    final header = this.header ? '首行为列名' : '无列名（按位置）';
    return '分隔符 "${encodeEscapes(fieldSep)}" · $header';
  }
}

/// One destination column and the source key (String) or position (int).
class ImportColumnMap {
  ImportColumnMap({required this.column, required this.source});
  String column;
  Object source; // String or int

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'column': column, 'source': source};

  ImportColumnMap copy() => ImportColumnMap(column: column, source: source);
}

/// Column mapping + value conversion options.
class ImportMappingRule {
  ImportMappingRule({
    List<ImportColumnMap>? columns,
    this.ignoreUnknown = true,
    this.emptyAsNull = false,
    List<String>? nullTokens,
    this.trimValues = true,
  })  : columns = columns ?? <ImportColumnMap>[],
        nullTokens = nullTokens ?? <String>['\\N'];

  List<ImportColumnMap> columns;
  bool ignoreUnknown;
  bool emptyAsNull;
  List<String> nullTokens;
  bool trimValues;

  ImportMappingRule copy() => ImportMappingRule(
        columns: columns.map((c) => c.copy()).toList(),
        ignoreUnknown: ignoreUnknown,
        emptyAsNull: emptyAsNull,
        nullTokens: List<String>.from(nullTokens),
        trimValues: trimValues,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'columns': columns.map((c) => c.toJson()).toList(),
        'ignore_unknown': ignoreUnknown,
        'empty_as_null': emptyAsNull,
        'null_tokens': nullTokens,
        'trim_values': trimValues,
      };
}

/// Interpret escape sequences typed into rule fields so a user can write \n or
/// \t without pressing Enter. Also supports \\, \r and \0.
String decodeEscapes(String input) {
  final out = StringBuffer();
  var i = 0;
  while (i < input.length) {
    final ch = input[i];
    if (ch == '\\' && i + 1 < input.length) {
      final next = input[i + 1];
      switch (next) {
        case 'n':
          out.write('\n');
          i += 2;
          continue;
        case 'r':
          out.write('\r');
          i += 2;
          continue;
        case 't':
          out.write('\t');
          i += 2;
          continue;
        case '0':
          out.write('\u0000');
          i += 2;
          continue;
        case '\\':
          out.write('\\');
          i += 2;
          continue;
        default:
          out.write(ch);
          i += 1;
          continue;
      }
    }
    out.write(ch);
    i += 1;
  }
  return out.toString();
}

/// Show control characters back in a text field as escape sequences.
String encodeEscapes(String value) {
  final out = StringBuffer();
  for (final ch in value.split('')) {
    switch (ch) {
      case '\n':
        out.write('\\n');
        break;
      case '\r':
        out.write('\\r');
        break;
      case '\t':
        out.write('\\t');
        break;
      case '\u0000':
        out.write('\\0');
        break;
      default:
        out.write(ch);
    }
  }
  return out.toString();
}

/// "第 12 行（第 8 条，字节 1024）" for an issue/record payload.
String recordPositionLabel(int line, int offset, [int? index]) {
  final record = index == null ? '' : '第 ${index + 1} 条，';
  return '第 $line 行（$record字节 $offset）';
}

/// Position label for one Rust issue object ({line, offset, index, message}).
String issuePositionLabel(Json issue) {
  final line = (issue['line'] as num?)?.toInt() ?? 0;
  final offset = (issue['offset'] as num?)?.toInt() ?? 0;
  final index = (issue['index'] as num?)?.toInt();
  final message = (issue['message'] ?? '').toString();
  return '${recordPositionLabel(line, offset, index)}：$message';
}

/// Group digits with thousands separators ("50000" -> "50,000").
String formatCount(num? value) {
  final text = (value ?? 0).toInt().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    if (i > 0 && (text.length - i) % 3 == 0) buffer.write(',');
    buffer.write(text[i]);
  }
  return buffer.toString();
}

/// Guess a column mapping for keyed records (JSON object / CSV header): match
/// table columns by name, case-insensitively, keeping the table's column order.
List<ImportColumnMap> autoMapKeyed(
  List<String> keys,
  List<String> tableColumns,
) {
  final exact = keys.toSet();
  final lower = keys.map((k) => k.toLowerCase()).toSet();
  final result = <ImportColumnMap>[];
  for (final column in tableColumns) {
    if (exact.contains(column)) {
      result.add(ImportColumnMap(column: column, source: column));
    } else if (lower.contains(column.toLowerCase())) {
      final match = keys.firstWhere(
        (k) => k.toLowerCase() == column.toLowerCase(),
      );
      result.add(ImportColumnMap(column: column, source: match));
    }
  }
  return result;
}

/// Guess a positional mapping: the first fieldCount table columns get fields
/// 0..fieldCount-1. Columns that are auto-increment are skipped when enough
/// other columns exist (a CSV dump usually omits the generated id).
List<ImportColumnMap> autoMapPositional(
  int fieldCount,
  List<String> tableColumns, {
  Set<String> autoIncrementColumns = const <String>{},
}) {
  var candidates = tableColumns
      .where((c) => !autoIncrementColumns.contains(c))
      .toList();
  if (candidates.length < fieldCount) candidates = tableColumns;
  final result = <ImportColumnMap>[];
  for (var i = 0; i < fieldCount && i < candidates.length; i++) {
    result.add(ImportColumnMap(column: candidates[i], source: i));
  }
  return result;
}

/// Poll a Rust import/validation/SQL-file job and surface progress updates.
///
/// Rust owns the long task; this only polls a status endpoint every 250 ms.
class ImportJobPoller {
  ImportJobPoller({
    required this.onUpdate,
    this.interval = const Duration(milliseconds: 250),
  });

  final void Function(Json status) onUpdate;
  final Duration interval;

  Timer? _timer;
  String? _jobId;
  bool _ticking = false;
  bool _disposed = false;

  String? get jobId => _jobId;

  void start(String jobId) {
    if (_disposed) return;
    _timer?.cancel();
    _jobId = jobId;
    _timer = Timer.periodic(interval, (_) => _tick());
    _tick();
  }

  Future<void> _tick() async {
    if (_ticking || _disposed || _jobId == null) return;
    _ticking = true;
    try {
      final status = await Api.instance.importJobStatus(_jobId!);
      if (_disposed) return;
      onUpdate(status);
      if (status['done'] == true) {
        _timer?.cancel();
        _timer = null;
        _jobId = null;
      }
    } catch (_) {
      // A vanished job (app restart) just stops the poller; the caller shows
      // its own message when the id is refused.
      if (!_disposed) {
        _timer?.cancel();
        _timer = null;
        _jobId = null;
      }
    } finally {
      _ticking = false;
    }
  }

  Future<void> cancelJob() async {
    final id = _jobId;
    if (id == null) return;
    try {
      await Api.instance.importJobCancel(id);
    } catch (_) {
      // Best effort; the job may have finished already.
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
