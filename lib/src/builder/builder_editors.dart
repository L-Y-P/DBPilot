// Dense editor widgets build many short labels by concatenating model values;
// keeping the '+' form makes those one-liners read better than nested
// interpolation.
// ignore_for_file: prefer_interpolation_to_compose_strings
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart' hide Text, Tooltip;
import '../text.dart';
import '../tooltip.dart';

import '../i18n_literals.dart';
import '../theme.dart';
import '../widgets.dart';
import 'builder_labels.dart';
import 'builder_widgets.dart';
import 'query_model.dart';

/// One output-field chip: coloured table prefix, column, aggregate picker,
/// optional alias and a remove button. Tapping the name opens the alias editor.
///
/// A long `table.column` cannot widen the chip past the tab body, so it
/// ellipsizes; hovering the name shows the full field (round 18 requirement:
/// anything a fixed-size container shortens must be readable on hover).
class BuilderOutputChip extends StatelessWidget {
  const BuilderOutputChip({
    super.key,
    required this.field,
    required this.onAggregateChanged,
    required this.onEditAlias,
    required this.onRemove,
    this.maxWidth = 260,
  });

  final OutputField field;
  final ValueChanged<String> onAggregateChanged;
  final VoidCallback onEditAlias;
  final VoidCallback onRemove;

