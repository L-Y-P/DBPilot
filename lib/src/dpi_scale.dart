// System-DPI strategy: declare DPI awareness on both desktop runners, keep
// every layout in Flutter logical pixels, and bound the *system* text scale so
// the 1080p design baseline survives a user who runs at 150%+ font scaling.
//
// Why clamp the system text scaler to 0.85–1.3?
//   * The UI is designed at 1080p (see docs/DPI_STRATEGY.md). Table rows,
//     buttons, pills and the query
//     builder's data-source panel have *fixed* heights and only the text inside
//     them is proportional, so an unbounded system text scale eventually
//     overflows those boxes.
//   * 1.3 is the ceiling: the fixed boxes text must fit are 24px (a data-grid
//     row element, data_grid.dart:815), 30px (data-grid rows and their header,
//     data_grid.dart:581) and 36px (a default button, kControlHeight in
//     widgets.dart:761). The most common label size is 13px, which at 1.3x
//     lays out as 16.9px with a ~20px line box - still inside the 24px box; at
//     1.5x-2.0x it exceeds the 24px box and the 30px row, and the grid clips.
//   * 0.85 is the floor: the smallest text this app draws is 9px
//     (data_grid.dart:774, builder/builder_widgets.dart:877) and 0.85 x 9 =
//     7.65px is already at the edge of legibility, so the clamp never shrinks
//     text below that. Fixed paddings and icon boxes also stop shrinking at
//     0.85, past which rows would show dead space around tiny text.
//
// 100% (no scaling) must stay *byte-for-byte* identical to the pre-change app,
// so goldens cannot move:
//   * [clampSystemTextScale] returns the *same instance* it was given whenever
//     the scaler already lies inside the interval, so
//     'MediaQueryData.copyWith(textScaler: ...)' produces an equal value and
//     the inherited data is unchanged;
//   * [TextScaler.noScaling] is returned unchanged (identity), which is the
//     default scaler in widget tests and in the golden suite.
// Nothing here mutates layout, only the inherited text scaler, and only when
// the platform value is actually outside the interval.

import 'package:flutter/widgets.dart';

/// Lower bound of the system text scale this app renders.
///
/// See the file header for why 0.85 and not something smaller.
const double kMinSystemTextScale = 0.85;

/// Upper bound of the system text scale this app renders.
///
/// See the file header for why 1.3 and not something larger.
const double kMaxSystemTextScale = 1.3;

/// Clamps [raw] (the platform-provided text scaler) into
/// [kMinSystemTextScale] .. [kMaxSystemTextScale].
///
/// * inside the interval (including the 100% case and
///   [TextScaler.noScaling]) the *same* instance is returned, so callers keep
///   the framework's exact behaviour;
/// * outside it, a proportional scaler is returned instead. Non-linear
///   platform scalers (e.g. Android 14's font-scale curve) stay non-linear:
///   [TextScaler.clamp] composes with them rather than flattening them.
TextScaler clampSystemTextScale(TextScaler raw) {
  if (identical(raw, TextScaler.noScaling)) return TextScaler.noScaling;
  return raw.clamp(
    minScaleFactor: kMinSystemTextScale,
    maxScaleFactor: kMaxSystemTextScale,
  );
}


/// Wraps [child] in a [MediaQuery] whose only changed field is a clamped
/// [MediaQueryData.textScaler]; every other field is copied verbatim.
///
/// The widget is intended to sit just under the root [MaterialApp] (see
/// main.dart) so dialogs, overlays and tooltips inherit the same clamp.
Widget applyTextScaleClamp(BuildContext context, Widget child) {
  final MediaQueryData media = MediaQuery.of(context);
  final TextScaler clamped = clampSystemTextScale(media.textScaler);
  return MediaQuery(
    data: media.copyWith(textScaler: clamped),
    child: child,
  );
}
