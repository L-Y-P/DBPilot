// 应用内帧耗时采样（FrameTiming trace）。
//
// 背景：AX / AppleScript 只能读到控件树，拿不到任何帧信息，所以「滚动到底卡不卡」
// 只能由应用自己回答。这里用 SchedulerBinding.addTimingsCallback 收集引擎上报的
// FrameTiming，周期性打印一行可被脚本 grep/awk 的统计行，用于 docs/UI_AUTOMATION_TESTING.md
// §5 的滚动性能量化。
//
// 开关：环境变量 DBPILOT_FRAME_TRACE=1（默认关闭，关闭时不注册任何回调，
// 引擎侧的性能统计开销约为 0）。
//
//   DBPILOT_FRAME_TRACE=1 open -a DBPilot          # 或
//   DBPILOT_FRAME_TRACE=1 flutter run -d macos
//
// 输出（每 60 帧或每 2 秒一行，单位毫秒；p50/p95 用最近秩法 nearest-rank）：
//
//   FRAME_TRACE enabled (DBPILOT_FRAME_TRACE=1): flush every 60 frames or 2000ms; jank > 16.67ms
//   FRAME_TRACE frames=60 jank=3(5.0%) window=2016ms | build(ms) p50=0.42 p95=1.85 max=7.31 | raster(ms) p50=0.90 p95=3.20 max=9.44 | total(ms) p50=1.40 p95=5.20 max=16.90
//
// 为什么用环境变量而不是设置项：
//   * 采样只在自动化 / 性能排查时需要，普通用户永远不该看到它，也不该为它付费；
//   * 设置项要走 Rust 核心持久化 + 设置面板 + 中英文文案，成本远大于收益；
//   * 环境变量在进程启动的第一帧之前就生效，不会漏掉首屏那几帧。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// 输出行的固定前缀，自动化脚本靠它 grep。
const String frameTraceTag = 'FRAME_TRACE';

/// 毫秒格式化：统一两位小数，方便直接比较日志。
String formatMillis(Duration duration) =>
    (duration.inMicroseconds / 1000).toStringAsFixed(2);

/// 一帧的耗时快照。
///
/// 统计逻辑只认这个轻量结构，不认 dart:ui 的 [FrameTiming]（它的构造函数不是给
/// 业务代码用的），真实回调通过 [FrameSample.fromFrameTiming] 做一次转换。
@immutable
class FrameSample {
  const FrameSample({
    required this.build,
    required this.raster,
    required this.total,
  });

  /// 把引擎上报的一帧转成统计用的样本。
  factory FrameSample.fromFrameTiming(FrameTiming timing) => FrameSample(
        build: timing.buildDuration,
        raster: timing.rasterDuration,
        total: timing.totalSpan,
      );

  /// UI 线程 build 耗时。
  final Duration build;

  /// raster 线程耗时。
  final Duration raster;

  /// vsync 到 raster 结束的总耗时。
  final Duration total;
}

/// 一组耗时的 p50 / p95 / max。
@immutable
class FramePercentiles {
  const FramePercentiles({
    required this.p50,
    required this.p95,
    required this.max,
  });

  static const FramePercentiles zero = FramePercentiles(
    p50: Duration.zero,
    p95: Duration.zero,
    max: Duration.zero,
  );

  final Duration p50;
  final Duration p95;
  final Duration max;

  String toSection(String label) =>
      '$label(ms) p50=${formatMillis(p50)} p95=${formatMillis(p95)} '
      'max=${formatMillis(max)}';
}

/// 一个采样窗口的汇总结果。
@immutable
class FrameTraceSummary {
  const FrameTraceSummary({
    required this.frames,
    required this.jankFrames,
    required this.build,
    required this.raster,
    required this.total,
  });

  final int frames;
  final int jankFrames;
  final FramePercentiles build;
  final FramePercentiles raster;
  final FramePercentiles total;

  bool get isEmpty => frames == 0;

  /// jank 帧占比（0..1）。
  double get jankRatio => frames == 0 ? 0 : jankFrames / frames;

  /// 单行日志。[window] 是这个采样窗口的墙钟时长。
  String toLine({Duration? window, String tag = frameTraceTag}) {
    if (isEmpty) return '$tag frames=0 (no samples)';
    final head = <String>[
      '$tag frames=$frames',
      'jank=$jankFrames(${(jankRatio * 100).toStringAsFixed(1)}%)',
      if (window != null) 'window=${window.inMilliseconds}ms',
    ];
    return <String>[
      head.join(' '),
      build.toSection('build'),
      raster.toSection('raster'),
      total.toSection('total'),
    ].join(' | ');
  }
}

/// 采样窗口内的统计（纯逻辑，可单测）。
///
/// 判定 jank：total 严格大于 [jankThreshold]（默认 16.67ms，即 60fps 的帧预算）。
class FrameTraceStats {
  FrameTraceStats({this.jankThreshold = FrameTrace.defaultJankThreshold});

  final Duration jankThreshold;

  final List<FrameSample> _samples = <FrameSample>[];
  int _jankCount = 0;

  int get count => _samples.length;
  bool get isEmpty => _samples.isEmpty;
  int get jankCount => _jankCount;

  void add(FrameSample sample) {
    _samples.add(sample);
    if (sample.total > jankThreshold) _jankCount++;
  }

  void addAll(Iterable<FrameSample> samples) {
    for (final sample in samples) {
      add(sample);
    }
  }

