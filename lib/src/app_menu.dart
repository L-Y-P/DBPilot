import 'package:flutter/material.dart' hide Text, Tooltip;

import 'text.dart';

import 'i18n_literals.dart';
import 'theme.dart';

/// One entry of a context menu.
///
/// A single model serves the sidebar tree, the database page toolbar and the
/// table page so the same action always appears under the same label, with the
/// same enablement rule, no matter where the user right-clicks.
class AppMenuEntry {
  const AppMenuEntry({
    required this.label,
    this.icon,
    this.onSelected,
    this.danger = false,
    this.enabled = true,
    this.separatorBefore = false,
  });

  /// Shown as the item text; translated through the literal table.
  final String label;
  final IconData? icon;

  /// Null (together with [enabled] false) renders a disabled row.
  final VoidCallback? onSelected;
  final bool danger;
  final bool enabled;

  /// Draw a divider above this entry: groups related actions.
  final bool separatorBefore;

  bool get isEnabled => enabled && onSelected != null;
}

/// Show [entries] at the pointer and run the chosen action.
///
/// Returns the chosen label (useful for tests) or null when dismissed. The
/// menu is positioned at [position] when given, otherwise it drops from the
/// widget that opened it (the usual Flutter behaviour).
Future<String?> showAppContextMenu(
  BuildContext context,
  List<AppMenuEntry> entries, {
  Offset? position,
}) async {
  if (entries.isEmpty) return null;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  final anchor =
      position ??
      (context.findRenderObject() is RenderBox
          ? (context.findRenderObject() as RenderBox).localToGlobal(
              (context.findRenderObject() as RenderBox).size.center(
                Offset.zero,
              ),
            )
          : const Offset(0, 0));
  final chosen = await showMenu<String>(
    context: context,
    color: AppColors.panel,
    elevation: 8,
    position: RelativeRect.fromRect(
      Rect.fromPoints(anchor, anchor),
      Offset.zero & (overlay?.size ?? const Size(1024, 768)),
    ),
    items: <PopupMenuEntry<String>>[
      for (final entry in entries) ...[
        if (entry.separatorBefore) const PopupMenuDivider(height: 7),
        PopupMenuItem<String>(
          value: entry.label,
          enabled: entry.isEnabled,
          height: 34,
          child: _AppMenuRow(entry: entry),
        ),
      ],
    ],
  );
  if (chosen == null) return null;
  for (final entry in entries) {
    if (entry.label == chosen) {
      entry.onSelected?.call();
      break;
    }
  }
  return chosen;
}

class _AppMenuRow extends StatelessWidget {
  const _AppMenuRow({required this.entry});

  final AppMenuEntry entry;

  @override
  Widget build(BuildContext context) {
    final color = !entry.isEnabled
        ? AppColors.muted
        : entry.danger
        ? AppColors.danger
        : AppColors.bodyText;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (entry.icon != null) ...[
          Icon(entry.icon, size: 14, color: color),
          const SizedBox(width: 8),
        ],
        Text(
          trLiteral(entry.label),
          style: TextStyle(fontSize: 13, color: color),
        ),
      ],
    );
  }
}
