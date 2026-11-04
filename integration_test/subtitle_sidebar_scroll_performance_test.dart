import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:video_player_app/utils/ui_interaction_budget.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';
import 'package:video_player_app/widgets/ui_refresh_rate_scope.dart';

// Deliberately separate from the UI isolate, as native model inference is.
// Every created isolate is killed by this test; no external process is touched.
void _cpuLoad(SendPort ready) async {
  ready.send(true);
  var value = 17;
  var batch = 0;
  while (true) {
    for (var i = 0; i < 800000; i++) {
      value = ((value * 1664525) + i + 1013904223) & 0x7fffffff;
    }
    if (++batch % 20 == 0) ready.send(value);
    await Future<void>.delayed(Duration.zero);
  }
}

class _CpuWorkers {
  static const executable = String.fromEnvironment(
    'SUBTITLE_STRESS_EXECUTABLE',
  );
  final _isolates = <Isolate>[];
  final _processes = <Process>[];
  final _ready = ReceivePort();
  final _drains = <Future<void>>[];

  Future<void> start(int count) async {
    if (executable.isNotEmpty) {
      for (var i = 0; i < count; i++) {
        final process = await Process.start(executable, const []);
        _processes.add(process);
        _drains.add(process.stderr.drain<void>());
        final ready = await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 10));
        if (ready != 'ready') throw StateError('CPU stress worker not ready');
      }
    } else {
      // Too many continuously runnable isolates can starve the VM's shared
      // worker pool, including the test driver itself. Use separate processes
      // for heavier CPU pressure, without that unrelated scheduling limit.
      if (count > 4) {
        throw ArgumentError('Set SUBTITLE_STRESS_EXECUTABLE for >4 workers');
      }
      for (var i = 0; i < count; i++) {
        _isolates.add(await Isolate.spawn(_cpuLoad, _ready.sendPort));
      }
      await _ready.where((value) => value == true).take(count).toList();
    }
  }

  Future<void> close() async {
    for (final worker in _isolates) {
      worker.kill(priority: Isolate.immediate);
    }
    for (final process in _processes) {
      process.kill();
    }
    _ready.close();
    await Future.wait(_processes.map((process) => process.exitCode));
    await Future.wait(_drains);
  }
}

