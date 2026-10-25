import 'dart:io';

import 'package:flutter/material.dart' hide Text, Tooltip;
import '../text.dart';

import '../api.dart';
import '../app_state.dart';
import '../components/data_grid.dart';
import '../i18n.dart';
import '../i18n_literals.dart';
import '../import_rules.dart';
import '../nav.dart';
import '../notice.dart';
import '../row_changes.dart';
import '../sql_highlight.dart';
import '../sqlite_sources.dart';
import '../theme.dart';
import 'data_import_wizard.dart';
import '../widgets.dart';
import 'result_table.dart';

/// ALTER 载荷里「非空列表才代表修改」的字段（与 Rust AlterTableSpec 的
/// `is_empty` 对齐）。
const List<String> _tableDesignListKeys = <String>[
  'add_columns',
  'modify_columns',
  'drop_columns',
  'rename_columns',
  'add_indexes',
  'drop_indexes',
  'add_foreign_keys',
  'drop_foreign_keys',
];

/// ALTER 载荷里「空串 = 没改」的字符串选项。
const List<String> _tableDesignStringKeys = <String>[
  'rename_to',
  'engine',
  'row_format',
  'charset',
  'collation',
  'tablespace',
];

/// ALTER 载荷里「null = 没改」的 Option 字段。
///
/// `comment` 用的是 Rust 的 `Option<String>`：null 表示不改，**空串表示清空
/// 注释**（是一种真实修改）；`set_primary_key` 同理（Some([]) 也算修改）。
const List<String> _tableDesignOptionKeys = <String>[
  'comment',
  'auto_increment',
  'set_primary_key',
  'unlogged',
  'without_rowid',
  'strict',
];

/// 设计 tab 的 ALTER 载荷是否为空（= 没有任何未应用的修改）。
///
/// 纯函数，便于单测：判断规则与 Rust 的 `AlterTableSpec::is_empty` 保持一致，
/// 覆盖字段（add/modify/drop/rename）、索引、外键、表名/注释以及
/// engine/row_format/auto_increment/charset/collation 等表选项。
///
/// 注意：未知字段（例如预览时附加的 `dry_run`）不参与判断，避免把内部参数
/// 误当成用户修改。
bool tableDesignBodyEmpty(Json body) {
  for (final key in _tableDesignListKeys) {
    final value = body[key];
    if (value == null) continue;
    if (value is! List) return false;
    if (value.isNotEmpty) return false;
  }
  for (final key in _tableDesignStringKeys) {
    final value = body[key];
    if (value != null && value.toString().trim().isNotEmpty) return false;
  }
  for (final key in _tableDesignOptionKeys) {
    if (body[key] != null) return false;
  }
  return true;
}

/// 设计器里是否存在需要「应用」或「撤销」的修改。
bool tableDesignHasPendingChanges(Json body) => !tableDesignBodyEmpty(body);

/// 从 structure 结果里取当前表注释（没有 info / 没有注释时为空串）。
///
/// 设计器的「表注释」只有在和这个基线值不同时才算未应用的修改，否则表本来
/// 就带注释时打开设计 tab 会一直显示 dirty。
String currentTableComment(Json structure) {
  final info = structure['info'];
  if (info is! Map) return '';
  return (info['TABLE_COMMENT'] ?? '').toString().trim();
}

/// 设计器字段行的「可编辑字段」（从 structure 的列定义规范化后的基线）。
///
/// 只包含可编辑的 6 个字段（不含 isNew/original/charset 这些 UI/元数据键），
/// 便于 [tableDesignColumnRowDirty] 做纯粹的字段比较。按原列名索引。
Map<String, Json> tableDesignColumnBaseline(Json structure) {
  final columns = structure['columns'];
  if (columns is! List) return <String, Json>{};
  final baseline = <String, Json>{};
  for (final raw in columns) {
    if (raw is! Map) continue;
    final name = (raw['name'] ?? '').toString();
    if (name.isEmpty) continue;
    baseline[name] = <String, dynamic>{
      'name': name,
      'type': (raw['type_name'] ?? '').toString(),
      'nullable': raw['IS_NULLABLE'] == 'YES',
      'default': raw['COLUMN_DEFAULT']?.toString() ?? '',
      'auto_increment': (raw['EXTRA'] ?? '').toString().contains(
        'auto_increment',
      ),
      'comment': (raw['COLUMN_COMMENT'] ?? '').toString(),
    };
  }
  return baseline;
}

/// 设计器里的一列相对于 [baseline] 是否被改过（第 56 轮：逐列还原）。
///
/// 只比较可编辑字段，UI 附加键（isNew/original/charset…）忽略。空值口径与
/// _buildAlter 一致：default/comment 的 null 与空串等价（空的默认值/注释不会
/// 被写进 ALTER 载荷）；列名按 trim 后比较（载荷里的列名也是 trim 过的）。
bool tableDesignColumnRowDirty(Json baseline, Json current) {
  String text(Json row, String key) => (row[key] ?? '').toString();
  bool optionTextChanged(String key) {
    // text() 已把 null/缺失统一成空串：null 与空串等价，只有值不同才算改。
    return text(baseline, key) != text(current, key);
  }

  if (text(baseline, 'name').trim() != text(current, 'name').trim()) {
    return true;
  }
  if (text(baseline, 'type') != text(current, 'type')) return true;
  if ((baseline['nullable'] == true) != (current['nullable'] == true)) {
    return true;
  }
  if (optionTextChanged('default')) return true;
  if ((baseline['auto_increment'] == true) !=
      (current['auto_increment'] == true)) {
    return true;
  }
  if (optionTextChanged('comment')) return true;
  return false;
}

/// 由基线生成一行可直接替换进 _designColumns 的深拷贝。
///
/// 六个可编辑字段与 [baseline] 等值；另外补上设计器需要的 UI 元数据
/// （isNew=false、original=列名），这样替换后的行会立刻被当作「数据库里的
/// 现有列」，不显示 changed/new，也不会在 _buildAlter 里丢掉 kept 映射。
Json tableDesignResetColumnRow(Json baseline) {
  final name = (baseline['name'] ?? '').toString();
  return <String, dynamic>{
    'name': name,
    'type': (baseline['type'] ?? '').toString(),
    'nullable': baseline['nullable'] == true,
    'default': baseline['default']?.toString() ?? '',
    'auto_increment': baseline['auto_increment'] == true,
    'comment': baseline['comment']?.toString() ?? '',
    'isNew': false,
    'original': name,
  };
}

/// 设计器里需要重命名的列（第 56 轮补充：列重命名真正生效）。
///
/// 只输出「数据库里已存在（isNew != true）且名字真的变了」的列，按设计器里的
/// 列顺序返回 `{'from': 原名, 'to': 新名}`。以下情况不生成，避免 ALTER 指向
/// 不存在/冲突的列（UI 如需更细的提示可另做校验）：
///   * 新加的列（isNew）没有原名，不能 RENAME；
///   * 原名/新名为空（不会产生空 to）；
///   * 新旧名相同（trim 后比较）；
///   * 新名和其它列的现有名（或其它列的原名）撞名，包括两列互换名——MySQL/
///     PostgreSQL 的 RENAME COLUMN 是逐条执行的，中间态撞名会直接失败。
///
/// Rust 会把每个 RENAME 拆成独立语句并**先**执行，然后再执行其余 ALTER（第 56
/// 轮 MySQL 实测：同一条 ALTER 里用旧名 MODIFY 会报 Unknown column）。所以既改
/// 类型又改名的列，modify payload 必须用**新**列名（见
/// [tableDesignColumnAlterPayload]）；未改名或改名因撞名被跳过时仍用原名。
/// SQLite 由驱动按自己的重建/rename 语义处理同一个 spec。
List<Json> tableDesignRenameColumns(List<Json> designColumns) {
  final count = designColumns.length;
  final originals = <String>[];
  final currentNames = <String>[];
  final candidates = <bool>[];
  for (var i = 0; i < count; i++) {
    final column = designColumns[i];
    final original = (column['original'] ?? '').toString().trim();
    final name = (column['name'] ?? '').toString().trim();
    originals.add(original.toLowerCase());
    currentNames.add(name.toLowerCase());
    candidates.add(
      column['isNew'] != true &&
          original.isNotEmpty &&
          name.isNotEmpty &&
          original != name,
    );
  }
  final out = <Json>[];
  final taken = <String>{};
  for (var i = 0; i < count; i++) {
    if (!candidates[i]) continue;
    final from = (designColumns[i]['original'] ?? '').toString().trim();
    final to = (designColumns[i]['name'] ?? '').toString().trim();
    final key = to.toLowerCase();
    if (taken.contains(key)) continue;
    var conflict = false;
    for (var j = 0; j < count && !conflict; j++) {
      if (j == i) continue;
      if (originals[j] == key) {
        // 目标名还是另一列的原名：逐条 RENAME 时该列尚未改名 → 撞名。
        conflict = true;
      } else if (!candidates[j] && currentNames[j] == key) {
        // 目标名被一个不参与重命名的列占用。
        conflict = true;
      }
    }
    if (conflict) continue;
    taken.add(key);
    out.add(<String, dynamic>{'from': from, 'to': to});
  }
  return out;
}

/// 现有列在 ALTER 载荷里的列名（第 56 轮补充：rename 改成独立语句先执行后，
/// 被改名列的 MODIFY 必须用新列名）。
///
/// * 该列有 [tableDesignRenameColumns] 生成的重命名 → 用 `to`（新名字此时
///   已经存在）；
/// * 没有重命名（没改名，或改名因撞名被跳过）→ 用原列名，避免 MODIFY 指向
///   不存在的列；
/// * 新列（original 为空）→ 用当前名。
String tableDesignColumnAlterName(Json column, List<Json> renameColumns) {
  final original = (column['original'] ?? '').toString().trim();
  final current = (column['name'] ?? '').toString().trim();
  if (column['isNew'] == true || original.isEmpty) return current;
  for (final rename in renameColumns) {
    if ((rename['from'] ?? '').toString().trim() != original) continue;
    final to = (rename['to'] ?? '').toString().trim();
    if (to.isNotEmpty) return to;
  }
  return original;
}

/// 构造一列的 ALTER payload（add_columns / modify_columns 共用）。
///
/// 名字规则见 [tableDesignColumnAlterName]；其余字段与旧实现一致：空默认值 /
/// 空注释发送 null（表示不改），只有真实差异才由调用方放进列表。
Json tableDesignColumnAlterPayload(Json column, List<Json> renameColumns) {
  return <String, dynamic>{
    'name': tableDesignColumnAlterName(column, renameColumns),
    'type': (column['type'] ?? '').toString(),
    'nullable': column['nullable'] == true,
    'default': (column['default'] ?? '').toString().isEmpty
        ? null
        : column['default'].toString(),
    'auto_increment': column['auto_increment'] == true,
    'comment': (column['comment'] ?? '').toString().isEmpty
        ? null
        : column['comment'].toString(),
  };
}

/// 一次批量保存的纯文案（第 63 轮）：中英文成对返回，便于单测同时断言。
class BatchApplyCopy {
  const BatchApplyCopy({required this.zh, required this.en});

  final String zh;
  final String en;
}

/// 批量保存（applyRowChanges）的结果（第 60 轮，第 63 轮细分原因）。
///
/// [zeroRows] 来自 Rust 的 `zero_row_results`（UPDATE/DELETE 影响 0 行）；
/// 第 63 轮起 Rust 还会返回 `zero_row_reasons` 与每条的 `reason`：
///   * not_found：目标行不存在（DELETE 的 0 行一定是这个）；
///   * unchanged：行还在、值本来就没变（MySQL 统计真正改变的行时才会出现）；
///   * unknown：存在性检查失败（权限/并发等），不臆测原因。
/// 老后端只有条数，[notFound]/[unchanged]/[unknown] 全为 0，提示退回旧文案。
class BatchApplyOutcome {
  const BatchApplyOutcome({
    required this.rowsAffected,
    required this.zeroRows,
    this.notFound = 0,
    this.unchanged = 0,
    this.unknown = 0,
  });

  final int rowsAffected;
  final int zeroRows;
  final int notFound;
  final int unchanged;
  final int unknown;

  bool get hasZeroRows => zeroRows > 0;

  BatchApplyCopy get copy => batchApplyCopy(
        rowsAffected: rowsAffected,
        zeroRows: zeroRows,
        notFound: notFound,
        unchanged: unchanged,
        unknown: unknown,
      );

  /// 保存成功后的用户提示（零行命中时追加按原因细分的诊断）。
  String get message => pickText(copy.zh, copy.en);

  /// 自定义提示（如「保存到原表」）复用的零行诊断后缀（含前导分隔符）。
  String get zeroRowSuffix {
    final zero = batchZeroRowCopy(
      zeroRows: zeroRows,
      notFound: notFound,
      unchanged: unchanged,
      unknown: unknown,
    );
    if (zero == null) return '';
    return pickText('；${zero.zh}', '; ${zero.en}');
  }
}

/// 零行诊断（不含「已保存 N 行」前缀）；没有零行改动时返回 null。
///
/// 未知条数按「总数 - 已解释条数」推断，这样老后端（只有 zeroRows）与新后端
/// 漏传某个计数时都不会丢提示；unknown 单独计数时也走旧的「可能已被删除或键
/// 被修改」措辞，绝不臆测成 not_found/unchanged。
BatchApplyCopy? batchZeroRowCopy({
  required int zeroRows,
  int notFound = 0,
  int unchanged = 0,
  int unknown = 0,
}) {
  if (zeroRows <= 0 && notFound <= 0 && unchanged <= 0 && unknown <= 0) {
    return null;
  }
  final rest = zeroRows - notFound - unchanged;
  final derivedUnknown = rest < 0 ? 0 : rest;
  final unknownCount = unknown > derivedUnknown ? unknown : derivedUnknown;
  final zhParts = <String>[
    if (notFound > 0) '$notFound 条未命中（目标行不存在）',
    if (unchanged > 0) '$unchanged 条值未变化（未写入）',
    if (unknownCount > 0)
      '$unknownCount 条改动未命中任何行（可能已被删除或键被修改）',
  ];
  final enParts = <String>[
    if (notFound > 0)
      '$notFound edit(s) matched no row (the target row no longer exists)',
    if (unchanged > 0)
      '$unchanged edit(s) had unchanged values (nothing was written)',
    if (unknownCount > 0)
      '$unknownCount edit(s) matched no row (the row may have been deleted or '
          'its key changed)',
  ];
  return BatchApplyCopy(zh: zhParts.join('；'), en: enParts.join('; '));
}

