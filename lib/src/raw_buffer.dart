//! Zero-copy view over a Rust-owned result buffer (mechanism prototype).
//!
//! Rust encodes a result set into one contiguous little-endian byte buffer and
//! hands Dart a raw pointer + length. This file turns those two integers into a
//! `Uint8List` **view** of Rust memory:
//!
//! ```dart
//! final handle = await makeRawBufferFromQuery(body: {...});
//! final view = RawBufferView.open(handle); // no row bytes copied
//! try {
//!   print(view.readRow(0));                // parse one row on demand
//! } finally {
//!   view.dispose();                        // frees the Rust buffer
//! }
//! ```
//!
//! # Safety boundary (must stay documented)
//!
//! * The `Uint8List` is **not GC-tracked**. It points into the `Vec<u8>` owned
//!   by the opaque Rust handle.
//! * It is valid only while the handle is alive. [RawBufferView.dispose] calls
//!   the generated opaque `dispose()`, which drops the buffer; every read after
//!   that throws [StateError] instead of touching freed memory.
//! * Do **not** store [RawBufferView.bytesView] (or a `sublistView` of it, or a
//!   `RawCell.bytesValue`, which is another zero-copy view) beyond the handle's
//!   lifetime.
//! * The buffer is immutable while the handle lives, so a view never dangles
//!   because Rust reallocated it.
//! * Writes through the view would corrupt Rust-owned memory; the API never
//!   exposes a mutable typed list.
//!
//! # Format
//!
//! Version 1, little-endian (mirror of `rust/src/api/raw_buffer.rs`):
//!
//! ```text
//! header:  magic u32 ("RAWB") | version u16 | flags u16 (bit0 = truncated)
//!          | col_count u32 | row_count u32
//! columns: col_count x (name_len u32 + utf8 name, type_len u32 + utf8 type)
//! rows:    row_count x col_count x cell
//! cell:    tag u8 + payload (0 null, 1 bool u8, 2 i64 LE, 3 f64 LE,
//!          4 text u32 len + utf8, 5 bytes u32 len + raw)
//! ```

import 'dart:convert' show utf8;
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'rust/api/query_types.dart' show ColumnDto;
import 'rust/api/raw_buffer.dart' as rust;

/// `"RAWB"` encoded as a little-endian u32, exactly like the Rust constant.
const int rawBufferMagic = 0x42574152;

/// Supported binary layout version.
const int rawBufferFormatVersion = 1;

/// Size of the fixed header, in bytes.
const int rawBufferHeaderSize = 16;

/// Header flag bit 0: the console row cap truncated the result.
const int rawBufferFlagTruncated = 1;

/// Defensive bound on the encoded column count (corrupt input guard).
const int _maxColumns = 4096;

/// Defensive bound on a single encoded string, so a corrupt length cannot ask
/// the parser to allocate gigabytes.
const int _maxStringBytes = 1 << 20;

/// One cell, decoded from the binary buffer.
///
/// Exactly one payload field is meaningful, selected by [kind]. This mirrors
/// `CellValue` from the typed FRB path so both can be compared cell by cell.
class RawCell {
  const RawCell._({
    required this.kind,
    this.boolValue,
    this.intValue,
    this.floatValue,
    this.textValue,
    this.bytesValue,
  });

  const RawCell.nullValue() : this._(kind: RawCellKind.nullValue);

  const RawCell.bool(bool value)
    : this._(kind: RawCellKind.boolValue, boolValue: value);

  const RawCell.int(int value)
    : this._(kind: RawCellKind.intValue, intValue: value);

  const RawCell.float(double value)
    : this._(kind: RawCellKind.floatValue, floatValue: value);

  const RawCell.text(String value)
    : this._(kind: RawCellKind.textValue, textValue: value);

  const RawCell.bytes(Uint8List value)
    : this._(kind: RawCellKind.bytesValue, bytesValue: value);

  final RawCellKind kind;
  final bool? boolValue;
  final int? intValue;
  final double? floatValue;
  final String? textValue;

  /// Zero-copy view into the Rust buffer for BYTES cells — see the safety note
  /// at the top of the file.
  final Uint8List? bytesValue;

  /// The payload as a plain Dart value (`null` for SQL NULL).
  Object? get value => switch (kind) {
    RawCellKind.nullValue => null,
    RawCellKind.boolValue => boolValue,
    RawCellKind.intValue => intValue,
    RawCellKind.floatValue => floatValue,
    RawCellKind.textValue => textValue,
    RawCellKind.bytesValue => bytesValue,
  };

