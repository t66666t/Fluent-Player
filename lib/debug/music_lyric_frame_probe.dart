import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' show TickerModeData;

import 'build_identity.dart';

enum MusicLyricFramePhase { idle, autoFollow, tap, drag }

typedef _LyricFrameSample = ({
  int atUs,
  int ui,
  int raster,
  int vsync,
  int total,
  int? interval,
  double budget,
  String phase,
  bool append,
  bool slow,
});

/// Bounded frame samples; the budget is the display rate when each frame
/// arrived, rather than assuming that every Android device runs at 60 Hz.
class MusicLyricFrameSamples {
  MusicLyricFrameSamples({this.capacity = 600}) : assert(capacity > 0);

  final int capacity;
  final _samples = <_LyricFrameSample>[];
  int _next = 0;
  int? _previousVsync;
  double? _previousBudget;
  bool _previousMotion = false;
  int _slowStreak = 0;
  int _windowLongestSlowStreak = 0;
  int sessionFrames = 0;
  int sessionOverBudget = 0;
  int sessionWorstUiUs = 0;
  int sessionWorstRasterUs = 0;
  int sessionWorstVsyncUs = 0;
  int sessionLongestSlowStreak = 0;
  int sessionEstimatedMissedMotionFrames = 0;

  bool get isEmpty => _samples.isEmpty;

  void add(
    ui.FrameTiming frame, {
    required double refreshRate,
    String phase = 'idle',
    bool motion = false,
    bool append = false,
  }) {
    final budget = 1000000 / (refreshRate > 0 ? refreshRate : 60);
    final vsyncStart = frame.timestampInMicroseconds(ui.FramePhase.vsyncStart);
    final interval =
        motion &&
            _previousMotion &&
            _previousVsync != null &&
            _previousBudget == budget &&
            vsyncStart > _previousVsync!
        ? vsyncStart - _previousVsync!
        : null;
    _previousVsync = vsyncStart;
    _previousBudget = budget;
    _previousMotion = motion;
    final uiUs = frame.buildDuration.inMicroseconds;
    final rasterUs = frame.rasterDuration.inMicroseconds;
    final vsyncUs = frame.vsyncOverhead.inMicroseconds;
    final gap = interval != null && interval > budget * 1.5;
    final slow = uiUs > budget || rasterUs > budget || vsyncUs > budget || gap;
    _slowStreak = slow ? _slowStreak + 1 : 0;
    if (_slowStreak > _windowLongestSlowStreak) {
      _windowLongestSlowStreak = _slowStreak;
    }
    if (_slowStreak > sessionLongestSlowStreak) {
      sessionLongestSlowStreak = _slowStreak;
    }
    if (gap) {
      sessionEstimatedMissedMotionFrames += (interval / budget).round() - 1;
    }
    final _LyricFrameSample sample = (
      atUs: vsyncStart,
      ui: uiUs,
      raster: rasterUs,
      vsync: vsyncUs,
      total: frame.totalSpan.inMicroseconds,
      interval: interval,
      budget: budget,
      phase: phase,
      append: append,
      slow: slow,
    );
    sessionFrames++;
    if (sample.ui > budget || sample.raster > budget) sessionOverBudget++;
    if (sample.ui > sessionWorstUiUs) sessionWorstUiUs = sample.ui;
    if (sample.raster > sessionWorstRasterUs) {
      sessionWorstRasterUs = sample.raster;
    }
    if (sample.vsync > sessionWorstVsyncUs) sessionWorstVsyncUs = sample.vsync;
    if (_samples.length < capacity) {
      _samples.add(sample);
    } else {
      _samples[_next] = sample;
      _next = (_next + 1) % capacity;
    }
  }

