import 'dart:math' as math;

import 'package:flutter/material.dart' hide Text, Tooltip;
import 'text.dart';
import 'tooltip.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'i18n.dart';
import 'i18n_literals.dart';
import 'notice.dart';
import 'theme.dart';

/// Width every column is pinned to when "auto-fit column widths" is off.
///
/// Shared by [GridTable] and the DataGrid so both grids answer the same
/// preference the same way. See [AppState.autoColumnWidth].
const double kFixedGridColumnWidth = 160;

/// Rounded white card with the web app's 6px radius, 1px border, 14px padding
/// and 16px bottom margin.
class CardBox extends StatelessWidget {
  const CardBox({
    super.key,
    required this.child,
    this.title,
    this.actions = const <Widget>[],
    this.padding,
  });

  final Widget child;
  final String? title;
  final List<Widget> actions;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: padding ?? const EdgeInsets.all(AppMetrics.cardPadding),
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppMetrics.radiusCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null) ...[
            Row(
              children: [
                Text(
                  title!,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.cardHeading,
                  ),
                ),
                if (actions.isNotEmpty) ...[
                  const Spacer(),
                  Wrap(spacing: 6, runSpacing: 6, children: actions),
                ],
              ],
            ),
            const SizedBox(height: 10),
          ],
          child,
        ],
      ),
    );
  }
}

/// Page header: title + inline metadata on the left, actions on the right.
///
/// The web `.page-head` puts a `.spacer` between the heading and the buttons,
/// so the actions hug the right edge. The desktop port used a single `Wrap`,
/// which left-aligned every button right after the title (visible on the
/// database page as 刷新 / 新建表 / 删除数据库 sitting next to the table count).
/// The header now mirrors the web flex row and falls back to two rows on a
/// narrow window instead of overflowing.
class PageHead extends StatelessWidget {
  const PageHead({
    super.key,
    this.title,
    this.titleWidget,
    this.leading = const <Widget>[],
    this.meta = const <Widget>[],
    this.actions = const <Widget>[],
  });

  final String? title;
  final Widget? titleWidget;

  /// Widgets rendered before the title (an icon, a back link, ...).
  final List<Widget> leading;

  /// Inline metadata that belongs beside the title (a count pill, a status).
  /// Keeping it out of [actions] means only real controls are pushed right.
  final List<Widget> meta;

  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final heading = Wrap(
      spacing: 10,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ...leading,
        if (titleWidget != null)
          titleWidget!
        else if (title != null)
          Text(
            title!,
            style: TextStyle(
              fontSize: 18,
              height: 1.2,
              fontWeight: FontWeight.w600,
              color: AppColors.bodyText,
            ),
          ),
        ...meta,
      ],
    );
    final actionRow = Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: actions,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (actions.isEmpty) return heading;
          // Below this width a single row would either squeeze the title or
          // overflow; the web layout wraps as well at its mobile breakpoint.
          if (constraints.maxWidth < 640) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                heading,
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerRight, child: actionRow),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: heading),
              const SizedBox(width: 16),
              actionRow,
            ],
          );
        },
      ),
    );
  }
}

enum PillTone { neutral, ok, warn, info, danger }

/// Small count badge, the web pill.
///
/// Pills usually hold a number or a short status, but a few carry server data
/// (a role name, a database label, a header cell). A long value used to make the
/// pill arbitrarily wide: inside a `Row` that is a `RenderFlex overflowed`
/// (measured 5412px for a 300px row), and inside a `Wrap` it became several
/// lines tall. [maxWidth] caps the pill and [EllipsisText] keeps the complete
/// value reachable on hover, so a badge can never stretch or overrun its row.
class Pill extends StatelessWidget {
  const Pill(this.text,
      {super.key, this.tone = PillTone.neutral, this.maxWidth = 220});

  final String text;
  final PillTone tone;

  /// Width cap. Long values ellipsize (with a hover tooltip) instead of pushing
  /// the surrounding row past the window.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    late final Color bg;
    late final Color fg;
    late final Color border;
    switch (tone) {
      case PillTone.neutral:
        bg = AppColors.chipBg;
        fg = AppColors.cardHeading;
        border = AppColors.border;
      case PillTone.ok:
        bg = AppColors.okBg;
        fg = AppColors.okText;
        border = AppColors.okBorder;
      case PillTone.warn:
        bg = AppColors.warnBg;
        fg = AppColors.warnText;
        border = AppColors.warnBorder;
      case PillTone.info:
        bg = AppColors.infoBg;
        fg = AppColors.infoText;
        border = AppColors.infoBorder;
      case PillTone.danger:
        bg = AppColors.errBg;
        fg = AppColors.errText;
        border = AppColors.errBorder;
    }
    return Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(999),
      ),
      // The pill is width-capped, so the label can be cut: hover shows it whole.
      child: EllipsisText(
        text,
        translate: true,
        style: TextStyle(fontSize: 12, color: fg),
      ),
    );
  }
}

enum AlertTone { error, ok, info, warn }

/// Colored alert block: error / ok / info, matching the web alert classes.
class AlertBox extends StatelessWidget {
  const AlertBox(this.message,
      {super.key, this.tone = AlertTone.error, this.onClose, this.liveRegion = false});

  final String message;
  final AlertTone tone;

  /// When set, a close button is shown so a stale banner can be dismissed.
  ///
  /// The sidebar keeps the last failure visible until something replaces it;
  /// without this a resolved problem (e.g. a database that is now granted)
  /// leaves an error pinned above the tree.
  final VoidCallback? onClose;

  /// Expose the message as a single labelled live region.
  ///
  /// P11: the connection-test outcome is plain alert text, and the macOS
  /// accessibility tree does not surface it as a stable value, so automation
  /// could not assert success/failure. Opt-in because most alerts are page
  /// copy that should keep their normal (selectable) semantics.
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    late final Color bg;
    late final Color fg;
    late final Color border;
    switch (tone) {
      case AlertTone.error:
        bg = AppColors.errBg;
        fg = AppColors.errText;
        border = AppColors.errBorder;
      case AlertTone.ok:
        bg = AppColors.okBg;
        fg = AppColors.okText;
        border = AppColors.okBorder;
      case AlertTone.info:
        bg = AppColors.infoBg;
        fg = AppColors.infoText;
        border = AppColors.infoBorder;
      case AlertTone.warn:
        bg = AppColors.warnBg;
        fg = AppColors.warnText;
        border = AppColors.warnBorder;
    }
    final box = Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(
              trLiteral(message),
              style: TextStyle(fontSize: 13, color: fg),
            ),
          ),
          if (onClose != null)
            IconBtn(Icons.close,
                tooltip: '关闭提示', small: true, onPressed: onClose),
        ],
      ),
    );
    if (!liveRegion) return box;
    return Semantics(
      container: true,
      liveRegion: true,
      label: trLiteral(message),
      child: box,
    );
  }
}

/// The success toast: rendered inline in page flow under the header, exactly
/// like the web app, and faded out by Notice.
class NoticeBanner extends StatelessWidget {
  const NoticeBanner(this.notice, {super.key});

