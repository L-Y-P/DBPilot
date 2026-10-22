import 'package:flutter/material.dart' as flutter;

import 'i18n_literals.dart';

/// [Tooltip] whose [message] goes through the literal translator.
///
/// Tooltips are a separate rendering channel from [Text]: their message is not
/// a widget, so the translating `Text` wrapper never sees it. UI files that
/// render copy through a tooltip import this class instead of Flutter's
/// (`import 'package:flutter/material.dart' hide Text, Tooltip;`).
///
/// Only [message] is translated; [richMessage] (an arbitrary inline span) is
/// passed through untouched, and so are data values that a caller already
/// marked as such.
class Tooltip extends flutter.StatelessWidget {
  const Tooltip({
    super.key,
    this.message,
    this.richMessage,
    this.constraints,
    this.padding,
    this.margin,
    this.verticalOffset,
    this.preferBelow,
    this.excludeFromSemantics,
    this.decoration,
    this.textStyle,
    this.textAlign,
    this.waitDuration,
    this.showDuration,
    this.exitDuration,
    this.enableTapToDismiss = true,
    this.triggerMode,
    this.enableFeedback,
    this.onTriggered,
    this.mouseCursor,
    this.ignorePointer,
    this.positionDelegate,
    this.child,
    this.noTranslate = false,
  });

  final String? message;
  final flutter.InlineSpan? richMessage;
  final flutter.BoxConstraints? constraints;
  final flutter.EdgeInsetsGeometry? padding;
  final flutter.EdgeInsetsGeometry? margin;
  final double? verticalOffset;
  final bool? preferBelow;
  final bool? excludeFromSemantics;
  final flutter.Decoration? decoration;
  final flutter.TextStyle? textStyle;
  final flutter.TextAlign? textAlign;
  final Duration? waitDuration;
  final Duration? showDuration;
  final Duration? exitDuration;
  final bool enableTapToDismiss;
  final flutter.TooltipTriggerMode? triggerMode;
  final bool? enableFeedback;
  final void Function()? onTriggered;
  final flutter.MouseCursor? mouseCursor;
  final bool? ignorePointer;
  final flutter.TooltipPositionDelegate? positionDelegate;
  final flutter.Widget? child;

  /// Leave [message] untranslated (it is a data value, not UI copy).
  final bool noTranslate;

  @override
  flutter.Widget build(flutter.BuildContext context) => flutter.Tooltip(
        message:
            message == null || noTranslate ? message : trLiteral(message!),
        richMessage: richMessage,
        constraints: constraints,
        padding: padding,
        margin: margin,
        verticalOffset: verticalOffset,
        preferBelow: preferBelow,
        excludeFromSemantics: excludeFromSemantics,
        decoration: decoration,
        textStyle: textStyle,
        textAlign: textAlign,
        waitDuration: waitDuration,
        showDuration: showDuration,
        exitDuration: exitDuration,
        enableTapToDismiss: enableTapToDismiss,
        triggerMode: triggerMode,
        enableFeedback: enableFeedback,
        onTriggered: onTriggered,
        mouseCursor: mouseCursor,
        ignorePointer: ignorePointer,
        positionDelegate: positionDelegate,
        child: child,
      );
}
