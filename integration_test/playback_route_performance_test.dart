import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/platform/app_video_player_controller.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/theme/playback_page_route.dart';
import 'support/legacy_zoom_page_route.dart';

typedef _Visit = ({
  String transition,
  bool portrait,
  bool cold,
  String direction,
  int fromUs,
  int toUs,
});

/// Profile on a native device, with a real decoder/texture and real VSync.
/// Set PLAYBACK_PROFILE_VIDEO to a device-local video. Desktop runs can create
/// their own silent fixture with ffmpeg. Reports deliberately retain both cold
/// and warm visits; widget tests separately simulate 60/90/120/144 Hz clocks.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('native playback entry and exit frame comparison', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    NativeVideoPlayerMediaKit.ensureInitialized();
    final directory = await Directory.systemTemp.createTemp('playback_routes_');
    final fixture = const String.fromEnvironment('PLAYBACK_PROFILE_VIDEO');
    final path = fixture.isNotEmpty ? fixture : '${directory.path}/silent.mp4';
    if (fixture.isEmpty) {
      final bundled = File('assets/binaries/windows/ffmpeg.exe');
      final result = await Process.run(
        Platform.isWindows && await bundled.exists()
            ? bundled.absolute.path
            : 'ffmpeg',
        [
          '-hide_banner',
          '-loglevel',
          'error',
          '-y',
          '-f',
          'lavfi',
          '-i',
          'testsrc2=size=1280x720:rate=30',
          '-t',
          '30',
          '-c:v',
          'libx264',
          '-preset',
          'ultrafast',
          '-pix_fmt',
          'yuv420p',
          path,
        ],
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }
    final timings = <ui.FrameTiming>[];
    final visits = <_Visit>[];
    void collect(List<ui.FrameTiming> batch) => timings.addAll(batch);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: ThemeData.dark().copyWith(
          pageTransitionsTheme: appPageTransitionsTheme,
        ),
        home: Scaffold(
          body: GridView.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              mainAxisExtent: 170,
            ),
            itemCount: 2000,
            itemBuilder: (_, i) => Card(
              child: Column(
                children: [
                  Expanded(
                    child: ColoredBox(
                      color: Colors.primaries[i % Colors.primaries.length],
                      child: const Center(
                        child: Icon(Icons.play_circle, size: 48),
                      ),
                    ),
                  ),
                  Text('Media library item $i'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    binding.addTimingsCallback(collect);
    try {
      for (final portrait in [false, true]) {
        for (final cold in [false, true]) {
          for (var round = 0; round < 2; round++) {
            for (final improved
                in round.isEven ? [false, true] : [true, false]) {
              final controller = AppVideoPlayerController.file(File(path));
              final ready = Completer<void>();
              Future<void> prepare() async {
                try {
                  await controller.initialize();
                  await controller.setVolume(0);
                  await controller.setLooping(true);
                  await controller.play();
                  ready.complete();
                } catch (error, stack) {
                  ready.completeError(error, stack);
                }
              }

              if (!cold) await prepare();
              Widget page(BuildContext context) => _NativePlayerScene(
                controller: controller,
                portrait: portrait,
                prepare: cold ? prepare : null,
              );
              final route = improved
                  ? PlaybackPageRoute<void>(builder: page)
                  : LegacyZoomPageRoute<void>(
                      builder: page,
                      allowSnapshotting: false,
                      delayPushOneFrame: false,
                    );
              final fromUs = await _navigateOnFrame(
                binding,
                () => navigator.currentState!.push(route),
              );
              await _waitForEntry(route);
              visits.add((
                transition: improved ? 'playback' : 'previousZoom',
                portrait: portrait,
                cold: cold,
                direction: 'enter',
                fromUs: fromUs,
                toUs: binding.currentSystemFrameTimeStamp.inMicroseconds,
              ));
              await ready.future.timeout(const Duration(seconds: 20));
              await Future<void>.delayed(const Duration(milliseconds: 150));
              expect(controller.value.hasError, isFalse);
              expect(controller.value.isInitialized, isTrue);
              final exitUs = await _navigateOnFrame(
                binding,
                () => navigator.currentState!.pop(),
              );
              await route.completed;
              visits.add((
                transition: improved ? 'playback' : 'previousZoom',
                portrait: portrait,
                cold: cold,
                direction: 'exit',
                fromUs: exitUs,
                toUs: binding.currentSystemFrameTimeStamp.inMicroseconds,
              ));
              expect(controller.value.hasError, isFalse);
              await controller.dispose();
              await Future<void>.delayed(const Duration(milliseconds: 120));
            }
          }
        }
      }
      // Release/profile frame timings are delivered in batches after paint.
      await Future<void>.delayed(const Duration(milliseconds: 800));
    } finally {
      binding.removeTimingsCallback(collect);
      await tester.pumpWidget(const SizedBox.shrink());
      await directory.delete(recursive: true);
    }
    final displayHz = tester.view.display.refreshRate;
    final budgetUs = 1000000 / (displayHz > 0 ? displayHz : 60);
    final reports = <Map<String, Object>>[];
    for (final visit in visits) {
      final frames = timings.where((frame) {
        final timestamp = frame.timestampInMicroseconds(
          ui.FramePhase.vsyncStart,
        );
        return timestamp >= visit.fromUs && timestamp <= visit.toUs;
      }).toList();
      expect(frames, isNotEmpty, reason: '$visit');
      final vsyncs =
          frames
              .map((t) => t.timestampInMicroseconds(ui.FramePhase.vsyncStart))
              .toList()
            ..sort();
      var missedVsyncs = 0;
      for (var i = 1; i < vsyncs.length; i++) {
        final periods = (vsyncs[i] - vsyncs[i - 1]) / budgetUs;
        if (periods > 1.5) missedVsyncs += periods.round() - 1;
      }
      reports.add({
        'transition': visit.transition,
        'portrait': visit.portrait,
        'cold': visit.cold,
        'direction': visit.direction,
        'frames': frames.length,
        'durationUs': visit.toUs - visit.fromUs,
        'missedVsyncs': missedVsyncs,
        'build': _summarize(frames.map((t) => t.buildDuration.inMicroseconds)),
        'raster': _summarize(
          frames.map((t) => t.rasterDuration.inMicroseconds),
        ),
        'vsyncOverhead': _summarize(
          frames.map((t) => t.vsyncOverhead.inMicroseconds),
        ),
        'overBudgetFrames': frames
            .where(
              (t) =>
                  t.buildDuration.inMicroseconds > budgetUs ||
                  t.rasterDuration.inMicroseconds > budgetUs,
            )
            .length,
      });
    }
    binding.reportData = {
      'platform': Platform.operatingSystem,
      'displayHz': displayHz,
      'nativeVideoIncluded': true,
      'visits': reports,
    };
    debugPrint('PLAYBACK_ROUTE_PROFILE ${jsonEncode(binding.reportData)}');
    expect(tester.takeException(), isNull);
  });
}

Future<void> _waitForEntry(PageRoute<void> route) async {
  // Hero measurement temporarily exposes an always-complete route animation
  // while the entering page is offstage. Measure its real animation only after
  // that first layout, otherwise the entry is incorrectly reported as 0 ms.
  await WidgetsBinding.instance.endOfFrame;
  if (route.animation!.isCompleted) return;
  final done = Completer<void>();
  void onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && !done.isCompleted) {
      done.complete();
    }
  }

  route.animation!.addStatusListener(onStatus);
  try {
    await done.future.timeout(const Duration(seconds: 20));
  } finally {
    route.animation!.removeStatusListener(onStatus);
  }
}

