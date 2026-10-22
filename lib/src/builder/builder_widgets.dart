// Builder labels are assembled from model values in many one-line expressions;
// explicit concatenation keeps them readable.
// ignore_for_file: prefer_interpolation_to_compose_strings
import 'package:flutter/material.dart' hide Text, Tooltip;
import '../text.dart';
import '../tooltip.dart';
import 'package:flutter/services.dart';

import '../i18n_literals.dart';
import '../theme.dart';
import '../widgets.dart';
import 'query_model.dart';

/// Shared visual language for the rewritten query builder.
///
/// The design sketch uses indigo accents and very round chips; this app's
/// tokens are the navy / slate palette from the rest of the desktop port, so
/// the builder reuses those colours rather than introducing a second theme.
class BuilderTone {
  const BuilderTone({
    required this.bg,
    required this.fg,
    required this.border,
  });

  final Color bg;
  final Color fg;
  final Color border;
}

/// Tone used for the "主表" badge (the app's primary colour).
BuilderTone builderPrimaryTone = BuilderTone(
  bg: AppColors.header,
  fg: Colors.white,
  border: AppColors.header,
);

BuilderTone builderNeutralTone = BuilderTone(
  bg: AppColors.chipBg,
  fg: AppColors.cardHeading,
  border: AppColors.border,
);

BuilderTone builderInfoTone = BuilderTone(
  bg: AppColors.infoBg,
  fg: AppColors.infoText,
  border: AppColors.infoBorder,
);

BuilderTone builderOkTone = BuilderTone(
  bg: AppColors.okBg,
  fg: AppColors.okText,
  border: AppColors.okBorder,
);

const BuilderTone builderPurpleTone = BuilderTone(
  bg: Color(0xFFF3EFFA),
  fg: Color(0xFF5B3E96),
  border: Color(0xFFD9CDF0),
);

BuilderTone builderWarnTone = BuilderTone(
  bg: AppColors.warnBg,
  fg: AppColors.warnText,
  border: AppColors.warnBorder,
);

final List<BuilderTone> _tableTones = <BuilderTone>[
  builderInfoTone,
  builderOkTone,
  builderWarnTone,
  builderPurpleTone,
  builderNeutralTone,
];