/// 批量保存成功提示的纯函数版本（便于单测中英双语；UI 用 BatchApplyOutcome.message）。
BatchApplyCopy batchApplyCopy({
  required int rowsAffected,
  int zeroRows = 0,
  int notFound = 0,
  int unchanged = 0,
  int unknown = 0,
}) {
  final saved = BatchApplyCopy(
    zh: '已保存 $rowsAffected 行',
    en: 'Saved $rowsAffected row(s)',
  );
  final zero = batchZeroRowCopy(
    zeroRows: zeroRows,
    notFound: notFound,
    unchanged: unchanged,
    unknown: unknown,
  );
  if (zero == null) return saved;
  return BatchApplyCopy(
    zh: '${saved.zh}；${zero.zh}',
    en: '${saved.en}; ${zero.en}',
  );
}

/// Single-table workbench with tabs: Browse, Structure, Design, DDL, Insert,
/// SQL, Export, Import and Operations.
///
/// Ports Table.vue. The visual designer, the WHERE filter builder and the
/// per-cell editing all keep the web semantics, including the rule that a
/// row is only editable when the statement resolves to one table.
class TableView extends StatefulWidget {
  const TableView({
    super.key,
    required this.db,
    required this.table,
    required this.notice,
  });

  final String db;
  final String table;
  final Notice notice;

  @override
  State<TableView> createState() => _TableViewState();
}

class _TableViewState extends State<TableView> with SingleTickerProviderStateMixin {
  static const _tabs = [
    'browse',
    'structure',
    'design',
    'ddl',
    'insert',
    'sql',
    'export',
    'import',
    'operations',
  ];

  /// Placeholder of the insert form's dropdowns: leaving it selected means the
  /// column stays out of the INSERT and the database applies its default.
  static const _defaultInsertOption = '（默认）';

  late TabController _tabController;
  String _tab = 'browse';

  Json _data = <String, dynamic>{};
  Json _structure = <String, dynamic>{};
  List<SortSpec> _sorts = <SortSpec>[];
  final _where = TextEditingController();
  int _page = 1;
  int _perPage = 25;

  /// 跨页暂存的批量编辑：行键（[rowChangeKeyFor]）→ 列名 → 单元格编辑。
  ///
  /// 第 59 轮：翻页 / 排序 / 筛选 / 改每页条数不再丢弃这些编辑 —— DataGrid 按
  /// 行键把当前页的编辑恢复出来，保存时把所有页合并成一条 applyRowChanges
  /// 事务。切页签 / 切表仍然要确认（跨表暂存不安全），刷新也保留确认。
  final Map<String, Map<String, DirtyCell>> _stagedEditsByKey =
      <String, Map<String, DirtyCell>>{};

  /// 是否启用第 59 轮的行键跨页保持。
  ///
  /// 第 60 轮：**无主键表禁用**。无主键表的行键是整行旧值，外部并发改动后
  /// applyRowChanges 可能命中 0 行；这类表退回第 57 轮行为（翻页/排序/筛选
  /// 先确认，暂存只保留当前页）。有主键表保持跨页保持。
  bool get _crossPageRetentionEnabled => _primaryKey.isNotEmpty;

  /// 所有页加起来的暂存编辑数（表格工具栏 /「未保存 N 处」用）。
  int get _stagedEditCount => _stagedEditsByKey.values.fold<int>(
        0,
        (sum, row) => sum + row.length,
      );

  /// 当前完整的跨页暂存 map，交给 DataGrid 按行键恢复当前页的着色与计数。
  Map<String, List<DirtyCell>> get _initialDirtyByKey => <String, List<DirtyCell>>{
        for (final entry in _stagedEditsByKey.entries)
          if (entry.value.isNotEmpty) entry.key: entry.value.values.toList(),
      };

  /// 把一批带 keys 的编辑并入跨页 map（没有 keys 的旧编辑按当前行推断）。
  void _mergeStagedEdits(Iterable<DirtyCell> edits) {
    for (final edit in edits) {
      var keys = edit.keys;
      if (keys == null) {
        final rows = _rows;
        if (edit.rowIndex < 0 || edit.rowIndex >= rows.length) continue;
        keys = rowChangeKeys(
          columns: _columns,
          row: rows[edit.rowIndex],
          primaryKey: _primaryKey,
        );
      }
      if (keys.isEmpty) continue;
      final key = rowChangeKeyFor(keys);
      (_stagedEditsByKey[key] ??= <String, DirtyCell>{})[edit.column] =
          DirtyCell(
        rowIndex: edit.rowIndex,
        column: edit.column,
        value: edit.value,
        isNull: edit.isNull,
        keys: keys,
      );
    }
  }

  /// Keyset cursors, one per loaded page.
  ///
  /// Index 0 is always `null` (page 1 starts at the table head); index `i` holds
  /// the `next_cursor` of page `i`. Deep pages therefore become
  /// `WHERE pk > cursor` range scans instead of `OFFSET n`, which the server
  /// reports through `used_keyset`.
  final List<Object?> _cursors = <Object?>[null];

  /// Cursor for the page after the one currently displayed (null when the
  /// server could not use a keyset scan, or when the last page is reached).
  Object? _nextCursor;

  /// Last total the server reported.
  ///
  /// Cursor pages are fetched with `count: false` (a full COUNT(*) on a wide
  /// table often costs more than the page itself), so those responses carry
  /// `total: null`. Keeping the number from the last counted page stops the
  /// header's row-count pill from flickering away as soon as the user turns a
  /// page.
  int? _knownTotal;

  String? _ddl;
  String _sqlText = '';
  /// One controller for the SQL tab. Building a fresh TextEditingController on
  /// every build (as this used to) resets the caret to the start on each
  /// keystroke-driven rebuild.
  final SqlHighlightingController _sqlController = SqlHighlightingController();
  List<Json> _sqlResults = <Json>[];
  String? _error;
  String? _sqlError;
  bool _sqlRunning = false;
  bool _loading = true;
  /// SQL-file import runs as a Rust job; this polls its progress.
  bool _importing = false;
  String? _importPath;
  Json? _importFileInfo;
  Json? _importJobStatus;
  Json? _importResult;
  ImportJobPoller? _importPoller;
  String _exportFormat = 'sql';
  bool _exportStructure = true;
  bool _exportData = true;
  bool _exportDrop = false;
  String? _exportPreview;
  /// True while a streamed file export is running (large tables take a while).
  bool _exporting = false;
  List<Json> _builderTables = <Json>[];
  final List<Json> _insertValues = <Json>[];
  final List<bool> _insertNulls = <bool>[];
  /// One controller per insert row, keyed by column name.
  ///
  /// The insert form used to build a fresh, *uncontrolled* TextField on every
  /// rebuild. Clearing the pending values after a successful insert therefore
  /// left the old text on screen (a TextField keeps its own internal state), and
  /// the next "插入" submitted the now-empty values instead — which is why a
  /// second insert without retyping failed with a missing-field error.
  final Map<String, TextEditingController> _insertControllers =
      <String, TextEditingController>{};

  // Design tab state
  final List<Json> _designColumns = <Json>[];
  final List<Json> _designNewIndexes = <Json>[];
  final List<Json> _designNewFks = <Json>[];
  final Set<String> _designDropIndexes = <String>{};
  final Set<String> _designDropFks = <String>{};
  String? _designSql;
  List<Json> _designResults = <Json>[];
  String? _designError;
  final _renameTo = TextEditingController();
  final _tableComment = TextEditingController();

  /// 设计的「文本修改版本号」：字段名/类型/默认值/注释、表名、表注释这些
  /// TextField 的 onChanged 不重建整页（否则光标会跳），所以每次文本变化 +1，
  /// 依赖它的按钮/单元格（撤销全部、逐列还原、表名/注释重置）重新计算可用态，
  /// 而输入框本身保持原状、不丢光标。
  final ValueNotifier<int> _designRevision = ValueNotifier<int>(0);

