//! Correctness tests for the zero-copy raw buffer (RustOpaque + raw pointer).
//!
//! Two layers:
//!  * pure-dart tests build synthetic binary buffers and check the parser
//!    (header, columns, every cell tag, skipping, corruption handling) without
//!    touching the Rust library;
//!  * FFI tests open a real Rust-owned buffer: the demo buffer (no database)
//!    and a SELECT through SQLite (the real console engine path).
//!
//! The view/dispose contract is tested explicitly: reads before dispose work,
//! reads after dispose throw StateError instead of touching freed memory.

import 'dart:convert' show utf8;
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/raw_buffer.dart';
import 'package:rust_myadmin_desktop/src/rust/api/raw_buffer.dart'
    show makeDemoRawBuffer, rawBufferLen, rawBufferMeta, rawBufferPtr;
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';

/// Column description for the synthetic buffer builder.
class _Column {
  const _Column(this.name, this.typeName);
  final String name;
  final String typeName;
}

/// Independent (test-only) encoder for the documented format.
///
/// Deliberately does not call Rust: if the Rust encoder and this builder agree,
/// the format is verified from two directions.
Uint8List _buildBuffer({
  required List<_Column> columns,
  required List<List<Object?>> rows,
  bool truncated = false,
}) {
  final builder = BytesBuilder(copy: false);
  void u16(int value) {
    final data = ByteData(2)..setUint16(0, value, Endian.little);
    builder.add(data.buffer.asUint8List());
  }

  void u32(int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.little);
    builder.add(data.buffer.asUint8List());
  }

  void i64(int value) {
    final data = ByteData(8)..setInt64(0, value, Endian.little);
    builder.add(data.buffer.asUint8List());
  }

  void f64(double value) {
    final data = ByteData(8)..setFloat64(0, value, Endian.little);
    builder.add(data.buffer.asUint8List());
  }

  void text(String value) {
    final bytes = utf8.encode(value);
    u32(bytes.length);
    builder.add(bytes);
  }

  void cell(Object? value) {
    if (value == null) {
      builder.addByte(RawCellKind.nullValue.wireTag);
    } else if (value is bool) {
      builder.addByte(RawCellKind.boolValue.wireTag);
      builder.addByte(value ? 1 : 0);
    } else if (value is int) {
      builder.addByte(RawCellKind.intValue.wireTag);
      i64(value);
    } else if (value is double) {
      builder.addByte(RawCellKind.floatValue.wireTag);
      f64(value);
    } else if (value is String) {
      builder.addByte(RawCellKind.textValue.wireTag);
      text(value);
    } else if (value is Uint8List) {
      builder.addByte(RawCellKind.bytesValue.wireTag);
      u32(value.length);
      builder.add(value);
    } else {
      throw ArgumentError('unsupported test cell: $value');
    }
  }

  // header
  u32(rawBufferMagic);
  u16(rawBufferFormatVersion);
  u16(truncated ? rawBufferFlagTruncated : 0);
  u32(columns.length);
  u32(rows.length);
  for (final column in columns) {
    text(column.name);
    text(column.typeName);
  }
  for (final row in rows) {
    for (final value in row) {
      cell(value);
    }
  }
  return builder.toBytes();
}

const _twoColumns = <_Column>[
  _Column('id', 'BIGINT'),
  _Column('name', 'VARCHAR'),
];

/// Position of [needle] in [haystack] at or after [from], or -1.
int _findSequence(Uint8List haystack, List<int> needle, int from) {
  for (var index = from; index + needle.length <= haystack.length; index++) {
    var match = true;
    for (var offset = 0; offset < needle.length; offset++) {
      if (haystack[index + offset] != needle[offset]) {
        match = false;
        break;
      }
    }
    if (match) return index;
  }
  return -1;
}

/// The Flutter binding can only be initialized once per test isolate; both FFI
/// groups share it, so the second call is a no-op.
bool _rustLibReady = false;

Future<void> _ensureRustLib() async {
  if (_rustLibReady) return;
  final dylib = File('rust/target/debug/librust_myadmin_core.dylib');
  if (!dylib.existsSync()) {
    fail('Run `cargo build --lib` in rust/ first: ${dylib.path} is missing');
  }
  await RustLib.init(externalLibrary: ExternalLibrary.open(dylib.path));
  _rustLibReady = true;
}