/// Stable per-table colour, so a table looks identical in every picker / chip.
BuilderTone builderToneFor(String table) {
  if (table.isEmpty) return builderNeutralTone;
  var hash = 0;
  for (final unit in table.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return _tableTones[hash % _tableTones.length];
}

/// Small rounded label, the desktop port's Pill with an optional leading icon
/// and a builder-specific tone.
class BuilderTag extends StatelessWidget {
  const BuilderTag(
    this.label, {
    super.key,
    this.tone,
    this.icon,
    this.tooltip,
    this.maxWidth,
  });

  final String label;

  /// Null keeps the historical default ([builderNeutralTone]), resolved in
  /// [build]: a `const` constructor cannot default to a runtime-palette tone.
  final BuilderTone? tone;
  final IconData? icon;
  final String? tooltip;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final tone = this.tone ?? builderNeutralTone;
    final tag = Container(
      constraints: BoxConstraints(maxWidth: maxWidth ?? 220),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: tone.bg,
        border: Border.all(color: tone.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: tone.fg),
            const SizedBox(width: 3),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.3,
                color: tone.fg,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
    // A tag is always width-capped ([maxWidth]), so its label can be cut off.
    // Default the hover text to the full label; a tag that adds its own tooltip
    // must not lose the complete value, so the two are joined.
    //
    // Both halves are UI copy and are translated individually: the composed
    // message never matches a dictionary entry, so leaving it raw would leak
    // Chinese into the English tooltip.
    final message = tooltip == null
        ? trLiteral(label)
        : (tooltip == label
            ? trLiteral(tooltip!)
            : trLiteral(label) + '\n' + trLiteral(tooltip!));
    return Tooltip(
      message: message,
      // A tag label is UI copy ("主表", "接入"); a caller-supplied tooltip is
      // translated too by the wrapper. Data values never reach this widget.
      constraints: kTooltipConstraints,
      waitDuration: const Duration(milliseconds: 300),
      child: tag,
    );
  }
}

/// Compact dropdown matching the builder's dense controls (28px high).
///
/// [selectedBuilder] lets the caller render the closed state as a coloured
/// table badge while the menu keeps plain text entries.
class BuilderDrop<T> extends StatelessWidget {
  const BuilderDrop({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.width,
    this.height = 28,
    this.hint = '选择',
    this.enabled = true,
    this.selectedBuilder,
    this.selectedLabel,
    this.tooltip,
    this.menuWidth,
  });

  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final double? width;
  final double height;
  final String hint;
  final bool enabled;
  final Widget Function(T value)? selectedBuilder;

  /// Optional display text for the closed state when the caller does not build
  /// a custom [selectedBuilder]. It lets the builder translate a value to a
  /// human-readable label (e.g. `LEFT` -> 左连接) without changing the stored
  /// SQL token.
  final String Function(T value)? selectedLabel;

  final String? tooltip;

  /// Minimum width of the open menu. A narrow control (122px table picker) used
  /// to truncate every entry in its own menu, so the name the user came to pick
  /// was never readable. The menu is allowed to be wider than the button.
  final double? menuWidth;

  @override
  Widget build(BuildContext context) {
    final hasValue = value != null && items.any((item) => item.value == value);
    final label = hasValue && selectedLabel != null && selectedBuilder == null
        ? selectedLabel!(value as T)
        : null;
    // Menu rows stay one line with a hover tooltip. The open menu is an overlay,
    // so the closed control's tooltip never applies to it; without this a long
    // table/column name was clipped inside the menu with no way to read it, and
    // a very long one turned the row into a multi-line block (measured 600px).
    final boundedItems = <DropdownMenuItem<T>>[
      for (final item in items)
        DropdownMenuItem<T>(
          value: item.value,
          enabled: item.enabled,
          child: Tooltip(
            message: _builderItemText(item.child),
            constraints: kTooltipConstraints,
            waitDuration: const Duration(milliseconds: 400),
            child: DefaultTextStyle.merge(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              child: item.child,
            ),
          ),
        ),
    ];
    final dropdown = DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        value: hasValue ? value : null,
        hint: Text(
          hint,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: AppColors.muted),
        ),
        items: boundedItems,
        // DropdownButton inflates an IndexedStack over every entry for the
        // closed state, so the tooltip-wrapped menu items must not be built
        // there: a 40-column picker created 40 Tooltips (MouseRegion +
        // AnimationController) per rebuild. The closed state uses plain
        // one-line Texts; the rich items are inflated only when the menu opens.
        selectedItemBuilder: selectedBuilder != null
            ? (context) => items
                .map((item) => selectedBuilder!(item.value as T))
                .toList()
            : (context) => items
                .map((item) => Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        label != null
                            ? selectedLabel!(item.value as T)
                            : _builderItemText(item.child),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: AppColors.bodyText),
                      ),
                    ))
                .toList(),
        onChanged: enabled ? onChanged : null,
        isDense: true,
        isExpanded: true,
        focusColor: Colors.transparent,
        style: TextStyle(fontSize: 12, color: AppColors.bodyText),
        icon: Icon(Icons.expand_more, size: 14, color: AppColors.muted),
        dropdownColor: AppColors.panel,
        menuMaxHeight: 320,
        menuWidth: menuWidth,
        borderRadius: BorderRadius.circular(AppMetrics.radiusControl),
      ),
    );
    final box = Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: enabled ? AppColors.panel : AppColors.chipBg,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: dropdown,
    );
    final sized = SizedBox(width: width, child: box);
    // The closed state is clipped to [width]; hovering it must reveal the value
    // (round-18: every truncating container is readable on hover).
    final full = label ?? (hasValue ? value.toString() : hint);
    // [full] may be a data value (a database name), so only the caption half is
    // translated; the separator follows the active language.
    final message = tooltip == null
        ? full
        : (tooltip == full
            ? tooltip!
            : trLiteral(tooltip!) + pickText('：', ': ') + full);
    return Tooltip(
      message: message,
      constraints: kTooltipConstraints,
      waitDuration: const Duration(milliseconds: 300),
      child: sized,
    );
  }
}

