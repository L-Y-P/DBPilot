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

/// E-R 关系设计器。
///
/// 公开接口由 §5.1 固定（导入向导第 5 步与快速建表向导第 4 步都依赖它）：
/// [database] 是当前数据库 / 模式，[initialTables] 是打开时预置加入的表，
/// [onChanged] 在关系变化（创建 / 删除 / 建中间表）后回调，[maxTables] 是画布
/// 上限（默认 5），[height] 决定嵌入高度，[compact] 让向导内嵌更紧凑。
class RelationDesigner extends StatefulWidget {
  const RelationDesigner({
    super.key,
    required this.database,
    this.initialTables = const <String>[],
    this.onChanged,
    this.maxTables = 5,
    this.height = 460,
    this.compact = false,
  });

  final String database;
  final List<String> initialTables;
  final Future<void> Function()? onChanged;
  final int maxTables;
  final double height;
  final bool compact;

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
  String? _hoverDot;

  bool get _isSqlite => AppState.instance.isSqlite;

  ErDriver get _driver => ErDriver.fromName(AppState.instance.driver);

  ErNodeMetrics get _metrics => ErNodeMetrics.forMode(widget.compact);

  /// 拖动时锁住画布滚动，避免滚动手势和拖拽抢指针。
  bool get _dragLocked => _drag != null || _dotPressed || _draggingNode != null;

  /// 两端都已在画布上的外键（去重后）。
  List<ErRelation> get _relations {
    final added = <String>{for (final table in _tables) table.name};
    final out = <ErRelation>[];
    final seen = <String>{};
    for (final table in _tables) {
      final local = _localRelations[table.name] ?? const <ErRelation>[];
      for (final relation in local) {
        if (!added.contains(relation.refTable)) continue;
        if (!seen.add(relation.key)) continue;
        out.add(relation);
      }
    }
    return out;
  }