  final Notice notice;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: notice,
      builder: (context, _) {
        if (!notice.visible) return const SizedBox.shrink();
        // N-04: the success toast is visual-only by default, so a screen
        // reader / automation could not observe "inserted" feedback. Expose it
        // as a live region so assistive tech announces it when it appears.
        return Semantics(
          liveRegion: true,
          container: true,
          // P3-08b: the visible toast translates through AlertBox's Text;
          // the accessibility label must be translated here too or a screen
          // reader announces Chinese copy in English mode.
          label: trLiteral(notice.message),
          child: AnimatedOpacity(
            opacity: notice.fading ? 0 : 1,
            duration: const Duration(milliseconds: 400),
            child: AlertBox(notice.message, tone: AlertTone.ok),
          ),
        );
      },
    );
  }
}

/// Buttons matching the web style: 1px border, 4px radius, white background,
/// with primary / danger / small variants.
class Btn extends StatefulWidget {
  const Btn(
    this.label, {
    super.key,
    this.onPressed,
    this.primary = false,
    this.danger = false,
    this.small = false,
    this.busy = false,
    this.icon,
    this.tooltip,
    this.height,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool danger;
  final bool small;
  final bool busy;
  final IconData? icon;
  final String? tooltip;

  /// Optional fixed height. A toolbar that mixes [Btn] with [IconBtn] passes
  /// the same value to both so the controls line up on one baseline instead of
  /// rendering a 23px, 26px and 36px button side by side.
  final double? height;

  @override
  State<Btn> createState() => _BtnState();
}

class _BtnState extends State<Btn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.busy;

    late Color bg;
    late Color fg;
    late Color border;
    if (widget.primary) {
      bg = _hover && enabled ? AppColors.header2 : AppColors.header;
      fg = Colors.white;
      border = bg;
    } else if (widget.danger) {
      bg = _hover && enabled ? const Color(0xFFA93226) : AppColors.danger;
      fg = Colors.white;
      border = bg;
    } else {
      bg = _hover && enabled ? AppColors.btnHoverBg : AppColors.panel;
      fg = AppColors.bodyText;
      border = _hover && enabled ? AppColors.btnHoverBorder : AppColors.border;
    }

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.icon != null) ...[
          Icon(widget.icon, size: widget.small ? 13 : 14, color: fg),
          const SizedBox(width: 5),
        ],
        Text(
          widget.busy ? '...' : trLiteral(widget.label),
          style: TextStyle(
            fontSize: widget.small ? 12 : 13,
            color: fg,
            fontWeight: widget.primary ? FontWeight.w500 : FontWeight.normal,
          ),
        ),
      ],
    );

    Widget result = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: enabled ? widget.onPressed : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: Container(
            height: widget.height ?? (widget.small ? null : kControlHeight),
            padding: widget.small
                ? const EdgeInsets.symmetric(horizontal: 7, vertical: 2)
                : const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              color: bg,
              border: Border.all(color: border),
              borderRadius: BorderRadius.circular(AppMetrics.radiusControl),
            ),
            // widthFactor keeps the box hugging its label instead of filling
            // the row, while the fixed height centres the text vertically.
            child: Center(widthFactor: 1, heightFactor: 1, child: content),
          ),
        ),
      ),
    );
    if (widget.tooltip != null) {
      result = Tooltip(
        message: trLiteral(widget.tooltip!),
        constraints: kTooltipConstraints,
        child: result,
      );
    }
    return Semantics(
      button: true,
      enabled: enabled,
      child: result,
    );
  }
}

/// Icon-only action button, the compact sibling of [Btn].
///
/// Used for actions whose meaning is carried by a standard glyph (edit,
/// delete, close, refresh, copy, browse, pagination). Keeping them icon-only
/// removes the need to translate repeated one-word labels and gives the data
/// grids a tighter action column. The tooltip and the semantics label always
/// keep the action available to screen readers and tests.
class IconBtn extends StatefulWidget {
  const IconBtn(
    this.icon, {
    super.key,
    required this.tooltip,
    this.onPressed,
    this.primary = false,
    this.danger = false,
    this.small = true,
    this.dimension,
    this.glyphSize,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool primary;
  final bool danger;
  final bool small;

  /// Optional square box override (default 28 small / 42 normal). Used where a
  /// page wants its toolbar glyphs slightly larger than the grid action cells.
  final double? dimension;

  /// Optional glyph size override (default 15 small / 17 normal).
  final double? glyphSize;

  @override
  State<IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<IconBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    late Color bg;
    late Color fg;
    late Color border;
    if (widget.primary) {
      bg = _hover && enabled ? AppColors.header2 : AppColors.header;
      fg = Colors.white;
      border = bg;
    } else if (widget.danger) {
      bg = _hover && enabled ? const Color(0xFFA93226) : AppColors.danger;
      fg = Colors.white;
      border = bg;
    } else {
      bg = _hover && enabled ? AppColors.btnHoverBg : AppColors.panel;
      fg = AppColors.bodyText;
      border = _hover && enabled ? AppColors.btnHoverBorder : AppColors.border;
    }
    final label = trLiteral(widget.tooltip);
    final result = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: enabled ? widget.onPressed : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: Container(
            height: widget.dimension ?? (widget.small ? 26 : kControlHeight),
            // 28px keeps the centred 15px glyph 6.5px from the cell edge, i.e.
            // within half a pixel of where the old "改"/"删" text buttons sat.
            width: widget.dimension ?? (widget.small ? 28 : 42),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              border: Border.all(color: border),
              borderRadius: BorderRadius.circular(AppMetrics.radiusControl),
            ),
            child: Icon(
              widget.icon,
              size: widget.glyphSize ?? (widget.small ? 15 : 17),
              color: fg,
            ),
          ),
        ),
      ),
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Tooltip(
        message: label,
        child: result,
      ),
    );
  }
}

OutlineInputBorder _inputBorder(Color color, {double width = 1}) =>
    OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppMetrics.radiusControl),
      borderSide: BorderSide(color: color, width: width),
    );

/// Text input matching the web input style, with an optional label above.
///
/// An empty `label` renders no label row at all. That matters inside forms such
/// as the connection editor, where the caption already lives in the surrounding
/// [FormRow]; an empty 12px text line plus its 4px gap used to add 20px of dead
/// space above every input and push rows out of line with their labels.
class Field extends StatelessWidget {
  const Field({
    super.key,
    required this.label,
    this.controller,
    this.hint,
    this.obscure = false,
    this.numeric = false,
    this.maxLines = 1,
    this.enabled = true,
    this.onSubmitted,
    this.onChanged,
    this.trailing,
    this.expand = true,
    this.compact = false,
  });

  final String label;
  final TextEditingController? controller;
  final String? hint;
  final bool obscure;
  final bool numeric;
  final int maxLines;
  final bool enabled;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final Widget? trailing;
  final bool expand;

  /// Drop the 10px bottom margin (and the label row) so the field can sit in a
  /// horizontal toolbar next to buttons, exactly like the web `.row` inputs.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final input = TextField(
      controller: controller,
      obscureText: obscure,
      enabled: enabled,
      maxLines: obscure ? 1 : maxLines,
      keyboardType: numeric ? TextInputType.number : null,
      inputFormatters: numeric
          ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))]
          : null,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      style: monoStyle(size: 13),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint == null ? null : trLiteral(hint!),
        hintStyle: TextStyle(color: AppColors.muted, fontSize: 13),
        filled: true,
        fillColor: enabled ? AppColors.panel : AppColors.chipBg,
        // 8px vertical padding makes the input exactly as tall as a
        // SelectBox (36px), so a field and a dropdown in the same row line up.
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        border: _inputBorder(AppColors.border),
        enabledBorder: _inputBorder(AppColors.border),
        focusedBorder: _inputBorder(AppColors.focusBorder, width: 2),
        disabledBorder: _inputBorder(AppColors.border),
      ),
    );

    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 0 : 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (label.isNotEmpty) ...[
            Text(label,
                style: TextStyle(fontSize: 12, color: AppColors.muted)),
            const SizedBox(height: 4),
          ],
          if (trailing == null)
            input
          else
            Row(
              children: [
                if (expand) Expanded(child: input) else input,
                const SizedBox(width: 8),
                trailing!,
              ],
            ),
        ],
      ),
    );
  }
}

