import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'dart:ui' as ui show Image;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';

// Run in profile/release on a device. This uses real engine frame timings;
// widget-test pump durations are not a measurement of rendering performance.
// --dart-define=LYRIC_PERF_REPORT=/absolute/path/report.json
// --dart-define=LYRIC_PERF_PLATFORM=android exercises the mobile list on desktop.
// --dart-define=LYRIC_PERF_SCENARIO=mixed also exercises actual lyric taps and
// wheel browsing. Platform overrides test widget paths, not native devices.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _Benchmark());
}

class _Benchmark extends StatefulWidget {
  const _Benchmark();
  @override
  State<_Benchmark> createState() => _BenchmarkState();
}

class _BenchmarkState extends State<_Benchmark>
    with SingleTickerProviderStateMixin {
  final clock = ValueNotifier(Duration.zero);
  final frames = <FrameTiming>[];
  final lyricKey = GlobalKey();
  final phaseFrames = <String, List<FrameTiming>>{};
  final phaseImages = <String, int>{};
  static const mixed = String.fromEnvironment('LYRIC_PERF_SCENARIO') == 'mixed';
  late final Ticker ticker;
  late final List<SubtitleItem> cues;
  Duration elapsed = Duration.zero;
  Duration clockOffset = const Duration(seconds: 5);
  int? firstVsync;
  int lastAction = -1;
  int seeks = 0;
  int wheelEvents = 0;
  int pointer = 100;
  bool finished = false;
  void Function(ui.Image)? previousImageOnCreate;

  String _phase(Duration time) {
    if (time < const Duration(seconds: 3)) return 'warmup';
    if (!mixed || time < const Duration(seconds: 11)) return 'auto';
    if (time < const Duration(seconds: 19)) return 'tap';
    return 'browse';
  }

  @override
  void initState() {
    super.initState();
    cues = List.generate(180, (index) {
      const text = 'The light is slowly dancing through the open window';
      var from = 0;
      return SubtitleItem(
        index: index,
        startTime: Duration(milliseconds: index * 1800),
        endTime: Duration(milliseconds: (index + 1) * 1800),
        text: text,
        lyricTranslation: '光影缓缓起舞，穿过敞开的窗。',
        timedSpans: [
          for (final word in text.split(' '))
            SubtitleTimedSpan(
              textStart: from,
              textEnd: (from += word.length),
              startTime: Duration(
                milliseconds: index * 1800 + (from - word.length) * 30,
              ),
              endTime: Duration(milliseconds: index * 1800 + from++ * 30),
            ),
        ],
      );
    });
    previousImageOnCreate = ui.Image.onCreate;
    ui.Image.onCreate = (image) {
      previousImageOnCreate?.call(image);
      phaseImages.update(
        _phase(elapsed),
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    };
    SchedulerBinding.instance.addTimingsCallback(_timings);
    ticker = createTicker((time) {
      elapsed = time;
      firstVsync ??=
          SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
      clock.value = elapsed + clockOffset;
      final phase = _phase(elapsed);
      final action = elapsed.inMilliseconds ~/ (phase == 'tap' ? 1000 : 100);
      if (mixed && action != lastAction && !finished) {
        lastAction = action;
        if (phase == 'tap' || phase == 'browse') {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || finished) return;
            if (phase == 'tap') {
              _tapVisibleLyric();
            } else {
              _browse();
            }
          });
        }
      }
      final duration = Duration(seconds: mixed ? 27 : 18);
      if (elapsed >= duration && !finished) {
        finished = true;
        ticker.stop();
        unawaited(_finish());
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => ticker.start());
  }

  void _timings(List<FrameTiming> values) {
    if (firstVsync == null) return;
    for (final frame in values) {
      final time = Duration(
        microseconds:
            frame.timestampInMicroseconds(FramePhase.vsyncStart) - firstVsync!,
      );
      final phase = _phase(time);
      if (phase == 'warmup') continue;
      frames.add(frame);
      phaseFrames.putIfAbsent(phase, () => []).add(frame);
    }
  }

  void _tapVisibleLyric() {
    final root = lyricKey.currentContext as Element?;
    if (root == null) return;
    final viewport = root.findRenderObject() as RenderBox;
    final rect = viewport.localToGlobal(Offset.zero) & viewport.size;
    Offset? target;
    void visit(Element element) {
      final widget = element.widget;
      if (widget is Semantics && widget.properties.onTap != null) {
        final box = element.findRenderObject();
        if (box is RenderBox && box.hasSize) {
          final point = box.localToGlobal(const Offset(20, 15));
          if (point.dy > rect.top + rect.height * 0.45 &&
              point.dy < rect.bottom - 30 &&
              rect.contains(point)) {
            target = point;
          }
        }
      }
      element.visitChildren(visit);
    }

    root.visitChildren(visit);
    if (target == null) return;
    final id = pointer++;
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(pointer: id, position: target!),
    );
    Timer(const Duration(milliseconds: 40), () {
      if (!mounted || finished) return;
      GestureBinding.instance.handlePointerEvent(
        PointerUpEvent(pointer: id, position: target!),
      );
    });
  }

  void _browse() {
    final box = lyricKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    GestureBinding.instance.handlePointerEvent(
      PointerScrollEvent(
        position: box.localToGlobal(box.size.center(Offset.zero)),
        scrollDelta: const Offset(0, 32),
      ),
    );
    wheelEvents++;
  }

  Future<void> _finish() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    Map<String, Object> summary(List<double> values) {
      values.sort();
      if (values.isEmpty) return {'frames': 0};
      double percentile(double p) => values[((values.length - 1) * p).round()];
      return {
        'meanMs': values.reduce((a, b) => a + b) / values.length,
        'p95Ms': percentile(0.95),
        'p99Ms': percentile(0.99),
        'maxMs': values.last,
        'over16ms': values.where((value) => value > 16.667).length,
        'over8ms': values.where((value) => value > 8.333).length,
      };
    }

    final worstFrames = [...frames]
      ..sort((a, b) => b.rasterDuration.compareTo(a.rasterDuration));
    final report = {
      'hostPlatform': Platform.operatingSystem,
      'platform': Theme.of(lyricKey.currentContext!).platform.name,
      'frames': frames.length,
      'scenario': mixed ? 'mixed' : 'auto',
      'seeks': seeks,
      'wheelEvents': wheelEvents,
      'createdImages': phaseImages,
      'slowestFrames': [
        for (final frame in worstFrames.take(8))
          {
            'elapsedMs':
                (frame.timestampInMicroseconds(FramePhase.vsyncStart) -
                    firstVsync!) /
                1000,
            'uiMs': frame.buildDuration.inMicroseconds / 1000,
            'rasterMs': frame.rasterDuration.inMicroseconds / 1000,
          },
      ],
      'devicePixelRatio': View.of(lyricKey.currentContext!).devicePixelRatio,
      'logicalSize': {
        'width':
            View.of(lyricKey.currentContext!).physicalSize.width /
            View.of(lyricKey.currentContext!).devicePixelRatio,
        'height':
            View.of(lyricKey.currentContext!).physicalSize.height /
            View.of(lyricKey.currentContext!).devicePixelRatio,
      },
      'phases': {
        for (final entry in phaseFrames.entries)
          entry.key: {
            'frames': entry.value.length,
            'ui': summary([
              for (final frame in entry.value)
                frame.buildDuration.inMicroseconds / 1000,
            ]),
            'raster': summary([
              for (final frame in entry.value)
                frame.rasterDuration.inMicroseconds / 1000,
            ]),
          },
      },
      'ui': summary(
        frames
            .map((frame) => frame.buildDuration.inMicroseconds / 1000)
            .toList(),
      ),
      'raster': summary(
        frames
            .map((frame) => frame.rasterDuration.inMicroseconds / 1000)
            .toList(),
      ),
    };
    const path = String.fromEnvironment('LYRIC_PERF_REPORT');
    if (path.isNotEmpty) {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
      );
    }
    debugPrint('LYRIC_PERF ${jsonEncode(report)}');
    exit(0);
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    ui.Image.onCreate = previousImageOnCreate;
    ticker.dispose();
    clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData(
      platform: switch (const String.fromEnvironment('LYRIC_PERF_PLATFORM')) {
        'android' => TargetPlatform.android,
        'ios' => TargetPlatform.iOS,
        'macos' => TargetPlatform.macOS,
        'linux' => TargetPlatform.linux,
        _ => null,
      },
    ),
    home: Scaffold(
      backgroundColor: const Color(0xff443344),
      body: Center(
        child: SizedBox(
          width: 560,
          child: MusicLyricView(
            key: lyricKey,
            subtitles: cues,
            positionListenable: clock,
            onSeek: (target) {
              seeks++;
              clockOffset = target - elapsed;
              clock.value = target;
            },
          ),
        ),
      ),
    ),
  );
}