  ErCanvasLayout get _layout =>
      ErCanvasLayout(tables: _tables, positions: _positions, metrics: _metrics);

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
      for (final name in wanted) {
        final loaded = await _readTable(name, schemaRows[name]!);
        tables.add(loaded.table);
        relations[name] = loaded.relations;
      }
      if (!mounted) return;
      _schemaRows = schemaRows;
      setState(() {
        _tables = tables;
        _localRelations
          ..clear()
          ..addAll(relations);
        _positions.clear(); // 首帧用真实画布宽度自动布局
        _loading = false;
      });
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
      if (table.columns.isEmpty) {
        return _LoadedTable(
          ErTable.fromSchema(<String, dynamic>{'name': name, ...schemaRow}),
          relations.isEmpty
              ? ErRelation.fromSchema(name, schemaRow)
              : relations,
        );
      }
      return _LoadedTable(table, relations);
    } catch (_) {
      return _LoadedTable(
        ErTable.fromSchema(<String, dynamic>{'name': name, ...schemaRow}),
        ErRelation.fromSchema(name, schemaRow),
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
    });
  }

  // ---------------------------------------------------------------- 表管理

  /// 补齐新加入节点 / 清掉已移除节点的位置；画布每帧布局时调用。
  void _fillMissingPositions(double width) {
    final layout = autoErLayout(
      _tables,
      viewportWidth: width,
      metrics: _metrics,
    );
    final names = <String>{};
    for (final table in _tables) {
      names.add(table.name);
      _positions.putIfAbsent(
        table.name,
        () => layout[table.name] ?? const Offset(24, 24),
      );
    }
    _positions.removeWhere((key, _) => !names.contains(key));
  }

  void _autoLayout() {
    final width = _layoutWidth > 0
        ? _layoutWidth
        : (widget.compact ? 660.0 : 860.0);
    setState(() {
      _positions
        ..clear()
        ..addAll(
          autoErLayout(_tables, viewportWidth: width, metrics: _metrics),
        );
    });
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
    for (final name in wanted) {
      final row = _schemaRows[name] ?? <String, dynamic>{'name': name};
      final loaded = await _readTable(name, row);
      loadedTables.add(loaded.table);
      loadedRelations[name] = loaded.relations;
    }
    if (!mounted) return;
    setState(() {
      _tables = <ErTable>[..._tables, ...loadedTables];
      _localRelations.addAll(loadedRelations);
    });
  }

  void _removeTable(String name) {
    final kept = <ErTable>[
      for (final table in _tables)
        if (table.name != name) table,
    ];
    setState(() {
      _tables = kept;
      _localRelations.remove(name);
      _positions.remove(name);
    });
  }

  // ------------------------------------------------------------ 关系增删

  Future<void> _beginCreateForeignKey({
    required ErTable localTable,
    required String localColumn,
    required ErTable refTable,
    required String refColumn,
  }) async {
    if (refTable.columns.isEmpty) return;
    // 同一对表之间已有关系 → 默认改为创建中间表（多对多）。
    if (localTable.name != refTable.name &&
        hasRelationBetween(_relations, localTable.name, refTable.name)) {
      final choice = await _offerJunction(localTable, refTable);
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
        onCreate: (payload) => _createForeignKey(localTable.name, payload),
      ),
      actions: <Widget>[
        Builder(
          builder: (context) =>
              Btn('取消', onPressed: () => Navigator.of(context).pop(false)),
        ),
        Builder(
          builder: (context) => Btn(
            '创建外键',
            primary: true,
            onPressed: () => key.currentState?.submit(),
          ),
        ),
      ],
    );
    if (created == true && mounted) await widget.onChanged?.call();
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

  /// 两表已有关系时的中间表提示；返回用户的选择。
  Future<_JunctionChoice> _offerJunction(
    ErTable localTable,
    ErTable refTable,
  ) async {
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
      title: '两表之间已存在关系',
      builder: (context) => _JunctionDialog(
        key: key,
        plan: plan,
        driver: _driver,
        localTable: localTable,
        refTable: refTable,
        existingTableNames: existingNames,
        onCreate: _createJunction,
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
    if (row != null) {
      final loaded = await _readTable(plan.name, row);
      table = loaded.table;
      relations = loaded.relations;
    }
    if (!mounted) return;
    setState(() {
      _tables = <ErTable>[..._tables, table];
      _localRelations[plan.name] = relations;
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

  void _startConnect(ErTable table, int columnIndex, Offset globalPosition) {
    final local = _toCanvas(globalPosition);
    final columnName = table.columns[columnIndex].name;
    final source = _layout.connectionPoint(table.name, columnName) ?? local;
    setState(() {
      _dotPressed = true;
      _drag = _ConnectDrag(
        table: table.name,
        columnIndex: columnIndex,
        source: source,
        point: local,
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

  void _handleHover(Offset local, List<ErRelationCurve> curves) {
    final hit = hitTestRelationCurves(curves, local);
    if (hit != _hoverRelation) {
      setState(() => _hoverRelation = hit);
    }
  }

  void _handleCanvasTap(Offset local, List<ErRelationCurve> curves) {
    final hit = hitTestRelationCurves(curves, local);
    if (hit == null) return;
    final relation = curves[hit].relation;
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

  Widget _toolbar() {
    final added = _tables.length;
    final max = widget.maxTables;
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
        Btn(
          '自动布局',
          key: const ValueKey('er-auto-layout'),
          small: widget.compact,
          icon: Icons.grid_view,
          onPressed: _tables.isEmpty ? null : _autoLayout,
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
        _fillMissingPositions(viewport.width);
        final layout = _layout;
        final relations = _relations;
        final curves = relationCurves(layout, relations);
        final content = layout.contentSize(viewport: viewport, margin: 40);
        final dropTarget = _drag == null ? null : layout.fieldAt(_drag!.point);
        final canvas = SizedBox(
          key: _canvasKey,
          width: content.width,
          height: content.height,
          child: MouseRegion(
            onHover: (event) => _handleHover(event.localPosition, curves),
            onExit: (_) {
              if (_hoverRelation != null) {
                setState(() => _hoverRelation = null);
              }
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) =>
                  _handleCanvasTap(details.localPosition, curves),
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _ErCanvasPainter(
                        layout: layout,
                        curves: curves,
                        drag: _drag,
                        hoveredRelation: _hoverRelation,
                        dropTarget: dropTarget,
                      ),
                    ),
                  ),
                  for (final table in _tables) _node(table),
                  for (var i = 0; i < curves.length; i++)
                    _relationLabel(curves[i], i),
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
          Text(
            pickText('$columnCount 列', '$columnCount cols'),
            style: TextStyle(fontSize: 9, color: AppColors.muted),
          ),
          const SizedBox(width: 2),
          IconBtn(
            Icons.close,
            key: ValueKey('er-remove-$tableName'),
            tooltip: '移除表',
            small: true,
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
    return SizedBox(
      height: metrics.rowHeight,
      child: Row(
        children: <Widget>[
          const SizedBox(width: 6),
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
              overflow: TextOverflow.ellipsis,
              style: monoStyle(
                size: widget.compact ? 10.5 : 11,
                color: AppColors.bodyText,
              ),
            ),
          ),
          if (column.typeLabel.isNotEmpty)
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: metrics.cardWidth * 0.3),
              child: Text(
                column.typeLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 9, color: AppColors.muted),
              ),
            ),
          _connectionDot(table, index, column, metrics),
        ],
      ),
    );
  }

  Widget _connectionDot(
    ErTable table,
    int index,
    ErColumn column,
    ErNodeMetrics metrics,
  ) {
    final enabled = !_isSqlite;
    final tableName = table.name;
    final columnName = column.name;
    final hoverKey = '$tableName\u0000$columnName';
    final hovered = _hoverDot == hoverKey;
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
          key: ValueKey('er-connect-$tableName-$columnName'),
          behavior: HitTestBehavior.opaque,
          onPanDown: enabled ? (_) => setState(() => _dotPressed = true) : null,
          onPanStart: enabled
              ? (details) => _startConnect(table, index, details.globalPosition)
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
    return Positioned(
      left: curve.labelAnchor.dx,
      top: curve.labelAnchor.dy,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: GestureDetector(
          key: ValueKey('er-relation-$relationKey'),
          onTap: () => _openRelationDialog(relation),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 200),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
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
    );
  }
}

/// 创建中间表 / 直接加第二个外键的选择。
enum _JunctionChoice { junction, direct, cancel }

/// 拖拽中的临时连线。
class _ConnectDrag {
  const _ConnectDrag({
    required this.table,
    required this.columnIndex,
    required this.source,
    required this.point,
  });

  final String table;
  final int columnIndex;
  final Offset source;
  final Offset point;

  _ConnectDrag copyWith({Offset? point}) => _ConnectDrag(
    table: table,
    columnIndex: columnIndex,
    source: source,
    point: point ?? this.point,
  );
}

/// 一张表的读取结果。
class _LoadedTable {
  const _LoadedTable(this.table, this.relations);

  final ErTable table;
  final List<ErRelation> relations;
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

/// 画布绘制：网格背景、关系曲线 + 箭头、拖拽预览、放置目标高亮。
class _ErCanvasPainter extends CustomPainter {
  _ErCanvasPainter({
    required this.layout,
    required this.curves,
    required this.drag,
    required this.hoveredRelation,
    required this.dropTarget,
  });

  final ErCanvasLayout layout;
  final List<ErRelationCurve> curves;
  final _ConnectDrag? drag;
  final int? hoveredRelation;
  final ErFieldRef? dropTarget;

  @override
  void paint(Canvas canvas, Size size) {
    _paintGrid(canvas, size);
    _paintDropTarget(canvas);
    for (var i = 0; i < curves.length; i++) {
      _paintCurve(canvas, curves[i], hovered: i == hoveredRelation);
    }
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
    }
  }

  void _paintCurve(
    Canvas canvas,
    ErRelationCurve curve, {
    required bool hovered,
  }) {
    final color = _colorFor(curve.relation.origin);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = hovered ? 2.6 : 1.6
      ..strokeCap = StrokeCap.round;
    final path = Path()
      ..moveTo(curve.start.dx, curve.start.dy)
      ..cubicTo(
        curve.control1.dx,
        curve.control1.dy,
        curve.control2.dx,
        curve.control2.dy,
        curve.end.dx,
        curve.end.dy,
      );
    canvas.drawPath(path, paint);
    canvas.drawCircle(curve.start, 2.6, Paint()..color = color);
    final direction = curve.endDirection;
    final length = direction.distance;
    if (length > 0) {
      final unit = direction / length;
      final normal = Offset(-unit.dy, unit.dx);
      final tip = curve.end;
      final base = tip - unit * 9;
      final arrow = Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(base.dx + normal.dx * 4, base.dy + normal.dy * 4)
        ..lineTo(base.dx - normal.dx * 4, base.dy - normal.dy * 4)
        ..close();
      canvas.drawPath(arrow, Paint()..color = color);
    }
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
    required this.onCreate,
  });

  final ErTable localTable;
  final ErTable refTable;
  final String initialLocalColumn;
  final String initialRefColumn;
  final String initialName;
  final Future<void> Function(Map<String, dynamic> payload) onCreate;

  @override
  State<_NewForeignKeyDialog> createState() => _NewForeignKeyDialogState();
}

class _NewForeignKeyDialogState extends State<_NewForeignKeyDialog> {
  late String _localColumn;
  late String _refColumn;
  late final TextEditingController _name;
  String _onDelete = '';
  String _onUpdate = '';
  String? _error;
  bool _busy = false;

  bool get _localNullable =>
      widget.localTable.columnNamed(_localColumn)?.nullable ?? true;

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
    final hint = defaultFkName(widget.localTable.name, _localColumn);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
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
        if (_error != null) ...<Widget>[
          const SizedBox(height: 8),
          AlertBox(_error!),
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
    required this.onCreate,
  });

  final ErJunctionPlan plan;
  final ErDriver driver;
  final ErTable localTable;
  final ErTable refTable;
  final Set<String> existingTableNames;
  final Future<void> Function(ErJunctionPlan plan) onCreate;

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          '同一对表之间再加一条外键会出现多条并存关系。建议自动创建中间表（多对多）；也可以仍然直接添加第二个外键。',
          style: kSmallMuted,
        ),
        const SizedBox(height: 8),
        CheckBox(
          label: '创建中间表（推荐）',
          value: !_direct,
          onChanged: (value) {
            if (value) setState(() => _direct = false);
          },
        ),
        CheckBox(
          label: '仍然直接添加第二个外键',
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
        ],
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