/// Label + control row used by the connection editor and other forms.
class FormRow extends StatelessWidget {
  const FormRow({super.key, required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        // The web .form-grid used align-items:center; matching that keeps the
        // caption on the same line as the control it names.
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 140,
            child: Text(label,
                style: TextStyle(fontSize: 12, color: AppColors.muted)),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// One selectable row inside a dropdown menu.
///
/// Dropdown menus clamp their own width to the view, but a long label would
/// still be *clipped without any way to read it*: the menu is a separate overlay
/// route, so the trigger's tooltip does not apply to it. Every menu item built
/// here therefore ellipsizes to one line and carries the complete value as a
/// hover tooltip. [label] is shown; [tooltip] defaults to it.
///
/// [maxWidth] keeps an enormous value (a 200-character table name) from making
/// the menu wider than its configured `menuWidth`; the enclosing menu is
/// already view-clamped, so this is the second guard that stops a long value
/// from filling the screen.
/// Longest tooltip message shown verbatim.
///
/// A tooltip is capped at [kTooltipConstraints] (~5 lines at 480px wide ×
/// 320px tall ≈ 900 characters). Flutter clips the rest silently — the value
/// would look like it simply ended. Clamping the *string* instead lets the tail
/// carry an explicit marker, so a truncated read-out is recognisable and the
/// user knows to use the full-value viewer / copy action.
const int kTooltipMaxChars = 600;

/// Clamp [value] to [kTooltipMaxChars] for use as a tooltip message.
///
/// Appends a hint naming the remaining length; never splits a surrogate pair.
String tooltipText(String value, {String? fullValueHint}) {
  if (value.length <= kTooltipMaxChars) return value;
  final remaining = value.length - kTooltipMaxChars;
  final cut = value.substring(0, kTooltipMaxChars);
  final hint = fullValueHint ?? '完整内容请双击查看或复制';
  return '$cut…（其余 $remaining 个字符未显示；$hint）';
}

/// Best-effort plain text of a menu item's child, for its hover tooltip.
///
/// Items are built by callers as `Text(name)`; anything more elaborate falls
/// back to an empty string, which disables the tooltip rather than showing a
/// misleading one.
String _itemText(Widget child) {
  // The child may be either this app's translating Text or Flutter's own (a
  // test or a file that did not opt into the wrapper builds the latter).
  final data = sourceTextOf(child);
  return data ?? '';
}

Widget dropdownItemLabel(String label,
    {String? tooltip, double maxWidth = 320}) {
  return SizedBox(
    width: maxWidth,
    child: EllipsisText(
      label,
      tooltip: tooltip ?? label,
      translate: true,
      style: const TextStyle(fontSize: 12),
    ),
  );
}

/// Height of one [SelectBox], measured on the real theme. The web app aligned a
/// `select` and an `input` in a flex row because both ended up the same height;
/// Flutter's controls do not agree by default (a dropdown is 36px, a text field
/// 38px, a checkbox 25px), so toolbar rows that mix them pin every control to
/// this value to stay on one line.
const double kControlHeight = 36;

/// Dropdown styled like the web select.
class SelectBox<T> extends StatelessWidget {
  const SelectBox({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.enabled = true,
    this.width,
  });

  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final bool enabled;
  final double? width;

  @override
  Widget build(BuildContext context) {
    // DropdownButton asserts when its value is absent from items (and shows a
    // blank box in release builds). That happens whenever the backing list is
    // still loading — e.g. a connection whose default database is not in the
    // cached list yet. Fall back to "nothing selected" instead of throwing.
    final hasValue = value != null && items.any((i) => i.value == value);
    // Callers pass plain Text items and cannot know the menu's width. Constrain
    // each item and attach the full label as a tooltip: the open menu is an
    // overlay route, so the trigger's hover text does not cover it, and a long
    // database / schema name would otherwise be clipped with no way to read it.
    final boundedItems = <DropdownMenuItem<T>>[
      for (final item in items)
        DropdownMenuItem<T>(
          value: item.value,
          enabled: item.enabled,
          // maxLines:1 + ellipsis is what keeps one long entry from turning into
          // a many-line menu row (measured 600px tall for a 250px-wide menu).
          child: Tooltip(
            message: _itemText(item.child),
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
    // The closed state must NOT inflate the tooltip-wrapped items: DropdownButton
    // builds an IndexedStack over all of them even when only one is visible, so
    // every item's Tooltip (a MouseRegion + AnimationController) would be built
    // on every rebuild — for a 40-column picker that is 40 controllers per
    // frame. `selectedItemBuilder` gives the closed state plain one-line Texts;
    // the rich items are only inflated when the menu actually opens.
    final closedItems = <Widget>[
      for (final item in items)
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            _itemText(item.child),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: AppColors.bodyText),
          ),
        ),
    ];
    final dropdown = DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        value: hasValue ? value : null,
        items: boundedItems,
        selectedItemBuilder: (context) => closedItems,
        onChanged: enabled ? onChanged : null,
        isDense: true,
        isExpanded: true,
        style: TextStyle(fontSize: 13, color: AppColors.bodyText),
        icon: Icon(Icons.expand_more, size: 16, color: AppColors.muted),
        dropdownColor: AppColors.panel,
        borderRadius: BorderRadius.circular(AppMetrics.radiusControl),
        // The menu is at most this tall and never wider than its own route
        // allows. Without menuMaxHeight a long database list (or a schema list
        // with many entries) made the overlay taller than the window; the
        // width is additionally clamped by Flutter to the view width, so a
        // single long label ellipsizes inside [EllipsisText] items instead of
        // stretching the popup.
        menuMaxHeight: 360,
      ),
    );


    final box = Container(
      height: kControlHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: enabled ? AppColors.panel : AppColors.chipBg,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppMetrics.radiusControl),
      ),
      child: dropdown,
    );
    // The closed state is width-limited ([width], or the parent's constraint),
    // so a long selected value ellipsizes; hovering it must show the whole
    // value. Only when something is selected — an empty select has nothing
    // hidden to reveal.
    final selectedText = hasValue
        ? _itemText(items.firstWhere((item) => item.value == value).child)
        : '';
    final shown = selectedText.isEmpty
        ? box
        : Tooltip(
            message: selectedText,
            constraints: kTooltipConstraints,
            waitDuration: const Duration(milliseconds: 400),
            child: box,
          );
    if (width == null) return shown;
    return SizedBox(width: width, child: shown);
  }
}

