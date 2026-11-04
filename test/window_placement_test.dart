// Round 85: initial-window placement must keep the title bar (minimise /
// maximise / close) on screen even when the saved/default size is larger than
// the current display — the bug behind "窗口控件无法显示" on a small virtual
// monitor (SunLogin IDD 1024x768 with a 1440x900 saved size).

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/window_placement.dart';

void main() {
  test('oversized saved size is clamped into a small work area (no negative Y)',
      () {
    // 1440x900 window on a 1024x768 work area (the reported bug).
    final p = resolveWindowPlacement(
      workArea: const Rect.fromLTWH(0, 0, 1024, 768),
      savedSize: const Size(1440, 900),
    );
    expect(p.size.width, lessThanOrEqualTo(1024));
    expect(p.size.height, lessThanOrEqualTo(768));
    // Crucially the top edge (title bar) must not be above the screen.
    expect(p.position.dy, greaterThanOrEqualTo(0));
    expect(p.position.dx, greaterThanOrEqualTo(0));
    // And the whole window stays inside the work area.
    expect(p.position.dx + p.size.width, lessThanOrEqualTo(1024 + 0.001));
    expect(p.position.dy + p.size.height, lessThanOrEqualTo(768 + 0.001));
  });

  test('a size that fits is kept and centred in the work area', () {
    final p = resolveWindowPlacement(
      workArea: const Rect.fromLTWH(0, 0, 1920, 1080),
      savedSize: const Size(1440, 900),
    );
    expect(p.size, const Size(1440, 900));
    expect(p.position.dx, closeTo((1920 - 1440) / 2, 0.001));
    expect(p.position.dy, closeTo((1080 - 900) / 2, 0.001));
  });

  test('a valid saved position is preserved', () {
    final p = resolveWindowPlacement(
      workArea: const Rect.fromLTWH(0, 0, 1920, 1080),
      savedSize: const Size(1200, 800),
      savedPosition: const Offset(100, 60),
    );
    expect(p.size, const Size(1200, 800));
    expect(p.position, const Offset(100, 60));
  });

  test('an off-screen saved position is pulled back inside', () {
    // Saved bottom-right on a big monitor, now on a smaller one.
    final p = resolveWindowPlacement(
      workArea: const Rect.fromLTWH(0, 0, 1366, 768),
      savedSize: const Size(1200, 800),
      savedPosition: const Offset(1800, 1000),
    );
    expect(p.position.dx + p.size.width, lessThanOrEqualTo(1366 + 0.001));
    expect(p.position.dy + p.size.height, lessThanOrEqualTo(768 + 0.001));
    expect(p.position.dx, greaterThanOrEqualTo(0));
    expect(p.position.dy, greaterThanOrEqualTo(0));
  });

  test('secondary monitor offset is respected (work area starts at non-zero)',
      () {
    final p = resolveWindowPlacement(
      workArea: const Rect.fromLTWH(1920, 0, 1280, 1024),
      savedSize: const Size(1000, 700),
    );
    // Centred within the secondary monitor, i.e. X >= 1920.
    expect(p.position.dx, greaterThanOrEqualTo(1920));
    expect(p.position.dx + p.size.width, lessThanOrEqualTo(1920 + 1280 + 0.001));
  });

  test('work area smaller than the minimum size does not force an oversized window',
      () {
    final p = resolveWindowPlacement(
      workArea: const Rect.fromLTWH(0, 0, 800, 500),
      savedSize: const Size(960, 600),
      minSize: const Size(960, 600),
    );
    expect(p.size.width, lessThanOrEqualTo(800));
    expect(p.size.height, lessThanOrEqualTo(500));
    expect(p.position.dy, greaterThanOrEqualTo(0));
  });

  test('maximized flag is passed through', () {
    final p = resolveWindowPlacement(
      workArea: const Rect.fromLTWH(0, 0, 1920, 1080),
      savedSize: const Size(1440, 900),
      maximized: true,
    );
    expect(p.maximized, isTrue);
  });

  test('no saved size uses the preferred default, clamped to the display', () {
    final p = resolveWindowPlacement(
      workArea: const Rect.fromLTWH(0, 0, 1024, 768),
      preferredSize: const Size(1440, 900),
    );
    expect(p.size.width, lessThanOrEqualTo(1024));
    expect(p.size.height, lessThanOrEqualTo(768));
  });
}
