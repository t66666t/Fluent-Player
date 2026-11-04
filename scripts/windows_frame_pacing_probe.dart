// Independent native probe. Does not initialize or modify the media library.
// flutter run -d windows --profile --no-resident
// -t scripts/windows_frame_pacing_probe.dart
// --dart-define=FRAME_REPORT=<absolute JSON path>
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:window_manager/window_manager.dart';

const reportPath = String.fromEnvironment('FRAME_REPORT');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows || reportPath.isEmpty) exit(2);
  await windowManager.ensureInitialized();
  runApp(const MaterialApp(home: _Probe()));
  await windowManager.maximize();
}

class _Probe extends StatefulWidget {
  const _Probe();
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with SingleTickerProviderStateMixin {
  late final AnimationController animation;
  final List<int> intervals = [];
  final List<FrameTiming> timings = [];
  int? lastTimestamp;
  late final Timer finish;

  @override
  void initState() {
    super.initState();
    animation =
        AnimationController(vsync: this, duration: const Duration(seconds: 2))
          ..addListener(_frame)
          ..repeat(reverse: true);
    SchedulerBinding.instance.addTimingsCallback(_timings);
    finish = Timer(const Duration(seconds: 14), _finish);
  }

  void _frame() {
    final timestamp =
        SchedulerBinding.instance.currentFrameTimeStamp.inMicroseconds;
    final previous = lastTimestamp;
    if (previous != null && timestamp > previous) {
      intervals.add(timestamp - previous);
    }
    lastTimestamp = timestamp;
  }

  void _timings(List<FrameTiming> frames) => timings.addAll(frames);

  Map<String, Object> summary(Iterable<int> samples) {
    final values = samples.toList()..sort();
    if (values.isEmpty) return {'count': 0};
    double percentile(double p) =>
        values[((values.length - 1) * p).round()] / 1000;
    return {
      'count': values.length,
      'p50Ms': percentile(.5),
      'p95Ms': percentile(.95),
      'p99Ms': percentile(.99),
      'over8_33ms': values.where((v) => v > 8334).length,
      'over16_67ms': values.where((v) => v > 16668).length,
    };
  }

  void _finish() {
    final view = View.of(context);
    // Exclude initialization/warmup. These are callback intervals, not measured
    // scanout FPS; raster durations also do not measure DWM presentation.
    final stableIntervals = intervals.skip(120).toList();
    final stableTimings = timings.skip(120).toList();
    File(reportPath).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'displayId': view.display.id,
        'reportedHz': view.display.refreshRate,
        'physicalWidth': view.physicalSize.width,
        'physicalHeight': view.physicalSize.height,
        'devicePixelRatio': view.devicePixelRatio,
        'frameCallbackIntervals': summary(stableIntervals),
        'callbackHz': stableIntervals.isEmpty
            ? null
            : 1000000 *
                  stableIntervals.length /
                  stableIntervals.reduce((a, b) => a + b),
        'build': summary(
          stableTimings.map((t) => t.buildDuration.inMicroseconds),
        ),
        'raster': summary(
          stableTimings.map((t) => t.rasterDuration.inMicroseconds),
        ),
      }),
      flush: true,
    );
    exit(0);
  }

  @override
  void dispose() {
    finish.cancel();
    animation.dispose();
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xff151515),
    body: Center(
      child: AnimatedBuilder(
        animation: animation,
        builder: (_, child) => Transform.translate(
          offset: Offset(animation.value * 400 - 200, 0),
          child: child,
        ),
        child: const RepaintBoundary(
          child: SizedBox(
            width: 80,
            height: 80,
            child: ColoredBox(color: Colors.blue),
          ),
        ),
      ),
    ),
  );
}
