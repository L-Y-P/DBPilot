import 'package:flutter/material.dart' hide Text, Tooltip;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'text.dart';

import 'i18n_literals.dart';
import 'theme.dart';

/// One entry of a context menu.
///
/// A single model serves the sidebar tree, the database page and the table page
/// so the same action always appears under the same label, with the same
/// enablement rule, no matter where the user right-clicks.
class AppMenuEntry {
  const AppMenuEntry({
    required this.label,
    this.onSelected,
    this.danger = false,
    this.enabled = true,
    this.separatorBefore = false,
  });

  /// Shown as the item text; translated through the literal table.
  final String label;

  /// Null (together with [enabled] false) renders a disabled row.
  final VoidCallback? onSelected;
  final bool danger;
  final bool enabled;

  /// Draw a divider above this entry: groups related actions.
  final bool separatorBefore;

  bool get isEnabled => enabled && onSelected != null;
}

/// Width of the menu; wide enough for the longest label, capped so a verbose
/// entry wraps instead of running off the window.
const double _kMenuMinWidth = 186;
const double _kMenuMaxWidth = 340;
const double _kRowHeight = 22;
const double _kRowRadius = 5;

/// Show [entries] at the pointer and run the chosen action.
///
/// Returns the chosen label (useful for tests) or null when dismissed. The menu
/// is positioned at [position] when given, otherwise it drops from the widget
/// that opened it (the usual Flutter behaviour).
///
/// The popup is a zero-duration route: a right-click menu that animates in feels
/// laggy next to native menus, so it appears and disappears in one frame.
Future<String?> showAppContextMenu(
  BuildContext context,
  List<AppMenuEntry> entries, {
  Offset? position,
}) async {
  if (entries.isEmpty) return null;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  final anchor = position ?? _anchorOf(context);
  final chosen = await Navigator.of(context).push<String>(
    _AppMenuRoute(
      entries: entries,
      position: anchor,
      overlaySize: overlay?.size ?? const Size(1024, 768),
    ),
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

Offset _anchorOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return Offset.zero;
  return box.localToGlobal(box.size.center(Offset.zero));
}

/// Zero-duration popup route: no fade, no scale, no delay.
class _AppMenuRoute extends PopupRoute<String> {
  _AppMenuRoute({
    required this.entries,
    required this.position,
    required this.overlaySize,
  });

  final List<AppMenuEntry> entries;
  final Offset position;
  final Size overlaySize;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => 'Dismiss';

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Duration get reverseTransitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _AppMenuPanel(
      entries: entries,
      position: position,
      overlaySize: overlaySize,
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      child;
}

class _AppMenuPanel extends StatelessWidget {
  const _AppMenuPanel({
    required this.entries,
    required this.position,
    required this.overlaySize,
  });

  final List<AppMenuEntry> entries;
  final Offset position;
  final Size overlaySize;

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      autofocus: true,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).maybePop(),
        },
        child: CustomSingleChildLayout(
          delegate: _AppMenuLayout(position: position, overlaySize: overlaySize),
          child: _box(context),
        ),
      ),
    );
  }

  Widget _box(BuildContext context) {
    final children = <Widget>[];
    for (final entry in entries) {
      if (entry.separatorBefore && children.isNotEmpty) {
        children.add(const _MenuSeparator());
      }
      children.add(_AppMenuRow(
        entry: entry,
        onTap: entry.isEnabled
            ? () => Navigator.of(context).pop(entry.label)
            : null,
      ));
    }
    return Container(
      constraints: const BoxConstraints(
        minWidth: _kMenuMinWidth,
        maxWidth: _kMenuMaxWidth,
      ),
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 5),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.7)),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 12,
            spreadRadius: 1,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _MenuSeparator extends StatelessWidget {
  const _MenuSeparator();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
      color: AppColors.border.withValues(alpha: 0.75),
    );
  }
}

class _AppMenuRow extends StatefulWidget {
  const _AppMenuRow({required this.entry, required this.onTap});

  final AppMenuEntry entry;
  final VoidCallback? onTap;

  @override
  State<_AppMenuRow> createState() => _AppMenuRowState();
}

class _AppMenuRowState extends State<_AppMenuRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final enabled = widget.onTap != null;
    final highlighted = enabled && _hovered;
    final color = highlighted
        ? AppColors.panel
        : !enabled
        ? AppColors.muted
        : entry.danger
        ? AppColors.danger
        : AppColors.bodyText;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          height: _kRowHeight,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: highlighted
                ? (entry.danger ? AppColors.danger : AppColors.accent)
                : null,
            borderRadius: BorderRadius.circular(_kRowRadius),
          ),
          alignment: Alignment.centerLeft,
          child: Text(
            trLiteral(entry.label),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, height: 1.15, color: color),
          ),
        ),
      ),
    );
  }
}

/// Places the menu at the pointer, flipping and clamping so it stays inside the
/// window instead of being clipped at the bottom/right edge.
class _AppMenuLayout extends SingleChildLayoutDelegate {
  const _AppMenuLayout({required this.position, required this.overlaySize});

  final Offset position;
  final Size overlaySize;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      minWidth: _kMenuMinWidth,
      maxWidth: _kMenuMaxWidth,
      maxHeight: overlaySize.height - 16,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    var dx = position.dx;
    var dy = position.dy;
    if (dx + childSize.width > size.width - 8) {
      dx = size.width - childSize.width - 8;
    }
    if (dy + childSize.height > size.height - 8) {
      // Not enough room below the pointer: open upwards from it.
      dy = dy - childSize.height;
    }
    if (dx < 8) dx = 8;
    if (dy < 8) dy = 8;
    return Offset(dx, dy);
  }

  @override
  bool shouldRelayout(_AppMenuLayout oldDelegate) =>
      oldDelegate.position != position ||
      oldDelegate.overlaySize != overlaySize;
}

/// Wraps [child] so a right-click anywhere inside it opens [entries].
///
/// The region stays inert while [enabled] is false, and a right-click that
/// lands on an editable field falls through to the platform text menu instead.
class ContextMenuRegion extends StatelessWidget {
  const ContextMenuRegion({
    super.key,
    required this.entries,
    required this.child,
    this.enabled = true,
  });

  final List<AppMenuEntry> entries;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (details) {
        // A right-click inside a text field belongs to the platform text menu;
        // the page-level menu must not steal it.
        if (_hitsEditable(context, details.globalPosition)) return;
        showAppContextMenu(
          context,
          entries,
          position: details.globalPosition,
        );
      },
      child: child,
    );
  }
}

bool _hitsEditable(BuildContext context, Offset globalPosition) {
  final result = HitTestResult();
  final view = View.of(context);
  WidgetsBinding.instance.hitTestInView(result, globalPosition, view.viewId);
  for (final entry in result.path) {
    if (entry.target is RenderEditable) return true;
  }
  return false;
}