  @override
  String toString() => switch (kind) {
    RawCellKind.nullValue => 'NULL',
    RawCellKind.boolValue => 'bool($boolValue)',
    RawCellKind.intValue => 'int($intValue)',
    RawCellKind.floatValue => 'float($floatValue)',
    RawCellKind.textValue => 'text($textValue)',
    RawCellKind.bytesValue => 'bytes(${bytesValue!.length})',
  };
}

/// Cell tags of the binary format (must match the `CELL_KIND_*` constants in
/// `rust/src/api/query_types.rs`).
enum RawCellKind {
  nullValue(0),
  boolValue(1),
  intValue(2),
  floatValue(3),
  textValue(4),
  bytesValue(5);

  const RawCellKind(this.wireTag);

  final int wireTag;

  static RawCellKind fromWireTag(int tag) {
    for (final kind in values) {
      if (kind.wireTag == tag) return kind;
    }
    throw FormatException('raw buffer: 未知 cell tag $tag');
  }
}

/// Decoded header (plus column metadata) of a raw buffer.
@visibleForTesting
class RawBufferHeader {
  const RawBufferHeader({
    required this.version,
    required this.flags,
    required this.columnCount,
    required this.rowCount,
    required this.columns,
    required this.rowsOffset,
    required this.byteLength,
  });

  final int version;
  final int flags;
  final int columnCount;
  final int rowCount;
  final List<ColumnDto> columns;

  /// Offset of the first cell in the buffer.
  final int rowsOffset;

  /// Total buffer length in bytes.
  final int byteLength;

  bool get truncated => (flags & rawBufferFlagTruncated) != 0;
}

/// Parse and validate the header/columns of [bytes].
///
/// Exposed for tests: it is pure Dart and does not need the Rust library, so
/// the binary format can be verified with synthetic byte buffers.
@visibleForTesting
RawBufferHeader parseRawBufferHeader(Uint8List bytes) {
  if (bytes.length < rawBufferHeaderSize) {
    throw FormatException(
      'raw buffer: 长度 ${bytes.length} 小于 header $rawBufferHeaderSize 字节',
    );
  }
  final data = ByteData.sublistView(bytes);
  final magic = data.getUint32(0, Endian.little);
  if (magic != rawBufferMagic) {
    throw FormatException(
      'raw buffer: magic 不匹配 '
      '(0x${magic.toRadixString(16)} != 0x${rawBufferMagic.toRadixString(16)})',
    );
  }
  final version = data.getUint16(4, Endian.little);
  if (version != rawBufferFormatVersion) {
    throw FormatException(
      'raw buffer: 不支持的格式版本 $version (期望 $rawBufferFormatVersion)',
    );
  }
  final flags = data.getUint16(6, Endian.little);
  final columnCount = data.getUint32(8, Endian.little);
  final rowCount = data.getUint32(12, Endian.little);
  if (columnCount > _maxColumns) {
    throw FormatException('raw buffer: 列数 $columnCount 超过上限 $_maxColumns');
  }

  var offset = rawBufferHeaderSize;
  final columns = <ColumnDto>[];
  for (var index = 0; index < columnCount; index++) {
    final name = _readSizedUtf8(bytes, data, offset, '列名');
    offset = name.nextOffset;
    final typeName = _readSizedUtf8(bytes, data, offset, '列类型');
    offset = typeName.nextOffset;
    columns.add(ColumnDto(name: name.value, typeName: typeName.value));
  }
  if (offset > bytes.length) {
    throw FormatException('raw buffer: columns 结束位置超过 buffer 长度');
  }

  return RawBufferHeader(
    version: version,
    flags: flags,
    columnCount: columnCount,
    rowCount: rowCount,
    columns: columns,
    rowsOffset: offset,
    byteLength: bytes.length,
  );
}

/// Pure-Dart row cursor over a raw buffer (no FFI, no handle ownership).
///
/// Rows are parsed on demand: `readRow(40_000)` skips the preceding rows by
/// walking their tags, it never copies or decodes all rows.
@visibleForTesting
class RawBufferReader {
  RawBufferReader(this.bytes)
    : header = parseRawBufferHeader(bytes),
      _data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData _data;
  final RawBufferHeader header;

