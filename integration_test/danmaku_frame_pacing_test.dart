import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player_app/models/danmaku_style.dart';
import 'package:video_player_app/services/playback_timeline_clock.dart';
import 'package:video_player_app/widgets/danmaku_overlay.dart';

/// Isolated native renderer profile, without video decoding. Run in profile
/// mode on each target device; synthetic refresh-rate tests live in test/.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('native VSync danmaku frame profile', (tester) async {
    final directory = await Directory.systemTemp.createTemp('danmaku_profile_');
    final reports = <Map<String, Object>>[];
    try {
      for (final count in [64, 320, 640]) {
        final file = File('${directory.path}/$count.ass');
        final ass = StringBuffer('''
[Script Info]
PlayResX: 1920
PlayResY: 1080
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
''');
        for (var i = 0; i < count; i++) {
          final y = (i % 27) * 40;
          ass.writeln(
            r'Dialogue: 0,0:00:00.00,0:01:00.00,Medium,,0,0,0,,{\move(1920,'
            '$y,-200,$y)}弹幕 $i',
          );
        }
        await file.writeAsString(ass.toString());
        final key = GlobalKey<_ProfileSceneState>();
        await tester.pumpWidget(
          MaterialApp(
            home: ColoredBox(
              color: Colors.black,
              child: _ProfileScene(key: key, path: file.path),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 2)),
        );
        final timings = <ui.FrameTiming>[];
        void collect(List<ui.FrameTiming> batch) => timings.addAll(batch);
        binding.addTimingsCallback(collect);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 3)),
        );
        final scene = key.currentState!;
        scene.stop();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 700)),
        );
        binding.removeTimingsCallback(collect);
        expect(timings, isNotEmpty);
        expect(scene.maximumClockErrorUs, 0);
        final vsyncs =
            timings
                .map((t) => t.timestampInMicroseconds(ui.FramePhase.vsyncStart))
                .toList()
              ..sort();
        final spanUs = vsyncs.last - vsyncs.first;
        reports.add({
          'platform': Platform.operatingSystem,
          'documentComments': count,
          'displayRefreshRate': scene.refreshRate,
          'frames': timings.length,
          'observedFps': spanUs > 0
              ? (timings.length - 1) * 1000000 / spanUs
              : 0,
          'build': _percentiles(
            timings.map((t) => t.buildDuration.inMicroseconds),
          ),
          'raster': _percentiles(
            timings.map((t) => t.rasterDuration.inMicroseconds),
          ),
          'maxClockErrorUs': scene.maximumClockErrorUs,
          'videoDecoderIncluded': false,
        });
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await directory.delete(recursive: true);
    }
    binding.reportData = {'danmaku': reports};
    debugPrint('DANMAKU_NATIVE_PROFILE ${jsonEncode(reports)}');
  });
}

Map<String, int> _percentiles(Iterable<int> values) {
  final sorted = values.toList()..sort();
  int at(double fraction) => sorted[((sorted.length - 1) * fraction).round()];
  return {'p50Us': at(.5), 'p95Us': at(.95), 'p99Us': at(.99)};
}

class _ProfileScene extends StatefulWidget {
  const _ProfileScene({super.key, required this.path});
  final String path;
  @override
  State<_ProfileScene> createState() => _ProfileSceneState();
}

class _ProfileSceneState extends State<_ProfileScene>
    with SingleTickerProviderStateMixin {
  final position = ValueNotifier(const Duration(seconds: 2));
  final clock = PlaybackTimelineClock();
  late final Ticker ticker;
  int? _firstTimestampUs;
  int maximumClockErrorUs = 0;
  double refreshRate = 0;

  @override
  void initState() {
    super.initState();
    clock.reset(position.value, running: true, rate: 1);
    ticker = createTicker((_) {
      final timestamp = SchedulerBinding.instance.currentFrameTimeStamp;
      _firstTimestampUs ??= timestamp.inMicroseconds;
      final next = clock.sampleFrame(timestamp);
      final expectedUs =
          2000000 + timestamp.inMicroseconds - _firstTimestampUs!;
      final errorUs = (next.inMicroseconds - expectedUs).abs();
      if (errorUs > maximumClockErrorUs) maximumClockErrorUs = errorUs;
      position.value = next;
    })..start();
  }

  void stop() => ticker.stop();

  @override
  Widget build(BuildContext context) {
    refreshRate = View.of(context).display.refreshRate;
    return DanmakuOverlay(
      path: widget.path,
      position: position,
      displayArea: .5,
      opacity: .95,
      fontScale: 1,
      speed: 1,
      fontFamily: null,
      fontWeight: 600,
      outlineType: DanmakuOutlineType.standard,
      playerHeight: MediaQuery.sizeOf(context).height,
    );
  }

  @override
  void dispose() {
    ticker.dispose();
    position.dispose();
    super.dispose();
  }
}
