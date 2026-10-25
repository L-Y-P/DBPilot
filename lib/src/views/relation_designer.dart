// E-R 关系设计器（第 50 轮）。
//
// 规格见 docs/IMPORT_EXCEL_ER_DESIGN.md §5：
//  * 从数据库页 / 内置导入向导 / 快速建表向导嵌入；
//  * 已存在外键自动画成箭头，点击箭头查看 / 删除；
//  * 从字段右侧连接点拖到另一张表的字段建立外键；
//  * 同一对表已有关系时默认自动创建中间表（多对多）；
//  * SQLite 不支持 ALTER 增删外键：连接点禁用、已有关系只读。
//
// 纯逻辑（模型、外键 payload、中间表、箭头命中、自动布局）在 er_model.dart，
// 可以无 FFI 单测；本文件只负责数据加载、画布绘制与对话框交互。

import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text, Tooltip;

import '../api.dart';
import '../app_state.dart';
import '../i18n_literals.dart';
import '../notice.dart';
import '../text.dart';
import '../theme.dart';
import '../tooltip.dart';
import '../widgets.dart';
import 'er_model.dart';

/// 「删除时 / 更新时」下拉与只读信息里的引用动作文案。
///
/// 中文界面只描述动作含义（不出现 SQL 关键字）；英文界面显示
/// ON DELETE CASCADE 这样的 SQL 表达——用 pickText 直接选择语言，所以这里
/// 不需要额外的 en 映射条目。
String erFkActionLabel(String action, {required bool onDelete}) {
  final value = action.trim().toUpperCase();
  switch (value) {
    case '':
    case 'NO ACTION':
      return pickText('不操作', 'NO ACTION');
    case 'CASCADE':
      return onDelete
          ? pickText('级联（一并删除子行）', 'ON DELETE CASCADE')
          : pickText('级联（一并更新子行）', 'ON UPDATE CASCADE');
    case 'SET NULL':
      return pickText(
        '置空（仅可空字段）',
        onDelete ? 'ON DELETE SET NULL' : 'ON UPDATE SET NULL',
      );
    case 'RESTRICT':
      return pickText(
        '限制（有子行时拒绝）',
        onDelete ? 'ON DELETE RESTRICT' : 'ON UPDATE RESTRICT',
      );
    default:
      return action;
  }
}

/// 「表.字段」的可读路径；参数是标识符（数据），不做翻译。
String erColumnPath(String table, String column) => '$table.$column';

/// 中间表提示里的引用行预览：本地列 → 引用表.引用列。
String erJunctionTarget(String column, String refTable, String refColumn) =>
    '$column → $refTable.$refColumn';

/// 建议关系的完整标签：建议：a.b → c.d。
String erSuggestionLabel(ErRelation relation) =>
    pickText('建议：', 'Suggested: ') + relation.displayLabel;

/// 建议关系的推导原因（帮助对话框与 hover tooltip 共用）。
String erSuggestionReason(ErRelation relation) {
  final column = relation.localColumn;
  final base = suggestedForeignKeyBase(column) ?? column;
  final target = relation.refTable;
  final keyColumn = relation.refColumn;
  return pickText(
    '列名 $column 以 _id / Id 结尾，基名 $base 匹配到表 $target（x / xs / xes），$keyColumn 是它的单列主键。',
    'Column $column ends with _id / Id; the base name $base matches table $target (x / xs / xes), and $keyColumn is its single-column primary key.',
  );
}

/// 建议关系的完整悬浮提示：建议：a.b → c.d（原因）。
String erSuggestionTooltip(ErRelation relation) {
  final label = erSuggestionLabel(relation);
  final reason = erSuggestionReason(relation);
  return pickText('$label（$reason）', '$label ($reason)');
}

/// 外键前置校验问题的中英文案（含具体表 / 列名）。
String erFkIssueMessage(ErFkIssue issue) {
  final localTable = issue.localTable;
  final localColumn = issue.localColumn;
  final refTable = issue.refTable;
  final refColumn = issue.refColumn;
  switch (issue.kind) {
    case ErFkIssueKind.localTableNoPrimary:
      return pickText(
        '表 $localTable 没有主键，无法创建外键；请先给该表设置主键。',
        'Table $localTable has no primary key, so a foreign key cannot be created; set a primary key first.',
      );
    case ErFkIssueKind.refTableNoPrimary:
      return pickText(
        '被引用表 $refTable 没有主键，无法作为外键目标；请先给该表设置主键。',
        'Referenced table $refTable has no primary key and cannot be a foreign key target; set a primary key first.',
      );
    case ErFkIssueKind.refColumnNotUnique:
      return pickText(
        '目标列 $refTable.$refColumn 不是主键或单列唯一列，数据库不允许作为外键引用；'
            '请先把该列设为 PRIMARY KEY 或 UNIQUE，或改引用它的主键列。',
        'Target column $refTable.$refColumn is not a primary key or single-column unique key and cannot be referenced; '
            'make it PRIMARY KEY / UNIQUE, or reference its primary key instead.',
      );
    case ErFkIssueKind.typeIncompatible:
      return pickText(
        '类型不一致：本地列 $localTable.$localColumn（${issue.localType}）与目标列 '
            '$refTable.$refColumn（${issue.refType}）类型不兼容。',
        'Type mismatch: local column $localTable.$localColumn (${issue.localType}) and target column '
            '$refTable.$refColumn (${issue.refType}) are not compatible.',
      );
  }
}

/// 关系创建被本地前置校验阻止时的对话框；回调非空时提供「返回工作表与字段修改」。
Future<void> showForeignKeyBlockedDialog(
  BuildContext context, {
  required String message,
  VoidCallback? onRequestEditFields,
}) {
  return showAppModal<void>(
    context: context,
    title: pickText('无法创建外键', 'Cannot create the foreign key'),
    builder: (context) => AlertBox(message),
    actions: <Widget>[
      Builder(
        builder: (context) =>
            Btn('关闭', onPressed: () => Navigator.of(context).pop()),
      ),
      if (onRequestEditFields != null)
        Builder(
          builder: (context) => Btn(
            '返回工作表与字段修改',
            key: const ValueKey('er-back-to-fields'),
            primary: true,
            onPressed: () {
              Navigator.of(context).pop();
              onRequestEditFields();
            },
          ),
        ),
    ],
  );
}

/// E-R 关系设计器。
///
/// 公开接口由 §5.1 固定（导入向导第 5 步与快速建表向导第 4 步都依赖它）：
/// [database] 是当前数据库 / 模式，[initialTables] 是打开时预置加入的表，
/// [onChanged] 在关系变化（创建 / 删除 / 建中间表）后回调，[maxTables] 是画布
/// 上限（默认 10），[height] 决定嵌入高度，[compact] 让向导内嵌更紧凑。
///
/// [onRequestEditFields] 非空时（快速建表向导第 4 步会传）：关系创建失败 / 被
/// 前置校验阻止 / SQLite 不支持 ALTER 的提示里都会多出一个「返回工作表与字段
/// 修改」按钮，点击后关闭提示并调用它，让宿主回到字段编辑步骤。
class RelationDesigner extends StatefulWidget {
  const RelationDesigner({
    super.key,
    required this.database,
    this.initialTables = const <String>[],
    this.onChanged,
    this.maxTables = 10,
    this.height = 460,
    this.compact = false,
    this.onRequestEditFields,
  });

  final String database;
  final List<String> initialTables;
  final Future<void> Function()? onChanged;
  final int maxTables;
  final double height;
  final bool compact;
  final VoidCallback? onRequestEditFields;

  @override
  State<RelationDesigner> createState() => _RelationDesignerState();
}

class _RelationDesignerState extends State<RelationDesigner> {
  // ---------------------------------------------------------------- 数据状态
  bool _loading = true;
  String? _loadError;

  /// 已加入画布的表（按加入顺序）。
  List<ErTable> _tables = <ErTable>[];

  /// 每张已加入表自己的外键（本表是 local 一侧）；画布只显示两端都加入的边。
  final Map<String, List<ErRelation>> _localRelations =
      <String, List<ErRelation>>{};

  /// builderSchema 的原始表对象（加入新表 / 兜底解析 / 中间表重名检查用）。
  Map<String, Map<String, dynamic>> _schemaRows =
      <String, Map<String, dynamic>>{};

  /// 节点左上角（画布坐标，用户拖动后保存到这里）。
  final Map<String, Offset> _positions = <String, Offset>{};

  // ------------------------------------------------------------ 画布交互状态
  final GlobalKey _canvasKey = GlobalKey();
  double _layoutWidth = 0;
  _ConnectDrag? _drag;
  bool _dotPressed = false;
  String? _draggingNode;
  Offset? _nodeDragLast;
  int? _hoverRelation;

  /// 当前 hover 的多对多连线 key（"m2m:中间表名"）；hover 时才显示它的标签。
  String? _hoverM2MKey;

  /// 当前 hover 的建议虚线 key（关系 key）；hover 时高亮虚线并展开完整标签。
  String? _hoverSuggestionKey;
  String? _hoverDot;

  /// 用户手动拖过位置的表：自动布局 / 自动带入时保留这些坐标。
  final Set<String> _userMoved = <String>{};

  /// 每张表里「单列唯一」的字段（单列主键 / 单列唯一索引），用于判断被引用列
  /// 能不能独立作为外键目标；同时决定「双方都不唯一 → 默认建议中间表」。
  final Map<String, Set<String>> _uniqueColumns = <String, Set<String>>{};

  /// 最近一次自动带入的关联表（顶部提示 + 撤销）。
  List<String> _autoAdded = <String>[];

  /// 用户手动移除 / 撤销自动加入过的表，不再自动带回。
  final Set<String> _userRemoved = <String>{};

  /// 被折叠的中间表（节点隐藏，只保留两端多对多连线）。
  final Set<String> _collapsedJunctions = <String>{};

  /// 当前选中（点击打开过详情）的关系 key，画布上高亮。
  String? _selectedRelationKey;

  /// 批量建立建议外键时的错误 / 提示（就地显示在工具栏下方）。
  String? _actionError;
  bool _applyingSuggestions = false;
  bool _expanding = false;

  /// 中间表识别 / 建议关系的缓存版本号：表或外键变化时 +1，避免画布每帧或
  /// 每次 hover 都重新扫描一遍关系图。
  int _graphRevision = 0;
  int _junctionCacheRevision = -1;
  Map<String, ErJunctionInfo>? _junctionCache;
  int _suggestionCacheRevision = -1;
  List<ErRelation>? _suggestionCache;

  /// 表 / 外键结构发生变化后调用（必须在 setState 里或之后再 build 之前）。
  void _bumpGraph() => _graphRevision++;

  bool get _isSqlite => AppState.instance.isSqlite;

  ErDriver get _driver => ErDriver.fromName(AppState.instance.driver);

  ErNodeMetrics get _metrics => ErNodeMetrics.forMode(widget.compact);

  /// 拖动时锁住画布滚动，避免滚动手势和拖拽抢指针。
  bool get _dragLocked => _drag != null || _dotPressed || _draggingNode != null;

  Set<String> get _addedNames => <String>{for (final t in _tables) t.name};

  /// 画布上实际显示的表（折叠的中间表节点不显示）。
  List<ErTable> get _visibleTables => <ErTable>[
    for (final table in _tables)
      if (!_collapsedJunctions.contains(table.name)) table,
  ];

  Set<String> get _visibleNames => <String>{
    for (final table in _visibleTables) table.name,
  };

  /// 中间表识别（基于全部已加入表，折叠与否都算，这样连线不会消失）。
  ///
  /// 结果按 [_graphRevision] 缓存：5 张表的画布上每个节点表头都要读它，
  /// 不缓存时一次 hover 重绘会重复扫描 5~6 次关系图。
  Map<String, ErJunctionInfo> get _junctionInfos {
    final cached = _junctionCache;
    if (cached != null && _junctionCacheRevision == _graphRevision) {
      return cached;
    }
    final computed = detectJunctionTables(
      relationsByTable: _localRelations,
      tables: _addedNames,
    );
    _junctionCache = computed;
    _junctionCacheRevision = _graphRevision;
    return computed;
  }