  Map<String, Object> snapshot() {
    double percentile(Iterable<int> input, double p) {
      final values = input.toList()..sort();
      if (values.isEmpty) return 0;
      return values[((values.length - 1) * p).round()] / 1000;
    }

    Map<String, Object> costs(List<_LyricFrameSample> frames) => {
      'frames': frames.length,
      'uiP95Ms': percentile(frames.map((s) => s.ui), 0.95),
      'uiP99Ms': percentile(frames.map((s) => s.ui), 0.99),
      'rasterP95Ms': percentile(frames.map((s) => s.raster), 0.95),
      'rasterP99Ms': percentile(frames.map((s) => s.raster), 0.99),
      'vsyncOverheadP95Ms': percentile(frames.map((s) => s.vsync), 0.95),
      'vsyncOverheadP99Ms': percentile(frames.map((s) => s.vsync), 0.99),
      'uiMaxMs': percentile(frames.map((s) => s.ui), 1),
      'rasterMaxMs': percentile(frames.map((s) => s.raster), 1),
      'vsyncOverheadMaxMs': percentile(frames.map((s) => s.vsync), 1),
      'slowFrames': frames.where((s) => s.slow).length,
    };
    final intervals = _samples.map((s) => s.interval).whereType<int>();

    return {
      'sampledFrames': _samples.length,
      ...costs(_samples),
      'totalP95Ms': percentile(_samples.map((sample) => sample.total), 0.95),
      'totalP99Ms': percentile(_samples.map((sample) => sample.total), 0.99),
      'motionIntervalP95Ms': percentile(intervals, 0.95),
      'motionIntervalP99Ms': percentile(intervals, 0.99),
      'motionIntervalMaxMs': percentile(intervals, 1),
      'motionGapFrames': _samples
          .where((s) => s.interval != null && s.interval! > s.budget * 1.5)
          .length,
      'lateStartFrames': _samples.where((s) => s.vsync > s.budget).length,
      'longestSlowStreak': _windowLongestSlowStreak,
      'overBudgetFrames': _samples
          .where(
            (sample) =>
                sample.ui > sample.budget || sample.raster > sample.budget,
          )
          .length,
      'latencyOverBudgetFrames': _samples
          .where((sample) => sample.total > sample.budget)
          .length,
      'sessionFrames': sessionFrames,
      'sessionOverBudgetFrames': sessionOverBudget,
      'sessionWorstUiMs': sessionWorstUiUs / 1000,
      'sessionWorstRasterMs': sessionWorstRasterUs / 1000,
      'sessionWorstVsyncOverheadMs': sessionWorstVsyncUs / 1000,
      'sessionLongestSlowStreak': sessionLongestSlowStreak,
      'sessionEstimatedMissedMotionFrames': sessionEstimatedMissedMotionFrames,
      'phases': {
        for (final phase in _samples.map((s) => s.phase).toSet())
          phase: costs(_samples.where((s) => s.phase == phase).toList()),
        if (_samples.any((s) => s.append))
          'append': costs(_samples.where((s) => s.append).toList()),
      },
    };
  }

  /// Bounded raw engine timings for opt-in physical-device A/B measurements.
  /// Layout: VSync timestamp, UI, raster, scheduling, total, budget (all us),
  /// activity, motion interval. A wrapped ring need not be chronological.
  List<List<Object?>> exportSamples() => [
    for (final sample in _samples)
      [
        sample.atUs,
        sample.ui,
        sample.raster,
        sample.vsync,
        sample.total,
        sample.budget,
        sample.phase,
        sample.interval,
      ],
  ];

  void clearWindow() {
    _samples.clear();
    _next = 0;
    _windowLongestSlowStreak = 0;
  }

  void breakMotionSequence() {
    _previousMotion = false;
    _slowStreak = 0;
  }
}

typedef _LyricFrameContext = ({
  int atUs,
  MusicLyricFramePhase phase,
  int appendUntilUs,
  bool visible,
  int epoch,
});

/// Android's engine log sink can truncate an individual message at 1024
/// bytes. Keep every diagnostic record recoverable on a physical device.
@visibleForTesting
List<String> musicLyricFrameReportLines(
  Map<String, Object> report, {
  required String id,
}) {
  final payload = jsonEncode(report);
  const partLength = 700;
  if (utf8.encode(payload).length <= partLength) {
    return ['[lyric-perf] $payload'];
  }
  // ASCII escaping makes the bound a byte bound, including non-ASCII build
  // labels. Frame reports contain diagnostics only, never lyric/media text.
  final ascii = StringBuffer();
  for (final unit in payload.codeUnits) {
    ascii.write(
      unit < 128
          ? String.fromCharCode(unit)
          : '\\u${unit.toRadixString(16).padLeft(4, '0')}',
    );
  }
  final encoded = ascii.toString();
  final count = (encoded.length / partLength).ceil();
  return [
    for (var i = 0; i < count; i++)
      '[lyric-perf-part] $id ${i + 1}/$count '
          '${encoded.substring(i * partLength, (i + 1) * partLength < encoded.length ? (i + 1) * partLength : encoded.length)}',
  ];
}

/// Opt-in local diagnostics for a real playback workload. Normal builds do
/// not register a frame callback. No lyrics or media paths are recorded.
class MusicLyricFrameProbe {
  MusicLyricFrameProbe({int Function()? timestampUs})
    : _timestampUs = timestampUs ?? _systemTimestampUs;

  static int _systemTimestampUs() =>
      SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
  final int Function() _timestampUs;
  static const enabled = bool.fromEnvironment('MUSIC_LYRIC_FRAME_TIMINGS');

  // A five-second window must also fit 144/240 Hz displays without silently
  // dropping its earliest samples. Normal builds never instantiate the probe.
  final samples = MusicLyricFrameSamples(capacity: 1200);
  static const _reportFile = String.fromEnvironment('MUSIC_LYRIC_FRAME_REPORT');
  Future<void> _reportWrites = Future<void>.value();
  final _clock = Stopwatch()..start();
  ui.FlutterView? _view;
  ValueListenable<TickerModeData>? _tickerMode;
  int _lastReportMs = 0;
  int _reportSequence = 0;
  int _startedUs = 0;
  bool _attached = false;
  final _contexts = <_LyricFrameContext>[];
  MusicLyricFramePhase _phase = MusicLyricFramePhase.idle;
  int _appendUntilUs = 0;
  int mountedRows = 0;
  int activeRows = 0;
  bool _visible = true;
  int _motionEpoch = 0;
  int? _lastSampleEpoch;