  /// Upper bound for the name portion; the aggregate picker and remove button
  /// keep their own width so a long identifier cannot push them off-screen.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final tone = builderToneFor(field.table);
    final full = field.alias.isEmpty
        ? field.key
        : field.key + ' AS ' + field.alias;
    return Container(
      height: 28,
      decoration: BoxDecoration(
        color: tone.bg,
        border: Border.all(color: tone.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: pickText('点击设置输出别名 · ', 'Click to set an output alias · ') + full,
            waitDuration: const Duration(milliseconds: 300),
            child: InkWell(
              borderRadius:
                  const BorderRadius.horizontal(left: Radius.circular(4)),
              onTap: onEditAlias,
              child: Padding(
                padding: const EdgeInsets.only(left: 6, right: 2),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      EllipsisText(
                        field.table + '.',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: tone.fg,
                        ),
                        tooltip: full,
                      ),
                      Flexible(
                        child: EllipsisText(
                          field.column,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: AppColors.bodyText,
                          ),
                          tooltip: full,
                        ),
                      ),
                      if (field.alias.isNotEmpty)
                        Flexible(
                          child: EllipsisText(
                            ' AS ' + field.alias,
                            style: TextStyle(
                              fontSize: 10,
                              fontStyle: FontStyle.italic,
                              color: AppColors.muted,
                            ),
                            tooltip: full,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          BuilderDrop<String>(
            value: field.aggregate,
            width: 104,
            height: 22,
            tooltip: aggregateCaption(),
            items: [
              for (final aggregate in kAggregates)
                DropdownMenuItem<String>(
                  value: aggregate,
                  child: EllipsisText(
                    aggregateLabel(aggregate),
                    tooltip: aggregateLabel(aggregate),
                    style: TextStyle(
                      fontSize: 11,
                      color: aggregate.isEmpty
                          ? AppColors.muted
                          : AppColors.bodyText,
                    ),
                  ),
                ),
            ],
            selectedLabel: aggregateLabel,
            onChanged: (value) => onAggregateChanged(value ?? ''),
          ),
          BuilderGlyphButton(
            icon: Icons.close,
            size: 12,
            tooltip: '移除输出字段',
            onPressed: onRemove,
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }
}

/// Read-only table badge used as the closed state of table dropdowns.
Widget builderTableBadge(String table, {double maxWidth = 116}) {
  return BuilderTag(
    table,
    tone: builderToneFor(table),
    icon: Icons.table_rows_outlined,
    maxWidth: maxWidth,
    // The badge is width-capped, so the full `db.table` must stay reachable by
    // hovering it — this is the exact control the round-18 report came from.
    tooltip: table,
  );
}

List<BuilderColumn> _columnsOf(List<BuilderTable> tables, String tableKey) {
  for (final entry in tables) {
    if (entry.key == tableKey) return entry.columns;
  }
  return <BuilderColumn>[];
}

BuilderTable? _findTable(List<BuilderTable> tables, String tableKey) {
  for (final entry in tables) {
    if (entry.key == tableKey) return entry;
  }
  return null;
}

/// Label for a table key inside a picker (`db.table` for cross-database).
String _tableLabel(List<BuilderTable> tables, String tableKey) {
  return _findTable(tables, tableKey)?.label ?? tableKey;
}

/// One JOIN configuration row.
class BuilderJoinRow extends StatelessWidget {
  const BuilderJoinRow({
    super.key,
    required this.index,
    required this.join,
    required this.tables,
    required this.participating,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final JoinSpec join;
  final List<BuilderTable> tables;
  final List<String> participating;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  void _autoFill() {
    autoFillJoin(join, tables);
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final leftColumns = _columnsOf(tables, join.leftTable);
    final rightColumns = _columnsOf(tables, join.rightTable);
    final leftOptions = participating.contains(join.leftTable)
        ? participating
        : <String>[
            ...participating,
            if (join.leftTable.isNotEmpty) join.leftTable
          ];
    final crossDatabaseNote = _findTable(tables, join.leftTable)?.database !=
            _findTable(tables, join.rightTable)?.database &&
        (join.leftColumn.isEmpty || join.rightColumn.isEmpty);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          BuilderDrop<String>(
            key: ValueKey('builder-join-' + index.toString() + '-left'),
            value: join.leftTable.isEmpty ? null : join.leftTable,
            width: 122,
            hint: '左表',
            tooltip: '连接左侧的表',
            items: [
              for (final table in leftOptions)
                DropdownMenuItem<String>(
                  value: table,
                  child: EllipsisText(
                    _tableLabel(tables, table),
                    tooltip: _tableLabel(tables, table),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
            selectedBuilder: (value) => builderTableBadge(value, maxWidth: 110),
            menuWidth: 260,
            onChanged: (value) {
              join.leftTable = value ?? '';
              _autoFill();
            },
          ),
          BuilderDrop<String>(
            key: ValueKey('builder-join-' + index.toString() + '-type'),
            value: join.type,
            width: 132,
            tooltip: '连接类型',
            items: [
              for (final type in kJoinTypes)
                DropdownMenuItem<String>(
                  value: type,
                  child: Tooltip(
                    message: joinTypeDescription(type),
                    constraints: kTooltipConstraints,
                    waitDuration: const Duration(milliseconds: 400),
                    child: Text(
                      joinTypeMenuLabel(type),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
            ],
            selectedLabel: joinTypeLabel,
            menuWidth: 250,
            onChanged: (value) {
              join.type = value ?? 'LEFT';
              onChanged();
            },
          ),
          BuilderDrop<String>(
            key: ValueKey('builder-join-' + index.toString() + '-right'),
            value: join.rightTable.isEmpty ? null : join.rightTable,
            width: 132,
            hint: '右表',
            tooltip: '要连接进来的表',
            items: [
              for (final table in tables)
                DropdownMenuItem<String>(
                  value: table.key,
                  child: EllipsisText(
                    table.label,
                    tooltip: table.label,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
            selectedBuilder: (value) => builderTableBadge(value, maxWidth: 120),
            menuWidth: 260,
            onChanged: (value) {
              join.rightTable = value ?? '';
              if (join.leftTable.isEmpty && participating.isNotEmpty) {
                join.leftTable = participating.first;
              }
              _autoFill();
            },
          ),
          if (!join.isCross) ...[
            Tooltip(
              message: '两表之间的匹配条件：左侧字段的值等于右侧字段的值',
              waitDuration: const Duration(milliseconds: 400),
              child: Text(onLabel(),
                  style:
                      TextStyle(fontSize: 11, color: AppColors.muted)),
            ),
            BuilderDrop<String>(
              key: ValueKey('builder-join-' + index.toString() + '-left-column'),
              value: join.leftColumn.isEmpty ? null : join.leftColumn,
              width: 148,
              hint: '左字段',
              tooltip: '匹配条件左侧字段',
              items: [
                for (final column in leftColumns)
                  DropdownMenuItem<String>(
                    value: column.name,
                    child: EllipsisText(
                      _tableLabel(tables, join.leftTable) + '.' + column.name,
                      tooltip:
                          _tableLabel(tables, join.leftTable) + '.' + column.name,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
              menuWidth: 320,
              onChanged: (value) {
                join.leftColumn = value ?? '';
                onChanged();
              },
            ),
            Tooltip(
              message: '左侧字段的值等于右侧字段的值',
              waitDuration: const Duration(milliseconds: 400),
              child: Text(joinEqualsLabel(),
                  style: TextStyle(fontSize: 12, color: AppColors.muted)),
            ),
            BuilderDrop<String>(
              key:
                  ValueKey('builder-join-' + index.toString() + '-right-column'),
              value: join.rightColumn.isEmpty ? null : join.rightColumn,
              width: 148,
              hint: '右字段',
              tooltip: '匹配条件右侧字段',
              items: [
                for (final column in rightColumns)
                  DropdownMenuItem<String>(
                    value: column.name,
                    child: EllipsisText(
                      _tableLabel(tables, join.rightTable) + '.' + column.name,
                      tooltip: _tableLabel(tables, join.rightTable) +
                          '.' +
                          column.name,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
              menuWidth: 320,
              onChanged: (value) {
                join.rightColumn = value ?? '';
                onChanged();
              },
            ),
          ],
          BuilderGlyphButton(
            icon: Icons.close,
            tooltip: '移除连接',
            onPressed: onRemove,
          ),
          if (crossDatabaseNote)
            BuilderTag(
              '跨库需手动选匹配字段',
              tone: builderWarnTone,
              icon: Icons.info_outline,
              maxWidth: 210,
              tooltip: '跨库连接无法自动推导外键，请在左侧选择两张表用于匹配的字段',
            ),
        ],
      ),
    );
  }
}

/// One condition row (top level or inside a group).
class BuilderFilterConditionRow extends StatelessWidget {
  const BuilderFilterConditionRow({
    super.key,
    required this.index,
    required this.condition,
    required this.tables,
    required this.participating,
    required this.onChanged,
    required this.onRemove,
    required this.connector,
    this.operators = kOperators,
  });

  /// 1-based display index inside its list.
  final int index;
  final FilterCondition condition;
  final List<BuilderTable> tables;
  final List<String> participating;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  /// Operators the active dialect can express (PostgreSQL adds ILIKE).
  final List<String> operators;

  /// Connector badge / picker shown before the field.
  final Widget connector;

  @override
  Widget build(BuildContext context) {
    final fieldItems = <DropdownMenuItem<String>>[];
    for (final tableName in participating) {
      final table = _findTable(tables, tableName);
      if (table == null) continue;
      for (final column in table.columns) {
        fieldItems.add(DropdownMenuItem<String>(
          value: builderFieldKey(tableName, column.name),
          child: EllipsisText(
            table.label + '.' + column.name,
            tooltip: table.label + '.' + column.name,
            style: const TextStyle(fontSize: 12),
          ),
        ));
      }
    }
    final fieldValue = condition.hasColumn
        ? builderFieldKey(condition.table, condition.column)
        : null;
    final noValue = condition.noValue;
    // A module saved before ILIKE existed (or with an operator this dialect
    // cannot express) must not crash the DropdownButton assertion: fall back to
    // showing the picker's current list and keep the stored value selectable.
    final ops = <String>[
      ...operators,
      if (!operators.contains(condition.op)) condition.op,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 18,
            child: Text(
              index.toString().padLeft(2, '0'),
              style: monoStyle(size: 10, color: AppColors.nullText),
            ),
          ),
          connector,
          BuilderDrop<String>(
            value: fieldValue,
            width: 214,
            hint: '选择字段',
            tooltip: '条件字段',
            items: fieldItems,
            menuWidth: 320,
            onChanged: (value) {
              if (value == null) return;
              final parts = splitBuilderFieldKey(value);
              condition.table = parts.$1;
              condition.column = parts.$2;
              onChanged();
            },
          ),
          BuilderDrop<String>(
            value: condition.op,
            width: 178,
            tooltip: operatorDescription(condition.op),
            items: [
              for (final op in ops)
                DropdownMenuItem<String>(
                  value: op,
                  child: EllipsisText(
                    operatorLabel(op),
                    tooltip: operatorLabel(op),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
            selectedLabel: operatorLabel,
            menuWidth: 260,
            onChanged: (value) {
              condition.op = value ?? '=';
              onChanged();
            },
          ),
          if (!noValue)
            SizedBox(
              width: 176,
              child: _BuilderConditionValueField(
                condition: condition,
                hint: condition.op == 'IN' ? '值1, 值2' : '输入值…',
                onChanged: onChanged,
              ),
            ),
          BuilderGlyphButton(
            icon: Icons.close,
            tooltip: '移除条件',
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// Value input that keeps its own controller but stays in sync with the model
/// (load, operator switches and external resets all update the visible text).
class _BuilderConditionValueField extends StatefulWidget {
  const _BuilderConditionValueField({
    required this.condition,
    required this.hint,
    required this.onChanged,
  });

  final FilterCondition condition;
  final String hint;
  final VoidCallback onChanged;

  @override
  State<_BuilderConditionValueField> createState() =>
      _BuilderConditionValueFieldState();
}

class _BuilderConditionValueFieldState
    extends State<_BuilderConditionValueField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.condition.value);

  @override
  void didUpdateWidget(covariant _BuilderConditionValueField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_controller.text != widget.condition.value) {
      _controller.text = widget.condition.value;
      _controller.selection =
          TextSelection.collapsed(offset: _controller.text.length);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return builderCompactField(
      controller: _controller,
      hint: widget.hint,
      onChanged: (value) {
        widget.condition.value = value;
        widget.onChanged();
      },
    );
  }
}

/// AND / OR group card inside the filter section.
class BuilderFilterGroupCard extends StatelessWidget {
  const BuilderFilterGroupCard({
    super.key,
    required this.entry,
    required this.tables,
    required this.participating,
    required this.onChanged,
    required this.onRemove,
    required this.onAddChild,
    this.operators = kOperators,
  });

  final FilterEntry entry;
  final List<BuilderTable> tables;
  final List<String> participating;
  final VoidCallback onChanged;
  final VoidCallback onRemove;
  final VoidCallback onAddChild;
  final List<String> operators;

  @override
  Widget build(BuildContext context) {
    final tone = entry.logic == 'OR' ? builderWarnTone : builderInfoTone;
    final accent = entry.logic == 'OR' ? AppColors.accent : AppColors.link;
    final header = Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        BuilderTag(
          filterGroupTitle(entry.logic),
          tone: tone,
          icon: Icons.account_tree_outlined,
          tooltip: entry.logic == 'OR'
              ? '组内任意一个条件满足即可'
              : '组内条件需要全部满足',
        ),
        Text(connectorCaption(),
            style: TextStyle(fontSize: 11, color: AppColors.muted)),
        BuilderDrop<String>(
          value: entry.connector,
          width: 104,
          tooltip: '这一组条件与上方条件如何组合',
          items: [
            for (final logic in <String>['AND', 'OR'])
              DropdownMenuItem<String>(
                value: logic,
                child: EllipsisText(connectorLabel(logic),
                    tooltip: connectorLabel(logic),
                    style: const TextStyle(fontSize: 12)),
              ),
          ],
          selectedLabel: connectorLabel,
          menuWidth: 170,
          onChanged: (value) {
            entry.connector = value ?? 'AND';
            onChanged();
          },
        ),
        Text(groupConnectorCaption(),
            style: TextStyle(fontSize: 11, color: AppColors.muted)),
        BuilderTag(connectorLabel(entry.logic), tone: tone),
        Btn('+ 组内条件', small: true, onPressed: onAddChild),
        BuilderGlyphButton(
          icon: Icons.close,
          tooltip: '移除分组',
          onPressed: onRemove,
        ),
      ],
    );
    final children = <Widget>[];
    for (var i = 0; i < entry.children.length; i++) {
      final condition = entry.children[i];
      children.add(BuilderFilterConditionRow(
        key: ObjectKey(condition),
        index: i + 1,
        condition: condition,
        tables: tables,
        participating: participating,
        operators: operators,
        connector: BuilderTag(
          i == 0 ? '组内' : connectorLabel(entry.logic),
          tone: i == 0 ? builderNeutralTone : tone,
          maxWidth: 110,
          tooltip: i == 0 ? null : groupConnectorCaption(),
        ),
        onChanged: onChanged,
        onRemove: () {
          entry.children.removeAt(i);
          onChanged();
        },
      ));
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 3, color: accent),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    header,
                    const SizedBox(height: 8),
                    if (entry.children.isEmpty)
                      Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text('还没有组内条件',
                            style: TextStyle(
                                fontSize: 11, color: AppColors.muted)),
                      )
                    else
                      ...children,
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One ORDER BY chip.
class BuilderSortChip extends StatelessWidget {
  const BuilderSortChip({
    super.key,
    required this.order,
    required this.onChanged,
    required this.onRemove,
  });

  final OrderSpec order;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final full = order.table + '.' + order.column;
    return Container(
      height: 28,
      decoration: BoxDecoration(
        color: AppColors.chipBg,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 6, right: 2),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: EllipsisText(
                full,
                style: monoStyle(size: 11.5),
                tooltip: pickText('排序字段：', 'Sort column: ') + full,
              ),
            ),
          ),
          BuilderDrop<String>(
            value: order.dir,
            width: 118,
            height: 22,
            tooltip: '排序方向',
            items: [
              for (final dir in <String>['ASC', 'DESC'])
                DropdownMenuItem<String>(
                  value: dir,
                  child: EllipsisText(orderDirectionLabel(dir),
                      tooltip: orderDirectionLabel(dir),
                      style: const TextStyle(fontSize: 11)),
                ),
            ],
            selectedLabel: orderDirectionLabel,
            menuWidth: 150,
            onChanged: (value) {
              order.dir = value ?? 'ASC';
              onChanged();
            },
          ),
          BuilderGlyphButton(
            icon: Icons.close,
            size: 12,
            tooltip: '移除排序',
            onPressed: onRemove,
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }
}

/// LIMIT field for the sorting tab.
///
/// There is deliberately no user-set "max return": the result preview always
/// caps itself (and says so), while export streams the complete result.
class BuilderLimitFields extends StatelessWidget {
  const BuilderLimitFields({
    super.key,
    required this.limitController,
    required this.onLimitChanged,
  });

  final TextEditingController limitController;
  final ValueChanged<String> onLimitChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(limitLabel(),
            style: TextStyle(fontSize: 11, color: AppColors.muted)),
        SizedBox(
          width: 76,
          child: builderCompactField(
            fieldKey: const ValueKey('builder-limit'),
            controller: limitController,
            numeric: true,
            hint: '100',
            onChanged: onLimitChanged,
          ),
        ),
        const SizedBox(width: 4),
        Tooltip(
          message: '结果预览固定最多展示 1000 行；完整结果请用「导出结果」',
          waitDuration: Duration(milliseconds: 300),
          child: Icon(Icons.info_outline, size: 13, color: AppColors.muted),
        ),
      ],
    );
  }
}

/// One header cell of the result preview.
class BuilderPreviewColumn {
  const BuilderPreviewColumn(this.name, [this.type = '']);

  final String name;
  final String type;
}

/// Lightweight read-only result table (the design's result preview card).
///
/// Wide results are **column-virtualised**: a 40-column page kept ~950 cells in
/// every visible row, and because the rows are re-inflated whenever the page or
/// the result changes, that was the most expensive thing on the builder page
/// (measured ~270ms per page turn in debug). Only the columns that intersect the
/// viewport are built; the rest is a single spacer that preserves the row width
/// and the horizontal scroll range. Vertically the [ListView] already builds
/// only the visible rows.
class BuilderPreviewTable extends StatefulWidget {
  const BuilderPreviewTable({
    super.key,
    required this.columns,
    required this.rows,
  });

  final List<BuilderPreviewColumn> columns;
  final List<List<Object?>> rows;

  static const double _rowHeight = 30;
  static const double _minColumnWidth = 140;

  @override
  State<BuilderPreviewTable> createState() => _BuilderPreviewTableState();
}

class _BuilderPreviewTableState extends State<BuilderPreviewTable> {
  static const double _rowHeight = BuilderPreviewTable._rowHeight;
  static const double _minColumnWidth = BuilderPreviewTable._minColumnWidth;

  /// Bottom strip reserved for the horizontal scrollbar thumb.
  ///
  /// The thumb is painted *over* the scroll view's bottom edge, so without this
  /// gutter it would sit on top of the last visible row (the same reason
  /// `DataGrid` pads its short-table branch by 10px).
  static const double _scrollbarGutter = 10;

  /// Horizontal scroll offset, used to pick the visible column range.
  final ScrollController _horizontal = ScrollController();
  double _offset = 0;

  @override
  void initState() {
    super.initState();
    _horizontal.addListener(_onScroll);
  }

  @override
  void dispose() {
    _horizontal.removeListener(_onScroll);
    _horizontal.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_horizontal.hasClients) return;
    final next = _horizontal.offset;
    // One setState per scrolled pixel is fine: the rebuild only covers the
    // visible columns, and the range check keeps it from thrashing.
    if ((next - _offset).abs() >= 1) {
      setState(() => _offset = next);
    }
  }

  @override
  void didUpdateWidget(covariant BuilderPreviewTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different result set resets the horizontal position: the old offset may
    // point past the end of the new table, which would build no columns at all.
    // Paging keeps the columns, so the offset is only reset when the column
    // list itself changes.
    if (!identical(oldWidget.columns, widget.columns)) {
      _offset = 0;
      if (_horizontal.hasClients) _horizontal.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final columns = widget.columns;
    if (columns.isEmpty) {
      // Not const: the copy is translated when the widget builds, and a const
      // instance would keep the previous language after a switch (P3-08a).
      return BuilderEmptyHint(
        icon: Icons.table_view_outlined,
        text: trLiteral('执行查询后在这里预览结果'),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // The surrounding Container draws a 1px border on each side, so the
        // inner layout width is two pixels narrower than maxWidth.
        final viewport = constraints.maxWidth.isFinite
            ? (constraints.maxWidth - 2).clamp(1.0, double.infinity)
            : _minColumnWidth * columns.length;
        final naturalWidth = _minColumnWidth * columns.length;
        final tableWidth = naturalWidth > viewport ? naturalWidth : viewport;
        final columnWidth = tableWidth / columns.length;
        // When the table fits, every column is on screen; otherwise pick the
        // range that intersects the viewport from the (clamped) scroll offset.
        // Clamping matters after a re-run with fewer columns: a stale offset
        // must not put the first visible column past the last one.
        final maxOffset = (tableWidth - viewport).clamp(0.0, double.infinity);
        final offset = _offset.clamp(0.0, maxOffset);
        final first = maxOffset == 0
            ? 0
            : (offset / columnWidth).floor().clamp(0, columns.length);
        final last = maxOffset == 0
            ? columns.length
            : ((offset + viewport) / columnWidth)
                .ceil()
                .clamp(first, columns.length);
        final table = SizedBox(
          width: tableWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(columnWidth, first, last),
              Expanded(
                child: widget.rows.isEmpty
                    ? BuilderEmptyHint(
                        icon: Icons.inbox_outlined,
                        text: trLiteral('查询没有返回数据行'),
                        padding: EdgeInsets.symmetric(vertical: 10),
                      )
                    : ScrollConfiguration(
                        behavior: _verticalBehavior(),
                        child: ListView.builder(
                          padding: EdgeInsets.zero,
                          itemCount: widget.rows.length,
                          itemExtent: _rowHeight,
                          itemBuilder: (context, index) =>
                              _row(index, columnWidth, first, last),
                        ),
                      ),
              ),
            ],
          ),
        );
        if (tableWidth <= viewport) {
          return Container(
            decoration: _borderDecoration(),
            clipBehavior: Clip.antiAlias,
            child: table,
          );
        }
        // Round 27 (reported: "结果预览无法左右拖动"): a wide result only
        // scrolled through the trackpad / shift+wheel. There was no scrollbar to
        // grab, and desktop scroll views ignore mouse drags by default (the
        // mouse is not one of [ScrollBehavior.dragDevices]), so with a mouse the
        // clipped columns on the right were simply unreachable.
        final baseBehavior = ScrollConfiguration.of(context);
        return Container(
          decoration: _borderDecoration(),
          clipBehavior: Clip.antiAlias,
          child: ScrollbarTheme(
            // The app-wide scrollbar thumb is a 33% black (`0x55000000`), which
            // is invisible on the dark palette's panel (`#161D26`): composited it
            // lands within ~7/255 of the background, so the wide preview looked
            // like it had no scrollbar at all even though the bar was mounted.
            // Tint it towards the current text colour instead so it reads on
            // both palettes.
            data: ScrollbarTheme.of(context).copyWith(
              thickness: const WidgetStatePropertyAll<double>(8),
              radius: const Radius.circular(4),
              thumbColor: WidgetStateProperty.resolveWith((states) =>
                  AppColors.muted.withValues(
                      alpha: states.contains(WidgetState.hovered) ? 0.55 : 0.38)),
            ),
            child: Scrollbar(
              controller: _horizontal,
              thumbVisibility: true,
              // Only the horizontal notifications belong to this bar; those from
              // the inner vertical [ListView] bubble up with depth 1.
              notificationPredicate: (notification) =>
                  notification.depth == 0,
              child: ScrollConfiguration(
                // Let the table itself be grabbed and dragged sideways, in
                // addition to the scrollbar thumb.
                behavior: baseBehavior.copyWith(
                  dragDevices: <PointerDeviceKind>{
                    ...baseBehavior.dragDevices,
                    PointerDeviceKind.mouse,
                  },
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  controller: _horizontal,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: _scrollbarGutter),
                    child: table,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  BoxDecoration _borderDecoration() => BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(4),
      );

  /// The touch-like drag devices Flutter enables by default.
  ///
  /// Deliberately **without** [PointerDeviceKind.mouse]: see
  /// [_verticalBehavior].
  static const Set<PointerDeviceKind> _wheelOnlyDragDevices =
      <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.unknown,
  };

  /// Behaviour for the inner vertical [ListView].
  ///
  /// The outer horizontal scroller adds [PointerDeviceKind.mouse] to
  /// [ScrollBehavior.dragDevices] so the table itself can be grabbed and pulled
  /// sideways (round 27). That setting is inherited by the nested vertical list,
  /// and a mouse drag with *any* vertical component then has **two** competitors
  /// in the gesture arena. The [VerticalDragGestureRecognizer] wins that contest:
  /// it is added first and self-declares as soon as `dy` clears the 1px
  /// precise-pointer hit slop, while the horizontal one only reacts to `dx`.
  /// A real mouse drag always wobbles a pixel or two vertically, so the
  /// horizontal offset stayed at exactly 0px — "拖不动" — even though the
  /// scrollbar and the dragDevices were both in place (round 27's tests dragged
  /// on a perfectly horizontal path, which is why they stayed green).
  ///
  /// Giving the vertical list the touch-like devices only removes it from the
  /// arena for mouse pointers, leaving the horizontal scroller as the sole drag
  /// competitor. Vertical scrolling is unchanged: rows still scroll with the
  /// wheel / trackpad, which is what the preview used before round 27.
  ScrollBehavior _verticalBehavior() => ScrollConfiguration.of(context)
      .copyWith(dragDevices: _wheelOnlyDragDevices);

  Widget _header(double columnWidth, int first, int last) {
    return Container(
      height: _rowHeight,
      decoration: BoxDecoration(
        color: AppColors.chipBg,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          if (first > 0) SizedBox(width: first * columnWidth),
          for (var column = first; column < last; column++)
            SizedBox(
              width: columnWidth,
              child: Tooltip(
                message: widget.columns[column].type.isEmpty
                    ? widget.columns[column].name
                    : widget.columns[column].name +
                        ' · ' +
                        widget.columns[column].type,
                constraints: kTooltipConstraints,
                waitDuration: const Duration(milliseconds: 300),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      widget.columns[column].name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.cardHeading,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (last < widget.columns.length)
            SizedBox(width: (widget.columns.length - last) * columnWidth),
        ],
      ),
    );
  }

  Widget _row(int index, double columnWidth, int first, int last) {
    final values = widget.rows[index];
    return Container(
      decoration: BoxDecoration(
        color: index.isEven ? AppColors.panel : AppColors.rowEven,
        border: const Border(
          bottom: BorderSide(color: Color(0xFFEDF0F4)),
        ),
      ),
      child: Row(
        children: [
          if (first > 0) SizedBox(width: first * columnWidth),
          for (var column = first; column < last; column++)
            SizedBox(
              width: columnWidth,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _cell(column < values.length ? values[column] : null),
                ),
              ),
            ),
          if (last < widget.columns.length)
            SizedBox(width: (widget.columns.length - last) * columnWidth),
        ],
      ),
    );
  }

  Widget _cell(Object? value) {
    if (value == null) {
      return Text(
        'NULL',
        style: TextStyle(
          fontSize: 11.5,
          fontStyle: FontStyle.italic,
          color: AppColors.nullText,
        ),
      );
    }
    final text = value.toString();
    // Round 18: a clipped cell must expose the *whole* value on hover — the
    // previous version cut the hover text at 120 characters, so the long tail
    // was unreachable anywhere in the preview. The bubble is width-bounded and
    // wraps instead (an unbounded tooltip renders as one very wide line).
    return EllipsisText(
      text,
      maxLines: 1,
      style: TextStyle(fontSize: 11.5, color: AppColors.bodyText),
      tooltipMaxWidth: 480,
    );
  }
}

/// Pagination control for the result preview (page size is fixed by the view).
class BuilderPagination extends StatelessWidget {
  const BuilderPagination({
    super.key,
    required this.page,
    required this.pageCount,
    required this.totalRows,
    required this.pageSize,
    required this.onPage,
  });

  final int page;
  final int pageCount;
  final int totalRows;
  final int pageSize;
  final ValueChanged<int> onPage;

  List<Object> _pageSlots() {
    if (pageCount <= 7) {
      return <Object>[for (var i = 0; i < pageCount; i++) i];
    }
    final slots = <Object>[0];
    final start = (page - 1).clamp(1, pageCount - 4);
    if (start > 1) slots.add('…');
    for (var i = start; i < start + 3 && i < pageCount - 1; i++) {
      slots.add(i);
    }
    if (start + 3 < pageCount - 1) slots.add('…');
    slots.add(pageCount - 1);
    return slots;
  }

  @override
  Widget build(BuildContext context) {
    final slots = _pageSlots();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          pickText(
            '第 ' + (page + 1).toString() + ' 页 · 共 ' + totalRows.toString() + ' 条',
            'Page ' +
                (page + 1).toString() +
                ' of ' +
                totalRows.toString(),
          ),
          style: TextStyle(fontSize: 11, color: AppColors.muted),
        ),
        const SizedBox(width: 6),
        _PageButton(
          icon: Icons.chevron_left,
          tooltip: '上一页',
          onPressed: page > 0 ? () => onPage(page - 1) : null,
        ),
        for (final slot in slots) ...[
          const SizedBox(width: 3),
          if (slot is String)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 2),
              child: Text('…',
                  style: TextStyle(fontSize: 11, color: AppColors.muted)),
            )
          else
            _PageButton(
              label: ((slot as int) + 1).toString(),
              active: slot == page,
              onPressed: () => onPage(slot),
            ),
        ],
        const SizedBox(width: 3),
        _PageButton(
          icon: Icons.chevron_right,
          tooltip: '下一页',
          onPressed: page < pageCount - 1 ? () => onPage(page + 1) : null,
        ),
      ],
    );
  }
}

class _PageButton extends StatelessWidget {
  const _PageButton({
    this.label,
    this.icon,
    this.active = false,
    this.onPressed,
    this.tooltip,
  });

  final String? label;
  final IconData? icon;
  final bool active;
  final VoidCallback? onPressed;
  final String? tooltip;

  /// Page cells were 24px with a 15px glyph, which read as tiny dots next to
  /// the 26px toolbar controls; 28/18 gives the chevrons a comfortable hit
  /// target without making the footer taller than the buttons beside it.
  static const double _box = 28;
  static const double _glyph = 18;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final cell = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          width: _box,
          height: _box,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? AppColors.header : AppColors.panel,
            border: Border.all(
                color: active ? AppColors.header : AppColors.border),
            borderRadius: BorderRadius.circular(4),
          ),
          child: icon != null
              ? Icon(
                  icon,
                  size: _glyph,
                  color: enabled
                      ? (active ? Colors.white : AppColors.muted)
                      : AppColors.nullText,
                )
              : Text(
                  label ?? '',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                    color: active
                        ? Colors.white
                        : (enabled ? AppColors.bodyText : AppColors.nullText),
                  ),
                ),
        ),
      ),
    );
    if (tooltip == null) return cell;
    return Tooltip(message: tooltip!, child: cell);
  }
}