/// Muted icon + text block for "nothing here yet" states inside a card.
class BuilderEmptyHint extends StatelessWidget {
  const BuilderEmptyHint({
    super.key,
    required this.icon,
    required this.text,
    this.padding = const EdgeInsets.symmetric(vertical: 18),
    this.action,
  });

  final IconData icon;
  final String text;
  final EdgeInsets padding;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 22, color: AppColors.nullText),
          const SizedBox(height: 6),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppColors.muted),
          ),
          if (action != null) ...[const SizedBox(height: 8), action!],
        ],
      ),
    );
  }
}

/// Borderless 22px icon button used inside dense tree rows.
class BuilderGlyphButton extends StatelessWidget {
  const BuilderGlyphButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.color,
    this.size = 16,
    this.boxSize = 22,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  /// Null keeps the historical default ([AppColors].muted), resolved in [build]:
  /// a `const` constructor cannot default to a palette-derived value.
  final Color? color;
  final double size;
  final double boxSize;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final button = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onPressed,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: boxSize,
          height: boxSize,
          child: Icon(
            icon,
            size: size,
            color: enabled ? (color ?? AppColors.muted) : AppColors.nullText,
          ),
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// Best-effort plain text of a menu item's child, for its hover tooltip.
String _builderItemText(Widget child) {
  final data = sourceTextOf(child);
  if (data != null) return data;
  // Builder items are usually `Text`; `EllipsisText` wraps one, so read the
  // label out of the widget so the tooltip still carries the full value.
  return child is EllipsisText ? child.text : '';
}

/// Dense 28px text field used by the LIMIT / max-return / filter-value inputs.
Widget builderCompactField({
  TextEditingController? controller,
  String? hint,
  ValueChanged<String>? onChanged,
  bool numeric = false,
  bool enabled = true,
  double height = 28,
  Key? fieldKey,
}) {
  return SizedBox(
    height: height,
    child: TextField(
      key: fieldKey,
      controller: controller,
      enabled: enabled,
      keyboardType: numeric ? TextInputType.number : null,
      inputFormatters: numeric
          ? <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly]
          : null,
      onChanged: onChanged,
      style: TextStyle(fontSize: 12, color: AppColors.bodyText),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint == null ? null : trLiteral(hint),
        hintStyle: TextStyle(fontSize: 12, color: AppColors.muted),
        filled: true,
        fillColor: enabled ? AppColors.panel : AppColors.chipBg,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: AppColors.focusBorder, width: 1.5),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: AppColors.border),
        ),
      ),
    ),
  );
}

/// The fixed-size data source panel on the left of the builder.
///
/// Selection rules (per the follow-up review):
///  * the first click on a table defines the primary table (FROM);
///  * once a primary exists, every later click adds / removes that table as a
///    joined ("接入") table, however many joins already exist;
///  * clicking an already selected table again cancels that selection.
///
/// The panel itself never grows: the tree scrolls internally and every
/// truncated name carries a tooltip with the full value. Fields only show a
/// leading add indicator when they are part of the query; joining a table is
/// done from its row, so the tree stays quiet.
class BuilderDataSourcePanel extends StatefulWidget {
  const BuilderDataSourcePanel({
    super.key,
    required this.tables,
    required this.primaryTable,
    required this.participating,
    required this.outputKeys,
    required this.loading,
    required this.enabled,
    required this.onToggleTable,
    required this.onToggleOutput,
    this.error,
    this.groupByDatabase = false,
    this.deniedDatabases = const <String>[],
  });

  final List<BuilderTable> tables;
  final String? primaryTable;
  final Set<String> participating;
  final Set<String> outputKeys;
  final bool loading;
  final String? error;
  final bool enabled;

  /// Clicking a table row: set it as primary, toggle it as a joined table, or
  /// clear the selection when it is already selected.
  final ValueChanged<String> onToggleTable;
  final void Function(String table, String column) onToggleOutput;

  /// Advanced (cross-database) mode: show the namespace of each table and
  /// group the tree by database.
  final bool groupByDatabase;

  /// Namespaces the server rejected; shown as a muted note, never as tables.
  final List<String> deniedDatabases;

  @override
  State<BuilderDataSourcePanel> createState() => _BuilderDataSourcePanelState();
}

