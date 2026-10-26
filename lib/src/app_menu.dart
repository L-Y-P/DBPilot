import 'package:flutter/material.dart' hide Text, Tooltip;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'text.dart';

import 'i18n_literals.dart';
import 'native_menu.dart';
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

// Geometry copied from a native macOS menu: 22px rows, 4px inner padding, a
// 6px corner radius and hairline separators. Keeping the numbers in one place
// makes the menu read as a system menu rather than as another app surface.
const double _kMenuMinWidth = 168;
const double _kMenuMaxWidth = 320;
const double _kRowHeight = 22;
const double _kRowRadius = 4;
const double _kMenuPadding = 4;

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
  final anchor = position ?? _anchorOf(context);

  // Capture everything that needs the context *before* awaiting: the native
  // round trip can outlive this frame, and reaching back into a disposed
  // context afterwards would be a use-after-dispose.
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  final navigator = Navigator.of(context);

  // On macOS hand the menu to AppKit: the native NSMenu is the only way to get
  // the real system look. Falls through to the Flutter-drawn menu below when the
  // bridge is absent (tests, other platforms).
  final nativeIndex = await _tryNativeMenu(entries, anchor);
  if (nativeIndex != null) {
    if (nativeIndex >= 0 && nativeIndex < entries.length) {
      // The platform side already shows the menu on its own run-loop turn and
      // only replies once the menu has closed, so the action runs with the
      // platform thread idle. Do NOT add a Dart-side delay here: a Timer never
      // fires under the fake-async zone of widget tests, and the
      // showAppContextMenu future would hang forever.
      entries[nativeIndex].onSelected?.call();
      return entries[nativeIndex].label;
    }
    return null;
  }

  final chosen = await navigator.push<String>(
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

/// Ask the platform for a real menu; null means "draw it yourself".
Future<int?> _tryNativeMenu(List<AppMenuEntry> entries, Offset anchor) async {
  if (!hasNativeMenu) return null;
  final items = <Map<String, Object?>>[];
  for (final entry in entries) {
    items.add(<String, Object?>{
      'label': trLiteral(entry.label),
      'enabled': entry.isEnabled,
      'danger': entry.danger,
      'separator': entry.separatorBefore,
    });
  }
  return showNativeMenu(items, anchor.dx, anchor.dy);
}

Offset _anchorOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return Offset.zero;
  return box.localToGlobal(box.size.center(Offset.zero));
}

/// The menu's own palette.
///
/// A context menu is a system surface, so it deliberately does *not* inherit
/// the app's accent (orange): native menus use the system accent and neutral
/// greys, and mixing the two is what made the previous menu look like a
/// floating card instead of a menu.
class _MenuColors {
  const _MenuColors({
    required this.background,
    required this.border,
    required this.shadow,
    required this.separator,
    required this.text,
    required this.mutedText,
    required this.dangerText,
    required this.highlight,
    required this.highlightText,
  });

  final Color background;
  final Color border;
  final Color shadow;
  final Color separator;
  final Color text;
  final Color mutedText;
  final Color dangerText;
  final Color highlight;
  final Color highlightText;

  static _MenuColors of(BuildContext context) {
    final dark = AppColors.palette.dark;
    if (dark) {
      return const _MenuColors(
        // #2C2C2E is the native dark menu surface.
        background: Color(0xFF2C2C2E),
        border: Color(0x1FFFFFFF),
        shadow: Color(0x66000000),
        separator: Color(0x26FFFFFF),
        text: Color(0xFFEDEDED),
        mutedText: Color(0xFF7C7C80),
        dangerText: Color(0xFFFF453A),
        // System accent blue; macOS tints the selected row solid.
        highlight: Color(0xFF0A84FF),
        highlightText: Color(0xFFFFFFFF),
      );
    }
    return const _MenuColors(
      // #F7F7F7 is the native light menu surface (NSMenu's material).
      background: Color(0xFFF7F7F7),
      border: Color(0x1A000000),
      shadow: Color(0x33000000),
      separator: Color(0x1A000000),
      text: Color(0xFF1D1D1F),
      mutedText: Color(0xFF9A9A9E),
      dangerText: Color(0xFFD70015),
      highlight: Color(0xFF007AFF),
      highlightText: Color(0xFFFFFFFF),
    );
  }
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
    final colors = _MenuColors.of(context);
    final children = <Widget>[];
    for (final entry in entries) {
      if (entry.separatorBefore && children.isNotEmpty) {
        children.add(_MenuSeparator(color: colors.separator));
      }
      children.add(_AppMenuRow(
        entry: entry,
        colors: colors,
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
      padding: const EdgeInsets.all(_kMenuPadding),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: colors.shadow,
            blurRadius: 20,
            spreadRadius: 2,
            offset: const Offset(0, 5),
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
  const _MenuSeparator({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    // Native menus inset the rule a few pixels from the menu edge.
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      color: color,
    );
  }
}

class _AppMenuRow extends StatefulWidget {
  const _AppMenuRow({
    required this.entry,
    required this.colors,
    required this.onTap,
  });

  final AppMenuEntry entry;
  final _MenuColors colors;
  final VoidCallback? onTap;

  @override
  State<_AppMenuRow> createState() => _AppMenuRowState();
}

class _AppMenuRowState extends State<_AppMenuRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final colors = widget.colors;
    final enabled = widget.onTap != null;
    final highlighted = enabled && _hovered;
    final color = highlighted
        ? colors.highlightText
        : !enabled
        ? colors.mutedText
        : entry.danger
        ? colors.dangerText
        : colors.text;
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
            color: highlighted ? colors.highlight : null,
            borderRadius: BorderRadius.circular(_kRowRadius),
          ),
          alignment: Alignment.centerLeft,
          child: Text(
            trLiteral(entry.label),
            maxLines: 1,
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