  List<ErManyToManyLink> get _m2mLinks => manyToManyLinks(_junctionInfos);

  /// 两端都可见的外键（去重后）。
  List<ErRelation> get _relations {
    final visible = _visibleNames;
    final out = <ErRelation>[];
    final seen = <String>{};
    for (final table in _visibleTables) {
      final local = _localRelations[table.name] ?? const <ErRelation>[];
      for (final relation in local) {
        if (!visible.contains(relation.refTable)) continue;
        if (!seen.add(relation.key)) continue;
        out.add(relation);
      }
    }
    return out;
  }

  /// 按列名推导的建议关系（虚线，尚未写库）；默认最多 20 条，防止宽表把画布铺满。
  List<ErRelation> get _suggestions {
    final cached = _suggestionCache;
    if (cached != null && _suggestionCacheRevision == _graphRevision) {
      return cached;
    }
    final computed = suggestRelations(
      tables: _tables,
      relationsByTable: _localRelations,
    );
    _suggestionCache = computed;
    _suggestionCacheRevision = _graphRevision;
    return computed;
  }

  ErCanvasLayout get _layout => ErCanvasLayout(
    tables: _visibleTables,
    positions: _positions,
    metrics: _metrics,
  );

  @override
  void initState() {
    super.initState();
    _loadInitial();
  }

  // ---------------------------------------------------------------- 数据加载