Future<int> _navigateOnFrame(WidgetsBinding binding, VoidCallback navigate) {
  final done = Completer<int>();
  binding.scheduleFrameCallback((_) {
    final timestamp = binding.currentSystemFrameTimeStamp.inMicroseconds;
    navigate();
    done.complete(timestamp);
  });
  return done.future;
}

Map<String, int> _summarize(Iterable<int> samples) {
  final values = samples.toList()..sort();
  int at(double fraction) => values[((values.length - 1) * fraction).round()];
  return {'p50Us': at(.5), 'p95Us': at(.95), 'maxUs': values.last};
}

class _NativePlayerScene extends StatefulWidget {
  const _NativePlayerScene({
    required this.controller,
    required this.portrait,
    this.prepare,
  });

  final VideoPlayerController controller;
  final bool portrait;
  final Future<void> Function()? prepare;

  @override
  State<_NativePlayerScene> createState() => _NativePlayerSceneState();
}

class _NativePlayerSceneState extends State<_NativePlayerScene> {
  @override
  void initState() {
    super.initState();
    if (widget.prepare != null) unawaited(widget.prepare!());
  }

  @override
  Widget build(BuildContext context) {
    final video = Expanded(
      flex: 2,
      child: RepaintBoundary(
        child: Center(
          child: ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: widget.controller,
            builder: (_, value, child) => AspectRatio(
              aspectRatio: value.isInitialized ? value.aspectRatio : 16 / 9,
              child: child,
            ),
            child: VideoPlayer(widget.controller),
          ),
        ),
      ),
    );
    final subtitles = Expanded(
      child: RepaintBoundary(
        child: ListView.builder(
          itemCount: 3000,
          itemExtent: 64,
          itemBuilder: (_, i) => ListTile(title: Text('Subtitle line $i')),
        ),
      ),
    );
    return Scaffold(
      backgroundColor: Colors.black,
      body: widget.portrait
          ? Center(
              child: SizedBox(
                width: 440,
                child: Column(children: [video, subtitles]),
              ),
            )
          : Row(children: [video, subtitles]),
    );
  }
}