/// One labelled control in a horizontal toolbar (structure sync, backups).
///
/// The web app used `.row` with plain flex items, which all share a baseline
/// because every control is the same height. Flutter's controls are not: a
/// labelled [Field] is 20px taller than a [SelectBox], and a [CheckBox] is
/// shorter than both. Putting the caption inside the control group and aligning
/// the groups by their bottom edge keeps the inputs on one line and the
/// captions on another — the layout the web version produced.
class ControlGroup extends StatelessWidget {
  const ControlGroup({
    super.key,
    this.label,
    required this.child,
    this.width,
    this.height,
  });

  /// Caption above the control. Null means "no caption" (a checkbox, say) while
  /// still keeping the control on the same bottom-aligned row.
  final String? label;
  final Widget child;
  final double? width;

  /// Force the control box to this height, centring the child vertically. Use
  /// [kControlHeight] so a checkbox lines up with the inputs next to it.
  final double? height;

  @override
  Widget build(BuildContext context) {
    var body = child;
    if (height != null) {
      // Align must hug the child (widthFactor/heightFactor = 1); a plain Align
      // would expand to the whole row and break the Wrap onto its own line.
      body = SizedBox(
        height: height,
        child: Align(
          alignment: Alignment.centerLeft,
          widthFactor: 1,
          heightFactor: 1,
          child: child,
        ),
      );
    }
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) ...[
          Text(label!, style: kSmallMuted),
          const SizedBox(height: 4),
        ],
        body,
      ],
    );
    if (width == null) return content;
    return SizedBox(width: width, child: content);
  }
}