  void reset() {
    _samples.clear();
    _jankCount = 0;
  }

  FrameTraceSummary summary() {
    if (_samples.isEmpty) {
      return const FrameTraceSummary(
        frames: 0,
        jankFrames: 0,
        build: FramePercentiles.zero,
        raster: FramePercentiles.zero,
        total: FramePercentiles.zero,
      );
    }
    final build = <int>[for (final s in _samples) s.build.inMicroseconds]..sort();
    final raster = <int>[for (final s in _samples) s.raster.inMicroseconds]
      ..sort();
    final total = <int>[for (final s in _samples) s.total.inMicroseconds]..sort();
    return FrameTraceSummary(
      frames: _samples.length,
      jankFrames: _jankCount,
      build: _percentiles(build),
      raster: _percentiles(raster),
      total: _percentiles(total),
    );
  }

  FramePercentiles _percentiles(List<int> sorted) => FramePercentiles(
        p50: _nearestRank(sorted, 0.50),
        p95: _nearestRank(sorted, 0.95),
        max: Duration(microseconds: sorted.last),
      );

  /// 最近秩法：p 分位取排序后第 ceil(p*n) 个样本（1-based）。
  Duration _nearestRank(List<int> sorted, double p) {
    var rank = (p * sorted.length).ceil();
    if (rank < 1) rank = 1;
    if (rank > sorted.length) rank = sorted.length;
    return Duration(microseconds: sorted[rank - 1]);
  }
}

/// 采样器：把真实回调、时钟、输出都做成可注入的，方便单测。
class FrameTrace {
  FrameTrace({
    required this.onRegister,
    this.onUnregister,
    void Function(String line)? sink,
    DateTime Function()? clock,
    this.flushFrames = defaultFlushFrames,
    this.flushInterval = defaultFlushInterval,
    this.jankThreshold = defaultJankThreshold,
  })  : _sink = sink ?? debugPrint,
        _clock = clock ?? DateTime.now,
        _stats = FrameTraceStats(jankThreshold: jankThreshold);

  /// 环境变量名；值为 '1' 时启用。
  static const String envEnable = 'DBPILOT_FRAME_TRACE';

  /// 每积累多少帧输出一次。
  static const int defaultFlushFrames = 60;

  /// 距上次输出超过多久也输出一次（帧少的时候不至于一直不打印）。
  static const Duration defaultFlushInterval = Duration(seconds: 2);

  /// 60fps 的帧预算，超过即记为 jank。
  static const Duration defaultJankThreshold = Duration(microseconds: 16667);

  /// 生产实例：接到真实的 SchedulerBinding 上，输出走 debugPrint。
  static final FrameTrace instance = FrameTrace(
    onRegister: (TimingsCallback callback) =>
        SchedulerBinding.instance.addTimingsCallback(callback),
    onUnregister: (TimingsCallback callback) =>
        SchedulerBinding.instance.removeTimingsCallback(callback),
  );

  /// 注册帧回调的注入点（生产实例接到 SchedulerBinding；测试里只记录调用）。
  final void Function(TimingsCallback callback) onRegister;

  /// 注销帧回调的注入点，可为空。
  final void Function(TimingsCallback callback)? onUnregister;
  final void Function(String line) _sink;
  final DateTime Function() _clock;
  final FrameTraceStats _stats;
  final int flushFrames;
  final Duration flushInterval;
  final Duration jankThreshold;

  bool _running = false;
  TimingsCallback? _callback;
  DateTime? _windowStart;

  bool get isRunning => _running;

  /// 当前窗口的统计（已输出的窗口会被清零）。
  FrameTraceStats get stats => _stats;

  /// 环境变量是否要求采样。
  static bool get enabledByEnvironment =>
      Platform.environment[envEnable] == '1';

  /// 按环境变量决定是否启动；返回是否在运行。
  bool maybeStart() => start(enabled: enabledByEnvironment);

  /// 启动采样。[enabled] 为 false 时什么也不做（不注册回调）。
  bool start({required bool enabled}) {
    if (!enabled) return false;
    if (_running) return true;
    _running = true;
    _stats.reset();
    _windowStart = _clock();
    final callback = _onTimings;
    _callback = callback;
    onRegister(callback);
    _sink('$frameTraceTag enabled ($envEnable=1): flush every $flushFrames '
        'frames or ${flushInterval.inMilliseconds}ms; '
        'jank > ${formatMillis(jankThreshold)}ms');
    return true;
  }

  /// 停止采样：先输出最后一个窗口，再摘掉回调。
  void stop() {
    if (!_running) return;
    final start = _windowStart;
    _flush(start == null ? Duration.zero : _clock().difference(start));
    final callback = _callback;
    if (callback != null) onUnregister?.call(callback);
    _callback = null;
    _running = false;
  }

  /// 喂入一帧样本；未启动时直接忽略。
  void addSample(FrameSample sample) {
    if (!_running) return;
    _stats.add(sample);
    final start = _windowStart;
    final elapsed = start == null ? Duration.zero : _clock().difference(start);
    if (_stats.count >= flushFrames || elapsed >= flushInterval) {
      _flush(elapsed);
    }
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      addSample(FrameSample.fromFrameTiming(timing));
    }
  }

  void _flush(Duration elapsed) {
    if (_stats.isEmpty) return;
    _sink(_stats.summary().toLine(window: elapsed));
    _stats.reset();
    _windowStart = _clock();
  }
}
