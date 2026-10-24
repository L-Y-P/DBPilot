import 'package:flutter/material.dart' hide Text, Tooltip;
import '../text.dart';

import '../api.dart';
import '../app_state.dart';
import '../db_options.dart';
import '../i18n.dart';
import '../type_labels.dart';
import '../theme.dart';
import '../widgets.dart';

/// Open the create-table designer; returns true when a table was created.
///
/// [onQuickCreate] adds the 从文件建表 entry point to the dialog's title bar
/// (round 50). The button closes the designer and delegates to the caller,
/// which owns the quick-create wizard — the dialog itself must not open another
/// dialog from its own context because popping it would tear the new route down
/// with the old one.
Future<bool> showCreateTableDialog(
  BuildContext context, {
  required String database,
  void Function(Object error)? onError,
  VoidCallback? onQuickCreate,
}) async {
  final key = GlobalKey<CreateTableDialogState>();
  final result = await showAppModal<bool>(
    context: context,
    title: t('table_new'),
    wide: true,
    builder: (context) =>
        CreateTableDialog(key: key, database: database, onError: onError),
    headerActions: [
      if (onQuickCreate != null)
        Builder(
          builder: (dialogContext) => Btn(
            '从文件建表',
            small: true,
            icon: Icons.file_upload_outlined,
            tooltip: '选择一个数据文件，按工作表批量建表并导入数据',
            onPressed: () {
              // Close the designer first; the wizard opens on the caller's
              // context so this route cannot close it again.
              Navigator.of(dialogContext).pop(false);
              onQuickCreate();
            },
          ),
        ),
    ],
    actions: [
      Builder(
        builder: (context) => Btn(
          t('preview_sql'),
          onPressed: () => key.currentState?.refreshPreview(),
        ),
      ),
      Builder(
        builder: (context) => Btn(
          t('cancel'),
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      Builder(
        builder: (context) => Btn(
          t('create'),
          primary: true,
          onPressed: () => key.currentState?.submit(),
        ),
      ),
    ],
  );
  return result == true;
}

/// One row of the column designer.
class _NewColumn {
  _NewColumn({
    required this.type,
    String name = '',
    this.nullable = true,
    this.primary = false,
    this.autoIncrement = false,
    this.charset = '',
    this.collation = '',
  }) : name = TextEditingController(text: name);

  final TextEditingController name;
  final TextEditingController defaultText = TextEditingController();
  final TextEditingController comment = TextEditingController();
  String type;
  bool nullable;
  bool primary;
  bool autoIncrement;
  String charset;
  String collation;

  void dispose() {
    name.dispose();
    defaultText.dispose();
    comment.dispose();
  }
}

/// One row of the foreign-key designer.
class _NewForeignKey {
  final TextEditingController name = TextEditingController();
  String column = '';
  String refTable = '';
  String refColumn = '';
  String onDelete = '';
  String onUpdate = '';

  void dispose() => name.dispose();
}

/// Full create-table designer, ported from the web Database.vue modal.
///
/// The old desktop dialog could create a table with **one** column and no table
/// options at all: the engine / charset / collation / row-format / auto-increment
/// / comment controls and the per-column extras the web build offered were
/// missing, so most of the "create table" feature set was unreachable. This
/// dialog restores the whole surface:
///
///   * table name, engine, charset + collation, row format, auto-increment
///     start, comment, UNLOGGED (PG), tablespace (PG), WITHOUT ROWID / STRICT
///     (SQLite), each rendered only when `meta_options.features` says the driver
///     supports it;
///   * a column grid: type, nullable, default, primary key, auto-increment,
///     per-column charset / collation and comment;
///   * a foreign-key grid: local column, referenced table + column, ON DELETE /
///     ON UPDATE;
///   * a live DDL preview produced by the Rust `dry_run` path, so the SQL shown
///     is exactly the SQL that runs.
class CreateTableDialog extends StatefulWidget {
  const CreateTableDialog({super.key, required this.database, this.onError});

  final String database;

  /// Called when the dry-run preview or the real CREATE TABLE fails.
  ///
  /// The dialog already shows the error itself; this callback only lets the
  /// database page learn that the account lacks the permission and grey the
  /// "new table" button out, instead of offering an action that can only fail
  /// again (P12).
  final void Function(Object error)? onError;

  @override
  State<CreateTableDialog> createState() => CreateTableDialogState();
}

class CreateTableDialogState extends State<CreateTableDialog> {
  static const List<String> _fkActions = <String>[
    'CASCADE',
    'SET NULL',
    'RESTRICT',
    'NO ACTION',
  ];

  final _name = TextEditingController();
  final _comment = TextEditingController();
  final _autoIncrement = TextEditingController();
  String _engine = '';
  String _charset = '';
  String _collation = '';
  String _rowFormat = '';
  String _tablespace = '';
  bool _unlogged = false;
  bool _withoutRowid = false;
  bool _strict = false;

  final List<_NewColumn> _columns = <_NewColumn>[];
  final List<_NewForeignKey> _foreignKeys = <_NewForeignKey>[];

  Json _meta = <String, dynamic>{};
  DbFeatures _features = const DbFeatures();
  List<String> _types = const <String>[];
  /// Tables already in this namespace, with their columns, so a foreign key
  /// points at a real column instead of a typed guess.
  List<Json> _otherTables = <Json>[];
  bool _loading = true;
  String? _error;
  String _preview = '';

  /// The last DDL preview the Rust dry-run path produced (exposed for tests).
  String get preview => _preview;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _name.dispose();
    _comment.dispose();
    _autoIncrement.dispose();
    for (final column in _columns) {
      column.dispose();
    }
    for (final fk in _foreignKeys) {
      fk.dispose();
    }
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final meta = await AppState.instance.loadMetaOptions();
      List<Json> tables = <Json>[];
      try {
        final schema = await Api.instance.builderSchema(widget.database);
        final raw = schema['tables'];
        if (raw is List) {
          tables =
              raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        }
      } catch (_) {
        // Foreign keys are optional; the grid still works without metadata.
      }
      if (!mounted) return;
      setState(() {
        _meta = meta;
        _features = DbFeatures.of(meta);
        _types = typeOptionsFor(AppState.instance.driver);
        _otherTables = tables;
        _charset =
            _features.tableCharset ? (meta['default_charset'] ?? '').toString() : '';
        _collation =
            _features.tableCharset ? defaultCollationFor(meta, _charset) : '';
        _engine = _features.engine ? defaultEngine(meta) : '';
        _rowFormat = _features.rowFormat ? defaultRowFormat(meta) : '';
        _tablespace = _features.tablespace ? defaultTablespace(meta) : '';
        _columns
          ..clear()
          ..add(_NewColumn(
            name: 'id',
            type: AppState.instance.isMysql ? 'INT UNSIGNED' : 'INTEGER',
            nullable: false,
            primary: true,
            autoIncrement: AppState.instance.isMysql,
            charset: _features.charset ? _charset : '',
            collation: _features.collation ? _collation : '',
          ));
        _loading = false;
      });
      await refreshPreview();
    } catch (e) {
      if (!mounted) return;
      widget.onError?.call(e);
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // --------------------------------------------------------------- payload

  /// The CreateTableSpec payload; the SQL is produced by the Rust side.
  Json body() {
    final features = _features;
    return <String, dynamic>{
      'name': _name.text.trim(),
      'engine': features.engine && _engine.isNotEmpty ? _engine : null,
      'charset': features.tableCharset && _charset.isNotEmpty ? _charset : null,
      'collation': features.tableCharset && _collation.isNotEmpty
          ? _collation
          : null,
      'row_format':
          features.rowFormat && _rowFormat.isNotEmpty ? _rowFormat : null,
      'auto_increment': features.autoIncrement
          ? int.tryParse(_autoIncrement.text.trim())
          : null,
      'unlogged': features.unlogged ? _unlogged : null,
      'tablespace':
          features.tablespace && _tablespace.isNotEmpty ? _tablespace : null,
      'without_rowid': features.withoutRowid ? _withoutRowid : null,
      'strict': features.strict ? _strict : null,
      'comment': features.comment && _comment.text.trim().isNotEmpty
          ? _comment.text.trim()
          : null,
      'columns': _columns
          .where((c) => c.name.text.trim().isNotEmpty)
          .map((c) => <String, dynamic>{
                'name': c.name.text.trim(),
                'type': c.type,
                'nullable': c.nullable,
                'default': c.defaultText.text.trim().isEmpty
                    ? null
                    : c.defaultText.text.trim(),
                'primary': c.primary,
                'auto_increment': c.autoIncrement,
                'comment': c.comment.text.trim().isEmpty
                    ? null
                    : c.comment.text.trim(),
                'charset': features.charset && isTextual(c.type)
                    ? (c.charset.isEmpty ? null : c.charset)
                    : null,
                'collation': features.collation && isTextual(c.type)
                    ? (c.collation.isEmpty ? null : c.collation)
                    : null,
              })
          .toList(),
      'foreign_keys': _foreignKeys
          .where((fk) =>
              fk.column.isNotEmpty &&
              fk.refTable.isNotEmpty &&
              fk.refColumn.isNotEmpty)
          .map((fk) => <String, dynamic>{
                'name': fk.name.text.trim().isEmpty
                    ? null
                    : fk.name.text.trim(),
                'columns': <String>[fk.column],
                'ref_table': fk.refTable,
                'ref_columns': <String>[fk.refColumn],
                'on_delete': fk.onDelete.isEmpty ? null : fk.onDelete,
                'on_update': fk.onUpdate.isEmpty ? null : fk.onUpdate,
              })
          .toList(),
    };
  }

  /// Regenerate the live DDL preview through the Rust dry-run path.
  Future<void> refreshPreview() async {
    if (_name.text.trim().isEmpty) {
      if (mounted) setState(() => _preview = '');
      return;
    }
    try {
      final res = await Api.instance.createTable(widget.database, body(),
          dryRun: true);
      if (!mounted) return;
      setState(() {
        _preview = (res['sql'] ?? '').toString();
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      widget.onError?.call(e);
      setState(() => _error = e.toString());
    }
  }

  Future<void> submit() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = (I18n.current == AppLang.en ? 'Enter a table name' : '请填写表名'));
      return;
    }
    if (_columns.every((c) => c.name.text.trim().isEmpty)) {
      setState(() => _error = (I18n.current == AppLang.en ? 'Enter at least one column name' : '请至少填写一个字段名'));
      return;
    }
    setState(() => _error = null);
    try {
      await Api.instance.createTable(widget.database, body());
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      widget.onError?.call(e);
      setState(() => _error = e.toString());
    }
  }

  // ------------------------------------------------------------------- view

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _tableOptionsCard(),
        const SizedBox(height: 14),
        _columnsCard(),
        const SizedBox(height: 14),
        _foreignKeysCard(),
        if (_error != null) ...[
          const SizedBox(height: 12),
          AlertBox(_error!),
        ],
        if (_preview.isNotEmpty) ...[
          const SizedBox(height: 12),
          SectionLabel((I18n.current == AppLang.en ? 'SQL preview' : 'SQL 预览')),
          const SizedBox(height: 6),
          CodeBlock(_preview, maxHeight: 200),
        ],
      ],
    );
  }

  Widget _tableOptionsCard() {
    final f = _features;
    final charsets = ((_meta['charsets'] as List?) ?? const <dynamic>[])
        .whereType<Map>()
        .toList();
    final rowFormats = ((_meta['row_formats'] as List?) ?? const <dynamic>[])
        .map((e) => e.toString())
        .toList();
    final engines = ((_meta['engines'] as List?) ?? const <dynamic>[])
        .whereType<Map>()
        .toList();
    final tablespaces = ((_meta['tablespaces'] as List?) ?? const <dynamic>[])
        .whereType<Map>()
        .toList();
    return CardBox(
      title: (I18n.current == AppLang.en ? 'Table options' : '表选项'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            label: t('table_name'),
            child: Field(
              key: const ValueKey('create-table-name'),
              label: t('table_name'),
              controller: _name,
              hint: 'my_table',
              onChanged: (_) => refreshPreview(),
            ),
          ),
          if (f.engine)
            FormRow(
              label: t('engine'),
              child: SelectBox<String>(
                value: _engine,
                onChanged: (v) {
                  setState(() => _engine = v ?? '');
                  refreshPreview();
                },
                items: [
                  for (final e in engines)
                    DropdownMenuItem(
                      value: e['engine'].toString(),
                      child: Text(e['engine'].toString()),
                    ),
                ],
              ),
            ),
          if (f.tableCharset) ...[
            FormRow(
              label: t('charset'),
              child: SelectBox<String>(
                value: _charset,
                onChanged: (v) {
                  setState(() {
                    _charset = v ?? '';
                    _collation = defaultCollationFor(_meta, _charset);
                  });
                  refreshPreview();
                },
                items: [
                  DropdownMenuItem(value: '', child: Text((I18n.current == AppLang.en ? '(default)' : '（默认）'))),
                  for (final c in charsets)
                    DropdownMenuItem(
                      value: c['charset'].toString(),
                      child: Text((c['description'] ?? '').toString().isEmpty
                          ? c['charset'].toString()
                          : '${c['charset']} — ${c['description']}'),
                    ),
                ],
              ),
            ),
            FormRow(
              label: t('collation'),
              child: SelectBox<String>(
                value: _collation,
                onChanged: (v) {
                  setState(() => _collation = v ?? '');
                  refreshPreview();
                },
                items: [
                  DropdownMenuItem(value: '', child: Text((I18n.current == AppLang.en ? '(default)' : '（默认）'))),
                  for (final c in collationsFor(_meta, _charset))
                    DropdownMenuItem(
                      value: c['collation'].toString(),
                      child: Text(c['collation'].toString() +
                          (c['is_default'] == 'Yes' ? ' *' : '')),
                    ),
                ],
              ),
            ),
          ],
          if (f.rowFormat)
            FormRow(
              label: t('row_format'),
              child: SelectBox<String>(
                value: _rowFormat,
                onChanged: (v) {
                  setState(() => _rowFormat = v ?? '');
                  refreshPreview();
                },
                items: [
                  for (final rf in rowFormats)
                    DropdownMenuItem(value: rf, child: Text(rf)),
                ],
              ),
            ),
          if (f.autoIncrement)
            FormRow(
              label: t('auto_increment_start'),
              child: Field(
                label: '',
                controller: _autoIncrement,
                numeric: true,
                onChanged: (_) => refreshPreview(),
              ),
            ),
          if (f.unlogged)
            FormRow(
              label: (I18n.current == AppLang.en ? 'Unlogged table' : '无日志表'),
              child: CheckBox(
                label: 'UNLOGGED',
                value: _unlogged,
                onChanged: (v) {
                  setState(() => _unlogged = v);
                  refreshPreview();
                },
              ),
            ),
          if (f.tablespace)
            FormRow(
              label: t('tablespace'),
              child: SelectBox<String>(
                value: _tablespace,
                onChanged: (v) {
                  setState(() => _tablespace = v ?? '');
                  refreshPreview();
                },
                items: [
                  DropdownMenuItem(value: '', child: Text((I18n.current == AppLang.en ? '(default)' : '（默认）'))),
                  for (final t in tablespaces)
                    DropdownMenuItem(
                      value: t['tablespace'].toString(),
                      child: Text(t['tablespace'].toString()),
                    ),
                ],
              ),
            ),
          if (f.withoutRowid)
            FormRow(
              label: 'WITHOUT ROWID',
              child: CheckBox(
                label: (I18n.current == AppLang.en ? 'Without rowid' : '不建 rowid'),
                value: _withoutRowid,
                onChanged: (v) {
                  setState(() => _withoutRowid = v);
                  refreshPreview();
                },
              ),
            ),
          if (f.strict)
            FormRow(
              label: 'STRICT',
              child: CheckBox(
                label: (I18n.current == AppLang.en ? 'Strict typing' : '严格类型'),
                value: _strict,
                onChanged: (v) {
                  setState(() => _strict = v);
                  refreshPreview();
                },
              ),
            ),
          if (f.comment)
            Field(
              label: t('table_comment'),
              controller: _comment,
              onChanged: (_) => refreshPreview(),
            ),
        ],
      ),
    );
  }

  Widget _columnsCard() {
    final f = _features;
    return CardBox(
      title: t('columns'),
      actions: [
        Btn(t('add_column'), small: true, onPressed: _addColumn),
      ],
      child: GridTable(
        headers: [
          Text(t('column_name')),
          Text(t('column_type')),
          Text((I18n.current == AppLang.en ? 'Allow NULL' : '允许 NULL')),
          Text(t('default_value')),
          Text(t('primary_key')),
          Text(t('auto_increment')),
          if (f.charset) Text(t('column_charset')),
          if (f.collation) Text(t('column_collation')),
          Text(t('comment')),
          const Text(''),
        ],
        emptyText: (I18n.current == AppLang.en ? '(no columns yet)' : '（还没有字段）'),
        rows: [
          for (var i = 0; i < _columns.length; i++) _columnRow(i),
        ],
      ),
    );
  }

  List<Map> get _charsetList =>
      ((_meta['charsets'] as List?) ?? const <dynamic>[]).whereType<Map>().toList();

  TableRow _columnRow(int index) {
    final f = _features;
    final charsets = _charsetList;
    final column = _columns[index];
    final textual = isTextual(column.type);
    final typeItems = <String>[..._types];
    if (column.type.isNotEmpty && !typeItems.contains(column.type)) {
      typeItems.insert(0, column.type);
    }
    return TableRow(
      key: ObjectKey(column),
      children: [
        _textCell(column.name, label: '${t('column_name')} #${index + 1}', onChanged: (_) => refreshPreview()),
        Padding(
          padding: const EdgeInsets.all(4),
          // 中文界面说人话（整数 / 文本（VARCHAR(255)）…），英文界面仍是原始
          // SQL 类型；选择值始终是 SQL 类型，DDL 预览不受影响。
          child: ColumnTypePicker(
            value: column.type,
            types: typeItems,
            width: 150,
            onChanged: (v) {
              setState(() => column.type = v ?? column.type);
              refreshPreview();
            },
          ),
        ),
        _checkCell(column.nullable, (v) {
          setState(() => column.nullable = v);
          refreshPreview();
        }),
        _textCell(column.defaultText, onChanged: (_) => refreshPreview()),
        _checkCell(column.primary, (v) {
          setState(() => column.primary = v);
          refreshPreview();
        }),
        _checkCell(column.autoIncrement, (v) {
          setState(() => column.autoIncrement = v);
          refreshPreview();
        }),
        if (f.charset)
          _selectCell(
            value: column.charset,
            emptyLabel: (I18n.current == AppLang.en ? '(inherit)' : '（继承）'),
            width: 170,
            enabled: textual,
            items: [
              for (final c in charsets)
                MapEntry(c['charset'].toString(), c['charset'].toString()),
            ],
            onChanged: (v) {
              setState(() {
                column.charset = v;
                if (f.collation) {
                  column.collation = defaultCollationFor(_meta, v);
                }
              });
              refreshPreview();
            },
          ),
        if (f.collation)
          _selectCell(
            value: column.collation,
            emptyLabel: (I18n.current == AppLang.en ? '(inherit)' : '（继承）'),
            width: 210,
            enabled: textual,
            items: [
              for (final c in collationsFor(
                  _meta, f.tableCharset ? column.charset : ''))
                MapEntry(c['collation'].toString(), c['collation'].toString()),
            ],
            onChanged: (v) {
              setState(() => column.collation = v);
              refreshPreview();
            },
          ),
        _textCell(column.comment, onChanged: (_) => refreshPreview()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Btn(t('delete'),
              small: true,
              danger: true,
              onPressed: () {
                setState(() {
                  final removed = _columns.removeAt(index);
                  removed.dispose();
                });
                refreshPreview();
              }),
        ),
      ],
    );
  }

  void _addColumn() {
    setState(() {
      _columns.add(_NewColumn(
        type: _types.isEmpty ? 'TEXT' : _types.first,
        charset: _features.charset ? _charset : '',
        collation: _features.collation ? _collation : '',
      ));
    });
    refreshPreview();
  }

  // ---------------------------------------------------------- foreign keys

  Widget _foreignKeysCard() {
    final supported = !AppState.instance.isSqlite;
    return CardBox(
      title: (I18n.current == AppLang.en ? 'Foreign keys' : '外键约束'),
      actions: [
        Btn((I18n.current == AppLang.en ? 'Add foreign key' : '添加外键'),
            small: true, onPressed: supported ? _addForeignKey : null),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!supported)
            Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'SQLite 不支持在 CREATE TABLE 之外新增外键；这里添加的外键会随建表语句一起创建。',
                style: kSmallMuted,
              ),
            ),
          GridTable(
            headers: [
              Text((I18n.current == AppLang.en ? 'Constraint name' : '外键名')),
              Text((I18n.current == AppLang.en ? 'Local column' : '本表字段')),
              Text((I18n.current == AppLang.en ? 'Referenced table' : '引用表')),
              Text((I18n.current == AppLang.en ? 'Referenced column' : '引用字段')),
              Text('ON DELETE'),
              Text('ON UPDATE'),
              Text(''),
            ],
            emptyText: (I18n.current == AppLang.en ? '(none)' : '（无）'),
            rows: [
              for (var i = 0; i < _foreignKeys.length; i++) _foreignKeyRow(i),
            ],
          ),
        ],
      ),
    );
  }

  TableRow _foreignKeyRow(int index) {
    final fk = _foreignKeys[index];
    final tables = _otherTables
        .map((t) => t['name'].toString())
        .where((n) => n.isNotEmpty)
        .toList();
    final refColumns = (() {
      for (final t in _otherTables) {
        if (t['name'].toString() != fk.refTable) continue;
        final columns = t['columns'];
        if (columns is List) {
          return columns
              .whereType<Map>()
              .map((c) => c['name'].toString())
              .where((n) => n.isNotEmpty)
              .toList();
        }
      }
      return <String>[];
    })();
    return TableRow(
      children: [
        _textCell(fk.name, onChanged: (_) => refreshPreview()),
        _selectCell(
          value: fk.column,
          emptyLabel: (I18n.current == AppLang.en ? 'Select column' : '选择字段'),
          items: [
            for (final column in _columns)
              if (column.name.text.trim().isNotEmpty)
                MapEntry(column.name.text.trim(), column.name.text.trim()),
          ],
          onChanged: (v) {
            setState(() => fk.column = v);
            refreshPreview();
          },
        ),
        _selectCell(
          value: fk.refTable,
          emptyLabel: (I18n.current == AppLang.en ? 'Select table' : '选择表'),
          items: [for (final table in tables) MapEntry(table, table)],
          onChanged: (v) {
            setState(() {
              fk.refTable = v;
              fk.refColumn = '';
            });
            refreshPreview();
          },
        ),
        _selectCell(
          value: fk.refColumn,
          emptyLabel: (I18n.current == AppLang.en ? 'Select column' : '选择字段'),
          items: [
            for (final column in refColumns) MapEntry(column, column),
          ],
          onChanged: (v) {
            setState(() => fk.refColumn = v);
            refreshPreview();
          },
        ),
        _selectCell(
          value: fk.onDelete,
          emptyLabel: (I18n.current == AppLang.en ? '(no action)' : '（无动作）'),
          items: [for (final a in _fkActions) MapEntry(a, a)],
          onChanged: (v) {
            setState(() => fk.onDelete = v);
            refreshPreview();
          },
        ),
        _selectCell(
          value: fk.onUpdate,
          emptyLabel: (I18n.current == AppLang.en ? '(no action)' : '（无动作）'),
          items: [for (final a in _fkActions) MapEntry(a, a)],
          onChanged: (v) {
            setState(() => fk.onUpdate = v);
            refreshPreview();
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Btn(t('remove'),
              small: true,
              danger: true,
              onPressed: () {
                setState(() {
                  final removed = _foreignKeys.removeAt(index);
                  removed.dispose();
                });
                refreshPreview();
              }),
        ),
      ],
    );
  }

  void _addForeignKey() {
    setState(() => _foreignKeys.add(_NewForeignKey()));
  }

  // ------------------------------------------------------------- controls

  Widget _textCell(TextEditingController controller,
      {ValueChanged<String>? onChanged, double width = 130, String? label}) {
    return Padding(
      padding: const EdgeInsets.all(4),
      child: SizedBox(
        width: width,
        child: TextField(
          key: ObjectKey(controller),
          controller: controller,
          onChanged: onChanged,
          style: const TextStyle(fontSize: 12),
          decoration: InputDecoration(
            labelText: label,
            isDense: true,
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          ),
        ),
      ),
    );
  }

  Widget _checkCell(bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: CheckBox(label: '', value: value, onChanged: onChanged),
    );
  }

  Widget _selectCell({
    required String value,
    required String emptyLabel,
    required List<MapEntry<String, String>> items,
    required ValueChanged<String> onChanged,
    bool enabled = true,
    double width = 150,
  }) {
    return Padding(
      padding: const EdgeInsets.all(4),
      child: SizedBox(
        // Wide enough for a real collation name ("utf8mb4_0900_ai_ci"); the
        // grid used to clip it to "utf8mb4_0900_a" with no way to read the rest.
        width: width,
        child: SelectBox<String>(
          value: value,
          enabled: enabled,
          onChanged: (v) => onChanged(v ?? ''),
          items: [
            DropdownMenuItem(value: '', child: Text(emptyLabel)),
            for (final item in items)
              DropdownMenuItem(value: item.key, child: Text(item.value)),
          ],
        ),
      ),
    );
  }
}