/// Checkbox with a label, sized like the web checkboxes.
class CheckBox extends StatelessWidget {
  const CheckBox({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled && onChanged != null ? () => onChanged!(!value) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: Checkbox(
                value: value,
                onChanged: enabled && onChanged != null
                    ? (v) => onChanged!(v ?? false)
                    : null,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                activeColor: AppColors.header,
                side: BorderSide(color: AppColors.border),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              trLiteral(label),
              style: TextStyle(
                fontSize: 13,
                color: enabled ? AppColors.bodyText : AppColors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Column width that is content-sized but never zero.
///
/// [Table]'s default column width is [FlexColumnWidth], whose *intrinsic* width
/// is 0 and which only receives space when the table is given a finite
/// maxWidth. This grid lives inside a horizontal [SingleChildScrollView] (the
/// web `.table-scroll`), where the incoming maxWidth is infinite, so the flex
/// algorithm has nothing to distribute: every column became 0px wide and the
/// cells collapsed into a one-character-wide vertical strip of clipped glyphs.
/// Sizing on the intrinsic width instead reproduces the web table, and the
/// floor keeps an empty table from shrinking to nothing.
class _ContentColumnWidth extends TableColumnWidth {
  const _ContentColumnWidth();

  /// A hair of width keeps an all-empty column visible as a bordered cell
  /// instead of collapsing to a zero-width sliver.
  static const double _floor = 1;

  @override
  double minIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) {
    var result = _floor;
    for (final cell in cells) {
      result = math.max(result, cell.getMinIntrinsicWidth(double.infinity));
    }
    return result;
  }

  @override
  double maxIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) {
    var result = _floor;
    for (final cell in cells) {
      result = math.max(result, cell.getMaxIntrinsicWidth(double.infinity));
    }
    return result;
  }
}

/// One data table styled like the web grid: 1px borders, 5x8 cell padding,
/// zebra rows and a header row.
///
/// Long tables are virtualised. The eager rendering is a single [Table] holding
/// every row, so a list of a few thousand rows builds thousands of cells on
/// every parent rebuild (measured ~63ms per rebuild and ~550ms for the first
/// frame at 300 rows × 6 columns, debug). Above [virtualizeAfter] rows the table
/// instead renders a pinned header plus one [ListView] item per row: only the
/// rows on screen are built, and the column widths are measured once from a
/// sample so the columns stay aligned and stable while scrolling.
class GridTable extends StatefulWidget {
  const GridTable({
    super.key,
    required this.headers,
    required this.rows,
    this.widths,
    this.maxHeight,
    this.emptyText = '（无）',
    this.virtualizeAfter = 150,
  });

  final List<Widget> headers;
  final List<TableRow> rows;
  final List<TableColumnWidth>? widths;
  final double? maxHeight;
  final String emptyText;

  /// Row count above which the body is virtualised.
  ///
  /// Short tables (the common case: processes, users, structure, backups) keep
  /// the original single-[Table] rendering, so nothing about them changes.
  final int virtualizeAfter;

  @override
  State<GridTable> createState() => _GridTableState();
}

/// A table column width that reports the width it computed.
///
/// [RenderTable] sizes a column from `maxIntrinsicWidth(cells)` over *all* the
/// cells it is given, so a wide table forces a measurement of every row. The
/// measuring pass renders only a sample of rows and captures the widths here;
/// the virtualised body then pins those widths with [FixedColumnWidth], which
/// keeps the columns stable while the rows scroll.
class _MeasuringColumn extends TableColumnWidth {
  const _MeasuringColumn(this.index, this.record);

  final int index;
  final void Function(int index, double width) record;

  static const TableColumnWidth _delegate = _ContentColumnWidth();

  @override
  double minIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      _delegate.minIntrinsicWidth(cells, containerWidth);

  @override
  double maxIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) {
    final width = _delegate.maxIntrinsicWidth(cells, containerWidth);
    record(index, width);
    return width;
  }
}

class _GridTableState extends State<GridTable> {
  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();

  /// Column widths captured by the measuring pass.
  final Map<int, double> _recorded = <int, double>{};

  /// Frozen widths used by the virtualised body (null until measured).
  List<double>? _frozen;

  /// Rows rendered in the measuring pass.
  static const int _measureRows = 40;

  /// Whether the user turned content-based column measuring off.
  ///
  /// With it off, every column is pinned to [kFixedGridColumnWidth] and the
  /// measuring pass is skipped entirely: no maxIntrinsicWidth walk over the
  /// sample rows, which is the expensive half of a wide table's first frame.
  bool _autoColumnWidth = true;

  @override
  void initState() {
    super.initState();
    _autoColumnWidth = AppState.instance.autoColumnWidth;
    AppState.instance.addListener(_onAppStateChanged);
  }

  void _onAppStateChanged() {
    if (!mounted) return;
    final next = AppState.instance.autoColumnWidth;
    if (next == _autoColumnWidth) return;
    setState(() {
      _autoColumnWidth = next;
      // The frozen widths belong to the previous mode; the next build either
      // measures again or pins the fixed width.
      _recorded.clear();
      _frozen = null;
    });
  }

  /// Height of the virtualised body when the caller did not cap it.
  static const double _virtualBodyHeight = 420;

  /// Whether the body should be virtualised.
  ///
  /// Small tables keep the original rendering byte for byte; only a table long
  /// enough to pay for it switches to one row per [ListView] item. Explicit
  /// [GridTable.widths] are used directly by the virtual body (no measuring
  /// pass), so a paginated table can pin columns and still keep its horizontal
  /// scrollbar at the viewport edge instead of below every row.
  bool get _virtualize =>
      widget.rows.length > widget.virtualizeAfter;

  /// Column widths supplied by the caller, when they are fixed widths.
  List<double>? _explicitWidths() {
    final widths = widget.widths;
    if (widths == null) return null;
    final result = <double>[];
    for (final width in widths) {
      if (width is! FixedColumnWidth) return null;
      result.add(width.value);
    }
    return result;
  }

  @override
  void didUpdateWidget(covariant GridTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different row count means new data (the list is rebuilt inline on every
    // parent build, so the list identity says nothing): re-measure. Rows are
    // only *sampled* anyway, so keeping the widths for an equal-length refresh
    // is intended.
    if (oldWidget.rows.length != widget.rows.length ||
        oldWidget.headers.length != widget.headers.length) {
      _recorded.clear();
      _frozen = null;
    }
  }

  @override
  void dispose() {
    AppState.instance.removeListener(_onAppStateChanged);
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  TableBorder get _eagerBorder =>
      TableBorder.all(color: AppColors.border, width: 1);
  BorderSide get _side => BorderSide(color: AppColors.border, width: 1);

  TableRow _headerRow() {
    return TableRow(
      decoration: BoxDecoration(color: AppColors.panel),
      children: [
        for (final h in widget.headers)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: DefaultTextStyle(
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.cardHeading,
              ),
              child: h,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_virtualize) return _eagerTable();
    // Caller-supplied fixed widths still win (a paginated table pins its own
    // columns). Without them, auto-fit measures; fixed-width mode does not.
    _frozen ??= _explicitWidths() ??
        (_autoColumnWidth ? null : _fixedWidthsFor(widget.headers.length));
    if (_frozen == null) return _measuringTable();
    return _virtualTable();
  }

  /// One [kFixedGridColumnWidth] per column, for the fixed-width mode.
  List<double> _fixedWidthsFor(int count) =>
      List<double>.filled(count, kFixedGridColumnWidth);

  /// The original rendering: one [Table] holding every row.
  Widget _eagerTable() {
    final headers = widget.headers;
    final rows = widget.rows;
    final widths = widget.widths;
    final maxHeight = widget.maxHeight;
    final emptyText = widget.emptyText;
    final table = Table(
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      border: _eagerBorder,
      // Never leave the columns to FlexColumnWidth: inside the horizontal
      // scroller below the constraints are unbounded, and flex columns collapse
      // to zero width (see _ContentColumnWidth).
      defaultColumnWidth: const _ContentColumnWidth(),
      // Fixed-width mode pins every column, which also means [Table] never has
      // to walk the rows for an intrinsic width: the layout is a constant.
      columnWidths: widths != null
          ? <int, TableColumnWidth>{
              for (var i = 0; i < widths.length; i++) i: widths[i],
            }
          : (_autoColumnWidth
              ? null
              : <int, TableColumnWidth>{
                  for (var i = 0; i < headers.length; i++)
                    i: const FixedColumnWidth(kFixedGridColumnWidth),
                }),
      children: [
        _headerRow(),
        if (rows.isEmpty)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                child: Text(emptyText,
                    style: TextStyle(color: AppColors.muted, fontSize: 13)),
              ),
              for (var i = 1; i < headers.length; i++) const SizedBox.shrink(),
            ],
          )
        else
          ...rows,
      ],
    );

    // The web `table.grid` is `width: 100%` and sits in `.table-scroll`
    // (overflow:auto): it fills the card and only scrolls once its content is
    // wider. Constrain the table to at least the viewport width so short tables
    // stretch like the web one instead of hugging their text.
    //
    // Both axes get their own Scrollbar with an explicit controller. A Scrollbar
    // without one attaches to the PrimaryScrollController (the page), so the
    // thumb was painted but could not be dragged.
    //
    // [child] is the table itself, or (with a height cap) the vertical scroller
    // that wraps it. A Scrollbar is laid out in its child's coordinate space, so
    // the vertical scroller has to sit *inside* the horizontal one: a horizontal
    // Scrollbar wrapped around a vertical scroller paints its thumb at the
    // bottom of the whole row list, below the fold, instead of at the bottom of
    // the viewport.
    Widget horizontalScroller(Widget child) {
      return LayoutBuilder(
        builder: (context, constraints) {
          // Fixed-width mode must not stretch: [Table] grows its columns to the
          // incoming minWidth, which would turn "160px everywhere" into "as wide
          // as the window allows" on a wide one.
          final minWidth = _autoColumnWidth && constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : 0.0;
          return SingleChildScrollView(
            controller: _horizontal,
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: minWidth),
              child: child,
            ),
          );
        },
      );
    }
    if (maxHeight == null) {
      // Only attach a horizontal Scrollbar when there is actually a horizontal
      // scrollable beneath it; a Scrollbar whose controller has no
      // ScrollPosition asserts while painting.
      return Scrollbar(
        controller: _horizontal,
        thumbVisibility: true,
        notificationPredicate: (notification) => notification.depth == 0,
        child: horizontalScroller(table),
      );
    }
    // Height-capped table. The horizontal Scrollbar wraps the horizontal
    // scroller, and the vertical scroller lives inside it, so the horizontal
    // thumb is painted along the viewport's bottom edge. The vertical Scrollbar
    // stays outside both: its own box is the viewport, which is what keeps the
    // vertical thumb at the window's right edge when the table is wider than the
    // viewport too. Both bars are bound to the controller of the scroll view
    // they describe, the same nesting the browse grid uses.
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Scrollbar(
        controller: _vertical,
        thumbVisibility: true,
        child: Scrollbar(
          controller: _horizontal,
          thumbVisibility: true,
          notificationPredicate: (notification) => notification.depth == 0,
          child: horizontalScroller(
            SingleChildScrollView(
              controller: _vertical,
              child: table,
            ),
          ),
        ),
      ),
    );
  }

  /// First phase of a long table: measure the sample of rows that is on screen
  /// anyway, then hand the captured widths to [_virtualTable].
  ///
  /// The visible frame is the top of the table rendered exactly like the eager
  /// path (header + first [_measureRows] rows), so the switch to the scrolling
  /// body is not a visible jump.
  Widget _measuringTable() {
    final count = widget.headers.length;
    final table = Table(
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      border: _eagerBorder,
      columnWidths: <int, TableColumnWidth>{
        for (var i = 0; i < count; i++)
          i: _MeasuringColumn(i, (index, width) => _recorded[index] = width),
      },
      children: [
        _headerRow(),
        ...widget.rows.take(_measureRows),
      ],
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _frozen != null) return;
      if (_recorded.length < count) return;
      setState(() {
        _frozen = <double>[
          for (var i = 0; i < count; i++) _recorded[i] ?? 110,
        ];
      });
    });
    return LayoutBuilder(
      builder: (context, constraints) {
        final minWidth =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 0.0;
        return Scrollbar(
          controller: _horizontal,
          thumbVisibility: true,
          notificationPredicate: (notification) => notification.depth == 0,
          child: SingleChildScrollView(
            controller: _horizontal,
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: minWidth),
              child: table,
            ),
          ),
        );
      },
    );
  }

  Map<int, TableColumnWidth> _fixedWidths() => <int, TableColumnWidth>{
        for (var i = 0; i < _frozen!.length; i++)
          i: FixedColumnWidth(_frozen![i]),
      };

  /// Virtualised body: a pinned header plus one [ListView] item per row.
  ///
  /// The rows are the caller's [TableRow]s, so cell content, decoration and
  /// vertical alignment are unchanged; only the container differs. Column widths
  /// are frozen from the measuring pass, which is what keeps every row aligned
  /// and stops the columns from resizing as different rows scroll into view.
  Widget _virtualTable() {
    final rows = widget.rows;
    final widthMap = _fixedWidths();
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 0.0;
        final natural = _frozen!.fold<double>(0, (a, b) => a + b);
        // Same rule as the eager path: only auto-fit mode stretches to the
        // viewport, so the fixed widths really stay fixed.
        final totalWidth =
            (!_autoColumnWidth || natural > viewport) ? natural : viewport;
        final header = Table(
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          columnWidths: widthMap,
          // The header draws all four sides; body rows draw left/right/bottom
          // and the inner verticals, so the grid stays a single 1px mesh
          // instead of doubling the line between the header and the first row.
          border: TableBorder(
            top: _side,
            left: _side,
            right: _side,
            bottom: _side,
            verticalInside: _side,
          ),
          children: [_headerRow()],
        );
        final body = Scrollbar(
          controller: _vertical,
          thumbVisibility: true,
          child: ListView.builder(
            controller: _vertical,
            padding: EdgeInsets.zero,
            itemCount: rows.length,
            itemBuilder: (context, index) => Table(
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              columnWidths: widthMap,
              border: TableBorder(
                left: _side,
                right: _side,
                bottom: _side,
                verticalInside: _side,
              ),
              children: [rows[index]],
            ),
          ),
        );
        // With a height cap, cap the WHOLE table (header + body). The horizontal
        // scrollbar wraps this fixed-height box, so its thumb sits at the edge of
        // the viewport: users no longer have to scroll the rows to the bottom
        // before they can drag left/right.
        final Widget content;
        if (widget.maxHeight != null) {
          content = SizedBox(
            width: totalWidth,
            height: widget.maxHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [header, Expanded(child: body)],
            ),
          );
        } else {
          content = SizedBox(
            width: totalWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                header,
                SizedBox(height: _virtualBodyHeight, child: body),
              ],
            ),
          );
        }
        // The header and the body share one horizontal scroller, so they can
        // never scroll out of sync.
        return Scrollbar(
          controller: _horizontal,
          thumbVisibility: true,
          notificationPredicate: (notification) => notification.depth == 0,
          child: SingleChildScrollView(
            controller: _horizontal,
            scrollDirection: Axis.horizontal,
            child: content,
          ),
        );
      },
    );
  }
}