  /// 设计器字段行的数据库基线（按原列名索引，来自 structure）；逐列还原用。
  Map<String, Json> _designColumnBaseline = <String, Json>{};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _sqlText = _defaultTableSql();
    _sqlController.text = _sqlText;
    _reloadAll();
  }

  @override
  void dispose() {
    _importPoller?.dispose();
    _tabController.dispose();
    _where.dispose();
    _renameTo.dispose();
    _sqlController.dispose();
    for (final controller in _insertControllers.values) {
      controller.dispose();
    }
    _tableComment.dispose();
    _designRevision.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TableView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.db != widget.db || oldWidget.table != widget.table) {
      _sqlText = _defaultTableSql();
      _sqlController.text = _sqlText;
      // 第 57 轮：切表前上一张表可能还有未保存的批量编辑。didUpdateWidget 在
      // build 期间，不能直接弹框/setState，所以 postFrame 里先问「放弃 / 保存到
      // 原表」再 reload 新表。限制：如果父组件给 TableView 加了 key（导致 State
      // 被销毁）就没有机会提示，只能寄望于翻页/页签守卫。
      if (_stagedEditCount > 0) {
        final edits = <DirtyCell>[
          for (final row in _stagedEditsByKey.values) ...row.values,
        ];
        final oldDb = oldWidget.db;
        final oldTable = oldWidget.table;
        // 此刻 _data 还是原表的数据，把原表的列/主键快照带进 postFrame；
        // 行键已在编辑暂存时捕获，跨页保存不再需要旧 rows。
        final oldColumns = _columns;
        final oldPrimaryKey = _primaryKey;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _handleTableSwitchWithDirty(
            oldDb,
            oldTable,
            oldColumns,
            oldPrimaryKey,
            edits,
          );
        });
      } else {
        _reloadAll();
      }
    }
  }

  /// 切表时处理上一张表未保存的批量编辑：先问「放弃 / 保存到原表」，再 reload。
  Future<void> _handleTableSwitchWithDirty(
    String oldDb,
    String oldTable,
    List<Json> oldColumns,
    List<String> oldPrimaryKey,
    List<DirtyCell> edits,
  ) async {
    final choice = await _showTableSwitchDirtyDialog(
      oldTable,
      widget.table,
      edits.length,
    );
    if (!mounted) return;
    var saveFailed = false;
    if (choice == 2) {
      final outcome = await _saveBatchEdits(
        oldDb,
        oldTable,
        oldColumns,
        oldPrimaryKey,
        edits,
      );
      if (!mounted) return;
      if (outcome != null) {
        widget.notice.show(
          pickText(
            '已保存 ${outcome.rowsAffected} 行到原表 $oldTable${outcome.zeroRowSuffix}',
            'Saved ${outcome.rowsAffected} row(s) to the previous table '
                '$oldTable${outcome.zeroRowSuffix}',
          ),
        );
      } else {
        // 原表保存失败：_reloadAll 会清掉错误横幅，所以切完新表后再提示一次，
        // 免得用户以为修改已经保存。限制：失败后的编辑无法在这里重试。
        saveFailed = true;
      }
    }
    _stagedEditsByKey.clear();
    await _reloadAll();
    if (saveFailed && mounted) {
      widget.notice.show(
        pickText(
          '保存到原表 $oldTable 失败，上一张表未保存的修改已丢弃。',
          'Saving to the previous table $oldTable failed; its unsaved changes '
              'were discarded.',
        ),
      );
    }
  }

  /// 切表时的两选一确认（没有「取消」：父组件已经切到新表，停留在旧数据上会
  /// 让后续操作把旧行写到新表里）。
  Future<int?> _showTableSwitchDirtyDialog(
    String oldTable,
    String newTable,
    int count,
  ) {
    return showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => Dialog(
        alignment: Alignment.topCenter,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 48),
        backgroundColor: AppColors.panel,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppMetrics.radiusModal),
          side: BorderSide(color: AppColors.border),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pickText(
                    '上一张表有未保存的修改',
                    'The previous table has unsaved changes',
                  ),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  pickText(
                    '正在切换到表 $newTable。上一张表 $oldTable 还有 $count 处'
                        '批量编辑没保存：可以先保存到原表，也可以放弃后继续。',
                    'Switching to table $newTable. The previous table $oldTable '
                        'still has $count unsaved batch edit(s): save them to the '
                        'old table, or discard them and continue.',
                  ),
                  style: kSmall,
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Btn(
                      pickText('放弃修改并继续', 'Discard changes and continue'),
                      key: const ValueKey<String>('table-switch-discard'),
                      danger: true,
                      onPressed: () => Navigator.of(dialogContext).pop(1),
                    ),
                    const SizedBox(width: 8),
                    Btn(
                      pickText(
                        '保存到原表并继续',
                        'Save to the previous table and continue',
                      ),
                      key: const ValueKey<String>('table-switch-save'),
                      primary: true,
                      onPressed: () => Navigator.of(dialogContext).pop(2),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Reset per-table state and reload data + structure, like the web reloadAll.
  Future<void> _reloadAll() async {
    setState(() {
      _tab = 'browse';
      _tabController.index = 0;
      _sorts = <SortSpec>[];
      _where.text = '';
      _page = 1;
      _ddl = null;
      _sqlResults = <Json>[];
      _error = null;
      _sqlError = null;
      _importPath = null;
      _importFileInfo = null;
      _importJobStatus = null;
      _importResult = null;
      _importPoller?.dispose();
      _importPoller = null;
      _importing = false;
      _exportPreview = null;
      _designColumns.clear();
      _designNewIndexes.clear();
      _designNewFks.clear();
      _designDropIndexes.clear();
      _designDropFks.clear();
      _designColumnBaseline = <String, Json>{};
      _designRevision.value = 0;
      _designSql = null;
      _designResults = <Json>[];
      _designError = null;
      // Another table's total must not be shown while this one loads: the
      // header pill reads _data / _knownTotal, and both used to survive the
      // switch (round34 P2-01).
      _data = <String, dynamic>{};
      _knownTotal = null;
      _loading = true;
    });
    await Future.wait([_loadData(refreshCount: true), _loadStructure()]);
  }

  /// Reload the current page.
  ///
  /// [refreshCount] forces a fresh COUNT(*) even when the page was reached
  /// through a cursor (see [shouldCountTableRows]). Writes pass it because they
  /// change the row count the header's pill is drawn from.
  Future<void> _loadData({bool refreshCount = false}) async {
    try {
      // Every caller that changes the result set (sort, filter, per-page,
      // refresh) sets _page back to 1. Starting at the head invalidates any
      // cursors collected for the previous ordering, so the chain restarts here
      // instead of sending a cursor that belongs to a different WHERE/ORDER BY.
      if (_page <= 1) {
        _cursors
          ..clear()
          ..add(null);
        _nextCursor = null;
      }
      final sortText = _sorts.map((s) => '${s.column}:${s.dir}').join(',');
      // Only send a cursor for a page we actually reached through one; after a
      // sort/filter change the stack is reset, so this is always in range.
      final cursor = _page > 0 && _page <= _cursors.length ? _cursors[_page - 1] : null;
      final res = await Api.instance.data(widget.db, widget.table, {
        'page': _page,
        'per_page': _perPage,
        'sort': sortText.isEmpty ? null : sortText,
        'where': _where.text.trim().isEmpty ? null : _where.text.trim(),
        'after': ?cursor,
        // Counting a large table is often more expensive than fetching a page,
        // so a cursor page normally skips it (the header and pager then reuse
        // the total learned on page 1). A write or an explicit refresh asks for
        // a fresh count even on a cursor page, so the header's row-count pill
        // cannot stay on a stale number after an insert / delete (round34
        // P2-01) — that is one extra COUNT per user action, never per page.
        'count':
            shouldCountTableRows(cursor: cursor, refreshCount: refreshCount),
      });
      if (!mounted) return;
      setState(() {
        _data = res;
        _loading = false;
        final counted = (res['total'] as num?)?.toInt();
        if (counted != null) _knownTotal = counted;
        final usedKeyset = res['used_keyset'] == true;
        if (!usedKeyset) {
          // The server fell back to OFFSET (composite/no primary key, or a
          // sort the index cannot serve): drop the cursor chain so paging stays
          // consistent with the rows that were actually returned.
          _cursors
            ..clear()
            ..add(null);
          _nextCursor = null;
        } else {
          _nextCursor = res['next_cursor'];
          if (_cursors.length > _page) {
            _cursors.removeRange(_page, _cursors.length);
          }
          if (_nextCursor != null) {
            if (_cursors.length == _page) {
              _cursors.add(_nextCursor);
            } else {
              _cursors[_page] = _nextCursor;
            }
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Reload the current page after a statement that changes the row count
  /// (insert / delete / truncate / arbitrary SQL / import).
  ///
  /// The reload keeps the current page and its cursor chain but forces the
  /// COUNT(*), so 「行数：N」 shows the new total immediately instead of the
  /// number from whenever the table was last counted (round34 P2-01).
  Future<void> _reloadAfterWrite() => _loadData(refreshCount: true);

  /// DataGrid 的暂存编辑变更回调（第 57/59 轮）。
  ///
  /// DataGrid 上报的是**当前页**的全部暂存编辑（含行键）：先把这一页的行键从
  /// 跨页 map 中移除，再并入上报的编辑。其它页的编辑原样保留。
  void _onDirtyChanges(List<DirtyCell> edits) {
    if (!mounted) return;
    if (!_crossPageRetentionEnabled) {
      // 第 60 轮：无主键表不做跨页保持，DataGrid 上报的就是当前页全部编辑。
      _stagedEditsByKey.clear();
      _mergeStagedEdits(edits);
      setState(() {});
      return;
    }
    final pageKeys = <String>{
      for (final row in _rows)
        rowChangeKey(
          columns: _columns,
          row: row,
          primaryKey: _primaryKey,
        ),
    }..remove('');
    _stagedEditsByKey.removeWhere((key, _) => pageKeys.contains(key));
    _mergeStagedEdits(edits);
    // DataGrid 只在事件处理或 postFrame 里回调，这里 setState 是安全的。
    setState(() {});
  }

  /// 离开当前页 / 当前批次前的未保存批量编辑确认。
  ///
  /// 返回 true 表示可以继续（没有编辑，或用户选择放弃 / 保存成功）；false 表示
  /// 用户取消或保存失败，调用方必须停留。保存走既有 [_applyDirtyEdits]（单事务、
  /// 自带 reload），失败时错误横幅已经显示。
  Future<bool> _confirmLeaveDirty() async {
    final count = _stagedEditCount;
    if (count == 0) return true;
    final choice = await showAppModal<int>(
      context: context,
      title: pickText('有未保存的修改', 'Unsaved changes'),
      builder: (context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              pickText(
                '有 $count 处批量编辑还没保存（可能分布在多页）。继续操作会丢弃'
                    '这些修改；也可以先保存再继续。',
                'There are $count unsaved batch edit(s), possibly across several '
                    'pages. Continuing discards them; you can also save first and '
                    'then continue.',
              ),
              style: kSmall,
            ),
            const SizedBox(height: 10),
            AlertBox(
              pickText(
                '选择「放弃修改并继续」会丢弃这些编辑，且无法撤销。',
                '"Discard changes and continue" drops these edits without undo.',
              ),
              tone: AlertTone.warn,
            ),
          ],
        ),
      ),
      actions: <Widget>[
        Builder(
          builder: (context) => Btn(
            pickText('取消', 'Cancel'),
            key: const ValueKey<String>('batch-leave-cancel'),
            onPressed: () => Navigator.of(context).pop(0),
          ),
        ),
        Builder(
          builder: (context) => Btn(
            pickText('放弃修改并继续', 'Discard changes and continue'),
            key: const ValueKey<String>('batch-leave-discard'),
            danger: true,
            onPressed: () => Navigator.of(context).pop(1),
          ),
        ),
        Builder(
          builder: (context) => Btn(
            pickText('保存后继续', 'Save and continue'),
            key: const ValueKey<String>('batch-leave-save'),
            primary: true,
            onPressed: () => Navigator.of(context).pop(2),
          ),
        ),
      ],
    );
    if (!mounted) return false;
    switch (choice) {
      case 1:
        // 放弃：清掉所有页的暂存记录。DataGrid 的内部暂存会在随后的 reload /
        // 切页签卸载时被替换或丢弃。
        _stagedEditsByKey.clear();
        setState(() {});
        return true;
      case 2:
        final saved = await _applyDirtyEdits(const <DirtyCell>[]);
        if (!mounted) return false;
        if (!saved) return false; // 保存失败：留在当前页，错误横幅已显示
        _stagedEditsByKey.clear();
        return true;
      default:
        return false;
    }
  }

  // ---- 第 59/60 轮：翻页/排序/筛选只换数据、不丢暂存编辑（按行键跨页保留） ----
  // 有主键表直接放行；无主键表退回第 57 轮离开确认。切页签 / 切表 / 刷新
  // 无论是否有主键都仍然确认。

  /// 换页/排序/筛选等会换掉当前页数据的入口。
  ///
  /// 有主键 → 第 59 轮跨页保持，直接放行；无主键 → 第 57 轮确认（行键是整行
  /// 旧值，跨页保存可能命中 0 行，不做跨页保持）。
  Future<bool> _allowPageReload() async {
    if (_crossPageRetentionEnabled) return true;
    return _confirmLeaveDirty();
  }

  Future<void> _goToPage(int target) async {
    if (!await _allowPageReload()) return;
    if (!mounted) return;
    setState(() => _page = target);
    await _loadData();
  }

  Future<void> _refreshData() async {
    // 刷新会重新拉当前页数据；暂存编辑按行键还在，但外部可能已经删/改了行，
    // 所以仍保留第 57 轮的确认。
    if (!await _confirmLeaveDirty()) return;
    if (!mounted) return;
    await _loadData(refreshCount: true);
  }

  Future<void> _applyWhere() async {
    if (!await _allowPageReload()) return;
    if (!mounted) return;
    setState(() => _page = 1);
    await _loadData();
  }

  Future<void> _clearWhere() async {
    if (_where.text.isEmpty) return;
    if (!await _allowPageReload()) return;
    if (!mounted) return;
    _where.text = '';
    setState(() => _page = 1);
    await _loadData();
  }

  Future<void> _loadStructure() async {
    try {
      final res = await Api.instance.structure(widget.db, widget.table);
      final schema = await Api.instance.builderSchema(widget.db);
      if (!mounted) return;
      setState(() {
        _structure = res;
        final tables = schema['tables'];
        _builderTables = tables is List
            ? tables.map((e) => Map<String, dynamic>.from(e as Map)).toList()
            : <Json>[];
        _seedInsertValues();
        _seedDesigner();
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = describeDbError(e));
      }
    }
  }

  List<Json> get _columns {
    final value = _data['columns'];
    if (value is! List) return <Json>[];
    return value.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  List<List<dynamic>> get _rows {
    final value = _data['rows'];
    if (value is! List) return <List<dynamic>>[];
    return value.map((row) => row is List ? row : <dynamic>[]).toList();
  }

  List<String> get _primaryKey {
    final value = _data['primary_key'];
    if (value is! List) return <String>[];
    return value.map((e) => e.toString()).toList();
  }

  List<Json> get _structureColumns {
    final value = _structure['columns'];
    if (value is! List) return <Json>[];
    return value.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  bool get _isView =>
      (_structure['info'] is Map) &&
      ((_structure['info'] as Map)['TABLE_TYPE'] ?? '').toString() == 'VIEW';

  void _seedInsertValues() {
    _insertValues.clear();
    _insertNulls.clear();
    for (final column in _structureColumns) {
      final name = (column['name'] ?? '').toString();
      _insertValues.add(<String, dynamic>{'value': '', 'isNull': false});
      _insertNulls.add(false);
      _insertControllers.putIfAbsent(name, () => TextEditingController());
    }
    // Drop controllers for columns that no longer exist, then clear the rest so
    // the visible inputs match the freshly cleared values.
    _insertControllers.removeWhere(
        (name, _) => !_structureColumns.any((c) => c['name'] == name));
    for (final controller in _insertControllers.values) {
      controller.clear();
    }
  }

  /// Copy the current columns into the designer snapshot.
  void _seedDesigner() {
    // 逐列还原的基线：与设计器快照同时刷新。
    _designColumnBaseline = tableDesignColumnBaseline(_structure);
    _designColumns.clear();
    for (final column in _structureColumns) {
      _designColumns.add(<String, dynamic>{
        'name': (column['name'] ?? '').toString(),
        'type': (column['type_name'] ?? '').toString(),
        'nullable': column['IS_NULLABLE'] == 'YES',
        'default': column['COLUMN_DEFAULT']?.toString() ?? '',
        'auto_increment':
            (column['EXTRA'] ?? '').toString().contains('auto_increment'),
        'comment': (column['COLUMN_COMMENT'] ?? '').toString(),
        'charset': (column['CHARACTER_SET_NAME'] ?? '').toString(),
        'collation': (column['COLLATION_NAME'] ?? '').toString(),
        'isNew': false,
        'original': (column['name'] ?? '').toString(),
      });
    }
    // 重新播种 = 回到数据库里的基线：清掉「用户动过设计器」的标记。
    _designRevision.value = 0;
    final info = _structure['info'];
    if (info is Map) {
      _renameTo.clear();
      _tableComment.text = (info['TABLE_COMMENT'] ?? '').toString();
    } else {
      // 驱动没有 info（或结构尚未加载）时也要清空，避免上一张表的输入残留。
      _renameTo.clear();
      _tableComment.clear();
    }
  }

  Future<void> _onSort(String column, bool additive) async {
    // 第 59/60 轮：有主键表排序不丢编辑；无主键表先离开确认。
    if (!await _allowPageReload()) return;
    if (!mounted) return;
    setState(() {
      final existing = _sorts.indexWhere((s) => s.column == column);
      if (existing >= 0) {
        final current = _sorts[existing];
        if (additive) {
          _sorts[existing] = current.toggled();
        } else {
          _sorts = [current.toggled()];
        }
      } else if (additive) {
        _sorts = [..._sorts, SortSpec(column, 'asc')];
      } else {
        _sorts = [SortSpec(column, 'asc')];
      }
      _page = 1;
    });
    await _loadData();
  }

  /// Build a WHERE clause from the DataGrid filter row, quoting identifiers
  /// for the active driver exactly like the web filtersToWhere().
  Future<void> _onFilters(List<GridFilter> filters) async {
    // 第 59/60 轮：筛选同排序——有主键表保留编辑，无主键表先确认。
    if (!await _allowPageReload()) return;
    if (!mounted) return;
    final q = AppState.instance.quoteIdent;
    final conditions = <String>[];
    for (var i = 0; i < _columns.length && i < filters.length; i++) {
      final filter = filters[i];
      if (!filter.active) continue;
      final column = q(_columns[i]['name'].toString());
      if (filter.op == 'IS NULL' || filter.op == 'IS NOT NULL') {
        conditions.add('$column ${filter.op}');
        continue;
      }
      final raw = filter.value.trim();
      if (raw.isEmpty) continue;
      final numeric = num.tryParse(raw) != null;
      final literal = (numeric || raw.startsWith('('))
          ? raw
          : "'${raw.replaceAll("'", "''")}'";
      if (filter.op == 'LIKE' || filter.op == 'NOT LIKE') {
        final escaped = raw.replaceAll("'", "''");
        conditions.add("$column ${filter.op} '%$escaped%'");
      } else if (filter.op == 'IN') {
        final values = raw.startsWith('(') ? raw : '($raw)';
        conditions.add('$column IN $values');
      } else {
        conditions.add('$column ${filter.op} $literal');
      }
    }
    setState(() {
      _where.text = conditions.join(' AND ');
      _page = 1;
    });
    await _loadData();
  }

  @override
  Widget build(BuildContext context) {
    return PageScroll(
      padding: const EdgeInsets.all(AppMetrics.mainPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(),
          if (_error != null)
            AlertBox(_error!, tone: AlertTone.error),
          if (_sqlError != null) AlertBox(_sqlError!),
          NoticeBanner(widget.notice),
          _tabBar(),
          const SizedBox(height: 12),
          _tabBody(),
        ],
      ),
    );
  }

  Widget _header() {
    final total = (_data['total'] as num?)?.toInt() ?? _knownTotal;
    return PageHead(
      titleWidget: Row(
        children: [
          InkWell(
            onTap: () => Navigation.instance.go(AppRoute.database(widget.db)),
            child: Text(widget.db, style: monoStyle(size: 14, color: AppColors.link)),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 6),
            child: Text('/', style: kMuted),
          ),
          Text(widget.table, style: monoStyle(size: 18, weight: FontWeight.w600)),
        ],
      ),
      actions: [
        if (total != null) Pill(I18n.current == AppLang.en ? 'Rows: $total' : '行数：$total'),
        const SizedBox(width: 8),
        Btn(t('back'),
            onPressed: () => Navigation.instance.go(AppRoute.database(widget.db))),
      ],
    );
  }

  Widget _tabBar() {
    final labels = <String, String>{
      'browse': t('tab_browse'),
      'structure': t('tab_structure'),
      'design': (I18n.current == AppLang.en ? 'Design' : '设计'),
      'ddl': 'DDL',
      'insert': t('tab_insert'),
      'sql': 'SQL',
      'export': t('tab_export'),
      'import': t('tab_import'),
      'operations': t('actions'),
    };
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Wrap(
        spacing: 2,
        children: [
          for (final tab in _tabs)
            GestureDetector(
              onTap: () => _switchTab(tab),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
                decoration: BoxDecoration(
                  color: _tab == tab ? AppColors.panel : Colors.transparent,
                  border: Border.all(
                      color: _tab == tab
                          ? AppColors.border
                          : Colors.transparent),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(5),
                    topRight: Radius.circular(5),
                  ),
                ),
                child: Text(
                  labels[tab] ?? tab,
                  style: TextStyle(
                    fontSize: 13,
                    color: _tab == tab ? AppColors.bodyText : AppColors.muted,
                    fontWeight:
                        _tab == tab ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _switchTab(String tab) async {
    if (tab == _tab) return;
    // 切页签会卸载 DataGrid：暂存的批量编辑会丢，先确认。
    if (!await _confirmLeaveDirty()) return;
    if (!mounted) return;
    setState(() => _tab = tab);
    if (tab == 'ddl' && _ddl == null) _loadDdl();
  }

  Widget _tabBody() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    switch (_tab) {
      case 'browse':
        return _browseTab();
      case 'structure':
        return _structureTab();
      case 'design':
        return _designTab();
      case 'ddl':
        return _ddlTab();
      case 'insert':
        return _insertTab();
      case 'sql':
        return _sqlTab();
      case 'export':
        return _exportTab();
      case 'import':
        return _importTab();
      case 'operations':
        return _operationsTab();
    }
    return const SizedBox.shrink();
  }

  // ------------------------------------------------------------------ browse

  Widget _browseTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CardBox(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text((I18n.current == AppLang.en ? 'Apply WHERE' : '应用 WHERE'), style: kSmall),
                  SizedBox(
                    width: 320,
                    child: TextField(
                      controller: _where,
                      style: monoStyle(size: 12),
                      onSubmitted: (_) => _applyWhere(),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: I18n.current == AppLang.en ? 'Optional WHERE condition' : '可选 WHERE 条件',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  Btn(t('filter'), primary: true, onPressed: _applyWhere),
                  if (_where.text.isNotEmpty)
                    Btn(t('clear'), onPressed: _clearWhere),
                  const Sep(),
                  Text((I18n.current == AppLang.en ? 'Per page' : '每页'), style: kSmall),
                  SelectBox<int>(
                    width: 90,
                    value: _perPage,
                    onChanged: (v) async {
                      final next = v ?? 25;
                      if (next == _perPage) return;
                      if (!await _allowPageReload()) return;
                      if (!mounted) return;
                      setState(() {
                        _perPage = next;
                        _page = 1;
                      });
                      await _loadData();
                    },
                    items: const [
                      DropdownMenuItem(value: 10, child: Text('10')),
                      DropdownMenuItem(value: 25, child: Text('25')),
                      DropdownMenuItem(value: 50, child: Text('50')),
                      DropdownMenuItem(value: 100, child: Text('100')),
                      DropdownMenuItem(value: 250, child: Text('250')),
                    ],
                  ),
                  // 第 57 轮：刷新会丢掉未保存的批量编辑，先确认。
                  // An explicit refresh must re-count even on a cursor page,
                  // otherwise the pill keeps the pre-refresh number and only
                  // walking back to page 1 updates it.
                  Btn(t('refresh'), onPressed: _refreshData),
                  if (_stagedEditCount > 0)
                    Pill(
                      pickText(
                        '未保存 $_stagedEditCount 处',
                        '$_stagedEditCount unsaved edit(s)',
                      ),
                      tone: PillTone.warn,
                    ),
                ],
              ),
              if (_primaryKey.isEmpty) ...[
                const SizedBox(height: 8),
                const AlertBox(
                  '该表没有主键，行编辑将按整行匹配，可能影响多行。',
                  tone: AlertTone.info,
                ),
              ],
            ],
          ),
        ),
        DataGrid(
          columns: _columns,
          rows: _rows,
          sorts: _sorts,
          primaryKey: _primaryKey,
          rowOps: true,
          editable: true,
          maxHeight: 460,
          onSort: _onSort,
          onFilters: _onFilters,
          onEdit: _showRowEditor,
          onDelete: _deleteRow,
          onDeleteSelected: _deleteRows,
          onSaveCell: _saveCell,
          onApplyEdits: _applyDirtyEdits,
          onDirtyChanges: _onDirtyChanges,
          // 第 60 轮：无主键表不做跨页保持（退回第 57 轮单页行为）。
          initialDirtyByKey:
              _crossPageRetentionEnabled ? _initialDirtyByKey : null,
          totalDirtyCount:
              _crossPageRetentionEnabled ? _stagedEditCount : null,
          maxDirtyCells: kMaxStagedCells,
        ),
        const SizedBox(height: 8),
        _pager(),
      ],
    );
  }

  Widget _pager() {
    final page = (_data['page'] as num?)?.toInt() ?? 1;
    final pages = (_data['pages'] as num?)?.toInt();
    final total = (_data['total'] as num?)?.toInt() ?? _knownTotal;
    final rows = _rows.length;
    // With a keyset scan the server no longer needs COUNT(*), so `pages` and
    // `total` can be absent (null). The pager then falls back to "there is a
    // next page while the server handed back a cursor", and reports the rows
    // seen so far instead of a total it does not have.
    final hasNext = _nextCursor != null || (pages != null && page < pages);
    final canPrev = page > 1;
    final pageLabel = pages == null ? '第 $page 页' : '第 $page / $pages 页';
    final countLabel =
        total == null ? '本页 $rows 行' : '显示 $rows / $total 行';
    return Row(
      children: [
        IconBtn(Icons.chevron_left,
            key: const ValueKey('pager-prev'),
            tooltip: '上一页',
            small: true,
            onPressed: canPrev ? () => _goToPage(page - 1) : null),
        const SizedBox(width: 8),
        Text(pageLabel, style: kSmall),
        const SizedBox(width: 8),
        IconBtn(Icons.chevron_right,
            key: const ValueKey('pager-next'),
            tooltip: '下一页',
            small: true,
            onPressed: hasNext ? () => _goToPage(page + 1) : null),
        const Spacer(),
        Text(countLabel, style: kSmallMuted),
      ],
    );
  }

  /// Row keys: primary key columns when present, otherwise every column.
  Map<String, dynamic> _rowKeys(int index) {
    final row = _rows[index];
    final keys = <String, dynamic>{};
    final target = _primaryKey.isEmpty
        ? _columns.map((c) => c['name'].toString()).toList()
        : _primaryKey;
    for (var i = 0; i < _columns.length; i++) {
      final name = _columns[i]['name'].toString();
      if (!target.contains(name)) continue;
      keys[name] = i < row.length ? row[i] : null;
    }
    return keys;
  }

  /// 把一批带行键的单元格编辑写到显式的 db/table（切表保存到原表也复用它）。
  ///
  /// 第 59 轮改用 [buildRowChangesFromKeys]：编辑可能来自多个页，行键在暂存时
  /// 已捕获，不再依赖当前页的 rows。第 60 轮额外读取 `zero_row_results`（键
  /// 命中 0 行的改动），失败返回 null，并在页面错误横幅里显示原因。
  Future<BatchApplyOutcome?> _saveBatchEdits(
    String db,
    String table,
    List<Json> columns,
    List<String> primaryKey,
    List<DirtyCell> edits,
  ) async {
    final changes = buildRowChangesFromKeys(
      columns: columns,
      primaryKey: primaryKey,
      edits: edits,
    );
    try {
      final result = await Api.instance.applyRowChanges(db, table, changes);
      // 第 63 轮：优先读汇总 zero_row_reasons；没有时退回逐条 reason；再没有
      // （旧后端）就只按条数，提示沿用旧文案。
      final zeroItems = result['zero_row_results'];
      final reasons = result['zero_row_reasons'];
      var notFound = 0;
      var unchanged = 0;
      var unknown = 0;
      if (reasons is Map) {
        notFound = (reasons['not_found'] as num?)?.toInt() ?? 0;
        unchanged = (reasons['unchanged'] as num?)?.toInt() ?? 0;
        unknown = (reasons['unknown'] as num?)?.toInt() ?? 0;
      } else if (zeroItems is List) {
        for (final item in zeroItems) {
          final reason = item is Map ? item['reason']?.toString() : null;
          switch (reason) {
            case 'not_found':
              notFound++;
            case 'unchanged':
              unchanged++;
            default:
              unknown++;
          }
        }
      }
      final zeroRows = reasons is Map
          ? notFound + unchanged + unknown
          : (zeroItems is List ? zeroItems.length : 0);
      return BatchApplyOutcome(
        rowsAffected: (result['rows_affected'] as num?)?.toInt() ?? 0,
        zeroRows: zeroRows,
        notFound: notFound,
        unchanged: unchanged,
        unknown: unknown,
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
      return null;
    }
  }

  /// Save every staged edit of every page in **one transaction**.
  ///
  /// Unlike [_saveCell] (one immediate UPDATE per cell), the grid stages edits
  /// and the Rust side validates all of them before opening the transaction and
  /// rolls the whole batch back on the first error. [edits] is the current
  /// page's list from DataGrid (used to refresh the cross-page map); the
  /// authoritative batch is [_stagedEditsByKey], so edits staged on other pages
  /// are included too.
  Future<bool> _applyDirtyEdits(List<DirtyCell> edits) async {
    _mergeStagedEdits(edits);
    final all = <DirtyCell>[
      for (final row in _stagedEditsByKey.values) ...row.values,
    ];
    if (all.isEmpty) return true;
    final outcome = await _saveBatchEdits(
      widget.db,
      widget.table,
      _columns,
      _primaryKey,
      all,
    );
    if (outcome == null) return false;
    widget.notice.show(outcome.message);
    _stagedEditsByKey.clear();
    await _reloadAfterWrite();
    return true;
  }

  Future<void> _saveCell(
      int rowIndex, String column, Object? value, bool isNull) async {
    try {
      await Api.instance.changeRow(widget.db, widget.table, {
        'action': 'update',
        'keys': _rowKeys(rowIndex),
        'values': {column: isNull ? null : value},
        'limit_one': _primaryKey.isEmpty,
      });
      widget.notice.show('单元格已保存');
      await _loadData();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _deleteRow(int index) async {
    // 第 58 轮：删除会 reload 当前页，先处理未保存的批量编辑（取消则什么都不做）。
    // 行键必须在确认之前按当前 rows 计算：守卫里选「保存后继续」会 reload，
    // 行索引可能不再指向同一行。
    final keys = _rowKeys(index);
    if (!await _confirmLeaveDirty()) return;
    if (!mounted) return;
    final ok = await confirmDialog(context,
        message: '确定删除该行吗？', confirmLabel: t('delete'), danger: true);
    if (!ok) return;
    try {
      await Api.instance.changeRow(widget.db, widget.table, {
        'action': 'delete',
        'keys': keys,
        'limit_one': _primaryKey.isEmpty,
      });
      widget.notice.show('行已删除');
      await _reloadAfterWrite();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _deleteRows(List<int> indices) async {
    // 第 58 轮：同 _deleteRow，删除前先处理未保存的批量编辑。行键先算好，
    // 守卫里的保存会 reload rows。
    final keyList = <Map<String, dynamic>>[
      for (final index in indices) _rowKeys(index),
    ];
    if (!await _confirmLeaveDirty()) return;
    if (!mounted) return;
    final ok = await confirmDialog(context,
        message: '确定删除选中的 ${indices.length} 行吗？',
        confirmLabel: t('delete'),
        danger: true);
    if (!ok) return;
    var deleted = 0;
    for (final keys in keyList) {
      try {
        await Api.instance.changeRow(widget.db, widget.table, {
          'action': 'delete',
          'keys': keys,
          'limit_one': _primaryKey.isEmpty,
        });
        deleted++;
      } catch (e) {
        if (mounted) setState(() => _error = e.toString());
        break;
      }
    }
    if (deleted > 0) {
      widget.notice.show('已删除 $deleted 行');
      await _reloadAfterWrite();
    }
  }

  /// Row editor modal: one control per column, skipping primary-key columns on
  /// update because those identify the row.
  Future<void> _showRowEditor(int index) async {
    if (index < 0 || index >= _rows.length) return;
    // 第 58 轮：行键在打开时算好——保存前的未保存确认里选「保存后继续」会
    // reload rows，行索引可能不再指向同一行。
    final keys = _rowKeys(index);
    final row = _rows[index];
    final controllers = <String, TextEditingController>{};
    final nulls = <String, bool>{};
    for (var i = 0; i < _columns.length; i++) {
      final name = _columns[i]['name'].toString();
      final value = i < row.length ? row[i] : null;
      controllers[name] = TextEditingController(text: displayCell(value));
      nulls[name] = value == null;
    }
    await showAppModal(
      context: context,
      title: '编辑行',
      builder: (context) => StatefulBuilder(
        builder: (context, setModal) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < _columns.length; i++)
              _editorRow(_columns[i], controllers, nulls, setModal),
          ],
        ),
      ),
      actions: [
        Builder(
          builder: (context) => Btn(t('cancel'),
              onPressed: () => Navigator.of(context).pop()),
        ),
        Builder(
          builder: (context) => Btn(t('save_changes'),
              primary: true,
              onPressed: () async {
                // 第 58 轮：行编辑器保存后会 reload 当前页，先处理未保存的
                // 批量编辑；取消则停留在编辑器里，不写数据库。
                if (!await _confirmLeaveDirty()) return;
                if (!mounted) return;
                final values = <String, dynamic>{};
                for (final column in _columns) {
                  final name = column['name'].toString();
                  if (_primaryKey.contains(name)) continue;
                  values[name] = nulls[name] == true
                      ? null
                      : _coerce(column, controllers[name]!.text);
                }
                try {
                  await Api.instance.changeRow(widget.db, widget.table, {
                    'action': 'update',
                    'keys': keys,
                    'values': values,
                    'limit_one': _primaryKey.isEmpty,
                  });
                  if (context.mounted) Navigator.of(context).pop();
                  widget.notice.show('行已更新');
                  await _loadData();
                } catch (e) {
                  if (mounted) setState(() => _error = e.toString());
                }
              }),
        ),
      ],
    );
  }

  Widget _editorRow(Json column, Map<String, TextEditingController> controllers,
      Map<String, bool> nulls, StateSetter setModal) {
    final name = column['name'].toString();
    final type = (column['type_name'] ?? '').toString().toLowerCase();
    final isBoolean = type.startsWith('bool') ||
        type.startsWith('tinyint(1)') ||
        type == 'boolean';
    final isLongText = type.contains('text') || type.contains('json');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 160,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: monoStyle(size: 12, weight: FontWeight.w600)),
                Text(column['type_name']?.toString() ?? '',
                    style: monoStyle(size: 11, color: AppColors.typeText)),
              ],
            ),
          ),
          Expanded(
            child: isBoolean
                ? SelectBox<String>(
                    value: controllers[name]!.text == 'true' ? 'true' : 'false',
                    enabled: nulls[name] != true,
                    onChanged: (v) => controllers[name]!.text = v ?? 'false',
                    items: const [
                      DropdownMenuItem(value: 'true', child: Text('true')),
                      DropdownMenuItem(value: 'false', child: Text('false')),
                    ],
                  )
                : TextField(
                    controller: controllers[name],
                    enabled: nulls[name] != true,
                    maxLines: isLongText ? 3 : 1,
                    style: monoStyle(size: 12),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
          ),
          const SizedBox(width: 8),
          CheckBox(
            label: 'NULL',
            value: nulls[name] == true,
            onChanged: (v) => setModal(() => nulls[name] = v),
          ),
        ],
      ),
    );
  }

  /// Coerce a text value to the JSON type the backend expects for the column.
  Object? _coerce(Json column, String raw) {
    final type = (column['type_name'] ?? '').toString().toLowerCase();
    final numeric = RegExp(r'int|decimal|numeric|float|double|real|bit|year|serial')
        .hasMatch(type);
    if (raw.isEmpty) return numeric ? null : '';
    if (numeric) return num.tryParse(raw) ?? raw;
    return raw;
  }

  // --------------------------------------------------------------- structure

  /// Human labels for the structure metrics; unknown keys are shown verbatim.
  Map<String, String> get _infoLabels => <String, String>{
    'TABLE_TYPE': '表类型',
    'ENGINE': '引擎',
    'TABLE_ROWS': AppState.instance.isSqlite
        ? (I18n.current == AppLang.en ? 'Rows' : '行数')
        : (I18n.current == AppLang.en ? 'Rows (estimated)' : '行数（估算）'),
    'DATA_LENGTH': '数据大小',
    'INDEX_LENGTH': '索引大小',
    'TABLE_COLLATION': '排序规则',
    'TABLE_COMMENT': t('comment'),
    'CREATE_TIME': '创建时间',
    'UPDATE_TIME': '更新时间',
    'AUTO_INCREMENT': '自增起始值',
    'TABLESPACE': '表空间',
    'UNLOGGED': 'UNLOGGED',
    'TABLE_SQL': '建表语句',
  };

  String _infoLabel(String key) => _infoLabels[key] ?? key;

  Widget _structureTab() {
    final info = _structure['info'];
    final indexes = _structure['indexes'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (info is Map)
          CardBox(
            title: (I18n.current == AppLang.en ? 'Table information' : '表信息'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Only show fields the driver actually filled. PostgreSQL has
                // no ENGINE / TABLE_COLLATION, and SQLite has neither, so the
                // old card was mostly "ENGINE: NULL" rows.
                for (final entry in info.entries)
                  if (entry.value != null &&
                      entry.value.toString().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 200,
                            child: Text(
                                _infoLabel(entry.key.toString()),
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.cardHeading)),
                          ),
                          Expanded(
                            child: SelectableText(
                              entry.value.toString(),
                              style: monoStyle(size: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          ),
        CardBox(
          title: t('columns'),
          child: GridTable(
            headers: [
              Text('#'),
              Text(t('column_name')),
              Text(t('column_type')),
              Text((I18n.current == AppLang.en ? 'Allow NULL' : '允许 NULL')),
              Text(t('default_value')),
              Text((I18n.current == AppLang.en ? 'Key' : '键')),
              Text((I18n.current == AppLang.en ? 'Extra' : '额外')),
              Text(t('comment')),
            ],
            emptyText: (I18n.current == AppLang.en ? '(none)' : '（无）'),
            rows: [
              for (final column in _structureColumns)
                TableRow(
                  children: [
                    gridCell(column['ORDINAL_POSITION']),
                    gridCell(column['name'], mono: true),
                    gridCell(column['type_name'], mono: true),
                    gridCell(column['IS_NULLABLE']),
                    gridCell(column['COLUMN_DEFAULT'] ?? 'NULL'),
                    gridCell(column['COLUMN_KEY']),
                    gridCell(column['EXTRA']),
                    gridCell(column['COLUMN_COMMENT']),
                  ],
                ),
            ],
          ),
        ),
        CardBox(
          title: (I18n.current == AppLang.en ? 'Indexes' : '索引'),
          child: GridTable(
            headers: [
              Text((I18n.current == AppLang.en ? 'Index name' : '索引名')),
              Text((I18n.current == AppLang.en ? 'Unique' : '唯一')),
              Text(t('columns')),
              Text((I18n.current == AppLang.en ? 'Sequence' : '序号')),
              Text((I18n.current == AppLang.en ? 'Cardinality' : '基数')),
              Text(t('column_type')),
            ],
            emptyText: (I18n.current == AppLang.en ? '(none)' : '（无）'),
            rows: [
              if (indexes is List)
                for (final idx in indexes)
                  TableRow(
                    children: [
                      gridCell((idx as Map)['INDEX_NAME'], mono: true),
                      gridCell(idx['NON_UNIQUE'] == 0 ? '是' : '否'),
                      gridCell(idx['COLUMN_NAME'], mono: true),
                      gridCell(idx['SEQ_IN_INDEX']),
                      gridCell(idx['CARDINALITY']),
                      gridCell(idx['INDEX_TYPE']),
                    ],
                  ),
            ],
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------------- ddl

  Future<void> _loadDdl() async {
    try {
      final res = await Api.instance.ddl(widget.db, widget.table);
      if (mounted) setState(() => _ddl = (res['ddl'] ?? '').toString());
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Widget _ddlTab() {
    return CardBox(
      title: 'DDL',
      actions: [Btn(t('refresh'), small: true, onPressed: _loadDdl)],
      child: CodeBlock(_ddl ?? '加载中…'),
    );
  }

  // ----------------------------------------------------------------- design

  Widget _designTab() {
    final features = _features();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CardBox(
          title: (I18n.current == AppLang.en ? 'Table options' : '表选项'),
          actions: [
            // 第 55 轮（ROUND51 P3-7）：设计器没有撤销时的兜底出口。只有真的
            // 有未应用的修改才可点；文本输入类改动通过 _designRevision 触发重算。
            ValueListenableBuilder<int>(
              valueListenable: _designRevision,
              builder: (context, revision, _) {
                // 结构/数据加载中不要点亮：此时 _designColumns 可能还是空的，
                // 算出来的 drop_columns 会是整张表，用户误点会重置成旧快照。
                // revision 只负责在文本输入后触发重算，是否 dirty 仍由载荷判断。
                final dirty =
                    !_loading && !tableDesignBodyEmpty(_buildAlter());
                return Btn(
                  pickText('撤销未应用的修改', 'Discard pending changes'),
                  key: const ValueKey<String>('table-design-reset'),
                  small: true,
                  onPressed: dirty ? _resetDesign : null,
                );
              },
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FormRow(
                label: (I18n.current == AppLang.en ? 'Rename to' : '重命名为'),
                child: Field(label: '', controller: _renameTo,
                  hint: I18n.current == AppLang.en ? 'New table name (leave blank to keep)' : '新表名（留空不改）',
                  onChanged: (_) => _designRevision.value++,
                  trailing: ValueListenableBuilder<int>(
                    valueListenable: _designRevision,
                    builder: (context, revision, _) {
                      // 留空 = 不重命名（与 _buildAlter 的口径一致）；只有真的
                      // 填了一个和当前表名不同的新名字才可重置。
                      final text = _renameTo.text.trim();
                      final dirty = text.isNotEmpty && text != widget.table;
                      return IconBtn(
                        Icons.restore,
                        key: const ValueKey<String>('table-design-reset-name'),
                        tooltip: pickText('恢复表名', 'Reset table name'),
                        onPressed: dirty ? _resetDesignName : null,
                      );
                    },
                  )),
              ),
              FormRow(
                label: t('table_comment'),
                child: Field(label: '', controller: _tableComment,
                  onChanged: (_) => _designRevision.value++,
                  trailing: ValueListenableBuilder<int>(
                    valueListenable: _designRevision,
                    builder: (context, revision, _) {
                      final dirty = _tableComment.text.trim() !=
                          currentTableComment(_structure);
                      return IconBtn(
                        Icons.restore,
                        key: const ValueKey<String>('table-design-reset-comment'),
                        tooltip: pickText('恢复注释', 'Reset comment'),
                        onPressed: dirty ? _resetDesignComment : null,
                      );
                    },
                  )),
              ),
            ],
          ),
        ),
        CardBox(
          title: (I18n.current == AppLang.en ? 'Column design' : '字段设计'),
          actions: [
            Btn(t('add_column'), small: true, onPressed: _addDesignColumn),
          ],
          child: GridTable(
            headers: [
              Text(t('column_name')),
              Text(t('column_type')),
              Text((I18n.current == AppLang.en ? 'Allow NULL' : '允许 NULL')),
              Text(t('default_value')),
              Text(t('auto_increment')),
              Text(t('comment')),
              Text(t('tab_status')),
              Text(t('actions')),
            ],
            emptyText: (I18n.current == AppLang.en ? '(none)' : '（无）'),
            rows: [
              for (var i = 0; i < _designColumns.length; i++)
                _designColumnRow(i),
            ],
          ),
        ),
        if (features['index'] != false)
          CardBox(
            title: (I18n.current == AppLang.en ? 'Indexes' : '索引'),
            actions: [Btn('添加索引', small: true, onPressed: _addDesignIndex)],
            child: GridTable(
              headers: [
                Text((I18n.current == AppLang.en ? 'Index name' : '索引名')),
                Text((I18n.current == AppLang.en ? 'Unique' : '唯一')),
                Text(t('columns')),
                Text(t('actions')),
              ],
              emptyText: (I18n.current == AppLang.en ? '(none)' : '（无）'),
              rows: [
                for (final index in _structureIndexes())
                  _designIndexRow(index),
                for (var i = 0; i < _designNewIndexes.length; i++)
                  _designNewIndexRow(i),
              ],
            ),
          ),
        CardBox(
          title: (I18n.current == AppLang.en ? 'Foreign keys' : '外键'),
          actions: [
            Btn((I18n.current == AppLang.en ? 'Add foreign key' : '添加外键'),
                small: true,
                onPressed: AppState.instance.isSqlite ? null : _addDesignFk),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (AppState.instance.isSqlite)
                Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('SQLite 不支持通过设计器添加外键。', style: kSmallMuted),
                ),
              GridTable(
                headers: [
                  Text((I18n.current == AppLang.en ? 'Name' : '名称')),
                  Text(t('columns')),
                  Text((I18n.current == AppLang.en ? 'Referenced table' : '引用表')),
                  Text((I18n.current == AppLang.en ? 'Referenced column' : '引用字段')),
                  Text((I18n.current == AppLang.en ? 'On delete' : '删除时')),
                  Text((I18n.current == AppLang.en ? 'On update' : '更新时')),
                  Text(t('actions')),
                ],
                emptyText: (I18n.current == AppLang.en ? '(none)' : '（无）'),
                rows: [
                  for (final fk in _structureFks()) _designFkRow(fk),
                  for (var i = 0; i < _designNewFks.length; i++)
                    _designNewFkRow(i),
                ],
              ),
            ],
          ),
        ),
        CardBox(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Btn(t('preview_sql'), onPressed: _previewDesign),
                  Btn((I18n.current == AppLang.en ? 'Apply changes' : '应用修改'), primary: true, onPressed: _applyDesign),
                ],
              ),
              const SizedBox(height: 8),
              if (_designError != null) AlertBox(_designError!),
              if (_designSql != null) CodeBlock(_designSql!),
              for (final result in _designResults)
                AlertBox(
                  (result['statement'] ?? '').toString() +
                      ((result['error'] ?? '') == null
                          ? ' ✓'
                          : '\n${result['error']}'),
                  tone: (result['error'] ?? '') == null
                      ? AlertTone.ok
                      : AlertTone.error,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Map<String, dynamic> _features() {
    final meta = AppState.instance.metaOptions;
    final features = meta?['features'];
    if (features is Map) return Map<String, dynamic>.from(features);
    return <String, dynamic>{};
  }

  List<Json> _structureIndexes() {
    final value = _structure['indexes'];
    if (value is! List) return <Json>[];
    // Collapse the per-column index rows into one row per index name.
    final grouped = <String, Json>{};
    for (final raw in value) {
      final idx = Map<String, dynamic>.from(raw as Map);
      final name = (idx['INDEX_NAME'] ?? '').toString();
      if (name.isEmpty) continue;
      final existing = grouped[name];
      if (existing == null) {
        grouped[name] = {
          'INDEX_NAME': name,
          'NON_UNIQUE': idx['NON_UNIQUE'],
          'columns': <String>[idx['COLUMN_NAME'].toString()],
        };
      } else {
        (existing['columns'] as List).add(idx['COLUMN_NAME'].toString());
      }
    }
    return grouped.values.toList();
  }

  List<Json> _structureFks() {
    final value = _structure['foreign_keys'];
    if (value is! List) return <Json>[];
    return value.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  TableRow _designColumnRow(int index) {
    final column = _designColumns[index];
    final changed = _columnChanged(column);
    // 逐列还原的基线按「原列名」查找；新加的列没有基线。
    final baseline =
        _designColumnBaseline[(column['original'] ?? '').toString()];
    return TableRow(
      decoration: BoxDecoration(
        color: changed ? AppColors.rowSelected : Colors.transparent,
      ),
      children: [
        _textCell(column['name'], (v) => column['name'] = v, mono: true),
        _textCell(column['type'], (v) => column['type'] = v, mono: true),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: CheckBox(
            label: '',
            value: column['nullable'] == true,
            onChanged: (v) => setState(() => column['nullable'] = v),
          ),
        ),
        _textCell(column['default'], (v) => column['default'] = v),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: CheckBox(
            label: '',
            value: column['auto_increment'] == true,
            onChanged: (v) => setState(() => column['auto_increment'] = v),
          ),
        ),
        _textCell(column['comment'], (v) => column['comment'] = v),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Pill(
            column['isNew'] == true
                ? 'new'
                : (changed ? 'changed' : '—'),
            tone: column['isNew'] == true
                ? PillTone.info
                : (changed ? PillTone.warn : PillTone.neutral),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: ValueListenableBuilder<int>(
            valueListenable: _designRevision,
            builder: (context, revision, _) {
              // 只有改过的现有列可还原：新列没有数据库基线，只能删除。
              final canRevert = column['isNew'] != true &&
                  baseline != null &&
                  tableDesignColumnRowDirty(baseline, column);
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconBtn(
                    Icons.restore,
                    key: ValueKey<String>('table-design-revert-$index'),
                    tooltip: pickText(
                      '还原该列到数据库当前定义',
                      'Revert this column to the database definition',
                    ),
                    onPressed: canRevert
                        ? () => _revertDesignColumn(index)
                        : null,
                  ),
                  const SizedBox(width: 4),
                  Btn(t('delete'),
                      small: true,
                      danger: true,
                      onPressed: () =>
                          setState(() => _designColumns.removeAt(index))),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  bool _columnChanged(Json column) {
    if (column['isNew'] == true) return true;
    final originalName = (column['original'] ?? '').toString();
    final original = _structureColumns.firstWhere(
      (c) => (c['name'] ?? '').toString() == originalName,
      orElse: () => <String, dynamic>{},
    );
    if (original.isEmpty) return true;
    return (original['type_name'] ?? '').toString() != column['type'] ||
        (original['IS_NULLABLE'] == 'YES') != (column['nullable'] == true) ||
        (original['COLUMN_DEFAULT'] ?? '').toString() !=
            (column['default'] ?? '').toString() ||
        (original['EXTRA'] ?? '').toString().contains('auto_increment') !=
            (column['auto_increment'] == true) ||
        (original['COLUMN_COMMENT'] ?? '').toString() !=
            (column['comment'] ?? '').toString();
  }

  Widget _textCell(Object? value, ValueChanged<String> onChanged,
      {bool mono = false}) {
    final controller = TextEditingController(text: value?.toString() ?? '');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: SizedBox(
        width: 140,
        child: TextField(
          controller: controller,
          style: mono ? monoStyle(size: 12) : const TextStyle(fontSize: 12),
          onChanged: (value) {
            onChanged(value);
            // 文本编辑不触发整页重建（TextField 自己维护光标）：这里递增版本号，
            // 让撤销/还原按钮重新计算可用态。
            _designRevision.value++;
          },
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          ),
        ),
      ),
    );
  }

  void _addDesignColumn() {
    setState(() {
      _designColumns.add(<String, dynamic>{
        'name': '',
        'type': AppState.instance.isMysql ? 'VARCHAR(255)' : 'TEXT',
        'nullable': true,
        'default': '',
        'auto_increment': false,
        'comment': '',
        'isNew': true,
        'original': '',
      });
    });
  }

  TableRow _designIndexRow(Json index) {
    final name = (index['INDEX_NAME'] ?? '').toString();
    final isPrimary = name.toUpperCase() == 'PRIMARY';
    return TableRow(
      children: [
        gridCell(name, mono: true),
        gridCell(index['NON_UNIQUE'] == 0 ? '是' : '否'),
        gridCell((index['columns'] as List?)?.join(', '), mono: true),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: isPrimary
              ? Text('主键不可删除', style: kSmallMuted)
              : CheckBox(
                  label: t('delete'),
                  value: _designDropIndexes.contains(name),
                  onChanged: (v) => setState(() {
                    if (v) {
                      _designDropIndexes.add(name);
                    } else {
                      _designDropIndexes.remove(name);
                    }
                  }),
                ),
        ),
      ],
    );
  }

  TableRow _designNewIndexRow(int index) {
    final entry = _designNewIndexes[index];
    final columns = (entry['columns'] as List?)?.cast<String>() ?? <String>[];
    return TableRow(
      children: [
        _textCell(entry['name'], (v) => entry['name'] = v, mono: true),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: CheckBox(
            label: (I18n.current == AppLang.en ? 'Unique' : '唯一'),
            value: entry['unique'] == true,
            onChanged: (v) => setState(() => entry['unique'] = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(4),
          child: SizedBox(
            width: 200,
            child: Wrap(
              spacing: 4,
              children: [
                for (final column in _designColumns)
                  FilterChip(
                    label: Text((column['name'] ?? '').toString(),
                        style: const TextStyle(fontSize: 11)),
                    selected: columns.contains(column['name']),
                    onSelected: (selected) => setState(() {
                      if (selected) {
                        columns.add(column['name'].toString());
                      } else {
                        columns.remove(column['name']);
                      }
                      entry['columns'] = columns;
                    }),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Btn('移除',
              small: true,
              danger: true,
              onPressed: () =>
                  setState(() => _designNewIndexes.removeAt(index))),
        ),
      ],
    );
  }

  void _addDesignIndex() {
    setState(() {
      _designNewIndexes.add(<String, dynamic>{
        'name': '',
        'unique': false,
        'columns': <String>[],
      });
    });
  }

  TableRow _designFkRow(Json fk) {
    final name = (fk['CONSTRAINT_NAME'] ?? '').toString();
    return TableRow(
      children: [
        gridCell(name.isEmpty ? '（自动）' : name, mono: true),
        gridCell(fk['COLUMN_NAME'], mono: true),
        gridCell(fk['REFERENCED_TABLE_NAME'], mono: true),
        gridCell(fk['REFERENCED_COLUMN_NAME'], mono: true),
        gridCell(fk['DELETE_RULE']),
        gridCell(fk['UPDATE_RULE']),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: name.isEmpty
              ? Text('—', style: kSmallMuted)
              : CheckBox(
                  label: t('delete'),
                  value: _designDropFks.contains(name),
                  onChanged: (v) => setState(() {
                    if (v) {
                      _designDropFks.add(name);
                    } else {
                      _designDropFks.remove(name);
                    }
                  }),
                ),
        ),
      ],
    );
  }

  TableRow _designNewFkRow(int index) {
    final fk = _designNewFks[index];
    final tables = _builderTables.map((t) => t['name'].toString()).toList();
    return TableRow(
      children: [
        _textCell(fk['name'], (v) => fk['name'] = v, mono: true),
        _columnPicker(fk['columns'], (v) => setState(() => fk['columns'] = v)),
        Padding(
          padding: const EdgeInsets.all(4),
          child: SelectBox<String>(
            width: 150,
            value: (fk['ref_table'] ?? '').toString().isEmpty
                ? null
                : fk['ref_table'].toString(),
            onChanged: (v) => setState(() => fk['ref_table'] = v ?? ''),
            items: [
              const DropdownMenuItem(value: null, child: Text('选择表')),
              for (final table in tables)
                DropdownMenuItem(value: table, child: Text(table)),
            ],
          ),
        ),
        _textCell(fk['ref_columns'], (v) => fk['ref_columns'] = v),
        _actionPicker(fk, 'on_delete'),
        _actionPicker(fk, 'on_update'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Btn('移除',
              small: true,
              danger: true,
              onPressed: () => setState(() => _designNewFks.removeAt(index))),
        ),
      ],
    );
  }

  Widget _columnPicker(Object? value, ValueChanged<String> onChanged) {
    final current = value?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.all(4),
      child: SelectBox<String>(
        width: 140,
        value: current.isEmpty ? null : current,
        onChanged: (v) => onChanged(v ?? ''),
        items: [
          const DropdownMenuItem(value: null, child: Text('选择字段')),
          for (final column in _designColumns)
            DropdownMenuItem(
              value: column['name'].toString(),
              child: Text(column['name'].toString()),
            ),
        ],
      ),
    );
  }

  Widget _actionPicker(Json fk, String key) {
    const actions = ['', 'CASCADE', 'SET NULL', 'RESTRICT', 'NO ACTION'];
    final current = (fk[key] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.all(4),
      child: SelectBox<String>(
        width: 130,
        value: current.isEmpty ? '' : current,
        onChanged: (v) => setState(() => fk[key] = v ?? ''),
        items: [
          for (final action in actions)
            DropdownMenuItem(
              value: action,
              child: Text(action.isEmpty ? 'NO ACTION' : action),
            ),
        ],
      ),
    );
  }

  void _addDesignFk() {
    setState(() {
      _designNewFks.add(<String, dynamic>{
        'name': '',
        'columns': '',
        'ref_table': '',
        'ref_columns': '',
        'on_delete': '',
        'on_update': '',
      });
    });
  }

  /// Build the AlterTableSpec payload, sending only real differences.
  Map<String, dynamic> _buildAlter() {
    final addColumns = <Json>[];
    final modifyColumns = <Json>[];
    final dropColumns = <String>[];
    final kept = <String>{};
    // 第 56 轮补充：列重命名真正进入 ALTER 载荷（之前 rename_columns 恒为空，
    // 设计器里改字段名既不生效也不显示为待应用修改）。
    final renameColumns = tableDesignRenameColumns(_designColumns);

    for (final column in _designColumns) {
      final name = (column['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final payload = tableDesignColumnAlterPayload(column, renameColumns);
      if (column['isNew'] == true) {
        addColumns.add(payload);
      } else {
        final original = (column['original'] ?? name).toString();
        kept.add(original);
        if (_columnChanged(column)) {
          // 现有列只有字段定义（类型/NULL/默认值/自增/注释）变了才进
          // modify_columns；仅改名只会出现在 rename_columns 里。payload 的
          // 列名规则见 tableDesignColumnAlterName：改名的列用新名（RENAME 先
          // 作为独立语句执行），未改名/改名被跳过时用原名。
          modifyColumns.add(payload);
        }
      }
    }
    // A column that existed before and is neither kept nor renamed is dropped.
    for (final original in _structureColumns) {
      final name = (original['name'] ?? '').toString();
      if (!kept.contains(name)) dropColumns.add(name);
    }

    final addIndexes = <Json>[];
    for (final index in _designNewIndexes) {
      final columns = (index['columns'] as List?)?.cast<String>() ?? <String>[];
      if ((index['name'] ?? '').toString().trim().isEmpty || columns.isEmpty) {
        continue;
      }
      addIndexes.add(<String, dynamic>{
        'name': index['name'].toString().trim(),
        'unique': index['unique'] == true,
        'columns': columns,
      });
    }

    final addFks = <Json>[];
    for (final fk in _designNewFks) {
      final columns = (fk['columns'] ?? '').toString().trim();
      final refTable = (fk['ref_table'] ?? '').toString().trim();
      if (columns.isEmpty || refTable.isEmpty) continue;
      final refColumns = (fk['ref_columns'] ?? '').toString().trim();
      addFks.add(<String, dynamic>{
        'name': (fk['name'] ?? '').toString().trim().isEmpty
            ? null
            : fk['name'].toString().trim(),
        'columns': columns.split(',').map((s) => s.trim()).toList(),
        'ref_table': refTable,
        'ref_columns': refColumns.isEmpty
            ? <String>[]
            : refColumns.split(',').map((s) => s.trim()).toList(),
        'on_delete': (fk['on_delete'] ?? '').toString().isEmpty
            ? null
            : fk['on_delete'].toString(),
        'on_update': (fk['on_update'] ?? '').toString().isEmpty
            ? null
            : fk['on_update'].toString(),
      });
    }

    final body = <String, dynamic>{
      'add_columns': addColumns,
      'modify_columns': modifyColumns,
      'drop_columns': dropColumns,
      'rename_columns': renameColumns,
      'add_indexes': addIndexes,
      'drop_indexes': _designDropIndexes.toList(),
      'add_foreign_keys': addFks,
      'drop_foreign_keys': _designDropFks.toList(),
    };
    final renameTo = _renameTo.text.trim();
    if (renameTo.isNotEmpty && renameTo != widget.table) {
      body['rename_to'] = renameTo;
    }
    // 注释只有和数据库里的当前值不同才算修改：否则表本来就有注释时设计器
    // 一打开就 dirty（撤销按钮常亮），应用时也会重复 SET COMMENT。
    final comment = _tableComment.text.trim();
    if (comment != currentTableComment(_structure)) body['comment'] = comment;
    return body;
  }

  /// 放弃所有尚未应用的修改（第 55 轮：ROUND51 P3-7 的「撤销」）。
  ///
  /// 只把设计器重置回当前 _structure 的基线：重新播种 _designColumns、清空
  /// 新增/删除的索引与外键、重命名/注释、SQL 预览与结果/错误。**不调用数据库、
  /// 不删除已应用的修改**；因此必须是带确认的显式动作（数据本身不会丢）。
  Future<void> _resetDesign() async {
    final ok = await confirmDialog(
      context,
      message: pickText(
        '放弃所有尚未应用的修改吗？',
        'Discard all pending changes?',
      ),
      detail: pickText(
        '只重置设计器里还没应用的改动（新增/修改/删除的字段、索引、外键、表名与'
            '注释、SQL 预览与结果），不会修改数据库；已经应用的修改保持不变。',
        'This only resets changes that have not been applied yet (added, modified '
            'or dropped columns, indexes, foreign keys, table name/comment, SQL '
            'preview and results). The database is not touched, and changes that '
            'were already applied are kept.',
      ),
      confirmLabel: pickText('放弃修改', 'Discard'),
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() {
      // 从当前结构重新生成字段快照，并复位重命名/注释输入。
      _seedDesigner();
      _designNewIndexes.clear();
      _designNewFks.clear();
      _designDropIndexes.clear();
      _designDropFks.clear();
      _designSql = null;
      _designResults = <Json>[];
      _designError = null;
      _designRevision.value = 0;
    });
    widget.notice.show(
      pickText('已撤销未应用的修改', 'Pending changes discarded'),
    );
  }

  /// 把某一列还原成数据库当前定义（逐列撤销，第 56 轮）。
  ///
  /// 原位替换 _designColumns[index]，不改变列顺序，也不动索引/外键配置；旧预览
  /// 与执行结果和还原后的草稿对不上，一并清空。
  void _revertDesignColumn(int index) {
    if (index < 0 || index >= _designColumns.length) return;
    final current = _designColumns[index];
    final baseline =
        _designColumnBaseline[(current['original'] ?? '').toString()];
    if (baseline == null) return;
    final name = (baseline['name'] ?? '').toString();
    setState(() {
      _designColumns[index] = tableDesignResetColumnRow(baseline);
      _designSql = null;
      _designResults = <Json>[];
      _designError = null;
    });
    widget.notice.show(pickText('已还原列 $name', 'Column $name reverted'));
  }

  /// 表名输入「恢复原表名」：丢弃尚未应用的重命名（rename_to 为空）。
  void _resetDesignName() {
    if (_renameTo.text.trim() == widget.table) return;
    setState(() {
      _renameTo.text = widget.table;
      _designSql = null;
      _designResults = <Json>[];
      _designError = null;
    });
  }

  /// 表注释输入「恢复数据库当前注释」。
  void _resetDesignComment() {
    final baseline = currentTableComment(_structure);
    if (_tableComment.text.trim() == baseline) return;
    setState(() {
      _tableComment.text = baseline;
      _designSql = null;
      _designResults = <Json>[];
      _designError = null;
    });
  }

  Future<void> _previewDesign() async {
    final body = _buildAlter();
    if (tableDesignBodyEmpty(body)) {
      setState(() => _designError = '没有需要应用的修改');
      return;
    }
    try {
      final res = await Api.instance.alterTable(
        widget.db,
        widget.table,
        {...body, 'dry_run': true},
      );
      final statements = res['statements'];
      setState(() {
        _designError = null;
        _designSql = statements is List ? statements.join(';\n') : '';
        _designResults = <Json>[];
      });
    } catch (e) {
      setState(() => _designError = e.toString());
    }
  }


  Future<void> _applyDesign() async {
    final body = _buildAlter();
    if (tableDesignBodyEmpty(body)) {
      setState(() => _designError = '没有需要应用的修改');
      return;
    }
    try {
      final preview = await Api.instance.alterTable(
        widget.db,
        widget.table,
        {...body, 'dry_run': true},
      );
      final statements = preview['statements'];
      final sql = statements is List ? statements.join(';\n') : '';
      if (!mounted) return;
      final ok = await confirmDialog(
        context,
        message: '确定应用以下修改吗？',
        detail: sql,
        confirmLabel: '应用',
      );
      if (!ok) return;
      final res = await Api.instance.alterTable(widget.db, widget.table, body);
      final executed = res['results'];
      setState(() {
        _designError = null;
        _designSql = sql;
        _designResults = executed is List
            ? executed.map((e) => Map<String, dynamic>.from(e as Map)).toList()
            : <Json>[];
      });
      final failed = _designResults.where((r) => r['error'] != null).length;
      if (failed == 0) {
        widget.notice.show('修改已应用');
        await _reloadAll();
      } else {
        setState(() => _designError = '有 $failed 条语句执行失败，请查看下方结果');
      }
    } catch (e) {
      if (mounted) setState(() => _designError = describeDbError(e));
    }
  }


  // -------------------------------------------------------------------- sql

  /// First line of the table page SQL editor.
  ///
  /// MySQL has a real USE statement; the console intercepts it and applies it
  /// as a validated database switch (so it cannot bypass only_db / hide_db).
  /// PostgreSQL uses the equivalent SET search_path, and SQLite has no USE
  /// syntax, so a comment documents the attached namespace instead.
  String _defaultSqlPrelude() {
    final state = AppState.instance;
    if (state.isMysql) {
      return 'USE ${state.quoteIdent(widget.db)};';
    }
    if (state.isPostgres) {
      return 'SET search_path TO ${state.quoteIdent(widget.db)};';
    }
    return '-- 当前数据库: ${widget.db}';
  }

  String _defaultTableSql() =>
      '${_defaultSqlPrelude()}\n\n'
      'SELECT * FROM ${AppState.instance.qualify(widget.db, widget.table)} LIMIT 50;';

  Widget _sqlTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CardBox(
          title: 'SQL 控制台 — ${widget.db}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SqlEditor(
                controller: _sqlController,
                lines: 7,
                onChanged: (v) => _sqlText = v,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  Btn(
                    t('run'),
                    primary: true,
                    busy: _sqlRunning,
                    onPressed: _sqlRunning ? null : _runSql,
                  ),
                  Btn(
                    '取消',
                    key: const ValueKey('table-sql-cancel'),
                    tooltip: AppState.instance.isSqlite
                        ? 'SQLite 在应用进程内执行查询，无法安全取消'
                        : '取消正在执行的查询（MySQL KILL / PostgreSQL pg_cancel_backend）',
                    onPressed: _sqlRunning ? _cancelSql : null,
                  ),
                  Btn('EXPLAIN', onPressed: _sqlRunning ? null : _explainSql),
                ],
              ),
            ],
          ),
        ),
        ResultTable(
          results: _sqlResults,
          database: widget.db,
          notice: widget.notice,
          onRefresh: (_) => _rerunSql(),
        ),
      ],
    );
  }

  List<Json> _resultsOf(Object? value) {
    if (value is! List) return <Json>[];
    return value.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> _runSql() async {
    if (_sqlRunning) return;
    setState(() {
      _sqlError = null;
      _sqlRunning = true;
    });
    try {
      final res = await Api.instance.query(_sqlText, widget.db);
      setState(() => _sqlResults = _resultsOf(res['results']));
      // The SQL tab can change the row count (INSERT / DELETE / TRUNCATE), so
      // the pill has to re-count here too.
      await _reloadAfterWrite();
    } catch (e) {
      if (mounted) setState(() => _sqlError = describeDbError(e));
    } finally {
      if (mounted) setState(() => _sqlRunning = false);
    }
  }

  /// Same semantics as the console cancel button: stop the server-side
  /// statement; the in-flight request returns the rewritten error.
  Future<void> _cancelSql() async {
    try {
      final res = await Api.instance.cancelQuery();
      final cancelled = (res['cancelled'] as num?)?.toInt() ?? 0;
      final reconnected = res['reconnected'] == true;
      if (cancelled <= 0) {
        widget.notice.show('没有找到正在执行的查询（可能已结束）');
      } else if (reconnected) {
        widget.notice.show('已中断查询连接，下一次查询会自动重连');
      } else {
        widget.notice.show('已发送取消请求');
      }
    } catch (e) {
      if (mounted) setState(() => _sqlError = describeDbError(e));
    }
  }

  Future<void> _rerunSql() async {
    if (_sqlRunning) return;
    setState(() {
      _sqlError = null;
      _sqlRunning = true;
    });
    try {
      final res = await Api.instance.query(_sqlText, widget.db);
      setState(() => _sqlResults = _resultsOf(res['results']));
    } catch (e) {
      if (mounted) setState(() => _sqlError = describeDbError(e));
    } finally {
      if (mounted) setState(() => _sqlRunning = false);
    }
  }

  Future<void> _explainSql() async {
    setState(() => _sqlError = null);
    try {
      final res = await Api.instance.explain(_sqlText, widget.db);
      setState(() => _sqlResults = _resultsOf(res['results']));
    } catch (e) {
      if (mounted) setState(() => _sqlError = describeDbError(e));
    }
  }
  // ----------------------------------------------------------------- insert

  /// Error shown inside the insert card; the page banner is far above the form
  /// once the table has many columns.
  String? _insertError;

  /// N-04: inline success confirmation next to the insert form.
  ///
  /// The page-level toast is 3 s and can be above the fold on a table with many
  /// columns, which made a successful insert look like nothing happened. This
  /// stays next to the buttons until the next insert.
  String? _insertNotice;

  Widget _insertTab() {
    return CardBox(
      title: '插入行',
      actions: [
        Btn('插入', primary: true, onPressed: _insertRow),
        Btn(t('clear'), onPressed: () => setState(_seedInsertValues)),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('留空的字段将使用默认值。', style: kSmallMuted),
          ),
          if (_insertError != null) AlertBox(_insertError!),
          if (_insertNotice != null)
            AlertBox(_insertNotice!, tone: AlertTone.ok),
          for (var i = 0; i < _structureColumns.length; i++) _insertRowWidget(i),
        ],
      ),
    );
  }

  Widget _insertRowWidget(int index) {
    final column = _structureColumns[index];
    final name = column['name'].toString();
    final rawType = (column['type_name'] ?? '').toString();
    final type = rawType.toLowerCase();
    final isBoolean = type.startsWith('bool') || type.startsWith('tinyint(1)');
    final isLongText = type.contains('text') || type.contains('json');
    // MySQL spells the allowed values in COLUMN_TYPE, e.g.
    // enum('G','PG-13','R'). A free-text box let any string through and only
    // the server complained ("Data truncated for column 'rating'", round34
    // P3-01), so an enum column gets a dropdown built from its own definition.
    final enumOptions = enumColumnOptions(rawType);
    final setOptions = setColumnOptions(rawType);
    final nullable = column['IS_NULLABLE'] == 'YES';
    final state = _insertValues[index];
    final isNull = state['isNull'] == true;
    final current = (state['value'] ?? '').toString();

    // Every column owns a controller and _insertRow reads it as the
    // authoritative value (it is what the user sees in the box), so a dropdown
    // has to write through to the controller, not only to _insertValues.
    void setValue(String next) {
      setState(() {
        state['value'] = next;
        _insertControllers
            .putIfAbsent(name, () => TextEditingController())
            .text = next;
      });
    }

    final Widget field;
    if (enumOptions != null) {
      field = SelectBox<String>(
        value: current.isEmpty ? _defaultInsertOption : current,
        enabled: !isNull,
        onChanged: (v) => setValue(v == _defaultInsertOption ? '' : (v ?? '')),
        items: [
          const DropdownMenuItem(
              value: _defaultInsertOption, child: Text(_defaultInsertOption)),
          for (final option in enumOptions)
            DropdownMenuItem(
                value: option, child: Text(option, noTranslate: true)),
        ],
      );
    } else if (isBoolean) {
      field = SelectBox<String>(
        value: current.isEmpty ? _defaultInsertOption : current,
        enabled: !isNull,
        onChanged: (v) => setValue(v == _defaultInsertOption ? '' : (v ?? '')),
        items: const [
          DropdownMenuItem(
              value: _defaultInsertOption, child: Text(_defaultInsertOption)),
          DropdownMenuItem(value: 'true', child: Text('true')),
          DropdownMenuItem(value: 'false', child: Text('false')),
        ],
      );
    } else {
      field = TextField(
        // Controlled: the box mirrors _insertValues through this controller,
        // so clearing the form really clears the text.
        controller: _insertControllers.putIfAbsent(
            name, () => TextEditingController()),
        enabled: !isNull,
        maxLines: isLongText ? 2 : 1,
        style: monoStyle(size: 12),
        onChanged: (v) => state['value'] = v,
        decoration: InputDecoration(
          isDense: true,
          border: const OutlineInputBorder(),
          // A set(...) column takes several of these values, comma separated,
          // so it stays a text box; the hint lists what the definition allows.
          hintText: setOptions?.join(' / '),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 160,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: monoStyle(size: 12, weight: FontWeight.w600)),
                Text(column['type_name']?.toString() ?? '',
                    style: monoStyle(size: 11, color: AppColors.typeText)),
              ],
            ),
          ),
          Expanded(child: field),
          const SizedBox(width: 8),
          CheckBox(
            label: 'NULL',
            value: isNull,
            enabled: nullable,
            onChanged: (v) => setState(() => state['isNull'] = v),
          ),
        ],
      ),
    );
  }

  Future<void> _insertRow() async {
    final values = <String, dynamic>{};
    for (var i = 0; i < _structureColumns.length; i++) {
      final column = _structureColumns[i];
      final name = column['name'].toString();
      final state = _insertValues[i];
      if (state['isNull'] == true) {
        values[name] = null;
        continue;
      }
      // The controller is authoritative: it is what the user sees in the box.
      final raw = (_insertControllers[name]?.text ?? state['value'] ?? '')
          .toString();
      if (raw.isEmpty) continue;
      // Checked before the round trip: the server answers an enum/set value it
      // cannot store with "Data truncated for column 'x'" (English + error
      // code), which reads as an application failure instead of "pick one of
      // these" (round34 P3-01).
      final invalid =
          typedValueError(name, column['type_name']?.toString(), raw);
      if (invalid != null) {
        setState(() {
          _insertError = invalid;
          _insertNotice = null;
        });
        return;
      }
      values[name] = _coerce(column, raw);
    }
    if (values.isEmpty) {
      setState(() {
        _insertError = '请至少填写一个字段';
        _insertNotice = null;
      });
      return;
    }
    setState(() {
      _insertError = null;
      _insertNotice = null;
    });
    try {
      await Api.instance.changeRow(widget.db, widget.table, {
        'action': 'insert',
        'values': values,
      });
      widget.notice.show('行已插入');
      setState(() {
        _insertError = null;
        _insertNotice = '已插入 1 行（数据已刷新）';
        _seedInsertValues();
      });
      await _reloadAfterWrite();
    } catch (e) {
      if (mounted) {
        setState(
            () => _insertError = describeInsertError(e, _structureColumns));
      }
    }
  }

  // ----------------------------------------------------------------- export

  Widget _exportTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CardBox(
          title: t('export_title', {'name': widget.table}),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(I18n.current == AppLang.en ? 'Format' : '格式', style: kSmall),
              SelectBox<String>(
                width: 140,
                value: _exportFormat,
                onChanged: (v) => setState(() {
                  _exportFormat = v ?? 'sql';
                  _exportPreview = null;
                }),
                items: const [
                  DropdownMenuItem(value: 'sql', child: Text('SQL')),
                  DropdownMenuItem(value: 'csv', child: Text('CSV')),
                  DropdownMenuItem(value: 'json', child: Text('JSON')),
                  DropdownMenuItem(value: 'xml', child: Text('XML')),
                  DropdownMenuItem(value: 'html', child: Text('HTML')),
                  DropdownMenuItem(value: 'txt', child: Text('TXT')),
                  DropdownMenuItem(value: 'xls', child: Text('Excel')),
                  DropdownMenuItem(value: 'md', child: Text('Markdown')),
                ],
              ),
              if (_exportFormat == 'sql') ...[
                CheckBox(
                  label: I18n.current == AppLang.en ? 'Include structure' : t('export_structure'),
                  value: _exportStructure,
                  onChanged: (v) => setState(() => _exportStructure = v),
                ),
                CheckBox(
                  label: I18n.current == AppLang.en ? 'Include data' : t('export_data'),
                  value: _exportData,
                  onChanged: (v) => setState(() => _exportData = v),
                ),
                CheckBox(
                  label: I18n.current == AppLang.en ? 'Include DROP' : t('export_drop'),
                  value: _exportDrop,
                  onChanged: (v) => setState(() => _exportDrop = v),
                ),
              ],
              Btn(
                  _exporting
                      ? (I18n.current == AppLang.en
                          ? 'Exporting…'
                          : '导出中…')
                      : (I18n.current == AppLang.en
                          ? 'Export to file'
                          : '导出到文件'),
                  primary: true,
                  busy: _exporting,
                  onPressed: _exporting ? null : _doExport),
              Btn(t('preview'),
                  onPressed: _exporting ? null : _previewExport),
            ],
          ),
        ),
        if (_exportPreview != null) CodeBlock(_exportPreview!, maxHeight: 420),
      ],
    );
  }

  Json _exportParams() => <String, dynamic>{
        'format': _exportFormat,
        'structure': _exportStructure,
        'data': _exportData,
        'drop': _exportDrop,
      };

  /// Default file name the save dialog should propose for the active format.
  String _exportFileName() {
    final ext = switch (_exportFormat) {
      'markdown' => 'md',
      'excel' => 'xls',
      _ => _exportFormat,
    };
    return '${widget.table}.$ext';
  }

  Future<void> _previewExport() async {
    try {
      final res = await Api.instance
          .exportTable(widget.db, widget.table, _exportParams());
      final content = (res['content'] ?? '').toString();
      final truncated = res['truncated'] == true;
      final note = I18n.current == AppLang.en
          ? '\n…(preview truncated)'
          : '\n…（预览已截断）';
      setState(() => _exportPreview = truncated ? '$content$note' : content);
    } catch (e) {
      if (mounted) setState(() => _error = describeDbError(e));
    }
  }

  /// Export the table, streaming the file from Rust.
  ///
  /// The old path fetched the whole table as a String through the FFI bridge
  /// and handed it to the save dialog; on a million-row table that peaked
  /// around 1 GB of memory (test report §6.3 P1). The destination is chosen
  /// first, then the Rust core writes it row by row.
  Future<void> _doExport() async {
    if (_exporting) return;
    String? path;
    try {
      path = await pickSavePath(
        title: I18n.current == AppLang.en ? 'Export to file' : '导出到文件',
        fileName: _exportFileName(),
        initialDirectory: AppState.instance.dataDir,
      );
      if (path == null || path.isEmpty) return;
      if (!mounted) return;
      setState(() {
        _exporting = true;
        _error = null;
      });
      final res = await Api.instance.exportTable(
          widget.db, widget.table, {..._exportParams(), 'path': path});
      if (!mounted) return;
      final rows = (res['rows'] as num?)?.toInt() ?? 0;
      widget.notice.show(
          I18n.current == AppLang.en
              ? 'Exported $rows rows to $path'
              : '已导出 $rows 行到 $path');
    } catch (e) {
      // The native save dialog already created/truncated the destination; do
      // not leave an empty file behind when the streamed export failed.
      if (path != null && path.isNotEmpty) {
        try {
          final file = File(path);
          if (file.existsSync() && file.lengthSync() == 0) file.deleteSync();
        } catch (_) {
          // Best effort only; the export error below is what matters.
        }
      }
      if (mounted) setState(() => _error = describeDbError(e));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }
  // ----------------------------------------------------------------- import

  Widget _importTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _dataImportCard(),
        _sqlFileImportCard(),
      ],
    );
  }

  Widget _dataImportCard() {
    return CardBox(
      title: pickText('导入数据文件到 ${widget.table}',
          'Import data file into ${widget.table}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            pickText(
              '支持 CSV / TSV / 分隔文本 / JSON 数组 / JSON Lines / 自定义包裹与分隔的文本。'
              '通过向导逐步设置一条数据怎么切分、列怎么识别，先试插入一条并校验整个文件，通过后再分批写入。',
              'Supports CSV / TSV / delimited text / JSON arrays / JSON Lines / custom '
              'wrappers and separators. Step through the wizard to define how one '
              'record is split and how columns are detected; one row is trial-inserted '
              'and the whole file validated before batching.',
            ),
            style: kSmallMuted,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Btn('打开数据导入向导',
                  key: const ValueKey('data-import-wizard'),
                  primary: true,
                  icon: Icons.upload_file,
                  onPressed: _openDataImportWizard),
              Btn('保存格式示例',
                  key: const ValueKey('data-import-sample'),
                  onPressed: _saveImportSample),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sqlFileImportCard() {
    final info = _importFileInfo;
    final result = _importResult;
    final progress = asJsonMap(_importJobStatus?['progress']);
    final percent = (progress['percent'] as num?)?.toDouble() ?? 0;
    final jobRunning =
        _importJobStatus != null && _importJobStatus!['done'] != true;
    return CardBox(
      title: pickText(
          '执行 SQL 文件到 ${widget.db}', 'Run SQL file on ${widget.db}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            pickText(
              '选择 UTF-8 的 .sql 脚本（支持 DELIMITER 指令），从磁盘流式读取并逐条执行；'
              '大文件不会整个载入内存，执行过程中可取消。',
              'Choose a UTF-8 .sql script (DELIMITER supported); it is streamed from '
              'disk and executed statement by statement. Large files are never loaded '
              'into memory and the run can be cancelled.',
            ),
            style: kSmallMuted,
          ),
          const SizedBox(height: 4),
          Text(_importContextText(), style: kSmallMuted),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Btn('选择 SQL 文件',
                  key: const ValueKey('sql-import-pick'),
                  onPressed: _importing ? null : _pickImportFile),
              if (_importPath != null)
                Text(
                  '${info?['name'] ?? baseNameOf(_importPath!)}'
                  '${info == null ? '' : ' · ${formatBytes((info['size'] as num?)?.toInt())}'}',
                  style: kSmallMuted,
                ),
              Btn(jobRunning ? '执行中…' : '执行 SQL 文件',
                  key: const ValueKey('sql-import-run'),
                  primary: true,
                  busy: jobRunning,
                  onPressed:
                      _importPath == null || _importing ? null : _runImport),
              if (jobRunning)
                Btn('取消',
                    danger: true, onPressed: () => _importPoller?.cancelJob()),
            ],
          ),
          if (jobRunning) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: percent <= 0 ? null : (percent / 100).clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: AppColors.chipBg,
              valueColor:
                  AlwaysStoppedAnimation<Color>(AppColors.header),
            ),
            const SizedBox(height: 6),
            Text(
              '${formatBytes((progress['bytes'] as num?)?.toInt() ?? 0)}'
              ' / ${formatBytes((progress['total_bytes'] as num?)?.toInt() ?? 0)}'
              '（${percent.toStringAsFixed(1)}%） · 已执行 '
              '${formatCount((progress['records'] as num?))} 条语句 · 用时 '
              '${((progress['elapsed_ms'] as num?)?.toInt() ?? 0) / 1000} 秒',
              style: kSmallMuted,
            ),
          ],
          if (result != null) ...[
            const SizedBox(height: 10),
            AlertBox(
              _importResultText(result),
              tone: result['ok'] == true ? AlertTone.ok : AlertTone.error,
            ),
            if (result['use_database'] != null) ...[
              Text(
                '执行中切换数据库：${result['use_database']}',
                style: kSmallMuted,
              ),
              const SizedBox(height: 6),
            ],
            if ((result['issues'] as List? ?? const <dynamic>[]).isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final raw in (result['issues'] as List).take(10))
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    issuePositionLabel(asJsonMap(raw)),
                    style: TextStyle(
                        fontSize: 12, color: AppColors.errText),
                  ),
                ),
              if ((result['issues'] as List).length > 10)
                Text(
                  '（仅显示前 10 条，共 ${(result['issues'] as List).length} 条）',
                  style: kSmallMuted,
                ),
            ],
          ],
        ],
      ),
    );
  }

  /// Context line for the SQL file card: the first statement the backend
  /// establishes (equivalent to a USE database statement) is surfaced so the user knows
  /// which database the file will run against.
  String _importContextText() {
    final state = AppState.instance;
    if (state.isMysql) {
      return '执行上下文：首条自动切换到 USE ${state.quoteIdent(widget.db)};（由应用校验可见性后安全切换）。';
    }
    if (state.isPostgres) {
      return '执行上下文：目标模式 ${widget.db}（文件中的表名建议使用模式限定）。';
    }
    return pickText('执行上下文：目标命名空间 ${widget.db}。',
        'Execution context: target namespace ${widget.db}.');
  }

  String _importResultText(Json result) {
    final statements = (result['statements'] as num?)?.toInt() ?? 0;
    final succeeded = (result['succeeded'] as num?)?.toInt() ?? 0;
    final failed = (result['failed'] as num?)?.toInt() ?? 0;
    final seconds = ((result['elapsed_ms'] as num?)?.toInt() ?? 0) / 1000;
    if (result['cancelled'] == true) {
      return '已取消：共执行 ${formatCount(statements)} 条语句，成功 ${formatCount(succeeded)} 条。';
    }
    if (result['ok'] == true) {
      return '执行完成：${formatCount(statements)} 条语句全部成功，用时 $seconds 秒。';
    }
    final message = (result['message'] ?? '').toString();
    return '执行结束：共 ${formatCount(statements)} 条语句，成功 ${formatCount(succeeded)} 条，'
        '失败 ${formatCount(failed)} 条。${message.isEmpty ? '' : '\n$message'}';
  }

  Future<void> _openDataImportWizard() async {
    await showDataImportWizard(
      context,
      database: widget.db,
      table: widget.table,
      notice: widget.notice,
      onImported: () async {
        await _reloadAfterWrite();
        await _loadStructure();
      },
    );
  }

  Future<void> _saveImportSample() async {
    const sample = 'id,name,age\n1,Ada,36\n2,Bob,41\n';
    try {
      final path = await pickSavePath(
        title: '保存数据导入示例',
        fileName: '${widget.table}_sample.csv',
        initialDirectory: AppState.instance.dataDir,
      );
      if (path == null || path.isEmpty) return;
      await Api.instance.writeTextFile(path, sample);
      widget.notice.show('示例已保存到 $path');
    } catch (e) {
      if (mounted) setState(() => _error = describeDbError(e));
    }
  }

  Future<void> _pickImportFile() async {
    try {
      final path = await pickSqlFile(title: '选择要执行的 SQL 文件');
      if (path == null || path.trim().isEmpty) return;
      final info = await Api.instance.sqlFilePreview(path.trim(), maxBytes: 1024);
      if (!mounted) return;
      setState(() {
        _importPath = path.trim();
        _importFileInfo = info;
        _importResult = null;
        _importJobStatus = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = describeDbError(e));
    }
  }

  Future<void> _runImport() async {
    final path = _importPath;
    if (path == null) return;
    setState(() {
      _importing = true;
      _importResult = null;
      _importJobStatus = null;
    });
    try {
      final res = await Api.instance
          .sqlFileExecuteStart(widget.db, path, <String, dynamic>{
        'on_error': 'stop',
        'max_issues': 50,
      });
      final jobId = (res['job_id'] ?? '').toString();
      if (!mounted) return;
      if (jobId.isEmpty) {
        setState(() => _importing = false);
        return;
      }
      _importPoller?.dispose();
      _importPoller = ImportJobPoller(onUpdate: (status) {
        if (!mounted) return;
        setState(() {
          _importJobStatus = status;
          if (status['done'] != true) return;
          _importing = false;
          if (status['state'] == 'failed') {
            _importResult = <String, dynamic>{
              'ok': false,
              'message': (status['error'] ?? '任务失败').toString(),
            };
          } else {
            _importResult = asJsonMap(status['result']);
            if (_importResult?['ok'] == true) {
              widget.notice.show('SQL 文件执行完成');
              _reloadAll();
            }
          }
        });
      });
      _importPoller!.start(jobId);
    } catch (e) {
      if (mounted) {
        setState(() {
          _importing = false;
          _importResult = <String, dynamic>{
            'ok': false,
            'message': describeDbError(e),
          };
        });
      }
    }
  }

  // ------------------------------------------------------------- operations

  Widget _operationsTab() {
    return CardBox(
      title: '操作',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_isView)
            Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('视图不能清空或删除。', style: kSmallMuted),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Btn('清空表', onPressed: _isView ? null : _truncateTable),
              Btn('删除表', danger: true, onPressed: _isView ? null : _dropTable),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _truncateTable() async {
    final ok = await confirmDialog(
      context,
      message: '确定清空表 ${widget.table} 吗？',
      detail: 'TRUNCATE TABLE 会删除全部数据且无法回滚。',
      confirmLabel: '清空',
      danger: true,
    );
    if (!ok) return;
    try {
      await Api.instance.truncate(widget.db, widget.table);
      widget.notice.show('表已清空');
      await _reloadAfterWrite();
    } catch (e) {
      if (mounted) setState(() => _error = describeDbError(e));
    }
  }

  Future<void> _dropTable() async {
    final ok = await confirmDialog(
      context,
      message: '确定删除表 ${widget.table} 吗？',
      detail: 'DROP TABLE 会连同数据一起删除且无法回滚。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    try {
      await Api.instance.dropTable(widget.db, widget.table);
      widget.notice.show('表已删除');
      AppState.instance.bumpExplorer();
      if (mounted) Navigation.instance.go(AppRoute.database(widget.db));
    } catch (e) {
      if (mounted) setState(() => _error = describeDbError(e));
    }
  }
}
// -------------------------------------------------------------------- helpers

/// Whether a table-page request must run COUNT(*).
///
/// The round-34 keyset contract counts only the first, un-cursored page: a
/// cursor page comes back with total: null and reuses the total learned on
/// page 1, because a full count on a wide table often costs more than the page
/// itself. A write or an explicit refresh passes [refreshCount] so the header's
/// row-count pill is refreshed even on a cursor page — one extra count per user
/// action, never one per page.
bool shouldCountTableRows({required Object? cursor, bool refreshCount = false}) =>
    cursor == null || refreshCount;

/// Values declared by a MySQL enum(...) / set(...) column.
///
/// [columnType] is the raw COLUMN_TYPE from information_schema, which the
/// structure query exposes as type_name (for example enum('G','PG-13','R')).
/// [base] is enum or set; any other type — varchar(10), PostgreSQL's
/// USER-DEFINED — returns null, meaning no value list is available.
///
/// Values keep their original case: the column definition is the only place
/// they are spelled out, and the widgets lowercase the type for their own
/// checks, which would turn PG into pg and make every value look invalid.
List<String>? _declaredTypeOptions(String? columnType, String base) {
  final type = (columnType ?? '').trim();
  final opening = RegExp('^$base\\s*\\(', caseSensitive: false);
  final match = opening.matchAsPrefix(type);
  if (match == null || !type.endsWith(')')) return null;
  final body = type.substring(match.end, type.length - 1);
  final options = <String>[];
  final buffer = StringBuffer();
  var quote = '';
  for (var i = 0; i < body.length; i++) {
    final char = body[i];
    if (quote.isEmpty) {
      if (char == "'" || char == '"') {
        quote = char;
        buffer.clear();
      }
      continue;
    }
    if (char == '\\' && i + 1 < body.length) {
      buffer.write(body[++i]);
      continue;
    }
    if (char == quote) {
      // MySQL escapes a quote inside a value by doubling it: 'it''s'.
      if (i + 1 < body.length && body[i + 1] == char) {
        buffer.write(char);
        i++;
        continue;
      }
      quote = '';
      options.add(buffer.toString());
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  return options.isEmpty ? null : options;
}

/// Allowed values of an enum column, or null when the type is not an enum.
List<String>? enumColumnOptions(String? columnType) =>
    _declaredTypeOptions(columnType, 'enum');

/// Allowed values of a set column, or null when the type is not a set.
List<String>? setColumnOptions(String? columnType) =>
    _declaredTypeOptions(columnType, 'set');

/// Reject a value the column definition cannot hold, before it reaches the
/// server.
///
/// Returns the message to show, or null when the value is acceptable. The two
/// branches are interpolated, so the call site picks the language with
/// pickText instead of relying on an exact-match dictionary entry.
String? typedValueError(String columnName, String? columnType, String raw) {
  final options = enumColumnOptions(columnType);
  if (options != null && !options.contains(raw)) {
    return pickText(
      '「$columnName」只能填以下值之一：${options.join('、')}',
      '"$columnName" only accepts one of: ${options.join(', ')}',
    );
  }
  final setValues = setColumnOptions(columnType);
  if (setValues != null) {
    final unknown = raw
        .split(',')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty && !setValues.contains(part))
        .toList();
    if (unknown.isNotEmpty) {
      return pickText(
        '「$columnName」的取值必须来自：${setValues.join('、')}（多个值用英文逗号分隔）',
        '"$columnName" values must come from: ${setValues.join(', ')}'
        ' (separate several values with commas)',
      );
    }
  }
  return null;
}

/// The column a MySQL "Data truncated for column 'x'" error names.
///
/// Kept separate so the mapping from the driver text to a readable message can
/// be unit-tested without a server.
String? truncatedColumnName(Object? error) {
  final text = error?.toString() ?? '';
  final match =
      RegExp(r"data truncated for column '([^']+)'", caseSensitive: false)
          .firstMatch(text);
  return match?.group(1);
}

/// Turn a failed INSERT into copy the user can act on.
///
/// MySQL reports an out-of-range enum/set (or an over-long value) with
/// "Data truncated for column 'x'" plus an error code, which the user cannot
/// do anything with. [columns] is the structure list, used to recover the
/// allowed values of the named column.
String describeInsertError(Object error, List<Json> columns) {
  final name = truncatedColumnName(error);
  if (name == null) return describeDbError(error);
  final column = columns.firstWhere(
      (c) => (c['name'] ?? '').toString() == name,
      orElse: () => const <String, dynamic>{});
  final options = enumColumnOptions(column['type_name']?.toString());
  if (options != null) {
    return pickText(
      '「$name」的值不在允许范围内。可选值：${options.join('、')}',
      '"$name" is outside the allowed values. Allowed: ${options.join(', ')}',
    );
  }
  return pickText(
    '「$name」的值超出了列定义允许的范围（长度或数值范围），请检查后重试。',
    '"$name" is outside the range its definition allows (length or numeric '
        'range); check the value and try again.',
  );
}