void main() {
  group('pure dart format', () {
    test('header and columns are parsed', () {
      final bytes = _buildBuffer(
        columns: _twoColumns,
        rows: [
          [1, 'one'],
        ],
      );
      final header = parseRawBufferHeader(bytes);
      expect(header.version, rawBufferFormatVersion);
      expect(header.flags, 0);
      expect(header.columnCount, 2);
      expect(header.rowCount, 1);
      expect(header.truncated, isFalse);
      expect(header.byteLength, bytes.length);
      expect(header.columns.map((c) => c.name).toList(), ['id', 'name']);
      expect(header.columns.map((c) => c.typeName).toList(), [
        'BIGINT',
        'VARCHAR',
      ]);
      // header 16 + id (4+2 name, 4+6 type) + name (4+4 name, 4+7 type).
      expect(header.rowsOffset, 16 + (4 + 2 + 4 + 6) + (4 + 4 + 4 + 7));
    });

    test('every cell kind round-trips', () {
      final payload = Uint8List.fromList([0, 1, 254, 255]);
      final bytes = _buildBuffer(
        columns: const [
          _Column('a', 'T'),
          _Column('b', 'T'),
          _Column('c', 'T'),
          _Column('d', 'T'),
          _Column('e', 'T'),
          _Column('f', 'T'),
        ],
        rows: [
          [null, true, -42, 1.5, 'hello', payload],
          [0, false, 9223372036854775807, -0.25, '', Uint8List(0)],
        ],
      );
      final reader = RawBufferReader(bytes);
      final first = reader.readRow(0);
      expect(first[0].kind, RawCellKind.nullValue);
      expect(first[0].value, isNull);
      expect(first[1].kind, RawCellKind.boolValue);
      expect(first[1].value, isTrue);
      expect(first[2].value, -42);
      expect(first[3].value, 1.5);
      expect(first[4].value, 'hello');
      expect(first[5].kind, RawCellKind.bytesValue);
      expect(first[5].bytesValue, [0, 1, 254, 255]);
      expect(first[5].bytesValue!.lengthInBytes, 4);
      // BYTES payload is a view into the reader's bytes (zero copy): mutating
      // the source payload after the read changes the cell in place.
      final payloadOffset = _findSequence(bytes, [0, 1, 254, 255], 16);
      expect(payloadOffset, greaterThanOrEqualTo(16));
      bytes[payloadOffset] = 9;
      expect(first[5].bytesValue, [9, 1, 254, 255]);

      final second = reader.readRow(1);
      expect(second[0].value, 0);
      expect(second[1].value, isFalse);
      expect(second[2].value, 9223372036854775807);
      expect(second[3].value, -0.25);
      expect(second[4].value, '');
      expect(second[5].bytesValue, isEmpty);
    });

    test('empty result has a valid header and zero rows', () {
      final bytes = _buildBuffer(columns: _twoColumns, rows: const []);
      final reader = RawBufferReader(bytes);
      expect(reader.rowCount, 0);
      expect(reader.columns.length, 2);
      expect(() => reader.readRow(0), throwsRangeError);
    });

    test('truncated flag is decoded', () {
      final bytes = _buildBuffer(
        columns: _twoColumns,
        rows: [
          [1, 'x'],
        ],
        truncated: true,
      );
      expect(parseRawBufferHeader(bytes).truncated, isTrue);
      expect(RawBufferReader(bytes).truncated, isTrue);
    });

    test('readRow skips preceding rows by tag walk (no bulk copy)', () {
      final rows = List.generate(
        120,
        (index) => <Object?>[index, 'row-$index'],
      );
      final bytes = _buildBuffer(columns: _twoColumns, rows: rows);
      final reader = RawBufferReader(bytes);
      expect(reader.readRow(0).first.value, 0);
      expect(reader.readRow(57).first.value, 57);
      expect(reader.readRow(57)[1].value, 'row-57');
      final page = reader.readRows(55, 3);
      expect(page.length, 3);
      expect(page.map((row) => row.first.value).toList(), [55, 56, 57]);
      expect(reader.readRows(120, 0), isEmpty);
      expect(reader.readRows(0, 120).length, 120);
    });

    test('negative and out-of-range page bounds are rejected', () {
      final bytes = _buildBuffer(
        columns: _twoColumns,
        rows: [
          [1, 'x'],
        ],
      );
      final reader = RawBufferReader(bytes);
      expect(() => reader.readRows(-1, 1), throwsRangeError);
      expect(() => reader.readRows(0, 2), throwsRangeError);
      expect(() => reader.readRow(1), throwsRangeError);
    });

    test('bad magic is rejected', () {
      final bytes = _buildBuffer(columns: _twoColumns, rows: const []);
      bytes[0] = 0;
      expect(() => parseRawBufferHeader(bytes), throwsFormatException);
    });

    test('unsupported version is rejected', () {
      final bytes = _buildBuffer(columns: _twoColumns, rows: const []);
      ByteData.sublistView(bytes).setUint16(4, 99, Endian.little);
      expect(() => parseRawBufferHeader(bytes), throwsFormatException);
    });

    test('truncated cell payload is rejected at read time', () {
      final bytes = _buildBuffer(
        columns: _twoColumns,
        rows: [
          [1, 'abcdef'],
        ],
      );
      final cut = Uint8List.sublistView(bytes, 0, bytes.length - 3);
      // The header still parses (row count is in the header), the row read
      // notices the missing bytes.
      final reader = RawBufferReader(cut);
      expect(() => reader.readRow(0), throwsFormatException);
    });

    test('unknown cell tag is rejected', () {
      final bytes = _buildBuffer(
        columns: _twoColumns,
        rows: [
          [1, 'x'],
        ],
      );
      final header = parseRawBufferHeader(bytes);
      bytes[header.rowsOffset] = 99;
      expect(() => RawBufferReader(bytes).readRow(0), throwsFormatException);
    });

    test('column count above the defensive cap is rejected', () {
      final bytes = _buildBuffer(columns: _twoColumns, rows: const []);
      ByteData.sublistView(bytes).setUint32(8, 100000, Endian.little);
      expect(() => parseRawBufferHeader(bytes), throwsFormatException);
    });

    test('column metadata that overruns the buffer is rejected', () {
      final bytes = _buildBuffer(columns: _twoColumns, rows: const []);
      ByteData.sublistView(bytes).setUint32(8, 3, Endian.little);
      expect(() => parseRawBufferHeader(bytes), throwsFormatException);
    });
  });

  group('ffi demo buffer', () {
    setUpAll(_ensureRustLib);

    testWidgets('opens a real Rust buffer through ptr/len (zero copy)', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final handle = makeDemoRawBuffer(rows: 6);
        try {
          final pointer = rawBufferPtr(buffer: handle).toInt();
          final length = rawBufferLen(buffer: handle).toInt();
          expect(pointer, isNot(0));
          expect(length, greaterThan(rawBufferHeaderSize));

          final meta = rawBufferMeta(buffer: handle);
          expect(meta.rowCount, 6);
          expect(meta.byteLen, length);
          expect(meta.columns.map((c) => c.name).toList(), [
            'id',
            'name',
            'score',
            'active',
            'payload',
            'note',
          ]);

          final view = RawBufferView.open(handle);
          try {
            expect(view.isDisposed, isFalse);
            expect(view.byteLength, length);
            expect(view.rowCount, 6);
            expect(view.columnCount, 6);
            expect(view.truncated, isFalse);
            // Same pointer the Rust side reported: the view is not a copy.
            expect(
              view.bytesView.buffer.lengthInBytes,
              greaterThanOrEqualTo(length),
            );
            expect(view.bytesView.sublist(0, 4), [0x52, 0x41, 0x57, 0x42]);
            expect(view.header.version, rawBufferFormatVersion);
            expect(view.columns.map((c) => c.typeName).toList(), [
              'BIGINT',
              'VARCHAR',
              'DOUBLE',
              'BOOLEAN',
              'VARBINARY',
              'TEXT',
            ]);

            final first = view.readRow(0);
            expect(first.length, 6);
            expect(first[0].value, 0);
            expect(first[1].value, 'row-0');
            expect(first[2].value, 0.0);
            expect(first[3].value, isTrue);
            expect(first[4].bytesValue, [0, 0, 255]);
            expect(first[5].value, isNull);
            final second = view.readRow(1);
            expect(second[1].value, 'row-1');
            expect(second[2].value, 0.5);
            expect(second[3].value, isFalse);
            expect(second[5].value, 'note-1');
            // Every fifth row's note is NULL.
            expect(view.readRow(5)[5].value, isNull);

            final page = view.readRows(2, 3);
            expect(page.length, 3);
            expect(page.map((row) => row.first.value).toList(), [2, 3, 4]);
            expect(view.readRows(0, 6).length, 6);
          } finally {
            view.dispose();
          }
          expect(view.isDisposed, isTrue);
          expect(handle.isDisposed, isTrue);
          // Using the view after dispose is a loud error, never a freed read.
          expect(() => view.readRow(0), throwsStateError);
          expect(() => view.bytesView, throwsStateError);
          expect(() => view.columns, throwsStateError);
          // dispose is idempotent.
          view.dispose();
        } finally {
          if (!handle.isDisposed) handle.dispose();
        }
      });
    });

    testWidgets('demo buffer row count is clamped and zero rows are valid', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final empty = makeDemoRawBuffer(rows: 0);
        final view = RawBufferView.open(empty);
        try {
          expect(view.rowCount, 0);
          expect(view.columnCount, 6);
          expect(() => view.readRow(0), throwsRangeError);
        } finally {
          view.dispose();
        }
      });
    });
  });

  group('ffi sqlite end to end', () {
    late Directory temporary;
    late String connectionId;

    setUpAll(() async {
      await _ensureRustLib();
      temporary = await Directory.systemTemp.createTemp('rma-raw-buffer-');
      final init = await Api.init(temporary.path);
      expect(init['ok'], isTrue, reason: 'init_app failed: $init');
      await AppState.instance.bootstrap(temporary.path);
      final dbFile = '${temporary.path}/raw.sqlite';
      File(dbFile).createSync(recursive: true);
      final created = await Api.instance.createConnection(<String, dynamic>{
        'name': 'raw buffer',
        'driver': 'sqlite',
        'database': dbFile,
      });
      connectionId = ((created['connection'] as Map)['id']).toString();
      await AppState.instance.connect(connectionId);
    });

    tearDownAll(() async {
      try {
        await Api.instance.disconnect();
      } catch (_) {}
      try {
        temporary.deleteSync(recursive: true);
      } catch (_) {}
    });

    testWidgets('a real SELECT is encoded and read back through the view', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final setup = await Api.instance.query(
          'CREATE TABLE raw_test(id INTEGER, name TEXT, score REAL, active INTEGER); '
          'INSERT INTO raw_test VALUES (1, \'one\', 1.5, 1); '
          'INSERT INTO raw_test VALUES (2, NULL, NULL, 0);',
        );
        final results = (setup['results'] as List);
        expect(
          results.every((r) => (r as Map)['error'] == null),
          isTrue,
          reason: 'setup failed: $setup',
        );

        final view = await runQueryRawBuffer(<String, dynamic>{
          'sql': 'SELECT id, name, score, active FROM raw_test ORDER BY id',
          'database': null,
        });
        try {
          expect(view.rowCount, 2);
          expect(view.columnCount, 4);
          expect(view.columns.map((c) => c.name).toList(), [
            'id',
            'name',
            'score',
            'active',
          ]);
          final first = view.readRow(0);
          expect(first[0].value, 1);
          expect(first[1].value, 'one');
          expect(first[2].value, 1.5);
          expect(first[3].value, 1);
          final second = view.readRow(1);
          expect(second[0].value, 2);
          expect(second[1].value, isNull);
          expect(second[2].value, isNull);
          expect(second[3].value, 0);
        } finally {
          view.dispose();
        }
        expect(view.isDisposed, isTrue);
      });
    });
  });
}