/// Page body: vertical scroll with the standard page padding.
///
/// It deliberately does **not** scroll horizontally. Wrapping the whole page in
/// a horizontal scroller gives its children an unbounded width, and every card
/// uses width: double.infinity (as the web .card does), which is invalid under
/// an infinite constraint - the layout threw and the page went blank.
///
/// Wide content instead gets its own horizontal scroller where it occurs:
/// [GridTable], [DataGrid], [CodeBlock] and [SqlEditor] all do this, so a long
/// value or a wide table stays reachable at any window size.
class PageScroll extends StatelessWidget {
  const PageScroll({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: padding ?? const EdgeInsets.all(AppMetrics.mainPadding),
      child: child,
    );
  }
}

/// A multi-line SQL editor that never widens the page.
///
/// A plain [TextField] wraps long statements, which makes indentation and
/// single-line queries hard to read; inside a narrow window it also forces the
/// surrounding card to grow. This puts a [TextField] on a horizontally
/// scrolling canvas of fixed minimum width, so long lines stay on one line and
/// can be scrolled into view without the layout itself overflowing.
class SqlEditor extends StatelessWidget {
  const SqlEditor({
    super.key,
    required this.controller,
    this.hint,
    this.lines = 8,
    this.onChanged,
    this.onRun,
  });

