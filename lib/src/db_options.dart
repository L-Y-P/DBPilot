library;

import 'api.dart';

/// Shared helpers for server-provided character set / collation / engine
/// options, ported 1:1 from `web/src/dbOptions.ts`.
///
/// The desktop build had no equivalent module, which is exactly why the desktop
/// create-table dialog offered no engine / charset / collation / row-format
/// controls: the helpers that decide what a driver can express were missing.

/// True when a column type carries text (so charset / collation apply to it).
bool isTextual(String type) {
  return RegExp(r'char|text|enum|set|json|uuid|clob|string|citext',
          caseSensitive: false)
      .hasMatch(type);
}

/// Column types offered per driver.
const Map<String, List<String>> typeOptions = <String, List<String>>{
  'mysql': <String>[
    'INT',
    'INT UNSIGNED',
    'TINYINT',
    'TINYINT(1)',
    'SMALLINT',
    'MEDIUMINT',
    'BIGINT',
    'BIGINT UNSIGNED',
    'DECIMAL(10,2)',
    'DECIMAL(20,6)',
    'FLOAT',
    'DOUBLE',
    'BIT',
    'CHAR(36)',
    'VARCHAR(64)',
    'VARCHAR(255)',
    'VARCHAR(500)',
    'TEXT',
    'TINYTEXT',
    'MEDIUMTEXT',
    'LONGTEXT',
    "ENUM('a','b')",
    "SET('a','b')",
    'JSON',
    'DATE',
    'TIME',
    'DATETIME',
    'TIMESTAMP',
    'YEAR',
    'BINARY(16)',
    'VARBINARY(255)',
    'BLOB',
    'MEDIUMBLOB',
    'LONGBLOB',
  ],
  'postgres': <String>[
    'smallint',
    'integer',
    'bigint',
    'serial',
    'bigserial',
    'smallserial',
    'numeric(10,2)',
    'numeric(20,6)',
    'real',
    'double precision',
    'money',
    'boolean',
    'char(36)',
    'varchar(64)',
    'varchar(255)',
    'varchar(500)',
    'text',
    'citext',
    'uuid',
    'json',
    'jsonb',
    'xml',
    'bytea',
    'date',
    'time',
    'timetz',
    'timestamp',
    'timestamptz',
    'interval',
    'inet',
    'cidr',
    'macaddr',
    'point',
    'tsvector',
  ],
  'sqlite': <String>[
    'INTEGER',
    'INT',
    'TINYINT',
    'SMALLINT',
    'BIGINT',
    'REAL',
    'DOUBLE',
    'FLOAT',
    'NUMERIC',
    'DECIMAL(10,2)',
    'TEXT',
    'VARCHAR(255)',
    'CHAR(36)',
    'CLOB',
    'BLOB',
    'BOOLEAN',
    'DATE',
    'DATETIME',
    'TIMESTAMP',
    'JSON',
  ],
};

List<String> typeOptionsFor(String driver) =>
    typeOptions[driver] ?? typeOptions['mysql']!;

/// MySQL character sets the connection editor offers.
///
/// This is the intersection of two capability sets and is deliberately narrower
/// than what the server advertises: `information_schema.CHARACTER_SETS` on
/// MySQL 8.x still lists `utf8mb3`, but sqlx's MySQL client has no entry for
/// that spelling and fails the handshake with "unsupported MySQL charset:
/// utf8mb3" (round34 P2-02). `utf8` is the same 3-byte encoding under the name
/// the client accepts, so the alias is not offered a second time. A connection
/// already saved with `utf8mb3` still opens: the Rust side maps it to
/// `utf8` in desktop/rust/src/drivers/mysql/mod.rs (`connection_charset`).
const List<String> mysqlConnectionCharsets = <String>[
  'utf8mb4',
  'utf8',
  'latin1',
  'gbk',
  'big5',
  'binary',
];

/// Character sets the connection form may offer for [driver].
///
/// [meta] is the connected server's `meta['charsets']` when one is already
/// known; it narrows the list to the names *this* server really has. With no
/// server at hand — a brand-new connection, which is the only case the form can
/// hit today — the driver's own capability list is used. That is why the list is
/// not simply the server's: asking the server would re-introduce `utf8mb3` on
/// MySQL 8.x, which the client then refuses. Non-MySQL drivers have no
/// connection charset at all.
List<String> connectionCharsetsFor(String driver, {Json? meta}) {
  if (driver != 'mysql') return const <String>[];
  final server = ((meta?['charsets'] as List?) ?? const <dynamic>[])
      .whereType<Map>()
      .map((c) => (c['charset'] ?? '').toString().toLowerCase())
      .where((name) => name.isNotEmpty)
      .toSet();
  if (server.isEmpty) return mysqlConnectionCharsets;
  final narrowed =
      mysqlConnectionCharsets.where(server.contains).toList(growable: false);
  // A server that recognises none of the names we know (an older MariaDB, a
  // failed metadata load) must not leave the user with an empty dropdown.
  return narrowed.isEmpty ? mysqlConnectionCharsets : narrowed;
}