class _BuilderDataSourcePanelState extends State<BuilderDataSourcePanel> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final Set<String> _expanded = <String>{};

  @override
  void didUpdateWidget(covariant BuilderDataSourcePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Expanding the primary automatically makes its fields reachable.
    final primary = widget.primaryTable;
    if (primary != null && primary != oldWidget.primaryTable) {
      _expanded.add(primary);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _active(String table) =>
      table == widget.primaryTable || widget.participating.contains(table);

  List<BuilderTable> get _visibleTables {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return widget.tables;
    return widget.tables.where((table) {
      if (table.name.toLowerCase().contains(query)) return true;
      return table.columns
          .any((column) => column.name.toLowerCase().contains(query));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppMetrics.radiusCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: AppColors.infoBg,
                  borderRadius: BorderRadius.all(Radius.circular(6)),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.table_chart_outlined,
                    size: 15, color: AppColors.infoText),
              ),
              const SizedBox(width: 8),
              Text(
                '数据源',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.cardHeading,
                ),
              ),
              const Spacer(),
              if (widget.tables.isNotEmpty)
                Pill(widget.tables.length.toString()),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 30,
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                isDense: true,
                hintText: trLiteral('搜索表 / 字段…'),
                hintStyle:
                    TextStyle(fontSize: 12, color: AppColors.muted),
                prefixIcon:
                    Icon(Icons.search, size: 15, color: AppColors.muted),
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 30, minHeight: 30),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : BuilderGlyphButton(
                        icon: Icons.close,
                        size: 13,
                        tooltip: '清空搜索',
                        onPressed: () {
                          _search.clear();
                          setState(() {});
                        },
                      ),
                suffixIconConstraints:
                    const BoxConstraints(minWidth: 28, minHeight: 28),
                filled: true,
                fillColor: AppColors.panel,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide:
                      BorderSide(color: AppColors.focusBorder, width: 1.5),
                ),
              ),
            ),
          ),
          if (widget.deniedDatabases.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline, size: 12, color: AppColors.warnText),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '无权限已跳过：' + widget.deniedDatabases.join('、'),
                    style: TextStyle(fontSize: 10, color: AppColors.warnText),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Divider(height: 1, color: AppColors.border),
          const SizedBox(height: 4),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (widget.loading) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (widget.error != null) {
      return BuilderEmptyHint(
        icon: Icons.error_outline,
        text: widget.error!,
      );
    }
    if (widget.tables.isEmpty) {
      // Not const: the copy is translated when the widget builds, and a const
      // instance would keep the previous language after a switch (P3-08a).
      return BuilderEmptyHint(
        icon: Icons.storage_outlined,
        text: trLiteral('该数据源没有数据表'),
      );
    }
    final tables = _visibleTables;
    if (tables.isEmpty) {
      return BuilderEmptyHint(
        icon: Icons.search_off,
        text: trLiteral('没有匹配的表或字段'),
      );
    }
    final items = <Widget>[];
    if (widget.groupByDatabase) {
      final groups = <String, List<BuilderTable>>{};
      for (final table in tables) {
        groups.putIfAbsent(table.database, () => <BuilderTable>[]).add(table);
      }
      for (final entry in groups.entries) {
        items.add(_databaseHeader(entry.key));
        for (final table in entry.value) {
          items.add(_tableTile(table));
        }
      }
    } else {
      for (final table in tables) {
        items.add(_tableTile(table));
      }
    }
    return Scrollbar(
      controller: _scroll,
      thumbVisibility: true,
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.only(bottom: 8),
        itemCount: items.length,
        itemBuilder: (context, index) => items[index],
      ),
    );
  }

  Widget _databaseHeader(String database) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 2),
      child: Row(
        children: [
          Icon(Icons.storage_outlined, size: 12, color: AppColors.muted),
          const SizedBox(width: 4),
          Expanded(
            child: EllipsisText(
              database.isEmpty ? '当前数据源' : database,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: AppColors.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tableTile(BuilderTable table) {
    final key = table.key;
    final isPrimary = widget.primaryTable == key;
    final isJoined = !isPrimary && widget.participating.contains(key);
    final expanded = _expanded.contains(key);
    final tone = builderToneFor(key);
    final selected = isPrimary || isJoined;
    final row = Material(
      key: ValueKey('builder-table-' + key),
      color: isPrimary ? tone.bg : (isJoined ? AppColors.chipBg : Colors.transparent),
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        hoverColor: AppColors.chipBg,
        onTap: widget.enabled ? () => widget.onToggleTable(key) : null,
        child: SizedBox(
          height: 30,
          child: Row(
            children: [
              BuilderGlyphButton(
                key: ValueKey('builder-expand-' + key),
                icon:
                    expanded ? Icons.keyboard_arrow_down : Icons.chevron_right,
                tooltip: expanded ? '收起字段' : '展开字段',
                onPressed: () {
                  setState(() {
                    if (expanded) {
                      _expanded.remove(key);
                    } else {
                      _expanded.add(key);
                    }
                  });
                },
              ),
              Icon(
                selected ? Icons.check_box : Icons.check_box_outline_blank,
                size: 13,
                color: isPrimary ? tone.fg : AppColors.muted,
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.table_rows_outlined,
                size: 14,
                color: isPrimary ? tone.fg : AppColors.muted,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: EllipsisText(
                  table.name,
                  tooltip: widget.groupByDatabase ? key : table.name,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isPrimary ? tone.fg : AppColors.bodyText,
                  ),
                ),
              ),
              if (isPrimary)
                BuilderTag('主表', tone: builderPrimaryTone)
              else if (isJoined)
                BuilderTag('接入', tone: builderInfoTone),
              const SizedBox(width: 4),
              Text(
                table.columns.length.toString(),
                style: TextStyle(fontSize: 10, color: AppColors.muted),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
    if (!expanded) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        ..._expandedBody(table),
        const SizedBox(height: 2),
      ],
    );
  }

  List<Widget> _expandedBody(BuilderTable table) {
    final rows = <Widget>[];
    if (table.columns.isEmpty) {
      rows.add(Padding(
        padding: EdgeInsets.only(left: 30, top: 2, bottom: 2),
        child: Text('没有字段',
            style: TextStyle(fontSize: 11, color: AppColors.muted)),
      ));
    }
    for (final column in table.columns) {
      rows.add(_columnRow(table.key, column));
    }
    return rows;
  }

  Widget _columnRow(String tableKey, BuilderColumn column) {
    final active = _active(tableKey);
    final added = widget.outputKeys.contains(tableKey + '.' + column.name);
    final type = column.type.isEmpty ? '—' : column.type;
    final row = Material(
      key: ValueKey('builder-field-' + tableKey + '.' + column.name),
      color: Colors.transparent,
      child: InkWell(
        hoverColor: AppColors.chipBg,
        onTap: active && widget.enabled
            ? () => widget.onToggleOutput(tableKey, column.name)
            : null,
        child: SizedBox(
          height: 26,
          child: Row(
            children: [
              const SizedBox(width: 50),
              if (added)
                Padding(
                  padding: EdgeInsets.only(right: 3),
                  child: Icon(Icons.check_circle,
                      size: 12, color: AppColors.ok),
                ),
              Expanded(
                child: Row(
                    children: [
                      Flexible(
                        child: EllipsisText(
                          column.name,
                          tooltip: active
                              ? tableKey + '.' + column.name
                              : column.name + '（请先在数据源中点击该表接入查询）',
                          style: monoStyle(
                            size: 11.5,
                            color:
                                active ? AppColors.bodyText : AppColors.muted,
                            weight:
                                added ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ),
                      if (column.isPrimaryKey) ...[
                        const SizedBox(width: 4),
                        Text('PK',
                            style: TextStyle(
                                fontSize: 9, color: AppColors.muted)),
                      ],
                      if (column.isSensitive) ...[
                        const SizedBox(width: 3),
                        Tooltip(
                          message: '敏感字段：脱敏需要服务端策略执行',
                          child: Icon(Icons.lock_outline,
                              size: 11, color: AppColors.warnText),
                        ),
                      ],
                    ],
                  ),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: EllipsisText(
                  type,
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 10, color: AppColors.muted),
                ),
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: row,
    );
  }
}