  final TextEditingController controller;
  final String? hint;
  final int lines;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onRun;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(
        maxHeight: (lines * 20.0) + 28,
        minHeight: (lines * 20.0) + 28,
      ),
      decoration: BoxDecoration(
        color: AppColors.panel,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppMetrics.radiusControl),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // A TextField inside an unbounded horizontal scroller throws
          // ("An InputDecorator ... cannot have an unbounded width"), so the
          // editor is given an explicit width: at least the viewport, and
          // wider when a long line needs it.
          final viewport =
              constraints.maxWidth.isFinite ? constraints.maxWidth : 600.0;
          return SingleChildScrollView(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: viewport < 1200 ? 1200 : viewport,
                child: CallbackShortcuts(
                  bindings: onRun == null ? const <ShortcutActivator, VoidCallback>{} : {
                    const SingleActivator(LogicalKeyboardKey.enter, control: true): onRun!,
                    const SingleActivator(LogicalKeyboardKey.enter, meta: true): onRun!,
                  },
                  // P11: expose the current SQL as a stable accessibility value.
                  // The native TextField value is not reliable in the macOS AX
                  // tree, so an explicit labelled node lets automation assert the
                  // editor content (default prelude, injected script, ...).
                  child: ListenableBuilder(
                    listenable: controller,
                    builder: (context, _) => Semantics(
                      key: const ValueKey('sql-editor-semantics'),
                      container: true,
                      label: pickText('SQL 编辑器', 'SQL editor'),
                      value: controller.text,
                      child: TextField(
                        controller: controller,
                        maxLines: null,
                        minLines: lines,
                        style: monoStyle(size: 13),
                        onChanged: onChanged,
                        decoration: InputDecoration(
                          hintText: hint == null ? null : trLiteral(hint!),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.all(8),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Text that ellipsizes inside its box and, when the text does not fit, shows
/// the **full untruncated value** on hover.
///
/// Requirement (round 18): every container that shortens content must let the
/// user read the whole thing with the mouse. A bare [Text] with
/// [TextOverflow.ellipsis] silently hides data (the join table picker was the
/// reported case); wrapping it in a [Tooltip] unconditionally would instead
/// pop a bubble for values that already fit. This measures the text with a
/// [TextPainter] and only attaches the tooltip when it really overflows, which
/// keeps the dense grids and trees usable.
///
/// The tooltip is always width-bounded: a long path / SQL / JSON value must not
/// render as one very wide line (that was itself an overflow, see
/// overflow_and_sqlite_test.dart).
class EllipsisText extends StatefulWidget {
  const EllipsisText(
    this.text, {
    super.key,
    this.style,
    this.maxLines = 1,
    this.textAlign,
    this.tooltip,
    this.tooltipMaxWidth = 420,
    this.softWrap = true,
    this.translate = false,
  });

  final String text;
  final TextStyle? style;
  final int maxLines;
  final TextAlign? textAlign;

  /// Message to show on hover. Defaults to [text], i.e. the full value.
  final String? tooltip;
  final double tooltipMaxWidth;
  final bool softWrap;

  /// Treat [text] as UI copy and translate it (see [trLiteral]).
  ///
  /// Data values (table names, cell values, paths) keep the default `false` so
  /// the translator can never rewrite user data.
  final bool translate;

  @override
  State<EllipsisText> createState() => _EllipsisTextState();
}

class _EllipsisTextState extends State<EllipsisText> {
  final GlobalKey _textKey = GlobalKey();
  bool _overflows = false;
  Size? _lastSize;

  @override
  Widget build(BuildContext context) {
    final body = Text(
      widget.translate ? trLiteral(widget.text) : widget.text,
      key: _textKey,
      style: widget.style,
      maxLines: widget.maxLines,
      overflow: TextOverflow.ellipsis,
      textAlign: widget.textAlign,
      softWrap: widget.softWrap,
    );
    if (widget.text.isNotEmpty) {
      // Truncation is only knowable after layout. Measuring the actual
      // RenderParagraph keeps this widget intrinsic-safe: a LayoutBuilder here
      // would throw inside Table's intrinsic column sizing (the data grids use
      // content-sized columns). See [RenderParagraph.didExceedMaxLines].
      //
      // The measurement runs after every build rather than once: a splitter /
      // window resize can start (or stop) truncating the same text, and the
      // tooltip has to follow. `setState` only fires when the outcome changes,
      // so this settles after one extra frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    }
    if (!_overflows) return body;
    return Tooltip(
      // Clamped in the string as well as the box: Flutter clips silently at the
      // height cap, which makes a cut-off value look complete.
      message: tooltipText(
          widget.translate
              ? trLiteral(widget.tooltip ?? widget.text)
              : (widget.tooltip ?? widget.text)),
      // Both axes: the width is per-site (a 520px cell value vs a 420px label),
      // the height is always capped so a long value cannot cover the window.
      constraints: BoxConstraints(
        maxWidth: widget.tooltipMaxWidth,
        maxHeight: kTooltipConstraints.maxHeight,
      ),
      waitDuration: const Duration(milliseconds: 300),
      child: body,
    );
  }

  void _measure() {
    if (!mounted) return;
    final render = _textKey.currentContext?.findRenderObject();
    if (render is! RenderParagraph) return; // not laid out yet
    final size = render.size;
    if (_lastSize == size) return;
    _lastSize = size;
    final overflows = render.didExceedMaxLines;
    if (overflows != _overflows) setState(() => _overflows = overflows);
  }
}

/// A plain table cell with the web typography.
///
/// Cells clip their content to the column width, so they carry an
/// [EllipsisText]: a value that does not fit is fully readable on hover.
/// [title] overrides the hover message when the raw cell text is not the most
/// useful caption (a path, a fully qualified column, ...).
Widget gridCell(Object? value,
    {bool mono = false, bool muted = false, String? title}) {
  final text = value == null ? '' : value.toString();
  final padded = Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    child: EllipsisText(
      text,
      style: mono
          ? monoStyle(
              size: 12, color: muted ? AppColors.muted : AppColors.bodyText)
          : TextStyle(
              fontSize: 13,
              color: muted ? AppColors.muted : AppColors.bodyText),
      maxLines: 2,
      tooltip: title ?? (text.isEmpty ? null : text),
    ),
  );
  return padded;
}

/// Page navigation row shared by the query-history and backup tables.
///
/// Mirrors the data browser's pager (prev / "第 N / M 页" / next / count) so the
/// two lists behave like the rest of the app instead of rendering everything.
class TablePager extends StatelessWidget {
  const TablePager({
    super.key,
    required this.page,
    required this.pages,
    required this.total,
    this.visible,
    this.onPage,
    this.keyPrefix = 'pager',
    this.unit = '行',
  });

  final int page;
  final int pages;
  final int total;
  final int? visible;
  final ValueChanged<int>? onPage;

  /// Prefix for the prev/next ValueKeys, so two pagers can coexist on a page.
  final String keyPrefix;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final current = page < 1 ? 1 : (page > pages ? pages : page);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          IconBtn(Icons.chevron_left,
              key: ValueKey('$keyPrefix-prev'),
              tooltip: '上一页',
              small: true,
              onPressed: onPage == null || current <= 1
                  ? null
                  : () => onPage!(current - 1)),
          const SizedBox(width: 8),
          Text('第 $current / $pages 页', style: kSmall),
          const SizedBox(width: 8),
          IconBtn(Icons.chevron_right,
              key: ValueKey('$keyPrefix-next'),
              tooltip: '下一页',
              small: true,
              onPressed: onPage == null || current >= pages
                  ? null
                  : () => onPage!(current + 1)),
          const Spacer(),
          Text('显示 ${visible ?? total} / $total $unit', style: kSmallMuted),
        ],
      ),
    );
  }
}

/// Monospace block for SQL previews and DDL, matching pre.code / sql-preview.
///
/// Scrolls on **both** axes: a long single-line statement used to be clipped at
/// the right edge with no way to reach the rest, and a long script grew past the
/// card until the page overflowed.
class CodeBlock extends StatelessWidget {
  const CodeBlock(
    this.text, {
    super.key,
    this.dark = false,
    this.maxHeight = 360,
    this.selectable = true,
  });

  final String text;
  final bool dark;
  final double maxHeight;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final content = text.isEmpty ? ' ' : text;
    final style = monoStyle(
      size: 12,
      color: dark ? AppColors.sqlPreviewText : AppColors.bodyText,
    );
    final body = selectable
        ? SelectableText(content, style: style)
        : Text(content, style: style);
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: maxHeight),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: dark ? AppColors.sqlPreviewBg : AppColors.code,
        border: Border.all(
            color: dark ? AppColors.sqlPreviewBg : AppColors.border),
        borderRadius: BorderRadius.circular(5),
      ),
      child: SingleChildScrollView(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: body,
        ),
      ),
    );
  }
}

/// Centered modal dialog replacing the web Modal.vue: 760px (980px wide),
/// backdrop click closes, and it always reserves a footer strip.
Future<T?> showAppModal<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  List<Widget> actions = const <Widget>[],
  bool wide = false,
}) {
  // The body is stateful (ModalBody) rather than a bare builder call, so it can
  // rebuild itself while a footer action such as "test connection" is running.
  return showModalShell<T>(
    context: context,
    title: title,
    builder: (context, _) => builder(context),
    actions: actions,
    wide: wide,
  );
}