  int get rowCount => header.rowCount;
  int get columnCount => header.columnCount;
  List<ColumnDto> get columns => header.columns;
  bool get truncated => header.truncated;

  /// Read one row. Throws [RangeError] for an out-of-range index and
  /// [FormatException] when the payload is truncated/corrupt.
  List<RawCell> readRow(int index) => readRows(index, 1).single;

  /// Read [count] rows starting at [start].
  ///
  /// The skip is a linear walk over the preceding rows' cell tags, exactly what
  /// a paginated reader needs; nothing before [start] is materialised.
  List<List<RawCell>> readRows(int start, int count) {
    if (start < 0) throw RangeError.range(start, 0, rowCount, 'start');
    if (count < 0) throw RangeError.range(count, 0, null, 'count');
    if (start + count > rowCount) {
      throw RangeError.range(start + count, 0, rowCount, 'start + count');
    }
    final cursor = _Cursor(bytes, _data, header.rowsOffset);
    for (var index = 0; index < start; index++) {
      _skipRow(cursor);
    }
    final rows = <List<RawCell>>[];
    for (var index = 0; index < count; index++) {
      rows.add(_readRow(cursor));
    }
    return rows;
  }

  List<RawCell> _readRow(_Cursor cursor) {
    final row = <RawCell>[];
    for (var column = 0; column < header.columnCount; column++) {
      row.add(_readCell(cursor));
    }
    return row;
  }

  void _skipRow(_Cursor cursor) {
    for (var column = 0; column < header.columnCount; column++) {
      _skipCell(cursor);
    }
  }

  void _skipCell(_Cursor cursor) {
    final tag = cursor.readUint8();
    switch (tag) {
      case 0:
        return;
      case 1:
        cursor.skip(1);
      case 2:
      case 3:
        cursor.skip(8);
      case 4:
      case 5:
        final length = cursor.readUint32();
        cursor.skip(length);
      default:
        throw FormatException('raw buffer: 未知 cell tag $tag');
    }
  }

  RawCell _readCell(_Cursor cursor) {
    final tag = cursor.readUint8();
    switch (tag) {
      case 0:
        return const RawCell.nullValue();
      case 1:
        return RawCell.bool(cursor.readUint8() != 0);
      case 2:
        return RawCell.int(cursor.readInt64());
      case 3:
        return RawCell.float(cursor.readFloat64());
      case 4:
        final length = cursor.readUint32();
        return RawCell.text(utf8.decode(cursor.readSlice(length)));
      case 5:
        final length = cursor.readUint32();
        return RawCell.bytes(cursor.readSlice(length));
      default:
        throw FormatException('raw buffer: 未知 cell tag $tag');
    }
  }
}

/// Owns a [rust.RawRowBuffer] handle and exposes its bytes as a zero-copy view.
///
/// The handle is kept alive for the lifetime of this object; [dispose] releases
/// it. All reads check [isDisposed] first so a use-after-dispose fails loudly
/// instead of reading freed memory.
class RawBufferView {
  RawBufferView._(this._handle, this._reader);

  /// Wrap a Rust handle. Reads `ptr`/`len` once, validates the header, and
  /// takes ownership of the handle.
  ///
  /// If validation fails the handle is disposed and the error is rethrown.
  factory RawBufferView.open(rust.RawRowBuffer handle) {
    try {
      final pointer = rust.rawBufferPtr(buffer: handle).toInt();
      final length = rust.rawBufferLen(buffer: handle).toInt();
      if (pointer == 0 || length == 0) {
        throw StateError(
          'raw buffer: Rust 返回空指针/零长度 '
          '(ptr=0x${pointer.toRadixString(16)}, len=$length)',
        );
      }
      if (length < rawBufferHeaderSize) {
        throw FormatException('raw buffer: 长度 $length 小于 header');
      }
      final bytes = ffi.Pointer<ffi.Uint8>.fromAddress(pointer)
          .asTypedList(length);
      return RawBufferView._(handle, RawBufferReader(bytes));
    } catch (_) {
      handle.dispose();
      rethrow;
    }
  }

  final rust.RawRowBuffer _handle;
  final RawBufferReader _reader;
  bool _disposed = false;

  /// Parsed format header (magic/version already validated).
  RawBufferHeader get header {
    _checkAlive();
    return _reader.header;
  }

