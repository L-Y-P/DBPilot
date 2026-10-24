// 应用内帧耗时采样（src/frame_trace.dart）的纯逻辑测试。
//
// 这里刻意不依赖 SchedulerBinding：统计逻辑只认 FrameSample，
// 采样器的时间源与输出 sink 都是构造参数，所以可以直接喂假样本、假时钟。

import 'package:flutter/scheduler.dart' show FrameTiming, TimingsCallback;
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/frame_trace.dart';

FrameSample _sample({
  required int buildMs,
  required int rasterMs,
  int? totalMs,
}) {
  final total = totalMs ?? (buildMs + rasterMs);
  return FrameSample(
    build: Duration(milliseconds: buildMs),
    raster: Duration(milliseconds: rasterMs),
    total: Duration(milliseconds: total),
  );
}

void main() {
  group('FrameTraceStats', () {
    test('empty stats report zero frames and zero percentiles', () {
      final stats = FrameTraceStats();
      expect(stats.isEmpty, isTrue);
      expect(stats.count, 0);
      expect(stats.jankCount, 0);

      final summary = stats.summary();
      expect(summary.isEmpty, isTrue);
      expect(summary.frames, 0);
      expect(summary.jankFrames, 0);
      expect(summary.jankRatio, 0);
      expect(summary.build.p50, Duration.zero);
      expect(summary.build.p95, Duration.zero);
      expect(summary.build.max, Duration.zero);
      expect(summary.total.max, Duration.zero);
      expect(summary.toLine(), 'FRAME_TRACE frames=0 (no samples)');
    });

    test('single sample: p50 == p95 == max', () {
      final stats = FrameTraceStats()
        ..add(_sample(buildMs: 3, rasterMs: 4));
      final summary = stats.summary();
      expect(summary.frames, 1);
      for (final section in <FramePercentiles>[
        summary.build,
        summary.raster,
        summary.total,
      ]) {
        expect(section.p50, section.max);
        expect(section.p95, section.max);
      }
      expect(summary.build.max, const Duration(milliseconds: 3));
      expect(summary.raster.max, const Duration(milliseconds: 4));
      expect(summary.total.max, const Duration(milliseconds: 7));
    });

    test('p50 / p95 / max use nearest rank', () {
      // 20 帧，build 依次为 1..20ms。
      final stats = FrameTraceStats();
      for (var i = 1; i <= 20; i++) {
        stats.add(_sample(buildMs: i, rasterMs: i));
      }
      final summary = stats.summary();
      expect(summary.frames, 20);
      // ceil(0.50 * 20) = 10 -> 第 10 个样本 = 10ms
      expect(summary.build.p50, const Duration(milliseconds: 10));
      // ceil(0.95 * 20) = 19 -> 第 19 个样本 = 19ms
      expect(summary.build.p95, const Duration(milliseconds: 19));
      expect(summary.build.max, const Duration(milliseconds: 20));
      // total = build + raster
      expect(summary.total.p50, const Duration(milliseconds: 20));
      expect(summary.total.max, const Duration(milliseconds: 40));
    });

    test('p95 rounds up to the last sample for small windows', () {
      // 4 帧：ceil(0.95 * 4) = 4 -> max
      final stats = FrameTraceStats();
      for (var i = 1; i <= 4; i++) {
        stats.add(_sample(buildMs: i, rasterMs: 0));
      }
      expect(stats.summary().build.p95, const Duration(milliseconds: 4));
      // 3 帧：ceil(0.95 * 3) = 3 -> max；p50 是第 2 个
      final three = FrameTraceStats();
      for (var i = 1; i <= 3; i++) {
        three.add(_sample(buildMs: i, rasterMs: 0));
      }
      expect(three.summary().build.p50, const Duration(milliseconds: 2));
      expect(three.summary().build.p95, const Duration(milliseconds: 3));
    });

    test('jank counts frames whose total exceeds 16.67ms', () {
      final stats = FrameTraceStats();
      stats.add(_sample(buildMs: 5, rasterMs: 5)); // total 10ms  -> ok
      stats.add(_sample(buildMs: 8, rasterMs: 8)); // total 16ms  -> ok
      stats.add(_sample(buildMs: 10, rasterMs: 7)); // total 17ms -> jank
      stats.add(_sample(buildMs: 30, rasterMs: 30)); // total 60ms -> jank
      expect(stats.count, 4);
      expect(stats.jankCount, 2);
      expect(stats.summary().jankRatio, 0.5);
    });

    test('exactly 16.67ms is not jank (strictly greater)', () {
      final stats = FrameTraceStats();
      stats.add(FrameSample(
        build: const Duration(milliseconds: 16),
        raster: const Duration(milliseconds: 0),
        total: const Duration(microseconds: 16667),
      ));
      expect(stats.jankCount, 0);

      stats.add(FrameSample(
        build: const Duration(milliseconds: 16),
        raster: const Duration(milliseconds: 1),
        total: const Duration(microseconds: 16668),
      ));
      expect(stats.jankCount, 1);
    });

    test('reset clears samples and the jank counter', () {
      final stats = FrameTraceStats()
        ..add(_sample(buildMs: 30, rasterMs: 30));
      expect(stats.count, 1);
      expect(stats.jankCount, 1);
      stats.reset();
      expect(stats.isEmpty, isTrue);
      expect(stats.jankCount, 0);
      expect(stats.summary().frames, 0);
    });

    test('the summary line is one greppable line with all three sections', () {
      final stats = FrameTraceStats();
      for (var i = 0; i < 10; i++) {
        stats.add(_sample(buildMs: 2, rasterMs: 3));
      }
      final line = stats
          .summary()
          .toLine(window: const Duration(milliseconds: 2000));
      expect(line, startsWith('FRAME_TRACE frames=10 jank=0(0.0%) window=2000ms'));
      expect(line, contains('build(ms) p50=2.00 p95=2.00 max=2.00'));
      expect(line, contains('raster(ms) p50=3.00 p95=3.00 max=3.00'));
      expect(line, contains('total(ms) p50=5.00 p95=5.00 max=5.00'));
      expect(line.contains('\n'), isFalse, reason: 'one line per window');
    });
  });

  group('FrameSample', () {
    test('fromFrameTiming maps build / raster / total', () {
      // FrameTiming 的具名构造只用于测试，这里正好用它验证转换。
      final timing = FrameTiming(
        vsyncStart: 1000,
        buildStart: 1200,
        buildFinish: 4200, // build = 3000us
        rasterStart: 4300,
        rasterFinish: 9300, // raster = 5000us
        rasterFinishWallTime: 9400,
      );
      final sample = FrameSample.fromFrameTiming(timing);
      expect(sample.build, const Duration(microseconds: 3000));
      expect(sample.raster, const Duration(microseconds: 5000));
      expect(sample.total, const Duration(microseconds: 8300));
    });
  });

  group('FrameTrace', () {
    late List<TimingsCallback> registered;
    late List<TimingsCallback> unregistered;
    late List<String> lines;

    setUp(() {
      registered = <TimingsCallback>[];
      unregistered = <TimingsCallback>[];
      lines = <String>[];
    });

    FrameTrace buildTrace({DateTime Function()? clock}) => FrameTrace(
          onRegister: registered.add,
          onUnregister: unregistered.add,
          sink: lines.add,
          clock: clock,
        );

    test('disabled by default: no callback registered, nothing printed', () {
      final trace = buildTrace();
      expect(trace.start(enabled: false), isFalse);
      expect(trace.isRunning, isFalse);
      expect(registered, isEmpty,
          reason: '默认关闭时不允许碰 SchedulerBinding');
      expect(lines, isEmpty);

      // 关闭状态下喂样本也不会产生输出。
      trace.addSample(_sample(buildMs: 1, rasterMs: 1));
      expect(trace.stats.isEmpty, isTrue);
      expect(lines, isEmpty);
    });

    test('enabled: registers exactly one callback and prints a header', () {
      final trace = buildTrace();
      expect(trace.start(enabled: true), isTrue);
      expect(trace.isRunning, isTrue);
      expect(registered, hasLength(1));
      expect(lines, hasLength(1));
      expect(lines.single, startsWith('FRAME_TRACE enabled'));
      expect(lines.single, contains('DBPILOT_FRAME_TRACE=1'));
      expect(lines.single, contains('jank > 16.67ms'));

      // 幂等：重复 start 不会注册第二个回调。
      expect(trace.start(enabled: true), isTrue);
      expect(registered, hasLength(1));
      expect(lines, hasLength(1));
    });

    test('a full window of 60 frames flushes one summary line', () {
      final frozen = DateTime(2026, 1, 1);
      final trace = buildTrace(clock: () => frozen)..start(enabled: true);
      for (var i = 0; i < 59; i++) {
        trace.addSample(_sample(buildMs: 1, rasterMs: 1));
      }
      expect(lines, hasLength(1), reason: 'still below the 60-frame window');
      trace.addSample(_sample(buildMs: 1, rasterMs: 1));
      expect(lines, hasLength(2));
      expect(lines.last, startsWith('FRAME_TRACE frames=60'));
      expect(trace.stats.isEmpty, isTrue, reason: 'the window resets on flush');
    });

    test('the 2s wall-clock fallback flushes a partial window', () {
      var now = DateTime(2026, 1, 1);
      final trace = buildTrace(clock: () => now)..start(enabled: true);
      trace.addSample(_sample(buildMs: 2, rasterMs: 2));
      expect(lines, hasLength(1));
      now = now.add(const Duration(seconds: 2));
      trace.addSample(_sample(buildMs: 2, rasterMs: 2));
      expect(lines, hasLength(2));
      expect(lines.last, startsWith('FRAME_TRACE frames=2'));
      expect(lines.last, contains('window=2000ms'));
    });

    test('stop flushes the tail window and removes the callback', () {
      final frozen = DateTime(2026, 1, 1);
      final trace = buildTrace(clock: () => frozen)..start(enabled: true);
      for (var i = 0; i < 3; i++) {
        trace.addSample(_sample(buildMs: 20, rasterMs: 20));
      }
      trace.stop();
      expect(trace.isRunning, isFalse);
      expect(unregistered, hasLength(1));
      expect(lines, hasLength(2));
      expect(lines.last, startsWith('FRAME_TRACE frames=3 jank=3(100.0%)'));

      // 停止之后不再统计、不再输出。
      trace.addSample(_sample(buildMs: 20, rasterMs: 20));
      expect(lines, hasLength(2));
      expect(trace.stats.isEmpty, isTrue);
    });

    test('jank ratio appears in the flushed line', () {
      final frozen = DateTime(2026, 1, 1);
      final trace = buildTrace(clock: () => frozen)..start(enabled: true);
      for (var i = 0; i < 4; i++) {
        trace.addSample(_sample(buildMs: 30, rasterMs: 30));
      }
      trace.stop();
      expect(lines.last, contains('jank=4(100.0%)'));
      expect(lines.last, contains('total(ms) p50=60.00 p95=60.00 max=60.00'));
    });
  });
}