/// Modal shell shared by [showAppModal] and callers that need the body's
/// [StateSetter] in their footer (see [ModalBody]).
Future<T?> showModalShell<T>({
  required BuildContext context,
  required String title,
  required Widget Function(BuildContext context, StateSetter setModalState) builder,
  List<Widget> actions = const <Widget>[],
  bool wide = false,
  ModalHandle? handle,
}) {
  return showDialog<T>(
    context: context,
    barrierColor: const Color(0x73141C28),
    // P3-06: Flutter exposes a *dismissible* modal barrier to the
    // accessibility tree as one screen-wide, tappable "Dismiss" node, and a
    // stray click on it closes the whole dialog. Automation aiming at a
    // control that the scroll viewport clips (P3-11: the "check for updates"
    // button at 1282x817) missed the button and hit the barrier, so the
    // dialog — and any half-filled form inside it, the connection editor
    // included — disappeared instead. Only `barrierDismissible: false`
    // removes that node (ModalBarrier then excludes itself from semantics),
    // so the shell relies on explicit affordances instead: the header ✕ that
    // every modal shell renders plus the caller's footer actions. There is
    // nothing left to label, which is why no localised barrierLabel is set.
    barrierDismissible: false,
    builder: (dialogContext) {
      handle?._dialogContext = dialogContext;
      // The title, the close tooltip and the footer buttons live outside the
      // ModalBody, so they used to keep the language the dialog was opened
      // with: switching to English in the settings dialog translated the body
      // immediately but left 「设置」/「关闭」 behind. Rebuilding the shell on
      // every language change keeps the whole dialog in sync; the body's State
      // survives the rebuild because the widget type and position do not move.
      return ValueListenableBuilder<AppLang>(
        valueListenable: I18n.lang,
        builder: (context, lang, _) => Dialog(
          alignment: Alignment.topCenter,
          insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 48),
          backgroundColor: AppColors.panel,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppMetrics.radiusModal),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: wide ? 980 : 760,
              maxHeight: MediaQuery.of(dialogContext).size.height * 0.82,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: AppColors.bodyText,
                          ),
                        ),
                      ),
                      IconBtn(Icons.close,
                          key: const ValueKey('dialog-close'),
                          tooltip: '关闭',
                          small: true,
                          onPressed: () => Navigator.of(dialogContext).pop()),
                    ],
                  ),
                ),
                Divider(height: 1, color: AppColors.border),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: ModalBody(builder: builder, handle: handle),
                  ),
                ),
                Divider(height: 1, color: AppColors.border),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      for (var i = 0; i < actions.length; i++) ...[
                        if (i > 0) const SizedBox(width: 8),
                        // P3-08b: the footer actions are built by the caller
                        // *before* showDialog runs. When Flutter meets the very
                        // same widget instance it skips rebuilding that
                        // subtree, so a footer created in Chinese kept its
                        // Chinese label after the user switched to English
                        // inside the dialog ("关闭" stayed 关闭 while the body
                        // and title became English). Keying the actions by
                        // language forces a fresh element — and therefore a
                        // fresh trLiteral() pass — on every switch.
                        KeyedSubtree(
                          key: ValueKey<String>('modal-action-$i-${lang.name}'),
                          child: actions[i],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// Stateful body for [showAppModal].
///
/// [showAppModal] renders its body through a plain `builder`, so the body only
/// rebuilds when its own `StatefulBuilder` is poked — and a footer button (the
/// "test connection" action, say) has no handle on that. Wrapping the body in
/// this widget gives the builder a `setModalState` it can call from anywhere,
/// and a `close` that pops the dialog it belongs to. The connection editor used
/// to lose both: a failed test set state on a StatefulBuilder the footer could
/// not reach, so the result never appeared, and "save" left the dialog open.
class ModalBody extends StatefulWidget {
  const ModalBody({super.key, required this.builder, this.handle});

  final Widget Function(BuildContext context, StateSetter setModalState) builder;

  /// Optional outward handle so the dialog footer can rebuild or close the body.
  final ModalHandle? handle;

  @override
  State<ModalBody> createState() => _ModalBodyState();
}

class _ModalBodyState extends State<ModalBody> {
  @override
  void initState() {
    super.initState();
    widget.handle?._attach(this);
  }

  @override
  void dispose() {
    widget.handle?._detach(this);
    super.dispose();
  }

  /// Public rebuild entry point for [ModalHandle].
  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, setState);
}

/// Handle on an open [showModalShell] dialog.
///
/// Footer actions are built outside the body, so they cannot call the body's
/// `setModalState`. Passing a handle into [showModalShell] lets them rebuild the
/// body after an async action (e.g. "test connection" finishing) and close the
/// dialog after a successful save — neither of which worked before.
class ModalHandle {
  _ModalBodyState? _body;
  BuildContext? _dialogContext;

  void _attach(_ModalBodyState body) => _body = body;
  void _detach(_ModalBodyState body) {
    if (identical(_body, body)) _body = null;
  }

  /// Rebuild the modal body if it is still on screen.
  void rebuild() => _body?.refresh();

  /// Close the dialog, optionally returning [result] to the awaiting caller.
  void close<T>([T? result]) {
    final context = _dialogContext;
    if (context == null || !context.mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop(result);
  }
}

/// Confirmation dialog replacing window.confirm. The detail string renders the
/// SQL that the multi-statement ALTER / sync confirmations used to embed.
Future<bool> confirmDialog(
  BuildContext context, {
  required String message,
  String? detail,
  String confirmLabel = '确定',
  bool danger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierColor: const Color(0x73141C28),
    // Same P3-06 reasoning as showModalShell: a dismissible barrier is a
    // tappable "Dismiss" node in the accessibility tree. The confirm dialog
    // has explicit 取消 / 确定 buttons, so the barrier only needs to block
    // input — not act as a second, unlabelled cancel button.
    barrierDismissible: false,
    builder: (context) => Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 48),
      backgroundColor: AppColors.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppMetrics.radiusModal),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text(trLiteral('请确认'),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            Divider(height: 1, color: AppColors.border),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(trLiteral(message),
                        style: const TextStyle(fontSize: 13)),
                    if (detail != null && detail.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      CodeBlock(detail, maxHeight: 240),
                    ],
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: AppColors.border),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Btn('取消', onPressed: () => Navigator.of(context).pop(false)),
                  const SizedBox(width: 8),
                  Btn(
                    confirmLabel,
                    primary: !danger,
                    danger: danger,
                    onPressed: () => Navigator.of(context).pop(true),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  return result ?? false;
}

/// Prompt for a single line of text (used by "new index" and similar).
///
/// `browse` adds a 浏览 button that fills the field from a real picker, so a
/// path input is never a bare text box the user has to type an absolute path
/// into.
Future<String?> promptDialog(
  BuildContext context, {
  required String title,
  String label = '',
  String initial = '',
  Future<String?> Function()? browse,
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showAppModal<String>(
    context: context,
    title: title,
    builder: (context) => Field(
      label: label,
      controller: controller,
      trailing: browse == null
          ? null
          : IconBtn(Icons.folder_open_outlined,
              tooltip: '浏览',
              small: true,
              onPressed: () async {
                final picked = await browse();
                if (picked != null && picked.isNotEmpty) {
                  controller.text = picked;
                }
              }),
    ),
    actions: [
      Builder(
        builder: (context) =>
            Btn('取消', onPressed: () => Navigator.of(context).pop()),
      ),
      Builder(
        builder: (context) => Btn(
          '确定',
          primary: true,
          onPressed: () => Navigator.of(context).pop(controller.text),
        ),
      ),
    ],
  );
  return result;
}

/// Copies text to the clipboard, mirroring the web behaviour.
Future<void> copyText(String value) async {
  await Clipboard.setData(ClipboardData(text: value));
}

/// Section label used inside cards, the web card h3.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppColors.cardHeading,
        ),
      );
}

/// Horizontal divider matching the web .sep element.
class Sep extends StatelessWidget {
  const Sep({super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 20,
        color: AppColors.border,
        margin: const EdgeInsets.symmetric(horizontal: 8),
      );
}

/// A compact tab strip for modal forms (used by the connection editor).
///
/// The desktop app has no Material TabBar in its dialogs because the dialogs
/// are not Scaffolds. This renders the same visual language as the table
/// workbench tabs: a bordered strip with an underline on the active tab, and
/// the body below it. Content is kept alive (IndexedStack) so switching tabs
/// does not lose controller focus or reset scroll position.
class FormTabs extends StatelessWidget {
  const FormTabs({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
    required this.children,
    this.trailing = const <Widget>[],
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;
  final List<Widget> children;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.border)),
          ),
          child: Row(
            children: [
              for (var i = 0; i < labels.length; i++)
                _FormTab(
                  label: labels[i],
                  active: i == index,
                  onTap: () => onChanged(i),
                ),
              if (trailing.isNotEmpty) ...[
                const Spacer(),
                ...trailing,
                const SizedBox(width: 6),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        IndexedStack(index: index, children: children),
      ],
    );
  }
}

class _FormTab extends StatelessWidget {
  const _FormTab({required this.label, required this.active, required this.onTap});

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? AppColors.header : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: active ? FontWeight.w600 : FontWeight.normal,
            color: active ? AppColors.header : AppColors.muted,
          ),
        ),
      ),
    );
  }
}