/// What the connected server can actually express, so the form renders only the
/// options its driver supports.
class DbFeatures {
  const DbFeatures({
    this.charset = false,
    this.tableCharset = false,
    this.collation = false,
    this.engine = false,
    this.rowFormat = false,
    this.autoIncrement = false,
    this.comment = false,
    this.unlogged = false,
    this.tablespace = false,
    this.withoutRowid = false,
    this.strict = false,
  });

  factory DbFeatures.of(Json? meta) {
    final raw = meta?['features'];
    if (raw is! Map) return const DbFeatures();
    bool flag(String key) => raw[key] == true;
    return DbFeatures(
      charset: flag('charset'),
      tableCharset: flag('table_charset'),
      collation: flag('collation'),
      engine: flag('engine'),
      rowFormat: flag('row_format'),
      autoIncrement: flag('auto_increment'),
      comment: flag('comment'),
      unlogged: flag('unlogged'),
      tablespace: flag('tablespace'),
      withoutRowid: flag('without_rowid'),
      strict: flag('strict'),
    );
  }

  final bool charset;
  final bool tableCharset;
  final bool collation;
  final bool engine;
  final bool rowFormat;
  final bool autoIncrement;
  final bool comment;
  final bool unlogged;
  final bool tablespace;
  final bool withoutRowid;
  final bool strict;
}

/// The engine the server reports as its default (MySQL: SUPPORT='DEFAULT').
String defaultEngine(Json? meta) {
  final engines = (meta?['engines'] as List?) ?? const <dynamic>[];
  for (final e in engines) {
    if (e is Map && e['support'] == 'DEFAULT') return e['engine'].toString();
  }
  for (final e in engines) {
    if (e is Map && e['engine'] == 'InnoDB') return 'InnoDB';
  }
  return engines.isEmpty ? '' : (engines.first as Map)['engine'].toString();
}

/// Collation to use for [charset] (empty means "whatever the server prefers").
String defaultCollationFor(Json? meta, String charset) {
  final collations = ((meta?['collations'] as List?) ?? const <dynamic>[])
      .whereType<Map>()
      .toList();
  if (charset.isEmpty) {
    for (final c in collations) {
      if (c['is_default'] == 'Yes') return c['collation'].toString();
    }
    return '';
  }
  for (final c in collations) {
    if (c['charset'] == charset && c['is_default'] == 'Yes') {
      return c['collation'].toString();
    }
  }
  for (final c in ((meta?['charsets'] as List?) ?? const <dynamic>[])
      .whereType<Map>()) {
    if (c['charset'] == charset && (c['default_collation'] ?? '').isNotEmpty) {
      return c['default_collation'].toString();
    }
  }
  for (final c in collations) {
    if (c['charset'] == charset) return c['collation'].toString();
  }
  return '';
}

/// Collations belonging to [charset] (all of them when it is empty).
List<Map> collationsFor(Json? meta, String charset) {
  final all = ((meta?['collations'] as List?) ?? const <dynamic>[])
      .whereType<Map>()
      .toList();
  if (charset.isEmpty) return all;
  return all
      .where((c) => (c['charset'] ?? '').toString().isEmpty ||
          c['charset'] == charset)
      .toList();
}

String defaultRowFormat(Json? meta) {
  final serverDefault = (meta?['default_row_format'] ?? '').toString();
  if (serverDefault.isNotEmpty) return serverDefault;
  final formats = (meta?['row_formats'] as List?) ?? const <dynamic>[];
  return formats.isEmpty ? '' : formats.first.toString();
}

String defaultTablespace(Json? meta) {
  final list = ((meta?['tablespaces'] as List?) ?? const <dynamic>[])
      .whereType<Map>()
      .toList();
  for (final t in list) {
    if (t['is_default'] == 'Yes') return t['tablespace'].toString();
  }
  return list.isEmpty ? '' : list.first['tablespace'].toString();
}

/// Character set of a table, derived from its collation.
String charsetOfTable(Json? info, Json? meta) {
  final collation = (info?['TABLE_COLLATION'] ?? '').toString();
  if (collation.isNotEmpty) {
    for (final c in ((meta?['collations'] as List?) ?? const <dynamic>[])
        .whereType<Map>()) {
      if (c['collation'] == collation && (c['charset'] ?? '').isNotEmpty) {
        return c['charset'].toString();
      }
    }
    final prefix = collation.split('_').first;
    if (prefix.isNotEmpty) return prefix;
  }
  return (meta?['default_charset'] ?? '').toString();
}