List<SubtitleItem> _cues(int start, int count) => List.generate(
  count,
  (i) => SubtitleItem(
    index: start + i,
    startTime: Duration(seconds: (start + i) * 3),
    endTime: Duration(seconds: (start + i) * 3 + 2),
    text: '第 ${start + i} 句：阅读文稿、连续定位，并在后台持续生成字幕。 A flowing transcript.',
  ),
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  const count = int.fromEnvironment(
    'SUBTITLE_PROFILE_CUES',
    defaultValue: 12000,
  );
  const stress = int.fromEnvironment(
    'SUBTITLE_STRESS_WORKERS',
    defaultValue: 4,
  );
  final reports = <Map<String, Object>>[];
  setUpAll(() async {
    await (FontLoader(
      'MiSans',
    )..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf'))).load();
  });
  for (final workersCount in {0, stress}) {
    testWidgets(
      'native ordinary-list reference with $workersCount CPU workers',
      (tester) async {
        final controller = ScrollController();
        final workers = _CpuWorkers();
        final timings = <ui.FrameTiming>[];
        void collect(List<ui.FrameTiming> batch) => timings.addAll(batch);
        var running = true;
        Future<void> move() async {
          while (running) {
            await controller.animateTo(
              200,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeInOut,
            );
            if (!running) break;
            await controller.animateTo(
              0,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeInOut,
            );
          }
        }

        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => UiRefreshRateScope(child: child!),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 430,
                  height: 720,
                  child: ListView.builder(
                    controller: controller,
                    itemExtent: 42,
                    itemCount: 12000,
                    itemBuilder: (context, index) =>
                        Text('Reference reading line $index'),
                  ),
                ),
              ),
            ),
          ),
        );
        Future<void>? motion;
        try {
          await workers.start(workersCount);
          binding.addTimingsCallback(collect);
          final start = developer.Timeline.now;
          motion = move();
          await Future<void>.delayed(const Duration(seconds: 3));
          final end = developer.Timeline.now;
          running = false;
          controller.jumpTo(controller.position.pixels);
          await motion;
          await Future<void>.delayed(const Duration(seconds: 1));
          final frames = timings.where((frame) {
            final at = frame.timestampInMicroseconds(ui.FramePhase.buildStart);
            return at >= start && at < end;
          }).toList();
          final hz =
              ui.PlatformDispatcher.instance.views.first.display.refreshRate;
          final intervals = [
            for (var i = 1; i < frames.length; i++)
              frames[i].timestampInMicroseconds(ui.FramePhase.vsyncStart) -
                  frames[i - 1].timestampInMicroseconds(
                    ui.FramePhase.vsyncStart,
                  ),
          ]..sort();
          final report = <String, Object>{
            'mode': 'ordinaryListReference',
            'workers': workersCount,
            'loadSource': _CpuWorkers.executable.isEmpty
                ? 'isolates'
                : 'processes',
            'frames': frames.length,
            'displayHz': hz,
            'intervalP95Ms': intervals[(intervals.length * .95).floor()] / 1000,
          };
          reports.add(report);
          binding.reportData = {'subtitleReading': reports};
          // ignore: avoid_print
          print('SUBTITLE_SCROLL_REFERENCE ${jsonEncode(report)}');
        } finally {
          running = false;
          binding.removeTimingsCallback(collect);
          await workers.close();
          await tester.pumpWidget(const SizedBox.shrink());
          await motion;
          controller.dispose();
        }
      },
    );
  }
  for (final mode in ['list', 'paragraph', 'continuous']) {
    testWidgets(
      '$mode native scrolling with $count cues, appends and CPU load',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'autoScrollSubtitles': true,
          'subtitleViewMode': mode == 'list' ? 0 : 1,
          'subtitleArticleParagraphModeEnabled': mode == 'paragraph',
          'subtitleArticleSentencesPerParagraph': 4,
        });
        final settings = SettingsService()..resetForTest();
        await settings.init();
        final primary = SubtitleCueBuffer()..addAll(_cues(0, count));
        final secondary = SubtitleCueBuffer()
          ..addAll(
            _cues(0, count).map(
              (cue) => cue.copyWith(
                text: 'Translation ${cue.index}: keep reading smoothly.',
              ),
            ),
          );
        final controller = VideoPlayerController.networkUrl(
          Uri.parse('https://example.invalid/subtitle-profile.mp4'),
        );
        final midpoint = count ~/ 2;
        controller.value = VideoPlayerValue(
          duration: Duration(seconds: count * 3 + 300),
          position: Duration(seconds: midpoint * 3),
          isInitialized: true,
        );
        final sidebar = GlobalKey<SubtitleSidebarState>();
        late StateSetter update;
        var subtitles = primary.snapshot;
        var translations = secondary.snapshot;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => UiRefreshRateScope(child: child!),
            theme: ThemeData(fontFamily: 'MiSans'),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 430,
                  height: 720,
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      update = setState;
                      return SubtitleSidebar(
                        key: sidebar,
                        subtitles: subtitles,
                        controller: controller,
                        secondarySubtitles: translations,
                        isPortrait: true,
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 8));
        sidebar.currentState!.locateToCurrentSubtitle(ignorePointer: true);
        await tester.pumpAndSettle(const Duration(milliseconds: 8));
        final workers = _CpuWorkers();
        final frames = <ui.FrameTiming>[];
        void collect(List<ui.FrameTiming> batch) => frames.addAll(batch);
        try {
          await workers.start(math.max(0, stress));
          await tester.pump(const Duration(milliseconds: 300));
          binding.addTimingsCallback(collect);
          final refresh =
              ui.PlatformDispatcher.instance.views.first.display.refreshRate;
          final hz = refresh > 0 ? refresh : 60.0;
          final cadence = Duration(microseconds: (1000000 / hz).round());
          final steps = (hz * 6).round();
          final manualAt = (hz * 4).round();
          final locateEvery = (hz * .4).round();
          final appendEvery = (hz * .25).round();
          final contexts =
              <({int at, bool moving, int epoch, bool dragging})>[];
          var epoch = 0;
          var wasMoving = false;
          TestGesture? drag;
          final start = developer.Timeline.now;
          for (var frame = 0; frame < steps; frame++) {
            if (frame < manualAt && frame % locateEvery == 0) {
              sidebar.currentState!.locateToTime(
                Duration(
                  seconds:
                      (midpoint + ((frame ~/ locateEvery).isEven ? 4 : 0)) * 3,
                ),
              );
            }
            if (frame == manualAt) {
              drag = await tester.startGesture(
                tester.getCenter(find.byType(ScrollablePositionedList)),
              );
              await drag.moveBy(const Offset(0, -20));
            } else if (frame > manualAt) {
              await drag!.moveBy(Offset(0, -240 / hz));
            }
            if (frame % appendEvery == 0) {
              final added = _cues(primary.snapshot.length, 2);
              primary.addAll(added);
              secondary.addAll(
                added.map(
                  (cue) => cue.copyWith(text: 'Translation ${cue.index}.'),
                ),
              );
              update(() {
                subtitles = primary.snapshot;
                translations = secondary.snapshot;
              });
            }
            final moving = UiInteractionBudget.instance.isActive;
            if (moving != wasMoving) epoch++;
            wasMoving = moving;
            contexts.add((
              at: developer.Timeline.now,
              moving: moving,
              epoch: epoch,
              dragging: frame >= manualAt,
            ));
            // Let the native engine tick at its own VSync; test-driven pumps
            // would cap the sample rate and hide event-loop stalls.
            await Future<void>.delayed(cadence);
          }
          await drag?.up();
          final end = developer.Timeline.now;
          await tester.pumpAndSettle(const Duration(milliseconds: 8));
          await tester.pump(const Duration(seconds: 1));
          final samples = <ui.FrameTiming>[];
          final intervals = <int>[];
          final dragIntervals = <int>[];
          final dragLatencies = <int>[];
          var locateFrames = 0;
          int? previousDragInput;
          int? previousAt, previousEpoch;
          var missed = 0;
          final budget = 1000000 / hz;
          for (final frame in frames) {
            final at = frame.timestampInMicroseconds(ui.FramePhase.vsyncStart);
            final builtAt = frame.timestampInMicroseconds(
              ui.FramePhase.buildStart,
            );
            if (at < start || at > end) continue;
            final context = contexts.lastWhere(
              (context) => context.at <= builtAt,
              orElse: () => (at: 0, moving: false, epoch: -1, dragging: false),
            );
            if (!context.moving) continue;
            samples.add(frame);
            if (!context.dragging) locateFrames++;
            if (context.dragging && previousDragInput != context.at) {
              previousDragInput = context.at;
              dragLatencies.add(
                math.max(
                  0,
                  frame.timestampInMicroseconds(ui.FramePhase.rasterFinish) -
                      context.at,
                ),
              );
            }
            if (previousAt != null && previousEpoch == context.epoch) {
              final interval = at - previousAt;
              if (context.dragging) {
                dragIntervals.add(interval);
              } else {
                intervals.add(interval);
                missed += math.max(0, (interval / budget).round() - 1);
              }
            }
            previousAt = at;
            previousEpoch = context.epoch;
          }
          intervals.sort();
          dragIntervals.sort();
          dragLatencies.sort();
          expect(
            samples.length,
            greaterThan(100),
            reason: 'Native live-frame sampling is required.',
          );
          final build =
              samples
                  .map((frame) => frame.buildDuration.inMicroseconds)
                  .toList()
                ..sort();
          final raster =
              samples
                  .map((frame) => frame.rasterDuration.inMicroseconds)
                  .toList()
                ..sort();
          double percentile(List<int> values, double p) =>
              values[((values.length - 1) * p).round()] / 1000;
          final slow =
              samples
                  .where(
                    (frame) =>
                        frame.buildDuration.inMicroseconds > budget ||
                        frame.rasterDuration.inMicroseconds > budget,
                  )
                  .length /
              samples.length;
          final report = <String, Object>{
            'mode': mode,
            'cues': count,
            'workers': stress,
            'loadSource': _CpuWorkers.executable.isEmpty
                ? 'isolates'
                : 'processes',
            'frames': samples.length,
            'displayHz': hz,
            'budgetMs': budget / 1000,
            'uiP95Ms': percentile(build, .95),
            'uiP99Ms': percentile(build, .99),
            'rasterP95Ms': percentile(raster, .95),
            'rasterP99Ms': percentile(raster, .99),
            'overBudgetFraction': slow,
            'vsyncP95Ms': percentile(
              samples.map((f) => f.vsyncOverhead.inMicroseconds).toList()
                ..sort(),
              .95,
            ),
            'locateFrames': locateFrames,
            'locateIntervalP95Ms': percentile(intervals, .95),
            'dragIntervalP95Ms': percentile(dragIntervals, .95),
            'dragInputToRasterP95Ms': percentile(dragLatencies, .95),
            'estimatedMissedMotionFrames': missed,
            'estimatedMissedMotionFraction': missed / (locateFrames + missed),
            'platform': Platform.operatingSystem,
          };
          reports.add(report);
          binding.reportData = {'subtitleReading': reports};
          // ignore: avoid_print
          print('SUBTITLE_SCROLL_PROFILE ${jsonEncode(report)}');
          expect(percentile(build, .95), lessThan(budget / 1000));
          expect(percentile(raster, .95), lessThan(budget / 1000));
          expect(slow, lessThan(.05));
          expect(percentile(intervals, .95), lessThan(budget * 1.8 / 1000));
          expect(percentile(dragLatencies, .95), lessThan(budget * 2.5 / 1000));
        } finally {
          binding.removeTimingsCallback(collect);
          await workers.close();
          await tester.pumpWidget(const SizedBox.shrink());
          await controller.dispose();
        }
      },
    );
  }
}
