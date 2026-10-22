import 'package:flutter/widgets.dart' as flutter;

import 'i18n_literals.dart';

/// [Text] with the desktop literal translator applied to its content.
///
/// The English UI is produced by translating **rendered strings** (see
/// [trLiteral] in `i18n_literals.dart`): view code keeps writing Chinese copy
/// and the translation tables turn the known UI strings into English when the
/// language is switched to `en`. Unknown text (table names, SQL, driver
/// errors, user data) is returned unchanged.
///
/// Translating at the string level only works if every rendered string passes
/// through the translator. Rather than wrapping hundreds of call sites in
/// `trLiteral(...)`, UI files shadow Flutter's `Text` with this one:
///
/// ```dart
/// import 'package:flutter/material.dart' hide Text;
/// import '../text.dart';
/// ```
///
/// Every `Text(...)` in those files then renders through [trLiteral] at build
/// time, so switching the language in the top bar (which rebuilds the shell)
/// re-renders the copy without touching the call site. Strings that are *not*
/// rendered by a [Text] — `Tooltip.message`, `InputDecoration.hintText`,
/// accessibility labels — must still be wrapped in [trLiteral] explicitly.
///
/// The widget mirrors [flutter.Text]'s constructor. The only difference is that
/// the text is translated, and that [data] always holds the **untranslated**
/// source text (callers such as menu-item tooltips read it).
/// Source text of a text widget, whether it is this [Text] or Flutter's own.
///
/// Widgets that read a child's label back (menu-item tooltips) receive either
/// type depending on which `Text` the calling file imported, so both are
/// recognised here instead of duplicating the check at every call site.
String? sourceTextOf(flutter.Widget child) {
  if (child is Text) return child.data;
  if (child is flutter.Text) return child.data;
  return null;
}


class Text extends flutter.StatelessWidget {
  const Text(
    this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.semanticsIdentifier,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
    this.noTranslate = false,
  });

  /// The text to display, as written in the source (never translated here).
  final String data;
  final flutter.TextStyle? style;
  final flutter.StrutStyle? strutStyle;
  final flutter.TextAlign? textAlign;
  final flutter.TextDirection? textDirection;
  final flutter.Locale? locale;
  final bool? softWrap;
  final flutter.TextOverflow? overflow;
  final flutter.TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final String? semanticsIdentifier;
  final flutter.TextWidthBasis? textWidthBasis;
  final flutter.TextHeightBehavior? textHeightBehavior;
  final flutter.Color? selectionColor;

  /// Render [data] verbatim.
  ///
  /// Data values (a connection name, a database account, a cell value) must
  /// never be translated, even if they happen to equal a UI string. Copy built
  /// in code that already chose its own language (for example
  /// `I18n.current == AppLang.en ? 'Rows' : '行数'`) also sets this, so the
  /// translator cannot rewrite it a second time.
  final bool noTranslate;

  @override
  flutter.Widget build(flutter.BuildContext context) => flutter.Text(
        noTranslate ? data : trLiteral(data),
        style: style,
        strutStyle: strutStyle,
        textAlign: textAlign,
        textDirection: textDirection,
        locale: locale,
        softWrap: softWrap,
        overflow: overflow,
        textScaler: textScaler,
        maxLines: maxLines,
        semanticsLabel: semanticsLabel == null ? null : trLiteral(semanticsLabel!),
        semanticsIdentifier: semanticsIdentifier,
        textWidthBasis: textWidthBasis,
        textHeightBehavior: textHeightBehavior,
        selectionColor: selectionColor,
      );
}
