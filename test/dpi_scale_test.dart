// Tests for the 1080p DPI strategy: the platform text-scaler clamp and the
// multi-resolution audit of the only bitmap asset the app ships.
//
// Companion docs: docs/DPI_STRATEGY.md. The two runner declarations
// (windows/runner/runner.exe.manifest, macos/Runner/Info.plist) are native
// files that cannot be exercised from a Dart test; they are asserted by
// inspection in the doc and are deliberately out of scope here.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/dpi_scale.dart';

/// Logical size the product mark is drawn at. Kept in sync with
/// 'lib/src/views/settings_dialog.dart' (Image.asset(..., width: 36, height: 36)).
const double kMarkDisplaySize = 36;

/// Reference font size used by the widget assertions; the framework scales the
/// paragraph by 'textScaler.scale(fontSize)'.
const double kProbeFontSize = 20;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('clampSystemTextScale', () {
    test('clamps a sub-1.0 system scale up to the 0.85 floor', () {
      final TextScaler out = clampSystemTextScale(TextScaler.linear(0.5));
      expect(out.scale(100), closeTo(85.0, 1e-9));
      expect(out.scale(11), closeTo(9.35, 1e-9));
    });

    test('1.0 is returned as the identical instance (no behaviour change)', () {
      final TextScaler raw = TextScaler.linear(1.0);
      final TextScaler out = clampSystemTextScale(raw);
      expect(identical(out, raw), isTrue);
      expect(out.scale(16), 16.0);
    });

    test('an in-range 1.2 is returned as the identical instance', () {
      final TextScaler raw = TextScaler.linear(1.2);
      final TextScaler out = clampSystemTextScale(raw);
      expect(identical(out, raw), isTrue);
      expect(out.scale(16), closeTo(19.2, 1e-9));
    });

    test('clamps a 2.0 system scale down to the 1.3 ceiling', () {
      final TextScaler out = clampSystemTextScale(TextScaler.linear(2.0));
      expect(out.scale(100), closeTo(130.0, 1e-9));
      expect(out.scale(kProbeFontSize), closeTo(26.0, 1e-9));
    });

    test('the interval endpoints are inclusive, not clamped', () {
      final TextScaler low = TextScaler.linear(kMinSystemTextScale);
      final TextScaler high = TextScaler.linear(kMaxSystemTextScale);
      expect(identical(clampSystemTextScale(low), low), isTrue);
      expect(identical(clampSystemTextScale(high), high), isTrue);
      expect(clampSystemTextScale(low).scale(100), closeTo(85.0, 1e-9));
      expect(clampSystemTextScale(high).scale(100), closeTo(130.0, 1e-9));
    });

    test('TextScaler.noScaling passes through unchanged', () {
      final TextScaler out = clampSystemTextScale(TextScaler.noScaling);
      expect(identical(out, TextScaler.noScaling), isTrue);
      expect(out.scale(16), 16.0);
    });

    test('composes with a non-linear platform scaler instead of flattening it',
        () {
      // Android 14-style scaler: proportional but already capped at 1.5x.
      final TextScaler system =
          TextScaler.linear(2.0).clamp(minScaleFactor: 0.0, maxScaleFactor: 1.5);
      final TextScaler out = clampSystemTextScale(system);
      expect(out.scale(100), closeTo(130.0, 1e-9));
      expect(out.scale(10), closeTo(13.0, 1e-9));
    });
  });


  group('applyTextScaleClamp', () {
    /// Pumps a single (undecorated) [Text] under a system scaler, optionally
    /// routed through [applyTextScaleClamp], and returns the built [RichText].
    Future<RichText> pumpProbe(
      WidgetTester tester,
      TextScaler system, {
      required bool clamp,
    }) async {
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: MediaQueryData(textScaler: system),
          // Center: give the paragraph loose constraints so getSize() reports
          // the text's own box instead of the 800x600 test surface.
          child: Center(
            child: Builder(builder: (BuildContext context) {
              const Widget probe =
                  Text('DPI', style: TextStyle(fontSize: kProbeFontSize));
              return clamp ? applyTextScaleClamp(context, probe) : probe;
            }),
          ),
        ),
      ));
      expect(find.byType(RichText), findsOneWidget);
      return tester.widget<RichText>(find.byType(RichText));
    }

    testWidgets('a 2.0 system scale is clamped to 1.3 for real text',
        (WidgetTester tester) async {
      final RichText unclampedWidget =
          await pumpProbe(tester, TextScaler.linear(2.0), clamp: false);
      expect(
          unclampedWidget.textScaler.scale(kProbeFontSize), closeTo(40.0, 1e-6));
      final Size unclamped = tester.getSize(find.text('DPI'));

      final RichText clampedWidget =
          await pumpProbe(tester, TextScaler.linear(2.0), clamp: true);
      expect(clampedWidget.textScaler.scale(kProbeFontSize), closeTo(26.0, 1e-6));
      final Size clamped = tester.getSize(find.text('DPI'));

      // The paragraph really shrank: 1.3x instead of 2.0x.
      expect(clamped.height, lessThan(unclamped.height));
      expect(clamped.height / unclamped.height, closeTo(1.3 / 2.0, 0.02));
    });

    testWidgets('a 0.5 system scale is raised to 0.85 for real text',
        (WidgetTester tester) async {
      final RichText rw =
          await pumpProbe(tester, TextScaler.linear(0.5), clamp: true);
      expect(rw.textScaler.scale(kProbeFontSize), closeTo(17.0, 1e-6));
    });

    testWidgets('100% renders bit-identically (same size as no clamp)',
        (WidgetTester tester) async {
      final RichText rw =
          await pumpProbe(tester, TextScaler.noScaling, clamp: true);
      expect(identical(rw.textScaler, TextScaler.noScaling), isTrue);
      final Size clamped = tester.getSize(find.text('DPI'));

      await pumpProbe(tester, TextScaler.noScaling, clamp: false);
      final Size plain = tester.getSize(find.text('DPI'));

      expect(clamped, plain);
    });

    testWidgets('in-range data is copied verbatim, only textScaler is touched',
        (WidgetTester tester) async {
      final MediaQueryData source = MediaQueryData(
        size: const Size(1920, 1080),
        devicePixelRatio: 2.0,
        textScaler: TextScaler.linear(1.2),
      );
      late MediaQueryData seen;
      await tester.pumpWidget(MediaQuery(
        data: source,
        child: Builder(builder: (BuildContext context) {
          return applyTextScaleClamp(
            context,
            Builder(builder: (BuildContext inner) {
              seen = MediaQuery.of(inner);
              return const SizedBox.shrink();
            }),
          );
        }),
      ));
      expect(seen, source);
      expect(seen.textScaler.scale(16), closeTo(19.2, 1e-9));
    });

    testWidgets('out-of-range data keeps every other MediaQuery field',
        (WidgetTester tester) async {
      final MediaQueryData source = MediaQueryData(
        size: const Size(1280, 720),
        devicePixelRatio: 1.5,
        padding: const EdgeInsets.all(7),
        textScaler: TextScaler.linear(2.0),
      );
      late MediaQueryData seen;
      await tester.pumpWidget(MediaQuery(
        data: source,
        child: Builder(builder: (BuildContext context) {
          return applyTextScaleClamp(
            context,
            Builder(builder: (BuildContext inner) {
              seen = MediaQuery.of(inner);
              return const SizedBox.shrink();
            }),
          );
        }),
      ));
      expect(seen.size, source.size);
      expect(seen.devicePixelRatio, source.devicePixelRatio);
      expect(seen.padding, source.padding);
      expect(seen.textScaler.scale(kProbeFontSize), closeTo(26.0, 1e-9));
    });
  });

  group('bitmap asset audit', () {
    test('dbpilot.png is 128x128 and covers >= 3x at its 36px display size',
        () async {
      final ByteData data = await rootBundle.load('assets/images/dbpilot.png');
      final Uint8List bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

      // PNG signature (8 bytes), then the first chunk: 4-byte big-endian
      // length at offset 8, 4-byte type at 12 ('IHDR'), then width at 16 and
      // height at 20.
      expect(bytes.sublist(0, 8),
          <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      final ByteData header = ByteData.sublistView(bytes);
      expect(header.getUint32(8), 13); // IHDR payload length
      expect(header.getUint32(12), 0x49484452); // 'IHDR'
      final int width = header.getUint32(16);
      final int height = header.getUint32(20);

      // Cross-check the header against the engine's own decoder.
      final ui.Image image = await decodeImageFromList(bytes);
      addTearDown(image.dispose);
      expect(image.width, width);
      expect(image.height, height);

      expect(width, 128);
      expect(height, 128);

      // Displayed at 36 logical px, so the source covers 128 / 36 = 3.56x:
      // every 1x / 2x / 3x device pixel ratio is served by real pixels instead
      // of an upscale. No @2x/@3x variants are required.
      expect(width / kMarkDisplaySize, greaterThanOrEqualTo(3.0));
      expect(width / kMarkDisplaySize, closeTo(3.5556, 0.001));
    });
  });
}
