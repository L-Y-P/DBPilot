// Initial-window placement that always keeps the title bar on screen.
//
// Bug (round 85, reported on Windows via 向日葵 virtual display): the app opened
// at its saved/default size (1440x900) centred on the work area. On a display
// smaller than that size (e.g. the SunLogin IDD virtual monitor 1024x768, or a
// small RDP session), centring an over-sized window pushed its top edge to a
// negative Y, so the native title bar — with the minimise / maximise / close
// buttons — sat *above* the visible screen and the user could not reach it
// ("窗口控件无法显示").
//
// This file holds the pure geometry so it is unit-testable without Flutter's
// window plugins. [resolveWindowPlacement] returns a size clamped into the work
// area and a position (in the same coordinate space as the work area) that keeps
// the whole window — title bar included — fully on screen.

import 'dart:ui' show Size, Offset, Rect;

/// A supported, on-screen window size + top-left position.
class WindowPlacement {
  const WindowPlacement({required this.size, required this.position, required this.maximized});

  final Size size;
  final Offset position;

  /// Passed through from the caller: when the window should open maximised the
  /// saved size/position are ignored by the shell, but a sane size is still
  /// returned so nothing downstream divides by zero.
  final bool maximized;

  @override
  String toString() =>
      'WindowPlacement(size: $size, position: $position, maximized: $maximized)';
}

/// Resolve the initial window size and position from saved state + the work area.
///
/// * [workArea] is the usable desktop rectangle in logical pixels (origin is the
///   display's top-left; on a secondary monitor it can start at a non-zero X/Y).
/// * [savedSize] / [savedPosition] are the last-run window geometry; either may
///   be null on first run.
/// * [preferredSize] is the default size when nothing is saved (e.g. 1440x900).
/// * [minSize] is the smallest the window may be shrunk to; if the work area is
///   itself smaller than [minSize] the window is allowed to match the work area
///   (a title bar you can see beats a minimum size you cannot reach).
///
/// The result's size never exceeds the work area, and the position always keeps
/// the window within [workArea] so the title bar and border are reachable.
WindowPlacement resolveWindowPlacement({
  required Rect workArea,
  Size? savedSize,
  Offset? savedPosition,
  Size preferredSize = const Size(1440, 900),
  Size minSize = const Size(960, 600),
  bool maximized = false,
  double margin = 0,
}) {
  double waW = workArea.width;
  double waH = workArea.height;

  // Desired size: saved (if a sane positive size) else the preferred default.
  double wantW = (savedSize != null && savedSize.width > 0)
      ? savedSize.width
      : preferredSize.width;
  double wantH = (savedSize != null && savedSize.height > 0)
      ? savedSize.height
      : preferredSize.height;

  // Usable area inside the margin.
  final double availW = (waW - margin * 2).clamp(1.0, double.infinity);
  final double availH = (waH - margin * 2).clamp(1.0, double.infinity);

  // Clamp size into the work area. The minimum only applies when it actually
  // fits; otherwise we fall back to the available area so the window (and its
  // title bar) is never larger than the screen.
  final double maxW = availW;
  final double maxH = availH;
  final double lowerW = minSize.width <= maxW ? minSize.width : maxW;
  final double lowerH = minSize.height <= maxH ? minSize.height : maxH;

  double finalW = wantW.clamp(lowerW, maxW);
  double finalH = wantH.clamp(lowerH, maxH);

  // Position: keep the saved top-left if it leaves the whole window on screen;
  // otherwise pull it back inside, and centre it when there is no saved spot.
  double x;
  double y;
  if (savedPosition == null) {
    // Centre within the work area (not the full display): this is what pushes
    // an over-sized window to a negative Y when not clamped — here we already
    // clamped the size, so centring is safe.
    x = workArea.left + (waW - finalW) / 2;
    y = workArea.top + (waH - finalH) / 2;
  } else {
    x = savedPosition.dx;
    y = savedPosition.dy;
  }

  // Pull the rectangle fully inside the work area (top-left first, so an
  // over-sized window never keeps a negative Y).
  final double minX = workArea.left + margin;
  final double minY = workArea.top + margin;
  final double maxX = workArea.left + waW - finalW - margin;
  final double maxY = workArea.top + waH - finalH - margin;

  if (maxX >= minX) {
    if (x < minX) x = minX;
    if (x > maxX) x = maxX;
  } else {
    x = minX; // window wider than work area (already clamped, but be safe)
  }
  if (maxY >= minY) {
    if (y < minY) y = minY;
    if (y > maxY) y = maxY;
  } else {
    y = minY;
  }

  return WindowPlacement(
    size: Size(finalW, finalH),
    position: Offset(x, y),
    maximized: maximized,
  );
}