  /// builderSchema 取表 / 列 / 已有外键，再对 [initialTables] 逐张读 structure
  /// 拿真实约束名与引用动作。
  Future<void> _loadInitial() async {
    setState(() {
      _loading = true;
      _loadError = null;
      _autoAdded = <String>[];
      _collapsedJunctions.clear();
      _selectedRelationKey = null;
      _actionError = null;
    });
    try {
      final schema = await Api.instance.builderSchema(widget.database);
      final rows = erRowsOf(schema['tables']);
      final schemaRows = <String, Map<String, dynamic>>{
        for (final row in rows) erStringOf(row['name']): row,
      };
      final wanted = <String>[];
      for (final raw in widget.initialTables) {
        final name = raw.trim();
        if (name.isEmpty || wanted.contains(name)) continue;
        if (wanted.length >= widget.maxTables) break;
        if (!schemaRows.containsKey(name)) continue; // 表可能已被删除
        wanted.add(name);
      }
      final tables = <ErTable>[];
      final relations = <String, List<ErRelation>>{};
      final unique = <String, Set<String>>{};
      for (final name in wanted) {
        final loaded = await _readTable(name, schemaRows[name]!);
        tables.add(loaded.table);
        relations[name] = loaded.relations;
        unique[name] = loaded.uniqueColumns;
      }
      if (!mounted) return;
      _schemaRows = schemaRows;
      setState(() {
        _tables = tables;
        _localRelations
          ..clear()
          ..addAll(relations);
        _uniqueColumns
          ..clear()
          ..addAll(unique);
        _positions.clear(); // 首帧用分层布局
        _userMoved.clear();
        _loading = false;
        _bumpGraph();
      });
      // seed 表（导入 / 快速建表）加入后，自动带入已有外键关联的父 / 子表。
      await _expandRelated();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.toString();
        _loading = false;
      });
    }
  }

  /// 读一张表：优先 structure（真实约束名 / 动作），失败时退回 builderSchema。
  Future<_LoadedTable> _readTable(
    String name,
    Map<String, dynamic> schemaRow,
  ) async {
    try {
      final structure = await Api.instance.structure(widget.database, name);
      final table = ErTable.fromStructure(name, structure);
      final relations = ErRelation.fromStructure(name, structure);
      final unique = erUniqueColumns(structure);
      if (table.columns.isEmpty) {
        return _LoadedTable(
          ErTable.fromSchema(<String, dynamic>{'name': name, ...schemaRow}),
          relations.isEmpty
              ? ErRelation.fromSchema(name, schemaRow)
              : relations,
          unique,
        );
      }
      return _LoadedTable(table, relations, unique);
    } catch (_) {
      return _LoadedTable(
        ErTable.fromSchema(<String, dynamic>{'name': name, ...schemaRow}),
        ErRelation.fromSchema(name, schemaRow),
        const <String>{},
      );
    }
  }

  /// 重新读一张表的列与外键（创建 / 删除外键、建中间表后调用）。
  Future<void> _reloadTable(String tableName) async {
    final row = _schemaRows[tableName];
    final loaded = await _readTable(
      tableName,
      row ?? <String, dynamic>{'name': tableName},
    );
    if (!mounted) return;
    setState(() {
      _tables = <ErTable>[
        for (final table in _tables)
          if (table.name == tableName) loaded.table else table,
      ];
      _localRelations[tableName] = loaded.relations;
      _uniqueColumns[tableName] = loaded.uniqueColumns;
      _bumpGraph();
    });
  }

  // ---------------------------------------------------------------- 表管理

  /// 分层布局用的边：真实外键 + 建议关系 + 中间表多对多（父 → 子方向）。
  List<ErRelation> _layoutRelations() => <ErRelation>[
    ..._relations,
    ..._suggestions,
    for (final link in _m2mLinks) link.syntheticRelation,
  ];

  Map<String, Offset> _layeredPositions(double width) => layeredErLayout(
    _tables,
    _layoutRelations(),
    viewportWidth: width,
    metrics: _metrics,
  );

  /// 首次加载 / 自动带入后重新分层布局；用户拖动过的节点保留原坐标。
  void _relayout({required bool force, required double width}) {
    if (_tables.isEmpty) return;
    final computed = _layeredPositions(width);
    for (final table in _tables) {
      final existing = _positions[table.name];
      final keep =
          !force && existing != null && _userMoved.contains(table.name);
      _positions[table.name] = keep
          ? existing
          : (computed[table.name] ?? existing ?? const Offset(24, 24));
    }
    if (force) _userMoved.clear();
  }

  /// 补上新加入节点的位置并清掉已移除节点；画布每帧布局时调用。
  void _ensurePositions(double width) {
    if (_tables.isEmpty) return;
    final missing = _tables.any((table) => !_positions.containsKey(table.name));
    if (_positions.isEmpty || missing) {
      _relayout(force: false, width: width);
    }
    final names = <String>{for (final table in _tables) table.name};
    _positions.removeWhere((key, _) => !names.contains(key));
  }

  void _autoLayout() {
    final width = _layoutWidth > 0
        ? _layoutWidth
        : (widget.compact ? 660.0 : 860.0);
    setState(() => _relayout(force: true, width: width));
  }

  ErTable? _tableNamed(String name) {
    for (final table in _tables) {
      if (table.name == name) return table;
    }
    return null;
  }

  Future<void> _openAddTables() async {
    final added = <String>{for (final table in _tables) table.name};
    // 已加入的表也列出来（灰显 + 已加入），让用户看到画布里已经有哪几张。
    final choices = <_TableChoice>[
      for (final entry in _schemaRows.entries)
        _TableChoice(
          entry.key,
          erRowsOf(entry.value['columns']).length,
          added: added.contains(entry.key),
        ),
    ]..sort((a, b) => a.name.compareTo(b.name));
    final remaining = widget.maxTables - _tables.length;
    final key = GlobalKey<_AddTablesDialogState>();
    final selected = await showAppModal<List<String>>(
      context: context,
      title: '添加表',
      builder: (context) =>
          _AddTablesDialog(key: key, choices: choices, remaining: remaining),
      actions: <Widget>[
        Builder(
          builder: (context) =>
              Btn('取消', onPressed: () => Navigator.of(context).pop()),
        ),
        Builder(
          builder: (context) => Btn(
            '加入',
            key: const ValueKey('er-picker-join'),
            primary: true,
            onPressed: () =>
                Navigator.of(context)
                    .pop(key.currentState?.selected ?? const <String>[]),
          ),
        ),
      ],
    );
    if (selected == null || selected.isEmpty) return;
    await _addTables(selected);
  }

  Future<void> _addTables(List<String> names) async {
    final added = <String>{for (final table in _tables) table.name};
    final wanted = <String>[];
    for (final name in names) {
      if (_tables.length + wanted.length >= widget.maxTables) break;
      if (added.contains(name) || wanted.contains(name)) continue;
      wanted.add(name);
    }
    if (wanted.isEmpty) return;
    final loadedTables = <ErTable>[];
    final loadedRelations = <String, List<ErRelation>>{};
    final loadedUnique = <String, Set<String>>{};
    for (final name in wanted) {
      final row = _schemaRows[name] ?? <String, dynamic>{'name': name};
      final loaded = await _readTable(name, row);
      loadedTables.add(loaded.table);
      loadedRelations[name] = loaded.relations;
      loadedUnique[name] = loaded.uniqueColumns;
      // 用户重新手动加入曾经自动移除的表，说明这次是他主动要的。
      _userRemoved.remove(name);
    }
    if (!mounted) return;
    setState(() {
      _tables = <ErTable>[..._tables, ...loadedTables];
      _localRelations.addAll(loadedRelations);
      _uniqueColumns.addAll(loadedUnique);
      for (final name in wanted) {
        _autoAdded.remove(name);
      }
      _bumpGraph();
    });
    await _expandRelated();
  }

  void _removeTable(String name) {
    final kept = <ErTable>[
      for (final table in _tables)
        if (table.name != name) table,
    ];
    setState(() {
      _tables = kept;
      _localRelations.remove(name);
      _uniqueColumns.remove(name);
      _positions.remove(name);
      _collapsedJunctions.remove(name);
      _autoAdded.remove(name);
      // 用户手动移除过的表不再自动加回；选中的关系也可能因此消失。
      _userRemoved.add(name);
      _userMoved.remove(name);
      _selectedRelationKey = null;
      _bumpGraph();
    });
  }

  // ------------------------------------------------------- 自动带入关联表

  /// 「表 → 有外键关联的表名列表」（父表 + 子表两个方向，来自 builderSchema）。
  Map<String, List<String>> _buildRelatedMap() {
    final related = <String, List<String>>{};
    void link(String a, String b) {
      if (a == b) return;
      final list = related.putIfAbsent(a, () => <String>[]);
      if (!list.contains(b)) list.add(b);
    }

    for (final entry in _schemaRows.entries) {
      for (final row in erRowsOf(entry.value['foreign_keys'])) {
        final ref = erStringOf(row['ref_table']);
        if (ref.isEmpty || !_schemaRows.containsKey(ref)) continue;
        link(entry.key, ref);
        link(ref, entry.key);
      }
    }
    return related;
  }

  /// 沿已有外键自动带入关联表（最多到画布上限），并在顶部显示提示。
  Future<void> _expandRelated() async {
    if (_expanding || _loading || _loadError != null) return;
    final added = _addedNames;
    if (added.length >= widget.maxTables) return;
    final candidates = expandRelatedTableNames(
      added: added,
      related: _buildRelatedMap(),
      excluded: _userRemoved,
      maxTables: widget.maxTables,
    );
    if (candidates.isEmpty) return;
    _expanding = true;
    try {
      final loadedTables = <ErTable>[];
      final loadedRelations = <String, List<ErRelation>>{};
      final loadedUnique = <String, Set<String>>{};
      final accepted = <String>[];
      for (final name in candidates) {
        final row = _schemaRows[name];
        if (row == null) continue;
        final loaded = await _readTable(name, row);
        loadedTables.add(loaded.table);
        loadedRelations[name] = loaded.relations;
        loadedUnique[name] = loaded.uniqueColumns;
        accepted.add(name);
      }
      if (!mounted || accepted.isEmpty) return;
      setState(() {
        _tables = <ErTable>[..._tables, ...loadedTables];
        _localRelations.addAll(loadedRelations);
        _uniqueColumns.addAll(loadedUnique);
        _autoAdded = accepted;
        _bumpGraph();
      });
    } finally {
      _expanding = false;
    }
  }

  /// 撤销最近一次自动加入：移除这些表，并记住不再自动带回。
  void _undoAutoAdded() {
    final remove = <String>{..._autoAdded};
    if (remove.isEmpty) return;
    setState(() {
      _tables = <ErTable>[
        for (final table in _tables)
          if (!remove.contains(table.name)) table,
      ];
      for (final name in remove) {
        _localRelations.remove(name);
        _uniqueColumns.remove(name);
        _positions.remove(name);
        _collapsedJunctions.remove(name);
        _userMoved.remove(name);
      }
      _userRemoved.addAll(remove);
      _autoAdded = <String>[];
      _selectedRelationKey = null;
      _bumpGraph();
    });
  }

  // ------------------------------------------------------- 建议关系（虚线）

  /// 批量（或单条）建立按列名推导的建议外键。
  ///
  /// 按钮/建议线在 SQLite 下也保持可点：点击弹明确说明（而不是静默禁用）。
  Future<void> _applySuggestions({ErRelation? only}) async {
    if (_applyingSuggestions) return;
    final targets = <ErRelation>[if (only != null) only else ..._suggestions];
    if (targets.isEmpty) return;
    // 先本地前置校验，不满足就报错（不让数据库先失败）。
    for (final suggestion in targets) {
      final issue = _validateSuggestion(suggestion);
      if (issue != null) {
        await _showBlocked(issue);
        return;
      }
    }
    if (_isSqlite) {
      await _showSqliteAlterFkNotice();
      return;
    }
    setState(() {
      _applyingSuggestions = true;
      _actionError = null;
    });
    final appliedTables = <String>{};
    try {
      for (final suggestion in targets) {
        final existingNames = <String>{
          for (final relation
              in _localRelations[suggestion.localTable] ?? const <ErRelation>[])
            if (relation.name.isNotEmpty) relation.name,
        };
        await Api.instance.alterTable(
          widget.database,
          suggestion.localTable,
          <String, dynamic>{
            'add_foreign_keys': <Map<String, dynamic>>[
              foreignKeyPayload(
                name: uniqueFkName(
                  suggestion.localTable,
                  suggestion.localColumn,
                  existingNames,
                ),
                localColumn: suggestion.localColumn,
                refTable: suggestion.refTable,
                refColumn: suggestion.refColumn,
              ),
            ],
          },
        );
        appliedTables.add(suggestion.localTable);
      }
    } catch (error) {
      final prefix = pickText(
        '建立建议外键失败：',
        'Failed to create the suggested foreign key: ',
      );
      final detail = error.toString();
      if (mounted) setState(() => _actionError = '$prefix$detail');
    } finally {
      for (final name in appliedTables) {
        await _reloadTable(name);
      }
      if (mounted) {
        setState(() => _applyingSuggestions = false);
        if (appliedTables.isNotEmpty) await widget.onChanged?.call();
      }
    }
  }

  /// 单条建议关系的前置校验（两端表都在画布上才校验）。
  ErFkIssue? _validateSuggestion(ErRelation suggestion) {
    final localTable = _tableNamed(suggestion.localTable);
    final refTable = _tableNamed(suggestion.refTable);
    if (localTable == null || refTable == null) return null;
    return validateForeignKeyCandidate(
      localTable: localTable,
      localColumn: suggestion.localColumn,
      refTable: refTable,
      refColumn: suggestion.refColumn,
      refUniqueColumns: _uniqueColumns[refTable.name] ?? const <String>{},
    );
  }

  /// 关系创建被本地前置校验阻止：弹带「返回工作表与字段修改」的错误框。
  Future<void> _showBlocked(ErFkIssue issue) => showForeignKeyBlockedDialog(
    context,
    message: erFkIssueMessage(issue),
    onRequestEditFields: widget.onRequestEditFields,
  );

  /// SQLite 下点建议外键时的明确说明（可点但无法 ALTER，不是静默失败）。
  Future<void> _showSqliteAlterFkNotice() async {
    await showAppModal<void>(
      context: context,
      title: pickText(
        'SQLite 不支持用 ALTER 新增外键',
        'SQLite does not support adding foreign keys with ALTER TABLE',
      ),
      builder: (context) => Text(
        pickText(
          'SQLite 不支持用 ALTER TABLE 给已有表新增外键，所以建议关系只能查看。'
              '如需外键，请在「从文件建表」时直接在建表语句里带上外键，或重建该表。',
          'SQLite cannot add foreign keys to an existing table with ALTER TABLE, '
              'so suggested relations are read-only here. To create foreign keys, '
              'include them when the table is created with "Create tables from file", '
              'or recreate the table.',
        ),
        style: kSmallMuted,
      ),
      actions: <Widget>[
        Builder(
          builder: (context) =>
              Btn('关闭', onPressed: () => Navigator.of(context).pop()),
        ),
        if (widget.onRequestEditFields != null)
          Builder(
            builder: (context) => Btn(
              '返回工作表与字段修改',
              key: const ValueKey('er-back-to-fields'),
              primary: true,
              onPressed: () {
                Navigator.of(context).pop();
                widget.onRequestEditFields!();
              },
            ),
          ),
      ],
    );
  }

  /// 建议关系推导帮助：规则说明 + 当前每条建议的原因。
  Future<void> _showSuggestionHelp() async {
    final suggestions = _suggestions;
    await showAppModal<void>(
      context: context,
      title: pickText('建议关系是怎么推导的？', 'How are suggested relations derived?'),
      wide: true,
      builder: (context) => _SuggestionHelpDialog(suggestions: suggestions),
      actions: <Widget>[
        Builder(
          builder: (context) =>
              Btn('关闭', onPressed: () => Navigator.of(context).pop()),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 关系增删

  Future<void> _beginCreateForeignKey({
    required ErTable localTable,
    required String localColumn,
    required ErTable refTable,
    required String refColumn,
  }) async {
    if (refTable.columns.isEmpty) return;
    // 0) 前置条件校验：不满足就在本地报错，不发 SQL。
    final issue = validateForeignKeyCandidate(
      localTable: localTable,
      localColumn: localColumn,
      refTable: refTable,
      refColumn: refColumn,
      refUniqueColumns: _uniqueColumns[refTable.name] ?? const <String>{},
    );
    if (issue != null) {
      await _showBlocked(issue);
      return;
    }
    final differentTables = localTable.name != refTable.name;
    // 1) 两表之间已经有中间表：多对多关系已经存在，提示不要重复创建。
    if (differentTables) {
      final existingJunction = _junctionConnecting(
        localTable.name,
        refTable.name,
      );
      if (existingJunction != null) {
        final direct = await _warnExistingJunction(existingJunction);
        if (!direct || !mounted) return;
      }
    }
    // 2) 两表之间已有直接关系 → 默认改为创建中间表（多对多）。
    if (differentTables &&
        hasRelationBetween(_relations, localTable.name, refTable.name)) {
      final choice = await _offerJunction(
        localTable,
        refTable,
        reason: _JunctionReason.existingRelation,
      );
      if (choice != _JunctionChoice.direct) return;
      if (!mounted) return;
    }
    // 3) 双方连接列都不唯一：直接外键的引用列可能不合法，默认建议中间表。
    final localUnique = _isUniqueColumn(localTable, localColumn);
    final refUnique = _isUniqueColumn(refTable, refColumn);
    if (differentTables && !localUnique && !refUnique) {
      final choice = await _offerJunction(
        localTable,
        refTable,
        reason: _JunctionReason.notUnique,
      );
      if (choice != _JunctionChoice.direct) return;
      if (!mounted) return;
    }
    final existingNames = <String>{
      for (final relation
          in _localRelations[localTable.name] ?? const <ErRelation>[])
        if (relation.name.isNotEmpty) relation.name,
    };
    final key = GlobalKey<_NewForeignKeyDialogState>();
    final created = await showAppModal<bool>(
      context: context,
      title: '新建外键关系',
      builder: (context) => _NewForeignKeyDialog(
        key: key,
        localTable: localTable,
        refTable: refTable,
        initialLocalColumn: localColumn,
        initialRefColumn: refColumn,
        initialName: uniqueFkName(localTable.name, localColumn, existingNames),
        driver: _driver,
        existingTableNames: <String>{..._schemaRows.keys},
        onCreate: (payload) => _createForeignKey(localTable.name, payload),
        onCreateJunction: _createJunction,
        onRequestEditFields: widget.onRequestEditFields,
        validate: (localColumn, refColumn) {
          final issue = validateForeignKeyCandidate(
            localTable: localTable,
            localColumn: localColumn,
            refTable: refTable,
            refColumn: refColumn,
            refUniqueColumns: _uniqueColumns[refTable.name] ?? const <String>{},
          );
          return issue == null ? null : erFkIssueMessage(issue);
        },
      ),
      actions: <Widget>[
        Builder(
          builder: (context) =>
              Btn('取消', onPressed: () => Navigator.of(context).pop(false)),
        ),
        Builder(
          builder: (context) => Btn(
            '创建',
            primary: true,
            onPressed: () => key.currentState?.submit(),
          ),
        ),
      ],
    );
    if (created == true && mounted) await widget.onChanged?.call();
  }

  /// 某张表的某个字段是否单列唯一（structure 读取失败时用单列主键兜底）。
  bool _isUniqueColumn(ErTable table, String column) {
    final unique = _uniqueColumns[table.name];
    if (unique != null && unique.isNotEmpty) return unique.contains(column);
    final primary = table.primaryColumns;
    return primary.length == 1 && primary.first.name == column;
  }

  /// 连接 [a] 与 [b] 的中间表（没有则返回 null）。
  ErJunctionInfo? _junctionConnecting(String a, String b) {
    for (final info in _junctionInfos.values) {
      if (info.connects(a, b)) return info;
    }
    return null;
  }

  /// 两表之间已经有中间表时的提示；返回 true 表示用户仍然要直接添加外键。
  Future<bool> _warnExistingJunction(ErJunctionInfo info) async {
    final junction = info.junctionTable;
    final message = pickText(
      '已存在中间表 $junction 表示这两张表的多对多关系，不需要再添加重复外键。',
      'Junction table $junction already represents the many-to-many relation between these tables; adding another foreign key is unnecessary.',
    );
    final result = await showAppModal<bool>(
      context: context,
      title: '两表之间已有中间表',
      builder: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[Text(message, style: kSmallMuted)],
      ),
      actions: <Widget>[
        Builder(
          builder: (context) =>
              Btn('取消', onPressed: () => Navigator.of(context).pop(false)),
        ),
        Builder(
          builder: (context) =>
              Btn('仍然直接添加', onPressed: () => Navigator.of(context).pop(true)),
        ),
      ],
    );
    return result == true;
  }

  Future<void> _createForeignKey(
    String localTable,
    Map<String, dynamic> payload,
  ) async {
    await Api.instance.alterTable(
      widget.database,
      localTable,
      <String, dynamic>{
        'add_foreign_keys': <Map<String, dynamic>>[payload],
      },
    );
    await _reloadTable(localTable);
  }

  Future<void> _deleteForeignKey(String localTable, String name) async {
    await Api.instance.alterTable(
      widget.database,
      localTable,
      <String, dynamic>{
        'drop_foreign_keys': <String>[name],
      },
    );
    await _reloadTable(localTable);
  }

  /// 两表已有关系 / 双方列都不唯一时的中间表提示；返回用户的选择。
  Future<_JunctionChoice> _offerJunction(
    ErTable localTable,
    ErTable refTable, {
    required _JunctionReason reason,
  }) async {
    final existingNames = <String>{..._schemaRows.keys};
    final plan = planJunction(
      driver: _driver,
      localTable: localTable,
      refTable: refTable,
      existingTableNames: existingNames,
    );
    if (plan == null) {
      // 缺主键时无法建中间表，退回普通外键创建（数据库会给出具体错误）。
      return _JunctionChoice.direct;
    }
    final key = GlobalKey<_JunctionDialogState>();
    final result = await showAppModal<String>(
      context: context,
      title: reason == _JunctionReason.notUnique ? '建议创建中间表' : '两表之间已存在关系',
      builder: (context) => _JunctionDialog(
        key: key,
        plan: plan,
        driver: _driver,
        localTable: localTable,
        refTable: refTable,
        existingTableNames: existingNames,
        reason: reason,
        onCreate: _createJunction,
        onRequestEditFields: widget.onRequestEditFields,
      ),
      actions: <Widget>[
        Builder(
          builder: (context) =>
              Btn('取消', onPressed: () => Navigator.of(context).pop('cancel')),
        ),
        Builder(
          builder: (context) => Btn(
            '创建',
            primary: true,
            onPressed: () => key.currentState?.submit(),
          ),
        ),
      ],
    );
    if (result == 'junction') {
      if (mounted) await widget.onChanged?.call();
      return _JunctionChoice.junction;
    }
    if (result == 'direct') return _JunctionChoice.direct;
    return _JunctionChoice.cancel;
  }

  /// 建中间表（createTable 一次带 id 主键自增 + 两列 + 两个内联外键；SQLite
  /// 也支持这种建表方式），成功后把新表加入画布。
  Future<void> _createJunction(ErJunctionPlan plan) async {
    await Api.instance.createTable(widget.database, plan.createTableBody());
    Map<String, dynamic>? row;
    try {
      final schema = await Api.instance.builderSchema(widget.database);
      final rows = erRowsOf(schema['tables']);
      _schemaRows = <String, Map<String, dynamic>>{
        for (final item in rows) erStringOf(item['name']): item,
      };
      row = _schemaRows[plan.name];
    } catch (_) {
      // 刷新 schema 失败不影响建表结果，下面用计划里的定义兜底显示。
    }
    var table = ErTable(name: plan.name, columns: plan.columns);
    var relations = plan.relations;
    var unique = <String>{plan.idColumn};
    if (row != null) {
      final loaded = await _readTable(plan.name, row);
      table = loaded.table;
      relations = loaded.relations;
      unique = loaded.uniqueColumns;
    }
    if (!mounted) return;
    setState(() {
      _tables = <ErTable>[
        for (final existing in _tables)
          if (existing.name != plan.name) existing,
        table,
      ];
      _localRelations[plan.name] = relations;
      _uniqueColumns[plan.name] = unique;
      _userRemoved.remove(plan.name);
      _autoAdded.remove(plan.name);
      _collapsedJunctions.remove(plan.name);
      _selectedRelationKey = null;
      _bumpGraph();
    });
  }

  Future<void> _openRelationDialog(ErRelation relation) async {
    final canDelete = !_isSqlite && relation.name.isNotEmpty;
    final key = GlobalKey<_RelationDialogState>();
    final deleted = await showAppModal<bool>(
      context: context,
      title: '外键关系',
      builder: (context) => _RelationDialog(
        key: key,
        relation: relation,
        canDelete: canDelete,
        isSqlite: _isSqlite,
        onDelete: () => _deleteForeignKey(relation.localTable, relation.name),
      ),
      actions: <Widget>[
        Builder(
          builder: (context) =>
              Btn('关闭', onPressed: () => Navigator.of(context).pop(false)),
        ),
        Builder(
          builder: (context) => Btn(
            '删除关系',
            danger: true,
            onPressed: canDelete
                ? () => key.currentState?.deleteRelation()
                : null,
          ),
        ),
      ],
    );
    if (deleted == true && mounted) await widget.onChanged?.call();
  }

  // -------------------------------------------------------------- 画布交互

  Offset _toCanvas(Offset globalPosition) {
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return globalPosition;
    return box.globalToLocal(globalPosition);
  }

  void _startNodeDrag(String table, Offset globalPosition) {
    setState(() {
      _draggingNode = table;
      _nodeDragLast = globalPosition;
    });
  }

  void _moveNodeDrag(String table, Offset globalPosition) {
    if (_draggingNode != table) return;
    final last = _nodeDragLast;
    if (last == null) return;
    final delta = globalPosition - last;
    final position = _positions[table] ?? const Offset(24, 24);
    setState(() {
      _userMoved.add(table);
      _nodeDragLast = globalPosition;
      _positions[table] = Offset(
        math.max(0, position.dx + delta.dx),
        math.max(0, position.dy + delta.dy),
      );
    });
  }

  void _endNodeDrag() {
    if (_draggingNode == null) return;
    setState(() {
      _draggingNode = null;
      _nodeDragLast = null;
    });
  }

  void _startConnect(
    ErTable table,
    int columnIndex,
    Offset globalPosition, {
    required bool fromLeft,
  }) {
    final local = _toCanvas(globalPosition);
    final columnName = table.columns[columnIndex].name;
    final layout = _layout;
    final source = fromLeft
        ? (layout.leftConnectionPoint(table.name, columnName) ?? local)
        : (layout.connectionPoint(table.name, columnName) ?? local);
    setState(() {
      _dotPressed = true;
      _drag = _ConnectDrag(
        table: table.name,
        columnIndex: columnIndex,
        source: source,
        point: local,
        fromLeft: fromLeft,
      );
    });
  }

  void _updateConnect(Offset globalPosition) {
    final drag = _drag;
    if (drag == null) return;
    setState(() => _drag = drag.copyWith(point: _toCanvas(globalPosition)));
  }

  void _cancelConnect() {
    setState(() {
      _drag = null;
      _dotPressed = false;
    });
  }

  Future<void> _finishConnect() async {
    final drag = _drag;
    setState(() {
      _drag = null;
      _dotPressed = false;
    });
    if (drag == null || _isSqlite) return;
    final target = _layout.fieldAt(drag.point);
    if (target == null) return;
    final localTable = _tableNamed(drag.table);
    final targetTable = _tableNamed(target.table);
    if (localTable == null || targetTable == null) return;
    if (drag.columnIndex >= localTable.columns.length) return;
    if (target.columnIndex >= targetTable.columns.length) return;
    final localColumn = localTable.columns[drag.columnIndex].name;
    final targetColumn = targetTable.columns[target.columnIndex].name;
    if (localTable.name == targetTable.name && localColumn == targetColumn) {
      return;
    }
    await _beginCreateForeignKey(
      localTable: localTable,
      localColumn: localColumn,
      refTable: targetTable,
      refColumn: targetColumn,
    );
  }

  void _handleHover(
    Offset local,
    List<ErRelationCurve> curves,
    List<ErRelationCurve> suggestionCurves,
    List<ErRelationCurve> m2mCurves,
    List<ErManyToManyLink> m2mLinks,
  ) {
    final hit = hitTestRelationCurves(curves, local);
    int? suggestionHit;
    if (hit == null && suggestionCurves.isNotEmpty) {
      suggestionHit = hitTestRelationCurves(suggestionCurves, local);
    }
    int? m2mHit;
    if (hit == null && suggestionHit == null && m2mCurves.isNotEmpty) {
      m2mHit = hitTestRelationCurves(m2mCurves, local);
    }
    final suggestionKey = suggestionHit == null
        ? null
        : suggestionCurves[suggestionHit].relation.key;
    final m2mKey = m2mHit == null ? null : m2mLinks[m2mHit].key;
    if (hit != _hoverRelation ||
        suggestionKey != _hoverSuggestionKey ||
        m2mKey != _hoverM2MKey) {
      setState(() {
        _hoverRelation = hit;
        _hoverSuggestionKey = suggestionKey;
        _hoverM2MKey = m2mKey;
      });
    }
  }

  void _handleCanvasTap(
    Offset local,
    List<ErRelationCurve> curves,
    List<ErRelationCurve> suggestionCurves,
  ) {
    final hit = hitTestRelationCurves(curves, local);
    if (hit != null) {
      _selectRelation(curves[hit].relation);
      return;
    }
    // 点建议虚线 = 只建立这一条建议外键（SQLite 会给出说明）。
    if (suggestionCurves.isNotEmpty) {
      final suggestionHit = hitTestRelationCurves(suggestionCurves, local);
      if (suggestionHit != null) {
        _applySuggestions(only: suggestionCurves[suggestionHit].relation);
        return;
      }
    }
    if (_selectedRelationKey != null) {
      setState(() => _selectedRelationKey = null);
    }
  }

  /// 选中一条边（画布高亮 + 标签显示）并打开详情。
  void _selectRelation(ErRelation relation) {
    setState(() => _selectedRelationKey = relation.key);
    _openRelationDialog(relation);
  }

  // ------------------------------------------------------------------- 视图

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: Container(
        // 与 CardBox 一致的卡片外观；不用 CardBox 是因为画布需要 Expanded，
        // CardBox 的 Column 以 min 布局，内部的 Expanded 拿不到有界高度。
        margin: const EdgeInsets.only(bottom: 16),
        padding: EdgeInsets.all(widget.compact ? 10 : 14),
        decoration: BoxDecoration(
          color: AppColors.panel,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(AppMetrics.radiusCard),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _toolbar(),
            const SizedBox(height: 3),
            _legend(),
            if (_autoAdded.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              _autoAddedHint(),
            ],
            if (_actionError != null) ...<Widget>[
              const SizedBox(height: 6),
              _actionErrorBox(),
            ],
            if (_isSqlite) ...<Widget>[
              const SizedBox(height: 6),
              _sqliteHint(),
            ],
            const SizedBox(height: 6),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  /// 画布上方的图例：箭头方向（约束方 → 被约束方）+ 线型 / 颜色含义。
  Widget _legend() {
    const legendStyle = TextStyle(fontSize: 11);
    final muted = legendStyle.copyWith(color: AppColors.muted);
    return Tooltip(
      message: pickText(
        '箭头从「被约束」指向「约束」：被约束方是拥有外键列的子表，约束方是被引用主键的父表。',
        'The arrow points from the constrained side to the constraining side: the constrained side owns the foreign key column (child table), and the constraining side is the referenced primary key (parent table).',
      ),
      waitDuration: const Duration(milliseconds: 300),
      child: Wrap(
        key: const ValueKey('er-legend'),
        spacing: 6,
        runSpacing: 3,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Icon(Icons.info_outline, size: 12, color: AppColors.muted),
          Text(
            pickText('外键关系：', 'Foreign key: '),
            style: legendStyle.copyWith(color: AppColors.bodyText),
          ),
          Text(
            pickText('被约束（外键列 / 子表）', 'Constrained (FK column / child)'),
            style: legendStyle.copyWith(color: AppColors.link),
          ),
          Icon(Icons.arrow_forward, size: 12, color: AppColors.bodyText),
          Text(
            pickText(
              '约束（被引用主键 / 父表）',
              'Constraining (referenced key / parent)',
            ),
            style: legendStyle.copyWith(color: AppColors.link),
          ),
          Text('·', style: muted),
          Text(
            pickText(
              '实线=已有外键 · 虚线=建议外键 · 橙色=多对多',
              'solid = existing FK · dashed = suggested FK · orange = many-to-many',
            ),
            style: muted,
          ),
        ],
      ),
    );
  }

  /// 批量建立建议外键失败时的提示；可返回字段修改（回调非空时）。
  Widget _actionErrorBox() {
    final back = widget.onRequestEditFields;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AlertBox(
          _actionError!,
          tone: AlertTone.error,
          onClose: () => setState(() => _actionError = null),
        ),
        if (back != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Btn(
              '返回工作表与字段修改',
              key: const ValueKey('er-back-to-fields'),
              small: true,
              onPressed: () {
                setState(() => _actionError = null);
                back();
              },
            ),
          ),
      ],
    );
  }

  Widget _toolbar() {
    final added = _tables.length;
    final max = widget.maxTables;
    final suggestionCount = _suggestions.length;
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            'E-R 关系图',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.cardHeading,
            ),
          ),
        ),
        Btn(
          '+ 添加表',
          key: const ValueKey('er-add-table'),
          small: widget.compact,
          icon: Icons.add,
          onPressed:
              _loading ||
                  _loadError != null ||
                  _tables.length >= widget.maxTables
              ? null
              : _openAddTables,
        ),
        const SizedBox(width: 8),
        if (suggestionCount > 0) ...<Widget>[
          Btn(
            pickText(
              '建立建议外键 ($suggestionCount)',
              'Create suggested FKs ($suggestionCount)',
            ),
            key: const ValueKey('er-apply-suggestions'),
            small: widget.compact,
            icon: Icons.auto_fix_high,
            tooltip: '按列名推导的建议关系批量建立外键',
            onPressed: _applyingSuggestions ? null : _applySuggestions,
          ),
          const SizedBox(width: 8),
        ],
        Btn(
          '自动布局',
          key: const ValueKey('er-auto-layout'),
          small: widget.compact,
          icon: Icons.grid_view,
          onPressed: _tables.isEmpty ? null : _autoLayout,
        ),
        const SizedBox(width: 8),
        IconBtn(
          Icons.help_outline,
          key: const ValueKey('er-suggestion-help'),
          tooltip: '建议关系是怎么推导的',
          dimension: 24,
          glyphSize: 14,
          onPressed: _showSuggestionHelp,
        ),
        const SizedBox(width: 10),
        Pill(
          pickText('已加入 $added/$max', 'Added $added/$max'),
          key: const ValueKey('er-table-count'),
          maxWidth: 140,
        ),
      ],
    );
  }

  Widget _sqliteHint() {
    return Row(
      children: <Widget>[
        Icon(Icons.info_outline, size: 13, color: AppColors.muted),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            'SQLite 不支持用 ALTER 增删外键：已有外键只读显示；建表时可以内联外键。',
            key: const ValueKey('er-sqlite-hint'),
            style: kSmallMuted,
          ),
        ),
      ],
    );
  }

  /// 顶部提示：本次自动带入了哪些关联表，并提供撤销。
  Widget _autoAddedHint() {
    final names = _autoAdded.join(pickText('、', ', '));
    return Row(
      children: <Widget>[
        Icon(Icons.link, size: 13, color: AppColors.infoText),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            pickText(
              '已自动加入关联表：$names',
              'Related tables added automatically: $names',
            ),
            key: const ValueKey('er-auto-added-hint'),
            style: TextStyle(fontSize: 11.5, color: AppColors.infoText),
          ),
        ),
        Btn(
          '撤销自动加入',
          key: const ValueKey('er-undo-auto'),
          small: true,
          onPressed: _undoAutoAdded,
        ),
      ],
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text('加载失败', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              AlertBox(_loadError!),
              Btn(
                '重试',
                key: const ValueKey('er-retry'),
                onPressed: _loadInitial,
              ),
            ],
          ),
        ),
      );
    }
    if (_tables.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.account_tree_outlined,
                size: 34,
                color: AppColors.muted,
              ),
              const SizedBox(height: 8),
              const Text(
                '还没有添加表',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  '添加表后，从字段右侧的圆点拖到另一张表的字段即可创建外键',
                  style: kSmallMuted,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return _canvas();
  }

  Widget _canvas() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        _layoutWidth = viewport.width;
        _ensurePositions(viewport.width);
        final layout = _layout;
        final relations = _relations;
        final curves = relationCurves(layout, relations);
        final suggestionCurves = relationCurves(layout, _suggestions);
        final m2mLinks = <ErManyToManyLink>[];
        final m2mCurves = <ErRelationCurve>[];
        for (final link in _m2mLinks) {
          final curve = manyToManyCurve(layout, link);
          if (curve == null) continue;
          m2mLinks.add(link);
          m2mCurves.add(curve);
        }
        final content = layout.contentSize(viewport: viewport, margin: 40);
        final dropTarget = _drag == null ? null : layout.fieldAt(_drag!.point);
        final canvas = SizedBox(
          key: _canvasKey,
          width: content.width,
          height: content.height,
          child: MouseRegion(
            onHover: (event) => _handleHover(
              event.localPosition,
              curves,
              suggestionCurves,
              m2mCurves,
              m2mLinks,
            ),
            onExit: (_) {
              if (_hoverRelation != null ||
                  _hoverSuggestionKey != null ||
                  _hoverM2MKey != null) {
                setState(() {
                  _hoverRelation = null;
                  _hoverSuggestionKey = null;
                  _hoverM2MKey = null;
                });
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) => _handleCanvasTap(
                details.localPosition,
                curves,
                suggestionCurves,
              ),
              child: Stack(
                key: const ValueKey('er-canvas-stack'),
                clipBehavior: Clip.none,
                children: <Widget>[
                  // 先画边、后画卡片：卡片不透明，穿过卡片的线段被自然遮挡；
                  // 箭头尖端落在卡片边界上，留在边界外的部分仍然可见。
                  Positioned.fill(
                    key: const ValueKey('er-edge-layer'),
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _ErCanvasPainter(
                          layout: layout,
                          curves: curves,
                          suggestionCurves: suggestionCurves,
                          m2mLinks: m2mLinks,
                          m2mCurves: m2mCurves,
                          drag: _drag,
                          hoveredRelation: _hoverRelation,
                          hoveredSuggestionKey: _hoverSuggestionKey,
                          hoveredM2MKey: _hoverM2MKey,
                          selectedRelationKey: _selectedRelationKey,
                          dropTarget: dropTarget,
                        ),
                      ),
                    ),
                  ),
                  for (final table in _visibleTables) _node(table),
                  for (var i = 0; i < curves.length; i++)
                    _relationLabel(curves[i], i),
                  for (var i = 0; i < m2mCurves.length; i++)
                    _manyToManyLabel(m2mLinks[i]),
                  for (final curve in suggestionCurves) _suggestionLabel(curve),
                ],
              ),
            ),
          ),
        );
        const locked = NeverScrollableScrollPhysics();
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: _dragLocked ? locked : null,
          child: SingleChildScrollView(
            physics: _dragLocked ? locked : null,
            child: canvas,
          ),
        );
      },
    );
  }

  Widget _node(ErTable table) {
    final position = _positions[table.name] ?? const Offset(24, 24);
    final metrics = _metrics;
    return Positioned(
      key: ValueKey('er-node-layer-${table.name}'),
      left: position.dx,
      top: position.dy,
      child: SizedBox(
        width: metrics.cardWidth,
        height: metrics.heightOf(table),
        child: _nodeCard(table, metrics),
      ),
    );
  }

  Widget _nodeCard(ErTable table, ErNodeMetrics metrics) {
    final tableName = table.name;
    return Container(
      key: ValueKey('er-node-$tableName'),
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(6),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.07),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _nodeHeader(table, metrics),
          for (var i = 0; i < table.columns.length; i++)
            _fieldRow(table, i, metrics),
          SizedBox(height: metrics.bottomPadding),
        ],
      ),
    );
  }

  Widget _nodeHeader(ErTable table, ErNodeMetrics metrics) {
    final tableName = table.name;
    final columnCount = table.columns.length;
    final junction = _junctionInfos[tableName];
    final header = Container(
      height: metrics.headerHeight,
      padding: const EdgeInsets.only(left: 8, right: 2),
      decoration: BoxDecoration(
        color: AppColors.chipBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              tableName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.cardHeading,
              ),
            ),
          ),
          if (junction != null)
            Tooltip(
              message: '中间表（多对多）',
              child: Container(
                constraints: BoxConstraints(maxWidth: widget.compact ? 72 : 86),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.warnBg,
                  border: Border.all(color: AppColors.warnBorder),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  '中间表（多对多）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 8, color: AppColors.warnText),
                ),
              ),
            )
          else
            Text(
              pickText('$columnCount 列', '$columnCount cols'),
              style: TextStyle(fontSize: 9, color: AppColors.muted),
            ),
          if (junction != null)
            IconBtn(
              Icons.unfold_less,
              key: ValueKey('er-collapse-$tableName'),
              tooltip: '折叠中间表',
              dimension: 22,
              glyphSize: 13,
              onPressed: () => _toggleJunction(tableName),
            ),
          const SizedBox(width: 2),
          IconBtn(
            Icons.close,
            key: ValueKey('er-remove-$tableName'),
            tooltip: '移除表',
            dimension: 22,
            glyphSize: 12,
            onPressed: () => _removeTable(tableName),
          ),
        ],
      ),
    );
    return Listener(
      onPointerDown: (event) => _startNodeDrag(tableName, event.position),
      onPointerMove: (event) => _moveNodeDrag(tableName, event.position),
      onPointerUp: (_) => _endNodeDrag(),
      onPointerCancel: (_) => _endNodeDrag(),
      child: MouseRegion(cursor: SystemMouseCursors.move, child: header),
    );
  }

  Widget _fieldRow(ErTable table, int index, ErNodeMetrics metrics) {
    final column = table.columns[index];
    final typeLabel = column.typeLabel;
    return SizedBox(
      height: metrics.rowHeight,
      child: Row(
        children: <Widget>[
          // 左右两端都有连接点：从任一端拖拽都能建关系。
          _connectionDot(table, index, column, metrics, fromLeft: true),
          SizedBox(
            width: 20,
            child: Text(
              column.primary ? 'PK' : (column.foreignKey ? 'FK' : ''),
              style: TextStyle(
                fontSize: 8.5,
                fontWeight: FontWeight.w600,
                color: column.primary ? AppColors.link : AppColors.muted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              column.name,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(
                size: widget.compact ? 10.5 : 11,
                color: AppColors.bodyText,
              ),
            ),
          ),
          if (typeLabel.isNotEmpty)
            SizedBox(
              width: metrics.cardWidth * 0.34,
              child: Text(
                typeLabel,
                maxLines: 1,
                softWrap: false,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 9, color: AppColors.muted),
              ),
            ),
          _connectionDot(table, index, column, metrics, fromLeft: false),
        ],
      ),
    );
  }

  Widget _connectionDot(
    ErTable table,
    int index,
    ErColumn column,
    ErNodeMetrics metrics, {
    required bool fromLeft,
  }) {
    final enabled = !_isSqlite;
    final tableName = table.name;
    final columnName = column.name;
    final side = fromLeft ? 'L' : 'R';
    final hoverKey = '$tableName\u0000$columnName\u0000$side';
    final hovered = _hoverDot == hoverKey;
    final keyName = fromLeft
        ? 'er-connect-left-$tableName-$columnName'
        : 'er-connect-$tableName-$columnName';
    final dot = Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: enabled && !hovered ? AppColors.panel : AppColors.accent,
        border: Border.all(
          color: enabled ? AppColors.link : AppColors.muted,
          width: 1.4,
        ),
      ),
    );
    final tooltip = enabled ? '拖动到另一张表的字段创建外键' : 'SQLite 不支持用 ALTER 新增外键';
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 300),
      child: MouseRegion(
        cursor: enabled
            ? SystemMouseCursors.precise
            : SystemMouseCursors.forbidden,
        onEnter: (_) => setState(() => _hoverDot = hoverKey),
        onExit: (_) {
          if (_hoverDot == hoverKey) setState(() => _hoverDot = null);
        },
        child: GestureDetector(
          key: ValueKey(keyName),
          behavior: HitTestBehavior.opaque,
          onPanDown: enabled ? (_) => setState(() => _dotPressed = true) : null,
          onPanStart: enabled
              ? (details) => _startConnect(
                  table,
                  index,
                  details.globalPosition,
                  fromLeft: fromLeft,
                )
              : null,
          onPanUpdate: enabled
              ? (details) => _updateConnect(details.globalPosition)
              : null,
          onPanEnd: enabled ? (_) => _finishConnect() : null,
          onPanCancel: enabled ? _cancelConnect : null,
          child: SizedBox(
            width: 16,
            height: metrics.rowHeight,
            child: Center(child: dot),
          ),
        ),
      ),
    );
  }

  Widget _relationLabel(ErRelationCurve curve, int index) {
    final relation = curve.relation;
    final relationKey = relation.key;
    final hovered = _hoverRelation == index;
    // 标签降噪：完整关系标签默认不显示，hover 或选中该边才出现。
    final visible = hovered || _selectedRelationKey == relationKey;
    return Positioned(
      left: curve.labelAnchor.dx,
      top: curve.labelAnchor.dy,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: IgnorePointer(
          ignoring: !visible,
          child: Opacity(
            opacity: visible ? 1 : 0,
            child: GestureDetector(
              key: ValueKey('er-relation-$relationKey'),
              onTap: () => _selectRelation(relation),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 200),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: hovered ? AppColors.focusRing : AppColors.panel,
                    border: Border.all(
                      color: hovered ? AppColors.link : AppColors.border,
                    ),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    relation.displayLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9.5,
                      color: hovered ? AppColors.linkHover : AppColors.link,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 折叠 / 展开中间表节点（折叠后只保留两端的多对多连线）。
  void _toggleJunction(String junctionTable) {
    setState(() {
      if (!_collapsedJunctions.remove(junctionTable)) {
        _collapsedJunctions.add(junctionTable);
      }
      _selectedRelationKey = null;
    });
  }

  /// 两端实体表之间的「多对多 · 中间表」标签；点击折叠 / 展开中间表节点。
  Widget _manyToManyLabel(ErManyToManyLink link) {
    final junction = link.junctionTable;
    final collapsed = _collapsedJunctions.contains(junction);
    final hint = collapsed ? '展开中间表' : '折叠中间表';
    final label = pickText('多对多 · $junction', 'many-to-many · $junction');
    // 标签降噪：多对多标签只在折叠状态或 hover 到这条线时显示。
    final visible = collapsed || _hoverM2MKey == link.key;
    return _edgeLabel(
      left: _m2mLabelAnchor(link),
      tooltip: hint,
      keyValue: 'er-m2m-$junction',
      visible: visible,
      background: AppColors.infoBg,
      borderColor: AppColors.infoBorder,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.link, size: 10, color: AppColors.infoText),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9.5, color: AppColors.infoText),
            ),
          ),
        ],
      ),
      onTap: () => _toggleJunction(junction),
    );
  }

  /// 建议关系的虚线标签：默认只显示小号「建议」胶囊；hover 时展开完整
  /// 「建议：a.b → c.d」，tooltip 里是完整文案 + 推导原因；点击建立这一条
  /// 建议外键（SQLite 会弹说明，不再静默）。
  Widget _suggestionLabel(ErRelationCurve curve) {
    final relation = curve.relation;
    final relationKey = relation.key;
    final hovered =
        _hoverSuggestionKey == relationKey ||
        _hoverSuggestionKey == null && false;
    return _edgeLabel(
      left: curve.labelAnchor,
      tooltip: erSuggestionTooltip(relation),
      keyValue: 'er-suggestion-$relationKey',
      background: hovered ? AppColors.focusRing : AppColors.warnBg,
      borderColor: AppColors.warnBorder,
      child: Text(
        hovered ? erSuggestionLabel(relation) : '建议',
        style: TextStyle(fontSize: 9, color: AppColors.warnText),
      ),
      onTap: () => _applySuggestions(only: relation),
    );
  }

  /// 边标签的公共壳：按画布坐标定位，水平垂直居中。
  Widget _edgeLabel({
    required Offset left,
    required String tooltip,
    required String keyValue,
    required Color background,
    required Color borderColor,
    required Widget child,
    VoidCallback? onTap,
    bool visible = true,
  }) {
    return Positioned(
      left: left.dx,
      top: left.dy,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: IgnorePointer(
          ignoring: !visible,
          child: Opacity(
            opacity: visible ? 1 : 0,
            child: Tooltip(
              message: tooltip,
              waitDuration: const Duration(milliseconds: 300),
              child: MouseRegion(
                cursor: onTap == null
                    ? SystemMouseCursors.basic
                    : SystemMouseCursors.click,
                child: GestureDetector(
                  key: ValueKey(keyValue),
                  onTap: onTap,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 210),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: background,
                      border: Border.all(color: borderColor),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 多对多标签锚点：两端实体表卡片中心连线的中点。
  Offset _m2mLabelAnchor(ErManyToManyLink link) {
    final layout = _layout;
    final tableA = layout.tableNamed(link.tableA);
    final tableB = layout.tableNamed(link.tableB);
    final positionA = layout.positions[link.tableA];
    final positionB = layout.positions[link.tableB];
    if (tableA == null ||
        tableB == null ||
        positionA == null ||
        positionB == null) {
      return Offset.zero;
    }
    final metrics = layout.metrics;
    final a = Offset(
      positionA.dx + metrics.cardWidth / 2,
      positionA.dy + metrics.heightOf(tableA) / 2,
    );
    final b = Offset(
      positionB.dx + metrics.cardWidth / 2,
      positionB.dy + metrics.heightOf(tableB) / 2,
    );
    return Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
  }
}

/// 创建中间表 / 直接加第二个外键的选择。
enum _JunctionChoice { junction, direct, cancel }

/// 中间表提示的触发原因：两表已有关系 / 双方连接列都不唯一。
enum _JunctionReason { existingRelation, notUnique }

/// 拖拽中的临时连线。
class _ConnectDrag {
  const _ConnectDrag({
    required this.table,
    required this.columnIndex,
    required this.source,
    required this.point,
    required this.fromLeft,
  });

  final String table;
  final int columnIndex;
  final Offset source;
  final Offset point;

  /// 拖拽起点是字段行的左连接点（true）还是右连接点。
  final bool fromLeft;

  _ConnectDrag copyWith({Offset? point}) => _ConnectDrag(
    table: table,
    columnIndex: columnIndex,
    source: source,
    point: point ?? this.point,
    fromLeft: fromLeft,
  );
}

/// 一张表的读取结果。
class _LoadedTable {
  const _LoadedTable(this.table, this.relations, this.uniqueColumns);

  final ErTable table;
  final List<ErRelation> relations;

  /// 单列唯一（单列主键 / 单列唯一索引）字段。
  final Set<String> uniqueColumns;
}

/// 添加表弹窗里的候选项。
class _TableChoice {
  const _TableChoice(this.name, this.columnCount, {this.added = false});

  final String name;
  final int columnCount;

  /// 已经在画布上（选择器里灰显、不可再勾选）。
  final bool added;
}

// ------------------------------------------------------------------ 画布绘制

/// 画布绘制：网格背景、三类关系曲线 + 目标端箭头、拖拽预览、放置目标高亮。
///
/// 三类边：真实外键（实线 + 箭头）、中间表多对多（实线 + 箭头）、按列名推导的
/// 建议关系（虚线 + 箭头）。边层先画、卡片后画：穿过卡片的线段被卡片自然遮挡，
/// 箭头尖端落在卡片边界上，留在边界外的三角部分仍然可见。
class _ErCanvasPainter extends CustomPainter {
  _ErCanvasPainter({
    required this.layout,
    required this.curves,
    required this.suggestionCurves,
    required this.m2mLinks,
    required this.m2mCurves,
    required this.drag,
    required this.hoveredRelation,
    required this.hoveredSuggestionKey,
    required this.hoveredM2MKey,
    required this.selectedRelationKey,
    required this.dropTarget,
  });

  final ErCanvasLayout layout;
  final List<ErRelationCurve> curves;
  final List<ErRelationCurve> suggestionCurves;
  final List<ErManyToManyLink> m2mLinks;
  final List<ErRelationCurve> m2mCurves;
  final _ConnectDrag? drag;
  final int? hoveredRelation;

  /// 当前 hover 的建议虚线（关系 key）：虚线加粗 + 光晕。
  final String? hoveredSuggestionKey;
  final String? hoveredM2MKey;
  final String? selectedRelationKey;
  final ErFieldRef? dropTarget;

  double get _arrowScale => layout.metrics.headerHeight <= 30 ? 0.85 : 1.0;

  @override
  void paint(Canvas canvas, Size size) {
    _paintGrid(canvas, size);
    // 建议关系在最底层（虚线、橙色），中间表多对多其次，真实外键最上层。
    for (final curve in suggestionCurves) {
      final highlighted = curve.relation.key == hoveredSuggestionKey;
      _paintDashedCurve(
        canvas,
        curve,
        AppColors.warnBorder,
        highlighted: highlighted,
      );
      _paintArrow(
        canvas,
        curve,
        AppColors.warnBorder,
        scale: _arrowScale * (highlighted ? 1.25 : 1.0),
      );
    }
    for (var i = 0; i < m2mCurves.length; i++) {
      final highlighted =
          hoveredM2MKey != null &&
          i < m2mLinks.length &&
          m2mLinks[i].key == hoveredM2MKey;
      _paintSolidCurve(
        canvas,
        m2mCurves[i],
        AppColors.accent,
        width: highlighted ? 3.0 : 2.0,
        highlighted: highlighted,
      );
      _paintArrow(
        canvas,
        m2mCurves[i],
        AppColors.accent,
        scale: _arrowScale * (highlighted ? 1.25 : 1.1),
      );
    }
    for (var i = 0; i < curves.length; i++) {
      final curve = curves[i];
      final selected =
          selectedRelationKey != null &&
          curve.relation.key == selectedRelationKey;
      final highlighted = i == hoveredRelation || selected;
      final color = _colorFor(curve.relation.origin);
      _paintSolidCurve(
        canvas,
        curve,
        color,
        width: highlighted ? 3.0 : 1.8,
        highlighted: highlighted,
      );
      _paintArrow(
        canvas,
        curve,
        color,
        scale: _arrowScale * (highlighted ? 1.2 : 1.0),
      );
    }
    _paintDropTarget(canvas);
    _paintDrag(canvas);
  }

  void _paintGrid(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.border.withValues(alpha: 0.32)
      ..strokeWidth = 1;
    const step = 32.0;
    for (var x = 0.0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  Color _colorFor(ErRelationOrigin origin) {
    switch (origin) {
      case ErRelationOrigin.existing:
        return AppColors.link;
      case ErRelationOrigin.created:
        return AppColors.ok;
      case ErRelationOrigin.junction:
        return AppColors.accent;
      case ErRelationOrigin.suggested:
        return AppColors.warnBorder;
    }
  }

  Path _pathFor(ErRelationCurve curve) {
    return Path()
      ..moveTo(curve.start.dx, curve.start.dy)
      ..cubicTo(
        curve.control1.dx,
        curve.control1.dy,
        curve.control2.dx,
        curve.control2.dy,
        curve.end.dx,
        curve.end.dy,
      );
  }

  void _paintSolidCurve(
    Canvas canvas,
    ErRelationCurve curve,
    Color color, {
    required double width,
    required bool highlighted,
  }) {
    if (highlighted) {
      canvas.drawPath(
        _pathFor(curve),
        Paint()
          ..color = color.withValues(alpha: 0.18)
          ..style = PaintingStyle.stroke
          ..strokeWidth = width + 6
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.drawPath(
      _pathFor(curve),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(
      curve.start,
      highlighted ? 3.4 : 2.6,
      Paint()..color = color,
    );
  }

  /// 虚线：按采样折线交替画线段，建议关系用；hover 时加粗并加一层光晕。
  void _paintDashedCurve(
    Canvas canvas,
    ErRelationCurve curve,
    Color color, {
    bool highlighted = false,
  }) {
    final points = curve.sample(segments: 48);
    if (highlighted) {
      _paintDashedSegments(
        canvas,
        points,
        color.withValues(alpha: 0.18),
        width: 8,
        dash: 7,
        gap: 5,
      );
    }
    _paintDashedSegments(
      canvas,
      points,
      color,
      width: highlighted ? 2.6 : 1.6,
      dash: 7,
      gap: 5,
    );
    canvas.drawCircle(
      curve.start,
      highlighted ? 3.4 : 2.4,
      Paint()..color = color,
    );
  }

  /// 按采样折线交替画虚线段。
  void _paintDashedSegments(
    Canvas canvas,
    List<Offset> points,
    Color color, {
    required double width,
    required double dash,
    required double gap,
  }) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    var drawing = true;
    var remaining = dash;
    for (var i = 0; i + 1 < points.length; i++) {
      var a = points[i];
      final b = points[i + 1];
      var segmentLength = (b - a).distance;
      while (segmentLength > 0.0001) {
        final step = math.min(remaining, segmentLength);
        final t = step / segmentLength;
        final next = Offset(a.dx + (b.dx - a.dx) * t, a.dy + (b.dy - a.dy) * t);
        if (drawing) canvas.drawLine(a, next, paint);
        a = next;
        segmentLength -= step;
        remaining -= step;
        if (remaining <= 0.0001) {
          drawing = !drawing;
          remaining = drawing ? dash : gap;
        }
      }
    }
  }

  /// 目标端箭头：尖端在曲线终点，沿贝塞尔终点切线方向回退成实心三角。
  void _paintArrow(
    Canvas canvas,
    ErRelationCurve curve,
    Color color, {
    double scale = 1,
  }) {
    final head = ErArrowHead.forCurve(
      curve,
      length: 13 * scale,
      halfWidth: 6 * scale,
    );
    if (head == null) return;
    final triangle = Path()..addPolygon(head.triangle, true);
    // 描一圈面板色，箭头压在卡片/网格上也能看清轮廓。
    canvas.drawPath(
      triangle,
      Paint()
        ..color = AppColors.panel.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    canvas.drawPath(triangle, Paint()..color = color);
  }

  void _paintDrag(Canvas canvas) {
    final current = drag;
    if (current == null) return;
    final paint = Paint()
      ..color = AppColors.accent
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    canvas.drawLine(current.source, current.point, paint);
    canvas.drawCircle(current.point, 4, Paint()..color = AppColors.accent);
  }

  void _paintDropTarget(Canvas canvas) {
    final target = dropTarget;
    if (target == null) return;
    final table = layout.tableNamed(target.table);
    final position = layout.positions[target.table];
    if (table == null || position == null) return;
    final metrics = layout.metrics;
    final rect = Rect.fromLTWH(
      position.dx + metrics.borderInset,
      position.dy +
          metrics.borderInset +
          metrics.headerHeight +
          target.columnIndex * metrics.rowHeight,
      metrics.cardWidth - metrics.borderInset * 2,
      metrics.rowHeight,
    );
    final radius = Radius.circular(3);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, radius),
      Paint()..color = AppColors.focusRing.withValues(alpha: 0.65),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, radius),
      Paint()
        ..color = AppColors.link
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(covariant _ErCanvasPainter oldDelegate) => true;
}

// -------------------------------------------------------------- 添加表弹窗

class _AddTablesDialog extends StatefulWidget {
  const _AddTablesDialog({
    super.key,
    required this.choices,
    required this.remaining,
  });

  final List<_TableChoice> choices;
  final int remaining;

  @override
  State<_AddTablesDialog> createState() => _AddTablesDialogState();
}

class _AddTablesDialogState extends State<_AddTablesDialog> {
  final TextEditingController _search = TextEditingController();
  final Set<String> _selected = <String>{};

  /// 已勾选的表名（按字母序），供底部「加入」按钮读取。
  List<String> get selected => _selected.toList()..sort();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<_TableChoice> get _filtered {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return widget.choices;
    return <_TableChoice>[
      for (final choice in widget.choices)
        if (choice.name.toLowerCase().contains(query)) choice,
    ];
  }

  void _toggle(_TableChoice choice) {
    if (choice.added) return;
    setState(() {
      if (!_selected.remove(choice.name)) {
        if (_selected.length < widget.remaining) _selected.add(choice.name);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    final remaining = widget.remaining;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Field(
          label: '',
          controller: _search,
          hint: '搜索表名',
          compact: true,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        if (widget.choices.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text('（没有可添加的表）', style: kSmallMuted),
          )
        else if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Text('（没有匹配的表）', style: kSmallMuted),
          )
        else
          SizedBox(
            height: 320,
            child: ListView.separated(
              itemCount: filtered.length,
              separatorBuilder: (_, _) =>
                  Divider(height: 1, color: AppColors.border),
              itemBuilder: (context, index) {
                final choice = filtered[index];
                final name = choice.name;
                final count = choice.columnCount;
                final added = choice.added;
                final checked = _selected.contains(name);
                return InkWell(
                  key: ValueKey('er-picker-$name'),
                  onTap: added ? null : () => _toggle(choice),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 8,
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          added
                              ? Icons.check_circle_outline
                              : (checked
                                    ? Icons.check_box
                                    : Icons.check_box_outline_blank),
                          size: 18,
                          color: added
                              ? AppColors.muted
                              : (checked ? AppColors.link : AppColors.muted),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: added ? kSmallMuted : monoStyle(size: 12),
                          ),
                        ),
                        if (added)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Text('已加入', style: kSmallMuted),
                          ),
                        Text(
                          pickText('$count 列', '$count cols'),
                          style: TextStyle(
                            fontSize: 10,
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 8),
        Text(
          pickText(
            '最多加入 $remaining 张表（画布上限）',
            'You can add up to $remaining more table(s)',
          ),
          style: kSmallMuted,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------- 新建外键弹窗

class _NewForeignKeyDialog extends StatefulWidget {
  const _NewForeignKeyDialog({
    super.key,
    required this.localTable,
    required this.refTable,
    required this.initialLocalColumn,
    required this.initialRefColumn,
    required this.initialName,
    required this.driver,
    required this.existingTableNames,
    required this.onCreate,
    required this.onCreateJunction,
    required this.onRequestEditFields,
    required this.validate,
  });

  final ErTable localTable;
  final ErTable refTable;
  final String initialLocalColumn;
  final String initialRefColumn;
  final String initialName;
  final ErDriver driver;
  final Set<String> existingTableNames;
  final Future<void> Function(Map<String, dynamic> payload) onCreate;
  final Future<void> Function(ErJunctionPlan plan) onCreateJunction;
  final VoidCallback? onRequestEditFields;

  /// 提交前的前置校验；返回错误文案（null = 通过）。
  final String? Function(String localColumn, String refColumn)? validate;

  @override
  State<_NewForeignKeyDialog> createState() => _NewForeignKeyDialogState();
}

class _NewForeignKeyDialogState extends State<_NewForeignKeyDialog> {
  late String _localColumn;
  late String _refColumn;
  late final TextEditingController _name;
  String _onDelete = '';
  String _onUpdate = '';
  bool _manyToMany = false;
  String? _error;
  bool _busy = false;

  bool get _localNullable =>
      widget.localTable.columnNamed(_localColumn)?.nullable ?? true;

  /// 多对多模式下要创建的中间表（两表缺单列主键时为 null）。
  ErJunctionPlan? get _junctionPlan => planJunction(
    driver: widget.driver,
    localTable: widget.localTable,
    refTable: widget.refTable,
    existingTableNames: widget.existingTableNames,
  );

  @override
  void initState() {
    super.initState();
    _localColumn = widget.initialLocalColumn;
    _refColumn = widget.initialRefColumn;
    _name = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  List<DropdownMenuItem<String>> _actionItems({required bool onDelete}) {
    return <DropdownMenuItem<String>>[
      for (final action in kErFkActions)
        DropdownMenuItem<String>(
          value: action,
          enabled: !(action == 'SET NULL' && !_localNullable),
          child: Text(erFkActionLabel(action, onDelete: onDelete)),
        ),
    ];
  }

  void _pickLocalColumn(String value) {
    setState(() {
      _localColumn = value;
      if (!_localNullable) {
        if (_onDelete == 'SET NULL') _onDelete = '';
        if (_onUpdate == 'SET NULL') _onUpdate = '';
      }
    });
  }

  Future<void> submit() async {
    if (_busy) return;
    if (_manyToMany) {
      final plan = _junctionPlan;
      if (plan == null) {
        setState(
          () => _error = pickText(
            '目标表没有主键，无法创建中间表',
            'A target table has no primary key, so a junction table cannot be created',
          ),
        );
        return;
      }
      setState(() {
        _busy = true;
        _error = null;
      });
      try {
        await widget.onCreateJunction(plan);
        if (!mounted) return;
        Navigator.of(context).pop(true);
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = error.toString();
        });
      }
      return;
    }
    final name = _name.text.trim();
    if (name.isNotEmpty && !RegExp(r'^[0-9A-Za-z_]+$').hasMatch(name)) {
      setState(
        () => _error = pickText(
          '约束名只能包含字母、数字和下划线',
          'Constraint names may only contain letters, digits and underscores',
        ),
      );
      return;
    }
    if (_localColumn.isEmpty || _refColumn.isEmpty) {
      setState(() => _error = pickText('请选择本表字段', 'Choose a local column'));
      return;
    }
    // 本地前置校验：目标列必须是主键/单列唯一、类型粗粒度兼容、两端有主键。
    final validation = widget.validate?.call(_localColumn, _refColumn);
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    if ((_onDelete == 'SET NULL' || _onUpdate == 'SET NULL') &&
        !_localNullable) {
      setState(
        () => _error = pickText(
          '置空要求本表字段允许为空',
          'SET NULL requires the local column to be nullable',
        ),
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onCreate(
        foreignKeyPayload(
          name: name,
          localColumn: _localColumn,
          refTable: widget.refTable.name,
          refColumn: _refColumn,
          onDelete: _onDelete,
          onUpdate: _onUpdate,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final localColumns = widget.localTable.columns;
    final refColumns = widget.refTable.columns;
    final refTableName = widget.refTable.name;
    final localTableName = widget.localTable.name;
    final hint = defaultFkName(widget.localTable.name, _localColumn);
    final plan = _manyToMany ? _junctionPlan : null;
    final junctionName = plan?.name ?? '';
    final junctionId = plan?.idColumn ?? '';
    final junctionColumnA = plan?.columnA ?? '';
    final junctionTableA = plan?.tableA ?? '';
    final junctionPrimaryA = plan?.primaryColumnA ?? '';
    final junctionColumnB = plan?.columnB ?? '';
    final junctionTableB = plan?.tableB ?? '';
    final junctionPrimaryB = plan?.primaryColumnB ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FormRow(
          label: '关系类型',
          child: SelectBox<String>(
            value: _manyToMany ? 'many_to_many' : 'many_to_one',
            onChanged: (value) => setState(() {
              _manyToMany = value == 'many_to_many';
              _error = null;
            }),
            items: <DropdownMenuItem<String>>[
              DropdownMenuItem<String>(
                value: 'many_to_one',
                child: Text('多对一（直接外键）'),
              ),
              DropdownMenuItem<String>(
                value: 'many_to_many',
                child: Text('多对多（自动创建中间表）'),
              ),
            ],
          ),
        ),
        if (_manyToMany) ...<Widget>[
          FormRow(
            label: '本表',
            child: Text(localTableName, style: monoStyle(size: 12)),
          ),
          FormRow(
            label: '引用表',
            child: Text(refTableName, style: monoStyle(size: 12)),
          ),
          const SizedBox(height: 4),
          if (plan == null)
            Text('目标表没有主键，无法创建中间表', style: kSmallMuted)
          else ...<Widget>[
            Text(
              pickText(
                '将自动创建中间表 $junctionName，包含指向两端主键的两个外键。',
                'A junction table $junctionName will be created, with two foreign keys pointing at both primary keys.',
              ),
              style: kSmallMuted,
            ),
            const SizedBox(height: 4),
            Text(
              pickText(
                '$junctionId：主键自增',
                '$junctionId: auto-increment primary key',
              ),
              style: monoStyle(size: 11),
            ),
            Text(
              erJunctionTarget(
                junctionColumnA,
                junctionTableA,
                junctionPrimaryA,
              ),
              style: monoStyle(size: 11),
            ),
            Text(
              erJunctionTarget(
                junctionColumnB,
                junctionTableB,
                junctionPrimaryB,
              ),
              style: monoStyle(size: 11),
            ),
          ],
        ] else ...<Widget>[
          FormRow(
            label: '本表字段',
            child: SelectBox<String>(
              value: _localColumn,
              onChanged: (value) => _pickLocalColumn(value ?? _localColumn),
              items: <DropdownMenuItem<String>>[
                for (final column in localColumns)
                  DropdownMenuItem<String>(
                    value: column.name,
                    child: Text(column.name),
                  ),
              ],
            ),
          ),
          FormRow(
            label: '引用表',
            child: Text(refTableName, style: monoStyle(size: 12)),
          ),
          FormRow(
            label: '引用字段',
            child: SelectBox<String>(
              value: _refColumn,
              onChanged: (value) =>
                  setState(() => _refColumn = value ?? _refColumn),
              items: <DropdownMenuItem<String>>[
                for (final column in refColumns)
                  DropdownMenuItem<String>(
                    value: column.name,
                    child: Text(column.name),
                  ),
              ],
            ),
          ),
          FormRow(
            label: '删除时',
            child: SelectBox<String>(
              value: _onDelete,
              onChanged: (value) => setState(() => _onDelete = value ?? ''),
              items: _actionItems(onDelete: true),
            ),
          ),
          FormRow(
            label: '更新时',
            child: SelectBox<String>(
              value: _onUpdate,
              onChanged: (value) => setState(() => _onUpdate = value ?? ''),
              items: _actionItems(onDelete: false),
            ),
          ),
          Field(
            label: '约束名',
            controller: _name,
            hint: hint,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          const SizedBox(height: 2),
          Text('外键名的默认值可以修改；MySQL 要求被引用的列必须有主键或唯一索引。', style: kSmallMuted),
        ],
        if (_error != null) ...<Widget>[
          const SizedBox(height: 8),
          AlertBox(_error!),
          if (widget.onRequestEditFields != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Btn(
                '返回工作表与字段修改',
                key: const ValueKey('er-back-to-fields'),
                small: true,
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onRequestEditFields!();
                },
              ),
            ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------- 查看 / 删除关系

class _RelationDialog extends StatefulWidget {
  const _RelationDialog({
    super.key,
    required this.relation,
    required this.canDelete,
    required this.isSqlite,
    required this.onDelete,
  });

  final ErRelation relation;
  final bool canDelete;
  final bool isSqlite;
  final Future<void> Function() onDelete;

  @override
  State<_RelationDialog> createState() => _RelationDialogState();
}

class _RelationDialogState extends State<_RelationDialog> {
  String? _error;
  bool _busy = false;

  Future<void> deleteRelation() async {
    if (_busy || !widget.canDelete) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onDelete();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final relation = widget.relation;
    final localPath = erColumnPath(relation.localTable, relation.localColumn);
    final refPath = erColumnPath(relation.refTable, relation.refColumn);
    final constraintName = relation.name.isNotEmpty
        ? relation.name
        : pickText('未命名（数据库自动生成）', 'Unnamed (generated by the database)');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FormRow(
          label: '本表',
          child: Text(localPath, style: monoStyle(size: 12)),
        ),
        FormRow(
          label: '引用表',
          child: Text(refPath, style: monoStyle(size: 12)),
        ),
        FormRow(
          label: '约束名',
          child: Text(constraintName, style: monoStyle(size: 12)),
        ),
        FormRow(
          label: '删除时',
          child: Text(erFkActionLabel(relation.onDelete, onDelete: true)),
        ),
        FormRow(
          label: '更新时',
          child: Text(erFkActionLabel(relation.onUpdate, onDelete: false)),
        ),
        if (widget.isSqlite)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'SQLite 不支持用 ALTER 删除外键，只能在重建表时去掉。',
              style: kSmallMuted,
            ),
          )
        else if (relation.name.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('这条外键没有约束名，无法按名字删除。', style: kSmallMuted),
          ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 8),
          AlertBox(_error!),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------- 中间表提示弹窗

class _JunctionDialog extends StatefulWidget {
  const _JunctionDialog({
    super.key,
    required this.plan,
    required this.driver,
    required this.localTable,
    required this.refTable,
    required this.existingTableNames,
    required this.reason,
    required this.onCreate,
    required this.onRequestEditFields,
  });

  final ErJunctionPlan plan;
  final ErDriver driver;
  final ErTable localTable;
  final ErTable refTable;
  final Set<String> existingTableNames;
  final _JunctionReason reason;
  final Future<void> Function(ErJunctionPlan plan) onCreate;
  final VoidCallback? onRequestEditFields;

  @override
  State<_JunctionDialog> createState() => _JunctionDialogState();
}

class _JunctionDialogState extends State<_JunctionDialog> {
  late final TextEditingController _name;
  bool _direct = false;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.plan.name);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  ErJunctionPlan get _preview =>
      planJunction(
        driver: widget.driver,
        localTable: widget.localTable,
        refTable: widget.refTable,
        existingTableNames: widget.existingTableNames,
        name: _name.text.trim().isEmpty ? null : _name.text.trim(),
      ) ??
      widget.plan;

  Future<void> submit() async {
    if (_busy) return;
    if (_direct) {
      Navigator.of(context).pop('direct');
      return;
    }
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(
        () => _error = pickText('请填写中间表名', 'Enter a junction table name'),
      );
      return;
    }
    if (widget.existingTableNames.contains(name)) {
      setState(
        () => _error = pickText(
          '表名已存在，请换一个名字',
          'A table with this name already exists; choose another name',
        ),
      );
      return;
    }
    final plan = planJunction(
      driver: widget.driver,
      localTable: widget.localTable,
      refTable: widget.refTable,
      existingTableNames: widget.existingTableNames,
      name: name,
    );
    if (plan == null) {
      setState(
        () => _error = pickText(
          '目标表没有主键，无法创建中间表',
          'A target table has no primary key, so a junction table cannot be created',
        ),
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onCreate(plan);
      if (!mounted) return;
      Navigator.of(context).pop('junction');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final idColumn = preview.idColumn;
    final targetA = erJunctionTarget(
      preview.columnA,
      preview.tableA,
      preview.primaryColumnA,
    );
    final targetB = erJunctionTarget(
      preview.columnB,
      preview.tableB,
      preview.primaryColumnB,
    );
    final message = widget.reason == _JunctionReason.notUnique
        ? pickText(
            '两个连接字段都不是唯一列，直接外键的引用列可能不合法。建议创建中间表（多对多）；也可以仍然直接添加外键。',
            'Neither connecting column is unique, so a direct foreign key may be invalid. Creating a junction table (many-to-many) is recommended; you can still add a direct foreign key instead.',
          )
        : pickText(
            '同一对表之间再加一条外键会出现多条并存关系。建议自动创建中间表（多对多）；也可以仍然直接添加第二个外键。',
            'Adding another foreign key between the same two tables would leave several relations side by side. A junction table (many-to-many) is recommended; you can still add a second direct foreign key instead.',
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(message, style: kSmallMuted),
        const SizedBox(height: 8),
        CheckBox(
          label: '创建中间表（推荐）',
          value: !_direct,
          onChanged: (value) {
            if (value) setState(() => _direct = false);
          },
        ),
        CheckBox(
          label: widget.reason == _JunctionReason.notUnique
              ? '仍然直接添加外键'
              : '仍然直接添加第二个外键',
          value: _direct,
          onChanged: (value) {
            if (value) setState(() => _direct = true);
          },
        ),
        if (!_direct) ...<Widget>[
          const SizedBox(height: 6),
          Field(
            label: '中间表名',
            controller: _name,
            hint: 'users_orders',
            onChanged: (_) => setState(() {}),
          ),
          Text('将创建中间表，包含指向两端主键的两个外键，原有关系保持不变。', style: kSmallMuted),
          const SizedBox(height: 6),
          Text(
            pickText('$idColumn：主键自增', '$idColumn: auto-increment primary key'),
            style: monoStyle(size: 11),
          ),
          Text(targetA, style: monoStyle(size: 11)),
          Text(targetB, style: monoStyle(size: 11)),
        ],
        if (_error != null) ...<Widget>[
          const SizedBox(height: 8),
          AlertBox(_error!),
          if (widget.onRequestEditFields != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Btn(
                '返回工作表与字段修改',
                key: const ValueKey('er-back-to-fields'),
                small: true,
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onRequestEditFields!();
                },
              ),
            ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------- 建议关系帮助弹窗

/// 建议关系帮助：推导规则 + 当前每条建议的原因。
class _SuggestionHelpDialog extends StatelessWidget {
  const _SuggestionHelpDialog({required this.suggestions});

  final List<ErRelation> suggestions;

  @override
  Widget build(BuildContext context) {
    final rules = <String>[
      pickText(
        '只对画布上还没有外键的表推导建议。',
        'Suggestions are derived only for tables that have no foreign key yet.',
      ),
      pickText(
        '列名以 _id / Id / ID 结尾时，取前面的部分作为基名（例如 category_id → category）。',
        'When a column ends with _id / Id / ID, the part before it is the base name (for example category_id → category).',
      ),
      pickText(
        '在已加入的表里找 x / xs / xes（y → ies）形式、且有单列主键的表作为目标（例如 category → categories）。',
        'Among the added tables, x / xs / xes (y → ies) forms with a single-column primary key are used as targets (for example category → categories).',
      ),
      pickText(
        '最多显示 20 条建议；只画虚线，不会写入数据库。',
        'At most 20 suggestions are shown; they are drawn as dashed lines and never written to the database.',
      ),
      pickText(
        '点工具栏「建立建议外键 (N)」批量建立，或直接点某条建议线只建立这一条（执行 ALTER TABLE ADD FOREIGN KEY）。SQLite 不支持 ALTER 加外键，会弹出说明。',
        'Use "Create suggested FKs (N)" to create them all, or click one suggested line to create just that one (ALTER TABLE ADD FOREIGN KEY). SQLite does not support ALTER and will show an explanation.',
      ),
    ];
    final count = suggestions.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var i = 0; i < rules.length; i++) ...<Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '${i + 1}. ',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.cardHeading,
                ),
              ),
              Expanded(child: Text(rules[i], style: kSmall)),
            ],
          ),
          const SizedBox(height: 6),
        ],
        const Divider(height: 20),
        Text(
          pickText('当前建议（$count 条）', 'Current suggestions ($count)'),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.cardHeading,
          ),
        ),
        const SizedBox(height: 8),
        if (suggestions.isEmpty)
          Text(
            pickText('当前没有可推导的建议关系', 'No suggested relations right now'),
            style: kSmallMuted,
          )
        else
          for (final relation in suggestions)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    erSuggestionLabel(relation),
                    style: monoStyle(size: 11.5),
                  ),
                  const SizedBox(height: 2),
                  Text(erSuggestionReason(relation), style: kSmallMuted),
                ],
              ),
            ),
      ],
    );
  }
}

// ------------------------------------------------------------------ 入口

/// 在独立对话框中打开关系设计器。
///
/// [notice] 传入时，每次关系变化后弹一条「关系已更新」提示（数据库页入口用）。
Future<void> showRelationDesigner(
  BuildContext context, {
  required String database,
  List<String> initialTables = const <String>[],
  Future<void> Function()? onChanged,
  Notice? notice,
}) {
  Future<void> refresh() async {
    await onChanged?.call();
    notice?.show('关系已更新');
  }

  return showAppModal<void>(
    context: context,
    title: 'E-R 关系图',
    wide: true,
    builder: (context) => RelationDesigner(
      database: database,
      initialTables: initialTables,
      onChanged: onChanged == null && notice == null ? null : refresh,
      height: 560,
    ),
    actions: <Widget>[
      Builder(
        builder: (context) =>
            Btn('关闭', onPressed: () => Navigator.of(context).pop()),
      ),
    ],
  );
}