  void _onTickerModeChanged() {
    final visible = _tickerMode?.value.enabled ?? false;
    if (_visible == visible) return;
    _visible = visible;
    _motionEpoch++;
    _recordContext();
  }

  void markPhase(MusicLyricFramePhase phase) {
    if (phase == _phase) return;
    _phase = phase;
    // There need not be an engine frame during an idle pause. A new activity
    // must not turn that intentional pause into an estimated missed frame.
    _motionEpoch++;
    _recordContext();
  }

  void markAppend() {
    _appendUntilUs = _timestampUs() + 100000;
    _recordContext();
  }

  void _recordContext() {
    _contexts.add((
      atUs: _timestampUs(),
      phase: _phase,
      appendUntilUs: _appendUntilUs,
      visible: _visible,
      epoch: _motionEpoch,
    ));
    // Release timings arrive in batches. Keep event timestamps so an old frame
    // is attributed to its actual activity, not the activity at report time.
    if (_contexts.length > 512) _contexts.removeAt(0);
  }

  void attach(ui.FlutterView view, ValueListenable<TickerModeData> tickerMode) {
    _view = view;
    if (_tickerMode != tickerMode) {
      _tickerMode?.removeListener(_onTickerModeChanged);
      _tickerMode = tickerMode;
      tickerMode.addListener(_onTickerModeChanged);
      _onTickerModeChanged();
    }
    if (_attached) return;
    _attached = true;
    _startedUs = _timestampUs();
    _recordContext();
    SchedulerBinding.instance.addTimingsCallback(_onFrames);
  }

  void _onFrames(List<ui.FrameTiming> frames) {
    if (!_attached || _view == null) return;
    final refreshRate = _view!.display.refreshRate;
    for (final frame in frames) {
      if (frame.timestampInMicroseconds(ui.FramePhase.vsyncStart) <
          _startedUs) {
        continue;
      }
      final atUs = frame.timestampInMicroseconds(ui.FramePhase.vsyncStart);
      final context = _contexts.lastWhere(
        (context) => context.atUs <= atUs,
        orElse: () => (
          atUs: 0,
          phase: MusicLyricFramePhase.idle,
          appendUntilUs: 0,
          visible: false,
          epoch: -1,
        ),
      );
      if (!context.visible) {
        samples.breakMotionSequence();
        continue;
      }
      if (_lastSampleEpoch != context.epoch) samples.breakMotionSequence();
      _lastSampleEpoch = context.epoch;
      samples.add(
        frame,
        refreshRate: refreshRate,
        phase: context.phase.name,
        motion: context.phase != MusicLyricFramePhase.idle,
        append: atUs < context.appendUntilUs,
      );
    }
    if (_clock.elapsedMilliseconds - _lastReportMs >= 5000) _report('window');
  }

  void _report(String reason) {
    if (samples.isEmpty || _view == null) return;
    final view = _view!;
    final report = {
      'build': BuildIdentity.id,
      'platform': defaultTargetPlatform.name,
      'mode': kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug',
      'reason': reason,
      'displayHz': view.display.refreshRate,
      'dpr': view.devicePixelRatio,
      'physicalWidth': view.physicalSize.width,
      'physicalHeight': view.physicalSize.height,
      'mountedRows': mountedRows,
      'activeRows': activeRows,
      ...samples.snapshot(),
    };
    for (final line in musicLyricFrameReportLines(
      report,
      id: '${identityHashCode(this)}:${_reportSequence++}',
    )) {
      debugPrint(line);
    }
    if (_reportFile.isNotEmpty) {
      final payload = jsonEncode({
        ...report,
        'reportedAtEpochUs': DateTime.now().microsecondsSinceEpoch,
        'capturedAtVsyncUs': _timestampUs(),
        'rawFrames': samples.exportSamples(),
      });
      _reportWrites = _reportWrites
          .then((_) async {
            final file = File(_reportFile);
            await file.parent.create(recursive: true);
            await file.writeAsString('$payload\n', mode: FileMode.append);
          })
          .catchError((Object error) {
            debugPrint(
              '[lyric-perf] report write failed: ${error.runtimeType}',
            );
          });
    }
    samples.clearWindow();
    _lastReportMs = _clock.elapsedMilliseconds;
  }

  void dispose() {
    if (_attached) SchedulerBinding.instance.removeTimingsCallback(_onFrames);
    _tickerMode?.removeListener(_onTickerModeChanged);
    _attached = false;
    _report('exit');
    _clock.stop();
    _view = null;
    _tickerMode = null;
  }
}