  List<ColumnDto> get columns {
    _checkAlive();
    return _reader.columns;
  }

  int get columnCount {
    _checkAlive();
    return _reader.columnCount;
  }

  int get rowCount {
    _checkAlive();
    return _reader.rowCount;
  }

  bool get truncated {
    _checkAlive();
    return _reader.truncated;
  }

  /// Length of the underlying view in bytes (header included).
  int get byteLength {
    _checkAlive();
    return _reader.bytes.length;
  }

  /// The raw zero-copy view of Rust memory.
  ///
  /// For benchmarks/diagnostics only: never retain it past [dispose].
  Uint8List get bytesView {
    _checkAlive();
    return _reader.bytes;
  }

  bool get isDisposed => _disposed;

  /// Parse a single row (see [RawBufferReader.readRow]).
  List<RawCell> readRow(int index) {
    _checkAlive();
    return _reader.readRow(index);
  }

  /// Parse [count] rows starting at [start], skipping earlier rows by tag walk.
  List<List<RawCell>> readRows(int start, int count) {
    _checkAlive();
    return _reader.readRows(start, count);
  }

  /// Release the Rust buffer. Idempotent; every later read throws
  /// [StateError].
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _handle.dispose();
  }

  void _checkAlive() {
    if (_disposed) {
      throw StateError('RawBufferView 已 dispose：视图指向的 Rust 内存已释放，禁止再读取');
    }
  }

  @override
  String toString() =>
      'RawBufferView(columns: ${_reader.header.columnCount}, '
      'rows: ${_reader.header.rowCount}, bytes: ${_reader.bytes.length}, '
      'truncated: ${_reader.truncated}, disposed: $_disposed)';
}

/// Run [body] through the console engine and open a zero-copy view.
///
/// The caller owns the returned view and **must** `dispose()` it:
///
/// ```dart
/// final view = await runQueryRawBuffer({'sql': 'SELECT ...'});
/// try { ... } finally { view.dispose(); }
/// ```
Future<RawBufferView> runQueryRawBuffer(Object? body) async {
  return RawBufferView.open(await rust.makeRawBufferFromQuery(body: body));
}

/// Open a synthetic demo buffer (no database needed); used by tests.
@visibleForTesting
RawBufferView openDemoRawBuffer(int rows) {
  return RawBufferView.open(rust.makeDemoRawBuffer(rows: rows));
}

// ------------------------------------------------------------------ internals

class _SizedUtf8 {
  const _SizedUtf8(this.value, this.nextOffset);

  final String value;
  final int nextOffset;
}

_SizedUtf8 _readSizedUtf8(
  Uint8List bytes,
  ByteData data,
  int offset,
  String label,
) {
  if (offset + 4 > bytes.length) {
    throw FormatException('raw buffer: $label 长度字段越界 (offset=$offset)');
  }
  final length = data.getUint32(offset, Endian.little);
  final start = offset + 4;
  if (length > _maxStringBytes) {
    throw FormatException(
      'raw buffer: $label 长度 $length 超过上限 $_maxStringBytes',
    );
  }
  final end = start + length;
  if (end > bytes.length) {
    throw FormatException(
      'raw buffer: $label 内容越界 (end=$end > ${bytes.length})',
    );
  }
  return _SizedUtf8(utf8.decode(Uint8List.sublistView(bytes, start, end)), end);
}

class _Cursor {
  _Cursor(this.bytes, this.data, this.offset);

  final Uint8List bytes;
  final ByteData data;
  int offset;

  void _ensure(int length) {
    if (offset + length > bytes.length) {
      throw FormatException(
        'raw buffer: 数据被截断 (需要 $length 字节, '
        'offset=$offset, len=${bytes.length})',
      );
    }
  }

  int readUint8() {
    _ensure(1);
    return bytes[offset++];
  }

  int readUint32() {
    _ensure(4);
    final value = data.getUint32(offset, Endian.little);
    offset += 4;
    return value;
  }

  int readInt64() {
    _ensure(8);
    final value = data.getInt64(offset, Endian.little);
    offset += 8;
    return value;
  }

  double readFloat64() {
    _ensure(8);
    final value = data.getFloat64(offset, Endian.little);
    offset += 8;
    return value;
  }

  Uint8List readSlice(int length) {
    _ensure(length);
    final slice = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return slice;
  }

  void skip(int length) {
    _ensure(length);
    offset += length;
  }
}
